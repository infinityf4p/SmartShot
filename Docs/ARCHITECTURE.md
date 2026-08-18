# SmartShot Architecture

## Status and Scope

This document distinguishes the current implementation from the target Safari DOM architecture. Sections labeled **Current** describe code present as of 2026-08-15. Sections labeled **Target** are design direction, not evidence of implementation. Manual Long and automatic AX scrolling are bounded native paths; the browser path still lacks real Chrome/Safari + X end-to-end evidence.

## Current Native Architecture

```text
SwiftUI app / MenuBarExtra / registered global shortcut
  -> AppModel
  -> Unified Capture overlay
       -> Smart
       -> SelectionOverlayController
            -> AccessibilityBlockDetector + AXUIElement provider
            -> WindowCandidateProvider
            -> manual drag candidate
       -> ScreenCaptureService (ScreenCaptureKit)
       -> Region
            -> manual drag candidate -> ScreenCaptureService
       -> Long
            -> fixed manual region
            -> ManualScrollingCaptureService
                 -> stable ScreenCaptureKit frames
                 -> VerticalOverlapEstimator + VerticalImageStitcher
                 -> ManualScrollingCaptureHUDController
  -> Automatic App Scroll (Experimental)
       -> scrollable-area selection
       -> AccessibilityScrollCaptureTarget
       -> ScrollingCaptureService
            -> repeated ScreenCaptureKit fragments
            -> VerticalOverlapEstimator + VerticalImageStitcher
  -> optional 0/3/5-second countdown
  -> read-only preview
  -> NSPasteboard, pinned NSPanel, or NSSavePanel + atomic PNG write
```

### SwiftUI and Application State

`SmartShotApp` owns the main window, menu commands, and menu-bar extra. `AppModel` owns the capture state:

```text
idle -> selecting -> capturing -> idle
  \-> failed(message)
```

`AppModel` stores only the latest `CapturedImage`. It exposes start, copy, save, and error-clear actions. The preview displays the captured image with aspect-fit scaling. It does not expose an editable crop model.

### Global Shortcut

`GlobalShortcutMonitor` uses exclusive Carbon hot-key registration after the main window appears. On launch it tries the persisted built-in combination first and then the other built-in combination if occupied; custom shortcuts are never silently replaced. `KeyboardShortcutValue` persists the hardware key code and normalized modifier bits. A custom update registers the candidate first, persists it, switches the active identifier, and only then unregisters the previous hot key. Conflicts and failures therefore leave the prior shortcut active. During recording, the existing Carbon event is routed back to the recorder instead of starting capture, allowing the active combination to be recorded without releasing its registration. SwiftUI command key equivalents do not duplicate the global capture shortcut.

`SelectionOverlayController` creates non-activating `NSPanel` overlays with full-screen auxiliary and all-application Space behavior. Capture origin is explicit: main-window captures reveal the preview, while menu-bar and global-shortcut captures remain in the target Space by default. Manual drags are clamped to their starting display because multi-display image composition is outside the current MVP.

### Overlay and Candidate Providers

`SelectionOverlayController` creates one borderless AppKit overlay window per `NSScreen`. It collects candidates from:

1. `AccessibilityBlockDetector`, when `AXIsProcessTrusted()` is true.
2. `WindowCandidateProvider`, using the visible Core Graphics window list.
3. A manual rectangle created by dragging in `SelectionOverlayView`.

`CandidateFilter` clips candidates to desktop bounds, rejects undersized rectangles, deduplicates rounded frames, and sorts by area. The overlay cycles the resulting array and draws the current candidate on every screen, clipped to each screen frame.

### Current Candidate Contract

```swift
public struct CaptureCandidate: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable {
        case accessibility
        case webDOM
        case window
        case manual
    }

    public let id: UUID
    public let rect: CGRect
    public let source: Source
    public let label: String
    public let level: Int
}
```

`rect` is expected to be an AppKit global logical-point rectangle before capture. The `.webDOM` case exists in the model, but no current native provider creates such a candidate.

### Accessibility Path

`SystemAccessibilityHierarchyProvider` uses `AXUIElementCopyElementAtPosition` and walks a bounded parent chain. The detector maps useful AX roles and frames to candidates. Its coordinate adapter is covered by `AXScreenLayoutTests`; role/filter behavior is covered by `AccessibilityBlockDetectorTests`.

The overlay debounces pointer updates and runs live AX inspection away from the main actor. Request identifiers prevent stale results from reviving an old highlight after movement, mode changes, or teardown. AX calls still depend on target-process response time and retain explicit messaging timeouts where live scroll targets are resolved.

### Window Path

`WindowCandidateProvider` reads on-screen normal-level windows under the pointer and creates a window candidate. This path remains available without Accessibility permission.

### Capture Path

`ScreenCaptureService`:

1. Rechecks Screen Recording permission.
2. obtains live `SCShareableContent`;
3. resolves the `NSScreen` containing the selected rectangle's center;
4. clips the selection to that screen;
5. converts the AppKit rectangle to Quartz coordinates;
6. builds an `SCContentFilter` that excludes the SmartShot application;
7. sets `SCStreamConfiguration.sourceRect`, width, and height;
8. calls `SCScreenshotManager.captureImage`;
9. encodes PNG and returns the image, bytes, logical rectangle, and label.

The service performs source-region cropping as part of screenshot acquisition. This is not post-capture editing. There is no `CropModel`, crop UI, or second bitmap crop after preview.

### Manual Long

`ManualScrollingCaptureService` prepares one fixed ScreenCaptureKit source rectangle and leaves the target application interactive. It repeatedly captures the same rectangle, waits until two consecutive frames are stable, and compares each stable frame with the last accepted frame. Identical frames are ignored. A changed frame is accepted only when `VerticalOverlapEstimator` finds a reliable downward translation; `VerticalImageStitcher` then copies only newly revealed rows.

`ManualScrollingCaptureHUDController` is a non-activating floating panel excluded by the app-level ScreenCaptureKit filter. It reports accepted section count and lets the user finish or cancel without switching Spaces. The manual controller does not synthesize scroll events, require Accessibility, infer document boundaries, or restore the position changed by the user.

The manual path is bounded to 24 fragments and 5 minutes, with limits of 20,000 logical points, 16,384 pixels on either output axis, and 32 million output pixels. Large jumps, reverse movement, changing geometry, or pixels that cannot produce a reliable seam are explicit failures.

### Automatic App Scroll (Experimental)

`AccessibilityScrollCaptureTarget.resolve` walks up from the selected point and accepts only the selected `AXScrollArea` whose frame matches the candidate and whose vertical `AXScrollBar` exposes a finite, non-empty, writable `AXValue` range. It records the owning process/window, scroll-area and capture frames, current frontmost process, range, and original scroll value. The capture frame must fit fully on one `NSScreen`; visible scrollbar strips are excluded from that frame.

`ScrollingCaptureService` then:

1. validates that the app, frontmost process, window frame, scroll-area frame, capture frame, and scrollbar range have not changed;
2. moves the scrollbar to its minimum and verifies a stable initial frame;
3. captures the same viewport repeatedly with ScreenCaptureKit while advancing the writable AX scrollbar;
4. estimates reliable vertical overlap, retries with a smaller scroll step when possible, and rejects unchanged or unstable content;
5. verifies the final scrollbar position and stable ending frame;
6. stitches the verified fragments vertically and returns one PNG;
7. restores the recorded scroll value after success, thrown error, or task cancellation.

The default bounds are 24 fragments, 75 seconds, 20,000 logical points of stitched height, 16,384 pixels on either output axis, and 32,000,000 output pixels. A restoration failure is reported explicitly rather than hidden behind the original error.

This architecture is designed for a static, single-display AX scroll area with a writable vertical scrollbar. It does not claim dynamic or infinite feeds, virtualized lists, nested scroll areas, cross-display composition, horizontal scrolling, or changing content. Overlap/stitching logic has automated coverage; the privileged real-application path still needs the manual matrix in `TEST_PLAN.md`.

### Coordinate Contract

The native selection contract uses AppKit global logical points. Current conversion is:

```text
AppKit global logical rect
  -> clip to NSScreen.frame
  -> ScreenGeometry.cocoaToQuartz
  -> subtract SCDisplay.frame origin
  -> ScreenCaptureKit sourceRect
  -> width/height multiplied by NSScreen.backingScaleFactor
```

Important current policy:

- A selection crossing displays is clipped to the display containing its center.
- Multiple and negative-origin display layouts must be verified with real hardware.
- The implementation currently uses `NSScreen.backingScaleFactor` for output sizing; mixed-scale and scaled-resolution behavior remain runtime test obligations.

## Current Browser Extension Architecture

```text
content.js
  -> semantic/X candidate with page and viewport rectangles
  -> if fully visible: versioned native request
       -> if not accepted: one captureVisibleTab + observed-scale crop
  -> if taller or partially offscreen: validate + plan bounded slices
       -> temporarily neutralize page motion and fixed/sticky interference
       -> for each slice: scroll, settle, request captureVisibleTab, crop at observed scale
       -> stitch into one local canvas
       -> restore page scroll and temporary styles
  -> local PNG download
```

`shared/core.js` supplies rectangle normalization/intersection, URL sanitization, versioned envelopes, semantic kind mapping, bounded slice planning, observed-image-scale pixel crop calculation, output-size validation, destination ranges, and safe filenames. Node tests exercise these pure functions. Background tests exercise the ordered long-capture handshake and rejection after active-tab or document changes.

The extension uses each captured image's actual width/height relative to viewport dimensions when calculating crop pixels; it does not assume `devicePixelRatio` is the capture scale. Browser capture is limited to 24 slices, 20,000 CSS pixels of target height, 16,384 pixels on either output axis, 32,000,000 output pixels, and 20 seconds. Targets wider than the available page viewport, inside nested scroll areas, or rooted in fixed/sticky containers are rejected. Navigation, resize, DOM/geometry changes, user scrolling, active-tab/document changes, and timeouts fail the session instead of returning a partial image.

## Current Safari Target State

The Xcode project embeds `SmartShotSafariExtension`, its manifest, scripts, and shared core. `SafariWebExtensionHandler` accepts native extension requests but deliberately returns:

```json
{
  "accepted": false,
  "handledBy": "browser"
}
```

This proves the target can be compiled, not that Safari DOM candidates reach or control the native app. The native app has no web provider, bridge coordinator, browser window mapper, or DOM coordinate conversion path. The shared extension contains a browser-local whole-block fallback, but the handler response alone does not prove that Safari runs `captureVisibleTab`, local stitching/download, and restoration successfully.

## Target Safari DOM-to-Native Architecture

The following is future design work:

```text
Safari DOM viewport CSS rectangle
  -> versioned native message
  -> message validation/freshness
  -> Safari tab and content-viewport mapping
  -> AppKit global logical rectangle
  -> CaptureCandidate(source: .webDOM)
  -> existing overlay/capture pipeline
```

### Target Unified Provider Protocol

When the bridge is implemented, providers should converge on the existing `CaptureCandidate` output or a versioned successor:

```swift
protocol CandidateProvider: Sendable {
    func candidates(at globalPoint: CGPoint) async -> [CaptureCandidate]
}
```

Moving current AX/window providers behind this protocol is optional refactoring; it must be justified by the Safari bridge rather than described as already complete.

### Target DOM Coordinate Mapping

`getBoundingClientRect()` returns CSS pixels relative to the browser viewport. It cannot be passed directly to ScreenCaptureKit. A valid bridge must account for:

- Safari content viewport origin inside its native window.
- Window position on the macOS desktop.
- Page zoom, `devicePixelRatio`, and `visualViewport` metrics.
- Toolbar/full-screen changes.
- Display scale and negative display origins.
- Stale messages after scroll, resize, navigation, or tab changes.

If the mapping cannot be established reliably, the app must decline the DOM candidate and retain AX/window/manual fallback.

### Target Message Boundary

Future native messages must be versioned, bounded, fresh, and treated as untrusted input. Allowed data should be limited to candidate geometry, semantic kind, viewport/session data, and an optional sanitized HTTP(S) URL. Post text, author labels, page titles, selectors, cookies, credentials, complete HTML, and browsing history are unnecessary for capture.

## Permissions and Degraded Modes

### Current

- Screen Recording is mandatory for native pixel capture.
- Accessibility improves native block selection but is not required for window/manual selection.
- Accessibility is mandatory for native **Automatic App Scroll (Experimental)** because it requires a writable AX scrollbar. Manual Long requires only Screen Recording.
- The app presents Screen Recording and Accessibility state/recovery controls.

### Experimental/Target

- Safari extension enablement and website access are required for the browser-local DOM path as well as any future native bridge; the browser-local path is implemented but still GUI-unverified in Safari.
- Because the native bridge is not implemented or GUI-verified, Safari permission recovery must not be described as a completed native workflow.

## Privacy and Security

- The native paths and current browser capture/stitch paths are local.
- SmartShot does not require a runtime network client for current capture behavior.
- Screenshot buffers remain in memory unless explicitly saved.
- Extension data is untrusted and must not be logged as page content.
- Current and future code should reject invalid/non-finite rectangles before capture.
- A future bridge must enforce schema version, message size, candidate count, string length, page/session identity, and recency.

## Current Module Map

```text
Sources/SmartShotApp
  SmartShotApp.swift
  Overlay/
  Services/AccessibilityScrollCaptureTarget.swift
  Services/AppModel.swift
  Services/GlobalShortcutMonitor.swift
  Services/PermissionService.swift
  Services/ScreenCaptureService.swift
  Services/ScrollingCaptureService.swift
  Views/MainView.swift

Sources/SmartShotCore
  Accessibility/
  Capture/CandidateFilter.swift
  Capture/ScreenGeometry.swift
  Capture/WindowCandidateProvider.swift
  LongCapture/
  Models/CaptureCandidate.swift

Sources/SmartShotSafariExtension
  SafariWebExtensionHandler.swift

BrowserExtension
  background.js
  content.js
  shared/core.js
  tests/background.test.js
  tests/core.test.js
```

## Known Architectural Gaps

| Gap | Status |
| --- | --- |
| Safari DOM candidate accepted by native app | Not implemented; handler returns `accepted: false`. |
| Safari DOM CSS-to-AppKit coordinate mapping | Not implemented. |
| Real Safari/X extension GUI verification | Not performed. |
| Browser DOM whole-block capture | Implemented and automated-tested; real Chrome/Safari + X E2E not performed. |
| Native `Automatic App Scroll (Experimental)` | Implemented with bounded AX/static/single-display scope; controlled runtime evidence recorded. |
| User-configurable shortcut | Implemented with validation, Carbon conflict rollback, persistence, and Restore Default. |
| Post-capture crop model/UI | Not implemented and outside v0.1. |
| General-purpose long screenshot across dynamic/infinite/virtualized/nested/cross-display content | Not implemented or promised. |
| Recording, OCR, annotation | Not implemented and outside v0.1. |
| Privileged real-device permission/display matrix | Outstanding verification work. |
| AX timeout/cancellation isolation | Future hardening. |
