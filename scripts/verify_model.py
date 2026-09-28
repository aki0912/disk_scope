#!/usr/bin/env python3
"""Test actual search scheduling and Rust JSON ownership using temporary probes."""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='diskscope-model-') as temporary:
    work = Path(temporary)
    fixture = work / 'fixture'
    fixture.mkdir()
    (fixture / '日本語.txt').write_bytes(b'content')
    copied = []
    for name in ['Sources/DiskScopeCore/ScanData.swift', 'Sources/DiskScope/ScannerModel.swift', 'Tests/Model/ModelHarness.swift']:
        text = (ROOT / name).read_text().replace('import DiskScopeCore\n', '')
        if name.endswith('ScannerModel.swift'):
            replacements = {
                'let data = Data(bytesNoCopy:': 'OwnershipProbe.take(pointer)\n        let data = Data(bytesNoCopy:',
                'ds_string_free(buffer.assumingMemoryBound(to: CChar.self))': 'OwnershipProbe.free(buffer.assumingMemoryBound(to: CChar.self))',
                'checkCancellation: { try Task.checkCancellation() }': 'checkCancellation: { try SearchProbe.shared.check() }',
            }
            for old, new in replacements.items():
                assert text.count(old) == 1, old
                text = text.replace(old, new)
        target = work / Path(name).name
        target.write_text(text)
        copied.append(str(target))
    subprocess.run(['cargo', 'build', '--release', '--manifest-path', 'rust/Cargo.toml'], cwd=ROOT, check=True)
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
                    '-target', f'{platform.machine()}-apple-macosx26.0', '-module-cache-path', str(work / 'module-cache'),
                    '-I', 'Sources/CScanner', '-L', 'rust/target/release', '-ldiskscope_scanner',
                    *copied, '-o', str(work / 'ModelHarness')], cwd=ROOT, check=True)
    subprocess.run([str(work / 'ModelHarness'), str(fixture)], cwd=ROOT, check=True, timeout=30)
