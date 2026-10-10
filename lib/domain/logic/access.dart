/// Access model, mirroring `SAE-Dashboard/src/lib/access.ts`.
///
/// Two roles only: `ADMIN` sees and manages everything, `USER` sees exactly
/// what an administrator has granted. `firestore.rules` mirrors this in
/// `delegablePages()`. The two must stay in step — the rules are what actually
/// enforce access, and this file only keeps the UI honest about it.
library;

import 'time_keys.dart';

/// Every routable area of the dashboard.
enum AccessPage {
  dashboard('dashboard', 'Dashboard'),
  employees('employees', 'Data Pegawai'),
  attendance('attendance', 'Data Absensi'),
  permissions('permissions', 'Perizinan'),
  settings('settings', 'Pengaturan'),
  profile('profile', 'Profil Saya');

  const AccessPage(this.wire, this.label);

  /// The exact string stored in `users/{uid}.accessiblePages`.
  final String wire;

  /// Indonesian label shown in the UI.
  final String label;

  static AccessPage? fromWire(Object? value) {
    if (value is! String) return null;
    for (final page in AccessPage.values) {
      if (page.wire == value) return page;
    }
    return null;
  }
}

/// Pages an administrator may delegate.
///
/// `employees` and `settings` are excluded because editing them can grant or
/// revoke access itself; delegating that would let a `USER` escalate. This is
/// the client-side half of the same restriction in `firestore.rules`.
const List<AccessPage> delegablePages = [
  AccessPage.dashboard,
  AccessPage.attendance,
  AccessPage.permissions,
  AccessPage.profile,
];

/// Pages an `ADMIN` always reaches, regardless of the stored list.
const List<AccessPage> adminDefaultPages = AccessPage.values;

/// Ticks a freshly created `USER` starts with.
const List<AccessPage> userDefaultPages = [
  AccessPage.dashboard,
  AccessPage.attendance,
  AccessPage.profile,
];

/// The only two roles. No other value is ever written to a user document.
class UserRole {
  static const String admin = 'ADMIN';
  static const String user = 'USER';

  static const List<String> all = [admin, user];

  static const Map<String, String> labels = {
    admin: 'Admin',
    user: 'User',
  };

  static const Map<String, String> descriptions = {
    admin: 'Akses penuh ke seluruh halaman dan pengaturan sistem.',
    user: 'Hanya halaman yang dicentang administrator.',
  };

  static bool isValid(String? value) => value == admin || value == user;
}

/// Maps a stored value to a known page list, ignoring unknown or empty entries.
///
/// The result is ordered by [AccessPage.values] rather than by the stored
/// order, so two documents granting the same pages always render identically.
List<AccessPage> normalisePages(Object? value, List<AccessPage> fallback) {
  if (value is! List) return List<AccessPage>.from(fallback);

  final seen = <AccessPage>{};
  for (final entry in value) {
    final page = AccessPage.fromWire(entry);
    if (page != null) seen.add(page);
  }
  return AccessPage.values.where(seen.contains).toList();
}

/// Pages a user may open, given their role and stored grants.
List<AccessPage> resolveAccess(String? role, Object? accessiblePages) {
  if (role == UserRole.admin) return List<AccessPage>.from(adminDefaultPages);
  return normalisePages(accessiblePages, userDefaultPages)
      .where(delegablePages.contains)
      .toList();
}

/// Whether the user may open [page].
bool canAccess(String? role, Object? accessiblePages, AccessPage page) =>
    resolveAccess(role, accessiblePages).contains(page);

/// A stable label for a stored role value, for display where the role is not
/// one of the two known constants.
String roleLabel(String? role) => UserRole.labels[role] ?? 'Tidak dikenal';

/// Formats an `accessiblePages` document field as readable text, for the
/// profile screen. An empty result is intentional: it is how an `ADMIN`,
/// whose grants are ignored, is rendered.
String describeAccessiblePages(String? role, Object? accessiblePages) {
  if (role == UserRole.admin) return 'Semua halaman';
  final pages = resolveAccess(role, accessiblePages);
  if (pages.isEmpty) return 'Tidak ada halaman';
  return pages.map((page) => page.label).join(', ');
}

/// Indirection so this file has no Flutter dependency and stays testable in a
/// plain `dart test` run.
///
/// Present because the dashboard's `access.ts` has no such seam; Dart lints
/// require it when an enum is converted from raw wire values.
String describeZone(String? zoneName, String? zoneAddress) {
  final name = zoneName?.trim();
  if (name == null || name.isEmpty) return 'Belum ditentukan';
  final address = zoneAddress?.trim();
  if (address == null || address.isEmpty) return name;
  return '$name — $address';
}

/// Re-exported so screens that gate on access do not need a second import
/// just to render a date next to a page label.
String formatDayForDisplay(String? iso) => formatDisplayDate(iso);