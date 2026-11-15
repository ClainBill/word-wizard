import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/slang_repository.dart';
import '../../domain/models/slang.dart';
import '../../widgets/confirm_dialog.dart';

/// Adds a word to the Slang Stack, or edits one already there.
///
/// [headword] opens the editor on that word: its slang entry when it has
/// one, otherwise a new entry with the headword filled in — which is how
/// "add your own meaning" on a dictionary card and "add it" from a search
/// that found nothing both land here.
///
/// Pops `true` when the word was deleted, so a screen showing a word only
/// the Slang Stack knew can close itself too.
class SlangEditorScreen extends ConsumerStatefulWidget {
  final String? headword;

  /// True when opened from the word's own card: saving goes back to it
  /// rather than opening a second copy on top.
  final bool fromCard;

  const SlangEditorScreen({super.key, this.headword, this.fromCard = false});

  @override
  ConsumerState<SlangEditorScreen> createState() => _SlangEditorScreenState();
}

/// What the dictionary says about the headword being typed.
enum _Status { checking, inDictionary, spellingOf, newWord, alreadyInStack }

class _MeaningDraft {
  final int? id;
  String pos;
  SlangTone? tone;
  final TextEditingController gloss;
  final TextEditingController plainEnglish;
  final TextEditingController examples;

  _MeaningDraft({this.id, this.pos = 'noun', this.tone, String gloss = '', String? plain, List<String> examples = const []})
      : gloss = TextEditingController(text: gloss),
        plainEnglish = TextEditingController(text: plain ?? ''),
        examples = TextEditingController(text: examples.join('\n'));

  factory _MeaningDraft.from(SlangSense s) => _MeaningDraft(
        id: s.id,
        pos: s.pos,
        tone: s.tone,
        gloss: s.gloss,
        plain: s.plainEnglish,
        examples: s.examples,
      );

  bool get isEmpty => gloss.text.trim().isEmpty;

  SlangSense toSense() => SlangSense(
        id: id,
        pos: pos,
        gloss: gloss.text.trim(),
        plainEnglish: plainEnglish.text,
        tone: tone,
        examples: examples.text.split('\n'),
      );

  void dispose() {
    gloss.dispose();
    plainEnglish.dispose();
    examples.dispose();
  }
}

class _SlangEditorScreenState extends ConsumerState<SlangEditorScreen> {
  final _headword = TextEditingController();
  final _sayItLike = TextEditingController();
  final _spellings = TextEditingController();
  final _forms = TextEditingController();
  final _region = TextEditingController();
  final _scene = TextEditingController();
  final _heardAt = TextEditingController();
  final _origin = TextEditingController();
  final _meanings = <_MeaningDraft>[];
  SlangFreshness? _freshness;

  /// The word being edited, once loaded; null for a new one.
  SlangWord? _existing;
  bool _loading = true;
  bool _saving = false;

  _Status _status = _Status.checking;

  /// How many meanings the dictionary has for the headword, when it has it.
  int _dictionarySenses = 0;

  /// The dictionary's headword when what's typed is only another spelling
  /// of it ("colour" for "color") — a slang word filed under the spelling
  /// could never be reached, since a lookup of it opens the main word.
  String? _mainSpelling;
  Timer? _checkDebounce;
  int _checkSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _checkDebounce?.cancel();
    for (final c in [_headword, _sayItLike, _spellings, _forms, _region, _scene, _heardAt, _origin]) {
      c.dispose();
    }
    for (final m in _meanings) {
      m.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final headword = widget.headword?.trim();
    final existing = headword == null || headword.isEmpty
        ? null
        : await ref.read(slangRepositoryProvider).byHeadword(headword);
    if (!mounted) return;
    setState(() {
      _existing = existing;
      _headword.text = existing?.headword ?? headword ?? '';
      if (existing != null) {
        _sayItLike.text = existing.sayItLike ?? '';
        _spellings.text = existing.spellings.join(', ');
        _forms.text = existing.forms.join(', ');
        _region.text = existing.region ?? '';
        _scene.text = existing.scene ?? '';
        _heardAt.text = existing.heardAt ?? '';
        _origin.text = existing.origin ?? '';
        _freshness = existing.freshness;
        _meanings.addAll(existing.senses.map(_MeaningDraft.from));
      }
      if (_meanings.isEmpty) _meanings.add(_MeaningDraft());
      _loading = false;
    });
    _checkHeadword();
  }

  void _onHeadwordChanged(String _) {
    _checkDebounce?.cancel();
    setState(() => _status = _Status.checking);
    _checkDebounce = Timer(const Duration(milliseconds: 300), _checkHeadword);
  }

  /// Looks the headword up as it's typed, so the person knows before saving
  /// whether they're adding a new word or a meaning to one the dictionary
  /// already has — slang often makes it into Wiktionary quickly.
  Future<void> _checkHeadword() async {
    final seq = ++_checkSeq;
    final headword = _headword.text.trim();
    if (headword.isEmpty) {
      setState(() => _status = _Status.newWord);
      return;
    }
    final slang = await ref.read(slangRepositoryProvider).byHeadword(headword);
    final word = await ref.read(searchRepositoryProvider).loadWord(headword);
    if (!mounted || seq != _checkSeq) return;
    setState(() {
      if (slang != null && slang.id != _existing?.id) {
        _status = _Status.alreadyInStack;
      } else if (word != null && !word.isSlangOnly && word.headword == headword) {
        _status = _Status.inDictionary;
        _dictionarySenses = word.posGroups.where((g) => !g.isSlang).fold(0, (n, g) => n + g.senses.length);
      } else if (word != null && !word.isSlangOnly && word.lookedUpAs == headword) {
        _status = _Status.spellingOf;
        _mainSpelling = word.headword;
      } else {
        _status = _Status.newWord;
      }
    });
  }

  bool get _canSave {
    if (_saving || _loading || _headword.text.trim().isEmpty) return false;
    if (const {_Status.alreadyInStack, _Status.checking, _Status.spellingOf}.contains(_status)) return false;
    // A word the dictionary doesn't know is nothing without a meaning; one
    // it does can be kept in the stack for its details alone.
    return _status == _Status.inDictionary || _meanings.any((m) => !m.isEmpty);
  }

  static List<String> _split(String text) => [
        for (final part in text.split(',')) if (part.trim().isNotEmpty) part.trim(),
      ];

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final repo = ref.read(slangRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await repo.save(SlangWord(
        id: _existing?.id,
        headword: _headword.text.trim(),
        sayItLike: _sayItLike.text,
        spellings: _split(_spellings.text),
        forms: _split(_forms.text),
        region: _region.text,
        scene: _scene.text,
        freshness: _freshness,
        heardAt: _heardAt.text,
        origin: _origin.text,
        createdAt: _existing?.createdAt,
        senses: [for (final m in _meanings) if (!m.isEmpty) m.toSense()],
      ));
      ref.read(slangEditsProvider.notifier).state++;
      if (!mounted) return;
      final wasNew = _existing == null;
      final renamed = !wasNew && saved.headword != _existing!.headword;
      // A new word opens on its card, where it can be studied or listed
      // like any other. An edit goes back to wherever it came from — unless
      // the word was renamed, when the card behind is for the old name.
      if ((wasNew && !widget.fromCard) || renamed) {
        context.pushReplacement('/entry/${Uri.encodeComponent(saved.headword)}');
      } else {
        context.pop();
      }
    } on SlangHeadwordTakenException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final existing = _existing;
    if (existing == null) return;
    final slangOnly = _status != _Status.inDictionary;
    final ok = await showConfirmDialog(
      context,
      title: 'Remove "${existing.headword}"?',
      message: slangOnly
          ? 'Removes it from your Slang Stack, along with its study progress, list places and '
              'notes — the dictionary doesn\'t have this word, so nothing else could show them. '
              'This can\'t be undone.'
          : 'Removes your own meanings and details. The dictionary\'s card for '
              '"${existing.headword}" stays, with its study progress, lists and notes.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(slangRepositoryProvider).delete(existing.id!);
    ref.read(slangEditsProvider.notifier).state++;
    if (mounted) context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final editing = _existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit slang' : 'Add slang'),
        actions: [
          if (editing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove from Slang Stack',
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _canSave ? _save : null,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
              children: [
                TextField(
                  controller: _headword,
                  autofocus: !editing && _headword.text.isEmpty,
                  textCapitalization: TextCapitalization.none,
                  autocorrect: false,
                  style: Theme.of(context).textTheme.titleLarge,
                  decoration: const InputDecoration(labelText: 'Word or phrase', border: OutlineInputBorder()),
                  onChanged: _onHeadwordChanged,
                ),
                _StatusLine(
                  status: _status,
                  headword: _headword.text.trim(),
                  dictionarySenses: _dictionarySenses,
                  mainSpelling: _mainSpelling,
                  onEditExisting: () => context.pushReplacement(
                    '/slang/edit?headword=${Uri.encodeQueryComponent(_headword.text.trim())}',
                  ),
                  // Files it under the main word and keeps what was typed
                  // as one of its spellings, so it's still found by it.
                  onUseMainSpelling: () {
                    final typed = _headword.text.trim();
                    final spellings = _split(_spellings.text);
                    if (!spellings.contains(typed)) _spellings.text = [...spellings, typed].join(', ');
                    _headword.text = _mainSpelling!;
                    _onHeadwordChanged(_mainSpelling!);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _sayItLike,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Say it like',
                    hintText: 'e.g. guy-at — the pronounce button reads this',
                    border: OutlineInputBorder(),
                  ),
                ),

                const _Header('Meanings'),
                for (final (i, m) in _meanings.indexed)
                  _MeaningCard(
                    key: ObjectKey(m),
                    draft: m,
                    number: i + 1,
                    onChanged: () => setState(() {}),
                    onRemove: _meanings.length == 1 && m.isEmpty
                        ? null
                        : () => setState(() {
                              _meanings.remove(m);
                              m.dispose();
                              if (_meanings.isEmpty) _meanings.add(_MeaningDraft());
                            }),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Another meaning'),
                    onPressed: () => setState(() => _meanings.add(_MeaningDraft())),
                  ),
                ),

                const _Header('Where it lives'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _region,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Where',
                          hintText: 'UK, Toronto…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _scene,
                        decoration: const InputDecoration(
                          labelText: 'Who says it',
                          hintText: 'gamers, Gen Z…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('How fresh is it?', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final f in SlangFreshness.values)
                      ChoiceChip(
                        label: Text(f.label),
                        selected: _freshness == f,
                        onSelected: (on) => setState(() => _freshness = on ? f : null),
                      ),
                  ],
                ),

                const _Header('Other spellings and forms'),
                TextField(
                  controller: _spellings,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Also written',
                    hintText: 'comma-separated, e.g. fina, fixna',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _forms,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Forms',
                    hintText: 'comma-separated, e.g. rizzed, rizzing',
                    helperText: 'Looking up or reading any of these finds this word.',
                    border: OutlineInputBorder(),
                  ),
                ),

                const _Header('Backstory'),
                TextField(
                  controller: _heardAt,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Where you heard it',
                    hintText: 'a person, a show, a link',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _origin,
                  minLines: 2,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Origin',
                    hintText: 'Where it came from, as far as you know',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  final String label;

  const _Header(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 10),
      child: Text(
        label,
        style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final _Status status;
  final String headword;
  final int dictionarySenses;
  final String? mainSpelling;
  final VoidCallback onEditExisting;
  final VoidCallback onUseMainSpelling;

  const _StatusLine({
    required this.status,
    required this.headword,
    required this.dictionarySenses,
    required this.mainSpelling,
    required this.onEditExisting,
    required this.onUseMainSpelling,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    if (headword.isEmpty || status == _Status.checking) return const SizedBox(height: 24);
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: switch (status) {
        _Status.inDictionary => Text(
            'The dictionary has "$headword" with $dictionarySenses '
            '${dictionarySenses == 1 ? 'meaning' : 'meanings'}. Yours go on the same card, '
            'first — and you can save it with no meaning of your own just to keep its details.',
            style: style,
          ),
        _Status.spellingOf => Row(
            children: [
              Expanded(
                child: Text(
                  '"$headword" is a spelling of "$mainSpelling", so it opens that card. '
                  'Add yours there — "$headword" will be kept as one of its spellings.',
                  style: style,
                ),
              ),
              TextButton(onPressed: onUseMainSpelling, child: Text('Use $mainSpelling')),
            ],
          ),
        _Status.alreadyInStack => Row(
            children: [
              Expanded(child: Text('"$headword" is already in your Slang Stack.', style: style)),
              TextButton(onPressed: onEditExisting, child: const Text('Edit it')),
            ],
          ),
        _ => Text('New to the dictionary — this will be its only card.', style: style),
      },
    );
  }
}

class _MeaningCard extends StatelessWidget {
  final _MeaningDraft draft;
  final int number;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  const _MeaningCard({
    super.key,
    required this.draft,
    required this.number,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('$number.', style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final pos in slangPartsOfSpeech)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(pos),
                              visualDensity: VisualDensity.compact,
                              selected: draft.pos == pos,
                              onSelected: (_) {
                                draft.pos = pos;
                                onChanged();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Remove this meaning',
                    onPressed: onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: draft.gloss,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => onChanged(),
              decoration: const InputDecoration(labelText: 'What it means', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: draft.plainEnglish,
              decoration: const InputDecoration(
                labelText: 'In plain English',
                hintText: 'the everyday word for it, e.g. charisma',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: draft.examples,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Examples',
                hintText: 'one sentence per line, using the word',
                helperText: 'Study games quiz you on these.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Tone', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 4),
                for (final tone in SlangTone.values)
                  Tooltip(
                    message: tone.description,
                    child: ChoiceChip(
                      label: Text(tone.label),
                      visualDensity: VisualDensity.compact,
                      selected: draft.tone == tone,
                      selectedColor: tone.isWarning ? scheme.errorContainer : null,
                      onSelected: (on) {
                        draft.tone = on ? tone : null;
                        onChanged();
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
