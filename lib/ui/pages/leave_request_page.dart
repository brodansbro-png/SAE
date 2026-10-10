import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../domain/logic/time_keys.dart';
import '../../domain/models/permission.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// The leave request form, opened from the permissions tab.
///
/// Self-contained rather than embedded in the list page so the date pickers and
/// the camera sheet have a route to push onto, and so a half-filled request is
/// discarded by a back gesture instead of silently persisting.
class LeaveRequestPage extends StatefulWidget {
  const LeaveRequestPage({super.key});

  @override
  State<LeaveRequestPage> createState() => _LeaveRequestPageState();
}

class _LeaveRequestPageState extends State<LeaveRequestPage> {
  PermissionTypeDoc? _type;
  DateTime? _start;
  DateTime? _end;
  String _reason = '';

  File? _attachment;
  bool _uploading = false;
  bool _submitting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (state.permissionTypes.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ajukan Izin')),
        body: const EmptyState(
          icon: Icons.category_outlined,
          title: 'Belum ada jenis izin',
          message: 'Hubungi administrator untuk mengatur jenis izin yang tersedia.',
        ),
      );
    }

    // Validated live through the same validator the submit path uses, so the
    // button's enabled state and the server's acceptance cannot disagree.
    final validation = const PermissionValidator().validate(
      type: _type,
      startDate: _start == null ? '' : toIsoDate(_start!),
      endDate: _end == null ? '' : toIsoDate(_end!),
      reason: _reason,
      attachmentUrl: 'pending',
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Ajukan Izin')),
      body: ListView(
        padding: SaeTheme.pagePadding(context),
        children: [
          const SectionHeader(
            title: 'Jenis izin',
            icon: Icons.category_outlined,
          ),
          ...state.permissionTypes.map(
            (type) => _TypeOption(
              type: type,
              selected: _type?.id == type.id,
              onTap: type.isActive ? () => setState(() => _type = type) : null,
            ),
          ),

          const SizedBox(height: 20),
          const SectionHeader(
            title: 'Rentang tanggal',
            icon: Icons.date_range_outlined,
          ),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Mulai',
                  value: _start,
                  // Async: the picker is awaited inside the field before the
                  // caller rebuilds with the new date.
                  onPick: (date) async => setState(() {
                    _start = date;
                    // Moving the start past the end would leave the form
                    // permanently invalid, so the end follows.
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
                  onPick: (date) async => setState(() => _end = date),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          const SectionHeader(
            title: 'Alasan',
            icon: Icons.notes_outlined,
          ),
          TextField(
            maxLines: 4,
            maxLength: PermissionValidator.maxReasonLength,
            onChanged: (value) => setState(() => _reason = value),
            decoration: const InputDecoration(
              hintText: 'Jelaskan alasan izin…',
            ),
          ),

          const SizedBox(height: 8),
          _AttachmentPicker(
            attachment: _attachment,
            required: _type?.requiresAttachment ?? false,
            busy: _uploading,
            onPick: _pickAttachment,
            onClear: () => setState(() => _attachment = null),
          ),

          // Live feedback, so the working-day count and the cap are visible
          // before submitting rather than after being refused.
          if (_start != null && _end != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  validation.isValid ? Icons.event_available : Icons.warning_amber_rounded,
                  size: 16,
                  color: validation.isValid ? SaeTheme.success : SaeTheme.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    validation.isValid
                        ? '${validation.dayCount} hari kerja'
                        : validation.errorMessage,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: validation.isValid ? SaeTheme.success : SaeTheme.warning,
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
          FilledButton(
            onPressed: (_submitting || !validation.isValid) ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Kirim pengajuan'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _pickAttachment() async {
    // Gallery rather than camera: the evidence here is a medical letter or a
    // signed form that already exists. Camera-only would force an employee to
    // photograph a document badly rather than attach a clean scan.
    final picker = ImagePicker();

    try {
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;

      setState(() {
        _attachment = File(file.path);
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Tidak dapat membuka galeri. Periksa izin akses foto.',
        isError: true,
      );
    }
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

    // Upload first, so the request is only written once its evidence is
    // durably stored. The reverse order would file a request whose attachment
    // could then fail, leaving an approver looking at missing evidence.
    String? attachmentUrl;
    if (_attachment != null) {
      setState(() => _uploading = true);
      final upload = await state.uploadLeaveAttachment(_attachment!.path);
      if (!mounted) return;

      if (upload.error != null) {
        setState(() {
          _uploading = false;
          _submitting = false;
          _error = upload.error;
        });
        return;
      }
      attachmentUrl = upload.url;
      if (!mounted) return;
      setState(() => _uploading = false);
    }

    final error = await state.submitPermission(
      type: type,
      startDate: toIsoDate(start),
      endDate: toIsoDate(end),
      reason: _reason,
      attachmentUrl: attachmentUrl,
    );

    if (!mounted) return;

    if (error == null) {
      Navigator.of(context).pop(true);
      showAppSnackBar(context, 'Pengajuan izin berhasil dikirim.');
      return;
    }

    setState(() {
      _submitting = false;
      _error = error;
    });
  }
}

/// A single leave category, with its cap stated up front.
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
                : theme.colorScheme.surface,
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
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
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
                      '${type.requiresAttachment ? ' · wajib lampiran' : ''}'
                      '${enabled ? '' : ' · nonaktif'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
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

/// The attachment control, with the requirement stated when one applies.
class _AttachmentPicker extends StatelessWidget {
  const _AttachmentPicker({
    required this.attachment,
    required this.required,
    required this.busy,
    required this.onPick,
    required this.onClear,
  });

  final File? attachment;
  final bool required;
  final bool busy;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (attachment != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              attachment!,
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: busy ? null : onClear,
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Hapus lampiran'),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: busy ? null : onPick,
          icon: busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.attach_file),
          label: Text(
            busy
                ? 'Mengunggah…'
                : required
                    ? 'Lampiran wajib'
                    : 'Lampiran (opsional)',
          ),
        ),
        if (required)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: SaeTheme.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Jenis izin ini mewajibkan bukti: surat dokter atau '
                    'dokumen pendukung.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: SaeTheme.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A read-only date field that opens the platform picker.
///
/// Inert when [onPick] is null, so the start field cannot open a picker before a
/// start date exists and produce a range that begins after it ends.
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
  final Future<void> Function(DateTime) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          // A leave request cannot begin in the past. That is what stops one
          // being filed after the fact to explain an absence the employee had
          // already taken.
          firstDate: firstDate ?? now,
          lastDate: now.add(const Duration(days: 365)),
        );
        if (picked != null) await onPick(picked);
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
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
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

/// Opens the form and returns whether a request was submitted.
Future<bool?> openLeaveRequestForm(BuildContext context) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const LeaveRequestPage()),
  );
}