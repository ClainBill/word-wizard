import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/features/study/study_recap.dart';

void main() {
  group('describeNextDue', () {
    test('an interval of a day (or a lapsed card) is tomorrow', () {
      expect(describeNextDue(1), 'tomorrow');
      expect(describeNextDue(0), 'tomorrow');
    });

    test('short intervals are exact days', () {
      expect(describeNextDue(6), 'in 6 days');
      expect(describeNextDue(13), 'in 13 days');
    });

    test('longer intervals round to weeks, months, years', () {
      expect(describeNextDue(14), 'in 2 weeks');
      expect(describeNextDue(45), 'in 6 weeks');
      expect(describeNextDue(60), 'in 2 months');
      expect(describeNextDue(97), 'in 3 months');
      expect(describeNextDue(400), 'in 1 year');
      expect(describeNextDue(800), 'in 2 years');
    });
  });

  group('describeElapsed', () {
    test('sub-minute sessions are not reported as zero', () {
      expect(describeElapsed(const Duration(seconds: 40)), 'under a minute');
    });

    test('whole minutes otherwise', () {
      expect(describeElapsed(const Duration(minutes: 4, seconds: 50)), '4 min');
    });
  });
}
