"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Core = require("../shared/core.js");

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test("intersectRect clips a block to the viewport", () => {
  assert.deepEqual(
    Core.intersectRect({ x: -20, y: 40, width: 100, height: 90 }, { x: 0, y: 0, width: 60, height: 80 }),
    { x: 0, y: 40, width: 60, height: 40 }
  );
});

test("isRectFullyVisible distinguishes the fast path from scrolling capture", () => {
  const viewport = { width: 800, height: 600 };
  assert.equal(Core.isRectFullyVisible({ x: 10, y: 20, width: 400, height: 300 }, viewport), true);
  assert.equal(Core.isRectFullyVisible({ x: 10, y: -4, width: 400, height: 300 }, viewport), false);
  assert.equal(Core.isRectFullyVisible({ x: 10, y: 20, width: 400, height: 700 }, viewport), false);
});

test("planVerticalSlices covers a tall element without gaps or overlaps", () => {
  const slices = Core.planVerticalSlices(
    { x: 100, y: 250, width: 500, height: 1300 },
    { width: 800, height: 600 },
    { width: 800, height: 2200 }
  );

  assert.deepEqual(slices, [
    { index: 0, scrollX: 0, scrollY: 250, pageStart: 250, pageEnd: 850 },
    { index: 1, scrollX: 0, scrollY: 850, pageStart: 850, pageEnd: 1450 },
    { index: 2, scrollX: 0, scrollY: 1450, pageStart: 1450, pageEnd: 1550 }
  ]);
});

test("planVerticalSlices anchors the final slice at the document bottom", () => {
  const slices = Core.planVerticalSlices(
    { x: 20, y: 900, width: 300, height: 550 },
    { width: 800, height: 600 },
    { width: 800, height: 1500 }
  );

  assert.deepEqual(slices, [
    { index: 0, scrollX: 0, scrollY: 900, pageStart: 900, pageEnd: 1450 }
  ]);
});

test("planVerticalSlices scrolls horizontally only when needed", () => {
  const slices = Core.planVerticalSlices(
    { x: 900, y: 100, width: 300, height: 700 },
    { width: 800, height: 500 },
    { width: 1400, height: 1200 }
  );
  assert.equal(slices[0].scrollX, 600);
  assert.throws(
    () => Core.planVerticalSlices(
      { x: 0, y: 0, width: 900, height: 200 },
      { width: 800, height: 500 },
      { width: 900, height: 500 }
    ),
    /wider than the browser viewport/
  );
});

test("planVerticalSlices enforces height and slice limits", () => {
  assert.throws(
    () => Core.planVerticalSlices(
      { x: 0, y: 0, width: 400, height: 20001 },
      { width: 800, height: 600 },
      { width: 800, height: 22000 }
    ),
    /taller than the capture limit/
  );
  assert.throws(
    () => Core.planVerticalSlices(
      { x: 0, y: 0, width: 400, height: 1800 },
      { width: 800, height: 500 },
      { width: 800, height: 2000 },
      { ...Core.CAPTURE_LIMITS, maxSlices: 3 }
    ),
    /too many capture slices/
  );
});

test("makeCandidate records page, viewport and visible rectangles", () => {
  const candidate = Core.makeCandidate({
    rect: { x: 10, y: -30, width: 300, height: 200 },
    scrollX: 5,
    scrollY: 500,
    viewportWidth: 800,
    viewportHeight: 600,
    devicePixelRatio: 2,
    url: "https://x.com/example/status/1?tracking=private#replies",
    kind: "x-post"
  });

  assert.deepEqual(candidate.pageRect, { x: 15, y: 470, width: 300, height: 200 });
  assert.deepEqual(candidate.visibleViewportRect, { x: 10, y: 0, width: 300, height: 170 });
  assert.equal(candidate.devicePixelRatio, 2);
  assert.equal(candidate.url, "https://x.com");
  assert.equal("title" in candidate, false);
  assert.equal("selector" in candidate, false);
});

test("sanitizeSourceURL keeps only the HTTP origin", () => {
  assert.equal(
    Core.sanitizeSourceURL("https://user:secret@example.com/post?id=private#section"),
    "https://example.com"
  );
  assert.equal(Core.sanitizeSourceURL("file:///Users/example/private.html"), "");
});

test("kindFromDescriptor gives X posts first-class semantics", () => {
  assert.equal(Core.kindFromDescriptor({ tagName: "article", testId: "tweet" }), "x-post");
  assert.equal(Core.kindFromDescriptor({ tagName: "section" }), "section");
  assert.equal(Core.kindFromDescriptor({ tagName: "div", role: "listitem" }), "list-item");
});

test("protocol envelopes are versioned and type-checkable", () => {
  const envelope = Core.makeEnvelope("capture.request", { candidate: {} }, "request-1");
  assert.equal(Core.isEnvelope(envelope, "capture.request"), true);
  assert.equal(Core.isEnvelope({ ...envelope, version: 2 }), false);
  assert.equal(Core.isEnvelope(envelope, "capture.response"), false);
});

test("selector commands use a shared controller protocol version", () => {
  assert.equal(Core.SELECTOR_PROTOCOL_VERSION, 3);
});

test("generated request IDs remain native-compatible without Web Crypto", () => {
  const sandbox = {
    Date,
    Math,
    URL,
    Uint8Array,
    module: { exports: {} }
  };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "..", "shared", "core.js"), "utf8"),
    sandbox,
    { filename: "core.js" }
  );

  const requestId = sandbox.module.exports.makeEnvelope("capture.request", {}).requestId;
  assert.match(requestId, UUID_PATTERN);
});

test("capturePixelRect uses observed image scale instead of assuming DPR", () => {
  const pixelRect = Core.capturePixelRect({
    visibleViewportRect: { x: 10.25, y: 20.5, width: 100, height: 50 },
    viewport: { width: 500, height: 400 }
  }, 1000, 800);

  assert.deepEqual(pixelRect, { x: 20, y: 41, width: 201, height: 100 });
});

test("capturePixelRectForViewportRect maps an arbitrary long-capture slice", () => {
  assert.deepEqual(
    Core.capturePixelRectForViewportRect(
      { x: 120.25, y: 300.5, width: 400, height: 199.5 },
      { width: 800, height: 500 },
      1600,
      1000
    ),
    { x: 240, y: 601, width: 801, height: 399 }
  );
});

test("captureOutputSize rejects canvas dimensions beyond browser-safe limits", () => {
  assert.deepEqual(Core.captureOutputSize({ width: 500, height: 1300 }, 2, 2), {
    width: 1000,
    height: 2600
  });
  assert.throws(
    () => Core.captureOutputSize({ width: 8000, height: 8000 }, 2, 2),
    /larger than the capture limit/
  );
});

test("destinationPixelRange keeps adjacent slices seam-free", () => {
  const first = Core.destinationPixelRange(250, 850, 250, 2, 2600);
  const second = Core.destinationPixelRange(850, 1450, 250, 2, 2600);
  const third = Core.destinationPixelRange(1450, 1550, 250, 2, 2600);
  assert.deepEqual(first, { y: 0, height: 1200 });
  assert.deepEqual(second, { y: 1200, height: 1200 });
  assert.deepEqual(third, { y: 2400, height: 200 });
});

test("safeFilename removes filesystem control characters", () => {
  assert.equal(Core.safeFilename(' x.com: post / 1? '), "x.com- post - 1-");
});
