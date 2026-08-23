# SmartShot Architecture

## Status and Evidence Boundary

This document describes code present in the checkout on 2026-08-24. It keeps four different claims separate:

- **Implemented**: the production path and a user-facing entry point exist.
- **Automated coverage**: deterministic tests exercise the named logic, but not macOS permissions, browser installation, or GUI interaction.
- **GUI verified**: a recorded signed-app or privileged run exists for the stated scenario only.
- **GUI pending**: the implementation still needs the manual matrix in [TEST_PLAN.md](TEST_PLAN.md).

A successful build, a registered permission, a configured browser host, and a correct end-to-end capture are different facts.

## System Overview

```text
SwiftUI window / MenuBarExtra / Carbon shortcut / smartshot:// URL / bundled CLI
  -> AppModel
      -> unified selection overlay
           -> Smart: AX blocks + windows + manual drag
           -> Region: manual drag
           -> Long: fixed region + user-driven scrolling
           -> App Scroll (Experimental): AX scroll target + driven scrolling
      -> ScreenCaptureKit pixels
      -> CaptureEditorModel
           -> ScreenshotRenderer
           -> local Vision OCR + sensitive-pattern helpers
      -> post-processing policy
           -> optional automatic clipboard copy
           -> optional local history
      -> Copy / Pin / Save / Quick Save / Flatten

Main window / app commands / MenuBarExtra recording entry
  -> AppModel active-operation coordinator
      -> recording-region overlay or display under pointer
      -> RecordingSourceMapper -> one SCDisplay / display-local sourceRect
      -> ScreenRecordingService actor
           -> SCStream video + optional system audio
           -> optional AVCaptureSession microphone
           -> RecordingSampleRouter -> RecordingAssetWriter
      -> H.264/AAC MP4 export -> Quick Save folder
      -> AVKit preview / reveal / copy file / Save As / bounded GIF export

Browser action
  -> DOM selection
  -> visible crop or bounded browser scroll/crop/stitch
  -> completed PNG
      -> strict native import -> SmartShot preview/editor/history policy
      -> browser download fallback when native import is unavailable or rejected
```

## Native Capture Pipeline

### Application State and Entry Points

`SmartShotApp` owns the main window, menu commands, menu-bar extra, and URL delivery. `AppModel` owns screenshot and recording operation state, the latest `CapturedImage` or `RecordingArtifact`, the current editor, permissions, output preferences, history, browser integration, and in-flight cancellation.

The public URL routes and bundled CLI converge on `SmartShotExternalCommand`. Capture URLs start Smart, Region, Long, or Automatic App Scroll; Quick Save renders the latest capture; Show activates the app. The CLI uses `NSWorkspace.OpenConfiguration`: Capture and Quick Save do not activate SmartShot, while Show does. It exits after LaunchServices accepts or rejects the URL, so it does not wait for capture completion or return a file path. `smartshot://import` is a separate internal browser-import route.

### Shortcut and Overlay

`GlobalShortcutMonitor` uses Carbon for an exclusive global shortcut. The persisted value stores a hardware key code and normalized modifiers. A replacement is registered before the old shortcut is removed, so conflict or validation failure leaves the previous working shortcut intact.

`SelectionOverlayController` creates one non-activating panel per `NSScreen` with all-application-Space and full-screen-auxiliary behavior. The overlay supports Smart, Region, Long, and App Scroll from one screenshot invocation, plus a separate recording-region drag mode. Screenshot selection supports nested candidate cycling, Return/click confirmation, drag selection, and Escape cancellation. Manual screenshot and recording drags are constrained to the display where the drag begins; cross-display composition is not implemented.

### Candidate Providers

Smart mode combines:

1. `AccessibilityBlockDetector`, when Accessibility is trusted.
2. `WindowCandidateProvider`, using visible Core Graphics windows.
3. A manual rectangle from the overlay.

`CandidateFilter` clips candidates to desktop bounds, rejects undersized rectangles, deduplicates rounded frames, and sorts by area. AX inspection is debounced and request-tagged so stale asynchronous results cannot revive a prior highlight after pointer movement, mode changes, or teardown.

`CaptureCandidate.Source.webDOM` remains in the shared model, but the current browser integration does not map DOM rectangles into this native selector. The browser creates the final PNG itself and imports that image.

### Pixel Capture and Coordinates

`ScreenCaptureService` rechecks Screen Recording access, obtains live `SCShareableContent`, requires the complete selection to fit one capturable display, excludes SmartShot, and captures with `SCScreenshotManager`. A cross-display or partially off-display selection fails explicitly instead of returning silently truncated pixels; only sub-point edge rounding is tolerated.

The native coordinate contract is:

```text
AppKit global logical rectangle
  -> require containment in one NSScreen.frame
  -> AppKit-to-Quartz conversion
  -> display-local ScreenCaptureKit sourceRect
  -> output pixels using the selected screen scale
```

Negative display origins, mixed 1x/2x arrangements, scaled resolutions, and live display changes remain real-hardware acceptance obligations.

## Long Capture Paths

### Manual Long

`ManualScrollingCaptureService` holds one ScreenCaptureKit rectangle while the target application stays interactive. The user scrolls downward in short steps. The service waits for stable frames, accepts only reliable downward overlap, removes only newly revealed rows, and handles one conservative unchanged top strip.

The non-activating HUD exposes Done and Cancel without taking over the target Space. A monitored scroll attempt after accepted movement can signal the bottom when it produces an equivalent frame. Manual Long does not synthesize scrolling, infer a hidden semantic document boundary, or restore the position changed by the user.

Bounds: 24 fragments, 5 minutes, 20,000 logical points of height, 16,384 pixels on either output axis, and 32 million output pixels.

### Automatic App Scroll (Experimental)

`AccessibilityScrollCaptureTarget` accepts only one static, single-display `AXScrollArea` whose vertical scrollbar has a finite writable `AXValue` range. It records the owning process/window, frames, range, frontmost application, and original scroll value.

`ScrollingCaptureService` validates identity and geometry, moves to the start, captures stable ScreenCaptureKit frames while advancing the AX scrollbar, verifies overlap and endpoint progress, stitches the fragments, and attempts to restore the exact original value after success, failure, or cancellation. Restoration failure is surfaced explicitly.

Bounds: 24 fragments, 75 seconds, 20,000 logical points, 16,384 pixels per output axis, and 32 million output pixels. Dynamic or infinite feeds, virtualized lists, nested scroll areas, changing content, horizontal scrolling, and cross-display areas are not supported claims.

## Editor, OCR, and Output

`CaptureEditorModel` keeps the original capture immutable and stores a normalized crop plus normalized annotations in `ScreenshotEditHistory`. Current tools are Select, Crop, Freehand, Arrow, Rectangle, Ellipse, Text, Mosaic, Blur, opaque Redaction, Spotlight, Magnifier, and Counter. Select can move or delete annotations; the UI also exposes color, line width, undo, redo, reset, and 100%-400% zoom.

`ScreenshotRenderer` produces a bounded preview from the current document and renders final Copy, Pin, Save, Quick Save, and Flatten output from the original bitmap. The preview is bounded to 2,400 pixels on its longest side and 8 million pixels; final rendering is bounded to 50 million pixels. Flatten replaces the current source and updates the same history item when one exists.

`TextRecognitionService` runs Vision `.accurate` recognition locally with language correction and automatic language detection. Images are tiled at up to 4,096 x 4,096 pixels with 192-pixel overlap, capped at 64 million input pixels and 2,000 recognized blocks. Post-processing converts Vision geometry to the editor's top-left normalized coordinates, restores reading order, and deduplicates overlap results.

The editor can copy recognized text, redact all recognized blocks, or add opaque redactions for supported email, phone, Luhn-valid payment-card, and checksum/date-valid Chinese national-ID matches. Detection is heuristic; blur and mosaic are visual effects, not irreversible privacy output.

`CaptureOutputService` supports PNG and JPEG, two filename styles, atomic Quick Save, collision avoidance, and a configurable directory initially resolved as `~/Pictures/SmartShot`.

## History and Private Capture

`CaptureHistoryStore` is an actor-backed local store under:

```text
~/Library/Application Support/SmartShot/History
```

Each retained item has a PNG, JPEG thumbnail, and JSON metadata. The UI can list, search, open, delete, and clear history; Settings can disable new history and retain 10, 25, 50, 100, or 250 items. Replacing a flattened capture retains the same history identity.

Search matches the capture label, an optional saved-file basename, and OCR text only when the separate OCR-index preference is enabled. OCR indexing is off by default, begins only after the user runs OCR, and is never persisted for private captures. Legacy metadata without the newer search fields remains readable.

`CapturePostProcessingPolicy` gives Private mode a deliberately narrow meaning: it suppresses automatic history and automatic clipboard copy. The latest preview remains in memory, and explicit Copy, Pin, Save, and Quick Save still work. Private mode also does not control a browser's download fallback.

## Screen Recording Pipeline

`AppModel` serializes screenshots and recordings through one active-operation state. Region recording uses the recording-specific overlay; current-display recording uses the display under the pointer. `RecordingSourceMapper` converts an AppKit global region into one ScreenCaptureKit display-local logical rectangle with a top-left origin. Cross-display and invalid/undersized regions fail before a stream starts.

`ScreenRecordingService` is an actor around a UUID-scoped state machine:

```text
idle -> preparing -> recording -> stopping -> finished
                    \-> cancelled / failed
```

`RecordingSourceResolver` obtains live `SCShareableContent`, chooses the requested display, excludes SmartShot, and produces either a full-display filter or a validated region `sourceRect`. `RecordingVideoPlanner` applies the selected 15/30/60 fps and 1,920/2,560/3,840-pixel maximum edge, preserves aspect ratio, and emits even H.264 dimensions.

An `SCStream` supplies screen frames and optional system audio. `SCStreamConfiguration` can show the pointer and excludes current-process audio. When microphone capture is enabled, `MicrophoneCaptureService` uses a separate `AVCaptureSession`; `RecordingSampleRouter` sends both audio sources and video to `RecordingAssetWriter`. Microphone is off by default and is blocked until macOS permission is granted.

The writer creates a temporary H.264/AAC MOV. Stop ends the stream and microphone, finishes the writer, composes the tracks into an H.264/AAC MP4, validates the exported codecs, cleans intermediates, and moves the MP4 into the Quick Save folder with a collision-safe timestamped name. Cancel, startup failure, runtime failure, and termination use session identity to prevent an older cleanup task from destroying a newer recording.

`ScreenRecordingHUDController` provides non-activating elapsed/Stop/Cancel controls. The main result view uses AVKit and exposes reveal, copy file, Save As, and `GIFExportService`. GIF export samples at most 30 seconds at 15 fps, scales to a 1,280-pixel long edge, writes at most 450 frames, and removes incomplete output on cancellation/failure.

Recording artifacts are ordinary local files, not screenshot-history items. Screenshot Private mode does not suppress recording output. Focused tests cover planning, state, routing, encoding configuration, cleanup, and synthetic offline MP4/GIF export; real ScreenCaptureKit pixels, audio, A/V sync, permissions, sustained duration, and display/sleep changes remain GUI acceptance work.

## Browser Capture and Native Import

### Browser-Side Capture

The Manifest V3 extension selects one semantic DOM block. For X, nested media and quoted-post descendants resolve to the outer `article[data-testid="tweet"]`; sibling replies remain separate, and threads are not combined. Generic pages use layout and semantic ancestors.

Fully visible targets use one `captureVisibleTab` frame and an observed bitmap-to-viewport scale. Taller or partially offscreen targets use at most 24 page slices. The background captures each slice again after 120 ms; the content script downsamples the selected slice to at most 96 pixels on its longest edge and rejects material pixel differences before cropping and stitching one local canvas. This is a fail-closed dynamic-content heuristic, not proof of frozen pixels, and the 20-second budget includes the extra frames. Capture is also bounded to 20,000 CSS pixels of target height, 16,384 pixels per output axis, and 32 million output pixels.

The browser path fails closed for wider-than-viewport targets, nested scrolling, fixed/sticky-rooted selections, navigation, resize, target mutation, manual scroll interference, active-tab/document changes, timeout, or size limits. Scroll position and temporary animation/fixed/sticky styles are restored on success and failure.

### Native Import Protocol

After either browser path has produced a complete PNG, `shared/delivery.js` requests native import. `background.js` validates a `data:image/png;base64,...` URL, estimates decoded size at no more than 64 MiB, sanitizes filename/kind/origin, and sends ordered base64 chunks no larger than 192 KiB:

```text
capture.import.begin -> ACK(begin)
capture.import.chunk(index 0...N-1) -> ACK(chunk, same index)
capture.import.end -> ACK(end)
```

Every envelope is versioned and uses the same RFC 4122 request ID. The begin message contains MIME type, encoding, byte/base64 lengths, chunk count, safe filename/kind, `sourceOrigin`, and finite positive logical dimensions. A missing host, rejection, malformed or mismatched acknowledgement, timeout, or interruption first asks the background worker to download the completed PNG. A content-page anchor remains a second fallback when the downloads API is unavailable or rejects the request; a successful background download is never duplicated.

Chromium sends messages to the embedded `SmartShotNativeHost`; Safari sends them to `SafariWebExtensionHandler`. Both use `BrowserCaptureImportStore` to validate the protocol, bound image geometry and size, stage files locally, decode the PNG, and reject malformed transfers. This completes phase one, but it is not yet final delivery.

In phase two, the bridge opens `smartshot://import?requestId=...&source=...`. `BrowserCaptureImportService` consumes the completed artifact, validates logical dimensions and image aspect, creates a `CapturedImage`, and passes it through the same editor and post-processing path as a native capture. The bridge returns an accepted end acknowledgement only after the app completes that work. Launch failure, app rejection, a ten-second timeout, or termination rejects and cleans the transfer so the browser can keep its completed-download fallback.

`BrowserCaptureImportQueue` permits exactly one outstanding request, counting active and pending work. A second overlapping import is rejected instead of being queued to overwrite the sole latest-preview slot. Duplicate and completed request IDs are handled idempotently.

Chromium keeps its completed phase-one artifact in the bounded Application Support store until app consumption. Safari cannot share that private container with the containing app, so the handler consumes its store artifact and publishes the PNG/metadata plus app acknowledgement through UUID-named `NSPasteboard` instances. Both sides revalidate request identity, metadata, size, PNG, and acknowledgement state, and normal success, rejection, and timeout paths clean up the boards.

This is an image-import architecture, not DOM-CSS-to-AppKit coordinate mapping.

### Browser Privacy Boundary

Native import contains PNG bytes plus a safe filename/kind, logical dimensions, and sanitized HTTP(S) origin. It does not include post text, author, page title, selector, HTML, URL credentials/path/query/fragment, cookies, or browsing history. The extension contains no analytics, upload endpoint, remote font, `fetch`, or `XMLHttpRequest` use.

Named pasteboards are a current P2 transport boundary: they do not cryptographically authenticate the writer against another process running as the same logged-in user, and an extension crash after publication can leave bounded request-scoped residue beyond the normal cleanup path. The UUID request name, strict validation, size limits, one-outstanding queue, timeout, and fail-closed fallback reduce exposure but do not turn the channel into authenticated IPC. A future hardened distribution should use an authenticated shared channel such as a correctly provisioned App Group plus an application-level integrity/authentication design.

## Permissions and Degraded Modes

| Capability | Required permission or setup | Degraded behavior |
| --- | --- | --- |
| Native screenshot pixels | Screen Recording | Capture fails with recovery guidance. |
| AX semantic candidates | Accessibility | Window and manual region selection remain available. |
| Manual Long | Screen Recording | No Accessibility dependency. |
| Automatic App Scroll | Screen Recording + Accessibility + writable AX scrollbar | The automatic path is unavailable; Manual Long remains the fallback. |
| Safari DOM selection/import | Enabled extension + Website Access + signed containing app + extension `downloads` permission | Native AX/window/manual paths remain available; failed import downloads in the browser when the API or source page remains available. |
| Chromium native import | Complete `/Applications/SmartShot.app`, installed host manifest, loaded pinned extension + extension `downloads` permission | Capture can still fall back to a browser download. |
| OCR | Current captured image | No extra permission; processing is local. |
| Region/display recording | Screen Recording | Recording cannot start; screenshot settings/recovery remain available. |
| Recording microphone | Microphone, only when enabled | Video and optional system audio remain available when microphone is off. |

The project has no analytics, account, cloud synchronization, or runtime screenshot-upload client. History is local and enabled by default, so it is incorrect to describe all screenshot bytes as memory-only.

The current local release is self-signed rather than Developer ID signed and notarized. Gatekeeper may quarantine or block a downloaded copy pending explicit user approval. This distribution boundary is separate from code-signing success, TCC state, and runtime GUI acceptance.

## Current Module Map

```text
Sources/SmartShotApp
  Editing/                         editor coordination
  Overlay/                         unified selection and input mapping
  Recording/                       recording source, stream, writer, export, and cleanup
  Services/AppModel.swift          application coordinator
  Services/ScreenCaptureService.swift
  Services/ManualScrollingCaptureService.swift
  Services/ScrollingCaptureService.swift
  Services/TextRecognitionService.swift
  Services/CaptureHistoryStore.swift
  Services/CaptureOutputService.swift
  Services/BrowserCaptureImportService.swift
  Services/ChromiumNativeMessagingInstaller.swift
  Views/                            main UI, settings, preview, HUDs, pinned panels

Sources/SmartShotCore
  Accessibility/                   AX hierarchy and screen mapping
  Capture/                         candidates and geometry
  Editing/                         edit document and raster renderer
  LongCapture/                     overlap, fixed-top detection, stitching
  Shortcut/                        persisted shortcut value

Sources/SmartShotBrowserBridge      strict staged import store/protocol
Sources/SmartShotNativeHost         Chromium native-messaging executable
Sources/SmartShotSafariExtension    Safari handler
Sources/SmartShotCommand            URL/CLI command model and parser
Sources/SmartShotCLI                embedded launcher executable
BrowserExtension                    WebExtension scripts, shared helpers, Node tests
```

## Known Architectural Boundaries

| Area | Current status |
| --- | --- |
| Native Smart/Region and manual Long | Implemented with deterministic coverage and narrow installed-app Smart, Region, and Manual Long GUI evidence; broad display/permission matrix pending. |
| Automatic App Scroll | Implemented for bounded static AX scroll areas; one controlled success and forced-timeout restoration run recorded. |
| Browser single-block/X single-post capture | Implemented with Node fixtures and native protocol/store tests; real signed Chrome/Safari + current X GUI pending. |
| Browser app handoff | Two-phase delivery with one outstanding import; Safari named-pasteboard source authentication and crash residue remain documented P2 boundaries. |
| Editor/OCR/history/private/output | Implemented with focused automated coverage and a narrow signed GUI subset; expanded GUI and persistence acceptance pending. |
| URL scheme and bundled CLI | Implemented with parsing/round-trip coverage and installed non-activating capture/Quick Save plus activating Show checks; the complete matrix remains pending. |
| Region/current-display screen recording | Implemented with focused component/offline-export coverage and one live region/video-only MP4/preview/Save As/GIF check; current-display/audio and the broader GUI matrix remain pending. |
| General dynamic/infinite/virtualized/nested/cross-display long capture | Not implemented or promised. |
| Automatic X thread/multiple-post capture | Not implemented. |
| Mixed-display capture composition | Not implemented. |
| Privileged permission, full-screen, browser-install, and mixed-scale matrix | Outstanding acceptance work. |
| Gatekeeper distribution | Current local artifact is self-signed and not notarized; Developer ID/notarization and clean-machine acceptance remain future release work. |
