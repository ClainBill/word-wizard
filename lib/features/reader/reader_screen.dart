import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../data/repositories/reader_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/reader_document.dart';
import '../../domain/reader/reader_analysis.dart';
import '../../domain/reader/text_import.dart';
import '../../domain/reader/tokenizer.dart';
import '../../services/clipboard_service.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/word_detail_sheet.dart';
import 'reader_options_sheet.dart';
import 'reader_page.dart';
import 'reader_peek_panel.dart';

/// Anything shorter than this on the clipboard is a word someone copied,
/// not something they're reading — it isn't pulled in on its own (the
/// Paste button still takes it), and history doesn't fill up with single
/// words and passwords.
const minAutoImportWords = 3;

/// The Reader tab: whatever text was last copied, laid out as a page with
/// every word tappable and the ones already in lists or under study lit
/// up. Watches the clipboard each time the tab is opened or the app comes
/// back to the foreground; keeps a history of everything it has shown.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

enum _MenuAction { write, edit, rename, options }

class _ReaderScreenState extends ConsumerState<ReaderScreen> with WidgetsBindingObserver {
  ReaderSelection? _selection;
  ResolvedWord? _peekWord;
  int? _peekDocumentId;
  final _hiddenListIds = <int>{};
  bool _showStudying = true;
  bool _checkingClipboard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The tab may be the first thing shown; the shell only counts
    // *switches* to it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final shell = StatefulNavigationShell.maybeOf(context);
    if (shell != null && shell.currentIndex != readerBranchIndex) return;
    _checkClipboard(afterResume: true);
  }

  /// Pulls new clipboard text in — silently ignoring anything already seen
  /// or too short to be reading material.
  Future<void> _checkClipboard({bool afterResume = false}) async {
    if (_checkingClipboard) return;
    _checkingClipboard = true;
    try {
      final settings = ref.read(settingsRepositoryProvider);
      final clipboard = ref.read(clipboardServiceProvider);
      final last = await settings.readerClipboardStamp();
      var snapshot = await clipboard.readIfNew(last);
      if (snapshot == null && afterResume) {
        // Android only hands the clipboard to the focused window, and focus
        // lands a beat after "resumed".
        await Future<void>.delayed(const Duration(milliseconds: 500));
        snapshot = await clipboard.readIfNew(last);
      }
      if (snapshot == null || !mounted) return;
      await settings.setReaderClipboardStamp(snapshot.stamp);
      if (countWords(snapshot.text) < minAutoImportWords) return;
      await _import(snapshot, automatic: true);
    } finally {
      _checkingClipboard = false;
    }
  }

  Future<void> _pasteNow() async {
    final snapshot = await ref.read(clipboardServiceProvider).read();
    if (!mounted) return;
    if (snapshot == null) {
      _toast('Nothing on the clipboard.');
      return;
    }
    await ref.read(settingsRepositoryProvider).setReaderClipboardStamp(snapshot.stamp);
    await _import(snapshot, automatic: false);
  }

  Future<void> _import(ClipboardSnapshot snapshot, {required bool automatic}) async {
    // Prefer the HTML flavour for its structure, unless it lost most of the
    // text along the way (a copy that was mainly an image, say).
    var blocks = snapshot.html == null ? const <ReaderBlock>[] : blocksFromHtml(snapshot.html!);
    final plainWords = countWords(snapshot.text);
    if (blocks.isEmpty || countWords(blocks.map((b) => b.text).join('\n')) < plainWords * 0.5) {
      blocks = blocksFromPlainText(snapshot.text);
    }
    if (blocks.isEmpty) return;

    final repo = ref.read(readerRepositoryProvider);
    final existing = await repo.findByContent(blocks);
    if (!mounted) return;
    if (existing != null) {
      await repo.open(existing);
      _toast('Already in your history — reopened it.');
      return;
    }
    final id = await repo.createDocument(blocks, source: ReaderSource.clipboard);
    if (!mounted) return;
    _toast(
      automatic ? 'Loaded from the clipboard.' : 'Pasted.',
      action: SnackBarAction(label: 'Undo', onPressed: () => repo.delete(id)),
    );
  }

  void _toast(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      // A snackbar with an action persists by default; "Undo" should still
      // go away on its own.
      ..showSnackBar(SnackBar(content: Text(message), action: action, persist: false));
  }

  void _clearSelection() {
    if (_selection == null && _peekWord == null) return;
    setState(() {
      _selection = null;
      _peekWord = null;
    });
  }

  void _onWordTap(int docId, int block, int token, AnalyzedToken analyzed, WordMarks marks) {
    final word = analyzed.word;
    if (word == null) {
      _clearSelection();
      _toast('No entry for that word.');
      return;
    }
    setState(() {
      _selection = (block: block, token: token);
      _peekWord = marks.effective(word);
      _peekDocumentId = docId;
    });
  }

  void _onWordLongPress(int docId, int block, int token, AnalyzedToken analyzed, WordMarks marks) {
    _onWordTap(docId, block, token, analyzed, marks);
    final word = analyzed.word;
    if (word != null) showWordDetailSheet(context, marks.effective(word).headword);
  }

  Future<void> _rename(ReaderDocument doc) async {
    final controller = TextEditingController(text: doc.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Title'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await ref.read(readerRepositoryProvider).rename(doc.id, name);
  }

  Future<void> _delete(ReaderDocument doc) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Remove from history?',
      message: 'Removes "${doc.title}" from the Reader. Words you added to lists or study stay where they are.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    _clearSelection();
    await ref.read(readerRepositoryProvider).delete(doc.id);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(readerTabVisitsProvider, (previous, next) => _checkClipboard());

    final docAsync = ref.watch(readerCurrentDocumentProvider);
    final doc = docAsync.valueOrNull;
    final marks = ref.watch(readerMarksProvider).valueOrNull ?? WordMarks.empty;
    final listIndex = ref.watch(readerListIndexProvider).valueOrNull ?? const <int, ReaderListInfo>{};
    final prefs = ref.watch(readerPrefsProvider).valueOrNull ?? const ReaderPrefs();
    final analysisAsync =
        doc == null ? null : ref.watch(readerAnalysisProvider((id: doc.id, contentHash: doc.contentHash)));
    final analysis = analysisAsync?.valueOrNull;

    // A selection belongs to one document; drop it when the page changes.
    if (_peekWord != null && doc?.id != _peekDocumentId) {
      _selection = null;
      _peekWord = null;
    }

    final legend = analysis == null ? null : _LegendData.compute(analysis, marks);
    final markContext = ReaderMarkContext(
      marks: marks,
      hiddenListIds: _hiddenListIds,
      showStudying: _showStudying,
      markUncommon: prefs.markUncommon,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reader'),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_outlined),
            tooltip: 'Paste from clipboard',
            onPressed: _pasteNow,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => context.push('/reader/history'),
          ),
          // Right in the bar rather than in the menu: clearing out a text
          // just read is the commonest thing done here after reading it.
          if (doc != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove from history',
              onPressed: () => _delete(doc),
            ),
          PopupMenuButton<_MenuAction>(
            onSelected: (action) {
              switch (action) {
                case _MenuAction.write:
                  context.push('/reader/edit');
                case _MenuAction.edit:
                  if (doc != null) context.push('/reader/edit?doc=${doc.id}');
                case _MenuAction.rename:
                  if (doc != null) _rename(doc);
                case _MenuAction.options:
                  showReaderOptionsSheet(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _MenuAction.write,
                child: ListTile(leading: Icon(Icons.edit_note_outlined), title: Text('Write or paste text')),
              ),
              if (doc != null)
                const PopupMenuItem(
                  value: _MenuAction.edit,
                  child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit this text')),
                ),
              if (doc != null)
                const PopupMenuItem(
                  value: _MenuAction.rename,
                  child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename')),
                ),
              const PopupMenuItem(
                value: _MenuAction.options,
                child: ListTile(leading: Icon(Icons.text_fields), title: Text('Reading options')),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (analysisAsync != null && analysisAsync.isLoading) const LinearProgressIndicator(minHeight: 2),
          if (legend != null && legend.hasAnything)
            _LegendBar(
              legend: legend,
              listIndex: listIndex,
              hiddenListIds: _hiddenListIds,
              showStudying: _showStudying,
              markUncommon: prefs.markUncommon,
              onToggleList: (id) => setState(() {
                if (!_hiddenListIds.remove(id)) _hiddenListIds.add(id);
              }),
              onToggleStudying: () => setState(() => _showStudying = !_showStudying),
              onToggleUncommon: () =>
                  ref.read(settingsRepositoryProvider).setReaderMarkUncommon(!prefs.markUncommon),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: _PaperSheet(
                child: doc == null
                    ? (docAsync.isLoading
                        ? const SizedBox.shrink()
                        : _EmptyPage(
                            onPaste: _pasteNow,
                            onWrite: () => context.push('/reader/edit'),
                          ))
                    : ReaderPage(
                        key: ValueKey(doc.id),
                        document: doc,
                        analysis: analysis,
                        markContext: markContext,
                        prefs: prefs,
                        selection: _selection,
                        onWordTap: (b, t, a) => _onWordTap(doc.id, b, t, a, marks),
                        onWordLongPress: (b, t, a) => _onWordLongPress(doc.id, b, t, a, marks),
                        onBackgroundTap: _clearSelection,
                      ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _peekWord == null
                ? const SizedBox(width: double.infinity)
                : ReaderPeekPanel(
                    key: ValueKey(_peekWord!.entryId),
                    word: _peekWord!,
                    marks: marks,
                    listIndex: listIndex,
                    onClose: _clearSelection,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The sheet of paper the page sits on — a shade lighter than the tab's
/// background, edged and softly shadowed, its bottom running off behind
/// the peek panel like a page that continues.
class _PaperSheet extends StatelessWidget {
  final Widget child;

  const _PaperSheet({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // The full width whatever the child: while the document is still
      // loading the child is nothing at all, and a sheet sized to it was a
      // zero-width, full-height box in the middle of the column whose two
      // side borders drew as a line down the centre of the screen for the
      // frame or two before the page arrived.
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant),
          left: BorderSide(color: scheme.outlineVariant),
          right: BorderSide(color: scheme.outlineVariant),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.35 : 0.07),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _EmptyPage extends StatelessWidget {
  final VoidCallback onPaste;
  final VoidCallback onWrite;

  const _EmptyPage({required this.onPaste, required this.onWrite});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined, size: 44, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'Nothing to read yet',
              style: TextStyle(
                fontFamily: readerFontFamily,
                fontFamilyFallback: readerFontFallback,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Copy some text in any app and come back — it\'ll be laid out here with every '
              'word tappable, and the ones already in your lists highlighted.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.content_paste_outlined, size: 18),
                  label: const Text('Paste'),
                  onPressed: onPaste,
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note_outlined, size: 18),
                  label: const Text('Write'),
                  onPressed: onWrite,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the legend has to say about a page: how many distinct words fall
/// under each list, how many are being studied, how many are uncommon.
class _LegendData {
  final Map<int, int> wordsPerList;
  final int studying;
  final int uncommon;

  const _LegendData({required this.wordsPerList, required this.studying, required this.uncommon});

  bool get hasAnything => wordsPerList.isNotEmpty || studying > 0 || uncommon > 0;

  static _LegendData compute(ReaderAnalysis analysis, WordMarks marks) {
    final perList = <int, Set<int>>{};
    final studying = <int>{};
    final uncommon = <int>{};
    for (final t in analysis.allTokens) {
      final word = t.word;
      if (word == null) continue;
      final effective = marks.effective(word);
      for (final id in marks.listsFor(effective.entryId)) {
        perList.putIfAbsent(id, () => {}).add(effective.entryId);
      }
      if (marks.isStudying(effective.entryId)) studying.add(effective.entryId);
      if (word.isUncommon) uncommon.add(word.entryId);
    }
    return _LegendData(
      wordsPerList: {for (final e in perList.entries) e.key: e.value.length},
      studying: studying.length,
      uncommon: uncommon.length,
    );
  }
}

/// A row of chips that doubles as the key to the page's marks and as
/// toggles for them — tap a list to hide its wash, tap "Studying" to drop
/// the underlines, tap "Uncommon" to switch that setting.
class _LegendBar extends StatelessWidget {
  final _LegendData legend;
  final Map<int, ReaderListInfo> listIndex;
  final Set<int> hiddenListIds;
  final bool showStudying;
  final bool markUncommon;
  final void Function(int listId) onToggleList;
  final VoidCallback onToggleStudying;
  final VoidCallback onToggleUncommon;

  const _LegendBar({
    required this.legend,
    required this.listIndex,
    required this.hiddenListIds,
    required this.showStudying,
    required this.markUncommon,
    required this.onToggleList,
    required this.onToggleStudying,
    required this.onToggleUncommon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listIds = legend.wordsPerList.keys.toList()
      ..sort((a, b) => (listIndex[a]?.name ?? '').compareTo(listIndex[b]?.name ?? ''));

    Widget chip({
      required Widget leading,
      required String label,
      required int count,
      required bool on,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: on ? 1 : 0.45,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                  const SizedBox(width: 5),
                  Text('$count', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
        children: [
          for (final id in listIds)
            chip(
              leading: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: ReaderPalette.swatch(id, theme.brightness),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              label: listIndex[id]?.name ?? 'List',
              count: legend.wordsPerList[id]!,
              on: !hiddenListIds.contains(id),
              onTap: () => onToggleList(id),
            ),
          if (legend.studying > 0)
            chip(
              leading: Container(
                width: 12,
                height: 2,
                color: scheme.primary,
              ),
              label: 'Studying',
              count: legend.studying,
              on: showStudying,
              onTap: onToggleStudying,
            ),
          if (legend.uncommon > 0)
            chip(
              leading: Text(
                '····',
                style: TextStyle(fontSize: 10, height: 0.6, color: scheme.onSurfaceVariant, letterSpacing: -1),
              ),
              label: 'Uncommon',
              count: legend.uncommon,
              on: markUncommon,
              onTap: onToggleUncommon,
            ),
        ],
      ),
    );
  }
}
