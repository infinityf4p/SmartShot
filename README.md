# SmartShot

SmartShot is a native macOS screenshot utility with one capture entry point for Smart blocks, dragged regions, and manual long captures. Static capture is the dependable path; bounded manual, native automatic, and browser scrolling capture are present with the limits below.

## Status

The native app currently supports macOS 14 or later and has been built and tested on Apple Silicon with Xcode 26.6.

| Capability | Status | Limit |
| --- | --- | --- |
| Manual visible-region capture | Implemented | Requires Screen Recording permission. |
| Smart blocks in macOS apps | Implemented | Depends on Accessibility permission and the target app's AX tree. |
| Unified Smart / Region / Long selector | Implemented, GUI verification in progress | One configurable shortcut opens all three modes. |
| Manual long capture | Implemented, GUI verification in progress | Drag one fixed region, scroll downward in small steps, then finish; 24 sections, 5 minutes, 16,384 px per side, and 32 million pixels. |
| Nested block cycling | Implemented | Use arrow keys or the scroll wheel during selection. |
| Global shortcut | Implemented | Configurable in Settings; changes are conflict-checked and persisted. |
| Full-screen app selection | Implemented | Non-activating overlays stay in the target app's full-screen Space. |
| Post-capture editor and output | Implemented, GUI verified | Crop, arrow, rectangle, text, mosaic, numbered markers, undo/redo, zoom, copy, pin, and PNG save. |
| 0 / 3 / 5 second delay | Implemented | Configurable in Settings and applied after selection. |
| Native `Automatic App Scroll (Experimental)` | Implemented, controlled runtime verified | One display; static AX scroll area with a writable vertical scrollbar; 24 fragments, 75 seconds, 16,384 px per side, and 32 million pixels. |
| Browser DOM whole-block capture, including X posts | Implemented, GUI unverified | Fully visible blocks use a fast path; taller/partially visible blocks are scrolled and stitched locally. Real Chrome/Safari + X end-to-end runs remain outstanding. |
| Safari DOM-to-native preview bridge | Not implemented | The Safari handler returns `accepted: false`; browser-local Safari capture is also not yet GUI-verified. |
| Recording and OCR | Not included | Tracked as separate roadmap work. |

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

Open `SmartShot.xcodeproj` in Xcode and select your development team to run a signed local build.

## Use The Native App

1. Launch SmartShot and allow Screen Recording when you are ready to capture.
2. Optionally allow Accessibility for smart block discovery in other apps.
3. Press the shortcut shown beside **Global Shortcut** (initially `Control-Shift-2`) or choose **Capture**. Change it in **SmartShot > Settings** by clicking the shortcut field and pressing a key with at least two modifiers.
4. Choose **Smart**, **Region**, or **Long** in the overlay. Smart highlights AX/window blocks and also accepts a drag; Region accepts a dragged rectangle.
5. Click or press Return to capture a Smart block, or drag to capture Region/Long. Press Escape to cancel.
6. In Long mode, scroll the selected content downward in small steps and pause after each step. Click **Done** after at least two sections have been accepted.
7. Crop or annotate the result with arrows, rectangles, text, mosaic, or numbered markers. Undo/redo and zoom are available; Copy, Pin, and Save render the edited PNG. Settings can add a 3/5 second delay, copy captures automatically, and optionally reveal SmartShot after captures started elsewhere.

If Accessibility is denied, window and manual-region capture remain available. If Screen Recording is denied, SmartShot can show settings and permission recovery but cannot produce an image.

The unified **Long** mode is the no-extension fallback for browsers and apps. It repeatedly samples the fixed rectangle while you scroll, accepts only stable frames with a verified vertical overlap, and rejects an unreliable seam instead of returning a partial success. It detects a conservative unchanged top strip so a stable fixed header is not duplicated, and it can finish automatically after an accepted movement followed by a new scroll attempt that reveals no new pixels. It does not know the hidden semantic boundary of a post or restore a manually changed scroll position.

For the separate automatic native path, choose **Automatic App Scroll (Experimental)**, then select an Accessibility scroll area. It works only when the whole capture area is on one display, the content remains static, and the target exposes a writable vertical AX scrollbar. It stops after 24 fragments or 75 seconds and rejects output above 16,384 pixels on either side or 32 million pixels total. SmartShot attempts to restore the original scroll position after success, failure, or cancellation and reports a restoration failure explicitly.

The privileged native path was verified on 2026-08-15 with a controlled static `NSScrollView`: the app produced a 2,688 x 8,724 pixel PNG containing fixture rows 001 through 240, and the same fixture process returned to its exact original AX scrollbar value after success. A forced timeout also restored that original value. This evidence does not broaden the supported-content limits below.

## Browser Extension

The Manifest V3 extension in [`BrowserExtension`](BrowserExtension/README.md) identifies generic semantic blocks and X posts. A fully visible block uses one `tabs.captureVisibleTab` capture. For a taller or partially offscreen DOM element, the extension scrolls the page, captures and crops visible slices using the observed image-to-viewport scale, stitches a single PNG, restores the page, and downloads the result locally. The bounded long path rejects unsupported nested scrolling and fixed/sticky-rooted targets instead of returning an unreliable image.

The extension geometry, stitching-plan, and protocol tests pass, but a real Chrome or Safari run against current X has not been recorded end to end. A Safari WebExtension target is embedded in the app and builds successfully. Its handler currently declines native import with `accepted: false`; that does not prove Safari's browser-local fallback, site access, download behavior, or X interaction.

The Safari extension does not currently place its result in SmartShot's native preview. That bridge needs shared-container import and signed runtime testing before it can be called supported.

The extension does not send post text, author labels, page titles, DOM selectors, cookies, credentials, HTML, or URL paths. Candidate messages retain only the HTTP(S) origin needed for a local filename.

## Privacy

- Screenshot processing and candidate detection are local.
- The project contains no analytics, upload endpoint, account, or cloud synchronization.
- Captures are kept in memory unless you explicitly save them.
- Accessibility values and screenshot pixels are not logged.

## Known Limits

- Manual long capture is bounded and seam-verified, not a general-purpose or automatic whole-document guarantee.
- Manual long capture requires downward scrolling with short pauses. A stable fixed top strip is handled conservatively, but changing sticky content, dynamic media, repeated/low-texture rows, large jumps, window movement, and direction changes can still be rejected.
- Native scrolling capture supports only static, single-display AX scroll areas with a writable vertical scrollbar. Dynamic or infinite content, virtualized lists, nested scrolling areas, and cross-display composition are not promised.
- Browser DOM whole-block capture is implemented, but real Chrome/Safari + X end-to-end verification remains outstanding. It does not automatically capture X threads or multiple posts.
- The editor does not yet provide blur, freehand drawing, shapes beyond rectangles/arrows, object removal, or irreversible semantic redaction. There is no video/audio recording, OCR, translation, or capture history.
- Canvas, games, remote desktops, and inaccessible apps may require manual selection.
- Manual selections are limited to the display where the drag begins; cross-display image composition is not included.
- Browser DOM-to-native geometry and non-100% browser zoom still require end-to-end verification.

## Documentation

- [MVP scope](Docs/MVP_REQUIREMENTS.md)
- [Architecture](Docs/ARCHITECTURE.md)
- [Test plan](Docs/TEST_PLAN.md)
- [Roadmap](Docs/ROADMAP.md)
