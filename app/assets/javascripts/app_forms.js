import { Application, Controller } from "@hotwired/stimulus";

import "@hotwired/turbo-rails";
import { registerTranslations } from "translations";
window.Turbo.session.drive = false;
const application = Application.start();
registerTranslations(application, Controller);
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
