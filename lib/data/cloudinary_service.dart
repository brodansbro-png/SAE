import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;

import '../domain/logic/geo.dart';
import 'transport_security.dart';

/// Upload foto absensi & lampiran izin ke Cloudinary.
///
/// ── Tentang API Secret ───────────────────────────────────────────────────
/// Tidak ada `api_secret` di sini, dan tidak boleh ada di app mobile.
/// Binary yang berjalan di perangkat pengguna bisa didecompile; secret yang
/// tersimpan di binary bukan rahasia. Secret tersebut akan memberi siapa pun
/// yang mendapatkannya kemampuan menghapus atau menggantikan semua foto absensi.
///
/// Yang dipakai adalah **unsigned upload preset**. Preset ini hanya bisa
/// upload — tidak bisa baca, timpa, atau hapus — dan batasannya
/// (format, ukuran, folder) ada di Cloudinary console, bukan di binary.
/// ── Upload ber-tanda (Signed Upload) ─────────────────────────────────────
/// Jika dibutuhkan (misalnya: preset perlu konfigurasi ketat), buat Firebase
/// Cloud Function yang menerima metadata, menghitung signature dengan
/// api_secret, lalu mengembalikan signature ke app. App kirim signature
/// bersama upload. Secret tidak pernah meninggalkan server.
class CloudinaryService {
  CloudinaryService({
    required this.cloudName,
    required this.uploadPreset,
    required this.leavePreset,
  });

  final String cloudName;
  final String uploadPreset;   // preset untuk foto absensi
  final String leavePreset;    // preset untuk lampiran izin/cuti

  // ── --dart-define constants (compile-time) ────────────────────────────
  static const String _dCloudName  = String.fromEnvironment('CLOUDINARY_CLOUD_NAME');
  static const String _dPreset     = String.fromEnvironment('CLOUDINARY_UPLOAD_PRESET');
  static const String _dLeave      = String.fromEnvironment('CLOUDINARY_LEAVE_PRESET');

  static String _v(String dartVal, String dotenvKey) {
    if (dartVal.isNotEmpty) return dartVal;
    try { return dotenv.env[dotenvKey] ?? ''; } catch (_) { return ''; }
  }

  /// Named identically to the constructor used elsewhere in the app, so a caller
  /// cannot accidentally pick the dotenv path in a context where no `.env` is
  /// loaded — `fromEnv` falls back silently, which is right for development.
  factory CloudinaryService.fromEnvironment() => CloudinaryService.fromEnv();

  /// Read from `--dart-define` at compile time, falling back to `flutter_dotenv`.
  ///
  /// The compile-time value is preferred deliberately: it is inlined into the
  /// binary, so a stray `.env` shipped inside the app bundle cannot redirect a
  /// production upload. The dotenv path exists for development, where re-reading
  /// `.env` beats recompiling the whole app.
  factory CloudinaryService.fromEnv() => CloudinaryService(
        cloudName:    _v(_dCloudName, 'CLOUDINARY_CLOUD_NAME'),
        uploadPreset: _v(_dPreset,    'CLOUDINARY_UPLOAD_PRESET'),
        leavePreset:  _v(_dLeave,     'CLOUDINARY_LEAVE_PRESET'),
      );

  bool get isConfigured =>
      cloudName.trim().isNotEmpty && uploadPreset.trim().isNotEmpty;

  /// Shown when an upload cannot be attempted at all.
  ///
  /// Surfaced on the attendance screen rather than only at upload time, so a
  /// misconfigured build fails with an actionable message instead of accepting a
  /// punch whose evidence silently vanished.
  String get configurationHint =>
      'Bukti foto tidak dapat diunggah karena konfigurasi Cloudinary belum '
      'lengkap. Hubungi administrator sistem.';

  String get _baseUrl =>
      'https://api.cloudinary.com/v1_1/$cloudName/image/upload';

  // ── Upload foto absensi ─────────────────────────────────────────────────
  /// Upload foto absensi (clock in / clock out).
  ///
  /// [employeeId] dan [punchType] dipakai untuk folder dan tag, sehingga
  /// foto bisa ditelusuri per pegawai per jenis absen di Cloudinary console.
  ///
  /// [onProgress] dipanggil dengan nilai 0.0–1.0 selama upload berlangsung.
  Future<UploadResult> uploadAttendancePhoto(
    File photo, {
    required String employeeId,
    required String punchType, // 'check_in' atau 'check_out'
    void Function(double progress)? onProgress,
  }) =>
      _upload(
        file: photo,
        preset: uploadPreset,
        folder: 'sae/attendance/$employeeId',
        tags: 'attendance,$punchType,$employeeId',
        onProgress: onProgress,
      );

  // ── Upload lampiran izin/cuti ───────────────────────────────────────────
  /// Upload dokumen pendukung pengajuan izin (foto surat dokter, dll.).
  Future<UploadResult> uploadLeaveAttachment(
    File file, {
    required String userId,
    required String permissionId,
    void Function(double progress)? onProgress,
  }) =>
      _upload(
        file: file,
        preset: leavePreset.isEmpty ? uploadPreset : leavePreset,
        folder: 'sae/leaves/$userId',
        tags: 'leave,$permissionId,$userId',
        onProgress: onProgress,
      );

  // ── Core upload ────────────────────────────────────────────────────────
  Future<UploadResult> _upload({
    required File file,
    required String preset,
    required String folder,
    required String tags,
    void Function(double progress)? onProgress,
  }) async {
    if (!isConfigured) {
      return const UploadResult.failure(
        'Konfigurasi Cloudinary belum lengkap. Hubungi administrator sistem.',
      );
    }

    final uri = Uri.parse(_baseUrl);
    // Pastikan endpoint HTTPS — belt-and-braces di atas platform flag
    TransportSecurity.assertSecure(uri);

    try {
      final dio = _buildDio();

      final formData = FormData.fromMap({
        'upload_preset': preset,
        'folder': folder,
        'tags': tags,
        'file': await MultipartFile.fromFile(
          file.path,
          filename: p.basename(file.path),
        ),
      });

      final response = await dio.post<Map<String, dynamic>>(
        _baseUrl,
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call(sent / total);
        },
      );

      final secureUrl = response.data?['secure_url'];
      if (secureUrl is! String || secureUrl.isEmpty) {
        return const UploadResult.failure(
          'Server tidak mengembalikan URL foto. Periksa pengaturan preset.',
        );
      }
      return UploadResult.success(secureUrl);
    } on DioException catch (e) {
      return UploadResult.failure(_describeDioError(e));
    } on SocketException {
      return const UploadResult.failure(
        'Tidak ada koneksi internet saat mengunggah foto.',
      );
    }
  }

  // ── Dio client dengan interceptor ─────────────────────────────────────
  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 60),
        responseType: ResponseType.json,
      ),
    );

    // Interceptor: log request/response di debug, sembunyikan di release
    dio.interceptors.add(LogInterceptor(
      request: false,
      requestHeader: false,
      requestBody: false,
      responseBody: false,
      error: true,
    ));

    return dio;
  }

  String _describeDioError(DioException error) {
    final code = error.response?.statusCode;
    if (code == 401 || code == 403) {
      return 'Upload ditolak Cloudinary. Periksa nama preset '
          '(${uploadPreset.isEmpty ? "belum diisi" : uploadPreset}).';
    }
    if (code == 413) return 'Ukuran foto terlalu besar.';
    if (code != null && code >= 500) {
      return 'Server Cloudinary bermasalah. Coba lagi nanti.';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return 'Timeout saat mengunggah foto. Periksa koneksi internet.';
    }
    // Cloudinary wraps its inner error as `{"error": {"message": "..."}}`, and on
    // some responses `error` is present but `message` is not — hence the two
    // narrowing casts rather than one.
    try {
      final body = error.response?.data;
      if (body is Map) {
        final inner = body['error'];
        if (inner is Map) {
          final msg = inner['message'];
          if (msg is String && msg.isNotEmpty) return 'Gagal upload: $msg';
        }
      }
    } catch (_) {
      // A non-JSON body is common behind a proxy; fall through to the status.
    }
    return 'Gagal mengunggah foto (kode ${code ?? "tidak diketahui"}).';
  }

  /// Uploads into an explicit [folder].
  ///
  /// The general entry point the attendance and leave flows use, so a caller
  /// that does not care about per-employee tagging can name a single folder
  /// rather than synthesise an employee id for it.
  Future<UploadResult> uploadFile(File file, {required String folder}) =>
      _upload(
        file: file,
        preset: uploadPreset,
        folder: folder,
        tags: folder.replaceAll('/', ','),
      );

  // ── Utilitas ───────────────────────────────────────────────────────────

  /// Deskripsi lokasi untuk field `checkInAddress` pada punch record.
  static String describeEvidenceLocation({
    String? zoneName,
    String? address,
  }) {
    final name = zoneName?.trim();
    final place = address?.trim();
    if (name != null && name.isNotEmpty && place != null && place.isNotEmpty) {
      return '$name — $place';
    }
    if (name != null && name.isNotEmpty) return name;
    if (place != null && place.isNotEmpty) return place;
    return 'Lokasi tidak dinamai';
  }

  /// Ringkasan fix untuk audit trail metadata.
  static String describeFix({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    double? distanceMeters,
    double? radiusMeters,
  }) {
    final parts = <String>[
      'titik ${formatCoordinate(latitude)}, ${formatCoordinate(longitude)}',
      'akurasi ±${accuracyMeters.round()} m',
    ];
    if (distanceMeters != null) {
      parts.add('jarak ${formatDistance(distanceMeters)}');
    }
    if (radiusMeters != null) {
      parts.add('radius ${formatDistance(radiusMeters)}');
    }
    return parts.join(', ');
  }
}

/// Hasil dari upload attempt.
class UploadResult {
  const UploadResult.success(this.url) : error = null;
  const UploadResult.failure(this.error) : url = null;

  final String? url;
  final String? error;

  bool get isSuccess => url != null;
}
