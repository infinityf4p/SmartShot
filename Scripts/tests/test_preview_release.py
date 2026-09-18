import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from preview_release import (asset_names, check_files, metadata, publish, reserve, resolve_pr,
                             validate_plan)
from release_artifacts import checksums, stage


class FakeGitHub:
    repository = "owner/SmartShot"

    def __init__(self):
        self.releases = []
        self.tags = {"v0.2.3": "0" * 40}
        self.uploads = 0
        self.fail_upload = False
        self.fail_after_publish = False
        self.corrupt_upload = False
        self.notes_requests = []
        self.pr = {"merged": True, "base": {"ref": "main", "repo": {"full_name": self.repository}},
                   "merge_commit_sha": "a" * 40}

    def pages(self, path):
        if path == "releases":
            return copy.deepcopy(self.releases)
        if path == "tags":
            return [{"name": tag} for tag in self.tags]
        raise AssertionError(path)

    def api(self, path, data=None, method="GET", missing_ok=False):
        if path.startswith("pulls/"):
            return copy.deepcopy(self.pr)
        if path == "releases/generate-notes":
            self.notes_requests.append(data)
            return {"body": "## Changes\nGenerated notes.\n"}
        if path == "releases" and method == "POST":
            release = dict(data, id=len(self.releases) + 1, assets=[], html_url="https://example.org/release")
            self.releases.append(release)
            return copy.deepcopy(release)
        if path.startswith("releases/"):
            release = next(r for r in self.releases if r["id"] == int(path.split("/")[1]))
            if method == "PATCH":
                release.update(data)
                if self.fail_after_publish:
                    self.fail_after_publish = False
                    raise RuntimeError("Connection lost after publication")
            return copy.deepcopy(release)
        if path.startswith("git/ref/tags/"):
            tag = path.removeprefix("git/ref/tags/")
            if tag not in self.tags:
                assert missing_ok
                return None
            return {"object": {"type": "commit", "sha": self.tags[tag]}}
        if path == "git/refs" and method == "POST":
            tag = data["ref"].removeprefix("refs/tags/")
            assert tag not in self.tags
            self.tags[tag] = data["sha"]
            return {}
        raise AssertionError((path, data, method))

    def upload(self, tag, files):
        self.uploads += 1
        release = next(r for r in self.releases if r["tag_name"] == tag)
        release["assets"] = []
        for name, path in files.items():
            data = path.read_bytes()
            release["assets"].append({"name": name, "size": len(data), "state": "uploaded",
                                      "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
            if self.fail_upload:
                self.fail_upload = False
                raise RuntimeError("Connection lost during upload")
        if self.corrupt_upload:
            release["assets"][0]["digest"] = "sha256:incorrect"


class PreviewReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "project.yml").write_text(
            "settings:\n  base:\n    MARKETING_VERSION: 0.2.3\n    CURRENT_PROJECT_VERSION: 11\n")
        self.github = FakeGitHub()

    def reserve(self, pr=3, commit="a" * 40):
        return reserve(self.github, pr, commit, self.source)

    def packages(self, plan):
        assets = self.root / ("assets-" + plan["version"])
        assets.mkdir(exist_ok=True)
        for name in asset_names(plan["version"])[:-1]:
            (assets / name).write_bytes(name.encode())
        checksums(assets, plan["version"])
        return assets

    def test_allocates_patch_and_build_after_latest_preview(self):
        plan = self.reserve()
        self.assertEqual((plan["version"], plan["build"]), ("0.2.4", 12))
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertNotIn("v0.2.4", self.github.tags)

    def test_compares_numeric_versions_and_ignores_non_release_tags(self):
        self.github.tags.update({"v0.2.10": "b" * 40, "v0.2.9": "c" * 40, "v9.0.0-beta": "d" * 40})
        self.assertEqual(self.reserve()["version"], "0.2.11")

    def test_honors_higher_source_version(self):
        project = self.source / "project.yml"
        project.write_text(project.read_text().replace("0.2.3", "0.3.0"))
        self.assertEqual(self.reserve()["version"], "0.3.0")

    def test_first_release_can_use_source_floor(self):
        self.github.tags.clear()
        self.assertEqual(self.reserve()["version"], "0.2.3")

    def test_draft_reserves_version_for_the_next_merge(self):
        first = self.reserve()
        second = self.reserve(pr=4, commit="b" * 40)
        self.assertEqual((second["version"], second["build"]), ("0.2.5", 13))
        self.assertEqual(self.reserve(), first)
        self.assertEqual(len(self.github.releases), 2)

    def test_rejects_changed_commit_for_reserved_pr(self):
        self.reserve()
        with self.assertRaisesRegex(ValueError, "different merge commit"):
            self.reserve(commit="b" * 40)

    def test_rejects_duplicate_pr_reservations(self):
        self.reserve()
        self.github.releases.append(copy.deepcopy(self.github.releases[0]))
        with self.assertRaisesRegex(ValueError, "Multiple"):
            self.reserve()

    def test_recovers_from_interrupted_upload_without_a_second_release(self):
        plan = self.reserve()
        assets = self.packages(plan)
        self.github.fail_upload = True
        with self.assertRaisesRegex(RuntimeError, "during upload"):
            publish(self.github, plan, assets)
        self.assertTrue(self.github.releases[0]["draft"])
        retry = self.reserve()
        self.assertEqual(retry, plan)
        publish(self.github, retry, assets)
        self.assertFalse(self.github.releases[0]["draft"])
        self.assertEqual(len(self.github.releases), 1)
        self.assertEqual(self.github.tags["v0.2.4"], plan["commit"])

    def test_recovers_when_publish_succeeds_but_response_is_lost(self):
        plan = self.reserve()
        self.github.fail_after_publish = True
        with self.assertRaisesRegex(RuntimeError, "after publication"):
            publish(self.github, plan, self.packages(plan))
        retry = self.reserve()
        self.assertFalse(retry["needs_build"])
        publish(self.github, retry, None)
        self.assertEqual(self.github.uploads, 1)
        self.assertEqual(len(self.github.releases), 1)

    def test_published_retry_does_not_replace_assets(self):
        plan = self.reserve()
        publish(self.github, plan, self.packages(plan))
        publish(self.github, self.reserve(), None)
        self.assertEqual(self.github.uploads, 1)

    def test_refuses_to_overwrite_an_existing_tag(self):
        plan = self.reserve()
        self.github.tags["v0.2.4"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "Refusing to move"):
            publish(self.github, plan, self.packages(plan))
        self.assertEqual(self.github.uploads, 0)

    def test_corrupt_local_package_is_rejected_before_creating_tag(self):
        plan = self.reserve()
        assets = self.packages(plan)
        (assets / asset_names(plan["version"])[0]).write_bytes(b"corrupted")
        with self.assertRaisesRegex(ValueError, "checksums"):
            publish(self.github, plan, assets)
        self.assertNotIn("v0.2.4", self.github.tags)
        self.assertEqual(self.github.uploads, 0)

    def test_unexpected_or_missing_package_is_rejected(self):
        plan = self.reserve()
        assets = self.packages(plan)
        (assets / "unexpected.txt").touch()
        with self.assertRaisesRegex(ValueError, "exactly"):
            check_files(assets, plan["version"])
        (assets / "unexpected.txt").unlink()
        (assets / asset_names(plan["version"])[0]).unlink()
        with self.assertRaisesRegex(ValueError, "exactly"):
            check_files(assets, plan["version"])

    def test_bad_uploaded_digest_keeps_release_private(self):
        plan = self.reserve()
        self.github.corrupt_upload = True
        with self.assertRaisesRegex(ValueError, "Uploaded asset differs"):
            publish(self.github, plan, self.packages(plan))
        self.assertTrue(self.github.releases[0]["draft"])

    def test_rejects_incomplete_published_release(self):
        plan = self.reserve()
        publish(self.github, plan, self.packages(plan))
        self.github.releases[0]["assets"].pop()
        with self.assertRaisesRegex(ValueError, "four expected"):
            self.reserve()

    def test_release_notes_start_at_previous_published_preview(self):
        first = self.reserve()
        publish(self.github, first, self.packages(first))
        self.reserve(pr=4, commit="b" * 40)
        self.assertEqual(self.github.notes_requests[-1]["previous_tag_name"], "v0.2.4")

    def test_rejects_version_metadata_that_disagrees_with_tag(self):
        self.reserve()
        self.github.releases[0]["tag_name"] = "v0.2.9"
        with self.assertRaisesRegex(ValueError, "does not match"):
            metadata(self.github.releases[0])

    def test_rejects_invalid_version_or_build_before_release_creation(self):
        plan = self.reserve()
        for value in ("0.2.3;echo unsafe", "01.2.3", "0.2.65536"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_plan(dict(plan, version=value))
        with self.assertRaises(ValueError):
            validate_plan(dict(plan, build=10000))

    @patch("preview_release.subprocess.run")
    def test_resolves_only_a_merged_pr_on_main_and_checks_ancestry(self, run):
        self.assertEqual(resolve_pr(self.github, "3"), "a" * 40)
        run.assert_called_once_with(["git", "merge-base", "--is-ancestor", "a" * 40, "origin/main"], check=True)
        for field, value in (("merged", False), ("base", {"ref": "other", "repo": {"full_name": self.github.repository}})):
            original = copy.deepcopy(self.github.pr)
            self.github.pr[field] = value
            with self.assertRaisesRegex(ValueError, "already merged"):
                resolve_pr(self.github, "3")
            self.github.pr = original
        with self.assertRaises(ValueError):
            resolve_pr(self.github, "3;false")

    def test_stages_consistent_versions_without_modifying_checkout(self):
        for name in ("Sources", "Resources", "Tests", "BrowserExtension"):
            (self.source / name).mkdir()
        for name in ("manifest.json", "package.json"):
            (self.source / "BrowserExtension" / name).write_text('{"version": "0.2.3", "name": "SmartShot"}')
        destination = self.root / "staged"
        stage(self.source, destination, "0.2.4", 12)
        self.assertIn("MARKETING_VERSION: 0.2.4", (destination / "project.yml").read_text())
        self.assertIn("CURRENT_PROJECT_VERSION: 12", (destination / "project.yml").read_text())
        self.assertIn("MARKETING_VERSION: 0.2.3", (self.source / "project.yml").read_text())
        for name in ("manifest.json", "package.json"):
            self.assertEqual(json.loads((destination / "BrowserExtension" / name).read_text())["version"], "0.2.4")
            self.assertEqual(json.loads((self.source / "BrowserExtension" / name).read_text())["version"], "0.2.3")


if __name__ == "__main__":
    unittest.main()
