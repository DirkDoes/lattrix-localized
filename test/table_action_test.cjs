const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const controllers = {};
let request, replacement, location, prevented = 0;
const results = {};
let response = { ok: true, url: "http://localhost/settings/users?status=active&q=Alice", text: async () => "<html>" };
vm.runInNewContext(fs.readFileSync("app/assets/javascripts/app_forms.js", "utf8").replace(/^(?:import .*;|window\.Turbo\.session.*;|register(?:Translations|FormatPreview).*;)\r?\n/gm, ""), {
  Application: { start: () => ({ register: (name, klass) => controllers[name] = klass }) },
  Controller: class {},
  FormData: class { constructor(form) { this.form = form; } },
  DOMParser: class { parseFromString() { return { querySelector: () => results, querySelectorAll: () => [] }; } },
  fetch: async (url, options) => { request = { url, options }; return response; },
  document: { querySelector: () => ({ replaceWith: node => replacement = node }) },
  history: { replaceState: (_state, _title, url) => location = url },
  window: { location: { assign: url => location = url, reload: () => location = "reload" } }
});
(async () => {
  const action = new controllers["table-action"]();
  action.element = { action: "/settings/users/123/ban" };
  await action.submit({ preventDefault: () => prevented++ });
  assert.equal(prevented, 1);
  assert.equal(request.options.method, "POST");
  assert.equal(request.options.body.form, action.element);
  assert.equal(replacement, results);
  assert.equal(location, response.url);
  assert.equal(action.pending, false);
  action.pending = true;
  request = null;
  await action.submit({ preventDefault() {} });
  assert.equal(request, null);
  action.pending = false;
  response = { ok: false, url: "/users/sign_in", text: async () => "" };
  await action.submit({ preventDefault() {} });
  assert.equal(location, "/users/sign_in");
  console.log("Table actions refresh results in place, preserve URL context, and prevent duplicate submissions");
})().catch(error => { console.error(error); process.exitCode = 1; });
