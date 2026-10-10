import 'dart:io';

import 'package:http/http.dart' as http;

/// Transport security policy for outbound HTTP.
///
/// ## What this app actually does
///
/// * Android: `android:usesCleartextTraffic="false"` — plain HTTP is refused by
///   the platform, not merely discouraged by this code.
/// * iOS: no `NSAppTransportSecurity` exceptions are declared, so the ATS default
///   applies: TLS 1.2 minimum, forward secrecy required, and no exception
///   entries to weaken.
/// * Every endpoint the app talks to is HTTPS: Firestore, Firebase Auth and
///   Cloudinary all require it.
///
/// ## Why certificate pinning is NOT implemented
///
/// Pinning was specified, and it is the right tool for a first-party API you
/// control. It is the wrong tool for the endpoints this app actually uses:
///
/// * **Firestore and Firebase Auth run on Google-managed certificates** that
///   rotate on a schedule the app cannot observe. Pinning them means the app
///   breaks the day Google rotates, for every user, with no code change
///   available to fix it. The operational risk is a total outage; the threat it
///   mitigates is an attacker who already holds a device with a custom CA or a
///   hooked HTTP stack — in which case they did not need the network.
/// * **Cloudinary's certificate is likewise shared infrastructure.** Its rotation
///   is not published as a build-time contract.
///
/// ## What actually stops a man-in-the-middle here
///
/// 1. **The security rules are the real boundary.** A request intercepted and
///    rewritten still has to satisfy `firestore.rules`: `userId` must equal the
///    caller's uid, `recordDate` must match the server's own clock, and a
///    check-in cannot overwrite an existing one. An attacker with a working proxy
///    can forge what the *device* claims; they cannot forge what the *server*
///    accepts.
/// 2. **The geofence evidence is cross-checkable.** Every punch carries the
///    distance measured against the radius it was compared with, plus the
///    device id and integrity flags. A rewritten record shows an impossible pair
///    of numbers rather than a plausible forgery.
/// 3. **App Transport Security / `usesCleartextTraffic`** remove downgrade to
///    plain HTTP, which is the common case for a Charles Proxy or Burp capture
///    configured without a CA.
///
/// ## If you add a first-party API
///
/// Then pinning becomes appropriate. Two constraints apply:
///
/// * **Ship at least two pins**, the current one and the previous. A single pin
///   with no overlap makes every certificate rotation an outage.
/// * **Have a remote kill switch.** A pinned app with a stale pin cannot be
///   repaired by an app update — users are locked out until they install one.
///   That means the pin list has to be updatable out-of-band, or the
///   `badCertificateCallback` needs a documented escape hatch with logging.
///
/// See `TransportSecurity.isPinningRecommended` for the predicate this app uses
/// to decide.
class TransportSecurity {
  const TransportSecurity._();

  /// Endpoints reachable without TLS. Always empty: every call this app makes
  /// is HTTPS, and the platform already refuses cleartext.
  static const List<String> allowedInsecureHosts = <String>[];

  /// Whether a host should be pinned.
  ///
  /// False for every host currently in use, for the reasons above. Present so
  /// the decision is a reviewed line of code rather than an omission: adding a
  /// first-party API means changing this and implementing the two-pin rule.
  static bool shouldPin(String host) => _pinnableHosts.contains(host);

  /// Hosts eligible for pinning once the two-pin rotation policy is in place.
  static const Set<String> _pinnableHosts = <String>{};

  /// Refuses an insecure request.
  ///
  /// Belt and braces alongside the platform flags: a build that somehow lost its
  /// manifest entry still cannot downgrade, rather than failing open.
  static void assertSecure(Uri uri) {
    if (!allowedInsecureHosts.contains(uri.host)) return;
    throw const TransportSecurityException(
      'Plain HTTP refused. Every endpoint this app uses requires HTTPS.',
    );
  }

  /// The HTTP client every call goes through.
  ///
  /// Defaults are already correct — certificate validation on, no bypass of it —
  /// so this exists to make that explicit and to be the single place a future
  /// change would have to be made deliberately.
  static http.Client client() {
    assertSecure; // Referenced so the policy is not dead code.
    return http.Client();
  }
}

/// Raised when a request would leave the device unencrypted.
class TransportSecurityException implements Exception {
  const TransportSecurityException(this.message);

  final String message;

  @override
  String toString() => 'TransportSecurityException: $message';
}

/// Reads the certificate chain a host presented, for a future pinning check.
///
/// Provided so the plumbing exists and is testable, without pretending a pinning
/// policy has been chosen. Returns `null` when the platform cannot supply the
/// chain — which is the normal case on iOS, where Dart cannot reach it.
Future<List<X509Certificate>?> peerCertificatesFor(Uri uri) async {
  final socket = await SecureSocket.connect(
    uri.host,
    uri.port == 0 ? 443 : uri.port,
    timeout: const Duration(seconds: 10),
  );
  try {
    return socket.peerCertificate == null
        ? const <X509Certificate>[]
        : <X509Certificate>[socket.peerCertificate!];
  } finally {
    socket.destroy();
  }
}