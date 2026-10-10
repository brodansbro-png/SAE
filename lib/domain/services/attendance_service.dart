import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../data/security_service.dart';
import '../errors.dart';
import '../logic/geofence_rules.dart';
import '../logic/shift_rules.dart';
import '../logic/time_keys.dart';
import '../models/attendance.dart';
import '../models/shift.dart';
import '../models/user.dart';
import 'auth_service.dart';
import 'firestore_map.dart';
import 'settings_service.dart';

/// Reads and writes attendance records.
///
/// This app is the only writer of `attendance`, and only of its own documents.
/// Three invariants from `firestore.rules` are load-bearing and are mirrored
/// here rather than left to the server:
///
///  1. The document id is `` `${uid}_${recordDate}` ``. That determinism is what
///     makes check-in → check-out idempotent: two devices racing on the same day
///     update one document instead of creating two rows.
///  2. A check-in may only be written when no check-in is present, so a retry
///     after a timeout cannot overwrite a real punch.
///  3. A check-out requires an existing check-in.
class AttendanceService {
  AttendanceService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Exposed so the audit trail can append through the same client instance,
  /// which keeps one Firestore session rather than creating a second one.
  FirebaseFirestore get firestore => _firestore;

  static const String collectionPath = 'attendance';

  /// Today's record for [uid], or `null` when nothing has been punched yet.
  ///
  /// Uses the deterministic document id rather than a query, so this costs one
  /// document read instead of scanning the day's records.
  Future<AttendanceDoc?> loadToday(String uid, {DateTime? now}) async {
    final isoDate = todayIso(now);
    try {
      final doc = await _firestore
          .collection(collectionPath)
          .doc(AttendanceDoc.documentIdFor(uid, isoDate))
          .get();

      if (!doc.exists) return null;
      return AttendanceDoc.fromMap(doc.id, firestoreData(doc.data()));
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Subscribes to today's record so the screen updates after a write.
  Stream<AttendanceDoc?> watchToday(String uid, {DateTime? now}) {
    final docRef = _firestore
        .collection(collectionPath)
        .doc(AttendanceDoc.documentIdFor(uid, todayIso(now)));

    return docRef.snapshots().map((doc) =>
        doc.exists
            ? AttendanceDoc.fromMap(doc.id, firestoreData(doc.data()))
            : null);
  }

  /// The employee's own history, newest first.
  ///
  /// Bounded by [limitCount] because Firestore bills per document read, and an
  /// unbounded history query on a growing collection quietly dominates the
  /// monthly invoice.
  Future<List<AttendanceDoc>> loadHistory(String uid, {int limitCount = 60}) async {
    try {
      final snapshot = await _firestore
          .collection(collectionPath)
          .where('userId', isEqualTo: uid)
          .orderBy('recordDate', descending: true)
          .limit(limitCount)
          .get();

      return snapshot.docs
          .map((doc) => AttendanceDoc.fromMap(doc.id, firestoreData(doc.data())))
          .toList();
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Monthly totals for the profile summary.
  ///
  /// Counts locally from the already-fetched history rather than issuing a
  /// second query: Firestore cannot aggregate, and a second bounded read to
  /// recompute numbers already in memory would double the cost for nothing.
  static HistorySummary summarise(List<AttendanceDoc> records, String monthPrefix) {
    final inMonth = records.where((r) => r.recordDate.startsWith(monthPrefix)).toList();

    var present = 0;
    var late = 0;
    var earlyLeave = 0;
    var onLeave = 0;
    var incomplete = 0;

    for (final record in inMonth) {
      if (statusCountsAsPresent(record.status)) present++;
      if (record.isLate) late++;
      if (record.status == AttendanceStatus.earlyLeave) earlyLeave++;
      if (record.isOnLeave) onLeave++;
      if (!record.isCompleted && record.hasCheckIn) incomplete++;
    }

    return HistorySummary(
      totalRecords: inMonth.length,
      present: present,
      late: late,
      earlyLeave: earlyLeave,
      onLeave: onLeave,
      incomplete: incomplete,
    );
  }

  /// Writes a check-in.
  ///
  /// [distanceMeters] and the zone's radius are stored on the document so the
  /// dashboard can show *why* a punch was accepted without re-reading the zone,
  /// and so a disputed punch can be audited without trusting this app's
  /// decision.
  ///
  /// [photoUrl] may be `null` when evidence upload is unconfigured; the punch
  /// itself is still valid, because the rules do not require a photo. Failing
  /// the whole punch over a missing attachment would lose a legitimate
  /// attendance record.
  Future<AttendanceDoc> checkIn({
    required UserDoc user,
    required String status,
    required Zone zone,
    required Fix fix,
    required double distanceMeters,
    String? photoUrl,
    String? address,
    String? deviceId,
    DateTime? now,
    Uint8List? sealingKey,
    String? shiftName,
    Map<String, dynamic> extraFields = const {},
  }) async {
    final stamp = now ?? DateTime.now();
    final isoDate = toIsoDate(stamp);
    final documentId = AttendanceDoc.documentIdFor(user.uid, isoDate);
    final docRef = _firestore.collection(collectionPath).doc(documentId);

    final payload = <String, dynamic>{
      'userId': user.uid,
      'userName': user.displayLabel,
      'employeeNumber': user.employeeNumber,
      'recordDate': isoDate,
      'checkInTime': minutesToClock(stamp.hour * 60 + stamp.minute),
      'checkInAt': toLocalIso(stamp),
      'checkInPhotoUrl': photoUrl,
      'checkInAddress': address,
      'checkInLat': fix.latitude,
      'checkInLng': fix.longitude,
      'checkInDistanceMeters': double.parse(distanceMeters.toStringAsFixed(2)),
      'checkInZoneRadiusMeters': zone.radiusMeters,
      'checkInAccuracyMeters': double.parse(fix.accuracyMeters.toStringAsFixed(2)),
      'checkInDeviceId': deviceId,
      // Explicitly null rather than absent, because `firestore.rules` asserts
      // `checkOutTime == null` to distinguish a fresh check-in from one that has
      // already been closed.
      'checkOutTime': null,
      'status': status,
      'shiftId': user.shiftId,
      'shiftName': shiftName,
      'zoneId': zone.id,
      'zoneName': zone.name,
      // `validPunchFields` in the rules requires `createdAt is timestamp`, so
      // omitting it fails every punch at the last possible moment. A server
      // timestamp rather than the device's, so a wrong clock cannot claim a
      // record predates it.
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      ...extraFields,
    };

    // The sealed coordinate pair rides along when a key is available. It is
    // additive: the plaintext pair above stays, because the dashboard's map and
    // the security rules both read it.
    if (sealingKey != null) {
      payload.addAll(
        PunchCrypto.sealAttendance(
          key: sealingKey,
          documentId: documentId,
          latitude: fix.latitude,
          longitude: fix.longitude,
        ),
      );
    }

    try {
      // `set` with merge:false. A retry after a timeout must fail rather than
      // silently overwriting an existing check-in, which is what the rules'
      // create/update split enforces server-side.
      await docRef.set(payload, SetOptions(merge: false));
    } on FirebaseException catch (error) {
      throw _translateWriteFailure(error);
    }

    // Re-read rather than assembling the object locally, so the screen shows
    // exactly what Firestore stored — including anything a rule coerced. The
    // locally-merged view is only a fallback for the case where the write
    // succeeded but the confirming read did not, which is better than
    // reporting a failure for a punch that is genuinely recorded.
    try {
      return await loadToday(user.uid, now: stamp) ??
          AttendanceDoc.fromMap(docRef.id, firestoreData(payload));
    } catch (_) {
      return AttendanceDoc.fromMap(docRef.id, firestoreData(payload));
    }
  }

  /// Writes a check-out onto the open record for [record].
  ///
  /// Takes the record rather than recomputing today's id, because for an
  /// overnight shift the check-out lands on the *previous* calendar day. Passing
  /// the open document is what makes that case work without the app having to
  /// reason about which day it is.
  Future<AttendanceDoc> checkOut({
    required UserDoc user,
    required AttendanceDoc record,
    required String status,
    required Zone zone,
    required Fix fix,
    required double distanceMeters,
    String? photoUrl,
    String? address,
    String? deviceId,
    DateTime? now,
  }) async {
    final stamp = now ?? DateTime.now();
    final docRef = _firestore.collection(collectionPath).doc(record.id);

    // Only the check-out half of the document is touched. `firestore.rules` pins
    // this exact key set with `hasOnly([...])`, so a stray field here is a
    // permission-denied at the worst possible moment — a check-out the employee
    // has already proved they are entitled to.
    //
    // That is also why no integrity or liveness field is written on the way out.
    // Those are recorded on the check-in, which happens once per day; duplicating
    // them per punch would double the read cost for the same information.
    final payload = <String, dynamic>{
      'checkOutTime': minutesToClock(stamp.hour * 60 + stamp.minute),
      'checkOutAt': toLocalIso(stamp),
      'checkOutPhotoUrl': photoUrl,
      'checkOutAddress': address,
      'checkOutLat': fix.latitude,
      'checkOutLng': fix.longitude,
      'checkOutDistanceMeters': double.parse(distanceMeters.toStringAsFixed(2)),
      'checkOutZoneRadiusMeters': zone.radiusMeters,
      'checkOutAccuracyMeters': double.parse(fix.accuracyMeters.toStringAsFixed(2)),
      'checkOutDeviceId': deviceId,
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await docRef.update(payload);
    } on FirebaseException catch (error) {
      throw _translateWriteFailure(error);
    } catch (error) {
      throw toAppFailure(error);
    }

    try {
      final doc = await docRef.get();
      if (doc.exists) {
        return AttendanceDoc.fromMap(doc.id, firestoreData(doc.data()));
      }
    } catch (_) {
      // Fall through to the locally-merged view below.
    }

    return record.copyWith(
      status: status,
      checkOutTime: minutesToClock(stamp.hour * 60 + stamp.minute),
      checkOutAt: toLocalIso(stamp),
      checkOutPhotoUrl: photoUrl,
      checkOutAddress: address,
      checkOutLat: fix.latitude,
      checkOutLng: fix.longitude,
      checkOutDistanceMeters: distanceMeters,
      checkOutZoneRadiusMeters: zone.radiusMeters,
      checkOutAccuracyMeters: fix.accuracyMeters,
      checkOutDeviceId: deviceId,
    );
  }

  /// The employee's most recent unclosed check-in, or `null`.
  ///
  /// Scans a bounded window backwards rather than assuming today, which is what
  /// finds the open record for a night shift checked out after midnight.
  Future<AttendanceDoc?> findOpenRecord(String uid, {DateTime? now, int lookbackDays = 3}) async {
    final stamp = now ?? DateTime.now();
    for (var offset = 0; offset <= lookbackDays; offset++) {
      final isoDate = addDaysToIso(toIsoDate(stamp), -offset);
      try {
        final doc = await _firestore
            .collection(collectionPath)
            .doc(AttendanceDoc.documentIdFor(uid, isoDate))
            .get();
        if (!doc.exists) continue;

        final record = AttendanceDoc.fromMap(doc.id, firestoreData(doc.data()));
        if (record.isOpen) return record;
      } catch (error) {
        throw toAppFailure(error);
      }
    }
    return null;
  }
}

/// Rolls up a month of history for the profile screen.
class HistorySummary {
  const HistorySummary({
    required this.totalRecords,
    required this.present,
    required this.late,
    required this.earlyLeave,
    required this.onLeave,
    required this.incomplete,
  });

  final int totalRecords;
  final int present;
  final int late;
  final int earlyLeave;
  final int onLeave;

  /// Days with a check-in but no check-out, which an administrator needs to see
  /// because they are the records most likely to need a manual correction.
  final int incomplete;

  /// Share of recorded days that were worked, as a percentage.
  int get attendanceRate {
    if (totalRecords == 0) return 0;
    return ((present / totalRecords) * 100).round();
  }
}

/// Turns a punch write failure into a copy the employee can act on.
///
/// A `permission-denied` on a check-in almost always means the account was
/// deactivated or the profile is incomplete, so it is reported as such rather
/// than as a generic write failure.
AppFailure _translateWriteFailure(FirebaseException error) {
  switch (error.code) {
    case 'permission-denied':
      return AppFailure(AppError.accountInactive, error.message);
    case 'not-found':
      // The rules require an existing check-in before a check-out.
      return AppFailure(AppError.noOpenCheckIn, error.message);
    case 'unavailable':
    case 'network-request-failed':
    case 'internal-error':
      return AppFailure(AppError.networkUnavailable, error.message);
    case 'deadline-exceeded':
      return AppFailure(AppError.timedOut, error.message);
    case 'unauthenticated':
      return AppFailure(AppError.sessionExpired, error.message);
    case 'aborted':
      // Firestore reports a contention abort here — two writes raced. Retrying
      // is the correct response.
      return AppFailure(AppError.punchWriteFailed, error.message);
    default:
      return AppFailure(AppError.punchWriteFailed, error.message);
  }
}

/// Re-exported so the history screen can evaluate a punch without importing
/// the rules library directly.
PunchEvaluation evaluatePunchForCheckIn({
  required Shift? shift,
  required DateTime now,
  required bool alreadyCheckedIn,
}) =>
    const ShiftRules().evaluateCheckIn(
      shift: shift,
      now: now,
      alreadyCheckedIn: alreadyCheckedIn,
    );

/// The zone a punch should be validated against, from the employee's profile.
Zone? resolveZoneFor(List<Zone> zones, UserDoc? user) =>
    SettingsService.resolveZone(zones, user?.zoneId);