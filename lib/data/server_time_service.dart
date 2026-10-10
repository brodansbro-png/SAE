import 'package:cloud_firestore/cloud_firestore.dart';

/// Layanan waktu server — mencegah manipulasi jam perangkat.
///
/// Mekanisme:
/// 1. Tulis `FieldValue.serverTimestamp()` ke Firestore.
/// 2. Baca kembali nilai yang dikembalikan server.
/// 3. Hitung delta antara waktu device dan waktu server.
/// 4. Semua validasi window shift memakai `serverTime.now` bukan `DateTime.now()`.
///
/// Mengapa ini aman:
/// - `FieldValue.serverTimestamp()` diisi oleh server Firestore, bukan device.
/// - `checkInAt` / `checkOutAt` di dokumen attendance selalu pakai serverTimestamp
///   → dashboard selalu melihat waktu nyata.
/// - Jika selisih device vs server > 5 menit → punch ditolak + peringatan ditampilkan.
class ServerTimeService {
  ServerTimeService._();
  static final ServerTimeService instance = ServerTimeService._();

  final _db = FirebaseFirestore.instance;

  Duration? _delta;
  static const Duration _maxDelta = Duration(minutes: 5);
  static const String _col = '_time_sync';

  /// Sinkronisasi waktu — dipanggil background saat startup & foreground resume.
  Future<void> sync() async {
    try {
      final ref = _db.collection(_col).doc('probe');
      await ref.set({'t': FieldValue.serverTimestamp()});
      final snap = await ref.get();
      final ts = snap.data()?['t'] as Timestamp?;
      if (ts == null) return;
      _delta = ts.toDate().toLocal().difference(DateTime.now());
    } catch (_) {}
  }

  /// Estimasi waktu server saat ini.
  DateTime get now {
    final d = _delta;
    return d == null ? DateTime.now() : DateTime.now().add(d);
  }

  /// True jika jam device terdeteksi dimanipulasi (selisih > 5 menit).
  bool get isSuspicious {
    final d = _delta;
    return d != null && d.abs() > _maxDelta;
  }

  /// Pesan untuk UI jika waktu mencurigakan.
  String? get warningMessage {
    if (!isSuspicious) return null;
    final d = _delta!;
    final behind = d.isNegative;
    return 'Jam perangkat ${behind ? "tertinggal" : "lebih cepat"} '
        '${d.abs().inMinutes} menit dari server. '
        'Aktifkan "Tanggal & waktu otomatis" di pengaturan perangkat.';
  }

  bool get hasSynced => _delta != null;
  Duration? get delta => _delta;
}
