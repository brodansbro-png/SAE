import '../logic/time_keys.dart';

/// Working-hours profile, mirroring `settings/shifts/{id}`.
///
/// A plain Dart class with no Firestore dependency, so the window arithmetic in
/// `shift_rules.dart` can be exercised without a database.
class Shift {
  const Shift({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.lateThresholdMinutes,
    required this.earlyLeaveThresholdMinutes,
    required this.checkInWindowStartMinutes,
    required this.checkInWindowEndMinutes,
    required this.checkOutWindowStartMinutes,
    required this.checkOutWindowEndMinutes,
    required this.daysOfWeek,
    required this.isActive,
  });

  /// Firestore document id.
  final String id;

  /// e.g. `Shift Pagi Kantor Pusat`.
  final String name;

  /// `HH:mm`. Also the default the dashboard's shift editor pre-fills.
  final String startTime;

  /// `HH:mm`, and may wrap past midnight — a 22:00–06:00 shift is legal.
  final String endTime;

  /// Grace period before a check-in counts as `LATE`.
  final int lateThresholdMinutes;

  /// Grace period before a check-out counts as `EARLY_LEAVE`.
  final int earlyLeaveThresholdMinutes;

  /// Minutes **before** [startTime] that a check-in opens.
  final int checkInWindowStartMinutes;

  /// Minutes **after** [startTime] that a check-in closes.
  final int checkInWindowEndMinutes;

  /// Minutes **before** [endTime] that a check-out opens.
  final int checkOutWindowStartMinutes;

  /// Minutes **after** [endTime] that a check-out closes.
  final int checkOutWindowEndMinutes;

  /// ISO weekday numbers, 1 = Monday … 7 = Sunday.
  ///
  /// ISO numbering rather than Dart's is the stored contract: `firestore.rules`
  /// constrains every entry to 1–7 precisely so Sunday can never be spelled
  /// `0`. Conveniently this matches [DateTime.weekday], so no translation is
  /// needed at the point of use.
  final List<int> daysOfWeek;

  final bool isActive;

  /// [startTime] as minutes past midnight, or `null` when unparseable.
  int? get startMinutes => clockToMinutes(startTime);

  /// [endTime] as minutes past midnight, or `null` when unparseable.
  int? get endMinutes => clockToMinutes(endTime);

  /// Whether [endTime] falls at or before [startTime], meaning the shift runs
  /// past midnight into the following calendar day.
  bool get wrapsMidnight {
    final start = startMinutes;
    final end = endMinutes;
    if (start == null || end == null) return false;
    return end <= start;
  }

  /// [endTime] expressed on the same timeline as a start, so an overnight shift
  /// ends *after* it starts: a 22:00–06:00 shift ends at 1800, not 360.
  ///
  /// Returns `null` when either time is unparseable.
  int? get effectiveEndMinutes {
    final start = startMinutes;
    final end = endMinutes;
    if (start == null || end == null) return null;
    return wrapsMidnight ? end + minutesPerDay : end;
  }

  /// Whether this shift covers [date]'s weekday.
  bool worksOn(DateTime date) => daysOfWeek.contains(isoWeekday(date));

  /// `08:00–17:00`, or `22:00–06:00 (+1)` when the shift wraps midnight.
  String get windowLabel {
    if (wrapsMidnight) return '$startTime–$endTime (+1)';
    return '$startTime–$endTime';
  }

  /// Builds a shift from a Firestore document.
  ///
  /// Every numeric field falls back to a sane default rather than throwing: a
  /// shift written by an older dashboard build may be missing the window
  /// fields entirely, and refusing to render the app over that would be worse
  /// than a slightly generous window.
  factory Shift.fromMap(String id, Map<String, dynamic> map) {
    final days = map['daysOfWeek'];
    return Shift(
      id: id,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? (map['name'] as String).trim()
          : 'Shift tanpa nama',
      startTime: _validClock(map['startTime']) ?? '08:00',
      endTime: _validClock(map['endTime']) ?? '17:00',
      lateThresholdMinutes: _positiveInt(map['lateThresholdMinutes'], 15),
      earlyLeaveThresholdMinutes:
          _positiveInt(map['earlyLeaveThresholdMinutes'], 15),
      checkInWindowStartMinutes:
          _positiveInt(map['checkInWindowStartMinutes'], 30),
      checkInWindowEndMinutes: _positiveInt(map['checkInWindowEndMinutes'], 60),
      checkOutWindowStartMinutes:
          _positiveInt(map['checkOutWindowStartMinutes'], 30),
      checkOutWindowEndMinutes:
          _positiveInt(map['checkOutWindowEndMinutes'], 60),
      daysOfWeek: days is List
          ? days.whereType<num>().map((value) => value.toInt()).toList()
          : const <int>[1, 2, 3, 4, 5],
      isActive: map['isActive'] != false,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'startTime': startTime,
        'endTime': endTime,
        'lateThresholdMinutes': lateThresholdMinutes,
        'earlyLeaveThresholdMinutes': earlyLeaveThresholdMinutes,
        'checkInWindowStartMinutes': checkInWindowStartMinutes,
        'checkInWindowEndMinutes': checkInWindowEndMinutes,
        'checkOutWindowStartMinutes': checkOutWindowStartMinutes,
        'checkOutWindowEndMinutes': checkOutWindowEndMinutes,
        'daysOfWeek': daysOfWeek,
        'isActive': isActive,
      };

  @override
  String toString() => 'Shift($id, $name, $windowLabel)';
}

/// Minutes in a day. Named so the overnight arithmetic reads as an intent
/// rather than as a stray `1440`.
const int minutesPerDay = 24 * 60;

/// Accepts only a well-formed `HH:mm`, so a malformed document cannot silently
/// become a shift that punches at the wrong hour.
String? _validClock(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (clockToMinutes(trimmed) == null) return null;
  return trimmed;
}

int _positiveInt(Object? value, int fallback) {
  if (value is num) return value.toInt().clamp(0, 24 * minutesPerDay);
  return fallback;
}