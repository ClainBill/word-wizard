import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/clues.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';

/// The word-list conventions the clue bake writes: `e:` clues, and flag 8
/// for a word the bake judged unfit for a puzzle.
void main() {
  const header = '# text\tdisplay\tzipf\tsynsets\tflags\tscore\ttier\tfamiliarity\ttags\tclue...\n';

  test('baked clues parse as edited and outweigh a WordNet gloss', () {
    final entry = parseWordList(
      '${header}ADO\tado\t3.5\t1\t0\t5.0\t99\t5\t\te:Fuss\te:Much ___ about nothing\td:A rapid active commotion',
    ).single;
    expect(entry.clues.map((c) => c.type), [
      CrosswordClueType.edited,
      CrosswordClueType.edited,
      CrosswordClueType.definition,
    ]);
    expect(clueOptionWeight(entry.clues.first), greaterThan(clueOptionWeight(entry.clues.last)));
    expect(inFillPool(entry), isTrue);
  });

  test('a rejected word leaves the fill pool but keeps its clues for anchoring', () {
    final entry = parseWordList('${header}HRS\thrs\t3.65\t1\t8\t5.0\t51\t4\t\te:Clock units').single;
    expect(entry.isRejected, isTrue);
    expect(entry.clues.single.text, 'Clock units');
    expect(inFillPool(entry), isFalse);
  });
}
