#!/usr/bin/env python3
"""Consolidates spelling variants into one word.

Wiktionary files "colour", "grey", "judgement", "shew" and "olde" as
entries of their own, each with nothing but a pointer gloss: "Commonwealth
and Ireland standard spelling of color", "Archaic spelling of show". In a
dictionary app that means two search results for one word and a card that
says nothing. This step finds every such stub — a headword whose *every*
sense, across every part of speech, is a pointer of that shape — and
records it in a `spelling_variants` table:

    variant   headword   label
    colour    color      Commonwealth and Ireland
    grey      gray       Commonwealth
    judgement judgment   alternative
    shew      show       archaic

The app then shows the target's card for a variant, folds the variant into
the target's row in search, and lists the variants on the card. A headword
that has a real sense of its own alongside a pointer ("theatre" has its
own meanings in some editions) is left alone: it is a word, not a spelling.

Runs as part of build_dictionary.py, and on its own against a database that
was built before this step existed:

    python3 spelling_variants.py ../../assets/db/dictionary.db
"""
from __future__ import annotations

import re
import sqlite3
import sys
from collections import Counter

# What may stand before "spelling of" / "form of" for the gloss to count as a
# pointer and nothing more. Two shapes:
#   - a kind: "Alternative", "Archaic", "Dated", "Eye dialect", …
#   - a place, or several: "US", "Commonwealth and Ireland",
#     "American, Canadian, and Philippines", "Non-Oxford British English"
#     — words from _PLACE_WORDS, optionally followed by "standard".
# Anything else ("A form of", "The pyranose form of", "Having the form of",
# "Shortened form of") is a definition that happens to contain the words,
# or points at a different word rather than a different spelling, and is
# not matched.
_KIND = (
    r"(?:Alternative|Alternate|Archaic|Dated|Rare|Obsolete|Nonstandard|Non-standard|"
    r"Uncommon|Informal|Pronunciation|Eye dialect|Censored|Filter-avoidance|Feminist|"
    r"Leetspeak|Early Modern|Etymologically incorrect(?: rare)?|Standard)"
)
_PLACE_WORDS = {
    "US", "U.S.", "UK", "U.K.", "American", "America", "British", "Britain", "Canadian",
    "Canada", "Australian", "Australia", "New", "Zealand", "NZ", "Commonwealth", "Ireland",
    "Irish", "Scottish", "Scotland", "Welsh", "Wales", "Indian", "India", "South", "African",
    "Africa", "Philippine", "Philippines", "Oxford", "Non-Oxford", "English", "Hong", "Kong",
    "Singapore", "Singaporean", "Malaysia", "Malaysian", "Jamaican", "Jamaica", "Caribbean",
    "International",
}
_PLACES = r"[A-Z][A-Za-z.\-]+(?:(?:, and | and |, or | or |, | )[A-Z][A-Za-z.\-]+)*"
_QUALIFIER = rf"(?:{_KIND}|{_PLACES}(?: standard)?)"
POINTER_RE = re.compile(
    rf"^(?:(?P<qualifier>{_QUALIFIER})(?: letter-case)? (?:spelling|form)"
    rf"|(?P<misspelling>(?:Common )?[Mm]isspelling)) of (?P<target>.+?)\.?$"
)
_KIND_RE = re.compile(rf"^{_KIND}$")
_PLACE_SPLIT_RE = re.compile(r", and |, or |, | and | or | ")

# Kinds that read better lower-cased on a card ("archaic") than as they
# appear at the start of a gloss; place names keep their capitals.
_GENERIC_KINDS = {
    "alternative", "alternate", "archaic", "dated", "rare", "obsolete", "nonstandard",
    "non-standard", "uncommon", "informal", "pronunciation", "eye dialect", "censored",
    "filter-avoidance", "feminist", "leetspeak", "early modern", "standard",
    "etymologically incorrect", "etymologically incorrect rare",
}

# The label given to "Misspelling of X" stubs. They go in the table so a
# search for the misspelling still lands on the word, and the app knows by
# this label not to list them on the card as spellings.
MISSPELLING_LABEL = "misspelling"


def parse_pointer(gloss: str) -> tuple[str, str] | None:
    """(label, target headword) when [gloss] is nothing but a pointer."""
    m = POINTER_RE.match(gloss.strip())
    if not m:
        return None
    if m.group("misspelling"):
        label = MISSPELLING_LABEL
    else:
        qualifier = m.group("qualifier")
        if qualifier.endswith(" standard"):
            qualifier = qualifier[: -len(" standard")]
        if _KIND_RE.match(qualifier):
            label = qualifier.lower() if qualifier.lower() in _GENERIC_KINDS else qualifier
        else:
            # A run of capitalised words is only a place if every word is one:
            # "Any form of", "Shortened form of" and "The form of" are not.
            if not all(w in _PLACE_WORDS for w in _PLACE_SPLIT_RE.split(qualifier) if w):
                return None
            label = qualifier
    target = m.group("target").strip()
    # "Alternative form of color (“hue”)", "… of tyre: the rubber covering"
    # — the headword stops at the first bracket or clause mark.
    target = re.split(r"\s*[(\[:;,]", target, maxsplit=1)[0].strip()
    if not target:
        return None
    return label, target


def add_spelling_variants(conn: sqlite3.Connection) -> int:
    """Builds the `spelling_variants` table; returns how many rows it holds."""
    conn.execute("DROP TABLE IF EXISTS spelling_variants")
    conn.execute(
        """
        CREATE TABLE spelling_variants (
          variant TEXT NOT NULL,
          headword TEXT NOT NULL,
          label TEXT NOT NULL,
          PRIMARY KEY (variant, headword)
        )
        """
    )
    headwords = {row[0] for row in conn.execute("SELECT DISTINCT headword FROM entries")}

    # Every sense of every entry, grouped by headword across its POS rows.
    senses_by_headword: dict[str, list[str]] = {}
    for headword, gloss in conn.execute(
        "SELECT e.headword, s.gloss FROM senses s JOIN entries e ON e.id = s.entry_id"
    ):
        senses_by_headword.setdefault(headword, []).append(gloss)

    # First pass: stubs, with the target each points at.
    pointers: dict[str, tuple[str, str]] = {}
    for headword, glosses in senses_by_headword.items():
        parsed = [parse_pointer(g) for g in glosses]
        if not parsed or any(p is None for p in parsed):
            continue
        targets = Counter(target for _, target in parsed)  # type: ignore[misc]
        target, _ = targets.most_common(1)[0]
        if target == headword or target.lower() == headword.lower() or target not in headwords:
            continue
        # The label from the senses that point at the chosen target: "shew"
        # is an archaic spelling of "show" and a nonstandard one of "shoo".
        labels = Counter(label for label, t in parsed if t == target)  # type: ignore[misc]
        pointers[headword] = (target, labels.most_common(1)[0][0])

    # Second pass: a variant of a variant ("olde" → "old" is one hop, but a
    # chain can happen) resolves to the end of the chain, and a stub whose
    # target is a stub of it (two spellings pointing at each other) is left
    # alone rather than looping.
    rows = []
    for variant, (target, label) in pointers.items():
        seen = {variant}
        while target in pointers and target not in seen:
            seen.add(target)
            target = pointers[target][0]
        if target in seen:
            continue
        rows.append((variant, target, label))

    conn.executemany(
        "INSERT OR IGNORE INTO spelling_variants (variant, headword, label) VALUES (?, ?, ?)",
        rows,
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_spelling_variants_headword ON spelling_variants(headword)"
    )
    conn.commit()
    return conn.execute("SELECT COUNT(*) FROM spelling_variants").fetchone()[0]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    conn = sqlite3.connect(argv[1])
    try:
        count = add_spelling_variants(conn)
        conn.execute("VACUUM")
    finally:
        conn.close()
    print(f"spelling_variants: {count} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
