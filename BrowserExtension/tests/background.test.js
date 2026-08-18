"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Core = require("../shared/core.js");

function makeBackground() {
  let messageListener;
  const captures = [];
  const activeTab = { id: 7, windowId: 3 };
  const browser = {
    runtime: {
      onMessage: { addListener(listener) { messageListener = listener; } }
    },
    action: { onClicked: { addListener() {} } },
    tabs: {
      async query() { return [{ ...activeTab }]; },
      async captureVisibleTab(windowId) {
        captures.push(windowId);
        return "data:image/png;base64,frame";
      },
      async sendMessage() {}
    }
  };
  const sandbox = {
    SmartShotCore: Core,
    browser,
    console,
    Date,
    navigator: { userAgent: "Safari" },
    Promise,
    setTimeout,
    clearTimeout,
    importScripts() {}
  };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8"),
    sandbox,
    { filename: "background.js" }
  );

  function dispatch(message, sender = {
    tab: { id: 7, windowId: 3 },
    documentId: "document-1",
    url: "https://x.com/home"
  }) {
    return new Promise((resolve, reject) => {
      try {
        assert.equal(messageListener(message, sender, resolve), true);
      } catch (error) {
        reject(error);
      }
    });
  }

  return { activeTab, captures, dispatch };
}

test("long-capture protocol accepts and completes an ordered one-slice session", async () => {
  const background = makeBackground();
  const requestId = "capture-1";
  const ready = await background.dispatch(Core.makeEnvelope("capture.long.begin", {
    sliceCount: 1
  }, requestId));
  assert.equal(ready.type, "capture.long.ready");

  const slice = await background.dispatch(Core.makeEnvelope("capture.slice.request", {
    index: 0
  }, requestId));
  assert.equal(slice.type, "capture.slice.response");
  assert.equal(slice.payload.imageDataUrl, "data:image/png;base64,frame");

  const ended = await background.dispatch(Core.makeEnvelope("capture.long.end", {
    cancelled: false
  }, requestId));
  assert.equal(ended.type, "capture.long.ended");
  assert.equal(ended.payload.completed, true);
  assert.deepEqual(background.captures, [3]);
});

test("long capture stops when the user changes the active tab", async () => {
  const background = makeBackground();
  const requestId = "capture-2";
  await background.dispatch(Core.makeEnvelope("capture.long.begin", { sliceCount: 1 }, requestId));
  background.activeTab.id = 99;

  const response = await background.dispatch(Core.makeEnvelope("capture.slice.request", {
    index: 0
  }, requestId));
  assert.equal(response.type, "error");
  assert.equal(response.payload.code, "long_capture_failed");
  assert.match(response.payload.message, /active browser tab changed/);
});

test("long capture stops when messages come from a new document", async () => {
  const background = makeBackground();
  const requestId = "capture-3";
  await background.dispatch(Core.makeEnvelope("capture.long.begin", { sliceCount: 1 }, requestId));

  const response = await background.dispatch(
    Core.makeEnvelope("capture.slice.request", { index: 0 }, requestId),
    {
      tab: { id: 7, windowId: 3 },
      documentId: "document-2",
      url: "https://x.com/other"
    }
  );
  assert.equal(response.type, "error");
  assert.match(response.payload.message, /page navigated/);
});

test("long capture rejects missing or out-of-order slices", async () => {
  const background = makeBackground();
  const requestId = "capture-4";
  await background.dispatch(Core.makeEnvelope("capture.long.begin", { sliceCount: 2 }, requestId));

  const response = await background.dispatch(Core.makeEnvelope("capture.slice.request", {
    index: 1
  }, requestId));
  assert.equal(response.type, "error");
  assert.match(response.payload.message, /out of order/);
});
