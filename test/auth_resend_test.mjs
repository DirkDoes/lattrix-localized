import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

test('resend countdown redraws, unlocks at the deadline, and prevents double submission', () => {
  const controllers = new Map();
  let now = 1000, tick;
  const form = {querySelector: () => form.button};
  const button = (attrs = new Map()) => ({
    getAttribute: name => attrs.get(name), hasAttribute: name => attrs.has(name),
    setAttribute: (name, value) => attrs.set(name, value), removeAttribute: name => attrs.delete(name),
    toggleAttribute: (name, enabled) => enabled ? attrs.set(name, '') : attrs.delete(name),
    cloneNode: () => button(new Map(attrs)), replaceWith: next => { form.button = next; }
  });
  form.button = button(new Map([['text', 'Resend code'], ['data-ready', 'true']]));
  vm.runInNewContext(readFileSync(new URL('../app/assets/javascripts/auth_forms.js', import.meta.url), 'utf8').replace(/^import .*;\r?\n/, ''), {
    Application: {start: () => ({register: (name, controller) => controllers.set(name, controller)})},
    Controller: class {}, Date: {now: () => now * 1000},
    setInterval: callback => { tick = callback; return 1; }, clearInterval: () => {}
  });
  const controller = new (controllers.get('email-code-resend'))();
  controller.element = form;
  controller.readyAtValue = 1030;
  controller.connect();
  assert.equal(form.button.getAttribute('text'), 'Resend in 0:30');
  assert.equal(form.button.hasAttribute('data-ready'), false);
  now = 1005; tick();
  assert.equal(form.button.getAttribute('text'), 'Resend in 0:25');
  assert.equal(form.button.hasAttribute('disabled'), true);
  let prevented = 0;
  controller.submit({preventDefault: () => prevented++});
  assert.equal(prevented, 1);
  now = 1030; tick();
  assert.equal(form.button.getAttribute('text'), 'Resend code');
  assert.equal(form.button.hasAttribute('disabled'), false);
  controller.submit({preventDefault: () => prevented++});
  assert.equal(form.button.getAttribute('text'), 'Sending…');
  controller.submit({preventDefault: () => prevented++});
  assert.equal(prevented, 2);
  controller.disconnect();
});
