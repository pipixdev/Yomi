/* One native scrolling WebView; a bounded window owns tokens, controls and translations. */
(() => {
  'use strict';
  const { paragraphs, initialIndex, labels } = window.analysisConfiguration;
  const root = document.getElementById('paragraphs');
  const post = (action, value = {}) => window.webkit.messageHandlers.analysis.postMessage({ action, ...value });
  const live = new Map();
  const sections = [];
  let current = initialIndex, frame = 0, started = false, pending = [], mutationFrame = 0, nextGeneration = 0;
  // Keep the requested paragraph stable through asynchronous token/cache/font layout.
  // Only real user interaction releases this pin; programmatic scroll events do not.
  let initialPositionPinned = true;
  const topInset = 16;
  const icons = {
    bookmark: '<path d="M6 3h12v18l-6-4-6 4z"/>',
    translate: '<path d="M3 5h12M9 3v2M6 5c0 6 6 10 9 10M13 5c0 6-5 10-10 12M14 21l4-10 4 10M16 17h4"/>',
    speech: '<path d="M4 9h4l5-5v16l-5-5H4zM17 8c2 2 2 6 0 8M20 5c4 4 4 10 0 14"/>',
    stop: '<rect x="5" y="5" width="14" height="14" rx="2" fill="currentColor" stroke="none"/>'
  };
  function placeholder(index) {
    const node = document.createElement('div');
    node.className = 'placeholder';
    node.textContent = paragraphs[index];
    node.lang = 'ja';
    return node;
  }
  const fragment = document.createDocumentFragment();
  paragraphs.forEach((_, index) => {
    const section = document.createElement('section');
    section.className = 'paragraph';
    section.dataset.index = index;
    section.dataset.live = 'false';
    // Offscreen rows are lightweight measured/estimated spacers, never full token trees.
    const columns = Math.max(8, Math.floor((window.innerWidth - 40) / 23));
    section.style.height = `${Math.max(110, Math.ceil(paragraphs[index].length / columns) * 48 + 72)}px`;
    sections.push(section);
    fragment.append(section);
  });
  root.append(fragment);

  // Ordered block offsets permit O(log n) lookup; no chapter-wide scan on scroll ticks.
  function indexAt(y) {
    let lo = 0, hi = sections.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (sections[mid].offsetTop + sections[mid].offsetHeight <= y) lo = mid + 1;
      else hi = mid;
    }
    return Math.min(lo, sections.length - 1);
  }
  function anchorMutation(change) {
    if (started && initialPositionPinned) {
      change();
      restoreInitialPosition();
      return;
    }
    const index = indexAt(window.scrollY + 1);
    const section = sections[index];
    const before = section.getBoundingClientRect().top;
    change();
    const delta = section.getBoundingClientRect().top - before;
    if (Math.abs(delta) > 0.5) window.scrollBy(0, delta);
  }
  function restoreInitialPosition() {
    if (!started || !initialPositionPinned) return;
    const target = Math.max(0, sections[initialIndex].offsetTop - topInset);
    if (Math.abs(window.scrollY - target) > 0.5) window.scrollTo(0, target);
  }
  function releaseInitialPosition() { initialPositionPinned = false; }
  function button(action, label) {
    const node = document.createElement('button');
    node.type = 'button'; node.className = 'action'; node.dataset.action = action;
    node.setAttribute('aria-label', label); node.setAttribute('aria-pressed', 'false');
    node.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[action]}</svg>`;
    return node;
  }
  function activate(index) {
    const section = sections[index];
    const content = placeholder(index);
    const actions = document.createElement('div'); actions.className = 'actions';
    const buttons = { bookmark: button('bookmark', labels.bookmark), translate: button('translate', labels.translate), speech: button('speech', labels.play) };
    Object.values(buttons).forEach(node => { node.disabled = true; actions.append(node); });
    const translation = document.createElement('div'); translation.className = 'translation'; translation.hidden = true;
    translation.setAttribute('aria-live', 'polite');
    translation.id = `translation-${index}`;
    buttons.translate.setAttribute('aria-controls', translation.id);
    buttons.translate.setAttribute('aria-expanded', 'false');
    section.replaceChildren(content, actions, translation);
    section.dataset.live = 'true';
    section.setAttribute('aria-busy', 'true');
    // Keep the old measured height until tokens arrive, avoiding collapse during fast reversal.
    live.set(index, { content, buttons, translation, tokens: [], starts: [], ends: [], highlighted: [], generation: String(++nextGeneration) });
  }
  function deactivate(index) {
    const section = sections[index];
    section.style.height = `${section.offsetHeight}px`;
    section.replaceChildren();
    section.dataset.live = 'false';
    section.setAttribute('aria-busy', 'false');
    live.delete(index);
  }
  function updateWindow() {
    frame = 0;
    if (!started) return;
    restoreInitialPosition();
    const first = initialPositionPinned ? initialIndex : indexAt(window.scrollY + 1);
    const last = indexAt(window.scrollY + window.innerHeight);
    // Minimum section height bounds the visible count. Cap also guards pathological viewport sizes.
    const low = Math.max(0, first - 6), high = Math.min(sections.length - 1, Math.max(first + 6, last + 6), low + 32);
    const desired = [];
    for (let index = low; index <= high; index++) desired.push(index);
    const wanted = new Set(desired);
    const changed = desired.some(index => !live.has(index)) || [...live.keys()].some(index => !wanted.has(index));
    if (changed) {
      anchorMutation(() => {
        for (const index of live.keys()) if (!wanted.has(index)) deactivate(index);
        for (const index of desired) if (!live.has(index)) activate(index);
      });
      // Visible work first; nearby rows follow on the serial tokenizer actor.
      desired.sort((a, b) => Math.abs(a - first) - Math.abs(b - first));
      post('window', { indices: desired, generations: Object.fromEntries(desired.map(index => [index, live.get(index).generation])) });
    }
    if (current !== first) { current = first; post('position', { index: first }); }
  }
  function scheduleWindow() {
    if (!frame) frame = requestAnimationFrame(updateWindow);
  }
  function setPressed(node, active, label) {
    node.setAttribute('aria-pressed', String(active)); node.setAttribute('aria-label', label);
  }
  function highlight(row, start, length) {
    const lower = Number(start) || 0, upper = lower + (Number(length) || 0);
    let lo = 0, hi = row.tokens.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (row.ends[mid] <= lower) lo = mid + 1; else hi = mid;
    }
    const next = [];
    if (upper > lower) for (let i = lo; i < row.tokens.length && row.starts[i] < upper; i++) next.push(i);
    const nextSet = new Set(next), previousSet = new Set(row.highlighted);
    row.highlighted.forEach(i => { if (!nextSet.has(i)) row.tokens[i].classList.remove('is-speaking'); });
    next.forEach(i => { if (!previousSet.has(i)) row.tokens[i].classList.add('is-speaking'); });
    row.highlighted = next;
  }
  function apply(action, value) {
    const row = live.get(value.index);
    if (!row) return;
    if (action === 'render') {
      if (row.generation !== value.generation) return;
      row.content.className = 'tokens'; row.content.innerHTML = value.html;
      sections[value.index].style.height = '';
      sections[value.index].setAttribute('aria-busy', 'false');
      row.tokens = Array.from(row.content.querySelectorAll('.token'));
      row.starts = row.tokens.map(token => Number(token.dataset.start));
      row.ends = row.tokens.map(token => Number(token.dataset.end));
      row.highlighted = [];
      Object.values(row.buttons).forEach(node => { node.disabled = false; });
    } else if (action === 'bookmark') {
      row.buttons.bookmark.disabled = !value.available;
      setPressed(row.buttons.bookmark, value.active, value.active ? labels.unbookmark : labels.bookmark);
    } else if (action === 'speech') {
      setPressed(row.buttons.speech, value.active, value.active ? labels.stop : labels.play);
      row.buttons.speech.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[value.active ? 'stop' : 'speech']}</svg>`;
      if (!value.active) highlight(row, 0, 0);
    } else if (action === 'translation' && row.generation === value.generation) {
      const visible = value.state !== 'hidden';
      setPressed(row.buttons.translate, visible, visible ? labels.hideTranslation : labels.translate);
      row.buttons.translate.setAttribute('aria-expanded', String(visible));
      row.translation.hidden = !visible; row.translation.replaceChildren();
      row.translation.setAttribute('aria-busy', String(value.state === 'loading'));
      if (visible) {
        const title = document.createElement('div'); title.className = 'translation-label';
        title.textContent = labels[value.state === 'loading' ? 'loading' : value.state === 'failed' ? 'failed' : 'translation'];
        row.translation.append(title);
        if (value.state === 'translated') value.lines.forEach(line => {
          const node = document.createElement('p'); node.textContent = line; row.translation.append(node);
        });
        if (value.state === 'failed') {
          const retry = document.createElement('button'); retry.type = 'button'; retry.className = 'retry';
          retry.dataset.action = 'retry'; retry.textContent = labels.retry; row.translation.append(retry);
        }
      }
    }
  }
  // Coalesce async completions into one layout/anchor adjustment per frame.
  window.analysisReceive = (action, value) => {
    if (action === 'start') {
      if (started) return;
      started = true;
      restoreInitialPosition();
      updateWindow();
      return;
    }
    if (action === 'scale') {
      anchorMutation(() => { document.documentElement.style.setProperty('--scale', value.value); });
      scheduleWindow(); return;
    }
    if (action === 'userScroll') { releaseInitialPosition(); return; }
    if (action === 'highlight') {
      const row = live.get(value.index); if (row) highlight(row, value.start, value.length);
      return;
    }
    pending.push([action, value]);
    if (!mutationFrame) mutationFrame = requestAnimationFrame(() => {
      mutationFrame = 0;
      const changes = pending; pending = [];
      anchorMutation(() => changes.forEach(([action, value]) => apply(action, value)));
      scheduleWindow();
    });
  };
  root.addEventListener('click', event => {
    const control = event.target.closest('button');
    if (!control || control.disabled) return;
    const section = control.closest('.paragraph');
    if (!section) return;
    const index = Number(section.dataset.index);
    if (control.dataset.action) post(control.dataset.action, { index });
    else if (control.dataset.index !== undefined) post('token', { index, token: Number(control.dataset.index) });
  });
  window.addEventListener('scroll', scheduleWindow, { passive: true });
  window.addEventListener('resize', scheduleWindow, { passive: true });
  window.addEventListener('touchstart', releaseInitialPosition, { passive: true });
  window.addEventListener('wheel', releaseInitialPosition, { passive: true });
  window.addEventListener('keydown', event => {
    if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)) releaseInitialPosition();
  });
  // WebKit can finish ruby/font layout after the mutation frame or a navigation resize.
  // Observe the document once, coalesce corrections, and never poll after it settles.
  new ResizeObserver(() => { if (initialPositionPinned) scheduleWindow(); }).observe(root);
  document.fonts?.ready.then(() => { if (initialPositionPinned) scheduleWindow(); });
})();
