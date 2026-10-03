import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../app/assets/javascripts/app_forms.js', import.meta.url), 'utf8');
let Sync, next = {status: 'running', busy: true, message: 'Synchronizing'}, timer, visit, aborted = false;
const badge = {replaceWith(replacement) { this.replacement = replacement; }};
vm.runInNewContext(source.slice(source.indexOf('application.register("catalog-sync"'), source.indexOf('application.register("project-header"')), {
  Controller: class {}, application: {register: (_, type) => Sync = type},
  AbortController: class { abort() { aborted = true; } },
  document: {createElement: () => ({attributes: {}, setAttribute(k, v) { this.attributes[k] = v; }})},
  fetch: async () => { if (next instanceof Error) throw next; return {ok: true, json: async () => next}; },
  window: {location: {href: '/translations'}, Turbo: {visit: (...args) => visit = args}},
  setTimeout: callback => { timer = callback; return 1; }, clearTimeout: () => { timer = null; }
});
const sync = new Sync();
sync.element = {querySelector: () => badge};
sync.messageTarget = {};
sync.urlValue = '/sync_status';
await sync.poll();
assert.equal(sync.messageTarget.textContent, 'Synchronizing');
assert.equal(badge.replacement.attributes.text, 'Syncing');
assert.equal(typeof timer, 'function');
next = new Error('Network offline');
await sync.poll();
assert.match(sync.messageTarget.textContent, /Retrying automatically/);
next = {status: 'succeeded', busy: false, message: 'Already up to date'};
await sync.poll();
assert.equal(visit[0], '/translations');
assert.equal(visit[1].frame, 'app-content');
assert.equal(visit[1].action, 'replace');
sync.disconnect();
assert.equal(aborted, true);
assert.equal(timer, null);
console.log('Catalog synchronization polling checks passed');
