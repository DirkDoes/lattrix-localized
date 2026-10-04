export function registerCatalogCell(application, Controller) {
  // One catalog revision covers every cell. Queue this page's saves so they do not race.
  let saves = Promise.resolve();
  application.register("catalog-cell", class extends Controller {
    static targets = ["display", "editor", "input", "status"];
    static values = { url: String, node: String, locale: String, revision: Number };
    connect() { this.original = this.inputTarget.getAttribute("value") || ""; }
    edit() {
      this.displayTarget.hidden = true;
      this.editorTarget.hidden = false;
      this.inputTarget.querySelector("textarea")?.focus();
    }
    close() {
      this.editorTarget.hidden = this.original !== "";
      this.displayTarget.hidden = this.original === "";
    }
    changed() { if (!this.saving) this.statusTarget.textContent = ""; }
    keydown(event) {
      if (event.defaultPrevented || event.isComposing || this.saving) return;
      if (event.key === "Escape") {
        event.preventDefault(); this.inputTarget.value = this.original;
        this.inputTarget.querySelector("textarea")?.removeAttribute("aria-invalid");
        this.statusTarget.textContent = ""; this.close();
      } else if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault(); this.save();
      }
    }
    blur(event) { if (!this.element.contains(event.relatedTarget)) this.save(); }
    save() {
      if (this.saving) return;
      const value = this.inputTarget.value;
      if (value === this.original) { this.close(); return; }
      this.saving = true;
      const input = this.inputTarget.querySelector("textarea");
      input.readOnly = true;
      this.statusTarget.innerHTML = '<se-tooltip><se-spinner data-se-region="trigger" size="small" label="Saving translation"></se-spinner>Saving translation</se-tooltip>';
      saves = saves.then(async () => {
        try {
          const response = await fetch(this.urlValue, {method: "POST", headers: {
            Accept: "application/json", "Content-Type": "application/json",
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
          }, body: JSON.stringify({operation: "translate", inline: "1", node_id: this.nodeValue,
            locale: this.localeValue, revision: this.revisionValue, value})});
          const result = await response.json();
          if (!response.ok) throw new Error(result.error || "Could not save this translation.");
          document.querySelectorAll('[data-catalog-cell-revision-value]').forEach(cell => { cell.dataset.catalogCellRevisionValue = result.revision; });
          const table = document.getElementById('catalog-rows');
          if (table) table.dataset.revision = result.revision;
          document.querySelectorAll('input[name="revision"]').forEach(field => { field.value = result.revision; });
          this.original = result.value;
          document.dispatchEvent(new CustomEvent("catalog:translation-saved", {detail: {node: this.nodeValue, locale: this.localeValue, value: result.value}}));
          this.inputTarget.value = result.value;
          this.displayTarget.innerHTML = result.html;
          input.removeAttribute("aria-invalid");
          this.close();
          this.statusTarget.innerHTML = '<se-tooltip><span data-se-region="trigger" tabindex="0" aria-label="Saved"><se-icon name="check" aria-hidden="true"></se-icon></span>Saved</se-tooltip>';
          for (const update of result.statuses || []) {
            document.querySelectorAll('[data-catalog-status]').forEach(region => {
              if (region.dataset.catalogStatus === update.id) region.innerHTML = update.html;
            });
          }
          for (const update of result.modals || []) {
            const modal = document.getElementById(update.id);
            if (modal && !modal.hasAttribute("open")) modal.outerHTML = update.html;
          }
        } catch (error) {
          this.statusTarget.innerHTML = '<span class="translation-status-label">Not saved</span>';
          input.setAttribute("aria-invalid", "true");
          this.editorTarget.hidden = false;
          this.displayTarget.hidden = true;
          const toast = document.createElement("se-toast");
          toast.setAttribute("tone", "error"); toast.setAttribute("message", error.message);
          toast.setAttribute("open", ""); document.body.append(toast);
        } finally { input.readOnly = false; this.saving = false; }
      });
    }
  });
}
