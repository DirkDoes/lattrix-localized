document.addEventListener("change", event => {
  if (!event.target.matches("se-select[data-catalog-locale]")) return;
  const form = document.getElementById("catalog-filters");
  form.elements.locale.value = event.detail.value;
  form.requestSubmit();
});

document.addEventListener("select", event => {
  if (event.target.matches("se-menu[data-catalog-history-menu]") && event.detail.modal) document.getElementById(event.detail.modal)?.open();
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
  if (form.dataset.submitting) return;
  form.dataset.submitting = "true";
  const modal = form.closest("se-modal");
  const buttons = [...(modal || form).querySelectorAll('se-button[type="submit"], se-button[data-modal-action="confirm"]')];
  form.setAttribute("aria-busy", "true");
  buttons.forEach(button => { button.inert = true; button.setAttribute("aria-disabled", "true"); });
  try {
    const response = await fetch(form.action, {method: form.method, body: new FormData(form), headers: {Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content}});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Could not save this change.");
    modal?.close();
    window.Turbo ? Turbo.visit(result.location) : window.location.assign(result.location);
  } catch (error) {
    const toast = document.createElement("se-toast");
    toast.setAttribute("tone", "error");
    toast.setAttribute("message", error.message);
    toast.setAttribute("open", "");
    document.body.append(toast);
  } finally {
    delete form.dataset.submitting;
    form.removeAttribute("aria-busy");
    buttons.forEach(button => { button.inert = false; button.removeAttribute("aria-disabled"); });
  }
});
