import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../domain/logic/geo.dart';
// `Zone` is declared here, not in the model layer: the geofence centre and
// radius a punch is judged against are policy, so the rule and its value object
// travel together. Without this import `_CoordModal.zone` and `_PointMap.zone`
// do not resolve and `flutter analyze` fails, which fails the CI build.
import '../../domain/logic/geofence_rules.dart';
import '../../domain/logic/time_keys.dart';
import '../../domain/models/attendance.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Riwayat presensi — 2 tab:
///   • Hari Ini  : rekap presensi hari berjalan (datang, pulang, durasi)
///   • Log       : daftar per rentang tanggal dengan kalender range picker,
///                 tanpa foto, koordinat bisa dipencet → modal titik di peta
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;

  void _clearRange() => setState(() {
        _rangeStart = null;
        _rangeEnd = null;
      });

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Riwayat Presensi'),
        actions: [
          IconButton(
            onPressed: state.isLoadingHistory
                ? null
                : () => context.read<AppState>().refreshHistory(),
            icon: state.isLoadingHistory
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Muat ulang',
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.today_outlined), text: 'Hari Ini'),
            Tab(
                icon: Icon(Icons.calendar_month_outlined),
                text: 'Log Presensi'),
          ],
          labelStyle: theme.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _TodayTab(state: state),
          _LogTab(
            state: state,
            rangeStart: _rangeStart,
            rangeEnd: _rangeEnd,
            onRangePicked: (start, end) =>
                setState(() {
                  _rangeStart = start;
                  _rangeEnd = end;
                }),
            onRangeCleared: _clearRange,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 1 — Hari Ini
// ═══════════════════════════════════════════════════════════════════════════════

class _TodayTab extends StatelessWidget {
  const _TodayTab({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = state.todayRecord;

    if (record == null) {
      return const EmptyState(
        icon: Icons.event_available_outlined,
        title: 'Belum ada presensi hari ini',
        message: 'Lakukan absen datang terlebih dahulu di menu Absensi.',
      );
    }

    return ListView(
      padding: SaeTheme.pagePadding(context),
      children: [
        // ── Header tanggal + status ─────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.today, color: theme.colorScheme.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatDisplayDateWithWeekday(record.recordDate),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (record.shiftName != null)
                      Text(
                        'Shift: ${record.shiftName}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                  ],
                ),
              ),
              StatusBadge(
                label: record.statusLabel,
                color: SaeTheme.statusColor(context, record.status),
                icon: _iconForStatus(record.status),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ── Absen datang ────────────────────────────────────────────────
        if (record.hasCheckIn) ...[
          _PunchDetailCard(
            title: 'Absen Datang',
            icon: Icons.login,
            iconColor: SaeTheme.success,
            time: record.checkInTime ?? '-',
            lat: record.checkInLat,
            lng: record.checkInLng,
            distanceMeters: record.checkInDistanceMeters,
            radiusMeters: record.checkInZoneRadiusMeters,
            accuracyMeters: record.checkInAccuracyMeters,
            address: record.checkInAddress,
            zoneId: record.zoneId,
            state: state,
          ),
          const SizedBox(height: 12),
        ],

        // ── Absen pulang ────────────────────────────────────────────────
        if (record.hasCheckOut) ...[
          _PunchDetailCard(
            title: 'Absen Pulang',
            icon: Icons.logout,
            iconColor: theme.colorScheme.tertiary,
            time: record.checkOutTime ?? '-',
            lat: record.checkOutLat,
            lng: record.checkOutLng,
            distanceMeters: record.checkOutDistanceMeters,
            radiusMeters: record.checkOutZoneRadiusMeters,
            accuracyMeters: record.checkOutAccuracyMeters,
            address: record.checkOutAddress,
            zoneId: record.zoneId,
            state: state,
          ),
          const SizedBox(height: 12),
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.pending_outlined,
                      size: 20, color: theme.colorScheme.outline),
                  const SizedBox(width: 12),
                  Text(
                    'Belum absen pulang',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // ── Durasi kerja ────────────────────────────────────────────────
        if (record.isCompleted)
          if (formatWorkDuration(record.checkInTime, record.checkOutTime)
              case final dur?) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.timelapse_outlined,
                      size: 18, color: theme.colorScheme.outline),
                  const SizedBox(width: 10),
                  Text('Durasi kerja: $dur',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        const SizedBox(height: 24),
      ],
    );
  }
}

// ── Kartu detail satu punch: jam + jarak + tombol koordinat map ───────────────

class _PunchDetailCard extends StatelessWidget {
  const _PunchDetailCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.time,
    required this.state,
    this.lat,
    this.lng,
    this.distanceMeters,
    this.radiusMeters,
    this.accuracyMeters,
    this.address,
    this.zoneId,
  });

  final String title;
  final IconData icon;
  final Color iconColor;
  final String time;
  final double? lat;
  final double? lng;
  final double? distanceMeters;
  final double? radiusMeters;
  final double? accuracyMeters;
  final String? address;
  final String? zoneId;
  final AppState state;

  bool get _hasCoords => lat != null && lng != null;
  bool get _insideZone =>
      distanceMeters != null &&
      radiusMeters != null &&
      distanceMeters! <= radiusMeters!;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    time,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: iconColor,
                    ),
                  ),
                ),
              ],
            ),
            if (address != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.location_on_outlined,
                      size: 14, color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(address!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ),
                ],
              ),
            ],
            if (distanceMeters != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _insideZone
                        ? Icons.check_circle_outline
                        : Icons.warning_amber_rounded,
                    size: 14,
                    color: _insideZone ? SaeTheme.success : SaeTheme.warning,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${formatDistance(distanceMeters)} dari pusat'
                      '${radiusMeters != null ? ' · radius ${formatDistance(radiusMeters)}' : ''}'
                      '${accuracyMeters != null ? ' · akurasi ±${accuracyMeters!.round()} m' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _insideZone
                            ? SaeTheme.success
                            : SaeTheme.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            // Tombol koordinat → buka modal peta
            if (_hasCoords) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _openModal(context),
                icon: const Icon(Icons.map_outlined, size: 16),
                label: Text(
                  '${formatCoordinate(lat)}, ${formatCoordinate(lng)}',
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  visualDensity: VisualDensity.compact,
                  foregroundColor:
                      _insideZone ? SaeTheme.success : SaeTheme.warning,
                  side: BorderSide(
                    color: _insideZone
                        ? SaeTheme.success.withValues(alpha: 0.5)
                        : SaeTheme.warning.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openModal(BuildContext context) {
    final zone =
        state.zones.where((z) => z.id == zoneId).firstOrNull ?? state.zone;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CoordModal(
        punchTitle: title,
        punchTime: time,
        lat: lat!,
        lng: lng!,
        distanceMeters: distanceMeters,
        radiusMeters: radiusMeters ?? zone?.radiusMeters,
        insideZone: _insideZone,
        zone: zone,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 2 — Log Presensi
// ═══════════════════════════════════════════════════════════════════════════════

class _LogTab extends StatelessWidget {
  const _LogTab({
    required this.state,
    required this.rangeStart,
    required this.rangeEnd,
    required this.onRangePicked,
    required this.onRangeCleared,
  });

  final AppState state;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;
  final void Function(DateTime, DateTime) onRangePicked;
  final VoidCallback onRangeCleared;

  List<AttendanceDoc> _filtered() {
    if (rangeStart == null && rangeEnd == null) return state.history;
    return state.history.where((r) {
      final date = DateTime.tryParse(r.recordDate);
      if (date == null) return false;
      final d = DateTime(date.year, date.month, date.day);
      if (rangeStart != null) {
        final s =
            DateTime(rangeStart!.year, rangeStart!.month, rangeStart!.day);
        if (d.isBefore(s)) return false;
      }
      if (rangeEnd != null) {
        final e = DateTime(rangeEnd!.year, rangeEnd!.month, rangeEnd!.day);
        if (d.isAfter(e)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final records = _filtered();

    return Column(
      children: [
        _RangeFilterBar(
          start: rangeStart,
          end: rangeEnd,
          onPick: onRangePicked,
          onClear: onRangeCleared,
          totalShown: records.length,
          totalAll: state.history.length,
        ),
        const Divider(height: 1),
        Expanded(
          child: state.isLoadingHistory && state.history.isEmpty
              ? const _LogSkeleton()
              : records.isEmpty
                  ? const EmptyState(
                      icon: Icons.event_busy_outlined,
                      title: 'Tidak ada data',
                      message: 'Tidak ada presensi pada rentang tanggal ini.',
                    )
                  : RefreshIndicator(
                      onRefresh: () =>
                          context.read<AppState>().refreshHistory(),
                      child: ListView.separated(
                        padding: SaeTheme.pagePadding(context),
                        itemCount: records.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) =>
                            _LogTile(record: records[i], state: state),
                      ),
                    ),
        ),
      ],
    );
  }
}

// ── Bar filter rentang tanggal ────────────────────────────────────────────────

class _RangeFilterBar extends StatelessWidget {
  const _RangeFilterBar({
    required this.start,
    required this.end,
    required this.onPick,
    required this.onClear,
    required this.totalShown,
    required this.totalAll,
  });

  final DateTime? start;
  final DateTime? end;
  final void Function(DateTime, DateTime) onPick;
  final VoidCallback onClear;
  final int totalShown;
  final int totalAll;

  bool get _hasFilter => start != null || end != null;

  String _fmt(DateTime? date) =>
      date == null ? '-' : formatDisplayDate(toIsoDate(date));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: theme.colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _pickRange(context),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _hasFilter
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  color: _hasFilter
                      ? theme.colorScheme.primary.withValues(alpha: 0.07)
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 16,
                      color: _hasFilter
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _hasFilter
                            ? '${_fmt(start)} – ${_fmt(end)}'
                            : 'Pilih rentang tanggal',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _hasFilter
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                          fontWeight: _hasFilter
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_hasFilter) ...[
            const SizedBox(width: 8),
            IconButton(
              onPressed: onClear,
              icon: const Icon(Icons.close),
              tooltip: 'Hapus filter',
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(width: 6),
          Text(
            '$totalShown / $totalAll',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Future<void> _pickRange(BuildContext context) async {
    final now = DateTime.now();
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: start != null && end != null
          ? DateTimeRange(start: start!, end: end!)
          : null,
      helpText: 'Pilih rentang presensi',
      saveText: 'Terapkan',
    );
    if (result != null) {
      onPick(result.start, result.end);
    }
  }
}

// ── Satu baris log ────────────────────────────────────────────────────────────

class _LogTile extends StatelessWidget {
  const _LogTile({required this.record, required this.state});

  final AttendanceDoc record;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tanggal + status
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatDisplayDateWithWeekday(record.recordDate),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                StatusBadge(
                  label: record.statusLabel,
                  color: SaeTheme.statusColor(context, record.status),
                  icon: _iconForStatus(record.status),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Jam datang · Jam pulang · Durasi  (tiap satu bisa dipencet)
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _TimeCoordChip(
                  icon: Icons.login,
                  label: record.hasCheckIn ? (record.checkInTime ?? '-') : '-',
                  lat: record.checkInLat,
                  lng: record.checkInLng,
                  distanceMeters: record.checkInDistanceMeters,
                  radiusMeters: record.checkInZoneRadiusMeters,
                  accuracyMeters: record.checkInAccuracyMeters,
                  address: record.checkInAddress,
                  punchTitle: 'Absen Datang',
                  punchTime: record.checkInTime ?? '-',
                  state: state,
                  record: record,
                ),
                _TimeCoordChip(
                  icon: Icons.logout,
                  label:
                      record.hasCheckOut ? (record.checkOutTime ?? '-') : '-',
                  lat: record.checkOutLat,
                  lng: record.checkOutLng,
                  distanceMeters: record.checkOutDistanceMeters,
                  radiusMeters: record.checkOutZoneRadiusMeters,
                  accuracyMeters: record.checkOutAccuracyMeters,
                  address: record.checkOutAddress,
                  punchTitle: 'Absen Pulang',
                  punchTime: record.checkOutTime ?? '-',
                  state: state,
                  record: record,
                ),
                if (record.isCompleted)
                  if (formatWorkDuration(
                          record.checkInTime, record.checkOutTime)
                      case final dur?)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timelapse,
                            size: 13, color: theme.colorScheme.outline),
                        const SizedBox(width: 4),
                        Text(
                          dur,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Chip jam + ikon pin (tapable buka modal peta) ─────────────────────────────

class _TimeCoordChip extends StatelessWidget {
  const _TimeCoordChip({
    required this.icon,
    required this.label,
    required this.punchTitle,
    required this.punchTime,
    required this.state,
    required this.record,
    this.lat,
    this.lng,
    this.distanceMeters,
    this.radiusMeters,
    this.accuracyMeters,
    this.address,
  });

  final IconData icon;
  final String label;
  final double? lat;
  final double? lng;
  final double? distanceMeters;
  final double? radiusMeters;
  final double? accuracyMeters;
  final String? address;
  final String punchTitle;
  final String punchTime;
  final AppState state;
  final AttendanceDoc record;

  bool get _hasCoords => lat != null && lng != null;
  bool get _inside =>
      distanceMeters != null &&
      radiusMeters != null &&
      distanceMeters! <= radiusMeters!;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _hasCoords
        ? (_inside ? SaeTheme.success : SaeTheme.warning)
        : theme.colorScheme.outline;

    return GestureDetector(
      onTap: _hasCoords ? () => _openModal(context) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (_hasCoords) ...[
            const SizedBox(width: 3),
            Icon(Icons.room_outlined, size: 12, color: color),
          ],
        ],
      ),
    );
  }

  void _openModal(BuildContext context) {
    final zone = state.zones
            .where((z) => z.id == record.zoneId)
            .firstOrNull ??
        state.zone;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CoordModal(
        punchTitle: punchTitle,
        punchTime: punchTime,
        lat: lat!,
        lng: lng!,
        distanceMeters: distanceMeters,
        radiusMeters: radiusMeters ?? zone?.radiusMeters,
        insideZone: _inside,
        zone: zone,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Modal koordinat — titik absen di peta + keterangan radius
// ═══════════════════════════════════════════════════════════════════════════════

class _CoordModal extends StatelessWidget {
  const _CoordModal({
    required this.punchTitle,
    required this.punchTime,
    required this.lat,
    required this.lng,
    required this.insideZone,
    this.distanceMeters,
    this.radiusMeters,
    this.zone,
  });

  final String punchTitle;
  final String punchTime;
  final double lat;
  final double lng;
  final bool insideZone;
  final double? distanceMeters;
  final double? radiusMeters;
  final Zone? zone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = insideZone ? SaeTheme.success : SaeTheme.warning;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Row(
              children: [
                Icon(
                  insideZone ? Icons.check_circle : Icons.warning_amber,
                  color: statusColor,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        punchTitle,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Pukul $punchTime  ·  '
                        '${insideZone ? 'Di dalam radius' : 'Di luar radius'}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: statusColor),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Peta + detail
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              child: Column(
                children: [
                  _PointMap(
                    punchLat: lat,
                    punchLng: lng,
                    zone: zone,
                    insideZone: insideZone,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _InfoRow(
                          icon: Icons.gps_fixed,
                          label: 'Koordinat tercatat',
                          value:
                              '${formatCoordinate(lat)}, ${formatCoordinate(lng)}',
                          mono: true,
                        ),
                        if (distanceMeters != null) ...[
                          const SizedBox(height: 10),
                          _InfoRow(
                            icon: Icons.straighten,
                            label: 'Jarak dari pusat zona',
                            value: formatDistance(distanceMeters),
                            valueColor: statusColor,
                          ),
                        ],
                        if (radiusMeters != null) ...[
                          const SizedBox(height: 10),
                          _InfoRow(
                            icon: Icons.radio_button_checked,
                            label: 'Radius zona',
                            value: formatDistance(radiusMeters),
                          ),
                        ],
                        const SizedBox(height: 12),
                        // Status badge
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                insideZone
                                    ? Icons.check_circle_outline
                                    : Icons.cancel_outlined,
                                size: 18,
                                color: statusColor,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  insideZone
                                      ? 'Titik absen berada di dalam radius lokasi yang ditentukan'
                                      : 'Titik absen berada di luar radius lokasi — perlu verifikasi',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: statusColor,
                                    fontWeight: FontWeight.w600,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Peta dalam modal ──────────────────────────────────────────────────────────

class _PointMap extends StatelessWidget {
  const _PointMap({
    required this.punchLat,
    required this.punchLng,
    required this.insideZone,
    this.zone,
  });

  final double punchLat;
  final double punchLng;
  final bool insideZone;
  final Zone? zone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final punchPoint = LatLng(punchLat, punchLng);
    final markerColor = insideZone ? SaeTheme.success : SaeTheme.warning;
    final zoneCenter =
        zone != null ? LatLng(zone!.latitude, zone!.longitude) : null;

    final circle = zone != null
        ? circleVertices(
            centerLat: zone!.latitude,
            centerLng: zone!.longitude,
            radiusMeters: zone!.radiusMeters,
            vertexCount: 96,
          ).map((p) => LatLng(p[0], p[1])).toList()
        : <LatLng>[];

    final initialCenter = zoneCenter ?? punchPoint;
    final initialZoom = zone != null
        ? zoomForRadius(
            zone!.radiusMeters * 1.8,
            latitude: zone!.latitude,
            viewportWidthPx: MediaQuery.sizeOf(context).width,
            fillFraction: 0.7,
          ).toDouble()
        : 16.0;

    return SizedBox(
      height: 240,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: initialCenter,
          initialZoom: initialZoom,
        ),
        children: [
          TileLayer(
            urlTemplate:
                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.sae.presensi',
            maxZoom: 19,
          ),
          if (circle.isNotEmpty)
            PolygonLayer(
              polygons: [
                Polygon(
                  points: circle,
                  color: (insideZone
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error)
                      .withValues(alpha: 0.15),
                  borderColor: insideZone
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                  borderStrokeWidth: 2,
                ),
              ],
            ),
          // Garis putus-putus dari zona ke titik absen jika di luar
          if (zoneCenter != null && !insideZone)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: [zoneCenter, punchPoint],
                  color: theme.colorScheme.error.withValues(alpha: 0.6),
                  strokeWidth: 2,
                  pattern: const StrokePattern.dotted(),
                ),
              ],
            ),
          MarkerLayer(
            markers: [
              if (zoneCenter != null)
                Marker(
                  point: zoneCenter,
                  width: 28,
                  height: 28,
                  child: _MapPin(
                    color: theme.colorScheme.primary,
                    icon: Icons.home_work,
                  ),
                ),
              Marker(
                point: punchPoint,
                width: 28,
                height: 28,
                child: _MapPin(
                  color: markerColor,
                  icon: Icons.person_pin_circle,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, size: 14, color: Colors.white),
    );
  }
}

// ── Info row di modal ─────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.mono = false,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: theme.colorScheme.outline),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              Text(
                value,
                style: (mono
                        ? theme.textTheme.bodySmall
                            ?.copyWith(fontFamily: 'monospace')
                        : theme.textTheme.bodySmall)
                    ?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Skeleton loading ──────────────────────────────────────────────────────────

class _LogSkeleton extends StatelessWidget {
  const _LogSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: SaeTheme.pagePadding(context),
      itemCount: 6,
      itemBuilder: (_, _) => const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 16, width: 160),
                SizedBox(height: 10),
                Row(
                  children: [
                    SkeletonBox(height: 14, width: 70),
                    SizedBox(width: 16),
                    SkeletonBox(height: 14, width: 70),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Helper ────────────────────────────────────────────────────────────────────

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
