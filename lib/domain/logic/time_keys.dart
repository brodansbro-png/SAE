/// Clock-time and day-key helpers.
///
/// `checkInTime` and `checkOutTime` are stored as local `HH:mm` strings, not
/// timestamps. That is a deliberate contract with the dashboard — see
/// `docs/FIRESTORE-SCHEMA.md` and the `checkInTime.size() == 5` constraint in
/// `firestore.rules`.
///
/// The reason it matters: a punch at 23:30 WIB must be filed under the 23:00
/// *local* day. Storing a UTC instant and deriving the day from it files it
/// under the next day, which is the classic off-by-one that makes "today"
/// queries match nothing. Firestore cannot do arithmetic on `HH:mm`, so the
/// sortable companion fields `checkInAt` / `checkOutAt` carry full ISO strings
/// with offset.
///
/// This means `DateTime.parse('07:58')` is **not** a valid parse — it throws.
/// Every renderer must go through here instead.
library;

final RegExp _clockOnly = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

/// `HH:mm:ss`, which the audit log uses for its local stamp.
final RegExp _clockWithSeconds = RegExp(r'^([01]\d|2[0-3]):([0-5]\d):([0-5]\d)$');

/// Full ISO instant, which older records and the `*At` fields use.
final RegExp _isoInstant = RegExp(r'^\d{4}-\d{2}-\d{2}T');

String _pad2(int value) => value.toString().padLeft(2, '0');

/// A bare `yyyy-MM-dd`.
final RegExp _dayKey = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Formats a punch time for display.
///
/// Accepts both shapes so a document written before the `HH:mm` contract — or
/// one still carrying only the sortable field — renders correctly instead of
/// showing garbage.
///
/// Returns `—` for anything absent, which is how tables distinguish "has not
/// punched yet" from "punched at an unparseable time".
String formatClockTime(String? value) {
  // A whitespace-only string is treated as absent. Firestore omits the field
  // entirely rather than storing "", but a hand-edited document can hold
  // either, and both mean "no punch recorded".
  if (value == null || value.trim().isEmpty) return '—';

  final trimmed = value.trim();

  final withSeconds = _clockWithSeconds.firstMatch(trimmed);
  if (withSeconds != null) {
    // Seconds are dropped: attendance is recorded to the minute, and showing
    // `:47` would imply a precision the system does not have.
    return '${withSeconds.group(1)}:${withSeconds.group(2)}';
  }

  final clockOnly = _clockOnly.firstMatch(trimmed);
  if (clockOnly != null) return '${clockOnly.group(1)}:${clockOnly.group(2)}';

  if (_isoInstant.hasMatch(trimmed)) {
    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) {
      // Assembled by hand rather than via a locale formatter, because some ICU
      // builds render `07.58` with a dot. The `HH:mm` field this displays
      // everywhere else uses a colon, and a punch time must not change its
      // punctuation depending on the runtime.
      return '${_pad2(parsed.hour)}:${_pad2(parsed.minute)}';
    }
  }

  // An unrecognised shape is shown verbatim rather than hidden. Silently
  // rendering `—` would look identical to "did not punch", which is the one
  // reading an administrator must never be misled about.
  return trimmed;
}

/// Which sortable timestamp to prefer for a punch.
///
/// The `*At` fields exist precisely because `HH:mm` cannot be ordered; anything
/// chronologically meaningful must use them.
String? punchInstant(String? clockTime, String? instant) =>
    instant ?? clockTime;

/// `HH:mm` as minutes past local midnight, or `null` when unparseable.
int? clockToMinutes(String? value) {
  if (value == null || value.isEmpty) return null;
  final trimmed = value.trim();
  final match =
      _clockOnly.firstMatch(trimmed) ?? _clockWithSeconds.firstMatch(trimmed);
  if (match == null) return null;
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

/// Minutes past midnight as `HH:mm`.
String minutesToClock(int minutes) {
  final clamped = minutes.clamp(0, 24 * 60 - 1);
  final hours = clamped ~/ 60;
  return '${_pad2(hours)}:${_pad2(clamped % 60)}';
}

/// Formats a calendar day as local `yyyy-MM-dd`.
///
/// `DateTime.toIso8601String()` must not be used for day keys: it converts to
/// UTC first, so at 01:00 WIB it reports *yesterday*. Attendance records are
/// bucketed by the local calendar day, and a one-day skew makes "today" queries
/// match nothing.
String toIsoDate(DateTime date) {
  final year = date.year;
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// Today in local time, as `yyyy-MM-dd`.
String todayIso([DateTime? now]) => toIsoDate(now ?? DateTime.now());

/// A full ISO timestamp carrying the local UTC offset.
///
/// `toIso8601String()` is not usable here: it always emits `Z`, which discards
/// the offset that makes a punch timestamp unambiguous across regions.
String toLocalIso(DateTime date) {
  // `timeZoneOffset` is the difference from UTC in the sense "local minus
  // UTC", which is exactly the sign the ISO string needs — unlike JavaScript's
  // `getTimezoneOffset()`, which is inverted.
  final offset = date.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absolute = offset.abs();

  final datePart = toIsoDate(date);
  final timePart =
      '${_pad2(date.hour)}:${_pad2(date.minute)}:${_pad2(date.second)}';
  return '$datePart'
      'T$timePart'
      '$sign${_pad2(absolute.inHours)}:${_pad2(absolute.inMinutes % 60)}';
}

/// `HH:mm:ss` in local time, the shape `activity_logs.atLocal` uses.
String toLocalClockSeconds(DateTime date) =>
    '${_pad2(date.hour)}:${_pad2(date.minute)}:${_pad2(date.second)}';

/// Parses a stored `yyyy-MM-dd` as **local** midnight.
///
/// `DateTime.parse` treats a bare date as UTC, which shifts the day backwards
/// for anyone west of Greenwich — a leave request starting on the 1st would
/// display as the 31st.
DateTime? parseDayKey(String? value) {
  if (value == null) return null;
  final match = _dayKey.firstMatch(value.trim());
  if (match == null) return null;

  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  if (year == null || month == null || day == null) return null;

  final result = DateTime(year, month, day);
  // Rejects impossible dates such as `2026-02-30`, which `DateTime` would
  // silently roll forward into March.
  if (result.year != year || result.month != month || result.day != day) {
    return null;
  }
  return result;
}

/// ISO weekday number, 1 = Monday … 7 = Sunday.
///
/// This is the numbering stored in `shift.daysOfWeek`, and `firestore.rules`
/// constrains it to 1–7 precisely so Sunday can never be spelled `0`.
int isoWeekday(DateTime date) {
  final weekday = date.weekday; // Dart: 1 = Monday … 7 = Sunday
  return weekday;
}

/// Whole-day difference between two `yyyy-MM-dd` keys, inclusive of both
/// endpoints. A negative span is clamped to zero.
int daysBetween(String start, String end) {
  final from = parseDayKey(start);
  final to = parseDayKey(end);
  if (from == null || to == null) return 0;

  // Compare at UTC midnight to sidestep daylight-saving transitions, which can
  // make two local midnights 23 or 25 hours apart and round the day count
  // either way.
  final fromUtc = DateTime.utc(from.year, from.month, from.day);
  final toUtc = DateTime.utc(to.year, to.month, to.day);

  final diff = toUtc.difference(fromUtc).inHours / 24.0;
  return (diff.round() + 1).clamp(0, 1 << 31);
}

/// Adds [days] to a `yyyy-MM-dd` key.
String addDaysToIso(String iso, int days) {
  final parsed = parseDayKey(iso);
  if (parsed == null) return iso;
  return toIsoDate(parsed.add(Duration(days: days)));
}

/// Number of `yyyy-MM-dd` keys in the inclusive range `[start, end]`.
int countDaysInclusive(String start, String end) => daysBetween(start, end);

/// Whether `date` falls on one of [isoWeekdays] (1 = Mon … 7 = Sun).
bool isWorkingDay(DateTime date, List<int> isoWeekdays) =>
    isoWeekdays.contains(isoWeekday(date));

/// Indonesian short day names, indexed by [isoWeekday] - 1.
const List<String> indonesianWeekdayNames = [
  'Senin',
  'Selasa',
  'Rabu',
  'Kamis',
  'Jumat',
  'Sabtu',
  'Minggu',
];

/// Indonesian short month names, indexed by month - 1.
const List<String> indonesianMonthNames = [
  'Januari',
  'Februari',
  'Maret',
  'April',
  'Mei',
  'Juni',
  'Juli',
  'Agustus',
  'September',
  'Oktober',
  'November',
  'Desember',
];

/// A calendar day for display, e.g. `8 Oktober 2026`.
///
/// Assembled by hand rather than through `intl` so the wording is identical on
/// every device and does not shift with the user's locale.
String formatDisplayDate(String? isoDate) {
  final parsed = parseDayKey(isoDate);
  if (parsed == null) return isoDate ?? '—';
  return '${parsed.day} ${indonesianMonthNames[parsed.month - 1]} ${parsed.year}';
}

/// A weekday for display, e.g. `Kamis, 8 Oktober 2026`.
String formatDisplayDateWithWeekday(String? isoDate) {
  final parsed = parseDayKey(isoDate);
  if (parsed == null) return isoDate ?? '—';
  final name = indonesianWeekdayNames[isoWeekday(parsed) - 1];
  return '$name, ${formatDisplayDate(isoDate)}';
}

/// Compact axis label for charts, e.g. `8 Okt`.
String formatChartDate(String isoDate) {
  final parsed = parseDayKey(isoDate);
  if (parsed == null) return isoDate;
  const short = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'Mei',
    'Jun',
    'Jul',
    'Ags',
    'Sep',
    'Okt',
    'Nov',
    'Des',
  ];
  return '${parsed.day} ${short[parsed.month - 1]}';
}

/// Up to two initials for an avatar placeholder.
///
/// Empty segments are skipped so a name written as `"Budi  Santoso"` does not
/// produce `BS` with a stray character from the double space.
String getInitials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .toList();
  if (parts.isEmpty) return '?';
  return parts.map((part) => part[0].toUpperCase()).join();
}

/// Thousands separator in the Indonesian locale: `1.234`.
String formatNumber(num value) {
  final rounded = value.round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < rounded.length; i++) {
    if (i > 0 && (rounded.length - i) % 3 == 0) buffer.write('.');
    buffer.write(rounded[i]);
  }
  return buffer.toString();
}

/// Work duration between two punches, e.g. `8j 12m`.
///
/// Returns `null` unless both punches exist, because a duration derived from a
/// missing punch is not a duration.
String? formatWorkDuration(String? checkIn, String? checkOut) {
  final from = clockToMinutes(checkIn);
  final to = clockToMinutes(checkOut);
  if (from == null || to == null) return null;

  // A shift that wraps past midnight ends on the following day, so an earlier
  // checkout is not a negative duration — it is an overnight one.
  var minutes = to - from;
  if (minutes < 0) minutes += 24 * 60;

  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  if (hours == 0) return '${remainder}m';
  return '${hours}j ${remainder}m';
}