(function exposeSmartShotDelivery(root, factory) {
  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  root.SmartShotDelivery = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function makeSmartShotDelivery() {
  "use strict";

  async function importOrDownload(options) {
    try {
      const logicalWidth = options.logicalWidth;
      const logicalHeight = options.logicalHeight;
      if (typeof logicalWidth !== "number" || !Number.isFinite(logicalWidth) || logicalWidth <= 0 ||
          typeof logicalHeight !== "number" || !Number.isFinite(logicalHeight) || logicalHeight <= 0) {
        throw new Error("The selected block has invalid logical dimensions.");
      }
      const request = options.makeEnvelope("capture.import.request", {
        imageDataUrl: options.imageDataUrl,
        filename: options.filename,
        kind: options.kind,
        sourceOrigin: options.sourceOrigin,
        logicalWidth,
        logicalHeight
      });
      let response;
      try {
        response = await options.sendMessage(request);
      } catch (_error) {
        response = await options.sendMessage(request);
      }
      if (options.isEnvelope(response, "capture.import.response") &&
          response.requestId === request.requestId &&
          response.payload.accepted === true) {
        return { handledBy: "native" };
      }
      if (options.isEnvelope(response, "capture.import.response") &&
          response.requestId === request.requestId &&
          response.payload.handledBy === "browser" &&
          response.payload.downloaded === true) {
        return { handledBy: "browser" };
      }
    } catch (_error) {
      // Native import is optional. Preserve the browser download fallback.
    }

    options.download(options.imageDataUrl, options.filename);
    return { handledBy: "browser" };
  }

  return Object.freeze({ importOrDownload });
});
