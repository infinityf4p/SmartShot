# SmartShot Browser Extension

SmartShot's Manifest V3 WebExtension identifies semantic content blocks in Chrome and Safari. Everything stays on the Mac: the extension makes no network requests and sends only the completed PNG plus bounded technical metadata to SmartShot when its native-messaging bridge is available. The selector is injected only after you click the toolbar action; it does not run persistently across every website.

## Current workflow

1. Click the extension action to enter selection mode. If an already-open HTTP(S) tab predates the extension load or reload, the action injects the same packaged selector scripts into that tab once and retries; ordinary pages do not need a reload.
2. Hover a block. X posts (`article[data-testid="tweet"]`) are selected as one post. Media, social context, and nested quoted-post content resolve to the outer post article; sibling replies remain separate and threads are not combined. Other pages start at the nearest layout block and let you climb through `article`, `main`, `section`, and semantic ARIA ancestors.
3. Use `Arrow Up` / `Arrow Right` or scroll down to select a larger ancestor. Use `Arrow Down` / `Arrow Left` or scroll up to return to a smaller block.
4. Click or press `Enter` to capture. Press `Escape` to cancel selection or an in-progress scrolling capture. Hiding, navigating away from, or closing the page also cancels capture and restores temporary page state.
5. Blocks already inside the viewport use one fast browser capture. Taller or partially offscreen blocks use bounded scrolling capture: SmartShot scrolls through the selected DOM element, captures each visible slice twice 120 ms apart, rejects materially changed pixels, crops using the observed image-to-viewport scale, and stitches one PNG for local delivery.
6. The browser finishes the PNG first, then uses a two-phase import for both one-frame and multi-slice results: the native bridge validates and stages the image, then SmartShot validates it and publishes the preview before the bridge returns final acceptance. SmartShot accepts only one outstanding browser import. If that path fails, the background worker downloads the completed PNG; a content-page download remains a second fallback when the downloads API is unavailable.

Scrolling capture is limited to 24 slices, 20,000 CSS pixels in height, 16,384 pixels on either output axis, 32 million output pixels, and 20 seconds including verification frames. Each slice compares a downsampled view of the selected pixels with a maximum 96-pixel edge. This is a fail-closed heuristic for common video, GIF, and canvas changes, not proof that every dynamic pixel is frozen; very slow or tiny changes can escape detection and compositor noise can cause rejection. The visible fast path remains single-frame. Native import accepts only PNG data up to 64 MB decoded and transfers base64 in ordered chunks no larger than 192 KiB. Before accepting the final stage, native code decodes the PNG, enforces pixel limits, and verifies that its aspect ratio matches the selected block's logical dimensions within the bounded rounding tolerance. A block wider than the viewport, nested inside another scroll area, or rooted in a fixed/sticky container is rejected rather than captured unreliably. The original scroll position and all temporary animation, fixed, and sticky styling are restored on success or failure. Navigation, selection geometry changes, viewport resizing, manual scrolling, changing the active tab, timeouts, and page-limit failures stop the capture instead of returning a partial image.

## Install in a Chromium browser

The current extension is loaded unpacked; it is not yet distributed through a browser store. Google Chrome, Chromium, Microsoft Edge, and Brave are supported by the native-host installer.

1. Install the complete app bundle at exactly `/Applications/SmartShot.app`, then launch it. A build run from Xcode's Derived Data directory cannot install the connector.
2. Launch each Chromium browser once so its Application Support directory exists.
3. In **SmartShot > Settings > Browser Integration**, click **Install**. This writes `com.infinityf4p.smartshot.json` into each detected browser's `NativeMessagingHosts` directory and points it at `/Applications/SmartShot.app/Contents/Helpers/SmartShotNativeHost`.
4. Click **Reveal Extension**. In the browser's extension page, enable Developer mode, choose **Load unpacked**, and select the directory containing the revealed `manifest.json`. If the reveal action is unavailable, the installed bundle's directory is `/Applications/SmartShot.app/Contents/PlugIns/SmartShot Safari Extension.appex/Contents/Resources`. A source checkout can select this `BrowserExtension` directory instead.
5. Use `chrome://extensions` for Chrome/Chromium, `edge://extensions` for Edge, or `brave://extensions` for Brave. Confirm the loaded extension ID is `fihllldonobikbajacoflinfomigonhd`, then pin its toolbar action.

The **Connected** status confirms that the native-host manifest is current for every detected browser. It does not by itself prove that the unpacked extension is loaded, enabled, allowed on the current site, or that a real capture has completed. The extension requests `downloads` so its background worker can preserve a completed PNG even if the source page closes while native import is pending. SmartShot only calls the API to create that fallback file and does not read or manage download history. Chromium may describe this as permission to manage downloads.

The current local app artifact is self-signed rather than Developer ID signed and notarized. Gatekeeper may require an explicit Finder **Open** or **Privacy & Security** approval after download; do not treat a local build or passing tests as notarized-distribution evidence.

## Enable in Safari

The `SmartShotSafariExtension` Xcode target already embeds this WebExtension in `SmartShot.app`; do not run `safari-web-extension-converter` for this project.

1. Build a signed SmartShot app with the Safari extension target embedded and launch the containing app once.
2. For this project's local self-signed development build only, enable **Safari > Settings > Developer > Allow unsigned extensions** and complete Safari's authentication prompt. Safari resets this development setting whenever it quits, so it must be enabled again after a Safari restart. A properly Apple-signed distribution build should not require this setting.
3. In **SmartShot > Settings > Browser Integration**, click **Open Safari Settings**, enable **SmartShot Web Selector**, and grant Website Access for the sites you want to capture, such as `x.com`.
4. Return to SmartShot and click **Refresh** to confirm the enabled state. Add or pin the SmartShot action in Safari's toolbar if it is not visible.

Safari sends native messages to application identifier `com.infinityf4p.SmartShot`. The embedded handler validates the same staged protocol as Chromium, then moves the completed artifact to request-scoped named pasteboards so the containing app can validate and preview it. The handler returns final acceptance only after the app acknowledges that second phase. If Safari cannot reach the handler or SmartShot cannot accept the result, the browser download fallback remains active.

The Safari named-pasteboard handoff validates request IDs, schemas, sizes, PNG content, and acknowledgement state, and normal success, rejection, and timeout paths clean up both boards. It does not cryptographically authenticate a writer against another process running as the same macOS user. A Safari extension crash after publishing can also leave bounded request-scoped pasteboard residue beyond normal cleanup. These are accepted P2 boundaries for the current local self-signed release.

## Troubleshooting installation

- **Install SmartShot in /Applications**: move the entire built app to `/Applications/SmartShot.app` and relaunch that copy.
- **No supported Chromium browser was detected**: launch the browser once, then return to SmartShot and click **Install** again.
- **The connector is missing from this SmartShot build**: the app bundle does not contain an executable `Contents/Helpers/SmartShotNativeHost`; rebuild/package the complete app before loading the extension.
- **Native host not found**: verify the unpacked extension ID above, then rerun **Install**. A differently keyed copy has a different origin and is intentionally rejected by the host manifest.
- **Capture downloads instead of opening SmartShot**: confirm the Settings status, extension site access, and that SmartShot can be launched. Download fallback is expected for a missing host, rejected or malformed ACK, host timeout, or interrupted transfer.
- **Safari reports installed but disabled and does not list the local extension**: for the self-signed development build, confirm **Allow unsigned extensions** is enabled for the current Safari process, then reopen Safari's Extensions settings. Do not use this development override as a distribution workaround.

## Message and native-import protocol

Extension-internal requests and native-import requests use the same versioned JSON envelope. The following `capture.request` candidate is sent only from the content script to the extension background worker so it can call `captureVisibleTab`; it is not the native import payload:

```json
{
  "protocol": "com.infinityf4p.smartshot",
  "version": 1,
  "type": "capture.request",
  "requestId": "4e2a2e51-7f8f-458e-9d7e-1fc2aca28983",
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

Only the HTTP(S) origin is retained in the internal candidate; credentials, paths, query parameters, and fragments are removed. Page titles, post text, author labels, DOM selectors, cookies, and HTML are not sent to native messaging.

Completed PNGs use a two-phase native import with one request ID. In phase one, the extension sends `capture.import.begin`, ordered `capture.import.chunk` messages, and `capture.import.end` so the bridge can validate and stage the complete PNG. In phase two, the bridge opens SmartShot and waits for app-side validation and preview publication. The begin payload contains exactly `mimeType`, `encoding`, decoded `byteLength`, `base64Length`, `chunkCount`, a safe `filename`, `kind`, sanitized `sourceOrigin`, and the selected block's positive finite CSS `logicalWidth` and `logicalHeight`. Chunks contain an index and base64 PNG data; the end repeats the byte/chunk counts. Page text, author data, HTML, and URL paths, queries, credentials, and fragments are never sent.

The native host must acknowledge every stage before the extension sends the next message:

```json
{
  "protocol": "com.infinityf4p.smartshot",
  "version": 1,
  "type": "capture.import.ack",
  "requestId": "4e2a2e51-7f8f-458e-9d7e-1fc2aca28983",
  "payload": { "accepted": true, "stage": "chunk", "index": 0 }
}
```

Begin and end acknowledgements use `stage: "begin"` and `stage: "end"`; chunk acknowledgements must also echo the exact zero-based index. The end acknowledgement is accepted only after phase-two app consumption succeeds. Native import request IDs are RFC 4122 UUIDs, and SmartShot allows one outstanding app import so a second concurrent request is rejected rather than replacing the first preview. Returning `accepted: false`, returning an invalid envelope/request ID/stage/index, timing out, or having no native host installed invokes a background-owned browser download. If that API fails while the page still exists, the content script tries a local anchor download without duplicating a successful background download. Rejected chunk/end transfers are removed immediately; abandoned partial transfers older than one hour are removed when a later import begins. The internal long-capture handshake uses the same request ID across `capture.long.begin`, ordered `capture.slice.request` messages, and `capture.long.end`; the background worker verifies that every slice still comes from the original active tab and document. Other internal types are `capture.request`, `capture.import.request`, `capture.import.response`, `selection.toggle`, `selection.start`, `selection.stop`, `selection.state`, and `error`.

The manifest embeds a stable public key so an unpacked Chromium installation keeps the same extension ID across machines and reloads. The native-host manifest must allow that pinned extension origin.

## Test

The shared geometry, selection fixtures, capture guards, content lifecycle, delivery fallback, and protocol tests have no external dependencies. Fixtures cover X timeline/detail posts with media, nested quotes, replies, and repost context, plus generic semantic blocks. They also verify fail-closed nested scrolling/sticky behavior, long-slice pixel-change detection, Promise/callback action reinjection and diagnostics, background-owned fallback after page teardown, in-flight Escape/page-hide cancellation, and page/style/scroll restoration. They do not replace a signed real-browser run against current X. The current-checkout run on 2026-08-24 passed 67/67 tests.

```sh
npm test
```

No analytics, remote fonts, upload endpoints, fetches, or XMLHttpRequests are present.
