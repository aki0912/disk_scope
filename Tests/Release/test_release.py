import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import hashlib

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


version = load('ci_release_version')
publisher = load('ci_publish_release')


class ReleaseTests(unittest.TestCase):
    def test_version_is_stable_on_retry_and_distinct_between_runs(self):
        self.assertEqual(version.release_version('0.1.0', '42'), {
            'tag': 'v0.1.0-build.42', 'asset_version': '0.1.0-build.42', 'build_number': '42'})
        self.assertNotEqual(version.release_version('0.1.0', '42'), version.release_version('0.1.0', '43'))
        for base, run in [('0.1', '1'), ('0.1.0', '0'), ('0.1.0', '../1'), ('x\ny', '1')]:
            with self.assertRaises(ValueError):
                version.release_version(base, run)

    def test_publish_retries_and_integrity(self):
        for mode in ['new', 'draft', 'published', 'conflict', 'tag_conflict', 'corrupt']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                dmg = Path(temporary) / 'DiskScope-0.1.0-build.42-arm64.dmg'
                checksum = Path(str(dmg) + '.sha256')
                dmg.write_bytes(b'verified disk image')
                checksum.write_text(f'{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}\n')
                calls = []
                def fake_gh(*args):
                    calls.append(args)
                    if args[0] == 'api' and '/git/matching-refs/' in args[-1]:
                        return json.dumps([{'ref': 'refs/tags/v0.1.0-build.42'}] if mode == 'tag_conflict' else [])
                    if args[0] == 'api' and '/commits/' in args[-1]:
                        return json.dumps({'sha': 'other'})
                    if args[0] == 'api':
                        release = {'tag_name': 'v0.1.0-build.42', 'target_commitish': 'other' if mode == 'conflict' else 'abc',
                                   'draft': mode != 'published', 'html_url': 'https://example.test/release',
                                   'assets': [{'name': dmg.name}, {'name': checksum.name}]}
                        return json.dumps([[] if mode == 'new' else [release]])
                    if args[:2] == ('release', 'download'):
                        directory = Path(args[args.index('--dir') + 1])
                        (directory / dmg.name).write_bytes(b'corrupt' if mode == 'corrupt' else dmg.read_bytes())
                        (directory / checksum.name).write_bytes(checksum.read_bytes())
                    return 'https://example.test/release'
                with patch.dict(os.environ, {'RELEASE_TAG': 'v0.1.0-build.42', 'GITHUB_SHA': 'abc', 'GH_REPO': 'owner/repo',
                                             'RELEASE_DMG': str(dmg), 'RELEASE_SHA256': str(checksum)}), patch.object(publisher, 'gh', fake_gh):
                    if mode in ['conflict', 'tag_conflict', 'corrupt']:
                        with self.assertRaises(RuntimeError): publisher.publish()
                    else:
                        publisher.publish()
                publishes = [c for c in calls if c[:2] == ('release', 'edit')]
                self.assertEqual(bool(publishes), mode in ['new', 'draft'])
                if mode == 'published': self.assertEqual(len(calls), 2)
                if mode == 'new':
                    self.assertIn('--draft', next(c for c in calls if c[:2] == ('release', 'create')))


if __name__ == '__main__':
    unittest.main()
