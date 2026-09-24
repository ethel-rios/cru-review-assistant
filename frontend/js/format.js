// Text helpers: escaping, times, and a small Markdown renderer that turns
// citations like [Call 7 · 1:15] and [Txn 8] into clickable chips.

export const esc = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export const clock = (sec) => {
  const s = Math.floor(sec || 0);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

export const shortDate = (iso) => (iso ? iso.slice(0, 16).replace("T", " ") : "");

function inline(text) {
  return esc(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])_([^_]+)_(?=$|[\s).,:;])/g, "$1<em>$2</em>")
    .replace(/\[Call (\d+)\s*[·•|-]\s*(\d+):(\d{2})\]/g, (_, call, m, s) =>
      `<button type="button" class="cite" data-call="${call}" data-sec="${Number(m) * 60 + Number(s)}">Call ${call} · ${m}:${s}</button>`)
    .replace(/\[Txn (\d+)\]/g, (_, id) => `<button type="button" class="cite cite-txn" data-txn="${id}">Txn ${id}</button>`);
}

export function renderMarkdown(text) {
  const html = [];
  let paragraph = [];
  let list = null; // { tag, items }

  const flushParagraph = () => {
    if (paragraph.length) html.push(`<p>${inline(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (list) html.push(`<${list.tag}>${list.items.map((i) => `<li>${inline(i)}</li>`).join("")}</${list.tag}>`);
    list = null;
  };

  for (const raw of String(text).split("\n")) {
    const line = raw.trimEnd();
    const bullet = line.match(/^\s*[-*]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
    if (bullet || numbered) {
      flushParagraph();
      const tag = bullet ? "ul" : "ol";
      if (list && list.tag !== tag) flushList();
      list ??= { tag, items: [] };
      list.items.push((bullet || numbered)[1]);
      continue;
    }
    flushList();
    const heading = line.match(/^#{1,4}\s+(.*)$/);
    if (heading) {
      flushParagraph();
      html.push(`<h4>${inline(heading[1])}</h4>`);
    } else if (!line.trim()) {
      flushParagraph();
    } else {
      paragraph.push(line);
    }
  }
  flushParagraph();
  flushList();
  return html.join("");
}
