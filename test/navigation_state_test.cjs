const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('app/assets/javascripts/navigation_state.js', 'utf8');
const storage = new Map();
function page(user = 'one', extraId = 'future-section', blocked = false) {
  const elements = ['app-sidebar', 'projects-navigation', 'administration-navigation', extraId].map(id => ({
    id, collapsed: id === 'administration-navigation',
    hasAttribute() { return this.collapsed; },
    toggleAttribute(name, value) { this.collapsed = value; }
  }));
  const sidebar = elements[0];
  sidebar.dataset = { navigationUser: user };
  sidebar.querySelectorAll = () => elements.slice(1);
  let ready, changed, toggled;
  sidebar.addEventListener = (name, callback) => { toggled = callback; };
  vm.runInNewContext(source, {
    document: { querySelector: () => sidebar, addEventListener: (name, callback) => { ready = callback; } },
    localStorage: {
      getItem(key) { if (blocked) throw Error(); return storage.get(key) || null; },
      setItem(key, value) { if (blocked) throw Error(); storage.set(key, value); }
    },
    MutationObserver: class { constructor(callback) { changed = callback; } observe() {} }
  });
  ready();
  return { elements, change(index, value) {
    elements[index].collapsed = value;
    changed([{ target: elements[index] }]);
  }, toggle(value) { sidebar.collapsed = value; toggled({ target: sidebar }); } };
}
let first = page();
assert.equal(first.elements[2].collapsed, true); // Markup default, no saved preference.
first.change(1, true);
first.change(2, false);
first.change(3, true); // New section uses the same mechanism.
first.toggle(true);
let next = page();
assert.deepEqual(next.elements.map(e => e.collapsed), [true, true, false, true]);
next.change(0, false); // Mobile layout adjustment must not overwrite desktop preference.
assert.equal(page().elements[0].collapsed, true);
assert.deepEqual(page('another-account').elements.map(e => e.collapsed), [false, false, true, false]);
page('one', 'sheet-section').change(3, true);
assert.equal(page().elements[3].collapsed, true); // Leaving a scope retains its preferences.
assert.doesNotThrow(() => page('one', 'other', true));
storage.set('navigation:one:v1', 'broken json');
assert.equal(page().elements[2].collapsed, true);
console.log('Sidebar defaults, navigation, scope changes, account isolation and storage fallback passed');
