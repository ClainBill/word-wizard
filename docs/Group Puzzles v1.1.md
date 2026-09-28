# Group puzzles — v1.1 design and status

*19 September 2026. Companion to the Premium Offers spec (§2.1 "Shared
friend groups", §7.2 "Privacy and social safety").*

## The idea

A **group** is a handful of people (up to 12) who pool the words they're
each studying. Every day the pool becomes **one puzzle the whole group
solves** — the same grid or board for everyone — and a leaderboard says who
knew the group's vocabulary best.

**What a group plays** is chosen when it's made (27 Sept 2026): a
**crossword** at one size — Mini, Midi or Mega — or a **Word Hunt** board.
It's fixed after that (a trigger refuses a change), and
`group_publish_puzzle` accepts only a puzzle of the group's own kind and
size, so every member plays the same thing whatever build they're on. It's the social reason to keep saving words, and
an invite is the free tier's first hands-on look at Premium.

Two modes were in the brief: **competitive** (everyone solves their own
copy, scores compared) and **cooperative** (one shared grid filled
together). v1.1 ships competitive; cooperative is designed below and
deferred.

## What's built (v1.1)

### Server — `supabase/migrations/20260920000000_groups.sql`

| Table | Holds | Who may |
|---|---|---|
| `groups` | name, owner, 8-char invite code | members read; owner renames/deletes |
| `group_members` | role, display name, **`share_words` consent**, joined | members read; own row updates; own leave; owner removes |
| `group_words` | one row per (member, headword) + gloss | members read; own rows only |
| `group_puzzles` | the day's published grid (`CrosswordPuzzle.toJson()`), anchors, who generated | members read; publish via RPC |
| `group_scores` | solved/total/completed/time/aided per member per puzzle | members read; own row |

Row-level security does the access control; the app talks to the tables
directly through PostgREST as the signed-in user. Three things are
functions because they must be atomic or bypass RLS: `group_create`
(seats the owner, mints a code), `group_join` (code → membership, 12-cap),
`group_publish_puzzle` (**first writer wins** on `(group, date, kind)`,
returns the row everyone plays). A trigger deletes a member's words the
instant they switch sharing off; leaving or being removed cascades.
Verified live on the dev project with two users (join, RLS refusals,
publish race, scores, unshare, leave, delete).

### Generation — on the device, not a server

The Crosswordler engine is Dart and already ships in the app, so the
group's grid is built by **whichever member opens it first**:
`CrosswordRepository.generateFromPool()` runs the same generator, lexicon
and quality gates with the pool's headwords as anchors (clues from the
local dictionary when it knows the word, else the shared gloss), seeded
from `(group id, date)` so simultaneous generators produce like grids —
and `group_publish_puzzle` makes the race harmless anyway. The winning
grid is imported as an ordinary local `crossword_puzzles` row
(`group_puzzle_links` maps server id → local id, with a `kind`), so it's
**played, saved and timed by the existing crossword screen** with no
changes to it. A Word Hunt group works the same way through
`HuntRepository.generateFromPool()` / `importPuzzle()` and the hunt screen:
up to three pool words anchor the board (sorted, then shuffled by the
shared seed), and the day's theme colours it without adding an anchor,
since choosing one depends on each device's recent boards. Group rows are
never "today's puzzle" for the personal games and don't count against the
two-a-day allowance. Scores upload when the group screen is next opened
(skipped when unchanged), each with its leaderboard points from
`lib/domain/games/scoring.dart`.

**Built once, edited once (28 Sept 2026).** `group_claim_build` gives one
member a five-minute claim on the day's puzzle; they generate it, run the
AI editor on a crossword (their `crossword_review` allowance, `group`
bucket: five a day on Premium, one per group at most) and publish the
edited grid. Anyone opening it meanwhile is told who's building and waits
for it rather than generating — and paying for — another. One puzzle per
group per day; nobody can regenerate it. A person can be in at most five
groups, owned or joined.

**Group leaderboard.** Besides today's scores, the group screen shows
standings — every member's points summed over the group's puzzles, *This
week* (from Monday) or *All time* — from `group_leaderboard(group, since)`,
members only, listing members who haven't played yet with nothing. A
play with anything revealed (the crossword help menu) is marked helped:
it scores 0 and the standings ignore its points.

This is why there is no Cloud Run worker in v1.1: the planned "Dart
container reusing `lib/domain/crossword`" (Launch Checklist §3) is only
needed for *server-initiated* generation — see deferred.

### App

- **Games → Group puzzles** (`/games/groups`): your groups; *Start a
  group* (Premium); *Join with a code* (anyone signed in).
- **Group screen** (`/games/groups/:id`): today's puzzle (Play / Build
  today's puzzle), today's scores and the week / all-time standings, **Share my words**
  switch behind a consent dialog (`shareWordsConsentText`: headwords only,
  never notes, pinned meanings or lookups; removal is immediate), members
  (owner can remove), invite code (copy / share sheet), change my name,
  leave / delete.
- **Free-tier participation** (spec §10 recommendation adopted): a free
  account can join, share words, see the leaderboard and the invite code;
  **playing** goes through the crossword route's Premium gate → paywall
  with the puzzle as destination. Creating a group needs Premium.
- Groups need an account (they live on it); the screen asks for sign-in.

### Tests

`test/data/repositories/group_generation_test.dart` (real word list,
pool anchors → Midi → import → play state), `test/domain/groups`,
`test/features/groups/groups_screen_test.dart`.

## Deferred — with the design so it's a build, not a rethink

1. **Cooperative mode (shared grid, filled together).** Add
   `group_puzzle_fills(puzzle_id, cell, letter, user_id, at)` with RLS
   like scores, and subscribe with Supabase Realtime (`postgres_changes`
   on the puzzle id). The crossword screen gets an optional
   `SharedFillSink`: local fills are written through it and remote fills
   merge in (last write wins per cell; a conflicting letter shows the
   other person's colour until resolved). Scores become one team row.
   Needs presence (who's on which cell) for it to feel alive — Realtime
   presence channels do that. Estimated: a week, mostly UI.
2. **Word Hunt for groups.** `HuntRepository` needs the same
   `generateFromPool` split as the crossword got; the `kind = 'hunt'`
   column and publish RPC already accept it.
3. **Server-side / scheduled generation** (the Cloud Run Dart worker):
   generate every group's puzzle at 00:05 local and push "Today's group
   puzzle is ready" notifications. Removes the "first member builds it"
   wait (~0.3 s Midi in release, up to a few seconds on old phones) and
   enables notifications. Reuses `lib/domain/crossword` unchanged; the
   worker calls `group_publish_puzzle` with the service role.
4. **Invite links** (`lexery://join/<code>` and a web fallback page once
   there's a domain) so an invite is a tap, not a code to type.
5. **Push notifications**: invite accepted, puzzle ready, someone beat
   your score. Needs FCM/APNs setup (Launch Checklist §7).
6. **Moderation & safety** (spec §7.2, store policy): display names are
   the only user-generated text and are visible only inside an invited
   group, so v1.1 ships with owner-removal and leave. Before opening
   groups to public discovery (never planned) or adding chat, add:
   report-a-member (feedback function with `group_id`), block list,
   profanity filter on names. Terms now carry a conduct clause.
7. **Pool controls**: pick which lists to share rather than all study
   words; per-word opt-out; "words I've mastered only". The `group_words`
   table needs no change.
8. **History**: past puzzles and all-time standings
   (`group_scores` aggregated by user). Simple query + screen.
9. **Larger grids / difficulty vote**: Mega needs more anchors than
   `maxAnchors` allows today; consider a group-specific difficulty with
   `maxAnchors` raised, since the pool is the point.
10. **Owner transfer** and **owner leaving**: today an owner can only
    delete the group. Add `group_transfer(new_owner)` RPC.
11. **Account deletion** cascades memberships and words (FK); groups a
    deleted user owned are deleted with them — document in the privacy
    policy once groups launch, or add owner transfer first.

## Open product questions

- Should the daily puzzle exist only when ≥ N words are in the pool (the
  generator fills from the dictionary regardless, so a two-word pool
  yields a normal Midi with two anchors)? Current: any non-empty pool.
- Leaderboard scoring: currently finished → words → unaided → time. A
  points system that rewards *whose* words you solved is more social.
- Time zone: "today" is each member's local date; a group spanning time
  zones may see two puzzles straddle a day. Server-side generation (3)
  fixes this by pinning a group time zone.
