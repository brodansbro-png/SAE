import 'package:cloud_firestore/cloud_firestore.dart';

/// Narrows a Firestore document to `Map<String, dynamic>`.
///
/// `DocumentSnapshot.data()` is typed `Map<dynamic, dynamic>` because that is
/// what the platform channel decodes into. Every repository funnels its reads
/// through here, so the failure lands once at the boundary with a clear message
/// instead of surfacing later as a `dynamic` cast error inside a model
/// constructor — where it would be attributed to the wrong piece of code.
///
/// Non-string keys are not expected: Firestore writes field names as strings, so
/// one appearing means the document is not shaped as the schema claims.
Map<String, dynamic> firestoreData(Map<dynamic, dynamic>? raw) {
  if (raw == null) return const <String, dynamic>{};

  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw StateError('Kunci field Firestore harus string, ditemukan: $key');
    }
    result[key] = entry.value;
  }
  return result;
}

/// Builds a model from a Firestore snapshot.
///
/// [build] is a model factory such as `AttendanceDoc.fromFirestore`. The
/// indirection keeps the platform type out of the model — a model that took a
/// `DocumentSnapshot` would need a Firestore import, and would then be untestable
/// without the plugin — while still letting a repository hand over a snapshot
/// directly instead of unpacking it at every call site.
T fromSnapshot<T>(
  DocumentSnapshot<Map<String, dynamic>> snapshot,
  T Function(String id, Map<dynamic, dynamic> data) build,
) =>
    build(snapshot.id, firestoreData(snapshot.data()));

/// Reads a `double` field, tolerating an int or a numeric string.
///
/// Firestore stores a `double` as a platform double, but a hand-edited document
/// or a value written by a different SDK can arrive as an int or a string, and
/// rejecting the whole record over that would hide a readable attendance entry.
double? readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// Reads a `String` field, treating an empty string as absent.
///
/// Firestore omits a field rather than storing "", but a hand-edited document can
/// hold either, and both mean "not recorded" — so they must not render
/// differently.
String? readString(Object? value) {
  if (value is! String) return null;
  return value.isEmpty ? null : value;
}

/// Reads a `String` field, preserving an empty string.
///
/// For fields where "" and "absent" are genuinely different — an optional note,
/// or a maintenance message the administrator deliberately cleared.
String readStringOrEmpty(Object? value) => value is String ? value : '';