import '../logic/time_keys.dart';
import '../services/firestore_map.dart';

/// One attendance record per employee per day.
///
/// The document id is deterministic — `` `${userId}_${recordDate}` ``, e.g.
/// `abc123_2026-10-08` — which is what makes the check-in → check-out round
/// trip idempotent: two devices racing on the same day resolve the same
/// document and update it, rather than creating a duplicate row.
///
/// The geofence values are denormalised from the zone at punch time. The
/// geofence is decided on the device, so recording the measured distance
/// alongside the radius it was compared against is what makes a disputed punch
/// auditable rather than merely arguable.
class AttendanceDoc {
  const AttendanceDoc({
    required this.id,
    required this.userId,
    required this.userName,
    required this.employeeNumber,
    required this.recordDate,
    required this.status,
    this.shiftId,
    this.shiftName,
    this.zoneId,
    this.zoneName,
    this.checkInTime,
    this.checkOutTime,
    this.checkInAt,
    this.checkOutAt,
    this.checkInPhotoUrl,
    this.checkOutPhotoUrl,
    this.checkInAddress,
    this.checkOutAddress,
    this.checkInLat,
    this.checkInLng,
    this.checkInDistanceMeters,
    this.checkInZoneRadiusMeters,
    this.checkInAccuracyMeters,
    this.checkOutLat,
    this.checkOutLng,
    this.checkOutDistanceMeters,
    this.checkOutZoneRadiusMeters,
    this.checkOutAccuracyMeters,
    this.checkInDeviceId,
    this.checkOutDeviceId,
    this.checkInLatEnc,
    this.checkOutLatEnc,
    this.deviceIntegrityCodes,
    this.deviceIntegrityFlagged = false,
    this.livenessVerified,
    this.notes,
  });

  /// Firestore document id, `` `${userId}_${recordDate}` ``.
  final String id;

  final String userId;
  final String userName;

  /// Denormalised so the dashboard can search the roster without a join.
  final String employeeNumber;

  /// Local `yyyy-MM-dd`, stored server-side so day queries are index-backed.
  final String recordDate;

  final String status;

  final String? shiftId;
  final String? shiftName;
  final String? zoneId;
  final String? zoneName;

  /// `HH:mm` local. `firestore.rules` requires exactly 5 characters on create.
  final String? checkInTime;

  /// `HH:mm` local.
  final String? checkOutTime;

  /// Full ISO instant with offset — the sortable companion to [checkInTime].
  final String? checkInAt;

  /// Full ISO instant with offset.
  final String? checkOutAt;

  /// Cloudinary evidence URLs.
  final String? checkInPhotoUrl;
  final String? checkOutPhotoUrl;

  /// Reverse-geocoded labels.
  final String? checkInAddress;
  final String? checkOutAddress;

  final double? checkInLat;
  final double? checkInLng;
  final double? checkInDistanceMeters;
  final double? checkInZoneRadiusMeters;
  final double? checkInAccuracyMeters;

  final double? checkOutLat;
  final double? checkOutLng;
  final double? checkOutDistanceMeters;
  final double? checkOutZoneRadiusMeters;
  final double? checkOutAccuracyMeters;

  /// Detects a shared phone punching on behalf of two employees.
  final String? checkInDeviceId;
  final String? checkOutDeviceId;

  /// AES-256-GCM sealed coordinate pairs, bound to [id] as associated data.
  ///
  /// Written alongside the plaintext `checkInLat`/`checkInLng` rather than
  /// instead of them, because the dashboard's map and the security rules both
  /// read the plaintext pair — sealing only would break them, and dropping them
  /// would leave the geofence unauditable. See `PunchCrypto` for exactly what
  /// this does and does not protect against.
  final String? checkInLatEnc;
  final String? checkOutLatEnc;

  /// Device-integrity finding codes recorded at punch time.
  ///
  /// Empty when the device passed every check. Non-empty does not mean the punch
  /// was fraudulent — a warning-level finding lands here too — so the dashboard
  /// presents it as a flag to review, not as a verdict.
  final String? deviceIntegrityCodes;

  /// Whether any integrity finding was recorded.
  final bool deviceIntegrityFlagged;

  /// Whether the evidence photo passed the liveness challenge.
  final bool? livenessVerified;

  final String? notes;

  /// The deterministic document id for a punch on [isoDate].
  static String documentIdFor(String uid, String isoDate) => '${uid}_$isoDate';

  /// A copy carrying a check-out that was just written.
  ///
  /// Used only as a fallback when the post-write re-read fails, so the screen
  /// reflects what was sent rather than reverting to the pre-punch state.
  AttendanceDoc copyWith({
    String? status,
    String? checkOutTime,
    String? checkOutAt,
    String? checkOutPhotoUrl,
    String? checkOutAddress,
    double? checkOutLat,
    double? checkOutLng,
    double? checkOutDistanceMeters,
    double? checkOutZoneRadiusMeters,
    double? checkOutAccuracyMeters,
    String? checkOutDeviceId,
    String? checkInLatEnc,
    String? checkOutLatEnc,
    String? deviceIntegrityCodes,
    bool? deviceIntegrityFlagged,
    bool? livenessVerified,
  }) =>
      AttendanceDoc(
        id: id,
        userId: userId,
        userName: userName,
        employeeNumber: employeeNumber,
        recordDate: recordDate,
        status: status ?? this.status,
        shiftId: shiftId,
        shiftName: shiftName,
        zoneId: zoneId,
        zoneName: zoneName,
        checkInTime: checkInTime,
        checkOutTime: checkOutTime ?? this.checkOutTime,
        checkInAt: checkInAt,
        checkOutAt: checkOutAt ?? this.checkOutAt,
        checkInPhotoUrl: checkInPhotoUrl,
        checkOutPhotoUrl: checkOutPhotoUrl ?? this.checkOutPhotoUrl,
        checkInAddress: checkInAddress,
        checkOutAddress: checkOutAddress ?? this.checkOutAddress,
        checkInLat: checkInLat,
        checkInLng: checkInLng,
        checkInDistanceMeters: checkInDistanceMeters,
        checkInZoneRadiusMeters: checkInZoneRadiusMeters,
        checkInAccuracyMeters: checkInAccuracyMeters,
        checkOutLat: checkOutLat ?? this.checkOutLat,
        checkOutLng: checkOutLng ?? this.checkOutLng,
        checkOutDistanceMeters: checkOutDistanceMeters ?? this.checkOutDistanceMeters,
        checkOutZoneRadiusMeters: checkOutZoneRadiusMeters ?? this.checkOutZoneRadiusMeters,
        checkOutAccuracyMeters: checkOutAccuracyMeters ?? this.checkOutAccuracyMeters,
        checkInDeviceId: checkInDeviceId,
        checkOutDeviceId: checkOutDeviceId ?? this.checkOutDeviceId,
        checkInLatEnc: checkInLatEnc ?? this.checkInLatEnc,
        checkOutLatEnc: checkOutLatEnc ?? this.checkOutLatEnc,
        deviceIntegrityCodes: deviceIntegrityCodes ?? this.deviceIntegrityCodes,
        deviceIntegrityFlagged: deviceIntegrityFlagged ?? this.deviceIntegrityFlagged,
        livenessVerified: livenessVerified ?? this.livenessVerified,
        notes: notes,
      );

  bool get hasCheckIn => checkInTime != null && checkInTime!.trim().isNotEmpty;

  bool get hasCheckOut => checkOutTime != null && checkOutTime!.trim().isNotEmpty;

  /// A check-in that has not yet been closed by a check-out.
  bool get isOpen => hasCheckIn && !hasCheckOut;

  bool get isCompleted => hasCheckIn && hasCheckOut;

  bool get isLate => status == AttendanceStatus.late;

  bool get isOnLeave => status == AttendanceStatus.onLeave;

  /// Whether the check-in left the assigned zone's radius.
  bool get checkInOutsideZone {
    final distance = checkInDistanceMeters;
    final radius = checkInZoneRadiusMeters;
    if (distance == null || radius == null) return false;
    return distance > radius;
  }

  /// Indonesian label for [status].
  String get statusLabel => attendanceStatusLabels[status] ?? status;

  factory AttendanceDoc.fromMap(String id, Map<String, dynamic> map) {
    double? num_(String key) {
      final value = map[key];
      return value is num ? value.toDouble() : null;
    }

    String? str(String key) {
      final value = map[key];
      if (value is! String) return null;
      return value.isEmpty ? null : value;
    }

    return AttendanceDoc(
      id: id,
      userId: (map['userId'] as String?) ?? '',
      userName: (map['userName'] as String?) ?? '',
      employeeNumber: (map['employeeNumber'] as String?)?.toString() ?? '',
      recordDate: (map['recordDate'] as String?) ?? '',
      status: (map['status'] as String?) ?? AttendanceStatus.pending,
      shiftId: str('shiftId'),
      shiftName: str('shiftName'),
      zoneId: str('zoneId'),
      zoneName: str('zoneName'),
      checkInTime: str('checkInTime'),
      checkOutTime: str('checkOutTime'),
      checkInAt: str('checkInAt'),
      checkOutAt: str('checkOutAt'),
      checkInPhotoUrl: str('checkInPhotoUrl'),
      checkOutPhotoUrl: str('checkOutPhotoUrl'),
      checkInAddress: str('checkInAddress'),
      checkOutAddress: str('checkOutAddress'),
      checkInLat: num_('checkInLat'),
      checkInLng: num_('checkInLng'),
      checkInDistanceMeters: num_('checkInDistanceMeters'),
      checkInZoneRadiusMeters: num_('checkInZoneRadiusMeters'),
      checkInAccuracyMeters: num_('checkInAccuracyMeters'),
      checkOutLat: num_('checkOutLat'),
      checkOutLng: num_('checkOutLng'),
      checkOutDistanceMeters: num_('checkOutDistanceMeters'),
      checkOutZoneRadiusMeters: num_('checkOutZoneRadiusMeters'),
      checkOutAccuracyMeters: num_('checkOutAccuracyMeters'),
      checkInDeviceId: str('checkInDeviceId'),
      checkOutDeviceId: str('checkOutDeviceId'),
      checkInLatEnc: str('checkInLatEnc'),
      checkOutLatEnc: str('checkOutLatEnc'),
      deviceIntegrityCodes: str('deviceIntegrityCodes'),
      // A flag absent from an older record is false, not unknown: the punch was
      // simply written before integrity checks existed.
      deviceIntegrityFlagged: map['deviceIntegrityFlagged'] == true,
      livenessVerified:
          map['livenessVerified'] is bool ? map['livenessVerified'] as bool : null,
      notes: str('notes'),
    );
  }

  /// Reads a record straight off a Firestore snapshot.
///
/// An alias for [AttendanceDoc.fromMap] rather than a second implementation: two
/// readers of the same document can drift, and every field that drifts becomes an
/// attendance record that renders blank on the history screen.
factory AttendanceDoc.fromFirestore(String id, Map<dynamic, dynamic> data) =>
      AttendanceDoc.fromMap(id, firestoreData(data));

  @override
  String toString() =>
      'AttendanceDoc($id, $recordDate, $status, in=$checkInTime out=$checkOutTime)';
}

/// Attendance statuses.
///
/// `firestore.rules` constrains a client-created record to `CHECKED_IN` or
/// `LATE`; the rest are written by an administrator after review.
class AttendanceStatus {
  const AttendanceStatus._();

  static const String pending = 'PENDING';
  static const String checkedIn = 'CHECKED_IN';
  static const String completed = 'COMPLETED';
  static const String late = 'LATE';
  static const String earlyLeave = 'EARLY_LEAVE';
  static const String onLeave = 'ON_LEAVE';
  static const String absent = 'ABSENT';

  static const List<String> all = [
    checkedIn,
    completed,
    late,
    earlyLeave,
    onLeave,
    absent,
  ];
}

/// Indonesian labels, matching the dashboard's `STATUS_LABELS`.
const Map<String, String> attendanceStatusLabels = {
  AttendanceStatus.pending: 'Belum absen',
  AttendanceStatus.checkedIn: 'Belum pulang',
  AttendanceStatus.completed: 'Lengkap',
  AttendanceStatus.late: 'Terlambat',
  AttendanceStatus.earlyLeave: 'Pulang awal',
  AttendanceStatus.onLeave: 'Izin',
  AttendanceStatus.absent: 'Belum absen',
};

/// Whether a status describes a day that was actually worked.
bool statusCountsAsPresent(String status) {
  return status == AttendanceStatus.checkedIn ||
      status == AttendanceStatus.completed ||
      status == AttendanceStatus.late ||
      status == AttendanceStatus.earlyLeave;
}

/// Re-exported so the history screen renders a record without importing two
/// libraries for one line.
String formatPunchTime(String? clockTime, String? instant) =>
    formatClockTime(punchInstant(clockTime, instant));