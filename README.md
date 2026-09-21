# Word Wizard

> **Naming.** The app is *Word Wizard*. *Lexery* is the in-app name for the store of words you're studying and know ("Add to Lexery"), and the URL scheme / backend project id keep the `lexery` identifier.

An offline advanced-English vocabulary dictionary and flashcard app
for Flutter — functionally reverse-engineered from renzo Inc.'s Japanese app,
retargeted from Japanese-for-English-speakers to advanced-English-for-fluent-
speakers. See `docs/DESIGN.md` for the full product & technical design doc
and feature backlog (`DesignInspiration/` is just mood-board images).

## Status

Phase 0 (content pipeline) and Phase 1 (MVP) are built: search, entry detail
with TTS, custom lists, and an SM-2 flashcard study session, all running
against an offline dictionary generated from an English Wiktionary extract.

## Project layout

```
lib/
  app/          MaterialApp, theming, go_router config, Riverpod providers
  domain/       Entry/Sense/StudyCard models, the pure SM-2 engine, the
                crossword engine ported from Crosswordler (PORTING_SPEC.md)
                and the Word Hunt engine ported from StrandinatorResearch/
  data/         drift schemas for dictionary.db (read-only) and user.db,
                plus the repositories that join them
  features/     one folder per screen (search, entry, lists, study, ...)
  widgets/      shared UI (EntryCard, PosTag, IpaLabel, ...)
tool/pipeline/  offline Python ETL — turns a Kaikki.org Wiktionary dump into
                assets/db/dictionary-core.db (bundled) and dictionary-full.db
test/           SM-2 engine unit tests
```

## Rebuilding the dictionary database

**`assets/db/dictionary.db` is not in this repository and the app will not
run without it.** It is a ~400 MB generated artifact — GitHub refuses files
over 100 MB — so it is gitignored and has to be built locally once:

```
cd tool/pipeline
python3 -m pip install wordfreq
curl -L -o raw/kaikki-english.jsonl \
  https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl
python3 build_dictionary.py --input raw/kaikki-english.jsonl --out out/
cp out/dictionary-full.db ../../assets/db/dictionary.db
```

### How the dictionary ships

It is deliberately *not* a Flutter asset (`pubspec.yaml`), because a
470 MB file in `flutter_assets` had to be loaded whole into memory and
copied out on first launch, and put the Android base module far over
Play's 200 MB cap. Instead (`lib/data/dictionary/dictionary_installer.dart`):

- **Android** — an install-time Play Asset Delivery pack
  (`android/dictionary_pack`, whose asset is a symlink to `assets/db/`).
  Play installs it with the app; the first launch streams it out to app
  storage through the `word_wizard/dictionary` channel in `MainActivity`,
  with progress on the launch screen, and later launches reuse the copy.
  Gradle only packs asset packs into *bundles*, so `flutter build apk` and
  `flutter run` fold the same file into the base APK's assets instead
  (`android/app/build.gradle.kts`) — same path for the app, either way.
  For Play, build an AAB: `flutter build appbundle`.
- **iOS** — a bundle resource of the Runner target (`project.pbxproj`),
  opened by sqlite in place, read-only. No copy, no second 470 MB on disk.

Bump `DictionaryDatabase._assetVersion` when the database changes so
installed Android copies are refreshed.

### Launch

`main()` puts the launch screen (`lib/app/launch_screen.dart`) up first
and opens the databases, keystore and backend behind it, then swaps in
the app. Release builds show the first frame in about two seconds on a
fresh install; debug builds are much slower to first frame because the
engine loads the JIT kernel, which has nothing to do with the app.

`out/dictionary-core.db` is a smaller frequency-ranked subset kept for dev
use; the app itself loads the full database.

The build also creates `examples_fts`, an FTS5 index over example sentences
(~60 MB) that the study session's "which sentence wants this word?" game uses
to pick distractors on the same topic as the real sentence. A `dictionary.db`
built before that index existed still works (the game falls back to random
sentences); to add the index without a full re-parse:

```
python3 build_dictionary.py --add-examples-fts ../../assets/db/dictionary.db
```

Two more tables are built in the same pass, and can likewise be added to an
existing database on their own:

- `spelling_variants` — every headword that is only another spelling of a
  word ("colour" → "color", "shew" → "show"; 82k rows), so search and lookup
  give one card whichever way a word is written and the card lists its
  other spellings. `python3 spelling_variants.py ../../assets/db/dictionary.db`
- `daily_words` — the curated word-of-the-day pool (~2,400 lemmas the
  crossword list rates familiar and uncommon, plus the advanced-vocabulary
  seed), walked one row a day. Needs the crossword word list:
  `python3 daily_words.py ../../assets/db/dictionary.db ../../assets/crossword/wordlist.tsv`

Either change to the bundled database needs `_assetVersion` in
`lib/data/dictionary/dictionary_database.dart` bumped so installed copies
are replaced. If you only changed
`ADVANCED_VOCAB_SEED` or `--core-size` and already have
`out/dictionary-full.db`, skip the slow re-parse with `--core-only`.

## Rebuilding the crossword word list

The crossword generator is a port of the **Crosswordler** engine
(`../Crosswordler`) — see `PORTING_SPEC.md` for the algorithm and
`APP_INTEGRATION.md` for the contract between the app and the engine.
`assets/crossword/wordlist.tsv` **is** committed (8.9 MB), so this is only
needed when Crosswordler's own asset changes:

```
# in the Crosswordler checkout, if its word list has changed:
PYTHONPATH=src python3 tools/export_wordlist.py \
  --out data/processed/wordlist_asset.json --min-zipf 2.5 --require-clue

# then, here:
python3 tool/pipeline/export_crossword_wordlist.py \
  --crosswordler ../Crosswordler --out assets/crossword/wordlist.tsv
```

That packs Crosswordler's 72,214-entry JSON asset (22.8 MB) into the TSV the
app parses in ~120 ms, folding in the two inputs the JSON does not carry: the
familiarity ratings and the crosswordese list, both of which the runtime fill
pool needs (`PORTING_SPEC.md` §6.3). The four fill-pool bars then reproduce the
reference implementation's pool exactly, 68,742 entries.

To check the generator after a change — fill success, timings, grid density
and quality-gate offenders per size:

```
dart run tool/crossword_bench.dart 8
```

Node counts are the first thing to check after touching the solver: §11
measures 11 / 32 / 115 nodes at the three sizes, and a port taking thousands
has a bug in propagation or undo however fast it runs. The unit tests assert
this for 9x9.

## The Word Hunt

The second game is a 4x4 letter board — trace adjacent letters (eight
directions, no tile twice) to find words. It is a Dart port of the
`StrandinatorResearch/` engine (milestones 0.3-0.4) and runs entirely
offline with no model calls:

- **Anchors.** Each board is built around up to two of the user's study words
  (due cards first) and one word from the day's theme, placed jointly by
  bounded backtracking. If they won't all fit, the lowest-priority anchor is
  dropped and the result says so — a board never silently claims a word it
  couldn't place. Finding a study word shows its definition; it does **not**
  grade the SRS card, because seeing the letters is not recall.
- **Answer classes.** *Main* words (familiar: rating ≥ 4, zipf ≥ 2.5) are
  what completion is measured against — the generator ranks candidate boards
  toward ~40 of them. *Bonus* words are everything else ENABLE accepts (minus
  the content list): recognised and counted, never required.
- **Certified scans.** The chosen board is scanned once by a memoised,
  budgeted solver that throws rather than truncate, and the complete answer
  sets are frozen into the puzzle row, so play never consults a dictionary
  and a lexicon update can't move the goalposts under a saved board.
- **Themes.** `assets/hunt/themes.tsv` maps ~36 Wiktionary topics (music,
  law, at sea, …) to familiar words whose *primary* sense carries the topic.
  One topic per calendar day; every topic word on the board lights up.
- **Hints.** A hint marks a random unfound word's start tile with an arrow
  toward its second letter, and stays until the word is found; tapping the
  arrowed tile repeats how long the word is. A board starts with two; every
  bonus word found earns one more. Once half the required words are found,
  the word counter unlocks for the rest of the board — each tile shows how
  many remaining words start on it — and a popup says so. Hints mark a
  solve as assisted; the halfway counter, being earned, does not. There is
  no reveal, in either game: only clues and hints.

Rebuild the three assets (`accepted.txt`, `main.txt`, `themes.tsv`) with:

```
python3 tool/pipeline/export_hunt_lexicon.py \
  --kaikki tool/pipeline/raw/kaikki-english.jsonl
```

Omit `--kaikki` to rebuild just the two word lists in seconds; the topic
stream over the 3 GB dump takes a few minutes. Open the screen directly on a
device with `flutter run --dart-define=INITIAL_ROUTE=/games/hunt`.

## The crossword's editorial pass

One optional LLM call per puzzle judges the finished grid and rewrites weak
clues (`PORTING_SPEC.md` §9.3). It is **strictly an upgrade**: no key, a
timeout, a rate limit or unparseable output all leave the deterministic puzzle
exactly as it was, and nothing about play requires a network.

Two rules from `APP_INTEGRATION.md` §4 shape how it is wired here:

- **The key never ships.** `CrosswordReviewService` calls OpenAI directly only
  in *debug* builds, and only when the key is passed at build time:

  ```
  flutter run --dart-define-from-file=.env
  ```

  `.env` is gitignored (`cp .env.example .env`). A define rather than a
  bundled asset is the point: an asset listed in `pubspec.yaml` is packaged
  into *every* artifact including release builds, whereas a define exists only
  in the build you passed it to. Plain `flutter run` simply leaves the pass
  switched off. `proxyUrl` is the seam a backend drops into, which is what a
  shipping build needs.
- **It is never on the click path.** Measured latency is ~15 s and flat in
  puzzle size. The screen shows the deterministic puzzle immediately and only
  swaps clues in if the review lands before the user types anything — never
  mid-solve. A revision that arrives late is still saved for next time.

To exercise the live path (makes a paid API call, ~20 s):

```
dart run tool/crossword_review_smoke.dart
```

### It bans bad answers rather than replacing them

`PORTING_SPEC.md` §9.4 has the reviewer propose a replacement answer, which is
then pinned and the grid re-solved around it. That is the one thing a model is
worst at: a substitute has to agree with every crossing letter, which is a
search problem. Measured, it failed almost every time — one review asked for
SUPRA→ABOVE and DOE→GAS and neither could be filled.

So the reviewer only says *which* answers are unfair, and the solver — 1-35 ms
for a whole grid — finds the replacements. It judges; the search searches.

The re-fill is a **local repair that widens only as needed**: the banned slot
and everything within one crossing of it is unpinned and the rest held fixed,
then two hops, then three, then the whole grid. Re-filling everything produces
a different puzzle (measured: 2 of 25 answers survived), which discards the
reviewer's other clue rewrites and rewrites a grid the user may already be
reading. At radius 2 a typical ban changes six answers out of twenty-four, and
a clue rewrite for an answer that didn't move still applies.

A banned answer also goes into `crossword_banned_answers` and stays out of
every future puzzle, whether or not this grid could lose it. That list is the
raw material for `CROSSWORDESE` in the Crosswordler project — the same job
reader complaints did by hand.

It is a model's opinion accumulating unchecked, so it is browsable and editable
rather than invisible: **Settings › Developer › Banned crossword answers** (also
reachable from each History screen) lists every ban with its reason and where
it came from, filters by answer or reason, sorts by recency or alphabetically,
and lets you add your own, reword a verdict, swipe one away (with undo), or
clear the lot.

### Two debug affordances around it (remove before release)

**Settings → Developer → Crossword AI editor** switches the pass off. Puzzles
still generate, and regenerating one costs nothing, which is what makes it
practical to iterate on grids, anchors or clue selection. Turning it off does
*not* mark a puzzle reviewed, so switching back on reviews that same puzzle —
which is how one grid gets compared with and without the pass.

**Each size's History screen** is one entry per *generation*, not per day.
"Start new" adds a puzzle rather than replacing the day's, so two attempts at
one day sit next to each other with their own progress and their own review —
which is what makes comparing them possible at all. Each row is addressed by
puzzle id (`?puzzle=<id>`), and a regenerated one is marked with a ↻.

The same screen is the token and cost readout. Every run is
logged to `crossword_review_log` — model, outcome, latency, prompt/completion/
reasoning tokens, estimated cost, the reviewer's own score and notes, and every
proposed edit with whether it survived §9.4's verification or which rule it
broke. Failed runs are logged too: an HTTP 429 or a blown deadline is exactly
what you want to see when the pass appears to be doing nothing. Regenerating
adds a second run under the same day rather than replacing the first.

While a puzzle is open, a strip under the app bar says what the pass is doing
to *that* puzzle — "reviewing…", "rewrote 18 clues · 0.43¢", "is off", "no API
key in this build", or the error it failed with. Without it the pass is
invisible: it runs in the background and either silently improves the clues or
silently does nothing. Tapping the strip opens the history.

Costs are estimated locally from `openAiPricePerMillionTokens`, a hardcoded
table that will go stale — check OpenAI's pricing page before trusting a total.
A model missing from it reports no cost rather than a wrong one. Measured on a
9x9: ~25 s, 1.6k in + 1.8k out, about $0.004 a puzzle.

## Premium

Sold per *docs/Premium Offers Implementation Specification*: monthly and
annual subscriptions and a one-time Founding Member purchase capped at 500.
Free accounts get the dictionary, Reader, lists, plain flashcards and a
labelled sample Mini crossword (no AI editor), with ads; Premium adds the
daily games, the AI editor, the study recall games and no ads; the Games tab opens the paywall (`/premium`) on every
visit and shows the locked catalogue behind it. Code: `lib/domain/premium`
(model, prompt policy), `lib/services/purchases_service.dart` (RevenueCat
behind an interface, with an in-memory fake for debug builds without a
key), `lib/features/premium` (paywall, preview, prompt, legal pages).
Founder inventory is server-side — see `supabase/README.md`.

## Group puzzles (v1.1)

See `docs/Group Puzzles v1.1.md`. Tables and RPCs in
`supabase/migrations/20260920000000_groups.sql`; app code in
`lib/domain/groups`, `lib/services/groups_api.dart`,
`lib/services/group_puzzle_service.dart` (device-side generation from the
pool, first-writer-wins publish, score upload) and `lib/features/groups`.

## Accounts

Optional; for Premium, the AI editor, groups and the leaderboard. One
sheet (`lib/features/account/sign_in_sheet.dart`, opened from Settings and
wherever an account is needed) offers Apple, Google and email — a link and
a six-digit code, no password. `AuthService` (`lib/services/auth_service.dart`)
does Apple natively on iOS and Google natively when the OAuth client ids
are defined at build time, and falls back to Supabase's hosted OAuth flow in
the browser otherwise; `supabase/README.md` → Auth providers has the setup.

## The landing board

The Search tab lands on a crossword-style board of Scrabble-like tiles
that grows outward from the word of the day, a word every quarter second,
until it runs out of room or words (`lib/domain/board/word_board.dart` is
the model and grower, `lib/features/search/word_board_view.dart` the
canvas). Drag and pinch to explore; tap a tile to open its word (a
crossing asks which). Tiles are tinted by the Lexery — plain for new
words, one tint for words being studied, a stronger one for mastered —
so the board turns more and more familiar as the person learns. Words
come from the curated daily pool and the middle of the frequency range
(`DictionaryDatabase.boardWords`), with a few of their own words mixed
in. Tapping the search field swaps it for the recent searches; leaving
the field empty brings it back.

## Leaderboard

Games → Leaderboard (the strip at the top of the tab): puzzle points this
week and all time. Anyone can look; scores go up only for accounts that
opted in under a public name (Settings → Account → Leaderboard name).
Rules in `lib/domain/games/scoring.dart`; upload in
`lib/services/score_sync.dart`; server side in `supabase/README.md`.

## Progress

Settings-free: the Progress screen (Study tab) counts words got right in
any puzzle, finished or not, time spent in puzzle screens, and how far
unfinished puzzles got, alongside the study numbers. "I've mastered this
word" on a review card sends a word to the mastered state on a 120-day
interval. The undo arrow in the session header (and "Undo last grade" on
the recap) takes back the most recent grade — SM-2 state restored, the
review row deleted — and puts the card back on screen
(`StudyRepository.ungrade`).

## Ads

Free accounts see an AdMob banner under word cards and an interstitial when
a review session ends; Premium removes both. `lib/services/ads_service.dart`
is the seam; Google's test unit ids are compiled in until real ones are
passed with `--dart-define` (see `lib/services/ads_config.dart`), and the
app ids in AndroidManifest.xml / Info.plist are Google's test ids to replace.

## Backend

`supabase/` holds the server side: Postgres schema and row-level security,
the quota-and-idempotency functions, and Edge Functions for the AI proxy,
RevenueCat entitlements, feedback intake and account deletion. Its README
has the setup; the app stays offline-first and only reaches for it for
premium, AI and reports.

The app picks its project with `--dart-define=ENV=dev|prod`
(`lib/app/environment.dart`; dev is the default). Settings → Account signs
in by email; a signed-in user's AI calls go through the backend with a
daily allowance instead of needing an API key.

## Bug reports and feature suggestions

Settings → "Report a bug or suggest a feature" is an in-app form: a
message, an optional link and reply address, and screenshots — the app
keeps a snapshot of the last few screens the user was on, taken as each
one is left, so the screen the bug was seen on is one tap away — or a
photo from the library. Reports go to a small Google Apps Script relay
that mails them to the developer; the setup is in `tool/feedback/`. Until
a build has the relay's URL (`--dart-define=FEEDBACK_ENDPOINT=…` or
`lib/services/feedback_config.dart`), reports wait in an on-device outbox
and go out on the first launch that can send them.

## Running

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

To judge the games on a device, run `--profile` or `--release`. A debug build
runs Dart under the JIT and the crossword and Word Hunt generators are
several times slower in it; the crossword gives debug builds 5× its time
budgets (`CrosswordRepository._debugBudgetScale`) so Midi and Mega still
fill, but the timings mean nothing until AOT. Every generation logs its
outcome and duration (`crossword midi: 30 words in 412 ms …`).

### Release builds

- Android signs with `android/key.properties` when it exists (see
  `android/key.properties.example`), otherwise with the debug key.
- Version and build number come from `version:` in `pubspec.yaml`, and the
  version shown in Settings from `appVersion` in
  `lib/services/feedback_config.dart`; bump both together.
- No API key ships: the build-time `OPENAI_API_KEY` define is ignored
  unless dev tools are on (`FeatureCluesService`, `CrosswordReviewService`),
  so a store build only calls OpenAI with a key the user pasted into Settings.

### A fast build with the developer tools

A release build is AOT-compiled and compressed — the one to judge speed
and the games on a phone — but normally drops the developer conveniences.
`--dart-define=DEV_TOOLS=true` (`AppEnvironment.devTools`, on by default
in debug builds) keeps them: the in-memory store with the "Debug: fake
Premium" switch, prompt-cooldown reset and open-paywall tiles in Settings,
the fake founder count, and the `.env` OpenAI key. Never for the stores.

```
flutter build apk --release --target-platform android-arm64 \
  --dart-define=DEV_TOOLS=true --dart-define-from-file=.env
```
