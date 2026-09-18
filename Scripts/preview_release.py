#!/usr/bin/env python3
"""Reserve and publish one preview per merged PR. Requires gh and its GH_TOKEN."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
MARKER = re.compile(r"<!-- smartshot-release: (.+) -->")


def version_tuple(value):
    if not VERSION.fullmatch(value):
        raise ValueError(f"Invalid release version: {value}")
    parts = tuple(map(int, value.split(".")))
    if max(parts) > 65535:
        raise ValueError("Version exceeds the browser extension's component limit")
    return parts


def validate_plan(plan):
    version_tuple(plan["version"])
    if not re.fullmatch(r"[0-9a-f]{40}", plan["commit"]):
        raise ValueError("Invalid merge commit")
    if type(plan["pr"]) is not int or plan["pr"] < 1:
        raise ValueError("Invalid PR number")
    if type(plan["build"]) is not int or not 1 <= plan["build"] <= 9999:
        raise ValueError("Build number must be between 1 and 9999")
    return plan


def metadata(release):
    match = MARKER.search(release.get("body") or "")
    if not match:
        return None
    plan = validate_plan(json.loads(match[1]))
    if release["tag_name"] != "v" + plan["version"]:
        raise ValueError("Release metadata does not match its tag")
    return plan


def source_version(source):
    project = (Path(source) / "project.yml").read_text()
    version = re.search(r"^    MARKETING_VERSION: (\S+)\s*$", project, re.M)[1]
    build = int(re.search(r"^    CURRENT_PROJECT_VERSION: (\d+)\s*$", project, re.M)[1])
    version_tuple(version)
    return version, build


def asset_names(version):
    return [f"SmartShot-{version}-universal.dmg", f"SmartShot-{version}-universal.zip",
            f"SmartShot-Web-Selector-{version}.zip", "SHA256SUMS.txt"]


def check_assets(release, version, files=None):
    assets = release.get("assets", [])
    if sorted(asset["name"] for asset in assets) != sorted(asset_names(version)):
        raise ValueError("Release must contain exactly the four expected assets")
    for asset in assets:
        if asset["state"] != "uploaded" or asset["size"] <= 0:
            raise ValueError(f"Incomplete asset: {asset['name']}")
        if files is not None:
            data = files[asset["name"]].read_bytes()
            digest = "sha256:" + hashlib.sha256(data).hexdigest()
            if asset["size"] != len(data) or asset.get("digest") not in (None, digest):
                raise ValueError(f"Uploaded asset differs: {asset['name']}")


def check_files(directory, version):
    directory = Path(directory)
    names = asset_names(version)
    if sorted(path.name for path in directory.iterdir()) != sorted(names):
        raise ValueError("Package directory must contain exactly the four release assets")
    files = {name: directory / name for name in names}
    expected = "".join(f"{hashlib.sha256(files[name].read_bytes()).hexdigest()}  {name}\n"
                       for name in sorted(names[:-1]))
    if files["SHA256SUMS.txt"].read_text() != expected:
        raise ValueError("Release checksums do not match the packages")
    if any(path.stat().st_size == 0 for path in files.values()):
        raise ValueError("Empty release asset")
    return files


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def api(self, path, data=None, method="GET", missing_ok=False):
        command = ["gh", "api", f"repos/{self.repository}/{path}", "--method", method]
        if data is not None:
            command += ["--input", "-"]
        result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                                text=True, capture_output=True)
        if result.returncode:
            if missing_ok and "(HTTP 404)" in result.stderr:
                return None
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout)

    def pages(self, path):
        items = []
        page = 1
        while True:
            batch = self.api(f"{path}?per_page=100&page={page}")
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1

    def upload(self, tag, files):
        subprocess.run(["gh", "release", "upload", tag, *map(str, files.values()),
                        "--clobber", "--repo", self.repository], check=True)


def resolve_pr(github, number):
    if not re.fullmatch(r"[1-9][0-9]*", str(number)):
        raise ValueError("Provide a positive PR number")
    pr = github.api(f"pulls/{number}")
    if (not pr["merged"] or pr["base"]["ref"] != "main"
            or pr["base"]["repo"]["full_name"] != github.repository):
        raise ValueError("Only a PR already merged into this repository's main can be released")
    commit = pr["merge_commit_sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit or ""):
        raise ValueError("The PR has no valid merge commit")
    subprocess.run(["git", "merge-base", "--is-ancestor", commit, "origin/main"], check=True)
    return commit


def reserve(github, number, commit, source):
    releases = github.pages("releases")
    plans = [(release, metadata(release)) for release in releases]
    existing = [(release, plan) for release, plan in plans if plan and plan["pr"] == number]
    if len(existing) > 1:
        raise ValueError("Multiple release reservations exist for this PR")
    if existing:
        release, plan = existing[0]
        if plan["commit"] != commit:
            raise ValueError("The reserved release belongs to a different merge commit")
        if not release["draft"]:
            check_assets(release, plan["version"])
        return dict(plan, release_id=release["id"], needs_build=release["draft"])

    floor_version, floor_build = source_version(source)
    tags = [tag["name"] for tag in github.pages("tags")]
    tags += [release["tag_name"] for release in releases]
    versions = [version_tuple(tag[1:]) for tag in tags
                if tag.startswith("v") and VERSION.fullmatch(tag[1:])]
    latest = max(versions, default=(-1, -1, -1))
    next_version = version_tuple(floor_version)
    if next_version <= latest:
        next_version = (latest[0], latest[1], latest[2] + 1)
    plan = validate_plan({"pr": number, "commit": commit,
                          "version": ".".join(map(str, next_version)),
                          "build": max([floor_build] + [p["build"] for _, p in plans if p]) + 1})
    body = (
        f"<!-- smartshot-release: {json.dumps(plan, sort_keys=True)} -->\n\n"
        f"Preview from merged PR #{number}. Source commit: `{commit}`.\n\n"
        "Includes a universal macOS app (Apple Silicon and Intel), a browser extension, "
        "and SHA-256 checksums. Install SmartShot.app in /Applications.\n\n"
        "This preview is ad-hoc signed, without Developer ID signing or Apple notarization. "
        "macOS approval and renewed permissions may be required. Safari development "
        "restrictions still apply; see the repository's Safari guide.\n\n"
    )
    notes_request = {"tag_name": "v" + plan["version"], "target_commitish": commit}
    published_tags = [r["tag_name"] for r in releases if not r["draft"]
                      and r["tag_name"].startswith("v") and VERSION.fullmatch(r["tag_name"][1:])]
    if published_tags:
        notes_request["previous_tag_name"] = max(published_tags, key=lambda tag: version_tuple(tag[1:]))
    notes = github.api("releases/generate-notes", notes_request, method="POST")
    release = github.api("releases", {
        "tag_name": "v" + plan["version"], "target_commitish": commit,
        "name": f"SmartShot {plan['version']} Preview", "body": body + notes["body"],
        "draft": True, "prerelease": True, "make_latest": "false",
    }, method="POST")
    return dict(plan, release_id=release["id"], needs_build=True)


def ensure_tag(github, plan, create):
    tag = "v" + plan["version"]
    reference = github.api(f"git/ref/tags/{tag}", missing_ok=True)
    if reference is None:
        if not create:
            raise ValueError("Published release tag is missing")
        github.api("git/refs", {"ref": "refs/tags/" + tag, "sha": plan["commit"]}, method="POST")
        return
    obj = reference["object"]
    while obj["type"] == "tag":
        obj = github.api("git/tags/" + obj["sha"])["object"]
    if obj["type"] != "commit" or obj["sha"] != plan["commit"]:
        raise ValueError("Refusing to move a release tag that points to another commit")


def publish(github, plan, directory):
    validate_plan(plan)
    release_path = f"releases/{plan['release_id']}"
    release = github.api(release_path)
    expected = {key: plan[key] for key in ("pr", "commit", "version", "build")}
    if metadata(release) != expected:
        raise ValueError("Release reservation changed during the build")
    if not release["draft"]:
        check_assets(release, plan["version"])
        ensure_tag(github, plan, create=False)
        return release["html_url"]
    files = check_files(directory, plan["version"])
    ensure_tag(github, plan, create=True)
    github.upload("v" + plan["version"], files)
    check_assets(github.api(release_path), plan["version"], files)
    published = github.api(release_path, {"draft": False, "prerelease": True,
                                        "make_latest": "false"}, method="PATCH")
    return published["html_url"]


def outputs(values):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for name, value in values.items():
                output.write(f"{name}={str(value).lower() if isinstance(value, bool) else value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("resolve", "reserve", "publish"))
    parser.add_argument("--repository", required=True)
    parser.add_argument("--pr")
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--assets", type=Path)
    args = parser.parse_args()
    github = GitHub(args.repository)
    if args.command == "resolve":
        commit = resolve_pr(github, args.pr)
        outputs({"commit": commit})
        print(commit)
    elif args.command == "reserve":
        commit = resolve_pr(github, args.pr)
        plan = reserve(github, int(args.pr), commit, args.source)
        args.plan.write_text(json.dumps(plan, indent=2) + "\n")
        outputs(plan)
        print(json.dumps(plan, indent=2))
    else:
        url = publish(github, json.loads(args.plan.read_text()), args.assets)
        print(url)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"Published preview: {url}\n")


if __name__ == "__main__":
    main()
