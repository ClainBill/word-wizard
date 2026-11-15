# Word Wizard site

Static pages served from Cloudflare Workers at https://wordwizard.wcgill.com.

- `public/index.html` — landing page (originally `design-explorations/site/word-wizard.html`).
- `public/privacy.html`, `public/terms.html` — rendered from `docs/PRIVACY_POLICY.md` and `docs/TERMS.md` by `node build-legal.mjs` (drops the author-facing draft note). Re-run after editing the docs.
- `public/delete-account.html` — the account-deletion request page Google Play requires; points at the Supabase project in `lib/app/environment.dart` (dev until prod exists).
- `public/legal.css` — shared styling for the above.
- `wrangler.jsonc` — Worker `wordwizard-site`, custom domain `wordwizard.wcgill.com` on the `wcgill.com` zone.

URLs: `/`, `/privacy`, `/terms`, `/delete-account`.

Editing the wording: `node edit.mjs`, then open http://localhost:4321. Click any text on the page to change it; the Panel button covers the page title, share-card text and the demos' scripted captions. Save (⌘S) writes straight into `public/*.html` — check with `git diff`, then deploy as below. `edit.mjs` and `edit-client.js` stay local; wrangler only uploads `public/`.

Deploy:

```sh
cd site
npx wrangler login   # once
node build-legal.mjs # if the legal docs changed
npx wrangler deploy
```
