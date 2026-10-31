import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {test} from 'node:test';

const source = readFileSync('app/assets/javascripts/catalog_loading.js', 'utf8').replaceAll('export ', '');
function cacheWith(fetch) {
  const context = vm.createContext({fetch, Map, JSON, DOMException});
  vm.runInContext(source + '; globalThis.Cache = CatalogReadCache;', context);
  return new context.Cache();
}
test('recent language snapshots are revalidated and reused without reparsing their DOM', async () => {
  let request;
  const cache = cacheWith(async (_url, options) => { request = options; return {status: 304}; });
  const nodes = [{id: '123', target: {existingNode: true}}];
  cache.remember('/nl', {nodes, revision: 4}, 'W/"snapshot"', 100);
  const value = await cache.read('/nl');
  assert.equal(request.headers['If-None-Match'], 'W/"snapshot"');
  assert.equal(value.nodes, nodes);
  assert.equal(value.etag, 'W/"snapshot"');
});
test('changed snapshots replace cached translations and the cache remains bounded', async () => {
  const cache = cacheWith(async () => ({status: 200, ok: true, headers: {get: () => 'new'}, text: async () => '{"locale":"nl","rows":"updated"}'}));
  cache.remember('/nl', {rows: 'old'}, 'old', 100);
  assert.equal((await cache.read('/nl')).rows, 'updated');
  assert.equal(cache.entries.get('/nl').etag, 'new');
  for (let i = 0; i < 6; i++) cache.remember('/' + i, {}, 'etag', 100);
  assert.equal(cache.entries.size, 4);
  assert.equal(cache.entries.has('/0'), false);
  cache.remember('/large', {}, 'etag', 1_999_999);
  assert.equal(cache.entries.size, 1);
  assert.ok(cache.bytes <= 2_000_000);
  cache.clear();
  assert.equal(cache.entries.size, 0);
});
test('aborted and invalidated requests cannot repopulate the cache', async () => {
  let finish;
  const cache = cacheWith(() => new Promise(resolve => { finish = resolve; }));
  const signal = new AbortController();
  const request = cache.read('/nl', signal.signal);
  signal.abort();
  finish({status: 200});
  await assert.rejects(request, {name: 'AbortError'});
  assert.equal(cache.entries.size, 0);
  const pending = cache.read('/fi'); cache.clear();
  finish({status: 200, ok: true, headers: {get: () => 'etag'}, text: async () => '{}'});
  await pending;
  assert.equal(cache.entries.size, 0);
});

test('prefetch holds a single next batch until the reader approaches the end and aborts on language changes', async () => {
  let More, resolveRead, reads = 0, appended = [], observers = [], renderCount = 0;
  const table = {dataset: {revision: '1'}, hasAttribute: () => false,
    querySelectorAll: () => [], append: row => appended.push(row)};
  const listeners = new Map(), sentinel = {};
  Object.defineProperty(sentinel, 'outerHTML', {set() { renderCount++; }});
  const context = vm.createContext({Map, WeakMap, Set, URL, AbortController, DOMException, JSON,
    performance: {now: () => 1, measure() {}},
    fetch: (_url, {signal}) => { reads++; return new Promise(resolve => { resolveRead = () => resolve({status: 200, ok: true, headers: {get: () => 'same'}, text: async () => '{"rows":"rows","revision":1,"more":"next"}'}); signal.addEventListener('abort', () => resolve({status: 200})); }); },
    IntersectionObserver: class { constructor(callback, options) { this.callback = callback; this.options = options; observers.push(this); } observe() {} disconnect() {} },
    DOMParser: class { parseFromString() { return {querySelectorAll: () => [{dataset: {catalogKey: '2'}}]}; } },
    window: {location: {href: 'http://localhost/translations'}},
    document: {getElementById: id => id === 'catalog-rows' ? table : sentinel,
      addEventListener: (name, listener) => listeners.set(name, listener), removeEventListener() {}}
  });
  vm.runInContext(source + '; globalThis.register = registerCatalogLoading;', context);
  context.register({register: (_name, type) => { More = type; }}, class {});
  const more = new More();
  more.element = {isConnected: true, closest: () => ({clientHeight: 600})};
  more.urlValue = '/translations?page=2'; more.statusTarget = {}; more.retryTarget = {};
  more.connect();
  assert.equal(observers[0].options.rootMargin, '1200px 0px');
  observers[0].callback([{isIntersecting: true}]);
  observers[0].callback([{isIntersecting: true}]);
  assert.equal(reads, 1);
  resolveRead(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(appended.length, 0);
  assert.equal(more.buffer.revision, 1);
  observers[1].callback([{isIntersecting: true}]);
  assert.equal(appended.length, 1);
  assert.equal(renderCount, 1);
  more.buffer = null; more.nearEnd = false;
  more.load(); listeners.get('catalog:language-start')();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(more.stopped, true);
  assert.equal(more.buffer, null);
  more.disconnect();
});

test('a late cancelled language response cannot replace or unlock the latest selection', async () => {
  const listeners = new Map(), pending = [], visits = [], attributes = new Set();
  const target = {outerHTML: '<div>Original translation</div>'};
  const row = {dataset: {catalogKey: '123'}, querySelector: () => target};
  const status = {hidden: true, querySelector: () => ({set textContent(value) { status.text = value; }})};
  const table = {isConnected: true, dataset: {revision: '1', catalogEtag: 'etag'},
    querySelectorAll: selector => selector === '[data-catalog-key]' ? [row] : [target], querySelector: () => status,
    hasAttribute: name => attributes.has(name), setAttribute: name => attributes.add(name), removeAttribute: name => attributes.delete(name)};
  const form = {elements: {locale: {value: 'nl'}}};
  const select = {value: 'fi', matches: () => true, options: [{id: 'fi', label: 'Finnish'}, {id: 'fr', label: 'French'}]};
  const context = vm.createContext({Map, WeakMap, Set, URL, AbortController, DOMException, JSON,
    performance: {now: () => 1, measure() {}},
    Event: class {}, CustomEvent: class {},
    fetch: (_url, options) => new Promise(resolve => pending.push({resolve, signal: options.signal})),
    window: {location: {href: 'http://localhost/translations?locale=nl'}, Turbo: {visit: url => visits.push(url)}},
    document: {getElementById: id => id === 'catalog-rows' ? table : id === 'catalog-filters' ? form : {},
      dispatchEvent: () => true, addEventListener: (name, listener) => listeners.set(name, listener),
      createElement() { throw new Error('Cancelled requests must not show an error toast'); }}
  });
  vm.runInContext(source + '; globalThis.register = registerCatalogLoading;', context);
  context.register({register() {}}, class {});
  const first = listeners.get('change')({target: select, detail: {value: 'fi'}});
  select.value = 'fr';
  const second = listeners.get('change')({target: select, detail: {value: 'fr'}});
  assert.equal(pending[0].signal.aborted, true);
  pending[0].resolve({status: 500});
  await first;
  assert.equal(attributes.has('aria-busy'), true);
  assert.equal(target.inert, true);
  assert.equal(row.inert, undefined, 'The component owns collapsed-row inert state');
  assert.equal(status.text, 'Loading French…');
  pending[1].resolve({status: 200, ok: true, headers: {get: () => 'etag2'}, text: async () => '{"locale":"fr","revision":2,"rows":"changed"}'});
  await second;
  assert.equal(visits.length, 1);
  assert.equal(new URL(visits[0]).searchParams.get('locale'), 'fr');
  assert.equal(attributes.has('aria-busy'), false);
  assert.equal(target.inert, false);
  assert.equal(status.hidden, true);
  assert.equal(select.value, 'fr');
});

test('a failed interrupted render can restore committed cells and remove partial rows', () => {
  const committed = {value: 'Dutch'}, current = {value: 'Finnish', replaceWith(node) { row.target = node; }};
  const header = {}, row = {dataset: {catalogKey: '1'}, target: current, previousElementSibling: header, querySelector() { return this.target; }};
  const extra = {dataset: {catalogKey: '2'}, remove() { this.removed = true; }};
  const oldMore = {}, newMore = {replaceWith(node) { this.replacement = node; }};
  const table = {querySelectorAll: () => [row, extra], querySelector: () => header};
  const context = vm.createContext({Map, Set});
  vm.runInContext(source + '; globalThis.restore = restoreCatalogView;', context);
  context.restore(table, {nodes: [{id: '1', row, target: committed}], moreNode: oldMore}, newMore);
  assert.equal(row.target, committed);
  assert.equal(extra.removed, true);
  assert.equal(newMore.replacement, oldMore);
});

test('lazy editors use the initial-open API and cancelling prevents a late dialog from opening', async () => {
  const listeners = new Map(), requests = [], appended = [];
  const modal = {id: 'catalog-key-1', attributes: {}, setAttribute(name, value) { this.attributes[name] = value; }};
  const loading = {id: 'catalog-editor-loading', isConnected: true, open() {}, close() { this.closed = true; listeners.get('close')({target: this}); }};
  const context = vm.createContext({Map, WeakMap, URL, Set, AbortController, DOMException, JSON,
    performance: {now: () => 1, measure() {}},
    fetch: (_url, options) => new Promise(resolve => requests.push({resolve, signal: options.signal})),
    DOMParser: class { parseFromString() { return {querySelectorAll: () => [modal]}; } },
    document: {addEventListener: (name, listener) => listeners.set(name, listener),
      getElementById: id => id === loading.id ? loading : id === 'catalog-modals' ? {append(node) { assert.equal(node.attributes.open, ''); appended.push(node); }} : null}
  });
  vm.runInContext(source + '; globalThis.register = registerCatalogLoading;', context);
  context.register({register() {}}, class {});
  const click = () => listeners.get('click')({preventDefault() {}, target: {closest: () => ({dataset: {openModal: modal.id, catalogEditor: '/editor'}})}});
  const response = {ok: true, text: async () => 'editor'};
  click(); listeners.get('close')({target: loading}); requests[0].resolve(response);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[0].signal.aborted, true);
  assert.equal(appended.length, 0);
  click(); requests[1].resolve(response);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(appended.length, 1);
  assert.equal(loading.closed, true);
});
