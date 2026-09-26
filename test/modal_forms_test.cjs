const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const handlers = {};
const document = {
  addEventListener(name, handler, capture) { (handlers[name] ||= []).push({handler, capture}); },
  querySelectorAll() { return []; },
  documentElement: {dataset: {}}
};
vm.runInNewContext(fs.readFileSync("app/assets/javascripts/ui.js", "utf8"), {
  document, customElements: {whenDefined: () => new Promise(() => {})}, URL,
  SimpleElements: {setBrandTheme() {}}
});

let submitted = 0, reset = 0, prevented = 0;
const form = {requestSubmit: () => submitted++, reset: () => reset++};
const modal = {querySelector: () => form, matches: () => false};
handlers.confirm[0].handler({target: modal, preventDefault: () => prevented++});
assert.equal(submitted, 1);
assert.equal(prevented, 1);

handlers.close[0].handler({target: {matches: () => true, querySelector: () => form}});
assert.equal(reset, 1);
console.log("Form modals wait for submission and reset when closed");
