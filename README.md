# Word Wizard

An offline, ad-free advanced-English vocabulary dictionary and flashcard app
for Flutter — functionally reverse-engineered from renzo Inc.'s Japanese app,
retargeted from Japanese-for-English-speakers to advanced-English-for-fluent-
speakers. See `DesignInspiration/` for the full product & technical design doc.

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

The bundled `assets/db/dictionary-core.db` is generated, not hand-written.
To rebuild it:

```
cd tool/pipeline
python3 -m pip install wordfreq
curl -L -o raw/kaikki-english.jsonl \
  https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl
python3 build_dictionary.py --input raw/kaikki-english.jsonl --out out/
cp out/dictionary-core.db ../../assets/db/dictionary-core.db
```

If you only changed `ADVANCED_VOCAB_SEED` or `--core-size` and already have
`out/dictionary-full.db`, skip the slow re-parse with `--core-only`.

## Running

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```
