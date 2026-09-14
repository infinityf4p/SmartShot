# SmartShot Roadmap

## Current Baseline

Implemented in the current checkout as of 2026-08-24:

- Unified Smart, Region, manual Long, and App Scroll selector with Escape cancellation and nested cycling.
- Configurable persisted Carbon shortcut with conflict rollback.
- ScreenCaptureKit still capture, AX/window/manual candidates, delay, pin, copy, Save, and Quick Save.
- Bounded manual Long and native Automatic App Scroll (Experimental).
- Expanded local editor: select/move/delete, crop, freehand, arrow, rectangle, ellipse, text, counter, mosaic, blur, opaque redaction, spotlight, and magnifier.
- On-device Vision OCR, text copy, supported sensitive-pattern detection, and OCR-assisted redaction.
- Local capture history with retention, search, open/delete/clear/replace, and an off-by-default OCR index.
- Private capture policy that suppresses automatic history and automatic copy.
- PNG/JPEG output, naming choices, and configurable Quick Save directory.
- Public capture/Quick Save/Show URL routes and an embedded fire-and-forget CLI.
- Browser semantic single-block capture, including X single-post fixtures, bounded browser scrolling/stitching with heuristic two-frame slice checks, Chromium/Safari two-phase native PNG import, one-outstanding app admission, background-owned download fallback, and Safari status/settings entry points.
- User-visible single-display/region recording with system audio, optional microphone, pointer/frame-size settings, H.264/AAC MP4 output, preview/file actions, and bounded GIF export.

The current automated gates pass 199/199 native Swift and 93/93 browser Node tests. Automated coverage is not a substitute for the remaining signed GUI and real-browser acceptance work.

## Milestone 1: Stabilize the Current Native Product

Outcome: make implemented native screenshot workflows evidence-backed.

- Complete Screen Recording and Accessibility denial/grant/revoke recovery.
- Record frontmost-app shortcut delivery and custom shortcut behavior across keyboard layouts.
- Verify overlays and cancellation in full-screen Spaces, Mission Control, lock/unlock, and repeated rapid use.
- Complete Retina, 1x/2x mixed-scale, negative-origin, display-change, and cross-display-boundary cases.
- Verify AX/window/manual capture edges and SmartShot-window exclusion from a signed installed build.
- Exercise PNG/JPEG Save, Quick Save, overwrite avoidance, cancellation, unwritable destinations, Copy, Pin, and Flatten.
- Verify termination while countdown, manual Long, automatic scrolling, browser import, and history writes are active.

Exit gate: no known stuck-input, wrong-display, captured-overlay, destructive-output, or permission-recovery defect in the recorded matrix.

## Milestone 2: Browser Installation and X Acceptance

Outcome: promote the implemented browser bridge from automated evidence to a real compatibility statement.

Recorded on 2026-08-24: universal native **0.2.1 (build 7)** is installed and running from `/Applications/SmartShot.app`; all embedded executables passed strict deep signature verification; Chromium manifests validate for detected browsers; stale Safari registrations were cleaned to one fresh `Sign to Run Locally` Clean7 WebExtension registration; and an earlier complete 0.2.1 development build was listed and enabled in Safari with its shortcut and toolbar action visible. These are artifact/setup results only. A physical Safari action, Chromium reload, and end-to-end capture remain open.

- Package and install the current complete app at `/Applications/SmartShot.app`.
- Verify helper executability and Chromium manifests for Chrome, Chromium, Edge, and Brave.
- Use Chromium's user-controlled Developer mode / **Load unpacked** UI to load the pinned unpacked extension and verify its expected ID.
- For Safari development, use Apple development signing or a complete **Sign to Run Locally** container/extension build, then enable Safari's per-process unsigned-extension override when required. Test a physical action plus Website Access denial/recovery, verify the override resets after Safari quits, and remove this development dependency through proper distribution signing. Do not expect the custom persistent self-signed `/Applications` build to become a valid Safari extension merely from the override.
- Run visible and tall controlled fixtures through native preview and forced download fallback.
- Verify phase-two app acceptance, a second overlapping import rejection, termination, and ten-second timeout cleanup without replacing the active preview.
- Run public X timeline/detail cases for text, media, quoted posts, replies/reposts, logged-out state, light/dark mode, and current DOM changes.
- Cover page zoom, window movement, full screen, navigation, tab changes, mutation, dynamic pixels, fixed/sticky content, nested scroll, timeout, and hard limits.
- Record exact browser/macOS/build versions, output dimensions, restoration, and non-sensitive seam evidence.
- Exercise Safari named-pasteboard cleanup after success, rejection, timeout, and forced extension termination; retain same-user source authentication and crash residue as explicit P2 boundaries until the transport is hardened.

This milestone supports one post only. Automatic threads, multiple posts, dynamic/infinite feeds, and virtualized lists remain excluded.

## Milestone 3: Editor, OCR, History, and Privacy Acceptance

Outcome: verify the new local workflow as users experience it.

- Exercise every editing tool, selection/movement/deletion, undo/redo/reset, zoom, and render-cache invalidation.
- Confirm magnifier output cannot reveal pixels hidden by opaque redaction.
- Test Vision OCR on controlled multilingual, Retina, long, rotated, low-contrast, and no-text images.
- Verify reading order, copy, redact-all, sensitive-only redaction, false positives, and false negatives.
- Confirm private captures create neither a history item nor automatic clipboard content while explicit actions remain available.
- Restart the app and verify history ordering, thumbnails, search, open/delete/confirmed-clear, retention changes, corrupted-entry recovery, and Flatten replacement.
- Verify label and saved-file-basename searches independently from OCR-index searches.
- Verify OCR search requires explicit opt-in and an OCR run, never indexes private captures, removes an older index when a capture is replaced without one, and explains its local storage boundary.

Exit gate: storage and privacy wording matches observed files and clipboard behavior.

## Milestone 4: Automation Acceptance

Outcome: make URL and CLI commands dependable for local workflows.

- Verify LaunchServices registration from a signed `/Applications` build.
- Exercise every capture mode through `open smartshot://...` and the bundled CLI.
- Verify capture requests received during another active operation are ignored or queued according to the documented contract.
- Verify Quick Save with and without a latest capture, configured PNG/JPEG output, filename collisions, and folder failures.
- Decide whether the CLI remains fire-and-forget or gains a separate authenticated IPC/result protocol.
- If exposing the CLI on `PATH`, add an explicit installer/uninstaller rather than implying it is already installed.

## Milestone 5: Recording Acceptance and Hardening

Outcome: promote the implemented recording workflow from focused automated evidence to a dependable runtime feature.

- Verify region and current-display selection, countdown, elapsed HUD, Stop, Cancel, failure, and termination from the main window, menu commands, and menu bar.
- Verify H.264 video plus system audio and optional microphone as AAC, including A/V sync, cursor on/off, 15/30/60 fps, and each maximum-edge setting.
- Exercise microphone not-determined/denied/granted/revoked states and Screen Recording recovery without misleading permission status.
- Verify SmartShot controls and current-process audio are excluded as promised.
- Test dropped frames, long duration, sleep/wake, display removal/change, encoder failure, low disk space, and temporary-file cleanup.
- Verify MP4 persistence, in-app preview, reveal/copy/Save As, filename collisions, and unwritable Quick Save destinations.
- Verify GIF cancellation and the 30-second, 15-fps, 1,280-pixel, 450-frame limits.
- Keep camera, click visualization, trimming, presets, and general video editing as later product decisions.

Component and synthetic media-export tests do not satisfy this runtime milestone.

## Long-Capture Research

The three bounded paths remain separate contracts:

- Manual Long: user-driven fixed rectangle.
- Automatic App Scroll: app-driven AX scrollbar with restoration.
- Browser whole block: DOM-defined element with browser page restoration.

Research remains for repeated/low-texture content, dynamic media, changing sticky headers, virtualized rows, nested scroll containers, horizontal content, and multiple displays. Unsupported content must fail rather than produce a plausible but incomplete image.

## Later Product Tracks

- Translation with an explicit provider and privacy design.
- Object removal and pixel-content editing.
- Safe local metadata/export controls and optional advanced history filters.
- Optional cloud sharing only with a separate account, retention, encryption, and abuse model.
- Developer ID signing, notarization, clean-machine Gatekeeper acceptance, updates, and crash diagnostics with opt-in privacy controls.
- Replace or harden Safari named-pasteboard transfer with an authenticated shared channel when provisioning supports it; include migration and stale-artifact cleanup.

## Prioritization Rules

1. Fix wrong pixels, wrong display, privacy leakage, destructive output, crashes, and stuck input first.
2. Prefer a reliable manual fallback over an inaccurate smart result.
3. Keep implementation, automated evidence, GUI evidence, and product claims separate.
4. Keep site-specific logic fixture-tested and bounded.
5. Never promote a configured connector or building target as a completed workflow.
6. Add permissions only when a user-visible capability and recovery path exist.
7. Keep local retention explicit and private-mode behavior precise.
