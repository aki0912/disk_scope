#!/usr/bin/env python3
"""Compare actual ScannerModel search input and result latency, alternating fresh processes."""
import argparse
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--runs', type=int, default=8)
args = parser.parse_args()
if args.runs < 3:
    parser.error('Use at least three measured runs')


def checked(command, **kwargs):
    result = subprocess.run(command, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


report = {'measured_runs': args.runs, 'measurement': 'Search setter on MainActor; results-ready includes debounce and up to one polling interval (1 ms requested). Synthetic names; fresh process per sample, first pair separate.', 'cases': {}}
with tempfile.TemporaryDirectory(prefix='diskscope-search-') as temporary:
    work = Path(temporary)
    binaries = {}
    checked(['cargo', 'build', '--release', '--manifest-path', str(ROOT / 'rust/Cargo.toml')])
    for version, source in [('before', args.baseline.resolve()), ('after', ROOT)]:
        destination = work / version
        destination.mkdir()
        copied = []
        for name in ['Sources/DiskScopeCore/ScanData.swift', 'Sources/DiskScope/ScannerModel.swift']:
            text = (source / name).read_text().replace('import DiskScopeCore\n', '')
            if name.endswith('ScannerModel.swift') and 'var searching' not in text:
                text = text.replace('final class ScannerModel: ObservableObject {', 'final class ScannerModel: ObservableObject {\n    var searching: Bool { false }')
            target = destination / Path(name).name
            target.write_text(text)
            copied.append(str(target))
        binaries[version] = destination / 'SearchBenchmark'
        checked(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
                 '-target', f'{platform.machine()}-apple-macosx26.0', '-module-cache-path', str(work / 'module-cache'),
                 '-I', str(ROOT / 'Sources/CScanner'), '-L', str(ROOT / 'rust/target/release'), '-ldiskscope_scanner',
                 *copied, str(ROOT / 'Benchmarks/Search.swift'), '-o', str(binaries[version])])
    for count in [10000, 50000]:
        samples = {'before': [], 'after': []}
        first = {}
        for iteration in range(args.runs + 1):
            for version in (['before', 'after'] if iteration % 2 == 0 else ['after', 'before']):
                result = json.loads(checked([str(binaries[version]), str(count)], timeout=30))
                if iteration == 0:
                    first[version] = result
                else:
                    samples[version].append(result)
        summary = {}
        for version, values in samples.items():
            summary[version] = []
            for index in range(3):
                row = {'query': values[0][index]['query'], 'matches': values[0][index]['matches']}
                for metric in ['input_main_thread_ms', 'results_ready_ms']:
                    numbers = [sample[index][metric] for sample in values]
                    row[metric] = {'median': statistics.median(numbers), 'max': max(numbers)}
                summary[version].append(row)
        report['cases'][str(count)] = {'first_run': first, 'samples': samples, 'summary': summary}
        print(f'{count}: {summary}', flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2))
