function wildcardEdges(format) {
  const parts = String(format || "").split("...");
  return parts.length === 2 && parts.every(Boolean) ? parts : null;
}
export function wildcardParts(text, format) {
  const edges = wildcardEdges(format);
  if (!edges) return [String(text)];
  const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return String(text).split(new RegExp(`(${escape(edges[0])}[\\s\\S]*?${escape(edges[1])})`, "g")).filter(Boolean);
}
function highlightWildcards(element, text = element.textContent, format = element.dataset.wildcardHighlightFormatValue) {
  const edges = wildcardEdges(format);
  element.replaceChildren(...wildcardParts(text, format).map(part => {
    if (!edges || !part.startsWith(edges[0]) || !part.endsWith(edges[1])) return document.createTextNode(part);
    const mark = document.createElement("span"); mark.className = "translation-wildcard"; mark.textContent = part; return mark;
  }));
}

export function registerTranslations(application, Controller) {
  application.register("wildcard-highlight", class extends Controller {
    static values = {format: String};
    connect() { highlightWildcards(this.element, this.element.textContent, this.formatValue); }
  });
  application.register("membership-languages", class extends Controller {
    static targets = ["role", "assignments"];
    connect() { this.update(); }
    update() { this.assignmentsTarget.hidden = this.roleTarget.value !== "translator"; }
  });
  application.register("file-input", class extends Controller {
    sync(event) {
      const transfer = new DataTransfer();
      if (event.detail.files[0]) transfer.items.add(event.detail.files[0]);
      this.element.querySelector('input[type="file"]').files = transfer.files;
    }
  });
  application.register("key-form", class extends Controller {
    static values = {pluralConfirmation: Boolean, pluralConfirmationId: String};
    async submit(event) {
      event.preventDefault();
      if (this.saving) return;
      this.saving = true;
      const modal = this.element.closest("se-modal");
      let status = this.element.querySelector('[role="alert"]');
      if (!status) { status = document.createElement("se-text"); status.setAttribute("role", "alert"); this.element.prepend(status); }
      status.textContent = "Saving…";
      try {
        const editor = this.application.getControllerForElementAndIdentifier(this.element, "key-editor");
        if (editor && !(await editor.resolve(true))?.valid) { status.textContent = ""; return; }
        if (this.pluralConfirmationValue && editor?.pluralTarget.checked && editor.hasTranslations() && !this.element.hasAttribute("data-plural-confirmed")) {
          status.textContent = "";
          document.getElementById(this.pluralConfirmationIdValue).open();
          return;
        }
        const response = await fetch(this.element.action, {method: this.element.method, body: new FormData(this.element), headers: {Accept: "application/json"}});
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || "Could not save. Your input is still here.");
        const url = new URL(data.location, window.location.origin);
        const toolbar = this.element.closest('[data-controller="translation-table"]')?.querySelector('.translation-toolbar');
        if (toolbar) {
          this.application.getControllerForElementAndIdentifier(this.element.closest('[data-controller="translation-table"]'), "translation-table")?.prepareRefresh();
          const filters = new FormData(toolbar);
          for (const name of ["view", "sort", "left", "right", "q", "mobile", "loaded"]) if (filters.has(name)) url.searchParams.set(name, filters.get(name));
        }
        const results = document.getElementById("translation-results");
        if (results) {
          modal?.close(); status.textContent = "";
          results.src = url.href;
        }
        else window.location.assign(url.href);
      } catch (error) {
        status.textContent = error.message;
        const toast = document.createElement("se-toast");
        toast.setAttribute("tone", "error"); toast.setAttribute("message", error.message); toast.setAttribute("open", "");
        document.body.append(toast);
      }
      finally { this.saving = false; }
    }
  });
  application.register("key-editor", class extends Controller {
    static targets = ["name", "parent", "parentArea", "parentPicker", "separated", "combinedToggle", "separatedToggle", "preview", "translations", "rows", "rowTemplate", "initial", "plural", "addTranslation"];
    static values = {preview: String, parents: String, default: String, delimiter: String, id: String};
    async connect() {
      this.sequence = 0; this.parentRequestNumber = 0; this.parentPath = this.parentTarget.dataset.path;
      await Promise.all([customElements.whenDefined("se-input"), customElements.whenDefined("se-select")]);
      if (!this.element.isConnected) return;
      if (!this.rowsTarget.querySelector("[data-language]")) JSON.parse(this.initialTarget.value).forEach(value => this.appendLanguage(value));
      this.updateToggle(); this.pluralChanged(); this.preview();
    }
    disconnect() { clearTimeout(this.previewTimer); clearTimeout(this.parentTimer); this.previewRequest?.abort(); this.parentRequest?.abort(); }
    updateToggle() { if (this.hasCombinedToggleTarget) { this.combinedToggleTarget.hidden = this.separatedTarget.value === "1"; this.separatedToggleTarget.hidden = this.separatedTarget.value !== "1"; } }
    async toggleParent() {
      if (this.separatedTarget.value === "1") {
        const parent = this.parentPath;
        this.nameTarget.value = (this.parentTarget.value ? parent + this.delimiterValue : "") + this.nameTarget.value;
        this.parentTarget.value = ""; this.separatedTarget.value = "0"; this.parentAreaTarget.hidden = true;
      } else {
        const result = await this.resolve();
        if (!result?.valid || !result.parent_id) return;
        this.parentTarget.value = result?.parent_id || "";
        this.parentPath = result?.parent || "";
        this.parentPickerTarget.options = result?.parent_id ? [{id: result.parent_id, label: result.parent}] : [];
        this.parentPickerTarget.value = result?.parent_id || "";
        this.nameTarget.value = result.levels.slice(result.existing.filter(Boolean).length).join(this.delimiterValue);
        this.separatedTarget.value = "1"; this.parentAreaTarget.hidden = false;
      }
      this.updateToggle(); this.preview();
    }
    preview() { this.setSplitEnabled(false); clearTimeout(this.previewTimer); this.previewTimer = setTimeout(() => this.resolve(), 300); }
    async resolve(required = false) {
      this.previewRequest?.abort(); this.previewRequest = new AbortController();
      if (!this.nameTarget.value.trim()) { this.fieldError(required ? "Enter a key name" : ""); this.showBadges(this.separatedTarget.value === "1" ? [] : [{text: "Add a key", tone: "gray"}]); return; }
      const url = new URL(this.previewValue, window.location.origin);
      url.searchParams.set("name", this.nameTarget.value);
      if (this.idValue) url.searchParams.set("id", this.idValue);
      url.searchParams.set("separated", this.separatedTarget.value);
      if (this.separatedTarget.value === "1") url.searchParams.set("parent_id", this.parentTarget.value);
      try {
        const response = await fetch(url, {signal: this.previewRequest.signal, headers: {Accept: "application/json"}});
        if (!response.ok) throw new Error("Could not check this path");
        const data = await response.json();
        this.setSplitEnabled(data.valid && !!data.parent_id);
        this.fieldError(data.valid ? "" : data.error);
        this.showBadges(!data.valid ? [] : data.levels.length > 1 ? data.levels.map((text, i) => ({text, tone: data.existing[i] ? "brand" : "success"})) : [{text: "Top level key", tone: "gray"}]);
        return data;
      } catch (error) { if (error.name !== "AbortError") this.fieldError(error.message); }
    }
    setSplitEnabled(enabled) {
      if (!this.hasCombinedToggleTarget) return;
      const button = this.combinedToggleTarget.querySelector("se-button");
      if (button.hasAttribute("disabled") === !enabled) return;
      const replacement = document.createElement("se-button");
      for (const {name, value} of button.attributes) if (name !== "data-ready") replacement.setAttribute(name, value);
      replacement.toggleAttribute("disabled", !enabled);
      button.replaceWith(replacement);
    }
    fieldError(message) {
      const field = this.nameTarget;
      if ((field.getAttribute("error") || "") === message) return;
      const input = field.querySelector("input");
      const focused = document.activeElement === input;
      const start = input?.selectionStart, end = input?.selectionEnd;
      const replacement = document.createElement("se-input");
      for (const {name, value} of field.attributes) if (name !== "data-ready" && name !== "class") replacement.setAttribute(name, value);
      replacement.setAttribute("value", field.value);
      if (message) replacement.setAttribute("error", message); else replacement.removeAttribute("error");
      field.replaceWith(replacement);
      if (focused) { const next = replacement.querySelector("input"); next?.focus(); next?.setSelectionRange(start, end); }
    }
    pluralChanged() { this.addTranslationTarget.hidden = this.hasPluralTarget && this.pluralTarget.checked; }
    hasTranslations() { return [...this.rowsTarget.querySelectorAll("[data-text]")].some(field => field.value.trim()); }
    showBadges(items) {
      this.previewTarget.replaceChildren(...items.map(item => {
        const badge = document.createElement("se-badge"); badge.setAttribute("text", item.text); badge.setAttribute("tone", item.tone); return badge;
      }));
    }
    searchParents(event) {
      clearTimeout(this.parentTimer); this.parentRequest?.abort();
      const request = ++this.parentRequestNumber;
      const select = this.parentPickerTarget;
      const query = event.detail.query.trim();
      select.options = [];
      select.setAttribute("empty-text", query.length < 3 ? "Type at least 3 characters." : "Searching…");
      if (query.length < 3) return;
      this.parentTimer = setTimeout(async () => {
        this.parentRequest = new AbortController();
        try {
          const url = new URL(this.parentsValue, window.location.origin); url.searchParams.set("q", query);
          const response = await fetch(url, {signal: this.parentRequest.signal, headers: {Accept: "application/json"}});
          if (!response.ok) throw new Error("Could not load parents. Try again.");
          const rows = await response.json();
          if (request !== this.parentRequestNumber) return;
          select.setAttribute("empty-text", "No matching keys."); select.options = rows;
        } catch (error) {
          if (request === this.parentRequestNumber && error.name !== "AbortError") select.setAttribute("empty-text", error.message);
        }
      }, 300);
    }
    chooseParent() {
      this.parentTarget.value = this.parentPickerTarget.value;
      this.parentPath = this.parentPickerTarget.options?.find(option => String(option.id) === String(this.parentTarget.value))?.label || "";
      this.preview();
    }
    addLanguage() { this.appendLanguage({language_id: this.rowsTarget.querySelectorAll("se-list-row:not([hidden])").length ? "" : this.defaultValue}); }
    appendLanguage(value) {
      const row = this.rowTemplateTarget.content.firstElementChild.cloneNode(true);
      const prefix = `translation_rows[${this.sequence++}]`;
      row.querySelector("[data-language]").setAttribute("name", `${prefix}[language_id]`);
      row.querySelector("[data-language]").setAttribute("value", value.language_id || "");
      row.querySelector("[data-text]").setAttribute("name", `${prefix}[text]`);
      row.querySelector("[data-text]").setAttribute("value", value.text || "");
      for (const field of ["version", "translation_id"]) {
        const input = document.createElement("input"); input.type = "hidden"; input.name = `${prefix}[${field}]`; input.value = value[field] ?? (field === "version" ? "new" : ""); row.firstElementChild.append(input);
      }
      row.dataset.existing = value.translation_id || "";
      this.rowsTarget.append(row); this.translationsTarget.hidden = false;
    }
    removeLanguage(event) {
      const row = event.currentTarget.closest(".key-translation-row");
      if (row.dataset.existing) { row.querySelector("[data-text]").value = ""; row.hidden = true; }
      else row.remove();
      this.translationsTarget.hidden = !this.rowsTarget.querySelector("se-list-row:not([hidden])");
    }
  });
  application.register("translation-cell", class extends Controller {
    static targets = ["display", "editor", "input", "status", "statusText", "spinner", "check", "error", "conflict", "current"];
    static values = {url: String, language: String, version: String, record: String};
    connect() { this.original = this.inputTarget.value; }
    setStatus(state, message = "") {
      this.spinnerTarget.hidden = state !== "saving";
      this.checkTarget.hidden = state !== "saved";
      this.statusTextTarget.textContent = message;
      this.statusTarget.title = message;
      this.errorTarget.hidden = state !== "error";
      this.errorTarget.textContent = state === "error" ? message : "";
    }
    changed() { if (!this.saving && this.conflictTarget.hidden) this.setStatus("idle"); }
    async edit() {
      if (this.saving) return;
      this.original = this.inputTarget.value;
      this.displayTarget.hidden = true;
      this.editorTarget.hidden = false;
      await customElements.whenDefined("se-input");
      const input = this.inputTarget.querySelector("textarea");
      input?.setAttribute("aria-label", this.inputTarget.getAttribute("aria-label"));
      input?.focus();
      input?.dispatchEvent(new Event("input", {bubbles: true}));
    }
    keydown(event) {
      if (event.isComposing) return;
      if (event.key === "Escape") { event.preventDefault(); this.inputTarget.value = this.original; this.close(); }
      if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); this.save(); }
    }
    blur(event) {
      if (this.element.contains(event.relatedTarget) || this.editorTarget.hidden || !this.conflictTarget.hidden) return;
      this.save();
    }
    close() { const empty = this.inputTarget.value === ""; this.editorTarget.hidden = !empty; this.displayTarget.hidden = empty; }
    async save() {
      if (this.saving || !this.conflictTarget.hidden) return;
      if (this.inputTarget.value === this.original) { this.close(); return; }
      this.saving = true; this.inputTarget.querySelector("textarea").readOnly = true; this.setStatus("saving", "Saving…");
      const text = this.inputTarget.value;
      try {
        const response = await fetch(this.urlValue, {method: "PATCH", headers: {"Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content}, body: JSON.stringify({language_id: this.languageValue, text, version: this.versionValue, translation_id: this.recordValue})});
        const data = await response.json();
        if (response.status === 409) {
          this.pendingVersion = data;
          highlightWildcards(this.currentTarget, data.text || "(missing)");
          this.conflictTarget.hidden = false;
          this.setStatus("error", data.error);
          return;
        }
        if (!response.ok) throw new Error(data.error || "Could not save. Your edit is still here.");
        this.apply(data); this.close(); this.setStatus("saved", "Saved");
      } catch (error) { this.setStatus("error", error.message || "Could not save. Try again."); }
      finally { this.saving = false; this.inputTarget.querySelector("textarea").readOnly = false; }
    }
    apply(data) {
      this.versionValue = String(data.version); this.recordValue = data.translation_id || "";
      this.inputTarget.value = data.text; this.original = data.text;
      highlightWildcards(this.displayTarget, data.text);
    }
    keep() { this.versionValue = String(this.pendingVersion.version); this.recordValue = this.pendingVersion.translation_id || ""; this.conflictTarget.hidden = true; this.save(); }
    useCurrent() { this.apply(this.pendingVersion); this.conflictTarget.hidden = true; this.close(); this.setStatus("saved", "Using saved value"); }
  });
  application.register("translation-mobile", class extends Controller {
    connect() {
      this.media = window.matchMedia("(max-width: 767px)");
      this.sync = () => this.element.querySelectorAll("[data-tree-collapsible]").forEach(row => {
        row.toggleAttribute("collapsible", !this.media.matches);
      });
      this.media.addEventListener("change", this.sync);
      this.observer = new MutationObserver(this.sync);
      this.observer.observe(this.element, {childList: true});
      this.sync();
    }
    disconnect() { this.media.removeEventListener("change", this.sync); this.observer.disconnect(); }
  });
  application.register("translation-table", class extends Controller {
    async connect() {
      this.media = window.matchMedia("(max-width: 767px)");
      const navigation = this.element.querySelector(".app-page-navigation");
      this.navigationObserver = new ResizeObserver(() => this.element.style.setProperty("--app-nav-height", `${navigation.offsetHeight}px`));
      this.navigationObserver.observe(navigation);
      this.boundLayout = () => this.layout(true);
      this.boundUpdate = event => {
        this.updateSort();
        if (event.target.id !== "translation-results" || !this.scrollState) return;
        const state = this.scrollState; this.scrollState = null;
        this.element.querySelectorAll('[data-tree-collapsible]').forEach(row => {
          if (state.collapsed.has(row.dataset.keyRow)) row.setAttribute("collapsed", "");
        });
        requestAnimationFrame(() => {
          event.target.style.minHeight = "";
          this.element.closest("main").scrollTop = state.top;
        });
      };
      this.beforeRender = event => {
        if (event.target.id !== "translation-results") return;
        const frame = event.target;
        this.scrollState = {top: this.element.closest("main").scrollTop, collapsed: new Set([...frame.querySelectorAll('[data-tree-collapsible][collapsed]')].map(row => row.dataset.keyRow))};
        frame.style.minHeight = `${frame.offsetHeight}px`;
      };
      this.element.addEventListener("turbo:before-frame-render", this.beforeRender);
      this.media.addEventListener("change", this.boundLayout);
      this.element.addEventListener("turbo:frame-load", this.boundUpdate);
      await customElements.whenDefined("se-popover");
      if (this.element.isConnected) this.layout(this.media.matches || new URL(window.location.href).searchParams.has("mobile"));
    }
    disconnect() {
      clearTimeout(this.searchTimer);
      this.navigationObserver.disconnect();
      this.media.removeEventListener("change", this.boundLayout);
      this.element.removeEventListener("turbo:frame-load", this.boundUpdate);
      this.element.removeEventListener("turbo:before-frame-render", this.beforeRender);
    }
    layout(refresh) {
      const mobile = this.media.matches;
      const search = this.element.querySelector('se-input[name="q"]');
      const destination = this.element.querySelector(mobile ? '[data-search-slot]' : '[data-desktop-search]');
      if (search.parentElement !== destination) destination.append(search);
      this.element.querySelector('[data-desktop-search]').hidden = mobile;
      this.element.querySelector('[data-mobile-search]').hidden = !mobile;
      this.element.querySelector('[data-view-field]').hidden = mobile;
      this.element.querySelector('[data-mobile-view]').disabled = !mobile;
      this.updateSort();
      if (refresh) { this.prepareRefresh(); this.element.querySelector('.translation-toolbar').requestSubmit(); }
    }
    updateSort() { const field = this.element.querySelector("[data-sort-field]"); if (field) field.hidden = !this.media?.matches && this.element.querySelector('se-select[name="view"]')?.value === "tree"; }
    keyAction(event) {
      if (event.detail.id === "edit") this.editKey(event);
      if (event.detail.id === "remove") { const url = new URL(event.currentTarget.dataset.url, window.location.origin); url.searchParams.set("remove", "1"); this.openModal(url); }
      if (event.detail.id === "child") this.addChild(event);
      if (event.detail.id === "plural") {
        this.element.querySelectorAll("[data-key-row]").forEach(row => { if (row.dataset.keyRow === event.currentTarget.dataset.key) row.removeAttribute("collapsed"); });
        this.element.querySelectorAll("[data-plural-parent]").forEach(row => {
          if (row.dataset.pluralParent === event.currentTarget.dataset.key && row.dataset.pluralCategory === event.detail.name) row.hidden = false;
        });
      }
    }
    editKey(event) { this.openModal(event.currentTarget.dataset.url); }
    async openModal(url) {
      try {
        const response = await fetch(url);
        if (!response.ok) throw new Error("Could not load key settings");
        const holder = document.createElement("div");
        holder.innerHTML = await response.text();
        this.element.querySelector("[data-key-modal-host]")?.remove();
        holder.dataset.keyModalHost = ""; this.element.append(holder);
        await customElements.whenDefined("se-modal"); holder.querySelector("se-modal").open();
      } catch (error) { const toast = document.createElement("se-toast"); toast.setAttribute("text", error.message); document.body.append(toast); }
    }
    prepareRefresh() {
      const positions = [...this.element.querySelectorAll('[data-row-position]')].map(row => Number(row.dataset.rowPosition));
      this.element.querySelector('.translation-toolbar').elements.loaded.value = Math.max(20, ...positions);
    }
    language(event) {
      const form = this.element.querySelector(".translation-toolbar");
      form.elements[event.currentTarget.dataset.languageSide].value = event.currentTarget.value;
      clearTimeout(this.searchTimer);
      this.prepareRefresh(); form.requestSubmit();
    }
    filter(event) { clearTimeout(this.searchTimer); this.updateSort(); this.prepareRefresh(); event.currentTarget.requestSubmit(); }
    search(event) { if (event.isComposing) return; clearTimeout(this.searchTimer); const form = event.currentTarget.closest("form"); this.searchTimer = setTimeout(() => { this.prepareRefresh(); form.requestSubmit(); }, 300); }
    addRoot(event) { this.openModal(event.currentTarget.dataset.url); }
    addChild(event) {
      const url = new URL(this.element.querySelector('[data-action="click->translation-table#addRoot"]').dataset.url, window.location.origin);
      url.searchParams.set("parent_id", event.currentTarget.dataset.key); this.openModal(url);
    }
  });
  application.register("configuration-toggle", class extends Controller {
    submit() { this.element.requestSubmit(); }
  });
  application.register("configuration-row", class extends Controller {
    static values = {url: String, method: String, resource: String, reload: Boolean};
    async save() {
      if (this.saving) return;
      this.saving = true;
      try {
        const values = Object.fromEntries([...this.element.querySelectorAll("[data-field]")].map(field => [field.dataset.field, field.value]));
        const response = await fetch(this.urlValue, {method: this.methodValue, headers: {"Content-Type":"application/json", Accept:"application/json", "X-CSRF-Token":document.querySelector('meta[name="csrf-token"]').content}, body:JSON.stringify({[this.resourceValue]:values})});
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || "Could not save.");
        if (this.reloadValue) { window.location.reload(); return; }
        this.notice(data.message, "success");
      } catch(error) { this.notice(error.message, "error"); }
      finally { this.saving = false; }
    }
    notice(message, tone) { const toast=document.createElement("se-toast"); toast.setAttribute("message",message); toast.setAttribute("tone",tone); toast.setAttribute("open",""); document.body.append(toast); }
  });
  application.register("export-download", class extends Controller {
    static targets = ["descriptions", "progressModal", "progress", "status"];
    disconnect() { clearTimeout(this.timer); }
    format(event) { this.descriptionsTarget.hidden = !["csv","xlsx"].includes(event.currentTarget.value); }
    async start(event) {
      event.preventDefault();
      if (this.starting) return;
      if (this.url) { event.target.closest("se-modal").close(); this.progressModalTarget.open(); return; }
      this.starting = true;
      try {
        const response=await fetch(event.target.action,{method:"POST",body:new FormData(event.target),headers:{Accept:"application/json"}});
        const data=await response.json();
        if (!response.ok) throw new Error(data.error || "Could not start export.");
        this.url=data.url; this.progressTarget.value=0; this.statusTarget.textContent="Queued…";
        event.target.closest("se-modal").close(); this.progressModalTarget.open(); this.poll();
      } catch(error) { this.notice(error.message); }
      finally { this.starting=false; }
    }
    async poll() {
      const url=this.url;
      if (!url) return;
      try {
        const response=await fetch(url,{headers:{Accept:"application/json"}});
        if (!response.ok) throw new Error("Could not read export status.");
        const data=await response.json();
        if (this.url !== url) return;
        this.progressTarget.value=data.progress;
        this.statusTarget.textContent=data.status === "queued" ? "Queued…" : `Building files… ${data.progress}%`;
        if (data.status === "ready") {
          this.url=null; this.progressModalTarget.close();
          const link=document.createElement("a"); link.href=data.download; link.download=""; document.body.append(link); link.click(); link.remove(); return;
        }
        if (["failed","cancelled"].includes(data.status)) { this.url=null; this.progressModalTarget.close(); if(data.error) this.notice(data.error); return; }
        this.timer=setTimeout(()=>this.poll(),1000);
      } catch(error) { this.statusTarget.textContent=error.message; this.timer=setTimeout(()=>this.poll(),3000); }
    }
    async cancel() {
      const url=this.url; this.url=null; clearTimeout(this.timer);
      if (!url) return;
      try {
        const response = await fetch(url,{method:"DELETE",headers:{"X-CSRF-Token":document.querySelector('meta[name="csrf-token"]').content}});
        if (!response.ok) throw new Error("Could not cancel export.");
      } catch(error) {
        this.url=url; this.progressModalTarget.open(); this.poll();
        this.notice("Could not cancel export. Please try again.");
      }
    }
    notice(message) { const toast=document.createElement("se-toast"); toast.setAttribute("message",message); toast.setAttribute("tone","error"); toast.setAttribute("open",""); document.body.append(toast); }
  });
  application.register("language-table", class extends Controller {
    static targets = ["rows", "template"];
    add() { this.rowsTarget.append(this.templateTarget.content.cloneNode(true)); }
  });
  application.register("language-row", class extends Controller {
    static targets = ["name", "identifier", "sheets"];
    static values = {url: String, method: String};
    async save() {
      if (this.saving) return;
      this.saving = true;
      let message, tone = "success";
      try {
        const language = {name: this.nameTarget.value, sheet_ids: Array.isArray(this.sheetsTarget.value) ? this.sheetsTarget.value : this.sheetsTarget.value.split(",").filter(Boolean)};
        if (this.hasIdentifierTarget) language.identifier = this.identifierTarget.value;
        const response = await fetch(this.urlValue, {method: this.methodValue, headers: {"Content-Type": "application/json", Accept:"application/json", "X-CSRF-Token":document.querySelector('meta[name="csrf-token"]').content}, body:JSON.stringify({language})});
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || "Could not save language.");
        this.urlValue = data.url; this.methodValue = "PATCH"; message = data.message;
        if (data.rows) this.element.insertAdjacentHTML("afterend", data.rows);
      } catch (error) { tone = "error"; message = error.message; }
      finally { this.saving = false; }
      const toast = document.createElement("se-toast"); toast.setAttribute("tone", tone); toast.setAttribute("message", message); toast.setAttribute("open", ""); document.body.append(toast);
    }
  });
  application.register("language-preset", class extends Controller {
    static targets = ["name", "identifier"];
    select(event) {
      const field = event.currentTarget;
      const option = JSON.parse(field.getAttribute("options")).find(item => item.id === field.value);
      if (option?.id) { this.nameTarget.value = option.label; this.identifierTarget.value = option.id; }
    }
  });
}
