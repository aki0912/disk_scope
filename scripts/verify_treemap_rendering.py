#!/usr/bin/env python3
"""Exercise the real SwiftUI Canvas in a mouse-disabled macOS test window."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--treemap-source", type=Path, help="Optional older TreemapView.swift for a before/after comparison")
args = parser.parse_args()

sources = [
    "Sources/DiskScopeCore/ScanData.swift",
    "Sources/DiskScopeCore/Treemap.swift",
    "Sources/DiskScope/ScannerModel.swift",
    "Sources/DiskScope/Theme.swift",
    "Sources/DiskScope/TreemapView.swift",
    "Tests/Rendering/RenderHarness.swift",
]
with tempfile.TemporaryDirectory(prefix="diskscope-rendering-") as temporary:
    work = Path(temporary)
    fixture = work / "fixture"
    fixture.mkdir()
    (fixture / "movie.mp4").write_bytes(b"m" * 65537)
    (fixture / "notes.txt").write_bytes(b"n" * 8193)
    (fixture / "photos").mkdir()
    (fixture / "photos/image.png").write_bytes(b"i" * 32769)
    copied = []
    for source in sources:
        path = ROOT / source
        if path.name == "TreemapView.swift" and args.treemap_source:
            path = args.treemap_source
        text = path.read_text().replace("import DiskScopeCore\n", "")
        if source.endswith("TreemapView.swift"):
            marker = "Canvas { context, _ in"
            assert text.count(marker) == 1, "Update the render probe insertion point"
            text = text.replace(marker, marker + """
                RenderProbe.record(names: tiles.map(\\.title), bytes: tiles.map(\\.bytes),
                                   rectangles: tiles.map(\\.rect), selectedID: model.selectedID)
""")
        destination = work / Path(source).name
        destination.write_text(text)
        copied.append(str(destination))
    subprocess.run(["cargo", "build", "--release", "--manifest-path", "rust/Cargo.toml"], cwd=ROOT, check=True)
    command = [
        "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macosx26.0",
        "-module-cache-path", str(work / "module-cache"),
        "-I", "Sources/CScanner", "-L", "rust/target/release", "-ldiskscope_scanner",
        *copied, "-o", str(work / "RenderHarness"),
    ]
    subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([str(work / "RenderHarness"), str(fixture)], cwd=ROOT, check=True, timeout=30)
