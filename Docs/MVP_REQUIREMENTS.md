# SmartShot MVP Requirements

## Purpose

SmartShot provides dependable local macOS screenshot and screen-recording workflows. Screenshots use semantic selection where the platform exposes structure and a manual region fallback everywhere else; bounded long capture, editing/OCR/history, and local automation do not imply universal page understanding or cloud services.

This scope reflects code present on 2026-08-24. **Implemented**, **automated-tested**, and **GUI-verified** are separate claims.

## Supported Platform

- macOS 14 or later.
- Apple Silicon is the currently exercised development platform.
- Native screenshots and screen recordings use ScreenCaptureKit.
- Smart native blocks use Accessibility when available.
- Browser semantic blocks use the Manifest V3 extension.
- OCR uses on-device Vision.

## Capture Entry Points

### Unified Capture

One configurable global shortcut and the app/menu-bar Capture commands open a unified overlay:

- **Smart**: AX candidates, window fallback, nested level cycling, and manual drag.
- **Region**: manual drag.
- **Long**: manual fixed-region scrolling capture.
- **App Scroll (Experimental)**: one compatible AX scroll target with driven scrolling.

The overlay supports mouse selection, Return confirmation, arrow/scroll candidate cycling, and Escape cancellation. It uses non-activating panels intended to remain with the target full-screen Space. Real full-screen, multi-display, and permission recovery behavior remains part of the GUI acceptance matrix.

### Automatic App Scroll (Experimental)

This is a separate explicit mode inside the unified overlay, not automatic behavior inside Smart or Long. It accepts only a static AX scroll area on one display with a writable vertical scrollbar. SmartShot captures verified fragments, stitches them, and attempts to restore the exact original scrollbar value after success, failure, or cancellation.

A controlled native fixture has verified one success and forced-timeout restoration. General third-party compatibility is not established.

### Browser Whole-Block Capture

The extension recognizes one semantic DOM block at a time. For X, descendants including media, social context, and nested quote content resolve to the outer selected `article[data-testid="tweet"]`; sibling replies remain separate. It does not combine threads or multiple posts.

- Fully visible targets use one browser screenshot and crop.
- Taller or partially offscreen targets use bounded page scrolling, observed-scale crops, and local stitching.
- The extension restores original page scroll and temporary styles.
- Unsupported nested-scroll, fixed/sticky-rooted, wider-than-viewport, dynamic, navigated, resized, or oversized targets fail explicitly.
- A completed PNG is offered to the native app. Native rejection/failure first uses a background-owned download, then a content-page fallback if that API fails and the page still exists.

The Chromium and Safari import bridges are implemented and automated-tested with two-phase delivery: the bridge validates/stages the PNG, then waits for SmartShot to validate and publish the preview before final acceptance. The app allows one outstanding browser import. Signed real-browser/X GUI acceptance remains outstanding.

## Long-Capture Limits

| Path | Fragments | Time | Logical/CSS height | Output |
| --- | ---: | ---: | ---: | --- |
| Manual Long | 24 | 5 minutes | 20,000 points | 16,384 px per axis; 32 million pixels |
| Automatic App Scroll | 24 | 75 seconds | 20,000 points | 16,384 px per axis; 32 million pixels |
| Browser block | 24 | 20 seconds | 20,000 CSS px | 16,384 px per axis; 32 million pixels |

Manual Long does not restore user-controlled scrolling. Automatic App Scroll restores its AX scrollbar or reports restoration failure. Browser capture restores window scrolling/styles or reports failure.

None of these paths promises dynamic/infinite feeds, virtualized lists, nested scrolling, horizontal scrolling, cross-display composition, or general-purpose whole-document capture.

## Screen Recording

Screen recording is implemented as a separate user workflow:

- **Record Region** opens a recording-specific drag overlay and clips the region to one display.
- **Record Current Display** chooses the display under the pointer.
- The main window, app commands, and menu bar expose start/stop/cancel controls; a non-activating HUD stays with the recording Space.
- Settings select system audio, optional microphone, pointer visibility, 15/30/60 fps, and a 1,920/2,560/3,840-pixel maximum edge.
- Stop finalizes H.264 video and AAC audio into MP4 and moves it to the Quick Save folder. Cancel discards the in-progress artifact.
- The result view previews the MP4 and supports reveal, copy file, Save As, and GIF export.
- GIF export is limited to the first 30 seconds, 15 fps, a 1,280-pixel maximum edge, and 450 frames.

The ScreenCaptureKit filter excludes SmartShot and current-process audio. Microphone is off by default and requires separate permission. Source mapping, state, routing, encoding, cleanup, and offline MP4/GIF export have automated coverage. One signed region/video-only MP4, preview, Save As, and GIF export path has narrow GUI evidence; display capture, system audio, microphone permission, A/V sync, long duration, and failure recovery remain GUI acceptance work.

## Editor and Output

The current editor provides:

- selection, movement, and deletion of annotations;
- crop and reset;
- freehand, arrow, rectangle, ellipse, text, and numbered counters;
- mosaic, blur, opaque redaction, spotlight, and magnifier;
- color and line-width controls;
- undo, redo, reset, and 100%-400% zoom;
- Copy, Pin, Save, Quick Save, and Flatten.

Copy, Pin, Save, and Quick Save render the current edit document from the source pixels. Flatten replaces the current capture and, when applicable, the same history item. Output supports PNG and JPEG, two filename styles, a configurable Quick Save folder, and collision-safe filenames.

Renderer effects have deterministic pixel coverage. The earlier GUI record covers only a basic subset; all expanded tools still need signed-app GUI acceptance.

## OCR and Privacy Assistance

The editor can run accurate, language-detecting Vision OCR locally. Large images are tiled with bounded overlap; results are mapped to original top-left image coordinates, deduplicated, and sorted in reading order.

Users can:

- inspect and copy recognized text;
- add opaque redaction over all recognized blocks;
- add opaque redaction over blocks matching supported sensitive patterns.

Current pattern assistance includes email, phone, Luhn-valid payment-card numbers, and checksum/date-valid Chinese national IDs. Detection and OCR can miss or misplace content; the user must inspect the final rendered bitmap.

Geometry, tiling, ordering, deduplication, validators, and cancellation have automated coverage. Real-image OCR accuracy and GUI behavior remain unverified.

## Local History and Private Captures

History is enabled by default. It stores PNG, JPEG thumbnail, and bounded metadata under `~/Library/Application Support/SmartShot/History`. The UI lists newest items and supports search, open, delete, and confirmed Clear History. Retention choices are 10, 25, 50, 100, or 250.

Search matches the capture label, an optional saved-file basename, and explicitly opted-in OCR index text. OCR index persistence is off by default and begins only after the user runs OCR; private captures never persist OCR index text, replacing an item without an index removes its old OCR index, and older metadata remains readable.

Private capture mode:

- prevents automatic history creation;
- prevents automatic clipboard copy;
- keeps the latest preview in memory;
- does not disable explicit Copy, Pin, Save, or Quick Save;
- does not control browser fallback downloads.

Private mode is a post-capture retention policy, not a sandbox or guarantee that other applications cannot observe the screen.

## Delay, Shortcut, and External Capture Behavior

- Capture delay options are Off, 3 seconds, and 5 seconds.
- The global shortcut is recorded in Settings, validated, conflict-checked, persisted, and recoverable with Restore Default.
- Captures started from the main window reveal the preview.
- Captures started by the global shortcut, menu bar, URL, or CLI can remain in the target Space; Settings can opt into revealing SmartShot afterward.

## URL Scheme and CLI

Public URLs:

```text
smartshot://capture?mode=smart|region|long|app-scroll
smartshot://quick-save
smartshot://show
```

The app embeds `Contents/Helpers/smartshot` with equivalent `capture`, `quick-save`, `show`, and `--help` commands. It is a fire-and-forget LaunchServices client, is not installed on `PATH`, and does not return a capture result. Capture and Quick Save use a non-activating open request so the target application/Space stays in place; Show intentionally activates SmartShot. Quick Save acts only on an existing latest capture.

`smartshot://import` is reserved for browser import and is not a public command.

## Browser Native Import Contract

The browser produces the PNG before native delivery. Phase one uses a UUID request ID and acknowledged `capture.import.begin`, ordered `capture.import.chunk`, and `capture.import.end` messages to validate and stage it. Phase two opens the internal import URL and returns final acceptance only after SmartShot validates the artifact and publishes the preview.

- PNG only, at most 64 MB decoded.
- Base64 chunks are at most 192 KiB.
- Imported images are bounded to 16,384 px per axis and 32 million pixels.
- Logical dimensions are finite, positive, and at most 20,000.
- The native store validates envelope, order, sizes, PNG decoding, and metadata.
- Chromium host installation is limited to a complete `/Applications/SmartShot.app` and a pinned extension origin.
- Safari uses the embedded handler and request-scoped named pasteboards to cross from its sandbox to the containing app.
- The app consumes a completed inbox item through an internal `smartshot://import` URL and opens it in the normal editor/history policy.
- The app accepts one outstanding browser import; overlap, app rejection, launch failure, or timeout rejects the native path and keeps the browser download fallback. The extension requests `downloads` solely to create that fallback and does not read download history.

No post text, author, page title, selector, HTML, cookie, credential, URL path/query/fragment, or browsing history is required or sent.

The Safari named-pasteboard channel validates UUIDs, metadata, size, PNG content, and acknowledgements and cleans up normal success/failure/timeout paths. It is not cryptographically source-authenticated against another process running as the same macOS user, and an extension crash after publication can leave bounded request-scoped residue beyond normal cleanup. These are accepted P2 boundaries of the current local self-signed release.

## Permissions and Degraded Modes

| Capability | Permission | Degraded behavior |
| --- | --- | --- |
| Native screenshot pixels | Screen Recording | Capture fails with recovery guidance. |
| AX smart blocks | Accessibility | Window and manual regions remain available. |
| Manual Long | Screen Recording | No Accessibility requirement. |
| Automatic App Scroll | Screen Recording + Accessibility | Cannot start without both and a writable AX scrollbar. |
| Safari semantic block | Safari extension + Website Access | Native AX/window/manual remains; extension cannot inspect the page. |
| OCR | None beyond access to the current capture | Recognition remains local. |
| Region/display recording | Screen Recording | Recording cannot start without permission. |
| Recording microphone | Microphone, only when enabled | Video and system-audio recording remain available with microphone disabled. |

Screen Recording and Accessibility denial/grant/revoke behavior still needs the current manual matrix before broad runtime claims.

## Local Distribution Boundary

The current release artifact is self-signed, not Developer ID signed or notarized. Gatekeeper may quarantine or block a downloaded copy until the user explicitly approves it. Clean-machine Gatekeeper behavior, Developer ID signing, and notarization are not completed acceptance claims.

## Privacy Requirements

- No analytics, upload endpoint, account, cloud sharing, or synchronization.
- No screenshot bytes or full AX text in logs.
- Browser technical metadata is bounded and URLs are reduced to HTTP(S) origin.
- History retention is explicit in Settings and private mode is accurately described.
- OCR and sensitive detection remain on-device.
- Screen recording and GIF export remain local; microphone use is explicit and off by default.
- Opaque redaction is used for privacy output; blur/mosaic are not called irreversible.
- Malformed extension input fails closed.
- Safari named-pasteboard same-user source authentication and crash residue remain documented P2 boundaries rather than being described as hardened IPC.

## Exclusions

The current product does not include:

- automatic X thread or multi-post capture;
- guaranteed dynamic/infinite/virtualized/nested/cross-display long capture;
- OCR translation or guaranteed sensitive-data discovery;
- object removal or semantic editing of text already baked into pixels;
- cloud links, accounts, or synchronization;
- recording camera capture, trimming, click visualization, presets, or general video editing.

Recording is limited to one display or a region on one display. GIF export is deliberately bounded and does not preserve audio.

## Acceptance Boundary

The native capture/editor/history/OCR/automation, browser bridge, and screen-recording workflow may be described as implemented in code. The current automated record is **199/199 Swift/XCTest** and **67/67 browser Node** tests; its exact scope is in [TEST_PLAN.md](TEST_PLAN.md). Narrow recorded GUI evidence now covers the controlled automatic AX fixture, installed Smart/Region/Manual Long captures, overlay Escape, a basic editor/output/private subset, installed CLI delivery, and one region/video-only recording plus Save As/GIF export.

Do not call Chrome/Safari + X, the complete CLI/URL failure/full-screen matrix, expanded OCR/editor/history workflows, audio/current-display recording, or the general native display/permission matrix GUI-verified until their test records exist.
