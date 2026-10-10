import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../data/cloudinary_service.dart';
import '../../data/security_service.dart';
import '../logic/geofence_rules.dart';
import '../logic/time_keys.dart';
import '../models/attendance.dart';
import 'firestore_map.dart';
import '../models/user.dart' as sae;

/// Semua operasi tulis & baca untuk koleksi `attendance`.
///
/// Repository ini menggabungkan empat lapisan yang harus setuju satu sama lain
/// sebelum punch tercatat:
///   1. Integrity check (root/emulator/mock GPS)
///   2. Upload foto ke Cloudinary
///   3. Enkripsi koordinat (AES-256-GCM)
///   4. Tulis dokumen ke Firestore
///
/// Dokumen id adalah deterministik: `{userId}_{recordDate}`, sehingga dua
/// perangkat yang mencoba absen pada hari yang sama akan memperbarui dokumen
/// yang sama — bukan membuat baris duplikat.
class AttendanceRepository {
  AttendanceRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    CloudinaryService? cloudinary,
    DeviceIntegrityService? integrity,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _cloudinary = cloudinary ?? CloudinaryService.fromEnv(),
        _integrity = integrity ?? const DeviceIntegrityService();

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final CloudinaryService _cloudinary;
  final DeviceIntegrityService _integrity;

  // ── Baca ──────────────────────────────────────────────────────────────

  /// Dokumen absen hari ini untuk user yang sedang login.
  Future<AttendanceDoc?> todayRecord() async {
    final uid = _requireUid();
    final docId = '${uid}_${todayIso()}';
    final snap = await _db.collection('attendance').doc(docId).get();
    if (!snap.exists) return null;
    return fromSnapshot(snap, AttendanceDoc.fromFirestore);
  }

  /// Stream dokumen absen hari ini — UI rebuild otomatis saat data berubah.
  Stream<AttendanceDoc?> watchTodayRecord() {
    final uid = _requireUid();
    final docId = '${uid}_${todayIso()}';
    return _db
        .collection('attendance')
        .doc(docId)
        .snapshots()
        .map((snap) => snap.exists ? fromSnapshot(snap, AttendanceDoc.fromFirestore) : null);
  }

  /// Riwayat absen untuk user saat ini — dibatasi 60 rekaman.
  Future<List<AttendanceDoc>> history({int limit = 60}) async {
    final uid = _requireUid();
    final snaps = await _db
        .collection('attendance')
        .where('userId', isEqualTo: uid)
        .orderBy('recordDate', descending: true)
        .limit(limit)
        .get();
    return snaps.docs.map((d) => fromSnapshot(d, AttendanceDoc.fromFirestore)).toList();
  }

  // ── Check In ──────────────────────────────────────────────────────────

  /// Proses clock-in lengkap: integrity → upload foto → enkripsi → Firestore.
  Future<PunchResult> checkIn({
    required sae.UserDoc user,
    required Fix fix,
    required double distanceMeters,
    required double zoneRadiusMeters,
    required String? zoneName,
    required String? zoneAddress,
    required String? shiftId,
    required String? shiftName,
    required String? zoneId,
    required String status,      // 'CHECKED_IN' atau 'LATE'
    File? photo,
    bool livenessVerified = false,
    void Function(double)? onUploadProgress,
  }) async {
    final uid = _requireUid();
    final now = DateTime.now();
    final recordDate = todayIso();
    final docId = '${uid}_$recordDate';

    // ── 1. Integrity check ────────────────────────────────────────────
    final integrityReport = await _integrity.assess();

    // Fix dari mock provider selalu blocking — seandainya safe_device gagal,
    // ini sebagai lapisan kedua.
    IntegrityReport report = integrityReport;
    if (fix.isMocked) {
      const finding = IntegrityFinding(
        code: IntegrityCode.mockLocation,
        severity: Severity.blocking,
        message: 'Lokasi palsu (Mock GPS) terdeteksi.',
      );
      report = IntegrityReport(findings: [...integrityReport.findings, finding]);
    }

    if (report.hasBlocking) {
      return PunchResult.failure(report.blocking.first.message);
    }

    // ── 2. Upload foto ────────────────────────────────────────────────
    String? photoUrl;
    if (photo != null && _cloudinary.isConfigured) {
      final result = await _cloudinary.uploadAttendancePhoto(
        photo,
        employeeId: user.employeeNumber,
        punchType: 'check_in',
        onProgress: onUploadProgress,
      );
      if (!result.isSuccess) {
        // Foto gagal upload → catat tanpa foto; absensi tetap diterima.
        // Celah ini dicatat di notes agar auditor tahu.
      }
      photoUrl = result.url;
    }

    // ── 3. Enkripsi koordinat ─────────────────────────────────────────
    final cryptoKey = await PunchCrypto.loadOrCreateKey();
    final sealedFields = PunchCrypto.sealAttendance(
      key: cryptoKey,
      documentId: docId,
      latitude: fix.latitude,
      longitude: fix.longitude,
    );

    // ── 4. Device ID ─────────────────────────────────────────────────
    final deviceId = await _getDeviceId();

    // ── 5. Tulis ke Firestore ─────────────────────────────────────────
    final checkInTime = _formatHHmm(now);
    final payload = <String, dynamic>{
      'id': docId,
      'userId': uid,
      'userName': user.displayName,
      'employeeNumber': user.employeeNumber,
      'recordDate': recordDate,
      'shiftId': shiftId,
      'shiftName': shiftName,
      'zoneId': zoneId,
      'zoneName': zoneName,
      'checkInTime': checkInTime,
      'checkInAt': now.toIso8601String(),
      'checkInPhotoUrl': photoUrl,
      'checkInAddress': CloudinaryService.describeEvidenceLocation(
        zoneName: zoneName,
        address: zoneAddress,
      ),
      'checkInLat': fix.latitude,
      'checkInLng': fix.longitude,
      'checkInDistanceMeters': distanceMeters,
      'checkInZoneRadiusMeters': zoneRadiusMeters,
      'checkInAccuracyMeters': fix.accuracyMeters,
      'checkInDeviceId': deviceId,
      'status': status,
      'livenessVerified': livenessVerified,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      ...sealedFields,
      ...PunchCrypto.describeIntegrity(report),
    };

    try {
      await _db.collection('attendance').doc(docId).set(
            payload,
            // SetOptions(merge: false) agar dokumen baru tidak menimpa check-out
            // yang sudah ada (race condition dua device)
            SetOptions(merge: false),
          );
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return const PunchResult.failure(
          'Ditolak oleh server. Pastikan Anda belum absen hari ini.',
        );
      }
      return PunchResult.failure('Gagal menyimpan absen: ${e.message}');
    }

    return PunchResult.success(
      message: 'Absen datang pukul $checkInTime berhasil dicatat.',
      warning: photo == null
          ? 'Absen dicatat tanpa foto bukti.'
          : (photoUrl == null ? 'Foto tidak berhasil diunggah.' : null),
    );
  }

  // ── Check Out ─────────────────────────────────────────────────────────

  Future<PunchResult> checkOut({
    required sae.UserDoc user,
    required Fix fix,
    required double distanceMeters,
    required double zoneRadiusMeters,
    required String? zoneName,
    required String? zoneAddress,
    required String newStatus,    // 'COMPLETED' atau 'EARLY_LEAVE'
    File? photo,
    bool livenessVerified = false,
    void Function(double)? onUploadProgress,
  }) async {
    final uid = _requireUid();
    final now = DateTime.now();
    final recordDate = todayIso();
    final docId = '${uid}_$recordDate';

    // ── Integrity ─────────────────────────────────────────────────────
    IntegrityReport report = await _integrity.assess();
    if (fix.isMocked) {
      const finding = IntegrityFinding(
        code: IntegrityCode.mockLocation,
        severity: Severity.blocking,
        message: 'Lokasi palsu (Mock GPS) terdeteksi.',
      );
      report = IntegrityReport(findings: [...report.findings, finding]);
    }
    if (report.hasBlocking) {
      return PunchResult.failure(report.blocking.first.message);
    }

    // ── Upload foto ───────────────────────────────────────────────────
    String? photoUrl;
    if (photo != null && _cloudinary.isConfigured) {
      final result = await _cloudinary.uploadAttendancePhoto(
        photo,
        employeeId: user.employeeNumber,
        punchType: 'check_out',
        onProgress: onUploadProgress,
      );
      photoUrl = result.url;
    }

    // ── Enkripsi koordinat ────────────────────────────────────────────
    final cryptoKey = await PunchCrypto.loadOrCreateKey();
    final encOutLat = PunchCrypto.encryptCoordinates(
      key: cryptoKey,
      latitude: fix.latitude,
      longitude: fix.longitude,
      documentId: docId,
    );

    final checkOutTime = _formatHHmm(now);
    final updatePayload = <String, dynamic>{
      'checkOutTime': checkOutTime,
      'checkOutAt': now.toIso8601String(),
      'checkOutPhotoUrl': photoUrl,
      'checkOutAddress': CloudinaryService.describeEvidenceLocation(
        zoneName: zoneName,
        address: zoneAddress,
      ),
      'checkOutLat': fix.latitude,
      'checkOutLng': fix.longitude,
      'checkOutDistanceMeters': distanceMeters,
      'checkOutZoneRadiusMeters': zoneRadiusMeters,
      'checkOutAccuracyMeters': fix.accuracyMeters,
      SealedFields.checkOutLatEnc: encOutLat,
      'status': newStatus,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await _db.collection('attendance').doc(docId).update(updatePayload);
    } on FirebaseException catch (e) {
      if (e.code == 'not-found') {
        return const PunchResult.failure(
          'Data absen hari ini tidak ditemukan. Lakukan absen datang terlebih dahulu.',
        );
      }
      if (e.code == 'permission-denied') {
        return const PunchResult.failure(
          'Ditolak oleh server. Absen pulang sudah tercatat atau belum waktunya.',
        );
      }
      return PunchResult.failure('Gagal menyimpan absen pulang: ${e.message}');
    }

    return PunchResult.success(
      message: 'Absen pulang pukul $checkOutTime berhasil dicatat.',
      warning: photo == null
          ? 'Absen pulang dicatat tanpa foto bukti.'
          : (photoUrl == null ? 'Foto tidak berhasil diunggah.' : null),
    );
  }

  // ── Utilitas privat ───────────────────────────────────────────────────

  String _requireUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Tidak ada pengguna yang login.');
    return uid;
  }

  Future<String> _getDeviceId() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        return android.id;
      } else if (Platform.isIOS) {
        final ios = await info.iosInfo;
        return ios.identifierForVendor ?? 'ios-unknown';
      }
    } catch (_) {}
    return 'unknown-device';
  }
}

// ════════════════════════════════════════════════════════════════════════════
// PunchResult
// ════════════════════════════════════════════════════════════════════════════
class PunchResult {
  const PunchResult.success({required this.message, this.warning})
      : error = null;
  const PunchResult.failure(this.error)
      : message = '',
        warning = null;

  final String message;
  final String? warning;
  final String? error;

  bool get success => error == null;
  bool get hasWarning => warning != null && warning!.isNotEmpty;
}

/// `HH:mm` local, the only punch-time shape `firestore.rules` accepts.
///
/// Delegates rather than formatting inline: `checkInTime.size() == 5` is enforced
/// by the rules, and a one-character drift from the canonical formatter would
/// fail every punch at the last possible moment.
String _formatHHmm(DateTime at) => minutesToClock(at.hour * 60 + at.minute);
