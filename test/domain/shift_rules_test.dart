import 'package:flutter_test/flutter_test.dart';
import 'package:sae/domain/logic/geofence_rules.dart';
import 'package:sae/domain/logic/shift_rules.dart';
import 'package:sae/domain/models/shift.dart';

/// Covers the window arithmetic that the original Kotlin `ShiftRules` and
/// `PunchValidator` owned.
///
/// Those classes went with the original app, so the rules were reconstructed
/// from the field meanings in `docs/FIRESTORE-SCHEMA.md` and the window slider
/// in the dashboard's `SettingsPage`. A window bug is invisible until an
/// employee's punch is rejected, so the whole decision table is pinned here
/// against fixed clocks rather than left to manual QA.
void main() {
  const rules = ShiftRules();

  /// The dashboard's default office shift, taken verbatim from the
  /// `DEFAULT_SHIFT` object in `SettingsPage.tsx`.
  final officeShift = Shift.fromMap('s1', {
    'name': 'Shift Pagi Kantor Pusat',
    'startTime': '08:00',
    'endTime': '17:00',
    'lateThresholdMinutes': 15,
    'earlyLeaveThresholdMinutes': 15,
    'checkInWindowStartMinutes': 30,
    'checkInWindowEndMinutes': 60,
    'checkOutWindowStartMinutes': 30,
    'checkOutWindowEndMinutes': 60,
    'daysOfWeek': [1, 2, 3, 4, 5],
    'isActive': true,
  });

  /// A 22:00–06:00 shift, to exercise the midnight wrap.
  final nightShift = Shift.fromMap('s2', {
    'name': 'Shift Malam',
    'startTime': '22:00',
    'endTime': '06:00',
    'lateThresholdMinutes': 15,
    'earlyLeaveThresholdMinutes': 15,
    'checkInWindowStartMinutes': 30,
    'checkInWindowEndMinutes': 60,
    'checkOutWindowStartMinutes': 30,
    'checkOutWindowEndMinutes': 60,
    'daysOfWeek': [1, 2, 3, 4, 5],
    'isActive': true,
  });

  /// Thursday 8 October 2026 — a working day for both shifts above.
  DateTime thursdayAt(int hour, int minute) =>
      DateTime(2026, 10, 8, hour, minute);

  /// Saturday 10 October 2026.
  final saturday = DateTime(2026, 10, 10, 8, 0);

  group('shift document parsing', () {
    test('reads a complete document', () {
      expect(officeShift.startMinutes, 480);
      expect(officeShift.endMinutes, 1020);
      expect(officeShift.effectiveEndMinutes, 1020);
      expect(officeShift.wrapsMidnight, isFalse);
      expect(officeShift.windowLabel, '08:00–17:00');
    });

    test('lifts an end time past midnight onto the shift timeline', () {
      // Without this, a 22:00–06:00 shift would end at 360 and every
      // check-out window comparison would be nonsense.
      expect(nightShift.startMinutes, 1320);
      expect(nightShift.endMinutes, 360);
      expect(nightShift.effectiveEndMinutes, 1800);
      expect(nightShift.wrapsMidnight, isTrue);
      expect(nightShift.windowLabel, '22:00–06:00 (+1)');
    });

    test('falls back on a document written before the window fields existed', () {
      final sparse = Shift.fromMap('s-old', {'name': 'Shift lama'});
      expect(sparse.startTime, '08:00');
      expect(sparse.endTime, '17:00');
      expect(sparse.checkInWindowStartMinutes, 30);
      expect(sparse.daysOfWeek, [1, 2, 3, 4, 5]);
    });

    test('replaces an out-of-range clock rather than honouring it', () {
      // A shift that punches at "25:00" would silently accept nobody.
      final broken = Shift.fromMap('s-bad', {
        'startTime': '25:00',
        'endTime': 'banana',
      });
      expect(broken.startMinutes, 480);
      expect(broken.endMinutes, 1020);
    });
  });

  group('window bounds', () {
    test('derives the check-in window from the start time', () {
      // 08:00 − 30 … 08:00 + 60.
      expect(rules.checkInWindowStart(officeShift), 450); // 07:30
      expect(rules.checkInWindowEnd(officeShift), 540); // 09:00
    });

    test('derives the check-out window from the end time', () {
      // 17:00 − 30 … 17:00 + 60.
      expect(rules.checkOutWindowStart(officeShift), 990); // 16:30
      expect(rules.checkOutWindowEnd(officeShift), 1080); // 18:00
    });

    test('keeps an overnight window on the shift timeline', () {
      expect(rules.checkOutWindowStart(nightShift), 1770); // 05:30 (+1)
      expect(rules.checkOutWindowEnd(nightShift), 1860); // 07:00 (+1)
    });

    test('renders windows as wall clocks, wrapping past midnight', () {
      // Otherwise the summary would read "29:30–31:00".
      expect(
        describeShiftWindows(nightShift),
        'Absen datang: 21:30–23:00\nAbsen pulang: 05:30–07:00',
      );
    });
  });

  group('window containment', () {
    test('accepts both endpoints', () {
      expect(ShiftRules.isWithinWindow(450, 450, 540), isTrue);
      expect(ShiftRules.isWithinWindow(540, 450, 540), isTrue);
      expect(ShiftRules.isWithinWindow(500, 450, 540), isTrue);
    });

    test('rejects just outside both endpoints', () {
      expect(ShiftRules.isWithinWindow(449, 450, 540), isFalse);
      expect(ShiftRules.isWithinWindow(541, 450, 540), isFalse);
    });

    test('accepts a punch after midnight for an overnight window', () {
      // A 22:00–06:00 check-out window of [1770, 1860] must accept 06:00.
      expect(ShiftRules.isWithinWindow(360, 1770, 1860), isTrue);
      expect(ShiftRules.isWithinWindow(420, 1770, 1860), isTrue); // 07:00
    });

    test('rejects the previous evening for an overnight window', () {
      // 22:00 on the preceding day lifts past the window's end, so a worker
      // cannot check out before their shift has begun.
      expect(ShiftRules.isWithinWindow(1320, 1770, 1860), isFalse);
      expect(ShiftRules.isWithinWindow(120, 1770, 1860), isFalse); // 02:00
    });

    test('counts forward to the nearest occurrence of the window', () {
      // Counted within a single day, never wrapped onto tomorrow: a window
      // opening at 05:30 is 23 hours from 06:30, not 47.
      expect(ShiftRules.minutesUntil(1400, 1770), 370);
      // 05:30 the next morning is 23h30m (1410 min) after 06:00 this morning.
      expect(ShiftRules.minutesUntil(360, 1770), 1410);
      expect(ShiftRules.minutesUntil(420, 450), 30);
      expect(ShiftRules.minutesUntil(1800, 1770), 0, reason: 'already past the open');
      expect(ShiftRules.minutesUntil(600, 450), 0, reason: 'already past the open');
    });

    test('never reports a wait longer than a day', () {
      // The clock repeats every 24 h, so a longer wait is never the truth.
      for (var now = 0; now < minutesPerDay; now++) {
        for (final start in [0, 450, 540, 990, 1770, 1860, 1439]) {
          expect(ShiftRules.minutesUntil(now, start), lessThanOrEqualTo(minutesPerDay));
        }
      }
    });

    test('distinguishes a punch before the window from one after it', () {
      // Inferring the side from the magnitude made a 10:00 check-in report
      // itself as "not yet open at 07:30", which is the failure this whole
      // method exists to prevent.
      expect(
        ShiftRules.relateToWindow(420, 450, 540),
        WindowRelation.beforeWindow,
        reason: '07:00 against a 07:30–09:00 window',
      );
      expect(
        ShiftRules.relateToWindow(600, 450, 540),
        WindowRelation.afterWindow,
        reason: '10:00 against a 07:30–09:00 window',
      );
      expect(
        ShiftRules.relateToWindow(500, 450, 540),
        WindowRelation.insideWindow,
      );
      expect(
        ShiftRules.relateToWindow(1320, 1770, 1860),
        WindowRelation.beforeWindow,
        reason: 'the evening before an overnight check-out window',
      );
      expect(
        ShiftRules.relateToWindow(360, 1770, 1860),
        WindowRelation.insideWindow,
        reason: '06:00 inside an overnight check-out window',
      );
      expect(
        ShiftRules.relateToWindow(120, 1770, 1860),
        WindowRelation.beforeWindow,
        reason: '02:00 is still before a 05:30 window',
      );
    });

    test('agrees with containment on every minute of the day', () {
      // The two must never disagree: one is used to open the screen and the
      // other to accept the punch.
      for (final window in [
        [450, 540],
        [990, 1080],
        [1290, 1380],
        [1770, 1860],
      ]) {
        for (var now = 0; now < minutesPerDay; now++) {
          final inside = ShiftRules.isWithinWindow(now, window[0], window[1]);
          final relation =
              ShiftRules.relateToWindow(now, window[0], window[1]);
          expect(
            inside,
            relation == WindowRelation.insideWindow,
            reason: 'minute $now against window ${window[0]}–${window[1]}',
          );
        }
      }
    });
  });

  group('check-in', () {
    test('refuses when no shift is assigned', () {
      final result = rules.evaluateCheckIn(
        shift: null,
        now: thursdayAt(8, 0),
        alreadyCheckedIn: false,
      );
      expect(result.allowed, isFalse);
      expect(result.reason, PunchBlockReason.noShift);
    });

    test('refuses when the shift is switched off', () {
      final disabled = Shift.fromMap('s-off', {...officeShift.toMap(), 'isActive': false});
      final result = rules.evaluateCheckIn(
        shift: disabled,
        now: thursdayAt(8, 0),
        alreadyCheckedIn: false,
      );
      expect(result.reason, PunchBlockReason.shiftInactive);
    });

    test('refuses on a non-working day', () {
      final result = rules.evaluateCheckIn(
        shift: officeShift,
        now: saturday,
        alreadyCheckedIn: false,
      );
      expect(result.reason, PunchBlockReason.notAWorkingDay);
      // The message names the days that *are* working, so the employee can see
      // what their shift covers without opening another screen.
      expect(result.message, contains('Senin, Selasa, Rabu, Kamis, Jumat'));
    });

    test('refuses a second check-in on the same day', () {
      // Caught from the existing document, so a double tap and a second device
      // racing the first are refused by the same check.
      final result = rules.evaluateCheckIn(
        shift: officeShift,
        now: thursdayAt(9, 0),
        alreadyCheckedIn: true,
      );
      expect(result.reason, PunchBlockReason.alreadyCheckedIn);
    });

    test('refuses before the window opens', () {
      final result = rules.evaluateCheckIn(
        shift: officeShift,
        now: thursdayAt(7, 0),
        alreadyCheckedIn: false,
      );
      expect(result.reason, PunchBlockReason.outsideCheckInWindow);
      expect(result.timeUntilOpensMinutes, 30);
      expect(result.message, contains('07:30'));
    });

    test('refuses after the window closes', () {
      final result = rules.evaluateCheckIn(
        shift: officeShift,
        now: thursdayAt(10, 0),
        alreadyCheckedIn: false,
      );
      expect(result.reason, PunchBlockReason.outsideCheckInWindow);
      expect(result.message, contains('09:00'));
    });

    test('records an on-time arrival inside the grace period', () {
      final result = rules.evaluateCheckIn(
        shift: officeShift,
        now: thursdayAt(8, 0),
        alreadyCheckedIn: false,
      );
      expect(result.allowed, isTrue);
      expect(result.status, 'CHECKED_IN');
    });

    test('records lateness only past the grace period', () {
      // Tolerance is 15 minutes, so 08:15 is still on time and 08:16 is not.
      expect(
        rules
            .evaluateCheckIn(
              shift: officeShift,
              now: thursdayAt(8, 15),
              alreadyCheckedIn: false,
            )
            .status,
        'CHECKED_IN',
      );
      expect(
        rules
            .evaluateCheckIn(
              shift: officeShift,
              now: thursdayAt(8, 16),
              alreadyCheckedIn: false,
            )
            .status,
        'LATE',
      );
    });

    test('only ever writes a status the rules accept on create', () {
      // `firestore.rules` constrains `create` to ['CHECKED_IN', 'LATE'], so any
      // other value would fail the write at the last moment.
      for (var minute = 0; minute < 24 * 60; minute++) {
        final result = rules.evaluateCheckIn(
          shift: officeShift,
          now: thursdayAt(0, 0).add(Duration(minutes: minute)),
          alreadyCheckedIn: false,
        );
        if (result.allowed) {
          expect(
            ['CHECKED_IN', 'LATE'],
            contains(result.status),
            reason: 'minute $minute produced ${result.status}',
          );
        }
      }
    });

    test('opens an overnight shift before its start and closes after', () {
      // 21:30–23:00 for a 22:00 shift.
      expect(
        rules
            .evaluateCheckIn(
              shift: nightShift,
              now: thursdayAt(21, 30),
              alreadyCheckedIn: false,
            )
            .allowed,
        isTrue,
      );
      expect(
        rules
            .evaluateCheckIn(
              shift: nightShift,
              now: thursdayAt(23, 0),
              alreadyCheckedIn: false,
            )
            .allowed,
        isTrue,
      );
      expect(
        rules
            .evaluateCheckIn(
              shift: nightShift,
              now: thursdayAt(23, 1),
              alreadyCheckedIn: false,
            )
            .allowed,
        isFalse,
      );
    });
  });

  group('check-out', () {
    test('refuses when there is no open check-in', () {
      // Required rather than inferred from the clock: for an overnight shift
      // the two are not the same thing.
      final result = rules.evaluateCheckOut(
        shift: officeShift,
        now: thursdayAt(17, 0),
        hasOpenCheckIn: false,
      );
      expect(result.reason, PunchBlockReason.nothingToCheckOut);
    });

    test('refuses before the window opens', () {
      final result = rules.evaluateCheckOut(
        shift: officeShift,
        now: thursdayAt(15, 0),
        hasOpenCheckIn: true,
      );
      expect(result.reason, PunchBlockReason.outsideCheckOutWindow);
      expect(result.timeUntilOpensMinutes, 90);
    });

    test('refuses after the window closes', () {
      final result = rules.evaluateCheckOut(
        shift: officeShift,
        now: thursdayAt(19, 0),
        hasOpenCheckIn: true,
      );
      expect(result.reason, PunchBlockReason.outsideCheckOutWindow);
    });

    test('completes the day inside the grace period', () {
      // Tolerance is 15 minutes, so 16:45 is on time and 16:44 is not.
      expect(
        rules
            .evaluateCheckOut(
              shift: officeShift,
              now: thursdayAt(16, 45),
              hasOpenCheckIn: true,
            )
            .status,
        'COMPLETED',
      );
      expect(
        rules
            .evaluateCheckOut(
              shift: officeShift,
              now: thursdayAt(16, 44),
              hasOpenCheckIn: true,
            )
            .status,
        'EARLY_LEAVE',
      );
    });

    test('opens the overnight check-out window after midnight', () {
      // 05:30–07:00 on the following day for a 22:00–06:00 shift.
      final atSix = DateTime(2026, 10, 9, 6, 0);
      expect(
        rules
            .evaluateCheckOut(shift: nightShift, now: atSix, hasOpenCheckIn: true)
            .allowed,
        isTrue,
      );

      final tooEarly = DateTime(2026, 10, 9, 5, 0);
      expect(
        rules
            .evaluateCheckOut(shift: nightShift, now: tooEarly, hasOpenCheckIn: true)
            .allowed,
        isFalse,
      );
    });

    test('does not call an overnight departure early', () {
      // 05:45 the next morning is late, not early: comparing against a raw
      // 360-minute clock would flag it as leaving 5h15m early.
      final result = rules.evaluateCheckOut(
        shift: nightShift,
        now: DateTime(2026, 10, 9, 5, 45),
        hasOpenCheckIn: true,
      );
      expect(result.status, 'COMPLETED');
    });
  });

  group('geofence', () {
    final office = Zone.fromMap('z1', {
      'name': 'Kantor Pusat',
      'address': 'Jl. Merdeka No. 1',
      'latitude': -6.208763,
      'longitude': 106.8456,
      'radiusMeters': 150,
      'isActive': true,
    });

    const geofence = GeofenceRules();

    Fix fixAt({
      required double lat,
      required double lng,
      double accuracy = 8,
    }) =>
        Fix(latitude: lat, longitude: lng, accuracyMeters: accuracy);

    test('accepts a fix at the zone centre', () {
      final result = geofence.evaluate(
        zone: office,
        fix: fixAt(lat: -6.208763, lng: 106.8456),
      );
      expect(result.allowed, isTrue);
      expect(result.distanceMeters, closeTo(0, 1));
    });

    test('accepts a fix inside the radius and rejects one outside', () {
      // ~55 m north of the centre, then ~220 m north.
      expect(
        geofence.evaluate(zone: office, fix: fixAt(lat: -6.208263, lng: 106.8456)).allowed,
        isTrue,
      );
      expect(
        geofence
            .evaluate(zone: office, fix: fixAt(lat: -6.206763, lng: 106.8456))
            .reason,
        PunchBlockReason.outsideZone,
      );
    });

    test('refuses the mock-location fingerprint', () {
      final result = geofence.evaluate(zone: office, fix: fixAt(lat: 0, lng: 0));
      expect(result.reason, PunchBlockReason.mockLocation);
    });

    test('refuses a fix whose accuracy cannot certify the zone', () {
      // A fix admitting a kilometre of uncertainty cannot honestly certify a
      // 150 m zone, even though its point estimate may fall inside.
      final result = geofence.evaluate(
        zone: office,
        fix: fixAt(lat: -6.208763, lng: 106.8456, accuracy: 850),
      );
      expect(result.reason, PunchBlockReason.fixUnreliable);
      expect(result.message, contains('850'));
    });

    test('refuses when there is no fix at all', () {
      expect(
        geofence.evaluate(zone: office, fix: null).reason,
        PunchBlockReason.fixUnreliable,
      );
    });

    test('refuses a zone that cannot geofence anything', () {
      // 0,0 with a 100 km radius reads as valid on the dashboard but
      // rubber-stamps every punch, so it is refused with an actionable message.
      final broken = Zone.fromMap('z-bad', {
        'name': 'Zona rusak',
        'latitude': 0,
        'longitude': 0,
        'radiusMeters': 100000,
        'isActive': true,
      });
      expect(
        geofence.evaluate(zone: broken, fix: fixAt(lat: -6.2, lng: 106.8)).reason,
        PunchBlockReason.zoneMisconfigured,
      );
    });

    test('refuses a zone outside the 10–2000 m radius bounds', () {
      for (final radius in [5, 0, -1, 2001]) {
        final zone = Zone.fromMap('z', {
          'name': 'Z',
          'latitude': -6.208763,
          'longitude': 106.8456,
          'radiusMeters': radius,
          'isActive': true,
        });
        expect(zone.isUsable, isFalse, reason: 'radius $radius');
      }
      for (final radius in [10, 150, 2000]) {
        final zone = Zone.fromMap('z', {
          'name': 'Z',
          'latitude': -6.208763,
          'longitude': 106.8456,
          'radiusMeters': radius,
          'isActive': true,
        });
        expect(zone.isUsable, isTrue, reason: 'radius $radius');
      }
    });

    test('refuses a deactivated zone', () {
      final disabled = Zone.fromMap('z-off', {...office.toMap(), 'isActive': false});
      expect(
        geofence.evaluate(zone: disabled, fix: fixAt(lat: -6.208763, lng: 106.8456)).reason,
        PunchBlockReason.zoneInactive,
      );
    });

    test('refuses when no zone is assigned', () {
      expect(
        geofence.evaluate(zone: null, fix: fixAt(lat: 0, lng: 0)).reason,
        PunchBlockReason.noZone,
      );
    });
  });
}