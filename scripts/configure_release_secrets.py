#!/usr/bin/env python3
"""One-time interactive setup; secret values never enter arguments or logs."""
import base64
import getpass
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

REPO = 'aki0912/disk_scope'
ROOT = Path(__file__).resolve().parents[1]


def main():
    os.umask(0o077)
    subprocess.run(['gh', 'auth', 'status'], check=True)
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    choices = re.findall(r'([A-F0-9]{40}) "(Developer ID Application: [^"]+)"', identities)
    if not choices:
        raise RuntimeError('Developer ID Application証明書が見つかりません。')
    for number, (fingerprint, name) in enumerate(choices, 1):
        print(f'{number}: {name} [{fingerprint}]')
    index = int(input('使用する証明書の番号: ')) - 1
    if not 0 <= index < len(choices):
        raise ValueError('証明書の番号が範囲外です。')
    fingerprint, name = choices[index]
    team = re.search(r'\(([A-Z0-9]+)\)$', name).group(1)
    print(f'{REPO} のGitHub Actions Secretsに、選択した証明書と公証用情報を登録します。')
    apple_id = input('Apple Accountのメールアドレス: ').strip()
    password = getpass.getpass('公証用のアプリ用パスワード（入力は表示されません）: ')
    if not apple_id or not password:
        raise ValueError('メールアドレスとアプリ用パスワードが必要です。')
    with tempfile.TemporaryDirectory(prefix='diskscope-secrets-') as temporary:
        work = Path(temporary)
        exporter = work / 'export-identity'
        subprocess.run(['swiftc', str(ROOT / 'scripts/export_signing_identity.swift'), '-o', str(exporter)], check=True)
        p12_password = secrets.token_urlsafe(32)
        p12 = work / 'identity.p12'
        subprocess.run([str(exporter), fingerprint, str(p12)], input=p12_password + '\n', text=True, check=True)
        values = {
            'SIGNING_CERTIFICATE_BASE64': base64.b64encode(p12.read_bytes()).decode(),
            'SIGNING_CERTIFICATE_PASSWORD': p12_password,
            'SIGNING_IDENTITY': fingerprint,
            'APPLE_ID': apple_id,
            'APPLE_TEAM_ID': team,
            'APPLE_APP_PASSWORD': password,
        }
        for key, value in values.items():
            subprocess.run(['gh', 'secret', 'set', key, '--repo', REPO], input=value, text=True, check=True)
            print(f'{key}: 登録済み')
    print('設定完了。PRのマージ後、GitHub Actionsが署名・公証済みDMGを作成します。')


if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        raise SystemExit('設定を中止しました。')
