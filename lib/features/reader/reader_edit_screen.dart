import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/reader_document.dart';
import '../../domain/reader/text_import.dart';
import 'reader_page.dart';

/// Type or paste text by hand — the fallback for anything the clipboard
/// path doesn't cover — or edit the text of an existing document.
///
/// Editing works on the flattened text: bold and headings that came in
/// from the clipboard become plain paragraphs (blank-line separated, with
/// `#`, `-`, `>` markers still understood). That's the honest trade for a
/// plain text box, and it's stated on the screen.
class ReaderEditScreen extends ConsumerStatefulWidget {
  final int? documentId;

  const ReaderEditScreen({super.key, this.documentId});

  @override
  ConsumerState<ReaderEditScreen> createState() => _ReaderEditScreenState();
}

class _ReaderEditScreenState extends ConsumerState<ReaderEditScreen> {
  final _titleController = TextEditingController();
  final _textController = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  bool get _isEdit => widget.documentId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      ref.read(readerRepositoryProvider).getDocument(widget.documentId!).then((doc) {
        if (!mounted) return;
        setState(() {
          _titleController.text = doc?.title ?? '';
          _textController.text = doc == null ? '' : _toEditableText(doc.blocks);
          _loaded = true;
        });
      });
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _textController.dispose();
    super.dispose();
  }

  /// Blocks back to text the plain-text importer will read the same way:
  /// markers for headings, quotes and items, blank lines between blocks.
  static String _toEditableText(List<ReaderBlock> blocks) {
    return blocks.map((b) {
      final t = b.text;
      return switch (b.kind) {
        BlockKind.heading => '${'#' * b.level.clamp(1, 6)} $t',
        BlockKind.quote => '> $t',
        BlockKind.bullet => '- $t',
        BlockKind.numbered => '${b.level}. $t',
        BlockKind.paragraph => t,
      };
    }).join('\n\n');
  }

  Future<void> _save() async {
    final blocks = blocksFromPlainText(_textController.text);
    if (blocks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to save.')));
      return;
    }
    setState(() => _saving = true);
    final repo = ref.read(readerRepositoryProvider);
    final title = _titleController.text.trim();
    if (_isEdit) {
      await repo.updateDocumentText(widget.documentId!, blocks, title: title.isEmpty ? null : title);
    } else {
      final existing = await repo.findByContent(blocks);
      if (existing != null) {
        await repo.open(existing);
      } else {
        await repo.createDocument(blocks, source: ReaderSource.typed, title: title.isEmpty ? null : title);
      }
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit text' : 'New text'),
        actions: [
          TextButton(
            onPressed: _loaded && !_saving ? _save : null,
            child: const Text('Done'),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _titleController,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(
                      fontFamily: readerFontFamily,
                      fontFamilyFallback: readerFontFallback,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Title (optional)',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    autofocus: !_isEdit,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(
                      fontFamily: readerFontFamily,
                      fontFamilyFallback: readerFontFallback,
                      fontSize: 17,
                      height: 1.55,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Paste or type anything you want to read.\n\n'
                          'Separate paragraphs with a blank line. Lines starting with #, - or > '
                          'become headings, bullets and quotes.',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(16, 14, 16, 16),
                    ),
                  ),
                ),
                if (_isEdit)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    child: Text(
                      'Editing keeps headings, quotes and lists; bold and italic from a copied page are dropped.',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
    );
  }
}
