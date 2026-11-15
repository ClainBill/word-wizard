import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/slang.dart';
import '../../widgets/pos_tag.dart';
import 'slang_chips.dart';

/// Every word in the Slang Stack, newest first, with a filter for when it
/// grows past a screenful. Tapping one opens its card, where it's studied
/// and listed like any other word; + adds a new one.
class SlangStackScreen extends ConsumerStatefulWidget {
  const SlangStackScreen({super.key});

  @override
  ConsumerState<SlangStackScreen> createState() => _SlangStackScreenState();
}

class _SlangStackScreenState extends ConsumerState<SlangStackScreen> {
  final _filter = TextEditingController();
  SlangFreshness? _freshness;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _matches(SlangWord w) {
    if (_freshness != null && w.freshness != _freshness) return false;
    final q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      w.headword,
      ...w.spellings,
      w.region,
      w.scene,
      for (final s in w.senses) ...[s.gloss, s.plainEnglish],
    ].any((field) => field != null && field.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final stackAsync = ref.watch(slangStackProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Slang Stack')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/slang/edit'),
        icon: const Icon(Icons.add),
        label: const Text('Add slang'),
      ),
      body: stackAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load your Slang Stack: $e')),
        data: (stack) {
          if (stack.isEmpty) return const _EmptyStack();
          final shown = stack.where(_matches).toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (stack.length > 6) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _filter,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Filter by word, meaning, place…',
                      prefixIcon: const Icon(Icons.filter_list),
                      filled: true,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      for (final f in SlangFreshness.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text(f.label),
                            selected: _freshness == f,
                            onSelected: (on) => setState(() => _freshness = on ? f : null),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Nothing matches.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              for (final word in shown) ...[
                _SlangTile(word: word),
                const Divider(height: 1),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SlangTile extends StatelessWidget {
  final SlangWord word;

  const _SlangTile({required this.word});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = word.senses.firstOrNull;
    return ListTile(
      onTap: () => context.push('/entry/${Uri.encodeComponent(word.headword)}'),
      title: Row(
        children: [
          Flexible(
            child: Text(word.headword, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
          ),
          if (first != null) ...[const SizedBox(width: 8), PosTag(first.pos)],
          if (word.hasWarning) ...[
            const SizedBox(width: 6),
            Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            first?.gloss ?? 'Kept for its details — the dictionary has its meanings.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: first == null ? const TextStyle(fontStyle: FontStyle.italic) : null,
          ),
          SlangChips(word: word, compact: true),
        ],
      ),
    );
  }
}

class _EmptyStack extends StatelessWidget {
  const _EmptyStack();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_outlined, size: 48, color: scheme.primary),
            const SizedBox(height: 12),
            Text('Your Slang Stack is empty', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add words the dictionary doesn\'t have yet — or meanings it doesn\'t know. '
              'They get a card like any other word: study them, list them, find them in the reader.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
