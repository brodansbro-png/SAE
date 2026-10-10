import '../models/shift.dart';
import 'time_keys.dart';

/// Why a punch was refused, or which status it earned.
///
/// Returning a specific reason rather than a bare boolean is what lets the UI
/// explain itself: an employee standing outside a zone needs to know whether
/// they are 30 m out, 3 hours early, or on the wrong day of the week.
enum PunchBlockReason {
  /// No shift is attached to the employee.
  noShift,

  /// The attached shift is switched off.
  shiftInactive,

  /// Today is not one of the shift's working days.
  notAWorkingDay,

  /// The device clock is outside the check-in window.
  outsideCheckInWindow,

  /// A check-in already exists for today.
  alreadyCheckedIn,

  /// The device clock is outside the check-out window.
  outsideCheckOutWindow,

  /// No unclosed check-in exists to check out from.
  nothingToCheckOut,

  /// The employee has no zone assigned.
  noZone,

  /// The assigned zone is switched off.
  zoneInactive,

  /// The zone has unusable coordinates or a radius outside 10–2000 m.
  zoneMisconfigured,

  /// The GPS fix cannot be trusted enough to certify the zone.
  fixUnreliable,

  /// The reported position is the 0,0 mock-location fingerprint.
  mockLocation,

  /// The fix resolves further from the zone centre than the radius allows.
  outsideZone,

  /// Firestore or the network refused the write.
  writeFailed,
}

/// Where a wall clock sits relative to a punch window.
enum WindowRelation {
  /// The window has not opened yet.
  beforeWindow,

  /// The clock is inside the window.
  insideWindow,

  /// The window has already closed.
  afterWindow,
}

/// The outcome of evaluating a punch before it is attempted.
class PunchEvaluation {
  const PunchEvaluation._({
    required this.allowed,
    required this.status,
    this.reason,
    this.message = '',
    this.distanceMeters,
    this.timeUntilOpensMinutes,
    this.timeUntilClosesMinutes,
  });

  /// Whether the punch may proceed to the Firestore write.
  final bool allowed;

  /// The status a successful check-in would record: `CHECKED_IN` or `LATE`.
  ///
  /// `firestore.rules` constrains `create` to exactly those two, so this is
  /// deliberately not a free-form string.
  final String status;

  /// Set when [allowed] is false.
  final PunchBlockReason? reason;

  /// Indonesian copy for the reason, safe to render directly.
  final String message;

  /// Measured distance to the zone centre, when a fix was available.
  final double? distanceMeters;

  /// Minutes until the window opens, when the punch is too early.
  final int? timeUntilOpensMinutes;

  /// Minutes until the window closes, when the punch is in the past.
  final int? timeUntilClosesMinutes;

  /// A refusal carrying [reason] and [message].
  factory PunchEvaluation.blocked(
    PunchBlockReason reason,
    String message, {
    double? distanceMeters,
    int? timeUntilOpensMinutes,
    int? timeUntilClosesMinutes,
  }) =>
      PunchEvaluation._(
        allowed: false,
        status: 'CHECKED_IN',
        reason: reason,
        message: message,
        distanceMeters: distanceMeters,
        timeUntilOpensMinutes: timeUntilOpensMinutes,
        timeUntilClosesMinutes: timeUntilClosesMinutes,
      );

  /// A permitted punch that will record [status].
  factory PunchEvaluation.allowed(
    String status, {
    double? distanceMeters,
    String message = '',
  }) =>
      PunchEvaluation._(
        allowed: true,
        status: status,
        message: message,
        distanceMeters: distanceMeters,
      );
}

/// Evaluates whether a check-in or check-out may be written.
///
/// This is the Dart half of the contract the old Kotlin `PunchValidator` and
/// `ShiftRules` owned; those classes went with the original app, so the rules
/// are reconstructed here from the field meanings documented in
/// `docs/FIRESTORE-SCHEMA.md` and the window slider in the dashboard's
/// `SettingsPage`.
///
/// Nothing here writes. Separating the decision from the write is what allows
/// the whole rule set to be unit-tested against fixed clocks, which matters
/// because a window bug is invisible until an employee's punch is rejected.
class ShiftRules {
  const ShiftRules();

  /// First minute at which a check-in is accepted.
  int checkInWindowStart(Shift shift) {
    final start = shift.startMinutes ?? 0;
    return start - shift.checkInWindowStartMinutes;
  }

  /// Last minute at which a check-in is accepted.
  int checkInWindowEnd(Shift shift) {
    final start = shift.startMinutes ?? 0;
    return start + shift.checkInWindowEndMinutes;
  }

  /// First minute at which a check-out is accepted, on the shift timeline.
  int checkOutWindowStart(Shift shift) {
    final end = shift.effectiveEndMinutes ?? minutesPerDay;
    return end - shift.checkOutWindowStartMinutes;
  }

  /// Last minute at which a check-out is accepted, on the shift timeline.
  int checkOutWindowEnd(Shift shift) {
    final end = shift.effectiveEndMinutes ?? minutesPerDay;
    return end + shift.checkOutWindowEndMinutes;
  }

  /// Whether [nowMinutes] falls inside the inclusive `[start, end]` window.
  ///
  /// The window may run past midnight, so [nowMinutes] — which is always
  /// 0–1439 — is lifted forward by whole days until it lands at or after
  /// [start], then compared. Lifting rather than wrapping is what makes an
  /// overnight shift behave: a 22:00–06:00 check-out window of [1770, 1860]
  /// accepts 02:00 (lifted to 1800) but rejects 22:00 the previous evening
  /// (lifted to 3000, past the end).
  static bool isWithinWindow(int nowMinutes, int start, int end) {
    if (start > end) return false;

    var candidate = nowMinutes;
    // Bounded to a couple of iterations by construction: [start] and [now] are
    // both within a few days of each other.
    var guard = 0;
    while (candidate < start && guard < 8) {
      candidate += minutesPerDay;
      guard++;
    }
    return candidate <= end;
  }

  /// Minutes from [nowMinutes] forward to the *nearest* occurrence of [start].
  ///
  /// Counts within a single day, never wrapping onto the following one. That
  /// matters because the clock repeats every 24 hours: a check-out window that
  /// opens at 05:30 the next morning is 23 hours away from 06:30 the evening
  /// before, not 47. Wrapping would report a wait longer than a day and tell
  /// the employee to come back tomorrow for a window that opens in twenty
  /// minutes.
  ///
  /// Returns 0 when [nowMinutes] is already at or past [start], so callers must
  /// not read 0 as proof the window is open — use [relateToWindow] for that.
  static int minutesUntil(int nowMinutes, int start) {
    final raw = start - nowMinutes;
    if (raw <= 0) return 0;
    return raw >= minutesPerDay ? minutesPerDay : raw;
  }

  /// Where [nowMinutes] sits relative to the window `[start, end]`.
  ///
  /// A punch that is refused needs to say *which* side it fell on, because the
  /// remedy differs: "come back at 07:30" is actionable where "the window has
  /// closed" is not. Inferring that from a magnitude — as an earlier version of
  /// this file did — is what made a 10:00 punch report itself as 07:30.
  static WindowRelation relateToWindow(int nowMinutes, int start, int end) {
    if (start > end) return WindowRelation.afterWindow;

    final lifted = _liftTo(nowMinutes, start);
    if (lifted <= end) return WindowRelation.insideWindow;

    // `lifted` is past `end`. Whether the real clock is before the window or
    // after it is decided by whether a whole day had to be added to get here:
    // a punch that needed lifting belongs to an earlier occurrence of the
    // window, one that has not arrived yet.
    return lifted - nowMinutes >= minutesPerDay
        ? WindowRelation.beforeWindow
        : WindowRelation.afterWindow;
  }

  /// Lifts [nowMinutes] forward by whole days until it reaches [start].
  ///
  /// Lands *on or after* [start], which is what window containment wants.
  static int _liftTo(int nowMinutes, int start) {
    var candidate = nowMinutes;
    // Bounded by construction: `start` is within a day or two of `now`.
    var guard = 0;
    while (candidate < start && guard < 8) {
      candidate += minutesPerDay;
      guard++;
    }
    return candidate;
  }

  /// Places [nowMinutes] in the day-long interval ending at [end].
  ///
  /// Differs from [_liftTo] in where it lands: that one lifts to `>= end`,
  /// which is right for asking "has the window started?" but wrong for asking
  /// "did they leave early?". Lifting 16:44 past an 17:00 end lands on 16:44
  /// *tomorrow*, which then compares as not-early and silently converts every
  /// early departure into a completed day.
  static int alignToEnd(int nowMinutes, int end) {
    // The representative of `now` within [end - 1 day, end].
    var candidate = end - ((end - nowMinutes) % minutesPerDay);
    if (candidate > end) candidate -= minutesPerDay;
    return candidate;
  }

  /// Whether a check-in at [nowMinutes] is past the grace period.
  bool isLate(Shift shift, int nowMinutes) {
    final start = shift.startMinutes;
    if (start == null) return false;
    return nowMinutes > start + shift.lateThresholdMinutes;
  }

  /// Whether a check-out at [nowMinutes] is before the grace period.
  ///
  /// The clock is placed on the same day of the shift timeline as [end] first,
  /// so an overnight departure at 05:45 is compared against 1800 rather than
  /// against 345. Without that alignment it would read as leaving more than
  /// five hours early.
  bool isEarlyLeave(Shift shift, int nowMinutes) {
    final end = shift.effectiveEndMinutes;
    if (end == null) return false;

    final candidate = alignToEnd(nowMinutes, end);
    return candidate < end - shift.earlyLeaveThresholdMinutes;
  }

  /// Whether today is a working day for [shift].
  bool isWorkingDay(Shift shift, DateTime now) => shift.worksOn(now);

  /// The status a check-out at [nowMinutes] completes the day with.
  String checkOutStatus(Shift shift, int nowMinutes) =>
      isEarlyLeave(shift, nowMinutes) ? 'EARLY_LEAVE' : 'COMPLETED';

  /// Evaluates a check-in.
  ///
  /// [alreadyCheckedIn] comes from the existing attendance document rather than
  /// from local state, so a second device racing the first one is caught by the
  /// same check that catches a double tap.
  PunchEvaluation evaluateCheckIn({
    required Shift? shift,
    required DateTime now,
    required bool alreadyCheckedIn,
  }) {
    if (shift == null) {
      return PunchEvaluation.blocked(
        PunchBlockReason.noShift,
        'Shift kerja belum ditentukan. Hubungi administrator.',
      );
    }
    if (!shift.isActive) {
      return PunchEvaluation.blocked(
        PunchBlockReason.shiftInactive,
        'Shift "${shift.name}" sedang dinonaktifkan.',
      );
    }

    final nowMinutes = now.hour * 60 + now.minute;

    if (alreadyCheckedIn) {
      return PunchEvaluation.blocked(
        PunchBlockReason.alreadyCheckedIn,
        'Anda sudah melakukan absen datang hari ini.',
      );
    }

    if (!isWorkingDay(shift, now)) {
      final days = shift.daysOfWeek
          .map((day) => indonesianWeekdayNames[(day - 1).clamp(0, 6)])
          .join(', ');
      return PunchEvaluation.blocked(
        PunchBlockReason.notAWorkingDay,
        'Hari ini bukan hari kerja untuk shift "${shift.name}" '
        '(hari kerja: $days).',
      );
    }

    final open = checkInWindowStart(shift);
    final close = checkInWindowEnd(shift);

    final relation = relateToWindow(nowMinutes, open, close);
    if (relation != WindowRelation.insideWindow) {
      final tooEarly = relation == WindowRelation.beforeWindow;
      return PunchEvaluation.blocked(
        PunchBlockReason.outsideCheckInWindow,
        tooEarly
            ? 'Absen datang belum dibuka. Dibuka pukul ${_clock(open)}.'
            : 'Jendela absen datang sudah tertutup pukul ${_clock(close)}.',
        timeUntilOpensMinutes: tooEarly ? minutesUntil(nowMinutes, open) : null,
        timeUntilClosesMinutes: tooEarly ? null : nowMinutes - close,
      );
    }

    final late = isLate(shift, nowMinutes);
    return PunchEvaluation.allowed(
      late ? 'LATE' : 'CHECKED_IN',
      message: late
          ? 'Absen tercatat sebagai terlambat (toleransi '
              '${shift.lateThresholdMinutes} menit).'
          : 'Absen datang berhasil dicatat.',
    );
  }

  /// Evaluates a check-out.
  ///
  /// [hasOpenCheckIn] is true when a check-in exists for the current record
  /// without a matching check-out. It is required rather than inferred from the
  /// clock, because for an overnight shift the two are not the same thing.
  PunchEvaluation evaluateCheckOut({
    required Shift? shift,
    required DateTime now,
    required bool hasOpenCheckIn,
  }) {
    if (shift == null) {
      return PunchEvaluation.blocked(
        PunchBlockReason.noShift,
        'Shift kerja belum ditentukan. Hubungi administrator.',
      );
    }
    if (!shift.isActive) {
      return PunchEvaluation.blocked(
        PunchBlockReason.shiftInactive,
        'Shift "${shift.name}" sedang dinonaktifkan.',
      );
    }
    if (!hasOpenCheckIn) {
      return PunchEvaluation.blocked(
        PunchBlockReason.nothingToCheckOut,
        'Belum ada absen datang yang tercatat, jadi absen pulang tidak bisa '
        'dilakukan.',
      );
    }

    final nowMinutes = now.hour * 60 + now.minute;
    final open = checkOutWindowStart(shift);
    final close = checkOutWindowEnd(shift);

    final relation = relateToWindow(nowMinutes, open, close);
    if (relation != WindowRelation.insideWindow) {
      final tooEarly = relation == WindowRelation.beforeWindow;
      return PunchEvaluation.blocked(
        PunchBlockReason.outsideCheckOutWindow,
        tooEarly
            ? 'Absen pulang belum dibuka. Dibuka pukul ${_clock(open)}.'
            : 'Jendela absen pulang sudah tertutup pukul ${_clock(close)}.',
        timeUntilOpensMinutes: tooEarly ? minutesUntil(nowMinutes, open) : null,
        timeUntilClosesMinutes: tooEarly ? null : nowMinutes - close,
      );
    }

    final early = isEarlyLeave(shift, nowMinutes);
    return PunchEvaluation.allowed(
      checkOutStatus(shift, nowMinutes),
      message: early
          ? 'Absen tercatat sebagai pulang awal (toleransi '
              '${shift.earlyLeaveThresholdMinutes} menit).'
          : 'Absen pulang berhasil dicatat.',
    );
  }
}

/// Human-readable summary of a shift's windows, for the attendance screen.
///
/// Shown above the punch buttons so an employee can see *why* a button is
/// disabled without having to try it.
String describeShiftWindows(Shift shift) {
  const rules = ShiftRules();
  final openIn = rules.checkInWindowStart(shift);
  final closeIn = rules.checkInWindowEnd(shift);
  final openOut = rules.checkOutWindowStart(shift);
  final closeOut = rules.checkOutWindowEnd(shift);

  return 'Absen datang: ${_clock(openIn)}–${_clock(closeIn)}\n'
      'Absen pulang: ${_clock(openOut)}–${_clock(closeOut)}';
}

/// Formats a shift-timeline minute back to a wall clock, wrapping past midnight
/// so an overnight window prints `05:30` rather than `29:30`.
String _clock(int minutes) => minutesToClock(minutes % minutesPerDay);