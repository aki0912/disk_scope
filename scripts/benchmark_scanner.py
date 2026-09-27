"""Compare release scanner binaries on identical, warm filesystem fixtures."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--candidate', type=Path, default=Path('rust/target/release/examples/scan'))
parser.add_argument('--files', type=int, default=50000)
parser.add_argument('--runs', type=int, default=8)
args = parser.parse_args()
if args.files < 1 or args.runs < 3:
    parser.error('Use at least one file and three measured runs')
binaries = {'before': args.baseline.resolve(), 'after': args.candidate.resolve()}
for binary in binaries.values():
    if not binary.is_file():
        parser.error(f'Binary does not exist: {binary.name}')


def contents(result):
    paths = [''] * len(result['nodes'])
    records = {}
    for node in result['nodes']:
        parent = node['parent']
        relative = '' if parent is None else paths[parent] + '/' + node['name']
        paths[node['id']] = relative
        records[relative] = {key: value for key, value in node.items() if key not in ('id', 'parent')}
    return records


report = {'files': args.files, 'file_bytes': 0, 'measured_runs': args.runs, 'warmup_runs': 1, 'cases': {}}
with tempfile.TemporaryDirectory(prefix='diskscope-benchmark-') as temporary:
    for case in ('flat', 'wide'):
        root = Path(temporary) / case
        root.mkdir()
        directories = 1 if case == 'flat' else min(200, args.files)
        folders = [root] if case == 'flat' else [root / f'dir-{i}' for i in range(directories)]
        for folder in folders:
            folder.mkdir(exist_ok=True)
        for index in range(args.files):
            (folders[index % directories] / f'file-{index:06}.txt').touch()
        wall = {key: [] for key in binaries}
        scan = {key: [] for key in binaries}
        results = {}
        for iteration in range(args.runs + 1):
            order = ('before', 'after') if iteration % 2 == 0 else ('after', 'before')
            for key in order:
                started = time.perf_counter()
                output = subprocess.check_output([str(binaries[key]), str(root)], timeout=120)
                duration = (time.perf_counter() - started) * 1000
                result = json.loads(output)
                results[key] = result
                if iteration:
                    wall[key].append(duration)
                    scan[key].append(result['elapsed'] * 1000)
        assert contents(results['before']) == contents(results['after']), 'Filesystem results differ'
        for key in ('fileCount', 'directoryCount', 'issueCount', 'excludedCount', 'duplicateCount'):
            assert results['before'][key] == results['after'][key], key
        report['cases'][case] = {
            key: {'export_ms_median': round(statistics.median(wall[key]), 3),
                  'scan_ms_median': round(statistics.median(scan[key]), 3),
                  'export_ms_samples': [round(value, 3) for value in wall[key]]}
            for key in binaries
        }
print(json.dumps(report, indent=2))
