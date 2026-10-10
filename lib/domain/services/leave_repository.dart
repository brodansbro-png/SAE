import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import '../../data/cloudinary_service.dart';
import '../models/permission.dart';
import '../models/user.dart' as sae;
import 'firestore_map.dart';

/// Semua operasi untuk koleksi `permissions` (pengajuan izin/cuti).
///
/// Seorang pegawai bisa:
///   - Mengajukan permintaan baru (status: PENDING)
///   - Membatalkan permintaan yang sudah diajukan (status: CANCELLED)
///   - Membaca riwayat permintaannya sendiri
///
/// Admin bisa approve/reject — itu ditangani di SAE-Dashboard, bukan di sini.
class LeaveRepository {
  LeaveRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    CloudinaryService? cloudinary,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _cloudinary = cloudinary ?? CloudinaryService.fromEnv();

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final CloudinaryService _cloudinary;

  static const _uuid = Uuid();

  // ── Baca ──────────────────────────────────────────────────────────────

  /// Riwayat pengajuan izin/cuti milik user yang login.
  Future<List<PermissionDoc>> myRequests({int limit = 30}) async {
    final uid = _requireUid();
    final snaps = await _db
        .collection('permissions')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    return snaps.docs.map((d) => fromSnapshot(d, PermissionDoc.fromFirestore)).toList();
  }

  /// Stream pengajuan aktif (PENDING) milik user saat ini.
  Stream<List<PermissionDoc>> watchPendingRequests() {
    final uid = _requireUid();
    return _db
        .collection('permissions')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'PENDING')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => fromSnapshot(d, PermissionDoc.fromFirestore)).toList());
  }

  /// Cek apakah ada izin yang disetujui yang mencakup tanggal tertentu.
  Future<PermissionDoc?> approvedLeaveForDate(String isoDate) async {
    final uid = _requireUid();
    final snaps = await _db
        .collection('permissions')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'APPROVED')
        .where('startDate', isLessThanOrEqualTo: isoDate)
        .get();

    for (final snap in snaps.docs) {
      final doc = fromSnapshot(snap, PermissionDoc.fromFirestore);
      if (doc.endDate.compareTo(isoDate) >= 0) return doc;
    }
    return null;
  }

  // ── Tulis ─────────────────────────────────────────────────────────────

  /// Buat pengajuan izin/cuti baru.
  Future<LeaveResult> submit({
    required sae.UserDoc user,
    required String permissionTypeId,
    required String permissionTypeName,
    required String startDate,    // yyyy-MM-dd
    required String endDate,      // yyyy-MM-dd
    required int dayCount,
    required String reason,
    File? attachmentFile,
    void Function(double)? onUploadProgress,
  }) async {
    final uid = _requireUid();
    final permissionId = _uuid.v4();

    // ── Upload lampiran jika ada ───────────────────────────────────────
    String? attachmentUrl;
    if (attachmentFile != null) {
      final result = await _cloudinary.uploadLeaveAttachment(
        attachmentFile,
        userId: uid,
        permissionId: permissionId,
        onProgress: onUploadProgress,
      );
      if (!result.isSuccess) {
        return LeaveResult.failure(
          'Gagal mengunggah lampiran: ${result.error}',
        );
      }
      attachmentUrl = result.url;
    }

    // ── Validasi sederhana ────────────────────────────────────────────
    if (reason.trim().length < 5) {
      return const LeaveResult.failure('Alasan terlalu singkat (minimal 5 karakter).');
    }

    final payload = <String, dynamic>{
      'id': permissionId,
      'userId': uid,
      'userName': user.displayName,
      'employeeNumber': user.employeeNumber,
      'permissionTypeId': permissionTypeId,
      'permissionTypeName': permissionTypeName,
      'startDate': startDate,
      'endDate': endDate,
      'dayCount': dayCount,
      'reason': reason.trim(),
      'attachmentUrl': attachmentUrl,
      'status': 'PENDING',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await _db.collection('permissions').doc(permissionId).set(payload);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return const LeaveResult.failure(
          'Tidak diizinkan mengajukan izin. Hubungi administrator.',
        );
      }
      return LeaveResult.failure('Gagal mengajukan izin: ${e.message}');
    }

    return const LeaveResult.success('Pengajuan izin berhasil dikirim.');
  }

  /// Batalkan pengajuan yang statusnya masih PENDING.
  Future<LeaveResult> cancel(String permissionId) async {
    try {
      await _db.collection('permissions').doc(permissionId).update({
        'status': 'CANCELLED',
        'cancelledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return const LeaveResult.success('Pengajuan berhasil dibatalkan.');
    } on FirebaseException catch (e) {
      return LeaveResult.failure('Gagal membatalkan: ${e.message}');
    }
  }

  // ── Utilitas privat ───────────────────────────────────────────────────

  String _requireUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Tidak ada pengguna yang login.');
    return uid;
  }
}

class LeaveResult {
  const LeaveResult.success(this.message) : error = null;
  const LeaveResult.failure(this.error) : message = '';

  final String message;
  final String? error;

  bool get success => error == null;
}
