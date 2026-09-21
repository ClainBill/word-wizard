import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';
import '../domain/premium/prompt_policy.dart';

/// Keeps the prompt-policy state (spec §5) and answers "may I, now?".
/// One per app; the trigger sites (a word milestone, the end of a review
/// session) ask it, and the sheet reports back what the person did.
class PremiumPrompts {
  final Future<String?> Function() _read;
  final Future<void> Function(String json) _write;
  PromptThresholds thresholds;
  PromptState _state = PromptState.initial;
  bool _shownThisSession = false;
  bool _loaded = false;

  /// A word milestone reached on the entry screen; the prompt waits until
  /// the person leaves that screen (spec §5.3).
  int? pendingMilestone;

  PremiumPrompts(SettingsRepository settings, {this.thresholds = PromptThresholds.defaults})
      : _read = settings.premiumPromptState,
        _write = settings.setPremiumPromptState;

  /// Storage of the caller's choosing — tests, mostly.
  PremiumPrompts.custom({
    required Future<String?> Function() load,
    required Future<void> Function(String json) save,
    this.thresholds = PromptThresholds.defaults,
  })  : _read = load,
        _write = save;

  /// Keeps nothing; for tests that never look at the prompt.
  PremiumPrompts.inMemory({this.thresholds = PromptThresholds.defaults})
      : _read = _none,
        _write = _drop;

  static Future<String?> _none() async => null;
  static Future<void> _drop(String _) async {}

  PromptState get state => _state;

  /// Reads the persisted state and counts this launch as a session.
  Future<void> startSession() async {
    await _load();
    await _save(_state.copyWith(sessions: _state.sessions + 1));
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final json = await _read();
      if (json != null) _state = PromptState.fromJson(jsonDecode(json) as Map<String, Object?>);
    } catch (e) {
      debugPrint('premium prompts: state unreadable, starting over: $e');
    }
  }

  Future<void> _save(PromptState next) async {
    _state = next;
    try {
      await _write(jsonEncode(next.toJson()));
    } catch (e) {
      debugPrint('premium prompts: state not saved: $e');
    }
  }

  PromptVerdict verdict({required int wordCount, required bool isPremium, DateTime? now}) {
    final v = promptVerdict(
      state: _state,
      thresholds: thresholds,
      now: now ?? DateTime.now(),
      wordCount: wordCount,
      isPremium: isPremium,
      shownThisSession: _shownThisSession,
    );
    if (v != PromptVerdict.show) debugPrint('premium prompt withheld: ${v.name}');
    return v;
  }

  /// Whether [wordCount] just crossed a milestone worth a prompt later.
  void noteWordCount(int wordCount) {
    if (promptMilestones.contains(wordCount)) pendingMilestone = wordCount;
  }

  Future<void> markShown() {
    _shownThisSession = true;
    return _save(_state.copyWith(lastShownAt: DateTime.now()));
  }

  Future<void> markDismissed() =>
      _save(_state.copyWith(dismissals: _state.dismissals + 1, lastDismissedAt: DateTime.now()));

  Future<void> markPurchaseCancelled() =>
      _save(_state.copyWith(purchaseCancelledAt: DateTime.now()));

  /// Debug: a way to see the prompt again without waiting a week.
  Future<void> reset() {
    _shownThisSession = false;
    return _save(PromptState(sessions: _state.sessions));
  }
}
