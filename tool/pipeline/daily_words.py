#!/usr/bin/env python3
"""Builds the word-of-the-day pool: the `daily_words` table.

The app shows one featured word a day (and can send it as a morning
notification). Picking that word at runtime from 740k entries by frequency
alone gave "paedo", "faxing" and "janky"; the pool needs judgement that
only exists offline, so it is chosen here and baked in, and the app just
takes row `(days since epoch) mod count`.

A word makes the pool when:

- the crossword word list (assets/crossword/wordlist.tsv, itself curated
  from corpus frequency, a constructor's tier and human familiarity
  ratings) has it as a plain lower-case word 5–12 letters long, familiar
  enough that a person recognises it (familiarity ≥ 3), used by
  constructors (tier ≤ 51), and *uncommon but real* — a zipf frequency
  between 2.3 and 3.3, i.e. "acumen" and "fortuitous" rather than "cat";
- or it is in the pipeline's advanced-vocabulary seed list, which is what
  the app is for and is admitted regardless of the frequency band;
- it is a lemma in the dictionary — not the plural, past or comparative
  of another headword — filed as a noun, verb, adjective or adverb;
- its first sense has an example sentence and a gloss that is a definition
  rather than a pointer ("form of", "spelling of") or a derivation ("One
  who…", "In a … manner", "Of or relating to…"), carries no usage warning
  (vulgar, offensive, slang, dated…), and isn't a wall of text;
- it isn't a derived form by shape (-er, -ness, -ly, -ing, -ology…), which
  the crossword list is full of and which make dull daily words.

The rows are shuffled with a fixed seed so consecutive days vary, and the
order is stable across rebuilds unless the inputs change.

Runs as part of build_dictionary.py, and on its own against a database
built before this step existed:

    python3 daily_words.py ../../assets/db/dictionary.db ../../assets/crossword/wordlist.tsv
"""
from __future__ import annotations

import random
import re
import sqlite3
import sys
from pathlib import Path

from build_dictionary import ADVANCED_VOCAB_SEED

ZIPF_MIN, ZIPF_MAX = 2.3, 3.3
FAMILIARITY_MIN = 3
TIER_MAX = 51
MAX_GLOSS_LENGTH = 160
SHUFFLE_SEED = 20260917

_WORD_RE = re.compile(r"[a-z]{5,12}")
_WARNING_RE = re.compile(
    r"vulgar|offensive|slang|derogatory|obsolete|archaic|dated|slur|pejorative|"
    r"spelling of|form of|initialism|abbreviation|acronym|plural of|past tense|"
    r"participle|misspelling",
    re.I,
)
_DERIVATION_RE = re.compile(
    r"^(One who|A person who|Someone who|Somebody who|Something that|That which|"
    r"In an? \w+ (manner|way)|In a manner|Of,? or (relating|pertaining)|"
    r"Of or (relating|pertaining)|Relating to|Pertaining to|The act of|The state of|"
    r"The quality of|The condition of|The property of|Capable of being|Able to be|"
    r"Not \w+able|Without \w+)\b",
    re.I,
)
_DERIVED_SHAPE_RE = re.compile(r"(er|or|ness|ist|ism|ly|ing|ology|ical|ised|ized)$")
# Wiktionary tags most of these, but not all — "Serious harassment or
# abuse" was a gloss for a word that is not going out as a notification.
_PROFANITY_RE = re.compile(
    r"shit|fuck|cunt|piss|cock|dick|arse|wank|bitch|whore|slut|nigg|fag|turd|crap|tits|"
    r"bastard|bugger|prick"
)
_INFLECTION_TYPES = ("plural", "past", "participle", "comparative", "superlative", "third-person")


def crossword_candidates(wordlist: Path) -> set[str]:
    """Lower-case lemma-shaped words the crossword list rates familiar and
    uncommon, by its own columns (see the file's header comment)."""
    out = set()
    with wordlist.open(encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) < 8:
                continue
            display, zipf, flags, tier, familiarity = f[1], float(f[2]), int(f[4]), int(f[6]), f[7]
            if flags != 0 or not _WORD_RE.fullmatch(display):
                continue
            fam = int(familiarity) if familiarity else 5
            if ZIPF_MIN <= zipf <= ZIPF_MAX and fam >= FAMILIARITY_MIN and tier <= TIER_MAX:
                out.add(display)
    return out


def add_daily_words(conn: sqlite3.Connection, wordlist: Path) -> int:
    """Builds the `daily_words` table; returns how many words it holds."""
    conn.execute("DROP TABLE IF EXISTS daily_words")
    conn.execute(
        """
        CREATE TABLE daily_words (
          id INTEGER PRIMARY KEY,
          entry_id INTEGER NOT NULL REFERENCES entries(id),
          headword TEXT NOT NULL
        )
        """
    )
    inflected = {
        row[0]
        for row in conn.execute(
            "SELECT DISTINCT f.form_text FROM forms f JOIN entries e ON e.id = f.entry_id "
            "WHERE e.headword <> f.form_text AND ("
            + " OR ".join(f"f.form_type LIKE '%{t}%'" for t in _INFLECTION_TYPES)
            + ")"
        )
    }
    candidates = crossword_candidates(wordlist) | set(ADVANCED_VOCAB_SEED)

    chosen: list[tuple[int, str]] = []
    for headword in sorted(candidates):
        seeded = headword in ADVANCED_VOCAB_SEED
        if _PROFANITY_RE.search(headword):
            continue
        if headword in inflected and not seeded:
            continue
        row = conn.execute(
            """
            SELECT e.id, e.pos, s.gloss,
                   (SELECT x.text FROM examples x WHERE x.sense_id = s.id LIMIT 1) AS example
            FROM entries e JOIN senses s ON s.entry_id = e.id
            WHERE e.headword = ? AND e.pos IN ('noun', 'verb', 'adj', 'adv')
            ORDER BY (e.frequency_rank IS NULL), e.frequency_rank, s.sense_order
            LIMIT 1
            """,
            (headword,),
        ).fetchone()
        if row is None:
            continue
        entry_id, pos, gloss, example = row
        if not example or _WARNING_RE.search(gloss) or len(gloss) > MAX_GLOSS_LENGTH:
            continue
        if not seeded and (
            pos == "adv" or _DERIVATION_RE.match(gloss) or _DERIVED_SHAPE_RE.search(headword)
        ):
            continue
        chosen.append((entry_id, headword))

    random.Random(SHUFFLE_SEED).shuffle(chosen)
    conn.executemany(
        "INSERT INTO daily_words (id, entry_id, headword) VALUES (?, ?, ?)",
        [(i + 1, entry_id, headword) for i, (entry_id, headword) in enumerate(chosen)],
    )
    conn.commit()
    return len(chosen)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    conn = sqlite3.connect(argv[1])
    try:
        count = add_daily_words(conn, Path(argv[2]))
        conn.execute("VACUUM")
    finally:
        conn.close()
    print(f"daily_words: {count} words")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
