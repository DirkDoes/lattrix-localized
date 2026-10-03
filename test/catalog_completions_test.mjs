import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';
const context = vm.createContext({});
vm.runInContext(readFileSync('app/assets/javascripts/catalog_completions.js', 'utf8').replaceAll('export function', 'function'), context);
const catalog = {paths: ['account.name', 'account.profile.email', 'checkout'], groups: ['devise', 'default'], terms: [{text: 'Lattrix', description: 'Product'}, {text: 'New York'}, {text: 'élève'}]};
const match = (kind, value, source = '', plural = false) => context.completionContext(kind, value, value.length, catalog, source, plural);
test('only root paths display their nonempty file group', () => {
  catalog.rootGroups = {account: 'devise', checkout: ''};
  assert.equal(match('path', 'a').items[0].description, 'devise');
  assert.equal(match('path', 'c').items[0].description, undefined);
  assert.equal(match('path', 'account.').items[0].description, undefined);
  assert.equal(context.insertCompletion(match('path', 'a'), 'account'), 'account');
});
test('paths complete only the current segment under the current parent', () => {
  assert.equal(JSON.stringify(match('path', 'account.').items), '[{"text":"name"},{"text":"profile"}]');
  assert.equal(context.insertCompletion(match('path', 'account.pr'), 'profile'), 'account.profile');
  assert.equal(match('path', 'elsewhere.'), null);
  assert.equal(match('group', 'dev').items[0].text, 'devise');
  assert.equal(match('group', 'def').items[0].text, 'default');
});
test('wildcards replace the entire typed token, including % and braces', () => {
  for (const prefix of ['%', '%{', '%{na']) {
    const result = match('translation', `Hello ${prefix}`, '%{name} %{email}');
    assert.equal(context.insertCompletion(result, '%{name}'), 'Hello %{name}');
  }
  assert.equal(match('translation', '%'), null);
  assert.equal(match('translation', '%', '', true).items[0].text, '%{count}');
  assert.equal(match('translation', '%', '%{count}', true).items.length, 1);
});
test('terms match from the first letter, support multiword and Unicode, and stop on mismatch', () => {
  assert.equal(match('translation', 'Hello L').items[0].description, 'Product');
  assert.equal(context.insertCompletion(match('translation', 'Visit New Y'), 'New York'), 'Visit New York');
  assert.equal(context.insertCompletion(match('translation', 'é'), 'élève'), 'élève');
  assert.equal(match('translation', 'Lax'), null);
  assert.equal(match('translation', 'xL'), null);
});
