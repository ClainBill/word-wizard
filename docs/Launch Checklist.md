1. Decide the launch offering

 - [x] Finalise the app name and check app-store, domain, and trademark conflicts.
  Word Wizard (decided 2026-09-20, back from "Lexery": more marketable, works in adverts and the logo). "Lexery" stays as the name of the store of words you're studying and know — "Add to Lexery", "In Lexery".
 - [ ] Finalise the icon/logo
 - [x] Define exactly what is free and what premium unlocks.
  Per *Premium Offers Implementation Specification* (19 Sept 2026): free = dictionary, Reader, lists, SRS flashcards (plain flip, no recall games), one labelled sample Mini crossword without the AI editor, with ads; Premium = daily personalized crosswords with the AI editor, Word Hunt, recall games in study, shared friend groups (v1.1), no ads. Implemented: Games tab gate, locked preview, paywall.
 - [x] Choose monthly/yearly subscriptions or a one-time purchase. Avoid promising unlimited ongoing AI usage through a small lifetime payment.
  Monthly $4.99, Annual $29.99, Founding Member $34.99 one-time capped at 500 completed purchases (real cap, server-enforced). Lifetime = "as long as Word Wizard and its service operate", fair-use limits on server-generated content (terms draft).
 - [ ] Set AI allowances and group-puzzle creation limits.
 - [x] Decide whether free users can join puzzles created by premium friends.
  Yes: a free account can join a group by code, share words and see the leaderboard; playing the group puzzle needs Premium (paywall with the puzzle as destination). Creating a group needs Premium.
 - [x] Decide whether premium follows the same app account between Android and iPhone.
  Yes: the RevenueCat app user id is the Supabase user id, so a verified purchase unlocks the account on both platforms; restore still follows each store's rules.
 - [ ] Choose launch countries and intended age group.
 - [ ] Define offline behaviour: which games work offline and when premium status needs refreshing.
  Today everything works offline — dictionary, study, Reader, both games, reminders. The only network use is the optional OpenAI features (user's own key) and sending a bug report (queued offline). Premium refresh rules are still to decide.

2. Set up your developer identity and payments

 - [ ] Choose individual/sole-proprietor or company enrolment.
 - [ ] Complete any applicable business-name registration and local permits.
 - [ ] Choose the legitimate address and seller identity you’re comfortable making public.
 - [ ] Create Apple Developer and Google Play Console accounts; complete identity verification.
 - [ ] Enable two-factor authentication and securely retain recovery details.
 - [ ] Complete Apple’s Paid Apps Agreement and Google’s merchant/payment setup.
 - [ ] Submit required tax information and verify your payout bank account.
 - [ ] Start bookkeeping for sales, commissions, refunds, and expenses.
 - [ ] Check eligibility for reduced store commissions.

3. Establish the production backend

Suggested stack: Supabase + RevenueCat, with a separate worker for shared puzzle generation.

  **Decided 2026-09-16:** Supabase (Auth + Postgres + Edge Functions) and RevenueCat; the group-puzzle worker is a Dart container on Cloud Run reusing `lib/domain/crossword`, post-launch. Launch scope is accounts (optional), premium, AI proxy, feedback, deletion; friends in v1.1, groups in v1.2. Code lives in `supabase/` — see its README for setup.

 - [ ] Create separate development and production environments.
  Code is environment-neutral (`supabase/config.toml`); create `lexery-dev` and `lexery-prod` projects, link, `db push`, `functions deploy`, set secrets. App side (`--dart-define=ENV=`) comes with sign-in.
 - [x] Implement sign-up, sign-in, sign-out, and account recovery.
  Email link/code, Apple and Google (Settings → Account, `lib/features/account/sign_in_sheet.dart`); sign-up is implicit, recovery is the same flow (no password). Apple is native on iOS (entitlement in `ios/Runner/Runner.entitlements`), via the browser on Android; Google is native with the client ids (`GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID` defines), via the browser without. Providers still to be configured in Supabase and the developer consoles — see `supabase/README.md` → Auth providers.
 - [ ] Preserve existing local vocabulary and progress when a guest creates an account.
  Satisfied by design at v1: study data stays on the device; an account adds premium/AI, moves nothing.
 - [x] Give online records globally unique IDs.
  Every table in `20260916000000_init.sql` keys on a uuid or a natural globally-unique id (RevenueCat event id, client report id).
 - [ ] Implement database permissions for private data, friendships, and group membership.
  RLS on every table: owners read their own profile/entitlement/AI rows; config, ledgers, feedback and deletion requests are service-role only. Friendships/groups later.
 - [x] Ensure users cannot modify their own premium status or AI allowance.
  No user-writable policy on `entitlements`, `ai_*` or `app_config`; the quota functions are `security definer` and executable by the service role only.
 - [x] Store LLM keys and administrative credentials only in server secrets.
  `OPENAI_API_KEY`, `REVENUECAT_API_KEY`, `REVENUECAT_WEBHOOK_SECRET` are function secrets (`supabase/.env.example`); the app never sees them.
 - [ ] Add database backups and verify a restore.
 - [ ] Add error monitoring, spending alerts, and an emergency switch for expensive operations.
  Switch and caps exist: `app_config.ai_enabled` (kill switch), `ai_global_daily_cap` (requests + micro-dollar cost/day), per-user daily limits by plan, a cost ledger per call. Still to add: alerting on the ledger and an OpenAI spend limit in their dashboard.
 - [ ] Keep server changes compatible with older installed app versions.
  Rule written into `supabase/README.md`: additive migrations, functions keep old request shapes.

4. Connect the AI features securely

 - [x] Replace direct provider calls in both AI services with authenticated backend requests.
  Done both sides: signed in → `AiGateway` → the functions; verified live 2026-09-17. The direct path remains only for development without an account.
 - [x] Send the user’s session token to the backend; never send or return your LLM key.
  `AiGateway` sends the Supabase access token; the OpenAI key exists only as a function secret.
 - [x] Remove the requirement for customers to enter their own API key.
  Signed-in users need no key. The key field stays as an optional "use OpenAI directly at your own cost" for developers.
 - [x] Make the server control prompts, permitted models, and output limits.
  Prompts in `_shared/prompts.ts`; model per kind, reasoning effort and `max_completion_tokens` are server-side; the client sends only the word / the rendered puzzle.
 - [ ] Validate incoming requests and returned AI content.
  Requests are validated and size-capped server-side; the returned verdict is still verified in the app (§9.4 rules), which is the right place — keep that.
 - [x] Enforce user quotas, rate limits, and an overall spending cutoff.
  `ai_reserve` in Postgres: per-user daily limits by plan, global daily request and cost caps, kill switch; atomic, reserved before the provider call.
 - [x] Prevent retries or repeated taps from generating duplicate billable jobs.
  Idempotency key per job (puzzle id / word) — a repeat returns the stored answer, an in-flight one answers 409.
 - [x] Handle timeouts and provider failures with a usable fallback.
  Bounded deadlines; a failure is credited back and the app keeps its deterministic puzzle/game, as it already does.
 - [ ] Run lengthy editorial requests as saved background jobs.
 - [x] Verify release builds contain no private credentials.
  Checked 2026-09-15: the `OPENAI_API_KEY` define is ignored when `kReleaseMode` (both AI services), `.env` is gitignored and not committed, no keys in the tree. A release build only calls OpenAI with a key the user pasted into Settings.

5. Implement purchases end to end

 - [ ] Create subscription products in App Store Connect, including a subscription group.
  Ids: `premium_monthly_v1`, `premium_annual_v1` (one group), `premium_founder_lifetime_v1` (non-consumable). See supabase/README.md → RevenueCat.
 - [ ] Create matching Google Play subscriptions and base plans.
 - [ ] Configure prices, availability, and any trials.
 - [ ] Connect both stores to RevenueCat.
  Server side ready: `revenuecat-webhook` (idempotent, reconciles from a fresh subscriber fetch) and `entitlement-refresh`; entitlement id must be `premium`.
 - [ ] Map both stores’ products to one entitlement, such as premium.
  Entitlement id must be `premium_active`.
 - [x] Integrate the RevenueCat Flutter SDK using a stable app account ID.
  `purchases_flutter` behind `PurchasesService`; configured with the Supabase user id at sign-in, `logOut` at sign-out. Needs the public SDK keys in `AppEnvironment` to go live.
 - [x] Display store-provided prices and billing periods on the paywall.
  Every price string is the store's; skeletons while loading; the annual saving and per-month figure are computed from live prices only.
 - [x] Explain included features, recurring billing, and trial terms before purchase.
  Four benefits, per-option renewal lines, button subtext, and a full disclosure paragraph in body-size type. No trial at launch.
 - [x] Add Restore Purchases and Manage Subscription.
  Restore on the paywall and in Settings; Manage subscription in Settings (RevenueCat management URL, store fallback).
 - [x] Handle pending, cancelled, failed, and successful purchases.
  Paywall states: loading, loaded, store unavailable (+ retry), purchasing, pending (+ refresh), cancelled (quiet), failed (store reason when actionable), sold out, already entitled, success.
 - [x] Configure authenticated purchase webhooks and retry-safe processing.
  Shared-secret header, event id recorded once, state derived by re-fetching the subscriber so redelivery and ordering don't matter. Dashboard side: paste the URL and secret.
 - [x] Handle renewal, expiration, billing problems, refunds, and revoked purchases.
  Derived from the subscriber on every webhook/refresh: `access` ∈ subscription | lifetime | grace_period | billing_retry | expired; grace keeps access, retry and refund don't; data is never deleted. App mirrors the same states from the SDK's customer info.
 - [x] Reconcile premium status when notifications are delayed or missed.
  `entitlement-refresh`: the app calls it after purchase/restore and on launch when its cache is stale.
 - [ ] Verify Google purchase acknowledgement is handled correctly.
 - [ ] Define account-switching and purchase-transfer behaviour so purchases cannot unlock unrelated accounts.

RevenueCat entitlements connect products to access; its webhooks support an authentication header. Google also requires correct purchase processing and acknowledgement.

6. Complete friends and progress sharing

 - [x] Global puzzle leaderboard (2026-09-20): opt-in public name on the profile, scores computed on the device (`lib/domain/games/scoring.dart`) and summed by the server, this week / all time, own rank; only opted-in names and points are visible, to signed-in users. Grants tightened so the anon key can't read it.
 - [ ] Implement usernames or friend invite codes.
  Group invite codes exist (v1.1 groups); a friend graph does not.
 - [ ] Add request, accept, decline, remove, and block actions.
 - [ ] Let users choose which progress statistics friends can see.
 - [ ] Upload the required progress summaries and show when they last synced.
 - [ ] Render friends’ progress cards consistently on both platforms.
 - [ ] Prevent unauthorised access to private vocabulary, notes, and reading history.
 - [ ] Handle offline uploads without duplicating progress.
 - [ ] Define reporting/moderation for user-visible names and other shared content.

7. Complete group puzzles

 - [ ] Implement group creation, invitations, membership, leaving, and removal.
 - [ ] Let members explicitly select vocabulary to contribute.
 - [ ] Define how vocabulary is balanced across members.
 - [ ] Snapshot contributed words when generation starts.
 - [ ] Deploy the puzzle-generation worker and durable job queue.
 - [ ] Generate and validate one puzzle, then save its final board and clues.
 - [ ] Ensure all participants receive the exact same puzzle.
 - [ ] Store each participant’s progress and result separately.
 - [ ] Define scoring, hints, assisted results, and completion rules.
 - [ ] Handle failed jobs, retries, abandoned groups, and membership changes.
 - [ ] Verify concurrent requests do not create duplicate puzzles or charges.

8. Complete privacy, support, and content requirements

 - [ ] Publish a privacy policy, terms, and support contact.
  Drafted for the app as it is today: `docs/PRIVACY_POLICY.md`, `docs/TERMS.md` (governing-law line to fill in). Support contact is the in-app feedback form plus the email. Needs a public URL (the stores require one) and a read-through; revise when accounts/premium/friends ship.
 - [ ] Explain data collection, retention, friend sharing, and AI processing.
  Collection, retention and AI processing are in the privacy draft; friend sharing waits on the feature.
 - [ ] Obtain permission before sending personal data to third-party AI.
 - [x] Implement account deletion in the app and an external deletion-request page.
  Settings → Account → Delete account (confirms, names the subscription caveat, verified live: cascades everything). `supabase/web/delete-account.html` still needs hosting at a public URL.
 - [x] Explain that deleting an account does not automatically cancel a store subscription.
  On the deletion page; repeat it in the in-app confirmation dialog.
 - [ ] Complete Apple App Privacy disclosures and Google Data Safety accurately, including SDK behaviour.
 - [ ] Complete age-rating and target-audience questionnaires.
 - [x] Check licences and attribution for dictionary data, word lists, fonts, artwork, and dependencies.
  Settings → About → *Data sources & licences* lists Wiktionary (CC BY-SA 3.0/GFDL), ENABLE (public domain), the Nediger list (MIT, full notice), WordNet (Princeton licence, full notice), wordfreq (attribution) and Material icons; the notices are also in the standard open-source licence page with every package's licence. No custom fonts; the icon is our own.
 - [ ] If adding third-party social login on iOS, meet Apple’s equivalent-login requirements—normally through Sign in with Apple.
 - [ ] If ads are included, configure consent and any applicable tracking permission, and verify premium removes ads.

Apple’s guidelines cover account deletion, login options, and AI data-sharing permission. Google additionally requires an external account-deletion route.

9. Prepare production builds

 - [x] Finalise permanent Android application ID and Apple bundle ID.
  `com.willcharlesgill.wordwizard` on both, kept through the Word Wizard rename (not user-facing — DESIGN.md). It can never change after the first upload, so if it should say `lexery`, now is the only time.
 - [ ] Configure Android upload signing and Play App Signing; back up the upload key.
  Gradle is wired: `android/key.properties` (gitignored) selects the upload keystore, falling back to the debug key when absent. Still to do: create the keystore (`android/key.properties.example` has the command), back it up, and opt into Play App Signing in the console.
 - [ ] Configure Apple signing, certificates, and provisioning.
 - [ ] Use production backend endpoints and the correct purchase configuration.
 - [x] Set release version and build numbers.
  `1.0.0+1` in pubspec; Settings shows `appVersion` from `lib/services/feedback_config.dart` — bump both together.
 - [x] Meet current Apple SDK and Google target-API requirements.
  Flutter 3.41.9: compileSdk/targetSdk 36, minSdk 24, AGP 8.11.1, Gradle 8.14. Xcode 26.6 installed; iOS deployment target 13.0.
 - [x] Verify Android 16 KB page-size compatibility, including native SQLite dependencies.
  Verified 2026-09-15 on the release APK: every `.so` (libsqlite3 3.52.0, libflutter, libapp, libdartjni) has 16 KB-aligned LOAD segments and `zipalign -c -P 16` passes.
 - [x] Review permissions; replace the existing exact-alarm approach unless it qualifies.
  Reminders fire at random times, so they don't qualify: `SCHEDULE_EXACT_ALARM` and `USE_EXACT_ALARM` removed, scheduling is `inexactAllowWhileIdle`, no exact-alarm prompt. Remaining: INTERNET, POST_NOTIFICATIONS, RECEIVE_BOOT_COMPLETED (re-registers reminders after reboot); iOS adds a photo-library usage string for bug-report attachments.
 - [x] Check iOS privacy manifests and required-reason API declarations.
  `ios/Runner/PrivacyInfo.xcprivacy` added and in the Runner target: no tracking, no collected data, file-timestamp (C617.1) and UserDefaults (CA92.1) reasons. Plugins ship their own manifests. Re-check Xcode's privacy report on the archive.
 - [x] Measure download size, installed size, and first-launch storage needs.
  Measured 2026-09-15: dictionary.db 464 MB raw, 214 MB gzip; fat release APK 232 MB. Installed ≈ 500 MB+ (the DB is copied out of the bundle on first launch, so briefly ~2×). Over Google Play's 200 MB base-module limit and Apple's 200 MB cellular threshold — see next item.
 - [x] Optimise or plan asset delivery for the dictionary: the uploaded database alone was approximately 464 MB uncompressed.
  Done 2026-09-21: Android ships it as an install-time Play Asset Delivery pack (`android/dictionary_pack`; base module stays ~40 MB), streamed to app storage on first launch with progress on the launch screen; iOS opens it in place from the bundle (no copy). Build the Play upload with `flutter build appbundle`. Earlier notes: Where the 464 MB goes (dbstat, 2026-09-15): examples 151 MB + their FTS index 48 MB, entries 64 MB, senses 62 MB, forms 28 MB, indexes ~60 MB — 740k entries, 921k senses, 546k examples. Options, cheapest first: shrink the DB (examples are 43% — cap them per sense or drop them for rare words; the example FTS index alone is 48 MB; then `VACUUM`); an install-time Play Asset Delivery pack (up to 2 GB, base stays under 200 MB); or download the dictionary on first launch from a CDN. Decide before the first AAB.

Apple currently requires Xcode 26 or later with the relevant version-26 SDK. Google’s target-API and native-library compatibility requirements also need checking against the final build.

10. Test the actual store builds

 - [ ] Test on real iPhones and Android phones, including an older/slower device.
 - [ ] Test fresh installation, upgrading, and database migrations without data loss.
 - [ ] Test dictionary, flashcards, reminders, sharing, and both games offline.
 - [ ] Test interrupted connections, expired login sessions, and server outages.
 - [ ] Verify one user cannot read another user’s private records.
 - [ ] Test purchases through Apple sandbox/TestFlight and Google licence testing.
 - [ ] Test restoration after reinstall and on another device.
 - [ ] Test renewals, refunds, expiration, pending payments, and account switching.
 - [ ] Test an iPhone user and Android user joining the same group puzzle.
 - [ ] Test account deletion and recovery flows.
 - [ ] Check accessibility, large text, keyboard overlap, and small screens.
 - [ ] Confirm production logging does not expose credentials or private content.

11. Complete store testing and listings

 - [ ] Recruit Google Play testers early.
 - [ ] Upload an Android App Bundle to internal testing, then closed testing.
 - [ ] If using a new personal Play account, complete 12 continuously opted-in testers for at least 14 days, then apply for production access.
 - [ ] Upload the iOS build to App Store Connect and distribute through TestFlight.
 - [ ] Prepare icons, screenshots, descriptions, category, and support/privacy URLs.
 - [ ] Complete Google’s app-content declarations and app-access instructions.
 - [ ] Provide reviewers with working demo credentials and access to the backend.
 - [ ] Explain how reviewers can test premium and group features.
 - [ ] Submit Apple’s first IAP/subscription products with the app version.
 - [ ] Resolve automated checks, pre-launch reports, and review feedback.

The Google testing period is a prerequisite for applying for production access, rather than an automatic approval after 14 days.

12. Release and operate

 - [ ] Confirm production purchases, webhooks, email delivery, and backend limits are working.
 - [ ] Confirm backup, monitoring, and support access.
 - [ ] Release to your chosen countries.
 - [ ] Monitor crashes, failed purchases, AI costs, and puzzle-generation failures.
 - [ ] Verify initial store transactions and subsequent bank payouts.
 - [ ] Keep dependencies, store declarations, and developer agreements current.