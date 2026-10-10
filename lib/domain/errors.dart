/// Every failure this app can surface, as one closed set.
///
/// A closed set is what makes the error messages reviewable: an exhaustive
/// `switch` in the UI fails to compile when a case is added, so a new failure
/// mode cannot slip through with a generic "something went wrong". That matters
/// most for [punchWriteFailed] and [networkUnavailable], which are the two an
/// employee most needs to be told apart — one is worth retrying immediately,
/// the other means walking to better signal.
enum AppError {
  // ─── Session ───────────────────────────────────────────────────────────────
  notAuthenticated,
  wrongPassword,
  userDisabled,
  tooManyAttempts,
  invalidEmail,
  resetNotEnabled,
  resetQuotaExceeded,
  passwordTooWeak,
  sessionExpired,

  // ─── Configuration ─────────────────────────────────────────────────────────
  firebaseNotConfigured,
  photoUploadNotConfigured,

  // ─── Network ───────────────────────────────────────────────────────────────
  networkUnavailable,
  timedOut,

  // ─── Permissions ───────────────────────────────────────────────────────────
  accountInactive,
  profileMissing,
  permissionDenied,

  // ─── Punching ──────────────────────────────────────────────────────────────
  punchWriteFailed,
  alreadyCheckedIn,
  noOpenCheckIn,

  // ─── Catch-all ─────────────────────────────────────────────────────────────
  unexpected,
}

/// Indonesian copy for [AppError], safe to render directly.
extension AppErrorMessage on AppError {
  String get message {
    switch (this) {
      // Session
      case AppError.notAuthenticated:
        return 'Sesi tidak valid. Silakan masuk kembali.';
      case AppError.wrongPassword:
        return 'Email atau kata sandi salah.';
      case AppError.userDisabled:
        return 'Akun ini dinonaktifkan. Hubungi administrator.';
      case AppError.tooManyAttempts:
        return 'Terlalu banyak percobaan. Coba lagi beberapa saat lagi.';
      case AppError.invalidEmail:
        return 'Format email tidak valid.';
      case AppError.resetNotEnabled:
        return 'Email reset kata sandi belum diaktifkan di Firebase Console.';
      case AppError.resetQuotaExceeded:
        return 'Batas kuota reset kata sandi harian habis. Hubungi administrator.';
      case AppError.passwordTooWeak:
        return 'Kata sandi terlalu lemah. Gunakan minimal 6 karakter.';
      case AppError.sessionExpired:
        return 'Sesi Anda telah berakhir. Silakan masuk kembali.';

      // Configuration
      case AppError.firebaseNotConfigured:
        return 'Firebase belum dikonfigurasi. Isi kredensial FIREBASE_* saat '
            'build aplikasi.';
      case AppError.photoUploadNotConfigured:
        return 'Konfigurasi bukti foto belum lengkap. Hubungi administrator.';

      // Network
      case AppError.networkUnavailable:
        return 'Tidak ada koneksi internet. Absen membutuhkan jaringan.';
      case AppError.timedOut:
        return 'Koneksi terlalu lama. Periksa jaringan lalu coba lagi.';

      // Permissions
      case AppError.accountInactive:
        return 'Akun Anda berstatus tidak aktif sehingga tidak dapat absen.';
      case AppError.profileMissing:
        return 'Data pegawai Anda belum lengkap. Hubungi administrator.';
      case AppError.permissionDenied:
        return 'Anda tidak memiliki akses untuk tindakan ini.';

      // Punching
      case AppError.punchWriteFailed:
        return 'Absen gagal disimpan. Silakan coba lagi.';
      case AppError.alreadyCheckedIn:
        return 'Anda sudah melakukan absen datang hari ini.';
      case AppError.noOpenCheckIn:
        return 'Belum ada absen datang yang tercatat, jadi absen pulang tidak '
            'bisa dilakukan.';

      // Catch-all
      case AppError.unexpected:
        return 'Terjadi kesalahan yang tidak terduga. Silakan coba lagi.';
    }
  }

  /// Whether retrying the same action unchanged could plausibly succeed.
  ///
  /// Drives whether the UI offers a "Coba lagi" button, so a permanently
  /// invalid state is not presented as a transient hiccup.
  bool get isRetryable {
    switch (this) {
      case AppError.networkUnavailable:
      case AppError.timedOut:
      case AppError.punchWriteFailed:
      case AppError.unexpected:
      case AppError.sessionExpired:
        return true;
      default:
        return false;
    }
  }

  /// Whether the app should send the employee to the login screen.
  bool get requiresReauthentication {
    switch (this) {
      case AppError.notAuthenticated:
      case AppError.sessionExpired:
        return true;
      default:
        return false;
    }
  }
}