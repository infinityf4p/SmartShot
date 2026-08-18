# SmartShot Test Plan and Evidence

## Evidence Labels

- **Passed automated**: a checked-in automated test was run successfully.
- **Implemented, unverified runtime**: code exists, but the real privileged GUI path has not been proven by the available evidence.
- **Experimental**: component builds or works in a narrower environment, but the advertised end-to-end path is incomplete or unverified.
- **Planned**: a future test required before the capability can be promoted.

This document does not convert planned cases into passing claims.

## Current Evidence Snapshot

### Passed Automated

The current native unit suite covers:

- AX/AppKit screen-coordinate adaptation (`AXScreenLayoutTests`).
- Accessibility role, hierarchy, and candidate behavior (`AccessibilityBlockDetectorTests`).
- Candidate clipping, minimum size, deduplication, and ordering (`CandidateFilterTests`).
- Vertical overlap estimation, including changing pixels and seam placement (`VerticalOverlapEstimatorTests`).
- Vertical fragment layout/stitching and size/error boundaries (`VerticalImageStitcherTests`).
- Unified selector mode order, distinct presentation, and accessible help (`CaptureSelectionModeTests`).

The current browser-extension Node suite covers:

- Viewport intersection.
- Page, viewport, and visible viewport candidate geometry.
- URL minimization to HTTP(S) origin only.
- X-post semantic kind mapping.
- Versioned protocol envelopes.
- Fast-path and long-path classification.
- Bounded vertical slice planning and output-size validation.
- Capture pixel crops using observed bitmap scale and seam-free destination ranges.
- Ordered long-capture handshakes and rejection after active-tab or document changes.
- Safe output filenames.

The browser DOM whole-block workflow is implemented and its geometry/protocol logic is automated-tested. Fully visible targets use one capture; taller or partially offscreen targets use bounded scrolling, slice capture, local stitching, and restoration. A recorded Chrome or Safari + X browser GUI run is still required before publishing a compatibility claim.

### Implemented, Unverified Runtime

The following native paths exist but still require a recorded real macOS GUI matrix:

- Delivery of the global shortcut while another app is frontmost. A 2026-08-13 launch check confirmed that Carbon registration returned success and the app displayed `Control-Shift-2`; this does not replace the frontmost-app keypress test.
- Multi-display overlay.
- AX/window/manual selection.
- ScreenCaptureKit capture with SmartShot excluded.
- Read-only preview.
- Pasteboard copy.
- PNG save and save cancellation/failure behavior.
- Unified Smart/Region/Long toolbar interaction.
- Manual Long fixed-region sampling, target-app scrolling, finish/cancel HUD, and final pinned preview.
- 3/5-second countdown and pinned-window behavior across Spaces.
- Screen Recording and Accessibility denial/recovery.
- Native **Automatic App Scroll (Experimental)** against a real third-party AX scroll area, including restoration after success/failure/cancellation.

### Experimental, Not End-to-End Verified

- The Safari WebExtension target is embedded and builds.
- `SafariWebExtensionHandler` returns `accepted: false`; it does not bridge candidates into the native app.
- Real Safari extension enablement, site access, X selection, native messaging, DOM global geometry, and resulting GUI screenshot have not been verified.

Safari/X tests below are promotion gates, not current pass results.

## Native Automated Test Plan

### Geometry

- Expand table-driven tests for main displays above, below, left, and right of secondary displays.
- Cover negative X/Y origins, 1x/2x scale, scaled resolutions, and rectangles touching display edges.
- Verify AppKit-to-Quartz conversion and display-local source rectangles.
- Verify the current center-display clipping policy for a cross-display candidate.
- Reject NaN, infinity, zero/negative sizes, and off-desktop rectangles.
- Verify pixel dimensions from actual ScreenCaptureKit results where a privileged integration harness is available.

### AX, Window, and Candidate Selection

- Continue fixture tests for nested AX roles, missing attributes, duplicate frames, tiny elements, and partial hierarchies.
- Add a controlled test application exposing known AX element frames.
- Verify window fallback when Accessibility is denied or an AX tree is incomplete.
- Verify arrow and scroll cycling order matches the area-sorted candidate array.
- Verify late/debounced updates cannot revive an overlay after teardown.
- Measure synchronous AX inspection and add timeout/cancellation architecture if it can block interaction.

### Native Capture and Export

- Capture a high-contrast synthetic window and compare all four result edges.
- Confirm the SmartShot overlay and app windows are absent from the bitmap.
- Verify copied image dimensions and representative pixels.
- Verify PNG dimensions and pixels after save/reopen.
- Verify an atomic save failure leaves the last preview available.
- Verify cancelling `NSSavePanel` writes no file.

There are no post-capture crop tests because the native app has no post-capture crop feature.

### Manual Long Capture

The manual Long path reuses the automated overlap/stitcher coverage, but its ScreenCaptureKit polling and user-driven scroll workflow require GUI evidence:

- Start from the unified shortcut, switch Smart -> Region -> Long, and verify each mode accepts only the intended click/drag behavior.
- Draw a fixed region over a controlled static numbered list, scroll downward by less than one viewport, pause, repeat, and finish. Verify every numbered row appears once and seam error is no more than one pixel.
- Verify the overlay disappears before scrolling, the pointer and target application remain usable, and the non-activating HUD does not enter any fragment.
- Verify Done is disabled until at least two accepted sections; Cancel produces no output and removes the HUD.
- Verify identical frames do not increment the section count.
- Verify upward scrolling, a jump larger than the available overlap, dynamic pixels, sticky content inside the rectangle, target/window movement, and scale/width changes fail explicitly.
- Verify 24-section, 75-second, 16,384-pixel-axis, 20,000-logical-point-height, and 32-million-pixel limits.
- Verify manual scrolling is not claimed to restore the target position.
- On a public X long post, select only the center content column, scroll in small steps, and inspect every seam. Record this as a manual region result, not automatic semantic whole-post recognition.

### Automatic App Scroll (Experimental)

Automated overlap and stitcher tests do not establish the privileged AX + ScreenCaptureKit workflow. Record these cases with a controlled native test app before broadening the claim:

Recorded on 2026-08-15 with a controlled static native `NSScrollView`: the success path saved a 2,688 x 8,724 pixel PNG containing fixture rows 001 through 240, and the same fixture PID restored its AX scrollbar exactly to `0.5790314500417478`. A forced timeout also restored the same value. A GUI cancellation run remains outstanding because the automation pointer overlay changes captured pixels; cancellation and termination restoration remain covered by automated tests.

- Select a static `AXScrollArea` exposing a writable vertical `AXScrollBar`; verify the stitched bitmap starts at the top, reaches the verified end, and has no missing or duplicated seam rows.
- Start from the middle of the area and verify success restores the exact original scrollbar value within the implementation tolerance.
- Cancel during capture; verify no PNG is produced and the original scrollbar value is restored.
- Force timeout, changing pixels, unreliable overlap, no scrollbar progress, window/frame movement, app/frontmost change, and output-limit failures; verify each fails explicitly and attempts restoration.
- Force a restoration failure separately and verify it is reported instead of claiming restoration.
- Verify the hard bounds: no more than 24 fragments, no more than 75 seconds, neither output axis above 16,384 pixels, and no output above 32,000,000 pixels.
- Place any part of the scroll area outside its display and verify selection is rejected rather than clipped or composed across displays.
- Verify a missing, read-only, invalid, or horizontal-only AX scrollbar is rejected.

Compatibility probes for dynamic/infinite content, virtualized lists, nested scroll areas, horizontally scrolling content, and multi-display areas must be recorded as unsupported investigations, not release support. Static content that changes between frames must fail rather than produce a best-effort stitch.

### Shortcut

- Verify `Control-Shift-2` works with another app frontmost.
- Occupy `Control-Shift-2`, relaunch, and verify that the sidebar reports and receives `Control-Option-2`.
- Occupy both shortcut candidates, verify the conflict state, release them, and verify Retry registers successfully.
- Record a custom shortcut, restart the app, and verify the same hardware key code and modifiers are registered.
- While recording, enter the currently active shortcut and verify the recorder receives it without starting capture.
- Occupy a custom candidate with Carbon and verify the old registration and persisted value remain unchanged.
- Verify the action does not repeat from key repeat.
- Verify registration and event handlers are removed on teardown/termination.
- Verify a missing Screen Recording permission brings the SmartShot window and recovery message to the foreground after shortcut delivery.

The automated App tests exercise real Carbon registration for successful replacement, restart persistence, conflict rollback, invalid input, event identifiers, and recording-time release/restore.

## Native Manual Matrix

Record app build, macOS build, hardware, display layout, scaling mode, and initial permission state.

### Displays and Retina

| ID | Configuration | Checks |
| --- | --- | --- |
| D1 | Built-in Retina only | Overlay/result edge agreement, preview, copy, save. |
| D2 | External 1x display if available | No hard-coded 2x assumption. |
| D3 | Retina plus 1x external | Capture on each display after moving the target. |
| D4 | External display left of main | Negative-origin geometry. |
| D5 | External above or below main | Nontrivial Y-origin geometry. |
| D6 | Candidate crossing displays | Confirm clipping to the center-containing display. |
| D7 | Display disconnected during selection | Safe cancellation or explicit recovery. |

For each available display, capture a high-contrast block near each edge and at the center. Inspect the result at 100% pixel zoom. A one-pixel outward inclusion can be acceptable; content clipping or systematic offset is not.

### Native Selection Sources

- Finder or another accessible native application: verify AX child and parent candidates.
- An app with incomplete AX data: verify window fallback.
- Accessibility denied: verify window and manual selection.
- Drag at least 6x6 points: verify manual selection wins over the hovered candidate.
- Click without dragging: verify the current candidate is selected.
- Escape and repeated rapid start/cancel: verify no orphan overlays or trapped input.
- Switch Spaces, enter full screen, lock/unlock, and invoke Mission Control during selection; record behavior.

### Preview and Output

- Capture small, large, wide, and tall regions.
- Confirm preview aspect-fit does not change output resolution.
- Confirm the preview has Pin, Copy, and Save actions; there must be no claim of crop editing.
- Pin a normal and a tall capture. Verify the non-activating panel stays above other windows, joins another Space, scrolls tall content, closes cleanly, and is excluded from later captures.
- Set delay to Off, 3 seconds, and 5 seconds. Verify the countdown appears after selection, does not intercept the mouse, is excluded from the screenshot, and cancellation/termination removes it.
- Copy into Preview and Notes and confirm image compatibility.
- Save PNG to a writable folder and verify dimensions.
- Cancel save and try a non-writable destination.

### Permissions

#### Screen Recording

- Not determined: invoke capture and observe the explanation/system path.
- Denied: confirm no false successful screenshot.
- Granted after denial: return to the app and record whether relaunch is required.
- Revoked while running: the next capture must recheck permission and fail clearly.

#### Accessibility

- Denied: window/manual selection remains available.
- Granted after denial: AX candidates appear after the required refresh/relaunch.
- Revoked while running: no crash or stale AX-only candidate.

## Browser Extension Test Plan

### Chrome/Chromium Current Path

- Run `npm test` from `BrowserExtension`.
- Load the extension unpacked in a named Chromium/Chrome/Edge version.
- On a controlled fixture page, select generic nested blocks and cycle levels.
- Capture a fully visible block and verify it uses the one-frame fast path with exact DOM bounds.
- Capture a partially offscreen block and a block taller than the viewport; verify all selected DOM content is present once in the stitched PNG.
- Repeat with actual captured bitmap scale differing from a naive DPR assumption.
- Verify the metadata boundary contains no page title, selector, author label, post text, URL credentials, path, query, or fragment.
- Verify adjacent slices have no gaps or duplicated rows on a static fixture.
- Verify fixed/sticky page elements are not duplicated and all temporary page styles and the original scroll position are restored after success, failure, and cancellation.
- Verify navigation, resize, target mutation/geometry changes, user scroll, active-tab changes, document replacement, timeout, and output limits produce explicit errors and no partial PNG.
- Verify blocks wider than the available page viewport, nested scroll targets, and fixed/sticky-rooted targets are rejected.
- Run against current public X timeline/detail layouts and capture one tall `article[data-testid="tweet"]` without publishing private timeline content.

The code and automated tests implement this whole-block path, but a real Chrome + X GUI result has not yet been recorded.

### Safari Build Check

- Generate/open the Xcode project.
- Build the app and embedded `SmartShotSafariExtension` target.
- Inspect the product to confirm the extension target is embedded.

A successful build does not pass native messaging or GUI capture.

### Safari/X Promotion Gate

The browser-local whole-block fallback can be exercised before the native handler accepts a candidate. The following two result paths must be recorded separately:

- Enable the extension in Safari and grant website access.
- With the current `accepted: false` handler, verify the browser-local one-frame and multi-slice capture/download paths on controlled fixtures and current public X.
- Verify Safari restores scroll/styles and handles the same timeout, tab/navigation, mutation, fixed/sticky, nested-scroll, and size-limit cases as Chrome.
- Record Safari version, extension enablement, site access, page zoom, saved PNG dimensions, and non-sensitive seam evidence.

The native-preview promotion gate additionally requires:

- Confirm a versioned DOM candidate reaches the correct native capture session.
- Map DOM CSS geometry to AppKit global points.
- Verify 80%, 100%, 125%, 150%, and 200% Safari page zoom where available.
- Move/resize Safari, show/hide toolbars, scroll, navigate, and enter full screen.
- Test X public text, media, quoted-post, timeline, detail-page, light/dark, and logged-out layouts.
- Verify highlighted DOM article and resulting native bitmap match on every edge.
- Verify stale messages after scroll/navigation are rejected.
- Verify extension/site-access denial falls back to native AX/window/manual behavior without implying DOM support.

Until the browser-local cases pass, Safari whole-block download remains GUI-unverified. Until the native-preview cases pass, X single-post DOM-to-native capture remains Experimental.

## Long and Partially Visible Content

Current expected behavior:

- Standard native AX/window/manual capture still captures only the selected visible pixels on one display.
- Manual **Long** samples a fixed single-display rectangle while the user scrolls downward, accepts only stable seam-verified sections, and stays within 24 fragments, 5 minutes, 16,384 pixels per side, 20,000 logical points high, and 32,000,000 pixels total.
- Native **Automatic App Scroll (Experimental)** scrolls and stitches only a static, single-display AX scroll area with a writable vertical scrollbar, within 24 fragments, 75 seconds, 16,384 pixels per side, and 32,000,000 pixels total.
- The browser extension captures one selected DOM element in full when its bounded page-scrolling path is eligible; fully visible blocks use the fast path.
- Neither path promises dynamic/infinite feeds, virtualized lists, nested scroll areas, cross-display composition, or automatic X thread/multi-post capture.

Use controlled static fixtures for seam correctness and X only for a non-sensitive compatibility run. A changing/unsupported target must fail explicitly rather than be described as a complete long capture.

## Privacy Checks

- Search native logs for screenshot bytes, AX text values, full URLs, cookies, credentials, and HTML.
- Search extension messages for page title, selector, author label, post text, URL credentials, path, query, and fragment.
- Verify no runtime network request is required for native capture or browser-local capture/stitch/download.
- Inspect temporary locations after copy, save, cancellation, and failure; current native behavior should retain only in memory unless explicitly saved.
- Fuzz any future native bridge with malformed envelopes, oversized values, invalid numbers, stale timestamps, and mismatched sessions.

## Release/Claim Gates

### Native MVP Claim

Before calling the native app runtime-verified:

- Complete the relevant display and permission matrix.
- Verify AX/window/manual capture, preview, copy, and PNG save from the built artifact.
- Confirm no stuck overlay, wrong-display crop, or captured SmartShot UI.
- Record exact hardware and macOS version.

Before calling **Automatic App Scroll (Experimental)** runtime-verified, pass its controlled static AX matrix, restoration cases, and all hard-limit checks above. Do not generalize those results to dynamic, infinite, virtualized, nested, or cross-display content.

### Safari/X Claim

Do not call Safari browser-local X-post capture GUI-verified until real Safari + X fast-path and long-path downloads, page restoration, seams, and failures are recorded. Do not call Safari X-post capture supported in the native preview until:

- The handler accepts and forwards candidates to the native app.
- DOM-to-global coordinate mapping exists.
- Real Safari/X GUI tests above pass.
- Permission/site-access failure behavior is verified.

### Exclusion Claim

Every release description must distinguish the two bounded long-capture implementations from general-purpose long screenshots. It must state that dynamic/infinite/virtualized/nested/cross-display capture is not promised and that recording, OCR, annotation, and post-capture editing are absent.

## Test Record Template

```text
Date:
Build/commit:
Test type: automated / runtime manual
macOS and hardware:
Displays and scaling:
Browser and page zoom (if applicable):
Permissions at start:
Scenario:
Expected:
Observed:
Bitmap dimensions:
Non-sensitive evidence:
Pass / Fail / Not run:
```
