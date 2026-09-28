// Renders docs/PRIVACY_POLICY.md and docs/TERMS.md into public/privacy.html
// and public/terms.html, sharing the landing page's palette and fonts.
// Run: node build-legal.mjs   (uses marked via npx: `npx marked` must resolve)
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const pages = [
  { src: "../docs/PRIVACY_POLICY.md", out: "public/privacy.html", title: "Privacy policy" },
  { src: "../docs/TERMS.md", out: "public/terms.html", title: "Terms of use" },
];

const shell = (title, body) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} — Word Wizard</title>
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/favicon-96.png" type="image/png" sizes="96x96">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,300..700&family=Newsreader:ital,opsz,wght@0,6..72,400..600;1,6..72,400..600&family=Instrument+Sans:wght@400;500;600&display=swap">
<link rel="stylesheet" href="/legal.css">
</head>
<body>
<header class="top"><a class="brand" href="/">← Word Wizard</a></header>
<main class="doc">
${body}
</main>
<footer class="foot"><a href="/privacy">Privacy policy</a> · <a href="/terms">Terms of use</a> · <a href="/delete-account">Delete your account</a></footer>
</body>
</html>
`;

for (const p of pages) {
  let md = readFileSync(p.src, "utf8");
  // Drop the author-facing "Draft" note (a leading blockquote after the H1).
  md = md.replace(/^(# .*\n)\n(?:>.*\n)+/m, "$1");
  const html = execFileSync("npx", ["--yes", "marked", "--gfm"], { input: md, encoding: "utf8" });
  const marked = html.replace("<p><em>Last updated:", '<p class="updated"><em>Last updated:');
  writeFileSync(p.out, shell(p.title, marked));
  console.log("wrote", p.out);
}
