#!/usr/bin/env python3
"""Compare snapshot storage, decoding, selection and navigation with identical JSON inputs."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--runs', type=int, default=8)
parser.add_argument('--sizes', type=int, nargs='+', default=[50000, 500000])
args = parser.parse_args()
if args.runs < 3 or min(args.sizes) < 10:
    parser.error('Use at least three runs and sizes >= 10')


def checked(command, **kwargs):
    result = subprocess.run(command, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def fixture(path, count, shape):
    folders = 0 if shape == 'flat' else count // 10
    logical_totals = [0] * (folders + 1)
    allocated_totals = [0] * (folders + 1)
    for i in range(folders + 1, count + 1):
        logical_totals[0] += i % 4096
        allocated_totals[0] += (i % 8) * 4096
        if folders:
            parent = 1 + ((i - folders - 1) % folders)
            logical_totals[parent] += i % 4096
            allocated_totals[parent] += (i % 8) * 4096
    with path.open('w') as out:
        out.write(json.dumps(dict(rootPath='/fixture', elapsed=0, fileCount=count - folders,
                                  directoryCount=folders + 1, issueCount=0, excludedCount=0,
                                  duplicateCount=0, issues=[]))[:-1] + ',"nodes":[')
        for i in range(count + 1):
            directory = i <= folders
            parent = None if i == 0 else (0 if directory or not folders else 1 + ((i - folders - 1) % folders))
            node = dict(id=i, name=('folder' if directory else 'file') + f'-{i:06}.txt', parent=parent,
                        kind='directory' if directory else 'file', logical=logical_totals[i] if directory else i % 4096,
                        allocated=allocated_totals[i] if directory else (i % 8) * 4096, modified=0,
                        duplicate=False, excluded=False, unreadable=False)
            if i:
                out.write(',')
            out.write(json.dumps(node, separators=(',', ':')))
        out.write(']}')


report = {'measured_runs': args.runs, 'measurement': 'Fresh process per sample; first pair separate; JSON mapped read + decode + indexes. RSS includes runtime/allocator caches. Backing storage counts array capacity and stride, excluding strings and allocator headers. Operations are medians of four calls after one warmup.', 'cases': {}}
with tempfile.TemporaryDirectory(prefix='diskscope-storage-') as temporary:
    work = Path(temporary)
    binaries = {}
    for version, source in [('before', args.baseline.resolve()), ('after', ROOT)]:
        text = (source / 'Sources/DiskScopeCore/ScanData.swift').read_text()
        children_bytes = 'children.capacity * MemoryLayout<[Int]>.stride + children.reduce(0) { $0 + $1.capacity * MemoryLayout<Int>.stride }'
        text += '\nextension ScanSnapshot { var benchmarkStorageBytes: Int { nodes.capacity * MemoryLayout<ScanNode>.stride + descendantFiles.capacity * MemoryLayout<Int>.stride + (' + children_bytes + ') } }\n'
        path = work / (version + '.swift')
        path.write_text(text)
        binary = work / version
        checked(['swiftc', '-O', '-module-cache-path', str(work / 'module-cache'), str(path),
                 str(ROOT / 'Benchmarks/Storage.swift'), '-o', str(binary)])
        binaries[version] = binary
    for count in args.sizes:
        for shape in ['flat', 'nested']:
            path = work / f'{shape}-{count}.json'
            fixture(path, count, shape)
            samples = {'before': [], 'after': []}
            first = {}
            for iteration in range(args.runs + 1):
                pair = {}
                for version in (['before', 'after'] if iteration % 2 == 0 else ['after', 'before']):
                    result = json.loads(checked([str(binaries[version]), str(path)], timeout=90))
                    pair[version] = result
                    if iteration == 0:
                        first[version] = result
                    else:
                        samples[version].append(result)
                for key in ['nodes', 'hierarchy_digest', 'checksums']:
                    assert pair['before'][key] == pair['after'][key], (key, pair)
            summary = {}
            for version, values in samples.items():
                summary[version] = {key: statistics.median(item[key] for item in values)
                                    for key in values[0] if key not in ['operations_ms', 'checksums', 'hierarchy_digest']}
                summary[version]['operations_ms'] = {key: statistics.median(item['operations_ms'][key] for item in values)
                                                     for key in values[0]['operations_ms']}
                summary[version]['max_decode_ms'] = max(item['decode_ms'] for item in values)
                summary[version]['max_peak_rss_bytes'] = max(item['peak_rss_bytes'] for item in values)
            report['cases'][path.stem] = {'first_run': first, 'samples': samples, 'summary': summary}
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + '\n')
            print(path.stem, summary, flush=True)
            path.unlink()
