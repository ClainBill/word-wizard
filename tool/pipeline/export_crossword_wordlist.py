#!/usr/bin/env python3
"""Build-time exporter for the crossword's scored word list.

This is step one of the two-step split the crossword generator is built
around (PORTING_SPEC.md §1): every natural-language judgement — corpus
frequency, sense counts, topical tags, quality scoring — happens *here*,
offline, and is baked into a static asset. The Dart runtime then needs no
NLP, no dictionary queries and no network to build a puzzle; it is pure
data structures and search.

Source is the app's own bundled Wiktionary dictionary rather than the
spec's ENABLE1 + WordNet pairing. The spec's §13 names its ~80-row curated
supplement of phrases/proper nouns as "the biggest single limitation on
puzzle character"; Wiktionary supplies 148k multi-word entries and 69k
proper nouns with real display forms, so it is a strict improvement on the
same schema. `freq_zipf` still comes from `wordfreq`, exactly as the spec
specifies and as `build_dictionary.py` already uses it, so every measured
constant downstream (the 2.5 fill floor, the score formula, the quality
floors) keeps the units it was calibrated in.

Usage:
    python3 tool/pipeline/export_crossword_wordlist.py \
        --db assets/db/dictionary.db \
        --out assets/crossword/wordlist.tsv \
        --min-zipf 2.0

Requires: wordfreq (pip install wordfreq). Stdlib otherwise.
"""

from __future__ import annotations

import argparse

import re
import sqlite3
import sys
import time
from collections import defaultdict

try:
    from wordfreq import tokenize, zipf_frequency
except ImportError:  # pragma: no cover - operator-facing
    sys.exit("Missing dependency: pip install wordfreq")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# --- §2.4 inclusion filter -------------------------------------------------

MIN_LENGTH = 3
MAX_LENGTH = 17
# Only short entries carry a frequency floor. The spec measured a global
# floor and found it actively breaks the solver: cutting ~50% of the 8- and
# 9-letter pool removes the letter-pattern diversity the search needs, and
# 9x9 fill success dropped to 0/4 (§2.4, §10.5). Short lengths are where
# obscure fill is both most jarring and most avoidable.
SHORT_LENGTH_MAX = 6
SHORT_MIN_ZIPF = 0.01

# --- §2.3 score formula ----------------------------------------------------

# Technically valid words that appear in crosswords far out of proportion to
# real usage. Verbatim from the spec, which invites extension.
CROSSWORDESE = {
    "ANOA", "ETUI", "ERNE", "ESNE", "OLEO", "EPEE", "ANTA", "ARIL", "ORLE",
    "ULNA", "UTA", "ENOL", "ESTOP", "ALOE", "ERG", "ERGS", "OBI", "OBIS",
    "AGA", "AGAS", "ARGOT", "ONAGER", "SNEE", "STOA", "TOLA", "ULEMA",
    "NENE", "AALII", "OAST", "EELY", "ERNES", "ESES", "ESNES",
}

# Not in the spec, which has no notion of abbreviations because WordNet
# carries none. Wiktionary carries thousands, and an entry whose only
# available clue is "Application programming interface, for short" spells
# out its own answer the moment it is read — a legitimate convention in
# moderation, unacceptable when it dominates the fill. Modelled as a
# sibling of CROSSWORDESE's penalty rather than an outright ban, so a
# genuinely common abbreviation can still earn its place.
#
# 3.5 is measured against this word list, not guessed: length 3 is where
# abbreviations concentrate (they are almost all 3-4 letters) and where the
# solver has the fewest alternatives, so the penalty is sized to push a
# merely-attested initialism such as CSV or BHD *below* the length-3 quality
# floor of 2.5 (spec §9.1) while leaving one carrying several real senses
# above it. At 2.5 the whole family cleared the floor and the gate never
# fired.
ACRONYM_PENALTY = 3.5

ABBREVIATION_GLOSS = re.compile(
    r"^(?:Abbreviation|Initialism|Acronym|Clipping|Ellipsis) of ", re.IGNORECASE
)

# Entries that exist only as a variant of some other spelling. An
# abbreviation is a legitimate crossword answer with a legitimate clue
# ("Federal Bureau of Investigation, for short"); a variant spelling is
# neither. Its only available clue is a pointer at the word it varies from,
# which is how a 5x5 grid ended up cluing USUN as "Alternative form of ussun"
# and SURAH as "Alternative spelling of sura".
#
# "Synonym of X" is deliberately absent: that one *is* a good clue, and the
# clue pipeline already rewrites it into a bare synonym.
VARIANT_GLOSS = re.compile(
    r"^(?:Alternative|Alt\.?|Obsolete|Archaic|Dated|Nonstandard|Non-standard|"
    r"Informal|Rare|Eye|Pronunciation|Common|Deliberate)\s+"
    r"(?:form|spelling|misspelling|dialect|dialectal spelling|letter-case form)\s+of\b"
    r"|^(?:Misspelling|Eye dialect|Pronunciation spelling|Superseded spelling)\s+of\b",
    re.IGNORECASE,
)

# Wiktionary orders senses with the primary meaning first; the app's clue
# pipeline only ever draws on the earliest few, so sense counting and
# acronym detection use the same window to stay consistent with what the
# solver will actually see clued.
MAX_SENSE_ORDER_FOR_CLUE = 2


def score_entry(zipf: float, sense_count: int, is_phrase: bool,
                text: str, is_acronym: bool) -> float:
    """PORTING_SPEC.md §2.3, verbatim, plus the acronym term above."""
    deficit = max(0.0, 3.0 - zipf)
    obscurity_penalty = (deficit ** 1.7) * 1.1
    sense_bonus = min(sense_count, 5) * 0.3
    crosswordese_pen = 4.0 if text in CROSSWORDESE else 0.0
    short_obscure_pen = 2.0 if (len(text) <= 4 and zipf < 2.0) else 0.0
    phrase_bonus = 1.0 if is_phrase else 0.0
    acronym_pen = ACRONYM_PENALTY if is_acronym else 0.0
    return (zipf * 2.0
            + sense_bonus + phrase_bonus
            - obscurity_penalty - crosswordese_pen - short_obscure_pen
            - acronym_pen)


# --- topical tags ----------------------------------------------------------

# The spec's day-of-week themes (§7.1) need `pop_culture` and
# `general_knowledge` pools, and its reference implementation fills them
# from ~80 hand-tagged rows — "a very small pool ... a known limitation"
# (§2). Wiktionary has no topic column in this app's schema, but its glosses
# are written to a house style regular enough to key off: definitions state
# their field ("In chemistry, ...", "A city in ..."). Coarse and
# recall-oriented by design — a slightly over-inclusive `science` pool of
# thousands beats an exact one of twelve.
TAG_PATTERNS = {
    "geography": re.compile(
        r"\b(?:city|town|country|river|province|island|capital|region|"
        r"mountain|village|municipality|county|peninsula|archipelago|"
        r"continent|lake|desert)\b", re.IGNORECASE),
    "history": re.compile(
        r"\b(?:historical|history|ancient|medieval|dynasty|empire|"
        r"civilization|prehistoric|antiquity|colonial)\b", re.IGNORECASE),
    "politics": re.compile(
        r"\b(?:political|politics|government|parliament|election|"
        r"legislature|treaty|minister|senate|diplomat|constitution)\b",
        re.IGNORECASE),
    "science": re.compile(
        r"\b(?:chemistry|chemical|physics|biology|biological|mathematics|"
        r"astronomy|medicine|medical|anatomy|geology|molecule|organism|"
        r"species|genus|enzyme|isotope|algebra)\b", re.IGNORECASE),
    "pop_culture": re.compile(
        r"\b(?:music|musical|film|movie|cinema|television|band|album|song|"
        r"video game|celebrity|comic|anime|manga|sitcom|pop\b)",
        re.IGNORECASE),
    "sport": re.compile(
        r"\b(?:football|soccer|baseball|basketball|cricket|tennis|golf|"
        r"boxing|athletics|hockey|rugby|olympic)\b", re.IGNORECASE),
}


def tags_for(glosses: list[str]) -> list[str]:
    blob = " ".join(glosses[:3])
    return sorted(tag for tag, pattern in TAG_PATTERNS.items()
                  if pattern.search(blob))


# --- grid form -------------------------------------------------------------

STRIP = re.compile(r"['’]")
PURE_ALPHA = re.compile(r"^[A-Za-z]+$")


def grid_text(headword: str) -> str | None:
    """The A-Z uppercase form a headword occupies in the grid, or None if it
    doesn't belong in the pool at all.

    Apostrophes are dropped (DONT for "don't", the spec's `text` vs `display`
    split, §2).

    The hard rule is that **`wordfreq` must recognise the headword as a single
    token**, because otherwise its Zipf score is not an observation at all.
    Given a string it can't tokenize as one word, `wordfreq` splits it and
    combines the parts, and the combination runs *high*: "turtle-footed" comes
    back at 3.20 and "front butt" at 4.24, above "propeller". Every
    frequency-based filter that admits "house of cards" admits those too.

    Apostrophe forms are the subtle case and cost a shipped puzzle to find.
    `tokenize` keeps the contractions it knows whole — "don't" 6.20,
    "o'clock" 4.04, "can't" 5.80 — but splits the ones it doesn't, so
    "us'un" scores 4.60 off `us` + `un` and "g'hal" 3.65 off `g` + `hal`.
    Both duly outscored MUSE (3.59) and landed in a 5x5 grid. Asking
    `tokenize` directly replaces three hand-rolled rules (no spaces, no
    hyphens, apostrophes are fine) with the one criterion they were all
    approximating.

    This leaves the word list single-word, which is also where the reference
    implementation lands from the other direction: its base list is ENABLE1,
    and every one of its ~80 phrases is hand-curated (§13). A curated
    supplement is the supported way to add phrases; an automatic frequency
    test is not.
    """
    if len(tokenize(headword, "en")) != 1:
        return None
    stripped = STRIP.sub("", headword)
    if not PURE_ALPHA.match(stripped):
        return None
    return stripped.upper()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="assets/db/dictionary.db")
    ap.add_argument("--out", default="assets/crossword/wordlist.tsv")
    ap.add_argument("--min-zipf", type=float, default=2.0,
                    help="Drop entries below this Zipf frequency. The solver's "
                         "own fill pool floor is 2.5 (spec §6.3); exporting a "
                         "little below that leaves anchors and theme entries "
                         "some rarer vocabulary to draw on.")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row

    log(f"reading entries from {args.db} ...")
    # One row per headword+pos in this schema; the crossword cares about the
    # grid form, so entries collapse into groups keyed by that.
    groups: dict[str, dict] = {}
    for row in conn.execute(
            "SELECT id, headword, pos, frequency_rank FROM entries"):
        text = grid_text(row["headword"])
        if text is None or not (MIN_LENGTH <= len(text) <= MAX_LENGTH):
            continue
        rank = row["frequency_rank"] or (1 << 30)
        group = groups.get(text)
        if group is None:
            groups[text] = group = {
                "text": text, "display": row["headword"], "entry_id": row["id"],
                "rank": rank, "ids": [], "pos": set(),
            }
        group["ids"].append(row["id"])
        group["pos"].add(row["pos"])
        # The best-ranked spelling wins the display form and the entry id the
        # runtime will pull a clue from: "and" the conjunction beats "AND" the
        # initialism, "I dos" keeps its spaces.
        if rank < group["rank"]:
            group["rank"] = rank
            group["display"] = row["headword"]
            group["entry_id"] = row["id"]
    log(f"  {len(groups):,} distinct grid forms")

    log("reading clue-eligible senses ...")
    glosses_by_entry: dict[int, list[str]] = defaultdict(list)
    for row in conn.execute(
            "SELECT entry_id, gloss FROM senses WHERE sense_order <= ? "
            "ORDER BY entry_id, sense_order", (MAX_SENSE_ORDER_FOR_CLUE,)):
        glosses_by_entry[row["entry_id"]].append(row["gloss"])
    conn.close()

    log("scoring ...")
    rows: list[str] = []
    kept = 0
    for group in groups.values():
        text = group["text"]
        display = group["display"]
        length = len(text)

        # wordfreq lowercases internally; the display form is what a corpus
        # would have seen, so look that up rather than the stripped grid form
        # ("I dos" and "IDOS" are not the same query).
        zipf = zipf_frequency(display, "en")

        if length <= SHORT_LENGTH_MAX and zipf < SHORT_MIN_ZIPF:
            continue
        if zipf < args.min_zipf:
            continue

        glosses: list[str] = []
        for entry_id in group["ids"]:
            glosses.extend(glosses_by_entry.get(entry_id, ()))
        # §2.2: count senses, not entries — and a word with no usable gloss
        # has nothing to be clued from, so it never earns the sense bonus.
        sense_count = len(glosses)
        # An entry whose every clue-eligible gloss is "Abbreviation of X" can
        # only ever be clued by spelling itself out.
        is_acronym = bool(glosses) and all(
            ABBREVIATION_GLOSS.match(g) for g in glosses)

        # Dropped outright rather than scored down: unlike an abbreviation,
        # a variant spelling has no clue that isn't a pointer at another
        # word, so there is no score at which it becomes usable fill.
        if glosses and all(VARIANT_GLOSS.match(g) for g in glosses):
            continue

        # Apostrophe forms only, now that multi-word headwords are gone —
        # DONT/"don't" is the surviving case of the spec's text-vs-display
        # split, and it earns the same bonus: they make good entries.
        is_phrase = STRIP.search(display) is not None
        # §2.2's concern, in this dictionary's terms: a capitalised headword
        # with no lowercase spelling anywhere in the group is a proper noun
        # masquerading as an ordinary word, and must not collect the
        # "well-attested common word" bonus a real common noun earns.
        is_proper = display[:1].isupper() and not is_acronym

        score = score_entry(zipf, 0 if is_proper else sense_count,
                            is_phrase, text, is_acronym)

        flags = (1 if is_proper else 0) | (2 if is_phrase else 0) | (4 if is_acronym else 0)
        rows.append("\t".join((
            text,
            display,
            str(group["entry_id"]),
            f"{zipf:.2f}",
            str(min(sense_count, 99)),
            str(flags),
            f"{score:.2f}",
            ",".join(tags_for(glosses)),
        )))
        kept += 1

    rows.sort()
    import os
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        # A tab-separated body rather than the spec's suggested JSON: it is
        # the "packed format" §2 recommends for app size, and Dart parses it
        # with a split rather than a full object graph, which matters on the
        # UI-blocking startup path.
        fh.write("# crosswordler-wordlist\tv1\t"
                 "text\tdisplay\tentry_id\tzipf\tsenses\tflags\tscore\ttags\n")
        fh.write("\n".join(rows))
        fh.write("\n")

    size_mb = os.path.getsize(args.out) / (1024 * 1024)
    log(f"wrote {kept:,} entries to {args.out} ({size_mb:.1f} MB)")

    by_length: dict[int, int] = defaultdict(int)
    fill_pool = 0
    for r in rows:
        parts = r.split("\t")
        by_length[len(parts[0])] += 1
        if float(parts[3]) >= 2.5:
            fill_pool += 1
    log(f"  fill pool (zipf >= 2.5): {fill_pool:,}")
    log("  by length: " + ", ".join(
        f"{n}:{by_length[n]:,}" for n in sorted(by_length)))


if __name__ == "__main__":
    main()
