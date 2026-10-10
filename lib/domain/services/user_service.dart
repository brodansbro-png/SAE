import 'package:cloud_firestore/cloud_firestore.dart';

import '../logic/geo.dart';
import '../logic/geofence_rules.dart';
import '../logic/time_keys.dart';
import '../models/activity_log.dart';
import '../models/user.dart';
import 'auth_service.dart';
import 'firestore_map.dart';

/// The staff profile for [uid], or `null` when it does not exist.
///
/// A missing profile is a real state, not an error: Firebase Authentication can
/// hold an account an administrator has not yet added to `users/`, and
/// `firestore.rules` gates every punch on `isActive == true`. The app shows a
/// "profil belum lengkap" screen instead of surfacing a permission error.
class UserProfileResult {
  const UserProfileResult(this.user);

  final UserDoc? user;

  bool get exists => user != null;

  /// Whether the account may punch.
  bool get canPunch => user?.isActive == true;
}

/// Loads and updates staff profiles.
///
/// This app only ever writes its *own* profile fields. The rules permit exactly
/// `photoUrl`, `fcmToken`, `lastSeenAt` and `updatedAt` on a self-update —
/// widening that would let a `USER` rewrite their own `role`.
class UserService {
  UserService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Exposed so the audit trail appends through the same client instance.
  FirebaseFirestore get firestore => _firestore;

  static const String usersPath = 'users';

  /// Reads the profile for [uid] once.
  Future<UserProfileResult> loadProfile(String uid) async {
    try {
      final doc = await _firestore.collection(usersPath).doc(uid).get();
      if (!doc.exists) return const UserProfileResult(null);
      return UserProfileResult(
        UserDoc.fromMap(doc.id, firestoreData(doc.data())),
      );
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Subscribes to a profile.
  ///
  /// A stream rather than a one-shot read because an administrator can
  /// deactivate an account or reassign its shift at any time; the punch screen
  /// must reflect that without the employee restarting the app.
  Stream<UserProfileResult> watchProfile(String uid) {
    return _firestore
        .collection(usersPath)
        .doc(uid)
        .snapshots()
        .map((doc) => UserProfileResult(
              doc.exists
                  ? UserDoc.fromMap(doc.id, firestoreData(doc.data()))
                  : null,
            ));
  }

  /// Uploads a new profile photo and stores its URL on the profile.
  ///
  /// Only `photoUrl` and `updatedAt` are touched, which is what the rules allow a
  /// self-update to change.
  Future<void> updatePhotoUrl(String uid, String photoUrl) async {
    try {
      await _firestore.collection(usersPath).doc(uid).update({
        'photoUrl': photoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Appends to the audit trail.
  ///
  /// Never throws: the trail is evidence, not a precondition. A punch that
  /// succeeds but whose log line fails is a gap worth knowing about, but not
  /// worth failing the employee's attendance over.
  static Future<void> appendLog({
    required FirebaseFirestore firestore,
    required UserDoc actor,
    required String action,
    required String summary,
    String? targetUserId,
    Map<String, dynamic>? metadata,
    DateTime? now,
  }) async {
    try {
      final payload = <String, dynamic>{
        'actorUid': actor.uid,
        'actorName': actor.displayLabel,
        'actorRole': actor.role,
        'action': action,
        'summary': summary,
        'at': FieldValue.serverTimestamp(),
        'atLocal': toLocalClockSeconds(now ?? DateTime.now()),
      };

      // Optional keys are omitted rather than written as null, because the
      // schema treats an absent field and a null one as different when a rule
      // reasons about presence.
      if (targetUserId != null) payload['targetUserId'] = targetUserId;
      if (metadata != null) payload['metadata'] = metadata;

      await firestore.collection('activity_logs').add(payload);
    } catch (_) {
      // Swallowed deliberately — see the doc comment.
    }
  }

  /// Appends a punch entry, carrying the measured geofence evidence.
  ///
  /// The distance and radius travel into the log as well as onto the punch, so
  /// the audit trail can be read without joining it against the attendance
  /// document. That is the second of the two mitigations that make a
  /// client-side geofence auditable rather than merely trusted.
  static Future<void> logPunch({
    required FirebaseFirestore firestore,
    required UserDoc actor,
    required bool isCheckIn,
    required String recordDate,
    required String status,
    required Zone zone,
    required Fix fix,
    required double distanceMeters,
    DateTime? now,
  }) {
    final stamp = now ?? DateTime.now();
    final action = isCheckIn ? ActivityAction.checkIn : ActivityAction.checkOut;
    final punchType = isCheckIn ? 'datang' : 'pulang';
    final punchTime = minutesToClock(stamp.hour * 60 + stamp.minute);

    return appendLog(
      firestore: firestore,
      actor: actor,
      action: action,
      summary: 'Absen $punchType pukul $punchTime — '
          'jarak ${formatDistance(distanceMeters)} dari ${zone.name} '
          '(radius ${formatDistance(zone.radiusMeters)}), status $status.',
      targetUserId: actor.uid,
      metadata: {
        'recordDate': recordDate,
        'status': status,
        'latitude': fix.latitude,
        'longitude': fix.longitude,
        'accuracyMeters': double.parse(fix.accuracyMeters.toStringAsFixed(2)),
        'distanceMeters': double.parse(distanceMeters.toStringAsFixed(2)),
        'zoneRadiusMeters': zone.radiusMeters,
        'zoneId': zone.id,
      },
      now: stamp,
    );
  }

  /// Appends a leave workflow entry.
  static Future<void> logPermissionAction({
    required FirebaseFirestore firestore,
    required UserDoc actor,
    required String action,
    required String summary,
    String? targetUserId,
    Map<String, dynamic>? metadata,
    DateTime? now,
  }) =>
      appendLog(
        firestore: firestore,
        actor: actor,
        action: action,
        summary: summary,
        targetUserId: targetUserId ?? actor.uid,
        metadata: metadata,
        now: now,
      );
}