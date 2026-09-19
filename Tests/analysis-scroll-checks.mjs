// Run the shipped analysis script against an instrumented layout/DOM fixture.
// This verifies state, bounds and anchor math, not device frame rates or WebKit typography.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../Yomi/AnalysisReader.js', import.meta.url), 'utf8');
function fixture(count = 3000, initialIndex = 1500) {
  let offsetReads = 0, queries = 0;
  const frames = new Map(), events = {}, messages = [], resizeObservers = [];
  let nextFrame = 0;
  class Element {
    constructor(tag) {
      this.tagName = tag; this.children = []; this.dataset = {}; this.attributes = {};
      this.style = { setProperty() {} }; this.className = ''; this.textContent = ''; this.hidden = false;
      this.classList = { values: new Set(), add: value => this.classList.values.add(value), remove: value => this.classList.values.delete(value) };
    }
    append(...nodes) {
      for (const node of nodes) {
        if (node.tagName === 'fragment') this.append(...node.children);
        else { node.parentElement = this; this.children.push(node); }
      }
    }
    replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
    setAttribute(key, value) { this.attributes[key] = value; }
    addEventListener(name, action) { this[name] = action; }
    closest(selector) {
      if (selector === 'button' && this.tagName === 'button') return this;
      if (selector === '.paragraph' && this.className === 'paragraph') return this;
      return this.parentElement?.closest(selector) ?? null;
    }
    get offsetTop() {
      offsetReads++;
      if (this.className !== 'paragraph') return 0;
      return 16 + root.children.slice(0, Number(this.dataset.index)).reduce((sum, section) => sum + section.offsetHeight + 24, 0);
    }
    get offsetHeight() {
      if (this.style.height) return Number.parseFloat(this.style.height);
      return this.children.reduce((height, node) => height + (node.hidden ? 0 : node.className === 'translation' ? 50 + node.children.length * 60 : node.className === 'actions' ? 44 : 160), 24);
    }
    getBoundingClientRect() { return { top: this.offsetTop - window.scrollY }; }
    scrollIntoView() { window.scrollY = this.offsetTop; }
    set innerHTML(html) {
      this.html = html;
      this.children = [];
      if (this.className !== 'tokens') return;
      for (const match of html.matchAll(/data-start="(\d+)" data-end="(\d+)"/g)) {
        const token = new Element('button'); token.className = 'token';
        token.dataset = { start: match[1], end: match[2], index: String(this.children.length) };
        this.append(token);
      }
    }
    querySelectorAll() { queries++; return this.children; }
  }
  const root = new Element('main');
  const document = { getElementById: () => root, createElement: tag => new Element(tag),
    createDocumentFragment: () => new Element('fragment'), documentElement: new Element('html') };
  let scrollY = 0;
  const window = {
    innerWidth: 390, innerHeight: 844,
    get scrollY() { return scrollY; },
    set scrollY(value) {
      // Model the browser's real scroll limit, including the trailing viewport runway.
      const height = 16 + root.children.reduce((sum, section) => sum + section.offsetHeight + 24, 0)
        + Math.max(24, this.innerHeight - 110);
      scrollY = Math.max(0, Math.min(value, height - this.innerHeight));
    },
    analysisConfiguration: { paragraphs: Array.from({ length: count }, (_, i) => `段落${i} 漢字😀`), initialIndex,
      labels: { bookmark: 'bookmark', unbookmark: 'remove', translate: 'translate', hideTranslation: 'hide', play: 'play', stop: 'stop', loading: 'loading', translation: 'translation', failed: 'failed', retry: 'retry' } },
    webkit: { messageHandlers: { analysis: { postMessage: value => messages.push(value) } } },
    scrollTo(_x, y) { this.scrollY = y; },
    scrollBy(_x, y) { this.scrollY += y; }, addEventListener: (name, callback) => { events[name] = callback; }
  };
  vm.runInNewContext(source, { document, window, ResizeObserver: class { constructor(callback) { resizeObservers.push(callback); } observe() {} }, requestAnimationFrame: callback => { frames.set(++nextFrame, callback); return nextFrame; } });
  const flush = () => { let loops = 0; while (frames.size) {
    assert.ok(++loops < 20, 'Layout must settle without a RAF feedback loop');
    const current = [...frames.values()]; frames.clear(); current.forEach(callback => callback());
  } };
  const receive = (action, value = {}) => window.analysisReceive(action, value);
  const lastWindow = () => messages.filter(value => value.action === 'window').at(-1);
  const render = (index, count = 10, generation = lastWindow().generations[index]) => {
    receive('render', { index, generation, html: Array.from({ length: count }, (_, i) => `<button data-start="${i * 3}" data-end="${i * 3 + 3}"></button>`).join('') });
  };
  const jump = index => { events.touchstart(); window.scrollY = root.children[index].offsetTop; events.scroll(); flush(); };
  return { root, window, messages, receive, flush, lastWindow, render, jump, events,
    layout: () => { resizeObservers.forEach(callback => callback()); flush(); },
    reads: () => offsetReads, queries: () => queries,
    scroll: () => { events.scroll(); flush(); } };
}

const f = fixture();
assert.equal(f.root.children.length, 3000);
assert.ok(f.root.children.every(row => row.children.length === 0), 'Offscreen chapter starts as lightweight spacers');
f.receive('start'); f.flush();
assert.equal(f.window.scrollY, f.root.children[1500].offsetTop - 16, 'Initial paragraph aligns with viewport');
assert.ok(f.lastWindow().indices.length <= 33);
assert.equal(f.lastWindow().indices[0], 1500, 'Visible paragraph is tokenized first');
for (const index of f.lastWindow().indices) f.render(index);
f.flush();
assert.equal(f.root.children[1500].getBoundingClientRect().top, 16, 'Hydrating earlier paragraphs preserves viewport anchor');
const callsBefore = f.messages.length, readsBefore = f.reads();
f.scroll();
assert.equal(f.messages.length, callsBefore, 'Stationary scrolling does not resend chapter state');
assert.ok(f.reads() - readsBefore < 40, 'Scroll lookup is logarithmic in chapter length');

const generation = f.lastWindow().generations[1499];
const before = f.root.children[1500].getBoundingClientRect().top;
f.receive('translation', { index: 1499, generation, state: 'translated', lines: ['翻訳😀', '<script>bad()</script>'] });
f.flush();
assert.equal(f.root.children[1500].getBoundingClientRect().top, before, 'Translation above viewport does not shift reading position');
const translated = f.root.children[1499].children[2];
assert.equal(translated.children[2].textContent, '<script>bad()</script>', 'Translation is inserted as text');
assert.equal(f.root.children[1499].children[1].children[1].attributes['aria-expanded'], 'true');
f.receive('translation', { index: 1499, generation, state: 'hidden', lines: [] }); f.flush();
assert.equal(f.root.children[1500].getBoundingClientRect().top, before, 'Collapsing translation preserves viewport');
assert.equal(translated.hidden, true);
assert.equal(f.root.children[1499].children[1].children[1].attributes['aria-expanded'], 'false');
f.receive('bookmark', { index: 1500, active: true, available: true }); f.flush();
const controls = f.root.children[1500].children[1];
assert.equal(controls.children[0].attributes['aria-pressed'], 'true');
f.receive('bookmark', { index: 1500, active: false, available: true }); f.flush();
assert.equal(controls.children[0].attributes['aria-pressed'], 'false');
f.root.click({ target: controls.children[1] });
assert.equal(f.messages.at(-1).action, 'translate');
assert.equal(f.messages.at(-1).index, 1500, 'Inline action addresses its own paragraph');

f.render(1500, 10000); f.flush();
const tokens = f.root.children[1500].children[0].children;
const queries = f.queries();
for (const [start, length] of [[0, 1], [29997, 3], [15001, 9], [0, 0], [30000, 1], [5, 0], [8, 20], [1, 1]]) {
  f.receive('highlight', { index: 1500, start, length });
  const actual = tokens.flatMap((token, i) => token.classList.values.has('is-speaking') ? [i] : []);
  const expected = tokens.flatMap((token, i) => length > 0 && +token.dataset.start < start + length && +token.dataset.end > start ? [i] : []);
  assert.deepEqual(actual, expected);
}
assert.equal(f.queries(), queries, 'Speech ticks reuse token offsets without DOM scans');

const oldGeneration = f.lastWindow().generations[1500];
f.jump(2800);
assert.ok(f.root.children.filter(row => row.dataset.live === 'true').length <= 33);
assert.equal(f.root.children[1500].children.length, 0, 'Eviction releases token DOM and controls');
f.jump(1500);
assert.notEqual(f.lastWindow().generations[1500], oldGeneration);
f.render(1500, 10, oldGeneration); f.flush();
assert.equal(f.root.children[1500].children[0].className, 'placeholder', 'Late result cannot populate a recycled row');
f.render(1500); f.flush();
f.receive('translation', { index: 1500, generation: oldGeneration, state: 'translated', lines: ['stale'] }); f.flush();
assert.equal(f.root.children[1500].children[2].hidden, true, 'Late translation cannot populate a recycled row');
for (const index of [0, 2999, 1, 1500, 2998]) {
  f.jump(index);
  assert.ok(f.lastWindow().indices.every(i => i >= 0 && i < 3000));
  assert.ok(f.root.children.filter(row => row.dataset.live === 'true').length <= 33);
}
const one = fixture(1, 0); one.receive('start'); one.flush(); one.render(0); one.flush();
assert.deepEqual(Array.from(one.lastWindow().indices), [0]);
console.log('PASS: continuous analysis, 3,000 paragraphs, bounded live DOM, initial/return positioning, anchor-preserving translation, inline toggles, stale result rejection, 10,000-token highlights.');

// Previously the initial one-shot scroll was clamped for short chapters / near the end.
for (const [count, selected] of [[1, 0], [3, 2], [8, 6], [3000, 2999]]) {
  const pinned = fixture(count, selected);
  pinned.receive('start'); pinned.flush();
  assert.equal(pinned.root.children[selected].getBoundingClientRect().top, 16);
  assert.equal(pinned.lastWindow().indices[0], selected);
  // Deliver separate async frames, in reverse order, including cached translations above.
  for (const index of [...pinned.lastWindow().indices].reverse()) {
    pinned.render(index); pinned.flush();
    pinned.receive('translation', { index, generation: pinned.lastWindow().generations[index], state: 'translated', lines: ['译文一', '译文二'] });
    pinned.flush();
    assert.equal(pinned.root.children[selected].getBoundingClientRect().top, 16);
  }
  if (selected > 0) {
    const previous = pinned.root.children[selected - 1];
    previous.style.height = `${previous.offsetHeight + 400}px`;
    pinned.layout(); // Late WebKit font/ruby layout outside our mutation callback.
    assert.equal(pinned.root.children[selected].getBoundingClientRect().top, 16);
  }
  pinned.window.innerHeight = 1000; pinned.events.resize(); pinned.flush();
  assert.equal(pinned.root.children[selected].getBoundingClientRect().top, 16);
  assert.ok(pinned.messages.filter(message => message.action === 'position').every(message => message.index === selected), 'Loading must not change the reader return target');
}
for (const interaction of ['touchstart', 'wheel', 'keydown', 'native']) {
  const user = fixture(30, 15); user.receive('start'); user.flush();
  if (interaction === 'native') user.receive('userScroll');
  else user.events[interaction]({ key: 'PageDown' });
  user.window.scrollTo(0, user.root.children[17].offsetTop);
  user.scroll(); user.layout();
  assert.equal(user.root.children[17].getBoundingClientRect().top, 0, 'User scroll releases the initial pin');
  assert.equal(user.messages.filter(message => message.action === 'position').at(-1).index, 17);
}
console.log('PASS: pinned entry with clamped scroll range, chapter end, out-of-order hydration/cache restoration, late font layout, viewport resize, and user-scroll release.');
