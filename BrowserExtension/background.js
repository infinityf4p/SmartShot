"use strict";

importScripts("shared/core.js");

const extensionApi = globalThis.browser || globalThis.chrome;
const Core = globalThis.SmartShotCore;
const isPromiseApi = typeof globalThis.browser !== "undefined";
const longCaptureSessions = new Map();
const SLICE_INTERVAL_MS = 550;
const STABILITY_PROBE_INTERVAL_MS = 120;
const IMPORT_MAX_BYTES = 64 * 1024 * 1024;
const IMPORT_CHUNK_BASE64_CHARACTERS = 192 * 1024;
const IMPORT_ACK_TIMEOUT_MS = 5000;
const IMPORT_END_ACK_TIMEOUT_MS = 15000;
const IMPORT_MAX_LOGICAL_DIMENSION = 20000;
const PNG_DATA_URL_PREFIX = "data:image/png;base64,";
const ACTION_DEFAULT_TITLE = "Select a content block";
const CONTENT_SCRIPT_FILES = Object.freeze([
  "shared/core.js",
  "shared/selection.js",
  "shared/capture-guards.js",
  "shared/delivery.js",
  "content.js"
]);

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

function withTimeout(promise, milliseconds) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("The SmartShot native import timed out.")), milliseconds);
    Promise.resolve(promise).then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

function validatedPNGBase64(value) {
  if (typeof value !== "string" || !value.startsWith(PNG_DATA_URL_PREFIX)) {
    throw new Error("The native import requires a PNG data URL.");
  }

  const base64 = value.slice(PNG_DATA_URL_PREFIX.length);
  const maximumBase64Length = Math.ceil(IMPORT_MAX_BYTES / 3) * 4;
  if (base64.length > maximumBase64Length) {
    throw new Error("The native import PNG exceeds the 64 MB limit.");
  }
  if (base64.length < 12 || base64.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) {
    throw new Error("The native import PNG has invalid base64 data.");
  }

  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  const byteLength = (base64.length / 4) * 3 - padding;
  if (byteLength > IMPORT_MAX_BYTES) {
    throw new Error("The native import PNG exceeds the 64 MB limit.");
  }

  const signature = globalThis.atob(base64.slice(0, 12));
  const expected = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (signature.length < expected.length || expected.some((byte, index) => signature.charCodeAt(index) !== byte)) {
    throw new Error("The native import data is not a PNG image.");
  }

  return { base64, byteLength };
}

function safeImportFilename(value) {
  const cleaned = Core.safeFilename(value)
    .replace(/[\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(/^\.+/, "")
    .replace(/[. ]+$/, "")
    .slice(0, 80);
  return cleaned || "capture";
}

function safeImportKind(value) {
  const cleaned = String(value || "block")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^a-z0-9:_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return cleaned || "block";
}

function validatedLogicalDimension(value) {
  if (typeof value !== "number" || !Number.isFinite(value) ||
      value <= 0 || value > IMPORT_MAX_LOGICAL_DIMENSION) {
    throw new Error("The native import has invalid logical dimensions.");
  }
  return value;
}

function isImportAck(response, requestId, stage, index) {
  if (!Core.isEnvelope(response, "capture.import.ack") ||
      response.requestId !== requestId ||
      response.payload.accepted !== true ||
      response.payload.stage !== stage) {
    return false;
  }
  return stage !== "chunk" || response.payload.index === index;
}

async function sendNativeImportMessage(message, timeout = IMPORT_ACK_TIMEOUT_MS) {
  return withTimeout(
    invoke(extensionApi.runtime, "sendNativeMessage", [nativeHostName(), message]),
    timeout
  );
}

async function importPNG(message) {
  if (typeof extensionApi.runtime.sendNativeMessage !== "function") return false;

  const image = validatedPNGBase64(message.payload.imageDataUrl);
  const filename = safeImportFilename(message.payload.filename);
  const kind = safeImportKind(message.payload.kind);
  const sourceOrigin = Core.sanitizeSourceURL(message.payload.sourceOrigin);
  const logicalWidth = validatedLogicalDimension(message.payload.logicalWidth);
  const logicalHeight = validatedLogicalDimension(message.payload.logicalHeight);
  const chunkCount = Math.ceil(image.base64.length / IMPORT_CHUNK_BASE64_CHARACTERS);
  const requestId = message.requestId;

  const begin = Core.makeEnvelope("capture.import.begin", {
    mimeType: "image/png",
    encoding: "base64",
    byteLength: image.byteLength,
    base64Length: image.base64.length,
    chunkCount,
    filename,
    kind,
    sourceOrigin,
    logicalWidth,
    logicalHeight
  }, requestId);
  const beginAck = await sendNativeImportMessage(begin);
  if (!isImportAck(beginAck, requestId, "begin")) return false;

  for (let index = 0; index < chunkCount; index += 1) {
    const start = index * IMPORT_CHUNK_BASE64_CHARACTERS;
    const chunk = Core.makeEnvelope("capture.import.chunk", {
      index,
      data: image.base64.slice(start, start + IMPORT_CHUNK_BASE64_CHARACTERS)
    }, requestId);
    const chunkAck = await sendNativeImportMessage(chunk);
    if (!isImportAck(chunkAck, requestId, "chunk", index)) return false;
  }

  const end = Core.makeEnvelope("capture.import.end", {
    byteLength: image.byteLength,
    chunkCount
  }, requestId);
  const endAck = await sendNativeImportMessage(end, IMPORT_END_ACK_TIMEOUT_MS);
  return isImportAck(endAck, requestId, "end");
}

async function downloadImportPNG(message) {
  if (!extensionApi.downloads || typeof extensionApi.downloads.download !== "function") return false;
  validatedPNGBase64(message.payload.imageDataUrl);
  const filename = `${safeImportFilename(message.payload.filename)}.png`;
  await invoke(extensionApi.downloads, "download", [{
    url: message.payload.imageDataUrl,
    filename,
    conflictAction: "uniquify",
    saveAs: false
  }]);
  return true;
}

async function handleImportRequest(message) {
  let accepted = false;
  try {
    accepted = await importPNG(message);
  } catch (_error) {
    accepted = false;
  }
  if (accepted) {
    return Core.makeEnvelope("capture.import.response", {
      accepted: true,
      handledBy: "native",
      downloaded: false
    }, message.requestId);
  }

  let downloaded = false;
  try {
    downloaded = await downloadImportPNG(message);
  } catch (_error) {
    downloaded = false;
  }
  return Core.makeEnvelope("capture.import.response", {
    accepted: false,
    handledBy: downloaded ? "browser" : "content",
    downloaded
  }, message.requestId);
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

  await new Promise((resolve) => setTimeout(resolve, STABILITY_PROBE_INTERVAL_MS));
  sessionFor(message, sender);
  await assertActiveCaptureTab(session.tabId, session.windowId);
  const verificationImageDataUrl = await invoke(extensionApi.tabs, "captureVisibleTab", [
    session.windowId,
    { format: "png" }
  ]);
  sessionFor(message, sender);
  await assertActiveCaptureTab(session.tabId, session.windowId);
  session.lastCaptureAt = Date.now();
  session.nextIndex += 1;
  return Core.makeEnvelope("capture.slice.response", {
    index,
    imageDataUrl,
    verificationImageDataUrl
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
  else if (message.type === "capture.import.request") task = handleImportRequest(message);
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

function canInjectIntoTab(tab) {
  if (!tab || typeof tab.url !== "string") return true;
  try {
    const url = new URL(tab.url);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch (_error) {
    return false;
  }
}

async function toggleSelectionInTab(tab, message) {
  try {
    return await invoke(extensionApi.tabs, "sendMessage", [tab.id, message]);
  } catch (initialError) {
    if (!canInjectIntoTab(tab) || !extensionApi.scripting ||
        typeof extensionApi.scripting.executeScript !== "function") {
      throw initialError;
    }
    await invoke(extensionApi.scripting, "executeScript", [{
      target: { tabId: tab.id, allFrames: false },
      files: CONTENT_SCRIPT_FILES
    }]);
    return invoke(extensionApi.tabs, "sendMessage", [tab.id, message]);
  }
}

function actionFailureMessage(tab, error) {
  if (!canInjectIntoTab(tab)) return "SmartShot cannot run on this browser page.";
  const detail = error instanceof Error ? error.message : String(error || "");
  if (/(permission|denied|not allowed|cannot access|missing host permission)/i.test(detail)) {
    return "SmartShot needs website access for this page.";
  }
  return "SmartShot could not start on this page.";
}

async function setActionFeedback(tabId, failureMessage = null) {
  if (!extensionApi.action) return;
  const details = { tabId };
  const tasks = [];
  if (typeof extensionApi.action.setBadgeText === "function") {
    tasks.push(invoke(extensionApi.action, "setBadgeText", [{ ...details, text: failureMessage ? "!" : "" }]));
  }
  if (failureMessage && typeof extensionApi.action.setBadgeBackgroundColor === "function") {
    tasks.push(invoke(extensionApi.action, "setBadgeBackgroundColor", [{ ...details, color: "#a3132f" }]));
  }
  if (typeof extensionApi.action.setTitle === "function") {
    tasks.push(invoke(extensionApi.action, "setTitle", [{
      ...details,
      title: failureMessage || ACTION_DEFAULT_TITLE
    }]));
  }
  await Promise.allSettled(tasks);
}

extensionApi.action.onClicked.addListener(async (tab) => {
  if (!tab || typeof tab.id !== "number") return;
  const message = Core.makeEnvelope("selection.toggle", {});

  try {
    await toggleSelectionInTab(tab, message);
    await setActionFeedback(tab.id);
  } catch (error) {
    await setActionFeedback(tab.id, actionFailureMessage(tab, error));
  }
});
