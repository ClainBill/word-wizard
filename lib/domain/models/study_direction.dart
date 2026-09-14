/// Which way round a study card is asked.
///
/// These are two genuinely different memories, not two views of one card.
/// Recognising what "abstruse" means when you see the word is a different
/// retrieval than producing "abstruse" when you're given its meaning — the
/// second is strictly harder and decays faster (the classic
/// receptive/productive vocabulary-knowledge split). So each direction gets
/// its own `study_cards` row with its own SM-2 state, its own due date and
/// its own review history, the way Anki treats a forward and reverse card
/// as separate cards of one note.
enum StudyDirection {
  /// The word is shown; recall what it means. The original behaviour.
  wordToMeaning('w2m'),

  /// The meaning is shown; recall (produce) the word itself.
  meaningToWord('m2w');

  const StudyDirection(this.storageKey);

  /// What's persisted in `study_cards.direction`. Deliberately short and
  /// stable — it is a stored value, not a display string.
  final String storageKey;

  static StudyDirection fromStorageKey(String key) =>
      key == meaningToWord.storageKey ? meaningToWord : wordToMeaning;

  String get label => switch (this) {
        StudyDirection.wordToMeaning => 'Word → meaning',
        StudyDirection.meaningToWord => 'Meaning → word',
      };

  /// A two-or-three-character badge for dense lists, where the full label
  /// doesn't fit.
  String get shortLabel => switch (this) {
        StudyDirection.wordToMeaning => 'W→M',
        StudyDirection.meaningToWord => 'M→W',
      };
}

/// The user's choice of which direction(s) to study, from the study options
/// sheet. A mode is a *filter plus a creation rule*: it decides which
/// directions get a card when a word is added, and which directions' cards
/// are allowed into the due queue.
///
/// Turning a direction off never deletes its cards — they keep their
/// history and simply stop being queued, so switching back mid-way through
/// a vocabulary set doesn't cost you months of scheduling.
enum StudyDirectionMode {
  wordToMeaning('word_to_meaning'),
  meaningToWord('meaning_to_word'),
  both('both');

  const StudyDirectionMode(this.storageKey);

  final String storageKey;

  static const StudyDirectionMode defaultMode = StudyDirectionMode.wordToMeaning;

  static StudyDirectionMode fromStorageKey(String? key) {
    for (final mode in StudyDirectionMode.values) {
      if (mode.storageKey == key) return mode;
    }
    return defaultMode;
  }

  Set<StudyDirection> get directions => switch (this) {
        StudyDirectionMode.wordToMeaning => const {StudyDirection.wordToMeaning},
        StudyDirectionMode.meaningToWord => const {StudyDirection.meaningToWord},
        StudyDirectionMode.both => const {
            StudyDirection.wordToMeaning,
            StudyDirection.meaningToWord,
          },
      };

  String get label => switch (this) {
        StudyDirectionMode.wordToMeaning => 'Word → meaning',
        StudyDirectionMode.meaningToWord => 'Meaning → word',
        StudyDirectionMode.both => 'Both ways',
      };

  String get description => switch (this) {
        StudyDirectionMode.wordToMeaning =>
          'You see the word and recall what it means. Easier, and how you '
              'read.',
        StudyDirectionMode.meaningToWord =>
          'You see the meaning and have to produce the word. Harder, and how '
              'you write and speak.',
        StudyDirectionMode.both =>
          'Every word is scheduled twice, once each way, on independent '
              'timers. Roughly double the daily reviews.',
      };
}
