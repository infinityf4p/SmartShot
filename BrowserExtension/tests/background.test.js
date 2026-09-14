"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Core = require("../shared/core.js");
const Delivery = require("../shared/delivery.js");
const SELECTOR_PROTOCOL_VERSION = Core.SELECTOR_PROTOCOL_VERSION;

function makeBackground(options = {}) {
  let messageListener;
  let actionListener;
  const captures = [];
  const captureTimes = [];
  const nativeMessages = [];
  const downloadRequests = [];
  const scriptExecutions = [];
  const tabMessages = [];
  const actionUpdates = [];
  const selectorDiagnostics = [];
  const activeTab = { id: 7, windowId: 3 };
  let selectorActive = options.selectorActive === true;
  let selectorCapturing = options.selectorCapturing === true;
  function returnAPIResult(task, callback) {
    if (options.api !== "chrome") return Promise.resolve().then(task);
    Promise.resolve().then(task).then(callback, (error) => {
      browser.runtime.lastError = { message: error instanceof Error ? error.message : String(error) };
      callback();
      delete browser.runtime.lastError;
    });
  }
  function returnActionResult(method, details, callback) {
    actionUpdates.push({ method, details });
    if (options.actionSynchronousError) throw options.actionSynchronousError;
    return returnAPIResult(() => {
      if (typeof options.actionHandler === "function") {
        return options.actionHandler(method, details);
      }
      return undefined;
    }, callback);
  }
  const browser = {
    runtime: {
      onMessage: { addListener(listener) { messageListener = listener; } }
    },
    action: {
      onClicked: { addListener(listener) { actionListener = listener; } },
      setBadgeText(details, callback) {
        return returnActionResult("setBadgeText", details, callback);
      },
      setBadgeBackgroundColor(details, callback) {
        return returnActionResult("setBadgeBackgroundColor", details, callback);
      },
      setTitle(details, callback) {
        return returnActionResult("setTitle", details, callback);
      }
    },
    downloads: {
      download(details, callback) {
        downloadRequests.push(details);
        return returnAPIResult(() => {
          if (typeof options.downloadHandler === "function") {
            return options.downloadHandler(details);
          }
          return downloadRequests.length;
        }, callback);
      }
    },
    tabs: {
      query(query, callback) {
        return returnAPIResult(() => {
          const tab = options.activeTabs?.find((item) => item.windowId === query.windowId) || activeTab;
          return [{ ...tab }];
        }, callback);
      },
      captureVisibleTab(windowId, _details, callback) {
        return returnAPIResult(() => {
          const now = Date.now();
          if (options.enforceCaptureQuota && captureTimes.filter((time) => now - time < 1000).length >= 2) {
            throw new Error("This request exceeds the MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND quota.");
          }
          captureTimes.push(now);
          captures.push(windowId);
          if (typeof options.captureHandler === "function") return options.captureHandler(windowId);
          return "data:image/png;base64,frame";
        }, callback);
      },
      sendMessage(tabId, message, callback) {
        tabMessages.push({ tabId, message });
        return returnAPIResult(() => {
          if (typeof options.tabMessageHandler === "function") {
            return options.tabMessageHandler(tabId, message, tabMessages.length - 1);
          }
          const action = message.type === "selection.command"
            ? message.payload.action
            : message.type.split(".").at(-1);
          if (action === "toggle") selectorActive = !selectorActive;
          else if (action === "start") selectorActive = true;
          else if (action === "stop") selectorActive = false;
          return Core.makeEnvelope("selection.state", {
            active: selectorActive,
            capturing: selectorCapturing,
            selectorProtocolVersion: SELECTOR_PROTOCOL_VERSION
          }, message.requestId);
        }, callback);
      }
    },
    scripting: {
      executeScript(details, callback) {
        scriptExecutions.push(details);
        return returnAPIResult(() => {
          if (typeof options.scriptHandler === "function") return options.scriptHandler(details);
          return [];
        }, callback);
      }
    }
  };
  if (typeof options.nativeHandler === "function" && options.api === "chrome") {
    browser.runtime.sendNativeMessage = (host, message, callback) => {
      nativeMessages.push({ host, message });
      Promise.resolve()
        .then(() => options.nativeHandler(host, message))
        .then(callback, (error) => {
          browser.runtime.lastError = { message: error instanceof Error ? error.message : String(error) };
          callback();
          delete browser.runtime.lastError;
        });
    };
  } else if (typeof options.nativeHandler === "function") {
    browser.runtime.sendNativeMessage = (host, message, callback) => {
      if (typeof callback !== "function") return undefined;
      nativeMessages.push({ host, message, callbackProvided: true });
      const returned = Promise.resolve()
        .then(() => options.nativeHandler(host, message));
      if (options.nativeCallbackNeverReturns) {
        returned.catch(() => {});
        return undefined;
      }
      returned.then((result) => {
        const deliver = () => callback(result);
        if (options.nativeCallbackDelay !== undefined) {
          setTimeout(deliver, options.nativeCallbackDelay);
        } else {
          deliver();
        }
      }, (error) => {
        browser.runtime.lastError = { message: error instanceof Error ? error.message : String(error) };
        callback();
        delete browser.runtime.lastError;
      });
      if (!options.nativePromiseAndCallback) return undefined;
      if (Object.prototype.hasOwnProperty.call(options, "nativeReturnedPromiseValue")) {
        return Promise.resolve(options.nativeReturnedPromiseValue);
      }
      if (options.nativeReturnedPromiseError) {
        return Promise.reject(options.nativeReturnedPromiseError);
      }
      return returned;
    };
  }
  const sandboxConsole = Object.create(console);
  sandboxConsole.error = (...args) => selectorDiagnostics.push(args);
  const sandbox = {
    SmartShotCore: Core,
    atob,
    console: sandboxConsole,
    Date,
    navigator: {
      userAgent: options.api === "chrome"
        ? "Mozilla/5.0 Chrome/140.0.0.0 Safari/537.36"
        : "Safari"
    },
    Promise,
    URL,
    setTimeout: options.immediateTimeout
      ? (callback) => setTimeout(callback, 0)
      : setTimeout,
    clearTimeout,
    importScripts() {}
  };
  if (options.api === "chrome") sandbox.chrome = browser;
  else sandbox.browser = browser;
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

  async function clickAction(tab = { id: 7, windowId: 3, url: "https://x.com/home" }) {
    return actionListener(tab);
  }

  return {
    actionUpdates,
    activeTab,
    captures,
    clickAction,
    downloadRequests,
    nativeMessages,
    selectorDiagnostics,
    scriptExecutions,
    tabMessages,
    dispatch
  };
}

function pngDataURL(byteLength = 8) {
  const bytes = Buffer.alloc(Math.max(8, byteLength));
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes);
  return `data:image/png;base64,${bytes.toString("base64")}`;
}

function importAck(message, accepted = true, overrides = {}) {
  const stage = message.type.split(".").at(-1);
  const payload = { accepted, stage };
  if (stage === "chunk") payload.index = message.payload.index;
  return Core.makeEnvelope("capture.import.ack", { ...payload, ...overrides }, message.requestId);
}

function currentSelectorState(message, active, requestId = message.requestId) {
  const version = message.payload?.selectorProtocolVersion || SELECTOR_PROTOCOL_VERSION;
  const payload = { active, selectorProtocolVersion: version };
  if (version >= 3) payload.capturing = false;
  return Core.makeEnvelope("selection.state", payload, requestId);
}

function legacySelectorState(message, active) {
  return Core.makeEnvelope("selection.state", { active }, message.requestId);
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
  assert.equal(slice.payload.verificationImageDataUrl, "data:image/png;base64,frame");

  const ended = await background.dispatch(Core.makeEnvelope("capture.long.end", {
    cancelled: false
  }, requestId));
  assert.equal(ended.type, "capture.long.ended");
  assert.equal(ended.payload.completed, true);
  assert.deepEqual(background.captures, [3, 3]);
});

test("long capture respects Chrome's quota across slices and verification frames", async () => {
  const background = makeBackground({ api: "chrome", enforceCaptureQuota: true });
  const requestId = "quota-long";
  await background.dispatch(Core.makeEnvelope("capture.long.begin", { sliceCount: 2 }, requestId));
  for (const index of [0, 1]) {
    const response = await background.dispatch(Core.makeEnvelope("capture.slice.request", { index }, requestId));
    assert.equal(response.type, "capture.slice.response", response.payload.message);
  }
  const ended = await background.dispatch(Core.makeEnvelope("capture.long.end", { cancelled: false }, requestId));
  assert.equal(ended.payload.completed, true);
  assert.equal(background.captures.length, 4);
});

test("concurrent visible captures share Chrome's quota across windows", async () => {
  const activeTabs = [{ id: 7, windowId: 3 }, { id: 8, windowId: 4 }];
  const background = makeBackground({ api: "chrome", enforceCaptureQuota: true, activeTabs });
  const responses = await Promise.all([0, 1, 0].map((index, request) => background.dispatch(
    Core.makeEnvelope("capture.request", {}, `quota-visible-${request}`),
    { tab: activeTabs[index] }
  )));
  for (const response of responses) assert.equal(response.type, "capture.response", response.payload.message);
  assert.deepEqual(background.captures, [3, 4, 3]);
});

test("capture queue recovers after a browser capture rejects", async () => {
  let attempts = 0;
  const background = makeBackground({
    captureHandler() {
      if (++attempts === 1) throw new Error("Capture unavailable");
      return "data:image/png;base64,recovered";
    }
  });
  const failed = await background.dispatch(Core.makeEnvelope("capture.request", {}, "failed-frame"));
  assert.equal(failed.type, "error");
  const recovered = await background.dispatch(Core.makeEnvelope("capture.request", {}, "recovered-frame"));
  assert.equal(recovered.type, "capture.response");
  assert.equal(recovered.payload.imageDataUrl, "data:image/png;base64,recovered");
});

test("queued capture rechecks the active tab before reading pixels", async () => {
  const background = makeBackground();
  await background.dispatch(Core.makeEnvelope("capture.request", {}, "initial-frame"));
  const queued = background.dispatch(Core.makeEnvelope("capture.request", {}, "queued-frame"));
  await new Promise(setImmediate);
  background.activeTab.id = 8;
  const response = await queued;
  assert.equal(response.type, "error");
  assert.match(response.payload.message, /active browser tab changed/);
  assert.deepEqual(background.captures, [3]);
});

test("cancelling a long session prevents its queued frame from being captured", async () => {
  const background = makeBackground();
  await background.dispatch(Core.makeEnvelope("capture.request", {}, "initial-frame"));
  const requestId = "cancelled-queued-session";
  await background.dispatch(Core.makeEnvelope("capture.long.begin", { sliceCount: 1 }, requestId));
  const queued = background.dispatch(Core.makeEnvelope("capture.slice.request", { index: 0 }, requestId));
  await new Promise(setImmediate);
  await background.dispatch(Core.makeEnvelope("capture.long.end", { cancelled: true }, requestId));
  const response = await queued;
  assert.equal(response.type, "error");
  assert.match(response.payload.message, /session expired/);
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

test("the action probes an inactive current selector before starting it", async () => {
  const background = makeBackground();

  await background.clickAction();

  assert.deepEqual(
    background.tabMessages.map(({ message }) => message.payload.action),
    ["status", "start"]
  );
  assert.equal(background.scriptExecutions.length, 0);
  assert.equal(background.tabMessages[1].message.payload.selectorProtocolVersion, SELECTOR_PROTOCOL_VERSION);
  assert.equal(
    background.actionUpdates.find((update) => update.method === "setBadgeText").details.text,
    ""
  );
});

test("the action probes an active current selector before stopping it", async () => {
  const background = makeBackground({ selectorActive: true });

  await background.clickAction();

  assert.deepEqual(
    background.tabMessages.map(({ message }) => message.payload.action),
    ["status", "stop"]
  );
  assert.equal(background.scriptExecutions.length, 0);
});

test("the action stops an in-flight capture instead of silently starting selection", async () => {
  const background = makeBackground({ selectorCapturing: true });

  await background.clickAction();

  assert.deepEqual(
    background.tabMessages.map(({ message }) => message.payload.action),
    ["status", "stop"]
  );
  assert.equal(background.scriptExecutions.length, 0);
});

test("repeated actions on one tab are serialized as true toggles", async () => {
  const background = makeBackground();

  await Promise.all([background.clickAction(), background.clickAction()]);

  assert.deepEqual(
    background.tabMessages.map(({ message }) => message.payload.action),
    ["status", "start", "status", "stop"]
  );
  assert.equal(background.scriptExecutions.length, 0);
});

test("an explicit state mismatch reinstalls the selector before retrying", async () => {
  let startAttempts = 0;
  const background = makeBackground({
    tabMessageHandler(_tabId, message) {
      if (message.type === "selection.command" && message.payload.action === "status") {
        return currentSelectorState(message, false);
      }
      if (message.type === "selection.command" && message.payload.action === "start") {
        startAttempts += 1;
        return currentSelectorState(message, startAttempts > 1);
      }
      if (message.type === "selection.stop") return legacySelectorState(message, false);
      throw new Error(`Unexpected selector message: ${message.type}`);
    }
  });

  await background.clickAction();

  assert.deepEqual(
    background.tabMessages.map(({ message }) => (
      message.type === "selection.command" ? message.payload.action : message.type
    )),
    ["status", "start", "selection.stop", "start"]
  );
  assert.equal(startAttempts, 2);
  assert.equal(background.scriptExecutions.length, 1);
  assert.equal(
    background.actionUpdates.find((update) => update.method === "setBadgeText").details.text,
    ""
  );
});

test("a queued action continues after the previous action fails", async () => {
  let startAttempts = 0;
  const background = makeBackground({
    tabMessageHandler(_tabId, message) {
      if (message.type === "selection.command" && message.payload.action === "status") {
        return currentSelectorState(message, false);
      }
      if (message.type === "selection.command" && message.payload.action === "start") {
        startAttempts += 1;
        return currentSelectorState(message, startAttempts > 1);
      }
      if (message.type === "selection.stop") return legacySelectorState(message, false);
      throw new Error(`Unexpected selector message: ${message.type}`);
    },
    scriptHandler() {
      throw new Error("Fixture reinjection failure");
    }
  });

  await Promise.all([background.clickAction(), background.clickAction()]);

  assert.deepEqual(
    background.tabMessages.map(({ message }) => (
      message.type === "selection.command" ? message.payload.action : message.type
    )),
    ["status", "start", "selection.stop", "status", "start"]
  );
  assert.equal(startAttempts, 2);
  assert.equal(background.scriptExecutions.length, 1);
});

test("selector actions on different tabs can probe in parallel", async () => {
  const pendingStatus = new Map();
  const background = makeBackground({
    tabMessageHandler(tabId, message) {
      if (message.type === "selection.command" && message.payload.action === "status") {
        return new Promise((resolve) => {
          pendingStatus.set(tabId, { message, resolve });
        });
      }
      if (message.type === "selection.command" && message.payload.action === "start") {
        return currentSelectorState(message, true);
      }
      throw new Error(`Unexpected selector message: ${message.type}`);
    }
  });

  const first = background.clickAction({ id: 7, windowId: 3, url: "https://example.com/one" });
  const second = background.clickAction({ id: 8, windowId: 3, url: "https://example.com/two" });
  for (let attempt = 0; attempt < 10 && pendingStatus.size < 2; attempt += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }

  assert.deepEqual(Array.from(pendingStatus.keys()).sort(), [7, 8]);
  for (const { message, resolve } of pendingStatus.values()) {
    resolve(currentSelectorState(message, false));
  }
  await Promise.all([first, second]);

  for (const tabId of [7, 8]) {
    assert.deepEqual(
      background.tabMessages
        .filter((entry) => entry.tabId === tabId)
        .map(({ message }) => message.payload.action),
      ["status", "start"]
    );
  }
  assert.equal(background.scriptExecutions.length, 0);
});

test("the action injects the selector into an already-open web page with no receiver", async () => {
  const background = makeBackground({
    tabMessageHandler(_tabId, message, index) {
      if (index < 5) throw new Error("Could not establish connection. Receiving end does not exist.");
      return currentSelectorState(message, true);
    }
  });

  await background.clickAction();

  assert.deepEqual(
    background.tabMessages.map(({ message }) => (
      message.type === "selection.command" ? message.payload.action : message.type
    )),
    ["status", "toggle", "toggle", "selection.toggle", "selection.stop", "start"]
  );
  assert.deepEqual(JSON.parse(JSON.stringify(background.scriptExecutions)), [{
    target: { tabId: 7, allFrames: false },
    files: [
      "shared/core.js",
      "shared/selection.js",
      "shared/capture-guards.js",
      "shared/delivery.js",
      "content.js"
    ]
  }]);
  const finalActionUpdate = background.actionUpdates.at(-1);
  assert.equal(finalActionUpdate.method, "setTitle");
  assert.equal(finalActionUpdate.details.tabId, 7);
  assert.equal(finalActionUpdate.details.title, "Select a content block");
});

test("injection waits for Safari message routing before starting the selector", async () => {
  let injected = false;
  let startAttempts = 0;
  const background = makeBackground({
    immediateTimeout: true,
    tabMessageHandler(_tabId, message) {
      if (!injected) throw new Error("Could not establish connection. Receiving end does not exist.");
      const action = message.type === "selection.command" ? message.payload.action : message.type;
      if (action === "start") {
        startAttempts += 1;
        if (startAttempts === 1) throw new Error("Could not establish connection. Receiving end does not exist.");
        return currentSelectorState(message, true);
      }
      if (action === "status") return currentSelectorState(message, false);
      throw new Error(`Unexpected selector message: ${message.type}`);
    },
    scriptHandler() {
      injected = true;
      return [];
    }
  });

  await background.clickAction();

  assert.equal(background.scriptExecutions.length, 1);
  assert.equal(startAttempts, 2);
  assert.deepEqual(
    background.tabMessages.slice(-3).map(({ message }) => message.payload.action),
    ["start", "status", "start"]
  );
  assert.deepEqual(background.selectorDiagnostics, []);
  assert.equal(
    background.actionUpdates.find((update) => update.method === "setBadgeText").details.text,
    ""
  );
});

test("an injection result error is reported with a sanitized inject stage", async () => {
  const secret = "https://private.example/account/42";
  const background = makeBackground({
    tabMessageHandler() {
      throw new Error("Could not establish connection. Receiving end does not exist.");
    },
    scriptHandler() {
      return [{ frameId: 0, error: `Evaluation failed in ${secret}` }];
    }
  });

  await background.clickAction();

  assert.equal(background.scriptExecutions.length, 1);
  assert.equal(background.selectorDiagnostics.length, 1);
  const diagnosticText = background.selectorDiagnostics[0].join(" ");
  assert.match(diagnosticText, /"stage":"inject"/);
  assert.match(diagnosticText, /"tabId":7/);
  assert.equal(diagnosticText.includes(secret), false);
});

test("feedback API failures preserve the original stage without leaking details", async () => {
  const privatePage = "https://private.example/messages/secret";
  const background = makeBackground({
    tabMessageHandler() {
      throw new Error("Could not establish connection. Receiving end does not exist.");
    },
    scriptHandler() {
      throw new Error(`Permission denied for ${privatePage}`);
    },
    actionSynchronousError: new Error(`Toolbar update failed for ${privatePage}`)
  });

  await background.clickAction();

  const diagnosticText = background.selectorDiagnostics.map((args) => args.join(" ")).join("\n");
  assert.match(diagnosticText, /"stage":"inject"/);
  assert.match(diagnosticText, /"stage":"feedback"/);
  assert.equal(diagnosticText.includes(privatePage), false);
  assert.equal(background.actionUpdates.length, 3);
});

test("migration preserves toggle-off when a legacy selector was active", async () => {
  let legacyActive = true;
  const background = makeBackground({
    tabMessageHandler(_tabId, message) {
      if (message.type === "selection.command" && message.payload.action === "status") return undefined;
      if (message.type === "selection.toggle") {
        legacyActive = !legacyActive;
        return legacySelectorState(message, legacyActive);
      }
      if (message.type === "selection.stop") {
        legacyActive = false;
        return legacySelectorState(message, false);
      }
      if (message.type === "selection.command" && message.payload.action === "stop") {
        return currentSelectorState(message, false);
      }
      throw new Error(`Unexpected selector message: ${message.type}`);
    }
  });

  await background.clickAction();

  assert.equal(background.scriptExecutions.length, 1);
  assert.deepEqual(
    background.tabMessages.map(({ message }) => (
      message.type === "selection.command" ? message.payload.action : message.type
    )),
    ["status", "toggle", "toggle", "selection.toggle", "selection.stop", "stop"]
  );
  assert.equal(legacyActive, false);
});

test("migration preserves toggle-on when a legacy selector was inactive", async () => {
  let legacyActive = false;
  const background = makeBackground({
    tabMessageHandler(_tabId, message) {
      if (message.type === "selection.command" && message.payload.action === "status") return undefined;
      if (message.type === "selection.toggle") {
        legacyActive = !legacyActive;
        return legacySelectorState(message, legacyActive);
      }
      if (message.type === "selection.stop") {
        legacyActive = false;
        return legacySelectorState(message, false);
      }
      if (message.type === "selection.command" && message.payload.action === "start") {
        return currentSelectorState(message, true);
      }
      throw new Error(`Unexpected selector message: ${message.type}`);
    }
  });

  await background.clickAction();

  assert.equal(background.scriptExecutions.length, 1);
  assert.deepEqual(
    background.tabMessages.map(({ message }) => (
      message.type === "selection.command" ? message.payload.action : message.type
    )),
    ["status", "toggle", "toggle", "selection.toggle", "selection.stop", "start"]
  );
});

test("migration preserves state from a versioned receiver without status support", async () => {
  let active = true;
  const background = makeBackground({
    tabMessageHandler(_tabId, message) {
      if (message.type === "selection.command" && message.payload.action === "status") return undefined;
      if (message.type === "selection.command" &&
          message.payload.action === "toggle" &&
          message.payload.selectorProtocolVersion === SELECTOR_PROTOCOL_VERSION) {
        return undefined;
      }
      if (message.type === "selection.command" &&
          message.payload.action === "toggle" &&
          message.payload.selectorProtocolVersion === SELECTOR_PROTOCOL_VERSION - 1) {
        active = !active;
        return currentSelectorState(message, active);
      }
      if (message.type === "selection.stop") {
        active = false;
        return legacySelectorState(message, false);
      }
      if (message.type === "selection.command" && message.payload.action === "stop") {
        return currentSelectorState(message, false);
      }
      throw new Error(`Unexpected selector message: ${message.type}`);
    }
  });

  await background.clickAction();

  assert.deepEqual(
    background.tabMessages.map(({ message }) => (
      message.type === "selection.command" ? message.payload.action : message.type
    )),
    ["status", "toggle", "toggle", "selection.stop", "stop"]
  );
  assert.equal(active, false);
  assert.equal(background.scriptExecutions.length, 1);
});

test("the action replaces a selector state with the wrong request ID", async () => {
  const background = makeBackground({
    tabMessageHandler(_tabId, message, index) {
      if (index === 0) return currentSelectorState(message, false, "wrong-request");
      if (message.type === "selection.toggle") return undefined;
      if (message.type === "selection.stop") return legacySelectorState(message, false);
      return currentSelectorState(message, true);
    }
  });

  await background.clickAction();

  assert.equal(background.scriptExecutions.length, 1);
  assert.equal(background.tabMessages.length, 4);
  assert.equal(background.tabMessages.at(-1).message.payload.action, "start");
});

test("the action reports a selector that remains invalid after reinjection", async () => {
  const background = makeBackground({
    immediateTimeout: true,
    tabMessageHandler() { return undefined; }
  });

  await background.clickAction();

  assert.equal(background.scriptExecutions.length, 1);
  assert.equal(background.tabMessages.length, 9);
  assert.match(background.selectorDiagnostics[0].join(" "), /"stage":"ready"/);
  assert.equal(
    background.actionUpdates.find((update) => update.method === "setBadgeText").details.text,
    "!"
  );
  assert.match(
    background.actionUpdates.find((update) => update.method === "setTitle").details.title,
    /could not start/
  );
});

test("the action does not attempt script injection into browser-internal pages", async () => {
  const background = makeBackground({
    tabMessageHandler() {
      throw new Error("Cannot access a chrome:// URL");
    }
  });

  await background.clickAction({ id: 7, windowId: 3, url: "chrome://extensions" });

  assert.equal(background.tabMessages.length, 1);
  assert.deepEqual(background.scriptExecutions, []);
  assert.equal(
    background.actionUpdates.find((update) => update.method === "setBadgeText").details.text,
    "!"
  );
  assert.match(
    background.actionUpdates.find((update) => update.method === "setTitle").details.title,
    /cannot run on this browser page/
  );
});

test("the action reports missing Website Access on the toolbar", async () => {
  const background = makeBackground({
    tabMessageHandler() {
      throw new Error("Cannot access contents of the page. Extension manifest must request permission.");
    },
    scriptHandler() {
      throw new Error("Permission denied for this site");
    }
  });

  await background.clickAction();

  assert.match(
    background.actionUpdates.find((update) => update.method === "setTitle").details.title,
    /needs website access/
  );
});

test("Chromium callback APIs inject and retry the action on an existing page", async () => {
  const background = makeBackground({
    api: "chrome",
    tabMessageHandler(_tabId, message, index) {
      if (index < 5) throw new Error("Receiving end does not exist.");
      return currentSelectorState(message, true);
    }
  });

  await background.clickAction();

  assert.equal(background.tabMessages.length, 6);
  assert.equal(background.scriptExecutions.length, 1);
  assert.equal(background.scriptExecutions[0].target.tabId, 7);
});

test("native import sanitizes metadata and sends bounded chunks in order", async () => {
  const background = makeBackground({
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const imageDataUrl = pngDataURL(200000);
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl,
    filename: "../X: post? ",
    kind: "X Post<script>",
    sourceOrigin: "https://user:secret@x.com/example/status/1?private=yes#replies",
    logicalWidth: 598.5,
    logicalHeight: 1740.25,
    author: "must not cross the native boundary",
    body: "must not cross the native boundary"
  }, "9dcdf9ca-02c9-44d7-9a16-0a56528fd9d3"));

  assert.equal(response.type, "capture.import.response");
  assert.equal(response.payload.accepted, true);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.chunk", "capture.import.end"]
  );
  assert.ok(background.nativeMessages.every(({ host }) => host === "com.infinityf4p.SmartShot"));

  const begin = background.nativeMessages[0].message;
  assert.equal(begin.requestId, "9dcdf9ca-02c9-44d7-9a16-0a56528fd9d3");
  assert.equal(begin.payload.sourceOrigin, "https://x.com");
  assert.equal(begin.payload.kind, "x-post-script");
  assert.equal(begin.payload.filename.includes("/"), false);
  assert.equal(begin.payload.chunkCount, 2);
  assert.equal(begin.payload.base64Length, imageDataUrl.split(",")[1].length);
  assert.equal(begin.payload.logicalWidth, 598.5);
  assert.equal(begin.payload.logicalHeight, 1740.25);
  assert.deepEqual(Object.keys(begin.payload).sort(), [
    "base64Length", "byteLength", "chunkCount", "encoding", "filename", "kind",
    "logicalHeight", "logicalWidth", "mimeType", "sourceOrigin"
  ]);

  const chunks = background.nativeMessages.slice(1, -1).map(({ message }) => message);
  assert.deepEqual(chunks.map((message) => message.payload.index), [0, 1]);
  assert.ok(chunks.every((message) => message.payload.data.length <= 192 * 1024));
  assert.equal(chunks.map((message) => message.payload.data).join(""), imageDataUrl.split(",")[1]);
});

test("concurrent and completed duplicate imports share one native task", async () => {
  let signalBeginStarted;
  const beginStarted = new Promise((resolve) => { signalBeginStarted = resolve; });
  let releaseBegin;
  const beginGate = new Promise((resolve) => { releaseBegin = resolve; });
  const background = makeBackground({
    api: "chrome",
    async nativeHandler(_host, message) {
      if (message.type === "capture.import.begin") {
        signalBeginStarted();
        await beginGate;
      }
      return importAck(message);
    }
  });
  const request = Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com/article",
    logicalWidth: 400,
    logicalHeight: 300
  }, "7a2f2fc3-ab84-4a0d-9c16-354be8666f23");

  const first = background.dispatch(request);
  await beginStarted;
  const second = background.dispatch(request);
  releaseBegin();
  const [firstResponse, secondResponse] = await Promise.all([first, second]);
  const completedResponse = await background.dispatch(request);

  assert.strictEqual(secondResponse, firstResponse);
  assert.strictEqual(completedResponse, firstResponse);
  assert.equal(firstResponse.payload.accepted, true);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.end"]
  );
  assert.equal(background.downloadRequests.length, 0);
});

test("duplicate imports share one completed background download fallback", async () => {
  const background = makeBackground({
    api: "chrome",
    nativeHandler() {
      throw new Error("Native host unavailable.");
    }
  });
  const request = Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com/article",
    logicalWidth: 400,
    logicalHeight: 300
  }, "85078192-dba1-4cf4-867a-55a65966669f");

  const [firstResponse, secondResponse] = await Promise.all([
    background.dispatch(request),
    background.dispatch(request)
  ]);
  const completedResponse = await background.dispatch(request);

  assert.strictEqual(secondResponse, firstResponse);
  assert.strictEqual(completedResponse, firstResponse);
  assert.equal(firstResponse.payload.handledBy, "browser");
  assert.equal(firstResponse.payload.downloaded, true);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin"]
  );
  assert.equal(background.downloadRequests.length, 1);
});

test("native import stops on a rejected chunk and returns a browser fallback", async () => {
  const background = makeBackground({
    nativeHandler(_host, message) {
      if (message.type === "capture.import.chunk") return importAck(message, false);
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "x-post",
    sourceOrigin: "https://x.com",
    logicalWidth: 600,
    logicalHeight: 1200
  }, "8a79fb0d-cf1b-4948-8117-1f85bb8f638c"));

  assert.equal(response.type, "capture.import.response");
  assert.equal(response.payload.accepted, false);
  assert.equal(response.payload.handledBy, "browser");
  assert.equal(response.payload.downloaded, true);
  assert.equal(background.downloadRequests.length, 1);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk"]
  );
});

test("Chromium callback-style native messaging completes the ordered import", async () => {
  const background = makeBackground({
    api: "chrome",
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com/private",
    logicalWidth: 400,
    logicalHeight: 300
  }, "5af283f5-1e16-40e5-9699-a7baa4fe2d8c"));

  assert.equal(response.payload.accepted, true);
  assert.ok(background.nativeMessages.every(({ host }) => host === "com.infinityf4p.smartshot"));
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.end"]
  );
});

test("native import rejects a mismatched acknowledgement request ID", async () => {
  const background = makeBackground({
    nativeHandler(_host, message) {
      return Core.makeEnvelope("capture.import.ack", {
        accepted: true,
        stage: "begin"
      }, `${message.requestId}-wrong`);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com/private/path",
    logicalWidth: 400,
    logicalHeight: 300
  }, "70c37666-834c-4f0b-8f1e-268fbca742d7"));

  assert.equal(response.payload.accepted, false);
  assert.equal(background.nativeMessages.length, 1);
});

test("native host failures and invalid PNG data return a browser fallback", async () => {
  const failedNative = makeBackground({
    nativeHandler() {
      throw new Error("native host unavailable");
    }
  });
  const request = Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "3887db24-c2d8-4522-b106-5693dd79217e");
  const failedResponse = await failedNative.dispatch(request);
  assert.equal(failedResponse.payload.accepted, false);
  assert.equal(failedNative.nativeMessages.length, 1);

  const invalidPNG = makeBackground({ nativeHandler() { throw new Error("must not be called"); } });
  const invalidResponse = await invalidPNG.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: "data:image/png;base64,bm90IGEgcG5n",
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "18032a35-cfab-4fa0-84e3-84cf6db42822"));
  assert.equal(invalidResponse.payload.accepted, false);
  assert.equal(invalidPNG.nativeMessages.length, 0);

  const invalidDimensions = makeBackground({ nativeHandler() { throw new Error("must not be called"); } });
  const invalidDimensionsResponse = await invalidDimensions.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 20001,
    logicalHeight: 300
  }, "9748c53a-b37d-42c4-8259-6c493d3730aa"));
  assert.equal(invalidDimensionsResponse.payload.accepted, false);
  assert.equal(invalidDimensions.nativeMessages.length, 0);

  const booleanDimensions = makeBackground({ nativeHandler() { throw new Error("must not be called"); } });
  const booleanDimensionsResponse = await booleanDimensions.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: true,
    logicalHeight: 300
  }, "94a6d875-3a90-441c-b651-682b12d02d21"));
  assert.equal(booleanDimensionsResponse.payload.accepted, false);
  assert.equal(booleanDimensions.nativeMessages.length, 0);
});

test("native import fails closed at rejected or malformed protocol stages", async (t) => {
  const cases = [
    {
      name: "rejected begin",
      expectedTypes: ["capture.import.begin"],
      response(message) {
        return importAck(message, false);
      }
    },
    {
      name: "wrong chunk index",
      expectedTypes: ["capture.import.begin", "capture.import.chunk"],
      response(message) {
        if (message.type === "capture.import.chunk") {
          return importAck(message, true, { index: message.payload.index + 1 });
        }
        return importAck(message);
      }
    },
    {
      name: "rejected end",
      expectedTypes: ["capture.import.begin", "capture.import.chunk", "capture.import.end"],
      response(message) {
        return importAck(message, message.type !== "capture.import.end");
      }
    }
  ];

  for (const scenario of cases) {
    await t.test(scenario.name, async () => {
      const background = makeBackground({ nativeHandler: (_host, message) => scenario.response(message) });
      const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
        imageDataUrl: pngDataURL(32),
        filename: "capture",
        kind: "block",
        sourceOrigin: "https://example.com/private",
        logicalWidth: 400,
        logicalHeight: 300
      }, "7f60c982-fbaf-45d8-b7ef-bcbc83c73f11"));

      assert.equal(response.payload.accepted, false);
      assert.equal(response.payload.handledBy, "browser");
      assert.deepEqual(
        background.nativeMessages.map(({ message }) => message.type),
        scenario.expectedTypes
      );
    });
  }
});

test("missing, callback-failed, and timed-out native hosts return fallback responses", async (t) => {
  const payload = {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  };

  await t.test("missing host API", async () => {
    const background = makeBackground();
    const response = await background.dispatch(Core.makeEnvelope(
      "capture.import.request",
      payload,
      "1c441320-ee31-4fbf-a88a-2781e43da18a"
    ));
    assert.equal(response.payload.accepted, false);
    assert.equal(background.nativeMessages.length, 0);
  });

  await t.test("Chromium runtime.lastError", async () => {
    const background = makeBackground({
      api: "chrome",
      nativeHandler() {
        throw new Error("Specified native messaging host not found.");
      }
    });
    const response = await background.dispatch(Core.makeEnvelope(
      "capture.import.request",
      payload,
      "09a24acc-7194-4c6d-bef9-77747d3750f8"
    ));
    assert.equal(response.payload.accepted, false);
    assert.equal(background.nativeMessages.length, 1);
  });

  await t.test("native timeout", async () => {
    const background = makeBackground({
      immediateTimeout: true,
      nativeHandler() {
        return new Promise(() => {});
      }
    });
    const response = await background.dispatch(Core.makeEnvelope(
      "capture.import.request",
      payload,
      "7e38b616-9484-424a-8e5b-648be11bbbe4"
    ));
    assert.equal(response.payload.accepted, false);
    assert.equal(background.nativeMessages.length, 1);
  });
});

test("Safari native messaging uses the callback overload and completes import", async () => {
  const background = makeBackground({
    nativeCallbackOnly: true,
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "ff0fa898-65e5-4a53-9136-35d04b490854"));

  assert.equal(response.payload.accepted, true);
  assert.equal(response.payload.handledBy, "native");
  assert.deepEqual(
    background.nativeMessages.map(({ host, message, callbackProvided }) => ({
      host,
      type: message.type,
      callbackProvided
    })),
    [
      { host: Core.NATIVE_HOSTS.safari, type: "capture.import.begin", callbackProvided: true },
      { host: Core.NATIVE_HOSTS.safari, type: "capture.import.chunk", callbackProvided: true },
      { host: Core.NATIVE_HOSTS.safari, type: "capture.import.end", callbackProvided: true }
    ]
  );
});

test("Safari runtime.lastError falls back to one browser download", async () => {
  const imageDataUrl = pngDataURL(32);
  const background = makeBackground({
    nativeCallbackOnly: true,
    nativeHandler() {
      throw new Error("Safari native host rejected the message.");
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl,
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "0bd0fbdb-f1c4-4ad5-848a-cd9fc6ae45af"));

  assert.equal(response.payload.accepted, false);
  assert.equal(response.payload.handledBy, "browser");
  assert.equal(response.payload.downloaded, true);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin"]
  );
  assert.equal(background.downloadRequests.length, 1);
  assert.equal(background.downloadRequests[0].url, imageDataUrl);
});

test("Safari callback timeout falls back to one browser download", async () => {
  const imageDataUrl = pngDataURL(32);
  const background = makeBackground({
    immediateTimeout: true,
    nativeCallbackOnly: true,
    nativeCallbackNeverReturns: true,
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl,
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "d4267d4a-0484-4099-999a-388cd75ce57d"));

  assert.equal(response.payload.accepted, false);
  assert.equal(response.payload.handledBy, "browser");
  assert.equal(response.payload.downloaded, true);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin"]
  );
  assert.equal(background.downloadRequests.length, 1);
  assert.equal(background.downloadRequests[0].url, imageDataUrl);
});

test("Safari Promise and callback completion settles each import stage once", async () => {
  const background = makeBackground({
    nativeCallbackOnly: true,
    nativePromiseAndCallback: true,
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "243d797a-ea65-45f6-a982-3db5e86897e8"));

  assert.equal(response.payload.accepted, true);
  assert.equal(response.payload.handledBy, "native");
  assert.equal(response.payload.downloaded, false);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.end"]
  );
  assert.ok(background.nativeMessages.every(({ callbackProvided }) => callbackProvided === true));
  assert.equal(background.downloadRequests.length, 0);
});

test("Safari ignores an early empty Promise result and waits for the callback ACK", async () => {
  const background = makeBackground({
    nativeCallbackOnly: true,
    nativePromiseAndCallback: true,
    nativeReturnedPromiseValue: undefined,
    nativeCallbackDelay: 0,
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "2a676c2e-3ea2-4fd9-a095-86e9bd208b7d"));

  assert.equal(response.payload.accepted, true);
  assert.equal(response.payload.handledBy, "native");
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.end"]
  );
  assert.equal(background.downloadRequests.length, 0);
});

test("Safari ignores a returned Promise rejection and waits for the callback ACK", async () => {
  const background = makeBackground({
    nativeCallbackOnly: true,
    nativePromiseAndCallback: true,
    nativeReturnedPromiseError: new Error("Safari Promise path rejected"),
    nativeCallbackDelay: 0,
    nativeHandler(_host, message) {
      return importAck(message);
    }
  });
  const response = await background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl: pngDataURL(32),
    filename: "capture",
    kind: "block",
    sourceOrigin: "https://example.com",
    logicalWidth: 400,
    logicalHeight: 300
  }, "a84080cf-ce88-4ccb-b10a-8cfeeb949630"));

  assert.equal(response.payload.accepted, true);
  assert.equal(response.payload.handledBy, "native");
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.end"]
  );
  assert.equal(background.downloadRequests.length, 0);
});

test("a native failure after accepted chunks still downloads the completed PNG", async () => {
  const background = makeBackground({
    nativeHandler(_host, message) {
      if (message.type === "capture.import.chunk" && message.payload.index === 1) {
        throw new Error("native host exited during transfer");
      }
      return importAck(message);
    }
  });
  const imageDataUrl = pngDataURL(200000);
  const downloads = [];

  const result = await Delivery.importOrDownload({
    imageDataUrl,
    filename: "x-post",
    kind: "x-post",
    sourceOrigin: "https://x.com/user/status/1?private=yes",
    logicalWidth: 600,
    logicalHeight: 1800,
    makeEnvelope: Core.makeEnvelope,
    isEnvelope: Core.isEnvelope,
    sendMessage: (message) => background.dispatch(message),
    download(data, filename) {
      downloads.push({ data, filename });
    }
  });

  assert.deepEqual(result, { handledBy: "browser" });
  assert.deepEqual(downloads, []);
  assert.equal(background.downloadRequests.length, 1);
  assert.equal(background.downloadRequests[0].url, imageDataUrl);
  assert.equal(background.downloadRequests[0].filename, "x-post.png");
  assert.equal(background.downloadRequests[0].conflictAction, "uniquify");
  assert.equal(background.downloadRequests[0].saveAs, false);
  assert.deepEqual(
    background.nativeMessages.map(({ message }) => message.type),
    ["capture.import.begin", "capture.import.chunk", "capture.import.chunk"]
  );
});

test("background fallback survives the content document closing during native import", async () => {
  let signalEndStarted;
  const endStarted = new Promise((resolve) => { signalEndStarted = resolve; });
  let finishEnd;
  const background = makeBackground({
    nativeHandler(_host, message) {
      if (message.type !== "capture.import.end") return importAck(message);
      signalEndStarted();
      return new Promise((resolve) => {
        finishEnd = () => resolve(importAck(message, false));
      });
    }
  });
  const imageDataUrl = pngDataURL(64);
  const pendingResponse = background.dispatch(Core.makeEnvelope("capture.import.request", {
    imageDataUrl,
    filename: "closed-page",
    kind: "block",
    sourceOrigin: "https://example.com/article",
    logicalWidth: 640,
    logicalHeight: 1200
  }, "6ebd76c9-4a42-49fd-88c4-7a86c2ec138f"));

  await endStarted;
  // The background worker owns the fallback; no content-script callback is needed here.
  finishEnd();
  const response = await pendingResponse;

  assert.equal(response.payload.accepted, false);
  assert.equal(response.payload.handledBy, "browser");
  assert.equal(response.payload.downloaded, true);
  assert.equal(background.downloadRequests.length, 1);
  assert.equal(background.downloadRequests[0].url, imageDataUrl);
  assert.equal(background.downloadRequests[0].filename, "closed-page.png");
});
