import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

test('shared submissions disable once, restore on failure, and close only redirected successes', () => {
  const listeners = {}, window = {addEventListener: (name, fn) => { listeners[name] = fn; }};
  const form = {
    attrs: new Map(), closed: 0, isConnected: true,
    closest: () => ({querySelectorAll: () => [form.button], close: () => form.closed++}),
    setAttribute: (k, v) => form.attrs.set(k, v), removeAttribute: k => form.attrs.delete(k)
  };
  const button = (attrs = new Map([['text', 'Create project'], ['data-ready', 'true']])) => ({
    matches: s => s === 'se-button', closest() { return this; },
    getAttribute: k => attrs.get(k), hasAttribute: k => attrs.has(k),
    setAttribute: (k, v) => attrs.set(k, v), removeAttribute: k => attrs.delete(k),
    cloneNode: () => button(new Map(attrs)), replaceWith: next => { form.button = next; }
  });
  form.button = button();
  const original = form.button;
  const microtasks = [];
  vm.runInNewContext(readFileSync(new URL('../app/assets/javascripts/form_submission.js', import.meta.url), 'utf8'), {
    window, document: {addEventListener: (name, fn) => { listeners[name] = fn; }},
    queueMicrotask: fn => fn(), setTimeout: fn => microtasks.push(fn)
  });
  listeners['turbo:submit-start']({target: form});
  assert.equal(form.button.getAttribute('text'), 'Loading…');
  assert.equal(form.button.hasAttribute('disabled'), true);
  assert.equal(form.button.hasAttribute('data-ready'), false);
  assert.equal(window.AppFormSubmission.start(form), false);
  let prevented = false;
  listeners.submit({target: form, preventDefault: () => { prevented = true; }, stopImmediatePropagation() {}});
  assert.equal(prevented, true);
  listeners['turbo:submit-end']({target: form, detail: {success: false}});
  assert.equal(form.button, original);
  assert.equal(form.attrs.has('aria-busy'), false);
  assert.equal(form.closed, 0);
  window.AppFormSubmission.start(form);
  listeners['turbo:submit-end']({target: form, detail: {success: true, fetchResponse: {redirected: true}}});
  assert.equal(form.closed, 1);
  window.AppFormSubmission.start(form);
  listeners['turbo:submit-end']({target: form, detail: {success: true, fetchResponse: {redirected: false}}});
  assert.equal(form.closed, 1, 'Intermediate confirmation responses must stay open');
  const customEvent = {target: form, defaultPrevented: false};
  listeners.submit(customEvent);
  assert.equal(form.button, original, 'Capture must not mark a custom form busy before its bubble handler');
  customEvent.defaultPrevented = true;
  assert.equal(window.AppFormSubmission.start(form), true, 'Custom handler must own the first submission');
  microtasks.shift()();
  window.AppFormSubmission.finish(form);
  listeners.submit({target: form, defaultPrevented: false});
  microtasks.shift()();
  assert.equal(form.button.hasAttribute('disabled'), true);
  listeners.pageshow();
  assert.equal(form.button, original, 'Back navigation restores native form buttons');
});
