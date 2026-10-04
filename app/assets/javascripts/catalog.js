document.addEventListener("change", event => {
  if (!event.target.matches("se-select[data-catalog-locale]")) return;
  const form = document.getElementById("catalog-filters");
  form.elements.locale.value = event.detail.value;
  form.requestSubmit();
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
