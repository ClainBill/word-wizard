# Lexery — design doc

**Version** 0.6 · **Date** 2026-09-06 · **Author** willcharlesgill · **Platform** Flutter · iOS + Android · **Distribution** personal use, unlisted

An offline, ad-free advanced-English vocabulary dictionary and flashcard app for Flutter — functionally reverse-engineered from renzo Inc.'s *Japanese* app, retargeted from Japanese-for-English-speakers to advanced-English-for-fluent-speakers.

**Name:** *Lexery* — *lexicon* + *library*. It names the app and, in the second sense, the user's own growing collection of words: a word card's enrol button reads **Add to Lexery** (→ *In Lexery* once it is), while the study session, Study tab and everything about reviewing keep the plain word *study*. (Renamed from *Word Wizard* on 2026-09-14; that name was already taken. Package, bundle and channel identifiers still say `word_wizard` / `wordwizard` — those are not user-facing and a rename would touch every import.)

**App icon:** a cream "L" monogram (Fraunces, WONK on) set left of centre, with a bookmark ribbon hanging from the top edge at the right — the *library* half of the name — on a solid `#8A5A22` field. Rendered by `tool/render_icon.py` from the Fraunces variable font; used as the full-bleed iOS icon, the Android adaptive icon (foreground glyph + solid-color background layer) and, as a plain white silhouette, the status-bar notification icon.

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

What Lexery is for, who it's for, and what it deliberately isn't.

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

| renzo feature | Lexery equivalent | Priority |
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
| 📄 Reader | Whatever you last copied, laid out as a page — every word tappable, list/study words colour-coded; keeps a history |
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
| Reader | Pulls new clipboard text in on every visit (HTML flavour too, so headings/bold survive) and lays it out as a paper page; words in lists get that list's highlighter colour, studied words an underline, uncommon words a dotted one, with a legend strip that toggles each; tap → peek panel (senses, IPA, add-to-list/study/card), long-press → full card. History of every text shown; write/edit text by hand; reading options (text size, uncommon marking) | Tab bar |
| Reader History | Every text the Reader has shown, newest-opened first; tap to reopen, swipe to remove, clear all | Reader |
| Lists | Grid of custom lists + curated packs, each with a card count and due count | Tab bar, "Add to list" on any entry |
| List Detail | Word table for one list; a ▶ Study action bulk-enrolls the whole list; a ⋮ menu resets/pauses/resumes/removes every studying word in it | Lists |
| Study Session | One card at a time, front (word) → reveal (definition/example/note) → a small comprehension mini-exercise → four-button SM-2 grading; a ⋮ menu removes the current word from study without leaving the session | Study tab, List Detail |
| Progress Dashboard | Cards due today, streak, 14-day forecast, and a tappable progress bar at the top (mastered / reviewing / learning / in lists, proportional to word counts) | Study tab |
| Progress screen | Every metric the app keeps, in units — no composite score; "words mastered" is the only headline. Study (reviews, time, mature-card retention, streak), games per difficulty (solved, clean, best, typical time), lookups (with repeat lookups offered for study), reading, a 12-week activity heatmap, and a text share card | Study tab → progress bar |
| Manage Study Words | Every word in the SRS pool with stage badge, review count; Pause/Resume, Reset, Remove | Study tab |
| Games → Crossword | Daily 5×5/9×9/17×17 crossword built to American/NYT convention (180° symmetry, min entry length 3, fully checked, connected), anchored on the SRS pool with a day-of-week theme; saves/resumes state; an app-bar chip counts how many of today's words came from the study pool. Generator ported from `PORTING_SPEC.md` | Games tab |
| Settings | Theme, TTS voice/rate, notification time, backup/export, import, data source attribution; **OpenAI API key** (user's own, kept in the platform keystore, checked against OpenAI before saving) which enables the crossword AI editor and the feature-clues recall game | Tab bar |

---

## Data model

Two databases: a read-only dictionary shipped as an asset, and a small read-write store holding everything the user creates.

### `dictionary.db` — read-only, generated by the content pipeline

| Table | Key fields | Notes |
|---|---|---|
| `entries` | id, headword, pos, frequency_rank, etymology | One row per lemma+POS pair; rows sharing a headword are merged into a single card at query time |
| `senses` | id, entry_id, gloss, order | 1:N — a word can have several definitions |
| `examples` | id, sense_id, text, source | From Wiktionary quotations/usage lines |
| `examples_fts` | text (FTS5 over `examples`, porter-stemmed) | Topic index over the sentences: the study session's "which sentence wants this word?" game ranks distractors by shared content words so they can't be told apart on subject alone. Optional — an older `dictionary.db` without it falls back to random sentences |
| `pronunciations` | entry_id, ipa, audio_hint | `audio_hint` feeds device TTS phonemes, not a stored audio file |
| `forms` | form_text, entry_id, form_type | Inflections — powers conjugation search and inflected-word tap-through |
| `morphemes` / `morpheme_entries` | — | Curated root/prefix/suffix reference (v2) |
| `entries_fts` | FTS5 virtual table | Indexes headword + forms for instant prefix search |

### `user.db` — read/write, on-device only

| Table | Key fields | Notes |
|---|---|---|
| `lists` | id, name, kind, parent_id, created_at | `kind`: custom \| curated \| folder. `parent_id` self-references `lists.id` (null = top-level) — a folder is just a `lists` row other rows can nest under, arbitrarily deep |
| `list_items` | list_id, entry_id, note, added_at | Also stores the user's free-text note per word |
| `study_cards` | entry_id, **direction**, state, ease_factor, interval_days, repetitions, due_at, paused | One SRS record per **(entry, direction)** — `direction` is `w2m` (see the word, recall the meaning) or `m2w` (see the meaning, produce the word), and a word studied both ways holds two independently-scheduled rows. `paused` excludes a card from due/dashboard/forecast/reminders without discarding progress; a direction the user has switched off is excluded the same way, and keeps its history |
| `study_senses` | entry_id, sense_id, excluded | The user's decisions about a word's meanings. A row with `excluded = 0` is a **pin** (the card shows exactly the pinned senses); `excluded = 1` keeps that sense off the random draw. Set from the entry screen: hold a meaning to pin (✓), keep holding through a second haptic to exclude (⊘) |
| `entry_notes` | entry_id, markdown, updated_at | Rendered on Entry Detail and mirrored onto the SRS review-card back |
| `review_log` | card_id, reviewed_at, grade, prior_interval, duration_ms | Append-only history. `duration_ms` is how long the card was on screen, capped at 2 min; 0 for reviews credited outside a session (a crossword solve) |
| `settings` | key, value | Theme, TTS voice, reminder time |
| `reader_documents` | title, source, blocks_json, preview, content_hash, word_count, created_at, opened_at, open_seq | The Reader's history. `blocks_json` is the text as headings/paragraphs/quotes/list items with bold/italic/underline runs (`ReaderBlock`); `content_hash` dedupes a re-copy; `open_seq` orders "most recently opened" exactly (DateTimes are stored to the second) |
| `crossword_puzzles` | puzzle_date, difficulty, grid_json, progress_json, completed | One row per generation (a day can hold several — "Start new" adds one); `progress_json` is the in-progress fill, updated on every keystroke |
| `game_results` | game, difficulty, ref_id, started_at, completed_at, active_ms, aided | One row per play of a Games-tab game (`crossword` for now; later games write the same shape). `active_ms` is foreground time only, flushed as they play; `completed_at` null = abandoned; `aided` = any cell revealed, which keeps the time out of personal bests |
| `search_log` | query, searched_at | The Search tab's recent-searches list. One row per distinct query, re-inserted on repeat so id order is recency. Not a progress metric |
| `lookup_log` | entry_id, headword, source, looked_up_at | Words looked up: searched for on the Search tab **and opened**. Nothing else writes here — opening a word from a list/reader/crossword is browsing. Append-only, so repeat lookups are visible (the progress screen offers to add those to study) |

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
    crossword/          # word_list, skeleton, solver, themes, clues, generator
                        #   — the PORTING_SPEC.md port; see its header comments
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
| 3 · Reading | Reader tab, tokenizer, inflection index, conjugation search | **Done 2026-09-11** — copy a paragraph anywhere, open the tab, tap any inflected word, get the right lemma; list words lit up in their list's colour |
| 4 · Polish | Curated list packs, dark mode, backup/export, tablet layout, Anki import, reminders | Feature-complete against the Feature map's v1/v2 rows |

---

## Backlog

Every idea raised after the MVP shipped, in the order they were raised, with what's actually built versus what's still open.

> **2026-09-06 audit:** of the 21 numbered ideas below, 9 were already fully built (4 of those were sitting unchecked in the source notes purely because no one had gone back to confirm them), 3 are partially built, and 9 are still open. The 2026-09-06 session shipped the four quickest wins found during the audit — the tappable-word feature and its stacked-sheet lookup turned out to satisfy two separate ideas (#10 and #15) at once.

| # | Idea | Status | Lift | Notes |
|---|---|---|---|---|
| 1 | SRS study screen: tap or swipe up to pop the full word card up from below | ✅ done | — | Shipped before this audit. |
| 2 | Crossword clues should favor real, commonly-used words — cut initialisms, drop forced symmetry | ✅ done | — | Superseded by the `PORTING_SPEC.md` port: fill comes from a scored word list restricted to recognizable vocabulary, so any valid fill is a publishable one. Initialisms are scored down and filtered out of the short-entry pool. Symmetry is now *kept* deliberately — it is what makes the grids fillable (spec §10.1), not decoration. |
| 3 | Show a counter of how many crossword words came from the SRS pool, in the corner | ✅ done | Quick | **Shipped 2026-09-06.** Puzzle words carry a persisted `fromStudyPool` flag; an app-bar chip shows the count. |
| 4 | Search: a trailing space should cut a word off for an exact match ("muse " excludes "museum") | ✅ done | — | Found already built during the audit, just unchecked in the source notes. |
| 5 | Group lists into folders — folders behave like lists but can also nest other lists and words | ✅ done | Large | **Shipped 2026-09-11.** A folder is just a `lists` row (`kind = 'folder'`) that other `lists` rows nest under via a new self-referential `parent_id` (schema v10) — nesting is arbitrarily deep, and a folder holds words directly the same way a plain list does, since `list_items` doesn't care about the owning row's kind. Every existing per-list action (▶ Study, reset/pause/resume/remove, due queue) now resolves its target through a `WITH RECURSIVE` subtree query (`lib/data/repositories/list_hierarchy.dart`) instead of a single `list_id = ?` filter, so they work on folders — recursively, across nested lists — with no branching in the UI or call sites; a plain list's subtree is just itself, so its behavior is unchanged. Lists screen and List Detail both gained "New folder", move-to-folder, and delete (list-level delete didn't exist in the UI before this). |
| 6 | Crossword should save its state on quit and resume later | ✅ done | — | Found already built during the audit — every keystroke persists progress against that day's puzzle row. |
| 7 | SRS review options: quiz from the meaning instead of the word (either direction, or both) | ✅ done | Medium | **Shipped 2026-09-10.** Not a toggle over one card but a second card: `study_cards` gained a `direction` column and a composite `UNIQUE(entry_id, direction)` (schema v9), so each direction carries its own ease/interval/due date/review log — receptive and productive knowledge of a word are different memories that decay at different rates. The picker lives in a study-options sheet reachable from the session's progress bar. Switching a direction off never deletes its cards; switching "both ways" on backfills reverse cards that inherit their sibling's due date rather than all becoming due today; a word's two cards are spaced apart in the queue so the second isn't answered off the first's short-term memory. |
| 8 | Crossword text input should skip over cells that already have a letter in them | ✅ done | Quick | **Shipped 2026-09-06.** Typing through a word skips cells a crossing word already filled, jumping to the next word once nothing's left empty. |
| 9 | SRS comprehension mini-exercises under the flipped card (sentence/synonym/definition matching, spelling, etc.) | ✅ done | Medium | **Rebuilt 2026-09-10.** The earlier set all tested producing *the word*, which on a word→meaning card is a spelling test rather than a memory jog — the missing half was the meaning. Games are now keyed to a `RecallTarget`: the pre-reveal jog exercises the side you were asked for, the post-reveal panel exercises the other, so every review touches both halves once. Eight visual games (`lib/features/study/recall_games.dart`): Crack the word, Fill the gap, Sound it out, Spell it out (the word's letters plus common-letter decoys on a small keyboard, so the key set gives nothing away), Guess from the clues, Which meaning is it?, Where does it belong?, Rebuild the meaning. Example-sentence matching ("Where does it belong?") closes the last open item here. |
| 10 | From the full card during SRS, tap a word in the description/example to add it to a list — without leaving SRS | ✅ done | Medium | **Shipped 2026-09-06** — via the tappable-word feature (#15): tapping a word pops its own card up as a stacked sheet, with its own Add-to-list/Study buttons, on top of the study session. |
| 11 | Remove a word from SRS without leaving the session (via an ⋮ menu) | ✅ done | Quick | **Shipped 2026-09-06.** The repository-level remove already existed (Manage Study Words); this wires a confirm-and-remove menu into the study session card itself. |
| 12 | A Games tab with an intelligent daily Crossword/Strands-style game built from SRS words — prefer no cloud API | 🟡 partial | Large (remaining) | Games tab + daily Crossword exist; the generator was rebuilt from `PORTING_SPEC.md` (offline, deterministic per day, CSP fill over a scored word list, SRS words as anchors). A Strands-style word-search mode is unbuilt. |
| 13 | A spelling test for complicated SRS words, in the Games tab | 🟡 partial | Medium (remaining) | The scrambled-letter "Spell it" exercise exists inline in SRS study (#9). A standalone, difficulty-targeted version in the Games tab isn't built. |
| 14 | Full documentation of every feature, accessible inside the app | ⬜ open | Medium | Mostly a content-writing task once a Settings → Help screen exists; this doc is the closest thing to that content today. |
| 15 | Click any word in a card to pull up that word's own card — especially in examples and word origin | ✅ done | Medium | **Shipped 2026-09-06.** Every word in a gloss, example, or etymology line is tappable (dotted underline); resolves inflected forms too. |
| 16 | Consolidate British/American (or other) spelling variants into one card | ⬜ open | Large | Depends on the content pipeline detecting and cross-linking variant spellings — a data problem more than a UI one. |
| 17 | Import a list from a pasted string of words | ⬜ open | Medium | Parse + batch-lookup is straightforward; the real work is UX for words that don't resolve or resolve ambiguously. |
| 18 | Read words aloud with correct pronunciation during SRS study (UK English first, US later) | ⬜ open | Medium | `flutter_tts` is already wired into Entry Detail's pronounce button; wiring the same call plus a UK/US voice setting into study is the remaining work. |
| 19 | Rehaul the app's look, feel, and logo — grainy, papery, analogue "old dictionary" aesthetic | ⬜ open | Large | The current theme already leans warm-paper in color only; an actual grain/paper texture treatment is a real visual-design pass. |
| 20 | Colour theme customization in Settings | ⬜ open | Medium | The theme is already seed-color-driven (`ColorScheme.fromSeed`); needs a stored seed-color setting and a picker UI, not a redesign. |
| 21 | A "question" feature on the SRS card back — ask something about the word and get an answer | ⬜ open | Large | Implies an answering engine (an LLM call), a real scope decision against the offline-only stance — or else it's "just" a stored Q&A note with no automatic answer. |
| 24 | Enter my own OpenAI API key in the app | ✅ done | Small | **Shipped 2026-09-11.** Settings → AI features. `ApiKeyStore` (flutter_secure_storage) with a Check/Save/Remove sheet; services prefer proxy → user key → debug define. See APP_INTEGRATION.md §4 for why a user's own key is allowed where a bundled one is not. |
| 23 | Text clipboard analyser tab, with history | ✅ done | Large | **Shipped 2026-09-11** as the Reader tab (`lib/features/reader/`, `ReaderRepository`, `ClipboardService`, schema v11). Auto-pulls new clipboard text (3+ words) on every tab visit / app resume, resolving each word to its canonical entry in two batched lookups (`analyze`); marks are a live layer over that (`watchMarks`) so adding to a list from the page lights the word up at once. Android hands over the clipboard's HTML flavour through a small method channel, and checks the clip *timestamp* before reading content — Android 12+ toasts on every content read. Page look: paper sheet, serif, dateline, headings/quotes/lists, per-list highlighter colours, studying underline, uncommon dotted underline, legend chips that toggle each. Open: share-sheet intake, in-page text selection. |
| 22 | *Other idea:* a separate app that turns a Google search into a flashcard | 💡 idea | — | Explicitly a different product concept, not a Lexery feature — noted for the record, not sized or scheduled. |

---

## Appendix

### Open questions

- Frequency source for ranking — SUBTLEX-US vs. Google Books Ngrams vs. a GRE/SAT-specific list; affects which ~15k words land in the bundled core set.
- Whether "Hard" needs its own interval formula or can reuse Anki's simpler `interval × 1.2` approximation used above.
- ~~Whether the Reader tokenizer needs real lemmatization or whether the `forms` table lookup is sufficient~~ — resolved 2026-09-11: the `forms` lookup is sufficient (with a possessive strip and a hyphen-split fallback on top); the one wrinkle is words that are both a headword and a form ("running"), which the Reader handles by carrying the lemma alongside and preferring whichever is in a list.

### Sources

- [Japanese — App Store listing](https://apps.apple.com/us/app/japanese/id290664053) (renzo Inc.) — ratings, size, platform support, version history, feature bullets.
- [Japanese — Google Play listing](https://play.google.com/store/apps/details?id=com.renzo.japanese) (com.renzo.japanese).
- [japaneseapp.com/support/ios](https://www.japaneseapp.com/support/ios/) — SRS description, list/study flow, romaji toggle.
- [japaneseapp.com/features](https://www.japaneseapp.com/features/) — full feature list, import sources, backup/restore, split view.
- [Kaikki.org English Wiktionary extract](https://kaikki.org/dictionary/English/) — data source for Lexery's dictionary content.

---

*Lexery design doc · not affiliated with renzo Inc. · a browsable rendering of this content is also published as a [Claude Artifact](https://claude.ai/code/artifact/2a88c5f7-a49d-41c6-bcb5-ba549eb0b22a).*
