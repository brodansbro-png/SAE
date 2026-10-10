import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../errors.dart';
import '../logic/time_keys.dart';

/// Authentication and profile loading.
///
/// Wraps Firebase Auth so the rest of the app deals in [AppError] rather than
/// SDK exception codes, and never has to know that `auth/invalid-credential`
/// is what "wrong password" looks like on the wire.
class AuthService {
  AuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  /// Emits on every sign-in and sign-out, and replays the current state.
  ///
  /// The app listens to this instead of polling, so a token refreshed in the
  /// background revalidates the profile without the user doing anything.
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  /// Signs in with email and password.
  ///
  /// Firebase deliberately returns the same error for an unknown email and a
  /// wrong password, which is correct — telling them apart would confirm which
  /// addresses have accounts. The message stays generic for the same reason.
  Future<void> signIn({required String email, required String password}) async {
    try {
      await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      throw _translateAuthError(error);
    } on FirebaseException catch (error) {
      throw _translateFirebaseError(error);
    }
  }

  /// Signs out.
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on FirebaseAuthException catch (error) {
      throw _translateAuthError(error);
    }
  }

  /// Sends a reset link to [email].
  ///
  /// Translation happens here rather than at the call site so the login screen
  /// has exactly one place that renders auth copy.
  Future<void> requestPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (error) {
      throw _translateAuthError(error);
    } on FirebaseException catch (error) {
      throw _translateFirebaseError(error);
    }
  }

  /// Changes the password, proving the session first.
  ///
  /// Firebase requires a fresh credential, which also proves the device is
  /// being used by its owner rather than left unattended at a logged-in screen.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw const AppFailure(AppError.notAuthenticated);
    }

    try {
      final credential = EmailAuthProvider.credential(
        email: email,
        password: currentPassword,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPassword);
    } on FirebaseAuthException catch (error) {
      throw _translateAuthError(error);
    } on FirebaseException catch (error) {
      throw _translateFirebaseError(error);
    }
  }

  /// Refreshes the ID token, verifying the session is still usable.
  ///
  /// Called on resume. A token that fails to refresh means the account was
  /// disabled or the refresh token revoked server-side, and continuing to show
  /// a signed-in UI would be a lie.
  Future<void> refreshSession() async {
    final user = _auth.currentUser;
    if (user == null) throw const AppFailure(AppError.notAuthenticated);

    try {
      await user.getIdToken(true);
    } on FirebaseAuthException catch (error) {
      throw _translateAuthError(error);
    }
  }

  /// Whether the OS reports a usable network.
  ///
  /// A punch needs the network, so this is checked before the geofence rather
  /// than after a failed write — there is no point validating a location that
  /// cannot be recorded.
  Future<bool> hasNetwork() async {
    try {
      // Deferred so a caller can construct this without pulling in the plugin.
      final results = await Connectivity().checkConnectivity();
      return !results.contains(ConnectivityResult.none);
    } catch (_) {
      // A plugin failure is not evidence of being offline, so the punch is
      // attempted and the real error surfaces from Firestore if it fails.
      return true;
    }
  }

  /// Records that the app was opened, for the roster's `lastSeenAt`.
  ///
  /// Best-effort: `firestore.rules` permits this field on a self-update, but a
  /// failure here must never block the app from starting.
  Future<void> touchLastSeen(String uid) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'lastSeenAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Intentionally swallowed.
    }
  }

  /// Local clock stamp for the audit trail, as `HH:mm:ss`.
  static String localStamp([DateTime? now]) => toLocalClockSeconds(now ?? DateTime.now());
}

/// A failure carrying an [AppError] the UI can render.
class AppFailure implements Exception {
  const AppFailure(this.error, [this.detail]);

  final AppError error;

  /// SDK text, kept for logging only — never shown to the user.
  final String? detail;

  String get message => error.message;

  @override
  String toString() =>
      detail == null ? 'AppFailure(${error.name})' : 'AppFailure(${error.name}): $detail';
}

/// Maps a Firebase Auth code onto the app's closed error set.
AppFailure _translateAuthError(FirebaseAuthException error) {
  switch (error.code) {
    case 'invalid-email':
      return AppFailure(AppError.invalidEmail, error.message);
    case 'user-not-found':
    case 'wrong-password':
    case 'invalid-credential':
    case 'invalid-login-credentials':
      // Deliberately one message: distinguishing them would confirm which
      // addresses have an account.
      return AppFailure(AppError.wrongPassword, error.message);
    case 'user-disabled':
      return AppFailure(AppError.userDisabled, error.message);
    case 'too-many-requests':
      return AppFailure(AppError.tooManyAttempts, error.message);
    case 'network-request-failed':
      return AppFailure(AppError.networkUnavailable, error.message);
    case 'operation-not-allowed':
      return AppFailure(AppError.resetNotEnabled, error.message);
    case 'unauthorized':
      // Firebase's free Spark plan caps reset emails at 1,000/day.
      return AppFailure(AppError.resetQuotaExceeded, error.message);
    case 'weak-password':
      return AppFailure(AppError.passwordTooWeak, error.message);
    case 'requires-recent-login':
    case 'user-token-expired':
      return AppFailure(AppError.sessionExpired, error.message);
    case 'timeout':
      return AppFailure(AppError.timedOut, error.message);
    default:
      return AppFailure(AppError.unexpected, error.message);
  }
}

/// Maps a Firestore / Firebase platform failure onto the app's error set.
AppFailure _translateFirebaseError(FirebaseException error) {
  switch (error.code) {
    case 'unavailable':
    case 'network-request-failed':
    case 'internal-error':
      return AppFailure(AppError.networkUnavailable, error.message);
    case 'deadline-exceeded':
      return AppFailure(AppError.timedOut, error.message);
    case 'unauthenticated':
      return AppFailure(AppError.sessionExpired, error.message);
    case 'permission-denied':
      return AppFailure(AppError.permissionDenied, error.message);
    case 'unimplemented':
      return AppFailure(AppError.firebaseNotConfigured, error.message);
    case 'not-found':
      return AppFailure(AppError.profileMissing, error.message);
    default:
      return AppFailure(AppError.unexpected, error.message);
  }
}

/// Translates an arbitrary thrown object into an [AppFailure].
///
/// The repositories use this at their boundaries so no raw SDK exception can
/// reach a widget and surface as an unhandled error mid-render.
AppFailure toAppFailure(Object error) {
  if (error is AppFailure) return error;

  if (error is FirebaseAuthException) return _translateAuthError(error);
  if (error is FirebaseException) return _translateFirebaseError(error);

  return AppFailure(AppError.unexpected, error.toString());
}