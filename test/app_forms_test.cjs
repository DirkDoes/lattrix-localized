const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const controllers = {};
let timer;
vm.runInNewContext(fs.readFileSync('app/assets/javascripts/app_forms.js', 'utf8').replace(/^import .*;\r?\n/, ''), {
  Application: { start: () => ({ register: (name, klass) => { controllers[name] = klass; } }) },
  Controller: class {},
  setTimeout: callback => { timer = callback; return 1; },
  clearTimeout: () => { timer = null; }
});
const slug = new controllers['project-slug']();
slug.nameTarget = { value: 'My Translation Project', contains: target => target === 'name' };
slug.slugTarget = { value: '', getAttribute: () => '', contains: target => target === 'slug' };
slug.connect();
slug.update({ target: 'name' });
assert.equal(slug.slugTarget.value, 'my_translation_project');
slug.slugTarget.value = 'custom_slug';
slug.update({ target: 'slug' });
slug.nameTarget.value = 'Changed Name';
slug.update({ target: 'name' });
assert.equal(slug.slugTarget.value, 'custom_slug');
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
