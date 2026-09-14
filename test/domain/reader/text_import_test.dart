import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/models/reader_document.dart';
import 'package:word_wizard/domain/reader/text_import.dart';

void main() {
  group('plain text', () {
    test('blank lines separate paragraphs and single newlines are soft wraps', () {
      final blocks = blocksFromPlainText('First line of one\nparagraph.\n\nSecond paragraph.');
      expect(blocks.map((b) => b.text), ['First line of one paragraph.', 'Second paragraph.']);
      expect(blocks.every((b) => b.kind == BlockKind.paragraph), isTrue);
    });

    test('with no blank lines at all, every line is its own paragraph', () {
      final blocks = blocksFromPlainText('Roses are red\nViolets are blue');
      expect(blocks.map((b) => b.text), ['Roses are red', 'Violets are blue']);
    });

    test('markdown-ish markers become headings, bullets, numbers and quotes', () {
      final blocks = blocksFromPlainText('# Title\n\n- one\n- two\n\n1. first\n2) second\n\n> a quote');
      expect(blocks[0].kind, BlockKind.heading);
      expect(blocks[0].level, 1);
      expect(blocks[0].text, 'Title');
      expect(blocks[1].kind, BlockKind.bullet);
      expect(blocks[2].text, 'two');
      expect(blocks[3].kind, BlockKind.numbered);
      expect(blocks[3].level, 1);
      expect(blocks[4].level, 2);
      expect(blocks[5].kind, BlockKind.quote);
      expect(blocks[5].text, 'a quote');
    });

    test('windows line endings and surrounding whitespace are normalized', () {
      final blocks = blocksFromPlainText('  a\r\n\r\nb  \r\n');
      expect(blocks.map((b) => b.text), ['a', 'b']);
    });

    test('empty input yields no blocks', () {
      expect(blocksFromPlainText('   \n\n  '), isEmpty);
    });
  });

  group('html', () {
    test('block structure and inline formatting survive', () {
      final blocks = blocksFromHtml('''
        <html><head><style>p{color:red}</style><script>alert(1)</script></head>
        <body>
          <h2>A   heading</h2>
          <p>Some <b>bold</b> and <em>italic</em> text.</p>
          <blockquote><p>Quoted words.</p></blockquote>
          <ul><li>first item</li><li>second <strong>item</strong></li></ul>
          <ol><li>one</li><li>two</li></ol>
        </body></html>
      ''');
      expect(blocks.map((b) => b.kind), [
        BlockKind.heading,
        BlockKind.paragraph,
        BlockKind.quote,
        BlockKind.bullet,
        BlockKind.bullet,
        BlockKind.numbered,
        BlockKind.numbered,
      ]);
      expect(blocks[0].text, 'A heading');
      expect(blocks[0].level, 2);
      expect(blocks[1].text, 'Some bold and italic text.');
      expect(blocks[1].spans.map((s) => (s.text, s.bold, s.italic)), [
        ('Some ', false, false),
        ('bold', true, false),
        (' and ', false, false),
        ('italic', false, true),
        (' text.', false, false),
      ]);
      expect(blocks[4].spans.last.bold, isTrue);
      expect(blocks[6].level, 2);
    });

    test('a browser\'s inline styles count as formatting', () {
      final blocks = blocksFromHtml(
        '<div><span style="font-weight: 700; color: rgb(0,0,0)">Heavy</span> '
        '<span style="font-style:italic">slanted</span> '
        '<span style="text-decoration-line: underline">under</span></div>',
      );
      expect(blocks, hasLength(1));
      final spans = blocks.single.spans;
      expect(spans.firstWhere((s) => s.text == 'Heavy').bold, isTrue);
      expect(spans.firstWhere((s) => s.text == 'slanted').italic, isTrue);
      expect(spans.firstWhere((s) => s.text == 'under').underline, isTrue);
    });

    test('nested divs and line breaks split blocks without leaving empty ones', () {
      final blocks = blocksFromHtml('<div><div>one</div><div><br></div><div>two<br>three</div></div>');
      expect(blocks.map((b) => b.text), ['one', 'two', 'three']);
    });

    test('an empty heading does not turn the next paragraph into one', () {
      final blocks = blocksFromHtml('<h1></h1><p>plain</p>');
      expect(blocks.single.kind, BlockKind.paragraph);
    });

    test('entities are decoded', () {
      final blocks = blocksFromHtml('<p>Tom &amp; Jerry&nbsp;&mdash; &ldquo;hi&rdquo;</p>');
      expect(blocks.single.text, 'Tom & Jerry — “hi”');
    });
  });

  group('titles and previews', () {
    test('title prefers the first heading, then the first paragraph', () {
      expect(deriveTitle(blocksFromPlainText('Opening words here.\n\n# Later heading')), 'Later heading');
      expect(deriveTitle(blocksFromPlainText('Just a paragraph.')), 'Just a paragraph.');
      expect(deriveTitle(const []), 'Untitled');
    });

    test('long titles are clipped at a word boundary with an ellipsis', () {
      final title = deriveTitle(blocksFromPlainText(List.filled(30, 'word').join(' ')));
      expect(title.length, lessThanOrEqualTo(61));
      expect(title, endsWith('…'));
      expect(title, isNot(contains('wor…')));
    });

    test('preview runs blocks together and clips', () {
      final preview = derivePreview(blocksFromPlainText('One.\n\nTwo.'), maxLength: 50);
      expect(preview, 'One. Two.');
    });
  });

  test('blocks round-trip through JSON', () {
    final blocks = blocksFromHtml('<h3>T</h3><p>a <b>b</b> <i>c</i></p><ol><li>x</li></ol>');
    final restored = [for (final b in blocks) ReaderBlock.fromJson(b.toJson())];
    expect(restored.map((b) => b.kind), blocks.map((b) => b.kind));
    expect(restored.map((b) => b.level), blocks.map((b) => b.level));
    expect(restored.map((b) => b.text), blocks.map((b) => b.text));
    expect(restored[1].spans[1].bold, isTrue);
    expect(restored[1].spans[3].italic, isTrue);
  });
}
