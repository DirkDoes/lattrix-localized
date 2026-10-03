// Matching is project-local. Keep insertion ranges ourselves: SE's default
// replacement only understands trailing ASCII words, not %{placeholders}.
export function completionContext(kind, value, caret, catalog, source = "", plural = false) {
  const before = value.slice(0, caret);
  let prefix, start, items;
  if (kind === "path") {
    const segments = before.split(".");
    prefix = segments.pop();
    const parent = segments.length ? `${segments.join(".")}.` : "";
    start = parent.length;
    items = [...new Set(catalog.paths.filter(path => path.startsWith(parent)).map(path => path.slice(parent.length).split(".")[0]))].map(text => ({text}));
    if (!parent) {
      for (const item of items) {
        if (Object.hasOwn(catalog.rootGroups || {}, item.text) && catalog.rootGroups[item.text]) item.description = catalog.rootGroups[item.text];
      }
    }
  } else if (kind === "group") {
    prefix = before; start = 0;
    items = catalog.groups.filter(Boolean).map(text => ({text}));
  } else {
    const wildcard = before.match(/%\{?[^\s{}%]*$/u);
    if (wildcard) {
      prefix = wildcard[0]; start = caret - prefix.length;
      items = [...new Set([...(source.match(/(?<!%)%\{[^{}\s]+\}/gu) || []), ...(plural ? ["%{count}"] : [])])].map(text => ({text, description: "Placeholder"}));
    } else {
      // A term can contain spaces/punctuation; match the longest suffix that
      // begins at a word boundary, so both "New York" and "checkout" work.
      items = catalog.terms || [];
      // Search all boundaries, including those inside an earlier unmatched word.
      const boundaries = [...before.matchAll(/\p{L}/gu)].filter(match => match.index === 0 || !/[\p{L}\p{N}_]/u.test(before[match.index - 1]));
      prefix = boundaries.map(match => before.slice(match.index)).find(part => items.some(item => item.text.toLocaleLowerCase().startsWith(part.toLocaleLowerCase()))) || "";
      start = caret - prefix.length;
      if (!prefix) return null;
    }
  }
  const matches = items.filter(item => item.text.toLocaleLowerCase().startsWith(prefix.toLocaleLowerCase()) && item.text !== prefix).slice(0, 30);
  return matches.length ? {start, end: caret, items: matches, value} : null;
}

export function insertCompletion(context, text) {
  return context.value.slice(0, context.start) + text + context.value.slice(context.end);
}

if (typeof document !== "undefined") {
  const contexts = new WeakMap();
  document.addEventListener("focusin", update);
  document.addEventListener("focusout", event => {
    const field = event.target.closest?.('se-input[data-complete]');
    if (field) { contexts.delete(field); field.removeAttribute("completions"); }
  });
  function update(event) {
    const field = event.target.closest?.('se-input[data-complete]');
    const editable = event.target;
    if (!field || typeof editable.selectionStart !== "number") return;
    // SE emits a plain Event before its public completion event. Preserve the
    // pre-insertion range until that event arrives (mouse and keyboard alike).
    if (event.type === "input" && event.constructor === Event && contexts.has(field)) return;
    if (event.isComposing) { field.removeAttribute("completions"); return; }
    const scope = field.closest('[data-completion-catalog]');
    if (!scope) return;
    const catalog = JSON.parse(scope.dataset.completionCatalog);
    const context = completionContext(field.dataset.complete, editable.value, editable.selectionStart, catalog, field.dataset.completionSource, field.dataset.completionPlural === "true");
    if (context) {
      context.end = editable.selectionEnd;
      contexts.set(field, context);
      field.setAttribute("completions", JSON.stringify(context.items));
    } else {
      contexts.delete(field); field.removeAttribute("completions");
    }
  }
  document.addEventListener("input", update);
  document.addEventListener("click", update);
  document.addEventListener("keyup", event => {
    if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) update(event);
  });
  document.addEventListener("completion", event => {
    const field = event.target;
    const context = contexts.get(field);
    const text = event.detail?.item?.text;
    if (!context || !text) return;
    contexts.delete(field);
    const editable = field.querySelector("input, textarea");
    editable.value = insertCompletion(context, text);
    editable.setSelectionRange(context.start + text.length, context.start + text.length);
    editable.dispatchEvent(new Event("input", {bubbles: true}));
    field.removeAttribute("completions");
  });
  document.addEventListener("catalog:translation-saved", event => {
    document.querySelectorAll('[data-completion-catalog]').forEach(scope => {
      const catalog = JSON.parse(scope.dataset.completionCatalog);
      if (catalog.source !== event.detail.locale) return;
      scope.querySelectorAll('[data-catalog-cell-node-value]').forEach(cell => {
        const field = cell.querySelector('[data-complete="translation"]');
        if (field && (cell.dataset.catalogCellNodeValue === String(event.detail.node) || field.dataset.completionSourceNode === String(event.detail.node)) && cell.dataset.catalogCellLocaleValue !== catalog.source) {
          field.dataset.completionSource = event.detail.value;
          field.dataset.completionSourceNode = event.detail.node;
        }
      });
    });
  });
  document.addEventListener("click", event => {
    const add = event.target.closest('[data-add-term]');
    if (add) {
      const form = add.closest('form');
      form.querySelector('se-collection').append(form.querySelector('template').content.cloneNode(true));
    }
    event.target.closest('[data-remove-term]')?.closest('[data-term-row]')?.remove();
  });
}
