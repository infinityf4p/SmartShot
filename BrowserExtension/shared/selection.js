(function exposeSmartShotSelection(root, factory) {
  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  root.SmartShotSelection = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function makeSmartShotSelection() {
  "use strict";

  const BLOCK_TAGS = new Set([
    "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt",
    "figure", "figcaption", "footer", "form", "header", "li", "main", "nav",
    "ol", "p", "pre", "section", "table", "tbody", "td", "th", "thead", "tr", "ul"
  ]);
  const SEMANTIC_ROLES = new Set(["article", "group", "listitem", "main", "region"]);

  function rectFor(element) {
    const rect = element.getBoundingClientRect();
    return {
      x: Number(rect.x ?? rect.left),
      y: Number(rect.y ?? rect.top),
      width: Number(rect.width),
      height: Number(rect.height)
    };
  }

  function descriptor(element) {
    return {
      tagName: element.localName,
      role: element.getAttribute("role") || "",
      testId: element.getAttribute("data-testid") || ""
    };
  }

  function hasUsableRect(element, getStyle) {
    const rect = rectFor(element);
    if (![rect.x, rect.y, rect.width, rect.height].every(Number.isFinite)) return false;
    if (rect.width < 32 || rect.height < 18) return false;
    const style = getStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity) !== 0;
  }

  function isSemantic(element) {
    const tag = element.localName;
    const role = (element.getAttribute("role") || "").toLowerCase();
    return tag === "article" || tag === "li" || tag === "main" || tag === "section" ||
      SEMANTIC_ROLES.has(role);
  }

  function isLayoutBlock(element, getStyle) {
    if (!element || element.nodeType !== 1 || !hasUsableRect(element, getStyle)) return false;
    if (BLOCK_TAGS.has(element.localName)) return true;
    const display = getStyle(element).display;
    return display === "block" || display === "flex" || display === "grid" || display === "flow-root";
  }

  function isXPost(element) {
    return element.localName === "article" &&
      (element.getAttribute("data-testid") || "").toLowerCase() === "tweet";
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

  function ancestryFor(leaf, documentElement) {
    const ancestry = [];
    for (let element = leaf; element && element !== documentElement; element = element.parentElement) {
      ancestry.push(element);
    }
    return ancestry;
  }

  function candidateChainFromLeaf(leaf, options) {
    if (!leaf || leaf === options.overlayHost) return [];
    if (leaf.nodeType !== 1) leaf = leaf.parentElement;
    if (!leaf) return [];

    const getStyle = options.getComputedStyle;
    const ancestry = ancestryFor(leaf, options.documentElement);
    // Quoted posts can contain their own tweet article. The product unit is the
    // outer timeline/detail article under the pointer, never the nested quote.
    const xPost = ancestry
      .filter((element) => isXPost(element) && hasUsableRect(element, getStyle))
      .at(-1);
    const base = xPost || ancestry.find((element) => isLayoutBlock(element, getStyle));
    if (!base) return [];

    const chain = [];
    for (let index = ancestry.indexOf(base); index < ancestry.length; index += 1) {
      const element = ancestry[index];
      if (!isLayoutBlock(element, getStyle) && !isSemantic(element)) continue;
      if (!hasUsableRect(element, getStyle)) continue;
      if (!substantiallyLarger(element, chain[chain.length - 1])) continue;
      chain.push(element);
      if (chain.length === (options.maximumLength || 10)) break;
    }
    return chain;
  }

  return Object.freeze({
    candidateChainFromLeaf,
    descriptor,
    hasUsableRect,
    isSemantic,
    isXPost,
    rectFor
  });
});
