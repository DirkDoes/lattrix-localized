import { Application, Controller } from "@hotwired/stimulus";

import "@hotwired/turbo-rails";
import { registerTranslations } from "translations";
import { registerFormatPreview } from "format_preview";
window.Turbo.session.drive = false;
const application = Application.start();
registerTranslations(application, Controller);
registerFormatPreview(application, Controller);
application.register("slug-mirror", class extends Controller {
  static targets = ["source", "destination"];
  static values = { separator: { type: String, default: "_" } };
  connect() { this.edited = Boolean(this.destinationTarget.getAttribute("value")); }
  update(event) {
    if (this.destinationTarget.contains(event.target)) this.edited = true;
    if (!this.edited && this.sourceTarget.contains(event.target)) {
      this.destinationTarget.value = this.sourceTarget.value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
        .replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase().replace(/[^a-z0-9]+/g, "_")
        .replace(/^_+|_+$/g, "").slice(0, 100).replace(/_+$/g, "").replace(/_/g, this.separatorValue);
    }
  }
});

application.register("sheet-import", class extends Controller {
  static targets = ["upload", "files", "auto", "name"];
  static values = {preview: String};
  connect() { this.selected = []; this.valid = true; }
  reset() {
    this.request?.abort(); this.selected = []; this.valid = true;
    this.filesTarget.replaceChildren(); this.autoTargets.forEach(badge => badge.hidden = true);
  }
  files(event) {
    this.selected = [...event.detail.files];
    const transfer = new DataTransfer();
    this.selected.forEach(file => transfer.items.add(file));
    this.uploadTarget.querySelector('input[type="file"]').files = transfer.files;
    this.refresh();
  }
  remove(event) {
    this.selected = this.selected.filter(file => file.name !== event.detail.filename);
    const transfer = new DataTransfer();
    this.selected.forEach(file => transfer.items.add(file));
    this.uploadTarget.querySelector('input[type="file"]').files = transfer.files;
    this.refresh();
  }
  async refresh() {
    this.request?.abort();
    if (!this.selected.length) { this.filesTarget.replaceChildren(); this.autoTargets.forEach(badge => badge.hidden = true); this.valid = true; return; }
    this.render(this.selected.map(file => ({filename: file.name, tone: "gray", subtext: "Reading…"})));
    const data = new FormData();
    this.selected.forEach(file => data.append("imports[]", file));
    data.append("default_language_id", this.element.querySelector('[name="sheet[default_language_id]"]').value);
    this.request = new AbortController();
    try {
      const response = await fetch(this.previewValue, {method: "POST", body: data, signal: this.request.signal, headers: {Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content}});
      const result = await response.json();
      this.render(result.files || []);
      this.valid = response.ok;
      if (response.ok) this.applySettings(result.settings);
    } catch (error) {
      if (error.name === "AbortError") return;
      this.valid = false;
      this.render(this.selected.map(file => ({filename: file.name, error: "Could not be read"})));
    }
  }
  render(files) {
    this.filesTarget.replaceChildren(...files.map(file => {
      const card = document.createElement("se-file-card");
      card.setAttribute("title", file.filename); card.setAttribute("subtitle", file.subtext || ""); card.setAttribute("action", "x");
      if (file.error) card.setAttribute("error", file.error); else if (file.tone) card.setAttribute("tone", file.tone);
      card.addEventListener("remove", event => this.remove(event));
      return card;
    }));
  }
  applySettings(settings) {
    Object.entries(settings).forEach(([name, value]) => {
      const field = this.element.querySelector(`se-checkbox[name="sheet[${name}]"], se-input[name="sheet[${name}]"], se-select[name="sheet[${name}]"]`);
      if (!field) return;
      if (field.localName === "se-checkbox") field.checked = Boolean(value); else field.value = value;
    });
    this.autoTargets.forEach(badge => badge.hidden = false);
  }
  clearNameError() { if (this.nameTarget.hasAttribute("error")) this.renderName(); }
  renderName(error) {
    const field = this.nameTarget, value = field.value;
    const replacement = field.cloneNode(false);
    replacement.removeAttribute("data-ready");
    replacement.removeAttribute("value");
    if (error) replacement.setAttribute("error", error); else replacement.removeAttribute("error");
    field.replaceWith(replacement);
    queueMicrotask(() => { replacement.value = value; const next = replacement.querySelector("input"); next?.focus(); next?.setSelectionRange(value.length, value.length); });
  }
  async submit(event) {
    event.preventDefault();
    if (!this.nameTarget.value.trim()) { this.renderName("Sheet name can't be blank"); return; }
    if (this.pending || (this.selected.length && !this.valid)) return;
    this.pending = true;
    try {
      const response = await fetch(this.element.action, {method: this.element.method, body: new FormData(this.element), headers: {Accept: "text/html"}});
      if (response.redirected) { this.element.closest("se-modal").close(); window.location.assign(response.url); return; }
      const page = new DOMParser().parseFromString(await response.text(), "text/html");
      const replacement = page.getElementById("sheet-create-modal");
      if (!replacement) throw new Error("Could not create the sheet. Please try again.");
      const files = this.selected;
      this.element.closest("se-modal").replaceWith(replacement);
      queueMicrotask(() => {
        replacement.open();
        if (files.length) replacement.querySelector("se-file-upload").dispatchEvent(new CustomEvent("files", {bubbles: true, detail: {files}}));
      });
    } catch (error) {
      const toast = document.createElement("se-toast");
      toast.setAttribute("message", error.message); toast.setAttribute("tone", "error"); toast.setAttribute("open", ""); document.body.append(toast);
    } finally { this.pending = false; }
  }
});

application.register("table-search", class extends Controller {
  connect() {
    const field = this.element.querySelector("se-input");
    customElements.whenDefined("se-input").then(() => {
      field.querySelector("input")?.setAttribute("aria-label", field.getAttribute("aria-label"));
    });
  }
  disconnect() { clearTimeout(this.timer); this.request?.abort(); }
  schedule(event) {
    if (event.isComposing) return;
    clearTimeout(this.timer);
    this.request?.abort();
    this.timer = setTimeout(() => this.element.requestSubmit(), 350);
  }
  async search(event) {
    event.preventDefault();
    clearTimeout(this.timer);
    this.request?.abort();
    const request = this.request = new AbortController();
    const url = new URL(this.element.action);
    url.search = new URLSearchParams(new FormData(this.element)).toString();
    try {
      const response = await fetch(url, { signal: request.signal });
      if (!response.ok || response.redirected) { window.location.assign(response.url); return; }
      const page = new DOMParser().parseFromString(await response.text(), "text/html");
      const results = page.querySelector("[data-table-results]");
      if (!results) { window.location.assign(url); return; }
      if (request.signal.aborted) return;
      document.querySelector("[data-table-results]").replaceWith(results);
      history.replaceState(null, "", url);
      const statusQuery = this.element.closest("header").querySelector('input[type="hidden"][name="q"]');
      if (statusQuery) statusQuery.value = url.searchParams.get("q") || "";
    } catch (error) {
      if (error.name !== "AbortError") window.location.assign(url);
    }
  }
});

application.register("table-action", class extends Controller {
  async submit(event) {
    event.preventDefault();
    if (this.pending) return;
    this.pending = true;
    try {
      const response = await fetch(this.element.action, { method: "POST", body: new FormData(this.element), headers: { Accept: "text/html" } });
      const page = new DOMParser().parseFromString(await response.text(), "text/html");
      const results = page.querySelector("[data-table-results]");
      if (!response.ok || !results) { window.location.assign(response.url); return; }
      document.querySelector("[data-table-results]").replaceWith(results);
      history.replaceState(null, "", response.url);
      page.querySelectorAll("se-toast").forEach(toast => document.body.append(toast));
    } catch {
      window.location.reload();
    } finally { this.pending = false; }
  }
});

application.register("control-label", class extends Controller {
  async connect() {
    await customElements.whenDefined(this.element.localName);
    this.element.querySelector("input:not([type=hidden]), textarea, button")?.setAttribute("aria-label", this.element.getAttribute("aria-label"));
  }
});
