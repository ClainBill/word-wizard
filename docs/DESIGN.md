# Word Wizard — design doc

**Version** 0.6 · **Date** 2026-09-06 · **Author** willcharlesgill · **Platform** Flutter · iOS + Android · **Distribution** personal use, unlisted

An offline, ad-free advanced-English vocabulary dictionary and flashcard app for Flutter — functionally reverse-engineered from renzo Inc.'s *Japanese* app, retargeted from Japanese-for-English-speakers to advanced-English-for-fluent-speakers.

**App icon:** a cream "W" monogram (Fraunces-adjacent serif) with a small four-point sparkle at its shoulder, on a solid `#8A5A22` field — legible at launcher size, and the sparkle is the one on-brand nod to "Wizard" without leaning on a literal wand or hat. Used as both the Android adaptive icon (foreground glyph + solid-color background layer) and, as a plain white silhouette, the status-bar notification icon.

This file is the source of truth for the design doc — it supersedes the stale `README.md` reference to `DesignInspiration/` (that folder is just mood-board images, no doc). A polished, browsable rendering of this doc is also kept as a Claude Artifact; treat this file as canonical when the two ever drift.

---

## Research

A teardown of the source app — what it is, how it's built, and what it costs nothing to copy functionally.

**The source app is *Japanese* by renzo Inc.** — a free iOS/Android/Mac/Vision/Watch reference app (App Store category: Reference) with a 4.8-star rating across roughly 3,600 ratings, a 260 MB install size, and a decade-plus history dating to at least 2019's v4.6.1 dark-mode release. It bills itself as a dictionary, study tool, kanji trainer, and text reader in one, and it is entirely free with no ads and no subscription tier.

### Content scale & sourcing

| Asset | Scale | Source |
|---|---|---|
| Dictionary entries | 175,000–180,000 | JMdict |
| Example sentences | 58,000 | Tanaka Corpus |
| Kanji stroke data | full jōyō + beyond | KanjiVG |
| Handwriting recognition | 99.3% claimed accuracy | on-device model, kanji + kana |

All three source datasets are free, open, community-maintained dictionary projects — the app's core value isn't proprietary content, it's **packaging that content into a fast, fully offline, well-designed mobile experience.** That's the part worth copying.

### Feature inventory (source app)

| Area | Feature |
|---|---|
| Search | Incremental fast search across 175k+ entries as you type |
| Search | Conjugation search — type any inflected form, resolve to the dictionary headword |
| Search | Multi-radical kanji search, search by dictionary code (SKIP) |
| Kanji tools | Handwriting recognition (draw a character, get matches) |
| Kanji tools | Stroke-order animation, on/kun readings |
| Reading aid | Text Reader — paste text, get it segmented into words with readings, tap for definitions |
| Study | Flashcards with an SRS engine "based on Anki's, reengineered for Japanese learners" |
| Study | Built-in JLPT (N5–N1) and Kanji Kentei list packs |
| Study | Study dashboard tracking progress across lists |
| Organization | Custom lists, folders, labels, and notes; add-to-list from any entry |
| Organization | Import from competing apps: imiwa?, Midori, Nihongo, Rikaichan |
| Organization | Backup & restore; share lists via AirDrop / Messages / Email |
| Organization | Romaji toggle via tap-and-hold on furigana |
| Platform | Fully offline after install; free, no ads, no subscription |
| Platform | iPad Split View; Dark Mode (added v4.6.1) |
| Platform | Text-to-speech pronunciation |

**Read on this research:** nothing here depends on Japanese specifically except the kanji-only tools (handwriting, radicals, stroke order, on/kun) — everything else is a general-purpose "offline dictionary + SRS flashcards + reading aid" product shape that maps cleanly onto any language. See [Feature map](#feature-map) for the entry-by-entry translation.

---

## Vision

What Word Wizard is for, who it's for, and what it deliberately isn't.

**Target user:** a single fluent English reader (you) who wants to systematically expand vocabulary — GRE/SAT-tier words, literary and rare words, precise near-synonyms — the way a Japanese learner uses renzo's app to expand their lexicon: look a word up once, decide it's worth keeping, and let spaced repetition do the memorizing.

**Product shape:** a **monolingual English dictionary** (not a translation dictionary), instrumented with the same four pillars as the source app: fast offline search, a reading aid that turns any pasted text into tappable lookups, custom study lists, and Anki-style spaced repetition.

### Non-goals

- No accounts, no server, no sync backend — single user, single device family, backup is a file you export yourself.
- No handwriting recognition, radical search, or stroke order — those are kanji-specific tools with no English analogue and are dropped rather than reinvented.
- No ads, no monetization — it's a personal build, not a shippable product, so App Store review constraints don't apply unless you later decide to distribute it.
- No claim of being a fully general dictionary for beginners — it's tuned for vocabulary *building* at an advanced level.

---

## Feature map

Every renzo feature, translated to its English-vocabulary equivalent, with a build priority (MVP / v1 / v2 / cut).

| renzo feature | Word Wizard equivalent | Priority |
|---|---|---|
| Incremental dictionary search | Prefix + fuzzy search over the Wiktionary-derived headword index; every POS variant of a headword merged into a single ranked result | MVP |
| Dictionary entry | Entry detail: word + IPA + TTS, senses grouped by POS, etymology, 3 examples always visible (expandable), forms & conjugations, custom Markdown notes | MVP |
| Text-to-speech pronunciation | Same — device TTS reads headword + example sentence | MVP |
| Custom lists / folders / labels / notes | Same, 1:1 — plus a ▶ Study action per list that bulk-enrolls every word into the SRS queue in one tap | MVP |
| Flashcards + SRS | Same engine shape (SM-2), applied to word entries; a word's custom note (if any) renders on the review-card back too | MVP |
| Study dashboard | "Manage study words" browser: every enrolled word, added date, full review history, per-word Pause/Reset/Remove | MVP |
| Conjugation search | Inflection index: "ran" / "better" / "mice" resolve to run / good / mouse | v1 |
| Text Reader | Same — English tokenization is whitespace/punctuation based, far simpler than Japanese segmentation | v1 |
| JLPT list packs | Curated packs: Academic Word List, GRE high-frequency, frequency tiers (top 1k/5k/10k) | v1 |
| Backup & restore, list sharing | JSON export/import via the OS share sheet | v1 |
| Dark mode, iPad Split View | Flutter theme + adaptive layout | v1 |
| Import from imiwa?/Midori/Rikaichan | Import from Anki `.apkg` and CSV | v2 |
| Multi-radical kanji search | Search by root/prefix/suffix ("bio-", "-ology") | v2 |
| Study reminders / notifications | Two local notifications a day naming a random word due within 24h | MVP |
| Handwriting recognition | Dropped — no English equivalent need | cut |
| Stroke order, on/kun, radical browsing | Dropped — kanji-specific | cut |

---

## Navigation

The app's shell: a five-tab bottom bar mirroring renzo's Dictionary / Lists / Study split, with Reader promoted to its own tab.

| Tab | Purpose |
|---|---|
| 🔍 Search | Dictionary home — search bar + recents |
| 📄 Reader | Paste text, tap any word to define |
| 🗂️ Lists | Custom lists + curated packs |
| 🎯 Study | Due-today queue + progress dashboard |
| ⚙️ Settings | Theme, backup, import, TTS voice |

Any entry — from Search, Reader, or a study session — opens the same **Entry Detail** screen and can be added to any list from there.

---

## Screens

### Entry Detail anatomy

A single Entry Detail card always renders its sections in this fixed order:

1. **Word** — headword, IPA, and a TTS button.
2. **Meanings, grouped by part of speech** — every POS variant of the headword merged into this one card, each with its own numbered senses. Every word inside a gloss is individually tappable — see [Backlog #15](#backlog).
3. **Word origin** — a brief etymology paragraph, when Wiktionary provides one. Tappable word-by-word, same as glosses.
4. **Examples** — the first three sentences always visible; an "N more examples" expander reveals the rest. Tappable word-by-word.
5. **Forms & conjugations** — tenses and inflections as chips.
6. **Notes** — a free-text Markdown editor, with a Preview toggle; also rendered on the word's SRS review-card back.

### Screen inventory

| Screen | Purpose | Reached from |
|---|---|---|
| Search | Type-ahead over the FTS index; deduplicated by headword; a trailing space forces an exact-token match | Tab bar |
| Entry Detail | Full entry in fixed section order; add-to-list, add-to-study, TTS | Search, Reader, Lists, Study results |
| Reader | Text box → tokenized word chips → tap a chip to define | Tab bar |
| Lists | Grid of custom lists + curated packs, each with a card count and due count | Tab bar, "Add to list" on any entry |
| List Detail | Word table for one list; a ▶ Study action bulk-enrolls the whole list; a ⋮ menu resets/pauses/resumes/removes every studying word in it | Lists |
| Study Session | One card at a time, front (word) → reveal (definition/example/note) → a small comprehension mini-exercise → four-button SM-2 grading; a ⋮ menu removes the current word from study without leaving the session | Study tab, List Detail |
| Progress Dashboard | Cards due today, streak, mastered count, 14-day forecast | Study tab |
| Manage Study Words | Every word in the SRS pool with stage badge, review count; Pause/Resume, Reset, Remove | Study tab |
| Games → Crossword | Daily mini/midi/mega crossword seeded from the SRS pool, real words only, no forced symmetry; saves/resumes state; an app-bar chip counts how many of today's words came from the study pool | Games tab |
| Settings | Theme, TTS voice/rate, notification time, backup/export, import, data source attribution | Tab bar |

---

## Data model

Two databases: a read-only dictionary shipped as an asset, and a small read-write store holding everything the user creates.

### `dictionary.db` — read-only, generated by the content pipeline

| Table | Key fields | Notes |
|---|---|---|
| `entries` | id, headword, pos, frequency_rank, etymology | One row per lemma+POS pair; rows sharing a headword are merged into a single card at query time |
| `senses` | id, entry_id, gloss, order | 1:N — a word can have several definitions |
| `examples` | id, sense_id, text, source | From Wiktionary quotations/usage lines |
| `pronunciations` | entry_id, ipa, audio_hint | `audio_hint` feeds device TTS phonemes, not a stored audio file |
| `forms` | form_text, entry_id, form_type | Inflections — powers conjugation search and inflected-word tap-through |
| `morphemes` / `morpheme_entries` | — | Curated root/prefix/suffix reference (v2) |
| `entries_fts` | FTS5 virtual table | Indexes headword + forms for instant prefix search |

### `user.db` — read/write, on-device only

| Table | Key fields | Notes |
|---|---|---|
| `lists` | id, name, kind, created_at | `kind`: custom \| curated |
| `list_items` | list_id, entry_id, note, added_at | Also stores the user's free-text note per word |
| `study_cards` | entry_id, state, ease_factor, interval_days, repetitions, due_at, paused | One SRS record per entry; `paused` excludes a card from due/dashboard/forecast/reminders without discarding progress |
| `entry_notes` | entry_id, markdown, updated_at | Rendered on Entry Detail and mirrored onto the SRS review-card back |
| `review_log` | card_id, reviewed_at, grade, prior_interval | Append-only history |
| `settings` | key, value | Theme, TTS voice, reminder time |
| `crossword_puzzles` | puzzle_date, difficulty, grid_json, progress_json, completed | One row per day+difficulty; `progress_json` is the in-progress fill, updated on every keystroke |

---

## SRS algorithm

SM-2, the same family renzo cites as its basis — a card's next interval grows with a per-card ease factor and shrinks to zero on a miss.

**Card lifecycle:** New → Learning (reps 0–1) → Review (reps ≥ 2) → Mastered (interval ≥ 90d, EF ≥ 2.5). A grade of *Again* on a Review card lapses it straight back to Learning.

**Grading → SM-2 update:**

| Button | Quality (q) | Effect |
|---|---|---|
| Again | 0 | reps → 0, interval → 1 day, lapses to Learning |
| Hard | 3 | reps holds, interval grows by ~1.2× instead of by EF |
| Good | 4 | standard SM-2 step |
| Easy | 5 | standard SM-2 step, EF bonus +0.15 |

```
EF' = EF + (0.1 - (5-q) * (0.08 + (5-q) * 0.02))
EF' = max(EF', 1.3)

if q < 3:
    repetitions = 0
    interval    = 1
else:
    repetitions += 1
    interval = 1                        if repetitions == 1
             = 6                        if repetitions == 2
             = round(interval * EF')    otherwise

due_at = today + interval days
```

The revealed side of a card also renders a small **comprehension mini-exercise** (definition-match or scrambled-letter spelling, randomly picked, with a shuffle button to reroll) and the word's custom Markdown note, if one exists.

---

## Architecture

A three-layer Flutter app with no backend — everything that would normally be a server call is a local SQLite query.

```
Presentation  →  Widgets · Riverpod providers · go_router
Domain        →  Entry/Card/List models · SM-2 engine · tokenizer · search ranking
Data          →  Drift (SQLite) · dictionary.db (read-only asset) · user.db (read/write) · repositories
```

### Package choices

| Concern | Package | Why |
|---|---|---|
| State management | `flutter_riverpod` | Compile-safe providers, easy to test the SRS engine in isolation |
| Local database | `drift` | Type-safe SQL, reactive streams for "cards due" counts, FTS5 support |
| Full-text search | SQLite FTS5 (via drift) | Sub-50ms prefix search over 150k+ rows on-device |
| Pronunciation | `flutter_tts` | Device TTS — avoids bundling audio for 150k+ words |
| Routing | `go_router` | Declarative deep links from Reader/Lists/Study into Entry Detail |
| Notifications | `flutter_local_notifications` | "Cards due" reminder |
| Sharing / export | `share_plus` | Same OS share sheet pattern as renzo's AirDrop/Messages/Email export |
| Import parsing | `archive`, `sqlite3` | Anki `.apkg` is a zipped SQLite file (v2) |

### Folder structure

```
lib/
  app/                 # MaterialApp, theming, go_router config
  domain/
    models/            # Entry, Sense, Card, WordList
    srs/                # sm2.dart — pure functions, unit-testable
    crossword/          # generator, pattern solver, models
  data/
    dictionary/         # drift schema + DAO for dictionary.db (read-only)
    user/               # drift schema + DAO for user.db (lists, cards, log, crosswords)
    repositories/        # SearchRepository, ListRepository, StudyRepository, CrosswordRepository
  features/
    search/ reader/ lists/ study/ games/ settings/ entry/
  widgets/              # shared UI: EntryCard, PosTag, IpaLabel, TappableWordText, ...
tool/
  pipeline/             # offline Python ETL — see Content pipeline
```

---

## Content pipeline

A one-time, offline script that turns a raw Wiktionary extract into the bundled `dictionary.db` — renzo's JMdict/Tanaka/KanjiVG role, played by Kaikki.org's parsed Wiktionary dump.

`Kaikki JSONL` → `Filter + rank` (cross-reference a frequency list) → `Build SQLite` (entries + senses + forms + FTS5) → `Emit dictionary.db, bundled whole`

1. **Source:** `kaikki.org/dictionary/English` — a JSONL export of English Wiktionary, free under CC BY-SA 3.0 / GFDL (attribution kept in Settings → About).
2. **Filter:** keep noun/verb/adjective/adverb entries with a gloss; drop proper nouns and pure inflection stubs (those become `forms` rows on their lemma).
3. **Rank:** join against a public word-frequency list to assign `frequency_rank`, powering frequency-tier list packs and default search ordering.
4. **Extract forms:** Kaikki's `forms` field lists inflections with tags — written as `forms` rows, powering conjugation search.
5. **Extract examples, IPA & etymology:** map directly onto `examples`, `pronunciations`, and `entries.etymology` (truncated to ~1,200 chars).
6. **Emit:** write `dictionary-full.db` (740,663 entries, 406 MB) and copy it into `assets/db/dictionary.db`. The app bundles this whole file rather than a separate small "core" set plus a download flow — acceptable at personal/unlisted-distribution scale. A small `dictionary-core.db` is still produced for fast dev-time iteration (`--core-only`) but nothing in the shipped app reads it.

**Assumption:** the pipeline runs once on a development machine (Python + `ijson` + `sqlite3`), not on-device. Re-run it manually to refresh the vocabulary.

**On-device migration:** the bundled asset is copied to app-private storage on first launch (or whenever a version marker changes), not on every launch.

---

## Non-functional requirements

| Requirement | Target |
|---|---|
| Search latency | Results update within one frame (<50 ms) of each keystroke, via FTS5 |
| Cold start | <1.5s to an interactive search box, DB opened lazily off the UI thread |
| Offline | 100% of core features work with the device in airplane mode after first-run sync |
| Platforms | iOS 13+, Android 8 (API 26)+ |
| Accessibility | Respects system text scaling and reduced-motion; dark mode follows system by default |
| Privacy | No network calls at runtime except the one-time dictionary asset copy — no analytics, no accounts |
| Install size | ~400 MB, the full 740k-entry dictionary bundled whole |

---

## Roadmap

| Phase | Scope | Exit criterion |
|---|---|---|
| 0 · Pipeline | Build and run the ETL script; produce `dictionary-core.db` | Can query 15k words by headword prefix from the command line |
| 1 · MVP | Search, Entry Detail, TTS, custom Lists with bulk ▶ Study, Study session with SM-2 | Look up a word, save it, add a note, bulk-enroll a list, review tomorrow with a correct due date |
| 2 · Study depth | Progress dashboard; full 740k-entry dictionary bundled directly | **Done** — dashboard matches ground truth, search resolves the full Wiktionary extract |
| 3 · Reading | Reader tab, tokenizer, inflection index, conjugation search | Paste a paragraph, tap any inflected word, get the right lemma |
| 4 · Polish | Curated list packs, dark mode, backup/export, tablet layout, Anki import, reminders | Feature-complete against the Feature map's v1/v2 rows |

---

## Backlog

Every idea raised after the MVP shipped, in the order they were raised, with what's actually built versus what's still open.

> **2026-09-06 audit:** of the 21 numbered ideas below, 9 were already fully built (4 of those were sitting unchecked in the source notes purely because no one had gone back to confirm them), 3 are partially built, and 9 are still open. The 2026-09-06 session shipped the four quickest wins found during the audit — the tappable-word feature and its stacked-sheet lookup turned out to satisfy two separate ideas (#10 and #15) at once.

| # | Idea | Status | Lift | Notes |
|---|---|---|---|---|
| 1 | SRS study screen: tap or swipe up to pop the full word card up from below | ✅ done | — | Shipped before this audit. |
| 2 | Crossword clues should favor real, commonly-used words — cut initialisms, drop forced symmetry | ✅ done | — | Shipped before this audit; acronyms deprioritized, not banned outright. |
| 3 | Show a counter of how many crossword words came from the SRS pool, in the corner | ✅ done | Quick | **Shipped 2026-09-06.** Puzzle words carry a persisted `fromStudyPool` flag; an app-bar chip shows the count. |
| 4 | Search: a trailing space should cut a word off for an exact match ("muse " excludes "museum") | ✅ done | — | Found already built during the audit, just unchecked in the source notes. |
| 5 | Group lists into folders — folders behave like lists but can also nest other lists and words | ⬜ open | Large | Needs a real hierarchy in the data model (self-referential `lists`, or a parent `list_id` column), plus recursive study/pause propagation and new UI for nested browsing. |
| 6 | Crossword should save its state on quit and resume later | ✅ done | — | Found already built during the audit — every keystroke persists progress against that day's puzzle row. |
| 7 | SRS review options: quiz from the meaning instead of the word (either direction, or both) | ⬜ open | Medium | A settings toggle plus flipping which side of the card shows first; the comprehension mini-exercises (#9) would need a meaning→word variant too. |
| 8 | Crossword text input should skip over cells that already have a letter in them | ✅ done | Quick | **Shipped 2026-09-06.** Typing through a word skips cells a crossing word already filled, jumping to the next word once nothing's left empty. |
| 9 | SRS comprehension mini-exercises under the flipped card (sentence/synonym/definition matching, spelling, etc.) | 🟡 partial | Medium (remaining) | Definition-match and letter-spelling are live and randomly picked. Still open: synonym-matching and example-sentence-matching. |
| 10 | From the full card during SRS, tap a word in the description/example to add it to a list — without leaving SRS | ✅ done | Medium | **Shipped 2026-09-06** — via the tappable-word feature (#15): tapping a word pops its own card up as a stacked sheet, with its own Add-to-list/Study buttons, on top of the study session. |
| 11 | Remove a word from SRS without leaving the session (via an ⋮ menu) | ✅ done | Quick | **Shipped 2026-09-06.** The repository-level remove already existed (Manage Study Words); this wires a confirm-and-remove menu into the study session card itself. |
| 12 | A Games tab with an intelligent daily Crossword/Strands-style game built from SRS words — prefer no cloud API | 🟡 partial | Large (remaining) | Games tab + daily Crossword (mini/midi/mega, offline, seeded from SRS) already exist. A Strands-style word-search mode is unbuilt. |
| 13 | A spelling test for complicated SRS words, in the Games tab | 🟡 partial | Medium (remaining) | The scrambled-letter "Spell it" exercise exists inline in SRS study (#9). A standalone, difficulty-targeted version in the Games tab isn't built. |
| 14 | Full documentation of every feature, accessible inside the app | ⬜ open | Medium | Mostly a content-writing task once a Settings → Help screen exists; this doc is the closest thing to that content today. |
| 15 | Click any word in a card to pull up that word's own card — especially in examples and word origin | ✅ done | Medium | **Shipped 2026-09-06.** Every word in a gloss, example, or etymology line is tappable (dotted underline); resolves inflected forms too. |
| 16 | Consolidate British/American (or other) spelling variants into one card | ⬜ open | Large | Depends on the content pipeline detecting and cross-linking variant spellings — a data problem more than a UI one. |
| 17 | Import a list from a pasted string of words | ⬜ open | Medium | Parse + batch-lookup is straightforward; the real work is UX for words that don't resolve or resolve ambiguously. |
| 18 | Read words aloud with correct pronunciation during SRS study (UK English first, US later) | ⬜ open | Medium | `flutter_tts` is already wired into Entry Detail's pronounce button; wiring the same call plus a UK/US voice setting into study is the remaining work. |
| 19 | Rehaul the app's look, feel, and logo — grainy, papery, analogue "old dictionary" aesthetic | ⬜ open | Large | The current theme already leans warm-paper in color only; an actual grain/paper texture treatment is a real visual-design pass. |
| 20 | Colour theme customization in Settings | ⬜ open | Medium | The theme is already seed-color-driven (`ColorScheme.fromSeed`); needs a stored seed-color setting and a picker UI, not a redesign. |
| 21 | A "question" feature on the SRS card back — ask something about the word and get an answer | ⬜ open | Large | Implies an answering engine (an LLM call), a real scope decision against the offline-only stance — or else it's "just" a stored Q&A note with no automatic answer. |
| 22 | *Other idea:* a separate app that turns a Google search into a flashcard | 💡 idea | — | Explicitly a different product concept, not a Word Wizard feature — noted for the record, not sized or scheduled. |

---

## Appendix

### Open questions

- Frequency source for ranking — SUBTLEX-US vs. Google Books Ngrams vs. a GRE/SAT-specific list; affects which ~15k words land in the bundled core set.
- Whether "Hard" needs its own interval formula or can reuse Anki's simpler `interval × 1.2` approximation used above.
- Whether the Reader tokenizer needs real lemmatization or whether the `forms` table lookup is sufficient — likely sufficient, since Kaikki's form data already covers irregular inflections.

### Sources

- [Japanese — App Store listing](https://apps.apple.com/us/app/japanese/id290664053) (renzo Inc.) — ratings, size, platform support, version history, feature bullets.
- [Japanese — Google Play listing](https://play.google.com/store/apps/details?id=com.renzo.japanese) (com.renzo.japanese).
- [japaneseapp.com/support/ios](https://www.japaneseapp.com/support/ios/) — SRS description, list/study flow, romaji toggle.
- [japaneseapp.com/features](https://www.japaneseapp.com/features/) — full feature list, import sources, backup/restore, split view.
- [Kaikki.org English Wiktionary extract](https://kaikki.org/dictionary/English/) — data source for Word Wizard's dictionary content.

---

*Word Wizard design doc · not affiliated with renzo Inc. · a browsable rendering of this content is also published as a [Claude Artifact](https://claude.ai/code/artifact/2a88c5f7-a49d-41c6-bcb5-ba549eb0b22a).*
