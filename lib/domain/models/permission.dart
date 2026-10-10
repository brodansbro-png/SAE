import '../logic/time_keys.dart';
import '../services/firestore_map.dart';

/// Leave/permission request, mirroring `permissions/{permissionId}`.
///
/// An employee files their own as `PENDING` and may withdraw it
/// (`CANCELLED`). Only an administrator approves or rejects, which
/// `firestore.rules` enforces.
class PermissionDoc {
  const PermissionDoc({
    required this.id,
    required this.userId,
    required this.userName,
    required this.employeeNumber,
    required this.permissionTypeId,
    required this.permissionTypeName,
    required this.startDate,
    required this.endDate,
    required this.reason,
    required this.status,
    this.attachmentUrl,
    this.dayCount = 0,
    this.reviewedBy,
    this.reviewedByUid,
    this.reviewedAt,
    this.rejectionReason,
  });

  /// Firestore document id.
  final String id;

  final String userId;
  final String userName;
  final String employeeNumber;

  final String permissionTypeId;

  /// Denormalised so a revoked type name does not rewrite historical rows.
  final String permissionTypeName;

  /// `yyyy-MM-dd`, inclusive.
  final String startDate;

  /// `yyyy-MM-dd`, inclusive.
  final String endDate;

  /// Working days after weekend exclusion, as recorded at submission.
  ///
  /// Stored rather than recomputed on read because the type's holiday calendar
  /// may change later; the value at submission is what was approved.
  final int dayCount;

  final String reason;

  /// Cloudinary URL, when the type requires an attachment.
  final String? attachmentUrl;

  final String status;

  final String? reviewedBy;
  final String? reviewedByUid;
  final String? reviewedAt;
  final String? rejectionReason;

  bool get isPending => status == PermissionStatus.pending;

  bool get isApproved => status == PermissionStatus.approved;

  bool get isRejected => status == PermissionStatus.rejected;

  bool get isCancelled => status == PermissionStatus.cancelled;

  /// Whether the employee may still withdraw this request.
  bool get canBeCancelled => isPending;

  /// Whether an administrator may still act on this request.
  bool get canBeReviewed => isPending;

  String get statusLabel => permissionStatusLabels[status] ?? status;

  /// Whether today falls inside the requested range.
  bool coversDate(String isoDate) {
    if (isoDate.compareTo(startDate) < 0) return false;
    return isoDate.compareTo(endDate) <= 0;
  }

  factory PermissionDoc.fromMap(String id, Map<String, dynamic> map) {
    String? str(String key) {
      final value = map[key];
      if (value is! String) return null;
      return value.isEmpty ? null : value;
    }

    final dayCount = map['dayCount'];

    return PermissionDoc(
      id: id,
      userId: (map['userId'] as String?) ?? '',
      userName: (map['userName'] as String?) ?? '',
      employeeNumber: (map['employeeNumber'] as String?)?.toString() ?? '',
      permissionTypeId: (map['permissionTypeId'] as String?) ?? '',
      permissionTypeName: (map['permissionTypeName'] as String?) ?? '',
      startDate: (map['startDate'] as String?) ?? '',
      endDate: (map['endDate'] as String?) ?? '',
      dayCount: dayCount is num ? dayCount.toInt() : 0,
      reason: (map['reason'] as String?) ?? '',
      attachmentUrl: str('attachmentUrl'),
      // A missing status is treated as `PENDING` rather than as something the
      // employee may act on: an unrecognised value must never be cancelable.
      status: PermissionStatus.isKnown(map['status'] as String?)
          ? map['status'] as String
          : PermissionStatus.pending,
      reviewedBy: str('reviewedBy'),
      reviewedByUid: str('reviewedByUid'),
      reviewedAt: str('reviewedAt'),
      rejectionReason: str('rejectionReason'),
    );
  }

  /// Reads a request straight off a Firestore snapshot.
///
/// An alias for [PermissionDoc.fromMap]: two readers of the same document can
/// drift, and a drifted reader shows an approver a request missing the very
/// reason they are being asked to judge it.
factory PermissionDoc.fromFirestore(String id, Map<dynamic, dynamic> data) =>
      PermissionDoc.fromMap(id, firestoreData(data));

  @override
  String toString() =>
      'PermissionDoc($id, $userName, $status, $startDate..$endDate)';
}

/// Permission request lifecycle.
class PermissionStatus {
  const PermissionStatus._();

  static const String pending = 'PENDING';
  static const String approved = 'APPROVED';
  static const String rejected = 'REJECTED';
  static const String cancelled = 'CANCELLED';

  static const List<String> all = [pending, approved, rejected, cancelled];

  static bool isKnown(String? value) => all.contains(value);
}

/// Indonesian labels for request statuses.
const Map<String, String> permissionStatusLabels = {
  PermissionStatus.pending: 'Menunggu',
  PermissionStatus.approved: 'Disetujui',
  PermissionStatus.rejected: 'Ditolak',
  PermissionStatus.cancelled: 'Dibatalkan',
};

/// Leave category, mirroring `settings/permission_types/{id}`.
class PermissionTypeDoc {
  const PermissionTypeDoc({
    required this.id,
    required this.name,
    required this.requiresAttachment,
    required this.maxDays,
    required this.isActive,
    this.description,
  });

  final String id;
  final String name;
  final String? description;

  /// When true, the submission form must accept an attachment or the request
  /// cannot be filed.
  final bool requiresAttachment;

  /// Cap enforced by the submission form against the requested span.
  final int maxDays;

  final bool isActive;

  factory PermissionTypeDoc.fromMap(String id, Map<String, dynamic> map) {
    final maxDays = map['maxDays'];
    final requires = map['requiresAttachment'];
    return PermissionTypeDoc(
      id: id,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? (map['name'] as String).trim()
          : 'Izin',
      description: map['description'] as String?,
      // Absent flags default to the stricter reading: an attachment is
      // required and a cap applies. Failing closed means a type written by an
      // older build cannot become an unlimited, evidence-free leave.
      requiresAttachment: requires is bool ? requires : true,
      maxDays: maxDays is num ? maxDays.toInt().clamp(1, 365) : 30,
      isActive: map['isActive'] != false,
    );
  }

  @override
  String toString() => 'PermissionTypeDoc($id, $name)';
}

/// Why a leave request form was refused, so the UI can explain itself.
enum PermissionFormError {
  noTypeSelected,
  invalidStartDate,
  invalidEndDate,
  endBeforeStart,
  exceedsMaxDays,
  reasonTooShort,
  reasonTooLong,
  attachmentRequired,
  noTypesAvailable,
}

/// A validated submission, or the reason it cannot be submitted.
class PermissionFormResult {
  const PermissionFormResult.valid({
    required this.type,
    required this.startDate,
    required this.endDate,
    required this.dayCount,
    required this.reason,
    this.attachmentUrl,
  })  : error = null,
        errorMessage = '';

  const PermissionFormResult.invalid(this.error, this.errorMessage)
      : type = null,
        startDate = '',
        endDate = '',
        dayCount = 0,
        reason = '',
        attachmentUrl = null;

  bool get isValid => error == null;

  final PermissionFormError? error;
  final String errorMessage;

  final PermissionTypeDoc? type;
  final String startDate;
  final String endDate;
  final int dayCount;
  final String reason;
  final String? attachmentUrl;
}

/// Validates a leave submission against its type's rules.
///
/// Split out of the form widget so the same rules can be unit-tested against
/// fixed dates, and so the submission button's enabled state and the server's
/// `firestore.rules` guard agree on what a valid request is.
class PermissionValidator {
  const PermissionValidator();

  /// `firestore.rules` caps the reason at 1000 characters.
  static const int maxReasonLength = 1000;

  static const int minReasonLength = 5;

  /// Maximum span the form will offer, independent of any type's cap.
  static const int hardMaxDays = 365;

  /// Validates the request and counts working days.
  ///
  /// [typesAreConfigured] distinguishes "the administrator has configured no
  /// leave categories at all" from "you have not picked one". The first is a
  /// setup problem nobody in the request flow can fix; the second is a missing
  /// form field. The error code is the same either way — this method sees only
  /// the field, and it is the caller that knows the list — but the copy differs,
  /// because the two need different remedies.
  PermissionFormResult validate({
    required PermissionTypeDoc? type,
    required String startDate,
    required String endDate,
    required String reason,
    String? attachmentUrl,
    bool typesAreConfigured = true,
  }) {
    if (type == null) {
      return typesAreConfigured
          ? const PermissionFormResult.invalid(
              PermissionFormError.noTypeSelected,
              'Pilih jenis izin terlebih dahulu.',
            )
          : const PermissionFormResult.invalid(
              PermissionFormError.noTypesAvailable,
              'Belum ada jenis izin yang dikonfigurasi. Hubungi administrator.',
            );
    }
    if (!type.isActive) {
      return PermissionFormResult.invalid(
        PermissionFormError.noTypeSelected,
        'Jenis izin "${type.name}" sedang dinonaktifkan.',
      );
    }

    final start = parseDayKey(startDate);
    final end = parseDayKey(endDate);
    if (start == null) {
      return const PermissionFormResult.invalid(
        PermissionFormError.invalidStartDate,
        'Tanggal mulai izin tidak valid.',
      );
    }
    if (end == null) {
      return const PermissionFormResult.invalid(
        PermissionFormError.invalidEndDate,
        'Tanggal selesai izin tidak valid.',
      );
    }
    if (end.isBefore(start)) {
      return const PermissionFormResult.invalid(
        PermissionFormError.endBeforeStart,
        'Tanggal selesai izin harus sama dengan atau setelah tanggal mulai.',
      );
    }

    final span = daysBetween(startDate, endDate);
    if (span > hardMaxDays) {
      return const PermissionFormResult.invalid(
        PermissionFormError.exceedsMaxDays,
        'Rentang izin maksimal $hardMaxDays hari.',
      );
    }
    if (span > type.maxDays) {
      return PermissionFormResult.invalid(
        PermissionFormError.exceedsMaxDays,
        'Jenis izin "${type.name}" maksimal ${type.maxDays} hari '
        '(dipilih $span hari).',
      );
    }

    final trimmedReason = reason.trim();
    if (trimmedReason.length < minReasonLength) {
      return const PermissionFormResult.invalid(
        PermissionFormError.reasonTooShort,
        'Alasan izin minimal 5 karakter.',
      );
    }
    if (trimmedReason.length > maxReasonLength) {
      return const PermissionFormResult.invalid(
        PermissionFormError.reasonTooLong,
        'Alasan izin maksimal $maxReasonLength karakter.',
      );
    }

    if (type.requiresAttachment &&
        (attachmentUrl == null || attachmentUrl.trim().isEmpty)) {
      return PermissionFormResult.invalid(
        PermissionFormError.attachmentRequired,
        'Jenis izin "${type.name}" wajib melampirkan bukti.',
      );
    }

    return PermissionFormResult.valid(
      type: type,
      startDate: startDate,
      endDate: endDate,
      dayCount: countWorkingDays(start, end),
      reason: trimmedReason,
      attachmentUrl: attachmentUrl,
    );
  }

  /// Working days in the inclusive range, excluding Saturdays and Sundays.
  ///
  /// Public holidays are not subtracted: the type has no holiday calendar, so
  /// claiming a count would be a guess. The number is stored on the record and
  /// shown to the approver as-is, who can see the dates and adjust by rejecting.
  static int countWorkingDays(DateTime start, DateTime end) {
    if (end.isBefore(start)) return 0;

    var count = 0;
    var cursor = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);

    // Bounded by `hardMaxDays`, but the guard stops a pathological range from
    // becoming a long loop even if that constant is ever relaxed.
    var guard = 0;
    while (!cursor.isAfter(last) && guard < 400) {
      final weekday = cursor.weekday;
      if (weekday != DateTime.saturday && weekday != DateTime.sunday) {
        count++;
      }
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      guard++;
    }
    return count;
  }
}