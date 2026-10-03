import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

test('downloads wait for the file, close only on success and always clear loading', async () => {
  const listeners = {}, appended = [];
  let resolve, closed = 0, clicked = 0;
  const attrs = new Map();
  const form = {action: 'http://localhost/export', matches: () => true,
    setAttribute: (k,v) => attrs.set(k,v), removeAttribute: k => attrs.delete(k),
    closest: () => ({querySelectorAll: () => [], close: () => closed++})};
  class DownloadURL extends URL { static createObjectURL() { return 'blob:test'; } static revokeObjectURL() {} }
  const window = {location: {href: 'http://localhost/'}, addEventListener() {}};
  vm.runInNewContext(readFileSync(new URL('../app/assets/javascripts/form_submission.js', import.meta.url), 'utf8'), {
    window, URL: DownloadURL, AbortSignal, FormData: class { *[Symbol.iterator]() { yield ['format_name', 'csv']; } },
    fetch: () => new Promise(r => resolve = r), setTimeout() {},
    document: {addEventListener: (name, fn) => listeners[name] = fn,
      body: {append: el => appended.push(el)},
      createElement: type => ({type, attrs: {}, setAttribute(k,v) { this.attrs[k]=v; }, click() { clicked++; }, remove() {}})}
  });
  const submit = () => listeners.submit({target: form, preventDefault() {}, stopImmediatePropagation() {}});
  submit();
  assert.equal(attrs.get('aria-busy'), 'true');
  assert.equal(closed, 0);
  resolve({ok: true, headers: new Map([['Content-Disposition', 'attachment; filename="catalog.csv"']]), blob: async () => new Blob(['key,en'])});
  await new Promise(setImmediate);
  assert.equal(clicked, 1);
  assert.equal(appended[0].download, 'catalog.csv');
  assert.equal(closed, 1);
  assert.equal(attrs.has('aria-busy'), false);
  submit();
  resolve({ok: false, headers: new Map([['Content-Type', 'application/json']]), json: async () => ({error:'Sync is running'})});
  await new Promise(setImmediate);
  assert.equal(closed, 1);
  assert.equal(attrs.has('aria-busy'), false);
  assert.equal(appended.at(-1).attrs.message, 'Sync is running');
});
