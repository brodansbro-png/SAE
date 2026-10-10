import 'package:cloud_firestore/cloud_firestore.dart';

import '../logic/geofence_rules.dart';
import '../logic/shift_rules.dart';
import '../logic/time_keys.dart';
import '../models/permission.dart';
import '../models/shift.dart';
import 'auth_service.dart';
import 'firestore_map.dart';

/// Reads the settings every signed-in client needs: zones, shifts and leave
/// types.
///
/// `firestore.rules` grants read access to all three collections to any signed
/// in user, because the app cannot geofence or validate a punch window without
/// them. Only an administrator may write, and this service never does.
class SettingsService {
  SettingsService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Collection paths, matching `COLLECTIONS` in `firestore.ts`.
  ///
  /// Top-level collections agar compatible dengan JS SDK v10 yang butuh path
  /// segmen ganjil. Sebelumnya 'settings/zones' (2 segmen = invalid di JS SDK).
  static const String zonesPath = 'zones';
  static const String shiftsPath = 'shifts';
  static const String permissionTypesPath = 'permission_types';

  /// Document id of the singleton app-settings document.
  static const String appSettingsId = 'current';

  /// App settings collection path.
  static const String appSettingsPath = 'settings';

  /// Every zone, including deactivated ones.
  ///
  /// Deactivated zones are read rather than filtered out so the app can explain
  /// *why* a punch is refused — an employee told "your zone is disabled" can act
  /// on it, while one told "no zone assigned" cannot.
  Future<List<Zone>> loadZones() async {
    try {
      final snapshot = await _firestore
          .collection(zonesPath)
          .orderBy('name')
          .get();

      return snapshot.docs
          .map((doc) => Zone.fromMap(doc.id, firestoreData(doc.data())))
          .toList();
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Every shift, ordered by start time.
  Future<List<Shift>> loadShifts() async {
    try {
      final snapshot =
          await _firestore.collection(shiftsPath).orderBy('startTime').get();

      return snapshot.docs
          .map((doc) => Shift.fromMap(doc.id, firestoreData(doc.data())))
          .toList();
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// The active shift with [shiftId], or `null` when it no longer exists.
  ///
  /// Resolved on the client rather than read through `users/{uid}` because the
  /// zone and shift documents are small and cached; a missing id therefore
  /// resolves to `null` and the punch screen explains it, instead of a stale
  /// `shiftId` string pointing at nothing.
  static Shift? resolveShift(List<Shift> shifts, String? shiftId) {
    if (shiftId == null || shiftId.trim().isEmpty) return null;
    for (final shift in shifts) {
      if (shift.id == shiftId) return shift;
    }
    return null;
  }

  /// The zone with [zoneId], or `null`.
  static Zone? resolveZone(List<Zone> zones, String? zoneId) {
    if (zoneId == null || zoneId.trim().isEmpty) return null;
    for (final zone in zones) {
      if (zone.id == zoneId) return zone;
    }
    return null;
  }

  /// Resolves a zone from an already-known centre.
  ///
  /// The punch record stores the zone's coordinates and radius alongside the
  /// distance, so a historical record can still be shown when the zone has
  /// since been deleted or moved.
  static Zone zoneFromPunch({
    required String? zoneId,
    required String? zoneName,
    required double? latitude,
    required double? longitude,
    required double? radiusMeters,
  }) =>
      Zone(
        id: zoneId ?? '',
        name: zoneName ?? 'Zona tidak dikenal',
        latitude: latitude ?? double.nan,
        longitude: longitude ?? double.nan,
        radiusMeters: radiusMeters ?? double.nan,
        isActive: true,
      );

  /// Human-readable zone description for the punch screen header.
  static String describeZone(Zone? zone) {
    if (zone == null) return 'Zona belum ditentukan';
    final address = zone.address?.trim();
    if (address == null || address.isEmpty) return zone.name;
    return '${zone.name} · $address';
  }

  /// A one-line summary of a shift, for the profile screen.
  static String describeShift(Shift? shift) {
    if (shift == null) return 'Shift belum ditentukan';
    final days = shift.daysOfWeek.isEmpty
        ? 'tanpa hari kerja'
        : shift.daysOfWeek
            .map((day) => indonesianWeekdayNames[(day - 1).clamp(0, 6)])
            .join(', ');
    return '${shift.name} · ${shift.windowLabel} · $days';
  }

  /// Loads leave categories.
  Future<List<PermissionTypeDoc>> loadPermissionTypes() async {
    try {
      final snapshot =
          await _firestore.collection(permissionTypesPath).orderBy('name').get();

      return snapshot.docs
          .map((doc) => PermissionTypeDoc.fromMap(
                doc.id,
                firestoreData(doc.data()),
              ))
          .toList();
    } catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Reads the singleton app-settings document.
  ///
  /// Returns `null` when it does not exist, which the app treats as "nothing
  /// configured" — no forced update, no maintenance gate — rather than as an
  /// error that would block every employee from signing in.
  Future<Map<String, dynamic>?> loadAppSettings() async {
    try {
      final doc =
          await _firestore.collection(appSettingsPath).doc(appSettingsId).get();
      if (!doc.exists) return null;
      return firestoreData(doc.data());
    } catch (error) {
      throw toAppFailure(error);
    }
  }
}

/// Re-exported so the punch screen does not need two imports to describe a
/// shift's windows next to its zone.
String describeShiftWindowsFor(Shift? shift) =>
    shift == null ? 'Shift belum ditentukan' : describeShiftWindows(shift);