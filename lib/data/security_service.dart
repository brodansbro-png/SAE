import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:safe_device/safe_device.dart';

import '../domain/models/attendance.dart';

// ════════════════════════════════════════════════════════════════════════════
// DeviceIntegrityService
// Tujuan: mendeteksi lingkungan yang tidak dapat dipercaya (root, emulator,
//         developer options aktif) sebelum proses absensi diizinkan.
//
// Advisory, bukan lockout absolut: false-positive lebih berbahaya dari fraud
// karena bisa menghalangi pegawai yang sah. Setiap temuan di-stamp ke punch
// agar administrator bisa mengaudit.
// ════════════════════════════════════════════════════════════════════════════
class DeviceIntegrityService {
  const DeviceIntegrityService();

  static const Severity warning = Severity.warning;
  static const Severity blocking = Severity.blocking;

  Future<IntegrityReport> assess() async {
    final findings = <IntegrityFinding>[];

    // ── Deteksi root / jailbreak ──────────────────────────────────────────
    try {
      final isSafe = await SafeDevice.isSafeDevice;
      if (!isSafe) {
        findings.add(const IntegrityFinding(
          code: IntegrityCode.rootedOrJailbroken,
          severity: blocking,
          message: 'Perangkat terdeteksi sudah di-root atau di-jailbreak.',
        ));
      }
    } catch (_) {
      // Plugin failure bukan bukti manipulasi — abaikan.
    }

    // ── Deteksi emulator (via safe_device, fallback ke heuristik) ─────────
    try {
      final isReal = await SafeDevice.isRealDevice;
      if (!isReal) {
        findings.add(const IntegrityFinding(
          code: IntegrityCode.emulator,
          severity: blocking,
          message: 'Aplikasi dijalankan pada emulator.',
        ));
      }
    } catch (_) {
      if (isProbablyEmulator()) {
        findings.add(const IntegrityFinding(
          code: IntegrityCode.emulator,
          severity: blocking,
          message: 'Aplikasi dijalankan pada emulator (heuristik).',
        ));
      }
    }

    // ── Deteksi developer options / debugger ─────────────────────────────
    try {
      final devOpts = await SafeDevice.isDevelopmentModeEnable;
      if (devOpts) {
        findings.add(const IntegrityFinding(
          code: IntegrityCode.debuggerAttached,
          severity: warning,
          message: 'Developer options aktif pada perangkat ini.',
        ));
      }
    } catch (_) {}

    return IntegrityReport(findings: findings);
  }

  /// Heuristik emulator berbasis environment block Android.
  /// Butuh dua sinyal cocok agar tidak memblokir perangkat sah.
  static bool isProbablyEmulator() {
    if (!_hasEnvironmentBlock) return false;
    final signals = <bool>[
      _modelLooksSynthetic,
      _hasEmulatorFingerprint,
    ];
    return signals.where((v) => v).length >= 2;
  }

  static bool isProbablyDebuggerAttached = false;

  static String get _model =>
      (Platform.environment['MODEL'] ?? '').toLowerCase();

  static bool get _modelLooksSynthetic {
    const markers = ['sdk', 'generic', 'emulator', 'android sdk', 'simulator'];
    return markers.any(_model.contains);
  }

  // ranchu dan goldfish adalah hardware fingerprint AOSP emulator
  static bool get _hasEmulatorFingerprint {
    final fp = (Platform.environment['HARDWARE'] ?? '').toLowerCase();
    return fp == 'ranchu' || fp == 'goldfish';
  }
}

bool get _hasEnvironmentBlock => !Platform.isIOS;

// ════════════════════════════════════════════════════════════════════════════
// PunchCrypto
// AES-256-GCM untuk enkripsi koordinat sebelum disimpan ke Firestore.
//
// Proteksi: riwayat pergerakan pegawai tidak muncul dalam plaintext
// di database dump atau backup bocor.
//
// BUKAN E2E encryption: siapa pun yang bisa menjalankan app bisa dekripsi —
// kunci harus dijangkau client untuk enkripsi.
// ════════════════════════════════════════════════════════════════════════════
class PunchCrypto {
  const PunchCrypto._();

  static const int keyLengthBytes = 32; // AES-256
  static const int macSizeBits = 128;   // GCM authentication tag
  static const int nonceLengthBytes = 12;
  static const String encryptedPrefix = 'enc:v1:';

  // ── Key management via Android Keystore / iOS Keychain ───────────────────
  //
  // `encryptedSharedPreferences` is deliberately NOT set: Jetpack Security, the
  // library behind it, is deprecated by Google and removed in v11. The plugin now
  // migrates existing values to its own ciphers on first access, so leaving the
  // flag off is both the supported path and the forward-compatible one.
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      // `first_unlock` rather than `unlocked`: a shift reminder scheduled while
      // the phone is locked must still be able to read its key. `unlocked_this_device`
      // would exclude the item from a locked backup, which is the one thing
      // worth adding if these keys ever become backup-eligible.
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  static const _keyAlias = 'sae_punch_aes_key_v1';

  /// Mengambil kunci AES dari Keystore/Keychain, atau membuat baru jika belum ada.
  /// Kunci hanya ada satu per instalasi perangkat.
  static Future<Uint8List> loadOrCreateKey() async {
    final existing = await _storage.read(key: _keyAlias);
    if (existing != null && existing.isNotEmpty) {
      try {
        return base64.decode(existing);
      } catch (_) {
        // Kunci korup — hapus dan buat ulang
        await _storage.delete(key: _keyAlias);
      }
    }
    final key = generateKey();
    await _storage.write(key: _keyAlias, value: base64.encode(key));
    return key;
  }

  /// Hapus kunci saat logout untuk keamanan maksimal.
  static Future<void> deleteKey() async {
    await _storage.delete(key: _keyAlias);
  }

  /// Hasilkan kunci AES-256 baru dari CSPRNG OS.
  static Uint8List generateKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(keyLengthBytes, (_) => random.nextInt(256)),
    );
  }

  /// Derivasi kunci dari secret via PBKDF2-HMAC-SHA256.
  /// Dipakai ketika key material berasal dari device identifier (entropi lemah).
  static Uint8List deriveKey(String secret, {int iterations = 100000}) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(utf8.encode(secret), iterations, keyLengthBytes));
    return derivator.process(Uint8List(0));
  }

  /// Enkripsi AES-256-GCM.
  ///
  /// [associatedData] di-bind ke tag autentikasi — ciphertext yang dipindahkan
  /// ke dokumen lain akan gagal autentikasi saat dekripsi.
  static String encrypt({
    required Uint8List key,
    required String plaintext,
    String? associatedData,
  }) {
    final nonce = _randomNonce();
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters<KeyParameter>(
          KeyParameter(key),
          macSizeBits,
          nonce,
          Uint8List.fromList(utf8.encode(associatedData ?? '')),
        ),
      );
    // process() mengembalikan ciphertext + authentication tag
    final sealed = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
    final payload = Uint8List(nonce.length + sealed.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + sealed.length, sealed);
    return '$encryptedPrefix${base64Url.encode(payload)}';
  }

  /// Dekripsi AES-256-GCM. Mengembalikan null jika:
  /// - bukan format ciphertext yang valid
  /// - tag autentikasi gagal (tampered, kunci salah, associated data salah)
  static String? decrypt({
    required Uint8List key,
    required String ciphertext,
    String? associatedData,
  }) {
    if (!ciphertext.startsWith(encryptedPrefix)) return null;
    Uint8List raw;
    try {
      raw = base64Url.decode(ciphertext.substring(encryptedPrefix.length));
    } catch (_) {
      return null;
    }
    if (raw.length <= nonceLengthBytes + macSizeBits ~/ 8) return null;
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters<KeyParameter>(
          KeyParameter(key),
          macSizeBits,
          Uint8List.sublistView(raw, 0, nonceLengthBytes),
          Uint8List.fromList(utf8.encode(associatedData ?? '')),
        ),
      );
    try {
      final opened = cipher.process(Uint8List.sublistView(raw, nonceLengthBytes));
      return utf8.decode(opened);
    } catch (_) {
      // InvalidCipherTextException: kunci salah, tag dipalsukan, atau
      // associated data tidak cocok. Ketiganya diperlakukan sama.
      return null;
    }
  }

  /// Enkripsi pasangan koordinat menjadi satu string.
  static String encryptCoordinates({
    required Uint8List key,
    required double latitude,
    required double longitude,
    String? documentId,
  }) =>
      encrypt(
        key: key,
        plaintext: '$latitude,$longitude',
        associatedData: documentId,
      );

  /// Dekripsi koordinat, mengembalikan (lat, lng) atau null.
  static (double, double)? decryptCoordinates({
    required Uint8List key,
    required String ciphertext,
    String? associatedData,
  }) {
    final plaintext = decrypt(
      key: key,
      ciphertext: ciphertext,
      associatedData: associatedData,
    );
    if (plaintext == null) return null;
    final parts = plaintext.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null) return null;
    return (lat, lng);
  }

  /// Enkripsi field sensitif punch untuk disimpan ke Firestore.
  static Map<String, dynamic> sealAttendance({
    required Uint8List key,
    required String documentId,
    required double? latitude,
    required double? longitude,
  }) {
    if (latitude == null || longitude == null) return {};
    return {
      SealedFields.checkInLatEnc: encryptCoordinates(
        key: key,
        latitude: latitude,
        longitude: longitude,
        documentId: documentId,
      ),
    };
  }

  /// Baca kembali koordinat terenkripsi dari dokumen Firestore.
  static (double, double)? openCoordinates({
    required Uint8List key,
    required String documentId,
    required AttendanceDoc record,
    bool isCheckIn = true,
  }) {
    final sealed = isCheckIn ? record.checkInLatEnc : record.checkOutLatEnc;
    if (sealed == null) return null;
    return decryptCoordinates(
      key: key,
      ciphertext: sealed,
      associatedData: documentId,
    );
  }

  /// Ubah integrity report menjadi fields yang ditulis ke dokumen punch.
  static Map<String, dynamic> describeIntegrity(IntegrityReport report) {
    if (report.isClean) return {};
    return {
      'deviceIntegrityCodes': report.codes,
      'deviceIntegrityFlagged': true,
    };
  }

  static Uint8List _randomNonce() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(nonceLengthBytes, (_) => random.nextInt(256)),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Supporting types
// ════════════════════════════════════════════════════════════════════════════

enum Severity { warning, blocking }

enum IntegrityCode {
  rootedOrJailbroken,
  emulator,
  debuggerAttached,
  mockLocation,
}

class IntegrityFinding {
  const IntegrityFinding({
    required this.code,
    required this.severity,
    required this.message,
  });

  final IntegrityCode code;
  final Severity severity;
  final String message;

  bool get isBlocking => severity == Severity.blocking;
  String get wireCode => code.name;
}

class IntegrityReport {
  const IntegrityReport({required this.findings});
  const IntegrityReport.clean() : findings = const [];

  final List<IntegrityFinding> findings;

  bool get isClean => findings.isEmpty;
  bool get hasBlocking => findings.any((f) => f.isBlocking);
  String get codes => findings.map((f) => f.wireCode).join(',');
  List<IntegrityFinding> get blocking =>
      findings.where((f) => f.isBlocking).toList();
}

class SealedFields {
  const SealedFields._();
  static const String checkInLatEnc = 'checkInLatEnc';
  static const String checkOutLatEnc = 'checkOutLatEnc';
}

class IntegrityFailure implements Exception {
  const IntegrityFailure(this.finding);
  final IntegrityFinding finding;
  String get message => finding.message;

  @override
  String toString() => 'IntegrityFailure(${finding.code.name})';
}
