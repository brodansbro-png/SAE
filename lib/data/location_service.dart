import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../domain/logic/geofence_rules.dart';

// ════════════════════════════════════════════════════════════════════════════
// LocationService
// Membaca posisi GPS untuk keputusan geofence, mendeteksi mock location,
// dan menyediakan stream posisi untuk readout jarak real-time di layar absen.
//
// Geofence diputuskan di perangkat karena Firestore tidak punya primitif
// geospatial. Itu adalah trust boundary nyata — ditutup dengan menyimpan
// jarak terukur dan radius yang dibandingkan pada setiap punch, bukan dengan
// berpura-pura keputusan ada di server.
// ════════════════════════════════════════════════════════════════════════════
enum LocationUnavailable {
  /// Location services dimatikan di level sistem.
  serviceDisabled,

  /// Izin ditolak; OS akan menanyakan lagi.
  permissionDenied,

  /// Izin ditolak permanen ("jangan tanya lagi").
  permissionDeniedForever,

  /// OS melaporkan lokasi tidak tersedia saat ini.
  unavailable,

  /// Fix tidak bisa diperoleh dalam batas waktu.
  timedOut,
}

class LocationService {
  LocationService();

  /// Akurasi maksimal yang masih bisa diterima untuk sertifikasi zone.
  /// Lokasi "perkiraan" Android tidak cukup teliti untuk membuktikan kehadiran.
  static const double maxAcceptableAccuracyMeters = 100.0;

  /// Batas waktu mendapatkan fix GPS.
  static const Duration fixTimeout = Duration(seconds: 20);

  /// Jarak filter stream — 0 agar readout konvergen tiap fix, bukan satu lompatan besar.
  static const int distanceFilterMeters = 0;

  // ── Permission & service check ─────────────────────────────────────────

  Future<void> ensureReady() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationFailure(LocationUnavailable.serviceDisabled);
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      throw const LocationFailure(LocationUnavailable.permissionDenied);
    }
    if (perm == LocationPermission.deniedForever) {
      throw const LocationFailure(LocationUnavailable.permissionDeniedForever);
    }
  }

  Future<bool> openSettings() => Geolocator.openAppSettings();
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  // ── Single fix ─────────────────────────────────────────────────────────

  /// Satu pembacaan posisi, sudah divalidasi akurasi.
  ///
  /// Mengembalikan null ketika fix tidak bisa diperoleh tanpa melempar
  /// exception — "belum ada fix" adalah kondisi normal pada cold start.
  Future<Fix?> currentFix({DateTime? now}) async {
    try {
      await ensureReady();
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          // Fix segar diperlukan — cache posisi dari kantor yang ditinggalkan
          // sejam lalu akan geofence ke tempat yang salah.
          timeLimit: fixTimeout,
        ),
      );
      return Fix(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracyMeters: pos.accuracy,
        altitudeMeters: pos.altitude,
        timestamp: pos.timestamp,
        // isFromMockProvider: flag platform Android untuk fake GPS.
        // Di iOS Core Location tidak punya equivalent — safe_device cover itu.
        isMocked: _isMocked(pos),
      );
    } on LocationFailure {
      rethrow;
    } on TimeoutException {
      throw const LocationFailure(LocationUnavailable.timedOut);
    } on LocationServiceDisabledException {
      throw const LocationFailure(LocationUnavailable.serviceDisabled);
    } on PermissionDeniedException {
      throw const LocationFailure(LocationUnavailable.permissionDenied);
    } catch (_) {
      // Platform failure lain → null (geofence akan menolak punch)
      return null;
    }
  }

  // ── Streaming fixes ────────────────────────────────────────────────────

  /// Stream posisi untuk readout jarak live di layar absen.
  Stream<Fix?> watchFixes() {
    late StreamController<Fix?> controller;
    StreamSubscription<Position>? sub;

    controller = StreamController<Fix?>.broadcast(
      onListen: () async {
        try {
          await ensureReady();
          sub = Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: distanceFilterMeters,
            ),
          ).listen(
            (pos) => controller.add(Fix(
              latitude: pos.latitude,
              longitude: pos.longitude,
              accuracyMeters: pos.accuracy,
              altitudeMeters: pos.altitude,
              timestamp: pos.timestamp,
              isMocked: _isMocked(pos),
            )),
            onError: (_) => controller.add(null),
          );
        } on LocationFailure {
          controller.add(null);
        } catch (_) {
          controller.add(null);
        }
      },
      onCancel: () async {
        await sub?.cancel();
        sub = null;
      },
    );

    return controller.stream;
  }

  // ── Validasi fix ───────────────────────────────────────────────────────

  /// Fix layak dipakai untuk sertifikasi zone jika:
  /// - punya koordinat valid
  /// - TIDAK berasal dari mock provider (Fake GPS)
  /// - akurasi di dalam batas yang diterima
  static bool isFixAcceptable(Fix fix) =>
      fix.hasCoordinates &&
      fix.isTrusted &&
      fix.accuracyMeters.isFinite &&
      fix.accuracyMeters >= 0 &&
      fix.accuracyMeters <= maxAcceptableAccuracyMeters;

  /// Baca flag mock location dari Position via reflection.
  /// Reflection karena `isMocked` tidak ada di iOS — TypeError ditangkap.
  static bool _isMocked(Position pos) {
    try {
      return pos.isMocked == true;
    } catch (_) {
      return false;
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════
// LocationFailure
// ════════════════════════════════════════════════════════════════════════════
class LocationFailure implements Exception {
  const LocationFailure(this.reason);

  final LocationUnavailable reason;

  String get message {
    switch (reason) {
      case LocationUnavailable.serviceDisabled:
        return 'Lokasi dimatikan di perangkat ini. Aktifkan GPS terlebih dahulu.';
      case LocationUnavailable.permissionDenied:
        return 'Aplikasi membutuhkan izin lokasi untuk memverifikasi absensi.';
      case LocationUnavailable.permissionDeniedForever:
        return 'Izin lokasi ditolak permanen. Buka pengaturan aplikasi untuk mengaktifkannya.';
      case LocationUnavailable.unavailable:
        return 'Lokasi belum tersedia. Pindah ke area dengan sinyal GPS lebih baik.';
      case LocationUnavailable.timedOut:
        return 'Waktu mencari sinyal GPS habis. Silakan coba lagi.';
    }
  }

  bool get isRetryable =>
      reason == LocationUnavailable.unavailable ||
      reason == LocationUnavailable.timedOut;

  @override
  String toString() => 'LocationFailure(${reason.name})';
}
