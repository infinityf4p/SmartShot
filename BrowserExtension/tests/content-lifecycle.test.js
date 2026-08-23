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

function makeHarness() {
  let runtimeListener;
  let resolveBegin;
  const beginGate = new Promise((resolve) => { resolveBegin = resolve; });
  const sentMessages = [];
  const documentEvents = new FixtureEventTarget();
  const windowEvents = new FixtureEventTarget();
  const html = decorateElement(new FixtureElement("html", {
    rect: { width: 1_000, height: 3_000 },
    clientWidth: 1_000,
    clientHeight: 700,
    scrollWidth: 1_000,
    scrollHeight: 3_000
  }));
  const target = decorateElement(new FixtureElement("article", {
    attributes: { "data-testid": "tweet" },
    rect: { x: 180, y: 100, width: 600, height: 1_200 }
  }));
  const fixed = decorateElement(new FixtureElement("nav", {
    computed: { position: "fixed" }
  }));
  html.append(target, fixed);

  const document = new FixtureDocument(html);
  document.body = html;
  document.hidden = false;
  document.addEventListener = documentEvents.addEventListener.bind(documentEvents);
  document.removeEventListener = documentEvents.removeEventListener.bind(documentEvents);
  document.dispatch = documentEvents.dispatch.bind(documentEvents);
  document.elementFromPoint = () => target;
  document.getElementById = (id) => flatten(html).find((element) => element.id === id) || null;
  document.createElement = (localName) => decorateElement(new FixtureElement(localName, {
    rect: { width: 0, height: 0 }
  }));

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

  const browser = {
    runtime: {
      onMessage: { addListener(listener) { runtimeListener = listener; } },
      async sendMessage(message) {
        sentMessages.push(message);
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
    console: { error() {} },
    Date,
    document,
    getComputedStyle: computedStyleFor,
    Image: class {},
    innerHeight: window.innerHeight,
    innerWidth: window.innerWidth,
    location: { href: "https://x.com/person/status/123?private=yes" },
    performance: { now: () => Date.now() },
    Promise,
    requestAnimationFrame(callback) {
      return setImmediate(() => callback(Date.now()));
    },
    setTimeout,
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

  function dispatchRuntime(type) {
    const message = Core.makeEnvelope(type, {});
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

  async function beginLongCapture() {
    assert.equal(dispatchRuntime("selection.start").payload.active, true);
    document.dispatch("pointermove", event({ clientX: 300, clientY: 200 }));
    await waitFor(() => document.getElementById("smartshot-selector-root") !== null);
    await new Promise((resolve) => setImmediate(resolve));
    document.dispatch("click", event());
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
    dispatchRuntime,
    document,
    finishCancellation,
    fixed,
    sentMessages,
    window
  };
}

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
  assert.equal(harness.dispatchRuntime("selection.start").payload.active, true);
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
