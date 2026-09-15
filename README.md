<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="80" height="80" alt="SmartShot icon">

# SmartShot

**Capture, annotate, and record on macOS.**

SmartShot combines smart block selection, region and long screenshots, an image editor, on-device OCR, and screen recording in a native macOS app. Capture processing stays on your Mac: no account, analytics, or cloud upload service.

[English](README.md) | [简体中文](README.zh-CN.md)

macOS 14+ · Swift 6 · Preview version 0.2.3

## Features

| Workflow | What you can do |
| --- | --- |
| Screenshot | Select a window or accessible content block, cycle nested candidates, or drag a region. Use a configurable global shortcut and optional capture delay. |
| Long capture | Stitch a fixed region while scrolling manually; use **Automatic App Scroll (Experimental)** for compatible native scroll areas; capture a whole webpage content block with the browser extension. |
| Edit | Crop, draw, add arrows, rectangles, ellipses, text, and numbered markers. Apply mosaic, blur, opaque redaction, spotlight, or magnifier effects. Move/delete annotations, undo/redo, and zoom from 100% to 400%. |
| OCR and redaction | Recognize text locally with Apple Vision, copy it, or cover recognized text. Sensitive-text assistance detects supported email, phone, payment-card, and Chinese-ID patterns. Review its results before sharing. |
| Save and pin | Copy the rendered screenshot, pin it above other windows, save PNG/JPEG, or Quick Save to a chosen folder. **Flatten** replaces the current image and its history copy with the rendered edits. |
| History and privacy | Browse, search, reopen, and manage local history. OCR search is opt-in. Private screenshots skip automatic history and clipboard copies while keeping explicit output actions available. |
| Record | Record a region or the current display to MP4, with optional system audio, microphone, and pointer. Choose 15/30/60 fps and a 1920/2560/3840-pixel maximum edge. Preview, Save As, or export a GIF. |
| Automate | Trigger capture, Quick Save, or Show through a URL scheme or the bundled command-line launcher. |

## Download

[SmartShot 0.2.3 Preview](https://github.com/infinityf4p/SmartShot/releases/tag/v0.2.3) supports Apple Silicon and Intel Macs in one universal application.

- [macOS DMG](https://github.com/infinityf4p/SmartShot/releases/download/v0.2.3/SmartShot-0.2.3-universal.dmg)
- [macOS ZIP](https://github.com/infinityf4p/SmartShot/releases/download/v0.2.3/SmartShot-0.2.3-universal.zip)
- [Browser extension ZIP](https://github.com/infinityf4p/SmartShot/releases/download/v0.2.3/SmartShot-Web-Selector-0.2.3.zip)
- [SHA-256 checksums](https://github.com/infinityf4p/SmartShot/releases/download/v0.2.3/SHA256SUMS.txt)

This preview is ad-hoc signed, without a Developer ID certificate or Apple notarization. macOS may block a downloaded copy until you explicitly approve it in Finder or Privacy & Security. The packaged app has no `get-task-allow` debugging entitlement. Safari development enablement and the pending acceptance cases below still apply.

## Get Started

1. Download the DMG or ZIP, place `SmartShot.app` in `/Applications`, and launch it. Alternatively, build from source below.
2. Allow **Screen Recording** for screenshots and video. **Accessibility** enables smart content-block selection; manual regions remain available without it. Microphone access is separate and optional.
3. Use **Capture** or the shortcut displayed in the app. Choose **Smart**, **Region**, **Long**, or **App Scroll**; press Escape to cancel.
4. Edit the result, then Copy, Pin, or Save. **Save** writes directly to the configured folder; its adjacent arrow opens the save dialog. Use the close button to return to the initial view. For video, choose **More > Record Region** or **Record Current Display**. Stop saves an MP4; Cancel discards the recording.

The initial native shortcut is `Control-Shift-2`. If it conflicts with another app, use the shortcut shown in SmartShot or change it in Settings.

## Build Locally

Requirements: macOS 14+, Xcode with Swift 6 support, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Node.js for browser tests. The current checkout has been tested on Apple Silicon with Xcode 26.6.

```sh
git clone https://github.com/infinityf4p/SmartShot.git
cd SmartShot
xcodegen generate

xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
  -configuration Release -derivedDataPath DerivedData \
  build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

open DerivedData/Build/Products/Release/SmartShot.app
```

This command overrides the project's local signing identity with ad-hoc signing, so it does not require a Keychain signing certificate. It builds a local app with the same signing limitations as the preview download, not a Developer ID signed or notarized release. Different signatures can require new macOS permissions.

For Safari extension development, use the dedicated isolated build instead:

```sh
Scripts/build_safari_development.sh
```

The script verifies universal binaries and nested signatures, prints the app path, and leaves the existing `/Applications/SmartShot.app` untouched. Its debugging entitlements are for development only; do not distribute that artifact. See [Safari development setup](Docs/SAFARI_DEVELOPMENT_BUILD.md).

## Browser Extension

The extension selects one webpage content block and produces a PNG. It captures visible content directly or scrolls and stitches a bounded tall block, restores page state, then imports the image into SmartShot. If native import fails, it falls back to a browser download.

**Chrome / Chromium / Edge / Brave**

1. Install the complete normal app bundle at `/Applications/SmartShot.app`, then use **Settings > Chromium Integration > Install** to configure its native host.
2. Open the browser's Extensions page, enable Developer mode, and **Load unpacked** from the extracted browser extension ZIP or this checkout's `BrowserExtension` directory. Reload it after updating. The app's **Reveal Extension** button locates the copy packaged with an installed build.
3. Open a permitted webpage and invoke **SmartShot Web Selector** from the toolbar or `Control-Shift-9` on macOS. Select a block and confirm with a click or Return.

**Safari**

Safari requires a compatible Apple development signature or the dedicated **Sign to Run Locally** build. The latter requires **Settings > Developer > Allow unsigned extensions**, extension enablement, and Website Access; Safari resets the unsigned override when it quits. A normal ad-hoc or custom self-signed build is not sufficient on its own. Safari capture/import is still awaiting full runtime acceptance.

See the [extension guide](BrowserExtension/README.md) for installation, permissions, capture bounds, and native messaging details.

## Current Verification

The full automated suites were rerun on **2026-09-14**:

| Suite | Result |
| --- | --- |
| Native Swift tests | 205 passed, 0 failed, 0 skipped |
| Browser extension tests | 114 passed, 0 failed, 0 skipped |

Recorded runtime checks include controlled Chrome visible/long capture with native preview, OCR and sensitive-text redaction, history search, private-history suppression, pinning, editor refresh/crop/move/delete, PNG/JPEG output, system-audio recording, GIF export, and recording cancellation. These observations cover specific scenarios, not every supported configuration.

Still pending: the complete editor/output/privacy matrix, actual microphone recording, A/V sync, Safari capture/import, current public X compatibility, mixed displays/full-screen Spaces, and sustained recording/failure recovery. See the [test plan](Docs/TEST_PLAN.md) and runtime records for [September 5](Docs/ACCEPTANCE_2026-09-05.md) and [September 6](Docs/ACCEPTANCE_2026-09-06.md).

To run the tests:

```sh
xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData test CODE_SIGNING_ALLOWED=NO

npm --prefix BrowserExtension test
```

The destination above targets Apple Silicon. Use the appropriate macOS architecture on an Intel Mac. Automated tests do not exercise real permissions or prove browser installation.

## Scope and Privacy

- Long capture has three distinct paths: manual fixed-region scrolling, experimental native AX scrolling, and browser DOM-block capture. Native automatic scrolling requires static content and a writable vertical accessibility scrollbar. Dynamic/infinite feeds, virtualized or nested scrolling, horizontal capture, and cross-display stitching are outside the current support scope.
- Browser selection includes fixtures for a single X post. It does not automatically capture a thread or multiple posts, and compatibility with the current public X site is unverified.
- Recording uses one display. GIF export is silent and capped at the first 30 seconds, 15 fps, a 1280-pixel long edge, and 450 frames. Camera capture, video trimming, click visualization, translation, and cloud sharing/sync are not implemented.
- Screenshot history is local. OCR indexing is off by default and never applies to Private captures. Private screenshot mode does not govern recordings or browser fallback downloads.
- Blur and mosaic are visual effects. Use opaque redaction for sensitive content and inspect the exported image; OCR-based detection is not guaranteed to find every sensitive value.
- Browser native import carries the PNG and limited technical metadata, including the site origin. It does not transmit page HTML, cookies, credentials, or URL paths. Safari's current named-pasteboard transport has documented same-user authentication and crash-cleanup limitations in the [handoff](Docs/HANDOFF.md).

## Project Guide

- [Architecture](Docs/ARCHITECTURE.md)
- [Requirements and scope](Docs/MVP_REQUIREMENTS.md)
- [Roadmap](Docs/ROADMAP.md)
- [Test plan and evidence](Docs/TEST_PLAN.md)
- [Browser extension](BrowserExtension/README.md)
- [Safari development builds](Docs/SAFARI_DEVELOPMENT_BUILD.md)

Maintained by [infinityf4p](https://github.com/infinityf4p).
