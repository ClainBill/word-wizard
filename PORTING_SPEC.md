# Crosswordler — Portable Algorithm Specification

**Audience:** an engineer or agent implementing this crossword generator in
another language (target: Dart/Flutter, but nothing here is language-specific).

**Status of the numbers in this document:** every constant marked *(measured)*
was determined empirically against a real word list, not chosen by intuition.
Changing them will change output quality and speed, sometimes drastically —
§10 records what was tried and failed, so you don't repeat it.

**Reference implementation:** Python, in `src/crosswordler/` of this repo. Where
this document and the code disagree, the code is authoritative; please update
this document.

**Wiring this into the Flutter app? Read `docs/APP_INTEGRATION.md` first.**
This document specifies the *algorithm*; that one specifies the contract
between the app and the engine — what the app must supply (SRS words, solve
events), where the LLM call belongs, and what must never happen (an API key in
the binary, a network call on the click path).

**Read Appendix A first if you are deciding what to build.** It lists the
product requirements this design is contractually bound to (sourced from
`Crosswordler Instructions.md`), marks which are met, partial, or missing, and
records the two requirements that were deliberately overridden and why. Several
behaviours that look like implementation details — the grid density, the
restricted word pool — are direct consequences of those rules.

---

## 1. The single most important design decision

**Split the system into build-time and run-time.**

| | build time (offline, once) | run time (in your app) |
|---|---|---|
| Language | Python (or anything) | your target language |
| Inputs | ENABLE1 word list, `wordfreq`, WordNet | the generated asset file |
| Output | one JSON/binary word-list asset | a finished puzzle |
| Cost | seconds to minutes | ~0.04s (9x9), ~1-8s (17x17) |

All the natural-language machinery — corpus frequency lookup, WordNet senses and
glosses — happens **at build time** and is baked into a static asset. The runtime
algorithm needs no NLP library, no dictionary API, and no network. It is pure
data structures and search.

This is what makes the port tractable: you are not reimplementing `wordfreq` or
WordNet in Dart. You are shipping a file and implementing a constraint solver.

---

## 2. The asset: scored word list

Produce one file (JSON is fine; a packed binary is better for app size) that is
an array of entries:

A real record, copied verbatim from the exporter's output:

```jsonc
{
  "text":         "MEDICALEXAMINER", // grid form: A-Z only, uppercase, no spaces/punctuation
  "display":      "medical examiner",// human form, may contain spaces/apostrophes ("I dos")
  "freq_zipf":    3.51,        // Zipf frequency, ~0.0 (never seen) to ~7.0 (the/of/and)
  "synset_count": 0,           // count of WordNet *common-noun* senses (see 2.2)
  "is_proper":    false,
  "is_phrase":    true,
  "tags":         [],          // free-form category tags; see note below
  "score":        9.02,        // precomputed composite quality (formula in 2.3)
  "editor_tier":  51,          // the Nediger tier (see 2.1a); 0 = absent from that list
  "clues": [                   // 1-2 options, best first; see §8 / §2.5
    {"text": "Coroner", "type": "synonym"},
    {"text": "A public official who investigates by inquest any death not due to natural causes",
     "type": "definition"}
  ]
}
```

`clues` is a **list** because the same answer recurring across puzzles should
not always carry the same clue — the brief's "vary clue types" requirement.
Measured: **64% of the fill pool has 2 options**, from WordNet's other senses
and co-lemmas plus the build-time LLM backfill (§2.5 step 4). `type` is one of
`curated | synonym | definition | fill_in_blank | llm`.
Pick among them with the puzzle's seeded RNG so a seed still reproduces a
puzzle exactly (§8).

`length` is derived (`text.length`) — don't store it.

Three things this example usefully shows:

- **`tags` is empty for the overwhelming majority of entries.** Only the ~80
  hand-curated supplement rows carry tags; ENABLE1- and Nediger-derived entries
  have none. Anything keying off tags (Wednesday's `general_knowledge` category,
  Tuesday's `pop_culture`) is therefore selecting from a very small pool. This is
  a known limitation, not a bug in your port — see §13.
- **`text` and `display` diverge for multi-word entries**, and both are needed:
  `text` is what goes in the grid, `display` is what the solver is shown and
  what the build-time clue derivation looks up in WordNet (§2.5 step 0).
- **The two clue options are deliberately different types.** A terse synonym and
  a definition, so a recurring answer doesn't read identically twice. Sense
  selection is still imperfect — LANDSLIDE draws "An overwhelming electoral
  victory", correct but not the geological reading most solvers reach for. That
  is the §8 sense-selection gap in miniature.

**Generate it with the bundled exporter** — this is the only build-time step you
need, and it emits exactly the schema above:

```bash
PYTHONPATH=src python3 tools/export_wordlist.py \
    --out wordlist_asset.json --min-zipf 2.5 --require-clue
```

Measured output: **72,214 entries, 22.8 MB raw JSON (3.7 MB gzipped), 100%
carrying at least one clue and 64% carrying two.** Drop the entries with
`editor_tier == 25` and that is the runtime fill pool exactly — 71,321 (§6.3).
Dropping `--min-zipf --require-clue` gives the full 402,231 entries, which you
only need if you want anchors and theme entries drawn from rarer vocabulary
than the fill pool. Both compress well; consider a packed binary format if app
size matters.

### 2.1 Sources and licensing

| source | role | license |
|---|---|---|
| **Nediger list** (`data/raw/nediger-list.txt`) | **curated crossword answers with a constructor's quality tier; source of multi-word/colloquial entries** | **MIT** (© bewilderingly) |
| ENABLE1 | base word list (~172k) | public domain |
| `wordfreq` (PyPI) | `freq_zipf` | Apache 2.0 (code); CC-licensed data, attribution |
| WordNet (Princeton) | `synset_count`, `clue` glosses | permissive, commercial use explicitly allowed |
| curated supplement (`data/raw/supplement.tsv`) | phrases, proper nouns, slang, abbreviations | authored here |

Do **not** substitute TWL/SOWPODS (proprietary), IMDb datasets (license bars
commercial use), or Urban Dictionary (no clean license). See `docs/research.md`
§4 for the full analysis and for the richer sources (Wiktextract, Wikidata) that
are the recommended next expansion.

### 2.1a The Nediger tier field (`editor_tier`)

A working constructor's judgement of each entry, and the most valuable single
signal in the asset. **Its values are not a quality ladder** — read
`data/raw/nediger-README.md`, not the numbers:

| tier | meaning | how we use it |
|---|---|---|
| 99 | <=7 letters: "very easy and/or inferable"; >=8: "would be considered assets" | small bonus when short (frequency already covers "easy"), larger from 8 letters up |
| 51 | "entries I'll use in most circumstances" | normal usable fill |
| 49 | "**likely too racy for many mainstream venues**" | **excluded at load** — content, not quality, and this ships in a vocabulary app |
| 25 | "only if absolutely necessary" | excluded from the fill pool |
| 0 | absent from the list | mild penalty only; the list legitimately omits many inflected forms we still want |

Two traps worth restating: tier 49 is a **content** warning that a naive
"higher is better" reading would let through, and tier 99 does **not** mean
"interesting" at short lengths. The list's own README also warns that "the 51 vs
99 scoring for long entries is very sporadic and unsystematic", so don't lean on
it as a fine-grained interestingness score.

The tier also earns its keep as a filter frequency cannot replicate: `ONI`,
`MES` and `HET` all clear the zipf floor but are tier 25, while `OLA`, `RES` and
`SSE` look equally odd yet are tier 51 — a constructor would use them.

### 2.2 `synset_count` must exclude proper-noun senses

WordNet distinguishes a *class* sense ("cat" → feline mammal) from an *instance*
sense ("oran" → a specific Algerian city, exposed via `instance_hypernyms()`).
ENABLE1 is all lowercase, so a place name can masquerade as an ordinary word.
Count only senses with **no** instance hypernyms. Otherwise proper nouns get an
undeserved "well-attested common word" score bonus.

### 2.3 Score formula *(measured)*

```
deficit            = max(0, 3.0 - freq_zipf)
obscurity_penalty  = deficit^1.7 * 1.1        // superlinear: rare words fall off a cliff
sense_bonus        = min(synset_count, 5) * 0.3
crosswordese_pen   = 4.0 if text in CROSSWORDESE else 0
short_obscure_pen  = 2.0 if (length <= 4 and freq_zipf < 2.0) else 0
phrase_bonus       = 1.0 if is_phrase else 0

editor_term        = -1.0 if editor_tier == 0        // absent from the list
                     -3.0 if editor_tier <= 25       // "only if absolutely necessary"
                      2.5 if editor_tier >= 99 and length >= 8   // a genuine asset
                      0.5 if editor_tier >= 99       // short + 99 just means "easy"
                      1.0 otherwise                  // tier 51: normal usable fill

score = freq_zipf * 2.0
      + sense_bonus + phrase_bonus + editor_term
      - obscurity_penalty - crosswordese_pen - short_obscure_pen
```

**`freq_zipf` for a multi-word entry must be capped at 4.0 when the asset is
built.** wordfreq cannot measure a phrase: it combines constituent frequencies
under an independence assumption, so what it returns is an upper bound set by
the rarest word, not evidence the phrase is ever said. It scores `the the` at
7.43, `on it` at 6.63 and `up to` at 6.35 — above almost every real word, on a
term that is doubled in the formula. Uncapped, the ~197k multi-word entries
crowd out ordinary vocabulary and anchor selection opens a puzzle with THE THE.
Only the top is clipped; low values are still informative (`abandonware` 1.42,
`nuff said` 2.61). For phrases the load-bearing recognizability signal is
`editor_tier`, not frequency.

`CROSSWORDESE` is a small hand-maintained denylist of words that are technically
valid but appear in crosswords far out of proportion to real usage: `ANOA ETUI
ERNE ESNE OLEO EPEE ANTA ARIL ORLE ULNA UTA ENOL ESTOP ALOE ERG ERGS OBI OBIS
AGA AGAS ARGOT ONAGER SNEE STOA TOLA ULEMA NENE AALII OAST EELY ERNES ESES
ESNES`. Extend it as you find offenders.

### 2.4 Inclusion filter *(measured — read the warning)*

Include an ENABLE1 word if `3 <= length <= 17` **and**:

```
if length <= 6:  require freq_zipf >= 0.01   // i.e. reject "never observed in any corpus"
else:            no frequency requirement
```

**Do not apply the frequency floor at lengths above 6.** It is tempting — those
lengths contain plenty of junk too — but it was measured and it *breaks the
solver*: cutting ~50% of the 8- and 9-letter pool removes the letter-pattern
diversity the search needs, and 9x9 fill success dropped to 0/4. Short lengths
are where obscure fill is both most jarring and most avoidable (thousands of
alternatives exist); long lengths are where the solver has the least slack.

Supplement entries override ENABLE1 entries with the same `text` (they carry
better `display` forms and tags).

### 2.5 Clue derivation (build time)

You only need this if you regenerate the asset; otherwise consume `clue` and
`clue_type` as given. Each step below fixes a measured failure.

**Step 0 — look the entry up under WordNet's own key.** WordNet indexes a
multi-word entry under its spaced form joined with underscores
(`ice_cream`), never the run-together grid form (`icecream`). Deriving the key
from `display` (lowercase, every run of non-alphanumerics → `_`) and falling
back to `text` finds **28,340** phrase entries that looking up `text` alone
misses — 19× the phrase coverage, and the single largest cause of unclued
entries. The key it returns is then used for every WordNet call below.

**Step 1 — curated table wins.** `data/raw/function_clues.tsv` supplies
hand-authored clues (currently 95 rows) for words WordNet has no entry for.
Only ~4% of the pool lacks a gloss, but they are the *most frequent* words
(THE, AND, YOU, pronouns, prepositions), so they appeared constantly in fill —
11% of generated clues were placeholders before this table existed. The table
also overrides glosses that are correct-but-wrong-domain, e.g. `ESS` (WordNet
gives einsteinium; the table gives "Curve shape").

**Step 2 — pick the sense a reader would actually mean.** Not `synsets[0]`.
Two failure modes, handled differently:

- *Wrong lemma entirely* — the real bug. WordNet matches morphological
  variants, so "has" also matches "ha" (hour angle) and "was" matches
  Washington. Restrict candidate lemmas to `{word} ∪ morphy(word, pos) for all
  pos`, then score each synset by the corpus frequency of its best allowed
  lemma (+1.5 if it matches the surface form exactly). Note that
  frequency *alone* is not enough — it must be gated by `morphy` first,
  because "uses" otherwise scores the United-States synset highest ("US" has
  pronoun-level frequency and "us"+"es" spells the target), producing
  "North American republic containing 50 states" as the clue for USES.
- *Wrong sense of the right lemma* — genuinely ambiguous (ABANDON the noun or
  the verb?). Reranking here is noise, so among synsets tied on lemma quality
  keep WordNet's own order, which is frequency-of-use ordered.

**Step 2b — collect a second option.** Walk the remaining WordNet senses
(best-sense-first, deduped on the first 40 characters) and keep up to
`MAX_CLUES_PER_ENTRY` (2) usable clues. This costs nothing and covers 54% of
the pool. It also *grows* the pool: a word whose best sense is unusable may
have a later sense that works, which is why enabling this took the clued pool
from 32,309 to 33,518 entries.

**Step 2c — synonym clues from synset co-lemmas.** A synset *is* a set of
interchangeable lemmas, so the answer's siblings are ready-made one-word clues
in the register a newspaper actually uses: `'HOOD` → "Punk", CEDE → "Yield",
MEDICALEXAMINER → "Coroner". Without this every clue in the asset was a gloss,
i.e. read like a dictionary. Four guards, each covering a wrong clue the naive
version emitted:

1. **The answer must itself be a lemma of the synset**, compared on the spaced
   form. WordNet matches inflections, so RUNS resolves to the synset of "run",
   whose co-lemmas ("operate", "flow") don't agree with the answer in number
   or tense. Exact lemma membership is the cheapest correct guard.
2. **The sense must be one the answer is actually used in.** Synonymy is
   symmetric; salience is not. "cat" is a listed lemma of the synset headed by
   "guy", so a naive pass clues CAT as "Guy". WordNet's sense-tagged counts
   separate the cases exactly (`cat`: 18 in the feline synset, 0 in guy's), so
   take senses where the answer's own lemma has `count > 0`, and where the
   corpus is silent for every sense, fall back to the single best sense only.
3. **The synonym must be a word the solver knows** — Zipf ≥ 3.0 measured on
   its *rarest* constituent word, so an obscure term can't hide inside a
   familiar phrase ("eighter from Decatur"). At most 3 words, at least 3
   letters, no digits.
4. **No shared root.** WordNet groups genuinely different roots in one synset
   (HOOD/hoodlum, CEDE/concede), and the general giveaway filter (§8) misses
   these: a 4-letter answer is too short for its substring rule. Reject when
   either string contains the other, or when they share a 4-character prefix.
   Keep the check this narrow: pertainyms link *different* roots, so
   NASAL/NOSE must survive.

Skip any synset that lists a bare digit as a lemma. Those are the number
synsets, and their co-lemmas are uniformly bad clues — numerals ("8", "VIII",
"viii"), dice slang ("Nina from Carolina") and technical rarities ("ogdoad").
Their glosses are fine and are the standard crossword treatment anyway.

Within a synset, order candidates by sense-tagged count descending, then
corpus frequency: for HOOD that picks "Punk" over the commoner but
adjective-reading "Tough".

**Step 2d — interleave the two sources.** Round-robin synonyms against
definitions rather than exhausting either. With `MAX_CLUES_PER_ENTRY = 2` that
yields a terse synonym *and* a definition, so a repeated answer reads
differently across puzzles; taking synonyms first would spend both slots on
one clue type. Measured over the fill pool: 61,929 definition, 14,094 synonym,
12,171 fill-in-the-blank, 163 curated.

**Step 3 — salvage a gloss that leaks its own answer.** ~7% of clues were
being discarded by the giveaway filter (§8) when the gloss itself was fine.
In order:

1. *Drop the offending clause.* Glosses are often semicolon-separated
   alternatives and the leak is confined to one. EEL: "The fatty flesh of eel;
   an elongate fish found in fresh water in Europe and America; large eels are
   usually smoked" → "An elongate fish found in fresh water in Europe and
   America".
2. *Redact whole-word occurrences* (the answer plus `s/es/ing/ed/er/ers`) as
   `___`, giving a fill-in-the-blank — a clue type the brief asks for. MACH:
   "…who introduced the ___ number…". Then drop any clause reduced to nothing
   but a blank, so you don't emit trailing "; ___".
3. Otherwise the word has **no clue** and is excluded from the fill pool.

Both salvage paths must check the result is *substantive* (≥3 words and ≥15
characters). Without that guard CAT loses both meaningful clauses to the leak
check and gets clued as, simply, "Wildcats". Synonym clues are exempt: being
short is the point of them.

**Leak checks run against every constituent word of a multi-word answer**, not
just the joined grid form. WordNet glosses `ice cream` as "frozen dessert
containing cream and sugar and flavoring" — a clean leak that
`isGiveaway(clue, "ICECREAM")` cannot see, because "cream" is neither a stem
variant of nor a substring match for the joined form. Build the leak-form list
once per entry (`text`, plus every `display` token of 3+ letters) and check the
clue against each; redaction (step 3.2) uses the same list, which is what turns
that gloss into "Frozen dessert containing ___ and sugar and flavoring".

---

## 3. Runtime data model

```
Entry   { text, display, freq_zipf, synset_count, is_proper, is_phrase, tags, score, clue }

Slot    { slotId:int, number:int, direction:ACROSS|DOWN, row:int, col:int, length:int,
          crossings: Map<int cellIndexInThisSlot, (int otherSlotId, int indexInOtherSlot)> }

Grid    black: bool[n][n]        // true = black square

Puzzle  { size, weekday, grid: (string|null)[n][n], slots, fill: Map<slotId,string>,
          entries: Map<slotId,Entry>, clues, themeName, themeKind, qualityScore, anchors }
```

`Slot.cells()` yields the slot's cell coordinates in order:
across → `(row, col+i)`; down → `(row+i, col)` for `i` in `0..length-1`.

---

## 4. Grid skeleton generation

Produces `black[n][n]`. This step is **where puzzle quality and solvability are
actually determined** — see §10.1.

### 4.1 Structural rules (American/NYT convention)

1. **180° rotational symmetry**: `black[r][c] == black[n-1-r][n-1-c]`.
2. **Minimum entry length 3**: every maximal run of white cells in any row or
   column has length 0 or >= 3.
3. **Full checking**: every white cell belongs to both an across and a down
   entry (follows from rules 2 + connectivity for these grid shapes).
4. **Connectivity**: all white cells form one orthogonally-connected component.

Helper predicates:

```
rowRunsOk(black, r):  scan row r; every maximal white run has length 0 or >= 3
colRunsOk(black, c):  same down column c
connected(black):     flood-fill from any white cell (4-neighbourhood);
                      reached count == total white count
```

`enumerateRuns` returns every maximal white run in the grid, each as an **ordered
list of its cell coordinates** (order matters: the splitter indexes into it):

```
enumerateRuns(black, n) -> List<List<(r,c)>>:
  out = []
  for r in 0..n-1:                       // rows first
    run = []
    for c in 0..n-1:
      if black[r][c]: if run non-empty { out.add(run); run = [] }
      else:           run.add((r,c))
    if run non-empty: out.add(run)
  for c in 0..n-1:                       // then columns
    run = []
    for r in 0..n-1:
      if black[r][c]: if run non-empty { out.add(run); run = [] }
      else:           run.add((r,c))
    if run non-empty: out.add(run)
  return out
```

A run of length `L` therefore corresponds to a would-be entry of length `L`.
Rows-then-columns ordering is not semantically important (the caller shuffles),
but keeping it makes runs reproducible for a given seed.

### 4.2 The generator *(this is the important algorithm)*

Two independent controls. **Both are required** — see §10.1 for the measurements
that prove neither alone is sufficient.

```
generateSkeletonCapped(n, maxEntryLen, whiteTarget, rng,
                       reservedWhite = {}, maxAttempts = 800) -> black | null:

  maxBlack = whiteTarget == null ? null : floor(n*n * (1 - whiteTarget))

  repeat maxAttempts times:
    black = all white
    stuck = false

    // ---- Phase 1: cap entry length by splitting over-long runs ----
    loop:
      tooLong = [run for run in enumerateRuns(black, n) if run.length > maxEntryLen]
      if tooLong is empty: break
      shuffle(tooLong); stable-sort tooLong by length descending
      cells = tooLong[0].cells                    // longest run, ties broken randomly

      options = indices 0..cells.length-1, SHUFFLED     // plain random; see §10.2
      placed = false
      for i in options:
        (r,c) = cells[i]
        (pr,pc) = (n-1-r, n-1-c)                        // symmetric partner
        if (r,c) or (pr,pc) in reservedWhite: continue
        if black[r][c]: continue
        black[r][c] = black[pr][pc] = true
        if rowRunsOk(r) and colRunsOk(c) and rowRunsOk(pr) and colRunsOk(pc):
          placed = true; break
        else:
          black[r][c] = black[pr][pc] = false           // undo
      if not placed: stuck = true; break

    if stuck: continue to next attempt

    // ---- Phase 2: top up black density ----
    if maxBlack != null:
      cells = all (r,c) with r*n + c <= (n*n - 1) / 2   // one half under symmetry
      shuffle(cells)
      for (r,c) in cells:
        if countBlack(black) >= maxBlack: break
        (pr,pc) = (n-1-r, n-1-c)
        if black[r][c] or (r,c)/(pr,pc) in reservedWhite: continue
        black[r][c] = black[pr][pc] = true
        if not (rowRunsOk(r) and colRunsOk(c) and rowRunsOk(pr) and colRunsOk(pc)):
          black[r][c] = black[pr][pc] = false           // undo

    // ---- Validate ----
    if not connected(black): continue
    slots = extractSlots(black)
    if slots empty or min(slot.length) < 3: continue
    if max(slot.length) > maxEntryLen: continue         // phase 2 can't break this, but check
    return black

  return null
```

Phase 1 alone yields grids that satisfy the length cap with *minimal* black
squares (85-87% white at 17x17) — and those **fail to fill** (0/8 measured).
Phase 2's density top-up is what breaks the grid into semi-independent regions.

`reservedWhite` lets you protect cells an anchor entry must occupy. The reference
implementation does not currently use it (anchors are fitted after generation,
§7.2) — wiring it up is a known improvement.

### 4.3 Per-size parameters *(measured)*

| size | maxEntryLen | whiteTarget | achieved white | fill success | fill time |
|---|---|---|---|---|---|
| 5 (mini) | 5 | 0.84 | ~84% | reliable | ~0.1-1.5s |
| 9 (midi) | 6 | 0.78 | ~72-79% | 8/8 | ~0.04s |
| 17 (mega) | 9 | 0.72 | ~72% | 7/8 | ~0.8-8s |

`whiteTarget` is a **floor on black squares, not an exact figure**: Phase 1's
length-capping can already place more black squares than the target implies, so
achieved white % often lands below it (measured 72.8% at 9x9 against a 0.78
target). Never treat a below-target result as a failure.

Note the achieved white % is *below* the brief's 85% target, deliberately. See
§10.1 — this is the central trade of the whole design.

At 5x5 the granularity argument matters: one black square is 4% of the grid, so
an 85% target caps mini at 3 black squares, and symmetry makes that effectively
"0 or 2". 0.84 unlocks the 4-black-square patterns standard in real NYT Minis.

### 4.4 Slot extraction and numbering

Standard crossword numbering: scan cells in raster order (row 0 left→right, then
row 1, …). A white cell gets the next number if it *starts* an across entry or a
down entry. Both directions at the same cell share one number.

```
extractSlots(black) -> Slot[]:
  nextNumber = 1; slotId = 0; slots = []
  for r in 0..n-1, for c in 0..n-1:
    if black[r][c]: continue
    startsAcross = (c == 0 or black[r][c-1]) and (c+1 < n and not black[r][c+1])
    startsDown   = (r == 0 or black[r-1][c]) and (r+1 < n and not black[r+1][c])
    if not (startsAcross or startsDown): continue
    number = numberAt[(r,c)] ?? nextNumber++          // one number per cell
    // runLengthRight: count white cells from (r,c) rightward until black/edge
    // runLengthDown:  count white cells from (r,c) downward until black/edge
    if startsAcross: emit Slot(number, ACROSS, r, c, runLengthRight(r,c), slotId++)
    if startsDown:   emit Slot(number, DOWN,   r, c, runLengthDown(r,c),  slotId++)
  computeCrossings(slots)
  return slots
```

```
computeCrossings(slots):
  owner: Map<(r,c), Map<direction, (Slot, indexWithinSlot)>>
  for each slot, for each (index, cell) in slot.cells():
      owner[cell][slot.direction] = (slot, index)
  for each slot, for each (index, cell) in slot.cells():
      other = owner[cell][opposite(slot.direction)]
      if other exists: slot.crossings[index] = (other.slot.slotId, other.index)
```

---

## 5. Pattern index

Fast "which words match `C.T`?" lookups. Built once per fill pool, in **two
representations of the same buckets** — port both; they serve different callers.

### 5.1 Set form (used by `refine()` and the quality gate)

```
index[length][position][letter] -> Set<String>   // texts
byLength[length]                -> List<String>
byText[text]                    -> Entry
```

```
candidates(pattern, exclude) -> Entry[]:
  fixed = [(i, ch) for i, ch in pattern if ch != '.']
  if fixed empty:  texts = byLength[pattern.length]
  else:            texts = intersection over fixed of index[len][i][ch]
                   (short-circuit to empty as soon as the running set is empty)
  return [byText[t] for t in texts if t not in exclude]
```

A trie/DAWG is *not* needed — set intersection over these indices is fast enough,
and this structure is far simpler to port.

**You do not need a `count()` method.** The reference implementation has one (and
a `bucket_size()`), left over from an earlier variable-ordering scheme that sized
domains on demand. Neither is called from anywhere. Don't port them.

### 5.2 Bitset form *(this is what the solver uses)*

Order the entries of each length by **score, descending**, and give each one a
bit index in that order. Then every bucket above becomes an integer bitmask over
that length's words:

```
entriesByLength[length] -> Entry[]                  // score-descending
bitOf[text]             -> int                      // index within its length
posMasks[length][position][letter] -> int           // bitmask
fullMask[length]        -> (1 << entriesByLength[length].length) - 1
```

A slot's **domain is one integer**. This changes the cost of everything the
search does:

| operation | set form | bitset form |
|---|---|---|
| intersect two domains | O(n) set ops | `a & b` |
| domain size (for MRV) | `length` | `popCount(a)` |
| exclude one word | rebuild/filter | `a &= ~(1 << bit)` |
| letter support for AC-3 | O(domain) scan | ~26 bitwise ops |
| candidates in score order | sort the domain | **iterate set bits low→high** |

That last row is worth dwelling on: because bit order *is* score order, value
ordering is free. The old solver sorted a candidate list — sometimes thousands
of entries — at every single node.

```
maskFor(pattern) -> int:
  mask = fullMask[pattern.length]
  for (i, ch) in pattern where ch != '.':
      mask &= posMasks[pattern.length][i][ch]   // 0 if that letter has no bucket
      if mask == 0: return 0
  return mask

entriesIn(length, mask, limit) -> Entry[]:        // best score first
  while mask != 0 and produced < limit:
      bit = mask & -mask                          // lowest set bit
      yield entriesByLength[length][log2(bit)]
      mask ^= bit
```

**Build the masks with a byte buffer, not by OR-ing bits into an integer.** In
languages with immutable big integers (Python, Dart's `BigInt`), `mask |= 1 << i`
copies the whole value on every set bit, making construction quadratic. Fill a
`Uint8List` and convert once.

**Build them lazily, per length, on first use.** A 5x5 puzzle only ever asks
about lengths 3-5; building all 17 lengths up front is waste. Measured full
build: 0.13s for the whole 71,321-entry pool, so this is a convenience, not a
necessity.

If your target language has fixed-width integers rather than arbitrary-precision
ones, use an array of 64-bit words and write the five operations above against
it; nothing in the algorithm depends on the mask being a single value.

---

## 6. The solver

Word-level CSP: one variable per **slot**, domain = candidate words. Do **not**
model individual letters as variables — that formulation does not scale (§10.3).

### 6.1 State

```
assignment: Map<slotId, String>        // slot -> chosen word text
domains:    Map<slotId, int>           // UNASSIGNED slots only; bitmask (§5.2)
lengthOf:   Map<slotId, int>           // slot length, for indexing posMasks
```

There is deliberately **no `used` set**. The all-different constraint is
enforced by construction: when a word is placed, its bit is cleared from every
unassigned domain that could hold it, and only same-length slots can, so that is
the whole constraint. Undo restores saved masks, which restores the bit. This
replaces filtering every candidate list against a `used` set at every node.

`pattern(slot, assignment)`: build a string of length `slot.length`, character
`i` = the crossing letter if that crossing slot is assigned, else `'.'`.

```
pattern(slot, assignment):
  chars = ['.'] * slot.length
  for (i, (otherId, otherIdx)) in slot.crossings:
      if assignment has otherId: chars[i] = assignment[otherId][otherIdx]
  return join(chars)
```

### 6.2 Initialisation

```
assignment = copy(preAssigned)                        // anchors, §7.2
for each slot not in assignment:
    lengthOf[slot.slotId] = slot.length
    domains[slot.slotId]  = maskFor(pattern(slot, assignment))

for text in preAssigned.values() UNION blocked:       // `blocked` = solved answers
    clearWord(text, saved = null)

clearWord(text, saved):
  bit = bitOf[text]; if absent: return                // not in the fill pool
  for (sid, domain) in domains where lengthOf[sid] == text.length:
      if domain & (1 << bit) == 0: continue
      if saved != null: saved.putIfAbsent(sid, domain)
      domains[sid] = domain & ~(1 << bit)
```

`blocked` carries the answers the user has already solved (requirement 10,
Appendix A; see §6.2a for how that set is built). Clearing their bits once here
is all that is needed: nothing in the
search ever *sets* a bit that was not set at this point — undo only restores
saved masks — so they stay excluded for the whole search. `refine()` (§6.6) must
apply the same exclusion or it will quietly pull them back in.

An anchor that is not in the fill pool has no bit; `clearWord` returning early is
correct, since it cannot appear in any domain either.

### 6.2a Building `blockedAnswers` — *solved*, not *shown*

The brief says not to reuse "answers discovered by the user" in the previous 10
puzzles. The obvious implementation — exclude everything that appeared in the
last 10 generated puzzles — is a different and weaker set, and it gets the
product backwards:

- A puzzle the user opened and abandoned taught them nothing, yet every answer
  in it would be suppressed for ten puzzles.
- An answer the user only got by revealing cells was not discovered either. It
  should come back, because they still need to learn it.

The cooldown exists so a learner is not re-quizzed on what they already know,
and "already know" means they wrote it in unaided. So key it on **solve
events**, which the app must record:

```
SolveEvent:
  puzzleId
  solved:   Set<String>     // entered correctly by the user
  revealed: Set<String>     // any cell given away by a hint or reveal

learned(event) = event.solved - event.revealed   // partial help still means "not unaided"

blockedAnswers(events, window = 10):
  return union of learned(e) for the last `window` events
```

Normalize to the grid form (A-Z only) on the way in, so "I do's" and "IDOS" are
the same answer. Reference implementation: `src/crosswordler/history.py`.

### 6.3 Fill pool

Four independent bars, **68,742 entries**. Each catches what the others miss,
so port all four:

```
freq_zipf >= FILL_MIN_ZIPF (2.5)      // is this attested at all?
clue is non-null                       // can we clue it?
editor_tier != 25                      // "only if absolutely necessary"
familiarity >= floor(length)           // does a person know the word?
    floor = 4 at lengths 3-4, else 3
```

This is the second half of the quality fix: because every word in the pool is
recognizable *and* cluable, **any valid fill is a publishable fill**. Combined
with §4's grid shapes it costs nothing in solvability.

**The familiarity bar is the one you cannot derive.** The other three come from
the asset's own numbers; this one is a judgement, shipped in
`data/raw/word_ratings.tsv` (entry → 1-5) and folded into the asset. It exists
because the first three all pass words nobody knows: corpus frequency scores
DES at 4.25 and AIN at 3.46, since below five characters it is counting a
letter sequence in running text rather than a word; and the Nediger tier rates
ABA 51, because a working constructor genuinely would use it — their bar is
"usable in a crossword", not "a learner knows this". Readers rejected ERG, PAP,
ABA, DES, AIN and NEE by name, and every one of them cleared the other three
bars.

The threshold is length-dependent because the ratings say that is where the
problem is: **9.4% of three-letter entries rate 2, against ~2.5% at every other
length**. Same reasoning as §2.4's frequency floor — short entries are where
obscurity is most jarring and most avoidable, long entries are where the solver
has least slack.

If you regenerate the ratings (`tools/review_wordlist.py`), ask a model for a
**1-5 rating, not a keep/remove verdict**. Two binary versions were tried and
both cut DNA, CIA, CPR, FAQ, HAM, BIO and PER along with the junk: asked to
find suspects, a model finds them. A rating leaves the threshold with you.

The clue requirement is what removes placeholder clues entirely: a word we cannot
clue is a word we cannot use, so it is simply never selected. Measured cost: free
at 5x5 and 9x9 (9x9 got *faster* — a smaller domain prunes sooner). At 17x17 it
halves per-skeleton fill success, but end-to-end generation is unaffected (6/8
either way) because the orchestrator retries.

Anchors (§7) are drawn from the *full* list, not the fill pool, and are
pre-assigned, so they don't need to be in the index — but they must still have a
clue (§7.2).

### 6.4 Constraint propagation (AC-3 style)

After an assignment, direct forward-checking only updates slots that cross the
assigned slot. This cascade goes further: narrowing a slot's domain shrinks the
set of letters it can contribute at *its* crossings, which can narrow slots two
hops away.

```
propagate(seedSlotIds, saved) -> ok: bool:
  queue = seedSlotIds; queued = set(queue)
  while queue not empty:
    sid = queue.removeFirst(); queued.remove(sid)
    source = domains[sid]; if absent: continue          // already assigned
    for (idx, (otherId, otherIdx)) in slots[sid].crossings:
      target = domains[otherId]; if absent or zero: continue

      // letters `sid` can still show at cell idx -> the words `otherId` has
      // with that letter at otherIdx. ~26 bitwise ops, any domain size.
      supported = 0
      for (letter, letterMask) in posMasks[lengthOf[sid]][idx]:
          if source & letterMask != 0:
              supported |= posMasks[lengthOf[otherId]][otherIdx][letter]

      narrowed = target & supported
      if narrowed != target:
        saved.putIfAbsent(otherId, target)              // FIRST value only
        domains[otherId] = narrowed
        if narrowed == 0: return false                  // dead end
        if otherId not in queued: queue.add(otherId); queued.add(otherId)
  return true
```

**`PROPAGATE_DOMAIN_CAP` is gone, and porting it back would be a mistake.** The
old set-based version computed letter support by walking the candidate list, so
its cost was O(domain); a cap of 150 switched propagation off above that, which
meant it was disabled for exactly the large domains where pruning is most
valuable (uncapped, the old version cost ~85ms per node at 17x17). The bitwise
formulation is O(26) regardless, so full MAC now runs at every node, always.

Iterate only the letters that actually have a bucket at that position, not all
26 — most positions use far fewer.

### 6.5 Search

```
run() -> assignment | null:
  steps += 1
  if steps > maxSteps or now > deadline: return null
  if domains is empty: return copy(assignment)          // every slot assigned: solved

  // --- variable ordering: MRV, ties by degree ---
  bestId = argmin over sid in domains of
             (popCount(domains[sid]), -slots[sid].crossings.length)
  domain = domains[bestId]
  if domain == 0: return null

  crossers = [(otherId, otherIdx, idx)
              for (idx, (otherId, otherIdx)) in slots[bestId].crossings
              if otherId in domains]

  for entry in orderedCandidates(bestId, domain):        // best score first
    assignment[bestId] = entry.text
    remove bestId from domains

    saved = {}; deadEnd = false

    // one-hop forward check: one AND per crossing. The assigned word fixes
    // one letter of the neighbour, and that letter's mask *is* the
    // neighbour's surviving domain.
    for (otherId, otherIdx, idx) in crossers:
      target   = domains[otherId]
      narrowed = target & posMasks[lengthOf[otherId]][otherIdx][entry.text[idx]]
      if narrowed != target: saved.putIfAbsent(otherId, target)
      domains[otherId] = narrowed
      if narrowed == 0: deadEnd = true; break

    if not deadEnd:
      clearWord(entry.text, saved)                       // all-different (§6.2)
      if not propagate(crossers.map(otherId), saved): deadEnd = true

    if not deadEnd:
      result = run()
      if result != null: return result

    // ---- undo, exactly ----
    for (otherId, oldDomain) in saved: domains[otherId] = oldDomain
    remove bestId from assignment
    domains[bestId] = domain                             // the mask from node entry

    if now > deadline: return null

  return null                                            // leaves domains[bestId] = domain
```

```
orderedCandidates(slotId, domain):        // lazy, best-first, chunked
  remaining = domain
  while remaining != 0:
    chunk = entriesIn(lengthOf[slotId], remaining, limit = CANDIDATE_CHUNK)
    if jitter > 0: sort chunk by -(score + rng.uniform(-jitter, +jitter))
    yield each of chunk
    for entry in chunk: remaining &= ~(1 << bitOf[entry.text])
```

`CANDIDATE_CHUNK = 256`. This is a **lazy slice, not a cap** — if every word in
a chunk fails, the next chunk is taken and the search stays complete. It exists
because a barely-constrained slot can have thousands of candidates while the
search almost never needs past the first few dozen; materializing and ordering
the whole domain at every node was most of the old solver's cost. Because bit
order is score order, the chunk boundary is a score boundary, so jitter
reorders within a chunk — which is all it was ever doing in practice.

**Undo correctness — still the subtlest part of the port**, even though masks are
values rather than lists:

- `saved` records each touched slot's domain from *before this candidate was
  tried*. Always `putIfAbsent`, never overwrite — a slot touched by the one-hop
  check, then `clearWord`, then the cascade must revert to its pre-assignment
  state, not an intermediate one.
- On backtrack, restore `domains[bestId] = domain`, the mask captured at node
  entry.
- When the loop exhausts all candidates and returns `null`, `domains[bestId]`
  must be left set — the slot is unassigned again and ancestors will reconsider
  it. Deleting it here is a bug (it was one; symptom: some slots never get filled
  on deeper branches).

**Domains are now exact, not a heuristic aid.** The old design recomputed an
authoritative candidate list at each node because the cached lists could go
stale; that caveat is gone. Masks are maintained precisely — forward-checked,
propagated, and all-different — so the domain *is* the candidate set, and MRV is
comparing real numbers rather than approximations.

**Score jitter.** `score_jitter = 2.0` *(measured)*. Without it the search is
deterministic, so retrying a rejected puzzle with a new skeleton converges on the
identical fill and never explores an alternative. Seed the RNG per generation
call for reproducibility.

Budgets: `maxSteps = 400_000`; per-solve wall clock 8s (see §9).

### 6.6 Local refinement

After a complete fill, try to upgrade weak entries without re-searching.

```
refine(assignment, slots, index, entriesByText, passes = 2, protected = {}):
  repeat passes times:
    improved = false
    for slotId in assignment.keys except protected, ascending by current entry score:
      used    = all assigned texts except this slot's
      pattern = pattern(slot, assignment without this slot)
      best    = argmax score over candidates(pattern, exclude=used)
      if best.score > currentScore + 0.5:
          assignment[slotId] = best.text; improved = true
    if not improved: break
```

`protected` **must** contain the anchor slot ids, or this pass will happily
replace a required SRS/theme entry with a higher-scoring word.

---

## 7. Themes and anchors

### 7.1 Day mapping

| weekday | category |
|---|---|
| Monday, Thursday, Friday | `random` (any topic) |
| Tuesday, Saturday | `pop_culture` |
| Wednesday | `general_knowledge` (tags: history, politics, geography, science) |
| Sunday | `distinctive` — a mechanism, see §7.3 |

`maxAnchors` by size *(measured against placement success)*: `{5: 1, 9: 2, 17: 3}`.

### 7.2 Anchor selection and fitting

1. Caller-supplied SRS words come first (highest priority). Normalize to A-Z
   uppercase. If a word isn't in the list, synthesize an `Entry` for it anyway so
   it can still be placed — the SRS vocabulary is the point of the product.
2. Fill remaining anchor slots from entries matching the day's category, excluding
   `blockedAnswers` (see §6.2a), preferring high
   score, length >= 4, **and requiring a clue**. Anchors are drawn from the whole
   word list rather than the fill pool, so unlike ordinary fill they can arrive
   unclued and fall through to a stub — in the puzzle's most prominent slot. The
   SRS word in step 1 is the deliberate exception; a theme pick is not.
3. Drop anchors longer than the grid.

Fitting into a generated skeleton, with graceful degradation:

```
fitAnchors(anchors, slots) -> (preAssigned, anchorsUsed):
  remaining = anchors sorted by score descending
  while remaining not empty:
    try to assign each anchor (longest first) to an unused slot of exactly its
      length; if every anchor gets one, return that mapping
    otherwise drop the lowest-scoring anchor and retry
  return ({}, [])
```

This implements the brief's "if they cannot reasonably be incorporated, use fewer
or none". A stricter approach — reserving anchor cells *before* generating the
skeleton, via `reservedWhite` — is better and not yet done.

### 7.3 Sunday mechanism: hidden words

Pick a category, then find entries that contain one of its words as a hidden
contiguous substring (and are not that word themselves). Those become the theme
anchors.

```
buildSundayTheme(entries, maxAnchors, rng):
  for each category (shuffled) in HIDDEN_CATEGORIES:
    for each word w in category:
      matches = entries where length >= 6 and text contains w and text != w
      keep top `maxPerWord` by score
    usable = category words that have at least one match
    if usable.length < min(3, maxAnchors): continue      // need real variety
    choose maxAnchors of them (shuffled); return theme
  return null
```

`HIDDEN_CATEGORIES` in the reference implementation: colors, animals, numbers,
body_parts, gems. Rebus and letter-addition/subtraction mechanisms are designed
but not implemented — see `docs/research.md` §3 for feasibility analysis.

---

## 8. Clues

The reference clue generator is the **weakest part of the system** and you should
expect to replace it. Port it if you want end-to-end parity; budget real work if
you want good puzzles.

Current behaviour, per entry:

Runtime is now trivial, because all the work happens at build time (§2.5):

1. If `entry.clues` is non-empty: pick one **with the puzzle's seeded RNG**, so
   a recurring answer varies across puzzles while a given seed stays
   reproducible. Use its `text` and `type` verbatim.
2. Else if `is_proper` / `is_phrase`: a stub from its tags.
3. Else: a placeholder (`"<n>-letter word"`).

**Paths 2 and 3 should never fire for ordinary fill**, because the fill pool
requires a clue (§6.3). They remain reachable only for anchors drawn from outside
the pool — a caller-supplied SRS word, or a supplement phrase with no clue yet.
Measured over the whole fill pool: 53% `definition`, 27% `llm`, 12%
`synonym`, 8% `fill_in_blank`, <1% `curated`, **0% placeholders** (down from 16%).

Weighted selection, not uniform: uniform choice measurably lowered quality
(TWO drew WordNet's "the cardinal number that is the sum of one and one…" as
often as the hand-written "A pair"). Weight `curated` ×3, `synonym` ×2.5,
`llm` ×2, and scale anything over 8 words down by `1 - 0.09*(words-8)`, floored
at 0.12. Every option keeps a real chance, so variety survives.

The **giveaway filter** is applied at build time when deriving the clue, and is
worth porting exactly if you regenerate the asset. It needs no NLP:

```
isGiveaway(clueText, answerText):
  answerVariants = { answer } plus naive suffix strip/add over
                   [s, es, ing, ed, er, ers, ly, tion, y]
  for token in words(clueText):
    t = lowercase(token); if t.length < 3: continue
    if t in answerVariants: return true
    if t.length >= 5 and t is substring of answer: return true
    if answer.length >= 5 and answer is substring of t: return true
  return false
```

The two length guards matter: without the `answer.length >= 5` condition, a short
answer like `CAT` flags the innocent clue word "domesti**cat**ed".

If a clue is a giveaway, try the §2.5 salvage paths before giving up.

**Difficulty score** (1 easy … 5 hard): `clamp(6.0 - mean(zipf of clue words with
length > 2), 1, 5)`. Rarer clue vocabulary reads as harder.

Known gaps, in priority order:

- **No wordplay, humour, or misdirection.** Every clue is a definition, a
  synonym, a curated one-liner, or a redacted gloss. The brief asks for varied,
  witty, occasionally misdirecting clues; this delivers *correct* clues, not
  *entertaining* ones. Biggest remaining gap in the whole system — though
  synonym clues (§2.5 step 2c) close the *register* half of it for free.
- **Residual sense ambiguity.** §2.5's step 2 fixes wrong-*lemma* errors but not
  wrong-*sense* ones. Known survivors: `EVENS` ("the latter part of the day",
  should be about levelling), `IDS` (glossed as Idaho). Detecting these needs
  real disambiguation — a local embedding check or an LLM pass.
- **Gloss register.** WordNet definitions are encyclopedic, not crossword-y:
  "Sluggish tailless Australian arboreal marsupial with grey furry ears and coat"
  is accurate but reads nothing like a newspaper clue. Synonym clues sidestep
  this where a synset offers one; shortening/rewriting the rest is a good use of
  the sanctioned narrow-AI role.
- **Number agreement in definitions.** Sense selection allows a base-form lemma
  for an inflected answer, so CRABS can draw "A quarrelsome grouch". Synonym
  clues are already guarded against this (§2.5 step 2c.1); definitions are not.
- **Phrases beyond WordNet.** 36,690 of the 197,720 multi-word entries now
  carry a clue. The rest — `ice cream headache`, `badgers the witness`,
  `abandonware` — have no lexical source at all and are excluded from fill.
  This is the population the LLM/runtime clue layer exists to serve.

`docs/research.md` §5 specifies the intended fuller pipeline (n-gram
fill-in-the-blank, Wikidata-templated trivia, a local embedding ambiguity check,
and a sparse LLM pass over theme entries only).

---

## 9. Orchestration

```
generatePuzzle(size, weekday, allEntries, fillIndex, srsWords, blockedAnswers, seed):
  rng             = seeded RNG
  (maxEntryLen, whiteTarget) = SIZE_PROFILE[size]
  overallDeadline = now + OVERALL_BUDGET[size]
  anchors         = selectAnchors(...)  // §7.2, Sunday theme if applicable

  best = null; bestOffenderCount = infinity

  for attempt in 0..skeletonAttempts-1:
    if now > overallDeadline: break
    black = generateSkeletonCapped(size, maxEntryLen, whiteTarget, rng, maxAttempts=800)
    if black == null: continue        // just take another attempt; see note below
    slots = extractSlots(black)
    (preAssigned, anchorsUsed) = fitAnchors(anchors, slots)

    result = solve(slots, fillIndex, preAssigned,
                   timeBudget = min(8s, overallDeadline - now),
                   rng, scoreJitter = 2.0)
    if result == null: continue

    fill    = refine(result, slots, fillIndex, entriesByText,
                     protected = preAssigned.keys)
    puzzle  = assemble(fill, slots, black, clues, theme, anchorsUsed)
    puzzle.qualityScore = scorePuzzle(puzzle, ...)

    offenders = qualityOffenders(puzzle.entries, preAssigned.keys)
    if offenders is empty: return puzzle            // clean — stop early
    if offenders.length < bestOffenderCount:
        best = puzzle; bestOffenderCount = offenders.length

  return best      // may be null if nothing solved at all
```

`assemble` builds the presentation grid from the fill — black cells become null,
white cells take their letter:

```
assemble(fill, slots, black):
  grid = [[ black[r][c] ? null : "" for c in 0..n-1 ] for r in 0..n-1]
  for slot in slots:
    word = fill[slot.slotId]
    for (i, (r,c)) in enumerate(slot.cells()): grid[r][c] = word[i]
  return grid
```

Across and down writes to the same cell agree by invariant 4 (§11), so write
order doesn't matter; if they ever disagree, your crossing map is wrong.

**On `generateSkeletonCapped` returning null.** With `maxAttempts = 800` this is
uncommon (measured success per call: 30/30 at 9x9 maxLen 6; 30/30 at 17x17
maxLen 9; 22/30 at 17x17 maxLen 8). Simply consume another orchestration attempt.

The reference implementation also keeps an older unconstrained random-skeleton
generator as a fallback here. **Do not port it.** It produces exactly the
long-entry, high-white-percentage grids that §10.1 identifies as unfillable, so
it converts a clean failure into a bad puzzle. It exists only for historical
comparison.

### 9.1 Quality gate

Reject a completed grid if any **non-anchor** entry falls below a per-length
recognizability floor, and regenerate. Keep the least-bad attempt as a fallback
so you return *something*.

```
QUALITY_FLOOR_BY_LENGTH = {3: 2.5, 4: 2.2, 5: 1.8, 6: 1.4, 7: 1.0, 8: 0.7, 9: 0.5}
// lengths > 9: no floor
```

With §4's grid shapes and §6.3's fill pool this gate now reports **zero
offenders** at all three sizes, so it functions as insurance rather than as the
main quality mechanism. Keep it: it is cheap and it catches regressions.

### 9.2 Puzzle-level score

Reported, not currently used to drive search:

```
answerQuality  = mean(entry.score)
obscurity      = mean(max(0, 3.0 - entry.freq_zipf))
varietyBonus   = min(distinct clue types, 5) * 0.5
anchorBonus    = 2.0 * anchorCount
themeBonus     = 3.0 if hidden-word theme else 1.0
repetitionPen  = 2.0 * (entries appearing in blockedAnswers)

score = answerQuality + varietyBonus + anchorBonus + themeBonus
      - obscurity - repetitionPen
```

---

### 9.3 The editorial pass (optional, needs a model)

Everything above is deterministic and offline. This is the one place a model
runs at generation time, and it is **strictly an upgrade**: no provider, a
timeout, a rate limit or unparseable output all leave the deterministic puzzle
exactly as it was. Never block play on it.

```
reviewPuzzle(puzzle) -> verdict:
  render the puzzle as text: day, theme, required answers, the grid with '#'
    for black squares, then every clue as "id=<slotId> <number>. [answer] clue"
  ask the model for strict JSON:
    {entertainment: 0-10, notes, clue_edits: {id: text}, word_edits: {id: ANSWER}}
  on ANY failure return an empty verdict
```

Answers are shown to the reviewer deliberately — fairness and factual accuracy
cannot be judged without them.

**The reviewer is untrusted, and this is the point.** Apply the verdict through
the verification in §9.4, never directly. In a measured run the model proposed
32 clue edits on one 9x9 and 3 of them broke rules it had been given
explicitly: two contained the answer, one signalled an abbreviation.

Two settings that mattered, both measured on gpt-5-mini:

- **Reasoning effort `low`.** Clue *writing* wants fluency, and `minimal` is
  right for it. Judgement needs more — but only up to a point. Same three
  puzzles, gpt-5-mini:

  | effort | 5x5 | 9x9 | 17x17 |
  |---|---|---|---|
  | minimal | 2.5s, 4/5 edits | 2.8s, 9/9 | 4.5s, **0 edits** |
  | **low** | **15.0s, 9/10** | **15.5s, 30/30** | **13.7s, 4/5** |
  | medium | 39.4s, 9/9 | 50.0s, 7/7 | **1396s, nothing** |

  At `minimal` the reviewer scores a puzzle 3/10 and proposes nothing — it has
  the opinion and does not do the work, and on the largest puzzle it proposes
  nothing at all. `medium` is 3x slower for no more edits, and on a 17x17 it ran
  for 23 minutes and returned nothing. `low` is the only setting that behaves
  the same at every size, and its latency is flat in puzzle size (~15s) because
  the cost is reasoning, not input length.
- **Bound the call in wall-clock time, not with a socket timeout.** These are
  not the same thing, and the difference is not academic: Python's `urllib`
  applies its `timeout` to each socket operation, so a server that keeps the
  connection alive resets it indefinitely — that 1,396-second review was made
  against a 240-second timeout. Whatever your HTTP client, verify it enforces a
  *total* deadline (Dart's `Future.timeout` does; a bare socket option usually
  does not). Scale the deadline with clue count: floor 45s plus ~1.5s per clue.
- Reasoning models reject a custom `temperature`; send none.

**~15s is too slow for a click-path feature.** The pass is worth having, but do
not put it between the user and the puzzle — generate ahead of time (the next
day's puzzles are computable as soon as today's are solved, and personalisation
depends on SRS state that is already known), or show the deterministic puzzle
and never block on the review.

What this pass is *for* is the class of defect no string check can reach:

| before | after |
|---|---|
| "The immature free-living form of most invertebrates and amphibians and fish which at hatching from the egg is fundamentally unlike its parent and must metamorphose" (LARVA) | "Immature stage before metamorphosis" |
| "(astronomy) the reappearance of a celestial body after an eclipse" (EGRESS) | "Exit or way out" |
| "The cardinal number that is the sum of one and one and one" (III) | "The number after two" |

The EGRESS row is the important one: the original was not merely verbose, it was
the *wrong sense*. And factual errors are the same category — the clue backfill
produced "City on the Pacific coast known for a big zoo" for DIEGO, which is San
Diego, and which passes every deterministic check because accuracy is not a
string property.

### 9.4 Verifying a verdict

Nothing the reviewer says is applied without proof. Word edits go **first**,
because re-solving regenerates every clue and would otherwise discard clue edits
already applied.

```
revisePuzzle(puzzle, verdict, index, entriesByText, blockedAnswers, seed):
  if verdict.word_edits:
    applyWordEdits(...)          // all-or-nothing, see below
  if verdict.clue_edits:
    for (slotId, text) in verdict.clue_edits:
      validate text against the SAME gate every other clue passes (§8, §2.5),
        keyed on the answer AND its display form for multi-word answers
      accept or reject individually, recording the reason
```

**Clue edits** are local and validated one at a time. **Word edits** are
structural — a replacement changes crossing letters, so it cannot be checked in
isolation. Instead:

```
applyWordEdits(puzzle, edits, ...):
  for each edit: reject the WHOLE set if the word is the wrong length, absent
    from the fill pool, in blockedAnswers, or duplicated
  pin the words and re-solve the grid (§6) around them
  if it does not solve, or the new fill fails the §9.1 quality gate,
    drop every word edit and keep the original fill
  otherwise commit fill, entries, grid letters and regenerated clues together
```

All-or-nothing, because a partially applied swap can leave the grid
inconsistent. Re-solving is affordable only because §6 made fill fast — at
1-35ms a re-solve is cheaper than reasoning about which edits are compatible.

Finally, run `assertPuzzleValid` unconditionally: crossings agree, no duplicate
answers, grid letters match the fill, and **every clue passes the full gate
again**. That last check is the safety net for the safety net — if it ever
fires, show the un-revised puzzle rather than a broken one.

---

## 10. What was tried and failed

Do not re-litigate these without new evidence; each cost real time.

### 10.1 Chasing 85% white squares is the root cause of bad fill

The brief asks for 85%+ white squares. Pursuing it is what produced obscure fill
(`SNYE`, `OVOIDAL`, `DEWAN`), 75-second 9x9 generations, and a 17x17 that never
completed. Fewer black squares ⇒ longer entries ⇒ dense mutual interlocking ⇒
grids that are not merely hard but **infeasible**.

Evidence:
- A word-level CP-SAT model (Google OR-Tools, C++) did **no better** than the
  Python solver on 9x9 — both fail. The search engine was never the bottleneck.
- CP-SAT **proved** several 17x17 grids infeasible in ~0.1s against a
  `zipf >= 3.0` pool. No valid fill exists.
- Length-capped but minimally-blackened 17x17 grids (85-87% white) filled 0/8.
  The same grids topped up to ~72% white filled in ~0.05s.

**Revised 2026-09-09 (docs/COMPARISON.md §4).** Adopting the Nediger list showed
the deeper cause was **pool thinness at long lengths**, with white% acting as a
proxy for it: with adequate long-entry supply, 17x17 went from 3/4 at 2.62s to
4/4 at 0.05s and uncapped-length 17x17 from 0/4 to 1/4, on the word list alone.
High white% is still unreliable at mid sizes, so the recommendation below stands
— but the specific caps and targets are more conservative than necessary and
should be re-derived.

**Recommendation: treat white % as an outcome, not a target** — ~84% (mini),
~75-79% (midi), ~72% (mega). A denser grid of words solvers recognize beats a
sparse one padded with obscurities. NYT's real 15x15 sits near 83%.

### 10.2 Cleverer split-position ordering in the skeleton generator

Random ordering beat both attempts. Deterministic "most balanced split first"
dropped 9x9 skeleton success from 26/30 to **0/30**; a two-tier
legal-splits-first shuffle gave 14/30. Restarts cost ~2ms, so random ordering
plus a high `maxAttempts` wins.

### 10.3 Letter-level CSP / CP-SAT for filling

Modeling each *cell* as a variable does not scale (published benchmark: 235s
model build + 730s solve for an 11x11, 32GB+ RAM). Use word-level variables.

### 10.4 Limited-discrepancy search (LDS)

A "budget of off-heuristic choices" layer *increased* branching, because bounding
deviations per path does nothing when a single slot's domain is large. Plain
best-score-first backtracking plus §6.6 refinement performs better. A correct
Korf-style wavefront LDS might help; the naive version does not.

### 10.5 A global frequency floor on the word list

See §2.4. Applying it above length 6 broke 9x9 solving (0/4).

### 10.6 A fixed cap on full-width entries

An earlier `maxFullLengthEntries <= 2` guard (added to stop 17x17 demanding six
17-letter words) silently rejected **every possible 5x5 skeleton**, so mini always
fell through to an unblocked-grid fallback and never had a single black square.
If you keep such a cap, derive it from the usable pool size at that length:
`clamp(usableWordsAtLength / 100, 2, 2n)`.

---

## 11. Expected behaviour (acceptance targets)

End-to-end generation, warm (word list already loaded), reference hardware —
skeleton + fill + refinement + clues, median of 8 seeds:

| size | time | fill success | quality-gate offenders |
|---|---|---|---|
| 5x5 | ~0.14s | 8/8 | 0 |
| 9x9 | ~0.14s | 8/8 | 0 |
| 17x17 | ~0.23s (worst seed 8.3s) | 8/8 | 0 |

The **solver alone**, over 20 skeletons per size at the §4.3 profile — use these
to tell a slow port from a wrong one, since they isolate §6 from grid generation:

| size | median | worst | nodes (median) |
|---|---|---|---|
| 5x5 | 1.2ms | 6ms | 11 |
| 9x9 | 4.3ms | 81ms | 32 |
| 17x17 | 35ms | 1 of 20 hit the 20s budget | 115 |

Node counts are the number to check first. They are a property of the *search*,
not of the language or machine, so a port landing near 11 / 32 / 115 has the
ordering heuristics and propagation right; one taking thousands has a bug in
propagation or undo, however fast it runs.

Invariants worth asserting in tests:

1. `black[r][c] == black[n-1-r][n-1-c]` for all cells.
2. Every slot length >= 3 and <= `maxEntryLen`.
3. All white cells form one connected component.
4. For every slot and every crossing `(i → (otherId, j))`:
   `fill[slot][i] == fill[otherId][j]`.
5. No word appears twice: `distinct(fill.values()).length == fill.length`.
6. Every pre-assigned anchor still present in the final fill.
7. Every non-anchor entry clears `QUALITY_FLOOR_BY_LENGTH`.

The reference implementation's tests (`tests/`) cover 1-6;
`tests/test_bitset_solver.py` covers 4-6 plus the bitset representation itself
(that `maskFor` agrees with the set-based `candidates`, and that set bits come
out in score order).

### 11.1 Reference skeletons (test vectors)

Real output from the reference implementation at the §4.3 parameters. Your
generator will not reproduce these cell-for-cell (different RNG — see §12), but
it **should** produce grids with the same structural character: the same
white-percentage band, no entry longer than `maxEntryLen`, minimum length 3,
symmetric, connected. Use these to sanity-check a port before wiring up the
solver, and as fixed inputs to test the solver independently of generation.

**5x5** — `maxEntryLen 5`, `whiteTarget 0.84` → 4 black, **84.0% white**,
10 slots, lengths `{3: 4, 5: 6}`:

```
#...#
.....
.....
.....
#...#
```

A valid fill for it: `1A AND`, `4A ALOHA`, `6A NAMED`, `7A DREAD`, `8A ARC`
(across), with `ALARM` among the downs.

**9x9** — `maxEntryLen 6`, `whiteTarget 0.78` → 22 black, **72.8% white**,
30 slots, lengths `{3: 13, 4: 10, 5: 3, 6: 4}`:

```
...###...
....##...
....#....
......###
##.....##
###......
....#....
...##....
...###...
```

**17x17** — `maxEntryLen 9`, `whiteTarget 0.72` → 81 black, **72.0% white**,
94 slots, lengths `{3: 38, 4: 26, 5: 8, 6: 8, 7: 8, 9: 6}`:

```
###....#...##...#
.......#...##...#
.......#.........
...#...###.......
....##.......#...
....###...###....
#....##...###....
####....##......#
#......###......#
#......##....####
....###...##....#
....###...###....
...#.......##....
.......###...#...
.........#.......
#...##...#.......
#...##...#....###
```

Note the length histograms: the great majority of entries are 3-6 letters even
at 17x17, with only six 9-letter entries. That distribution *is* the fix — it is
what the old generator got wrong, and it's the quickest way to tell whether your
port is behaving. If your 17x17 grids show many 8+ letter entries, you have
reproduced the original bug (§10.1).

Achieved white % lands slightly below `whiteTarget` at 9x9 (72.8% vs 78%) because
Phase 1's length-capping alone can already exceed the density implied by the
target; the target is a floor on black squares, not an exact figure.

---

## 12. Porting notes

- **RNG**: seed explicitly and thread one instance through skeleton generation,
  anchor selection, and the solver, so a seed reproduces a puzzle exactly. Note
  that reproducibility across languages requires an identical RNG algorithm; if
  you need cross-language determinism, port a small PRNG (e.g. xorshift) rather
  than relying on the platform's.
- **Recursion**: the solver recurses once per assigned slot — depth is bounded by
  slot count (<= ~90 at 17x17), so native recursion is fine. Convert to an
  explicit stack only if your platform has a tight stack limit.
- **Hot paths**, in order of cost: `candidates()` set intersection, `propagate()`
  letter-set construction, `pattern()` string building. Prefer integer letter
  codes (0-25) over characters and preallocated buffers over string concatenation
  in the innermost loops.
- **Sets**: `used` and the index buckets are hot. Use hash sets; the intersection
  in `candidates()` should iterate the *smallest* bucket first.
- **Asset loading**: parse the word list once at startup and build the index for
  the fill pool lazily per size if memory matters (index per length is
  independent).
- **Threading**: skeleton attempts are independent and embarrassingly parallel —
  an easy win for 17x17 if your platform allows background isolates/threads.

---

## 13. Deliberate omissions

Present in the design but **not implemented** in the reference code — do not
assume they exist:

- Rebus and letter-addition/subtraction Sunday mechanisms (`docs/research.md` §3).
- Position-first anchor placement (`reservedWhite` is plumbed but unused).
- Wiktextract/Wikidata lexical expansion. The Nediger list (§2.1) replaced the
  ~80-entry hand-curated supplement as the source of phrases, idioms and
  colloquialisms, so the shortage is now *clues* for them, not entries.
- Clue generation beyond WordNet glosses, co-lemmas and the build-time LLM
  backfill (§8). The backfill has covered the tier-99 entries; ~141,000 tier-51
  entries still have no clue and so cannot enter the fill pool.
- Grid aesthetics: black squares currently clump into blobs and long runs. Real
  grids avoid 2x2 all-black blocks; adding that as a skeleton validity rule is
  the obvious next improvement.

---

## Appendix A — Requirements this design must satisfy

Source: `Crosswordler Instructions.md` (the product brief), with supporting
analysis in `docs/research.md` and open items in `docs/TODO.md`. This appendix
exists so an implementer can tell **which behaviours are contractual** and which
are incidental to the reference implementation — and so the deviations come with
their justification attached rather than looking like oversights.

Status key: **MET** · **PARTIAL** · **GAP** (required, not implemented) ·
**DEVIATED** (deliberately, with evidence).

### A.1 Product framing

> "Do not optimize merely for generating a valid crossword. A technically valid
> grid containing boring, obscure, repetitive, or unnatural fill is a failure.
> Optimize for the experience of solving it."

This is the governing rule, and it is why §4 and §6.3 look the way they do. The
whole "constrain the grid, restrict the pool to recognizable words" design exists
to make *validity and quality the same thing* rather than trading one off against
the other. If you find yourself relaxing the fill pool to make a grid solvable,
you are re-introducing the original bug — change the grid instead.

The generator is destined for a vocabulary app with spaced repetition; puzzles
exercise the user's vocabulary **and** their ability to deduce clever clues.

### A.2 Requirement compliance

| # | Requirement (abridged) | Status | Where / why |
|---|---|---|---|
| 1 | Data sources must permit **commercial use** | MET | §2.1; explicitly excluded TWL/SOWPODS, IMDb, Urban Dictionary |
| 2 | Sizes: mini / midi / mega (5, 9, 17) | MET | §4.3 |
| 3 | Include **1-3 SRS words** as high-priority anchors; use fewer or none rather than damage quality | MET | §7.2, incl. graceful degradation |
| 4 | Anchors/theme entries should **influence grid generation**, not be fitted afterwards | **GAP** | §7.2 fits anchors to an already-generated skeleton. `reservedWhite` (§4.2) is plumbed for this but unused |
| 5 | Day-of-week themes (Mon/Thu/Fri random, Tue/Sat pop culture, Wed general knowledge, Sun distinctive) | PARTIAL | §7.1. Mapping implemented; the brief's "preferably related to the selected SRS words" for Mon/Thu/Fri is **not** |
| 6 | Themes may be a shared topic, a **wordplay mechanism**, or both; prefer mechanisms over category-filling | PARTIAL | §7.3 implements one mechanism (hidden words) for Sunday only. Other days are topic-only, via `tags` |
| 7 | Wednesday's theme should shape the **subject matter of clues**, not force every answer into one topic | **GAP** | Implemented as answer-category selection, i.e. the thing the brief said not to do |
| 8 | Target **85%+ white squares**; avoid ugly/repetitive patterns; *determine whether this should change per size* | **DEVIATED** | §10.1. Measured as the root cause of unfillable grids. Now ~84/75/72% by size. The brief explicitly invited this ("determine during research whether this requirement should change for different puzzle sizes"). "Avoid ugly patterns" is **not** met — black squares clump (§13) |
| 9 | Follow NYT/American grid conventions | MET | §4.1 — 180° symmetry, min length 3, full checking, connectivity |
| 10 | **Do not reuse answers discovered by the user in the previous 10 puzzles** | MET | `blockedAnswers` is cleared from every domain at setup (§6.2) and honoured by `refine()` (§6.6), anchor selection (§7.2) and scoring (§9.2). §6.2a defines *discovered* as solved unaided, which is a closer reading of the brief than "appeared in a recent puzzle". Covered by `tests/test_solved_cooldown.py` |
| 11 | Prefer words recognizable to a modern solver; avoid obscure/archaic fill | MET | §2.4, §6.3, §9.1 — this was the subject of a major fix |
| 12 | **Difficulty is not obscurity** — prefer "Oh, of course!" over unknowable trivia | PARTIAL | Obscurity is controlled; difficulty is only a crude clue-vocabulary metric (§8), and is not tunable per puzzle |
| 13 | Allow phrases, proper nouns, abbreviations, idioms, slang, titles, multi-word entries; strip spaces for the grid but keep display form | PARTIAL | Schema fully supports it (`text` vs `display`, §2). The Nediger list supplies **197,720** multi-word entries (§2.1), of which **36,690** have a clue and so can reach the fill pool. The limit is no longer data breadth but clue coverage for phrases WordNet doesn't hold (§8) |
| 14 | Avoid excessive crosswordese | PARTIAL | 33-word denylist plus scoring (§2.3); not data-driven |
| 15 | Rich lexical metadata: recognizability, interestingness, difficulty, obscurity, modern relevance, thematic relevance, classification, temporal/cultural relevance, clue potential, prior usage, display forms | PARTIAL | Frequency, obscurity, sense count, classification and display forms are derived. Interestingness, modern/temporal/cultural relevance, thematic relevance and clue potential are **not** — they need the Wikidata/pageviews/Ngrams layer in `research.md` §4 |
| 16 | Optimize the **whole puzzle**, not the best word per slot | PARTIAL | Score-ordered search + refinement (§6.6) + a puzzle-level gate (§9.1). No beam search; only one partial solution is ever kept |
| 17 | Puzzle-level scoring (theme + answers + variety + interest + clue potential − obscurity − crosswordese − repetition − bad structure) | PARTIAL | §9.2 implements the computable terms; it is *reported*, not used to steer search |
| 18 | A healthy mixture of standout answers and ordinary supporting vocabulary | **GAP** | Nothing explicitly balances "sparkle" against filler |
| 19 | Investigate CSP, backtracking, constraint propagation, MRV, weighted CSP, beam search, stochastic search, pattern indexing, building grids around anchors, keeping multiple partial solutions | MET (research) / PARTIAL (build) | §6 implements CSP + MRV + forward checking + AC-3 cascade + weighted ordering + pattern index. Beam search and multiple retained partials were **not** built; naive LDS was tried and rejected (§10.4) |
| 20 | Clues: varied types, entertaining, no giveaways, no derivatives of the answer, semantically verified, witty/misdirecting, fair, adjustable difficulty | PARTIAL | §8, §2.5. Giveaways/derivatives: done — 0 leaks, 0 abbreviation signals and 0 acronym expansions across all 76,000 clues in the fill pool. Every answer carries a real clue (0% placeholders, down from 16%). Sense selection fixes wrong-lemma errors (`HAS`, `WAS`, `USES`). Four clue types now in real proportions (71/16/14/<1), not one. The optional editorial pass (§9.3) adds the judgement no string check can reach — sense correctness, factual accuracy, register and whole-puzzle variety — and is verified before anything it says is applied (§9.4). Still missing: deliberate wordplay and misdirection at *generation* time rather than as a rewrite |
| 21 | Offline-first, deterministic, free/open; explore non-AI approaches first; AI must not be required for structural validity | MET | Zero AI at runtime, no network, fully deterministic for a given seed and RNG |
| 22 | Portable to a Flutter/Dart app | MET | This document + `tools/export_wordlist.py` |
| 23 | Requirements are provisional — recommend changes where they prove counterproductive | MET | §10.1 (white squares), §4.3 (mini granularity) |

### A.3 The deviations, stated plainly

Two requirements were deliberately not followed. Both are argued from
measurement, and both should be re-examined if your constraints differ.

1. **85%+ white squares → ~84% (mini) / ~75% (midi) / ~72% (mega).** Chasing 85%
   produces grids that are not merely hard to fill but provably *unfillable* from
   a quality word list (CP-SAT proved several 17x17 grids infeasible in ~0.1s).
   It was the direct cause of obscure fill, 75-second generations, and a 17x17
   that never completed. Full evidence in §10.1 and `docs/research.md` §0.
2. **Mini white target 0.84 rather than 0.85.** At 5x5 one black square is 4% of
   the grid, so 85% permits at most 3 black squares and symmetry makes that
   effectively "0 or 2". A single percentage point unlocks the 4-black-square
   patterns that are standard in real NYT Minis (§4.3).

### A.4 If you only fix three things

Ranked by impact on the solver's actual experience, not by effort:

1. **Clue generation (§8, requirement 20).** The grids are now good; the clues
   are the weakest link by a wide margin. Proper nouns and phrases currently get
   useless stub clues, and nothing checks that a gloss matches the intended
   sense.
2. **Word-pool breadth (requirement 13).** Real phrases, idioms and proper nouns
   via Wiktextract/Wikidata (`research.md` §4). This is what makes a puzzle feel
   contemporary rather than dictionary-ish.
3. **Recent-answer exclusion (requirement 10).** A one-line fix (§6.2) that turns
   a violated requirement into a met one.
