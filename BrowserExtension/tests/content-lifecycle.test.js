"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Core = require("../shared/core.js");
const Selection = require("../shared/selection.js");
const CaptureGuards = require("../shared/capture-guards.js");
const Delivery = require("../shared/delivery.js");
const SELECTOR_PROTOCOL_VERSION = Core.SELECTOR_PROTOCOL_VERSION;
const {
  FixtureDocument,
  FixtureElement,
  computedStyleFor,
  flatten
} = require("./fixture-dom.js");

class FixtureEventTarget {
  constructor() {
    this.listeners = new Map();
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(listener);
  }

  removeEventListener(type, listener) {
    this.listeners.get(type)?.delete(listener);
  }

  dispatch(type, event = {}) {
    for (const listener of Array.from(this.listeners.get(type) || [])) listener(event);
  }
}

function event(values = {}) {
  return {
    defaultPrevented: false,
    immediatePropagationStopped: false,
    preventDefault() { this.defaultPrevented = true; },
    stopImmediatePropagation() { this.immediatePropagationStopped = true; },
    ...values
  };
}

function decorateElement(element) {
  element.classList = { toggle() {} };
  element.setAttribute = (name, value) => { element.attributes[name] = String(value); };
  element.attachShadow = () => ({ append() {} });
  element.click = () => {};
  return element;
}

function makeHarness(options = {}) {
  let runtimeListener;
  let resolveBegin;
  const beginGate = new Promise((resolve) => { resolveBegin = resolve; });
  const errors = [];
  const sentMessages = [];
  const elementFromPointCalls = [];
  const documentEvents = new FixtureEventTarget();
  const windowEvents = new FixtureEventTarget();
  const targetHeight = options.targetHeight || 1_200;
  const html = decorateElement(new FixtureElement("html", {
    rect: { width: 1_000, height: 3_000 },
    clientWidth: 1_000,
    clientHeight: 700,
    scrollWidth: 1_000,
    scrollHeight: 3_000
  }));
  const target = decorateElement(new FixtureElement("article", {
    rect: { x: 180, y: 100, width: 600, height: targetHeight }
  }));
  const targetHeader = decorateElement(new FixtureElement("header", {
    rect: { x: 180, y: 100, width: 600, height: 52 }
  }));
  const targetLeaf = decorateElement(new FixtureElement("button", {
    attributes: { role: "button" },
    rect: { x: 690, y: 110, width: 72, height: 32 },
    computed: { display: "block" }
  }));
  const fixed = decorateElement(new FixtureElement("nav", {
    computed: { position: "fixed" }
  }));
  targetHeader.append(targetLeaf);
  target.append(targetHeader);
  html.append(target, fixed);

  const document = new FixtureDocument(html);
  document.body = html;
  document.activeElement = options.focusedTargetLeaf ? targetLeaf : html;
  document.hidden = false;
  document.addEventListener = documentEvents.addEventListener.bind(documentEvents);
  document.removeEventListener = documentEvents.removeEventListener.bind(documentEvents);
  document.dispatch = documentEvents.dispatch.bind(documentEvents);
  document.elementFromPoint = (x, y) => {
    elementFromPointCalls.push({ x, y });
    return options.emptyPage ? null : targetLeaf;
  };
  document.getElementById = (id) => flatten(html).find((element) => element.id === id) || null;
  document.createElement = (localName) => {
    if (localName === "canvas") {
      const context = {
        fillStyle: "",
        drawImage() {},
        fillRect() {},
        getImageData(_x, _y, width, height) {
          return { width, height, data: new Uint8ClampedArray(width * height * 4) };
        }
      };
      return {
        width: 0,
        height: 0,
        getContext() { return context; },
        toDataURL() { return "data:image/png;base64,fixture"; }
      };
    }
    return decorateElement(new FixtureElement(localName, {
      rect: { width: 0, height: 0 }
    }));
  };

  const window = {
    innerWidth: 1_000,
    innerHeight: 700,
    scrollX: 0,
    scrollY: 0,
    devicePixelRatio: 2,
    visualViewport: { scale: 1, offsetLeft: 0, offsetTop: 0 },
    addEventListener: windowEvents.addEventListener.bind(windowEvents),
    removeEventListener: windowEvents.removeEventListener.bind(windowEvents),
    dispatch: windowEvents.dispatch.bind(windowEvents),
    scrollTo(x, y) {
      this.scrollX = x;
      this.scrollY = y;
    }
  };
  target.getBoundingClientRect = () => ({
    x: 180 - window.scrollX,
    y: 100 - window.scrollY,
    left: 180 - window.scrollX,
    top: 100 - window.scrollY,
    right: 780 - window.scrollX,
    bottom: 100 + targetHeight - window.scrollY,
    width: 600,
    height: targetHeight
  });

  const browser = {
    runtime: {
      onMessage: { addListener(listener) { runtimeListener = listener; } },
      async sendMessage(message) {
        sentMessages.push(message);
        if (typeof options.sendMessage === "function") {
          return options.sendMessage(message);
        }
        if (message.type === "capture.long.begin") return beginGate;
        if (message.type === "capture.long.end") {
          return Core.makeEnvelope("capture.long.ended", { completed: false }, message.requestId);
        }
        throw new Error(`Unexpected content message: ${message.type}`);
      }
    }
  };
  const sandbox = {
    SmartShotCore: Core,
    SmartShotSelection: Selection,
    SmartShotCaptureGuards: CaptureGuards,
    SmartShotDelivery: Delivery,
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    browser,
    console: { error(...values) { errors.push(values); } },
    Date,
    document,
    getComputedStyle: computedStyleFor,
    Image: class {
      constructor() {
        this.naturalWidth = 2_000;
        this.naturalHeight = 1_400;
      }
      set src(value) {
        this.currentSrc = value;
        setImmediate(() => this.onload?.());
      }
    },
    innerHeight: window.innerHeight,
    innerWidth: window.innerWidth,
    location: { href: "https://x.com/person/status/123?private=yes" },
    performance: { now: () => Date.now() },
    Promise,
    requestAnimationFrame(callback) {
      return setImmediate(() => callback(Date.now()));
    },
    setTimeout(callback, delay) {
      return setTimeout(callback, delay === 6_000 ? 0 : delay);
    },
    clearTimeout,
    URL,
    window
  };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "..", "content.js"), "utf8"),
    sandbox,
    { filename: "content.js" }
  );

  function dispatchRuntime(action, selectorProtocolVersion = SELECTOR_PROTOCOL_VERSION) {
    const message = Core.makeEnvelope("selection.command", {
      action,
      selectorProtocolVersion
    });
    let response;
    runtimeListener(message, {}, (value) => { response = value; });
    return response;
  }

  function dispatchLegacy(action) {
    const message = Core.makeEnvelope(`selection.${action}`, {});
    let response;
    runtimeListener(message, {}, (value) => { response = value; });
    return response;
  }

  async function waitFor(predicate) {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      if (predicate()) return;
      await new Promise((resolve) => setImmediate(resolve));
    }
    throw new Error("Timed out waiting for content-script fixture state.");
  }

  async function startCapture({ movePointer = true } = {}) {
    const response = dispatchRuntime("start");
    assert.equal(response.payload.active, true);
    assert.equal(response.payload.capturing, false);
    assert.equal(response.payload.selectorProtocolVersion, SELECTOR_PROTOCOL_VERSION);
    if (movePointer) {
      document.dispatch("pointermove", event({ clientX: 300, clientY: 200 }));
    }
    await waitFor(() => document.getElementById("smartshot-selector-root") !== null);
    await new Promise((resolve) => setImmediate(resolve));
    document.dispatch("click", event({ target: targetLeaf }));
  }

  async function beginLongCapture(options = {}) {
    await startCapture(options);
    await waitFor(() => sentMessages.some((message) => message.type === "capture.long.begin"));
  }

  async function finishCancellation() {
    const begin = sentMessages.find((message) => message.type === "capture.long.begin");
    resolveBegin(Core.makeEnvelope("capture.long.ready", { accepted: true }, begin.requestId));
    await waitFor(() => sentMessages.some((message) => (
      message.type === "capture.long.end" && message.payload.cancelled === true
    )));
    for (let frame = 0; frame < 8; frame += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  return {
    beginLongCapture,
    dispatchLegacy,
    dispatchRuntime,
    document,
    elementFromPointCalls,
    errors,
    finishCancellation,
    fixed,
    sentMessages,
    startCapture,
    resolveBegin,
    waitFor,
    window
  };
}

test("starting with a focused nested button lets Enter capture its semantic article", async () => {
  const harness = makeHarness({ focusedTargetLeaf: true });

  assert.equal(harness.dispatchRuntime("start").payload.active, true);
  assert.deepEqual(harness.elementFromPointCalls, []);
  const enter = event({ key: "Enter" });
  harness.document.dispatch("keydown", enter);
  await harness.waitFor(() => harness.sentMessages.some((message) => message.type === "capture.long.begin"));

  const begin = harness.sentMessages.find((message) => message.type === "capture.long.begin");
  assert.equal(enter.defaultPrevented, true);
  assert.equal(enter.immediatePropagationStopped, true);
  assert.equal(begin.payload.candidate.kind, "article");
  assert.deepEqual(begin.payload.candidate.pageRect, {
    x: 180,
    y: 100,
    width: 600,
    height: 1_200
  });
  harness.document.dispatch("keydown", event({ key: "Escape" }));
  await harness.finishCancellation();
});

test("starting without a usable focus seeds the candidate from the viewport center", async () => {
  const harness = makeHarness();

  assert.equal(harness.dispatchRuntime("start").payload.active, true);
  assert.deepEqual(harness.elementFromPointCalls, [{ x: 500, y: 350 }]);
  harness.document.dispatch("keydown", event({ key: "Enter" }));
  await harness.waitFor(() => harness.sentMessages.some((message) => message.type === "capture.long.begin"));

  const begin = harness.sentMessages.find((message) => message.type === "capture.long.begin");
  assert.equal(begin.payload.candidate.kind, "article");
  harness.document.dispatch("keydown", event({ key: "Escape" }));
  await harness.finishCancellation();
});

test("starting and pressing Enter on an empty page remains safe", async () => {
  const harness = makeHarness({ emptyPage: true });

  assert.equal(harness.dispatchRuntime("start").payload.active, true);
  assert.deepEqual(harness.elementFromPointCalls, [{ x: 500, y: 350 }]);
  const enter = event({ key: "Enter" });
  harness.document.dispatch("keydown", enter);
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(enter.defaultPrevented, true);
  assert.equal(enter.immediatePropagationStopped, true);
  assert.deepEqual(harness.sentMessages, []);
  assert.deepEqual(harness.errors, []);
  const escape = event({ key: "Escape" });
  harness.document.dispatch("keydown", escape);
  assert.equal(escape.defaultPrevented, true);
  assert.equal(escape.immediatePropagationStopped, true);
  assert.equal(harness.document.getElementById("smartshot-selector-root"), null);
});

test("clicking a nested header button selects its semantic article without pointer movement", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture({ movePointer: false });

  assert.equal(
    harness.sentMessages.filter((message) => message.type === "capture.long.begin").length,
    1
  );
  const begin = harness.sentMessages.find((message) => message.type === "capture.long.begin");
  assert.equal(begin.payload.candidate.kind, "article");
  assert.deepEqual(begin.payload.candidate.pageRect, {
    x: 180,
    y: 100,
    width: 600,
    height: 1_200
  });
  harness.document.dispatch("keydown", event({ key: "Escape" }));
  await harness.finishCancellation();
});

test("pointer movement skips non-semantic roles and defaults to the containing article", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture();

  const begin = harness.sentMessages.find((message) => message.type === "capture.long.begin");
  assert.equal(begin.payload.candidate.kind, "article");
  assert.deepEqual(begin.payload.candidate.pageRect, {
    x: 180,
    y: 100,
    width: 600,
    height: 1_200
  });
  harness.document.dispatch("keydown", event({ key: "Escape" }));
  await harness.finishCancellation();
});

test("Escape cancels an in-flight long capture and immediately restores page styles", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture();
  assert.equal(harness.fixed.style.getPropertyValue("visibility"), "hidden");

  const escape = event({ key: "Escape" });
  harness.document.dispatch("keydown", escape);

  assert.equal(escape.defaultPrevented, true);
  assert.equal(escape.immediatePropagationStopped, true);
  assert.equal(harness.fixed.style.getPropertyValue("visibility"), "");
  await harness.finishCancellation();
  assert.equal(harness.dispatchRuntime("start").payload.active, true);
});

test("selector commands from another controller version are ignored", () => {
  const harness = makeHarness();
  assert.equal(harness.dispatchRuntime("start", SELECTOR_PROTOCOL_VERSION - 2), undefined);
  assert.equal(harness.document.getElementById("smartshot-selector-root"), null);
});

test("selector commands from the previous controller version remain compatible", () => {
  const harness = makeHarness();
  const response = harness.dispatchRuntime("start", SELECTOR_PROTOCOL_VERSION - 1);
  assert.equal(response.payload.active, true);
  assert.equal(response.payload.capturing, false);
  assert.equal(response.payload.selectorProtocolVersion, SELECTOR_PROTOCOL_VERSION - 1);
});

test("selector status is side-effect free", () => {
  const harness = makeHarness();
  assert.equal(harness.dispatchRuntime("status").payload.active, false);
  assert.equal(harness.document.getElementById("smartshot-selector-root"), null);
  assert.equal(harness.dispatchRuntime("start").payload.active, true);
  assert.equal(harness.dispatchRuntime("status").payload.active, true);
});

test("legacy selector commands remain compatible with a cached 0.2.0 background", () => {
  const harness = makeHarness();
  assert.equal(harness.dispatchLegacy("toggle").payload.active, true);
  assert.notEqual(harness.document.getElementById("smartshot-selector-root"), null);
  assert.equal(harness.dispatchLegacy("toggle").payload.active, false);
  assert.equal(harness.document.getElementById("smartshot-selector-root"), null);
  assert.equal(harness.dispatchLegacy("start").payload.active, true);
  assert.equal(harness.dispatchLegacy("stop").payload.active, false);
});

test("a start command during capture cancels the in-flight operation for older backgrounds", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture();
  const status = harness.dispatchRuntime("status");
  assert.equal(status.payload.active, false);
  assert.equal(status.payload.capturing, true);

  const response = harness.dispatchRuntime("start", SELECTOR_PROTOCOL_VERSION - 1);
  assert.equal(response.payload.active, false);
  assert.equal(response.payload.capturing, true);
  await harness.finishCancellation();
});

test("long capture rejects a ready response for another request", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture();
  harness.resolveBegin(Core.makeEnvelope("capture.long.ready", { accepted: true }, "wrong-request"));
  await harness.waitFor(() => harness.errors.length > 0);

  assert.match(String(harness.errors.at(-1)[1]?.message), /another capture request/);
  assert.equal(
    harness.sentMessages.some((message) => message.type === "capture.slice.request"),
    false
  );
});

test("long capture rejects a ready response that was not accepted", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture();
  const begin = harness.sentMessages.find((message) => message.type === "capture.long.begin");
  harness.resolveBegin(Core.makeEnvelope("capture.long.ready", { accepted: false }, begin.requestId));
  await harness.waitFor(() => harness.errors.length > 0);

  assert.match(String(harness.errors.at(-1)[1]?.message), /did not accept/);
  assert.equal(
    harness.sentMessages.some((message) => message.type === "capture.slice.request"),
    false
  );
});

test("long capture rejects an end response that was not completed", async () => {
  const harness = makeHarness({
    sendMessage(message) {
      if (message.type === "capture.long.begin") {
        return Core.makeEnvelope("capture.long.ready", { accepted: true }, message.requestId);
      }
      if (message.type === "capture.slice.request") {
        return Core.makeEnvelope("capture.slice.response", {
          index: message.payload.index,
          imageDataUrl: "data:image/png;base64,frame",
          verificationImageDataUrl: "data:image/png;base64,verification"
        }, message.requestId);
      }
      if (message.type === "capture.long.end") {
        return Core.makeEnvelope("capture.long.ended", { completed: false }, message.requestId);
      }
      throw new Error(`Unexpected content message: ${message.type}`);
    }
  });

  await harness.beginLongCapture();
  await harness.waitFor(() => harness.errors.length > 0);

  assert.match(String(harness.errors.at(-1)[1]?.message), /did not complete/);
  assert.equal(
    harness.sentMessages.some((message) => message.type === "capture.import.request"),
    false
  );
  assert.ok(harness.sentMessages.some((message) => (
    message.type === "capture.long.end" && message.payload.cancelled === false
  )));
});

test("long capture rejects a slice response for another request", async () => {
  const harness = makeHarness({
    sendMessage(message) {
      if (message.type === "capture.long.begin") {
        return Core.makeEnvelope("capture.long.ready", { accepted: true }, message.requestId);
      }
      if (message.type === "capture.slice.request") {
        return Core.makeEnvelope("capture.slice.response", {
          index: message.payload.index,
          imageDataUrl: "data:image/png;base64,frame",
          verificationImageDataUrl: "data:image/png;base64,verification"
        }, "wrong-request");
      }
      if (message.type === "capture.long.end") {
        return Core.makeEnvelope("capture.long.ended", { completed: false }, message.requestId);
      }
      throw new Error(`Unexpected content message: ${message.type}`);
    }
  });

  await harness.beginLongCapture();
  await harness.waitFor(() => harness.errors.length > 0);

  assert.match(String(harness.errors.at(-1)[1]?.message), /another capture request/);
  assert.equal(
    harness.sentMessages.some((message) => message.type === "capture.import.request"),
    false
  );
});

test("visible capture rejects a response for another request", async () => {
  const harness = makeHarness({
    targetHeight: 300,
    sendMessage(message) {
      if (message.type === "capture.request") {
        return Core.makeEnvelope("capture.response", {
          imageDataUrl: "data:image/png;base64,frame"
        }, "wrong-request");
      }
      throw new Error(`Unexpected content message: ${message.type}`);
    }
  });

  await harness.startCapture();
  await harness.waitFor(() => harness.errors.length > 0);

  assert.match(String(harness.errors.at(-1)[1]?.message), /another capture request/);
  assert.equal(
    harness.sentMessages.some((message) => message.type === "capture.import.request"),
    false
  );
});

test("visible capture rejects a response that was not accepted", async () => {
  const harness = makeHarness({
    targetHeight: 300,
    sendMessage(message) {
      if (message.type === "capture.request") {
        return Core.makeEnvelope("capture.response", {
          accepted: false,
          imageDataUrl: "data:image/png;base64,frame"
        }, message.requestId);
      }
      throw new Error(`Unexpected content message: ${message.type}`);
    }
  });

  await harness.startCapture();
  await harness.waitFor(() => harness.errors.length > 0);

  assert.match(String(harness.errors.at(-1)[1]?.message), /No browser capture/);
  assert.equal(
    harness.sentMessages.some((message) => message.type === "capture.import.request"),
    false
  );
});

test("hiding the page cancels long capture and restores scroll and styles", async () => {
  const harness = makeHarness();
  await harness.beginLongCapture();
  harness.window.scrollTo(0, 640);
  harness.document.hidden = true;

  harness.document.dispatch("visibilitychange", event());

  assert.deepEqual({ x: harness.window.scrollX, y: harness.window.scrollY }, { x: 0, y: 0 });
  assert.equal(harness.fixed.style.getPropertyValue("visibility"), "");
  await harness.finishCancellation();
});
