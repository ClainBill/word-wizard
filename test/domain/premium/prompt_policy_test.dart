import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/premium/prompt_policy.dart';

void main() {
  final now = DateTime(2026, 9, 19, 12);
  const t = PromptThresholds.defaults;

  PromptVerdict verdict({
    PromptState state = const PromptState(sessions: 3),
    int wordCount = 5,
    bool isPremium = false,
    bool shownThisSession = false,
    DateTime? at,
  }) =>
      promptVerdict(
        state: state,
        thresholds: t,
        now: at ?? now,
        wordCount: wordCount,
        isPremium: isPremium,
        shownThisSession: shownThisSession,
      );

  test('the baseline: third session, five words, nothing shown yet', () {
    expect(verdict(), PromptVerdict.show);
  });

  test('never for premium, never in the first sessions, never with too few words', () {
    expect(verdict(isPremium: true), PromptVerdict.premium);
    expect(verdict(state: const PromptState(sessions: 2)), PromptVerdict.tooFewSessions);
    expect(verdict(wordCount: 4), PromptVerdict.tooFewWords);
  });

  test('at most one per session and one per seven days', () {
    expect(verdict(shownThisSession: true), PromptVerdict.shownThisSession);
    expect(
      verdict(state: PromptState(sessions: 5, lastShownAt: now.subtract(const Duration(days: 6)))),
      PromptVerdict.coolingDown,
    );
    expect(
      verdict(state: PromptState(sessions: 5, lastShownAt: now.subtract(const Duration(days: 8)))),
      PromptVerdict.show,
    );
  });

  test('dismissals stretch the quiet: 7, 14, then 30 days', () {
    PromptState dismissed(int n, int daysAgo) => PromptState(
          sessions: 9,
          dismissals: n,
          lastShownAt: now.subtract(Duration(days: daysAgo)),
          lastDismissedAt: now.subtract(Duration(days: daysAgo)),
        );
    expect(verdict(state: dismissed(1, 6)), PromptVerdict.dismissedRecently);
    expect(verdict(state: dismissed(1, 8)), PromptVerdict.show);
    expect(verdict(state: dismissed(2, 13)), PromptVerdict.dismissedRecently);
    expect(verdict(state: dismissed(2, 15)), PromptVerdict.show);
    expect(verdict(state: dismissed(3, 29)), PromptVerdict.dismissedRecently);
    expect(verdict(state: dismissed(3, 31)), PromptVerdict.show);
    expect(verdict(state: dismissed(7, 31)), PromptVerdict.show);
  });

  test('a cancelled purchase buys 24 hours of silence', () {
    expect(
      verdict(state: PromptState(sessions: 5, purchaseCancelledAt: now.subtract(const Duration(hours: 23)))),
      PromptVerdict.purchaseCancelledRecently,
    );
    expect(
      verdict(state: PromptState(sessions: 5, purchaseCancelledAt: now.subtract(const Duration(hours: 25)))),
      PromptVerdict.show,
    );
  });

  test('state round-trips through JSON and thresholds read remote config', () {
    final state = PromptState(sessions: 4, dismissals: 2, lastShownAt: now, lastDismissedAt: now);
    final back = PromptState.fromJson(state.toJson());
    expect(back.sessions, 4);
    expect(back.dismissals, 2);
    expect(back.lastShownAt, now);
    final remote = PromptThresholds.fromJson({'min_sessions': 5, 'cooldown_days': 10});
    expect(remote.minSessions, 5);
    expect(remote.cooldown, const Duration(days: 10));
    expect(remote.minWords, 5);
  });
}
