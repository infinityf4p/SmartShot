(function exposeSmartShotCaptureGuards(root, factory) {
  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  root.SmartShotCaptureGuards = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function makeSmartShotCaptureGuards() {
  "use strict";

  function closeEnough(first, second, tolerance = 2) {
    return Math.abs(first - second) <= tolerance;
  }

  function verificationSampleSize(width, height, maximumDimension = 96) {
    if (!Number.isFinite(width) || width <= 0 ||
        !Number.isFinite(height) || height <= 0 ||
        !Number.isFinite(maximumDimension) || maximumDimension < 1) {
      throw new Error("Capture pixel verification received invalid dimensions.");
    }

    const scale = Math.min(1, Math.floor(maximumDimension) / Math.max(width, height));
    return {
      width: Math.max(1, Math.round(width * scale)),
      height: Math.max(1, Math.round(height * scale))
    };
  }

  function validatedPixelSample(sample) {
    const width = sample && sample.width;
    const height = sample && sample.height;
    const data = sample && sample.data;
    if (!Number.isInteger(width) || width < 1 ||
        !Number.isInteger(height) || height < 1 ||
        !data || typeof data.length !== "number" || data.length !== width * height * 4) {
      throw new Error("Capture pixel verification received an invalid sample.");
    }
    return { width, height, data };
  }

  function pixelSampleDifference(firstSample, secondSample, options = {}) {
    const first = validatedPixelSample(firstSample);
    const second = validatedPixelSample(secondSample);
    if (first.width !== second.width || first.height !== second.height) {
      throw new Error("Capture pixel verification frames have different dimensions.");
    }

    const channelThreshold = Number.isFinite(options.channelThreshold)
      ? Math.max(0, options.channelThreshold)
      : 12;
    let changedPixels = 0;
    let totalChannelDelta = 0;
    for (let offset = 0; offset < first.data.length; offset += 4) {
      const redDelta = Math.abs(first.data[offset] - second.data[offset]);
      const greenDelta = Math.abs(first.data[offset + 1] - second.data[offset + 1]);
      const blueDelta = Math.abs(first.data[offset + 2] - second.data[offset + 2]);
      totalChannelDelta += redDelta + greenDelta + blueDelta;
      if (Math.max(redDelta, greenDelta, blueDelta) >= channelThreshold) changedPixels += 1;
    }

    const pixelCount = first.width * first.height;
    return Object.freeze({
      changedPixels,
      changedPixelRatio: changedPixels / pixelCount,
      meanChannelDelta: totalChannelDelta / (pixelCount * 3)
    });
  }

  function assertStablePixelSamples(first, second, options = {}) {
    const maximumChangedPixelRatio = Number.isFinite(options.maximumChangedPixelRatio)
      ? Math.max(0, options.maximumChangedPixelRatio)
      : 0.001;
    const maximumMeanChannelDelta = Number.isFinite(options.maximumMeanChannelDelta)
      ? Math.max(0, options.maximumMeanChannelDelta)
      : 0.75;
    const difference = pixelSampleDifference(first, second, options);
    if (difference.changedPixelRatio > maximumChangedPixelRatio ||
        difference.meanChannelDelta > maximumMeanChannelDelta) {
      throw new Error("Capture stopped because pixels in the selected block changed between frames.");
    }
    return difference;
  }

  function createCaptureCancellationController() {
    let reason = null;
    const listeners = new Set();

    return Object.freeze({
      cancel(message = "Capture cancelled.") {
        if (reason) return;
        reason = new Error(message);
        reason.name = "AbortError";
        for (const listener of listeners) {
          try {
            listener(reason);
          } catch (_error) {
            // Cancellation must continue even if one best-effort cleanup fails.
          }
        }
        listeners.clear();
      },
      get cancelled() {
        return reason !== null;
      },
      onCancel(listener) {
        if (typeof listener !== "function") return () => {};
        if (reason) {
          listener(reason);
          return () => {};
        }
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      throwIfCancelled() {
        if (reason) throw reason;
      }
    });
  }

  function isCaptureCancellation(error) {
    return Boolean(error && error.name === "AbortError");
  }

  function assertStandardVisualViewport(view) {
    const viewport = view.visualViewport;
    if (!viewport) return;
    if (!closeEnough(viewport.scale, 1, 0.01) ||
        !closeEnough(viewport.offsetLeft, 0, 0.5) ||
        !closeEnough(viewport.offsetTop, 0, 0.5)) {
      throw new Error("Reset page pinch zoom before starting a long capture.");
    }
  }

  function assertStableTarget(options) {
    if (options.currentURL() !== options.expectedURL) {
      throw new Error("Capture stopped because the page navigated.");
    }
    if (!options.element.isConnected) {
      throw new Error("Capture stopped because the selected block left the page.");
    }
    if (options.targetMutated()) {
      throw new Error("Capture stopped because the selected block changed while scrolling.");
    }
    if (!closeEnough(options.view.innerWidth, options.expectedViewport.width, 0.5) ||
        !closeEnough(options.view.innerHeight, options.expectedViewport.height, 0.5)) {
      throw new Error("Capture stopped because the browser viewport changed.");
    }
    assertStandardVisualViewport(options.view);

    const rect = options.rectFor(options.element);
    const current = options.normalizeRect({
      x: rect.x + options.view.scrollX,
      y: rect.y + options.view.scrollY,
      width: rect.width,
      height: rect.height
    });
    if (!closeEnough(current.x, options.expectedRect.x) ||
        !closeEnough(current.y, options.expectedRect.y) ||
        !closeEnough(current.width, options.expectedRect.width) ||
        !closeEnough(current.height, options.expectedRect.height)) {
      throw new Error("Capture stopped because the selected block changed while scrolling.");
    }
  }

  function assertWindowScrollableTarget(target, documentElement, getStyle) {
    for (let ancestor = target.parentElement; ancestor && ancestor !== documentElement; ancestor = ancestor.parentElement) {
      const style = getStyle(ancestor);
      const canScrollY = /(auto|scroll|overlay)/.test(style.overflowY) &&
        ancestor.scrollHeight > ancestor.clientHeight + 1;
      const canScrollX = /(auto|scroll|overlay)/.test(style.overflowX) &&
        ancestor.scrollWidth > ancestor.clientWidth + 1;
      if (canScrollX || canScrollY) {
        throw new Error("A block inside a nested scroll area cannot be scrolling-captured reliably.");
      }
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

  function restoreStyles(changes, freezeStyle) {
    for (let index = changes.length - 1; index >= 0; index -= 1) {
      const change = changes[index];
      if (change.value) change.element.style.setProperty(change.property, change.value, change.priority);
      else change.element.style.removeProperty(change.property);
    }
    freezeStyle.remove();
  }

  function prepareCaptureEnvironment(options) {
    const { target, document, getComputedStyle, maximumStyleNodes } = options;
    assertWindowScrollableTarget(target, document.documentElement, getComputedStyle);
    const elements = Array.from(document.querySelectorAll("*"));
    if (elements.length > maximumStyleNodes) {
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

    let restored = false;
    const restore = () => {
      if (restored) return;
      restored = true;
      restoreStyles(changes, freezeStyle);
    };

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
      restore();
      throw error;
    }

    return restore;
  }

  function assertScrollPosition(view, x, y) {
    if (!closeEnough(view.scrollX, x, 1) || !closeEnough(view.scrollY, y, 1)) {
      throw new Error("Capture stopped because the page was scrolled during a capture slice.");
    }
  }

  async function restorePageState(view, originalScroll, restoreEnvironment, nextPaint) {
    let firstError = null;
    try {
      view.scrollTo(originalScroll.x, originalScroll.y);
    } catch (error) {
      firstError = error;
    }
    try {
      restoreEnvironment();
    } catch (error) {
      firstError ||= error;
    }
    try {
      await nextPaint();
    } catch (error) {
      firstError ||= error;
    }
    // Restoring fixed/sticky elements can change layout or trigger scroll anchoring.
    // Reapply the original position after that layout has settled.
    try {
      view.scrollTo(originalScroll.x, originalScroll.y);
    } catch (error) {
      firstError ||= error;
    }
    try {
      await nextPaint();
    } catch (error) {
      firstError ||= error;
    }
    if (firstError) throw firstError;
  }

  return Object.freeze({
    assertScrollPosition,
    assertStablePixelSamples,
    assertStableTarget,
    assertStandardVisualViewport,
    assertWindowScrollableTarget,
    closeEnough,
    createCaptureCancellationController,
    isCaptureCancellation,
    pixelSampleDifference,
    prepareCaptureEnvironment,
    restorePageState,
    verificationSampleSize
  });
});
