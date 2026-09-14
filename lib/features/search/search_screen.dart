import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/entry.dart';
import '../../widgets/entry_card.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  /// Search is live, so a query only exists as a thing worth remembering
  /// once typing has stopped on it: "ser", "seren", "serendipity" is one
  /// search, not three. Results settling for this long, or a result being
  /// opened, is what writes it to history.
  Timer? _settle;
  static const _settleAfter = Duration(milliseconds: 1500);

  List<EntrySummary> _results = const [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _settle?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    _settle?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _loading = true);
    final results = await ref.read(searchRepositoryProvider).searchOrResolve(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
    // A query with no matches is a typo, not a search.
    if (results.isNotEmpty) {
      _settle?.cancel();
      _settle = Timer(_settleAfter, () => _rememberQuery(query));
    }
  }

  void _rememberQuery(String query) {
    if (_controller.text.trim() != query.trim()) return;
    ref.read(progressRepositoryProvider).logSearch(query);
  }

  /// Opening a result is the one path that counts as looking a word up —
  /// the search brought it here, they chose it. Browsing to the same word
  /// from a list or the reader logs nothing. The entry screen writes the
  /// lookup itself once it knows the word's canonical id.
  void _open(EntrySummary entry) {
    _settle?.cancel();
    ref.read(progressRepositoryProvider).logSearch(_controller.text);
    context.push('/entry/${Uri.encodeComponent(entry.headword)}?from=search');
  }

  void _rerun(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    setState(() {});
    _runSearch(query);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Word Wizard'),
        centerTitle: false,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: false,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search a word…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                        },
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) {
                setState(() {}); // refresh the clear-button visibility
                _onChanged(v);
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _results.isEmpty
                ? _controller.text.trim().isNotEmpty
                    ? const _EmptyState(hasQuery: true)
                    : _RecentSearches(onPick: _rerun)
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (context, i) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = _results[i];
                      return EntryCard(entry: e, onTap: () => _open(e));
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasQuery;

  const _EmptyState({required this.hasQuery});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          hasQuery ? 'No matches.' : 'Look up a word to get started.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// What was searched before, shown while the field is empty. Tapping one
/// re-runs it; the swipe and the clear action are there because a search
/// history nobody can edit is a small embarrassment waiting to happen.
class _RecentSearches extends ConsumerWidget {
  final ValueChanged<String> onPick;

  const _RecentSearches({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentSearchesProvider).valueOrNull ?? const <String>[];
    if (recent.isEmpty) return const _EmptyState(hasQuery: false);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text('Recent', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              TextButton(
                onPressed: () => ref.read(progressRepositoryProvider).clearSearches(),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        for (final query in recent)
          Dismissible(
            key: ValueKey('recent-$query'),
            direction: DismissDirection.endToStart,
            onDismissed: (_) => ref.read(progressRepositoryProvider).removeSearch(query),
            background: Container(
              color: scheme.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.history, size: 20, color: scheme.onSurfaceVariant),
              title: Text(query),
              onTap: () => onPick(query),
            ),
          ),
      ],
    );
  }
}
