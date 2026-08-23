# SmartShot

SmartShot is a local-first macOS screenshot and screen-recording utility for semantic blocks, dragged regions, bounded long captures, editing, OCR, history, and automation. The dependable screenshot fallback is always a visible manual region; smart and scrolling paths fail explicitly when they cannot establish a reliable boundary or seam.

## Status

The app targets macOS 14 or later and has been built on Apple Silicon with Xcode 26.6. Status labels below are intentionally separate:

- **Implemented** means the code and user-facing entry point exist.
- **Automated coverage** means deterministic unit or Node tests cover the named logic; it does not prove permissions, browser installation, or GUI behavior.
- **GUI verified** means a recorded signed-app or privileged runtime check exists for the stated scenario only.
- **GUI pending** means the implementation still needs the manual matrix in [Docs/TEST_PLAN.md](Docs/TEST_PLAN.md).

| Capability | Implementation and evidence | Current boundary |
| --- | --- | --- |
| Smart / Region capture | Implemented; signed installed-app captures were GUI verified on a controlled TextEdit window | Screen Recording is required. AX smart blocks also depend on Accessibility and the target app's AX tree; the broader display/full-screen matrix remains pending. |
| Unified selector, nested cycling, Escape | Implemented; the four-mode overlay and overlay Escape cancellation were GUI verified | One configurable shortcut opens Smart, Region, Long, and App Scroll; a real global keypress from another full-screen Space and mixed-display cases still need the recorded matrix. |
| Manual Long | Implemented; a three-fragment controlled TextEdit workflow was GUI verified | User scrolls a fixed single-display region downward. Limit: 24 fragments, 5 minutes, 20,000 logical points, 16,384 px per axis, 32 million pixels. |
| Automatic App Scroll (Experimental) | Implemented; controlled native success and timeout restoration were GUI verified | Static single-display AX scroll area with a writable vertical scrollbar only. Limit: 24 fragments, 75 seconds, 20,000 logical points, 16,384 px per axis, 32 million pixels. |
| Browser whole-block capture and native preview import | Implemented with Node and native protocol coverage; real Chrome/Safari + X GUI pending | One DOM block, including one X post. Long slices use heuristic two-frame pixel verification; no thread capture, and dynamic, nested-scroll, fixed-rooted, oversized, or wider-than-viewport targets can be rejected. |
| Editor and output | Implemented; renderer has pixel tests; signed GUI checks cover a basic edit subset, Pin, Save As, and Quick Save | Select/move/delete, crop, freehand, arrow, rectangle, ellipse, text, mosaic, blur, opaque redaction, spotlight, magnifier, counters, undo/redo/reset, 100%-400% zoom, PNG/JPEG, copy, pin, Save, and Quick Save. The complete tool/output matrix remains pending. |
| OCR and privacy assistance | Implemented; tiling, geometry, ordering, deduplication, validators, and cancellation have automated coverage; real OCR/UI matrix pending | On-device Vision OCR, text copy, redact all recognized text, or redact detected email/phone/payment-card/Chinese-ID blocks. Accuracy is not guaranteed. |
| Local history and private captures | Implemented; a signed private capture was GUI verified to leave the existing history count unchanged | History is enabled by default. Search covers labels and saved-file basenames; OCR indexing is a separate opt-in and never applies to Private captures. Private mode suppresses automatic history and automatic clipboard copy, but not explicit output. Restart/persistence and the full search/retention matrix remain pending. |
| URL scheme and bundled CLI | Implemented; installed `capture`, `quick-save`, `show`, help, and invalid-input paths were exercised | Capture and Quick Save did not activate SmartShot in the controlled TextEdit run; another app's full-screen Space remains pending. Show activates SmartShot. The CLI is fire-and-forget, embedded in the app bundle, and not installed on `PATH`. |
| Screen recording | Implemented; one live region/video-only MP4, preview, Save As, and GIF export path was GUI verified | H.264/AAC MP4, optional system audio/microphone, pointer control, 15/30/60 fps, 1,920/2,560/3,840 px maximum edge, preview/file actions, and bounded GIF export. Display capture, audio/microphone, sustained duration, and failure matrices remain pending. Single-display sources only. |

## Build And Test

Requirements:

- macOS 14+
- Xcode 26 or a compatible recent Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Node.js for browser-extension tests

```sh
cd SmartShot
xcodegen generate
xcodebuild -project SmartShot.xcodeproj \
  -scheme SmartShot \
  -configuration Debug \
  -derivedDataPath DerivedData \
  test CODE_SIGNING_ALLOWED=NO

cd BrowserExtension
npm test
```

The current-checkout automated run on 2026-08-24 passed **199/199 Swift/XCTest tests** and **67/67 browser Node tests**. These are automated results, not permission, browser-installation, or GUI acceptance.

Open `SmartShot.xcodeproj` in Xcode and build with the configured local signing identity, or intentionally replace it with signing from your own development team. Install the complete bundle as `/Applications/SmartShot.app` before testing the Chromium connector or the bundled CLI; a Derived Data copy does not satisfy the connector installer.

The current local release path is self-signed, not Developer ID signed or notarized. Gatekeeper can quarantine or block a downloaded copy until the user explicitly approves it with Finder **Open** or **Privacy & Security**. Automated tests and a successful local launch do not establish notarized distribution compatibility.

The 2026-08-24 local Release build was installed byte-for-byte at `/Applications/SmartShot.app`, launched successfully, and survived repeated Safari-extension status refreshes. Its main app, native host, CLI, and Safari extension executables are universal `arm64`/`x86_64`, and strict deep signature verification passed. This is narrow installed-artifact evidence, not clean-machine or browser-capture acceptance.

## Use The Native App

1. Launch SmartShot and allow Screen Recording when you are ready to capture.
2. Optionally allow Accessibility for smart block discovery in other apps.
3. Press the shortcut shown beside **Global Shortcut** (initially `Control-Shift-2`) or choose **Capture**. Change it in **SmartShot > Settings** by clicking the shortcut field and pressing a key with at least two modifiers.
4. Choose **Smart**, **Region**, **Long**, or **App Scroll** in the overlay. Smart highlights AX/window blocks and also accepts a drag; Region accepts a dragged rectangle; App Scroll requires a compatible Accessibility scroll area.
5. Click or press Return to capture a Smart block, or drag to capture Region/Long. Press Escape to cancel.
6. In Long mode, scroll the selected content downward in small steps and pause after each step. Click **Done** after at least two sections have been accepted.
7. Edit with crop, drawing, shapes, text, mosaic, blur, opaque redaction, spotlight, magnifier, or counters. The OCR button can copy recognized text or add redactions. Copy, Pin, Save, and Quick Save render the current edits; **Flatten** replaces the current source and its history item with the rendered result.
8. Choose **More > Record Region** or **Record Current Display** to record. Stop saves an MP4 to the Quick Save folder; Cancel discards it. The result view can preview, reveal, copy, Save As, or export a bounded GIF.
9. Settings controls delay, automatic copy, preview behavior for externally started captures, history retention/search indexing/clear, private captures, PNG/JPEG output, filename style, Quick Save folder, recording audio/pointer/frame-size options, shortcut, Chromium integration, and Safari extension status/settings.

If Accessibility is denied, window and manual-region capture remain available. If Screen Recording is denied, SmartShot can show settings and permission recovery but cannot create screenshots or recordings.

## Long Capture Contracts

The unified **Long** mode is the no-extension fallback for browsers and apps. It repeatedly samples one fixed rectangle while you scroll downward, accepts only stable frames with verified overlap, handles a conservative fixed top strip, and can finish after a later scroll attempt reveals no new pixels. It does not know a hidden semantic boundary or restore the position you changed manually.

For the separate automatic native path, choose **Automatic App Scroll (Experimental)**, then select an Accessibility scroll area. It works only when the whole capture area is on one display, the content remains static, and the target exposes a writable vertical AX scrollbar. It stops after 24 fragments or 75 seconds and rejects output above 16,384 pixels on either side or 32 million pixels total. SmartShot attempts to restore the original scroll position after success, failure, or cancellation and reports a restoration failure explicitly.

The privileged native path was verified on 2026-08-15 with a controlled static `NSScrollView`: the app produced a 2,688 x 8,724 pixel PNG containing fixture rows 001 through 240 and restored the exact original AX scrollbar value. A forced timeout also restored it. This narrow evidence does not broaden the supported-content limits.

The browser extension is the semantic whole-block path for webpages. It selects one DOM element, uses one visible capture when possible, otherwise scrolls and stitches bounded slices, then restores page scroll and temporary styles. Every long-capture slice is sampled twice 120 ms apart and compared at a maximum 96-pixel edge to reject common dynamic media changes. This heuristic does not prove that all motion is frozen; the visible fast path remains single-frame. The browser path is limited to 24 slices, 20 seconds, 20,000 CSS pixels, 16,384 px per output axis, and 32 million output pixels.

## Screen Recording

Screen recording has two user-facing sources: a dragged region and the display under the pointer. Both are restricted to one display and exclude SmartShot's own application from the ScreenCaptureKit filter. Settings select system audio, optional microphone, pointer visibility, 15/30/60 fps, and a maximum output edge of 1,920/2,560/3,840 pixels. The defaults are system audio on, microphone off, pointer on, 30 fps, and 3,840 pixels.

After Stop, SmartShot finalizes H.264 video and any audio as AAC, then atomically moves the MP4 into the configured Quick Save folder and opens an in-app preview. The preview can reveal or copy the file, Save As, or export an animated GIF. GIF export is capped at the first 30 seconds, 15 fps, a 1,280-pixel long edge, and 450 frames. Cancel and failed export paths remove incomplete temporary files.

The state machine, source/size planning, routing, H.264/AAC writer, cleanup, and offline MP4/GIF export have focused tests. A real signed run covering ScreenCaptureKit pixels, system audio, microphone permission, A/V sync, sustained recording, and sleep/display changes is still required before claiming broad runtime compatibility.

## Automation

SmartShot registers these public local URLs:

```text
smartshot://capture?mode=smart
smartshot://capture?mode=region
smartshot://capture?mode=long
smartshot://capture?mode=app-scroll
smartshot://quick-save
smartshot://show
```

The complete app embeds a matching command-line launcher:

```sh
/Applications/SmartShot.app/Contents/Helpers/smartshot capture --mode smart
/Applications/SmartShot.app/Contents/Helpers/smartshot capture --mode region
/Applications/SmartShot.app/Contents/Helpers/smartshot capture --mode long
/Applications/SmartShot.app/Contents/Helpers/smartshot capture --mode app-scroll
/Applications/SmartShot.app/Contents/Helpers/smartshot quick-save
/Applications/SmartShot.app/Contents/Helpers/smartshot show
```

Running `smartshot` without arguments starts Smart capture. The launcher only asks LaunchServices to open a URL; it does not wait for capture completion or return an output path. Capture and Quick Save URLs request non-activating LaunchServices delivery; the controlled TextEdit run did not activate SmartShot, but delivery while another app owns a full-screen Space remains pending. Show intentionally activates SmartShot. `quick-save` requires a latest capture. `smartshot://import` is reserved for the validated browser bridge and is not a public automation command.

## Browser Extension

The Manifest V3 extension in [BrowserExtension](BrowserExtension/README.md) identifies generic semantic blocks and one X post at a time. It produces the completed PNG in the browser, then uses a two-phase import: the Chromium or Safari bridge first validates and stages the complete image, then opens SmartShot and waits for the app to validate it and publish the preview before returning final acceptance. SmartShot permits one outstanding browser import. Missing hosts, malformed acknowledgements, rejection, interruption, timeout, and overlap use a background-owned browser download; the content page is only a second fallback when the downloads API fails. The extension requests `downloads` for this write-only fallback and does not read download history. Toolbar injection failures expose a fixed `!` badge/title without including page data.

The browser Node suite and native import-store/installer tests cover selection fixtures, limits, restoration guards, chunk order, strict acknowledgements, malformed input, and download fallback. Real signed Chrome/Safari installation, website permission, current X behavior, page zoom, and final preview import remain GUI acceptance work. A **Connected** Chromium status proves only that host manifests are current for detected browsers.

Before the 2026-08-24 installed-app check, 32 stale temporary SmartShot Safari registrations were removed, leaving exactly the embedded extension in `/Applications/SmartShot.app`. SmartShot then reported **installed but disabled** instead of an extension-manager error. This proves host-registration cleanup and stable status reporting only; it does not prove Website Access, capture, native preview import, or fallback.

The embedded Safari extension in the current local self-signed build is a development artifact. Safari ignores it until the user enables **Safari > Settings > Developer > Allow unsigned extensions**, and Safari resets that setting whenever it quits. After that explicit development override, enable **SmartShot Web Selector** in Safari Extensions and grant Website Access. A properly Apple-signed distribution build should not require the unsigned-extension override.

Chromium's Developer mode and **Load unpacked** controls are protected, user-controlled browser UI. SmartShot can install the native-host manifest and reveal the packaged files, but it does not claim to complete extension installation automatically.

The extension does not send post text, author labels, page titles, DOM selectors, cookies, credentials, HTML, or URL paths to native messaging. Native import retains only the HTTP(S) origin needed for safe technical metadata.

Safari crosses the extension/app sandbox boundary with request-scoped named pasteboards containing the PNG, bounded metadata, and final acknowledgement. Normal success, rejection, and timeout paths clean them up, but named pasteboards do not cryptographically authenticate the writer against another process running as the same macOS user, and an extension crash after publication can leave request-scoped residue beyond normal cleanup. Those are documented P2 boundaries of the current local self-signed release, not claims of a hardened multi-user IPC channel.

## Privacy

- Screenshot processing, screen recording, Vision OCR, browser stitching, and sensitive-pattern detection are local; the project contains no analytics, upload endpoint, account, cloud synchronization, or runtime capture network client.
- Local history is enabled by default and stores PNG, thumbnail, and metadata files under `~/Library/Application Support/SmartShot/History`; the UI can search, open, delete, or clear items, and Settings can disable new history or choose a 10/25/50/100/250-item limit.
- History search covers labels and saved-file basenames. Persisting OCR text in the local search index is off by default, begins only after an OCR run, and is always disabled for Private captures.
- Private capture mode prevents new automatic history entries and automatic clipboard copies. The latest preview remains in memory; explicit Copy, Pin, Save, and Quick Save still work, and the setting does not control a browser fallback download.
- Browser native import sends the PNG plus bounded technical metadata: safe filename/kind, logical dimensions, and HTTP(S) origin only. It does not send post text, author labels, page titles, DOM selectors, HTML, credentials, URL path/query/fragment, cookies, or browsing history.
- OCR redaction is heuristic. Use opaque redaction and inspect the rendered output before sharing; blur and mosaic are visual effects, not guaranteed irreversible sanitization.
- Microphone capture is off by default and requires separate macOS permission. Completed recordings are ordinary local files in the Quick Save folder and are not part of screenshot history or Private capture policy.

## Known Limits

- Manual long capture is bounded and seam-verified, not a general-purpose or automatic whole-document guarantee.
- Manual long capture requires downward scrolling with short pauses. A stable fixed top strip is handled conservatively, but changing sticky content, dynamic media, repeated/low-texture rows, large jumps, window movement, and direction changes can still be rejected.
- Native scrolling capture supports only static, single-display AX scroll areas with a writable vertical scrollbar. Dynamic or infinite content, virtualized lists, nested scrolling areas, and cross-display composition are not promised.
- Browser DOM whole-block capture is implemented, but real Chrome/Safari + X end-to-end verification remains outstanding. Two-frame long-slice checks are heuristic, and the visible fast path is single-frame. It does not automatically capture X threads or multiple posts.
- OCR accuracy, sensitive-pattern matching, and redaction rectangles must be reviewed by the user. Translation, object removal, cloud share, accounts, and synchronization are absent.
- Screen recording is single-display. One region/video-only path is GUI verified, but display capture, system audio, microphone, sustained operation, and failure recovery remain pending. Camera capture, trimming, click visualization, presets, and general editing of recorded video are absent; GIF export is deliberately bounded.
- Canvas, games, remote desktops, and inaccessible apps may require manual selection.
- Manual selections are limited to the display where the drag begins; cross-display image composition is not included.
- Browser crop scale, imported logical dimensions, and non-100% browser zoom still require end-to-end verification.

## Documentation

- [MVP scope](Docs/MVP_REQUIREMENTS.md)
- [Architecture](Docs/ARCHITECTURE.md)
- [Test plan](Docs/TEST_PLAN.md)
- [Roadmap](Docs/ROADMAP.md)
