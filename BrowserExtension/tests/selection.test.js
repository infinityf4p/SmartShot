"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("../shared/core.js");
const Selection = require("../shared/selection.js");
const { FixtureElement, computedStyleFor } = require("./fixture-dom.js");

function element(tag, attributes, rect, computed) {
  return new FixtureElement(tag, { attributes, rect, computed });
}

function chainFrom(leaf, html) {
  return Selection.candidateChainFromLeaf(leaf, {
    documentElement: html,
    overlayHost: null,
    getComputedStyle: computedStyleFor
  });
}

function xTimelineFixture() {
  const html = element("html", {}, { width: 1200, height: 5000 });
  const main = element("main", { role: "main" }, { x: 180, width: 800, height: 4200 });
  const cell = element("div", { "data-testid": "cellInnerDiv" }, { x: 260, y: 200, width: 620, height: 980 });
  const article = element("article", { "data-testid": "tweet" }, { x: 270, y: 210, width: 600, height: 960 });
  const text = element("div", { "data-testid": "tweetText" }, { x: 300, y: 300, width: 540, height: 180 });
  const media = element("div", { "data-testid": "tweetPhoto" }, { x: 300, y: 500, width: 540, height: 420 });
  const image = element("img", { alt: "media" }, { x: 305, y: 505, width: 530, height: 410 }, { display: "inline" });
  html.append(main);
  main.append(cell);
  cell.append(article);
  article.append(text, media);
  media.append(image);
  return { html, main, cell, article, text, media, image };
}

test("X timeline media resolves to its outer single tweet article", () => {
  const fixture = xTimelineFixture();
  const chain = chainFrom(fixture.image, fixture.html);

  assert.equal(chain[0], fixture.article);
  assert.equal(Core.kindFromDescriptor(Selection.descriptor(chain[0])), "x-post");
  assert.deepEqual(chain.filter(Selection.isXPost), [fixture.article]);
});

test("a nested quoted tweet resolves to the outer original post", () => {
  const fixture = xTimelineFixture();
  const quoteLink = element("div", { role: "link" }, { x: 310, y: 700, width: 520, height: 300 });
  const quotedArticle = element("article", { "data-testid": "tweet" }, { x: 320, y: 710, width: 500, height: 280 });
  const quotedText = element("div", { "data-testid": "tweetText" }, { x: 340, y: 750, width: 460, height: 100 });
  fixture.article.append(quoteLink);
  quoteLink.append(quotedArticle);
  quotedArticle.append(quotedText);

  const chain = chainFrom(quotedText, fixture.html);
  assert.equal(chain[0], fixture.article);
  assert.equal(chain.includes(quotedArticle), false);
  assert.deepEqual(chain.filter(Selection.isXPost), [fixture.article]);
});

test("reply and detail timeline siblings stay separate single-post selections", () => {
  const fixture = xTimelineFixture();
  fixture.main.attributes["aria-label"] = "Timeline: Conversation";
  const replyCell = element("div", { "data-testid": "cellInnerDiv" }, { x: 260, y: 1220, width: 620, height: 520 });
  const replyArticle = element("article", { "data-testid": "tweet" }, { x: 270, y: 1230, width: 600, height: 500 });
  const replyText = element("div", { "data-testid": "tweetText" }, { x: 300, y: 1320, width: 540, height: 120 });
  fixture.main.append(replyCell);
  replyCell.append(replyArticle);
  replyArticle.append(replyText);

  const originalChain = chainFrom(fixture.text, fixture.html);
  const replyChain = chainFrom(replyText, fixture.html);
  assert.equal(originalChain[0], fixture.article);
  assert.equal(replyChain[0], replyArticle);
  assert.equal(originalChain.includes(replyArticle), false);
  assert.equal(replyChain.includes(fixture.article), false);
});

test("repost social context and post text resolve to the containing tweet", () => {
  const fixture = xTimelineFixture();
  const socialContext = element("div", { "data-testid": "socialContext" }, { x: 290, y: 230, width: 550, height: 30 });
  fixture.article.append(socialContext);

  assert.equal(chainFrom(socialContext, fixture.html)[0], fixture.article);
  assert.equal(chainFrom(fixture.text, fixture.html)[0], fixture.article);
});

test("generic pages start at the nearest layout block and climb semantic ancestors", () => {
  const html = element("html", {}, { width: 1200, height: 2400 });
  const main = element("main", { role: "main" }, { x: 100, width: 900, height: 1800 });
  const section = element("section", { role: "region" }, { x: 140, y: 100, width: 760, height: 800 });
  const article = element("article", {}, { x: 170, y: 130, width: 700, height: 620 });
  const card = element("div", {}, { x: 200, y: 160, width: 620, height: 420 }, { display: "grid" });
  const label = element("span", {}, { x: 220, y: 180, width: 200, height: 24 }, { display: "inline" });
  html.append(main);
  main.append(section);
  section.append(article);
  article.append(card);
  card.append(label);

  const chain = chainFrom(label, html);
  assert.equal(chain[0], card);
  assert.ok(chain.includes(article));
  assert.ok(chain.includes(section));
  assert.ok(chain.includes(main));
  assert.deepEqual(chain.filter(Selection.isXPost), []);
});

test("overlay and unusable leaves do not become candidates", () => {
  const html = element("html", {}, { width: 1200, height: 800 });
  const overlay = element("div", {}, { width: 1200, height: 800 });
  const hidden = element("span", {}, { width: 10, height: 10 }, { display: "none" });
  html.append(overlay, hidden);

  assert.deepEqual(Selection.candidateChainFromLeaf(overlay, {
    documentElement: html,
    overlayHost: overlay,
    getComputedStyle: computedStyleFor
  }), []);
  assert.deepEqual(chainFrom(hidden, html), []);
});
