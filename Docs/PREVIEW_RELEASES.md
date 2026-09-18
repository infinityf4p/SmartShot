# Automatic preview releases

Every PR merged into `main` triggers **Publish Preview**. Closing an unmerged PR or pushing directly to `main` does not publish a release. **Validate Preview Build** runs the tests and packaging on PRs with read-only permissions, without creating tags or releases.

The release workflow uses `pull_request_target: closed` so merged contributions from forks can also publish. It runs only after merge, checks the PR's repository, base branch and merge commit against `main`, and builds that exact commit in a separate worktree. It never builds an unmerged PR head with a write token. Manual runs are accepted only from `main`.

## Pipeline

1. Run release-script tests, browser extension tests, and native Swift tests on `macos-26` with Xcode 26.6, Node 24 and XcodeGen 2.46.0.
2. Reserve a version in a draft release. Starting after `v0.2.3`, the next version is `v0.2.4`; subsequent releases increase the patch number. Existing tags and draft releases are included when allocating versions. A higher `MARKETING_VERSION` in `project.yml` starts a new version line. Build numbers increase from the source value or the highest automated release's build number.
3. Copy sources to a temporary directory and set the same version in `project.yml`, the browser manifest and its package metadata. Generate the Xcode project, then build the app, Safari extension and both command-line helpers for `arm64` and `x86_64`.
4. Verify the architecture of all four executables, nested signatures, app/extension versions, hardened runtime, required entitlements, and the absence of `get-task-allow`. Create and verify the DMG, app ZIP, browser extension ZIP and `SHA256SUMS.txt`.
5. Create the version tag at the PR's merge commit, upload all four assets to the draft, check their sizes and available server digests, then publish it as a prerelease. Notes are generated from the previous published preview.

The workflow uses the repository's `GITHUB_TOKEN` with `contents: write` and `pull-requests: read`; no personal access token or signing certificate is required. GitHub Actions must be enabled and repository/organization policies must permit these permissions and release tag creation. No source version commit is pushed to `main`: the release tag and its hidden metadata record the source commit, final version and build number. Versions in the checkout remain defaults for local development.

Releases remain ad-hoc signed previews, without Developer ID signing or notarization. They do not use the Safari development build script or its debugging entitlements. Publishing a release does not install it on any developer's Mac.

## Queue and recovery

The shared concurrency group uses [GitHub's `queue: max`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency), which allows up to 100 pending runs without replacing earlier pending merges. Each run allocates its version while holding that group. Versions follow reservation order; GitHub does not guarantee merge-event ordering.

- A test failure creates no draft or tag. A build failure leaves a draft reservation, and an interrupted upload keeps the release private. Fix the failure, then rerun the workflow.
- A rerun finds the reservation by PR number, keeps its version/build and replaces incomplete draft assets. A complete published release is left intact. A tag pointing to another commit stops the run instead of being moved.
- In **Actions → Publish Preview → Run workflow**, select `main` and enter the merged PR number to retry a missed run. This also bootstraps the PR that first introduces the workflow if its merge event does not start a run. Manual runs use the current workflow and release scripts but build the specified PR's exact merged source.
- Use **Re-run all jobs** for a transient failure. To use a repaired release script after a later PR, use the manual entry point. Do not remove the `smartshot-release` metadata comment from a draft or published release; it is the retry record. Do not manually publish incomplete drafts or move release tags.

Download previews from the [Releases page](https://github.com/infinityf4p/SmartShot/releases). GitHub's `/releases/latest` endpoint excludes prereleases.

## Local validation

With full Xcode, Node.js, Python 3.9+ and XcodeGen 2.46.0 installed:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -v
npm --prefix BrowserExtension test
xcodegen generate
xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SmartShotTests test \
  CODE_SIGNING_ALLOWED=NO REGISTER_WITH_LAUNCH_SERVICES=NO
bash Scripts/build_preview.sh 0.2.4 12 /tmp/SmartShotPreviewPackages
```

The packaging output directory must be empty. Packaging uses disposable sources and DerivedData, cleans them on exit, and leaves only the four distributable files. Remove the test DerivedData and output directory after validation. No app is launched or installed. The Python tests use a simulated GitHub API to exercise version allocation, retry recovery, checksum failures and tag conflicts without publishing anything.
