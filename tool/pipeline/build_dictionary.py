#!/usr/bin/env python3
"""Lexery content pipeline.

Turns a raw Kaikki.org English Wiktionary JSONL extract into two SQLite
databases:

  - dictionary-core.db  a small curated/frequency-ranked subset (dev use)
  - dictionary-full.db  every kept entry — this is what the app actually
                         bundles today, copied to assets/db/dictionary.db

Source data: https://kaikki.org/dictionary/English/
License: Wiktionary content is CC BY-SA 3.0 / GFDL — see Settings -> About
in the app for the attribution string this pipeline expects the app to show.

Usage:
    python3 build_dictionary.py --input raw/kaikki-english.jsonl --out out/

Requires: wordfreq (pip install wordfreq). Uses only the stdlib otherwise —
a Kaikki dump is JSON Lines, so no streaming JSON parser is needed.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import time
from pathlib import Path

from spelling_variants import add_spelling_variants

try:
    from wordfreq import zipf_frequency
except ImportError:  # pragma: no cover
    sys.exit("Missing dependency: pip install wordfreq")

KEPT_POS = {"noun", "verb", "adj", "adv"}
CORE_SIZE = 15_000
MAX_EXAMPLES_PER_SENSE = 3
MAX_SENSES_PER_ENTRY = 8
FORM_TEXT_RE = re.compile(r"^[A-Za-z][A-Za-z' \-]{0,63}$")

# Corpus frequency alone under-serves this app's actual purpose: GRE/SAT-tier
# and literary vocabulary is by definition rare in general text, so a plain
# top-15k-by-frequency cut is dominated by everyday words ("fast", "cat")
# and drops the advanced words the app is meant to teach. This seed list
# guarantees classic advanced-vocabulary headwords land in the bundled core
# regardless of their raw frequency rank; the rest of the core is still
# filled out by frequency as before. See the "Open questions" section of the
# design doc — this is the pipeline's answer to the flagged ranking-source
# tradeoff.
ADVANCED_VOCAB_SEED = {
    "abate", "aberrant", "abeyance", "abscond", "abstemious", "abstruse",
    "acerbic", "acquiesce", "acrimony", "acumen", "admonish", "adroit",
    "adulation", "aesthetic", "affable", "aggrandize", "alacrity", "altruism",
    "ambivalent", "ameliorate", "anachronism", "analogous", "anomaly",
    "antipathy", "apathy", "apocryphal", "approbation", "arbitrary",
    "arcane", "ardent", "arduous", "articulate", "ascetic", "assiduous",
    "audacious", "austere", "avarice", "aver", "banal", "belie",
    "belligerent", "benevolent", "beguile", "bombastic", "boorish",
    "burgeon", "buttress", "cacophony", "cajole", "candor", "capitulate",
    "capricious", "castigate", "catalyst", "caustic", "chicanery",
    "circumlocution", "circumspect", "clairvoyant", "coalesce", "cogent",
    "cognizant", "commensurate", "complacent", "conciliatory", "condone",
    "conflagration", "congenial", "conjecture", "connoisseur", "contentious",
    "contrite", "conundrum", "convoluted", "copious", "corroborate",
    "credulous", "cryptic", "cursory", "cynical", "debacle", "debilitate",
    "decorous", "deference", "deleterious", "demagogue", "denigrate",
    "deride", "desiccate", "despot", "diaphanous", "diatribe", "dichotomy",
    "diffident", "digress", "dilatory", "diligent", "diminutive",
    "disconcert", "discordant", "discreet", "disingenuous", "disparage",
    "disparate", "dissemble", "dissonance", "divergent", "document",
    "dogmatic", "duplicity", "ebullient", "eclectic", "efface", "effervescent",
    "effrontery", "egregious", "elicit", "eloquent", "elucidate",
    "emulate", "enervate", "engender", "enigma", "enmity", "ephemeral",
    "equanimity", "equivocal", "erudite", "esoteric", "eulogy", "euphemism",
    "evanescent", "exacerbate", "exculpate", "exigent", "extol", "extraneous",
    "facetious", "fastidious", "fatuous", "feckless", "fervent", "fervor",
    "flagrant", "florid", "fortuitous", "fractious", "frugal", "furtive",
    "garrulous", "grandiloquent", "gratuitous", "gregarious", "guile",
    "hackneyed", "hedonist", "hegemony", "heterodox", "histrionic",
    "iconoclast", "idiosyncrasy", "ignominious", "impartial", "impassive",
    "impecunious", "imperious", "impervious", "implacable", "implicit",
    "inchoate", "incongruous", "indefatigable", "indolent", "ineffable",
    "inexorable", "ingenuous", "inimical", "innocuous", "insipid",
    "insolent", "insular", "intransigent", "intrepid", "inured",
    "invective", "inveterate", "irascible", "jocular", "jubilant",
    "juxtapose", "laconic", "languid", "largesse", "lassitude", "laud",
    "lethargic", "limpid", "loquacious", "lucid", "lugubrious", "magnanimous",
    "malaise", "malfeasance", "malinger", "maverick", "mendacious",
    "mercurial", "meticulous", "misanthrope", "mitigate", "mollify",
    "morose", "mundane", "myopic", "nebulous", "nefarious", "neophyte",
    "nonchalant", "nostalgia", "noxious", "obdurate", "obfuscate",
    "obsequious", "obstinate", "obviate", "occlude", "officious",
    "onerous", "opaque", "opprobrium", "orthodox", "ostentatious",
    "paradigm", "paradox", "parochial", "parsimonious", "paucity",
    "pedantic", "pellucid", "penchant", "penurious", "perfidious",
    "perfunctory", "perspicacious", "pervasive", "petulant", "philistine",
    "phlegmatic", "placate", "placid", "plaintive", "platitude", "plausible",
    "plethora", "polemic", "pragmatic", "precarious", "precocious",
    "predilection", "presumptuous", "pretentious", "prevaricate",
    "pristine", "probity", "problematic", "proclivity", "prodigal",
    "prodigious", "profligate", "profound", "prolific", "propensity",
    "propitious", "prosaic", "protean", "provincial", "prudent", "puerile",
    "pugnacious", "punctilious", "quixotic", "rancor", "recalcitrant",
    "recondite", "redolent", "refute", "relegate", "reprobate", "repudiate",
    "rescind", "reticent", "reverent", "sagacious", "salient", "sanguine",
    "sardonic", "satiate", "saturnine", "sedulous", "sinuous", "skeptic",
    "solicitous", "soporific", "spurious", "staid", "stoic", "stolid",
    "strident", "stultify", "surfeit", "surreptitious", "sycophant",
    "taciturn", "tangential", "tautology", "temerity", "tenacious",
    "tenuous", "terse", "torpid", "tortuous", "tractable", "transient",
    "trenchant", "trepidation", "trite", "truculent", "turgid", "ubiquitous",
    "umbrage", "unctuous", "unequivocal", "untenable", "urbane", "vacillate",
    "vacuous", "vehement", "venal", "veracity", "verbose", "vestige",
    "vex", "vicarious", "vindicate", "vindictive", "virulent", "visceral",
    "vitriolic", "vociferous", "volatile", "voracious", "wanton", "wary",
    "whimsical", "zealous",
}

SCHEMA = """
CREATE TABLE entries (
  id INTEGER PRIMARY KEY,
  headword TEXT NOT NULL,
  pos TEXT NOT NULL,
  frequency_rank INTEGER,
  etymology TEXT
);
CREATE INDEX idx_entries_headword ON entries(headword);
CREATE INDEX idx_entries_frequency_rank ON entries(frequency_rank);

CREATE TABLE senses (
  id INTEGER PRIMARY KEY,
  entry_id INTEGER NOT NULL REFERENCES entries(id),
  gloss TEXT NOT NULL,
  sense_order INTEGER NOT NULL
);
CREATE INDEX idx_senses_entry_id ON senses(entry_id);

CREATE TABLE examples (
  id INTEGER PRIMARY KEY,
  sense_id INTEGER NOT NULL REFERENCES senses(id),
  text TEXT NOT NULL,
  source TEXT
);
CREATE INDEX idx_examples_sense_id ON examples(sense_id);

CREATE TABLE pronunciations (
  entry_id INTEGER PRIMARY KEY REFERENCES entries(id),
  ipa TEXT,
  audio_hint TEXT
);

CREATE TABLE forms (
  id INTEGER PRIMARY KEY,
  entry_id INTEGER NOT NULL REFERENCES entries(id),
  form_text TEXT NOT NULL,
  form_type TEXT NOT NULL
);
CREATE INDEX idx_forms_entry_id ON forms(entry_id);
CREATE INDEX idx_forms_form_text ON forms(form_text);

CREATE VIRTUAL TABLE entries_fts USING fts5(
  headword, content='entries', content_rowid='id'
);
"""

# Full-text index over example sentences, so the study session's "which
# sentence wants this word?" game can pick distractors that are *about the
# same things* as the real sentence instead of three unrelated ones (which a
# learner can tell apart on topic alone, without knowing the word). Porter
# stemming so "sailed" finds "sailing"; an external-content table, so the
# text itself is stored once. Kept out of SCHEMA because it is also applied
# on its own to an already-built database — see add_examples_fts().
EXAMPLES_FTS_SQL = """
CREATE VIRTUAL TABLE IF NOT EXISTS examples_fts USING fts5(
  text, content='examples', content_rowid='id', tokenize='porter unicode61'
);
INSERT INTO examples_fts(examples_fts) VALUES('delete-all');
INSERT INTO examples_fts(rowid, text) SELECT id, text FROM examples;
"""


def add_examples_fts(conn: sqlite3.Connection) -> None:
    """Builds (or rebuilds) examples_fts over whatever is in `examples`."""
    conn.executescript(EXAMPLES_FTS_SQL)
    conn.commit()


def log(msg: str) -> None:
    print(f"[pipeline] {msg}", file=sys.stderr, flush=True)


def last_gloss(sense: dict) -> str | None:
    glosses = sense.get("glosses")
    if not glosses:
        return None
    text = glosses[-1].strip()
    return text or None


def clean_form(form: dict) -> tuple[str, str] | None:
    text = (form.get("form") or "").strip()
    tags = form.get("tags") or []
    if not text or not FORM_TEXT_RE.match(text):
        return None
    if "table-tags" in tags or "inflection-template" in tags:
        return None
    return text, ",".join(tags) if tags else "form"


# The crossword list the daily-word pool is filtered through; the app's
# bundled copy, since that is what it is checked against.
CROSSWORD_WORDLIST = Path(__file__).resolve().parents[2] / "assets" / "crossword" / "wordlist.tsv"


def _add_daily_words(conn: sqlite3.Connection) -> int:
    # Imported here rather than at the top: daily_words takes the advanced
    # vocabulary seed from this module, and the other way round would loop.
    from daily_words import add_daily_words

    return add_daily_words(conn, CROSSWORD_WORDLIST)


def build_full_db(input_path: Path, db_path: Path) -> None:
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("PRAGMA synchronous=OFF")

    entry_id = 0
    sense_id = 0
    example_id = 0
    form_id = 0
    kept = 0
    skipped = 0
    t0 = time.time()

    with input_path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            if obj.get("lang_code") != "en":
                skipped += 1
                continue
            pos = obj.get("pos")
            if pos not in KEPT_POS:
                skipped += 1
                continue
            headword = (obj.get("word") or "").strip()
            if not headword:
                skipped += 1
                continue

            raw_senses = obj.get("senses") or []
            # Skip inflection-stub entries (e.g. "ran" pointing back at "run") —
            # the lemma's own `forms` list already covers this surface form.
            if any(s.get("form_of") for s in raw_senses):
                skipped += 1
                continue

            sense_rows = []
            for order, s in enumerate(raw_senses[:MAX_SENSES_PER_ENTRY]):
                if s.get("tags") and "obsolete" in s["tags"]:
                    continue
                gloss = last_gloss(s)
                if not gloss:
                    continue
                examples = []
                for ex in (s.get("examples") or [])[:MAX_EXAMPLES_PER_SENSE]:
                    text = (ex.get("text") or "").strip()
                    if text:
                        examples.append((text, ex.get("ref")))
                sense_rows.append((gloss, order, examples))

            if not sense_rows:
                skipped += 1
                continue

            etymology = (obj.get("etymology_text") or "").strip() or None
            if etymology and len(etymology) > 1200:
                etymology = etymology[:1200].rsplit(" ", 1)[0] + "…"

            entry_id += 1
            eid = entry_id
            conn.execute(
                "INSERT INTO entries (id, headword, pos, frequency_rank, etymology) VALUES (?, ?, ?, NULL, ?)",
                (eid, headword, pos, etymology),
            )

            for gloss, order, examples in sense_rows:
                sense_id += 1
                sid = sense_id
                conn.execute(
                    "INSERT INTO senses (id, entry_id, gloss, sense_order) VALUES (?, ?, ?, ?)",
                    (sid, eid, gloss, order),
                )
                for text, source in examples:
                    example_id += 1
                    conn.execute(
                        "INSERT INTO examples (id, sense_id, text, source) VALUES (?, ?, ?, ?)",
                        (example_id, sid, text, source),
                    )

            ipa = None
            for sound in obj.get("sounds") or []:
                if sound.get("ipa"):
                    ipa = sound["ipa"]
                    break
            if ipa:
                conn.execute(
                    "INSERT INTO pronunciations (entry_id, ipa, audio_hint) VALUES (?, ?, NULL)",
                    (eid, ipa),
                )

            seen_forms = set()
            for form in obj.get("forms") or []:
                cleaned = clean_form(form)
                if not cleaned:
                    continue
                text, form_type = cleaned
                if text.lower() == headword.lower():
                    continue
                key = (text.lower(), form_type)
                if key in seen_forms:
                    continue
                seen_forms.add(key)
                form_id += 1
                conn.execute(
                    "INSERT INTO forms (id, entry_id, form_text, form_type) VALUES (?, ?, ?, ?)",
                    (form_id, eid, text, form_type),
                )

            kept += 1
            if kept % 20_000 == 0:
                conn.commit()
                log(f"{kept:,} entries kept, {skipped:,} skipped, "
                    f"{line_no:,} lines read ({time.time() - t0:.0f}s)")

    conn.commit()
    log(f"parse done: {kept:,} entries kept, {skipped:,} skipped")

    log("ranking by frequency (wordfreq zipf, en)...")
    cache: dict[str, float] = {}
    rows = conn.execute("SELECT id, headword FROM entries").fetchall()
    ranked = []
    for eid, headword in rows:
        key = headword.lower()
        z = cache.get(key)
        if z is None:
            z = zipf_frequency(key, "en")
            cache[key] = z
        ranked.append((z, eid))
    ranked.sort(key=lambda r: (-r[0], r[1]))
    conn.executemany(
        "UPDATE entries SET frequency_rank = ? WHERE id = ?",
        [(rank + 1, eid) for rank, (_, eid) in enumerate(ranked)],
    )
    conn.commit()

    log("building FTS5 index...")
    conn.execute("INSERT INTO entries_fts(rowid, headword) SELECT id, headword FROM entries")
    conn.commit()
    log("building examples FTS5 index...")
    add_examples_fts(conn)
    log("consolidating spelling variants...")
    log(f"  {add_spelling_variants(conn)} variant spellings folded into their words")
    log("choosing the word-of-the-day pool...")
    log(f"  {_add_daily_words(conn)} words")

    conn.execute("PRAGMA user_version = 1")
    conn.execute("VACUUM")
    conn.commit()
    conn.close()
    log(f"wrote {db_path} ({db_path.stat().st_size / 1e6:.1f} MB)")


def build_core_db(full_db_path: Path, core_db_path: Path, core_size: int) -> None:
    if core_db_path.exists():
        core_db_path.unlink()
    conn = sqlite3.connect(core_db_path)
    conn.executescript(SCHEMA)
    conn.execute(f"ATTACH DATABASE '{full_db_path.as_posix()}' AS full_db")

    seed_placeholders = ",".join("?" for _ in ADVANCED_VOCAB_SEED)
    conn.execute(f"""
        INSERT INTO entries (id, headword, pos, frequency_rank, etymology)
        SELECT id, headword, pos, frequency_rank, etymology FROM full_db.entries
        WHERE lower(headword) IN ({seed_placeholders})
    """, sorted(ADVANCED_VOCAB_SEED))
    seeded = conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
    log(f"seeded {seeded} advanced-vocabulary entries "
        f"({len(ADVANCED_VOCAB_SEED)} headwords, some with multiple senses/POS)")

    remaining = max(core_size - seeded, 0)
    conn.execute(f"""
        INSERT INTO entries (id, headword, pos, frequency_rank, etymology)
        SELECT id, headword, pos, frequency_rank, etymology FROM full_db.entries
        WHERE frequency_rank IS NOT NULL
          AND id NOT IN (SELECT id FROM entries)
        ORDER BY frequency_rank ASC LIMIT {remaining}
    """)
    conn.execute("""
        INSERT INTO senses (id, entry_id, gloss, sense_order)
        SELECT s.id, s.entry_id, s.gloss, s.sense_order
        FROM full_db.senses s JOIN entries e ON e.id = s.entry_id
    """)
    conn.execute("""
        INSERT INTO examples (id, sense_id, text, source)
        SELECT x.id, x.sense_id, x.text, x.source
        FROM full_db.examples x JOIN senses s ON s.id = x.sense_id
    """)
    conn.execute("""
        INSERT INTO pronunciations (entry_id, ipa, audio_hint)
        SELECT p.entry_id, p.ipa, p.audio_hint
        FROM full_db.pronunciations p JOIN entries e ON e.id = p.entry_id
    """)
    conn.execute("""
        INSERT INTO forms (id, entry_id, form_text, form_type)
        SELECT f.id, f.entry_id, f.form_text, f.form_type
        FROM full_db.forms f JOIN entries e ON e.id = f.entry_id
    """)
    conn.execute("INSERT INTO entries_fts(rowid, headword) SELECT id, headword FROM entries")
    conn.commit()
    add_examples_fts(conn)
    add_spelling_variants(conn)
    _add_daily_words(conn)
    conn.execute("DETACH DATABASE full_db")
    conn.execute("PRAGMA user_version = 1")
    conn.execute("VACUUM")
    conn.commit()
    conn.close()
    log(f"wrote {core_db_path} ({core_db_path.stat().st_size / 1e6:.1f} MB)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", type=Path, help="Path to the Kaikki English JSONL dump")
    ap.add_argument("--out", type=Path, default=Path("out"), help="Output directory")
    ap.add_argument("--core-size", type=int, default=CORE_SIZE)
    ap.add_argument(
        "--core-only", action="store_true",
        help="Skip the (slow) full-dump parse and just rebuild dictionary-core.db "
             "from an existing dictionary-full.db in --out — use this after editing "
             "ADVANCED_VOCAB_SEED or --core-size.",
    )
    ap.add_argument(
        "--add-examples-fts", type=Path, metavar="DB",
        help="Skip every other step and just add (or rebuild) the examples_fts "
             "index inside an existing database, in place — for upgrading a "
             "dictionary.db built before the index existed without a full re-parse.",
    )
    args = ap.parse_args()

    if args.add_examples_fts:
        if not args.add_examples_fts.exists():
            sys.exit(f"no such database: {args.add_examples_fts}")
        log(f"adding examples_fts to {args.add_examples_fts}...")
        conn = sqlite3.connect(args.add_examples_fts)
        add_examples_fts(conn)
        conn.close()
        log("done.")
        return

    args.out.mkdir(parents=True, exist_ok=True)
    full_db = args.out / "dictionary-full.db"
    core_db = args.out / "dictionary-core.db"

    if args.core_only:
        if not full_db.exists():
            sys.exit(f"--core-only requires an existing {full_db}")
    else:
        if not args.input:
            sys.exit("--input is required unless --core-only is set")
        build_full_db(args.input, full_db)

    build_core_db(full_db, core_db, args.core_size)
    log("done.")


if __name__ == "__main__":
    main()
