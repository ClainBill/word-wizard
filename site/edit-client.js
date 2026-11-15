// In-page editor, injected by edit.mjs just ahead of the page's own scripts so it can
// snapshot the static text before any demo rewrites it. Each DOM text node is matched to
// its run in the source (window.__WW.texts); saving patches only those runs.
(() => {
  const WW = window.__WW;
  const SVG = "http://www.w3.org/2000/svg";
  const SKIP = new Set(["SCRIPT", "STYLE", "TEXTAREA", "NOSCRIPT", "TEMPLATE"]);
  const hasText = (s) => /[^ \t\n\r\f]/.test(s);
  const skipped = (n, top) => {
    for (let p = n.parentNode; p && p !== top; p = p.parentNode) if (SKIP.has(p.nodeName) || p.namespaceURI === SVG) return true;
    return false;
  };
  const textNodes = (root) => {
    const out = [], tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n; (n = tw.nextNode());) if (hasText(n.data) && !skipped(n, root)) out.push(n);
    return out;
  };

  // ---- 1. Snapshot, synchronously, before the page script runs ----
  const snap = textNodes(document.body).map((node) => ({ node, orig: node.data }));
  const ta = document.createElement("textarea");
  const decode = (raw) => { ta.innerHTML = raw; return ta.value; };
  const mapped = WW.editable && snap.length === WW.texts.length;
  const runs = mapped ? snap.map((s, i) => ({ ...s, i, raw: WW.texts[i] })).filter((r) => decode(r.raw) === r.orig) : [];
  const runOf = new Map(runs.map((r) => [r.node, r]));

  // Re-encode an edited value, keeping the source's own entities wherever the text didn't change.
  const UNIT = /&(?:#\d+|#x[\da-f]+|[a-z][a-z\d]*);|[\s\S]/giu;
  function reencode(raw, value, esc) {
    const units = raw.match(UNIT) || [], dec = units.map(decode);
    let a = 0, pre = "";
    while (a < units.length && value.startsWith(pre + dec[a])) pre += dec[a++];
    let b = units.length, suf = "";
    while (b > a && value.length - pre.length >= suf.length + dec[b - 1].length && value.endsWith(dec[b - 1] + suf)) suf = dec[--b] + suf;
    return units.slice(0, a).join("") + esc(value.slice(pre.length, value.length - suf.length)) + units.slice(b).join("");
  }
  const escText = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;");
  const escAttr = (q) => (s) => escText(s).replace(q === "'" ? /'/g : /"/g, q === "'" ? "&#39;" : "&quot;");
  const escJs = (q) => (s) => s.replace(/\r?\n/g, " ").replace(new RegExp(`(^|[^\\\\])${q}`, "g"), `$1\\${q}`).replace(new RegExp(`(^|[^\\\\])${q}`, "g"), `$1\\${q}`);
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

  // ---- 2. Once the page has built itself, mark the static text as editable ----
  let editing = true, hosts = [];
  const panel = { meta: new Map(), js: new Map() }; // index → edited value
  const depth = (el) => { let d = 0; for (; el; el = el.parentElement) d++; return d; };

  function setupHosts() {
    const good = new Set(runs.filter((r) => r.node.isConnected && r.node.data === r.orig).map((r) => r.node));
    const cands = [...new Set([...good].map((n) => n.parentElement))].sort((x, y) => depth(x) - depth(y));
    for (const el of cands) {
      if (el.parentElement.closest("[data-ww-host]")) continue;
      if (!textNodes(el).every((n) => good.has(n))) continue; // a demo rewrites part of it
      el.setAttribute("data-ww-host", "");
      hosts.push(el);
      for (const n of textNodes(el)) runOf.get(n).host = el;
    }
    // Demos that rewrite their text later (search captions, flashcards) lose editability.
    new MutationObserver((recs) => {
      if (userEdit) return;
      for (const rec of recs) {
        const el = rec.target.nodeType === 1 ? rec.target : rec.target.parentElement;
        const h = el?.closest("[data-ww-host]");
        if (h) dropHost(h);
      }
    }).observe(document.body, { childList: true, characterData: true, subtree: true });
    setEditing(editing);
  }
  function dropHost(h) {
    h.removeAttribute("contenteditable"); h.removeAttribute("data-ww-host"); h.removeAttribute("data-ww-dirty");
    hosts = hosts.filter((x) => x !== h);
    for (const r of runs) if (r.host === h) r.host = null;
    ui.render();
  }
  // true while a change comes from you typing rather than from a page script
  let userEdit = false;
  const asUser = () => { userEdit = true; setTimeout(() => (userEdit = false)); };

  function setEditing(on) {
    editing = on;
    document.documentElement.classList.toggle("ww-on", on);
    for (const h of hosts) on ? h.setAttribute("contenteditable", "plaintext-only") : h.removeAttribute("contenteditable");
    ui.render();
  }

  // ---- 3. Keep edits inside the original text runs ----
  const inHost = (e) => editing && e.target instanceof Element && e.target.closest("[data-ww-host]");
  // stop demos, links and buttons reacting while you're editing their words
  for (const type of ["click", "keydown", "keyup", "keypress", "pointerdown", "mousedown"]) {
    window.addEventListener(type, (e) => {
      if (!inHost(e)) return;
      if (type === "keydown" && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") return;
      e.stopPropagation();
      if (type === "click") e.preventDefault();
    }, true);
  }
  window.addEventListener("submit", (e) => { if (editing) e.preventDefault(); }, true);
  document.addEventListener("beforeinput", (e) => {
    if (!inHost(e)) return;
    asUser();
    const t = e.inputType;
    if (t === "insertParagraph" || t === "insertLineBreak" || t.startsWith("format") || t === "insertFromDrop" || t === "deleteByDrag") {
      e.preventDefault();
      if (t !== "insertFromDrop") ui.hint("Line breaks and formatting can't be added here — just the words.");
      return;
    }
    if (e.getTargetRanges().some((r) => !r.collapsed && r.startContainer !== r.endContainer)) {
      e.preventDefault();
      ui.hint("That selection crosses italics, bold or a link. Edit each piece separately.");
    }
  }, true);
  document.addEventListener("paste", (e) => {
    if (!inHost(e)) return;
    e.preventDefault();
    asUser();
    document.execCommand("insertText", false, e.clipboardData.getData("text/plain").replace(/\s*\n\s*/g, " "));
  }, true);
  document.addEventListener("input", (e) => {
    const h = inHost(e);
    if (h) { markDirty(h); ui.render(); }
  }, true);

  const valueOf = (r) => (r.node.isConnected ? r.node.data : r.host.isConnected ? "" : null);
  function markDirty(h) {
    h.toggleAttribute("data-ww-dirty", runs.some((r) => r.host === h && valueOf(r) !== r.orig));
  }

  function collect() {
    const edits = [], stray = [];
    for (const r of runs) {
      if (!r.host) continue;
      const v = valueOf(r);
      if (v === null || v === r.orig) continue;
      edits.push({ kind: "texts", index: r.i, old: r.raw, raw: reencode(r.raw, v, escText), before: r.orig, after: v, run: r });
    }
    for (const h of hosts) for (const n of textNodes(h)) if (!runOf.has(n)) stray.push(n.data.trim());
    for (const kind of ["meta", "js"]) {
      for (const [i, v] of panel[kind]) {
        const s = WW[kind][i];
        const before = kind === "meta" ? decode(s.raw) : s.raw;
        if (v === before) continue;
        const raw = kind === "meta" ? reencode(s.raw, v, s.q ? escAttr(s.q) : esc) : escJs(s.q)(v);
        edits.push({ kind, index: i, old: s.raw, raw, before, after: v, label: s.label });
      }
    }
    return { edits, stray };
  }

  function undo(edit) {
    if (edit.run) {
      const r = edit.run;
      asUser();
      if (r.node.isConnected) r.node.data = r.orig; else ui.hint("That piece was deleted outright — use Discard all, or retype it.");
      markDirty(r.host);
    } else panel[edit.kind].delete(edit.index);
    ui.render(true);
  }

  async function save() {
    const { edits } = collect();
    if (!edits.length) return ui.hint("Nothing to save yet.");
    ui.busy(true);
    try {
      const res = await fetch("/__ww/save", {
        method: "POST",
        body: JSON.stringify({ page: WW.page, edits: edits.map(({ kind, index, old, raw }) => ({ kind, index, old, raw })) }),
      });
      const out = await res.json();
      if (!out.ok) throw new Error(out.error);
      try { sessionStorage.setItem("ww-scroll", JSON.stringify([WW.page, scrollY, ui.drawerTab()])); } catch {}
      dirtyGuard = false;
      location.reload();
    } catch (err) {
      ui.busy(false);
      ui.hint("Save failed: " + err.message, 8000);
    }
  }
  let dirtyGuard = true;
  window.addEventListener("beforeunload", (e) => { if (dirtyGuard && collect().edits.length) e.preventDefault(); });
  window.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") { e.preventDefault(); save(); }
    if (e.key === "Escape" && inHost(e)) e.target.closest("[data-ww-host]").blur();
  }, true);

  // ---- 4. Toolbar + drawer, in a shadow root so the site's CSS can't reach it ----
  const ui = (() => {
    const css = document.createElement("style");
    css.textContent = `
      html.ww-on [data-ww-host] { cursor: text; outline: 1px dashed transparent; outline-offset: 3px; border-radius: 2px; transition: outline-color .15s; }
      html.ww-on [data-ww-host]:hover { outline-color: rgba(138, 90, 34, .55); }
      html.ww-on [data-ww-host]:focus { outline: 2px solid #8A5A22; }
      [data-ww-dirty] { background-color: rgba(240, 180, 40, .28) !important; box-shadow: 0 0 0 2px rgba(240, 180, 40, .55) !important; }
      html { scroll-padding-bottom: 90px; }
      body { padding-bottom: 80px !important; }`;
    document.head.appendChild(css);

    const host = document.createElement("ww-editor");
    const root = host.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>
        :host { all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;
          font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; color: #F3F1E8; }
        * { box-sizing: border-box; }
        button, select { font: inherit; color: inherit; }
        .bar { pointer-events: auto; position: absolute; right: 12px; bottom: 12px;
          display: flex; align-items: center; gap: 6px; padding: 6px; max-width: calc(100vw - 24px);
          background: #1C211B; border: 1px solid #39413A; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,.35); }
        .brand { padding: 0 8px 0 6px; font-weight: 600; letter-spacing: .01em; white-space: nowrap; color: #D9B77E; }
        .btn, select { background: #2A3129; border: 1px solid #3F483F; border-radius: 8px; padding: 6px 10px; cursor: pointer; white-space: nowrap; }
        .btn:hover, select:hover { background: #343C33; }
        .btn[aria-pressed="true"] { background: #35604F; border-color: #4B7A67; }
        .btn.save { background: #8A5A22; border-color: #A6702F; font-weight: 600; }
        .btn.save:disabled { opacity: .45; cursor: default; }
        .count { min-width: 1.6em; display: inline-block; text-align: center; padding: 0 5px; margin-left: 4px; border-radius: 99px; background: rgba(255,255,255,.14); font-variant-numeric: tabular-nums; }
        .hint { pointer-events: none; position: absolute; right: 12px; bottom: 70px; max-width: min(560px, calc(100vw - 24px));
          background: #F3F1E8; color: #1C211B; padding: 8px 12px; border-radius: 8px; box-shadow: 0 6px 20px rgba(0,0,0,.25); opacity: 0; transition: opacity .2s; }
        .hint.show { opacity: 1; }
        .drawer { pointer-events: auto; position: absolute; top: 12px; right: 12px; bottom: 70px; width: min(420px, calc(100vw - 24px));
          display: none; flex-direction: column; background: #1C211B; border: 1px solid #39413A; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,.35); overflow: hidden; }
        .drawer.open { display: flex; }
        .tabs { display: flex; gap: 4px; padding: 8px; border-bottom: 1px solid #39413A; }
        .tabs .btn { flex: 1; }
        .body { overflow: auto; padding: 10px 12px 16px; }
        .note { color: #B9BDB2; margin: 4px 0 12px; }
        .warn { background: #4A3A1A; border: 1px solid #7A5E2A; color: #F3E3C0; border-radius: 8px; padding: 8px 10px; margin-bottom: 12px; }
        h4 { margin: 14px 0 6px; font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: #9AA197; font-weight: 600; }
        label { display: block; margin: 10px 0 4px; color: #C9CCBE; }
        textarea { width: 100%; min-height: 54px; resize: vertical; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
          color: #F3F1E8; background: #121611; border: 1px solid #3F483F; border-radius: 8px; padding: 7px 9px; }
        textarea.changed { border-color: #D9A441; box-shadow: 0 0 0 1px #D9A441; }
        .chg { border: 1px solid #39413A; border-radius: 8px; padding: 8px 10px; margin-bottom: 8px; }
        .chg .where { color: #9AA197; font-size: 11px; display: flex; justify-content: space-between; align-items: center; gap: 8px; }
        .chg .btn { padding: 2px 8px; font-size: 12px; }
        del { color: #E7A08F; text-decoration-color: rgba(231,160,143,.6); }
        ins { color: #A9DBB9; text-decoration: none; }
        .diff { margin-top: 4px; white-space: pre-wrap; word-break: break-word; }
        .empty { color: #9AA197; padding: 20px 0; text-align: center; }
        @media (max-width: 640px) { .brand { display: none; } }
      </style>
      <div class="drawer" part="drawer">
        <div class="tabs">
          <button class="btn" data-tab="changes">Changes</button>
          <button class="btn" data-tab="meta">Title &amp; meta</button>
          <button class="btn" data-tab="js">Demo text</button>
        </div>
        <div class="body"></div>
      </div>
      <div class="hint"></div>
      <div class="bar">
        <span class="brand">✎ Wording editor</span>
        <select class="page" title="Page"></select>
        <button class="btn edit" aria-pressed="true" title="Turn off to use the interactive demos">Editing</button>
        <button class="btn more" aria-pressed="false">Panel</button>
        <button class="btn discard" title="Throw away unsaved edits">Discard</button>
        <button class="btn save" title="Write changes to site/public (⌘S)">Save<span class="count">0</span></button>
      </div>`;
    const $ = (s) => root.querySelector(s);
    let tab = "changes", hintTimer;

    const sel = $(".page");
    for (const [file, label] of Object.entries({ ...WW.pages, "privacy.html": "Privacy (generated)", "terms.html": "Terms (generated)" })) {
      sel.add(new Option(label, file, false, file === WW.page));
    }
    sel.onchange = () => { location.href = "/" + (sel.value === "index.html" ? "" : sel.value.replace(/\.html$/, "")); };
    $(".edit").onclick = () => setEditing(!editing);
    $(".more").onclick = () => { $(".drawer").classList.toggle("open"); render(true); };
    $(".discard").onclick = () => { if (collect().edits.length) { dirtyGuard = false; location.reload(); } };
    $(".save").onclick = save;
    root.querySelectorAll("[data-tab]").forEach((b) => (b.onclick = () => { tab = b.dataset.tab; render(true); }));

    const diffHtml = (a, b) => {
      let p = 0; while (p < a.length && p < b.length && a[p] === b[p]) p++;
      let s = 0; while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++;
      const ctx = (t, fromEnd) => { t = t.replace(/\s+/g, " "); return fromEnd ? (t.length > 60 ? "…" + t.slice(-60) : t) : t.length > 60 ? t.slice(0, 60) + "…" : t; };
      return esc(ctx(a.slice(0, p), true)) + (a.slice(p, a.length - s) ? `<del>${esc(a.slice(p, a.length - s))}</del>` : "") +
        (b.slice(p, b.length - s) ? `<ins>${esc(b.slice(p, b.length - s))}</ins>` : "") + esc(ctx(a.slice(a.length - s), false));
    };

    function fieldList(kind) {
      const items = WW[kind];
      if (!items.length) return `<div class="empty">None on this page.</div>`;
      const intro = kind === "meta"
        ? `<p class="note">Not visible on the page — this is what shows in the browser tab, search results and link previews.</p>`
        : `<p class="note">Wording that lives in the page's script: animated captions, flashcard and dictionary entries. Raw JavaScript strings, so <code>&lt;em&gt;</code> tags are fine. Shows on the page after you save.</p>`;
      let group = "";
      return intro + items.map((s, i) => {
        const shown = kind === "meta" ? decode(s.raw) : s.raw;
        const v = panel[kind].has(i) ? panel[kind].get(i) : shown;
        const g = kind === "js" ? s.label.split(" ")[0] : "";
        const head = g && g !== group ? `<h4>${esc((group = g))}</h4>` : "";
        return `${head}<label>${esc(kind === "js" ? s.label.slice(g.length).replace(/^ · /, "") || "text" : s.label)}</label>
          <textarea data-kind="${kind}" data-i="${i}" class="${v !== shown ? "changed" : ""}" rows="${Math.min(6, Math.ceil(v.length / 48) + 1)}">${esc(v)}</textarea>`;
      }).join("");
    }

    function render(full) {
      const { edits, stray } = collect();
      $(".count").textContent = edits.length;
      $(".save").disabled = !edits.length;
      $(".edit").setAttribute("aria-pressed", editing);
      $(".edit").textContent = editing ? "Editing" : "Editing off";
      $(".more").setAttribute("aria-pressed", $(".drawer").classList.contains("open"));
      root.querySelectorAll("[data-tab]").forEach((b) => b.setAttribute("aria-pressed", b.dataset.tab === tab));
      if (!$(".drawer").classList.contains("open")) return;
      if (!full && tab !== "changes") return; // don't rebuild textareas while typing in them
      const body = $(".body");
      let html = "";
      if (tab === "changes") {
        if (WW.note) html += `<div class="warn">${esc(WW.note)}</div>`;
        else if (!mapped) html += `<div class="warn">Couldn't line up the page text with the source (${snap.length} vs ${WW.texts.length} runs), so inline editing is off. The panel tabs still work.</div>`;
        if (stray.length) html += `<div class="warn">Some typed text landed outside the original wording and won't be saved: “${esc(stray.join("”, “").slice(0, 120))}”. Undo it and retype inside the existing words.</div>`;
        html += edits.length
          ? edits.map((e, k) => `<div class="chg"><div class="where"><span>${esc(e.label || (e.run.host.closest("section, header, footer, main")?.querySelector("h1, h2, h3")?.textContent.trim().slice(0, 50) || "Page text"))}</span><button class="btn" data-undo="${k}">Undo</button></div>
              <div class="diff">${diffHtml(e.before, e.after)}</div></div>`).join("")
          : `<div class="empty">No unsaved changes. Click any text on the page to edit it.</div>`;
        const hidden = runs.filter((r) => r.host && !r.host.getClientRects().length);
        if (hidden.length) {
          html += `<h4>Hidden on screen right now</h4><p class="note">Messages the page only shows in certain states.</p>` +
            hidden.map((r) => `<textarea data-run="${r.i}" rows="${Math.min(6, Math.ceil(r.node.data.length / 48) + 1)}">${esc(r.node.data.trim())}</textarea>`).join("");
        }
      } else html = fieldList(tab);
      body.innerHTML = html;
      body.querySelectorAll("[data-undo]").forEach((b) => (b.onclick = () => undo(edits[+b.dataset.undo])));
      body.querySelectorAll("textarea[data-kind]").forEach((t) => (t.oninput = () => {
        panel[t.dataset.kind].set(+t.dataset.i, t.value);
        const s = WW[t.dataset.kind][+t.dataset.i];
        t.classList.toggle("changed", t.value !== (t.dataset.kind === "meta" ? decode(s.raw) : s.raw));
        render();
      }));
      body.querySelectorAll("textarea[data-run]").forEach((t) => (t.oninput = () => {
        const r = runs.find((x) => x.i === +t.dataset.run);
        asUser();
        const lead = r.orig.match(/^\s*/)[0], trail = r.orig.match(/\s*$/)[0];
        r.node.data = lead + t.value.replace(/\s*\n\s*/g, " ") + trail;
        markDirty(r.host);
        $(".count").textContent = collect().edits.length;
        $(".save").disabled = false;
      }));
    }

    function hint(msg, ms = 3500) {
      const h = $(".hint");
      h.textContent = msg; h.classList.add("show");
      clearTimeout(hintTimer); hintTimer = setTimeout(() => h.classList.remove("show"), ms);
    }

    document.addEventListener("DOMContentLoaded", () => document.documentElement.appendChild(host));
    return {
      render, hint,
      busy: (b) => { $(".save").disabled = b; $(".save").firstChild.textContent = b ? "Saving…" : "Save"; },
      drawerTab: () => ($(".drawer").classList.contains("open") ? tab : null),
      open: (t) => { if (t) { tab = t; $(".drawer").classList.add("open"); } render(true); },
    };
  })();

  document.addEventListener("DOMContentLoaded", () => {
    setupHosts();
    let restore = null;
    try { restore = JSON.parse(sessionStorage.getItem("ww-scroll")); sessionStorage.removeItem("ww-scroll"); } catch {}
    if (restore && restore[0] === WW.page) {
      requestAnimationFrame(() => scrollTo(0, restore[1]));
      ui.open(restore[2]);
      ui.hint("Saved to site/public/" + WW.page);
    } else if (WW.note || !mapped) ui.open("changes");
  });
})();
