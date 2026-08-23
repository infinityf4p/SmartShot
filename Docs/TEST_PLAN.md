# SmartShot Test Plan and Evidence

## Evidence Rules

- **Automated pass** means the named command completed successfully for the current checkout.
- **Implemented, GUI pending** means production code and its entry point exist, but permissions, installation, interaction, or pixels have not been observed end to end.
- **GUI verified** applies only to the exact recorded build, hardware, permission state, and scenario.
- **Unsupported** behavior must fail explicitly; a plausible partial image is not a pass.

Never promote a build result, a unit test, a permission checkbox, or a native-host manifest into a runtime compatibility claim.

## Repeatable Automated Gates

Run from the repository root:

```sh
xcodegen generate
xcodebuild -project SmartShot.xcodeproj \
  -scheme SmartShot \
  -configuration Debug \
  -derivedDataPath DerivedData \
  test CODE_SIGNING_ALLOWED=NO

cd BrowserExtension
npm test
for file in background.js content.js shared/*.js tests/*.js; do
  node --check "$file"
done
node -e 'JSON.parse(require("fs").readFileSync("manifest.json", "utf8"))'
```

Also run `git diff --check` and validate local Markdown links before handoff. Code signing is intentionally disabled for deterministic unit tests; this does not test TCC, LaunchServices, Safari, Chromium, or the GUI.

## Current Checkout Automated Record

Recorded on 2026-08-24 for the checkout described by these documents:

- `xcodebuild ... test CODE_SIGNING_ALLOWED=NO`: **199/199 passed**.
- `BrowserExtension/npm test`: **67/67 passed**.
- Browser JavaScript syntax checks, manifest JSON parsing, Markdown relative-link validation, and `git diff --check` passed.

These results prove current automated gates only, not signed GUI behavior.

## Checked-In Automated Coverage

### Native Screenshot and Selection

The Swift suites cover:

- AppKit/AX screen-coordinate adaptation, including nontrivial display layouts.
- Accessibility roles, hierarchy traversal, filtering, and candidate behavior.
- Window/manual candidate clipping, minimum size, deduplication, and ordering.
- Smart/Region/Long/App Scroll mode ordering, keyboard commands, Escape, confirmation, and scroll-selection commit policy.
- Carbon shortcut parsing, persistence, real registration replacement, conflict rollback, and recording-mode event routing.
- Overlay occlusion/exclusion policy and manual-scroll gesture/bottom-attempt policy.

These tests do not prove frontmost-app delivery, full-screen Space behavior, real AX trees, multi-display pixels, or permission recovery.

### Long Capture Algorithms

The Swift suites cover vertical overlap estimation, unreliable and changing pixels, fixed-top detection, fragment layout/stitching, cancellation, size bounds, and failure mapping. Automatic-scroll unit paths cover target contracts and restoration-related control logic where deterministic fixtures are available.

These tests do not prove that a third-party app exposes a stable writable scrollbar or that ScreenCaptureKit returns seam-compatible frames.

### Editor, OCR, Output, History, and Privacy Policy

The Swift suites cover:

- Crop mapping; edit history; selection/movement/deletion; freehand, arrow, rectangle, ellipse, text, counter, mosaic, blur, opaque redaction, spotlight, and magnifier rendering.
- Privacy ordering so magnification cannot recover pixels hidden by opaque redaction.
- Vision tile planning, coordinate conversion, reading order, overlap deduplication, limits, cancellation, and supported sensitive-value validators.
- PNG/JPEG encoding, filename sanitization/styles, collision handling, and output failures.
- History save/load/delete/delete-all, thumbnails, retention, replacement, search, legacy JSON, and corrupted/missing artifact handling.
- Search across labels, optional saved-file basenames, and explicitly enabled OCR text.
- Default/private OCR-index suppression and removal of an older OCR index when an item is replaced without one.
- Private post-processing policy: no automatic history and no automatic clipboard copy.

Vision tests validate support logic, not real-world OCR accuracy or completeness. History tests use isolated directories, not the user's live store.

### Browser Import and Automation

The Swift suites cover:

- Strict native `begin -> chunk -> end` phase-one handling, request IDs, ACK stages/indexes, PNG/metadata/geometry validation, cleanup, and consumption.
- Phase-two app validation/final acceptance, duplicate URL handling, the one-outstanding import queue, cancellation, termination, timeout, and Safari named-pasteboard guards/cleanup.
- Chromium host-manifest planning and installation validation for supported browser directories.
- Public URL parsing/round trips, CLI argument parsing, and activation policy for Smart, Region, Long, Automatic App Scroll, Quick Save, and Show.

They do not prove that the installed app owns the URL scheme, that browsers can launch the embedded helper, or that a capture reaches the preview.

### BrowserExtension Node Suite

The dependency-free Node suite covers:

- X timeline/detail posts with media, nested quotes, reply/repost context, and outer-article selection.
- Generic semantic/layout ancestors and nested candidate cycling.
- Viewport/page geometry, visible and long-path classification, observed capture scale, crops, destination ranges, and hard output limits.
- Fail-closed nested-scroll and fixed/sticky-root behavior.
- Navigation, tab/document, mutation, resize, manual-scroll, timeout, and dynamic-content guards, including long-slice verification-frame dimensions, bounded noise, localized motion, and broad low-amplitude changes.
- Restoration of page scroll and temporary page/style changes after success and failure.
- Strict native-import order, chunking, UUID and ACK validation, rejection/timeout/interruption behavior, background downloads that outlive content-page teardown, content fallback without duplicates, and fixed toolbar diagnostics.
- URL minimization, safe filenames/kinds/origins, and absence of page content at the native boundary.

Fixtures intentionally keep one X post in scope. They are not a current-X browser compatibility result and do not implement thread capture.

### Recording Components

Recording tests cover AppKit-to-display-local region mapping, source planning/resolution, state transitions, session-isolated sample routing, H.264/AAC writer setup, output cleanup/export validation, and bounded GIF planning/encoding. A synthetic offline media integration creates H.264 source video, exports validated H.264/AAC MP4, and creates GIF output without exercising a live screen or microphone. A passing component suite does not establish microphone permission handling, sustained capture, A/V sync, or final live pixels/audio.

## Recorded Narrow GUI Evidence

The following observations may be cited only with their stated scope:

- On 2026-08-15, a controlled static native `NSScrollView` Automatic App Scroll run produced a 2,688 x 8,724 PNG containing fixture rows 001 through 240 and restored the exact original AX scrollbar value. A forced-timeout run restored the same value.
- On 2026-08-19, a signed Debug editor fixture exercised tool switching, text/counter placement, undo/redo, 150% zoom, and Pin. This did not cover every current tool, OCR, history, private mode, or output format.
- A prior launch showed successful Carbon registration and the configured shortcut, but did not prove a keypress delivered while another full-screen app was frontmost.
- On 2026-08-23, the installed self-signed Release app captured controlled TextEdit content through Smart and Region modes, completed a three-fragment Manual Long capture, and canceled the unified four-mode overlay with Escape. The automation host could not inject a real global keypress, so another application's full-screen shortcut delivery remains pending.
- On 2026-08-23, Pin created an always-on-top layer-3 panel; Quick Save wrote a 1,992 x 1,285 PNG; and a Private Region capture left the existing six-item history unchanged. Arrow/Undo/Redo and a controlled OCR recognition path also ran, but the complete editor/OCR/history matrix remains pending.
- On 2026-08-23, the installed CLI exercised help, invalid input, activating Show, non-activating Smart/App Scroll delivery to TextEdit, and Quick Save writing an 880 x 520 PNG.
- On 2026-08-23, a live region recording with system audio, microphone, and pointer disabled produced a 22.18-second 994 x 622 H.264 MP4. Preview remained in the same SmartShot process, Save As succeeded, and GIF export produced a 994 x 622 333-frame GIF.
- On 2026-08-24, a fresh universal self-signed Release build passed strict deep signature verification, matched the staged app byte-for-byte after installation at `/Applications/SmartShot.app`, launched successfully, and remained alive through repeated Safari-extension status refreshes. This does not prove extension enablement or capture.
- On 2026-08-24, 32 stale temporary Safari-extension registrations were removed, leaving exactly the installed app's embedded extension registered. SmartShot then reported **installed but disabled** instead of the prior extension-manager error. This is environment/status evidence only.

No real signed Chrome/Safari + current X native-import result is recorded in this document. The installed-app startup, status, and registration-cleanup observations above do not change this.

No live current-display, system-audio, or microphone recording is recorded in this document. The live evidence above is limited to one video-only region path; the offline media export test remains automated evidence.

## Native GUI Acceptance Matrix

Record app build/commit, macOS build, hardware, display arrangement/scaling, permission state, and non-sensitive output dimensions for every case.

### Permissions, Shortcut, and Overlay

- Test Screen Recording as not determined, denied, granted after denial, revoked while running, and granted after relaunch when required.
- Test Accessibility as denied, newly granted, and revoked. Window/manual selection must remain usable without it.
- Press the configured shortcut while Finder, Chrome/Safari, a native app, and another app's full-screen Space are frontmost.
- Change the shortcut, restart, verify persistence, force a conflict, and confirm the previous working shortcut remains active.
- Invoke/cancel repeatedly with Escape; confirm no orphan panel, darkened screen, trapped pointer, captured overlay, or lost keyboard focus.
- Test Mission Control, Space changes, lock/unlock, countdown cancellation, and termination during selection.

### Displays and Pixel Geometry

| ID | Configuration | Required observation |
| --- | --- | --- |
| D1 | Built-in Retina | Highlight and output edges agree at center and all four edges. |
| D2 | External 1x | No hard-coded 2x scale assumption. |
| D3 | Mixed 1x/2x | Correct logical and pixel size on each display. |
| D4 | External left of main | Negative X origin works. |
| D5 | External above/below main | Nontrivial Y origin works. |
| D6 | Selection crosses displays | Capture fails explicitly; no display is chosen by center point and no truncated image is returned. |
| D7 | Display removed during selection | Safe cancellation or clear failure. |

Use high-contrast fixtures and inspect output at 100% pixel zoom. Content clipping, systematic offset, or the SmartShot UI inside the image is a failure.

### Native Selection and Standard Capture

- On controlled native and browser windows, cycle child/parent AX candidates and verify the label/outline matches the clicked output.
- Test an incomplete AX tree and Accessibility denial; window and manual fallback must still work.
- Exercise Smart click, Smart drag, Region drag, Return, candidate cycling, and Escape.
- Verify Off/3/5-second delay, automatic copy, optional preview activation, Copy, Pin, Save, Quick Save, and cancellation/error recovery.
- Confirm pinned panels work across Spaces and are excluded from subsequent captures.

### Manual Long

- Select a fixed region over a static numbered list; scroll downward by less than one viewport and pause between steps.
- Verify each numbered row appears exactly once and seam error is no more than one pixel.
- Confirm the target pointer and scrolling remain usable, and the HUD never appears in a fragment.
- Confirm Done stays unavailable before two accepted sections; Cancel produces no image.
- Verify identical frames do not advance, while a later bottom scroll attempt can finish after accepted movement.
- Verify one stable fixed top strip appears once.
- Force upward scrolling, large jumps, changing sticky pixels, dynamic media, target/window movement, width/scale change, timeout, and all hard limits. Each must fail clearly without a partial PNG.
- Record that manual scrolling changes the target position and is not restored.

### Automatic App Scroll (Experimental)

- Use a controlled static single-display `AXScrollArea` with a writable vertical scrollbar.
- Start from the middle, capture top-to-bottom, verify every row once, and compare the restored scrollbar value.
- Separately test success, explicit cancel, timeout, termination, no progress, changed geometry/pixels, frontmost-app change, and unreliable overlap.
- Force restoration failure and confirm it is reported rather than hidden by another error.
- Verify 24-fragment, 75-second, 20,000-logical-point, 16,384-pixel-axis, and 32-million-pixel bounds.
- Reject missing/read-only/horizontal-only scrollbars and any capture area not fully on one display.

Dynamic/infinite feeds, virtualized lists, nested scroll areas, horizontal content, and cross-display areas remain unsupported investigations.

## Editor, OCR, History, Output, and Private GUI Matrix

### Editor and OCR

- Exercise every current tool, including Select move/delete, crop, all vector/raster effects, undo/redo/reset, color, line width, and 100%-400% zoom.
- Compare preview and final Copy/Pin/Save/Quick Save pixels, including Retina and long captures.
- Place redaction before magnifier and confirm magnification cannot reveal original pixels.
- Run OCR on controlled English, Chinese, mixed-language, long/tiled, low-contrast, rotated, no-text, and over-limit images.
- Verify reading order, Copy Text, Redact Sensitive, and Redact All placement.
- Include false-positive and false-negative fixtures for email, phone, card, and Chinese ID; never describe detection as guaranteed.

### Output and History

- Save and Quick Save both PNG and JPEG with both naming styles; test collision suffixes, changed folder, unwritable folder, cancelled panel, and atomic failure.
- Restart the app and verify history order, thumbnails, open, delete, clear confirmation, retention changes, and corrupted-entry recovery.
- Flatten an edited current capture and confirm the same history item is replaced with rendered pixels.
- Search by label and saved-file basename. With OCR indexing off, OCR text must not match; with explicit opt-in and OCR run, it may match; turning the search option off must exclude it.
- Confirm old history JSON without new search fields remains loadable.

### Private Capture

- Clear the pasteboard and note history count, enable Private, capture, and confirm neither automatic clipboard content nor a new history artifact appears.
- Confirm the latest preview remains available and explicit Copy, Pin, Save, and Quick Save still work.
- Run OCR while Private and confirm OCR text is not persisted even if indexing is enabled.
- Force browser native-import failure separately and confirm Private does not suppress the browser's own download fallback.

## URL Scheme and CLI Acceptance

Install a signed complete bundle at `/Applications/SmartShot.app`, verify its Info.plist URL registration, then exercise:

```text
smartshot://capture?mode=smart
smartshot://capture?mode=region
smartshot://capture?mode=long
smartshot://capture?mode=app-scroll
smartshot://quick-save
smartshot://show
```

Run the embedded `/Applications/SmartShot.app/Contents/Helpers/smartshot` with no arguments, each command/mode, `--help`, invalid modes, and extra arguments. Verify that fire-and-forget behavior is documented, Quick Save with no latest capture does not invent output, active-session command handling is predictable, and URL commands work when another Space is frontmost. Do not claim the CLI is on `PATH` unless a separate installer is added.

## Browser Extension Acceptance

### Installed Artifact

- Install the complete signed app at exactly `/Applications/SmartShot.app`.
- Confirm executable `Contents/Helpers/SmartShotNativeHost`, embedded Safari extension, stable manifest key, expected Chromium extension ID `fihllldonobikbajacoflinfomigonhd`, and exactly one current installed Safari-extension registration. Record stale-registration cleanup separately from product acceptance.
- Record that the current artifact is self-signed and not notarized. On a newly downloaded/quarantined copy, verify the exact Gatekeeper prompt and explicit Finder **Open** or **Privacy & Security** approval path; do not disable Gatekeeper or call this Developer ID distribution.
- In Chrome, Chromium, Edge, and Brave as available, install the host from Settings and use the browser's protected, user-controlled Developer mode / **Load unpacked** UI to load the revealed extension. Record the `downloads` permission warning and confirm SmartShot does not inspect download history.
- Treat **Connected** only as manifest validation. Separately verify the extension is loaded, enabled, has site access, and completes native import.
- In Safari, use SmartShot's status and settings entry to enable the embedded extension, grant/revoke Website Access, refresh status, and verify action/API failure diagnostics. For the current self-signed development artifact, first enable **Safari > Settings > Developer > Allow unsigned extensions**, record the authentication prompt, and verify that Safari resets the override after it quits. Do not include that override in the supported distribution contract.

### Controlled Browser Fixtures

- Capture a fully visible generic block and confirm exact bounds and one-frame delivery.
- Capture partially offscreen and taller-than-viewport blocks; verify every row exactly once and restored page position/style.
- Run browser page zoom and OS display scaling combinations; use captured bitmap dimensions, not a DPR assumption.
- Verify native preview receives the completed PNG and correct logical aspect.
- Confirm the bridge does not return accepted end ACK until SmartShot has validated and published the preview.
- Start a second import while the first is awaiting app acceptance; it must be rejected to browser download without replacing the first preview.
- Force missing host, rejected begin/chunk/end, wrong request ID/stage/chunk index, malformed ACK, timeout, interruption, app-open failure, and source-tab closure while native import is pending. Each must download the already completed PNG exactly once when the background downloads API is available. Separately force that API to fail and record whether the still-live content page can complete its second fallback.
- Confirm rejected partial native imports are cleaned and no corrupt preview/history item appears.
- Inspect messages to ensure native receives only PNG, safe filename/kind, logical dimensions, and HTTP(S) origin.

### X Compatibility Gate

- Test public, non-sensitive X timeline and detail pages with text-only, media, nested quoted post, reply, and repost context.
- Confirm descendants of a quote/media select the one outer `article[data-testid="tweet"]`, while sibling replies remain separate.
- Run visible and tall-post paths, logged-out state, light/dark mode, page zoom, window movement, and full screen.
- Verify navigation, mutation, dynamic media, active-tab change, resize, manual scroll, nested scroll, fixed/sticky root, timeout, and hard limits fail without a partial image and restore the page when restoration is possible. Include slowly changing and tiny animations to record possible heuristic misses, plus static pages in both browsers to detect compositor-noise false rejections.

Passing this gate supports one post only. It does not support automatic threads, multiple posts, dynamic/infinite feeds, or virtualized timelines.

## Privacy and Security Checks

- Search source and runtime logs for screenshot bytes, full AX text, OCR text, post text, author, full URLs, credentials, cookies, selectors, and HTML.
- Inspect browser/native envelopes for strict schema/version/request identity, stage/index order, bounded strings, bounded chunks, PNG signature, decoded size, logical dimensions, and sanitized origin.
- For Safari, inspect both request-scoped named pasteboards after success, rejection, app timeout, and forced extension termination. Record any crash residue and verify a later request is not confused by it.
- Treat another process running as the same user as inside the named-pasteboard threat boundary: verify malformed/replaced data fails closed, and do not claim cryptographic source authentication.
- Verify no analytics, upload, account, cloud-sync, `fetch`, or `XMLHttpRequest` path is required for capture.
- Inspect `~/Library/Application Support/SmartShot/History`, browser import staging, Quick Save, and temporary recording locations after success, failure, cancellation, cleanup, and app termination.
- Verify history-on, history-off, Private, and explicit-output storage behavior separately.
- Treat opaque redaction as the privacy output; do not claim blur or mosaic is irreversible.

## Recording Promotion Gate

The region/current-display workflow, settings, HUD, MP4 preview/file actions, and GIF export are implemented. Before recording is described as runtime-verified or broadly compatible, the integrated workflow must pass:

- Region and display source selection with precise output bounds.
- Screen Recording denial/recovery and microphone denial/recovery when microphone capture is enabled.
- H.264 MP4 video, system audio on/off, microphone on/off, cursor on/off, A/V duration/sync, and expected dimensions/frame rate.
- Non-activating HUD Stop/Cancel, repeated starts, termination, runtime stream failure, sleep/display change, and low-disk behavior.
- Exclusion of SmartShot controls and current-process audio where promised.
- Cleanup of raw/intermediate files after success, cancel, failure, and export.
- GIF export bounds, duration/frame pacing, output dimensions, and cancellation through the current UI.

Component tests alone do not pass this gate.

## Release Claim Gates

- Do not call the native screenshot workflow broadly GUI verified until the permission, frontmost-app, full-screen, and available display cases are recorded.
- Keep **Experimental** in the name of Automatic App Scroll and do not generalize its controlled fixture to arbitrary apps.
- Do not claim Chrome/Safari + X support until installed native preview and forced fallback both pass against current public X.
- Describe OCR and sensitive detection as local assistance, not guaranteed discovery.
- Describe Private mode narrowly: it suppresses automatic history and automatic copy, not explicit output or browser fallback download.
- Do not claim general-purpose long screenshots, X threads, cross-display composition, object removal, translation, cloud sharing, accounts, or synchronization.
- Describe recording as **implemented with focused automated coverage and one narrow live region/video-only check** until the promotion gate above passes.
- Describe the current downloadable app as self-signed and not notarized; Gatekeeper override behavior is a release boundary, not a passed distribution gate.
- Keep Safari named-pasteboard same-user source authentication and extension-crash residue documented as P2 until an authenticated transport and cleanup strategy replace it.

## Test Record Template

```text
Date and time:
Build/commit:
Test type: automated / runtime manual
macOS and hardware:
Displays and scaling:
Browser/version/page zoom (if applicable):
Permissions and privacy settings at start:
Scenario:
Expected:
Observed:
Output path/type/dimensions/duration:
Restoration and cleanup result:
Non-sensitive evidence:
Pass / Fail / Not run:
```
