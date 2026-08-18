# SmartShot v0.1 MVP Requirements

## Status Legend

This document separates the implementation snapshot from intended follow-up work.

- **Current**: present in the native app or browser extension as of 2026-08-15.
- **Verified**: exercised by the automated or runtime evidence named in `TEST_PLAN.md`.
- **Experimental**: present, but the relevant end-to-end user path is not verified.
- **Target**: a requirement for a later milestone, not a current capability.

## Product Goal

SmartShot is a native macOS utility for capturing an interface block without drawing every boundary by hand. Its dependable fallback is a manually dragged visible region. Native scrolling capture and browser DOM whole-block capture are bounded, Experimental additions rather than a general-purpose long-screenshot promise.

The current native workflow is:

1. Start capture from the app, menu bar, menu command, or the registered global shortcut shown in the sidebar. The initial default is `Control-Shift-2`; `Control-Option-2` is its built-in conflict fallback.
2. Choose Smart, Region, or Long in the same selection overlay.
3. Point at an Accessibility/window candidate in Smart mode, or drag a rectangle in any mode.
4. Capture a static region immediately, or manually scroll a fixed Long region while SmartShot accepts seam-verified stable sections.
5. Preview, copy, pin, or save the original captured PNG.

There is no post-capture crop editor. The selected source rectangle determines the output bounds.

## Current Native Scope

### Platform and Shell

- macOS 14 or later.
- Native SwiftUI application with AppKit interaction windows.
- Main app window plus a menu-bar extra.
- Global shortcut registration starts after the app window appears.
- The default shortcut is `Control-Shift-2`; if the currently selected built-in shortcut is occupied at launch, SmartShot attempts the other built-in combination and persists the active choice.
- Settings records a custom shortcut with at least two standard modifiers. The new combination is registered and persisted before the previous registration is released, so conflicts leave the old shortcut active.
- The sidebar reports the active shortcut, a conflict, or the Carbon registration error and offers a retry action.
- Capture overlays use non-activating panels in other applications' full-screen Spaces. Successful external captures stay in the current Space unless the user enables the preview setting.

### Selection

- Accessibility candidates from the macOS AX hierarchy when Accessibility permission is granted.
- Visible window candidates from the Core Graphics window list.
- Manual visible-region selection by dragging.
- One transparent overlay window per active display.
- Pointer hover highlighting.
- Arrow-key or scroll-wheel cycling through nested candidates.
- Click or Return to confirm; Escape to cancel.
- A compact native toolbar switches between Smart, Region, and Long without invoking another shortcut.

If Accessibility permission is denied, window and manual-region capture remain available.

### Static Capture and Output

- ScreenCaptureKit still-image capture of the selected source rectangle.
- The SmartShot process is excluded from the capture filter.
- The selection is clipped to the display containing its center.
- The output dimensions are derived from the selected region and display backing scale.
- Captured image preview in the main app.
- Copy to the system pasteboard.
- Pin the latest capture in a local floating window.
- Save as PNG through the standard save panel using an atomic write.
- Optional 0, 3, or 5 second delay after selection and before pixel capture.

The preview is read-only. v0.1 does not provide crop handles, crop reset, or any post-capture pixel editing.

### Manual Long Capture

The unified **Long** mode is implemented as a bounded, user-driven capture:

- The user drags one fixed rectangle on a single display. No browser extension or writable AX scrollbar is required.
- After the selection overlay is removed, the target application remains interactive and the user scrolls downward manually.
- SmartShot waits for stable frames, verifies vertical pixel overlap, retains only newly revealed rows, and stitches locally.
- A non-activating HUD reports accepted section count and provides Done/Cancel without entering the screenshot.
- Capture is bounded to 24 fragments and 5 minutes. Output is limited to 16,384 pixels on either axis, 20,000 logical points high, and 32,000,000 pixels total.
- Identical frames are ignored. Large jumps, upward scrolling, dynamic/sticky content, geometry changes, and unverified overlaps fail explicitly rather than producing a claimed complete image.

Manual Long does not infer a hidden DOM/AX block boundary, auto-scroll, or restore the position changed by the user. A long X post can be captured by drawing the fixed content-column region and scrolling it, but automatic whole-post boundary detection beyond the visible viewport remains separate browser/semantic work.

### Automatic App Scroll (Experimental)

The native app retains a separate **Automatic App Scroll (Experimental)** command. Its current support contract is deliberately narrow:

- The selected candidate must resolve to an Accessibility `AXScrollArea` with a vertical `AXScrollBar` whose `AXValue` is writable.
- The complete visible scroll area must remain on one display.
- The application, window, AX geometry, scrollbar range, and captured content must remain static while capture is running.
- SmartShot drives the vertical scrollbar, captures the same visible scroll viewport with ScreenCaptureKit, verifies overlap, and stitches the fragments vertically.
- Capture is bounded to 24 fragments and 75 seconds. The output is limited to 16,384 pixels on either axis and 32,000,000 pixels total.
- The original scrollbar position is restored after success, failure, or cancellation. Failure to restore is surfaced as an explicit error.

A controlled static native `NSScrollView` run on 2026-08-15 verified the privileged success path, a 2,688 x 8,724 pixel PNG spanning fixture rows 001 through 240, exact same-process scrollbar restoration after success, and exact restoration after a forced timeout. This evidence does not imply support for other application classes.

This path does not promise support for dynamic or infinite feeds, virtualized lists, nested scroll areas, cross-display areas, horizontal scrolling, or content whose pixels change during capture. These are unsupported-boundary statements, not untested claims of compatibility.

### Permissions

| Capability | Permission | Current Behavior When Missing |
| --- | --- | --- |
| Pixel capture | Screen Recording | The app requests access, reports failure, and cannot produce a screenshot. |
| AX block detection | Accessibility | AX candidates are omitted; window and manual candidates remain available. |
| Manual Long | Screen Recording | The selected area remains interactive after selection; AX access is not required. |
| Automatic App Scroll (Experimental) | Screen Recording and Accessibility | Capture cannot begin without both; the target must also expose a writable vertical AX scrollbar. |
| Global shortcut | None beyond normal app execution | The sidebar reports registration state; Settings validates, conflict-checks, and persists changes. |

The current app exposes permission state and recovery actions for Screen Recording and Accessibility. Permission behavior still needs the real denial/recovery matrix in `TEST_PLAN.md` before it is described as fully verified.

## Current Browser Extension Scope

The Manifest V3 WebExtension currently contains:

- Generic semantic element selection.
- X-post detection centered on `article[data-testid="tweet"]`.
- Nested element cycling and an in-page highlight.
- A one-frame `tabs.captureVisibleTab` fast path for blocks already inside the viewport.
- Bounded page scrolling and visible-slice capture for a taller or partially offscreen DOM element.
- Pixel cropping based on the actual captured image-to-viewport scale, followed by local vertical canvas stitching.
- Local PNG download.
- HTTP(S) origin only; credentials, path, query, and fragment are removed.
- No post text, author label, page title, selector, cookie, credential, or HTML in the current candidate message.

The browser long path is bounded to 24 slices, 20,000 CSS pixels in element height, 16,384 pixels on either output axis, 32,000,000 output pixels, and 20 seconds. It rejects an element wider than the scrollable viewport, a target inside a nested scroll area, and a target rooted in a fixed/sticky container. It temporarily neutralizes relevant scrolling/animation and fixed/sticky interference, then restores page scroll and styles on success or failure. Navigation, tab/document changes, resize, manual scroll, geometry changes, timeout, and limit failures stop with an error rather than a partial success.

The shared extension geometry and protocol tests pass, including slice planning, observed-image-scale crop calculation, output bounds, ordered capture handshakes, and tab/document-change failures. No real Chrome or Safari + X browser GUI end-to-end record is included yet.

## Experimental Safari/X Scope

The Safari WebExtension target is embedded in the Xcode project and builds. That build fact does not establish a working native smart-capture path.

Current limitations:

- `SafariWebExtensionHandler` deliberately returns `accepted: false`.
- The handler does not translate DOM candidates into the native app's `CaptureCandidate` pipeline.
- DOM-to-AppKit global coordinate mapping is not implemented in the native app.
- Real Safari extension enablement, site access, X page selection, native messaging, and screenshot GUI behavior have not been verified.

Therefore Safari DOM-to-native selection and X single-post capture are **Experimental**, not a supported native v0.1 capability. The browser-local whole-block path exists in the shared extension, but returning `accepted: false` does not by itself prove that Safari executes its `captureVisibleTab`, stitching, download, and restoration workflow correctly.

The desired X flow remains a future target: hover a visible loaded post, select its DOM article boundary, hand it to the native overlay/capture pipeline, and capture matching pixels. It must not be marketed as implemented until the bridge and real GUI tests pass.

## Privacy Boundaries

- Native screenshots and AX/window candidates are processed locally.
- Browser extension selection, slice capture, stitching, and download are local.
- The current project has no analytics, upload endpoint, account system, or cloud synchronization.
- Native captures remain in memory unless the user saves them.
- Logs must not contain screenshot pixels, post text, full AX values, cookies, credentials, HTML, or source URLs with query/fragment data.
- Future Safari native messages must be treated as untrusted input and limited to geometry, kind, protocol/session data, and an optional sanitized URL.

## Explicit Non-Goals for v0.1

- General-purpose or unbounded long-screenshot capture across dynamic/infinite/virtualized/nested/cross-display content.
- Automatic X thread, conversation, or multi-post capture.
- Screen recording, system audio, microphone, camera, or GIF export.
- OCR, translation, QR recognition, text search, or automatic sensitive-data detection.
- Annotation tools, blur, mosaic, arrows, text boxes, object removal, or redaction.
- Post-capture cropping or other image editing.
- Screenshot history, cloud upload, sharing links, accounts, or sync.
- Guaranteed recognition of Canvas, games, remote desktops, video surfaces, or inaccessible app content.

## Current Acceptance Boundary

The current native MVP can be described as implemented when referring to the unified Smart/Region/Long overlay, AX/window/manual visible-region selection, ScreenCaptureKit still capture, bounded manual long stitching, capture delay, read-only preview, pin, pasteboard copy, and PNG save. Automatic native scrolling may only be described as **Automatic App Scroll (Experimental)** with its AX/static/single-display requirements and hard limits.

Browser DOM whole-block capture may be described as implemented in code and automated-tested, but not real-browser/X verified. It must not be described as fully runtime-verified across all machines until the native and browser manual matrices in `TEST_PLAN.md` are recorded. Safari DOM/X native capture must remain Experimental until its bridge and real Safari/X GUI path are implemented and verified.
