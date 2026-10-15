#!/usr/bin/env python3
"""Verify a release bundle without opening the app or accessing user data."""
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def verify(app, architecture):
    assert architecture in ("arm64", "x86_64"), architecture
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    assert info["CFBundleIdentifier"] == "io.github.ayush5harma.PhotosBackup"
    version = (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip()
    assert info["CFBundleShortVersionString"] == version
    assert info["LSMinimumSystemVersion"] == "14.0"
    assert not info.get("PhotosBackupE2ECopy"), "An E2E copy cannot ship"
    binaries = []
    for path in contents.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as handle:
                magic = handle.read(4)
            if magic not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                continue
            arches = output("lipo", "-archs", str(path)).split()
            assert architecture in arches, f"Wrong architecture: {path}: {arches}"
            commands = output("otool", "-arch", architecture, "-l", str(path))
            versions = []
            for block in re.split(r"Load command \d+", commands):
                if "cmd LC_BUILD_VERSION" in block:
                    versions += re.findall(r"^\s*minos\s+(\d+(?:\.\d+)+)\s*$", block, re.MULTILINE)
                elif "cmd LC_VERSION_MIN_MACOSX" in block:
                    versions += re.findall(r"^\s*version\s+(\d+(?:\.\d+)+)\s*$", block, re.MULTILINE)
            assert versions, f"No deployment target: {path}"
            assert all(tuple(map(int, v.split('.'))) <= (14, 0, 0) for v in versions), f"Requires newer macOS: {path}: {versions}"
            binaries.append(path)
    assert contents / "MacOS/PhotosBackup" in binaries
    python = contents / "Resources/python/bin/python3"
    assert output(str(python), "-I", "-B", "-c", "import platform; print(platform.machine())") == architecture
    bridge = contents / "Resources/bridge/gpmc_bridge.py"
    result = subprocess.run([str(python), "-I", "-B", str(bridge)], input='{"command":"version"}\n', text=True, capture_output=True, check=True)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert any(event.get("gpmc") for event in events), "Missing gpmc version"
    subprocess.run([str(python), "-I", "-B", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import ssl, sqlite3; from gpmc import Client", str(bridge.parent / "site-packages")], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Verified {len(binaries)} Mach-O files for {architecture}, macOS 14, bridge imports and bundle signature")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(), sys.argv[2])
