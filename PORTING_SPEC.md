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
  "text":         "LANDSLIDE", // grid form: A-Z only, uppercase, no spaces/punctuation
  "display":      "landslide", // human form, may contain spaces/apostrophes ("I dos")
  "freq_zipf":    3.47,        // Zipf frequency, ~0.0 (never seen) to ~7.0 (the/of/and)
  "synset_count": 2,           // count of WordNet *common-noun* senses (see 2.2)
  "is_proper":    false,
  "is_phrase":    false,
  "tags":         [],          // free-form category tags; see note below
  "score":        7.54,        // precomputed composite quality (formula in 2.3)
  "clue":         "An overwhelming electoral victory"  // see §8
}
```

`length` is derived (`text.length`) — don't store it.

Two things this example usefully shows:

- **`tags` is empty for the overwhelming majority of entries.** Only the ~80
  hand-curated supplement rows carry tags; ENABLE1-derived entries have none.
  Anything keying off tags (Wednesday's `general_knowledge` category, Tuesday's
  `pop_culture`) is therefore selecting from a very small pool. This is a known
  limitation, not a bug in your port — see §13.
- **The clue is WordNet's *first* sense, which is often not the obvious one.**
  "An overwhelming electoral victory" for LANDSLIDE is correct but not the
  geological reading most solvers would reach for. That is the §8 sense-selection
  gap in miniature.

**Generate it with the bundled exporter** — this is the only build-time step you
need, and it emits exactly the schema above:

```bash
PYTHONPATH=src python3 tools/export_wordlist.py \
    --out wordlist_asset.json --min-zipf 2.5
```

Measured output: **36,406 entries, 7.9 MB raw JSON, 96% carrying a WordNet
clue**. Dropping `--min-zipf` gives the full ~165,000 entries (~26 MB), which you
only need if you want anchors and theme entries drawn from rarer vocabulary than
the fill pool. Both compress well; consider a packed binary format if app size
matters.

The 4% without a clue are the phrases and proper nouns from the curated
supplement (`IDOS`, `SIXSEVEN`, …), which WordNet does not cover — they surface
as stub clues at runtime (§8).

### 2.1 Sources and licensing

| source | role | license |
|---|---|---|
| ENABLE1 | base word list (~172k) | public domain |
| `wordfreq` (PyPI) | `freq_zipf` | Apache 2.0 (code); CC-licensed data, attribution |
| WordNet (Princeton) | `synset_count`, `clue` glosses | permissive, commercial use explicitly allowed |
| curated supplement (`data/raw/supplement.tsv`) | phrases, proper nouns, slang, abbreviations | authored here |

Do **not** substitute TWL/SOWPODS (proprietary), IMDb datasets (license bars
commercial use), or Urban Dictionary (no clean license). See `docs/research.md`
§4 for the full analysis and for the richer sources (Wiktextract, Wikidata) that
are the recommended next expansion.

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

score = freq_zipf * 2.0
      + sense_bonus + phrase_bonus
      - obscurity_penalty - crosswordese_pen - short_obscure_pen
```

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

Fast "which words match `C.T`?" lookups. Built once per fill pool.

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
and this structure is far simpler to port. Revisit only if profiling says so.

**You do not need a `count()` method.** The reference implementation has one (and
a `bucket_size()`), left over from an earlier variable-ordering scheme that sized
domains on demand. The current search sizes domains from the cached `domains` map
instead, so neither is called from anywhere. Don't port them.

---

## 6. The solver

Word-level CSP: one variable per **slot**, domain = candidate words. Do **not**
model individual letters as variables — that formulation does not scale (§10.3).

### 6.1 State

```
assignment: Map<slotId, String>        // slot -> chosen word text
used:       Set<String>                // every word placed (no duplicates in a puzzle)
domains:    Map<slotId, Entry[]>       // UNASSIGNED slots only
```

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
assignment = copy(preAssigned)          // anchors, §7.2
used       = set(preAssigned.values())
for each slot not in assignment:
    domains[slot.slotId] = candidates(pattern(slot, assignment), exclude=used)
```

### 6.3 Fill pool

Restrict the index to entries with `freq_zipf >= FILL_MIN_ZIPF` (**2.5**,
*measured*), ~36k words. This is the second half of the quality fix: because
every word in the pool is recognizable, **any valid fill is a publishable fill**.
Combined with §4's grid shapes it costs nothing in solvability.

Anchors (§7) are drawn from the *full* list, not the fill pool, and are
pre-assigned, so they don't need to be in the index.

### 6.4 Constraint propagation (AC-3 style)

After an assignment, direct forward-checking only updates slots that cross the
assigned slot. This cascade goes further: narrowing a slot's domain shrinks the
set of letters it can contribute at *its* crossings, which can narrow slots two
hops away.

```
propagate(seedSlotIds) -> (ok: bool, saved: Map<slotId, Entry[]>):
  saved = {}                                   // pre-call domain, for undo
  queue = seedSlotIds; queued = set(queue)
  while queue not empty:
    sid = queue.removeFirst(); queued.remove(sid)
    if sid not in domains: continue            // already assigned
    domain = domains[sid]
    if domain.length > PROPAGATE_DOMAIN_CAP or slot has no crossings: continue
    for (idx, (otherId, otherIdx)) in slots[sid].crossings:
      if otherId not in domains: continue
      allowed  = { word[idx] for word in domain }        // letters possible at idx
      filtered = [e for e in domains[otherId] if e.text[otherIdx] in allowed]
      if filtered.length != domains[otherId].length:
        saved.putIfAbsent(otherId, domains[otherId])     // FIRST value only
        domains[otherId] = filtered
        if filtered is empty: return (false, saved)      // dead end
        if otherId not in queued: queue.add(otherId); queued.add(otherId)
  return (true, saved)
```

`PROPAGATE_DOMAIN_CAP = 150` *(measured)*. Skipping propagation *from* slots with
huge domains is a pure performance guard: a barely-constrained slot's letter set
is close to "anything goes", so the scan costs more than it prunes. Removing the
cap made 17x17 ~85ms/node; setting it to 50 was worse than 150 for 9x9.

### 6.5 Search

```
run() -> assignment | null:
  steps += 1
  if steps > maxSteps or now > deadline: return null
  if domains is empty: return copy(assignment)          // every slot assigned: solved

  // --- variable ordering: MRV, ties by degree ---
  bestId = argmin over sid in domains of
             (domains[sid].length, -slots[sid].crossings.length)

  // --- authoritative candidate list for the decision ---
  fresh = candidates(pattern(slots[bestId], assignment), exclude=used)
  candidatesSorted = jitter > 0
      ? sort(fresh) by -(score + rng.uniform(-jitter, +jitter))
      : sort(fresh) by -score
  if candidatesSorted is empty: return null

  crossers = [(otherId, otherIdx) for slots[bestId].crossings.values
              if otherId in domains]

  for entry in candidatesSorted:
    assignment[bestId] = entry.text
    used.add(entry.text)
    remove bestId from domains

    saved = {}; deadEnd = false

    // one-hop forward check (exact: recomputed from the index)
    for (otherId, _) in crossers:
      saved[otherId] = domains[otherId]
      domains[otherId] = candidates(pattern(slots[otherId], assignment), exclude=used)
      if domains[otherId] is empty: deadEnd = true; break

    // multi-hop cascade
    if not deadEnd:
      (ok, propSaved) = propagate(crossers.map(otherId))
      for (k,v) in propSaved: saved.putIfAbsent(k, v)   // keep EARLIEST saved value
      if not ok: deadEnd = true

    if not deadEnd:
      result = run()
      if result != null: return result

    // ---- undo, exactly ----
    for (otherId, oldDomain) in saved: domains[otherId] = oldDomain
    remove bestId from assignment
    used.remove(entry.text)
    domains[bestId] = fresh                              // NB: fresh, not a recompute

    if now > deadline: return null

  return null                                            // leaves domains[bestId] = fresh
```

**Undo correctness — the subtlest part of the port.** `domains` is a single
mutable map shared across the whole recursion, with a manual undo trail. Get
these exactly right:

- `saved` records each touched slot's domain from *before this candidate was
  tried*. When merging `propSaved`, keep the **earliest** value (`putIfAbsent`),
  never overwrite — a slot touched by both the one-hop check and the cascade must
  revert to its pre-assignment state, not the intermediate one.
- On backtrack, restore `domains[bestId] = fresh` (the list computed *before* any
  candidate was tried), not a fresh recomputation.
- When the loop exhausts all candidates and returns `null`, `domains[bestId]`
  must be left set to `fresh` — the slot is unassigned again and ancestors will
  reconsider it. Deleting it here is a bug (it was one; symptom: some slots never
  get filled on deeper branches).

**Cached domains may be stale.** `domains` is used *only* for the cheap MRV
comparison. A cached list can contain a word that another, non-crossing slot has
since consumed. That is fine and intentional: the candidate list actually used to
branch (`fresh`) is always recomputed against live `used`. Do not "fix" the
staleness with global invalidation; it costs more than it saves.

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
   `recentUsage` (the last 10 puzzles' answers, per the brief), preferring high
   score, length >= 4.
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

1. If the entry has a WordNet gloss (baked into the asset as `clue`): use it,
   capitalized, trailing period stripped, with a part-of-speech marker appended
   for verbs/adjectives/adverbs (`(verb)`, `(adj.)`, `(adv.)`).
2. Else if `is_proper`: a stub from its tags.
3. Else if `is_phrase`: a stub from its tags.
4. Else: a placeholder (`"<n>-letter word"`).

Then a **giveaway filter** rejects any clue that leaks the answer — this part is
worth porting exactly, and needs no NLP:

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

If a clue is a giveaway, fall back to the placeholder.

**Difficulty score** (1 easy … 5 hard): `clamp(6.0 - mean(zipf of clue words with
length > 2), 1, 5)`. Rarer clue vocabulary reads as harder.

Known gaps, in priority order: proper nouns and phrases get useless stub clues;
there is no fill-in-the-blank, trivia, or wordplay generation; nothing verifies a
gloss actually matches the intended sense (observed failure: `EVENS` clued as
"the latter part of the day"). `docs/research.md` §5 specifies the intended
pipeline (n-gram fill-in-the-blank, Wikidata-templated trivia, a local embedding
ambiguity check, and a sparse LLM pass over theme entries only).

---

## 9. Orchestration

```
generatePuzzle(size, weekday, allEntries, fillIndex, srsWords, recentUsage, seed):
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
repetitionPen  = 2.0 * (entries appearing in recentUsage)

score = answerQuality + varietyBonus + anchorBonus + themeBonus
      - obscurity - repetitionPen
```

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

Generation, warm (word list already loaded), reference hardware:

| size | time | fill success | quality-gate offenders |
|---|---|---|---|
| 5x5 | ~0.1-1.5s | reliable | 0 |
| 9x9 | ~0.13s | reliable | 0 |
| 17x17 | ~0.8-8s (occasionally ~30s) | mostly | 0 |

Invariants worth asserting in tests:

1. `black[r][c] == black[n-1-r][n-1-c]` for all cells.
2. Every slot length >= 3 and <= `maxEntryLen`.
3. All white cells form one connected component.
4. For every slot and every crossing `(i → (otherId, j))`:
   `fill[slot][i] == fill[otherId][j]`.
5. No word appears twice: `distinct(fill.values()).length == fill.length`.
6. Every pre-assigned anchor still present in the final fill.
7. Every non-anchor entry clears `QUALITY_FLOOR_BY_LENGTH`.

The reference implementation's tests (`tests/`) cover 1-6.

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
- Wiktextract/Wikidata lexical expansion — phrases, idioms and proper nouns are
  currently a ~80-entry hand-curated supplement, which is the biggest single
  limitation on puzzle *character*.
- Any real clue generation beyond WordNet glosses (§8).
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
| 10 | **Do not reuse answers from the previous 10 puzzles** | **GAP** | `recentUsage` reaches anchor selection (§7.2) and the puzzle score (§9.2) but **never the solver**, so ordinary fill can repeat recent answers. Fix in your port: add `recentUsage` to the solver's initial `used` set (§6.2). One line, and it makes the requirement hold |
| 11 | Prefer words recognizable to a modern solver; avoid obscure/archaic fill | MET | §2.4, §6.3, §9.1 — this was the subject of a major fix |
| 12 | **Difficulty is not obscurity** — prefer "Oh, of course!" over unknowable trivia | PARTIAL | Obscurity is controlled; difficulty is only a crude clue-vocabulary metric (§8), and is not tunable per puzzle |
| 13 | Allow phrases, proper nouns, abbreviations, idioms, slang, titles, multi-word entries; strip spaces for the grid but keep display form | PARTIAL | Schema fully supports it (`text` vs `display`, §2), but the data is ~80 curated rows. This is the biggest limit on puzzle *character* |
| 14 | Avoid excessive crosswordese | PARTIAL | 33-word denylist plus scoring (§2.3); not data-driven |
| 15 | Rich lexical metadata: recognizability, interestingness, difficulty, obscurity, modern relevance, thematic relevance, classification, temporal/cultural relevance, clue potential, prior usage, display forms | PARTIAL | Frequency, obscurity, sense count, classification and display forms are derived. Interestingness, modern/temporal/cultural relevance, thematic relevance and clue potential are **not** — they need the Wikidata/pageviews/Ngrams layer in `research.md` §4 |
| 16 | Optimize the **whole puzzle**, not the best word per slot | PARTIAL | Score-ordered search + refinement (§6.6) + a puzzle-level gate (§9.1). No beam search; only one partial solution is ever kept |
| 17 | Puzzle-level scoring (theme + answers + variety + interest + clue potential − obscurity − crosswordese − repetition − bad structure) | PARTIAL | §9.2 implements the computable terms; it is *reported*, not used to steer search |
| 18 | A healthy mixture of standout answers and ordinary supporting vocabulary | **GAP** | Nothing explicitly balances "sparkle" against filler |
| 19 | Investigate CSP, backtracking, constraint propagation, MRV, weighted CSP, beam search, stochastic search, pattern indexing, building grids around anchors, keeping multiple partial solutions | MET (research) / PARTIAL (build) | §6 implements CSP + MRV + forward checking + AC-3 cascade + weighted ordering + pattern index. Beam search and multiple retained partials were **not** built; naive LDS was tried and rejected (§10.4) |
| 20 | Clues: varied types, entertaining, no giveaways, no derivatives of the answer, semantically verified, witty/misdirecting, fair, adjustable difficulty | **LARGELY GAP** | §8. Only the giveaway/derivative filter is properly done. No wordplay, no variety, no semantic verification, no fill-in-the-blank or trivia. Treat §8 as a stub to replace |
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
