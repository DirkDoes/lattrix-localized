// Page-local, bounded cache. Every reuse is authorized and revalidated by the server.
export class CatalogReadCache {
  constructor() { this.entries = new Map(); this.bytes = 0; this.generation = 0; }
  clear() { this.entries.clear(); this.bytes = 0; this.generation++; }
  remember(url, value, etag, size) {
    const previous = this.entries.get(url);
    if (previous) { this.bytes -= previous.size; this.entries.delete(url); }
    if (!etag || size > 2_000_000) return;
    this.entries.set(url, {value, etag, size}); this.bytes += size;
    while (this.entries.size > 4 || this.bytes > 2_000_000) {
      const oldest = this.entries.keys().next().value;
      this.bytes -= this.entries.get(oldest).size; this.entries.delete(oldest);
    }
  }
  async read(url, signal) {
    const cached = this.entries.get(url), generation = this.generation;
    const headers = {Accept: 'application/json'};
    if (cached) headers['If-None-Match'] = cached.etag;
    const response = await fetch(url, {headers, signal, cache: 'no-store'});
    if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
    if (response.status === 304 && cached) {
      if (generation === this.generation) this.remember(url, cached.value, cached.etag, cached.size);
      return {...cached.value, etag: cached.etag};
    }
    if (!response.ok || response.redirected) throw new Error('Could not load translations. Please try again.');
    const text = await response.text(), value = JSON.parse(text), etag = response.headers.get('ETag');
    if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
    if (generation === this.generation) this.remember(url, value, etag, text.length * 2);
    return {...value, etag};
  }
}

export function restoreCatalogView(table, snapshot, more) {
  const ids = new Set(snapshot.nodes.map(node => node.id));
  const current = new Map([...table.querySelectorAll('[data-catalog-key]')].map(row => [row.dataset.catalogKey, row]));
  for (const [id, row] of current) if (!ids.has(id)) row.remove();
  let preceding = table.querySelector('se-list-header');
  for (const saved of snapshot.nodes) {
    const row = current.get(saved.id) || saved.row;
    const target = row.querySelector('[data-catalog-target]');
    if (target !== saved.target) target.replaceWith(saved.target);
    if (row.previousElementSibling !== preceding) preceding.after(row);
    preceding = row;
  }
  if (more !== snapshot.moreNode) more.replaceWith(snapshot.moreNode);
}

export function registerCatalogLoading(application, Controller) {
  const caches = new WeakMap();
  const restoreViews = new WeakMap();
  const cacheFor = table => {
    if (!caches.has(table)) caches.set(table, new CatalogReadCache());
    return caches.get(table);
  };
  const measure = (name, start) => performance.measure(name, {start, end: performance.now()});
  const notify = message => {
    const toast = document.createElement('se-toast');
    toast.setAttribute('tone', 'error'); toast.setAttribute('message', message); toast.setAttribute('open', '');
    document.body.append(toast);
  };
  const canNavigate = () => document.dispatchEvent(new CustomEvent('catalog:before-language', {cancelable: true}));
  const refresh = (url = window.location.href) => { if (canNavigate()) window.Turbo.visit(url, {frame: 'app-content', action: 'replace'}); };
  const switchUrl = (locale, rows) => {
    const url = new URL(window.location.href);
    url.searchParams.set('locale', locale); url.searchParams.delete('page');
    const request = new URL(url);
    request.searchParams.set('page', Math.max(1, Math.ceil(rows.length / 40)));
    if (rows.length) request.searchParams.set('through', rows.at(-1).dataset.catalogKey);
    request.searchParams.set('known', rows.map(row => row.dataset.catalogKey).join(','));
    return {url, request};
  };
  let languageRequest;
  document.addEventListener('change', async event => {
    const select = event.target;
    if (!select.matches('se-select[data-catalog-locale]')) return;
    const table = document.getElementById('catalog-rows'), form = document.getElementById('catalog-filters');
    const previous = form.elements.locale.value, selected = event.detail.value;
    if (selected === previous && !languageRequest) return;
    if (!canNavigate()) { select.value = previous; return; }
    languageRequest?.abort();
    const rows = [...table.querySelectorAll('[data-catalog-key]')], cache = cacheFor(table);
    if (!table.hasAttribute('aria-busy')) {
      // Retain actual nodes: serializing initialized Simple Elements would lose their listeners.
      const snapshot = {locale: previous, revision: table.dataset.revision, etag: table.dataset.catalogEtag,
        nodes: rows.map(row => ({id: row.dataset.catalogKey, row, target: row.querySelector('[data-catalog-target]')})),
        moreNode: document.getElementById('catalog-more')};
      restoreViews.set(table, snapshot);
      cache.remember(switchUrl(previous, rows).request.href, snapshot, table.dataset.catalogEtag,
        rows.reduce((size, row) => size + row.querySelector('[data-catalog-target]').outerHTML.length * 2, 0));
    }
    const request = new AbortController(); languageRequest = request;
    const {url, request: requestUrl} = switchUrl(selected, rows), started = performance.now();
    const status = table.querySelector('[data-catalog-language-status]');
    const options = select.options || JSON.parse(select.getAttribute('options') || '[]');
    const label = options.find(option => option.id === selected)?.label || selected;
    status.querySelector('se-text').textContent = `Loading ${label}…`; status.hidden = false;
    table.setAttribute('aria-busy', 'true');
    // Keep the selector usable; the collection retains ownership of collapsed rows' inert state.
    table.querySelectorAll('[data-catalog-key] > div').forEach(cell => { cell.inert = true; });
    document.dispatchEvent(new Event('catalog:language-start'));
    try {
      const result = await cache.read(requestUrl.href, request.signal);
      measure('catalog-language-fetch', started);
      if (request !== languageRequest || !table.isConnected) return;
      if (String(result.revision) !== table.dataset.revision ||
          (table.dataset.catalogEtag && result.etag !== table.dataset.catalogEtag) ||
          (!result.nodes && !result.rows.trim())) { cache.clear(); refresh(url.href); return; }
      const renderStarted = performance.now(), scroller = table.closest('main');
      const nextRows = result.nodes || [...new DOMParser().parseFromString(result.rows, 'text/html').querySelectorAll('[data-catalog-key]')]
        .map(row => ({id: row.dataset.catalogKey, row, target: row.querySelector('[data-catalog-target]')}));
      const ids = new Set(nextRows.map(row => row.id)), top = table.querySelector('se-list-header').getBoundingClientRect().bottom;
      const anchor = rows.find(row => ids.has(row.dataset.catalogKey) && row.getBoundingClientRect().height > 0 && row.getBoundingClientRect().bottom > top);
      const offset = anchor?.getBoundingClientRect().top, originalRows = new Map(rows.map(row => [row.dataset.catalogKey, row]));
      rows.filter(row => !ids.has(row.dataset.catalogKey)).forEach(row => row.remove());
      let preceding = table.querySelector('se-list-header');
      for (const [index, next] of nextRows.entries()) {
        if (index > 0 && index % 40 === 0) {
          await new Promise(resolve => requestAnimationFrame(resolve));
          if (request !== languageRequest || !table.isConnected) return;
        }
        const existing = originalRows.get(next.id);
        next.target.inert = true;
        if (existing) {
          existing.querySelector('[data-catalog-target]').replaceWith(next.target); preceding = existing;
        } else {
          next.row.querySelector('[data-catalog-target]').replaceWith(next.target);
          next.row.querySelectorAll(':scope > div').forEach(cell => { cell.inert = true; });
          preceding.after(next.row); preceding = next.row;
        }
      }
      const more = document.getElementById('catalog-more');
      if (result.moreNode) more.replaceWith(result.moreNode); else more.outerHTML = result.more;
      const holdAnchor = () => { if (request === languageRequest && anchor?.isConnected) scroller.scrollTop += anchor.getBoundingClientRect().top - offset; };
      holdAnchor();
      const resize = new ResizeObserver(holdAnchor); resize.observe(table);
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      resize.disconnect();
      if (request !== languageRequest || !table.isConnected) return;
      holdAnchor();
      form.elements.locale.value = result.locale;
      table.dataset.catalogEtag = result.etag || '';
      history.replaceState(history.state, '', url);
      restoreViews.delete(table);
      measure('catalog-language-render', renderStarted);
    } catch (error) {
      if (request === languageRequest && error.name !== 'AbortError') {
        const snapshot = restoreViews.get(table);
        if (snapshot && table.isConnected) restoreCatalogView(table, snapshot, document.getElementById('catalog-more'));
        restoreViews.delete(table);
        select.value = previous;
        notify('Could not change language. Please try again.');
      }
    } finally {
      if (request === languageRequest) {
        languageRequest = null;
        table.querySelectorAll('[data-catalog-key] > div').forEach(cell => { cell.inert = false; });
        table.removeAttribute('aria-busy'); status.hidden = true;
        document.dispatchEvent(new Event('catalog:language-end'));
      }
    }
  });
  const invalidate = () => {
    const table = document.getElementById('catalog-rows');
    if (table) { cacheFor(table).clear(); delete table.dataset.catalogEtag; }
  };
  document.addEventListener('catalog:translation-saved', invalidate);
  document.addEventListener('catalog:before-sync', invalidate);
  document.addEventListener('turbo:before-cache', () => { languageRequest?.abort(); languageRequest = null; invalidate(); });

  let editorRequest;
  async function openEditor(id, url) {
    editorRequest?.abort();
    const request = new AbortController(); editorRequest = request;
    const loading = document.getElementById('catalog-editor-loading'); loading.open();
    try {
      const response = await fetch(url, {signal: request.signal, headers: {Accept: 'text/html'}, cache: 'no-store'});
      if (!response.ok || response.redirected) throw new Error('Could not open the editor. Please try again.');
      const html = await response.text();
      if (request !== editorRequest || request.signal.aborted || !loading.isConnected) return;
      const content = new DOMParser().parseFromString(html, 'text/html');
      for (const modal of content.querySelectorAll('se-modal')) {
        if (modal.id === id) modal.setAttribute('open', '');
        document.getElementById(modal.id)?.remove(); document.getElementById('catalog-modals').append(modal);
      }
      // The public initial-open attribute waits for the component's queued composition.
      loading.close();
    } catch (error) {
      if (request === editorRequest && error.name !== 'AbortError') { loading.close(); notify(error.message); }
    }
  }
  document.addEventListener('close', event => { if (event.target.id === 'catalog-editor-loading') editorRequest?.abort(); });
  document.addEventListener('click', event => {
    const trigger = event.target.closest('[data-catalog-editor]');
    if (trigger) { event.preventDefault(); openEditor(trigger.dataset.openModal, trigger.dataset.catalogEditor); }
  });
  document.addEventListener('select', event => {
    if (event.target.matches('se-menu[data-catalog-history-menu]') && event.detail.editor) openEditor(event.detail.modal, event.detail.editor);
  });

  application.register('catalog-more', class extends Controller {
    static values = {url: String};
    static targets = ['status', 'retry'];
    connect() {
      this.table = document.getElementById('catalog-rows'); this.scroller = this.element.closest('main');
      this.stopped = false; this.loading = false; this.buffer = null;
      const options = {root: this.scroller};
      this.prefetch = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) this.load(); },
        {...options, rootMargin: `${this.scroller.clientHeight * 2}px 0px`});
      this.append = new IntersectionObserver(entries => {
        this.nearEnd = entries.some(entry => entry.isIntersecting); if (this.nearEnd) this.flush();
      }, {...options, rootMargin: '400px 0px'});
      this.pause = () => { this.stopped = true; this.prefetch.disconnect(); this.append.disconnect(); this.request?.abort(); this.buffer = null; this.loading = false; };
      this.resume = () => { if (this.element.isConnected) { this.stopped = false; this.observe(); } };
      document.addEventListener('catalog:language-start', this.pause);
      document.addEventListener('catalog:language-end', this.resume);
      document.addEventListener('catalog:translation-saved', this.pauseForEdit = () => { this.pause(); this.resume(); });
      this.observe();
    }
    observe() { this.prefetch.observe(this.element); this.append.observe(this.element); }
    disconnect() {
      this.pause();
      document.removeEventListener('catalog:language-start', this.pause);
      document.removeEventListener('catalog:language-end', this.resume);
      document.removeEventListener('catalog:translation-saved', this.pauseForEdit);
    }
    async load() {
      if (this.loading || this.buffer || this.stopped || this.table.hasAttribute('aria-busy')) return;
      this.loading = true; this.retryTarget.hidden = true; this.statusTarget.hidden = false;
      const request = new AbortController(); this.request = request;
      const url = new URL(this.urlValue, window.location.href); url.searchParams.set('batch', '1');
      const started = performance.now();
      try {
        const result = await cacheFor(this.table).read(url.href, request.signal);
        if (this.stopped || this.request !== request) return;
        measure('catalog-prefetch-fetch', started);
        this.buffer = result; this.flush();
      } catch (error) {
        if (error.name !== 'AbortError' && this.request === request) { this.statusTarget.hidden = true; this.retryTarget.hidden = false; }
      } finally { if (this.request === request) this.loading = false; }
    }
    flush() {
      if (!this.buffer || !this.nearEnd || this.stopped || this.table.hasAttribute('aria-busy')) return;
      const result = this.buffer;
      if (String(result.revision) !== this.table.dataset.revision ||
          (this.table.dataset.catalogEtag && result.etag !== this.table.dataset.catalogEtag)) { this.pause(); refresh(); return; }
      const started = performance.now(), content = new DOMParser().parseFromString(result.rows, 'text/html');
      const existing = new Set([...this.table.querySelectorAll('[data-catalog-key]')].map(row => row.dataset.catalogKey));
      for (const row of content.querySelectorAll('[data-catalog-key]')) if (!existing.has(row.dataset.catalogKey)) this.table.append(row);
      this.table.dataset.catalogEtag = result.etag || '';
      measure('catalog-prefetch-render', started);
      document.getElementById('catalog-more').outerHTML = result.more;
    }
  });
}
