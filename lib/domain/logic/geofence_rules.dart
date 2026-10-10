import '../logic/shift_rules.dart' show PunchEvaluation, PunchBlockReason;
import '../logic/geo.dart';

/// Attendance zone, mirroring `settings/zones/{id}`.
class Zone {
  const Zone({
    required this.id,
    required this.name,
    this.address,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.isActive,
  });

  final String id;
  final String name;

  /// Shown under the zone name and on the map picker.
  final String? address;

  final double latitude;
  final double longitude;

  /// Radius in metres. `firestore.rules` locks this to 10–2000.
  final double radiusMeters;

  final bool isActive;

  /// Radius bounds shared with `firestore.rules` and the dashboard slider.
  static const int minRadiusMeters = 10;
  static const int maxRadiusMeters = 2000;

  /// Whether the coordinates and radius are usable for a geofence decision.
  ///
  /// A zone with `0, 0` or a 100 km radius reads as valid on the dashboard but
  /// silently rejects or rubber-stamps every punch, so it is refused here
  /// rather than discovered by an employee standing outside the office.
  bool get isUsable =>
      isValidCoordinate(latitude, longitude) &&
      radiusMeters >= minRadiusMeters &&
      radiusMeters <= maxRadiusMeters;

  factory Zone.fromMap(String id, Map<String, dynamic> map) => Zone(
        id: id,
        name: (map['name'] as String?)?.trim().isNotEmpty == true
            ? (map['name'] as String).trim()
            : 'Zona tanpa nama',
        address: map['address'] as String?,
        latitude: _toDouble(map['latitude']),
        longitude: _toDouble(map['longitude']),
        radiusMeters: _toDouble(map['radiusMeters']),
        isActive: map['isActive'] != false,
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        if (address != null && address!.trim().isNotEmpty) 'address': address,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters.round(),
        'isActive': isActive,
      };

  @override
  String toString() => 'Zone($id, $name, ${radiusMeters.round()} m)';
}

double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? double.nan;
  return double.nan;
}

/// Whether the OS reported this fix as injected rather than measured.
///
/// The Android framework exposes `Location.isFromMockProvider`, which is true
/// for a fix that came from a mock-location app, an emulator's location setting,
/// or `adb`-injected coordinates. It is not sufficient on its own — a determined
/// attacker can install a provider the OS does not flag, and some OEM ROMs set
/// the flag spuriously — so it is combined with [isNullIsland] and the accuracy
/// ceiling rather than trusted alone.
class FixTrust {
  const FixTrust._();

  /// Whether the platform can report mock provenance at all.
  ///
  /// iOS has no equivalent API: Core Location gives no indication that a fix was
  /// injected, so the check is Android-only and the simulator case is covered by
  /// the device-integrity checks instead.
  static bool get isMockDetectionSupported => !isApplePlatform;

  /// Whether [isApplePlatform], overridable so the branch is testable.
  static bool isApplePlatform = false;

  /// Whether the fix must be refused outright.
  ///
  /// A mock-reported position is *never* acceptable, as opposed to the
  /// accuracy checks which merely refuse to guess.
  static bool isUntrusted({required bool osReportedMock, required bool nullIsland}) =>
      osReportedMock || nullIsland;
}

/// A single GPS reading, decoupled from the platform plugin.
///
/// `geolocator` types are kept out of the domain layer so the geofence rules can
/// be unit-tested with hand-written fixes — including the degenerate ones that
/// are hard to reproduce on a real device.
class Fix {
  const Fix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    this.altitudeMeters,
    this.timestamp,
    this.isMocked = false,
  });

  final double latitude;
  final double longitude;

  /// Horizontal accuracy as a radius of uncertainty, in metres.
  ///
  /// Reported by the OS rather than measured here, and therefore only as
  /// trustworthy as the platform — see `README.md` under known limitations.
  final double accuracyMeters;

  final double? altitudeMeters;
  final DateTime? timestamp;

  /// Whether the OS reported this fix as injected by a mock-location provider.
  ///
  /// Always false on iOS, where Core Location exposes no such signal; that
  /// platform is covered by the device-integrity checks instead.
  final bool isMocked;

  bool get hasCoordinates => isValidCoordinate(latitude, longitude);

  /// Whether this fix may be used to certify a zone at all.
  bool get isTrusted => !FixTrust.isUntrusted(
        osReportedMock: isMocked,
        nullIsland: isNullIsland(latitude, longitude),
      );
}

/// Decides whether a punch's position satisfies the zone geofence.
///
/// This mirrors `com.sae.presensi.domain.Geofence` from the original Kotlin app,
/// which was lost with it. It uses the same haversine implementation as the
/// dashboard (`geo.dart`), so the distance recorded on a punch is the distance
/// the dashboard will recompute from the stored coordinates.
///
/// The geofence is enforced **here, on the device**, because Firestore has no
/// geospatial primitives — `firestore.rules` cannot compare two coordinate
/// pairs. That is a real trust boundary. It is made auditable rather than
/// merely convenient by recording the measured distance and the radius it was
/// compared against on every punch, and by appending each punch to
/// `activity_logs`.
class GeofenceRules {
  const GeofenceRules();

  /// Refuses a fix whose reported accuracy is worse than
  /// [maxAcceptableAccuracyMeters].
  ///
  /// This is the mitigation the Kotlin app also relied on: a fix that claims a
  /// kilometre of uncertainty cannot honestly certify a 50 m zone, so it is
  /// treated as no fix at all rather than as a pass.
  static const double maxAcceptableAccuracyMeters = 100.0;

  /// Evaluates a punch position against [zone].
  ///
  /// Order matters. The zone's own configuration is checked before the fix, so
  /// a misconfigured zone produces an actionable message for the administrator
  /// instead of telling the employee their GPS is bad.
  PunchEvaluation evaluate({
    required Zone? zone,
    required Fix? fix,
  }) {
    if (zone == null) {
      return PunchEvaluation.blocked(
        PunchBlockReason.noZone,
        'Zona absensi belum ditentukan. Hubungi administrator.',
      );
    }
    if (!zone.isActive) {
      return PunchEvaluation.blocked(
        PunchBlockReason.zoneInactive,
        'Zona "${zone.name}" sedang dinonaktifkan.',
      );
    }
    if (!zone.isUsable) {
      return PunchEvaluation.blocked(
        PunchBlockReason.zoneMisconfigured,
        'Zona "${zone.name}" tidak memiliki koordinat atau radius yang valid. '
        'Hubungi administrator.',
      );
    }
    if (fix == null) {
      return PunchEvaluation.blocked(
        PunchBlockReason.fixUnreliable,
        'Lokasi belum dapat ditentukan. Pastikan GPS dalam keadaan aktif.',
      );
    }

    final distance = haversineMeters(
      fix.latitude,
      fix.longitude,
      zone.latitude,
      zone.longitude,
    );

    if (distance.isNaN) {
      return PunchEvaluation.blocked(
        PunchBlockReason.fixUnreliable,
        'Lokasi tidak dapat dihitung. Coba pindah ke area dengan sinyal GPS '
        'yang lebih baik.',
      );
    }

    if (isNullIsland(fix.latitude, fix.longitude)) {
      return PunchEvaluation.blocked(
        PunchBlockReason.mockLocation,
        'Lokasi terdeteksi sebagai lokasi palsu (0, 0). Matikan fitur mock '
        'location pada perangkat Anda.',
        distanceMeters: distance,
      );
    }

    // The OS's own mock-provider flag, checked separately from the 0,0
    // fingerprint above because the two come from different signals: a mock app
    // can be configured to report a plausible coordinate, and refusing only on
    // 0,0 would miss it entirely.
    if (fix.isMocked) {
      return PunchEvaluation.blocked(
        PunchBlockReason.mockLocation,
        'Sistem mendeteksi bahwa lokasi ini berasal dari aplikasi Fake GPS. '
        'Matikan lokasi palsu lalu coba lagi.',
        distanceMeters: distance,
      );
    }

    // Accuracy is checked before the radius comparison, but the distance is
    // still reported so the UI can show how far off the reading was.
    if (!fix.accuracyMeters.isFinite || fix.accuracyMeters < 0) {
      return PunchEvaluation.blocked(
        PunchBlockReason.fixUnreliable,
        'Akurasi lokasi tidak terbaca. Coba ulangi beberapa saat lagi.',
        distanceMeters: distance,
      );
    }

    if (fix.accuracyMeters > maxAcceptableAccuracyMeters) {
      return PunchEvaluation.blocked(
        PunchBlockReason.fixUnreliable,
        'Akurasi GPS terlalu rendah (±${fix.accuracyMeters.round()} m). '
        'Tunggu hingga sinyal GPS membaik, lalu coba lagi.',
        distanceMeters: distance,
      );
    }

    if (distance > zone.radiusMeters) {
      return PunchEvaluation.blocked(
        PunchBlockReason.outsideZone,
        'Anda berada ${formatDistance(distance)} dari pusat zona '
        '"${zone.name}". Batas radius ${formatDistance(zone.radiusMeters)}.',
        distanceMeters: distance,
      );
    }

    return PunchEvaluation.allowed(
      'CHECKED_IN',
      distanceMeters: distance,
      message: 'Lokasi valid — ${formatDistance(distance)} dari pusat zona.',
    );
  }
}