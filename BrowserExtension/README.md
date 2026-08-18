# SmartShot Browser Extension

SmartShot's Manifest V3 WebExtension identifies semantic content blocks in Chrome and Safari. Everything stays on the Mac: the extension makes no network requests and only sends a selected candidate to the SmartShot native app when its native-messaging host is installed.

## Current workflow

1. Click the extension action to enter selection mode.
2. Hover a block. X posts (`article[data-testid="tweet"]`) are selected as one post; other pages prefer `article`, `main`, `section`, and semantic ARIA roles before generic layout blocks.
3. Use `Arrow Up` / `Arrow Right` or scroll down to select a larger ancestor. Use `Arrow Down` / `Arrow Left` or scroll up to return to a smaller block.
4. Click or press `Enter` to capture. Press `Escape` to cancel.
5. Blocks already inside the viewport use one fast browser capture. Taller or partially offscreen blocks use bounded scrolling capture: SmartShot scrolls through the selected DOM element, captures visible slices, crops them using the observed image-to-viewport scale, stitches one PNG, and downloads it locally.
6. The native app gets first refusal for the one-frame fast path. The browser handles multi-slice captures locally so it can coordinate scrolling and restore the page immediately.

Scrolling capture is limited to 24 slices, 20,000 CSS pixels in height, 16,384 pixels on either output axis, 32 million output pixels, and 20 seconds. A block wider than the viewport, nested inside another scroll area, or rooted in a fixed/sticky container is rejected rather than captured unreliably. The original scroll position and all temporary animation, fixed, and sticky styling are restored on success or failure. Navigation, selection geometry changes, viewport resizing, manual scrolling, changing the active tab, timeouts, and page-limit failures stop the capture with a visible error instead of returning a partial image.

## Load in Chrome or Edge

Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select this directory. Pin the extension action for one-click selection.

Chrome's native host manifest name must be `com.infinityf4p.smartshot`. Until that host is installed, capture automatically uses the local `tabs.captureVisibleTab` fallback.

## Convert for Safari

Use Apple's converter from the parent project directory:

```sh
xcrun safari-web-extension-converter BrowserExtension \
  --project-location SafariExtension \
  --app-name SmartShot \
  --bundle-identifier com.infinityf4p.SmartShot
```

The Safari native app identifier used by `sendNativeMessage` is `com.infinityf4p.SmartShot`. Safari packaging, signing, and Website Access permissions belong in the generated Xcode extension target.

## Native protocol

Every cross-component message is a JSON envelope:

```json
{
  "protocol": "com.infinityf4p.smartshot",
  "version": 1,
  "type": "capture.request",
  "requestId": "a-unique-id",
  "payload": {
    "candidate": {
      "pageRect": { "x": 120, "y": 850, "width": 600, "height": 420 },
      "viewportRect": { "x": 120, "y": 150, "width": 600, "height": 420 },
      "visibleViewportRect": { "x": 120, "y": 150, "width": 600, "height": 420 },
      "viewport": { "width": 1440, "height": 900 },
      "devicePixelRatio": 2,
      "url": "https://x.com",
      "kind": "x-post",
      "metadata": { "platform": "x" }
    }
  }
}
```

Only the HTTP(S) origin is retained; credentials, paths, query parameters, and fragments are removed. Page titles, post text, author labels, DOM selectors, cookies, and HTML are not sent to native messaging.

The native host should return this to claim the request:

```json
{
  "protocol": "com.infinityf4p.smartshot",
  "version": 1,
  "type": "capture.response",
  "requestId": "the-same-request-id",
  "payload": { "accepted": true, "handledBy": "native" }
}
```

Returning `accepted: false`, returning an invalid envelope, or having no native host installed invokes the browser fallback. The internal long-capture handshake uses the same request ID across `capture.long.begin`, ordered `capture.slice.request` messages, and `capture.long.end`; the background worker verifies that every slice still comes from the original active tab and document. Other internal types are `selection.toggle`, `selection.start`, `selection.stop`, `selection.state`, and `error`.

## Test

The shared geometry and protocol code has no dependencies:

```sh
npm test
```

No analytics, remote fonts, upload endpoints, fetches, or XMLHttpRequests are present.
