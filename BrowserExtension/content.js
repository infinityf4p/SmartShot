(function installSmartShotSelector() {
  "use strict";

  const extensionApi = globalThis.browser || globalThis.chrome;
  const Core = globalThis.SmartShotCore;
  const SELECTOR_PROTOCOL_VERSION = Core.SELECTOR_PROTOCOL_VERSION;
  const Selection = globalThis.SmartShotSelection;
  const CaptureGuards = globalThis.SmartShotCaptureGuards;
  const Delivery = globalThis.SmartShotDelivery;
  const previousController = globalThis.__smartShotSelectorController;
  if (previousController && typeof previousController.dispose === "function") {
    previousController.dispose();
  }
  globalThis.__blockShotSelectorInstalled = true;
  const state = {
    active: false,
    host: null,
    box: null,
    label: null,
    chain: [],
    level: 0,
    pointer: { x: 0, y: 0 },
    framePending: false,
    capturing: false,
    captureController: null,
    previousCursor: { value: "", priority: "" }
  };

  function sendMessage(message) {
    if (typeof globalThis.browser !== "undefined") {
      return Promise.resolve(extensionApi.runtime.sendMessage(message));
    }
    return new Promise((resolve, reject) => {
      extensionApi.runtime.sendMessage(message, (response) => {
        const error = globalThis.chrome && chrome.runtime.lastError;
        if (error) reject(new Error(error.message));
        else resolve(response);
      });
    });
  }

  function rectFor(element) {
    return Selection.rectFor(element);
  }

  function kindFor(element) {
    return Core.kindFromDescriptor(Selection.descriptor(element));
  }

  function candidateChainFromLeaf(leaf) {
    if (!leaf || leaf === state.host) return [];
    return Selection.candidateChainFromLeaf(leaf, {
      documentElement: document.documentElement,
      overlayHost: state.host,
      getComputedStyle
    });
  }

  function candidateChainAt(x, y) {
    return candidateChainFromLeaf(document.elementFromPoint(x, y));
  }

  function metadataFor(_element, kind) {
    return kind === "x-post" ? { platform: "x" } : {};
  }

  function currentElement() {
    return state.chain[state.level] || null;
  }

  function preferredLevel(chain) {
    const semanticLevel = chain.findIndex((element) => Selection.isSemantic(element));
    return semanticLevel >= 0 ? semanticLevel : 0;
  }

  function initialCandidateChain() {
    const focused = document.activeElement;
    const focusIsUsable = focused &&
      focused !== document.body &&
      focused !== document.documentElement &&
      focused !== state.host &&
      !(state.host && state.host.contains(focused));
    if (focusIsUsable) {
      const focusedChain = candidateChainFromLeaf(focused);
      if (focusedChain.length) return focusedChain;
    }
    return candidateChainAt(innerWidth / 2, innerHeight / 2);
  }

  function candidateFor(element) {
    if (!element) return null;
    const kind = kindFor(element);
    return Core.makeCandidate({
      rect: rectFor(element),
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
      url: location.href,
      kind,
      metadata: metadataFor(element, kind)
    });
  }

  function currentCandidate() {
    return candidateFor(currentElement());
  }

  function render() {
    const element = currentElement();
    if (!element || !state.box || !element.isConnected) {
      if (state.box) state.box.style.display = "none";
      return;
    }

    const rect = element.getBoundingClientRect();
    state.box.style.display = "block";
    state.box.style.transform = `translate(${Math.max(0, rect.left)}px, ${Math.max(0, rect.top)}px)`;
    state.box.style.width = `${Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left))}px`;
    state.box.style.height = `${Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top))}px`;
    state.box.classList.toggle("near-top", rect.top < 27);
    state.label.textContent = `${kindFor(element)}  ${state.level + 1}/${state.chain.length}`;
  }

  function refreshAtPointer() {
    state.framePending = false;
    if (!state.active) return;
    const nextChain = candidateChainAt(state.pointer.x, state.pointer.y);
    const selected = currentElement();
    const preservedIndex = selected ? nextChain.indexOf(selected) : -1;
    state.chain = nextChain;
    state.level = preservedIndex >= 0 ? preservedIndex : preferredLevel(nextChain);
    render();
  }

  function onPointerMove(event) {
    state.pointer = { x: event.clientX, y: event.clientY };
    if (!state.framePending) {
      state.framePending = true;
      requestAnimationFrame(refreshAtPointer);
    }
  }

  function shiftLevel(delta) {
    if (!state.chain.length) return;
    state.level = Math.max(0, Math.min(state.chain.length - 1, state.level + delta));
    render();
  }

  function onWheel(event) {
    if (!state.active || !state.chain.length) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    shiftLevel(event.deltaY > 0 ? 1 : -1);
  }

  function onKeyDown(event) {
    if (!state.active) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopImmediatePropagation();
      stop();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      event.stopImmediatePropagation();
      captureSelection();
      return;
    }
    if (["ArrowUp", "ArrowRight"].includes(event.key)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      shiftLevel(1);
    } else if (["ArrowDown", "ArrowLeft"].includes(event.key)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      shiftLevel(-1);
    }
  }

  function cancelCapture(message = "Capture cancelled.") {
    if (state.captureController) state.captureController.cancel(message);
  }

  function onCaptureKeyDown(event) {
    if (!state.capturing || event.key !== "Escape") return;
    event.preventDefault();
    event.stopImmediatePropagation();
    cancelCapture();
  }

  function onPageLifecycleExit() {
    if (state.active) stop();
    cancelCapture("Capture stopped because the page became inactive.");
  }

  function onVisibilityChange() {
    if (document.hidden) onPageLifecycleExit();
  }

  function onClick(event) {
    if (!state.active) return;
    if (!currentElement()) {
      state.chain = candidateChainFromLeaf(event.target);
      state.level = preferredLevel(state.chain);
    }
    if (!currentElement()) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    captureSelection();
  }

  function createOverlay() {
    const host = document.createElement("div");
    host.id = "smartshot-selector-root";
    host.style.cssText = "all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;";
    const shadow = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      .box { position: fixed; box-sizing: border-box; display: none; border: 2px solid #ff375f;
        background: rgb(255 55 95 / 10%); box-shadow: 0 0 0 1px rgb(255 255 255 / 85%),
        0 4px 18px rgb(0 0 0 / 25%); pointer-events: none; }
      .label { position: absolute; left: -2px; top: -27px; height: 23px; box-sizing: border-box;
        padding: 3px 7px; border-radius: 4px 4px 0 0; color: white; background: #e9214b;
        font: 600 12px/17px -apple-system, BlinkMacSystemFont, sans-serif; white-space: nowrap; }
      .box.near-top .label { top: 0; border-radius: 0 0 4px 0; }
    `;
    const box = document.createElement("div");
    box.className = "box";
    const label = document.createElement("div");
    label.className = "label";
    box.append(label);
    shadow.append(style, box);
    document.documentElement.append(host);
    state.host = host;
    state.box = box;
    state.label = label;
  }

  function start() {
    if (state.active || state.capturing) return;
    state.active = true;
    createOverlay();
    document.addEventListener("pointermove", onPointerMove, true);
    document.addEventListener("wheel", onWheel, { capture: true, passive: false });
    document.addEventListener("keydown", onKeyDown, true);
    document.addEventListener("click", onClick, true);
    window.addEventListener("scroll", render, true);
    state.previousCursor = {
      value: document.documentElement.style.getPropertyValue("cursor"),
      priority: document.documentElement.style.getPropertyPriority("cursor")
    };
    document.documentElement.style.setProperty("cursor", "crosshair", "important");
    state.chain = initialCandidateChain();
    state.level = preferredLevel(state.chain);
    render();
  }

  function stop() {
    if (!state.active) return;
    state.active = false;
    document.removeEventListener("pointermove", onPointerMove, true);
    document.removeEventListener("wheel", onWheel, true);
    document.removeEventListener("keydown", onKeyDown, true);
    document.removeEventListener("click", onClick, true);
    window.removeEventListener("scroll", render, true);
    if (state.previousCursor.value) {
      document.documentElement.style.setProperty("cursor", state.previousCursor.value, state.previousCursor.priority);
    } else {
      document.documentElement.style.removeProperty("cursor");
    }
    if (state.host) state.host.remove();
    state.host = null;
    state.box = null;
    state.label = null;
    state.chain = [];
    state.level = 0;
  }

  function nextPaint() {
    return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  }

  function documentSize() {
    const root = document.documentElement;
    const body = document.body;
    return {
      width: Math.max(root.clientWidth, root.scrollWidth, body ? body.scrollWidth : 0),
      height: Math.max(root.clientHeight, root.scrollHeight, body ? body.scrollHeight : 0)
    };
  }

  function deadlineAfter(milliseconds) {
    return performance.now() + milliseconds;
  }

  function remainingTime(deadline) {
    return Math.max(0, deadline - performance.now());
  }

  function assertBeforeDeadline(deadline) {
    if (remainingTime(deadline) <= 0) throw new Error("The long capture exceeded its time limit.");
  }

  function withTimeout(promise, milliseconds, message) {
    const wait = Math.max(1, milliseconds);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(message)), wait);
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

  function pageRectFor(element) {
    const rect = rectFor(element);
    return Core.normalizeRect({
      x: rect.x + window.scrollX,
      y: rect.y + window.scrollY,
      width: rect.width,
      height: rect.height
    });
  }

  function closeEnough(first, second, tolerance = 2) {
    return CaptureGuards.closeEnough(first, second, tolerance);
  }

  function assertStandardVisualViewport() {
    CaptureGuards.assertStandardVisualViewport(window);
  }

  function assertStableTarget(element, expectedRect, expectedURL, expectedViewport, targetMutated) {
    CaptureGuards.assertStableTarget({
      element,
      expectedRect,
      expectedURL,
      expectedViewport,
      targetMutated,
      currentURL: () => location.href,
      view: window,
      rectFor,
      normalizeRect: Core.normalizeRect
    });
  }

  function prepareCaptureEnvironment(target) {
    return CaptureGuards.prepareCaptureEnvironment({
      target,
      document,
      getComputedStyle,
      maximumStyleNodes: Core.CAPTURE_LIMITS.maxStyleNodes
    });
  }

  async function scrollAndSettle(x, y, deadline, cancellation) {
    cancellation.throwIfCancelled();
    window.scrollTo(x, y);
    for (let frame = 0; frame < 10; frame += 1) {
      assertBeforeDeadline(deadline);
      await new Promise((resolve) => requestAnimationFrame(resolve));
      cancellation.throwIfCancelled();
      if (closeEnough(window.scrollX, x, 1) && closeEnough(window.scrollY, y, 1)) {
        await nextPaint();
        cancellation.throwIfCancelled();
        return;
      }
    }
    throw new Error("Capture stopped because the page did not settle at the requested scroll position.");
  }

  function assertScrollPosition(x, y) {
    CaptureGuards.assertScrollPosition(window, x, y);
  }

  function loadImage(dataUrl) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error("The captured browser image could not be decoded."));
      image.src = dataUrl;
    });
  }

  function sampledPixels(image, source) {
    const sampleSize = CaptureGuards.verificationSampleSize(source.width, source.height);
    const canvas = document.createElement("canvas");
    canvas.width = sampleSize.width;
    canvas.height = sampleSize.height;
    const context = canvas.getContext("2d", { alpha: false, willReadFrequently: true });
    if (!context) throw new Error("The browser could not verify capture pixels.");
    context.imageSmoothingEnabled = true;
    context.drawImage(
      image,
      source.x,
      source.y,
      source.width,
      source.height,
      0,
      0,
      sampleSize.width,
      sampleSize.height
    );
    return context.getImageData(0, 0, sampleSize.width, sampleSize.height);
  }

  function assertStableCapturedPixels(image, verificationImage, source) {
    if (image.naturalWidth !== verificationImage.naturalWidth ||
        image.naturalHeight !== verificationImage.naturalHeight) {
      throw new Error("Capture stopped because verification frame dimensions changed.");
    }
    CaptureGuards.assertStablePixelSamples(
      sampledPixels(image, source),
      sampledPixels(verificationImage, source)
    );
  }

  async function cropVisibleCapture(imageDataUrl, candidate) {
    const image = await loadImage(imageDataUrl);
    const crop = Core.capturePixelRect(candidate, image.naturalWidth, image.naturalHeight);
    if (!crop.width || !crop.height) throw new Error("The selected block is outside the visible viewport.");
    const canvas = document.createElement("canvas");
    canvas.width = crop.width;
    canvas.height = crop.height;
    const context = canvas.getContext("2d", { alpha: false });
    context.drawImage(image, crop.x, crop.y, crop.width, crop.height, 0, 0, crop.width, crop.height);
    return canvas.toDataURL("image/png");
  }

  function assertEnvelopeResponse(response, request, type) {
    if (!Core.isEnvelope(response)) throw new Error("SmartShot returned an invalid response.");
    if (response.requestId !== request.requestId) {
      throw new Error("SmartShot returned a response for another capture request.");
    }
    if (response.type === "error") throw new Error(response.payload.message || "Capture failed.");
    if (response.type !== type) throw new Error("SmartShot returned an unexpected capture response.");
    return response;
  }

  async function sendBeforeDeadline(message, deadline) {
    assertBeforeDeadline(deadline);
    return withTimeout(
      sendMessage(message),
      remainingTime(deadline),
      "The long capture timed out while waiting for the browser."
    );
  }

  async function captureLongElement(element, initialCandidate, cancellation) {
    const originalScroll = { x: window.scrollX, y: window.scrollY };
    const expectedURL = location.href;
    const deadline = deadlineAfter(Core.CAPTURE_LIMITS.maxDurationMs);
    const restoreEnvironment = prepareCaptureEnvironment(element);
    const requestId = Core.makeEnvelope("capture.long.begin", {}).requestId;
    let targetChanged = false;
    let targetObserver = null;
    let sessionStarted = false;
    let completed = false;
    const stopImmediateRestoration = cancellation.onCancel(() => {
      try {
        window.scrollTo(originalScroll.x, originalScroll.y);
      } catch (_error) {
        // The final restoration path will retry and report persistent failures.
      }
      try {
        restoreEnvironment();
      } catch (_error) {
        // The final restoration path will retry and report persistent failures.
      }
    });

    try {
      cancellation.throwIfCancelled();
      await nextPaint();
      cancellation.throwIfCancelled();
      if (!element.isConnected) throw new Error("The selected block is no longer on the page.");

      const targetRect = pageRectFor(element);
      const viewport = { width: window.innerWidth, height: window.innerHeight };
      assertStandardVisualViewport();
      targetObserver = new MutationObserver(() => { targetChanged = true; });
      targetObserver.observe(element, {
        attributes: true,
        childList: true,
        characterData: true,
        subtree: true
      });
      const slices = Core.planVerticalSlices(targetRect, viewport, documentSize());
      const begin = Core.makeEnvelope("capture.long.begin", {
        sliceCount: slices.length,
        candidate: {
          ...initialCandidate,
          pageRect: targetRect,
          viewport
        }
      }, requestId);
      const ready = await sendBeforeDeadline(begin, deadline);
      assertEnvelopeResponse(ready, begin, "capture.long.ready");
      if (ready.payload.accepted !== true) {
        throw new Error("The browser did not accept the long capture session.");
      }
      sessionStarted = true;
      cancellation.throwIfCancelled();

      let canvas = null;
      let context = null;
      let outputSize = null;
      let capturedImageSize = null;
      let scaleX = 0;
      let scaleY = 0;

      for (const slice of slices) {
        cancellation.throwIfCancelled();
        assertStableTarget(element, targetRect, expectedURL, viewport, () => targetChanged);
        await scrollAndSettle(slice.scrollX, slice.scrollY, deadline, cancellation);
        assertStableTarget(element, targetRect, expectedURL, viewport, () => targetChanged);

        const request = Core.makeEnvelope("capture.slice.request", { index: slice.index }, requestId);
        const response = assertEnvelopeResponse(
          await sendBeforeDeadline(request, deadline),
          request,
          "capture.slice.response"
        );
        cancellation.throwIfCancelled();
        if (response.payload.index !== slice.index || typeof response.payload.imageDataUrl !== "string") {
          throw new Error("The browser returned a mismatched capture slice.");
        }
        if (typeof response.payload.verificationImageDataUrl !== "string") {
          throw new Error("The browser did not return a capture verification frame.");
        }

        const [image, verificationImage] = await withTimeout(
          Promise.all([
            loadImage(response.payload.imageDataUrl),
            loadImage(response.payload.verificationImageDataUrl)
          ]),
          remainingTime(deadline),
          "Capture verification frames could not be decoded before the timeout."
        );
        cancellation.throwIfCancelled();
        assertScrollPosition(slice.scrollX, slice.scrollY);
        assertStableTarget(element, targetRect, expectedURL, viewport, () => targetChanged);
        if (!canvas) {
          scaleX = image.naturalWidth / viewport.width;
          scaleY = image.naturalHeight / viewport.height;
          if (!Number.isFinite(scaleX) || !Number.isFinite(scaleY) || scaleX <= 0 || scaleY <= 0 ||
              Math.abs(scaleX - scaleY) / Math.max(scaleX, scaleY) > 0.05) {
            throw new Error("The browser returned an image with an unexpected viewport scale.");
          }
          outputSize = Core.captureOutputSize(targetRect, scaleX, scaleY);
          canvas = document.createElement("canvas");
          canvas.width = outputSize.width;
          canvas.height = outputSize.height;
          context = canvas.getContext("2d", { alpha: false });
          if (!context) throw new Error("The browser could not create the long-capture canvas.");
          context.fillStyle = "white";
          context.fillRect(0, 0, canvas.width, canvas.height);
          capturedImageSize = { width: image.naturalWidth, height: image.naturalHeight };
        } else if (image.naturalWidth !== capturedImageSize.width || image.naturalHeight !== capturedImageSize.height) {
          throw new Error("Capture stopped because the browser viewport changed.");
        }

        const viewportRect = {
          x: targetRect.x - window.scrollX,
          y: slice.pageStart - window.scrollY,
          width: targetRect.width,
          height: slice.pageEnd - slice.pageStart
        };
        const source = Core.capturePixelRectForViewportRect(
          viewportRect,
          viewport,
          image.naturalWidth,
          image.naturalHeight
        );
        const destination = Core.destinationPixelRange(
          slice.pageStart,
          slice.pageEnd,
          targetRect.y,
          scaleY,
          outputSize.height
        );
        if (!source.width || !source.height || !destination.height) {
          throw new Error("A capture slice fell outside the visible browser viewport.");
        }
        assertStableCapturedPixels(image, verificationImage, source);
        context.drawImage(
          image,
          source.x,
          source.y,
          source.width,
          source.height,
          0,
          destination.y,
          outputSize.width,
          destination.height
        );
      }

      const end = Core.makeEnvelope("capture.long.end", { cancelled: false }, requestId);
      const ended = assertEnvelopeResponse(
        await sendBeforeDeadline(end, deadline),
        end,
        "capture.long.ended"
      );
      if (ended.payload.completed !== true) {
        throw new Error("The browser did not complete the long capture session.");
      }
      completed = true;
      cancellation.throwIfCancelled();

      const result = canvas.toDataURL("image/png");
      if (!result.startsWith("data:image/png")) {
        throw new Error("The browser could not encode the completed long capture.");
      }
      return {
        imageDataUrl: result,
        candidate: {
          ...initialCandidate,
          pageRect: targetRect,
          viewport
        }
      };
    } finally {
      stopImmediateRestoration();
      if (targetObserver) targetObserver.disconnect();
      if (sessionStarted && !completed) {
        const cancel = Core.makeEnvelope("capture.long.end", { cancelled: true }, requestId);
        try {
          await withTimeout(sendMessage(cancel), 1000, "Capture cancellation timed out.");
        } catch (_error) {
          // The background worker also expires abandoned sessions automatically.
        }
      }
      await CaptureGuards.restorePageState(window, originalScroll, restoreEnvironment, nextPaint);
    }
  }

  function filenameFor(candidate) {
    let host = "web";
    try {
      host = new URL(candidate.url).hostname.replace(/^www\./, "");
    } catch (_error) {
      // Keep the generic host label.
    }
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    return Core.safeFilename(`${host}-${candidate.kind}-${timestamp}`);
  }

  function downloadDataUrl(imageDataUrl, filename) {
    const anchor = document.createElement("a");
    anchor.href = imageDataUrl;
    anchor.download = `${filename}.png`;
    anchor.style.display = "none";
    document.documentElement.append(anchor);
    anchor.click();
    anchor.remove();
  }

  function importOrDownload(imageDataUrl, candidate) {
    return Delivery.importOrDownload({
      imageDataUrl,
      filename: filenameFor(candidate),
      kind: candidate.kind,
      sourceOrigin: candidate.url,
      logicalWidth: candidate.pageRect.width,
      logicalHeight: candidate.pageRect.height,
      makeEnvelope: Core.makeEnvelope,
      isEnvelope: Core.isEnvelope,
      sendMessage,
      download: downloadDataUrl
    });
  }

  function showCaptureError(error) {
    const previous = document.getElementById("smartshot-capture-error");
    if (previous) previous.remove();

    const host = document.createElement("div");
    host.id = "smartshot-capture-error";
    host.setAttribute("role", "alert");
    host.style.cssText = "all:initial!important;position:fixed!important;left:50%!important;top:18px!important;transform:translateX(-50%)!important;z-index:2147483647!important;pointer-events:none!important;";
    const shadow = host.attachShadow({ mode: "closed" });
    const message = document.createElement("div");
    message.textContent = error instanceof Error ? error.message : String(error);
    message.style.cssText = "box-sizing:border-box;max-width:min(560px,calc(100vw - 32px));padding:9px 12px;border:1px solid rgb(255 255 255 / 35%);border-radius:6px;background:#a3132f;color:white;box-shadow:0 8px 28px rgb(0 0 0 / 32%);font:600 13px/18px -apple-system,BlinkMacSystemFont,sans-serif;white-space:normal;";
    shadow.append(message);
    document.documentElement.append(host);
    setTimeout(() => host.remove(), 6000);
  }

  async function captureSelection() {
    const element = currentElement();
    const candidate = candidateFor(element);
    if (!element || !candidate || state.capturing) return;
    const cancellation = CaptureGuards.createCaptureCancellationController();
    state.capturing = true;
    state.captureController = cancellation;
    stop();
    document.addEventListener("keydown", onCaptureKeyDown, true);

    try {
      await nextPaint();
      cancellation.throwIfCancelled();
      const refreshedCandidate = candidateFor(element);
      if (!refreshedCandidate) throw new Error("The selected block is no longer on the page.");
      if (!Core.isRectFullyVisible(refreshedCandidate.viewportRect, refreshedCandidate.viewport)) {
        const capture = await captureLongElement(element, refreshedCandidate, cancellation);
        cancellation.throwIfCancelled();
        await importOrDownload(capture.imageDataUrl, capture.candidate);
        return;
      }

      const request = Core.makeEnvelope("capture.request", { candidate: refreshedCandidate });
      const response = assertEnvelopeResponse(
        await sendMessage(request),
        request,
        "capture.response"
      );
      cancellation.throwIfCancelled();
      if (response.payload.accepted !== true || typeof response.payload.imageDataUrl !== "string") {
        throw new Error("No browser capture was returned.");
      }

      const croppedDataUrl = await cropVisibleCapture(response.payload.imageDataUrl, refreshedCandidate);
      cancellation.throwIfCancelled();
      await importOrDownload(croppedDataUrl, refreshedCandidate);
    } catch (error) {
      if (!CaptureGuards.isCaptureCancellation(error)) {
        console.error("SmartShot capture failed:", error);
        showCaptureError(error);
      }
    } finally {
      document.removeEventListener("keydown", onCaptureKeyDown, true);
      if (state.captureController === cancellation) state.captureController = null;
      state.capturing = false;
    }
  }

  function selectorCommandForMessage(message) {
    if (Core.isEnvelope(message, "selection.command") &&
        [SELECTOR_PROTOCOL_VERSION, SELECTOR_PROTOCOL_VERSION - 1]
          .includes(message.payload.selectorProtocolVersion)) {
      return {
        action: message.payload.action,
        responseProtocolVersion: message.payload.selectorProtocolVersion
      };
    }
    if (Core.isEnvelope(message, "selection.toggle")) {
      return { action: "toggle", responseProtocolVersion: SELECTOR_PROTOCOL_VERSION };
    }
    if (Core.isEnvelope(message, "selection.start")) {
      return { action: "start", responseProtocolVersion: SELECTOR_PROTOCOL_VERSION };
    }
    if (Core.isEnvelope(message, "selection.stop")) {
      return { action: "stop", responseProtocolVersion: SELECTOR_PROTOCOL_VERSION };
    }
    return null;
  }

  function onRuntimeMessage(message, _sender, sendResponse) {
    const command = selectorCommandForMessage(message);
    if (!command) return false;
    const { action } = command;

    if (action === "toggle") {
      if (state.capturing) cancelCapture();
      else state.active ? stop() : start();
    }
    else if (action === "start") {
      if (state.capturing) cancelCapture();
      else start();
    }
    else if (action === "stop") {
      if (state.capturing) cancelCapture();
      stop();
    }
    else if (action !== "status") return false;

    if (typeof sendResponse === "function") {
      sendResponse(Core.makeEnvelope("selection.state", {
        active: state.active,
        capturing: state.capturing,
        selectorProtocolVersion: command.responseProtocolVersion
      }, message.requestId));
    }
    return false;
  }

  function dispose() {
    cancelCapture("SmartShot selector was updated.");
    stop();
    if (typeof extensionApi.runtime.onMessage.removeListener === "function") {
      extensionApi.runtime.onMessage.removeListener(onRuntimeMessage);
    }
    window.removeEventListener("pagehide", onPageLifecycleExit, true);
    document.removeEventListener("visibilitychange", onVisibilityChange, true);
    if (globalThis.__smartShotSelectorController === controller) {
      delete globalThis.__smartShotSelectorController;
    }
  }

  const controller = Object.freeze({
    selectorProtocolVersion: SELECTOR_PROTOCOL_VERSION,
    dispose
  });
  globalThis.__smartShotSelectorController = controller;
  extensionApi.runtime.onMessage.addListener(onRuntimeMessage);

  window.addEventListener("pagehide", onPageLifecycleExit, true);
  document.addEventListener("visibilitychange", onVisibilityChange, true);
})();
