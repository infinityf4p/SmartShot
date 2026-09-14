"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const Core = require("../shared/core.js");
const Delivery = require("../shared/delivery.js");
const manifest = require("../manifest.json");

const MANIFEST_PUBLIC_KEY = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtq5WbE6Fhkv/dsj+Ih8HoMsyVE6/s+MSofNmGZF2Ihe3ODAyG00Si4IBGXKCaRehvPSWS/mFBuccvwwTkn8RXr10mpsU2CA55Mg+HJ8fB6PQxM/stvaPlAHW37mU+tle5JH5n8x/xATI/l+dlIYA9RE532/6cTcef11xd0fKeTbOj8Z8uRyO1e0ur5feEr/bWaG3qMrkQrcxZrWgZGRVk5bgGwENtjwP48pt+I8Bttc0NQsQBZfQKNb4WyHSnq3Mg5tdHHH/Z6IGRuSfpd5krpAwoaGnBh97Elk+xoaay+hOpbiOmvSjowD/kEQx6at5lPj45+S9iRc9mFdB38hNoQIDAQAB";

function options(sendMessage, downloads) {
  return {
    imageDataUrl: "data:image/png;base64,iVBORw0KGgo=",
    filename: "x.com-x-post-2026",
    kind: "x-post",
    sourceOrigin: "https://x.com/status/1?private=yes",
    logicalWidth: 598.5,
    logicalHeight: 1740.25,
    makeEnvelope: Core.makeEnvelope,
    isEnvelope: Core.isEnvelope,
    sendMessage,
    download(imageDataUrl, filename) {
      downloads.push({ imageDataUrl, filename });
    }
  };
}

test("manifest pins the Chromium extension identity", () => {
  assert.equal(manifest.key, MANIFEST_PUBLIC_KEY);
  const alphabet = "abcdefghijklmnop";
  const digest = crypto.createHash("sha256")
    .update(Buffer.from(manifest.key, "base64"))
    .digest()
    .subarray(0, 16);
  const extensionId = Array.from(
    digest,
    (byte) => `${alphabet[byte >> 4]}${alphabet[byte & 0x0f]}`
  ).join("");
  assert.equal(extensionId, "fihllldonobikbajacoflinfomigonhd");
  assert.equal(manifest.content_scripts, undefined);
  assert.equal(manifest.host_permissions, undefined);
  assert.ok(manifest.permissions.includes("activeTab"));
  assert.ok(manifest.permissions.includes("downloads"));
  assert.ok(manifest.permissions.includes("scripting"));
  assert.deepEqual(manifest.commands._execute_action.suggested_key, {
    default: "Ctrl+Shift+9",
    mac: "MacCtrl+Shift+9"
  });
});

test("accepted native import suppresses the browser download", async () => {
  const downloads = [];
  const result = await Delivery.importOrDownload(options(async (request) => {
    assert.deepEqual(Object.keys(request.payload).sort(), [
      "filename", "imageDataUrl", "kind", "logicalHeight", "logicalWidth", "sourceOrigin"
    ]);
    assert.equal(request.payload.logicalWidth, 598.5);
    assert.equal(request.payload.logicalHeight, 1740.25);
    return Core.makeEnvelope("capture.import.response", {
      accepted: true,
      handledBy: "native"
    }, request.requestId);
  }, downloads));

  assert.deepEqual(result, { handledBy: "native" });
  assert.deepEqual(downloads, []);
});

test("native rejection preserves the browser download fallback", async () => {
  const downloads = [];
  const result = await Delivery.importOrDownload(options(async (request) => (
    Core.makeEnvelope("capture.import.response", {
      accepted: false,
      handledBy: "browser"
    }, request.requestId)
  ), downloads));

  assert.deepEqual(result, { handledBy: "browser" });
  assert.equal(downloads.length, 1);
});

test("a background download survives content-page teardown without a duplicate", async () => {
  const downloads = [];
  const result = await Delivery.importOrDownload(options(async (request) => (
    Core.makeEnvelope("capture.import.response", {
      accepted: false,
      handledBy: "browser",
      downloaded: true
    }, request.requestId)
  ), downloads));

  assert.deepEqual(result, { handledBy: "browser" });
  assert.deepEqual(downloads, []);
});

test("a lost native response retries the same request without a content download", async () => {
  const downloads = [];
  const requests = [];
  const result = await Delivery.importOrDownload(options(async (request) => {
    requests.push(request);
    if (requests.length === 1) throw new Error("The first response was lost.");
    return Core.makeEnvelope("capture.import.response", {
      accepted: true,
      handledBy: "native",
      downloaded: false
    }, request.requestId);
  }, downloads));

  assert.deepEqual(result, { handledBy: "native" });
  assert.equal(requests.length, 2);
  assert.strictEqual(requests[1], requests[0]);
  assert.equal(requests[1].requestId, requests[0].requestId);
  assert.deepEqual(downloads, []);
});

test("a lost background-download response retries without a content download", async () => {
  const downloads = [];
  const requests = [];
  const result = await Delivery.importOrDownload(options(async (request) => {
    requests.push(request);
    if (requests.length === 1) throw new Error("The first response was lost.");
    return Core.makeEnvelope("capture.import.response", {
      accepted: false,
      handledBy: "browser",
      downloaded: true
    }, request.requestId);
  }, downloads));

  assert.deepEqual(result, { handledBy: "browser" });
  assert.equal(requests.length, 2);
  assert.strictEqual(requests[1], requests[0]);
  assert.equal(requests[1].requestId, requests[0].requestId);
  assert.deepEqual(downloads, []);
});

test("native messaging failures preserve the browser download fallback", async () => {
  const downloads = [];
  let requests = 0;
  const result = await Delivery.importOrDownload(options(async () => {
    requests += 1;
    throw new Error("native messaging failed");
  }, downloads));

  assert.deepEqual(result, { handledBy: "browser" });
  assert.equal(requests, 2);
  assert.equal(downloads.length, 1);
});

test("an acknowledgement for another request falls back to download", async () => {
  const downloads = [];
  await Delivery.importOrDownload(options(async () => (
    Core.makeEnvelope("capture.import.response", { accepted: true }, "wrong-request")
  ), downloads));

  assert.equal(downloads.length, 1);
});

test("invalid logical dimensions skip native messaging and fall back to download", async () => {
  const downloads = [];
  let requests = 0;
  const input = options(async () => {
    requests += 1;
  }, downloads);
  input.logicalWidth = Number.NaN;
  await Delivery.importOrDownload(input);

  assert.equal(requests, 0);
  assert.equal(downloads.length, 1);

  const booleanDownloads = [];
  const booleanInput = options(async () => {
    requests += 1;
  }, booleanDownloads);
  booleanInput.logicalWidth = true;
  await Delivery.importOrDownload(booleanInput);

  assert.equal(requests, 0);
  assert.equal(booleanDownloads.length, 1);
});
