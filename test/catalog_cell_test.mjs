import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';

test('inline editor queues saves, preserves failures, and handles keyboard controls', async () => {
  let Cell;
  const cells = [], requests = [];
  let fail = false;
  const document = {
    getElementById: () => null,
    dispatchEvent() {},
    querySelector: () => ({content: 'csrf'}),
    querySelectorAll: selector => selector.includes('revision-value') ? cells.map(c => c.element) : [],
    createElement: () => ({setAttribute() {}}), body: {append() {}}
  };
  const context = vm.createContext({document, CustomEvent: class {}, fetch: async (_url, request) => {
    const body = JSON.parse(request.body); requests.push(body);
    return {ok: !fail, json: async () => fail ? {error: 'Conflict'} : {value: body.value, html: body.value, revision: body.revision + 1}};
  }});
  vm.runInContext(readFileSync('app/assets/javascripts/catalog_cell.js', 'utf8').replace('export function', 'function'), context);
  context.registerCatalogCell({register: (_name, klass) => { Cell = klass; }}, class {});
  function cell(value) {
    const c = new Cell();
    const input = {setAttribute(name, value) { this[name] = value; }, removeAttribute(name) { delete this[name]; }};
    c.element = {dataset: {catalogCellRevisionValue: 1}, contains: () => false};
    Object.defineProperty(c, 'revisionValue', {get: () => Number(c.element.dataset.catalogCellRevisionValue)});
    c.inputTarget = {value, getAttribute: () => value, querySelector: () => input};
    c.displayTarget = {}; c.editorTarget = {}; c.statusTarget = {};
    c.connect(); cells.push(c); return c;
  }
  const a = cell('old'), b = cell('');
  const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
  a.inputTarget.value = 'new'; b.inputTarget.value = 'second';
  a.save(); b.save(); await flush();
  assert.deepEqual(requests.map(r => r.revision), [1, 2]);
  assert.equal(a.editorTarget.hidden, true);
  assert.match(a.statusTarget.innerHTML, /Saved/);
  a.inputTarget.value = 'line\nline';
  a.keydown({key: 'Enter', defaultPrevented: true});
  assert.equal(requests.length, 2);
  a.keydown({key: 'Enter', shiftKey: true});
  assert.equal(requests.length, 2);
  a.keydown({key: 'Escape', preventDefault() {}});
  assert.equal(a.inputTarget.value, 'new');
  fail = true; a.inputTarget.value = 'keep my text';
  a.keydown({key: 'Enter', preventDefault() {}}); await flush();
  assert.equal(a.inputTarget.value, 'keep my text');
  assert.equal(a.editorTarget.hidden, false);
  assert.equal(a.inputTarget.querySelector().readOnly, false);
  assert.equal(a.inputTarget.querySelector()['aria-invalid'], 'true');
  fail = false; a.inputTarget.value = ''; a.save(); await flush();
  assert.equal(a.editorTarget.hidden, false);
  assert.equal(a.displayTarget.hidden, true);
});
