const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync("app/assets/javascripts/format_preview.js", "utf8").replaceAll("export function", "function");
const context = {};
vm.runInNewContext(`${source}\nresult = { yaml: highlightFormatPreview("name: \\\"Lattrix\\\"\\nenabled: true", "yaml"), csv: highlightFormatPreview("key,en\\ncount,2", "csv") };`, context);
assert.match(context.result.yaml, /se-token--property/);
assert.match(context.result.yaml, /se-token--string/);
assert.match(context.result.yaml, /se-token--keyword/);
assert.match(context.result.csv, /se-token--property/);
assert.equal(context.result.csv.match(/se-token--property/g).length, 1);
assert.match(context.result.csv, /se-token--operator/);
assert.match(context.result.csv, /se-token--number/);
console.log("YAML and CSV preview highlighting passed");
