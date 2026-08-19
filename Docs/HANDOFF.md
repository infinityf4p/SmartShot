# SmartShot Documentation Handoff

## Implementation Snapshot

Use this as the source-of-truth checklist when updating the root README or release notes.

| Capability | Current Classification | Exact Boundary |
| --- | --- | --- |
| Native AX/window/manual selection | Implemented | Runtime matrix still needs recorded verification. |
| Native static capture | Implemented | ScreenCaptureKit; visible region on one display. |
| Unified Smart/Region/Long overlay | Implemented, final GUI matrix in progress | One shortcut exposes all three modes. |
| Manual Long | Implemented, final GUI matrix in progress | Fixed one-display region; verified overlaps, conservative fixed-top handling, and automatic bottom finish after a no-movement scroll attempt. |
| Native crop/annotation editor and output | Implemented, editor GUI verified | Crop, arrow, rectangle, text, mosaic, numbered markers, undo/redo, zoom, copy, pin, and PNG save. |
| Capture delay | Implemented | Off, 3 seconds, or 5 seconds. |
| Global shortcut | Implemented | Configurable in Settings with validation, conflict rollback, and persistence. |
| Full-screen app overlay | Implemented | Non-activating panels preserve the target app/Space; external preview is opt-in. |
| Native `Automatic App Scroll (Experimental)` | Implemented, controlled runtime verified | Static, single-display AX scroll area with writable vertical scrollbar; bounded to 24 fragments/75 seconds/16,384 px per side/32M pixels. |
| Safari WebExtension target | Builds | Embedded target, not evidence of working DOM-to-native capture. |
| Safari DOM native bridge | Not implemented | Handler returns `accepted: false`; no native web provider or coordinate mapper. |
| Safari/X GUI path | Experimental/unverified | No real Safari/X end-to-end GUI evidence yet. |
| Browser DOM whole-block capture | Implemented, GUI unverified | One-frame fast path plus bounded page scroll/crop/stitch path; real Chrome/Safari + X E2E outstanding. |
| General-purpose long screenshot | Not implemented/promised | Dynamic/infinite/virtualized/nested/cross-display content is outside the current contract. |
| Recording/OCR/advanced redaction | Not implemented | Basic annotation is implemented; do not imply blur/object removal/semantic redaction. |

## README Rules

- Say `configurable shortcut` with `Control-Shift-2` initial default and transactional conflict rollback.
- Describe the post-capture editor exactly: crop, arrows, rectangles, text, mosaic, numbered markers, undo/redo, reset, and zoom; Copy/Pin/Save render the current edits.
- Describe AX/window/manual selection as implemented; qualify runtime support with the actual test record.
- Describe the Safari extension target as embedded and buildable.
- Describe Safari DOM-to-native integration and X native capture as Experimental/unverified.
- State explicitly that the handler returns `accepted: false` and the native bridge/coordinate mapping are absent.
- Describe browser DOM whole-block capture as implemented and automated-tested: one-frame fast path for visible blocks and bounded page scroll/crop/stitch for taller or partially offscreen blocks.
- State that real Chrome/Safari + X E2E is outstanding; do not infer Safari success from `accepted: false` or shared code alone.
- Distinguish unified **Long** (manual scroll, no AX requirement, no automatic scroll restoration) from **Automatic App Scroll (Experimental)** (AX/static/single-display requirements and restoration behavior).
- Keep general-purpose dynamic/infinite/virtualized/nested/cross-display long screenshots, recording, OCR, history, object removal, and semantic redaction in the absent/not-promised list.

## Suggested README Status Table

```text
| Capability | Status | Limit |
| Native AX/window/manual selection | Implemented | Real display/permission matrix still being recorded. |
| ScreenCaptureKit still capture | Implemented | Visible selection clipped to one display. |
| Crop/annotation editor, copy, pin, PNG save | Implemented | Basic local editor; no history, blur, object removal, or semantic redaction. |
| Unified Smart/Region/Long | Implemented, GUI matrix in progress | One shortcut opens all modes; manual Long does not require AX. |
| Global shortcut | Implemented | Settings recorder, persistence, conflict rollback, and Restore Default. |
| Native Automatic App Scroll (Experimental) | Implemented, controlled runtime verified | Static, one-display AX scroll area with writable vertical scrollbar; 24 fragments/75 seconds/16,384 px per side/32M pixels. |
| Browser DOM whole-block capture | Implemented, GUI unverified | Fast path plus bounded page scroll/crop/stitch; Chrome/Safari + X E2E outstanding. |
| Safari extension target | Experimental | Builds, but handler declines native requests. |
| Safari/X DOM-to-native capture | Not implemented | Bridge and GUI verification outstanding. |
| General-purpose long capture, recording, OCR, advanced redaction | Not included | Bounded long paths do not cover dynamic/infinite/virtualized/nested/cross-display content. |
```

## Current User Flow to Document

1. Launch the native app.
2. Grant Screen Recording for screenshots.
3. Optionally grant Accessibility for AX block detection.
4. Press the shortcut shown in the sidebar (normally `Control-Shift-2`) or choose Capture.
5. Choose Smart, Region, or Long in the bottom overlay toolbar.
6. Select a Smart block or drag a region; in Long, scroll downward in small steps and finish from the HUD if automatic bottom detection does not finish first.
7. Crop or annotate the result, then copy it, pin it, or save it as PNG.

Document **Automatic App Scroll (Experimental)** as a separate advanced command, not as an automatic behavior of Smart or manual Long. It requires both Screen Recording and Accessibility permissions and a selected AX scroll area with a writable vertical scrollbar. It captures a static viewport repeatedly on one display, stitches verified overlaps, and attempts to restore the original scrollbar value after success, failure, or cancellation. The hard limits are 24 fragments, 75 seconds, 16,384 pixels on either side, and 32,000,000 pixels total; restoration failure is an explicit error.

Controlled privileged-GUI evidence recorded on 2026-08-15: a static native `NSScrollView` produced a 2,688 x 8,724 pixel PNG with fixture rows 001 through 240 and restored the same process's AX scrollbar from and to `0.5790314500417478`. A forced timeout also restored that exact value. Native cancellation restoration remains covered by automated state-machine tests rather than a recorded GUI run.

## Permission Wording

| Missing Permission | Current Degraded Behavior |
| --- | --- |
| Screen Recording | Native screenshot cannot complete. |
| Accessibility | Window and manual candidates remain available. |
| Accessibility for Scrolling Capture | Experimental scrolling capture cannot select/control an AX scroll area. |
| Safari site access | Browser-local DOM capture is unavailable until extension access is granted; the Safari path remains GUI-unverified. |

Do not present Safari permission recovery as a completed native workflow until it has been GUI-tested.

## Browser Wording

The extension implements one-frame browser capture for a fully visible candidate and bounded scrolling capture for a taller or partially offscreen DOM element. The long path scrolls the page, captures ordered visible-tab slices, uses the actual image-to-viewport scale for cropping, stitches one PNG, restores scroll/styles, and downloads locally. It is limited to 24 slices, 20,000 CSS pixels of target height, 16,384 pixels per output side, 32,000,000 output pixels, and 20 seconds. It rejects targets wider than the available page viewport, inside a nested scroll area, or rooted in a fixed/sticky container.

Pure geometry/protocol tests pass, including slice planning and tab/document failure handling. Real Chrome/Safari + X GUI runs are still required. Do not describe the shared extension implementation as verified browser compatibility.

For Safari, keep these facts together:

- The extension target is embedded and builds.
- The handler returns `accepted: false`.
- DOM candidates do not enter the native selection pipeline.
- DOM CSS-to-AppKit coordinate mapping is absent.
- Real Safari/X GUI behavior has not been verified.

The shared code contains a Safari browser-local fallback, but do not infer that it works in Safari merely from Chrome behavior or from the handler's `handledBy: browser` label. Safari `captureVisibleTab`, download, page restoration, site access, and X interaction still need real GUI verification.

## Privacy Wording

Current extension tests establish that candidate messages omit page title, selector, author label, and post text, and retain only the HTTP(S) origin rather than credentials, path, query, or fragment. Current native capture is local and stored in memory unless explicitly saved.

Before making broader privacy claims, verify the release build and runtime logs. Never ask users to publish private X timelines, cookies, page HTML, full AX values, or URLs with sensitive parameters.

## Test Evidence to Link

- Native unit coverage: AX screen layout, Accessibility detector, candidate filter.
- Native long-capture unit coverage: overlap estimator, fixed-top detector, vertical stitcher, and manual completion policy; controlled AX/ScreenCaptureKit success and timeout restoration are recorded, while the broader real-app matrix remains outstanding.
- Browser unit coverage: geometry, slice planning, limits, sanitized URL, protocol, observed-scale crop, ordered session/tab/document failures, filenames.
- Chrome/Safari browser whole-block capture: GUI test outstanding; record browser version, X/fixture scenario, seams, restoration, and failure behavior for a public compatibility statement.
- Native privileged GUI matrix: outstanding unless a newer test record says otherwise.
- Safari/X real GUI matrix: outstanding.

Link to `Docs/TEST_PLAN.md` for detailed gates. Do not turn planned matrix items into check marks without a test record.

## Known Limitations List

- Basic post-capture crop and annotation editing is implemented; there is no persistent edit history, blur, freehand drawing, object removal, or semantic redaction.
- Native scrolling capture is Experimental and limited to a static, single-display AX scroll area with a writable vertical scrollbar.
- Browser DOM whole-block capture is implemented but still lacks real Chrome/Safari + X E2E verification.
- Dynamic/infinite content, virtualized lists, nested scrolling areas, cross-display composition, and general-purpose long capture are not promised.
- No automatic X thread/multi-post capture.
- No screen recording or audio.
- No OCR, translation, text search, or sensitive-data recognition.
- No capture history, cloud share, account, or sync; pinning is implemented.
- Canvas, games, remote desktops, and inaccessible content may require manual selection.
- Cross-display native selections are clipped to the display containing the selection center.
- Safari DOM/X native capture is not implemented.

## Documentation Map

- `MVP_REQUIREMENTS.md`: current scope, Experimental Safari boundary, privacy, and exclusions.
- `ARCHITECTURE.md`: current code path versus target DOM bridge.
- `TEST_PLAN.md`: existing evidence versus outstanding promotion gates.
- `ROADMAP.md`: hardening and future milestones.
- `BrowserExtension/README.md`: extension-specific developer instructions.

## Pre-Release Claim Audit

- [ ] Root README describes the configurable shortcut and full-screen Space behavior accurately.
- [ ] Root README describes the implemented editor and edited-output behavior accurately.
- [ ] Root README says Safari target builds but native bridge is absent.
- [ ] Root README does not call X/Safari DOM capture supported.
- [ ] Browser whole-block capture is described as implemented and automated-tested, with real Chrome/Safari + X E2E outstanding.
- [ ] Automatic native scrolling is named `Automatic App Scroll (Experimental)` and includes AX/static/single-display requirements, limits, and restoration behavior.
- [ ] Native runtime claims cite the actual GUI matrix performed.
- [ ] Browser claims cite browser/version and actual test performed.
- [ ] General-purpose dynamic/infinite/virtualized/nested/cross-display long capture remains unpromised; recording, OCR, history, object removal, and semantic redaction remain excluded.
- [ ] No architecture target is presented as current code.
