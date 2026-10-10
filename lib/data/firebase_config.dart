import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Konfigurasi Firebase SAE.
///
/// **Dua sumber nilai (prioritas turun):**
/// 1. `--dart-define` → di-embed saat compile, dipakai di CI/CD & release build.
/// 2. `flutter_dotenv` dari `.env` → dipakai saat development lokal.
///
/// Jika `--dart-define` kosong (tidak diisi saat `flutter run`), dotenv
/// menjadi fallback secara otomatis. Developer lokal cukup isi `.env`.
///
/// **Tidak boleh ada di Flutter app:**
/// - `CLOUDINARY_API_SECRET` → server only
/// - `FIREBASE_SERVICE_ACCOUNT` / private key → server only
/// - `VAPID_PRIVATE_KEY` → server only
class FirebaseConfig {
  const FirebaseConfig({
    required this.apiKey,
    required this.authDomain,
    required this.projectId,
    required this.appId,
    this.storageBucket = '',
    this.messagingSenderId = '',
    this.measurementId = '',
    this.iosAppId = '',
  });

  final String apiKey;
  final String authDomain;
  final String projectId;
  final String storageBucket;
  final String messagingSenderId;
  final String measurementId;
  final String appId;
  final String iosAppId;

  /// True ketika field wajib sudah terisi dan bukan placeholder.
  bool get isConfigured =>
      apiKey.isNotEmpty &&
      projectId.isNotEmpty &&
      appId.isNotEmpty &&
      !apiKey.startsWith('your') &&
      !projectId.startsWith('your');

  /// Names the build-time variables still needing a value.
  ///
  /// Static because the setup screen has to report the gap *before* a config
  /// instance exists — that is the whole point of the screen. An instance getter
  /// would force the caller to construct one, which it cannot do while the
  /// credentials are exactly what it is missing.
  static List<String> missingConfigKeys() {
    final values = <String, String>{
      'FIREBASE_API_KEY': _dApiKey,
      'FIREBASE_AUTH_DOMAIN': _dAuthDomain,
      'FIREBASE_PROJECT_ID': _dProjectId,
      'FIREBASE_APP_ID': _dAppId,
    };

    const placeholders = ['your_', 'placeholder', 'changeme', 'xxx'];
    bool isPlaceholder(String value) {
      final normalised = value.trim().toLowerCase();
      if (normalised.isEmpty) return true;
      return placeholders.any(
        (token) => normalised.startsWith(token) || normalised.contains(token),
      );
    }

    return values.entries
        .where((entry) => isPlaceholder(entry.value))
        .map((entry) => entry.key)
        .toList();
  }

  /// Whether Firebase can be initialised at all, without building an instance.
  static bool get isFullyConfigured => missingConfigKeys().isEmpty;

  // ── --dart-define constants (compile-time) ────────────────────────────
  // Nilai ini di-embed saat build dengan flag:
  //   --dart-define=FIREBASE_API_KEY=AIza...
  // Jika tidak diisi, String.fromEnvironment mengembalikan '' (string kosong).
  static const String _dApiKey     = String.fromEnvironment('FIREBASE_API_KEY');
  static const String _dAuthDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const String _dProjectId  = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const String _dBucket     = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
  static const String _dSenderId   = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const String _dAppId      = String.fromEnvironment('FIREBASE_APP_ID');
  static const String _dMeasId     = String.fromEnvironment('FIREBASE_MEASUREMENT_ID');
  static const String _dIosAppId   = String.fromEnvironment('FIREBASE_IOS_APP_ID');

  // ── Helper: dart-define jika ada, fallback ke dotenv ─────────────────
  static String _v(String dartDefineValue, String dotenvKey) {
    if (dartDefineValue.isNotEmpty) return dartDefineValue;
    try {
      return dotenv.env[dotenvKey] ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Membaca konfigurasi dari dart-define (compile-time) dengan fallback dotenv.
  factory FirebaseConfig.fromEnvironment() => FirebaseConfig(
        apiKey:            _v(_dApiKey,    'FIREBASE_API_KEY'),
        authDomain:        _v(_dAuthDomain,'FIREBASE_AUTH_DOMAIN'),
        projectId:         _v(_dProjectId, 'FIREBASE_PROJECT_ID'),
        storageBucket:     _v(_dBucket,    'FIREBASE_STORAGE_BUCKET'),
        messagingSenderId: _v(_dSenderId,  'FIREBASE_MESSAGING_SENDER_ID'),
        appId:             _v(_dAppId,     'FIREBASE_APP_ID'),
        measurementId:     _v(_dMeasId,    'FIREBASE_MEASUREMENT_ID'),
        iosAppId:          _v(_dIosAppId,  'FIREBASE_IOS_APP_ID'),
      );

  FirebaseOptions toOptions() => FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: messagingSenderId,
        projectId: projectId,
        authDomain: authDomain,
        storageBucket: storageBucket,
        measurementId: measurementId.isNotEmpty ? measurementId : null,
      );
}

/// Inisialisasi Firebase. Mengembalikan true jika berhasil.
/// Tidak throw agar layar setup tetap bisa ditampilkan jika konfigurasi kurang.
Future<bool> initialiseFirebase() async {
  final config = FirebaseConfig.fromEnvironment();
  if (!config.isConfigured) return false;
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: config.toOptions());
    }
    return true;
  } catch (_) {
    return false;
  }
}
