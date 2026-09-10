# Word Wizard

An offline, ad-free advanced-English vocabulary dictionary and flashcard app
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
  domain/       Entry/Sense/StudyCard models, the pure SM-2 engine, and the
                crossword engine ported from Crosswordler (PORTING_SPEC.md)
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

`out/dictionary-core.db` is a smaller frequency-ranked subset kept for dev
use; the app itself loads the full database. If you only changed
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

## Running

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```
