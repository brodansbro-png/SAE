import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:sae/data/security_service.dart';
import 'package:sae/domain/logic/geofence_rules.dart';
import 'package:sae/domain/logic/shift_rules.dart';
import 'package:sae/domain/models/attendance.dart';

/// Covers the security layer.
///
/// The crypto tests are round-trip and tamper cases rather than known-answer
/// vectors: what matters here is that a value only decrypts for the key that
/// sealed it, under the document id it was sealed for — not that the bytes match
/// a NIST vector, which `pointycastle`'s own suite already covers.
void main() {
  group('AES-256-GCM', () {
    final key = PunchCrypto.generateKey();

    test('generates a full-length key', () {
      expect(PunchCrypto.generateKey().length, 32);
      expect(key.length, PunchCrypto.keyLengthBytes);
    });

    test('generates a different key each time', () {
      // A constant key would make every punch on every device decryptable by
      // anyone who obtained that constant.
      expect(PunchCrypto.generateKey(), isNot(PunchCrypto.generateKey()));
    });

    test('round-trips a coordinate pair', () {
      final sealed = PunchCrypto.encryptCoordinates(
        key: key,
        latitude: -6.208763,
        longitude: 106.845600,
      );
      final opened = PunchCrypto.decryptCoordinates(key: key, ciphertext: sealed);

      expect(opened, isNotNull);
      expect(opened!.$1, closeTo(-6.208763, 1e-9));
      expect(opened.$2, closeTo(106.8456, 1e-9));
    });

    test('round-trips under associated data', () {
      final sealed = PunchCrypto.encrypt(
        key: key,
        plaintext: 'rahasia',
        associatedData: 'uid_2026-10-08',
      );
      expect(
        PunchCrypto.decrypt(
          key: key,
          ciphertext: sealed,
          associatedData: 'uid_2026-10-08',
        ),
        'rahasia',
      );
    });

    test('fails to open under a different key', () {
      final sealed = PunchCrypto.encrypt(key: key, plaintext: 'rahasia');
      expect(
        PunchCrypto.decrypt(key: PunchCrypto.generateKey(), ciphertext: sealed),
        isNull,
      );
    });

    test('fails to open under different associated data', () {
      // This is what stops a ciphertext being copied from one employee's punch
      // onto another's document.
      final sealed = PunchCrypto.encrypt(
        key: key,
        plaintext: 'rahasia',
        associatedData: 'uidA_2026-10-08',
      );
      expect(
        PunchCrypto.decrypt(
          key: key,
          ciphertext: sealed,
          associatedData: 'uidB_2026-10-08',
        ),
        isNull,
        reason: 'a ciphertext lifted onto another record must not authenticate',
      );
    });

    test('detects a tampered ciphertext', () {
      final sealed = PunchCrypto.encrypt(key: key, plaintext: '-6.20,106.84');
      // Flip one base64 character in the body.
      final body = sealed.substring(PunchCrypto.encryptedPrefix.length);
      final flipped = body[2] == 'A' ? 'B' : 'A';

      expect(
        PunchCrypto.decrypt(
          key: key,
          ciphertext:
              '${PunchCrypto.encryptedPrefix}${body[0]}$body[1]$flipped${body.substring(3)}',
        ),
        isNull,
        reason: 'GCM must reject a modified body rather than yielding wrong coordinates',
      );
    });

    test('returns null for a plaintext or malformed value', () {
      // Degrades to "no coordinates" rather than throwing, so a legacy field or a
      // corrupt value cannot take the punch screen down.
      expect(PunchCrypto.decrypt(key: key, ciphertext: 'not-encrypted'), isNull);
      expect(PunchCrypto.decrypt(key: key, ciphertext: '${PunchCrypto.encryptedPrefix}!!!'), isNull);
      expect(
        PunchCrypto.decrypt(key: key, ciphertext: PunchCrypto.encryptedPrefix),
        isNull,
      );
    });

    test('uses a fresh nonce for every encryption', () {
      // Reusing a GCM nonce under one key leaks the XOR of the plaintexts and
      // permits tag forgery, so identical input must never produce identical
      // output.
      final first = PunchCrypto.encrypt(key: key, plaintext: 'same');
      final second = PunchCrypto.encrypt(key: key, plaintext: 'same');
      expect(first, isNot(second));
    });

    test('tags its output with a version marker', () {
      final sealed = PunchCrypto.encrypt(key: key, plaintext: 'x');
      expect(sealed, startsWith(PunchCrypto.encryptedPrefix));
    });
  });

  group('key derivation', () {
    test('is deterministic for one secret', () {
      final a = PunchCrypto.deriveKey('device-abc');
      final b = PunchCrypto.deriveKey('device-abc');
      expect(a, b);
    });

    test('differs across secrets', () {
      expect(PunchCrypto.deriveKey('device-abc'), isNot(PunchCrypto.deriveKey('device-xyz')));
    });

    test('yields a full-length key from a short secret', () {
      // The whole point of PBKDF2: a low-entropy device identifier must not yield
      // a short key.
      expect(PunchCrypto.deriveKey('a').length, PunchCrypto.keyLengthBytes);
    });

    test('produces a different key per device identity', () {
      // Two employees on two phones must not share a sealing key, or one
      // ciphertext would open on the other's device.
      expect(
        PunchCrypto.deriveKey('sae.android-1'),
        isNot(PunchCrypto.deriveKey('sae.android-2')),
      );
    });
  });

  group('fix trust', () {
    test('refuses an OS-reported mock fix', () {
      const geofence = GeofenceRules();
      final zone = Zone.fromMap('z', {
        'name': 'Kantor',
        'latitude': -6.208763,
        'longitude': 106.8456,
        'radiusMeters': 150,
        'isActive': true,
      });

      // Standing exactly on the zone centre, so the only reason to refuse is the
      // provenance flag.
      final result = geofence.evaluate(
        zone: zone,
        fix: const Fix(
          latitude: -6.208763,
          longitude: 106.8456,
          accuracyMeters: 5,
          isMocked: true,
        ),
      );

      expect(result.allowed, isFalse);
      expect(result.reason, PunchBlockReason.mockLocation);
    });

    test('accepts a genuine fix at the zone centre', () {
      const geofence = GeofenceRules();
      final zone = Zone.fromMap('z', {
        'name': 'Kantor',
        'latitude': -6.208763,
        'longitude': 106.8456,
        'radiusMeters': 150,
        'isActive': true,
      });

      final result = geofence.evaluate(
        zone: zone,
        fix: const Fix(
          latitude: -6.208763,
          longitude: 106.8456,
          accuracyMeters: 5,
        ),
      );
      expect(result.allowed, isTrue);
    });

    test('reports a fix as untrusted on either signal', () {
      expect(
        FixTrust.isUntrusted(osReportedMock: true, nullIsland: false),
        isTrue,
      );
      expect(
        FixTrust.isUntrusted(osReportedMock: false, nullIsland: true),
        isTrue,
      );
      expect(
        FixTrust.isUntrusted(osReportedMock: false, nullIsland: false),
        isFalse,
      );
    });
  });

  group('device integrity', () {
    test('a clean report has no findings', () {
      const report = IntegrityReport.clean();
      expect(report.isClean, isTrue);
      expect(report.hasBlocking, isFalse);
      expect(report.codes, isEmpty);
    });

    test('separates blocking findings from warnings', () {
      const report = IntegrityReport(findings: [
        IntegrityFinding(
          code: IntegrityCode.debuggerAttached,
          severity: Severity.warning,
          message: 'Debugger terpasang.',
        ),
      ]);
      // A debugger is a warning, not a lockout: it blocks no legitimate punch.
      expect(report.isClean, isFalse);
      expect(report.hasBlocking, isFalse);
      expect(report.codes, 'debuggerAttached');
    });

    test('blocks on a root or jailbreak finding', () {
      const report = IntegrityReport(findings: [
        IntegrityFinding(
          code: IntegrityCode.rootedOrJailbroken,
          severity: Severity.blocking,
          message: 'Perangkat di-root.',
        ),
      ]);
      expect(report.hasBlocking, isTrue);
      expect(report.blocking.length, 1);
    });

    test('writes nothing onto a punch when the device is clean', () {
      expect(PunchCrypto.describeIntegrity(const IntegrityReport.clean()), isEmpty);
    });

    test('stamps the codes onto a punch when findings exist', () {
      final fields = PunchCrypto.describeIntegrity(const IntegrityReport(findings: [
        IntegrityFinding(
          code: IntegrityCode.debuggerAttached,
          severity: Severity.warning,
          message: 'x',
        ),
        IntegrityFinding(
          code: IntegrityCode.emulator,
          severity: Severity.blocking,
          message: 'y',
        ),
      ]));

      expect(fields['deviceIntegrityFlagged'], isTrue);
      expect(fields['deviceIntegrityCodes'], 'debuggerAttached,emulator');
    });
  });

  group('sealed attendance fields', () {
    final key = PunchCrypto.generateKey();

    test('writes nothing when the coordinates are absent', () {
      final sealed = PunchCrypto.sealAttendance(
        key: key,
        documentId: 'uid_2026-10-08',
        latitude: null,
        longitude: 106.8,
      );
      // A partial pair is not a position, so nothing is sealed.
      expect(sealed, isEmpty);
    });

    test('round-trips through the record model', () {
      const documentId = 'uid_2026-10-08';
      final sealed = PunchCrypto.sealAttendance(
        key: key,
        documentId: documentId,
        latitude: -6.208763,
        longitude: 106.8456,
      );

      final record = AttendanceDoc.fromMap(documentId, {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': '2026-10-08',
        'status': 'CHECKED_IN',
        ...sealed,
      });

      final opened = PunchCrypto.openCoordinates(
        key: key,
        documentId: documentId,
        record: record,
      );

      expect(opened, isNotNull);
      expect(opened!.$1, closeTo(-6.208763, 1e-9));
    });

    test('returns null when the sealed field is absent', () {
      final record = AttendanceDoc.fromMap('uid_2026-10-08', {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': '2026-10-08',
        'status': 'CHECKED_IN',
      });

      expect(
        PunchCrypto.openCoordinates(
          key: key,
          documentId: 'uid_2026-10-08',
          record: record,
        ),
        isNull,
      );
    });

    test('returns null under another device key', () {
      const documentId = 'uid_2026-10-08';
      final sealed = PunchCrypto.sealAttendance(
        key: key,
        documentId: documentId,
        latitude: -6.208763,
        longitude: 106.8456,
      );
      final record = AttendanceDoc.fromMap(documentId, {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': '2026-10-08',
        'status': 'CHECKED_IN',
        ...sealed,
      });

      expect(
        PunchCrypto.openCoordinates(
          key: PunchCrypto.deriveKey('sae.some-other-device'),
          documentId: documentId,
          record: record,
        ),
        isNull,
      );
    });
  });

  group('integrity fields on a record', () {
    test('reads the liveness verdict and the integrity flag', () {
      final record = AttendanceDoc.fromMap('uid_2026-10-08', {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': '2026-10-08',
        'status': 'CHECKED_IN',
        'livenessVerified': true,
        'deviceIntegrityFlagged': true,
        'deviceIntegrityCodes': 'debuggerAttached',
      });

      expect(record.livenessVerified, isTrue);
      expect(record.deviceIntegrityFlagged, isTrue);
      expect(record.deviceIntegrityCodes, 'debuggerAttached');
    });

    test('treats fields absent from an older record as not verified', () {
      final record = AttendanceDoc.fromMap('uid_2026-10-08', {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': '2026-10-08',
        'status': 'CHECKED_IN',
      });

      expect(record.livenessVerified, isNull,
          reason: 'unknown is distinct from a failed check');
      expect(record.deviceIntegrityFlagged, isFalse);
    });

    test('records a failed liveness check as false, not absent', () {
      final record = AttendanceDoc.fromMap('uid_2026-10-08', {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': '2026-10-08',
        'status': 'CHECKED_IN',
        'livenessVerified': false,
      });

      expect(record.livenessVerified, isFalse);
    });
  });

  group('key hygiene', () {
    test('a derived key is not itself printable text', () {
      // A mistake that produces a string key rather than bytes would otherwise
      // pass every round-trip test above.
      final derived = PunchCrypto.deriveKey('sae.android-1');
      expect(derived, isA<Uint8List>());
      expect(derived.length, 32);
    });
  });
}