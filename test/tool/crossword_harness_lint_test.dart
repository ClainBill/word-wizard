import 'package:flutter_test/flutter_test.dart';

import '../../tool/crossword_harness/lint.dart';

/// The harness's clue lint, on real clues from a baseline run: each flag
/// fires on the fault it names and stays quiet on a good newspaper clue.
void main() {
  test('good clues pass clean', () {
    for (final (answer, clue) in [
      ('TERSE', 'Short and to the point'),
      ('THE', 'Word before noun'),
      ('SKI', 'Glide down a slope'),
      ('OPAQUE', 'Hard to see through'),
    ]) {
      expect(lintClue(answer, clue), isEmpty, reason: '$answer: $clue');
    }
  });

  test('each fault is caught', () {
    expect(lintClue('TIN', 'A vessel (box, can, pan, etc.) made of tinplate and used mainly in baking'),
        contains(ClueFlag.long));
    expect(lintClue('AGO', 'Gone by; or in the past (adj.)'), containsAll([ClueFlag.multiSense, ClueFlag.residue]));
    expect(lintClue('OLD', "Past times (especially in the phrase `in days of ___')"), contains(ClueFlag.residue));
    expect(lintClue('EARED', 'Worn or shabby from overuse; -Clifton Fadiman (adj.)'), contains(ClueFlag.residue));
    expect(lintClue('THORACIC', 'Of or relating to the chest or thorax'), contains(ClueFlag.dictionaryVoice));
    expect(lintClue('ALANINE', 'A crystalline amino acid that occurs in many proteins'), contains(ClueFlag.technical));
    expect(lintClue('PETS', 'Stroke or caress in an erotic manner'), contains(ClueFlag.unsuitable));
    expect(lintClue('CANDID', 'Candidly honest'), contains(ClueFlag.leak));
    expect(lintClue('YOU', 'Reader, e.g.'), contains(ClueFlag.endsWithPeriod));
  });
}
