"use strict";

importScripts("shared/core.js");

const extensionApi = globalThis.browser || globalThis.chrome;
const Core = globalThis.SmartShotCore;
const isPromiseApi = typeof globalThis.browser !== "undefined";
const longCaptureSessions = new Map();
const SLICE_INTERVAL_MS = 550;

function invoke(object, method, args) {
  if (isPromiseApi) {
    return Promise.resolve(object[method](...args));
  }

  return new Promise((resolve, reject) => {
    object[method](...args, (result) => {
      const error = globalThis.chrome && chrome.runtime.lastError;
      if (error) reject(new Error(error.message));
      else resolve(result);
    });
  });
}

function nativeHostName() {
  const userAgent = typeof navigator !== "undefined" ? navigator.userAgent : "";
  const safari = /Safari/i.test(userAgent) && !/(Chrome|Chromium|Edg)/i.test(userAgent);
  return safari ? Core.NATIVE_HOSTS.safari : Core.NATIVE_HOSTS.chromium;
}

function nativeAccepted(response) {
  if (Core.isEnvelope(response, "capture.response")) {
    return response.payload.accepted === true || response.payload.handledBy === "native";
  }
  return Boolean(response && response.accepted === true);
}

async function tryNativeCapture(request) {
  if (!extensionApi.runtime.sendNativeMessage) return null;

  try {
    const response = await invoke(extensionApi.runtime, "sendNativeMessage", [nativeHostName(), request]);
    return nativeAccepted(response) ? response : null;
  } catch (_error) {
    return null;
  }
}

async function captureVisible(sender) {
  if (!extensionApi.tabs || typeof extensionApi.tabs.captureVisibleTab !== "function") {
    throw new Error("This browser requires the SmartShot native app for capture.");
  }
  if (!sender.tab || typeof sender.tab.windowId !== "number") {
    throw new Error("The capture request did not originate from a browser tab.");
  }

  await assertActiveCaptureTab(sender.tab.id, sender.tab.windowId);
  const imageDataUrl = await invoke(extensionApi.tabs, "captureVisibleTab", [
    sender.tab.windowId,
    { format: "png" }
  ]);
  await assertActiveCaptureTab(sender.tab.id, sender.tab.windowId);
  return imageDataUrl;
}

async function assertActiveCaptureTab(tabId, windowId) {
  if (typeof tabId !== "number" || typeof windowId !== "number") {
    throw new Error("The capture tab is no longer available.");
  }
  const activeTabs = await invoke(extensionApi.tabs, "query", [{ active: true, windowId }]);
  if (!Array.isArray(activeTabs) || activeTabs.length !== 1 || activeTabs[0].id !== tabId) {
    throw new Error("Capture stopped because the active browser tab changed.");
  }
}

function sessionFor(message, sender) {
  const session = longCaptureSessions.get(message.requestId);
  const currentDocument = typeof sender.documentId === "string" ? sender.documentId : null;
  const currentURL = typeof sender.url === "string" ? sender.url : null;
  if (!session) throw new Error("The long-capture session expired. Start the capture again.");
  if (Date.now() > session.deadline) {
    longCaptureSessions.delete(message.requestId);
    throw new Error("The long capture exceeded its time limit.");
  }
  if (!sender.tab || sender.tab.id !== session.tabId || sender.tab.windowId !== session.windowId) {
    throw new Error("Capture stopped because the browser tab changed.");
  }
  if (session.documentId && currentDocument !== session.documentId) {
    throw new Error("Capture stopped because the page navigated.");
  }
  if (!session.documentId && session.url && currentURL !== session.url) {
    throw new Error("Capture stopped because the page navigated.");
  }
  return session;
}

function expireSession(requestId, session) {
  const timer = setTimeout(() => {
    if (longCaptureSessions.get(requestId) === session) {
      longCaptureSessions.delete(requestId);
    }
  }, Core.CAPTURE_LIMITS.maxDurationMs + 1000);
  if (timer && typeof timer.unref === "function") timer.unref();
}

async function handleLongCaptureBegin(message, sender) {
  if (!sender.tab || typeof sender.tab.id !== "number" || typeof sender.tab.windowId !== "number") {
    throw new Error("The capture request did not originate from a browser tab.");
  }
  const sliceCount = Math.floor(Number(message.payload.sliceCount));
  if (!Number.isFinite(sliceCount) || sliceCount < 1 || sliceCount > Core.CAPTURE_LIMITS.maxSlices) {
    throw new Error("The long-capture slice count is invalid.");
  }
  await assertActiveCaptureTab(sender.tab.id, sender.tab.windowId);
  const session = {
    tabId: sender.tab.id,
    windowId: sender.tab.windowId,
    documentId: typeof sender.documentId === "string" ? sender.documentId : null,
    url: typeof sender.url === "string" ? sender.url : null,
    sliceCount,
    nextIndex: 0,
    deadline: Date.now() + Core.CAPTURE_LIMITS.maxDurationMs,
    lastCaptureAt: 0
  };
  longCaptureSessions.set(message.requestId, session);
  expireSession(message.requestId, session);
  return Core.makeEnvelope("capture.long.ready", { accepted: true }, message.requestId);
}

async function handleSliceRequest(message, sender) {
  const session = sessionFor(message, sender);
  const index = Math.floor(Number(message.payload.index));
  if (index !== session.nextIndex || index >= session.sliceCount) {
    throw new Error("Long-capture slices arrived out of order.");
  }
  await assertActiveCaptureTab(session.tabId, session.windowId);

  const wait = SLICE_INTERVAL_MS - (Date.now() - session.lastCaptureAt);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  sessionFor(message, sender);
  await assertActiveCaptureTab(session.tabId, session.windowId);

  const imageDataUrl = await invoke(extensionApi.tabs, "captureVisibleTab", [
    session.windowId,
    { format: "png" }
  ]);
  sessionFor(message, sender);
  await assertActiveCaptureTab(session.tabId, session.windowId);
  session.lastCaptureAt = Date.now();
  session.nextIndex += 1;
  return Core.makeEnvelope("capture.slice.response", {
    index,
    imageDataUrl
  }, message.requestId);
}

function handleLongCaptureEnd(message, sender) {
  const session = sessionFor(message, sender);
  const completed = session.nextIndex === session.sliceCount;
  longCaptureSessions.delete(message.requestId);
  if (!completed && message.payload.cancelled !== true) {
    throw new Error("The long capture ended before every slice was captured.");
  }
  return Core.makeEnvelope("capture.long.ended", { completed }, message.requestId);
}

async function handleCaptureRequest(message, sender) {
  const nativeResponse = await tryNativeCapture(message);
  if (nativeResponse) return nativeResponse;

  const imageDataUrl = await captureVisible(sender);
  return Core.makeEnvelope("capture.response", {
    accepted: true,
    handledBy: "browser",
    imageDataUrl,
    candidate: message.payload.candidate
  }, message.requestId);
}

extensionApi.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!Core.isEnvelope(message)) return false;

  let task;
  if (message.type === "capture.request") task = handleCaptureRequest(message, sender);
  else if (message.type === "capture.long.begin") task = handleLongCaptureBegin(message, sender);
  else if (message.type === "capture.slice.request") task = handleSliceRequest(message, sender);
  else if (message.type === "capture.long.end") task = Promise.resolve().then(() => handleLongCaptureEnd(message, sender));
  else return false;

  task
    .then(sendResponse)
    .catch((error) => {
      if (message.type.startsWith("capture.long") || message.type === "capture.slice.request") {
        longCaptureSessions.delete(message.requestId);
      }
      sendResponse(Core.makeEnvelope("error", {
        code: message.type === "capture.request" ? "capture_failed" : "long_capture_failed",
        message: error instanceof Error ? error.message : String(error)
      }, message.requestId));
    });
  return true;
});

extensionApi.action.onClicked.addListener(async (tab) => {
  if (!tab || typeof tab.id !== "number") return;
  const message = Core.makeEnvelope("selection.toggle", {});

  try {
    await invoke(extensionApi.tabs, "sendMessage", [tab.id, message]);
  } catch (_error) {
    // Browser-internal pages cannot host content scripts. The action is inert there.
  }
});
