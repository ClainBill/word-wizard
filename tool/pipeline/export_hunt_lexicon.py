#!/usr/bin/env python3
"""Builds the Word Hunt's lexicon assets — `assets/hunt/`.

The hunt is a 4x4 letter board (StrandinatorResearch/, milestones 0.3-0.4),
and the research established that its dictionary must be split three ways:

- **accepted** — every spelling the board will recognise. ENABLE1, 4-16
  letters, minus the Nediger tier-49 content list. Broad on purpose: a
  player who traces a real word and is told "not a word" is the single worst
  experience the game can give, and the research measured a median of 54
  ordinary words per board that the narrower familiar list alone rejected.
- **main** — the words a player is *asked* to find: `accepted` ∩ the
  crossword word list's familiar entries (familiarity ≥ 4, zipf ≥ 2.5, not
  proper/phrase/abbreviation, not the constructor's last-resort tier).
  Completion is measured against this set only, so bonus breadth never
  makes a board harder to finish.
- **themes** — the day's theme vocabulary: for each curated Wiktionary topic
  (music, nautical, law, …) the `main` words Kaikki tags with it. One theme
  word is placed as an anchor and any other theme words the board happens
  to contain light up as theme finds.

Everything here is derived offline; the runtime reads three plain text
files. Stdlib only.

Usage:
    python3 tool/pipeline/export_hunt_lexicon.py \
        --research StrandinatorResearch/input/data/raw \
        --wordlist assets/crossword/wordlist.tsv \
        --kaikki tool/pipeline/raw/kaikki-english.jsonl \
        --out assets/hunt

`--kaikki` is optional; without it `themes.tsv` is left untouched (the
stream is 3 GB and takes a few minutes).
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

MIN_LEN, MAX_LEN = 4, 16

# Wiktionary topic -> display label. Only these are exported; the raw
# hierarchy has hundreds of topics, most too thin or too abstract
# ("sciences", "lifestyle") to make a recognisable theme.
TOPICS = {
    "music": "Music",
    "nautical": "At sea",
    "botany": "Plants",
    "zoology": "Animals",
    "anatomy": "The body",
    "medicine": "Medicine",
    "law": "Law",
    "military": "Military",
    "architecture": "Architecture",
    "astronomy": "The night sky",
    "chemistry": "Chemistry",
    "physics": "Physics",
    "mathematics": "Mathematics",
    "geometry": "Shapes",
    "geology": "Rocks & earth",
    "geography": "Geography",
    "religion": "Religion",
    "finance": "Money",
    "computing": "Computing",
    "sports": "Sport",
    "ball-games": "Ball games",
    "card-games": "Card games",
    "chess": "Chess",
    "baseball": "Baseball",
    "cricket": "Cricket",
    "theater": "Theatre",
    "film": "Film",
    "literature": "Literature",
    "linguistics": "Language",
    "grammar": "Grammar",
    "agriculture": "Farming",
    "textiles": "Fabric & sewing",
    "mining": "Mining",
    "railways": "Railways",
    "aviation": "Flight",
    "philosophy": "Philosophy",
    "heraldry": "Heraldry",
    "printing": "Printing",
    "education": "School",
    "cooking": "Cooking",
    "food": "Food",
    "fishing": "Fishing",
    "hunting": "Hunting",
    "weather": "Weather",
    "meteorology": "Weather",
    "dance": "Dance",
    "photography": "Photography",
    "painting": "Painting",
    "sculpture": "Sculpture",
    "poetry": "Poetry",
    "mythology": "Myth & legend",
    "fantasy": "Fantasy",
    "horse-racing": "Horses",
    "equestrianism": "Horses",
    "golf": "Golf",
    "tennis": "Tennis",
    "cycling": "Cycling",
    "boxing": "Boxing",
    "swimming": "Swimming",
    "climbing": "Climbing",
    "gambling": "Gambling",
    "carpentry": "Woodwork",
    "woodworking": "Woodwork",
    "pottery": "Pottery",
    "jewelry": "Jewellery",
    "clothing": "Clothing",
    "fashion": "Fashion",
    "furniture": "Furniture",
    "gardening": "The garden",
    "beekeeping": "Bees",
    "ornithology": "Birds",
    "entomology": "Insects",
    "ichthyology": "Fish",
    "mycology": "Fungi",
    "brewing": "Brewing",
    "wine": "Wine",
    "cheese": "Cheese",
    "baking": "Baking",
    "pharmacology": "Drugs & remedies",
    "psychology": "The mind",
    "psychiatry": "The mind",
    "dentistry": "Teeth",
    "optics": "Light & lenses",
    "acoustics": "Sound",
    "electricity": "Electricity",
    "engineering": "Engineering",
    "automotive": "Cars",
    "transport": "Transport",
    "shipping": "Shipping",
    "roads": "Roads",
    "cartography": "Maps",
    "navigation": "Navigation",
    "space": "Space",
    "oceanography": "The ocean",
    "ecology": "Ecology",
    "genetics": "Genetics",
    "microbiology": "Microbes",
    "cryptography": "Codes & ciphers",
    "journalism": "Journalism",
    "broadcasting": "Broadcasting",
    "advertising": "Advertising",
    "banking": "Banking",
    "economics": "Economics",
    "accounting": "Accounting",
    "insurance": "Insurance",
    "real-estate": "Property",
    "sewing": "Fabric & sewing",
    "knitting": "Knitting",
    "typography": "Type & print",
    "calligraphy": "Handwriting",
    "archaeology": "Archaeology",
    "history": "History",
    "monarchy": "Kings & queens",
    "nobility": "Nobility",
    "crime": "Crime",
    "police": "Police",
    "prison": "Prison",
    "firefighting": "Fire",
    "medicine": "Medicine",
    "surgery": "Surgery",
    "nursing": "Nursing",
    "veterinary": "Animal care",
    "martial-arts": "Martial arts",
    "wrestling": "Wrestling",
    "archery": "Archery",
    "fencing": "Fencing",
    "sailing": "Sailing",
    "rowing": "Rowing",
    "skiing": "Skiing",
    "skating": "Skating",
    "surfing": "Surfing",
    "camping": "Camping",
    "hiking": "Hiking",
    "circus": "The circus",
    "magic": "Magic",
    "games": "Games",
    "board-games": "Board games",
    "video-games": "Video games",
    "toys": "Toys",
    "furniture": "Furniture",
    "tools": "Tools",
    "masonry": "Stonework",
    "plumbing": "Plumbing",
    "roofing": "Roofing",
    "metalworking": "Metalwork",
    "blacksmithing": "The forge",
    "glassblowing": "Glass",
    "leatherworking": "Leather",
    "perfumery": "Scent",
    "cosmetics": "Cosmetics",
    "hairdressing": "Hair",
    "tobacco": "Tobacco",
    "alcoholic-beverages": "Drinks",
    "beverages": "Drinks",
    "confectionery": "Sweets",
    "desserts": "Desserts",
    "fruits": "Fruit",
    "vegetables": "Vegetables",
    "spices": "Spices & herbs",
    "herbs": "Spices & herbs",
    "seafood": "Seafood",
    "meats": "Meat",
    "dairy": "Dairy",
    "bread": "Bread",
    "pasta": "Pasta",
    "family": "Family",
    "emotions": "Feelings",
    "colors": "Colours",
    "colours": "Colours",
    "numbers": "Numbers",
    "time": "Time",
    "calendar": "The calendar",
    "seasons": "Seasons",
    "holidays": "Holidays",
    "christmas": "Christmas",
    "halloween": "Halloween",
    "wedding": "Weddings",
    "funeral": "Funerals",
    "death": "Death",
    "birth": "Birth",
    "childcare": "Children",
    "pets": "Pets",
    "dogs": "Dogs",
    "cats": "Cats",
    "horses": "Horses",
    "cattle": "Cattle",
    "sheep": "Sheep",
    "poultry": "Poultry",
    "trees": "Trees",
    "flowers": "Flowers",
    "mammals": "Mammals",
    "reptiles": "Reptiles",
    "amphibians": "Amphibians",
    "birds": "Birds",
    "fish": "Fish",
    "insects": "Insects",
    "arachnids": "Spiders",
    "molluscs": "Shellfish",
    "crustaceans": "Crustaceans",
    "dinosaurs": "Dinosaurs",
    "paleontology": "Fossils",
    "anthropology": "Peoples",
    "sociology": "Society",
    "theology": "Theology",
    "Christianity": "Christianity",
    "Judaism": "Judaism",
    "Islam": "Islam",
    "Buddhism": "Buddhism",
    "Hinduism": "Hinduism",
    "occult": "The occult",
    "astrology": "Astrology",
    "mysticism": "Mysticism",
    "alchemy": "Alchemy",
    "folklore": "Folklore",
    "fairy-tales": "Fairy tales",
    "science-fiction": "Science fiction",
    "comics": "Comics",
    "animation": "Animation",
    "television": "Television",
    "radio": "Radio",
    "telephony": "Telephones",
    "internet": "The internet",
    "programming": "Programming",
    "software": "Software",
    "hardware": "Hardware",
    "robotics": "Robots",
    "artificial-intelligence": "AI",
    "electronics": "Electronics",
    "telecommunications": "Telecoms",
    "energy": "Energy",
    "nuclear-physics": "The atom",
    "thermodynamics": "Heat",
    "mechanics": "Mechanics",
    "hydrology": "Water",
    "volcanology": "Volcanoes",
    "seismology": "Earthquakes",
    "mineralogy": "Minerals",
    "gemology": "Gems",
    "metallurgy": "Metals",
    "petroleum": "Oil",
    "forestry": "Forests",
    "horticulture": "The garden",
    "viticulture": "Wine",
    "apiculture": "Bees",
    "aquaculture": "Fish farming",
    "animal-husbandry": "Livestock",
    "dairy-farming": "Dairy",
    "logging": "Timber",
    "construction": "Building",
    "surveying": "Surveying",
    "urban-planning": "Cities",
    "traffic": "Traffic",
    "cycling": "Cycling",
    "motor-racing": "Motor racing",
    "motorcycling": "Motorbikes",
    "boating": "Boats",
    "canoeing": "Canoeing",
    "diving": "Diving",
    "scuba-diving": "Diving",
    "athletics": "Athletics",
    "gymnastics": "Gymnastics",
    "weightlifting": "Weights",
    "bodybuilding": "Fitness",
    "fitness": "Fitness",
    "yoga": "Yoga",
    "rugby": "Rugby",
    "soccer": "Football",
    "football": "Football",
    "American-football": "American football",
    "basketball": "Basketball",
    "volleyball": "Volleyball",
    "hockey": "Hockey",
    "ice-hockey": "Ice hockey",
    "lacrosse": "Lacrosse",
    "polo": "Polo",
    "billiards": "Billiards",
    "snooker": "Snooker",
    "bowling": "Bowling",
    "darts": "Darts",
    "poker": "Poker",
    "bridge": "Bridge",
    "dominoes": "Dominoes",
    "dice": "Dice",
    "puzzles": "Puzzles",
    "crosswords": "Crosswords",
    "backgammon": "Backgammon",
    "go": "Go",
    "mahjong": "Mahjong",
    "juggling": "Juggling",
    "origami": "Origami",
    "quilting": "Quilting",
    "embroidery": "Embroidery",
    "weaving": "Weaving",
    "spinning": "Spinning",
    "dyeing": "Dyeing",
    "tailoring": "Tailoring",
    "shoemaking": "Shoes",
    "footwear": "Shoes",
    "headwear": "Hats",
    "opera": "Opera",
    "ballet": "Ballet",
    "jazz": "Jazz",
    "rock-music": "Rock",
    "hip-hop": "Hip-hop",
    "musical-instruments": "Instruments",
    "singing": "Singing",
    "percussion": "Drums",
    "guitar": "Guitar",
    "piano": "Piano",
    "violin": "Strings",
    "organ": "Organ",
    "bells": "Bells",
    "drama": "Drama",
    "comedy": "Comedy",
    "rhetoric": "Rhetoric",
    "logic": "Logic",
    "ethics": "Ethics",
    "aesthetics": "Beauty",
    "metaphysics": "Metaphysics",
    "epistemology": "Knowledge",
    "statistics": "Statistics",
    "probability": "Chance",
    "algebra": "Algebra",
    "calculus": "Calculus",
    "arithmetic": "Arithmetic",
    "trigonometry": "Trigonometry",
    "topology": "Topology",
    "set-theory": "Sets",
    "number-theory": "Numbers",
    "phonetics": "Speech sounds",
    "phonology": "Speech sounds",
    "semantics": "Meaning",
    "etymology": "Word origins",
    "lexicography": "Dictionaries",
    "orthography": "Spelling",
    "translation-studies": "Translation",
    "sign-language": "Sign language",
    "writing": "Writing",
    "publishing": "Publishing",
    "bookbinding": "Books",
    "libraries": "Libraries",
    "museums": "Museums",
    "art": "Art",
    "arts": "The arts",
    "design": "Design",
    "graphic-design": "Design",
    "interior-design": "Interiors",
    "landscaping": "Landscape",
    "ceramics": "Ceramics",
    "glass": "Glass",
    "dentistry": "Teeth",
    "ophthalmology": "Eyes",
    "cardiology": "The heart",
    "neurology": "The brain",
    "oncology": "Oncology",
    "pathology": "Disease",
    "immunology": "Immunity",
    "virology": "Viruses",
    "epidemiology": "Epidemics",
    "obstetrics": "Childbirth",
    "pediatrics": "Children's health",
    "geriatrics": "Old age",
    "toxicology": "Poisons",
    "nutrition": "Nutrition",
    "dietetics": "Diet",
    "hygiene": "Hygiene",
    "first-aid": "First aid",
    "emergency-medicine": "Emergencies",
    "sleep": "Sleep",
    "dreams": "Dreams",
}

FLAG_PROPER, FLAG_PHRASE = 1, 2

# Parents in Kaikki's topic hierarchy: kept only when a sense has no
# narrower mapped topic.
BROAD_TOPICS = {"mathematics", "engineering", "business", "sports", "games", "government", "politics", "transport", "philosophy", "publishing", "arts", "sciences", "lifestyle", "hobbies", "human-sciences", "natural-sciences", "physical-sciences", "entertainment", "media"}

# Sense tags that disqualify a primary sense from carrying a theme.
UNTHEMED_TAGS = {"obsolete", "archaic", "rare", "dated", "slang", "vulgar", "offensive", "derogatory", "historical", "nonstandard", "informal"}


def load_enable(path: Path) -> set[str]:
    words = set()
    for line in path.read_text().splitlines():
        w = line.strip().upper()
        if w.isascii() and w.isalpha() and MIN_LEN <= len(w) <= MAX_LEN:
            words.add(w)
    return words


def load_blocked(research: Path) -> set[str]:
    """Tier 49 — Nediger's "too racy for many mainstream venues" list. Read
    from both the ratings TSV and the original list, because the ratings do
    not cover that tier completely (research README, v0.3)."""
    blocked = set()
    for line in (research / "word_ratings.tsv").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) >= 5 and fields[4] == "49":
            blocked.add(fields[0])
    for line in (research / "nediger-list.txt").read_text().splitlines():
        if ";" not in line:
            continue
        display, tier = line.rsplit(";", 1)
        if tier.strip() == "49":
            blocked.add("".join(c for c in display.upper() if "A" <= c <= "Z"))
    return blocked


def load_main(wordlist: Path, accepted: set[str]) -> set[str]:
    """The familiar lexicon — research `lexicon()` policy, read from the
    app's own crossword asset so the two games agree on what "familiar"
    means. Unrated entries are treated as unfamiliar here, the opposite of
    the crossword's fill pool: a hunt asks the player to find *every* main
    word, so an unknown word costs completion rather than one clue."""
    main = set()
    for line in wordlist.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 9:
            continue
        text, display, zipf, _syn, flags, _score, tier, familiarity = f[:8]
        if text not in accepted:
            continue
        if not familiarity or int(familiarity) < 4:
            continue
        if float(zipf) < 2.5:
            continue
        if int(flags) & (FLAG_PROPER | FLAG_PHRASE):
            continue
        if not (display.isascii() and display.isalpha() and display.islower()):
            continue
        if int(tier) in (25, 49):
            continue
        main.add(text)
    return main


def stream_topics(kaikki: Path, main: set[str]) -> dict[str, set[str]]:
    """topic -> main words Kaikki tags with it (any sense). Streams the
    3 GB dump line by line; only the `word` and `senses[].topics` fields
    are looked at."""
    by_topic: dict[str, set[str]] = defaultdict(set)
    wanted = set(TOPICS)
    with kaikki.open("rb") as fh:
        for n, raw in enumerate(fh):
            if n % 500000 == 0:
                print(f"  kaikki line {n:,}", file=sys.stderr)
            # Cheap pre-filter before paying for a JSON parse.
            if b'"topics"' not in raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            word = entry.get("word", "")
            # Lowercase only: "Wolves" and "Canary" are football clubs in
            # the dump, and folding case would file them under Football.
            if not (word.isascii() and word.isalpha() and word.islower()):
                continue
            if entry.get("pos") in ("name", "prefix", "suffix", "abbrev"):
                continue
            upper = word.upper()
            if upper not in main:
                continue
            senses = entry.get("senses", ())
            if not senses:
                continue
            # Primary sense only: a word whose *first* meaning is nautical
            # is a sea word; one with a nautical fifteenth sense (DEVIL,
            # SADDLE) is not, and a theme built on such senses reads as
            # random. Marked senses are out for the same reason.
            sense = senses[0]
            if any(tag in UNTHEMED_TAGS for tag in sense.get("tags", ())):
                continue
            topics = {t for t in sense.get("topics", ()) if t in wanted}
            # Kaikki writes a sense's whole topic ancestry ("computing" comes
            # with "mathematics" and "engineering"), so a broad parent only
            # counts when nothing more specific was said.
            if topics - BROAD_TOPICS:
                topics -= BROAD_TOPICS
            for topic in topics:
                by_topic[topic].add(upper)
    return by_topic


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--research", type=Path, default=Path("StrandinatorResearch/input/data/raw"))
    ap.add_argument("--wordlist", type=Path, default=Path("assets/crossword/wordlist.tsv"))
    ap.add_argument("--kaikki", type=Path, default=None)
    ap.add_argument("--out", type=Path, default=Path("assets/hunt"))
    ap.add_argument("--min-theme-words", type=int, default=30)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    enable = load_enable(args.research / "enable1.txt")
    blocked = load_blocked(args.research)
    accepted = enable - blocked
    main_words = load_main(args.wordlist, accepted)

    (args.out / "accepted.txt").write_text("\n".join(sorted(accepted)) + "\n")
    (args.out / "main.txt").write_text("\n".join(sorted(main_words)) + "\n")
    print(f"accepted {len(accepted):,} (ENABLE {len(enable):,} − blocked {len(enable & blocked):,})")
    print(f"main {len(main_words):,}")

    if args.kaikki is None:
        print("no --kaikki; themes.tsv left as is")
        return

    by_topic = stream_topics(args.kaikki, main_words)
    # Merge topics that share a label (weather/meteorology, …).
    by_label: dict[str, set[str]] = defaultdict(set)
    for topic, words in by_topic.items():
        by_label[TOPICS[topic]] |= words
    rows = []
    for label, words in sorted(by_label.items()):
        # A theme needs enough anchor-sized words to vary day to day.
        anchors = [w for w in words if 5 <= len(w) <= 9]
        if len(words) < args.min_theme_words or len(anchors) < 15:
            continue
        rows.append(f"{label}\t{','.join(sorted(words))}")
    header = (
        "# Word Hunt daily themes: label<TAB>comma-separated main words Wiktionary\n"
        "# tags with that topic. Built by tool/pipeline/export_hunt_lexicon.py.\n"
    )
    (args.out / "themes.tsv").write_text(header + "\n".join(rows) + "\n")
    print(f"themes {len(rows)}: " + ", ".join(r.split('\t')[0] for r in rows))


if __name__ == "__main__":
    main()
