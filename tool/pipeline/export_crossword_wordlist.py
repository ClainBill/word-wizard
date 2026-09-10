#!/usr/bin/env python3
"""Packs the Crosswordler word-list asset into the form the app bundles.

This is step one of the two-step split the crossword generator is built
around (PORTING_SPEC.md §1): every natural-language judgement — corpus
frequency, WordNet sense selection, synonym and definition clues, the
Nediger constructor tier, the familiarity ratings — happens offline in the
Crosswordler project, and is baked into a static asset. The Dart runtime
needs no NLP, no dictionary queries and no network to build a puzzle; it is
pure data structures and search.

**This script derives nothing.** It reads Crosswordler's own build output
(`data/processed/wordlist_asset.json`, PORTING_SPEC.md §2) and rewrites it
as a tab-separated file that Dart can parse with one `split` per line rather
than building a 72,000-object JSON graph. It also folds in the two inputs
the JSON asset does not carry but the runtime fill pool (§6.3) needs:

- **familiarity** (`data/raw/word_ratings.tsv`), a 1-5 rating of whether a
  person knows the word. It is the one fill-pool bar that cannot be derived
  from the asset's own numbers — corpus frequency scores DES at 4.25 because
  below five characters it counts a letter sequence in running text, and the
  Nediger tier rates ABA 51 because a working constructor genuinely would
  use it.
- **crosswordese** (the `CROSSWORDESE` set in `src/crosswordler/wordlist.py`),
  read out of the source rather than copied, so a name added there from
  reader feedback reaches the app on the next export instead of drifting.

Usage:
    python3 tool/pipeline/export_crossword_wordlist.py \
        --crosswordler ../Crosswordler \
        --out assets/crossword/wordlist.tsv

Stdlib only.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

# Clue types are written as a single leading character so 118,000 clue
# fields don't each carry a word of type name. Kept in sync with
# PORTING_SPEC.md §2.5 / §8 — the runtime weights selection by type.
CLUE_TYPE_CODES = {
    "curated": "c",
    "definition": "d",
    "synonym": "s",
    "fill_in_blank": "f",
    "llm": "l",
}

FLAG_PROPER = 1
FLAG_PHRASE = 2
FLAG_CROSSWORDESE = 4


def load_crosswordese(source: Path) -> set[str]:
    """The `CROSSWORDESE` literal out of `wordlist.py`, without importing it.

    Importing the module would drag in wordfreq and NLTK — a heavy build-time
    dependency for one constant. The literal carries `#` comments, so strip
    those before evaluating it.
    """
    text = source.read_text()
    match = re.search(r"^CROSSWORDESE = \{(.*?)^\}", text, re.S | re.M)
    if not match:
        raise SystemExit(f"no CROSSWORDESE literal found in {source}")
    body = "\n".join(
        line for line in match.group(1).splitlines() if not line.strip().startswith("#")
    )
    return set(ast.literal_eval("{" + body + "}"))


def load_ratings(path: Path) -> dict[str, int]:
    """grid text -> 1-5 familiarity, from Crosswordler's tools/review_wordlist.py.

    A missing file is not fatal: no ratings simply means no rating-based
    exclusions, which is how Crosswordler itself treats it.
    """
    if not path.exists():
        print(f"warning: no ratings at {path}; familiarity will be blank", file=sys.stderr)
        return {}
    out: dict[str, int] = {}
    with path.open() as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                continue
    return out


def clean(text: str) -> str:
    """Strip the two characters the packed format reserves.

    Tabs separate fields; newlines separate rows. Neither occurs in the
    source data, but a clue arriving with one would silently corrupt every
    following field, so normalize rather than trust.
    """
    return re.sub(r"\s+", " ", text).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--crosswordler",
        type=Path,
        default=Path("../Crosswordler"),
        help="path to the Crosswordler project checkout",
    )
    ap.add_argument("--out", type=Path, default=Path("assets/crossword/wordlist.tsv"))
    ap.add_argument(
        "--max-clues",
        type=int,
        default=2,
        help="clue options to keep per entry (PORTING_SPEC.md §2.5 MAX_CLUES_PER_ENTRY)",
    )
    args = ap.parse_args()

    root = args.crosswordler
    asset_path = root / "data/processed/wordlist_asset.json"
    if not asset_path.exists():
        raise SystemExit(
            f"{asset_path} not found — run Crosswordler's own exporter first:\n"
            "  PYTHONPATH=src python3 tools/export_wordlist.py "
            "--out data/processed/wordlist_asset.json --min-zipf 2.5 --require-clue"
        )

    crosswordese = load_crosswordese(root / "src/crosswordler/wordlist.py")
    ratings = load_ratings(root / "data/raw/word_ratings.tsv")
    entries = json.loads(asset_path.read_text())

    args.out.parent.mkdir(parents=True, exist_ok=True)
    rows = 0
    clue_count = 0
    with args.out.open("w") as fh:
        fh.write(
            "# Crosswordler word list, packed by tool/pipeline/export_crossword_wordlist.py\n"
            "# text\tdisplay\tzipf\tsynsets\tflags\tscore\ttier\tfamiliarity\ttags\tclue...\n"
            "# flags: 1=proper 2=phrase 4=crosswordese; familiarity blank = unrated\n"
            "# clue fields are '<type-code>:<text>', best first; type codes: "
            + " ".join(f"{code}={name}" for name, code in CLUE_TYPE_CODES.items())
            + "\n"
        )
        for e in entries:
            text = e["text"]
            flags = 0
            if e.get("is_proper"):
                flags |= FLAG_PROPER
            if e.get("is_phrase"):
                flags |= FLAG_PHRASE
            if text in crosswordese:
                flags |= FLAG_CROSSWORDESE

            fields = [
                text,
                clean(e.get("display") or text),
                f"{e.get('freq_zipf', 0.0):g}",
                str(e.get("synset_count", 0)),
                str(flags),
                f"{e.get('score', 0.0):g}",
                str(e.get("editor_tier", 0)),
                str(ratings.get(text, "")),
                ",".join(e.get("tags") or ()),
            ]
            for clue in (e.get("clues") or [])[: args.max_clues]:
                code = CLUE_TYPE_CODES.get(clue.get("type", ""), "d")
                body = clean(clue.get("text", ""))
                if not body:
                    continue
                fields.append(f"{code}:{body}")
                clue_count += 1

            fh.write("\t".join(fields) + "\n")
            rows += 1

    size_mb = args.out.stat().st_size / 1e6
    rated = sum(1 for e in entries if e["text"] in ratings)
    print(
        f"wrote {rows:,} entries ({clue_count:,} clues) to {args.out} "
        f"({size_mb:.1f} MB); {rated:,} carry a familiarity rating, "
        f"{sum(1 for e in entries if e['text'] in crosswordese):,} flagged crosswordese"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
