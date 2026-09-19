// Run with: node Tests/reader-script-checks.mjs
// Execute the actual embedded reader scripts against a small instrumented DOM.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const readerSource = fs.readFileSync(new URL('../Yomi/ReaderView.swift', import.meta.url), 'utf8');
const readerScript = readerSource.slice(readerSource.indexOf('    (() => {'), readerSource.indexOf('    """', readerSource.indexOf('    (() => {')))
  .replaceAll('\\(Self.analyzeParagraphHandlerName)', 'yomiAnalyzeParagraph')
  .replaceAll('\\(escapedAnalyzeLabel)', '段落を解析');

function chapter(count) {
  let siblingVisits = 0, queries = 0;
  const messages = [];
  const observers = [];
  class Element {
    constructor(tag, parent = null) {
      this.localName = tag; this.parentElement = parent; this.nodes = [];
      this.nodeType = 1; this.dataset = {}; this.events = {}; this.attributes = {};
      this.style = { setProperty() {} };
      if (parent) parent.nodes.push(this);
    }
    get children() {
      const nodes = this.nodes;
      return { *[Symbol.iterator]() { for (const node of nodes) { siblingVisits++; yield node; } } };
    }
    get previousElementSibling() { return this.parentElement.nodes[this.parentElement.nodes.indexOf(this) - 1]; }
    matches(selector) { return selector === '.yomi-paragraph-slot' && this.isSlot; }
    querySelectorAll(selector) {
      return this.nodes.flatMap(node => [...(node.matches(selector) ? [node] : []), ...node.querySelectorAll(selector)]);
    }
    replaceChildren() { this.nodes = []; }
    setAttribute(key, value) { this.attributes[key] = value; }
    addEventListener(type, handler) { this.events[type] = handler; }
    closest() { return this.isControl ? this : null; }
    scrollIntoView(options) { this.revealed = options; }
  }
  const root = new Element('html');
  const body = new Element('body', root);
  const section = new Element('section', body);
  const targets = [];
  function add(text) {
    const target = new Element('p', section);
    target.textContent = text + '読み';
    const slot = new Element('span', section);
    slot.isSlot = true; slot.dataset.yomiParagraphText = text;
    targets.push(target);
    return slot;
  }
  for (let i = 0; i < count; i++) add(`段落${i} — 漢字😀`);
  const document = {
    documentElement: root, readyState: 'complete',
    querySelectorAll(selector) { queries++; return root.querySelectorAll(selector); }
  };
  let collapsed = true;
  const window = { webkit: { messageHandlers: { yomiAnalyzeParagraph: { postMessage: value => messages.push(value) } } },
    getSelection: () => ({ isCollapsed: collapsed }) };
  vm.runInNewContext(readerScript, { document, window, Node: { ELEMENT_NODE: 1 },
    MutationObserver: class { constructor(callback) { observers.push(callback); } observe() {} } });
  function click(index, options = {}) {
    let prevented = false;
    const target = targets[index];
    target.events[options.key ? 'keydown' : 'click']({
      target: options.control ? { closest: () => ({}) } : target,
      key: options.key, preventDefault() { prevented = true; }, stopPropagation() {}
    });
    return prevented;
  }
  return { targets, messages, click, window, add, observers,
    selection: value => { collapsed = value; },
    metrics: () => ({ siblingVisits, queries }) };
}

const fixture = chapter(3000);
const start = performance.now();
assert.equal(fixture.click(1500), true);
const elapsed = performance.now() - start;
let payload = fixture.messages.at(-1);
assert.equal(payload.index, 1500);
assert.equal(payload.paragraphs.length, 3000);
assert.equal(payload.paragraphs[1500], '段落1500 — 漢字😀');
assert.equal(payload.selectors[1500], 'html > body:nth-child(1) > section:nth-child(1) > p:nth-child(3001)');
assert.equal(payload.highlights[1500], fixture.targets[1500].textContent);
assert.equal(fixture.targets[0].attributes['aria-description'], '段落を解析');
assert.ok(fixture.metrics().siblingVisits <= 6002, 'Selectors must visit each sibling at most once');
const firstMetrics = fixture.metrics();
fixture.click(2999);
assert.deepEqual(fixture.metrics(), firstMetrics, 'Repeat taps should reuse the chapter index and selectors');
assert.equal(fixture.window.yomiRevealParagraph(2999), true);
assert.equal(fixture.window.yomiRevealParagraph(-1), false);
assert.equal(fixture.targets[2999].revealed.behavior, 'auto');
const messageCount = fixture.messages.length;
fixture.selection(false); fixture.click(1);
fixture.selection(true); fixture.click(1, { control: true });
assert.equal(fixture.messages.length, messageCount, 'Selection and links must retain native interaction');
fixture.click(2, { key: 'Enter' });
assert.equal(fixture.messages.at(-1).index, 2);
const slot = fixture.add('追加段落');
fixture.observers[0]([{ addedNodes: [fixture.targets.at(-1), slot] }]);
fixture.click(3000);
assert.equal(fixture.messages.at(-1).paragraphs.length, 3001, 'DOM changes must invalidate cached data');
assert.equal(fixture.messages.at(-1).selectors[3000], 'html > body:nth-child(1) > section:nth-child(1) > p:nth-child(6001)');

const analysisSource = fs.readFileSync(new URL('../Yomi/ParagraphAnalysisView.swift', import.meta.url), 'utf8');
const highlightScript = analysisSource.slice(analysisSource.indexOf('              const tokens = Array.from'), analysisSource.indexOf('              const reportHeight ='));
const active = new Set();
const tokens = Array.from({ length: 10000 }, (_, index) => ({
  dataset: { start: String(index * 3), end: String(index * 3 + 3) },
  classList: { add() { active.add(index); }, remove() { active.delete(index); } }
}));
const highlightWindow = {};
let tokenQueries = 0;
vm.runInNewContext(highlightScript, { window: highlightWindow, document: { querySelectorAll() { tokenQueries++; return tokens; } } });
for (const [start, length] of [[0, 1], [29997, 3], [15001, 9], [0, 0], [30000, 1], [5, 0], [8, 20], [1, 1]]) {
  highlightWindow.yomiHighlightRange(start, length);
  const expected = tokens.flatMap((token, i) => length > 0 && Number(token.dataset.start) < start + length && Number(token.dataset.end) > start ? [i] : []);
  assert.deepEqual([...active].sort((a, b) => a - b), expected);
}
assert.equal(tokenQueries, 1, 'Speech ticks must reuse the token index');
console.log(`PASS: 3,000-paragraph bridge (${elapsed.toFixed(1)} ms in synthetic DOM, ${firstMetrics.siblingVisits} sibling visits), cache invalidation, locator indices, selection/keyboard behavior, 10,000-token highlighting.`);
