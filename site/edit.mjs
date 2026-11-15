// Live wording editor for the site. Serves public/ with an editing layer on top and
// writes edits straight back into public/*.html — review them with `git diff`.
// Run: node edit.mjs   then open http://localhost:4321  (PORT=… to change)
// Nothing here is deployed: wrangler only uploads public/.
import http from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const PUB = path.join(here, "public");
const PORT = Number(process.env.PORT) || 4321;

const PAGES = { "index.html": "Landing page", "delete-account.html": "Delete account" };
// Rendered by build-legal.mjs, so edits here would be overwritten.
const GENERATED = { "privacy.html": "docs/PRIVACY_POLICY.md", "terms.html": "docs/TERMS.md" };
const META_LABELS = {
  description: "Search description (meta description)",
  "og:title": "Share title (og:title)",
  "og:description": "Share description (og:description)",
  "twitter:title": "Twitter title",
  "twitter:description": "Twitter description",
};
const TYPES = {
  ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript",
  ".png": "image/png", ".ico": "image/x-icon", ".svg": "image/svg+xml",
  ".webmanifest": "application/manifest+json", ".json": "application/json",
};

// Finds every piece of wording in a page and where it sits in the source:
//   texts — body text runs, in the order the browser builds them as DOM text nodes
//           (stops at the first body <script>, where the editor is injected)
//   meta  — <title> and the description / share-card meta tags
//   js    — prose-looking string literals in inline scripts (captions, definitions)
function scan(src) {
  const texts = [], meta = [], js = [];
  const tag = /<!--[\s\S]*?-->|<![^>]*>|<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g;
  let pos = 0, inBody = false, svg = 0, inject = -1, m;
  const lower = src.toLowerCase();
  const onText = (s, e) => {
    if (inBody && !svg && inject < 0 && /[^ \t\n\r\f]/.test(src.slice(s, e))) texts.push({ start: s, end: e });
  };
  while ((m = tag.exec(src))) {
    if (m.index > pos) onText(pos, m.index);
    pos = tag.lastIndex;
    const [, close, rawName, attrs = ""] = m;
    if (!rawName) continue;
    const name = rawName.toLowerCase();
    if (close) { if (name === "svg" && svg) svg--; continue; }
    if (name === "body") inBody = true;
    if (name === "svg" && !/\/\s*$/.test(attrs)) svg++;
    if (name === "meta") metaSlot(m.index + 1 + rawName.length, attrs, meta);
    if (["script", "style", "textarea", "title", "noscript"].includes(name)) {
      let end = lower.indexOf("</" + name, pos);
      if (end < 0) end = src.length;
      if (name === "script" && inBody && inject < 0) inject = m.index;
      if (name === "script" && !/\bsrc\s*=/i.test(attrs)) jsSlots(src, pos, end, js);
      if (name === "title" && !inBody && !svg) meta.unshift({ label: "Page title (browser tab)", start: pos, end, q: "" });
      pos = tag.lastIndex = end;
    }
  }
  if (inject < 0) inject = lower.lastIndexOf("</body>");
  if (inject < 0) inject = src.length;
  return { texts, meta, js, inject };
}

function metaSlot(attrsAt, attrs, out) {
  const a = {};
  for (const am of attrs.matchAll(/([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)')/g)) {
    const q = am[2][0], at = attrsAt + am.index + am[0].length - am[2].length + 1;
    a[am[1].toLowerCase()] = { value: am[3] ?? am[4], start: at, end: at + (am[3] ?? am[4]).length, q };
  }
  const key = (a.name || a.property)?.value;
  if (key in META_LABELS && a.content) out.push({ label: META_LABELS[key], start: a.content.start, end: a.content.end, q: a.content.q });
}

function jsSlots(src, from, to, out) {
  for (let i = from; i < to;) {
    const c = src[i];
    if (c === "/" && src[i + 1] === "/") { const nl = src.indexOf("\n", i); i = nl < 0 || nl > to ? to : nl; continue; }
    if (c === "/" && src[i + 1] === "*") { const e = src.indexOf("*/", i + 2); i = e < 0 ? to : e + 2; continue; }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < to && src[j] !== c && (c === "`" || src[j] !== "\n")) j += src[j] === "\\" ? 2 : 1;
      const raw = src.slice(i + 1, j);
      if (c !== "`" && raw.length >= 12 && /[A-Za-z]{3,} [A-Za-z]{2,}/.test(raw.replace(/<[^>]*>/g, ""))) {
        const before = src.slice(from, i);
        const near = [...before.matchAll(/\b(?:const|let|var|function)\s+(\w+)/g)].pop()?.[1];
        const owner = near && /^[A-Z_]+$/.test(near) ? near : "Messages";
        const key = before.slice(before.lastIndexOf("\n") + 1).match(/(\w+)\s*:\s*$/)?.[1];
        const line = src.slice(0, i).split("\n").length;
        out.push({ label: `${owner}${key ? " · " + key : ""} (line ${line})`, start: i + 1, end: j, q: c });
      }
      i = j + 1;
      continue;
    }
    i++;
  }
}

const slotsFor = (src) => {
  const { texts, meta, js } = scan(src);
  const raw = (list) => list.map((s) => ({ ...s, raw: src.slice(s.start, s.end) }));
  return { texts: texts.map((s) => src.slice(s.start, s.end)), meta: raw(meta), js: raw(js) };
};

const VALID = {
  texts: (raw) => !raw.includes("<"),
  meta: (raw, q) => !raw.includes("<") && (q ? !raw.includes(q) : true),
  js: (raw, q) => new RegExp(`^(?:[^\\\\${q}\\n]|\\\\.)*$`).test(raw),
};

async function save(body) {
  const { page, edits } = body;
  if (!(page in PAGES)) throw new Error(`${page} isn't editable here`);
  const file = path.join(PUB, page);
  const src = await readFile(file, "utf8");
  const sc = scan(src);
  const patches = edits.map((e) => {
    const slot = sc[e.kind]?.[e.index];
    if (!slot) throw new Error(`No ${e.kind} #${e.index} in ${page}`);
    if (src.slice(slot.start, slot.end) !== e.old) throw new Error(`${page} changed on disk since this preview loaded — reload and redo that edit`);
    if (!VALID[e.kind](e.raw, slot.q)) throw new Error(`Rejected ${e.kind} edit: ${JSON.stringify(e.raw).slice(0, 80)}`);
    return { ...slot, raw: e.raw };
  });
  let out = src;
  for (const p of patches.sort((a, b) => b.start - a.start)) out = out.slice(0, p.start) + p.raw + out.slice(p.end);
  await writeFile(file, out);
  return { ok: true, saved: patches.length };
}

async function servePage(res, page) {
  const src = await readFile(path.join(PUB, page), "utf8");
  const ww = {
    page, pages: PAGES,
    editable: page in PAGES,
    note: GENERATED[page] ? `This page is generated from ${GENERATED[page]} — edit that file and run node build-legal.mjs.` : "",
    ...slotsFor(src),
  };
  const { inject } = scan(src);
  const data = JSON.stringify(ww).replace(/</g, "\\u003c");
  const tags = `<script>window.__WW=${data}</script><script src="/__ww/client.js"></script>\n`;
  res.writeHead(200, { "content-type": TYPES[".html"], "cache-control": "no-store" });
  res.end(src.slice(0, inject) + tags + src.slice(inject));
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    if (req.method === "POST" && url.pathname === "/__ww/save") {
      let body = "";
      for await (const chunk of req) body += chunk;
      const result = await save(JSON.parse(body)).catch((e) => ({ ok: false, error: e.message }));
      res.writeHead(result.ok ? 200 : 409, { "content-type": "application/json" });
      return res.end(JSON.stringify(result));
    }
    if (url.pathname === "/__ww/client.js") {
      res.writeHead(200, { "content-type": TYPES[".js"], "cache-control": "no-store" });
      return res.end(await readFile(path.join(here, "edit-client.js")));
    }
    let rel = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "index.html";
    if (!path.extname(rel)) rel += ".html";
    const file = path.join(PUB, rel);
    if (!file.startsWith(PUB + path.sep)) { res.writeHead(403); return res.end(); }
    if (rel.endsWith(".html")) return await servePage(res, rel);
    const buf = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[path.extname(rel)] || "application/octet-stream" });
    res.end(buf);
  } catch (e) {
    res.writeHead(e.code === "ENOENT" ? 404 : 500, { "content-type": "text/plain" });
    res.end(e.code === "ENOENT" ? "Not found" : String(e.stack || e));
  }
}).listen(PORT, "127.0.0.1", () => console.log(`Word Wizard site editor → http://localhost:${PORT}`));
