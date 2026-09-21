import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/board/word_board.dart' show isBoardable;
import '../../domain/models/entry.dart';
import '../../widgets/entry_card.dart';
import '../../widgets/pos_tag.dart';
import 'word_board_view.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  /// Search is live, so a query only exists as a thing worth remembering
  /// once typing has stopped on it: "ser", "seren", "serendipity" is one
  /// search, not three. Results settling for this long, or a result being
  /// opened, is what writes it to history.
  Timer? _settle;
  static const _settleAfter = Duration(milliseconds: 1500);

  List<EntrySummary> _results = const [];
  bool _loading = false;

  /// Which search is the current one. Searches overlap when typing is
  /// quick — "can" can come back after "candor" — and only the latest
  /// may set the results.
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _settle?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _keyboardUp = false;

  /// Android's back closes the keyboard but leaves the field focused, which
  /// would leave the recents up with no way back to the board. Closing the
  /// keyboard on an empty field means "never mind" — so drop the focus too.
  @override
  void didChangeMetrics() {
    final up = View.of(context).viewInsets.bottom > 0;
    if (_keyboardUp && !up && _focus.hasFocus && _controller.text.trim().isEmpty) {
      _focus.unfocus();
    }
    _keyboardUp = up;
  }

  /// The board is what the tab lands on: it stays until the field is
  /// tapped, and comes back when the field is left empty.
  bool get _showBoard => !_focus.hasFocus && _controller.text.trim().isEmpty;

  void _onChanged(String query) {
    _debounce?.cancel();
    _settle?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    final seq = ++_searchSeq;
    if (query.trim().isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final results = await ref.read(searchRepositoryProvider).searchOrResolve(query);
    if (!mounted || seq != _searchSeq) return;
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

  /// A tile on the board. Counts as a lookup (they chose the word), but
  /// isn't a search, so it doesn't go in the search history.
  void _openFromBoard(String headword) {
    context.push('/entry/${Uri.encodeComponent(headword)}?from=board');
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
              focusNode: _focus,
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
            child: _showBoard
                ? _LandingBoard(onOpen: _openFromBoard)
                : _results.isEmpty
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

/// The word board with its data: the word of the day in the middle, a
/// fresh draw of words around it, and the Lexery deciding the colours.
class _LandingBoard extends ConsumerWidget {
  final ValueChanged<String> onOpen;

  const _LandingBoard({required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final wotdAsync = ref.watch(wordOfTheDayProvider(today));
    final wotd = wotdAsync.valueOrNull;
    final words = ref.watch(boardWordsProvider);
    final familiarity = ref.watch(familiarityProvider).valueOrNull ?? const {};

    // Wait for the seed as well as the pool: a board that restarts when the
    // word of the day arrives a moment later would flash.
    if (wotdAsync.isLoading) return const Center(child: CircularProgressIndicator());
    return words.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => const _EmptyState(hasQuery: false),
      data: (pool) {
        final daily = wotd?.headword.toLowerCase();
        final seed = daily != null && isBoardable(daily)
            ? daily
            : pool.firstWhere(isBoardable, orElse: () => 'wizard');
        return WordBoardView(
          seed: seed,
          seedCaption: seed == daily ? 'Word of the day' : null,
          words: pool,
          familiarity: familiarity,
          onOpen: onOpen,
          onShuffle: () => ref.invalidate(boardWordsProvider),
        );
      },
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

/// Today's featured word, on the Search tab above the recent searches.
/// Tap it for the card; the button underneath goes to the Games tab, where
/// the day's puzzles are.
class _WordOfTheDayCard extends ConsumerWidget {
  const _WordOfTheDayCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final word = ref.watch(wordOfTheDayProvider(today)).valueOrNull;
    if (word == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/entry/${Uri.encodeComponent(word.headword)}?from=search'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.wb_sunny_outlined, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'WORD OF THE DAY',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(child: Text(word.headword, style: theme.textTheme.headlineSmall)),
                    const SizedBox(width: 8),
                    PosTag(word.pos),
                  ],
                ),
                const SizedBox(height: 6),
                Text(word.gloss, maxLines: 3, overflow: TextOverflow.ellipsis),
                if (word.example != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    word.example!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => ref.read(ttsProvider).speak(word.headword),
                      icon: const Icon(Icons.volume_up_outlined, size: 18),
                      label: const Text('Say it'),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => context.go('/games'),
                      icon: const Icon(Icons.extension_outlined, size: 18),
                      label: const Text('Today\'s puzzles'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What was searched before, shown while the field is focused and empty,
/// under the word of the day. Tapping one re-runs it; the swipe and the clear action
/// are there because a search history nobody can edit is a small
/// embarrassment waiting to happen.
class _RecentSearches extends ConsumerWidget {
  final ValueChanged<String> onPick;

  const _RecentSearches({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentSearchesProvider).valueOrNull ?? const <String>[];
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      children: [
        const _WordOfTheDayCard(),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: _EmptyState(hasQuery: false),
          ),
        if (recent.isNotEmpty)
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
