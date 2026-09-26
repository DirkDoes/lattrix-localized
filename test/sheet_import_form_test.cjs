const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync("app/assets/javascripts/app_forms.js", "utf8").replace(/^import .*;$/gm, "");
const controllers = {};
const cards = [];
const context = {
  Application: { start: () => ({ register: (name, controller) => controllers[name] = controller }) },
  Controller: class {},
  registerTranslations() {}, registerFormatPreview() {},
  window: { Turbo: { session: {} } },
  document: { createElement: () => { const card = {attributes: {}, setAttribute(name, value) { this.attributes[name] = value; }, addEventListener() {}}; cards.push(card); return card; } }
};
vm.runInNewContext(source, context);

const form = Object.create(controllers["sheet-import"].prototype);
form.selected = [{ name: "translations.csv" }];
form.valid = true;
form.nameTarget = { value: "", hasAttribute: () => false };
form.renderName = error => form.nameError = error;
let prevented = false;
form.submit({ preventDefault: () => prevented = true });

assert.equal(prevented, true);
assert.equal(form.nameError, "Sheet name can't be blank");
assert.equal(form.selected.length, 1);
form.filesTarget = { replaceChildren: () => form.filesCleared = true };
form.autoTargets = [{ hidden: false }];
form.reset();
assert.equal(form.selected.length, 0);
assert.equal(form.autoTargets[0].hidden, true);
form.filesTarget = { replaceChildren() {} };
form.render([{filename: "bad.csv", subtext: "CSV", tone: "gray", error: "Invalid columns"}]);
assert.equal(cards[0].attributes.title, "bad.csv");
assert.equal(cards[0].attributes.subtitle, "CSV");
assert.equal(cards[0].attributes.error, "Invalid columns");
assert.equal(cards[0].attributes.tone, undefined);
console.log("Invalid sheet names preserve selected import files");
