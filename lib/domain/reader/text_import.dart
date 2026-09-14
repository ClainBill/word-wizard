import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/reader_document.dart';

/// Turns what arrived on the clipboard (or was typed) into [ReaderBlock]s.
///
/// Two importers: plain text, which has to guess at structure from line
/// breaks and the odd markdown-ish marker, and HTML, which gets the real
/// structure for free but has to survive whatever a browser sprays onto the
/// clipboard — nested divs, inline `style="font-weight:700"` instead of
/// `<b>`, and a script tag or two.

final _blankLine = RegExp(r'\n[ \t]*\n');
final _headingMarker = RegExp(r'^(#{1,6})\s+(.*)$');
final _bulletMarker = RegExp(r'^[-*•·▪◦]\s+(.*)$');
final _numberMarker = RegExp(r'^(\d+)[.)]\s+(.*)$');
final _quoteMarker = RegExp(r'^>\s?(.*)$');

List<ReaderBlock> blocksFromPlainText(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return const [];

  // Blank lines are the one structure signal plain text reliably has. When
  // there are any, single newlines inside a chunk are most likely hard
  // wraps (a PDF, an email, a terminal) and get joined back into prose.
  // When there are none at all, every line is its own paragraph — a note,
  // a poem, a list, a chat — since joining them would destroy the only
  // structure the text had.
  final chunks = normalized.split(_blankLine);
  final blocks = <ReaderBlock>[];
  for (final chunk in chunks) {
    final lines = chunk.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) continue;
    final separateLines = chunks.length == 1 || lines.any(_hasMarker);
    if (separateLines) {
      for (final line in lines) {
        blocks.add(_lineToBlock(line.trim()));
      }
    } else {
      blocks.add(_lineToBlock(lines.map((l) => l.trim()).join(' ')));
    }
  }
  return blocks;
}

bool _hasMarker(String line) {
  final t = line.trim();
  return _headingMarker.hasMatch(t) ||
      _bulletMarker.hasMatch(t) ||
      _numberMarker.hasMatch(t) ||
      _quoteMarker.hasMatch(t);
}

ReaderBlock _lineToBlock(String line) {
  final heading = _headingMarker.firstMatch(line);
  if (heading != null) {
    return ReaderBlock(
      kind: BlockKind.heading,
      level: heading.group(1)!.length,
      spans: [ReaderSpan(heading.group(2)!.trim())],
    );
  }
  final bullet = _bulletMarker.firstMatch(line);
  if (bullet != null) {
    return ReaderBlock(kind: BlockKind.bullet, spans: [ReaderSpan(bullet.group(1)!.trim())]);
  }
  final number = _numberMarker.firstMatch(line);
  if (number != null) {
    return ReaderBlock(
      kind: BlockKind.numbered,
      level: int.parse(number.group(1)!),
      spans: [ReaderSpan(number.group(2)!.trim())],
    );
  }
  final quote = _quoteMarker.firstMatch(line);
  if (quote != null) {
    return ReaderBlock(kind: BlockKind.quote, spans: [ReaderSpan(quote.group(1)!.trim())]);
  }
  return ReaderBlock(kind: BlockKind.paragraph, spans: [ReaderSpan(line)]);
}

List<ReaderBlock> blocksFromHtml(String html) {
  final document = html_parser.parse(html);
  final root = document.body ?? document.documentElement;
  if (root == null) return const [];
  final walker = _HtmlWalker();
  walker.visitChildren(root, const _InlineStyle());
  walker.flush();
  return walker.blocks;
}

class _InlineStyle {
  final bool bold;
  final bool italic;
  final bool underline;

  const _InlineStyle({this.bold = false, this.italic = false, this.underline = false});

  _InlineStyle merge({bool? bold, bool? italic, bool? underline}) => _InlineStyle(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
      );
}

const _skippedTags = {
  'script', 'style', 'head', 'title', 'meta', 'link', 'noscript', 'template', //
  'svg', 'iframe', 'object', 'embed', 'canvas', 'video', 'audio', 'img',
};

const _blockTags = {
  'p', 'div', 'section', 'article', 'header', 'footer', 'main', 'aside', 'nav', //
  'figure', 'figcaption', 'table', 'thead', 'tbody', 'tr', 'td', 'th', 'li', 'ul',
  'ol', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'hr', 'dl', 'dt',
  'dd', 'address', 'details', 'summary', 'form', 'fieldset', 'center', 'body',
};

final _boldWeight = RegExp(r'font-weight\s*:\s*(bold|bolder|[6-9]00)', caseSensitive: false);
final _italicStyle = RegExp(r'font-style\s*:\s*(italic|oblique)', caseSensitive: false);
final _underlineStyle = RegExp(r'text-decoration(?:-line)?\s*:[^;]*underline', caseSensitive: false);
final _whitespaceRun = RegExp(r'\s+');

class _HtmlWalker {
  final blocks = <ReaderBlock>[];
  final _spans = <ReaderSpan>[];
  BlockKind _kind = BlockKind.paragraph;
  int _level = 0;
  int _quoteDepth = 0;
  int _preDepth = 0;

  /// One counter per open `<ol>`; null entries are `<ul>`s.
  final _listStack = <int?>[];

  void visitChildren(dom.Node node, _InlineStyle style) {
    for (final child in node.nodes) {
      _visit(child, style);
    }
  }

  void _visit(dom.Node node, _InlineStyle style) {
    if (node is dom.Text) {
      _appendText(node.data, style);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName?.toLowerCase() ?? '';
    if (_skippedTags.contains(tag)) return;

    var childStyle = style;
    switch (tag) {
      case 'b' || 'strong':
        childStyle = childStyle.merge(bold: true);
      case 'i' || 'em' || 'cite' || 'dfn' || 'var':
        childStyle = childStyle.merge(italic: true);
      case 'u' || 'ins':
        childStyle = childStyle.merge(underline: true);
    }
    final inline = node.attributes['style'];
    if (inline != null) {
      if (_boldWeight.hasMatch(inline)) childStyle = childStyle.merge(bold: true);
      if (_italicStyle.hasMatch(inline)) childStyle = childStyle.merge(italic: true);
      if (_underlineStyle.hasMatch(inline)) childStyle = childStyle.merge(underline: true);
    }

    if (tag == 'br') {
      flush();
      return;
    }
    if (!_blockTags.contains(tag)) {
      visitChildren(node, childStyle);
      return;
    }

    flush();
    switch (tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _kind = BlockKind.heading;
        _level = int.parse(tag.substring(1));
      case 'blockquote':
        _quoteDepth++;
      case 'ul':
        _listStack.add(null);
      case 'ol':
        _listStack.add(0);
      case 'li':
        if (_listStack.isNotEmpty && _listStack.last != null) {
          _listStack[_listStack.length - 1] = _listStack.last! + 1;
          _kind = BlockKind.numbered;
          _level = _listStack.last!;
        } else {
          _kind = BlockKind.bullet;
        }
      case 'pre':
        _preDepth++;
    }
    visitChildren(node, childStyle);
    flush();
    switch (tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' || 'li':
        // An empty heading or item must not lend its kind to whatever
        // block comes next.
        _kind = BlockKind.paragraph;
        _level = 0;
      case 'blockquote':
        _quoteDepth--;
      case 'ul' || 'ol':
        if (_listStack.isNotEmpty) _listStack.removeLast();
      case 'pre':
        _preDepth--;
    }
  }

  void _appendText(String raw, _InlineStyle style) {
    String text;
    if (_preDepth > 0) {
      text = raw;
    } else {
      text = raw.replaceAll(_whitespaceRun, ' ');
      // Leading whitespace at the start of a block is indentation from the
      // markup, not content.
      if (_spans.isEmpty || _spans.last.text.endsWith(' ')) text = text.trimLeft();
    }
    if (text.isEmpty) return;
    final span = ReaderSpan(text, bold: style.bold, italic: style.italic, underline: style.underline);
    if (_spans.isNotEmpty && _spans.last.sameStyle(span)) {
      _spans[_spans.length - 1] = _spans.last.copyWith(text: _spans.last.text + text);
    } else {
      _spans.add(span);
    }
  }

  /// Emits the block in progress, if there is one. An empty flush keeps the
  /// pending kind: `<li><p>text</p></li>` opens the paragraph (an empty
  /// flush) before any text has landed under the item, and the text still
  /// has to come out as a bullet.
  void flush() {
    if (_spans.isEmpty) return;
    final last = _spans.last;
    _spans[_spans.length - 1] = last.copyWith(text: last.text.trimRight());
    _spans.removeWhere((s) => s.text.isEmpty);
    if (_spans.isNotEmpty) {
      // Anything that lives inside a blockquote reads as a quote.
      final kind = _quoteDepth > 0 && _kind == BlockKind.paragraph ? BlockKind.quote : _kind;
      blocks.add(ReaderBlock(kind: kind, level: _level, spans: List.of(_spans)));
    }
    _spans.clear();
    _kind = BlockKind.paragraph;
    _level = 0;
  }
}

/// A short name for a document: its first heading if it has one, otherwise
/// the opening of its first paragraph.
String deriveTitle(List<ReaderBlock> blocks) {
  for (final block in blocks) {
    if (block.kind == BlockKind.heading) {
      final t = block.text.trim();
      if (t.isNotEmpty) return _clip(t, 80);
    }
  }
  for (final block in blocks) {
    final t = block.text.trim();
    if (t.isNotEmpty) return _clip(t, 60);
  }
  return 'Untitled';
}

/// The first line or so of a document, for the history list.
String derivePreview(List<ReaderBlock> blocks, {int maxLength = 160}) {
  final buffer = StringBuffer();
  for (final block in blocks) {
    final t = block.text.trim();
    if (t.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(t);
    if (buffer.length >= maxLength) break;
  }
  return _clip(buffer.toString(), maxLength);
}

String _clip(String text, int max) {
  if (text.length <= max) return text;
  final cut = text.lastIndexOf(' ', max);
  return '${text.substring(0, cut > max ~/ 2 ? cut : max).trimRight()}…';
}
