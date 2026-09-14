# Crosswordler — App Integration Guide

**Audience:** whoever is wiring the generator into the existing Flutter/Dart
SRS app.

**This is not the algorithm.** `docs/PORTING_SPEC.md` specifies the generator
itself — grids, solver, clues, ~1,500 lines of measured detail. Read it to
*build* the engine. Read this to work out what the **app** has to provide, what
it gets back, and what it must never do. Where the two disagree, the spec wins
on algorithm and this document wins on integration.

---

## 1. What ships, and what runs where

| | where | needs network | cost |
|---|---|---|---|
| word-list asset | bundled in the app | no | — |
| grid + fill + clues | on device | no | free |
| editorial pass | your backend → OpenAI | **yes** | ~3 calls/subscriber/day |

The generator is **offline and deterministic**. Given the same seed, word list
and inputs it produces the same puzzle, on any device, forever. Nothing about
play requires a network.

The editorial pass is the single exception and is **strictly optional** — it
improves clues and never gates a puzzle. Design every path around it failing.

### The asset

Produced by `tools/export_wordlist.py`, committed as
`data/processed/wordlist_asset.json`:

- **72,214 entries, 22.8 MB raw JSON, 3.7 MB gzipped.** Ship it compressed and
  decompress on first launch, or convert to a packed binary if the 22 MB
  unpacked matters on device.
- 100% carry at least one clue, 64% carry two.
- Schema in `PORTING_SPEC.md` §2. Every field is needed at runtime except
  `synset_count`, which only feeds the precomputed `score`.

Regenerate it whenever the word list changes; it is a build artifact, not
something to hand-edit.

---

## 2. What the app must give the generator

```dart
Puzzle generate({
  required int size,           // 5, 9 or 17
  required String weekday,     // "Monday".."Sunday"
  List<String> srsWords,       // this user's due vocabulary, highest priority first
  Set<String> blockedAnswers,  // answers already solved — see §3
  int? seed,                   // null = random; pass one to reproduce a puzzle
});
```

**`srsWords` is the product.** They become anchors: the grid is built around
them, and if they cannot be placed the set degrades gracefully to fewer or none
(`PORTING_SPEC.md` §7.2). Pass them in priority order; a word not in the word
list is still honoured, synthesised as a literal anchor.

Send words in whatever form your SRS holds; the generator normalizes to A-Z.
A three-letter minimum applies — anything shorter cannot be a crossword answer.

**`seed` is worth storing.** A puzzle is `(seed, size, weekday, srsWords,
blockedAnswers)` and nothing else, so persisting those five reproduces it
exactly. That is much cheaper than storing grids, and it means a support
request ("this puzzle was broken") is reproducible.

---

## 3. Solve events — the part the app alone can do

The brief forbids reusing answers the user has **discovered** in the last 10
puzzles. That is *solved*, not *shown*, and the difference is the product:

- A puzzle they opened and abandoned taught them nothing. Suppressing its
  answers wastes ten puzzles' worth of vocabulary.
- An answer they only got by revealing cells was not discovered. It must come
  back, because they still need to learn it.

So record, per finished puzzle:

```dart
class SolveEvent {
  String puzzleId;
  Set<String> solved;    // entered correctly by the user
  Set<String> revealed;  // ANY cell of this answer was hinted or revealed
}

// blockedAnswers = union of (solved - revealed) over the last 10 events
```

An answer in both sets counts as revealed: partial help still means it was not
worked out. Normalize to grid form (A-Z only) so "I do's" and "IDOS" are one
answer. Reference implementation: `src/crosswordler/history.py`, ~60 lines,
no I/O.

**Also feed this back into the SRS.** An answer solved unaided in a crossword is
a genuine retrieval event for that word, which is exactly what the SRS schedule
wants to know. The generator does not care, but the app should.

---

## 4. The editorial pass

One LLM call over the finished puzzle: it judges the whole thing, rewrites weak
clues and can replace answers it considers unfair. Details and prompt in
`PORTING_SPEC.md` §9.3; verification in §9.4.

### Never put the API key in the app

A key in a mobile binary is extractable in minutes, and then it is your bill,
your rate limit and your terms of service. The app calls **your** backend; your
backend calls OpenAI. A subscription already needs a backend for entitlement
checks, so this is close to free.

**The user's own key is a different matter.** Settings → AI features lets the
user paste their own OpenAI key (`lib/services/api_key_store.dart`). It is
theirs, on their device, in the platform keystore, and spent on their account;
the rule above is about a key *shared by every install*. Precedence in both
services: `proxyUrl` → the user's key (any build) → the `--dart-define` key
(debug builds only).

### Never block play on it

Measured, `gpt-5-mini` at `reasoning_effort: low`:

| size | latency | tokens |
|---|---|---|
| 5x5 | 15.0s | 677 in + 1,460 out |
| 9x9 | 15.5s | 1,076 in + 1,211 out |
| 17x17 | 13.7s | 2,580 in + 1,270 out |

Latency is flat in puzzle size — the cost is reasoning, not input length — and
~15s is a median, not a ceiling; one 9x9 took 30s. **Fifteen seconds between
tapping Play and seeing a grid is not acceptable**, so do not schedule it
there.

**Generate ahead of time instead.** Personalisation depends on SRS state, which
is known in advance, so build tomorrow's three puzzles when today's are
finished, or in the background on app open. That keeps the personalisation and
the editorial pass while removing the network from the critical path entirely.

If you do want a live path: show the deterministic puzzle immediately, and if
the review lands before the user starts, swap the clues. **Never swap clues
mid-solve.**

### Bound the call in wall-clock time

A socket timeout is not a deadline. Verify your HTTP client enforces a *total*
deadline — Dart's `Future.timeout` does; a bare socket option usually does not.
Without one, a suspended device or a stalled connection leaves the call hanging
indefinitely.

### Treat the response as untrusted

Every edit is re-validated before it lands, and this is not a formality — in
measured runs the model broke rules it had been given explicitly: clues
containing the answer, abbreviation signals, profanity. Port §9.4 exactly.

One rule is easy to miss and shipped a real bug: **word edits and clue edits
cannot both apply in one pass.** Word edits re-solve the grid, so slots keep
their ids but change their answers; applying clue edits afterwards puts a clue
for LLOYD'S onto SYNTAX. Take one kind per pass.

### Cost

At three puzzles per subscriber per day, roughly **$0.04–$1.80 per subscriber
per month** depending on model tier (`gpt-5-nano` / `gpt-5-mini` / `gpt-5`).
Not the constraint; latency is.

---

## 5. Failure modes and what to show

| what happens | what the app does |
|---|---|
| generator returns null (rare; see §11 targets) | retry with a new seed, then fall back to a smaller size |
| no network / backend down / key rejected | play the deterministic puzzle. **Say nothing** — nothing is missing from the user's point of view |
| review times out | same |
| review returns edits that all fail validation | play the deterministic puzzle |
| `assertPuzzleValid` fails after a revision | discard the revision, play the pre-review puzzle, and log it — this should be unreachable |

The pattern throughout: the deterministic puzzle is always valid and always
playable, and every optional layer degrades to it silently.

---

## 6. What is not solved yet

Be honest with your roadmap about these; they are known, measured, and open.

1. **Clue quality is the weak layer, not the grids.** Playtesting produced 33
   flagged clues across 9 puzzles. Grids, fill and speed are solved
   (0.13–0.20s median at every size); clues are where the remaining work is.
2. **Recognizability at three letters is unreliable.** Corpus frequency counts
   letter sequences, so DES, AIN, PAP and ABA all score as common words. The
   denylist and the LLM are the current defences; real solve-rate data from
   users is the fix. Expect to keep extending `CROSSWORDESE` from feedback.
3. **~141,000 usable entries still have no clue** and so cannot enter the fill
   pool. Extending the build-time backfill is cheap and is the single highest
   -leverage remaining task.
4. **Themes are shallow.** Weekday themes select answers by category rather
   than shaping clue subject matter, which is what the brief asked for.
5. **Black squares clump.** No rule against 2x2 all-black blocks yet; real
   grids avoid them.
6. **Difficulty is not calibrated.** It is a clue-vocabulary frequency metric,
   not anything validated against how hard people actually find a puzzle. Solve
   telemetry from the app is what would fix it — another reason to record §3
   properly.

---

## 7. Suggested order of work

1. Bundle the asset and port §4–§6 of the spec (grid, index, solver). Nothing
   else works without them, and they are the parts with exact test vectors
   (§11.1) — port those first and you will know immediately if it is right.
2. Port clue selection (§8) and the day/anchor layer (§7). At this point the
   app generates real personalised puzzles, entirely offline.
3. Record solve events (§3). Do this before launch even if nothing consumes
   them yet — the history is not reconstructable later, and both the cooldown
   and difficulty calibration depend on it.
4. Add the backend proxy and the editorial pass, off the click path.
