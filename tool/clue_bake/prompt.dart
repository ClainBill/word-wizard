// What the clue bake asks the model, and how it reads the answer.

import 'dart:convert';

const bakeSystemPrompt = '''
You write clues for the daily crossword in a vocabulary app. Its solvers are fluent adult English readers who enjoy words; they are not crossword veterans. Write in the register of a New York Times Monday–Wednesday or Guardian Quick crossword: short, accurate, natural, a little lively.

For EACH answer you are given, write 3 clues and give a verdict.

CLUES
- 1 to 6 words each; one or two words is often best. Start with a capital letter. No final period.
- Good: "Fuss" (ADO). "Much ___ about nothing" (ADO). "Years lived" (AGE). "Ancient Greek marketplace" (AGORA). "Wealthy" (AFFLUENT). Bad: "how old are you? how many ___ do you have?" — clumsy, not a crossword clue.
- Clue the meaning most people know first. The senses given are dictionary glosses, roughly most common first; use your judgement, not the order, and ignore rare, archaic, regional and technical senses.
- Match the answer's grammar exactly. Test it: the clue and the answer must be interchangeable in a sentence. A plural answer takes a plural clue (EON is not "Ages"), a noun a noun clue (REPO is not "Seized for missed payments"), a past tense a past tense. An answer written as several words ("as written") is a phrase; clue the whole phrase.
- Vary the three: one synonym-style clue (a word or two), one short definition, and one fill-in-the-blank or a short descriptive clue.
- A fill-in-the-blank uses exactly ___ (three underscores) in a fixed phrase, idiom, title or saying people really use, word for word ("The whole enchilada", never "The entire ___ enchilada"; "Much ___ about nothing"). No invented sentences ("He ___ it daily"), no trivia sentences. If there is no well-known phrase, write a descriptive clue instead.
- Prefer a clue with a little life — an everyday context, a common collocation, a vivid picture — over a flat dictionary gloss. Never babyish ("One more than three" for FOUR; try "Number of seasons" or "Quartet's count"). Never pad ("Receives action of see").
- Only say what is always true. ESSAYS are not always short; a G-SUIT is not for aerobatic fliers.
- Every clue must be unambiguously TRUE of the answer. Accuracy matters more than wit. If you are unsure of a fact, write a plainer clue.
- Never use the answer, a word sharing its root, or an inflection of it. For a phrase, never use any of its words.
- Never say it is an abbreviation ("for short", "abbr.", "initials", "acronym") and never mention its length or letters.
- No sexual or crude content, slurs, or gore. Clue a word with a crude sense by an innocent one.
- For a name, clue its most famous bearer or meaning with a fact any adult knows.

VERDICT — "keep" or "reject". Reject an answer that doesn't belong in a puzzle for these solvers:
- an abbreviation or initialism (AAA, AKA, AFL, CSS, HRS, MPS, SSN, TBS, YRS), unless people say it as a word and everyone knows it (NASA, SCUBA, LASER, RADAR);
- a partial phrase that isn't a unit on its own (A LA, I DO, AS TO, LET EM, HAD AT, SIDE A, AM BAND);
- a word most fluent readers wouldn't know: obscure, archaic, dialect, or specialist jargon (ALANINE, AGAR, ERG);
- a foreign word not naturalised in English;
- a bare prefix or suffix;
- a niche proper noun: a minor place, a half-remembered person, a brand (ACURA), a sports league;
- a religious name or term best left out of a word game (ALLAH);
- crude or offensive words;
- an inflection nobody writes.
Keep ordinary words, well-known names and places, and common phrases. Always write the clues, even for an answer you reject; give a short reason only when you reject.

Return strict JSON only, one item per answer, using the ids given:
{"answers": [{"id": 0, "verdict": "keep", "reason": "", "clues": [{"text": "...", "style": "synonym"}, {"text": "...", "style": "definition"}, {"text": "...", "style": "blank"}]}]}''';

/// One word as the model sees it.
class BakeItem {
  final int id;
  final String answer;
  final String display;
  final List<String> senses;
  final List<String> existing;

  const BakeItem(this.id, this.answer, this.display, this.senses, this.existing);

  Map<String, dynamic> toJson() => {
    'id': id,
    'answer': answer,
    if (display.toUpperCase().replaceAll(RegExp('[^A-Z]'), '') != display.toUpperCase() ||
        display.contains(' '))
      'as_written': display,
    'senses': senses,
    if (existing.isNotEmpty) 'old_clues_may_be_poor': existing,
  };
}

String bakeUserMessage(List<BakeItem> items) =>
    const JsonEncoder.withIndent(' ').convert({'answers': [for (final i in items) i.toJson()]});

/// The model's answer for one word, before the gate.
class BakeResult {
  final String answer;
  final String verdict;
  final String reason;
  final List<({String text, String style})> clues;

  const BakeResult(this.answer, this.verdict, this.reason, this.clues);
}

/// Reads a reply to [items]; words the reply leaves out are simply absent.
List<BakeResult> parseBakeReply(String content, List<BakeItem> items) {
  final byId = {for (final i in items) i.id: i};
  final json = jsonDecode(content) as Map<String, dynamic>;
  final out = <BakeResult>[];
  for (final raw in json['answers'] as List? ?? const []) {
    final a = raw as Map<String, dynamic>;
    final item = byId[(a['id'] as num?)?.toInt()];
    if (item == null) continue;
    out.add(
      BakeResult(
        item.answer,
        a['verdict'] == 'reject' ? 'reject' : 'keep',
        a['reason'] as String? ?? '',
        [
          for (final c in a['clues'] as List? ?? const [])
            if (c is Map && c['text'] is String)
              (text: c['text'] as String, style: '${c['style'] ?? ''}')
            else if (c is String)
              (text: c, style: ''),
        ],
      ),
    );
  }
  return out;
}
