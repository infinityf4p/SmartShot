"use strict";

class FixtureStyleDeclaration {
  constructor(initial = {}) {
    this.values = new Map();
    for (const [property, value] of Object.entries(initial)) {
      this.setProperty(property, value);
    }
  }

  getPropertyValue(property) {
    return this.values.get(property)?.value || "";
  }

  getPropertyPriority(property) {
    return this.values.get(property)?.priority || "";
  }

  setProperty(property, value, priority = "") {
    this.values.set(property, { value: String(value), priority: String(priority) });
  }

  removeProperty(property) {
    const previous = this.getPropertyValue(property);
    this.values.delete(property);
    return previous;
  }
}

class FixtureElement {
  constructor(localName, options = {}) {
    this.nodeType = 1;
    this.localName = localName;
    this.attributes = { ...(options.attributes || {}) };
    this.rect = {
      x: 0,
      y: 0,
      width: 100,
      height: 40,
      ...(options.rect || {})
    };
    this.computed = {
      display: "block",
      visibility: "visible",
      opacity: "1",
      position: "static",
      overflowX: "visible",
      overflowY: "visible",
      ...(options.computed || {})
    };
    this.style = new FixtureStyleDeclaration(options.inlineStyle);
    this.children = [];
    this.parentElement = null;
    this.isConnected = options.isConnected !== false;
    this.clientWidth = options.clientWidth ?? this.rect.width;
    this.clientHeight = options.clientHeight ?? this.rect.height;
    this.scrollWidth = options.scrollWidth ?? this.clientWidth;
    this.scrollHeight = options.scrollHeight ?? this.clientHeight;
    this.textContent = "";
    this.removed = false;
  }

  append(...children) {
    for (const child of children) {
      child.parentElement = this;
      child.isConnected = this.isConnected;
      this.children.push(child);
    }
  }

  getAttribute(name) {
    return this.attributes[name] ?? null;
  }

  getBoundingClientRect() {
    return {
      ...this.rect,
      left: this.rect.x,
      top: this.rect.y,
      right: this.rect.x + this.rect.width,
      bottom: this.rect.y + this.rect.height
    };
  }

  contains(candidate) {
    for (let element = candidate; element; element = element.parentElement) {
      if (element === this) return true;
    }
    return false;
  }

  remove() {
    this.removed = true;
    if (!this.parentElement) return;
    const index = this.parentElement.children.indexOf(this);
    if (index >= 0) this.parentElement.children.splice(index, 1);
    this.parentElement = null;
    this.isConnected = false;
  }
}

function computedStyleFor(element) {
  const value = (property, fallback) => element.style.getPropertyValue(property) || fallback;
  return {
    display: value("display", element.computed.display),
    visibility: value("visibility", element.computed.visibility),
    opacity: value("opacity", element.computed.opacity),
    position: value("position", element.computed.position),
    overflowX: value("overflow-x", element.computed.overflowX),
    overflowY: value("overflow-y", element.computed.overflowY)
  };
}

function flatten(root) {
  return [root, ...root.children.flatMap(flatten)];
}

class FixtureDocument {
  constructor(documentElement) {
    this.documentElement = documentElement;
  }

  querySelectorAll(selector) {
    if (selector !== "*") throw new Error(`Unsupported fixture selector: ${selector}`);
    return flatten(this.documentElement);
  }

  createElement(localName) {
    return new FixtureElement(localName, { rect: { width: 0, height: 0 } });
  }
}

module.exports = {
  FixtureDocument,
  FixtureElement,
  FixtureStyleDeclaration,
  computedStyleFor,
  flatten
};
