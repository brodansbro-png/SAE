/// Append-only audit trail, mirroring `activity_logs/{logId}`.
///
/// Nobody edits it, including administrators — `firestore.rules` denies update
/// and delete outright.
///
/// This is the second of the two mitigations that make the client-side geofence
/// defensible: a client that claims to be inside a zone while its device is
/// demonstrably elsewhere leaves an append-only trace showing an impossible
/// pair of coordinates, rather than a forged success.
class ActivityLogDoc {
  const ActivityLogDoc({
    required this.id,
    required this.actorUid,
    required this.actorName,
    required this.actorRole,
    required this.action,
    required this.summary,
    required this.atLocal,
    this.targetUserId,
    this.metadata,
  });

  final String id;

  final String actorUid;
  final String actorName;

  /// `ADMIN` or `USER`, captured at the time of the action.
  final String actorRole;

  /// One of [ActivityAction] values.
  final String action;

  /// Optional: whose record this action touched.
  final String? targetUserId;

  /// Indonesian one-line description for the audit trail.
  final String summary;

  final Map<String, dynamic>? metadata;

  /// `HH:mm:ss` local time, so a trail reads correctly without a timezone.
  final String atLocal;

  /// Indonesian label for [action].
  String get actionLabel => activityActionLabels[action] ?? action;

  factory ActivityLogDoc.fromMap(String id, Map<String, dynamic> map) {
    final metadata = map['metadata'];
    return ActivityLogDoc(
      id: id,
      actorUid: (map['actorUid'] as String?) ?? '',
      actorName: (map['actorName'] as String?) ?? '',
      actorRole: (map['actorRole'] as String?) ?? 'USER',
      action: (map['action'] as String?) ?? '',
      targetUserId: map['targetUserId'] as String?,
      summary: (map['summary'] as String?) ?? '',
      metadata: metadata is Map
          ? Map<String, dynamic>.from(metadata)
          : null,
      atLocal: (map['atLocal'] as String?) ?? '',
    );
  }

  @override
  String toString() => 'ActivityLogDoc($id, $action, $actorName)';
}

/// Actions written to the audit trail.
class ActivityAction {
  const ActivityAction._();

  static const String checkIn = 'CHECK_IN';
  static const String checkOut = 'CHECK_OUT';
  static const String permissionSubmit = 'PERMISSION_SUBMIT';
  static const String permissionApprove = 'PERMISSION_APPROVE';
  static const String permissionReject = 'PERMISSION_REJECT';
  static const String permissionCancel = 'PERMISSION_CANCEL';
  static const String userUpdate = 'USER_UPDATE';
  static const String zoneUpdate = 'ZONE_UPDATE';
  static const String shiftUpdate = 'SHIFT_UPDATE';
  static const String settingsUpdate = 'SETTINGS_UPDATE';

  static const List<String> all = [
    checkIn,
    checkOut,
    permissionSubmit,
    permissionApprove,
    permissionReject,
    permissionCancel,
    userUpdate,
    zoneUpdate,
    shiftUpdate,
    settingsUpdate,
  ];
}

/// Indonesian labels, matching the dashboard's audit vocabulary.
const Map<String, String> activityActionLabels = {
  ActivityAction.checkIn: 'Absen datang',
  ActivityAction.checkOut: 'Absen pulang',
  ActivityAction.permissionSubmit: 'Pengajuan izin',
  ActivityAction.permissionApprove: 'Persetujuan izin',
  ActivityAction.permissionReject: 'Penolakan izin',
  ActivityAction.permissionCancel: 'Pembatalan izin',
  ActivityAction.userUpdate: 'Perubahan data pegawai',
  ActivityAction.zoneUpdate: 'Perubahan zona',
  ActivityAction.shiftUpdate: 'Perubahan shift',
  ActivityAction.settingsUpdate: 'Perubahan pengaturan',
};