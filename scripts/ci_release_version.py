#!/usr/bin/env python3
"""Give each workflow run an immutable release tag without editing source files."""
import os
import plistlib
import re
from pathlib import Path


def release_version(base: str, run_number: str) -> dict[str, str]:
    if not re.fullmatch(r"\d+\.\d+\.\d+", base):
        raise ValueError("CFBundleShortVersionString must be major.minor.patch")
    if not re.fullmatch(r"[1-9]\d*", run_number):
        raise ValueError("GITHUB_RUN_NUMBER must be a positive integer")
    version = f"{base}-build.{run_number}"
    return {"tag": f"v{version}", "asset_version": version, "build_number": run_number}


if __name__ == "__main__":
    with Path("Info.plist").open("rb") as source:
        base = plistlib.load(source)["CFBundleShortVersionString"]
    values = release_version(base, os.environ["GITHUB_RUN_NUMBER"])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    print(f"Release: {values['tag']}")
