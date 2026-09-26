const patterns = {
  yaml: /(?<comment>#[^\n]*)|(?<property>^\s*(?:-\s+)?(?:[\w.-]+|'(?:''|[^'])*'|"(?:\\.|[^"\\])*")(?=\s*:))|(?<string>'(?:''|[^'])*'|"(?:\\.|[^"\\])*")|(?<number>-?\b\d+(?:\.\d+)?\b)|(?<keyword>\b(?:true|false|null|yes|no)\b|[>|]-?)/gim,
  csv: /(?<property>^[^\n]+(?=\n))|(?<string>"(?:[^"]|"")*")|(?<number>-?\b\d+(?:\.\d+)?\b)|(?<operator>,)/g
};

const escapeHtml = (value) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

export function highlightFormatPreview(source, language) {
  const pattern = patterns[language];
  if (!pattern) return null;
  pattern.lastIndex = 0;
  let result = "";
  let cursor = 0;
  for (const match of source.matchAll(pattern)) {
    const type = Object.keys(match.groups).find((name) => match.groups[name] !== undefined);
    result += escapeHtml(source.slice(cursor, match.index));
    result += `<span class="se-token--${type}">${escapeHtml(match[0])}</span>`;
    cursor = match.index + match[0].length;
  }
  return result + escapeHtml(source.slice(cursor));
}

export function registerFormatPreview(application, Controller) {
  application.register("format-preview", class extends Controller {
    async connect() {
      await customElements.whenDefined("se-code-editor");
      const highlighted = highlightFormatPreview(this.element.getAttribute("value") || "", this.element.getAttribute("language"));
      if (highlighted) this.element.querySelector(".se-editor__highlight code").innerHTML = highlighted;
    }
  });
}
