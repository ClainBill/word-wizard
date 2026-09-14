import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/repositories/settings_repository.dart';
import '../../domain/models/reader_document.dart';
import '../../domain/reader/reader_analysis.dart';

/// The Reader's typographic voice: a serif body on a paper-coloured sheet,
/// so a pasted article reads like a page of a book rather than a form
/// field. Generic family names resolve to the platform's serif (Noto Serif
/// on Android); the fallbacks cover the desktop targets.
const readerFontFamily = 'serif';
const readerFontFallback = ['Georgia', 'Times New Roman', 'Noto Serif'];

/// One highlighter colour per list. A list keeps the same colour
/// everywhere (it's chosen from its id), so the legend and the page agree
/// and so it doesn't shift when another list is created.
class ReaderPalette {
  static const _hues = [
    Color(0xFFF2D544), // yellow marker
    Color(0xFF8ED47C), // green
    Color(0xFFF59BC2), // pink
    Color(0xFF7FC4F2), // blue
    Color(0xFFF7B267), // orange
    Color(0xFFC6A5F0), // violet
    Color(0xFF7AD5CB), // teal
    Color(0xFFF08A7E), // coral
  ];

  static Color base(int listId) => _hues[listId % _hues.length];

  /// The wash behind a word on the page.
  static Color highlight(int listId, Brightness brightness) =>
      base(listId).withValues(alpha: brightness == Brightness.dark ? 0.38 : 0.55);

  /// The solid swatch in the legend and peek chips.
  static Color swatch(int listId, Brightness brightness) =>
      base(listId).withValues(alpha: brightness == Brightness.dark ? 0.85 : 1.0);
}

/// Which word on the page is selected: block index and token index within
/// that block's analysis.
typedef ReaderSelection = ({int block, int token});

/// Everything the page needs to decorate a word — the live marks and what
/// the legend has toggled off.
class ReaderMarkContext {
  final WordMarks marks;
  final Set<int> hiddenListIds;
  final bool showStudying;
  final bool markUncommon;

  const ReaderMarkContext({
    required this.marks,
    this.hiddenListIds = const {},
    this.showStudying = true,
    this.markUncommon = true,
  });

  /// The lists a word should be highlighted for, in the order they'll be
  /// drawn (only the first actually is — one word, one wash).
  List<int> visibleListsFor(ResolvedWord word) =>
      [for (final id in marks.listsFor(word.entryId)) if (!hiddenListIds.contains(id)) id];
}

/// The paper sheet: title, dateline, and the blocks — every word tappable.
class ReaderPage extends StatelessWidget {
  final ReaderDocument document;
  final ReaderAnalysis? analysis;
  final ReaderMarkContext markContext;
  final ReaderPrefs prefs;
  final ReaderSelection? selection;
  final void Function(int block, int token, AnalyzedToken analyzed) onWordTap;
  final void Function(int block, int token, AnalyzedToken analyzed) onWordLongPress;
  final VoidCallback onBackgroundTap;

  const ReaderPage({
    super.key,
    required this.document,
    required this.analysis,
    required this.markContext,
    required this.prefs,
    required this.selection,
    required this.onWordTap,
    required this.onWordLongPress,
    required this.onBackgroundTap,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = document.blocks;
    // A copied page's own <h1> became the title; drawing it again as the
    // first block would show it twice.
    final firstBlock = blocks.isNotEmpty &&
            blocks.first.kind == BlockKind.heading &&
            blocks.first.text.trim() == document.title.trim()
        ? 1
        : 0;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onBackgroundTap,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 160),
        itemCount: blocks.length - firstBlock + 1,
        itemBuilder: (context, i) {
          if (i == 0) return _PageHeader(document: document, analysis: analysis);
          final index = i - 1 + firstBlock;
          return _BlockView(
            block: blocks[index],
            tokens: analysis == null || index >= analysis!.blocks.length ? const [] : analysis!.blocks[index],
            markContext: markContext,
            prefs: prefs,
            selectedToken: selection?.block == index ? selection!.token : null,
            onWordTap: (t, a) => onWordTap(index, t, a),
            onWordLongPress: (t, a) => onWordLongPress(index, t, a),
            onBackgroundTap: onBackgroundTap,
          );
        },
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  final ReaderDocument document;
  final ReaderAnalysis? analysis;

  const _PageHeader({required this.document, required this.analysis});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final uncommon = analysis?.uncommonCount;
    final meta = [
      document.source.label,
      formatReaderDate(document.createdAt),
      '${document.wordCount} words',
      if (uncommon != null && uncommon > 0) '$uncommon uncommon',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            document.title,
            style: TextStyle(
              fontFamily: readerFontFamily,
              fontFamilyFallback: readerFontFallback,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.2,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            meta.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

class _BlockView extends StatelessWidget {
  final ReaderBlock block;
  final List<AnalyzedToken> tokens;
  final ReaderMarkContext markContext;
  final ReaderPrefs prefs;
  final int? selectedToken;
  final void Function(int token, AnalyzedToken analyzed) onWordTap;
  final void Function(int token, AnalyzedToken analyzed) onWordLongPress;
  final VoidCallback onBackgroundTap;

  const _BlockView({
    required this.block,
    required this.tokens,
    required this.markContext,
    required this.prefs,
    required this.selectedToken,
    required this.onWordTap,
    required this.onWordLongPress,
    required this.onBackgroundTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = prefs.fontSize;
    final body = TextStyle(
      fontFamily: readerFontFamily,
      fontFamilyFallback: readerFontFallback,
      fontSize: size,
      height: 1.6,
      color: scheme.onSurface,
    );

    switch (block.kind) {
      case BlockKind.heading:
        final scale = switch (block.level) { 1 => 1.5, 2 => 1.3, _ => 1.15 };
        return Padding(
          padding: EdgeInsets.only(top: block.level <= 2 ? 18 : 12, bottom: 8),
          child: _text(body.copyWith(fontSize: size * scale, fontWeight: FontWeight.w700, height: 1.3)),
        );
      case BlockKind.quote:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            padding: const EdgeInsets.only(left: 14),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: scheme.primary.withValues(alpha: 0.5), width: 3)),
            ),
            child: _text(body.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
          ),
        );
      case BlockKind.bullet || BlockKind.numbered:
        final marker = block.kind == BlockKind.bullet ? '•' : '${block.level}.';
        return Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(marker, style: body.copyWith(color: scheme.onSurfaceVariant)),
              ),
              Expanded(child: _text(body)),
            ],
          ),
        );
      case BlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _text(body),
        );
    }
  }

  Widget _text(TextStyle style) => _TappableBlockText(
        text: block.text,
        spans: block.spans,
        tokens: tokens,
        baseStyle: style,
        markContext: markContext,
        selectedToken: selectedToken,
        onWordTap: onWordTap,
        onWordLongPress: onWordLongPress,
        onBackgroundTap: onBackgroundTap,
      );
}

/// A block's text as one [RichText], with every resolved word decorated by
/// its marks and located by hit-testing the paragraph's own layout rather
/// than by giving each of a few thousand words its own gesture recognizer.
class _TappableBlockText extends StatefulWidget {
  final String text;
  final List<ReaderSpan> spans;
  final List<AnalyzedToken> tokens;
  final TextStyle baseStyle;
  final ReaderMarkContext markContext;
  final int? selectedToken;
  final void Function(int token, AnalyzedToken analyzed) onWordTap;
  final void Function(int token, AnalyzedToken analyzed) onWordLongPress;

  /// A tap inside the block that didn't land on a word — the blank end of
  /// a line — which should clear the selection like any other blank tap.
  final VoidCallback onBackgroundTap;

  const _TappableBlockText({
    required this.text,
    required this.spans,
    required this.tokens,
    required this.baseStyle,
    required this.markContext,
    required this.selectedToken,
    required this.onWordTap,
    required this.onWordLongPress,
    required this.onBackgroundTap,
  });

  @override
  State<_TappableBlockText> createState() => _TappableBlockTextState();
}

class _TappableBlockTextState extends State<_TappableBlockText> {
  final _paragraphKey = GlobalKey();

  /// The token under [local], if the point is actually on a word's glyphs
  /// (not the blank end of a line or the gap between lines).
  int? _tokenAt(Offset local) {
    final paragraph = _paragraphKey.currentContext?.findRenderObject();
    if (paragraph is! RenderParagraph) return null;
    final offset = paragraph.getPositionForOffset(local).offset;
    // A caret offset sits *between* characters, so the last letter of a word
    // can report the offset just past it; accept either edge and let the
    // glyph-box check below settle it.
    int? candidate;
    for (var i = 0; i < widget.tokens.length; i++) {
      final t = widget.tokens[i].token;
      if (offset >= t.start && offset < t.end) {
        candidate = i;
        break;
      }
      if (offset == t.end) candidate ??= i;
    }
    if (candidate == null) return null;
    final t = widget.tokens[candidate].token;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: t.start, extentOffset: t.end),
    );
    for (final box in boxes) {
      if (box.toRect().inflate(3).contains(local)) return candidate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final i = _tokenAt(d.localPosition);
        if (i == null) {
          widget.onBackgroundTap();
        } else {
          widget.onWordTap(i, widget.tokens[i]);
        }
      },
      onLongPressStart: (d) {
        final i = _tokenAt(d.localPosition);
        if (i != null) widget.onWordLongPress(i, widget.tokens[i]);
      },
      child: RichText(
        key: _paragraphKey,
        text: TextSpan(style: widget.baseStyle, children: _buildSpans(context)),
      ),
    );
  }

  /// Walks the text once, cutting at every formatting-run boundary *and*
  /// every word boundary, so each piece carries both its bold/italic and
  /// its marks.
  List<InlineSpan> _buildSpans(BuildContext context) {
    final text = widget.text;
    final spans = widget.spans;
    final tokens = widget.tokens;
    final cuts = <int>{0, text.length};
    var pos = 0;
    for (final s in spans) {
      pos += s.text.length;
      cuts.add(pos);
    }
    for (final t in tokens) {
      cuts.add(t.token.start);
      cuts.add(t.token.end);
    }
    final sorted = cuts.toList()..sort();

    final out = <InlineSpan>[];
    var spanIndex = 0;
    var spanEnd = spans.isEmpty ? text.length : spans.first.text.length;
    var tokenIndex = 0;
    for (var c = 0; c + 1 < sorted.length; c++) {
      final a = sorted[c];
      final b = sorted[c + 1];
      if (b <= a) continue;
      while (a >= spanEnd && spanIndex + 1 < spans.length) {
        spanIndex++;
        spanEnd += spans[spanIndex].text.length;
      }
      while (tokenIndex < tokens.length && tokens[tokenIndex].token.end <= a) {
        tokenIndex++;
      }
      final inToken = tokenIndex < tokens.length && tokens[tokenIndex].token.start <= a;
      var style = spans.isEmpty ? const TextStyle() : _formatting(spans[spanIndex]);
      if (inToken) {
        final decoration = _markStyle(context, tokenIndex, tokens[tokenIndex]);
        if (decoration != null) style = style.merge(decoration);
      }
      out.add(TextSpan(text: text.substring(a, b), style: style));
    }
    return out;
  }

  TextStyle _formatting(ReaderSpan span) => TextStyle(
        fontWeight: span.bold ? FontWeight.w700 : null,
        fontStyle: span.italic ? FontStyle.italic : null,
        decoration: span.underline ? TextDecoration.underline : null,
      );

  /// How a word is drawn: selected wins outright; otherwise a list wash
  /// behind it, a firm underline if it's being studied, and a faint dotted
  /// underline if it's merely uncommon — the last two combine with the
  /// wash, and the first of them with each other.
  TextStyle? _markStyle(BuildContext context, int index, AnalyzedToken analyzed) {
    final scheme = Theme.of(context).colorScheme;
    if (index == widget.selectedToken) {
      return TextStyle(
        color: scheme.onPrimary,
        background: Paint()..color = scheme.primary,
      );
    }
    final word = analyzed.word;
    if (word == null) return null;
    final ctx = widget.markContext;
    final effective = ctx.marks.effective(word);
    final lists = ctx.visibleListsFor(effective);
    final studying = ctx.showStudying && ctx.marks.isStudying(effective.entryId);
    final uncommon = ctx.markUncommon && word.isUncommon;
    if (lists.isEmpty && !studying && !uncommon) return null;
    return TextStyle(
      background: lists.isEmpty
          ? null
          : (Paint()..color = ReaderPalette.highlight(lists.first, Theme.of(context).brightness)),
      decoration: studying || uncommon ? TextDecoration.underline : null,
      decorationStyle: studying ? TextDecorationStyle.solid : TextDecorationStyle.dotted,
      decorationThickness: studying ? 2 : 1.2,
      decorationColor: studying ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: 0.55),
    );
  }
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today, 14:32" / "Yesterday, 09:10" / "3 Sep 2026".
String formatReaderDate(DateTime at) {
  final now = DateTime.now();
  final time = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  if (at.year == now.year && at.month == now.month && at.day == now.day) return 'Today, $time';
  final yesterday = now.subtract(const Duration(days: 1));
  if (at.year == yesterday.year && at.month == yesterday.month && at.day == yesterday.day) {
    return 'Yesterday, $time';
  }
  return '${at.day} ${_monthNames[at.month - 1]} ${at.year}';
}
