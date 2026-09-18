import { Application, Controller } from "@hotwired/stimulus";

const application = Application.start();
application.register("project-slug", class extends Controller {
  static targets = ["name", "slug"];
  connect() { this.edited = Boolean(this.slugTarget.getAttribute("value")); }
  update(event) {
    if (this.slugTarget.contains(event.target)) this.edited = true;
    if (!this.edited && this.nameTarget.contains(event.target)) {
      this.slugTarget.value = this.nameTarget.value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
        .replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase().replace(/[^a-z0-9]+/g, "_")
        .replace(/^_+|_+$/g, "").slice(0, 100).replace(/_+$/g, "");
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
