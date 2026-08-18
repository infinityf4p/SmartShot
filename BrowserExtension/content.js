(function installSmartShotSelector() {
  "use strict";

  if (globalThis.__blockShotSelectorInstalled) return;
  globalThis.__blockShotSelectorInstalled = true;

  const extensionApi = globalThis.browser || globalThis.chrome;
  const Core = globalThis.SmartShotCore;
  const BLOCK_TAGS = new Set([
    "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt",
    "figure", "figcaption", "footer", "form", "header", "li", "main", "nav",
    "ol", "p", "pre", "section", "table", "tbody", "td", "th", "thead", "tr", "ul"
  ]);
  const SEMANTIC_ROLES = new Set(["article", "group", "listitem", "main", "region"]);
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
    const rect = element.getBoundingClientRect();
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  }

  function hasUsableRect(element) {
    const rect = rectFor(element);
    if (rect.width < 32 || rect.height < 18) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity) !== 0;
  }

  function isSemantic(element) {
    const tag = element.localName;
    const role = (element.getAttribute("role") || "").toLowerCase();
    return tag === "article" || tag === "main" || tag === "section" || SEMANTIC_ROLES.has(role);
  }

  function isLayoutBlock(element) {
    if (!(element instanceof Element) || !hasUsableRect(element)) return false;
    if (BLOCK_TAGS.has(element.localName)) return true;
    const display = getComputedStyle(element).display;
    return display === "block" || display === "flex" || display === "grid" || display === "flow-root";
  }

  function descriptor(element) {
    return {
      tagName: element.localName,
      role: element.getAttribute("role") || "",
      testId: element.getAttribute("data-testid") || ""
    };
  }

  function kindFor(element) {
    return Core.kindFromDescriptor(descriptor(element));
  }

  function substantiallyLarger(element, previous) {
    if (!previous) return true;
    const nextRect = rectFor(element);
    const previousRect = rectFor(previous);
    const nextArea = nextRect.width * nextRect.height;
    const previousArea = previousRect.width * previousRect.height;
    return nextRect.width >= previousRect.width + 6 ||
      nextRect.height >= previousRect.height + 6 ||
      nextArea >= previousArea * 1.08;
  }

  function candidateChainAt(x, y) {
    let leaf = document.elementFromPoint(x, y);
    if (!leaf || leaf === state.host) return [];
    if (leaf.nodeType !== Node.ELEMENT_NODE) leaf = leaf.parentElement;

    const ancestry = [];
    for (let element = leaf; element && element !== document.documentElement; element = element.parentElement) {
      ancestry.push(element);
    }

    const xPost = leaf.closest('article[data-testid="tweet"]');
    // X posts are intentional product-level blocks. Generic pages start at the
    // nearest layout block so the user can climb into article/section/main.
    let base = xPost && hasUsableRect(xPost) ? xPost : ancestry.find(isLayoutBlock);
    if (!base) return [];

    const baseIndex = ancestry.indexOf(base);
    const chain = [];
    for (let index = baseIndex; index < ancestry.length; index += 1) {
      const element = ancestry[index];
      if (!isLayoutBlock(element) && !isSemantic(element)) continue;
      if (!hasUsableRect(element)) continue;
      if (!substantiallyLarger(element, chain[chain.length - 1])) continue;
      chain.push(element);
      if (chain.length === 10) break;
    }
    return chain;
  }

  function metadataFor(_element, kind) {
    return kind === "x-post" ? { platform: "x" } : {};
  }

  function currentElement() {
    return state.chain[state.level] || null;
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
    state.level = preservedIndex >= 0 ? preservedIndex : 0;
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
      stop();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
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

  function onClick(event) {
    if (!state.active || !currentElement()) return;
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
    return Math.abs(first - second) <= tolerance;
  }

  function assertStandardVisualViewport() {
    const viewport = window.visualViewport;
    if (!viewport) return;
    if (!closeEnough(viewport.scale, 1, 0.01) ||
        !closeEnough(viewport.offsetLeft, 0, 0.5) ||
        !closeEnough(viewport.offsetTop, 0, 0.5)) {
      throw new Error("Reset page pinch zoom before starting a long capture.");
    }
  }

  function assertStableTarget(element, expectedRect, expectedURL, expectedViewport, targetMutated) {
    if (location.href !== expectedURL) throw new Error("Capture stopped because the page navigated.");
    if (!element.isConnected) throw new Error("Capture stopped because the selected block left the page.");
    if (targetMutated()) throw new Error("Capture stopped because the selected block changed while scrolling.");
    if (!closeEnough(window.innerWidth, expectedViewport.width, 0.5) ||
        !closeEnough(window.innerHeight, expectedViewport.height, 0.5)) {
      throw new Error("Capture stopped because the browser viewport changed.");
    }
    assertStandardVisualViewport();
    const current = pageRectFor(element);
    if (!closeEnough(current.x, expectedRect.x) ||
        !closeEnough(current.y, expectedRect.y) ||
        !closeEnough(current.width, expectedRect.width) ||
        !closeEnough(current.height, expectedRect.height)) {
      throw new Error("Capture stopped because the selected block changed while scrolling.");
    }
  }

  function setTemporaryStyle(changes, element, property, value) {
    changes.push({
      element,
      property,
      value: element.style.getPropertyValue(property),
      priority: element.style.getPropertyPriority(property)
    });
    element.style.setProperty(property, value, "important");
  }

  function assertWindowScrollableTarget(target) {
    for (let ancestor = target.parentElement; ancestor && ancestor !== document.documentElement; ancestor = ancestor.parentElement) {
      const style = getComputedStyle(ancestor);
      const canScrollY = /(auto|scroll|overlay)/.test(style.overflowY) &&
        ancestor.scrollHeight > ancestor.clientHeight + 1;
      const canScrollX = /(auto|scroll|overlay)/.test(style.overflowX) &&
        ancestor.scrollWidth > ancestor.clientWidth + 1;
      if (canScrollX || canScrollY) {
        throw new Error("A block inside a nested scroll area cannot be scrolling-captured reliably.");
      }
    }
  }

  function prepareCaptureEnvironment(target) {
    assertWindowScrollableTarget(target);
    const elements = Array.from(document.querySelectorAll("*"));
    if (elements.length > Core.CAPTURE_LIMITS.maxStyleNodes) {
      throw new Error("The page is too large to freeze safely for a long capture.");
    }

    const changes = [];
    const freezeStyle = document.createElement("style");
    freezeStyle.textContent = `
      *, *::before, *::after {
        animation-play-state: paused !important;
        caret-color: transparent !important;
        scroll-behavior: auto !important;
        transition-duration: 0s !important;
        transition-delay: 0s !important;
      }
      html { overflow-anchor: none !important; scroll-behavior: auto !important; }
    `;
    document.documentElement.append(freezeStyle);

    try {
      for (const element of elements) {
        const position = getComputedStyle(element).position;
        if (position !== "fixed" && position !== "sticky") continue;

        if (element === target || element.contains(target)) {
          throw new Error("A block inside a fixed or sticky container cannot be scrolling-captured reliably.");
        }
        if (!target.contains(element) || position === "fixed") {
          setTemporaryStyle(changes, element, "visibility", "hidden");
          continue;
        }

        setTemporaryStyle(changes, element, "position", "relative");
        for (const edge of ["top", "right", "bottom", "left"]) {
          setTemporaryStyle(changes, element, edge, "auto");
        }
      }
    } catch (error) {
      for (const change of changes.reverse()) {
        if (change.value) change.element.style.setProperty(change.property, change.value, change.priority);
        else change.element.style.removeProperty(change.property);
      }
      freezeStyle.remove();
      throw error;
    }

    return () => {
      for (const change of changes.reverse()) {
        if (change.value) change.element.style.setProperty(change.property, change.value, change.priority);
        else change.element.style.removeProperty(change.property);
      }
      freezeStyle.remove();
    };
  }

  async function scrollAndSettle(x, y, deadline) {
    window.scrollTo(x, y);
    for (let frame = 0; frame < 10; frame += 1) {
      assertBeforeDeadline(deadline);
      await new Promise((resolve) => requestAnimationFrame(resolve));
      if (closeEnough(window.scrollX, x, 1) && closeEnough(window.scrollY, y, 1)) {
        await nextPaint();
        return;
      }
    }
    throw new Error("Capture stopped because the page did not settle at the requested scroll position.");
  }

  function assertScrollPosition(x, y) {
    if (!closeEnough(window.scrollX, x, 1) || !closeEnough(window.scrollY, y, 1)) {
      throw new Error("Capture stopped because the page was scrolled during a capture slice.");
    }
  }

  function loadImage(dataUrl) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error("The captured browser image could not be decoded."));
      image.src = dataUrl;
    });
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

  function assertEnvelopeResponse(response, type) {
    if (!Core.isEnvelope(response)) throw new Error("SmartShot returned an invalid response.");
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

  async function captureLongElement(element, initialCandidate) {
    const originalScroll = { x: window.scrollX, y: window.scrollY };
    const expectedURL = location.href;
    const deadline = deadlineAfter(Core.CAPTURE_LIMITS.maxDurationMs);
    const restoreEnvironment = prepareCaptureEnvironment(element);
    const requestId = Core.makeEnvelope("capture.long.begin", {}).requestId;
    let targetChanged = false;
    let targetObserver = null;
    let sessionStarted = false;
    let completed = false;

    try {
      await nextPaint();
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
      assertEnvelopeResponse(ready, "capture.long.ready");
      sessionStarted = true;

      let canvas = null;
      let context = null;
      let outputSize = null;
      let capturedImageSize = null;
      let scaleX = 0;
      let scaleY = 0;

      for (const slice of slices) {
        assertStableTarget(element, targetRect, expectedURL, viewport, () => targetChanged);
        await scrollAndSettle(slice.scrollX, slice.scrollY, deadline);
        assertStableTarget(element, targetRect, expectedURL, viewport, () => targetChanged);

        const request = Core.makeEnvelope("capture.slice.request", { index: slice.index }, requestId);
        const response = assertEnvelopeResponse(
          await sendBeforeDeadline(request, deadline),
          "capture.slice.response"
        );
        if (response.payload.index !== slice.index || typeof response.payload.imageDataUrl !== "string") {
          throw new Error("The browser returned a mismatched capture slice.");
        }

        const image = await withTimeout(
          loadImage(response.payload.imageDataUrl),
          remainingTime(deadline),
          "A capture slice could not be decoded before the timeout."
        );
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
      assertEnvelopeResponse(await sendBeforeDeadline(end, deadline), "capture.long.ended");
      completed = true;

      const result = canvas.toDataURL("image/png");
      if (!result.startsWith("data:image/png")) {
        throw new Error("The browser could not encode the completed long capture.");
      }
      return result;
    } finally {
      if (targetObserver) targetObserver.disconnect();
      if (sessionStarted && !completed) {
        const cancel = Core.makeEnvelope("capture.long.end", { cancelled: true }, requestId);
        try {
          await withTimeout(sendMessage(cancel), 1000, "Capture cancellation timed out.");
        } catch (_error) {
          // The background worker also expires abandoned sessions automatically.
        }
      }
      window.scrollTo(originalScroll.x, originalScroll.y);
      restoreEnvironment();
      await nextPaint();
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
    state.capturing = true;
    stop();
    await nextPaint();

    try {
      const refreshedCandidate = candidateFor(element);
      if (!refreshedCandidate) throw new Error("The selected block is no longer on the page.");
      if (!Core.isRectFullyVisible(refreshedCandidate.viewportRect, refreshedCandidate.viewport)) {
        const imageDataUrl = await captureLongElement(element, refreshedCandidate);
        downloadDataUrl(imageDataUrl, filenameFor(refreshedCandidate));
        return;
      }

      const request = Core.makeEnvelope("capture.request", { candidate: refreshedCandidate });
      const response = await sendMessage(request);
      if (!Core.isEnvelope(response)) throw new Error("SmartShot returned an invalid response.");
      if (response.type === "error") throw new Error(response.payload.message || "Capture failed.");
      if (response.payload.handledBy === "native") return;
      if (response.type !== "capture.response" || typeof response.payload.imageDataUrl !== "string") {
        throw new Error("No browser capture was returned.");
      }

      const croppedDataUrl = await cropVisibleCapture(response.payload.imageDataUrl, refreshedCandidate);
      downloadDataUrl(croppedDataUrl, filenameFor(refreshedCandidate));
    } catch (error) {
      console.error("SmartShot capture failed:", error);
      showCaptureError(error);
    } finally {
      state.capturing = false;
    }
  }

  extensionApi.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!Core.isEnvelope(message)) return false;
    if (message.type === "selection.toggle") state.active ? stop() : start();
    else if (message.type === "selection.start") start();
    else if (message.type === "selection.stop") stop();
    else return false;

    if (typeof sendResponse === "function") {
      sendResponse(Core.makeEnvelope("selection.state", { active: state.active }, message.requestId));
    }
    return false;
  });
})();
