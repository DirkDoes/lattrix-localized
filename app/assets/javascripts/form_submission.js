// Shared by native forms, Turbo forms, and the JSON catalog forms.
(() => {
  const pending = new Map();
  function start(form) {
    if (pending.has(form)) return false;
    const controls = [];
    (form.closest('se-modal') || form).querySelectorAll('se-button[type="submit"], se-button[data-modal-action="confirm"], button[type="submit"], input[type="submit"], button:not([type])').forEach(button => {
      if (!button.matches('se-button') && button.closest('se-button')) return;
      if (button.hasAttribute('disabled')) return;
      // SE v0.16 button attributes are initialization-only. Recreate via public markup.
      if (button.matches('se-button')) {
        const loading = button.cloneNode(false);
        loading.removeAttribute('data-ready');
        loading.setAttribute('disabled', '');
        loading.setAttribute('text', 'Loading…');
        loading.setAttribute('aria-label', 'Loading');
        button.replaceWith(loading);
        controls.push(() => loading.replaceWith(button));
      } else {
        const label = button.tagName === 'INPUT' ? button.value : button.innerHTML;
        button.disabled = true;
        if (button.tagName === 'INPUT') button.value = 'Loading…';
        else button.textContent = 'Loading…';
        controls.push(() => {
          button.disabled = false;
          if (button.tagName === 'INPUT') button.value = label;
          else button.innerHTML = label;
        });
      }
    });
    pending.set(form, controls);
    form.setAttribute('aria-busy', 'true');
    return true;
  }
  function finish(form) {
    pending.get(form)?.forEach(restore => restore());
    pending.delete(form);
    form.removeAttribute('aria-busy');
  }
  window.AppFormSubmission = {start, finish};
  document.addEventListener('submit', event => {
    if (pending.has(event.target)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    // A microtask can run between capture and bubble listeners. Wait for the whole
    // dispatch so custom handlers can cancel native submission and own their busy state.
    setTimeout(() => { if (!event.defaultPrevented && event.target.isConnected) start(event.target); }, 0);
  }, true);
  document.addEventListener('turbo:submit-start', event => start(event.target));
  document.addEventListener('turbo:submit-end', event => {
    finish(event.target);
    if (event.detail.success && event.detail.fetchResponse?.redirected) event.target.closest('se-modal')?.close();
  });
  for (const event of ['pageshow', 'turbo:before-cache']) {
    window.addEventListener(event, () => [...pending.keys()].forEach(finish));
  }
})();
