import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/srs/sm2.dart';

void main() {
  final anchor = DateTime(2026, 1, 1);

  group('gradeCard — new card', () {
    test('Again keeps the card in Learning, due tomorrow', () {
      final r = gradeCard(StudyCardState.initial, Grade.again, now: anchor);
      expect(r.state.repetitions, 0);
      expect(r.state.intervalDays, 1);
      expect(r.dueAt, DateTime(2026, 1, 2));
      expect(r.state.stage, CardStage.newCard);
    });

    test('Good moves reps to 1, interval to 1 day', () {
      final r = gradeCard(StudyCardState.initial, Grade.good, now: anchor);
      expect(r.state.repetitions, 1);
      expect(r.state.intervalDays, 1);
      expect(r.dueAt, DateTime(2026, 1, 2));
    });

    test('Easy applies the EF bonus and moves reps to 1, interval to 1 day', () {
      final r = gradeCard(StudyCardState.initial, Grade.easy, now: anchor);
      expect(r.state.repetitions, 1);
      expect(r.state.intervalDays, 1);
      expect(r.state.easeFactor, closeTo(2.5 + 0.1 + 0.15, 1e-9));
    });
  });

  group('gradeCard — progression', () {
    test('second consecutive Good moves interval to 6 days', () {
      var state = StudyCardState.initial;
      state = gradeCard(state, Grade.good, now: anchor).state;
      final r2 = gradeCard(state, Grade.good, now: anchor);
      expect(r2.state.repetitions, 2);
      expect(r2.state.intervalDays, 6);
      expect(r2.state.stage, CardStage.review);
    });

    test('third consecutive Good multiplies interval by the ease factor', () {
      var state = StudyCardState.initial;
      state = gradeCard(state, Grade.good, now: anchor).state;
      state = gradeCard(state, Grade.good, now: anchor).state;
      final r3 = gradeCard(state, Grade.good, now: anchor);
      expect(r3.state.repetitions, 3);
      expect(r3.state.intervalDays, (6 * state.easeFactor).round());
    });

    test('a lapse on a Review card drops it straight back to Learning', () {
      var state = StudyCardState.initial;
      state = gradeCard(state, Grade.good, now: anchor).state;
      state = gradeCard(state, Grade.good, now: anchor).state; // now Review, EF preserved
      final ef = state.easeFactor;
      final r = gradeCard(state, Grade.again, now: anchor);
      expect(r.state.repetitions, 0);
      expect(r.state.intervalDays, 1);
      expect(r.state.easeFactor, ef); // Again does not touch EF
      expect(r.state.stage, CardStage.newCard);
    });

    test('Hard grows the interval by ~1.2x without touching EF or reps', () {
      var state = StudyCardState.initial;
      state = gradeCard(state, Grade.good, now: anchor).state; // reps 1, interval 1
      state = gradeCard(state, Grade.good, now: anchor).state; // reps 2, interval 6
      final ef = state.easeFactor;
      final reps = state.repetitions;
      final r = gradeCard(state, Grade.hard, now: anchor);
      expect(r.state.intervalDays, (6 * 1.2).round());
      expect(r.state.easeFactor, ef);
      expect(r.state.repetitions, reps);
    });

    test('ease factor never drops below 1.3', () {
      var state = const StudyCardState(repetitions: 5, easeFactor: 1.3, intervalDays: 30);
      final r = gradeCard(state, Grade.hard == Grade.hard ? Grade.again : Grade.again, now: anchor);
      // Again resets reps/interval but must not push EF below the floor either.
      expect(r.state.easeFactor, greaterThanOrEqualTo(1.3));
    });

    test('a card reaches Mastered once interval >= 90d and EF >= 2.5', () {
      final state = const StudyCardState(repetitions: 4, easeFactor: 2.6, intervalDays: 95);
      expect(state.stage, CardStage.mastered);
    });
  });
}
