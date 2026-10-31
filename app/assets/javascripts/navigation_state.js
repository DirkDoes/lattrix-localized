// Restore public state before Simple Elements upgrades the navigation controls.
(() => {
  const mobile = matchMedia('(max-width: 767px)');
  const topbar = document.querySelector('.app-topbar');
  const compactTopbar = () => topbar?.setAttribute('data-se-minimized', String(mobile.matches));
  compactTopbar();
  mobile.addEventListener('change', compactTopbar);
  const sidebar = document.querySelector('[data-navigation-user]');
  if (!sidebar) return;
  const key = `navigation:${sidebar.dataset.navigationUser}:v1`;
  let state = {};
  try {
    const saved = JSON.parse(localStorage.getItem(key));
    if (saved && typeof saved === 'object' && !Array.isArray(saved)) state = saved;
  } catch { /* Storage may be blocked; navigation must still work. */ }
  // v1 stored the icon rail as "collapsed". Its boolean now means minimized.
  state[sidebar.id] ??= sidebar.getAttribute('data-se-minimized') === 'true';
  for (const element of sidebar.querySelectorAll('[id]')) {
    if (typeof state[element.id] === 'boolean') element.toggleAttribute('collapsed', state[element.id]);
  }
  const save = () => {
    try { localStorage.setItem(key, JSON.stringify(state)); } catch { /* Storage unavailable. */ }
  };
  const workspace = () => document.getElementById('app-content');
  const backdrop = document.querySelector('.app-navigation-backdrop');
  const trigger = () => document.querySelector('se-panel-toggle[mode="collapse"][for="app-sidebar"] button');
  const close = (restoreFocus = false) => {
    const open = mobile.matches && !sidebar.hidden;
    if (mobile.matches) sidebar.hidden = true;
    backdrop.hidden = true;
    workspace().inert = false;
    if (open && restoreFocus) trigger()?.focus();
  };
  const layout = () => {
    close();
    if (mobile.matches && sidebar.contains(document.activeElement)) trigger()?.focus();
    sidebar.hidden = mobile.matches;
    sidebar.setAttribute('data-se-minimized', String(!mobile.matches && state[sidebar.id]));
  };
  layout();
  mobile.addEventListener('change', layout);
  document.addEventListener('DOMContentLoaded', () => {
    new MutationObserver(records => {
      for (const {target, attributeName} of records) {
        if (target === sidebar && attributeName === 'data-se-minimized' && !mobile.matches) {
          state[sidebar.id] = sidebar.getAttribute('data-se-minimized') === 'true';
        } else if (target !== sidebar && target.id && attributeName === 'collapsed') {
          state[target.id] = target.hasAttribute('collapsed');
        }
      }
      save();
    }).observe(sidebar, {subtree: true, attributes: true, attributeFilter: ['collapsed', 'data-se-minimized']});
    document.addEventListener('beforetoggle', event => {
      if (!mobile.matches || event.detail.target !== sidebar || event.detail.mode !== 'collapse') return;
      event.preventDefault();
      if (!sidebar.hidden) { close(true); return; }
      sidebar.hidden = false;
      backdrop.hidden = false;
      workspace().inert = true;
      sidebar.querySelector('nav a, nav button')?.focus();
    });
    backdrop.addEventListener('click', () => close(true));
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && mobile.matches && !sidebar.hidden) { event.preventDefault(); close(true); }
    });
    sidebar.addEventListener('click', event => {
      if (event.target.closest('a[href]')) close(true);
    });
    document.addEventListener('turbo:frame-load', event => {
      if (event.target.id === 'app-content') close();
    });
  }, {once: true});
})();

// Section links use native fragments within the independently scrolling main pane.
(() => {
  const selectSection = () => {
    const items = [...document.querySelectorAll('[data-settings-anchor]')];
    if (!items.length) return;
    const active = items.find(item => item.getAttribute('href') === window.location.hash) || items[0];
    items.forEach(item => item.toggleAttribute('active', item === active));
  };
  document.addEventListener('DOMContentLoaded', selectSection);
  document.addEventListener('turbo:frame-load', selectSection);
  window.addEventListener('hashchange', selectSection);
})();
