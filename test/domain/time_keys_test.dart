import 'package:flutter_test/flutter_test.dart';
import 'package:sae/domain/logic/time_keys.dart';

/// Mirrors `SAE-Dashboard/src/tests/time.test.ts`.
void main() {
  group('clock rendering', () {
    test('renders an HH:mm clock value unchanged', () {
      expect(formatClockTime('07:58'), '07:58');
      expect(formatClockTime('17:02'), '17:02');
      expect(formatClockTime('00:00'), '00:00');
      expect(formatClockTime('23:30'), '23:30');
    });

    test('drops seconds, because attendance is minute-resolution', () {
      expect(formatClockTime('07:58:47'), '07:58');
      expect(formatClockTime('07:58:00'), '07:58');
    });

    test('renders an absent punch as an em dash, never garbage', () {
      // `DateTime.parse('07:58')` throws rather than yielding Invalid Date, so a
      // renderer that parsed the field directly would crash on every screen.
      expect(formatClockTime(null), '—');
      expect(formatClockTime(''), '—');
      expect(formatClockTime('   '), '—');
    });

    test('accepts the sortable ISO instant for records that carry one', () {
      final rendered = formatClockTime('2026-10-08T07:58:00+07:00');
      expect(rendered, matches(RegExp(r'^\d{2}:\d{2}$')));
    });

    test('shows an unrecognised shape verbatim rather than hiding it', () {
      // "—" is indistinguishable from "did not punch", which is the one reading
      // an administrator must never be misled about.
      expect(formatClockTime('menyesuaikan'), 'menyesuaikan');
      expect(formatClockTime('25:00'), '25:00');
    });
  });

  group('clock conversion', () {
    test('rejects an out-of-range clock on conversion', () {
      expect(clockToMinutes('24:00'), isNull);
      expect(clockToMinutes('07:60'), isNull);
      expect(clockToMinutes('7:58'), isNull);
      expect(clockToMinutes('nonsense'), isNull);
    });

    test('converts valid clock values to minutes', () {
      expect(clockToMinutes('00:00'), 0);
      expect(clockToMinutes('08:00'), 480);
      expect(clockToMinutes('17:30'), 1050);
      expect(clockToMinutes('23:59'), 1439);
      expect(clockToMinutes('07:58:12'), 478, reason: 'seconds are ignored');
      expect(clockToMinutes(null), isNull);
    });

    test('round-trips minutes back to a clock value', () {
      for (final clock in ['00:00', '08:00', '12:34', '23:59']) {
        expect(minutesToClock(clockToMinutes(clock)!), clock);
      }
    });

    test('clamps minutes that would overflow the day', () {
      expect(minutesToClock(-10), '00:00');
      expect(minutesToClock(1500), '23:59');
    });
  });

  group('sortable companions', () {
    test('prefers the sortable instant over the clock value', () {
      // `HH:mm` cannot be ordered, so anything chronological must use the `*At`
      // fields.
      expect(
        punchInstant('07:58', '2026-10-08T07:58:00+07:00'),
        '2026-10-08T07:58:00+07:00',
      );
      expect(punchInstant('07:58', null), '07:58');
      expect(punchInstant(null, null), isNull);
    });
  });

  group('work duration', () {
    test('formats a same-day shift', () {
      expect(formatWorkDuration('08:00', '17:00'), '9j 0m');
      expect(formatWorkDuration('08:00', '08:45'), '45m');
    });

    test('formats a shift that wraps past midnight as an overnight one', () {
      // 23:00 → 01:00 is two hours, not −22 hours.
      expect(formatWorkDuration('23:00', '01:00'), '2j 0m');
    });

    test('returns nothing when a punch is missing', () {
      // A duration derived from a missing punch is not a duration.
      expect(formatWorkDuration('08:00', null), isNull);
      expect(formatWorkDuration(null, null), isNull);
    });
  });

  group('indonesian formatting', () {
    test('renders a weekday-qualified date', () {
      // 8 October 2026 is a Thursday.
      expect(formatDisplayDateWithWeekday('2026-10-08'), 'Kamis, 8 Oktober 2026');
    });

    test('renders a compact chart label', () {
      expect(formatChartDate('2026-10-08'), '8 Okt');
    });

    test('formats numbers with Indonesian separators', () {
      expect(formatNumber(1), '1');
      expect(formatNumber(1234), '1.234');
      expect(formatNumber(1234567), '1.234.567');
    });
  });
}