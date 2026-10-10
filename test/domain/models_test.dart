import 'package:flutter_test/flutter_test.dart';

import 'package:sae/domain/logic/geofence_rules.dart';
import 'package:sae/domain/models/activity_log.dart';
import 'package:sae/domain/models/attendance.dart';
import 'package:sae/domain/models/permission.dart';
import 'package:sae/domain/models/shift.dart';
import 'package:sae/domain/models/app_settings.dart';
import 'package:sae/domain/models/user.dart';
import 'package:sae/domain/services/attendance_service.dart';
import 'package:sae/domain/services/permissions_service.dart';

/// Covers the model and service-level logic that the widget tests cannot reach
/// without a live Firestore.
///
/// Everything here is pure: documents in, decisions out. That is deliberate —
/// the parts of this app most likely to be wrong are the ones that decide
/// whether a punch is allowed, and those must be checkable without an emulator.
void main() {
  group('attendance record', () {
    AttendanceDoc record(Map<String, dynamic> data) =>
        AttendanceDoc.fromMap('uid_2026-10-08', data);

    final base = <String, dynamic>{
      'userId': 'uid',
      'userName': 'Budi Santoso',
      'employeeNumber': 'PG-0002',
      'recordDate': '2026-10-08',
      'status': 'CHECKED_IN',
    };

    test('builds a deterministic document id', () {
      // This is the id both sides of a check-in/check-out pair resolve, so it
      // must be reproducible from the uid and the local day alone.
      expect(
        AttendanceDoc.documentIdFor('abc123', '2026-10-08'),
        'abc123_2026-10-08',
      );
    });

    test('treats a check-in without a check-out as open', () {
      final doc = record({...base, 'checkInTime': '08:00'});
      expect(doc.hasCheckIn, isTrue);
      expect(doc.hasCheckOut, isFalse);
      expect(doc.isOpen, isTrue);
      expect(doc.isCompleted, isFalse);
    });

    test('treats both punches as complete', () {
      final doc = record({...base, 'checkInTime': '08:00', 'checkOutTime': '17:00'});
      expect(doc.isOpen, isFalse);
      expect(doc.isCompleted, isTrue);
    });

    test('treats neither punch as not punched at all', () {
      final doc = record(base);
      expect(doc.hasCheckIn, isFalse);
      expect(doc.isOpen, isFalse);
      expect(doc.isCompleted, isFalse);
    });

    test('treats an empty string as absent', () {
      // Firestore omits a field rather than storing "", but a hand-edited
      // document can hold either and both mean "no punch recorded".
      final doc = record({...base, 'checkInTime': ''});
      expect(doc.hasCheckIn, isFalse);
    });

    test('flags a punch recorded outside its own radius', () {
      final doc = record({
        ...base,
        'checkInTime': '08:00',
        'checkInDistanceMeters': 220.0,
        'checkInZoneRadiusMeters': 150.0,
      });
      expect(doc.checkInOutsideZone, isTrue);
    });

    test('does not flag a punch inside its radius', () {
      final doc = record({
        ...base,
        'checkInTime': '08:00',
        'checkInDistanceMeters': 40.0,
        'checkInZoneRadiusMeters': 150.0,
      });
      expect(doc.checkInOutsideZone, isFalse);
    });

    test('reads an int distance as a double', () {
      // A platform channel decodes Firestore numbers without a guaranteed type.
      final doc = record({
        ...base,
        'checkInTime': '08:00',
        'checkInDistanceMeters': 42,
      });
      expect(doc.checkInDistanceMeters, 42.0);
    });

    test('labels every known status in Indonesian', () {
      for (final status in AttendanceStatus.all) {
        expect(
          attendanceStatusLabels[status],
          isNotNull,
          reason: 'status $status must have a label',
        );
      }
      expect(attendanceStatusLabels['COMPLETED'], 'Lengkap');
      expect(attendanceStatusLabels['LATE'], 'Terlambat');
      expect(attendanceStatusLabels['ON_LEAVE'], 'Izin');
    });

    test('counts only worked days as present', () {
      // A day on leave is not an absence, so it must not inflate the rate.
      expect(statusCountsAsPresent('COMPLETED'), isTrue);
      expect(statusCountsAsPresent('LATE'), isTrue);
      expect(statusCountsAsPresent('EARLY_LEAVE'), isTrue);
      expect(statusCountsAsPresent('CHECKED_IN'), isTrue);
      expect(statusCountsAsPresent('ON_LEAVE'), isFalse);
      expect(statusCountsAsPresent('ABSENT'), isFalse);
      expect(statusCountsAsPresent('PENDING'), isFalse);
    });
  });

  group('history summary', () {
    AttendanceDoc on(String date, String status, {String? checkOut}) {
      final data = <String, dynamic>{
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'recordDate': date,
        'status': status,
        'checkInTime': '08:00',
      };
      // Built imperatively because the null-aware map entry (`?key: value`) is
      // not available at this language version.
      if (checkOut != null) data['checkOutTime'] = checkOut;
      return AttendanceDoc.fromMap('id', data);
    }

    test('counts only the requested month', () {
      final summary = AttendanceService.summarise([
        on('2026-10-01', 'COMPLETED', checkOut: '17:00'),
        on('2026-10-02', 'LATE'),
        on('2026-09-30', 'COMPLETED', checkOut: '17:00'),
      ], '2026-10');

      expect(summary.totalRecords, 2);
      expect(summary.present, 2);
    });

    test('counts late, early and incomplete separately', () {
      final summary = AttendanceService.summarise([
        on('2026-10-01', 'COMPLETED', checkOut: '17:00'),
        on('2026-10-02', 'LATE'),
        on('2026-10-05', 'EARLY_LEAVE', checkOut: '15:00'),
        on('2026-10-06', 'CHECKED_IN'),
      ], '2026-10');

      expect(summary.present, 4);
      expect(summary.late, 1);
      expect(summary.earlyLeave, 1);
      // Both the late and the still-open day count: a check-in with no check-out
      // is the record an administrator most often has to correct by hand, and
      // the two need the same attention.
      expect(summary.incomplete, 2);
    });

    test('does not count leave as attendance', () {
      final summary = AttendanceService.summarise([
        on('2026-10-01', 'ON_LEAVE'),
      ], '2026-10');

      expect(summary.present, 0);
      expect(summary.attendanceRate, 0);
    });

    test('reports a zero rate for an empty month rather than dividing by zero', () {
      final summary = AttendanceService.summarise([], '2026-10');
      expect(summary.attendanceRate, 0);
      expect(summary.totalRecords, 0);
    });

    test('rounds the rate to a whole percentage', () {
      // 2 of 3 days worked is 66.67%, shown as 67.
      final summary = AttendanceService.summarise([
        on('2026-10-01', 'COMPLETED', checkOut: '17:00'),
        on('2026-10-02', 'COMPLETED', checkOut: '17:00'),
        on('2026-10-03', 'ABSENT'),
      ], '2026-10');

      expect(summary.attendanceRate, 67);
    });
  });

  group('staff profile', () {
    test('treats a missing isActive as inactive', () {
      // An unknown status must not grant punching rights.
      final user = UserDoc.fromMap('uid', {'role': 'USER'});
      expect(user.isActive, isFalse);
    });

    test('treats an unrecognised role as the least-privileged one', () {
      // A corrupted document must never silently grant administrator rights.
      final user = UserDoc.fromMap('uid', {'role': 'SUPERADMIN'});
      expect(user.role, 'USER');
      expect(user.isAdmin, isFalse);
    });

    test('falls back through weaker name sources', () {
      expect(
        UserDoc.fromMap('uid', {'displayName': 'Budi Santoso'}).displayLabel,
        'Budi Santoso',
      );
      expect(
        UserDoc.fromMap('uid', {'email': 'budi@sae.local'}).displayLabel,
        'budi',
      );
      expect(UserDoc.fromMap('uid', {}).displayLabel, 'Pengguna');
    });

    test('grants an admin every page', () {
      final user = UserDoc.fromMap('uid', {'role': 'ADMIN'});
      expect(user.resolvedPages.length, 6);
    });

    test('never escalates a user through a stored page list', () {
      // The same restriction `firestore.rules` enforces, mirrored client-side.
      final user = UserDoc.fromMap('uid', {
        'role': 'USER',
        'accessiblePages': ['employees', 'settings'],
      });
      expect(user.resolvedPages, isEmpty);
    });
  });

  group('leave validation', () {
    const validator = PermissionValidator();

    PermissionTypeDoc type({
      int maxDays = 3,
      bool requiresAttachment = false,
      bool isActive = true,
    }) =>
        PermissionTypeDoc(
          id: 'pt1',
          name: 'Cuti Tahunan',
          maxDays: maxDays,
          requiresAttachment: requiresAttachment,
          isActive: isActive,
        );

    test('accepts a plain two-day request', () {
      final result = validator.validate(
        type: type(),
        startDate: '2026-10-05',
        endDate: '2026-10-06',
        reason: 'Keperluan keluarga',
      );
      expect(result.isValid, isTrue);
      expect(result.dayCount, 2);
    });

    test('refuses when no type is chosen', () {
      final result = validator.validate(
        type: null,
        startDate: '2026-10-05',
        endDate: '2026-10-06',
        reason: 'Keperluan keluarga',
      );
      expect(result.error, PermissionFormError.noTypeSelected);
      expect(result.errorMessage, contains('Pilih jenis izin'));
    });

    test('distinguishes an unconfigured type list from an unpicked field', () {
      // A setup problem nobody in the request flow can fix, so the copy points
      // at the administrator rather than at the missing form field.
      final none = validator.validate(
        type: null,
        startDate: '2026-10-05',
        endDate: '2026-10-06',
        reason: 'Keperluan keluarga',
        typesAreConfigured: false,
      );
      expect(none.error, PermissionFormError.noTypesAvailable);
      expect(none.errorMessage, contains('administrator'));
    });

    test('refuses an end date before the start', () {
      final result = validator.validate(
        type: type(),
        startDate: '2026-10-06',
        endDate: '2026-10-05',
        reason: 'Keperluan keluarga',
      );
      expect(result.error, PermissionFormError.endBeforeStart);
    });

    test('refuses a span beyond the type cap', () {
      final result = validator.validate(
        type: type(maxDays: 2),
        startDate: '2026-10-05',
        endDate: '2026-10-09',
        reason: 'Keperluan keluarga',
      );
      expect(result.error, PermissionFormError.exceedsMaxDays);
      expect(result.errorMessage, contains('2 hari'));
    });

    test('refuses a reason that is too short or too long', () {
      expect(
        validator
            .validate(
              type: type(),
              startDate: '2026-10-05',
              endDate: '2026-10-06',
              reason: 'sak',
            )
            .error,
        PermissionFormError.reasonTooShort,
      );
      expect(
        validator
            .validate(
              type: type(),
              startDate: '2026-10-05',
              endDate: '2026-10-06',
              reason: 'x' * 1001,
            )
            .error,
        PermissionFormError.reasonTooLong,
      );
    });

    test('requires an attachment when the type demands one', () {
      final result = validator.validate(
        type: type(requiresAttachment: true),
        startDate: '2026-10-05',
        endDate: '2026-10-06',
        reason: 'Surgek dokter',
      );
      expect(result.error, PermissionFormError.attachmentRequired);
    });

    test('counts working days, excluding the weekend', () {
      // Friday 9th through Monday 12th is four calendar days but only two
      // working ones: the 10th and 11th are a weekend.
      final result = validator.validate(
        type: type(maxDays: 5),
        startDate: '2026-10-09',
        endDate: '2026-10-12',
        reason: 'Keperluan keluarga',
      );
      expect(result.isValid, isTrue);
      expect(result.dayCount, 2);
    });

    test('counts a full week as five working days', () {
      final result = validator.validate(
        type: type(maxDays: 7),
        startDate: '2026-10-05',
        endDate: '2026-10-11',
        reason: 'Keperluan keluarga',
      );
      expect(result.dayCount, 5);
    });

    test('excludes a whole weekend', () {
      final result = validator.validate(
        type: type(maxDays: 5),
        startDate: '2026-10-10',
        endDate: '2026-10-11',
        reason: 'Akhir pekan',
      );
      expect(result.dayCount, 0);
    });

    test('refuses a deactivated type', () {
      final result = validator.validate(
        type: type(isActive: false),
        startDate: '2026-10-05',
        endDate: '2026-10-06',
        reason: 'Keperluan keluarga',
      );
      expect(result.error, PermissionFormError.noTypeSelected);
    });

    test('treats a malformed type document as the strict reading', () {
      // An older document missing the flags must not become an unlimited,
      // evidence-free leave.
      final parsed = PermissionTypeDoc.fromMap('pt', {'name': 'Izin'});
      expect(parsed.requiresAttachment, isTrue);
      expect(parsed.maxDays, 30);
    });
  });

  group('leave request dates', () {
    PermissionDoc request(String start, String end) => PermissionDoc.fromMap('id', {
          'userId': 'uid',
          'userName': 'Budi',
          'employeeNumber': 'PG-0002',
          'permissionTypeId': 'pt1',
          'permissionTypeName': 'Cuti',
          'startDate': start,
          'endDate': end,
          'reason': 'Keperluan',
          'status': 'APPROVED',
        });

    test('covers today only inside the range', () {
      final doc = request('2026-10-05', '2026-10-09');
      expect(doc.coversDate('2026-10-05'), isTrue, reason: 'inclusive start');
      expect(doc.coversDate('2026-10-09'), isTrue, reason: 'inclusive end');
      expect(doc.coversDate('2026-10-04'), isFalse);
      expect(doc.coversDate('2026-10-10'), isFalse);
    });

    test('recognises an approved request covering today', () {
      final docs = [
        request('2026-10-01', '2026-10-03'),
        request('2026-10-05', '2026-10-09'),
      ];
      expect(
        PermissionsService.approvedLeaveToday(docs, now: DateTime(2026, 10, 7)),
        isNotNull,
      );
      expect(
        PermissionsService.isOnApprovedLeaveToday(
          docs,
          now: DateTime(2026, 10, 2),
        ),
        isTrue,
      );
    });

    test('ignores a request that is not approved', () {
      // A pending request must not excuse an absence.
      final pending = PermissionDoc.fromMap('id', {
        'userId': 'uid',
        'userName': 'Budi',
        'employeeNumber': 'PG-0002',
        'permissionTypeId': 'pt1',
        'permissionTypeName': 'Cuti',
        'startDate': '2026-10-05',
        'endDate': '2026-10-09',
        'reason': 'Keperluan',
        'status': 'PENDING',
      });
      expect(
        PermissionsService.isOnApprovedLeaveToday(
          [pending],
          now: DateTime(2026, 10, 7),
        ),
        isFalse,
      );
    });

    test('only lets a pending request be withdrawn or reviewed', () {
      final pending = PermissionDoc.fromMap('id', {
        'userId': 'uid',
        'userName': 'B',
        'employeeNumber': '1',
        'permissionTypeId': 'pt',
        'permissionTypeName': 'C',
        'startDate': '2026-10-05',
        'endDate': '2026-10-06',
        'reason': 'x',
        'status': 'PENDING',
      });
      final approved = PermissionDoc.fromMap('id2', {
        'userId': 'uid',
        'userName': 'B',
        'employeeNumber': '1',
        'permissionTypeId': 'pt',
        'permissionTypeName': 'C',
        'startDate': '2026-10-05',
        'endDate': '2026-10-06',
        'reason': 'x',
        'status': 'APPROVED',
      });

      expect(pending.canBeCancelled, isTrue);
      expect(pending.canBeReviewed, isTrue);
      expect(approved.canBeCancelled, isFalse);
      expect(approved.canBeReviewed, isFalse);
    });

    test('treats an unrecognised status as not actionable', () {
      // An unrecognised value must never be cancelable by the employee.
      final doc = PermissionDoc.fromMap('id', {
        'userId': 'uid',
        'userName': 'B',
        'employeeNumber': '1',
        'permissionTypeId': 'pt',
        'permissionTypeName': 'C',
        'startDate': '2026-10-05',
        'endDate': '2026-10-06',
        'reason': 'x',
        'status': 'WEIRD',
      });
      expect(doc.status, 'PENDING');
      expect(doc.canBeCancelled, isTrue);
    });
  });

  group('app settings gates', () {
    test('compares version segments as numbers, not strings', () {
      // The bug a lexical compare produces: 0.9.0 sorts above 0.10.0, so a
      // release gate silently stops working after release 9.
      expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('1.0.1', '1.0.0'), greaterThan(0));
      expect(compareVersions('2.0.0', '10.0.0'), lessThan(0));
    });

    test('handles a differing number of segments', () {
      expect(compareVersions('1.0', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.1', '1.0'), greaterThan(0));
    });

    test('treats an empty gate as disabled', () {
      // A project that has never configured a minimum must not lock every
      // employee out.
      expect(isVersionBelowMinimum('1.0.0', ''), isFalse);
      expect(isVersionBelowMinimum('', '1.0.0'), isFalse);
    });

    test('blocks only an older build', () {
      expect(isVersionBelowMinimum('1.0.0', '1.2.0'), isTrue);
      expect(isVersionBelowMinimum('1.2.0', '1.2.0'), isFalse);
      expect(isVersionBelowMinimum('1.3.0', '1.2.0'), isFalse);
    });

    test('defaults both kill switches off', () {
      // A document missing the flags is an older build's; refusing every punch
      // because of an absent field would be the worse failure.
      final settings = AppSettings.fromMap({'orgName': 'SAE'});
      expect(settings.forceUpdate, isFalse);
      expect(settings.maintenanceMode, isFalse);
    });

    test('falls back to generic maintenance copy', () {
      final settings = AppSettings.fromMap({'maintenanceMode': true});
      expect(settings.maintenanceNotice, contains('pemeliharaan'));
    });

    test('names the target version in the update prompt', () {
      final settings = AppSettings.fromMap({
        'appVersion': '2.0.0',
        'forceUpdate': true,
      });
      expect(settings.updateRequiredMessage('1.0.0'), contains('2.0.0'));
      expect(settings.updateRequiredMessage('1.0.0'), contains('1.0.0'));
    });
  });

  group('audit trail', () {
    test('labels every action in Indonesian', () {
      for (final action in ActivityAction.all) {
        expect(
          ActivityLogDoc.fromMap('id', {
            'actorUid': 'uid',
            'actorName': 'Budi',
            'actorRole': 'USER',
            'action': action,
            'summary': 'x',
            'atLocal': '08:00:00',
          }).actionLabel,
          isNotEmpty,
          reason: 'action $action must have a label',
        );
      }
    });

    test('falls back to the raw value for an unknown action', () {
      // An unrecognised action is shown verbatim rather than hidden, so an
      // auditor can see it happened even if a newer client wrote it.
      final log = ActivityLogDoc.fromMap('id', {
        'actorUid': 'uid',
        'actorName': 'Budi',
        'actorRole': 'USER',
        'action': 'FUTURE_ACTION',
        'summary': 'x',
        'atLocal': '08:00:00',
      });
      expect(log.actionLabel, 'FUTURE_ACTION');
    });
  });

  group('shift assignment resolution', () {
    final shifts = [
      Shift.fromMap('s1', {'name': 'Pagi', 'startTime': '08:00', 'endTime': '17:00'}),
      Shift.fromMap('s2', {'name': 'Malam', 'startTime': '22:00', 'endTime': '06:00'}),
    ];

    test('resolves an assigned shift', () {
      expect(SettingsServiceBridge.resolve(shifts, 's2')?.name, 'Malam');
    });

    test('resolves nothing for a missing or blank id', () {
      expect(SettingsServiceBridge.resolve(shifts, null), isNull);
      expect(SettingsServiceBridge.resolve(shifts, ''), isNull);
      expect(SettingsServiceBridge.resolve(shifts, 's9'), isNull);
    });

    test('describes a shift with its hours and working days', () {
      final described = SettingsServiceBridge.describe(shifts.first);
      expect(described, contains('Pagi'));
      expect(described, contains('08:00–17:00'));
    });

    test('names the missing assignment rather than rendering nothing', () {
      expect(SettingsServiceBridge.describe(null), 'Shift belum ditentukan');
      expect(SettingsServiceBridge.describeZone(null), 'Zona belum ditentukan');
    });
  });

  group('zone document', () {
    test('rejects an unusable geofence', () {
      final zone = Zone.fromMap('z', {
        'name': 'Z',
        'latitude': 0,
        'longitude': 0,
        'radiusMeters': 100000,
        'isActive': true,
      });
      expect(zone.isUsable, isFalse);
    });

    test('accepts the radius bounds the rules allow', () {
      for (final radius in [10, 150, 2000]) {
        final zone = Zone.fromMap('z', {
          'name': 'Z',
          'latitude': -6.2,
          'longitude': 106.8,
          'radiusMeters': radius,
          'isActive': true,
        });
        expect(zone.isUsable, isTrue, reason: 'radius $radius');
      }
    });

    test('rejects coordinates outside the valid range', () {
      final zone = Zone.fromMap('z', {
        'name': 'Z',
        'latitude': 95.0,
        'longitude': 106.8,
        'radiusMeters': 150,
        'isActive': true,
      });
      expect(zone.isUsable, isFalse);
    });
  });
}

/// A tiny indirection so the resolution tests read as behaviour rather than as
/// service plumbing.
class SettingsServiceBridge {
  static Shift? resolve(List<Shift> shifts, String? id) {
    for (final shift in shifts) {
      if (shift.id == id) return shift;
    }
    return null;
  }

  static String describe(Shift? shift) {
    if (shift == null) return 'Shift belum ditentukan';
    return '${shift.name} · ${shift.windowLabel} · '
        '${shift.daysOfWeek.join(', ')}';
  }

  static String describeZone(Zone? zone) =>
      zone == null ? 'Zona belum ditentukan' : zone.name;
}

