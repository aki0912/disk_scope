#!/usr/bin/env python3
"""Compare scan-to-Canvas latency in the real dashboard, using release builds."""
import argparse
import json
import math
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True, help='A source checkout of the previous version')
parser.add_argument('--runs', type=int, default=8)
parser.add_argument('--settled', action='store_true', help='Also measure resident memory one second after first draw')
parser.add_argument('--sizes', type=int, nargs='+', default=[1000, 10000, 50000])
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.runs < 3 or min(args.sizes) < 1:
    parser.error('Use at least three runs and positive sizes')


def checked(command, **kwargs):
    result = subprocess.run(command, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{command[0]} failed:\n{result.stdout}\n{result.stderr}')
    return result


def compile_version(source, destination):
    destination.mkdir()
    shutil.copytree(source / 'rust', destination / 'rust', ignore=shutil.ignore_patterns('target'))
    rust = destination / 'rust/src/lib.rs'
    text = rust.read_text()
    marker = '    let mut json ='
    assert text.count(marker) == 1
    text = text.replace(marker, '    let json_started = Instant::now();\n' + marker)
    text = text.replace('    Ok(json)', '    eprintln!("BENCH_JSON_MS={}", json_started.elapsed().as_secs_f64() * 1000.0);\n    Ok(json)')
    rust.write_text(text)
    checked(['cargo', 'build', '--release', '--manifest-path', str(destination / 'rust/Cargo.toml')])
    sources = [*sorted((source / 'Sources/DiskScopeCore').glob('*.swift')),
               *[source / f'Sources/DiskScope/{name}.swift' for name in ['ScannerModel', 'Theme', 'TreemapView', 'ContentView']]]
    copied = []
    for path in sources:
        text = path.read_text().replace('import DiskScopeCore\n', '')
        if path.name == 'ScannerModel.swift':
            marker = '    static func result(_ id: UInt64) throws -> ScanSnapshot {'
            assert marker in text
            text = text.replace(marker, marker + '\n        let decodeStarted = ProcessInfo.processInfo.systemUptime\n        defer { PerformanceProbe.record("decode_ms", (ProcessInfo.processInfo.systemUptime - decodeStarted) * 1000) }')
            marker = 'self.recentRoots.removeAll'
            assert text.count(marker) == 1
            text = text.replace(marker, 'PerformanceProbe.record("prepared_at", ProcessInfo.processInfo.systemUptime)\n                    ' + marker)
        elif path.name == 'ScanData.swift':
            marker = 'public func largestChildren(of id: Int, metric: SizeMetric, limit: Int, matching query: String = "") -> ChildSelection {'
            assert marker in text
            text = text.replace(marker, marker + '''
        let selectionStarted = ProcessInfo.processInfo.systemUptime
        defer {
            if id == 0 && limit == 300 && query.isEmpty {
                PerformanceProbe.record("selection_ms", (ProcessInfo.processInfo.systemUptime - selectionStarted) * 1000)
                PerformanceProbe.record("selection_on_main", Thread.isMainThread ? 1 : 0)
            }
        }
''')
        elif path.name == 'TreemapView.swift':
            marker = 'Canvas { context, _ in'
            assert text.count(marker) == 1
            text = text.replace(marker, marker + '\n                defer { if !tiles.isEmpty { PerformanceProbe.frameFinished() } }')
        target = destination / path.name
        target.write_text(text)
        copied.append(str(target))
    executable = destination / 'FirstFrame'
    checked(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
             '-target', f'{platform.machine()}-apple-macosx14.0',
             '-module-cache-path', str(destination / 'module-cache'),
             '-I', str(source / 'Sources/CScanner'), '-L', str(destination / 'rust/target/release'),
             '-ldiskscope_scanner', *copied, str(ROOT / 'Benchmarks/FirstFrame.swift'), '-o', str(executable)])
    return executable


def sample(executable, fixture):
    output = checked([str(executable), str(fixture), *(['--settled'] if args.settled else [])], timeout=45)
    data = json.loads(output.stdout.strip().splitlines()[-1])
    data['json_ms'] = float(re.search(r'BENCH_JSON_MS=([0-9.eE+-]+)', output.stderr).group(1))
    data['detection_and_handoff_ms'] = (data['first_frame_ms'] - data['scan_ms'] - data['json_ms']
                                        - data['decode_ms'] - data['selection_ms'] - data['prepare_to_frame_ms'])
    return data


report = {'measured_runs': args.runs, 'first_run_policy': 'reported separately; not a cold-cache measurement',
          'measurement': 'model.start through completion of the first nonempty Canvas renderer; excludes app startup and GPU presentation',
          'cases': {}}
with tempfile.TemporaryDirectory(prefix='diskscope-first-frame-') as temporary:
    work = Path(temporary)
    binaries = {name: compile_version(source, work / name)
                for name, source in [('before', args.baseline.resolve()), ('after', ROOT)]}
    case_index = 0
    for count in args.sizes:
        for shape in ['flat', 'nested']:
            fixture = work / f'{shape}-{count}'
            fixture.mkdir()
            if shape == 'flat':
                folders = [fixture]
            else:
                folders = [fixture / f'group-{i // 10:02}' / f'folder-{i:03}' for i in range(100)]
                for folder in folders:
                    folder.mkdir(parents=True, exist_ok=True)
            for index in range(count):
                (folders[index % len(folders)] / f'file-{index:06}.txt').write_bytes(b'x')
            samples = {name: [] for name in binaries}
            first = {}
            for iteration in range(args.runs + 1):
                order = ['before', 'after'] if (iteration + case_index) % 2 == 0 else ['after', 'before']
                pair = {}
                for name in order:
                    result = sample(binaries[name], fixture)
                    pair[name] = result
                    if iteration == 0:
                        first[name] = result
                    else:
                        samples[name].append(result)
                for key in ['files', 'logical_bytes', 'allocated_bytes']:
                    assert pair['before'][key] == pair['after'][key], (key, pair)
                assert pair['after']['selection_on_main'] == 0
            case = {'first_run': first, 'samples': samples, 'summary': {}}
            for name, values in samples.items():
                case['summary'][name] = {
                    'median': {key: statistics.median(item[key] for item in values) for key in values[0]},
                    'p95_first_frame_ms': sorted(item['first_frame_ms'] for item in values)[math.ceil(len(values) * .95) - 1],
                    'max_peak_rss_bytes': max(item['peak_rss_bytes'] for item in values),
                }
            report['cases'][fixture.name] = case
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2))
            print(f'{fixture.name}: ' + ' / '.join(f'{name} {case["summary"][name]["median"]["first_frame_ms"]:.1f} ms' for name in binaries), flush=True)
            shutil.rmtree(fixture)
            case_index += 1
