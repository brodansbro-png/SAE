import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../data/location_service.dart';
import '../../domain/logic/geo.dart';
import '../../domain/logic/shift_rules.dart';
import '../../domain/logic/time_keys.dart';
import '../../domain/models/attendance.dart';
import '../../domain/services/settings_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/face_capture_sheet.dart';
import '../widgets/greeting_animation.dart';
import '../widgets/zone_map.dart';

/// The core screen: check in, check out, and see why neither is possible.
///
/// The order of the screen is the order of the decision the employee is making:
/// where am I (map), what time is it and what does my shift say (header), what
/// does today look like (card), and only then the action.
class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> with WidgetsBindingObserver {
  File? _photo;
  bool _punching = false;

  /// Whether the captured photo passed the liveness challenge.
  ///
  /// Recorded onto the punch so the dashboard can tell a verified capture from
  /// one taken before liveness existed. Reset with the photo, because a verdict
  /// must not be reused for a different picture.
  bool? _livenessVerified;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Started after the first frame so `context.read` is safe and the map does
    // not compete with the initial build for the frame budget.
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginLocation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground can change the answer: the employee may have
    // walked into the zone, or granted location permission from Settings.
    if (state == AppLifecycleState.resumed) {
      _beginLocation();
    }
  }

  Future<void> _beginLocation() async {
    if (!mounted) return;
    final appState = context.read<AppState>();
    await appState.startLocation();
  }

  Future<void> _capturePhoto() async {
    // The liveness sheet, not the bare OS picker. A gallery pick would let an
    // employee attach a photograph taken last week, and a direct camera shot
    // would accept a printed photo held up to the lens — the challenge is what
    // makes the evidence worth storing.
    final evidence = await captureWithLiveness(context);
    if (evidence == null || !mounted) return;

    setState(() {
      _photo = File(evidence.path);
      _livenessVerified = true;
    });
  }

  Future<void> _punch({required bool isCheckIn}) async {
    if (_punching) return;

    setState(() => _punching = true);

    final state = context.read<AppState>();
    final outcome = isCheckIn
        ? await state.punchIn(
            photoPath: _photo?.path,
            livenessVerified: _livenessVerified,
          )
        : await state.punchOut(
            photoPath: _photo?.path,
            livenessVerified: _livenessVerified,
          );

    if (!mounted) return;

    setState(() {
      _punching = false;
      // The photo is consumed by the punch; keeping it would let the same
      // evidence be attached to the check-out as well.
      if (outcome.success) {
        _photo = null;
        _livenessVerified = null;
      }
    });

    if (outcome.success) {
      showAppSnackBar(
        context,
        outcome.message.isEmpty ? 'Absen berhasil dicatat.' : outcome.message,
      );
      if (outcome.hasWarning) {
        // Reported separately so a punch with no evidence is still visibly
        // acknowledged — the audit trail will show the gap.
        showAppSnackBar(context, outcome.warning!, isError: true);
      }
    } else {
      showAppSnackBar(context, outcome.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final padding = SaeTheme.pagePadding(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Absensi'),
        actions: [
          IconButton(
            onPressed: state.isLocating
                ? null
                : () async {
                    await state.acquireFix(force: true);
                    if (!context.mounted) return;
                    showAppSnackBar(context, 'Lokasi diperbarui.');
                  },
            icon: state.isLocating
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
            tooltip: 'Perbarui lokasi',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          // Captured before the first await so no `BuildContext` is read across
          // the async gap.
          final appState = context.read<AppState>();
          await appState.startLocation();
          await appState.refreshHistory();
        },
        child: ListView(
          padding: padding,
          children: [
            const _GreetingRow(),
            const SizedBox(height: 14),
            _ShiftHeader(state: state),
            const SizedBox(height: 14),
            _LocationCard(state: state),
            const SizedBox(height: 14),
            _TodayCard(state: state),
            const SizedBox(height: 14),
            _PhotoPicker(
              photo: _photo,
              enabled: !_punching,
              onCapture: _capturePhoto,
              onClear: () => setState(() {
              _photo = null;
              _livenessVerified = null;
            }),
              verified: _livenessVerified,
            ),
            const SizedBox(height: 16),
            _PunchActions(
              state: state,
              busy: _punching,
              hasPhoto: _photo != null,
              onPunchIn: () => _punch(isCheckIn: true),
              onPunchOut: () => _punch(isCheckIn: false),
            ),
            const SizedBox(height: 14),
            _LeaveBanner(state: state),
            const SizedBox(height: 14),
            _MonthSummary(state: state),
            const SizedBox(height: 24),
            Center(
              child: Text(
                'Versi aplikasi ${state.appVersion.isEmpty ? '—' : state.appVersion}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The time-of-day greeting with its Lottie animation.
class _GreetingRow extends StatelessWidget {
  const _GreetingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 4, bottom: 2),
      child: GreetingAnimation(size: 56),
    );
  }
}

/// Shift, working days and the punch windows.
class _ShiftHeader extends StatelessWidget {
  const _ShiftHeader({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shift = state.shift;

    if (shift == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: SaeTheme.warning),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Shift kerja belum ditentukan. Hubungi administrator.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final days = shift.daysOfWeek.isEmpty
        ? 'Tanpa hari kerja'
        : shift.daysOfWeek
            .map((day) => indonesianWeekdayNames[(day - 1).clamp(0, 6)].substring(0, 3))
            .join(', ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.work_outline, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    shift.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  shift.windowLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              days,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              describeShiftWindows(shift),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The map, the live readout, and the permission remedies.
class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = state.locationFailure;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: SettingsService.describeZone(state.zone),
              icon: Icons.location_on_outlined,
              action: state.isLocating
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            ZoneMap(
              zone: state.zone,
              fix: state.fix,
              height: 240,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  state.isInsideZone ? Icons.check_circle : Icons.error_outline,
                  size: 16,
                  color: state.isInsideZone ? SaeTheme.success : SaeTheme.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    describeDistance(
                      distance: state.liveDistance,
                      radiusMeters: state.zone?.radiusMeters ?? 0,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: state.isInsideZone ? SaeTheme.success : SaeTheme.warning,
                    ),
                  ),
                ),
              ],
            ),
            if (failure != null) ...[
              const SizedBox(height: 10),
              _LocationFailureNotice(failure: failure, state: state),
            ],
          ],
        ),
      ),
    );
  }
}

/// A location problem, with the action that fixes it.
class _LocationFailureNotice extends StatelessWidget {
  const _LocationFailureNotice({required this.failure, required this.state});

  final LocationFailure failure;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The remedy differs per reason: a disabled toggle and a permanently
    // denied permission both need a trip to Settings, while a weak signal only
    // needs patience.
    final needsSettings = !failure.isRetryable;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.location_disabled, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  failure.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (needsSettings)
                FilledButton.tonal(
                  onPressed: () => state.openLocationSettings(),
                  child: const Text('Buka pengaturan'),
                )
              else
                FilledButton.tonal(
                  onPressed: () => state.acquireFix(force: true),
                  child: const Text('Coba lagi'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Today's punches, with the evidence and geofence measurements.
class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = state.todayRecord;
    final shiftEvaluation = state.evaluateCheckIn();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: formatDisplayDateWithWeekday(todayIso()),
              icon: Icons.today_outlined,
            ),
            if (record == null) ...[
              Row(
                children: [
                  StatusBadge(
                    label: AttendanceStatus.pending == 'PENDING'
                        ? 'Belum absen'
                        : 'Belum absen',
                    color: theme.colorScheme.outline,
                    icon: Icons.schedule,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                shiftEvaluation.allowed
                    ? 'Anda dapat melakukan absen datang.'
                    : shiftEvaluation.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: shiftEvaluation.allowed
                      ? theme.colorScheme.onSurface
                      : SaeTheme.warning,
                ),
              ),
            ] else ...[
              Row(
                children: [
                  StatusBadge(
                    label: record.statusLabel,
                    color: SaeTheme.statusColor(context, record.status),
                    icon: _iconForStatus(record.status),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _PunchRow(
                label: 'Absen datang',
                time: formatClockTime(record.checkInTime),
                photoUrl: record.checkInPhotoUrl,
                distance: record.checkInDistanceMeters,
                radius: record.checkInZoneRadiusMeters,
                accuracy: record.checkInAccuracyMeters,
                address: record.checkInAddress,
              ),
              if (record.hasCheckOut) ...[
                const Divider(height: 24),
                _PunchRow(
                  label: 'Absen pulang',
                  time: formatClockTime(record.checkOutTime),
                  photoUrl: record.checkOutPhotoUrl,
                  distance: record.checkOutDistanceMeters,
                  radius: record.checkOutZoneRadiusMeters,
                  accuracy: record.checkOutAccuracyMeters,
                  address: record.checkOutAddress,
                ),
                if (formatWorkDuration(record.checkInTime, record.checkOutTime)
                    case final duration?) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.timelapse,
                          size: 16, color: theme.colorScheme.outline),
                      const SizedBox(width: 6),
                      Text(
                        'Durasi kerja: $duration',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// One punch: its time, its evidence, and the geofence numbers it recorded.
class _PunchRow extends StatelessWidget {
  const _PunchRow({
    required this.label,
    required this.time,
    this.photoUrl,
    this.distance,
    this.radius,
    this.accuracy,
    this.address,
  });

  final String label;
  final String time;
  final String? photoUrl;
  final double? distance;
  final double? radius;
  final double? accuracy;
  final String? address;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.check_circle_outline, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    time,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (address != null)
                Text(
                  address!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              // The measured distance against the radius it was compared with,
              // which is what makes a disputed punch auditable rather than
              // merely arguable.
              if (distance != null)
                Text(
                  'Jarak ${formatDistance(distance)}'
                  '${radius != null ? ' / radius ${formatDistance(radius)}' : ''}'
                  '${accuracy != null ? ' · akurasi ±${accuracy!.round()} m' : ''}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
        if (photoUrl != null) ...[
          const SizedBox(width: 8),
          _EvidenceThumbnail(url: photoUrl!),
        ],
      ],
    );
  }
}

/// The evidence photo, tappable to view full size.
class _EvidenceThumbnail extends StatelessWidget {
  const _EvidenceThumbnail({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openFullSize(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          // A failed thumbnail must not take the whole card down: the punch is
          // still valid evidence on its own, and the URL is still on record.
          errorBuilder: (_, _, _) => Container(
            width: 52,
            height: 52,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.broken_image_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : Container(
                  width: 52,
                  height: 52,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
        ),
      ),
    );
  }

  void _openFullSize(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Bukti foto')),
          backgroundColor: Colors.black,
          body: Center(
            child: InteractiveViewer(
              maxScale: 4,
              child: Image.network(
                url,
                errorBuilder: (_, _, _) => const Text(
                  'Foto tidak dapat dimuat.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The evidence capture control.
///
/// Foto wajah adalah WAJIB — tombol absen tidak aktif sampai foto diambil
/// dan wajah terdeteksi. Ini mencegah absen tanpa kehadiran fisik.
class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.photo,
    required this.enabled,
    required this.onCapture,
    required this.onClear,
    this.verified,
  });

  final File? photo;
  final bool enabled;
  final VoidCallback onCapture;
  final VoidCallback onClear;

  /// Whether the captured photo passed the liveness challenge.
  final bool? verified;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (photo != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.photo_camera, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Foto wajah siap',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: enabled ? onClear : null,
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Ulangi'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  photo!,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 8),
              // Status verifikasi wajah
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: SaeTheme.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: SaeTheme.success.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.verified_user, size: 14, color: SaeTheme.success),
                    const SizedBox(width: 6),
                    Text(
                      'Wajah terdeteksi dan terverifikasi',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: SaeTheme.success,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Belum ada foto — tampilkan tombol wajib dengan penjelasan
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.face_retouching_natural,
                    size: 22, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Foto wajah diperlukan',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Kamera akan mendeteksi wajah Anda secara otomatis. '
              'Tombol absen akan aktif setelah foto diambil.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: enabled ? onCapture : null,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Buka Kamera & Ambil Foto'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The two punch buttons, each disabled with its reason shown.
///
/// Foto wajah adalah WAJIB — kedua tombol tidak aktif sampai foto diambil.
class _PunchActions extends StatelessWidget {
  const _PunchActions({
    required this.state,
    required this.busy,
    required this.onPunchIn,
    required this.onPunchOut,
    required this.hasPhoto,
  });

  final AppState state;
  final bool busy;
  final bool hasPhoto;
  final VoidCallback onPunchIn;
  final VoidCallback onPunchOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final checkIn = state.evaluateCheckIn();
    final hasOpenCheckIn = state.todayRecord?.isOpen == true;
    final checkOut = state.evaluateCheckOut();

    final canCheckIn = state.canPunch && checkIn.allowed && hasPhoto && !busy;
    final canCheckOut = state.canPunch && checkOut.allowed && hasOpenCheckIn && hasPhoto && !busy;

    // Pesan status yang paling relevan untuk ditampilkan
    final String statusMessage;
    if (!state.canPunch) {
      statusMessage = 'Absen sedang tidak tersedia.';
    } else if (!hasPhoto) {
      statusMessage = 'Ambil foto wajah terlebih dahulu untuk absen.';
    } else if (!hasOpenCheckIn) {
      statusMessage = checkIn.message;
    } else {
      statusMessage = checkOut.message;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: canCheckIn ? onPunchIn : null,
          icon: busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: Text(hasOpenCheckIn ? 'Sudah absen datang' : 'Absen Datang'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: theme.colorScheme.primary,
            disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: canCheckOut ? onPunchOut : null,
          icon: const Icon(Icons.logout),
          label: const Text('Absen Pulang'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: theme.colorScheme.tertiary,
            disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 10),
        // Penjelasan mengapa tombol nonaktif
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              !hasPhoto
                  ? Icons.camera_alt_outlined
                  : (canCheckIn || canCheckOut)
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
              size: 14,
              color: (!hasPhoto || (!canCheckIn && !canCheckOut))
                  ? SaeTheme.warning
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                statusMessage,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: (!hasPhoto || (!canCheckIn && !canCheckOut))
                      ? SaeTheme.warning
                      : theme.colorScheme.outline,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A banner when an approved leave covers today.
class _LeaveBanner extends StatelessWidget {
  const _LeaveBanner({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = state.approvedLeaveToday;
    if (request == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.tertiary.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.beach_access, size: 20, color: theme.colorScheme.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Anda sedang cuti: ${request.permissionTypeName}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${formatDisplayDate(request.startDate)} – '
                  '${formatDisplayDate(request.endDate)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// This month's totals, computed from the already-fetched history.
class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = state.monthSummary;
    if (summary == null) return const SizedBox.shrink();

    final [year, month] = state.summaryMonth.split('-');
    final monthName = indonesianMonthNames[(int.tryParse(month) ?? 1) - 1];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Rekap bulan $monthName $year',
              icon: Icons.calendar_month_outlined,
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.7,
              children: [
                StatTile(
                  label: 'Kehadiran',
                  value: formatNumber(summary.present),
                  color: SaeTheme.success,
                  icon: Icons.check_circle_outline,
                ),
                StatTile(
                  label: 'Terlambat',
                  value: formatNumber(summary.late),
                  color: SaeTheme.warning,
                  icon: Icons.schedule,
                ),
                StatTile(
                  label: 'Pulang awal',
                  value: formatNumber(summary.earlyLeave),
                  color: SaeTheme.warning,
                  icon: Icons.exit_to_app,
                ),
                StatTile(
                  label: 'Belum pulang',
                  value: formatNumber(summary.incomplete),
                  color: theme.colorScheme.outline,
                  icon: Icons.pending_outlined,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.trending_up, size: 16, color: theme.colorScheme.outline),
                const SizedBox(width: 6),
                Text(
                  'Tingkat kehadiran ${summary.attendanceRate}% '
                  'dari ${formatNumber(summary.totalRecords)} hari tercatat',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _iconForStatus(String status) {
  switch (status) {
    case AttendanceStatus.completed:
      return Icons.check_circle;
    case AttendanceStatus.late:
      return Icons.schedule;
    case AttendanceStatus.earlyLeave:
      return Icons.exit_to_app;
    case AttendanceStatus.onLeave:
      return Icons.beach_access;
    case AttendanceStatus.checkedIn:
      return Icons.login;
    default:
      return Icons.help_outline;
  }
}