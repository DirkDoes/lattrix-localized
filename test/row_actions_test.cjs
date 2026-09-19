const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const handlers = [];
let destination, submitted = 0;
vm.runInNewContext(fs.readFileSync("app/assets/javascripts/ui.js", "utf8"), {
  document: { documentElement: { dataset: {} }, addEventListener: (name, fn) => { if (name === "select") handlers.push(fn); } },
  matchMedia: () => ({ addEventListener() {} }),
  customElements: { whenDefined: () => new Promise(() => {}) },
  window: { location: { assign: url => destination = url } }
});
const target = {
  matches: selector => selector === "se-menu[data-row-actions]",
  dataset: { editUrl: "/settings/users/example/edit" },
  parentElement: { querySelector: selector => { assert.equal(selector, "form[data-row-action-form]"); return { requestSubmit: () => submitted++ }; } }
};
for (const fn of handlers) fn({ target, detail: { id: "edit" } });
assert.equal(destination, target.dataset.editUrl);
assert.equal(submitted, 0);
for (const fn of handlers) fn({ target, detail: { id: "action" } });
assert.equal(submitted, 1);
console.log("Row menu navigation and form submission passed");
