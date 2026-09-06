import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'word_detail_sheet.dart';

final _wordPattern = RegExp(r"[A-Za-z][A-Za-z'-]*");

/// Renders [text] with every word individually tappable — tapping one
/// looks it up in the dictionary and pops its full card up as a sheet,
/// stacking on top of whatever's already open (so this works from inside
/// the study session's own word-detail sheet without leaving it). Used for
/// glosses, example sentences, and etymology text, where a reader is most
/// likely to hit an unfamiliar word worth looking up on the spot.
class TappableWordText extends ConsumerStatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  const TappableWordText(this.text, {super.key, this.style, this.textAlign = TextAlign.start});

  @override
  ConsumerState<TappableWordText> createState() => _TappableWordTextState();
}

class _TappableWordTextState extends ConsumerState<TappableWordText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void didUpdateWidget(TappableWordText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _disposeRecognizers();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _onTapWord(String word) async {
    final entry = await ref.read(searchRepositoryProvider).lookupTappedWord(word);
    if (!mounted) return;
    if (entry == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No entry for "$word"')));
      return;
    }
    showWordDetailSheet(context, entry.headword);
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = widget.style ?? DefaultTextStyle.of(context).style;
    final underlineColor = (baseStyle.color ?? DefaultTextStyle.of(context).style.color)?.withValues(alpha: 0.35);
    final wordStyle = baseStyle.copyWith(
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: underlineColor,
    );

    _disposeRecognizers();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _wordPattern.allMatches(widget.text)) {
      if (match.start > last) spans.add(TextSpan(text: widget.text.substring(last, match.start)));
      final word = match.group(0)!;
      final recognizer = TapGestureRecognizer()..onTap = () => _onTapWord(word);
      _recognizers.add(recognizer);
      spans.add(TextSpan(text: word, style: wordStyle, recognizer: recognizer));
      last = match.end;
    }
    if (last < widget.text.length) spans.add(TextSpan(text: widget.text.substring(last)));

    return RichText(
      textAlign: widget.textAlign,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }
}
