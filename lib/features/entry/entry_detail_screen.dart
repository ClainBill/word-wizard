import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/entry.dart';
import '../../widgets/add_to_list_sheet.dart';
import '../../widgets/ipa_label.dart';
import '../../widgets/pos_tag.dart';
import '../../widgets/tappable_word_text.dart';

final _wordProvider = FutureProvider.family<WordEntry?, String>(
  (ref, headword) => ref.watch(searchRepositoryProvider).loadWord(headword),
);

final _isStudyingProvider = FutureProvider.family<bool, int>(
  (ref, id) => ref.watch(studyRepositoryProvider).isStudying(id),
);

final _noteProvider = StreamProvider.family<String?, int>(
  (ref, id) => ref.watch(notesRepositoryProvider).watchNote(id),
);

class EntryDetailScreen extends ConsumerWidget {
  final String headword;

  const EntryDetailScreen({super.key, required this.headword});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wordAsync = ref.watch(_wordProvider(headword));

    return Scaffold(
      appBar: AppBar(title: const Text('Entry')),
      body: wordAsync.when(
        data: (word) => word == null
            ? const Center(child: Text('Entry not found.'))
            : WordBody(word: word),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load entry: $e')),
      ),
    );
  }
}

/// The full dictionary-entry body — word, meanings, etymology, examples,
/// forms, and notes. Used both by [EntryDetailScreen] (as a full page) and
/// by the study session's "view full card" bottom sheet, so it accepts an
/// optional [controller] to hook into a [DraggableScrollableSheet] when
/// embedded there.
class WordBody extends ConsumerWidget {
  final WordEntry word;
  final ScrollController? controller;

  const WordBody({super.key, required this.word, this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studyingAsync = ref.watch(_isStudyingProvider(word.canonicalEntryId));
    final allExamples = word.allExamples;
    final previewExamples = allExamples.take(3).toList();
    final moreExamples = allExamples.skip(3).toList();

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        // 1. Word
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(word.headword, style: Theme.of(context).textTheme.headlineMedium),
            ),
            IconButton(
              icon: const Icon(Icons.volume_up_outlined),
              tooltip: 'Pronounce',
              onPressed: () => ref.read(ttsProvider).speak(word.headword),
            ),
          ],
        ),
        IpaLabel(word.pronunciation.ipa),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.folder_outlined),
                label: const Text('Add to list'),
                onPressed: () => showAddToListSheet(context, ref, word.canonicalEntryId),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: studyingAsync.when(
                data: (studying) => FilledButton.icon(
                  icon: Icon(studying ? Icons.check : Icons.add),
                  label: Text(studying ? 'Studying' : 'Study'),
                  onPressed: studying
                      ? null
                      : () async {
                          await ref.read(studyRepositoryProvider).ensureCard(word.canonicalEntryId);
                          ref.invalidate(_isStudyingProvider(word.canonicalEntryId));
                          ref.invalidate(dueCountProvider);
                        },
                ),
                loading: () => const FilledButton(onPressed: null, child: Text('…')),
                error: (error, stack) => const FilledButton(onPressed: null, child: Text('Study')),
              ),
            ),
          ],
        ),

        // 2. Meanings, grouped by part of speech
        const SizedBox(height: 28),
        for (final group in word.posGroups) _PosSection(group: group),

        // 3. Etymology
        if (word.etymology != null) ...[
          const SizedBox(height: 8),
          _SectionHeader(icon: Icons.history_edu_outlined, label: 'Word origin'),
          const SizedBox(height: 8),
          TappableWordText(
            word.etymology!,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5),
          ),
        ],

        // 4. Examples — the first 3 always visible, more (if any) behind a
        // single expander so you never need a click just to see 3 of them.
        if (previewExamples.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionHeader(icon: Icons.format_quote_outlined, label: 'Examples'),
          const SizedBox(height: 8),
          for (final ex in previewExamples) _ExampleLine(text: ex.text),
          if (moreExamples.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text(
                  '${moreExamples.length} more example${moreExamples.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                children: [for (final ex in moreExamples) _ExampleLine(text: ex.text)],
              ),
            ),
        ],

        // 5. Forms & conjugations
        if (word.forms.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionHeader(icon: Icons.auto_awesome_motion_outlined, label: 'Forms & conjugations'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final f in word.forms)
                Chip(label: Text(f.formText), visualDensity: VisualDensity.compact),
            ],
          ),
        ],

        // 6. Custom notes
        const SizedBox(height: 24),
        _SectionHeader(icon: Icons.edit_note_outlined, label: 'Notes'),
        const SizedBox(height: 8),
        _NotesEditor(entryId: word.canonicalEntryId),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
        ),
      ],
    );
  }
}

class _ExampleLine extends StatelessWidget {
  final String text;

  const _ExampleLine({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TappableWordText(
        '"$text"',
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PosSection extends StatelessWidget {
  final PosSenses group;

  const _PosSection({required this.group});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PosTag(group.pos),
          const SizedBox(height: 8),
          for (final sense in group.senses)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${sense.order + 1}.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(child: TappableWordText(sense.gloss)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NotesEditor extends ConsumerStatefulWidget {
  final int entryId;

  const _NotesEditor({required this.entryId});

  @override
  ConsumerState<_NotesEditor> createState() => _NotesEditorState();
}

class _NotesEditorState extends ConsumerState<_NotesEditor> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _preview = false;
  bool _loadedInitial = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      ref.read(notesRepositoryProvider).saveNote(widget.entryId, text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final noteAsync = ref.watch(_noteProvider(widget.entryId));

    // Seed the controller from storage once, without clobbering live edits
    // on every rebuild triggered by the note's own stream.
    noteAsync.whenData((note) {
      if (!_loadedInitial) {
        _loadedInitial = true;
        _controller.text = note ?? '';
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined, size: 16),
            label: Text(_preview ? 'Edit' : 'Preview'),
            onPressed: () => setState(() => _preview = !_preview),
          ),
        ),
        if (_preview)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _controller.text.trim().isEmpty
                ? Text(
                    'Nothing written yet.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  )
                : MarkdownBody(data: _controller.text),
          )
        else
          TextField(
            controller: _controller,
            maxLines: 6,
            minLines: 3,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: 'Add notes (Markdown supported) — these also appear on this '
                  'word\'s study card.',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
      ],
    );
  }
}
