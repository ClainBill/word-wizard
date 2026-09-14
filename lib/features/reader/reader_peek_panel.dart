import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/reader_repository.dart';
import '../../domain/models/entry.dart';
import '../../domain/reader/reader_analysis.dart';
import '../../widgets/add_to_list_sheet.dart';
import '../../widgets/ipa_label.dart';
import '../../widgets/pos_tag.dart';
import '../../widgets/word_detail_sheet.dart';
import 'reader_page.dart';

final _peekEntryProvider = FutureProvider.autoDispose.family<WordEntry?, String>(
  (ref, headword) => ref.watch(searchRepositoryProvider).loadWord(headword),
);

/// The strip that rises from the bottom when a word on the page is tapped:
/// enough to answer "what does this mean?" without leaving the page — the
/// headword, its part of speech and pronunciation, the first couple of
/// senses, and which lists it's already in — plus the three things a reader
/// wants next: add it to a list, start studying it, or open the full card.
///
/// Non-modal on purpose. The full card is a sheet that covers the text;
/// this sits under it so the sentence the word came from stays in view.
class ReaderPeekPanel extends ConsumerWidget {
  final ResolvedWord word;
  final WordMarks marks;
  final Map<int, ReaderListInfo> listIndex;
  final VoidCallback onClose;

  const ReaderPeekPanel({
    super.key,
    required this.word,
    required this.marks,
    required this.listIndex,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entryAsync = ref.watch(_peekEntryProvider(word.headword));
    final entry = entryAsync.valueOrNull;
    final studying = marks.isStudying(word.entryId);
    final listIds = marks.listsFor(word.entryId);

    // The first two senses, once the full entry is in; the analysis's
    // one-line gloss until then, so the panel never appears empty.
    final senses = <({String pos, String gloss})>[];
    if (entry != null) {
      for (final group in entry.posGroups) {
        for (final sense in group.senses) {
          senses.add((pos: group.pos, gloss: sense.gloss));
          if (senses.length == 2) break;
        }
        if (senses.length == 2) break;
      }
    }
    if (senses.isEmpty && word.gloss != null) senses.add((pos: word.pos, gloss: word.gloss!));

    return Material(
      color: scheme.surface,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        Text(
                          word.headword,
                          style: TextStyle(
                            fontFamily: readerFontFamily,
                            fontFamilyFallback: readerFontFallback,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        PosTag(senses.isEmpty ? word.pos : senses.first.pos),
                        if (entry?.pronunciation.ipa != null) IpaLabel(entry!.pronunciation.ipa),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.volume_up_outlined),
                    tooltip: 'Pronounce',
                    onPressed: () => ref.read(ttsProvider).speak(word.headword),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: onClose,
                  ),
                ],
              ),
              if (senses.isNotEmpty) ...[
                const SizedBox(height: 4),
                for (var i = 0; i < senses.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 18,
                          child: Text('${i + 1}.', style: TextStyle(color: scheme.onSurfaceVariant)),
                        ),
                        Expanded(
                          child: Text(
                            senses[i].gloss,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(height: 1.35, color: scheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
              ] else if (entryAsync.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (listIds.isNotEmpty || studying) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final id in listIds)
                      _ListPill(
                        label: listIndex[id]?.name ?? 'List',
                        color: ReaderPalette.swatch(id, theme.brightness),
                      ),
                    if (studying) const _StudyingPill(),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.folder_outlined, size: 18),
                    label: const Text('Add to list'),
                    onPressed: () => showAddToListSheet(context, ref, word.entryId),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    icon: Icon(studying ? Icons.check : Icons.school_outlined, size: 18),
                    label: Text(studying ? 'Studying' : 'Study'),
                    onPressed: studying
                        ? null
                        : () async {
                            await ref.read(studyRepositoryProvider).ensureCard(
                                  word.entryId,
                                  ref.read(studyDirectionsProvider),
                                );
                            ref.invalidate(dueCountProvider);
                          },
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: const Text('Card'),
                    onPressed: () => showWordDetailSheet(context, word.headword),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListPill extends StatelessWidget {
  final String label;
  final Color color;

  const _ListPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 9, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
        ],
      ),
    );
  }
}

class _StudyingPill extends StatelessWidget {
  const _StudyingPill();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 9, 3),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.school_outlined, size: 13, color: scheme.primary),
          const SizedBox(width: 5),
          Text('Studying', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
        ],
      ),
    );
  }
}
