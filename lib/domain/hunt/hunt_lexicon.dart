import 'hunt_models.dart';
import 'hunt_trie.dart';

/// The two compiled lexicons a hunt is built against — research contract
/// §1: validity (accepted) and main-word difficulty are separate policies.
///
/// - [accepted]: every spelling the board recognises. ENABLE1 minus the
///   content list, 4-16 letters (`assets/hunt/accepted.txt`).
/// - [main]: the familiar subset the player must find
///   (`assets/hunt/main.txt`). Always ⊆ accepted; anything in the main file
///   the accepted file doesn't know is dropped here rather than trusted.
///
/// Built once (in an isolate — ~170k words) and reused for every board.
/// [fingerprint] hashes both sources so a saved puzzle records what it was
/// certified against.
class HuntLexicon {
  final HuntTrie accepted;
  final HuntTrie main;
  final String fingerprint;

  const HuntLexicon({required this.accepted, required this.main, required this.fingerprint});

  factory HuntLexicon.fromSources({required String acceptedText, required String mainText}) {
    final accepted = HuntTrie.build(_lines(acceptedText));
    final main = HuntTrie.build([
      for (final w in _lines(mainText))
        if (accepted.contains(w)) w,
    ]);
    final hash = _fnv1a(acceptedText, _fnv1a(mainText, _fnv1aSeed));
    return HuntLexicon(
      accepted: accepted,
      main: main,
      fingerprint: 'enable-bonus-v1:${hash.toRadixString(16)}',
    );
  }

  /// Whether a word is a legal anchor: an accepted spelling of board-fitting
  /// length. Unknown study terms are refused rather than injected — the
  /// board would then reward a spelling the dictionary can't vouch for.
  bool isAnchorable(String text) =>
      text.length >= huntMinWordLength &&
      text.length <= huntMaxWordLength &&
      accepted.contains(text);

  static Iterable<String> _lines(String text) sync* {
    for (final line in text.split('\n')) {
      final w = line.trim();
      if (w.isNotEmpty && !w.startsWith('#')) yield w;
    }
  }

  static const int _fnv1aSeed = 0xcbf29ce484222325;

  /// 64-bit FNV-1a over a string's code units. Not cryptographic — it only
  /// has to tell one lexicon build from another.
  static int _fnv1a(String s, int hash) {
    for (var i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i);
      hash *= 0x100000001b3;
    }
    return hash;
  }
}
