#!/usr/bin/env python3
"""Publish only a complete, verified DMG; retries never overwrite a public asset."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import quote


def gh(*args: str) -> str:
    return subprocess.check_output(["gh", *args], text=True)


def publish() -> None:
    tag = os.environ["RELEASE_TAG"]
    sha = os.environ["GITHUB_SHA"]
    repo = os.environ["GH_REPO"]
    dmg = Path(os.environ["RELEASE_DMG"])
    checksum = Path(os.environ["RELEASE_SHA256"])
    if not dmg.is_file() or not checksum.is_file():
        raise RuntimeError("Release files are missing")
    expected = f"{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}"
    if checksum.read_text().strip() != expected:
        raise RuntimeError("DMG checksum does not match")
    refs = json.loads(gh("api", f"repos/{repo}/git/matching-refs/tags/{quote(tag, safe='')}"))
    if any(ref["ref"] == f"refs/tags/{tag}" for ref in refs):
        commit = json.loads(gh("api", f"repos/{repo}/commits/{quote(tag, safe='')}"))["sha"]
        if commit != sha:
            raise RuntimeError("Existing Git tag belongs to another commit")
    # A failed API request must fail the job, never look like an absent release.
    releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    existing = next((r for page in releases for r in page if r["tag_name"] == tag), None)
    if existing:
        if existing["target_commitish"] != sha:
            raise RuntimeError("Release tag belongs to another commit")
        if not existing["draft"]:
            assets = {a["name"] for a in existing["assets"]}
            if not {dmg.name, checksum.name}.issubset(assets):
                raise RuntimeError("Published release has incomplete assets")
            print(f"Already published: {existing['html_url']}")
            return
    else:
        notes = f"""PRのマージ後に自動作成したプレビュー版です。

Apple Silicon / macOS 26以降向け。Developer ID署名・Appleの公証済みです。
下のAssetsから `{dmg.name}` をダウンロードし、DiskScopeをApplicationsへドラッグしてください。
ソースコードのZIPはインストールには不要です。

ソース: {sha}
テスト・署名・公証・DMGの整合性を検証後に公開しています。
実機でのインストール確認を自動テストが代替するものではありません。
添付の `.sha256` ファイルでダウンロード後の整合性を確認できます。
"""
        with tempfile.TemporaryDirectory(prefix="diskscope-release-notes-") as temporary:
            notes_path = Path(temporary) / "notes.md"
            notes_path.write_text(notes)
            gh("release", "create", tag, "--target", sha, "--title", f"DiskScope {tag[1:]}（プレビュー）",
               "--notes-file", str(notes_path), "--draft", "--prerelease", "--latest=false")
    gh("release", "upload", tag, str(dmg), str(checksum), "--clobber")
    # Verify downloaded draft assets before exposing the release to users.
    with tempfile.TemporaryDirectory(prefix="diskscope-release-verify-") as temporary:
        gh("release", "download", tag, "--dir", temporary, "--pattern", dmg.name, "--pattern", checksum.name)
        if hashlib.sha256((Path(temporary) / dmg.name).read_bytes()).hexdigest() != expected.split()[0]:
            raise RuntimeError("Uploaded DMG does not match")
        if (Path(temporary) / checksum.name).read_bytes() != checksum.read_bytes():
            raise RuntimeError("Uploaded checksum does not match")
    gh("release", "edit", tag, "--draft=false", "--prerelease", "--latest=false")
    print(gh("release", "view", tag, "--json", "url", "--jq", ".url").strip())


if __name__ == "__main__":
    publish()
