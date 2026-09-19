# Lexery backend

Supabase (Postgres + Auth + Edge Functions) behind an offline-first app.
What lives here, and the rule for all of it: **the app never holds a
secret and never decides its own entitlements.** Premium comes from
RevenueCat through a webhook; AI calls go through functions that hold the
OpenAI key, own the prompts, enforce quotas and a global kill switch, and
never bill the same piece of work twice.

```
supabase/
  config.toml                 CLI config; per-function JWT settings
  migrations/                 schema, RLS, the quota functions (SQL)
  functions/
    _shared/                  http, supabase clients, OpenAI, RevenueCat, prompts
    ai-crossword-review/      POST — the crossword editorial pass
    ai-feature-clues/         POST — recall-game clues
    revenuecat-webhook/       POST — RevenueCat → entitlements
    entitlement-refresh/      POST — app asks for a fresh entitlement
    feedback/                 POST — bug reports (replaces tool/feedback/Code.gs)
    delete-account/           POST — in-app deletion + external requests
  web/delete-account.html     the public deletion-request page Google requires
  .env.example                function secrets
```

## Setup

Two hosted projects, **lexery-dev** and **lexery-prod**, on the same
Supabase org. Everything below is done once per project; the code is
identical, only the link and the secrets differ.

1. Install the CLI: `brew install supabase/tap/supabase`. (Docker is only
   needed for `supabase start`, the local stack; you can work entirely
   against the dev project without it.)
2. Create the project at supabase.com (region near you; Free plan is fine
   for dev, Pro for prod — Pro's 400 s function limit also matters for
   Mega crossword reviews, see below).
3. Link and push the schema:
   ```
   supabase login
   supabase link --project-ref <ref>
   supabase db push
   ```
4. Secrets: `cp supabase/.env.example supabase/.env`, fill it in, then
   `supabase secrets set --env-file supabase/.env`.
5. Deploy the functions: `supabase functions deploy` (all of them; add
   `--no-verify-jwt` for nothing — config.toml carries the per-function
   setting).
6. Smoke test:
   ```
   curl -s -X POST https://pnbenhthybmszavtonrj.supabase.co/functions/v1/feedback \
     -H "apikey: <anon key>" -H "Authorization: Bearer <anon key>" \
     -H "Content-Type: application/json" \
     -d '{"kind":"bug","message":"backend smoke test","app":{"version":"dev"}}'
   ```
   → `{"ok":true,"id":"…"}` and a row in `feedback`.

### Auth providers

Dashboard → Authentication → Providers:

- **Apple** — needs the Services ID, team id, key id and .p8 from the
  Apple developer account (required on iOS because Google sign-in is
  offered).
- **Google** — OAuth client ids for iOS, Android and web.
- **Email** — magic link. Keep confirmations off for the link flow.

Set *Site URL* / *Redirect URLs* to the app's deep link (`lexery://auth`
until decided; update config.toml to match).

### Email (sign-in mail)

Sign-in is by email: the mail carries a link back into the app
(`lexery://auth`) and, once the template in `templates/magic_link.html` is
active, a six-digit code as well. Two limits of the free tier's default
mail provider to know about:

- it **only delivers to members of the Supabase org** — fine for your own
  testing, useless for testers;
- it refuses custom templates, so the mail has the link but no code.

Both go away with custom SMTP. Without a domain, Gmail works: a Google
account with 2-step verification → an *App password* → Dashboard →
Project Settings → Authentication → SMTP: host `smtp.gmail.com`, port
`587`, user = the address, password = the app password, sender = the
address (500 mails/day). Then uncomment the `[auth.email.template.magic_link]`
block in `config.toml` and `supabase config push`. Move to Resend or
Postmark when there is a domain.

### RevenueCat

1. RevenueCat project with the App Store and Play apps; products mapped to
   one entitlement whose id is exactly `premium`
   (`_shared/revenuecat.ts` → `premiumEntitlementId`).
2. *Integrations → Webhooks*: URL
   `https://<ref>.supabase.co/functions/v1/revenuecat-webhook`,
   Authorization header value `Bearer <REVENUECAT_WEBHOOK_SECRET>`.
3. The app configures the RevenueCat SDK with the **Supabase user id** as
   the app user id at sign-in. That is the whole mapping: the webhook
   looks up entitlements by that id, and anonymous RevenueCat ids are
   ignored until the user signs in and the SDK aliases them.

### Feedback

Once deployed, point the app at it:
`--dart-define=FEEDBACK_ENDPOINT=https://<ref>.supabase.co/functions/v1/feedback`
(or set the default in `lib/services/feedback_config.dart`) and retire the
Apps Script relay. Attachments land in the private `feedback` bucket
under `<row id>/`. Reading reports: Table Editor → `feedback`, or a query
on `status = 'new'`. A daily "new reports" email is a Database Webhook
away when wanted.

### Account deletion

- **In app:** Settings → Account → Delete account → `delete-account` with
  the user's JWT. Cascades through every table.
- **Outside the app:** host `web/delete-account.html` (fill in the
  project URL and anon key at the bottom) and link it from the Play
  listing's Data safety section. Requests land in `deletion_requests`;
  confirm the address by email, then delete the user in the dashboard.

## AI functions: the contract

Both take the caller's Supabase JWT (`Authorization: Bearer <access
token>`) and answer:

| status | body | meaning |
|---|---|---|
| 200 | `{content, model, usage, cached, remaining}` | `content` is the model's JSON string, parsed by the app as before |
| 400 | `{error:"invalid_request"}` | |
| 401 | `{error:"unauthenticated"}` | sign in |
| 402 | `{error:"quota_exceeded", limit, premium, resets_at}` | the paywall's cue |
| 409 | `{error:"in_progress"}` | the same key is being worked on |
| 429 | `{error:"provider_unavailable"}` | provider rate limit; retry later |
| 503 | `{error:"ai_unavailable", reason}` / `provider_unavailable` | kill switch, global cap, or OpenAI down |

Requests:

- `ai-feature-clues` — `{headword, pos, gloss}`; key defaults to the
  word, so the same word is never billed twice.
- `ai-crossword-review` — `{puzzle_id, rendered, word_count}` where
  `rendered` is `renderForReview(puzzle)` from `editorial.dart` (the
  puzzle as data). Keyed by puzzle id.

What the server controls: the system prompts (`_shared/prompts.ts`), the
model per kind, reasoning effort, output-token caps, timeouts, per-user
daily limits by plan, a global daily request/cost cap and the kill
switch — all but the prompts live in `app_config` and change without a
deploy:

```sql
update app_config set value = 'false' where key = 'ai_enabled';   -- emergency stop
update app_config set value = '{"free":{"crossword_review":1,"feature_clues":30},"premium":{"crossword_review":12,"feature_clues":400}}' where key = 'ai_daily_limits';
```

Every call is a row in `ai_requests` with tokens and micro-dollar cost;
`ai_usage_daily` and `ai_global_daily` are the tallies the limits read.
A failed provider call is credited back. A retry with the same key
returns the stored answer.

**Timeouts.** Edge Functions are cut off at 150 s wall-clock on the Free
plan and 400 s on Pro. A Mega review at `low` effort measured ~25 s, and
the function caps its own deadline at 140 s; raise that in
`ai-crossword-review/index.ts` once prod is on Pro.

## The app side

`lib/app/environment.dart` selects the project with
`--dart-define=ENV=dev|prod` (dev is the default and is filled in; prod
waits on the lexery-prod project). The anon key is public by design; RLS
protects the data.

- **Sign-in:** `SupabaseAuthService` (`lib/services/auth_service.dart`),
  email link/code, Settings → Account. Apple/Google go in beside it when
  the developer accounts exist.
- **AI:** `AiGateway` (`lib/services/ai_gateway.dart`) adds the session
  token and speaks the contract above; `FeatureCluesService` and
  `CrosswordReviewService` use it whenever someone is signed in, and their
  old direct path (debug define / pasted key) otherwise.
- **Feedback:** `FeedbackService` posts to the `feedback` function with the
  user's token, or the anon key when signed out.
- **Keys:** the app initialises Supabase with the *legacy anon key*, not
  the newer publishable key, because the functions' gateway JWT check only
  accepts JWTs and signed-out calls (`feedback`, `delete-account`) carry the
  anon key. To move to publishable keys: set `verify_jwt = false` on those
  two functions (they validate the user themselves) and pass the
  publishable key as `apikey`.

### Verified against the dev project (2026-09-17)

`feedback` anonymous → row; admin-created user → `ai-feature-clues` →
real clues, ledger row with tokens and cost, repeat call `cached: true`
at no charge, anon-only call → 401, `app_config` invisible under RLS,
`delete-account` → 200 and every row for the user gone. Two bugs found
and fixed by that run: gpt-5-mini spent the whole 300-token cap on
reasoning and answered nothing (now `minimal` effort, a larger cap, and an
empty answer is a failure, never cached), and OpenAI's dated model names
("gpt-5-mini-2025-08-07") missed the price table (prefix match now).

## Local development

With Docker: `supabase start` brings up Postgres, Auth, Storage, the
function runtime and Studio on http://127.0.0.1:54323; `supabase functions
serve --env-file supabase/.env` runs the functions with hot reload. The
migration applies on start.

Without Docker: type-check with `deno check functions/*/index.ts`, unit
tests with `deno test functions/_shared`. The SQL is only exercised by
`db push` against the dev project.

## Compatibility rule

Migrations are additive: add columns and tables, never rename or drop
what a shipped app version reads. A function keeps accepting every
request shape it ever accepted.
