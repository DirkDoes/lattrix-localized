// Run before Simple Elements upgrades: restore public attributes before it builds controls.
(() => {
  const sidebar = document.querySelector('se-sidebar[data-navigation-user]');
  if (!sidebar) return;
  const key = `navigation:${sidebar.dataset.navigationUser}:v1`;
  let state = {};
  try {
    const saved = JSON.parse(localStorage.getItem(key));
    if (saved && typeof saved === 'object' && !Array.isArray(saved)) state = saved;
  } catch { /* Storage may be blocked; navigation must still work. */ }

  for (const element of [sidebar, ...sidebar.querySelectorAll('[id]')]) {
    if (typeof state[element.id] === 'boolean') element.toggleAttribute('collapsed', state[element.id]);
  }

  // Ignore component initialization and responsive layout changes to the outer sidebar.
  // Groups/chapters share the public collapsed attribute even when they emit no event.
  document.addEventListener('DOMContentLoaded', () => {
    const save = (element) => {
      if (!element.id) return;
      state[element.id] = element.hasAttribute('collapsed');
      try { localStorage.setItem(key, JSON.stringify(state)); } catch { /* Storage unavailable. */ }
    };
    new MutationObserver((records) => {
      for (const { target } of records) if (target !== sidebar) save(target);
    }).observe(sidebar, { subtree: true, attributes: true, attributeFilter: ['collapsed'] });
    sidebar.addEventListener('collapsechange', (event) => {
      if (event.target === sidebar) save(sidebar);
    });
  }, { once: true });
})();
