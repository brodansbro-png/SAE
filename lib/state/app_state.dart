import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/cloudinary_service.dart';
import '../data/firebase_config.dart';
import '../data/location_service.dart';
import '../data/security_service.dart';
import '../domain/errors.dart';
import '../domain/logic/access.dart';
import '../domain/logic/geo.dart';
import '../domain/logic/geofence_rules.dart';
import '../domain/logic/shift_rules.dart';
import '../domain/logic/time_keys.dart';
import '../domain/models/app_settings.dart';
import '../domain/models/attendance.dart';
import '../domain/models/permission.dart';
import '../domain/models/shift.dart';
import '../domain/models/user.dart';
import '../domain/services/attendance_service.dart';
import '../domain/services/auth_service.dart';
import '../domain/services/permissions_service.dart';
import '../domain/services/settings_service.dart';
import '../domain/services/user_service.dart';
import '../data/notification_service.dart';
import '../data/server_time_service.dart';


/// Where the app should be right now.
///
/// A single gate in front of the router. Modelled as states rather than as
/// booleans so two of them cannot both be true — the classic way a "signed in but
/// forced to update" screen becomes reachable.
enum AppStage {
  /// Firebase credentials are absent from the build.
  setupRequired,

  /// Starting up.
  loading,

  /// Signed out.
  signedOut,

  /// Signed in, but the account is deactivated or has no profile.
  profileIncomplete,

  /// Signed in, below the configured minimum version.
  updateRequired,

  /// Signed in, but punching is disabled by the administrator.
  maintenance,

  /// Ready to use.
  ready,
}

/// One-shot user feedback, consumed by the shell once and cleared.
class AppNotice {
  const AppNotice({
    required this.message,
    this.isError = false,
    this.actionLabel,
  });

  final String message;
  final bool isError;

  /// Label of an optional follow-up action, e.g. "Coba lagi".
  final String? actionLabel;
}

/// The app's single source of truth.
///
/// One `ChangeNotifier` rather than a per-feature set of providers, because the
/// screens here are not independent: the punch screen's enabled state depends on
/// the profile, the shift, the zone, the live fix and the current attendance
/// record at once. Splitting that across stores makes the stale-combination bug
/// (button enabled against a profile that was just deactivated) the default
/// rather than the exception.
class AppState extends ChangeNotifier {
  AppState({
    AuthService? authService,
    SettingsService? settingsService,
    AttendanceService? attendanceService,
    PermissionsService? permissionsService,
    UserService? userService,
    LocationService? locationService,
    CloudinaryService? cloudinaryService,
  })  : _auth = authService ?? AuthService(),
        _settings = settingsService ?? SettingsService(),
        _attendance = attendanceService ?? AttendanceService(),
        _permissions = permissionsService ?? PermissionsService(),
        _users = userService ?? UserService(),
        _location = locationService ?? LocationService(),
        _cloudinary = cloudinaryService ?? CloudinaryService.fromEnvironment();

  final AuthService _auth;
  final SettingsService _settings;
  final AttendanceService _attendance;
  final PermissionsService _permissions;
  final UserService _users;
  final LocationService _location;
  final CloudinaryService _cloudinary;

  // ─── Session ───────────────────────────────────────────────────────────────

  AppStage _stage = AppStage.loading;
  AppStage get stage => _stage;

  UserDoc? _user;
  UserDoc? get user => _user;

  /// The signed-in Firebase uid, or `null`.
  String? get uid => _user?.uid;

  bool get isAdmin => _user?.isAdmin == true;

  /// Pages this user may open, resolved exactly as the rules resolve them.
  List<AccessPage> get accessiblePages => _user?.resolvedPages ?? const [];

  bool canOpen(AccessPage page) => accessiblePages.contains(page);

  AppSettings _appSettings = const AppSettings();
  AppSettings get appSettings => _appSettings;

  String _appVersion = '';
  String get appVersion => _appVersion;

  // ─── Reference data ────────────────────────────────────────────────────────

  List<Zone> _zones = const [];
  List<Zone> get zones => _zones;

  List<Shift> _shifts = const [];
  List<Shift> get shifts => _shifts;

  List<PermissionTypeDoc> _permissionTypes = const [];
  List<PermissionTypeDoc> get permissionTypes => _permissionTypes;

  Shift? get shift => SettingsService.resolveShift(_shifts, _user?.shiftId);

  Zone? get zone => SettingsService.resolveZone(_zones, _user?.zoneId);

  // ─── Attendance ────────────────────────────────────────────────────────────

  AttendanceDoc? _today;
  AttendanceDoc? get todayRecord => _today;

  List<AttendanceDoc> _history = const [];
  List<AttendanceDoc> get history => _history;

  bool _loadingHistory = false;
  bool get isLoadingHistory => _loadingHistory;

  HistorySummary? _monthSummary;
  HistorySummary? get monthSummary => _monthSummary;

  /// The month currently summarised, as `yyyy-MM`.
  String _summaryMonth = '';
  String get summaryMonth => _summaryMonth;

  // ─── Permissions ───────────────────────────────────────────────────────────

  List<PermissionDoc> _myPermissions = const [];
  List<PermissionDoc> get myPermissions => _myPermissions;

  /// The approved request covering today, if any.
  PermissionDoc? get approvedLeaveToday =>
      PermissionsService.approvedLeaveToday(_myPermissions);

  // ─── Live location ─────────────────────────────────────────────────────────

  Fix? _fix;
  Fix? get fix => _fix;

  bool _locating = false;
  bool get isLocating => _locating;

  LocationFailure? _locationFailure;
  LocationFailure? get locationFailure => _locationFailure;

  /// Live distance to the zone centre, or `null` when unmeasurable.
  double? get liveDistance {
    final target = zone;
    final position = _fix;
    if (target == null || position == null) return null;
    final distance = haversineMeters(
      position.latitude,
      position.longitude,
      target.latitude,
      target.longitude,
    );
    return distance.isNaN ? null : distance;
  }

  /// Whether the current fix satisfies the geofence right now.
  bool get isInsideZone {
    final evaluation = _evaluateGeofence();
    return evaluation.allowed;
  }

  // ─── Device ────────────────────────────────────────────────────────────────

  String _deviceId = '';

  /// Per-install device identity, written onto every punch.
  ///
  /// Two employees producing punches under one id is the signature of a shared
  /// phone, which is exactly what an auditor looks for.
  String get deviceId => _deviceId;

  bool get isPhotoUploadConfigured => _cloudinary.isConfigured;

  CloudinaryService get cloudinary => _cloudinary;

  // ─── Notice ────────────────────────────────────────────────────────────────

  AppNotice? _notice;
  AppNotice? get notice => _notice;

  void showNotice(AppNotice notice) {
    _notice = notice;
    notifyListeners();
  }

  void consumeNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  // ─── Subscriptions ─────────────────────────────────────────────────────────

  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<UserProfileResult>? _profileSubscription;
  StreamSubscription<AttendanceDoc?>? _todaySubscription;
  StreamSubscription<Fix?>? _fixSubscription;

  /// Starts listening and loads the first screen's data.
  ///
  /// Safe to call twice; the previous subscriptions are cancelled first, because
  /// a hot restart does not re-run `main` cleanly on every platform and a
  /// duplicate listener would double every write.
  Future<void> start() async {
    if (!FirebaseConfig.isFullyConfigured) {
      _stage = AppStage.setupRequired;
      notifyListeners();
      return;
    }

    _appVersion = await _resolveAppVersion();
    _deviceId = await _resolveDeviceId();

    await _authSubscription?.cancel();
    _authSubscription = _auth.authStateChanges.listen(_onAuthStateChanged);

    // Emits the current state immediately, so a warm start is handled without a
    // separate initial read.
    await _onAuthStateChanged(_auth.currentUser);
  }

  Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }

  /// A stable per-install identifier, distinct from the Auth uid.
  ///
  /// The uid identifies the *account*, which follows an employee across devices;
  /// this identifies the *hardware*, which is what reveals a shared phone. The
  /// Android ID and the iOS identifierForVendor are both reset by the user, which
  /// is acceptable: the field's purpose is to flag the obvious case, not to track
  /// a person.
  Future<String> _resolveDeviceId() async {
    try {
      final info = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = await info.androidInfo;
        return 'android-${android.id}';
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = await info.iosInfo;
        return 'ios-${ios.identifierForVendor}';
      }
    } catch (_) {
      // Platform channel unavailable — falls through to the stable placeholder.
    }
    return 'unknown-platform';
  }

  Future<void> _onAuthStateChanged(User? user) async {
    if (user == null) {
      await _teardownSession();
      _stage = AppStage.signedOut;
      notifyListeners();
      return;
    }

    _stage = AppStage.loading;
    notifyListeners();

    // Settings first: the profile references a zone and a shift by id, and the
    // punch screen needs both resolved before it can say anything useful.
    await _loadReferenceData();
    await _subscribeToProfile(user.uid);
  }

  Future<void> _teardownSession() async {
    await _profileSubscription?.cancel();
    await _todaySubscription?.cancel();
    await _fixSubscription?.cancel();
    _profileSubscription = null;
    _todaySubscription = null;
    _fixSubscription = null;

    _user = null;
    _today = null;
    _history = const [];
    _myPermissions = const [];
    _monthSummary = null;
    _summaryMonth = '';
    _fix = null;
    _locationFailure = null;
  }

  Future<void> _loadReferenceData() async {
    try {
      final results = await Future.wait([
        _settings.loadZones(),
        _settings.loadShifts(),
        _settings.loadPermissionTypes(),
        _settings.loadAppSettings(),
      ]);

      _zones = results[0] as List<Zone>;
      _shifts = results[1] as List<Shift>;
      _permissionTypes = results[2] as List<PermissionTypeDoc>;

      final rawSettings = results[3] as Map<String, dynamic>?;
      _appSettings = rawSettings == null ? const AppSettings() : AppSettings.fromMap(rawSettings);
    } on AppFailure catch (failure) {
      _notice = AppNotice(message: failure.message, isError: true);
    }
  }

  Future<void> _subscribeToProfile(String uid) async {
    await _profileSubscription?.cancel();
    _profileSubscription = _users.watchProfile(uid).listen(
      (result) async {
        _user = result.user;
        _evaluateGates();

        if (_user == null) {
          _stage = AppStage.profileIncomplete;
          notifyListeners();
          return;
        }

        await _loadAttendance();
        await _loadPermissions();
        await _auth.touchLastSeen(uid);

        // Daftarkan FCM token ke Firestore agar server/dashboard bisa kirim push
        unawaited(NotificationService.instance.registerToken(uid));

        // Jadwalkan pengingat shift jika ada
        final activeShift = shift;
        if (activeShift != null) {
          unawaited(NotificationService.instance.scheduleShiftReminder(activeShift));
        }

        // Sinkronisasi waktu server (background)
        unawaited(ServerTimeService.instance.sync());

        _evaluateGates();
        _stage = _stage == AppStage.loading ? AppStage.ready : _stage;
        notifyListeners();
      },
      onError: (Object error) {
        _notice = AppNotice(message: toAppFailure(error).message, isError: true);
        _stage = AppStage.signedOut;
        notifyListeners();
      },
    );
  }

  /// Applies the maintenance and forced-update gates, in priority order.
  ///
  /// An account-level problem outranks a global one: telling a deactivated
  /// employee to update the app would send them somewhere that cannot help.
  void _evaluateGates() {
    if (_user == null) {
      _stage = AppStage.profileIncomplete;
      return;
    }
    if (_stage == AppStage.signedOut || _stage == AppStage.setupRequired) return;

    if (_appSettings.forceUpdate &&
        isVersionBelowMinimum(_appVersion, _appSettings.appVersion)) {
      _stage = AppStage.updateRequired;
      return;
    }
    if (_appSettings.maintenanceMode) {
      _stage = AppStage.maintenance;
      return;
    }

    _stage = _user!.isActive ? AppStage.ready : AppStage.profileIncomplete;
  }

  Future<void> _loadAttendance() async {
    final id = uid;
    if (id == null) return;

    await _todaySubscription?.cancel();
    _todaySubscription = _attendance.watchToday(id).listen((record) {
      _today = record;
      notifyListeners();
    });

    _loadingHistory = true;
    notifyListeners();

    try {
      _history = await _attendance.loadHistory(id);
      _refreshMonthSummary();
    } on AppFailure catch (failure) {
      _notice = AppNotice(message: failure.message, isError: true);
    }

    _loadingHistory = false;
    notifyListeners();
  }

  Future<void> refreshHistory() async {
    final id = uid;
    if (id == null) return;

    _loadingHistory = true;
    notifyListeners();

    try {
      _history = await _attendance.loadHistory(id);
      _refreshMonthSummary();
    } on AppFailure catch (failure) {
      _notice = AppNotice(message: failure.message, isError: true);
    }

    _loadingHistory = false;
    notifyListeners();
  }

  void _refreshMonthSummary() {
    final now = DateTime.now();
    _summaryMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _monthSummary = AttendanceService.summarise(_history, _summaryMonth);
  }

  Future<void> _loadPermissions() async {
    final id = uid;
    if (id == null) return;

    try {
      _myPermissions = await _permissions.loadForUser(id);
    } on AppFailure catch (failure) {
      _notice = AppNotice(message: failure.message, isError: true);
    }
    notifyListeners();
  }

  Future<void> refreshPermissions() async {
    await _loadPermissions();
  }

  // ─── Location ──────────────────────────────────────────────────────────────

  /// Begins live location updates.
  ///
  /// Idempotent: called on every screen entry, so a duplicate subscription would
  /// otherwise double the GPS drain over a shift.
  Future<void> startLocation() async {
    if (_fixSubscription != null) return;

    try {
      await _location.ensureReady();
      _locationFailure = null;
    } on LocationFailure catch (failure) {
      _locationFailure = failure;
      notifyListeners();
      return;
    }

    await _fixSubscription?.cancel();
    _fixSubscription = _location.watchFixes().listen((value) {
      _fix = value;
      _locationFailure = null;
      notifyListeners();
    });
  }

  void stopLocation() {
    _fixSubscription?.cancel();
    _fixSubscription = null;
  }

  /// A single fresh fix, for the punch button.
  ///
  /// Prefers the live fix when it is recent and good enough, because acquiring a
  /// new one costs the employee twenty seconds indoors; falls back to requesting
  /// one when the cached reading is stale or too coarse to certify the zone.
  Future<Fix?> acquireFix({bool force = false}) async {
    if (!force) {
      final cached = _fix;
      if (cached != null && LocationService.isFixAcceptable(cached)) return cached;
    }

    _locating = true;
    _locationFailure = null;
    notifyListeners();

    try {
      final fresh = await _location.currentFix();
      if (fresh != null) _fix = fresh;
      return fresh;
    } on LocationFailure catch (failure) {
      _locationFailure = failure;
      return null;
    } finally {
      _locating = false;
      notifyListeners();
    }
  }

  /// Opens the OS settings page, then re-checks permission on return.
  Future<void> openLocationSettings() async {
    await _location.openSettings();
    await startLocation();
  }

  /// Runs the device-integrity checks.
  ///
  /// Cached per session because the root and emulator signals cannot change while
  /// the app runs: re-running them on every punch would add platform-channel
  /// round trips to the critical path for no new information.
  IntegrityReport? _integrity;

  Future<IntegrityReport> _assessIntegrity() async {
    final cached = _integrity;
    if (cached != null) return cached;

    final report = await const DeviceIntegrityService().assess();
    _integrity = report;
    return report;
  }

  /// The last integrity assessment, for the profile screen.
  IntegrityReport? get integrityReport => _integrity;

  /// True jika jam device terdeteksi dimanipulasi vs waktu server.
  bool get isDeviceTimeSuspicious => ServerTimeService.instance.isSuspicious;

  /// Pesan peringatan waktu untuk UI.
  String? get deviceTimeWarning => ServerTimeService.instance.warningMessage;

  /// The AES key used to seal coordinates on this install.
  ///
  /// Derived from the device identity rather than stored, so there is no key
  /// material sitting in the app's data directory to steal. That makes it
  /// unsuitable for a real threat model — see `PunchCrypto` — but it does mean
  /// rotating the device identity invalidates every sealed value, which is the
  /// useful property for a migration.
  Uint8List? get sealingKey =>
      _deviceId.isEmpty ? null : PunchCrypto.deriveKey('sae.$_deviceId');

  /// Evaluates the geofence for a given fix.
  PunchEvaluation _evaluateGeofence({Fix? override}) {
    return const GeofenceRules().evaluate(
      zone: zone,
      fix: override ?? _fix,
    );
  }

  // ─── Punching ──────────────────────────────────────────────────────────────

  /// Whether the employee may punch at all right now.
  ///
  /// Cheap checks only — no network, no GPS wait. The expensive ones run inside
  /// [punch], so tapping the button never hangs on a location search that was
  /// already known to fail.
  bool get canPunch => stage == AppStage.ready && _user?.isActive == true;

  /// Evaluates a check-in without writing anything.
  ///
  /// Drives the button's enabled state and the message above it, so an employee
  /// learns *why* they cannot punch before tapping rather than after.
  PunchEvaluation evaluateCheckIn() {
    const rules = ShiftRules();
    // Pakai waktu server — tidak bisa diakali dengan mengubah jam perangkat
    return rules.evaluateCheckIn(
      shift: shift,
      now: ServerTimeService.instance.now,
      alreadyCheckedIn: _today?.hasCheckIn ?? false,
    );
  }

  /// Evaluates a check-out without writing anything.
  PunchEvaluation evaluateCheckOut({AttendanceDoc? openRecord}) {
    const rules = ShiftRules();
    // Pakai waktu server — tidak bisa diakali dengan mengubah jam perangkat
    return rules.evaluateCheckOut(
      shift: shift,
      now: ServerTimeService.instance.now,
      hasOpenCheckIn: openRecord?.isOpen ?? _today?.isOpen ?? false,
    );
  }

  /// Writes a check-in.
  ///
  /// Every gate is re-checked here rather than trusted from the UI, because the
  /// button's state could be a frame stale — an administrator may have
  /// deactivated the account between the tap and this call.
  ///
  /// [photoPath] is the evidence file, if one was captured. A missing or failed
  /// upload does not fail the punch: `firestore.rules` does not require a photo,
  /// and discarding a legitimate attendance record over an attachment is worse
  /// than recording it without evidence.
  Future<PunchOutcome> punchIn({
    String? photoPath,
    bool? livenessVerified,
  }) async {
    final profile = _user;
    if (profile == null) {
      return PunchOutcome.failure(AppError.profileMissing.message);
    }
    if (!profile.isActive) {
      return PunchOutcome.failure(AppError.accountInactive.message);
    }
    if (!await _auth.hasNetwork()) {
      return PunchOutcome.failure(AppError.networkUnavailable.message);
    }

    // Cek manipulasi jam perangkat — sync waktu server jika belum
    if (!ServerTimeService.instance.hasSynced) {
      await ServerTimeService.instance.sync();
    }
    if (ServerTimeService.instance.isSuspicious) {
      return PunchOutcome.failure(
        ServerTimeService.instance.warningMessage ??
            'Jam perangkat tidak sesuai waktu server. Aktifkan waktu otomatis.',
      );
    }

    // Device integrity is checked *before* the geofence, because a compromised
    // device can report any position at all — validating the location first
    // would spend the employee's twenty seconds waiting for GPS only to have the
    // punch refused afterwards on a check that needed no signal.
    final integrity = await _assessIntegrity();
    if (integrity.hasBlocking) {
      return PunchOutcome.failure(integrity.blocking.first.message);
    }

    final shiftEvaluation = evaluateCheckIn();
    if (!shiftEvaluation.allowed) {
      return PunchOutcome.failure(shiftEvaluation.message);
    }

    final fix = await acquireFix(force: true);
    final geofenceEvaluation = _evaluateGeofence(override: fix);
    if (!geofenceEvaluation.allowed) {
      return PunchOutcome.failure(geofenceEvaluation.message);
    }

    final targetZone = zone!;
    final distance = geofenceEvaluation.distanceMeters ?? 0;
    final now = DateTime.now();

    // Evidence upload failure sets `warning` instead of failing the punch:
    // `firestore.rules` does not require a photo, so discarding a legitimate
    // attendance record over an attachment would be the worse outcome.
    String? warning;
    final photoUrl = await _uploadEvidence(
      photoPath: photoPath,
      folder: 'sae/absensi',
      onWarning: (message) => warning = message,
    );

    // Integrity codes and the liveness verdict travel alongside the punch. Built
    // imperatively rather than with a conditional map entry, which this language
    // version has no null-aware syntax for.
    final extraFields = <String, dynamic>{
      ...PunchCrypto.describeIntegrity(integrity),
    };
    // Tri-state: written explicitly so the dashboard can tell a punch that
    // passed liveness from one taken before the check existed.
    if (livenessVerified != null) {
      extraFields['livenessVerified'] = livenessVerified;
    }

    try {
      final record = await _attendance.checkIn(
        user: profile,
        status: shiftEvaluation.status,
        zone: targetZone,
        fix: fix!,
        distanceMeters: distance,
        photoUrl: photoUrl,
        address: CloudinaryService.describeEvidenceLocation(
          zoneName: targetZone.name,
          address: targetZone.address,
        ),
        deviceId: _deviceId,
        now: now,
        sealingKey: sealingKey,
        shiftName: shift?.name,
        extraFields: extraFields,
      );

      _today = record;
      unawaited(
        UserService.logPunch(
          firestore: _attendance.firestore,
          actor: profile,
          isCheckIn: true,
          recordDate: record.recordDate,
          status: record.status,
          zone: targetZone,
          fix: fix,
          distanceMeters: distance,
          now: now,
        ),
      );

      await refreshHistory();
      notifyListeners();

      return PunchOutcome.success(
        record: record,
        message: shiftEvaluation.message,
        warning: warning,
      );
    } on AppFailure catch (failure) {
      return PunchOutcome.failure(failure.message);
    }
  }

  /// Writes a check-out onto the open record.
  Future<PunchOutcome> punchOut({
    String? photoPath,
    bool? livenessVerified,
  }) async {
    final profile = _user;
    if (profile == null) {
      return PunchOutcome.failure(AppError.profileMissing.message);
    }
    if (!await _auth.hasNetwork()) {
      return PunchOutcome.failure(AppError.networkUnavailable.message);
    }

    final integrity = await _assessIntegrity();
    if (integrity.hasBlocking) {
      return PunchOutcome.failure(integrity.blocking.first.message);
    }

    // Located before the window check, because the window test needs no network
    // while the geofence test needs a fix — and an employee who cannot punch out
    // should learn which of the two stopped them.
    AttendanceDoc? openRecord;
    try {
      openRecord = _today?.isOpen == true ? _today : await _attendance.findOpenRecord(profile.uid);
    } on AppFailure catch (failure) {
      return PunchOutcome.failure(failure.message);
    }

    final shiftEvaluation = evaluateCheckOut(openRecord: openRecord);
    if (!shiftEvaluation.allowed) {
      return PunchOutcome.failure(shiftEvaluation.message);
    }

    final fix = await acquireFix(force: true);
    final geofenceEvaluation = _evaluateGeofence(override: fix);
    if (!geofenceEvaluation.allowed) {
      return PunchOutcome.failure(geofenceEvaluation.message);
    }

    final targetZone = zone!;
    final distance = geofenceEvaluation.distanceMeters ?? 0;
    final now = DateTime.now();

    String? warning;
    final photoUrl = await _uploadEvidence(
      photoPath: photoPath,
      folder: 'sae/absensi',
      onWarning: (message) => warning = message,
    );

    try {
      final record = await _attendance.checkOut(
        user: profile,
        record: openRecord!,
        status: shiftEvaluation.status,
        zone: targetZone,
        fix: fix!,
        distanceMeters: distance,
        photoUrl: photoUrl,
        address: CloudinaryService.describeEvidenceLocation(
          zoneName: targetZone.name,
          address: targetZone.address,
        ),
        deviceId: _deviceId,
        now: now,
      );

      _today = record;
      // Integrity and liveness are recorded on the check-in only: the rules pin
      // the check-out key set exactly, so writing them here would be refused.
      unawaited(
        UserService.logPunch(
          firestore: _attendance.firestore,
          actor: profile,
          isCheckIn: false,
          recordDate: record.recordDate,
          status: record.status,
          zone: targetZone,
          fix: fix,
          distanceMeters: distance,
          now: now,
        ),
      );

      await refreshHistory();
      notifyListeners();

      return PunchOutcome.success(
        record: record,
        message: shiftEvaluation.message,
        warning: warning,
      );
    } on AppFailure catch (failure) {
      return PunchOutcome.failure(failure.message);
    }
  }

  /// Uploads evidence, returning the URL or `null`.
  ///
  /// Never throws. [onWarning] receives the reason a punch has no photo, so the
  /// UI can tell the employee rather than leaving a silent gap in the audit
  /// trail.
  Future<String?> _uploadEvidence({
    required String? photoPath,
    required String folder,
    required void Function(String message) onWarning,
  }) async {
    if (photoPath == null || photoPath.isEmpty) {
      onWarning('Absen dicatat tanpa bukti foto.');
      return null;
    }
    if (!_cloudinary.isConfigured) {
      onWarning(_cloudinary.configurationHint);
      return null;
    }

    try {
      final result = await _cloudinary.uploadFile(File(photoPath), folder: folder);
      if (result.isSuccess) return result.url;
      onWarning(result.error ?? 'Bukti foto gagal diunggah.');
      return null;
    } catch (_) {
      onWarning('Bukti foto gagal diunggah.');
      return null;
    }
  }

  // ─── Permissions actions ───────────────────────────────────────────────────

  Future<String?> submitPermission({
    required PermissionTypeDoc? type,
    required String startDate,
    required String endDate,
    required String reason,
    String? attachmentUrl,
  }) async {
    final profile = _user;
    if (profile == null) return AppError.profileMissing.message;

    final validation = const PermissionValidator().validate(
      type: type,
      startDate: startDate,
      endDate: endDate,
      reason: reason,
      attachmentUrl: attachmentUrl,
    );

    if (!validation.isValid) return validation.errorMessage;

    try {
      await _permissions.submit(user: profile, form: validation);
      await refreshPermissions();
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  /// Uploads a leave attachment.
  ///
  /// Separate from [submitPermission] so the form can upload first and only file
  /// the request once its evidence is durably stored — the reverse order would
  /// leave an approver looking at a request whose attachment silently failed.
  Future<({String? url, String? error})> uploadLeaveAttachment(String path) async {
    if (!_cloudinary.isConfigured) {
      return (url: null, error: _cloudinary.configurationHint);
    }

    try {
      final result = await _cloudinary.uploadFile(File(path), folder: 'sae/izin');
      if (result.isSuccess) return (url: result.url, error: null);
      return (url: null, error: result.error ?? 'Lampiran gagal diunggah.');
    } catch (_) {
      return (url: null, error: 'Lampiran gagal diunggah.');
    }
  }

  /// Withdraws a pending request.
  Future<String?> cancelPermission(PermissionDoc request) async {
    try {
      await _permissions.cancel(permissionId: request.id, request: request);
      await refreshPermissions();
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  /// Approves a request. Administrator only.
  Future<String?> approvePermission(PermissionDoc request) async {
    final profile = _user;
    if (profile == null || !profile.isAdmin) return AppError.permissionDenied.message;

    try {
      await _permissions.approve(permissionId: request.id, reviewer: profile);
      await refreshPermissions();
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  /// Rejects a request. Administrator only.
  Future<String?> rejectPermission(PermissionDoc request, String reason) async {
    final profile = _user;
    if (profile == null || !profile.isAdmin) return AppError.permissionDenied.message;

    try {
      await _permissions.reject(
        permissionId: request.id,
        reviewer: profile,
        reason: reason,
      );
      await refreshPermissions();
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  // ─── Profile ───────────────────────────────────────────────────────────────

  /// Uploads a new profile photo.
  Future<String?> updateProfilePhoto(String photoPath) async {
    final profile = _user;
    if (profile == null) return AppError.profileMissing.message;
    if (!_cloudinary.isConfigured) return _cloudinary.configurationHint;

    try {
      final result = await _cloudinary.uploadFile(File(photoPath), folder: 'sae/profil');
      if (!result.isSuccess) return result.error ?? 'Bukti foto gagal diunggah.';

      await _users.updatePhotoUrl(profile.uid, result.url!);
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      await _auth.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  Future<String?> signIn({required String email, required String password}) async {
    try {
      await _auth.signIn(email: email, password: password);
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  Future<String?> requestPasswordReset(String email) async {
    try {
      await _auth.requestPasswordReset(email);
      return null;
    } on AppFailure catch (failure) {
      return failure.message;
    }
  }

  Future<void> signOut() async {
    // Batalkan semua reminder dan hapus FCM token sebelum logout
    final currentUid = uid;
    if (currentUid != null) {
      unawaited(NotificationService.instance.unregisterToken(currentUid));
    }
    unawaited(NotificationService.instance.cancelAll());
    await _teardownSession();
    await _auth.signOut();
    _stage = AppStage.signedOut;
    notifyListeners();
  }

  /// Re-checks a token after the app returns to the foreground.
  ///
  /// A token that will not refresh means the account was disabled or revoked
  /// server-side. Continuing to show a signed-in UI would be a lie, so the app
  /// returns to the login screen.
  Future<bool> revalidateSession() async {
    if (_auth.currentUser == null) return false;

    try {
      await _auth.refreshSession();
      return true;
    } on AppFailure {
      await signOut();
      return false;
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _profileSubscription?.cancel();
    _todaySubscription?.cancel();
    _fixSubscription?.cancel();
    super.dispose();
  }
}

/// The result of a punch attempt.
class PunchOutcome {
  const PunchOutcome._({
    required this.success,
    required this.message,
    this.record,
    this.warning,
  });

  const PunchOutcome.success({
    required AttendanceDoc record,
    required String message,
    String? warning,
  }) : this._(
          success: true,
          record: record,
          message: message,
          warning: warning,
        );

  const PunchOutcome.failure(String message)
      : this._(success: false, message: message);

  final bool success;

  /// Indonesian copy describing what happened.
  final String message;

  /// The stored record, on success.
  final AttendanceDoc? record;

  /// Set when the punch succeeded but something was incomplete — currently only
  /// a missing photo, which the employee should know about because the audit
  /// trail will show the gap.
  final String? warning;

  bool get hasWarning => warning != null && warning!.isNotEmpty;
}

/// Formats a work duration for display, re-exported for the history screen.
String? formatDuration(String? checkIn, String? checkOut) =>
    formatWorkDuration(checkIn, checkOut);