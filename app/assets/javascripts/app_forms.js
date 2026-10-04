import { Application, Controller } from "@hotwired/stimulus";

import "@hotwired/turbo-rails";
import { registerFormatPreview } from "format_preview";
import { registerCatalogCell } from "catalog_cell";
import "catalog_completions";
import "catalog_options";
window.Turbo.session.drive = false;
const application = Application.start();
registerFormatPreview(application, Controller);
registerCatalogCell(application, Controller);
document.addEventListener('catalog:before-sync', event => {
  const unsaved = [...document.querySelectorAll('[data-controller~="catalog-cell"]')].some(element => {
    const cell = application.getControllerForElementAndIdentifier(element, 'catalog-cell');
    return cell && (cell.saving || cell.inputTarget.value !== cell.original);
  });
  if (!unsaved) return;
  event.preventDefault();
  const toast = document.createElement('se-toast');
  toast.setAttribute('tone', 'warning');
  toast.setAttribute('message', 'Finish saving your translation before synchronizing.');
  toast.setAttribute('open', '');
  document.body.append(toast);
});
application.register("catalog-sync", class extends Controller {
  static values = {url: String};
  static targets = ["message"];
  connect() { this.stopped = false; this.poll(); }
  disconnect() { this.stopped = true; clearTimeout(this.timer); this.request?.abort(); }
  async poll() {
    this.request = new AbortController();
    try {
      const response = await fetch(this.urlValue, {headers: {Accept: "application/json"}, signal: this.request.signal});
      if (!response.ok) throw new Error();
      const result = await response.json();
      if (this.stopped) return;
      this.messageTargets.forEach(target => target.textContent = result.message);
      if (!result.busy) {
        window.Turbo.visit(window.location.href, {frame: "app-content", action: "replace"});
        return;
      }
    } catch (error) {
      if (this.stopped) return;
      this.messageTargets.forEach(target => target.textContent = "Cannot check synchronization right now. Retrying automatically…");
    }
    this.timer = setTimeout(() => this.poll(), 3000);
  }
});
application.register("project-header", class extends Controller {
  static targets = ["original", "compact"];
  connect() {
    this.scroller = this.element.closest("main");
    this.update = () => {
      const root = this.scroller.getBoundingClientRect();
      const bounds = this.originalTarget.getBoundingClientRect();
      const compact = this.compactTarget;
      compact.hidden = bounds.bottom > root.top;
      compact.style.top = `${root.top}px`;
      compact.style.left = `${bounds.left}px`;
      compact.style.width = `${bounds.width}px`;
      const inset = (compact.hidden ? 0 : compact.offsetHeight) - parseFloat(getComputedStyle(this.scroller).paddingTop);
      this.scroller.style.setProperty("--project-header-offset", `${inset}px`);
    };
    this.scroller.addEventListener("scroll", this.update, {passive: true});
    this.resize = new ResizeObserver(this.update);
    [this.scroller, this.originalTarget, this.compactTarget].forEach(element => this.resize.observe(element));
    this.update();
  }
  disconnect() {
    this.scroller.removeEventListener("scroll", this.update);
    this.resize.disconnect();
    this.scroller.style.removeProperty("--project-header-offset");
  }
});
application.register("catalog-more", class extends Controller {
  static values = { url: String };
  static targets = ["status", "retry"];
  connect() {
    this.observer = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) this.load(); }, {rootMargin: "250px"});
    this.observer.observe(this.element);
  }
  disconnect() { this.observer.disconnect(); this.request?.abort(); }
  async load() {
    if (this.loading) return;
    this.loading = true;
    this.retryTarget.hidden = true;
    this.statusTarget.hidden = false;
    this.request = new AbortController();
    try {
      const response = await fetch(this.urlValue, {headers: {Accept: "text/vnd.turbo-stream.html"}, signal: this.request.signal});
      if (!response.ok || !response.headers.get("content-type")?.includes("turbo-stream")) throw new Error("Could not load more translations");
      window.Turbo.renderStreamMessage(await response.text());
    } catch (error) {
      if (error.name !== "AbortError") { this.statusTarget.hidden = true; this.retryTarget.hidden = false; this.loading = false; }
    }
  }
});
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
    if (!window.AppFormSubmission.start(this.element)) return;
    try {
      const response = await fetch(this.element.action, { method: "POST", body: new FormData(this.element), signal: AbortSignal.timeout(120000), headers: { Accept: "text/html" } });
      const page = new DOMParser().parseFromString(await response.text(), "text/html");
      const results = page.querySelector("[data-table-results]");
      if (!response.ok || !results) { window.location.assign(response.url); return; }
      document.querySelector("[data-table-results]").replaceWith(results);
      history.replaceState(null, "", response.url);
      page.querySelectorAll("se-toast").forEach(toast => document.body.append(toast));
    } catch {
      window.location.reload();
    } finally { window.AppFormSubmission.finish(this.element); }
  }
});

application.register("control-label", class extends Controller {
  async connect() {
    await customElements.whenDefined(this.element.localName);
    this.element.querySelector("input:not([type=hidden]), textarea, button")?.setAttribute("aria-label", this.element.getAttribute("aria-label"));
  }
});
