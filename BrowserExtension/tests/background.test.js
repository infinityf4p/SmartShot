"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Core = require("../shared/core.js");
const Delivery = require("../shared/delivery.js");

function makeBackground(options = {}) {
  let messageListener;
  let actionListener;
  const captures = [];
  const nativeMessages = [];
  const downloadRequests = [];
  const scriptExecutions = [];
  const tabMessages = [];
  const actionUpdates = [];
  const activeTab = { id: 7, windowId: 3 };
  function returnAPIResult(task, callback) {
    if (options.api !== "chrome") return Promise.resolve().then(task);
    Promise.resolve().then(task).then(callback, (error) => {
      browser.runtime.lastError = { message: error instanceof Error ? error.message : String(error) };
      callback();
      delete browser.runtime.lastError;
    });
  }
  const browser = {
    runtime: {
      onMessage: { addListener(listener) { messageListener = listener; } }
    },
    action: {
      onClicked: { addListener(listener) { actionListener = listener; } },
      setBadgeText(details, callback) {
        actionUpdates.push({ method: "setBadgeText", details });
        return returnAPIResult(() => undefined, callback);
      },
      setBadgeBackgroundColor(details, callback) {
        actionUpdates.push({ method: "setBadgeBackgroundColor", details });
        return returnAPIResult(() => undefined, callback);
      },
      setTitle(details, callback) {
        actionUpdates.push({ method: "setTitle", details });
        return returnAPIResult(() => undefined, callback);
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
      async query() { return [{ ...activeTab }]; },
      async captureVisibleTab(windowId) {
        captures.push(windowId);
        return "data:image/png;base64,frame";
      },
      sendMessage(tabId, message, callback) {
        tabMessages.push({ tabId, message });
        return returnAPIResult(() => {
          if (typeof options.tabMessageHandler === "function") {
            return options.tabMessageHandler(tabId, message, tabMessages.length - 1);
          }
          return Core.makeEnvelope("selection.state", { active: true }, message.requestId);
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
    browser.runtime.sendNativeMessage = async (host, message) => {
      nativeMessages.push({ host, message });
      return options.nativeHandler(host, message);
    };
  }
  const sandbox = {
    SmartShotCore: Core,
    atob,
    console,
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

test("the action injects the selector into an already-open web page and retries once", async () => {
  const background = makeBackground({
    tabMessageHandler(_tabId, _message, index) {
      if (index === 0) throw new Error("Could not establish connection. Receiving end does not exist.");
      return Core.makeEnvelope("selection.state", { active: true }, _message.requestId);
    }
  });

  await background.clickAction();

  assert.equal(background.tabMessages.length, 2);
  assert.equal(background.tabMessages[0].message.requestId, background.tabMessages[1].message.requestId);
  assert.equal(background.tabMessages[1].message.type, "selection.toggle");
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
      if (index === 0) throw new Error("Receiving end does not exist.");
      return Core.makeEnvelope("selection.state", { active: true }, message.requestId);
    }
  });

  await background.clickAction();

  assert.equal(background.tabMessages.length, 2);
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
