const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('app/assets/javascripts/navigation_state.js', 'utf8');
const storage = new Map();
function page(user = 'one', mobileInitially = false, blocked = false) {
  const listeners = new Map(), media = {matches: mobileInitially, listeners: [],
    addEventListener(_, fn) { this.listeners.push(fn); }, change() { this.listeners.forEach(fn => fn()); }};
  const element = id => ({id, attrs: new Map(), hidden: false,
    hasAttribute(name) { return this.attrs.has(name); },
    getAttribute(name) { return this.attrs.get(name) ?? null; },
    setAttribute(name, value) { this.attrs.set(name, value); },
    toggleAttribute(name, value) { if (value) this.attrs.set(name, ''); else this.attrs.delete(name); }});
  const sidebar = element('app-sidebar'), group = element('projects-navigation'), future = element('future-section');
  sidebar.dataset = {navigationUser: user};
  sidebar.setAttribute('data-se-minimized', 'false');
  sidebar.querySelectorAll = () => [group, future];
  sidebar.addEventListener = (name, fn) => listeners.set('sidebar:' + name, [fn]);
  const backdrop = {hidden: true, addEventListener(name, fn) { listeners.set('backdrop:' + name, [fn]); }};
  const topbar = element('topbar'), workspace = {inert: false};
  let focus = null, changed;
  const trigger = {focus() { focus = 'trigger'; }}, link = {focus() { focus = 'link'; }};
  sidebar.querySelector = () => link;
  sidebar.contains = node => node === link;
  const document = {
    querySelector: selector => selector === '[data-navigation-user]' ? sidebar : selector === '.app-topbar' ? topbar : selector === '.app-navigation-backdrop' ? backdrop : trigger,
    querySelectorAll: () => [], getElementById: () => workspace,
    addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); }
  };
  vm.runInNewContext(source, {
    document, window: {location: {hash: ''}, addEventListener() {}}, matchMedia: () => media,
    localStorage: {
      getItem(key) { if (blocked) throw Error(); return storage.get(key) || null; },
      setItem(key, value) { if (blocked) throw Error(); storage.set(key, value); }
    },
    MutationObserver: class { constructor(fn) { changed = fn; } observe() {} }
  });
  for (const fn of listeners.get('DOMContentLoaded')) fn();
  const dispatch = (name, event = {}) => { for (const fn of listeners.get(name) || []) fn(event); };
  return {sidebar, group, future, workspace, backdrop, topbar, get focus() { return focus; },
    changeGroup(target, collapsed) { target.toggleAttribute('collapsed', collapsed); changed([{target, attributeName: 'collapsed'}]); },
    minimize(value) { sidebar.setAttribute('data-se-minimized', String(value)); changed([{target: sidebar, attributeName: 'data-se-minimized'}]); },
    resize(value) { media.matches = value; media.change(); changed([{target: sidebar, attributeName: 'data-se-minimized'}]); },
    toggle() { let prevented = false; dispatch('beforetoggle', {detail: {target: sidebar, mode: 'collapse'}, preventDefault() { prevented = true; }}); return prevented; },
    escape() { dispatch('keydown', {key: 'Escape', preventDefault() {}}); },
    outside() { dispatch('backdrop:click'); },
    navigate() { dispatch('sidebar:click', {target: {closest: () => ({})}}); },
    frameLoad() { dispatch('turbo:frame-load', {target: {id: 'app-content'}}); }
  };
}
// Migrate the existing icon-rail preference, retaining account-specific group states.
storage.set('navigation:one:v1', JSON.stringify({'app-sidebar': true, 'projects-navigation': true}));
let first = page();
assert.equal(first.sidebar.getAttribute('data-se-minimized'), 'true');
assert.equal(first.sidebar.hidden, false);
assert.equal(first.group.hasAttribute('collapsed'), true);
first.changeGroup(first.future, true);
first.changeGroup(first.group, false);
assert.equal(page().future.hasAttribute('collapsed'), true);
assert.equal(page().group.hasAttribute('collapsed'), false);
assert.equal(page('another-account').sidebar.getAttribute('data-se-minimized'), 'false');
// Mobile hides the whole panel without replacing the saved desktop preference.
first.resize(true);
assert.equal(first.sidebar.hidden, true);
assert.equal(first.topbar.getAttribute('data-se-minimized'), 'true');
assert.equal(first.toggle(), true);
assert.equal(first.sidebar.hidden, false);
assert.equal(first.workspace.inert, true);
assert.equal(first.focus, 'link');
first.escape();
assert.equal(first.sidebar.hidden, true);
assert.equal(first.workspace.inert, false);
assert.equal(first.focus, 'trigger');
for (const dismiss of ['outside', 'navigate', 'frameLoad']) {
  first.toggle(); first[dismiss]();
  assert.equal(first.sidebar.hidden, true);
  assert.equal(first.backdrop.hidden, true);
  assert.equal(first.workspace.inert, false);
}
first.toggle(); first.resize(false);
assert.equal(first.sidebar.hidden, false);
assert.equal(first.workspace.inert, false);
assert.equal(first.backdrop.hidden, true);
assert.equal(first.sidebar.getAttribute('data-se-minimized'), 'true');
first.minimize(false);
assert.equal(page().sidebar.getAttribute('data-se-minimized'), 'false');
assert.equal(page('mobile-account', true).sidebar.hidden, true);
assert.doesNotThrow(() => page('blocked', false, true));
storage.set('navigation:one:v1', 'broken json');
assert.equal(page().sidebar.getAttribute('data-se-minimized'), 'false');
console.log('Navigation migration, persistence, mobile dismissal, focus and breakpoint cleanup passed');

const publicTopbar = {setAttribute(_, value) { this.minimized = value; }};
const publicMedia = {matches: true, addEventListener(_, fn) { this.change = fn; }};
vm.runInNewContext(source, {
  matchMedia: () => publicMedia,
  document: {querySelector: selector => selector === '.app-topbar' ? publicTopbar : null, addEventListener() {}},
  window: {addEventListener() {}}
});
assert.equal(publicTopbar.minimized, 'true');
publicMedia.matches = false; publicMedia.change();
assert.equal(publicTopbar.minimized, 'false');
