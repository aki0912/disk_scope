"""Verify real filesystem totals through the same C ABI used by Swift."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parent.parent
subprocess.run(["cargo", "build", "--release", "--manifest-path", "rust/Cargo.toml", "--example", "scan"], cwd=project, check=True)
with tempfile.TemporaryDirectory(prefix="diskscope-verification-") as temporary:
    root = Path(temporary)
    for directory in range(48):
        folder = root / f"folder-{directory}"
        folder.mkdir()
        for index in range(250):
            (folder / f"file-{index}.txt").write_bytes(b"x" * (index + 1))
    for index in range(1300):
        (root / f"flat-{index}.bin").write_bytes(b"batch")
    (root / '日本語"改行\n.txt').write_bytes(b"unicode")
    (root / "empty").mkdir()
    (root / "sparse.bin").touch()
    with (root / "sparse.bin").open("wb") as stream:
        stream.truncate(256 * 1024 * 1024)
    os.link(root / "folder-0/file-0.txt", root / "hardlink.txt")
    os.symlink(root, root / "cycle")
    blocked = root / "unreadable"
    blocked.mkdir()
    blocked.chmod(0)
    try:
        output = subprocess.check_output([str(project / "rust/target/release/examples/scan"), str(root)], text=True)
    finally:
        blocked.chmod(0o700)
    result = json.loads(output)
    seen = set()
    logical = allocated = files = 0
    for current, _, names in os.walk(root, followlinks=False):
        paths = [Path(current) / name for name in names]
        paths += [Path(current) / name for name in os.listdir(current) if (Path(current) / name).is_symlink() and (Path(current) / name).is_dir()]
        for path in paths:
            stat = path.lstat()
            files += 1
            identity = (stat.st_dev, stat.st_ino)
            if identity in seen:
                continue
            seen.add(identity)
            logical += stat.st_size
            allocated += stat.st_blocks * 512
    assert result["nodes"][0]["logical"] == logical
    assert result["nodes"][0]["allocated"] == allocated
    assert result["fileCount"] == files == 13304
    assert result["duplicateCount"] == 1
    assert result["directoryCount"] == 51
    if os.geteuid() != 0:
        assert result["issueCount"] == 1
        assert any(node["unreadable"] for node in result["nodes"])
    for node in result["nodes"]:
        if node["kind"] == "directory":
            children = [item for item in result["nodes"] if item["parent"] == node["id"]]
            assert node["logical"] == sum(item["logical"] for item in children)
            assert node["allocated"] == sum(item["allocated"] for item in children)
    print(f'PASS: {files:,} files, exact logical and allocated totals, hardlinks, sparse file, symlink cycle, permission error, Unicode JSON; Rust scan {result["elapsed"]:.3f}s')
