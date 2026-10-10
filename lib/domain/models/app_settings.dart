/// System-wide settings, mirroring `settings/app` (document id `current`).
///
/// Read by every signed-in client at launch. It carries the organisation name
/// shown in the header, plus the kill switch and the forced-update gate.
class AppSettings {
  const AppSettings({
    this.orgName = 'SAE',
    this.appVersion = '',
    this.forceUpdate = false,
    this.maintenanceMode = false,
    this.maintenanceMessage = '',
  });

  /// Shown in the app header.
  final String orgName;

  /// Minimum accepted version, as `major.minor.patch` or a bare build number.
  final String appVersion;

  /// When true, an older client is refused with [updateRequiredMessage].
  final bool forceUpdate;

  /// When true, punching is blocked entirely.
  final bool maintenanceMode;

  /// Copy shown while [maintenanceMode] is on.
  final String maintenanceMessage;

  factory AppSettings.fromMap(Map<String, dynamic> map) => AppSettings(
        orgName: _nonEmpty(map['orgName']) ?? 'SAE',
        appVersion: _nonEmpty(map['appVersion']) ?? '',
        // Both flags default to off: a document missing them is an older
        // build's, and refusing every punch because of an absent field would be
        // a worse failure than letting a stale client through.
        forceUpdate: map['forceUpdate'] == true,
        maintenanceMode: map['maintenanceMode'] == true,
        maintenanceMessage: _nonEmpty(map['maintenanceMessage']) ?? '',
      );

  /// Copy for the forced-update gate.
  ///
  /// Falls back to the bare minimum version when the setting is empty, so the
  /// gate never blocks on a blank string.
  String updateRequiredMessage(String currentVersion) {
    final target = appVersion.trim().isEmpty ? 'terbaru' : appVersion;
    return 'Aplikasi perlu diperbarui ke versi $target. '
        'Versi Anda saat ini $currentVersion. '
        'Silakan unduh pembaruan dari Play Store atau App Store.';
  }

  /// Copy for the maintenance gate.
  String get maintenanceNotice => maintenanceMessage.trim().isEmpty
      ? 'Aplikasi sedang dalam pemeliharaan. Silakan coba lagi nanti.'
      : maintenanceMessage.trim();

  @override
  String toString() =>
      'AppSettings(org=$orgName, minVersion=$appVersion, '
      'forceUpdate=$forceUpdate, maintenance=$maintenanceMode)';
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Compares two dotted version strings.
///
/// Returns a negative number when [a] is older than [b], zero when they are
/// equivalent, positive when [a] is newer.
///
/// Numeric segments are compared as numbers, not lexically, so `0.10.0` is
/// correctly newer than `0.9.0` — the bug a plain string compare produces and
/// the reason a build-number gate silently stops working after release 9.
/// Non-numeric segments fall back to a string compare so a build number like
/// `1.2.0-beta3` still orders deterministically.
int compareVersions(String a, String b) {
  final left = a.trim().split('.');
  final right = b.trim().split('.');

  final length = left.length > right.length ? left.length : right.length;

  for (var i = 0; i < length; i++) {
    if (i >= left.length) return -1;
    if (i >= right.length) return 1;

    final leftPart = left[i];
    final rightPart = right[i];

    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);

    if (leftNumber != null && rightNumber != null) {
      if (leftNumber != rightNumber) return leftNumber - rightNumber;
      continue;
    }

    final byString = leftPart.compareTo(rightPart);
    if (byString != 0) return byString;
  }

  return 0;
}

/// Whether [currentVersion] is older than the [minimumVersion] gate demands.
///
/// An empty gate disables the check, so a project that has never configured
/// `appVersion` does not lock every employee out of the app.
bool isVersionBelowMinimum(String currentVersion, String minimumVersion) {
  if (minimumVersion.trim().isEmpty) return false;
  if (currentVersion.trim().isEmpty) return false;
  return compareVersions(currentVersion, minimumVersion) < 0;
}