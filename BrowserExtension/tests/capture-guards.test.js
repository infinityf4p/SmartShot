"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("../shared/core.js");
const Guards = require("../shared/capture-guards.js");
const { FixtureDocument, FixtureElement, computedStyleFor } = require("./fixture-dom.js");

function element(tag, options = {}) {
  return new FixtureElement(tag, options);
}

function prepare(target, document, maximumStyleNodes = 100) {
  return Guards.prepareCaptureEnvironment({
    target,
    document,
    getComputedStyle: computedStyleFor,
    maximumStyleNodes
  });
}

test("nested scrolling ancestors are rejected before page styles change", () => {
  const html = element("html");
  const scroller = element("div", {
    computed: { overflowY: "auto" },
    clientHeight: 300,
    scrollHeight: 1200
  });
  const target = element("article", { rect: { width: 600, height: 900 } });
  html.append(scroller);
  scroller.append(target);
  const document = new FixtureDocument(html);

  assert.throws(() => prepare(target, document), /nested scroll area/);
  assert.equal(html.children.some((child) => child.localName === "style"), false);
});

test("oversized DOMs are rejected before the freeze style is installed", () => {
  const html = element("html");
  const target = element("article");
  html.append(target, element("div"), element("div"));
  const document = new FixtureDocument(html);

  assert.throws(() => prepare(target, document, 2), /page is too large/);
  assert.equal(html.children.some((child) => child.localName === "style"), false);
});

test("sticky ancestors fail closed and remove the temporary freeze style", () => {
  const html = element("html");
  const sticky = element("div", { computed: { position: "sticky" } });
  const target = element("article", { rect: { width: 600, height: 900 } });
  html.append(sticky);
  sticky.append(target);
  const document = new FixtureDocument(html);

  assert.throws(() => prepare(target, document), /fixed or sticky container/);
  assert.equal(html.children.some((child) => child.localName === "style"), false);
  assert.equal(sticky.style.getPropertyValue("visibility"), "");
});

test("fixed and sticky page styles are restored exactly after capture", () => {
  const html = element("html");
  const target = element("article", { rect: { width: 600, height: 1200 } });
  const stickyChild = element("div", {
    computed: { position: "sticky" },
    inlineStyle: { position: "sticky", top: "12px" }
  });
  stickyChild.style.setProperty("top", "12px", "important");
  const fixedChild = element("button", { computed: { position: "fixed" } });
  const outsideFixed = element("nav", {
    computed: { position: "fixed" },
    inlineStyle: { visibility: "visible" }
  });
  html.append(target, outsideFixed);
  target.append(stickyChild, fixedChild);
  const document = new FixtureDocument(html);

  const restore = prepare(target, document);
  assert.equal(stickyChild.style.getPropertyValue("position"), "relative");
  assert.equal(stickyChild.style.getPropertyValue("top"), "auto");
  assert.equal(fixedChild.style.getPropertyValue("visibility"), "hidden");
  assert.equal(outsideFixed.style.getPropertyValue("visibility"), "hidden");
  assert.equal(html.children.some((child) => child.localName === "style"), true);

  restore();
  restore();
  assert.equal(stickyChild.style.getPropertyValue("position"), "sticky");
  assert.equal(stickyChild.style.getPropertyValue("top"), "12px");
  assert.equal(stickyChild.style.getPropertyPriority("top"), "important");
  assert.equal(fixedChild.style.getPropertyValue("visibility"), "");
  assert.equal(outsideFixed.style.getPropertyValue("visibility"), "visible");
  assert.equal(html.children.some((child) => child.localName === "style"), false);
});

function stableOptions() {
  const element = new FixtureElement("article", {
    rect: { x: 100, y: 50, width: 500, height: 900 }
  });
  const view = {
    innerWidth: 1000,
    innerHeight: 700,
    scrollX: 0,
    scrollY: 500,
    visualViewport: { scale: 1, offsetLeft: 0, offsetTop: 0 }
  };
  return {
    element,
    expectedRect: { x: 100, y: 550, width: 500, height: 900 },
    expectedURL: "https://x.com/user/status/1",
    expectedViewport: { width: 1000, height: 700 },
    targetMutated: () => false,
    currentURL: () => "https://x.com/user/status/1",
    view,
    rectFor: (candidate) => candidate.getBoundingClientRect(),
    normalizeRect: Core.normalizeRect
  };
}

test("stable targets pass while navigation, mutation, detachment and geometry drift fail", () => {
  const baseline = stableOptions();
  assert.doesNotThrow(() => Guards.assertStableTarget(baseline));

  assert.throws(() => Guards.assertStableTarget({
    ...stableOptions(), currentURL: () => "https://x.com/home"
  }), /page navigated/);
  assert.throws(() => Guards.assertStableTarget({
    ...stableOptions(), targetMutated: () => true
  }), /selected block changed/);

  const detached = stableOptions();
  detached.element.isConnected = false;
  assert.throws(() => Guards.assertStableTarget(detached), /left the page/);

  const resized = stableOptions();
  resized.view.innerHeight = 650;
  assert.throws(() => Guards.assertStableTarget(resized), /viewport changed/);

  const shifted = stableOptions();
  shifted.element.rect.y += 20;
  assert.throws(() => Guards.assertStableTarget(shifted), /selected block changed/);

  const zoomed = stableOptions();
  zoomed.view.visualViewport.scale = 1.2;
  assert.throws(() => Guards.assertStableTarget(zoomed), /pinch zoom/);
});

test("scroll and page-style state are restored after a failed capture operation", async () => {
  const html = element("html");
  const target = element("article", { rect: { width: 600, height: 1200 } });
  const fixed = element("nav", { computed: { position: "fixed" } });
  html.append(target, fixed);
  const restoreEnvironment = prepare(target, new FixtureDocument(html));
  const view = {
    scrollX: 0,
    scrollY: 1500,
    scrollTo(x, y) {
      this.scrollX = x;
      this.scrollY = y;
    }
  };
  let paints = 0;
  let failure;

  try {
    throw new Error("fixture capture failed");
  } catch (error) {
    failure = error;
  } finally {
    await Guards.restorePageState(view, { x: 10, y: 320 }, restoreEnvironment, async () => {
      paints += 1;
    });
  }

  assert.match(failure.message, /fixture capture failed/);
  assert.deepEqual({ x: view.scrollX, y: view.scrollY }, { x: 10, y: 320 });
  assert.equal(fixed.style.getPropertyValue("visibility"), "");
  assert.equal(html.children.some((child) => child.localName === "style"), false);
  assert.equal(paints, 2);
});

test("style cleanup and repaint still run when scroll restoration fails", async () => {
  let stylesRestored = false;
  let paints = 0;
  const view = {
    scrollTo() {
      throw new Error("scroll restoration failed");
    }
  };

  await assert.rejects(() => Guards.restorePageState(
    view,
    { x: 0, y: 0 },
    () => { stylesRestored = true; },
    async () => { paints += 1; }
  ), /scroll restoration failed/);
  assert.equal(stylesRestored, true);
  assert.equal(paints, 2);
});

test("restoration corrects scroll anchoring caused by restored page styles", async () => {
  const calls = [];
  const view = {
    scrollX: 0,
    scrollY: 1_500,
    scrollTo(x, y) {
      calls.push({ x, y });
      this.scrollX = x;
      this.scrollY = y;
    }
  };
  let paint = 0;

  await Guards.restorePageState(view, { x: 12, y: 320 }, () => {
    view.scrollY += 80;
  }, async () => {
    paint += 1;
    if (paint === 1) view.scrollY += 20;
  });

  assert.deepEqual(calls, [{ x: 12, y: 320 }, { x: 12, y: 320 }]);
  assert.deepEqual({ x: view.scrollX, y: view.scrollY }, { x: 12, y: 320 });
  assert.equal(paint, 2);
});

test("capture cancellation is synchronous, idempotent, and recognizable", () => {
  const controller = Guards.createCaptureCancellationController();
  const reasons = [];
  controller.onCancel((reason) => reasons.push(reason));

  controller.cancel("Capture stopped because the page became inactive.");
  controller.cancel("second cancellation must be ignored");

  assert.equal(controller.cancelled, true);
  assert.equal(reasons.length, 1);
  assert.equal(Guards.isCaptureCancellation(reasons[0]), true);
  assert.throws(
    () => controller.throwIfCancelled(),
    (error) => error.name === "AbortError" && /page became inactive/.test(error.message)
  );
});

function pixelSample(width, height, fill = [20, 40, 60, 255]) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let offset = 0; offset < data.length; offset += 4) {
    data.set(fill, offset);
  }
  return { width, height, data };
}

test("verification samples preserve aspect ratio without upscaling", () => {
  assert.deepEqual(Guards.verificationSampleSize(1_200, 600), { width: 96, height: 48 });
  assert.deepEqual(Guards.verificationSampleSize(24, 12), { width: 24, height: 12 });
  assert.throws(() => Guards.verificationSampleSize(0, 100), /invalid dimensions/);
});

test("identical capture samples and bounded channel noise remain stable", () => {
  const first = pixelSample(32, 24);
  const identical = pixelSample(32, 24);
  assert.doesNotThrow(() => Guards.assertStablePixelSamples(first, identical));

  const boundedNoise = pixelSample(32, 24, [25, 44, 66, 255]);
  const difference = Guards.assertStablePixelSamples(first, boundedNoise, {
    maximumMeanChannelDelta: 6
  });
  assert.equal(difference.changedPixels, 0);
  assert.ok(difference.meanChannelDelta > 0);
});

test("localized dynamic pixels fail capture verification", () => {
  const first = pixelSample(40, 30);
  const changed = pixelSample(40, 30);
  for (let pixel = 0; pixel < 8; pixel += 1) {
    const offset = (12 * 40 + 10 + pixel) * 4;
    changed.data[offset] = 220;
    changed.data[offset + 1] = 10;
    changed.data[offset + 2] = 180;
  }

  assert.throws(
    () => Guards.assertStablePixelSamples(first, changed),
    /pixels in the selected block changed/
  );
});

test("widespread subtle pixel motion and mismatched frames fail closed", () => {
  const first = pixelSample(24, 24);
  const subtleMotion = pixelSample(24, 24, [22, 42, 62, 255]);
  assert.throws(
    () => Guards.assertStablePixelSamples(first, subtleMotion),
    /pixels in the selected block changed/
  );
  assert.throws(
    () => Guards.assertStablePixelSamples(first, pixelSample(24, 23)),
    /different dimensions/
  );
  assert.throws(
    () => Guards.assertStablePixelSamples(first, { width: 24, height: 24, data: [] }),
    /invalid sample/
  );
});
