import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/reader_document.dart';
import '../../widgets/confirm_dialog.dart';
import 'reader_page.dart';

/// Everything the Reader has shown, newest-opened first. Tapping a row
/// makes it the page again; swiping removes it.
class ReaderHistoryScreen extends ConsumerWidget {
  const ReaderHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(readerHistoryProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if ((historyAsync.valueOrNull?.length ?? 0) > 1)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: () async {
                final ok = await showConfirmDialog(
                  context,
                  title: 'Clear history?',
                  message: 'Removes every text from the Reader. Words you added to lists or study '
                      'stay where they are.',
                  confirmLabel: 'Clear',
                  destructive: true,
                );
                if (ok) await ref.read(readerRepositoryProvider).deleteAll();
              },
            ),
        ],
      ),
      body: historyAsync.when(
        data: (docs) => docs.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Nothing here yet.\nText you paste into the Reader will be kept here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView.separated(
                itemCount: docs.length,
                separatorBuilder: (context, i) => const Divider(height: 1),
                itemBuilder: (context, i) => _HistoryTile(doc: docs[i]),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load history: $e')),
      ),
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  final ReaderDocumentSummary doc;

  const _HistoryTile({required this.doc});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(doc.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline),
      ),
      onDismissed: (_) => ref.read(readerRepositoryProvider).delete(doc.id),
      child: ListTile(
        leading: Icon(
          doc.source == ReaderSource.clipboard ? Icons.content_paste_outlined : Icons.edit_note_outlined,
          color: scheme.onSurfaceVariant,
        ),
        title: Text(
          doc.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: readerFontFamily,
            fontFamilyFallback: readerFontFallback,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (doc.preview.isNotEmpty && doc.preview != doc.title)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 3),
                child: Text(
                  doc.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3),
                ),
              ),
            Text(
              '${doc.source.label}  ·  ${formatReaderDate(doc.openedAt)}  ·  ${doc.wordCount} words',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        isThreeLine: true,
        onTap: () async {
          await ref.read(readerRepositoryProvider).open(doc.id);
          if (context.mounted) context.pop();
        },
      ),
    );
  }
}
