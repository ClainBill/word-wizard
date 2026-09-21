/// When the app may put an unsolicited "see Premium" prompt in front of a
/// free user — spec §5, as pure rules over a small persisted state, so
/// they can be tested without a widget in sight.
library;

/// The thresholds. Defaults are the spec's; the backend may tighten or
/// loosen them (spec §5.5), never grant anything.
class PromptThresholds {
  final int minSessions;
  final int minWords;
  final Duration cooldown;
  final Duration afterOneDismissal;
  final Duration afterTwoDismissals;
  final Duration afterThreeDismissals;
  final Duration afterCancelledPurchase;

  const PromptThresholds({
    this.minSessions = 3,
    this.minWords = 5,
    this.cooldown = const Duration(days: 7),
    this.afterOneDismissal = const Duration(days: 7),
    this.afterTwoDismissals = const Duration(days: 14),
    this.afterThreeDismissals = const Duration(days: 30),
    this.afterCancelledPurchase = const Duration(hours: 24),
  });

  static const defaults = PromptThresholds();

  static PromptThresholds fromJson(Map<String, Object?> json) {
    int n(String k, int d) => (json[k] as num?)?.toInt() ?? d;
    return PromptThresholds(
      minSessions: n('min_sessions', 3),
      minWords: n('min_words', 5),
      cooldown: Duration(days: n('cooldown_days', 7)),
      afterOneDismissal: Duration(days: n('dismissed_1_days', 7)),
      afterTwoDismissals: Duration(days: n('dismissed_2_days', 14)),
      afterThreeDismissals: Duration(days: n('dismissed_3_days', 30)),
      afterCancelledPurchase: Duration(hours: n('cancelled_purchase_hours', 24)),
    );
  }
}

/// What has happened so far. Persisted per device now, and meant to be
/// mirrored to the account so the cooldown holds across devices.
class PromptState {
  /// Separate app launches so far.
  final int sessions;
  final int dismissals;
  final DateTime? lastShownAt;
  final DateTime? lastDismissedAt;
  final DateTime? purchaseCancelledAt;

  const PromptState({
    this.sessions = 0,
    this.dismissals = 0,
    this.lastShownAt,
    this.lastDismissedAt,
    this.purchaseCancelledAt,
  });

  static const initial = PromptState();

  PromptState copyWith({
    int? sessions,
    int? dismissals,
    DateTime? lastShownAt,
    DateTime? lastDismissedAt,
    DateTime? purchaseCancelledAt,
  }) => PromptState(
    sessions: sessions ?? this.sessions,
    dismissals: dismissals ?? this.dismissals,
    lastShownAt: lastShownAt ?? this.lastShownAt,
    lastDismissedAt: lastDismissedAt ?? this.lastDismissedAt,
    purchaseCancelledAt: purchaseCancelledAt ?? this.purchaseCancelledAt,
  );

  Map<String, Object?> toJson() => {
    'sessions': sessions,
    'dismissals': dismissals,
    'last_shown_at': lastShownAt?.toIso8601String(),
    'last_dismissed_at': lastDismissedAt?.toIso8601String(),
    'purchase_cancelled_at': purchaseCancelledAt?.toIso8601String(),
  };

  static PromptState fromJson(Map<String, Object?> json) => PromptState(
    sessions: (json['sessions'] as num?)?.toInt() ?? 0,
    dismissals: (json['dismissals'] as num?)?.toInt() ?? 0,
    lastShownAt: DateTime.tryParse(json['last_shown_at'] as String? ?? ''),
    lastDismissedAt: DateTime.tryParse(json['last_dismissed_at'] as String? ?? ''),
    purchaseCancelledAt: DateTime.tryParse(json['purchase_cancelled_at'] as String? ?? ''),
  );
}

/// Why a prompt was withheld, for the debug log and the tests.
enum PromptVerdict {
  show,
  premium,
  tooFewSessions,
  tooFewWords,
  shownThisSession,
  coolingDown,
  dismissedRecently,
  purchaseCancelledRecently,
}

/// The rules of spec §5.1–5.2. The *moment* (not mid-review, not while
/// typing) is the caller's to judge; this decides whether the person is
/// owed some quiet.
PromptVerdict promptVerdict({
  required PromptState state,
  required PromptThresholds thresholds,
  required DateTime now,
  required int wordCount,
  required bool isPremium,
  required bool shownThisSession,
}) {
  if (isPremium) return PromptVerdict.premium;
  if (shownThisSession) return PromptVerdict.shownThisSession;
  if (state.sessions < thresholds.minSessions) return PromptVerdict.tooFewSessions;
  if (wordCount < thresholds.minWords) return PromptVerdict.tooFewWords;
  final cancelled = state.purchaseCancelledAt;
  if (cancelled != null && now.difference(cancelled) < thresholds.afterCancelledPurchase) {
    return PromptVerdict.purchaseCancelledRecently;
  }
  final dismissed = state.lastDismissedAt;
  if (dismissed != null) {
    final quiet = switch (state.dismissals) {
      <= 0 => Duration.zero,
      1 => thresholds.afterOneDismissal,
      2 => thresholds.afterTwoDismissals,
      _ => thresholds.afterThreeDismissals,
    };
    if (now.difference(dismissed) < quiet) return PromptVerdict.dismissedRecently;
  }
  final shown = state.lastShownAt;
  if (shown != null && now.difference(shown) < thresholds.cooldown) {
    return PromptVerdict.coolingDown;
  }
  return PromptVerdict.show;
}

/// The word-count milestones that are good moments (spec §5.3).
const List<int> promptMilestones = [10, 25, 50];
