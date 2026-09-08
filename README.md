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
  domain/       Entry/Sense/StudyCard models, the pure SM-2 engine
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

`assets/crossword/wordlist.tsv` **is** committed (1.7 MB), so this is only
needed if you change the scoring. It is the scored, filtered word pool the
crossword generator searches — see `PORTING_SPEC.md` §1-§2 for why all the
natural-language work happens offline and the runtime gets a static asset:

```
python3 -m pip install wordfreq
python3 tool/pipeline/export_crossword_wordlist.py \
  --db assets/db/dictionary.db --out assets/crossword/wordlist.tsv
```

To check the generator after a change — fill success, timings, grid density
and quality-gate offenders per size:

```
dart run tool/crossword_bench.dart 10
```

## Running

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```
