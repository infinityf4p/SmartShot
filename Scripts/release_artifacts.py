#!/usr/bin/env python3
"""Stage versioned sources and verify the macOS preview before packaging."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from preview_release import asset_names, check_files, source_version, version_tuple


def stage(source, destination, version, build):
    version_tuple(version)
    if not 1 <= build <= 9999:
        raise ValueError("Build number must be between 1 and 9999")
    destination.mkdir()
    for name in ("Sources", "Resources", "BrowserExtension", "Tests"):
        shutil.copytree(source / name, destination / name,
                        ignore=shutil.ignore_patterns("node_modules", "__pycache__", ".DS_Store"))
    project = (source / "project.yml").read_text()
    for key, value in (("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)):
        project, count = re.subn(rf"^    {key}: .+$", f"    {key}: {value}", project, flags=re.M)
        if count != 1:
            raise ValueError(f"Expected one {key} in project.yml")
    (destination / "project.yml").write_text(project)
    for name in ("manifest.json", "package.json"):
        path = destination / "BrowserExtension" / name
        data = json.loads(path.read_text())
        data["version"] = version
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def verify_app(app, version, build):
    extension = app / "Contents/PlugIns/SmartShot Safari Extension.appex"
    for bundle in (app, extension):
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (version, str(build)):
            raise ValueError(f"Incorrect version in {bundle}")
    manifest = json.loads((extension / "Contents/Resources/manifest.json").read_text())
    if manifest["version"] != version:
        raise ValueError("Embedded browser extension version differs from the app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    binaries = [app / "Contents/MacOS/SmartShot",
                extension / "Contents/MacOS/SmartShot Safari Extension",
                app / "Contents/Helpers/SmartShotNativeHost", app / "Contents/Helpers/smartshot"]
    for binary in binaries:
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
        if set(architectures) != {"arm64", "x86_64"}:
            raise ValueError(f"Expected arm64 and x86_64 in {binary}, found {architectures}")
        signature = subprocess.run(["codesign", "-d", "--verbose=4", str(binary)],
                                   check=True, capture_output=True, text=True).stderr
        if "Signature=adhoc" not in signature or "runtime" not in signature:
            raise ValueError(f"Expected an ad-hoc signature with hardened runtime: {binary}")
        data = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(binary)],
                              check=True, capture_output=True).stdout
        entitlements = plistlib.loads(data) if data else {}
        if entitlements.get("com.apple.security.get-task-allow"):
            raise ValueError(f"Development entitlement found in {binary}")
        required = None
        if binary == binaries[0]:
            required = "com.apple.security.device.audio-input"
        elif binary == binaries[1]:
            required = "com.apple.security.app-sandbox"
        if required and entitlements.get(required) is not True:
            raise ValueError(f"Missing {required} in {binary}")


def checksums(directory, version):
    names = asset_names(version)[:-1]
    content = "".join(f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
                      for name in sorted(names))
    (directory / "SHA256SUMS.txt").write_text(content)
    check_files(directory, version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("stage", "verify", "checksums", "version"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    args = parser.parse_args()
    if args.command == "stage":
        stage(args.path, args.destination, args.version, args.build)
    elif args.command == "verify":
        verify_app(args.path, args.version, args.build)
    elif args.command == "checksums":
        checksums(args.path, args.version)
    else:
        print(*source_version(args.path))


if __name__ == "__main__":
    main()
