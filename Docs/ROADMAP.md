# SmartShot Roadmap

## Current Baseline: v0.1 Native MVP

Implemented baseline as of 2026-08-15:

- Native macOS 14+ SwiftUI/AppKit app.
- Configurable global capture shortcut with built-in launch fallback, conflict rollback, persistence, visible status, and retry.
- Non-activating selection overlays in other applications' full-screen Spaces.
- AX, visible-window, and manual visible-region candidates.
- Multi-display selection overlay and candidate cycling.
- ScreenCaptureKit still capture.
- One shortcut and overlay for Smart, Region, and manual Long modes.
- Bounded manual long capture with stable-frame sampling and seam verification.
- Read-only preview, pasteboard copy, pin-to-screen, and PNG save.
- Optional 0/3/5-second capture delay.
- Screen Recording and Accessibility permission UI.
- Embedded Safari WebExtension target that builds.
- Manifest V3 extension with semantic/X selection.
- Browser DOM whole-block capture with one-frame fast path, bounded page scrolling, observed-scale slice crops, local stitching, and restoration; real Chrome/Safari + X E2E remains outstanding.
- Native **Automatic App Scroll (Experimental)** for a static, single-display AX scroll area with a writable vertical scrollbar; overlap/stitching tests and a controlled privileged success/timeout-restoration run are recorded.
- Native and extension unit coverage described in `TEST_PLAN.md`.

Not in the baseline:

- Post-capture crop.
- General-purpose long capture for dynamic/infinite/virtualized/nested/cross-display content.
- Recording.
- OCR.
- Annotation.

The next native priority is runtime verification on real display and permission configurations, not feature expansion.

## Milestone 1: Native Runtime Hardening

Outcome: turn implemented native paths into evidence-backed support claims.

- Complete Retina, mixed-scale, negative-origin, and cross-display tests.
- Verify Screen Recording and Accessibility denial/recovery on current macOS.
- Verify AX/window/manual selection and overlay teardown under repeated use.
- Verify preview, copy, PNG save, and save failure/cancellation from a signed build.
- Expand native **Automatic App Scroll (Experimental)** evidence beyond the completed controlled success/timeout-restoration run to cancellation, hard-limit, restoration-failure, and real-application cases.
- Verify default, fallback, retry, and foreground delivery with real keyboard input and competing apps.
- Verify shortcut recording and persistence across keyboard input sources on signed builds.
- Move potentially slow AX work behind measured cancellation/timeout boundaries if required.
- Record a compatibility matrix with exact macOS/hardware evidence.

Exit gate: no known stuck-input, wrong-display, captured-overlay, or privacy defect in the tested matrix.

## Milestone 2: Safari DOM-to-Native Bridge

Outcome: make Safari semantic blocks real native capture candidates.

- Replace the handler's unconditional `accepted: false` response with validated routing.
- Add a session-aware native message decoder.
- Map Safari DOM CSS rectangles through browser content coordinates into AppKit global points.
- Reject stale candidates after scroll, resize, navigation, or tab changes.
- Feed accepted DOM candidates into the existing selection/capture pipeline.
- Preserve AX/window/manual fallback when the extension or mapping is unavailable.
- Verify Safari extension enablement and site-access recovery.
- Run the Safari zoom/window/display matrix in `TEST_PLAN.md`.

Until this exit gate passes, Safari DOM integration remains Experimental.

## Milestone 3: X Single-Post Hardening

Outcome: promote browser-local X-post whole-block capture only after real-site evidence, while keeping the native-preview bridge as a separate gate.

- Replace dependence on `article[data-testid="tweet"]` as the sole special-case signal with multiple semantic signals.
- Add sanitized fixture coverage for text, media, quoted posts, replies/reposts, timelines, detail pages, localization, and DOM changes.
- Test current public X in Chrome and Safari without publishing private timeline evidence.
- Confirm one-frame behavior for a visible post and bounded scrolling/stitching for a post taller than the viewport.
- Verify seam quality, fixed/sticky handling, page restoration, tab/navigation/mutation errors, and all capture limits.
- Document sticky overlays, dynamic media, login state, and site-change limitations.

This milestone still does not include automatic X thread/multi-post capture and does not promise dynamic/infinite/virtualized content.

## Milestone 4: Workflow Enhancements

Candidates after native and Safari correctness are established:

- Local history with explicit retention controls.
- Output naming and appearance presets.
- Shortcuts, URL scheme, or CLI automation.
- Optional source metadata export with explicit privacy controls.

Post-capture cropping may be evaluated here, but it is neither implemented nor promised for v0.1.

## Research Track: Long-Capture Hardening

Three bounded paths now exist: manual Long, browser DOM whole-block capture, and native **Automatic App Scroll (Experimental)**. None is evidence of general-purpose long-screenshot compatibility.

Research questions:

- Can DOM segments remain stable during automated scrolling?
- Can layout, lazy media, sticky elements, and animation be reconciled without missing or duplicate seams?
- Can SmartShot cancel safely and restore the original scroll position?
- Can it distinguish a visible-only capture from a complete long capture without ambiguity?
- Which applications expose a stable, writable vertical AX scrollbar and static pixels suitable for the native path?
- Can virtualized, nested, infinite, or cross-display content ever meet a deterministic support contract?

Only the current bounded contracts may be claimed. Promotion requires controlled fixtures and real-site/application cases demonstrating repeatable stitching and restoration; unsupported categories remain excluded until separately designed and verified.

## Separate Future Tracks

### OCR and Privacy Assistance

- On-device Vision OCR.
- Searchable local history.
- Sensitive-pattern detection.
- Irreversible redaction.
- Explicit translation provider/privacy design.

### Recording

- ScreenCaptureKit video.
- System audio, microphone, camera, cursor/click display, trimming, and GIF export.

### Annotation

- Arrow, rectangle, text, numbered steps, blur/mosaic, and redaction.

These tracks need separate architecture and tests. They are not partial v0.1 capabilities.

## Prioritization Rules

1. Fix wrong-region, wrong-display, privacy, crash, and stuck-input defects first.
2. Prefer a reliable manual/window fallback over an inaccurate smart detector.
3. Separate code presence, automated evidence, GUI runtime proof, and roadmap intent.
4. Keep site-specific detectors isolated and fixture-tested.
5. Do not market a building target as a working integration.
6. Add permissions only for an implemented user-visible capability.
7. Keep current capture local and retention explicit.
