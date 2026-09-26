const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync("app/assets/javascripts/translations.js", "utf8").replaceAll("export function", "function");
const context = {
  document: { createTextNode: text => ({text}), createElement: () => ({}) },
  element: { textContent: "Saved ${count} of $[total]", dataset: {wildcardHighlightFormatValue: "${...}"}, replaceChildren(...children) { this.children = children; } }
};
vm.runInNewContext(source + `
  highlightWildcards(element);
  result = { bracketParts: wildcardParts(element.textContent, "$[...]"), classes: element.children.map(child => child.className).filter(Boolean), disabled: wildcardParts(element.textContent, "") };
`, context);
assert.deepEqual([...context.result.bracketParts], ["Saved ${count} of ", "$[total]"]);
assert.deepEqual([...context.result.classes], ["translation-wildcard"]);
assert.deepEqual([...context.result.disabled], ["Saved ${count} of $[total]"]);
console.log("Translation wildcard parsing passed");
