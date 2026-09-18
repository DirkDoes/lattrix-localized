const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const handlers = {};
const document = {
  documentElement: { dataset: {} },
  addEventListener: (name, handler) => { (handlers[name] ||= []).push(handler); }
};
const revoked = [];
vm.runInNewContext(fs.readFileSync('app/assets/javascripts/ui.js', 'utf8'), {
  document,
  matchMedia: () => ({ matches: false, addEventListener() {} }),
  customElements: { whenDefined: () => new Promise(() => {}) },
  URL: { createObjectURL: () => 'blob:preview', revokeObjectURL: url => revoked.push(url) },
  DataTransfer: class {
    files = [];
    items = { add: file => this.files.push(file) };
  }
});
const image = { dataset: {}, removeAttribute() { delete this.src; } };
const preview = { hidden: true, querySelector: () => image };
const message = {};
const input = {};
const form = { querySelector: selector => selector === '[data-photo-preview]' ? preview : message };
const upload = { matches: () => true, closest: () => form, querySelector: () => input };
const choose = files => handlers.files[0]({ target: upload, detail: { files } });

choose([{ name: 'photo.png', size: 100 }]);
assert.equal(input.files.length, 1);
assert.equal(image.src, 'blob:preview');
image.onload();
assert.equal(upload.hidden, true);
assert.equal(preview.hidden, false);
choose([{ name: 'large.png', size: 6 * 1024 * 1024 }]);
assert.equal(input.files.length, 0);
assert.equal(preview.hidden, true);
assert.equal(upload.hidden, false);
assert.match(message.textContent, /5 MB/);
assert.equal(revoked.length, 1);
choose([{ name: 'photo.heic', size: 100 }]);
image.onerror();
assert.match(message.textContent, /cannot preview/);
assert.equal(upload.hidden, false);
choose([]);
assert.equal(input.files.length, 0);
assert.equal(message.textContent, '');
console.log('Photo preview checks passed');
