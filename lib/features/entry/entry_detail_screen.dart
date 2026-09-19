import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/study_repository.dart' show SenseChoices, StudyRepository;
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

class EntryDetailScreen extends ConsumerStatefulWidget {
  final String headword;

  /// True when the Search tab opened this — the one path that counts as
  /// looking the word up (see `LookupLog`). Logged here rather than on the
  /// result tap so the lookup carries the word's canonical id, which only
  /// the loaded entry knows.
  final bool fromSearch;

  const EntryDetailScreen({super.key, required this.headword, this.fromSearch = false});

  @override
  ConsumerState<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends ConsumerState<EntryDetailScreen> {
  bool _lookupLogged = false;

  void _logLookup(WordEntry word) {
    if (_lookupLogged || !widget.fromSearch) return;
    _lookupLogged = true;
    ref.read(progressRepositoryProvider).logLookup(word.canonicalEntryId, word.headword);
  }

  @override
  Widget build(BuildContext context) {
    final wordAsync = ref.watch(_wordProvider(widget.headword));

    return Scaffold(
      appBar: AppBar(title: const Text('Entry')),
      body: wordAsync.when(
        data: (word) {
          if (word == null) return const Center(child: Text('Entry not found.'));
          _logLookup(word);
          return WordBody(word: word);
        },
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
    final studying = studyingAsync.valueOrNull ?? false;
    final choices =
        ref.watch(senseChoicesProvider(word.canonicalEntryId)).valueOrNull ?? SenseChoices.none;
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
            Expanded(child: Text(word.headword, style: Theme.of(context).textTheme.headlineMedium)),
            IconButton(
              icon: const Icon(Icons.volume_up_outlined),
              tooltip: 'Pronounce',
              onPressed: () => ref.read(ttsProvider).speak(word.headword),
            ),
          ],
        ),
        IpaLabel(word.pronunciation.ipa),
        _SpellingsLine(word),
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
                  label: Text(studying ? 'In Lexery' : 'Add to Lexery'),
                  onPressed: studying
                      ? null
                      : () async {
                          await ref
                              .read(studyRepositoryProvider)
                              .ensureCard(word.canonicalEntryId, ref.read(studyDirectionsProvider));
                          ref.invalidate(_isStudyingProvider(word.canonicalEntryId));
                          ref.invalidate(dueCountProvider);
                        },
                ),
                loading: () => const FilledButton(onPressed: null, child: Text('…')),
                error: (error, stack) => const FilledButton(onPressed: null, child: Text('Add to Lexery')),
              ),
            ),
          ],
        ),

        // 2. Meanings, grouped by part of speech. Holding one toggles it on
        // or off the study card, right here where it's read — no separate
        // picker, and the checkmarks always show what the card carries.
        // Holding on past a second beat does the opposite and keeps the
        // meaning off the card for good.
        const SizedBox(height: 20),
        Text(
          _sensesCaption(studying, choices, word),
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final group in word.posGroups)
          _PosSection(
            group: group,
            choices: choices,
            onHold: (sense) => _togglePin(ref, sense, studying: studying, choices: choices),
            onHoldLonger: (sense) =>
                _toggleExclude(ref, sense, studying: studying, choices: choices),
          ),

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
              for (final f in word.forms) Chip(label: Text(f.formText), visualDensity: VisualDensity.compact),
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

  static String _sensesCaption(bool studying, SenseChoices choices, WordEntry word) {
    final total = word.posGroups.fold(0, (n, g) => n + g.senses.length);
    if (!studying) {
      return total <= 1 ? 'Hold the meaning to study it.' : 'Hold a meaning to study just that one.';
    }
    final left = choices.excluded.isEmpty
        ? ''
        : ' · ${choices.excluded.length} left out';
    if (choices.pinned.isEmpty) {
      return total <= 1
          ? 'On the study card.'
          : 'The card draws one or two meanings at random each review. '
              'Hold a meaning to pin it instead, or keep holding to leave it out$left.';
    }
    return 'Hold a meaning to pin or unpin it, keep holding to leave it out · '
        '${choices.pinned.length} of $total on the card$left.';
  }

  /// Puts the word into study if it isn't yet — either hold means
  /// "remember this one", which needs a card to remember it on.
  Future<StudyRepository> _ensureStudying(WidgetRef ref, bool studying) async {
    final repo = ref.read(studyRepositoryProvider);
    if (!studying) {
      await repo.ensureCard(word.canonicalEntryId, ref.read(studyDirectionsProvider));
      ref.invalidate(_isStudyingProvider(word.canonicalEntryId));
      ref.invalidate(dueCountProvider);
    }
    return repo;
  }

  /// A hold on a sense: pins or unpins it. Pinning an excluded sense lifts
  /// the exclusion — the pin is the more deliberate gesture. With no pins
  /// left the card goes back to drawing meanings at random.
  Future<void> _togglePin(
    WidgetRef ref,
    Sense sense, {
    required bool studying,
    required SenseChoices choices,
  }) async {
    final repo = await _ensureStudying(ref, studying);
    final pinned = Set.of(choices.pinned);
    if (!pinned.remove(sense.id)) pinned.add(sense.id);
    await repo.setSenseChoices(
      word.canonicalEntryId,
      pinned: pinned,
      excluded: choices.excluded.difference({sense.id}),
    );
  }

  /// A longer hold: keeps the sense off the card, or lets it back on.
  Future<void> _toggleExclude(
    WidgetRef ref,
    Sense sense, {
    required bool studying,
    required SenseChoices choices,
  }) async {
    final repo = await _ensureStudying(ref, studying);
    final excluded = Set.of(choices.excluded);
    if (!excluded.remove(sense.id)) excluded.add(sense.id);
    await repo.setSenseChoices(
      word.canonicalEntryId,
      pinned: choices.pinned.difference({sense.id}),
      excluded: excluded,
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
        style: TextStyle(fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _PosSection extends StatelessWidget {
  final PosSenses group;

  /// Which senses the card carries (a checkmark) and which it never will
  /// (a ⊘), so what the card will show is always visible right where the
  /// meanings are read.
  final SenseChoices choices;

  /// Long-press on a sense — toggles it on or off the card.
  final ValueChanged<Sense> onHold;

  /// Holding on past the pin — toggles the sense's exclusion.
  final ValueChanged<Sense> onHoldLonger;

  const _PosSection({
    required this.group,
    required this.choices,
    required this.onHold,
    required this.onHoldLonger,
  });

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
            _SenseRow(
              sense: sense,
              state: choices.pinned.contains(sense.id)
                  ? _SenseState.pinned
                  : choices.excluded.contains(sense.id)
                      ? _SenseState.excluded
                      : _SenseState.plain,
              onHold: onHold,
              onHoldLonger: onHoldLonger,
            ),
        ],
      ),
    );
  }
}

enum _SenseState { plain, pinned, excluded }

/// One meaning. A quick tap still lands on the individual words (their
/// lookup recognisers win the gesture arena); holding anywhere on the row
/// wins instead. The hold has two beats: the long-press lands with a
/// haptic and, on release, pins the sense; keep the finger down through a
/// second haptic and the release excludes it instead. Two gestures on one
/// row, told apart by how long the finger stays — the same way a hold is
/// told apart from a tap. The row tints itself while armed, so the second
/// beat is visible as well as felt.
class _SenseRow extends StatefulWidget {
  final Sense sense;
  final _SenseState state;
  final ValueChanged<Sense> onHold;
  final ValueChanged<Sense> onHoldLonger;

  const _SenseRow({
    required this.sense,
    required this.state,
    required this.onHold,
    required this.onHoldLonger,
  });

  @override
  State<_SenseRow> createState() => _SenseRowState();
}

class _SenseRowState extends State<_SenseRow> {
  /// How much longer than a long-press the finger has to stay down for the
  /// hold to mean "leave it out" rather than "pin it".
  static const _longerBy = Duration(milliseconds: 650);

  Timer? _longer;
  bool _armed = false;

  @override
  void dispose() {
    _longer?.cancel();
    super.dispose();
  }

  void _start() {
    HapticFeedback.mediumImpact();
    _armed = false;
    _longer?.cancel();
    _longer = Timer(_longerBy, () {
      HapticFeedback.heavyImpact();
      setState(() => _armed = true);
    });
  }

  void _end() {
    _longer?.cancel();
    if (_armed) {
      setState(() => _armed = false);
      widget.onHoldLonger(widget.sense);
    } else {
      widget.onHold(widget.sense);
    }
  }

  void _cancel() {
    _longer?.cancel();
    if (_armed) setState(() => _armed = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pinned = widget.state == _SenseState.pinned;
    final excluded = widget.state == _SenseState.excluded;
    // While the second beat is armed the row previews what release will
    // do, so the finger can be lifted with confidence.
    final showExcluded = _armed ? !excluded : excluded;
    final showPinned = _armed ? false : pinned;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) => _start(),
        onLongPressEnd: (_) => _end(),
        onLongPressCancel: _cancel,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(0, 4, 6, 4),
          decoration: BoxDecoration(
            color: showPinned
                ? scheme.primary.withValues(alpha: 0.06)
                : showExcluded
                    ? scheme.onSurface.withValues(alpha: 0.04)
                    : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text('${widget.sense.order + 1}.', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
              Expanded(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: showExcluded ? 0.45 : 1,
                  child: TappableWordText(widget.sense.gloss),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: showPinned
                    ? Padding(
                        key: const ValueKey('pinned'),
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Tooltip(
                          message: 'Pinned to the study card — hold to unpin',
                          child: Icon(Icons.check_circle, size: 18, color: scheme.primary),
                        ),
                      )
                    : showExcluded
                        ? Padding(
                            key: const ValueKey('excluded'),
                            padding: const EdgeInsets.only(left: 8, top: 2),
                            child: Tooltip(
                              message: 'Left off the study card — keep holding to bring it back',
                              child: Icon(Icons.block, size: 18, color: scheme.onSurfaceVariant),
                            ),
                          )
                        : const SizedBox(key: ValueKey('off'), width: 26),
              ),
            ],
          ),
        ),
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
  final _focus = FocusNode();
  final _fieldKey = GlobalKey();
  Timer? _debounce;
  bool _preview = false;
  bool _loadedInitial = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  /// The field is the last thing on the page, so when the keyboard comes up
  /// it is exactly what gets covered. The framework's own caret-into-view
  /// nudge runs before the keyboard has finished arriving; this one waits
  /// for it, then brings the whole field up, not just the caret line.
  void _onFocusChanged() {
    if (!_focus.hasFocus) return;
    Future.delayed(const Duration(milliseconds: 350), () {
      // Looked up after the delay on purpose — it's the field's own
      // context, current as of now, not one captured before the gap.
      final fieldContext = _fieldKey.currentContext;
      if (!mounted || fieldContext == null) return;
      Scrollable.ensureVisible(
        // ignore: use_build_context_synchronously
        fieldContext,
        alignment: 0.2,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
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
            key: _fieldKey,
            controller: _controller,
            focusNode: _focus,
            maxLines: 6,
            minLines: 3,
            onChanged: _onChanged,
            scrollPadding: const EdgeInsets.only(bottom: 120),
            decoration: InputDecoration(
              hintText:
                  'Add notes (Markdown supported) — these also appear on this '
                  'word\'s study card.',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
      ],
    );
  }
}

/// The word's other spellings — "Also spelled colour (Commonwealth and
/// Ireland)" — and, when the card was reached by one of them, which. One
/// card per word, whichever way it's written (see [SpellingVariant]).
class _SpellingsLine extends StatelessWidget {
  final WordEntry word;

  const _SpellingsLine(this.word);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final reachedBy = word.lookedUpAs;
    // Misspellings get a card looked up by them, not a place on it.
    final listed = word.variants.where((v) => !v.isMisspelling && v.text != reachedBy).toList();
    if (reachedBy == null && listed.isEmpty) return const SizedBox.shrink();

    String describe(SpellingVariant v) => '${v.text} (${v.label})';
    const shown = 4;
    final more = listed.length - shown;
    final others = [
      for (final v in listed.take(shown)) describe(v),
      if (more > 0) '$more more',
    ].join(', ');

    final reachedVariant = reachedBy == null
        ? null
        : word.variants.where((v) => v.text == reachedBy).firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reachedBy != null)
            Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: reachedBy,
                  style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface),
                ),
                TextSpan(
                  text: reachedVariant == null || reachedVariant.isMisspelling
                      ? ' is a spelling of ${word.headword}'
                      : ' is the ${reachedVariant.label} spelling of ${word.headword}',
                ),
              ]),
              style: style,
            ),
          if (listed.isNotEmpty)
            Text(
              '${reachedBy == null ? 'Also spelled' : 'Also'} $others',
              style: style,
            ),
        ],
      ),
    );
  }
}
