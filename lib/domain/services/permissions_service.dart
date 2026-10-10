import 'package:cloud_firestore/cloud_firestore.dart';

import '../errors.dart';
import '../logic/time_keys.dart';
import '../models/permission.dart';
import '../models/user.dart';
import 'auth_service.dart';
import 'firestore_map.dart';

/// Reads and writes leave requests.
///
/// The rules make this a two-sided workflow: an employee may file a request for
/// themselves as `PENDING` and may later withdraw it, while only an
/// administrator may approve or reject. The service enforces the same split so
/// the UI never offers an action the server will refuse.
class PermissionsService {
  PermissionsService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static const String collectionPath = 'permissions';

  /// Upper bound applied to every list query.
  ///
  /// Firestore bills per document read, so an unbounded list of a growing
  /// collection quietly dominates the invoice. Sized for the stated 200-user
  /// deployment with headroom.
  static const int maxTracked = 500;

  /// The caller's own requests, newest first.
  ///
  /// The `userId` filter is not a convenience: `firestore.rules` denies an
  /// unfiltered read to a non-admin, so a caller without full access must
  /// constrain the query or it fails outright.
  Future<List<PermissionDoc>> loadForUser(String uid, {int limitCount = 100}) async {
    try {
      final snapshot = await _firestore
          .collection(collectionPath)
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(limitCount)
          .get();

      return snapshot.docs
          .map((doc) => PermissionDoc.fromMap(doc.id, firestoreData(doc.data())))
          .toList();
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// The full queue, for an administrator.
  ///
  /// [status] narrows the query so the rules' composite index is used, and so an
  /// unfiltered read never leaves the device.
  Future<List<PermissionDoc>> loadAll({String? status, int limitCount = maxTracked}) async {
    try {
      Query<Map<String, dynamic>> query =
          _firestore.collection(collectionPath).orderBy('createdAt', descending: true);

      if (status != null && status.isNotEmpty) {
        query = _firestore
            .collection(collectionPath)
            .where('status', isEqualTo: status)
            .orderBy('createdAt', descending: true);
      }

      final snapshot = await query.limit(limitCount).get();

      return snapshot.docs
          .map((doc) => PermissionDoc.fromMap(doc.id, firestoreData(doc.data())))
          .toList();
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Files a leave request for [user].
  ///
  /// Always written as `PENDING`. Filing it approved would bypass review
  /// entirely, which the rules refuse and which is the whole point of the
  /// workflow.
  Future<String> submit({
    required UserDoc user,
    required PermissionFormResult form,
    DateTime? now,
  }) async {
    final validated = form;
    if (!validated.isValid || validated.type == null) {
      throw AppFailure(AppError.permissionDenied, validated.errorMessage);
    }

    try {
      final docRef = await _firestore.collection(collectionPath).add({
        'userId': user.uid,
        'userName': user.displayLabel,
        'employeeNumber': user.employeeNumber,
        'permissionTypeId': validated.type!.id,
        'permissionTypeName': validated.type!.name,
        'startDate': validated.startDate,
        'endDate': validated.endDate,
        'dayCount': validated.dayCount,
        'reason': validated.reason,
        'attachmentUrl': validated.attachmentUrl,
        'status': PermissionStatus.pending,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      return docRef.id;
    } on FirebaseException catch (error) {
      throw _translate(error);
    }
  }

  /// Withdraws a pending request.
  ///
  /// Only the status and cancellation fields are sent: the rules pin that key
  /// set, so writing anything else alongside would make the update — and the
  /// withdrawal — fail.
  Future<void> cancel({
    required String permissionId,
    required PermissionDoc request,
    DateTime? now,
  }) async {
    if (!request.canBeCancelled) {
      throw const AppFailure(AppError.permissionDenied);
    }

    try {
      await _firestore.collection(collectionPath).doc(permissionId).update({
        'status': PermissionStatus.cancelled,
        'cancelledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      throw _translate(error);
    }
  }

  /// Approves a request. Administrator only.
  Future<void> approve({
    required String permissionId,
    required UserDoc reviewer,
    DateTime? now,
  }) async {
    final stamp = now ?? DateTime.now();
    try {
      await _firestore.collection(collectionPath).doc(permissionId).update({
        'status': PermissionStatus.approved,
        'reviewedBy': reviewer.displayLabel,
        'reviewedByUid': reviewer.uid,
        'reviewedAt': toLocalIso(stamp),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      throw _translate(error);
    }
  }

  /// Rejects a request, with a reason the employee can read. Administrator only.
  Future<void> reject({
    required String permissionId,
    required UserDoc reviewer,
    required String reason,
    DateTime? now,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw const AppFailure(
        AppError.permissionDenied,
        'Alasan penolakan wajib diisi.',
      );
    }

    final stamp = now ?? DateTime.now();
    try {
      await _firestore.collection(collectionPath).doc(permissionId).update({
        'status': PermissionStatus.rejected,
        'reviewedBy': reviewer.displayLabel,
        'reviewedByUid': reviewer.uid,
        'reviewedAt': toLocalIso(stamp),
        'rejectionReason': trimmed,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      throw _translate(error);
    }
  }

  /// A one-line summary for a list row.
  static String describeRange(PermissionDoc request) {
    final start = formatDisplayDate(request.startDate);
    if (request.startDate == request.endDate) return start;
    return '$start – ${formatDisplayDate(request.endDate)}';
  }

  /// A one-line summary of a request's span, including the day count.
  static String describeSpan(PermissionDoc request) {
    final days = request.dayCount > 0 ? ' · ${request.dayCount} hari kerja' : '';
    return '${describeRange(request)}$days';
  }

  /// Whether today falls inside an approved request, which the punch screen
  /// surfaces so an employee on leave is not told they simply failed to punch.
  static bool isOnApprovedLeaveToday(List<PermissionDoc> requests, {DateTime? now}) {
    final today = todayIso(now);
    return requests.any(
      (request) =>
          request.isApproved &&
          request.coversDate(today),
    );
  }

  /// The approved request covering today, if any.
  static PermissionDoc? approvedLeaveToday(
    List<PermissionDoc> requests, {
    DateTime? now,
  }) {
    final today = todayIso(now);
    for (final request in requests) {
      if (request.isApproved && request.coversDate(today)) return request;
    }
    return null;
  }
}

AppFailure _translate(FirebaseException error) {
  switch (error.code) {
    case 'permission-denied':
      return AppFailure(AppError.permissionDenied, error.message);
    case 'unavailable':
    case 'network-request-failed':
    case 'internal-error':
      return AppFailure(AppError.networkUnavailable, error.message);
    case 'deadline-exceeded':
      return AppFailure(AppError.timedOut, error.message);
    case 'unauthenticated':
      return AppFailure(AppError.sessionExpired, error.message);
    default:
      return AppFailure(AppError.unexpected, error.message);
  }
}