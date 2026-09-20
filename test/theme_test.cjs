const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
for (const [preference, systemDark, expected] of [['system',true,'dark'],['system',false,'light'],['dark',false,'dark'],['light',true,'light']]) {
  const root = {dataset:{themePreference:preference}};
  const listeners = {};
  const media = {matches:systemDark,addEventListener:(name,fn)=>listeners.system=fn};
  vm.runInNewContext(fs.readFileSync('app/assets/javascripts/theme.js','utf8'),{document:{documentElement:root,addEventListener:(name,fn)=>listeners.change=fn},matchMedia:()=>media});
  assert.equal(root.dataset.theme,expected);
  assert.equal(root.dataset.seTheme,expected==='dark'?'flat':'clean');
  listeners.change({target:{matches:()=>true},detail:{value:'dark'}});
  assert.equal(root.dataset.theme,'dark');
  media.matches=false;listeners.system();
  assert.equal(root.dataset.theme,'dark');
}
console.log('Theme resolves before component initialization and respects explicit preferences');
