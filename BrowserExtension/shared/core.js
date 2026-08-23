(function exposeSmartShotCore(root, factory) {
  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  root.SmartShotCore = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function makeSmartShotCore() {
  "use strict";

  const PROTOCOL = "com.infinityf4p.smartshot";
  const VERSION = 1;
  const NATIVE_HOSTS = Object.freeze({
    chromium: "com.infinityf4p.smartshot",
    safari: "com.infinityf4p.SmartShot"
  });
  const CAPTURE_LIMITS = Object.freeze({
    maxSlices: 24,
    maxCSSHeight: 20000,
    maxPixelDimension: 16384,
    maxPixelCount: 32000000,
    maxDurationMs: 20000,
    maxStyleNodes: 30000
  });

  function finite(value, fallback = 0) {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }

  function rounded(value) {
    return Math.round(finite(value) * 1000) / 1000;
  }

  function normalizeRect(rect) {
    const x = finite(rect && (rect.x ?? rect.left));
    const y = finite(rect && (rect.y ?? rect.top));
    const width = Math.max(0, finite(rect && rect.width));
    const height = Math.max(0, finite(rect && rect.height));

    return {
      x: rounded(x),
      y: rounded(y),
      width: rounded(width),
      height: rounded(height)
    };
  }

  function intersectRect(first, second) {
    const a = normalizeRect(first);
    const b = normalizeRect(second);
    const left = Math.max(a.x, b.x);
    const top = Math.max(a.y, b.y);
    const right = Math.min(a.x + a.width, b.x + b.width);
    const bottom = Math.min(a.y + a.height, b.y + b.height);

    return normalizeRect({
      x: left,
      y: top,
      width: Math.max(0, right - left),
      height: Math.max(0, bottom - top)
    });
  }

  function isRectFullyVisible(rect, viewport, tolerance = 0.5) {
    const value = normalizeRect(rect);
    const width = Math.max(0, finite(viewport && viewport.width));
    const height = Math.max(0, finite(viewport && viewport.height));
    const slack = Math.max(0, finite(tolerance));

    return value.width > 0 && value.height > 0 &&
      value.x >= -slack && value.y >= -slack &&
      value.x + value.width <= width + slack &&
      value.y + value.height <= height + slack;
  }

  function horizontalScrollForRect(pageRect, viewportWidth, documentWidth, tolerance = 0.5) {
    const target = normalizeRect(pageRect);
    const visibleWidth = Math.max(0, finite(viewportWidth));
    const pageWidth = Math.max(visibleWidth, finite(documentWidth));
    const slack = Math.max(0, finite(tolerance));

    if (!target.width || !visibleWidth) throw new Error("The selected block has no capturable width.");
    if (target.width > visibleWidth + slack) {
      throw new Error("The selected block is wider than the browser viewport.");
    }
    if (target.x < -slack || target.x + target.width > pageWidth + slack) {
      throw new Error("The selected block extends beyond the scrollable page width.");
    }

    const maximum = Math.max(0, pageWidth - visibleWidth);
    const scrollX = Math.min(Math.max(0, target.x), maximum);
    if (scrollX > target.x + slack || scrollX + visibleWidth < target.x + target.width - slack) {
      throw new Error("The selected block cannot fit horizontally in one browser capture.");
    }
    return rounded(scrollX);
  }

  function planVerticalSlices(pageRect, viewport, documentSize, limits = CAPTURE_LIMITS) {
    const target = normalizeRect(pageRect);
    const viewportWidth = Math.max(0, finite(viewport && viewport.width));
    const viewportHeight = Math.max(0, finite(viewport && viewport.height));
    const documentWidth = Math.max(viewportWidth, finite(documentSize && documentSize.width));
    const documentHeight = Math.max(viewportHeight, finite(documentSize && documentSize.height));

    if (!target.width || !target.height || !viewportWidth || !viewportHeight) {
      throw new Error("The selected block has no capturable area.");
    }
    if (target.height > finite(limits.maxCSSHeight, CAPTURE_LIMITS.maxCSSHeight)) {
      throw new Error("The selected block is taller than the capture limit.");
    }

    const scrollX = horizontalScrollForRect(target, viewportWidth, documentWidth);
    const tolerance = 0.5;
    if (target.y < -tolerance || target.y + target.height > documentHeight + tolerance) {
      throw new Error("The selected block extends beyond the scrollable page height.");
    }

    const maximumScrollY = Math.max(0, documentHeight - viewportHeight);
    const bottom = Math.min(documentHeight, target.y + target.height);
    const slices = [];
    let pageStart = Math.max(0, target.y);

    while (pageStart < bottom - 0.001) {
      const scrollY = Math.min(Math.max(0, pageStart), maximumScrollY);
      const pageEnd = Math.min(bottom, scrollY + viewportHeight);
      if (pageEnd <= pageStart + 0.001) {
        throw new Error("The page did not expose the next capture slice.");
      }
      slices.push({
        index: slices.length,
        scrollX,
        scrollY: rounded(scrollY),
        pageStart: rounded(pageStart),
        pageEnd: rounded(pageEnd)
      });
      if (slices.length > finite(limits.maxSlices, CAPTURE_LIMITS.maxSlices)) {
        throw new Error("The selected block needs too many capture slices.");
      }
      pageStart = pageEnd;
    }

    return slices;
  }

  function sanitizeSourceURL(value) {
    try {
      const parsed = new URL(String(value || ""));
      if (!/^https?:$/.test(parsed.protocol)) return "";
      return parsed.origin;
    } catch (_error) {
      return "";
    }
  }

  function makeCandidate(input) {
    const viewportRect = normalizeRect(input.rect);
    const viewport = {
      width: Math.max(0, rounded(input.viewportWidth)),
      height: Math.max(0, rounded(input.viewportHeight))
    };
    const pageRect = normalizeRect({
      x: viewportRect.x + finite(input.scrollX),
      y: viewportRect.y + finite(input.scrollY),
      width: viewportRect.width,
      height: viewportRect.height
    });
    const visibleViewportRect = intersectRect(viewportRect, {
      x: 0,
      y: 0,
      width: viewport.width,
      height: viewport.height
    });

    return {
      pageRect,
      viewportRect,
      visibleViewportRect,
      viewport,
      devicePixelRatio: Math.max(0.1, rounded(input.devicePixelRatio || 1)),
      url: sanitizeSourceURL(input.url),
      kind: String(input.kind || "block"),
      metadata: input.metadata && input.metadata.platform === "x" ? { platform: "x" } : {}
    };
  }

  function generatedRequestId() {
    const webCrypto = typeof globalThis !== "undefined" ? globalThis.crypto : undefined;
    if (webCrypto && typeof webCrypto.randomUUID === "function") {
      return webCrypto.randomUUID();
    }

    const bytes = new Uint8Array(16);
    if (webCrypto && typeof webCrypto.getRandomValues === "function") {
      webCrypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hexadecimal = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
    return `${hexadecimal.slice(0, 4).join("")}-${hexadecimal.slice(4, 6).join("")}-${hexadecimal.slice(6, 8).join("")}-${hexadecimal.slice(8, 10).join("")}-${hexadecimal.slice(10).join("")}`;
  }

  function makeEnvelope(type, payload, requestId) {
    const resolvedRequestId = requestId ? String(requestId) : generatedRequestId();

    return {
      protocol: PROTOCOL,
      version: VERSION,
      type: String(type || ""),
      requestId: resolvedRequestId,
      payload: payload && typeof payload === "object" ? payload : {}
    };
  }

  function isEnvelope(value, expectedType) {
    return Boolean(
      value &&
      value.protocol === PROTOCOL &&
      value.version === VERSION &&
      typeof value.type === "string" &&
      (!expectedType || value.type === expectedType) &&
      typeof value.requestId === "string" &&
      value.payload &&
      typeof value.payload === "object"
    );
  }

  function kindFromDescriptor(descriptor) {
    const tagName = String(descriptor && descriptor.tagName || "").toLowerCase();
    const role = String(descriptor && descriptor.role || "").toLowerCase();
    const testId = String(descriptor && descriptor.testId || "").toLowerCase();

    if (tagName === "article" && testId === "tweet") return "x-post";
    if (tagName === "article" || role === "article") return "article";
    if (tagName === "main" || role === "main") return "main";
    if (tagName === "section" || role === "region") return "section";
    if (role === "listitem" || tagName === "li") return "list-item";
    if (role) return `role:${role}`;
    return "block";
  }

  function capturePixelRectForViewportRect(rect, viewport, imageWidth, imageHeight) {
    const visible = normalizeRect(rect);
    const scaleX = finite(imageWidth) / Math.max(1, finite(viewport.width, 1));
    const scaleY = finite(imageHeight) / Math.max(1, finite(viewport.height, 1));
    const left = Math.max(0, Math.floor(visible.x * scaleX));
    const top = Math.max(0, Math.floor(visible.y * scaleY));
    const right = Math.min(Math.floor(finite(imageWidth)), Math.ceil((visible.x + visible.width) * scaleX));
    const bottom = Math.min(Math.floor(finite(imageHeight)), Math.ceil((visible.y + visible.height) * scaleY));

    return {
      x: left,
      y: top,
      width: Math.max(0, right - left),
      height: Math.max(0, bottom - top)
    };
  }

  function capturePixelRect(candidate, imageWidth, imageHeight) {
    return capturePixelRectForViewportRect(
      candidate && candidate.visibleViewportRect,
      candidate && candidate.viewport || {},
      imageWidth,
      imageHeight
    );
  }

  function captureOutputSize(cssRect, scaleX, scaleY, limits = CAPTURE_LIMITS) {
    const rect = normalizeRect(cssRect);
    const width = Math.max(1, Math.ceil(rect.width * Math.max(0, finite(scaleX))));
    const height = Math.max(1, Math.ceil(rect.height * Math.max(0, finite(scaleY))));
    const maximumDimension = finite(limits.maxPixelDimension, CAPTURE_LIMITS.maxPixelDimension);
    const maximumPixels = finite(limits.maxPixelCount, CAPTURE_LIMITS.maxPixelCount);

    if (width > maximumDimension || height > maximumDimension || width * height > maximumPixels) {
      throw new Error("The selected block would create an image larger than the capture limit.");
    }
    return { width, height };
  }

  function destinationPixelRange(pageStart, pageEnd, targetTop, scaleY, outputHeight) {
    const height = Math.max(0, Math.floor(finite(outputHeight)));
    const top = Math.max(0, Math.min(height, Math.round((finite(pageStart) - finite(targetTop)) * finite(scaleY))));
    const bottom = Math.max(top, Math.min(height, Math.round((finite(pageEnd) - finite(targetTop)) * finite(scaleY))));
    return { y: top, height: bottom - top };
  }

  function safeFilename(value) {
    const cleaned = String(value || "capture")
      .normalize("NFKC")
      .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 80);
    return cleaned || "capture";
  }

  return Object.freeze({
    PROTOCOL,
    VERSION,
    NATIVE_HOSTS,
    CAPTURE_LIMITS,
    normalizeRect,
    intersectRect,
    isRectFullyVisible,
    horizontalScrollForRect,
    planVerticalSlices,
    sanitizeSourceURL,
    makeCandidate,
    makeEnvelope,
    isEnvelope,
    kindFromDescriptor,
    capturePixelRectForViewportRect,
    capturePixelRect,
    captureOutputSize,
    destinationPixelRange,
    safeFilename
  });
});
