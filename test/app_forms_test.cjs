const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const controllers = {};
let timer;
vm.runInNewContext(fs.readFileSync('app/assets/javascripts/app_forms.js', 'utf8').replace(/^(?:import .*;|window\.Turbo\.session.*;|register(?:Translations|FormatPreview).*;)\r?\n/gm, ""), {
  Application: { start: () => ({ register: (name, klass) => { controllers[name] = klass; } }) },
  Controller: class {},
  setTimeout: callback => { timer = callback; return 1; },
  clearTimeout: () => { timer = null; }
});
const slug = new controllers['slug-mirror']();
slug.sourceTarget = { value: 'My Translation Sheet', contains: target => target === 'name' };
slug.destinationTarget = { value: '', getAttribute: () => '', contains: target => target === 'slug' };
slug.separatorValue = "_";
slug.connect();
slug.update({ target: 'name' });
assert.equal(slug.destinationTarget.value, 'my_translation_sheet');
slug.destinationTarget.value = 'custom-slug';
slug.update({ target: 'slug' });
slug.sourceTarget.value = 'Changed Name';
slug.update({ target: 'name' });
assert.equal(slug.destinationTarget.value, 'custom-slug');
slug.edited = false;
slug.separatorValue = "-";
slug.update({ target: 'name' });
assert.equal(slug.destinationTarget.value, 'changed-name');
const search = new controllers['table-search']();
let submissions = 0;
search.element = { requestSubmit: () => submissions++ };
search.schedule({});
search.schedule({});
assert.equal(submissions, 0);
timer();
assert.equal(submissions, 1);
search.schedule({});
search.disconnect();
assert.equal(timer, null);
console.log('Slug mirroring and search debounce checks passed');
