function refreshPendingSnapshot() {
  const frame = document.querySelector('[data-pending-refresh]');
  if (!frame || frame.dataset.polling) return;
  frame.dataset.polling = 'true';
  setTimeout(async () => {
    if (!frame.isConnected) return;
    try {
      const response = await fetch(frame.dataset.pendingRefresh, {headers: {Accept: 'text/html'}, signal: AbortSignal.timeout(15000)});
      if (!response.ok || response.redirected) throw new Error('Refresh unavailable');
      const doc = new DOMParser().parseFromString(await response.text(), 'text/html');
      const replacement = doc.getElementById('incoming-pulls');
      if (replacement && frame.isConnected) { frame.replaceWith(replacement); refreshPendingSnapshot(); }
    } catch (_) {
      if (frame.isConnected) { delete frame.dataset.polling; refreshPendingSnapshot(); }
    }
  }, 3000);
}
document.addEventListener('DOMContentLoaded', refreshPendingSnapshot);
document.addEventListener('turbo:load', refreshPendingSnapshot);
document.addEventListener('turbo:frame-load', refreshPendingSnapshot);

document.addEventListener("click", async event => {
  const button = event.target.closest('[data-pending-diff]');
  if (!button) return;
  event.preventDefault();
  const modal = document.getElementById('pending-diff');
  const content = modal.querySelector('[data-pending-content]');
  content.innerHTML = '<div class="app-row-actions" role="status"><se-spinner></se-spinner><se-text>Loading translation changes…</se-text></div>';
  modal.open();
  const url = button.dataset.pendingDiff;
  content.dataset.request = url;
  try {
    const response = await fetch(url, {headers: {Accept: 'text/html'}, signal: AbortSignal.timeout(60000)});
    if (!response.ok || response.redirected) throw new Error('Unable to load changes. Close this dialog and try again.');
    const html = await response.text();
    if (content.dataset.request === url) content.innerHTML = html;
  } catch (error) {
    if (content.dataset.request === url) content.textContent = error.message;
  }
});

document.addEventListener("change", async event => {
  if (!event.target.matches("se-select[data-catalog-locale]")) return;
  const form = document.getElementById("catalog-filters");
  const table = document.getElementById("catalog-rows");
  const previous = form.elements.locale.value;
  const selected = event.detail.value;
  if (selected === previous) return;
  if (!document.dispatchEvent(new CustomEvent('catalog:before-language', {cancelable: true}))) {
    event.target.value = previous;
    return;
  }
  const scroller = table.closest('main');
  const url = new URL(window.location.href);
  url.searchParams.set('locale', selected);
  url.searchParams.delete('page');
  const requestUrl = new URL(url);
  const rows = [...table.querySelectorAll('[data-catalog-key]')];
  requestUrl.searchParams.set('page', Math.ceil(rows.length / 40));
  requestUrl.searchParams.set('through', rows.at(-1).dataset.catalogKey);
  table.inert = true;
  table.setAttribute('aria-busy', 'true');
  document.dispatchEvent(new Event('catalog:language-start'));
  try {
    const response = await fetch(requestUrl, {headers: {Accept: 'application/json'}, signal: AbortSignal.timeout(30000)});
    if (!response.ok || response.redirected) throw new Error('Could not change language. Please try again.');
    const result = await response.json();
    if (!table.isConnected) return;
    // A concurrent catalog edit needs the full fresh projection, not a partial cell swap.
    if (String(result.revision) !== table.dataset.revision || !result.rows.trim()) {
      window.Turbo.visit(url.href, {frame: 'app-content', action: 'replace'});
      return;
    }
    const incoming = new DOMParser().parseFromString(result.rows, 'text/html');
    const nextRows = [...incoming.querySelectorAll('[data-catalog-key]')];
    const ids = new Set(nextRows.map(row => row.dataset.catalogKey));
    const top = table.querySelector('se-list-header').getBoundingClientRect().bottom;
    const anchor = rows.find(row => ids.has(row.dataset.catalogKey) && row.getBoundingClientRect().height > 0 && row.getBoundingClientRect().bottom > top);
    const offset = anchor?.getBoundingClientRect().top;
    const originalRows = new Map(rows.map(row => [row.dataset.catalogKey, row]));
    rows.filter(row => !ids.has(row.dataset.catalogKey)).forEach(row => row.remove());
    let preceding = table.querySelector('se-list-header');
    for (const row of nextRows) {
      const existing = originalRows.get(row.dataset.catalogKey);
      if (existing) {
        existing.querySelector('[data-catalog-target]').replaceWith(row.querySelector('[data-catalog-target]'));
        preceding = existing;
      } else {
        preceding.after(row);
        preceding = row;
      }
    }
    document.getElementById('catalog-modals').innerHTML = result.modals;
    document.getElementById('catalog-more').outerHTML = result.more;
    form.elements.locale.value = result.locale;
    history.replaceState(history.state, '', url);
    // Anchor a visible key rather than scrollTop: rows above it can change height.
    const holdAnchor = () => {
      if (anchor?.isConnected) scroller.scrollTop += anchor.getBoundingClientRect().top - offset;
    };
    holdAnchor();
    const resize = new ResizeObserver(holdAnchor);
    resize.observe(table);
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    holdAnchor();
    resize.disconnect();
  } catch (error) {
    event.target.value = previous;
    const toast = document.createElement('se-toast');
    toast.setAttribute('tone', 'error'); toast.setAttribute('message', 'Could not change language. Please try again.'); toast.setAttribute('open', ''); document.body.append(toast);
  } finally {
    table.inert = false;
    table.removeAttribute('aria-busy');
    document.dispatchEvent(new Event('catalog:language-end'));
  }
});

document.addEventListener("select", event => {
  if (event.target.matches("se-menu[data-catalog-history-menu]") && event.detail.modal) {
    const modal = document.getElementById(event.detail.modal);
    if (event.detail.id === "add-child") {
      modal.querySelector('form').reset();
      modal.querySelector('se-input[name="path"]').value = event.detail.path;
    }
    modal?.open();
  }
});

document.addEventListener("action", event => {
  if (!event.target.matches("se-split-button[data-catalog-actions]")) return;
  const action = event.detail.id || event.target.dataset.defaultAction;
  if (event.detail.disabled || event.target.hasAttribute("disabled")) return;
  if (action === "export") document.getElementById("catalog-export")?.open();
  if (action === "sync") {
    if (!document.dispatchEvent(new CustomEvent('catalog:before-sync', {cancelable: true}))) return;
    const form = document.getElementById("catalog-sync-form");
    if (!form || form.hasAttribute("aria-busy")) return;
    form.requestSubmit();
  }
});

document.addEventListener("click", async event => {
  const button = event.target.closest("[data-history-more]");
  if (!button || button.inert) return;
  event.preventDefault();
  button.inert = true;
  try {
    const response = await fetch(button.dataset.historyMore, {headers: {Accept: "text/vnd.turbo-stream.html"}});
    if (!response.ok || !response.headers.get("content-type")?.includes("turbo-stream")) throw new Error();
    window.Turbo.renderStreamMessage(await response.text());
  } catch {
    button.inert = false;
    const toast = document.createElement("se-toast");
    toast.setAttribute("tone", "error"); toast.setAttribute("message", "Could not load events. Please try again."); toast.setAttribute("open", ""); document.body.append(toast);
  }
});

document.addEventListener("submit", async (event) => {
  const form = event.target.closest("form[data-catalog-form]");
  if (!form) return;
  event.preventDefault();
  if (!window.AppFormSubmission.start(form)) return;
  const actions = form.id === 'catalog-sync-form' ? [...document.querySelectorAll('[data-catalog-actions]')] : [];
  const loadingActions = actions.map(button => {
    const loading = document.createElement('se-split-button');
    for (const attribute of button.attributes) if (attribute.name !== 'data-ready') loading.setAttribute(attribute.name, attribute.value);
    loading.setAttribute('disabled', '');
    loading.setAttribute('text', 'Queuing…');
    loading.setAttribute('aria-busy', 'true');
    button.replaceWith(loading);
    return loading;
  });
  const modal = form.closest("se-modal");
  try {
    const response = await fetch(form.action, {method: form.method, body: new FormData(form), signal: AbortSignal.timeout(120000), headers: {Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content}});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Could not save this change.");
    modal?.close();
    window.Turbo ? Turbo.visit(result.location, {frame: "app-content"}) : window.location.assign(result.location);
  } catch (error) {
    const toast = document.createElement("se-toast");
    toast.setAttribute("tone", "error");
    toast.setAttribute("message", error.message);
    toast.setAttribute("open", "");
    document.body.append(toast);
  } finally {
    window.AppFormSubmission.finish(form);
    loadingActions.forEach((button, index) => button.replaceWith(actions[index]));
  }
});
