import '../logic/access.dart';

/// Staff profile, mirroring `users/{uid}`.
///
/// Keyed by the Firebase Auth uid. Created by the dashboard after the account
/// exists in Firebase Authentication.
///
/// The human-readable staff identifier is [employeeNumber] (e.g. `2024001`).
/// There is deliberately no NIP field anywhere in the schema — nothing to leak,
/// display, or migrate.
class UserDoc {
  const UserDoc({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.employeeNumber,
    required this.role,
    required this.isActive,
    this.jabatan,
    this.unitKerja,
    this.phone,
    this.photoUrl,
    this.zoneId,
    this.shiftId,
    this.accessiblePages,
  });

  /// Firestore document id; the Firebase Auth uid is the key.
  final String uid;

  final String email;
  final String displayName;

  /// Nomor pegawai, e.g. `2024001`.
  final String employeeNumber;

  /// `ADMIN` or `USER`. Nothing else is ever written.
  final String role;

  final String? jabatan;
  final String? unitKerja;
  final String? phone;

  /// Cloudinary URL, set from this app.
  final String? photoUrl;

  /// Attendance zone this employee punches at.
  final String? zoneId;

  /// Working-hours profile; may differ per employee.
  final String? shiftId;

  /// Pages a `USER` may open. Ignored for `ADMIN`. Read by the rules.
  final List<AccessPage>? accessiblePages;

  final bool isActive;

  bool get isAdmin => role == UserRole.admin;

  /// Pages this user may open, resolved exactly as `access.ts` resolves them.
  List<AccessPage> get resolvedPages => resolveAccess(role, accessiblePages);

  /// The name to show in the UI.
  ///
  /// Falls back through progressively weaker sources rather than rendering an
  /// empty header when a profile is still being filled in by an administrator.
  String get displayLabel {
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (email.trim().isNotEmpty) return email.split('@').first;
    return 'Pengguna';
  }

  UserDoc copyWith({
    String? email,
    String? displayName,
    String? employeeNumber,
    String? role,
    String? jabatan,
    String? unitKerja,
    String? phone,
    String? photoUrl,
    String? zoneId,
    String? shiftId,
    List<AccessPage>? accessiblePages,
    bool? isActive,
  }) =>
      UserDoc(
        uid: uid,
        email: email ?? this.email,
        displayName: displayName ?? this.displayName,
        employeeNumber: employeeNumber ?? this.employeeNumber,
        role: role ?? this.role,
        jabatan: jabatan ?? this.jabatan,
        unitKerja: unitKerja ?? this.unitKerja,
        phone: phone ?? this.phone,
        photoUrl: photoUrl ?? this.photoUrl,
        zoneId: zoneId ?? this.zoneId,
        shiftId: shiftId ?? this.shiftId,
        accessiblePages: accessiblePages ?? this.accessiblePages,
        isActive: isActive ?? this.isActive,
      );

  factory UserDoc.fromMap(String uid, Map<String, dynamic> map) {
    final pages = map['accessiblePages'];
    return UserDoc(
      uid: uid,
      email: (map['email'] as String?) ?? '',
      displayName: (map['displayName'] as String?) ?? '',
      employeeNumber: (map['employeeNumber'] as String?)?.toString() ?? '',
      // An unrecognised role is treated as the least-privileged one. A
      // corrupted document must not silently grant administrator rights.
      role: UserRole.isValid(map['role'] as String?) ? map['role'] as String : UserRole.user,
      jabatan: map['jabatan'] as String?,
      unitKerja: map['unitKerja'] as String?,
      phone: map['phone'] as String?,
      photoUrl: map['photoUrl'] as String?,
      zoneId: map['zoneId'] as String?,
      shiftId: map['shiftId'] as String?,
      accessiblePages: normalisePages(pages, const <AccessPage>[]),
      // Absent `isActive` is treated as inactive: an account whose status is
      // unknown should not be able to punch. `firestore.rules` gates writes on
      // `isActive == true` anyway, so this only affects the UI's honesty.
      isActive: map['isActive'] == true,
    );
  }

  @override
  String toString() => 'UserDoc($uid, $displayName, $role)';
}