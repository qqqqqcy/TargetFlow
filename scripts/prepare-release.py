#!/usr/bin/env python3
"""Create a release snapshot version without writing generated commits to main."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
project = root / "Dayflow/Dayflow.xcodeproj/project.pbxproj"
text = project.read_text()
current = re.search(r"MARKETING_VERSION = ([0-9.]+);", text).group(1)
tags = subprocess.check_output(["git", "tag", "--list", "v*"], cwd=root, text=True).splitlines()
versions = [tuple(map(int, current.split(".")))]
for tag in tags:
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-.*)?", tag)
    if match:
        versions.append(tuple(map(int, match.groups())))
major, minor, patch = max(versions)
version = f"{major}.{minor}.{patch + 1}"
build = max(
    int(os.environ.get("GITHUB_RUN_NUMBER", "1")),
    max(map(int, re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", text))) + 1,
)
text = re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {version};", text)
text = re.sub(r"CURRENT_PROJECT_VERSION = [^;]+;", f"CURRENT_PROJECT_VERSION = {build};", text)
project.write_text(text)
plist_path = root / "Dayflow/Dayflow/Info.plist"
plist = plistlib.loads(plist_path.read_bytes())
plist["CFBundleShortVersionString"] = version
plist["CFBundleVersion"] = str(build)
plist_path.write_bytes(plistlib.dumps(plist, sort_keys=False))
source = os.environ.get("GITHUB_SHA") or subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
metadata = {"version": version, "build": build, "source": source, "tag": f"v{version}"}
(root / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
if os.environ.get("GITHUB_OUTPUT"):
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in metadata.items():
            output.write(f"{key}={value}\n")
print(json.dumps(metadata))
