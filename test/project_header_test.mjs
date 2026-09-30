import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../app/assets/javascripts/app_forms.js', import.meta.url), 'utf8');
let Header;
vm.runInNewContext(source.slice(source.indexOf('application.register("project-header"'), source.indexOf('application.register("catalog-more"')), {
  Controller: class {},
  application: {register: (_, controller) => Header = controller},
  getComputedStyle: () => ({paddingTop: '48px'}),
  ResizeObserver: class { observe() {} disconnect() { this.disconnected = true; } }
});
let bottom = 147;
const properties = new Map();
const scroller = {
  getBoundingClientRect: () => ({top: 0}),
  style: {setProperty: (key, value) => properties.set(key, value), removeProperty: key => properties.delete(key)},
  addEventListener: (_, callback) => scroller.listener = callback,
  removeEventListener: (_, callback) => assert.equal(callback, scroller.listener)
};
const controller = new Header();
controller.element = {closest: () => scroller};
controller.originalTarget = {getBoundingClientRect: () => ({bottom, left: 112, width: 1126})};
controller.compactTarget = {style: {}, offsetHeight: 91};
controller.connect();
assert.equal(controller.compactTarget.hidden, true);
bottom = -10;
scroller.listener();
assert.equal(controller.compactTarget.hidden, false);
assert.equal(controller.compactTarget.style.left, '112px');
assert.equal(controller.compactTarget.style.width, '1126px');
assert.equal(properties.get('--project-header-offset'), '43px');
bottom = 147;
scroller.listener();
assert.equal(controller.compactTarget.hidden, true);
controller.disconnect();
assert.equal(properties.size, 0);
assert.equal(controller.resize.disconnected, true);
console.log('Project header scroll, inset and cleanup checks passed');
