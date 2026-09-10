import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/crossword_repository.dart';

/// **Debug.** The answers barred from every crossword, browsable and editable.
///
/// Two things feed this list: the editorial pass, which rejects answers it
/// judges unfair to a learner (PORTING_SPEC.md §9.3), and you. It is a
/// model's opinion accumulating unchecked otherwise, so it has to be
/// somewhere you can read it, disagree with it, and add to it — the persistent
/// offenders here are the raw material for `CROSSWORDESE` in the Crosswordler
/// project, which is the same job reader complaints have always done, and the
/// proper home for a verdict once you agree with it.
///
/// Remove this screen with the rest of the debug affordances before release.
class CrosswordBannedAnswersScreen extends ConsumerStatefulWidget {
  const CrosswordBannedAnswersScreen({super.key});

  @override
  ConsumerState<CrosswordBannedAnswersScreen> createState() =>
      _CrosswordBannedAnswersScreenState();
}

enum _Sort { recent, alphabetical }

class _CrosswordBannedAnswersScreenState
    extends ConsumerState<CrosswordBannedAnswersScreen> {
  final _filterController = TextEditingController();
  String _filter = '';
  _Sort _sort = _Sort.recent;

  /// Answers swiped away whose removal hasn't reached the list yet.
  ///
  /// A `Dismissible` must leave the tree in the same frame it is dismissed;
  /// re-reading the database is asynchronous, so between the swipe and the
  /// refresh the row would still be built — which Flutter reports as "a
  /// dismissed Dismissible widget is still part of the tree". Hiding it here
  /// closes that gap without pretending the write was synchronous.
  final Set<String> _pendingRemoval = {};

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _refresh() => ref.refresh(crosswordBannedAnswersProvider.future);

  CrosswordRepository get _repository => ref.read(crosswordRepositoryProvider);

  Future<void> _add() async {
    final result = await showDialog<({String answer, String reason})>(
      context: context,
      builder: (context) => const _BanEditor(title: 'Ban an answer'),
    );
    if (result == null) return;
    final banned = await _repository.banAnswer(result.answer, reason: result.reason);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(banned == null ? 'Not a usable answer' : 'Banned $banned'),
    ));
  }

  Future<void> _edit(CrosswordBannedAnswer ban) async {
    final result = await showDialog<({String answer, String reason})>(
      context: context,
      builder: (context) => _BanEditor(
        title: 'Edit ban',
        answer: ban.answer,
        reason: ban.reason,
        // The word itself is fixed: it is the row's identity, and renaming it
        // would silently unban the original.
        answerLocked: true,
      ),
    );
    if (result == null) return;
    await _repository.updateBanReason(ban.answer, result.reason);
    await _refresh();
  }

  Future<void> _unban(CrosswordBannedAnswer ban) async {
    // Hidden first, deleted second: see [_pendingRemoval].
    setState(() => _pendingRemoval.add(ban.answer));
    await _repository.unbanAnswer(ban.answer);
    await _refresh();
    if (!mounted) return;
    setState(() => _pendingRemoval.remove(ban.answer));

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${ban.answer} unbanned'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          await _repository.banAnswer(ban.answer, reason: ban.reason);
          await _refresh();
        },
      ),
    ));
  }

  Future<void> _clearAll(int count) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Clear the ban list?'),
            content: Text('$count answer${count == 1 ? '' : 's'} will be allowed '
                'back into puzzles.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear all'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _repository.clearBannedAnswers();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bansAsync = ref.watch(crosswordBannedAnswersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Banned answers'),
        actions: [
          IconButton(
            icon: Icon(_sort == _Sort.recent ? Icons.schedule : Icons.sort_by_alpha),
            tooltip: _sort == _Sort.recent ? 'Newest first' : 'A to Z',
            onPressed: () => setState(() =>
                _sort = _sort == _Sort.recent ? _Sort.alphabetical : _Sort.recent),
          ),
          PopupMenuButton<String>(
            onSelected: (_) => _clearAll(bansAsync.valueOrNull?.length ?? 0),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear all')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.block),
        label: const Text('Ban a word'),
      ),
      body: bansAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load the ban list: $e')),
        data: (all) {
          final filtered = [
            for (final ban in all)
              if (!_pendingRemoval.contains(ban.answer) &&
                  (_filter.isEmpty ||
                      ban.answer.contains(_filter) ||
                      ban.reason.toLowerCase().contains(_filter.toLowerCase())))
                ban,
          ]..sort((a, b) => _sort == _Sort.alphabetical
              ? a.answer.compareTo(b.answer)
              : b.at.compareTo(a.at));

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: TextField(
                  controller: _filterController,
                  onChanged: (value) => setState(() => _filter = value.trim()),
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Filter by answer or reason',
                    border: const OutlineInputBorder(),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _filterController.clear();
                              setState(() => _filter = '');
                            },
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text(
                      '${filtered.length}'
                      '${filtered.length == all.length ? '' : ' of ${all.length}'}'
                      ' banned',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const Spacer(),
                    Text(
                      'Excluded from every new puzzle',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (filtered.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        all.isEmpty
                            ? 'Nothing is banned. The AI editor adds answers it '
                                'judges unfair, and you can add your own.'
                            : 'No banned answer matches "$_filter".',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final ban = filtered[index];
                      return Dismissible(
                        key: ValueKey(ban.answer),
                        background: Container(
                          color: scheme.errorContainer,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: const Icon(Icons.undo),
                        ),
                        secondaryBackground: Container(
                          color: scheme.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: const Icon(Icons.undo),
                        ),
                        onDismissed: (_) => _unban(ban),
                        child: ListTile(
                          title: Text(
                            ban.answer,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            ban.reason.isEmpty ? 'No reason recorded' : ban.reason,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          trailing: Text(
                            ban.difficulty.isEmpty ? '' : ban.difficulty,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          onTap: () => _edit(ban),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Add or amend one ban. The answer field is locked when editing, since the
/// word is the row's identity.
class _BanEditor extends StatefulWidget {
  final String title;
  final String answer;
  final String reason;
  final bool answerLocked;

  const _BanEditor({
    required this.title,
    this.answer = '',
    this.reason = '',
    this.answerLocked = false,
  });

  @override
  State<_BanEditor> createState() => _BanEditorState();
}

class _BanEditorState extends State<_BanEditor> {
  late final TextEditingController _answer =
      TextEditingController(text: widget.answer);
  late final TextEditingController _reason =
      TextEditingController(text: widget.reason);

  @override
  void dispose() {
    _answer.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _answer,
            enabled: !widget.answerLocked,
            autofocus: !widget.answerLocked,
            textCapitalization: TextCapitalization.characters,
            // Grid form is letters only; anything else is stripped on save,
            // but stopping it here means what you type is what gets banned.
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z]'))],
            decoration: const InputDecoration(labelText: 'Answer', isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            autofocus: widget.answerLocked,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Why (optional)',
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (answer: _answer.text.toUpperCase(), reason: _reason.text.trim()),
          ),
          child: Text(widget.answerLocked ? 'Save' : 'Ban'),
        ),
      ],
    );
  }
}
