import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/study_card.dart';
import '../../domain/models/study_direction.dart';
import '../../data/repositories/study_repository.dart' show StudyRepository;
import '../../domain/srs/sm2.dart';
import '../../widgets/ipa_label.dart';
import '../../widgets/pos_tag.dart';
import '../../widgets/tappable_word_text.dart';
import '../../widgets/word_detail_sheet.dart';
import '../premium/paywall_screen.dart';
import '../premium/premium_prompt.dart';
import 'card_motion.dart';
import 'recall_games.dart';
import 'study_options_sheet.dart';
import 'study_recap.dart';

// autoDispose, so the queue is re-read every time a session screen opens:
// a cached queue would re-serve cards graded in an earlier, early-ended
// session, and would deal every session the same random senses.
final _dueQueueProvider = FutureProvider.autoDispose.family<List<StudyCard>, int?>(
  (ref, listId) => ref
      .watch(studyRepositoryProvider)
      .dueQueue(directions: ref.watch(studyDirectionsProvider), listId: listId),
);

class StudySessionScreen extends ConsumerStatefulWidget {
  final int? listId;

  const StudySessionScreen({super.key, this.listId});

  @override
  ConsumerState<StudySessionScreen> createState() => _StudySessionScreenState();
}

/// Where a card currently sits in the flip sequence:
/// front (the prompt side only) -> back (everything revealed, grade
/// buttons shown), with an optional game stage in between — a recall jog
/// for whichever side you were being asked for — that only a left swipe on
/// the front goes through. A tap or a right swipe turns the card straight
/// over.
enum _Stage { front, game, back }

class _StudySessionScreenState extends ConsumerState<StudySessionScreen> {
  int _index = 0;
  _Stage _stage = _Stage.front;
  List<StudyCard>? _queue;
  final List<StudyCard> _missed = [];
  final List<SessionReview> _reviews = [];

  Map<Grade, int> get _grades {
    final tally = <Grade, int>{};
    for (final r in _reviews) {
      tally[r.grade] = (tally[r.grade] ?? 0) + 1;
    }
    return tally;
  }

  bool _missedRoundDone = false;

  /// Which way the last graded card should leave: right when it was swiped
  /// right (Good), left otherwise.
  bool _exitToRight = false;

  /// Set when the user backs out with cards still in the queue: the recap
  /// is shown in place of the session, and "Keep going" clears it again.
  bool _ended = false;

  /// Whether the last grade can still be taken back: true right after a
  /// grade, false once the queue has been reshaped underneath it (a word
  /// mastered or removed), since then `_index - 1` is no longer that card.
  bool _canUndo = false;

  /// Takes back the most recent grade: the card's SM-2 state is restored,
  /// its review row deleted, and the card comes back on screen turned
  /// over, ready to be graded again.
  Future<void> _undo() async {
    if (!_canUndo || _reviews.isEmpty) return;
    final last = _reviews.last;
    await ref.read(studyRepositoryProvider).ungrade(last.card);
    ref.invalidate(dueCountProvider);
    if (!mounted) return;
    setState(() {
      _reviews.removeLast();
      if (last.grade == Grade.again) {
        final i = _missed.lastIndexOf(last.card);
        if (i >= 0) _missed.removeAt(i);
      }
      _index -= 1;
      _stage = _Stage.back;
      _exitToRight = false;
      _ended = false;
      _missedRoundDone = false;
      _cardShownAt = DateTime.now();
      _canUndo = _reviews.isNotEmpty;
    });
  }

  final DateTime _startedAt = DateTime.now();
  DateTime? _lastGradedAt;

  /// When the card now on screen was first shown — what its review's
  /// logged duration is measured from. Reset on every advance and on
  /// resuming from the recap, since the card wasn't being looked at while
  /// the recap was up.
  DateTime _cardShownAt = DateTime.now();

  Duration get _elapsed => (_lastGradedAt ?? _startedAt).difference(_startedAt);

  /// Leaves the session, then — a finished review being a fair moment
  /// (spec §5.3), never before or between cards — offers Premium if the
  /// policy allows.
  ///
  /// Free accounts see an interstitial here first — the one place the app
  /// plays one — and then no Premium prompt on top of it: one monetisation
  /// surface per moment (spec §5.4).
  Future<void> _finish(BuildContext context) async {
    final root = Navigator.of(context, rootNavigator: true).context;
    final adShown = await ref.read(adsServiceProvider).showInterstitial(placement: 'review_end');
    if (!context.mounted) return;
    context.pop();
    if (adShown) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (root.mounted) maybeShowPremiumPrompt(root, trigger: 'review_complete');
    });
  }

  @override
  Widget build(BuildContext context) {
    final queueAsync = ref.watch(_dueQueueProvider(widget.listId));
    final cards = _queue;
    final finished = cards != null && cards.isNotEmpty && _index >= cards.length;
    final inMissedRound = finished && _missed.length >= 2 && !_missedRoundDone;
    final showingRecap = (finished && !inMissedRound) || _ended;

    return PopScope(
      // Leaving mid-session with something graded goes through the recap
      // first, so the grades just given don't vanish without a word; back
      // from the missed-words round skips the round, not the recap. With
      // nothing graded yet — or from the recap itself — back just leaves.
      canPop: showingRecap || _reviews.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (inMissedRound) {
            _missedRoundDone = true;
          } else {
            _ended = true;
          }
        });
      },
      child: Scaffold(
        appBar: AppBar(title: Text(showingRecap ? 'Session recap' : 'Study session')),
        body: queueAsync.when(
          data: (queue) {
            _queue ??= queue;
            final cards = _queue!;
            // Empty from the start: nothing due. Emptied mid-session (the
            // last card mastered or removed): the recap of what was done.
            if (cards.isEmpty && _reviews.isEmpty) return const _NothingDue();
            // The recall games — the jog before the answer, the exercise on
            // the back, the round on missed words — are Premium. Free
            // accounts get the plain flip card.
            final premium = ref.watch(isPremiumProvider);
            if (_index >= cards.length) {
              if (premium && _missed.length >= 2 && !_missedRoundDone) {
                return _MissedWordsRound(
                  cards: _missed,
                  onDone: () => setState(() => _missedRoundDone = true),
                );
              }
              return StudyRecap(
                reviews: _reviews,
                remaining: 0,
                elapsed: _elapsed,
                onDone: () => _finish(context),
                onUndo: _canUndo && _reviews.isNotEmpty ? _undo : null,
              );
            }
            if (_ended) {
              return StudyRecap(
                reviews: _reviews,
                remaining: cards.length - _index,
                elapsed: _elapsed,
                onDone: () => _finish(context),
                onUndo: _canUndo && _reviews.isNotEmpty ? _undo : null,
                onResume: () => setState(() {
                  _ended = false;
                  _cardShownAt = DateTime.now();
                }),
              );
            }
            return _CardView(
              card: cards[_index],
              index: _index,
              total: cards.length,
              stage: _stage,
              onOpenOptions: () => showStudyOptionsSheet(
                context,
                progress: (done: _index, total: cards.length, grades: _grades),
              ),
              premium: premium,
              onUndo: _canUndo && _reviews.isNotEmpty ? _undo : null,
              onKnewIt: () => setState(() => _stage = _Stage.back),
              onDidntKnowIt: () => setState(() => _stage = premium ? _Stage.game : _Stage.back),
              onGameDone: () => setState(() => _stage = _Stage.back),
              exitToRight: _exitToRight,
              onGrade: (grade, {bool toRight = false}) async {
                final card = cards[_index];
                if (grade == Grade.again) _missed.add(card);
                final now = DateTime.now();
                final update = await ref
                    .read(studyRepositoryProvider)
                    .grade(card, grade, spent: now.difference(_cardShownAt));
                ref.invalidate(dueCountProvider);
                setState(() {
                  _reviews.add((card: card, grade: grade, update: update));
                  _lastGradedAt = now;
                  _cardShownAt = now;
                  _exitToRight = toRight;
                  _index += 1;
                  _stage = _Stage.front;
                  _canUndo = true;
                });
              },
              onMaster: () async {
                final card = cards[_index];
                final repo = ref.read(studyRepositoryProvider);
                final messenger = ScaffoldMessenger.of(context);
                await repo.masterEntry(card.entryId);
                ref.invalidate(dueCountProvider);
                ref.invalidate(studyStatsProvider);
                if (!context.mounted) return;
                // Both directions are mastered together, so both leave
                // the queue.
                final rest = cards.where((c) => c.entryId != card.entryId).toList();
                _canUndo = false;
                if (rest.length <= _index) {
                  // That was the last card: back to the Study tab (or the
                  // recap, if anything was graded first) rather than an
                  // empty session.
                  if (_reviews.isEmpty) {
                    context.pop();
                  } else {
                    setState(() {
                      _queue = rest;
                      _ended = true;
                    });
                  }
                } else {
                  setState(() {
                    _queue = rest;
                    _stage = _Stage.front;
                    _cardShownAt = DateTime.now();
                  });
                }
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      '"${card.headword}" marked as mastered — it comes back for a check in '
                      '${StudyRepository.masteredIntervalDays ~/ 30} months.',
                    ),
                  ),
                );
              },
              onRemove: () async {
                final card = cards[_index];
                final confirmed =
                    await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('Remove "${card.headword}" from study?'),
                        content: const Text(
                          'This deletes its review history — in both directions, if you study it '
                          'both ways — and takes it out of the SRS pool. It stays in any lists it '
                          'belongs to and can be added back to study later.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.error,
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirmed) return;
                await ref.read(studyRepositoryProvider).removeEntry(card.entryId);
                ref.invalidate(dueCountProvider);
                setState(() {
                  // Every direction of the word goes, so drop them all from the
                  // queue rather than only the card being looked at — otherwise
                  // its sibling turns up later pointing at a row that no longer
                  // exists.
                  _queue = cards.where((c) => c.entryId != card.entryId).toList();
                  _stage = _Stage.front;
                  _canUndo = false;
                });
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Couldn\'t load session: $e')),
        ),
      ),
    );
  }
}

class _CardView extends StatelessWidget {
  final StudyCard card;
  final int index;
  final int total;
  final _Stage stage;

  /// Whether the recall games are on (Premium).
  final bool premium;
  final VoidCallback onOpenOptions;
  final VoidCallback onKnewIt;
  final VoidCallback onDidntKnowIt;
  final VoidCallback onGameDone;
  final void Function(Grade grade, {bool toRight}) onGrade;
  final VoidCallback onRemove;

  /// "I've mastered this": the word leaves the queue on a long interval.
  final VoidCallback onMaster;

  /// Takes back the previous card's grade; null when there's none to take.
  final VoidCallback? onUndo;
  final bool exitToRight;

  const _CardView({
    required this.card,
    required this.index,
    required this.total,
    required this.stage,
    required this.premium,
    this.onUndo,
    required this.onOpenOptions,
    required this.onKnewIt,
    required this.onDidntKnowIt,
    required this.onGameDone,
    required this.onGrade,
    required this.onRemove,
    required this.onMaster,
    required this.exitToRight,
  });

  /// Which side of the card the user is being asked to produce — and so
  /// which family of recall games can actually help them. This is the whole
  /// point of the direction setting: on a word → meaning card the word is
  /// already on screen, so a game that makes you spell it teaches nothing.
  RecallTarget get _asked => switch (card.direction) {
    StudyDirection.wordToMeaning => RecallTarget.meaning,
    StudyDirection.meaningToWord => RecallTarget.word,
  };

  /// The other side. Exercised *after* the reveal, so every review touches
  /// both halves of the word once — the half you were graded on, and the
  /// half you weren't.
  RecallTarget get _notAsked => _asked == RecallTarget.meaning ? RecallTarget.word : RecallTarget.meaning;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SessionHeader(
          index: index,
          total: total,
          direction: card.direction,
          onOpenOptions: onOpenOptions,
          onRemove: onRemove,
          onMaster: onMaster,
          onUndo: onUndo,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: CardDeck(
              exitToRight: exitToRight,
              child: KeyedSubtree(
                key: ValueKey(card.cardId),
                child: SwipeableCard(
                  // Only the back swipes: by then you've seen the answer,
                  // so a swipe is a verdict. Right is "knew it", left is
                  // "didn't" — the two grades that cover most reviews; the
                  // buttons stay for Hard and Easy.
                  enabled: stage == _Stage.back,
                  rightLabel: 'Good',
                  leftLabel: 'Again',
                  rightColor: Colors.green,
                  leftColor: Colors.red,
                  onSwipeRight: () => onGrade(Grade.good, toRight: true),
                  onSwipeLeft: () => onGrade(Grade.again),
                  child: FlipCard(
                    showBack: stage == _Stage.back,
                    front: _CardFace(
                      onTap: stage == _Stage.front ? onKnewIt : null,
                      onPullUp: stage == _Stage.front ? onDidntKnowIt : null,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // The prompt side stays put through the game
                          // stage — it is the question, not part of the
                          // answer. Only the back opens up into everything.
                          _PromptSide(card: card),
                          const SizedBox(height: 20),
                          // The game rises from below the prompt on a swipe
                          // up, the way it was asked for.
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 340),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, anim) => FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(anim),
                                child: child,
                              ),
                            ),
                            child: stage == _Stage.game
                                ? RecallGamePanel(
                                    key: ValueKey('jog-${card.cardId}'),
                                    card: card,
                                    target: _asked,
                                    onDone: onGameDone,
                                  )
                                : _FrontHint(
                                    key: const ValueKey('hint'),
                                    direction: card.direction,
                                    games: premium,
                                  ),
                          ),
                        ],
                      ),
                    ),
                    // No pull-up on the back: a flick that starts on the
                    // game panel looks exactly like one, and opening the
                    // full card when someone meant to scroll is worse than
                    // making them tap for it.
                    back: _CardFace(
                      onTap: () => showWordDetailSheet(context, card.headword),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RevealedCard(card: card),
                          const SizedBox(height: 20),
                          Text(
                            'Swipe right if you knew it, left if you didn\'t · tap for the full card',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (premium)
                            RecallGamePanel(
                              key: ValueKey('exercise-${card.cardId}'),
                              card: card,
                              target: _notAsked,
                              onDone: () {},
                              showSkip: false,
                              dense: true,
                            )
                          else
                            const _RecallGamesLocked(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (stage == _Stage.back)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    _GradeButton(label: 'Again', color: Colors.red, onTap: () => onGrade(Grade.again)),
                    _GradeButton(label: 'Hard', color: Colors.orange, onTap: () => onGrade(Grade.hard)),
                    _GradeButton(label: 'Good', color: Colors.green, onTap: () => onGrade(Grade.good)),
                    _GradeButton(label: 'Easy', color: Colors.teal, onTap: () => onGrade(Grade.easy)),
                  ],
                ),
                // Beyond Easy: the word is known cold and needn't keep
                // coming round. Rare, so quiet — a text button, not a fifth grade.
                TextButton.icon(
                  onPressed: onMaster,
                  icon: const Icon(Icons.verified_outlined, size: 18),
                  label: const Text('I\'ve mastered this word'),
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 88),
      ],
    );
  }
}

/// One side of the card. Just a faded outline on the same background as
/// everything else — enough for the flip and the swipe to read as a card
/// turning and moving, without a second surface colour. The content
/// scrolls inside when the back runs long.
///
/// [onPullUp] is a swipe up on the face. It fires either from a plain
/// upward drag — which the inner scroll view leaves alone when its content
/// fits — or, when the content does scroll, from dragging on past the end.
/// Only the front uses it; on the back, where the content scrolls and the
/// game panel is under the thumb, either path is indistinguishable from an
/// attempt to scroll.
class _CardFace extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onPullUp;

  const _CardFace({required this.child, this.onTap, this.onPullUp});

  @override
  State<_CardFace> createState() => _CardFaceState();
}

class _CardFaceState extends State<_CardFace> {
  static const _pullDistance = 40.0;

  double _overscroll = 0;
  bool _pulled = false;

  void _pull() {
    if (_pulled) return;
    _pulled = true;
    HapticFeedback.selectionClick();
    widget.onPullUp?.call();
  }

  bool _onScroll(ScrollNotification n) {
    if (widget.onPullUp == null) return false;
    if (n is ScrollStartNotification) {
      _overscroll = 0;
      _pulled = false;
    } else if (n is OverscrollNotification && n.overscroll > 0) {
      _overscroll += n.overscroll;
      if (_overscroll > _pullDistance) _pull();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: widget.onTap,
      onVerticalDragEnd: widget.onPullUp == null
          ? null
          : (details) {
              _pulled = false;
              if ((details.primaryVelocity ?? 0) < -250) _pull();
            },
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          // Opaque in the page's own colour, so two cards overlapping
          // mid-transition don't show through each other.
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              // Clamping, so a drag past the end surfaces as an overscroll
              // notification rather than a bounce — that's the pull-up.
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 52),
                child: Center(child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Counter, direction badge, undo, ⋮ menu, and the progress bar — which is also
/// the way into the study options sheet, since a progress bar is exactly
/// where you look when you want to know how much is left and how it's being
/// scheduled.
class _SessionHeader extends StatelessWidget {
  final int index;
  final int total;
  final StudyDirection direction;
  final VoidCallback onOpenOptions;
  final VoidCallback onRemove;
  final VoidCallback onMaster;
  final VoidCallback? onUndo;

  const _SessionHeader({
    required this.index,
    required this.total,
    required this.direction,
    required this.onOpenOptions,
    required this.onRemove,
    required this.onMaster,
    this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              Text('${index + 1} / $total', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(direction.label, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
              ),
              const Spacer(),
              // Always drawn, greyed when there's nothing to take back, so
              // it's in the same place every time a thumb reaches for it.
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo last grade',
                onPressed: onUndo,
              ),
              PopupMenuButton<void>(
                icon: const Icon(Icons.more_vert),
                tooltip: 'More',
                itemBuilder: (context) => [
                  PopupMenuItem(
                    onTap: onOpenOptions,
                    child: const Row(
                      children: [Icon(Icons.tune, size: 18), SizedBox(width: 8), Text('Study options')],
                    ),
                  ),
                  PopupMenuItem(
                    onTap: onMaster,
                    child: const Row(
                      children: [
                        Icon(Icons.verified_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Mark as mastered'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    onTap: onRemove,
                    child: const Row(
                      children: [
                        Icon(Icons.delete_outline, size: 18),
                        SizedBox(width: 8),
                        Text('Remove from study'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 2),
          Tooltip(
            message: 'Study options',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onOpenOptions,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 6, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: total == 0 ? 0 : index / total, minHeight: 6),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.tune, size: 14, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The question side of the card — the word for a word → meaning card, the
/// meaning for a meaning → word card. Stays on screen unchanged through the
/// ask and game stages.
class _PromptSide extends StatelessWidget {
  final StudyCard card;

  const _PromptSide({required this.card});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (card.direction == StudyDirection.wordToMeaning) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(card.headword, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          IpaLabel(card.ipa),
          const SizedBox(height: 8),
          _PosTags(card: card),
        ],
      );
    }

    // Meaning → word. The pronunciation is deliberately withheld: an IPA
    // transcription of a word you're being asked to produce is the answer
    // spelled out phonetically.
    final letters = card.headword.replaceAll(RegExp('[^A-Za-z]'), '').length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PosTags(card: card),
        const SizedBox(height: 12),
        if (card.senses.length > 1)
          _SenseList(card: card, showExamples: false, style: theme.textTheme.titleMedium)
        else
          Text(
            card.gloss ?? 'No definition stored for this word.',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(height: 1.4),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < letters.clamp(0, 14); i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                width: 8,
                height: 2,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            if (letters > 14)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text('…', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text('$letters letters', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

/// Everything, once the card is turned over — the same content whichever
/// direction was asked, because after the grade there is no reason to keep
/// half a word hidden.
class _RevealedCard extends StatelessWidget {
  final StudyCard card;

  const _RevealedCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(card.headword, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        IpaLabel(card.ipa),
        const SizedBox(height: 8),
        _PosTags(card: card),
        const SizedBox(height: 20),
        if (card.senses.length > 1)
          _SenseList(card: card, showExamples: true)
        else ...[
          if (card.gloss != null) TappableWordText(card.gloss!, textAlign: TextAlign.center),
          if (card.example != null) ...[
            const SizedBox(height: 8),
            TappableWordText(
              '"${card.example}"',
              textAlign: TextAlign.center,
              style: TextStyle(fontStyle: FontStyle.italic, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
        if (card.note != null && card.note!.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          Divider(color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 8),
          MarkdownBody(data: card.note!, shrinkWrap: true),
        ],
      ],
    );
  }
}

/// The part(s) of speech of what this card is actually testing — the dealt
/// or pinned senses' POS, not the canonical entry's. A "muse" card dealt
/// the verb sense says "verb"; one dealt a noun and a verb says both.
class _PosTags extends StatelessWidget {
  final StudyCard card;

  const _PosTags({required this.card});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      alignment: WrapAlignment.center,
      children: [for (final pos in card.posTags) PosTag(pos)],
    );
  }
}

/// The meanings this card carries, numbered, when there is more than one.
/// When they span parts of speech each line carries its own POS tag so
/// "muse — to ponder" doesn't read as a noun. Examples are left off the
/// meaning → word prompt, where they would spell out the answer.
class _SenseList extends StatelessWidget {
  final StudyCard card;
  final bool showExamples;
  final TextStyle? style;

  const _SenseList({required this.card, required this.showExamples, this.style});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < card.senses.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == card.senses.length - 1 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}.', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (card.posTags.length > 1)
                        Padding(padding: const EdgeInsets.only(bottom: 4), child: PosTag(card.senses[i].pos)),
                      TappableWordText(card.senses[i].gloss, style: style),
                      if (showExamples && card.senses[i].example != null) ...[
                        const SizedBox(height: 4),
                        TappableWordText(
                          '"${card.senses[i].example}"',
                          style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FrontHint extends StatelessWidget {
  final StudyDirection direction;

  /// Whether swiping up leads to a recall game (Premium) or just turns
  /// the card.
  final bool games;

  const _FrontHint({super.key, required this.direction, required this.games});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          direction == StudyDirection.wordToMeaning
              ? 'What does it mean? Tap to turn the card over.'
              : 'What word is it? Tap to turn the card over.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        if (games) ...[
          const SizedBox(height: 6),
          Text(
            'Swipe up to jog your memory first',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
        ],
      ],
    );
  }
}

/// What a free account sees where the back-of-card exercise would be: a
/// line about the recall games, and the way to them.
class _RecallGamesLocked extends StatelessWidget {
  const _RecallGamesLocked();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recall games are Premium: a quick exercise on each card, a memory jog '
                  'before the answer, and a round on the words you missed.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => showPaywall(context, source: 'study_recall_games'),
              child: const Text('See Premium'),
            ),
          ),
        ],
      ),
    );
  }
}

class _GradeButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _GradeButton({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.6)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

/// A session-end matching round pairing every word marked "Again" this
/// session against its definition — same mechanic as Quizlet's "Match"
/// mode. Only shown when there's more than one miss; capped at
/// [_maxPairs] so it stays a 20-30s round instead of growing with the
/// session.
class _MissedWordsRound extends StatefulWidget {
  final List<StudyCard> cards;
  final VoidCallback onDone;

  const _MissedWordsRound({required this.cards, required this.onDone});

  @override
  State<_MissedWordsRound> createState() => _MissedWordsRoundState();
}

class _MissedWordsRoundState extends State<_MissedWordsRound> {
  static const _maxPairs = 6;

  late final List<StudyCard> _pairs;
  late final List<StudyCard> _wordOrder;
  late final List<StudyCard> _glossOrder;
  final Set<int> _matched = {};
  int? _selectedWordId;
  int? _selectedGlossId;
  int? _wrongFlashWordId;
  int? _wrongFlashGlossId;

  @override
  void initState() {
    super.initState();
    // Deduped by entry: a word missed in both directions is one word to
    // re-pair, not two identical tiles.
    final seen = <int>{};
    final withGloss =
        widget.cards
            .where((c) => c.gloss != null && c.gloss!.trim().isNotEmpty && seen.add(c.entryId))
            .toList()
          ..shuffle();
    _pairs = withGloss.take(_maxPairs).toList();
    _wordOrder = List.of(_pairs)..shuffle();
    _glossOrder = List.of(_pairs)..shuffle();
  }

  void _tryMatch() {
    if (_selectedWordId == null || _selectedGlossId == null) return;
    if (_selectedWordId == _selectedGlossId) {
      final matchedId = _selectedWordId!;
      setState(() {
        _matched.add(matchedId);
        _selectedWordId = null;
        _selectedGlossId = null;
      });
      return;
    }
    final wrongWord = _selectedWordId;
    final wrongGloss = _selectedGlossId;
    setState(() {
      _wrongFlashWordId = wrongWord;
      _wrongFlashGlossId = wrongGloss;
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _selectedWordId = null;
        _selectedGlossId = null;
        _wrongFlashWordId = null;
        _wrongFlashGlossId = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allMatched = _matched.length == _pairs.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          Icon(Icons.grid_view_outlined, size: 32, color: scheme.primary),
          const SizedBox(height: 8),
          Text('Match what you missed', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'A quick round with the ${_pairs.length} word${_pairs.length == 1 ? '' : 's'} you marked '
            '"Again" this session.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        for (final c in _wordOrder)
                          _MatchTile(
                            text: c.headword,
                            matched: _matched.contains(c.cardId),
                            selected: _selectedWordId == c.cardId,
                            wrong: _wrongFlashWordId == c.cardId,
                            onTap: _matched.contains(c.cardId)
                                ? null
                                : () {
                                    setState(() => _selectedWordId = c.cardId);
                                    _tryMatch();
                                  },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        for (final c in _glossOrder)
                          _MatchTile(
                            text: c.gloss!,
                            matched: _matched.contains(c.cardId),
                            selected: _selectedGlossId == c.cardId,
                            wrong: _wrongFlashGlossId == c.cardId,
                            onTap: _matched.contains(c.cardId)
                                ? null
                                : () {
                                    setState(() => _selectedGlossId = c.cardId);
                                    _tryMatch();
                                  },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (allMatched)
            FilledButton(onPressed: widget.onDone, child: const Text('Done'))
          else
            TextButton(onPressed: widget.onDone, child: const Text('Skip')),
        ],
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  final String text;
  final bool matched;
  final bool selected;
  final bool wrong;
  final VoidCallback? onTap;

  const _MatchTile({
    required this.text,
    required this.matched,
    required this.selected,
    required this.wrong,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color border = scheme.outlineVariant;
    Color? bg;
    if (matched) {
      border = Colors.green;
      bg = Colors.green.withValues(alpha: 0.1);
    } else if (wrong) {
      border = Colors.red;
      bg = Colors.red.withValues(alpha: 0.12);
    } else if (selected) {
      border = scheme.primary;
      bg = scheme.primary.withValues(alpha: 0.08);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: matched ? scheme.onSurfaceVariant.withValues(alpha: 0.5) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// What an empty queue shows. A session that actually ran ends on
/// [StudyRecap] instead.
class _NothingDue extends StatelessWidget {
  const _NothingDue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.celebration_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('Nothing due.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
