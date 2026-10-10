import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../domain/logic/time_keys.dart';
import '../../domain/models/permission.dart';
import '../../domain/services/permissions_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Halaman Izin — 2 tab:
///   • Ajukan Izin  : form pengajuan izin/cuti
///   • Riwayat Izin : daftar semua pengajuan milik pengguna ini
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Perizinan'),
        actions: [
          IconButton(
            onPressed: () => context.read<AppState>().refreshPermissions(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Muat ulang',
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline), text: 'Ajukan Izin'),
            Tab(icon: Icon(Icons.history_outlined), text: 'Riwayat Izin'),
          ],
          labelStyle: theme.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _AjukanTab(onSubmitted: () => _tabs.animateTo(1)),
          const _RiwayatTab(),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 0 — Ajukan Izin
// ═══════════════════════════════════════════════════════════════════════════════

/// Form pengajuan izin yang di-embed di dalam tab (bukan push route baru),
/// sehingga pengguna tidak perlu keluar dari halaman.
class _AjukanTab extends StatelessWidget {
  const _AjukanTab({required this.onSubmitted});
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.permissionTypes.isEmpty) {
      return const EmptyState(
        icon: Icons.category_outlined,
        title: 'Belum ada jenis izin',
        message:
            'Hubungi administrator untuk mengatur jenis izin yang tersedia.',
      );
    }

    return _LeaveForm(onSubmitted: onSubmitted);
  }
}

/// Form izin yang di-embed di dalam tab.
/// Submit langsung pindah ke tab Riwayat via [onSubmitted].
class _LeaveForm extends StatefulWidget {
  const _LeaveForm({required this.onSubmitted});
  final VoidCallback onSubmitted;

  @override
  State<_LeaveForm> createState() => _LeaveFormState();
}

class _LeaveFormState extends State<_LeaveForm> {
  PermissionTypeDoc? _type;
  DateTime? _start;
  DateTime? _end;
  String _reason = '';
  bool _submitting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    final validation = const PermissionValidator().validate(
      type: _type,
      startDate: _start == null ? '' : toIsoDate(_start!),
      endDate: _end == null ? '' : toIsoDate(_end!),
      reason: _reason,
      attachmentUrl: 'pending',
    );

    return ListView(
      padding: SaeTheme.pagePadding(context),
      children: [
        // ── Jenis izin ──────────────────────────────────────────────────
        const SectionHeader(title: 'Jenis Izin', icon: Icons.category_outlined),
        ...state.permissionTypes.map(
          (type) => _TypeOption(
            type: type,
            selected: _type?.id == type.id,
            onTap: type.isActive
                ? () => setState(() => _type = type)
                : null,
          ),
        ),

        const SizedBox(height: 20),

        // ── Rentang tanggal ─────────────────────────────────────────────
        const SectionHeader(
            title: 'Rentang Tanggal', icon: Icons.date_range_outlined),
        Row(
          children: [
            Expanded(
              child: _DateField(
                label: 'Mulai',
                value: _start,
                onPick: (date) => setState(() {
                  _start = date;
                  if (_end != null && _end!.isBefore(date)) _end = date;
                }),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _DateField(
                label: 'Selesai',
                value: _end,
                firstDate: _start,
                onPick: (date) => setState(() => _end = date),
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // ── Alasan ─────────────────────────────────────────────────────
        const SectionHeader(title: 'Alasan', icon: Icons.notes_outlined),
        TextField(
          maxLines: 4,
          maxLength: PermissionValidator.maxReasonLength,
          onChanged: (v) => setState(() => _reason = v),
          decoration: const InputDecoration(hintText: 'Jelaskan alasan izin…'),
        ),

        // ── Info hari kerja ─────────────────────────────────────────────
        if (_start != null && _end != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                validation.isValid
                    ? Icons.event_available
                    : Icons.warning_amber_rounded,
                size: 16,
                color:
                    validation.isValid ? SaeTheme.success : SaeTheme.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  validation.isValid
                      ? '${validation.dayCount} hari kerja'
                      : validation.errorMessage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: validation.isValid
                        ? SaeTheme.success
                        : SaeTheme.warning,
                  ),
                ),
              ),
            ],
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: 12),
          _ErrorNote(message: _error!),
        ],

        const SizedBox(height: 24),

        // ── Tombol submit ───────────────────────────────────────────────
        FilledButton.icon(
          onPressed: (_submitting || !validation.isValid) ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined),
          label: Text(_submitting ? 'Mengirim…' : 'Kirim Pengajuan'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    final type = _type;
    final start = _start;
    final end = _end;
    if (type == null || start == null || end == null) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    final error = await state.submitPermission(
      type: type,
      startDate: toIsoDate(start),
      endDate: toIsoDate(end),
      reason: _reason,
      attachmentUrl: null,
    );

    if (!mounted) return;

    if (error == null) {
      showAppSnackBar(context, 'Pengajuan izin berhasil dikirim.');
      // Reset form
      setState(() {
        _type = null;
        _start = null;
        _end = null;
        _reason = '';
        _submitting = false;
      });
      widget.onSubmitted();
      return;
    }

    setState(() {
      _submitting = false;
      _error = error;
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 1 — Riwayat Izin
// ═══════════════════════════════════════════════════════════════════════════════

class _RiwayatTab extends StatelessWidget {
  const _RiwayatTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final requests = state.myPermissions;

    if (requests.isEmpty) {
      return const EmptyState(
        icon: Icons.description_outlined,
        title: 'Belum ada pengajuan',
        message:
            'Riwayat izin dan cuti yang Anda ajukan akan muncul di sini.',
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<AppState>().refreshPermissions(),
      child: ListView.separated(
        padding: SaeTheme.pagePadding(context),
        itemCount: requests.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _PermissionCard(
          request: requests[index],
          isAdmin: state.isAdmin,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Kartu izin
// ═══════════════════════════════════════════════════════════════════════════════

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.request, required this.isAdmin});

  final PermissionDoc request;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Text(
                    request.permissionTypeName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                StatusBadge(
                  label: request.statusLabel,
                  color: _statusColor(context),
                  icon: _statusIcon,
                ),
              ],
            ),
            const SizedBox(height: 4),

            // ── Rentang tanggal ─────────────────────────────────────────
            Row(
              children: [
                Icon(Icons.date_range_outlined,
                    size: 14, color: theme.colorScheme.outline),
                const SizedBox(width: 6),
                Text(
                  PermissionsService.describeSpan(request),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Alasan ──────────────────────────────────────────────────
            Text(
              request.reason,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),

            if (request.attachmentUrl != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.attach_file,
                      size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Lampiran tersedia',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              ),
            ],

            // ── Review info ─────────────────────────────────────────────
            if (request.reviewedBy != null) ...[
              const Divider(height: 20),
              InfoRow(label: 'Ditinjau oleh', value: request.reviewedBy!),
              if (request.rejectionReason != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Alasan penolakan: ${request.rejectionReason}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ],
            ],

            // ── Aksi (admin atau user) ──────────────────────────────────
            if (request.canBeReviewed && isAdmin) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _approve(context),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Setujui'),
                      style: FilledButton.styleFrom(
                        backgroundColor: SaeTheme.success,
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _reject(context),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Tolak'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ),
                ],
              ),
            ] else if (request.canBeCancelled) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _cancel(context),
                  icon: const Icon(Icons.undo, size: 16),
                  label: const Text('Batalkan pengajuan'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusColor(BuildContext context) {
    switch (request.status) {
      case PermissionStatus.approved:
        return SaeTheme.success;
      case PermissionStatus.rejected:
        return Theme.of(context).colorScheme.error;
      case PermissionStatus.cancelled:
        return Theme.of(context).colorScheme.outline;
      default:
        return SaeTheme.warning;
    }
  }

  IconData get _statusIcon {
    switch (request.status) {
      case PermissionStatus.approved:
        return Icons.check_circle;
      case PermissionStatus.rejected:
        return Icons.cancel;
      case PermissionStatus.cancelled:
        return Icons.remove_circle_outline;
      default:
        return Icons.hourglass_empty;
    }
  }

  Future<void> _approve(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Setujui pengajuan?',
      message:
          'Pengajuan ${request.permissionTypeName} akan disetujui.',
      confirmLabel: 'Setujui',
    );
    if (confirmed != true || !context.mounted) return;

    final error =
        await context.read<AppState>().approvePermission(request);
    if (!context.mounted) return;

    showAppSnackBar(context, error ?? 'Pengajuan disetujui.',
        isError: error != null);
  }

  Future<void> _reject(BuildContext context) async {
    final reason = await _askRejectionReason(context);
    if (reason == null || !context.mounted) return;

    final error =
        await context.read<AppState>().rejectPermission(request, reason);
    if (!context.mounted) return;

    showAppSnackBar(context, error ?? 'Pengajuan ditolak.',
        isError: error != null);
  }

  Future<void> _cancel(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Batalkan pengajuan?',
      message: 'Pengajuan yang dibatalkan tidak dapat diproses kembali.',
      confirmLabel: 'Batalkan',
    );
    if (confirmed != true || !context.mounted) return;

    final error =
        await context.read<AppState>().cancelPermission(request);
    if (!context.mounted) return;

    showAppSnackBar(context, error ?? 'Pengajuan dibatalkan.',
        isError: error != null);
  }

  static Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
  }) =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Tidak'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      );

  static Future<String?> _askRejectionReason(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alasan penolakan'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'Jelaskan alasan penolakan…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Tolak'),
          ),
        ],
      ),
    );
    controller.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Widgets helper form
// ═══════════════════════════════════════════════════════════════════════════════

class _TypeOption extends StatelessWidget {
  const _TypeOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final PermissionTypeDoc type;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 20,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: enabled ? null : theme.colorScheme.outline,
                      ),
                    ),
                    Text(
                      'Maksimal ${type.maxDays} hari'
                      '${enabled ? '' : ' · nonaktif'}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    this.firstDate,
  });

  final String label;
  final DateTime? value;
  final DateTime? firstDate;
  final void Function(DateTime) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: firstDate ?? now,
          lastDate: now.add(const Duration(days: 365)),
        );
        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(
          value == null
              ? 'Pilih tanggal'
              : formatDisplayDate(toIsoDate(value!)),
          style: TextStyle(
            color: value == null
                ? theme.colorScheme.outline
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
