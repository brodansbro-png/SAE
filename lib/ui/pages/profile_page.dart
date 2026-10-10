import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../domain/logic/access.dart';
import '../../domain/logic/time_keys.dart';
import '../../domain/models/user.dart';
import '../../domain/services/settings_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Ambil foto profil dari galeri (tidak pakai liveness — ini foto profil, bukan bukti absen).
Future<String?> capturePhotoForProfile(BuildContext context) async {
  final picker = ImagePicker();
  try {
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    return file?.path;
  } catch (_) {
    if (context.mounted) {
      showAppSnackBar(context, 'Tidak dapat membuka galeri. Periksa izin akses foto.', isError: true);
    }
    return null;
  }
}

/// The employee's own profile: identity, assignment, month totals, and sign-out.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;
    final theme = Theme.of(context);

    if (user == null) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.person_off_outlined,
          title: 'Profil tidak ditemukan',
          message: 'Data pegawai Anda belum terdaftar di sistem.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Profil Saya')),
      body: RefreshIndicator(
        onRefresh: () => context.read<AppState>().refreshHistory(),
        child: ListView(
          padding: SaeTheme.pagePadding(context),
          children: [
            _IdentityCard(user: user),
            const SizedBox(height: 14),
            _AssignmentCard(state: state, user: user),
            const SizedBox(height: 14),
            _AccessCard(user: user),
            const SizedBox(height: 14),
            _SecurityCard(),
            const SizedBox(height: 14),
            _SessionCard(state: state),

            const SizedBox(height: 14),
            _AppInfoCard(state: state),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _confirmSignOut(context),
              icon: Icon(Icons.logout, color: theme.colorScheme.error),
              label: Text(
                'Keluar',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  static Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keluar dari aplikasi?'),
        content: const Text('Anda perlu masuk kembali untuk melakukan absen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<AppState>().signOut();
    }
  }
}

/// Avatar, name, and the identifiers an employee is asked for by support.
class _IdentityCard extends StatefulWidget {
  const _IdentityCard({required this.user});

  final UserDoc user;

  @override
  State<_IdentityCard> createState() => _IdentityCardState();
}

class _IdentityCardState extends State<_IdentityCard> {
  bool _uploadingPhoto = false;

  Future<void> _changePhoto() async {
    final state = context.read<AppState>();
    // Ambil foto dari galeri
    final evidence = await capturePhotoForProfile(context);
    if (evidence == null || !mounted) return;

    setState(() => _uploadingPhoto = true);
    final error = await state.updateProfilePhoto(evidence);
    if (!mounted) return;
    setState(() => _uploadingPhoto = false);

    if (error != null) {
      showAppSnackBar(context, error, isError: true);
    } else {
      showAppSnackBar(context, 'Foto profil berhasil diperbarui.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                // Avatar + tombol ganti foto
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14),
                      backgroundImage: user.photoUrl == null
                          ? null
                          : NetworkImage(user.photoUrl!),
                      child: user.photoUrl != null
                          ? null
                          : Text(
                              getInitials(user.displayLabel),
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    // Tombol kamera di pojok kanan bawah avatar
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        onTap: _uploadingPhoto ? null : _changePhoto,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.surface,
                              width: 2,
                            ),
                          ),
                          child: _uploadingPhoto
                              ? Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                )
                              : Icon(
                                  Icons.camera_alt,
                                  size: 12,
                                  color: theme.colorScheme.onPrimary,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.displayLabel,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user.jabatan ?? 'Jabatan belum ditentukan',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 6),
                      StatusBadge(
                        label: roleLabel(user.role),
                        color: user.isAdmin ? theme.colorScheme.primary : SaeTheme.success,
                        icon: user.isAdmin ? Icons.shield_outlined : Icons.badge_outlined,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 28),
            InfoRow(
              label: 'Nomor pegawai',
              value: user.employeeNumber.isEmpty ? '—' : user.employeeNumber,
              icon: Icons.tag,
            ),
            InfoRow(label: 'Email', value: user.email, icon: Icons.mail_outline),
            if (user.unitKerja != null)
              InfoRow(
                label: 'Unit kerja',
                value: user.unitKerja!,
                icon: Icons.apartment_outlined,
              ),
            if (user.phone != null)
              InfoRow(label: 'Telepon', value: user.phone!, icon: Icons.phone_outlined),
          ],
        ),
      ),
    );
  }
}

/// The zone and shift this employee punches against.
class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard({required this.state, required this.user});

  final AppState state;
  final UserDoc user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Penugasan absensi',
              icon: Icons.assignment_outlined,
            ),
            InfoRow(
              label: 'Zona',
              value: state.zone == null
                  ? 'Belum ditentukan'
                  : '${state.zone!.name}'
                      '${state.zone!.address != null ? ' · ${state.zone!.address}' : ''}',
              icon: Icons.location_on_outlined,
              valueColor: state.zone == null ? SaeTheme.warning : null,
            ),
            InfoRow(
              label: 'Shift',
              value: SettingsService.describeShift(state.shift),
              icon: Icons.work_outline,
              valueColor: state.shift == null ? SaeTheme.warning : null,
            ),
            if (state.shift != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  describeShiftWindowsFor(state.shift),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    height: 1.5,
                  ),
                ),
              ),
            InfoRow(
              label: 'Status akun',
              value: user.isActive ? 'Aktif' : 'Tidak aktif',
              icon: Icons.verified_user_outlined,
              valueColor: user.isActive ? SaeTheme.success : theme.colorScheme.error,
            ),
          ],
        ),
      ),
    );
  }
}

/// Which pages this user may open.
///
/// Mirrors `describeAccessiblePages` in the dashboard. An `ADMIN` sees "Semua
/// halaman" because their stored list is ignored — rendering the stored array
/// here would be actively misleading.
class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.user});

  final UserDoc user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Halaman yang dapat diakses',
              icon: Icons.lock_outline,
              action: StatusBadge(
                label: roleLabel(user.role),
                color: user.isAdmin ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
            ),
            Text(
              user.isAdmin
                  ? 'Sebagai admin, Anda memiliki akses ke seluruh halaman dan '
                      'pengaturan sistem.'
                  : describeAccessiblePages(user.role, user.accessiblePages),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            if (!user.isAdmin) ...[
              const SizedBox(height: 10),
              // Naming what cannot be delegated explains why the two missing
              // entries are not an oversight.
              Text(
                'Data Pegawai dan Pengaturan tidak dapat didelegasikan karena '
                'keduanya dapat mengubah hak akses.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Password change.
///
/// Firebase requires a fresh credential first, which also proves the device is
/// being used by its owner rather than left unattended at a signed-in screen.
class _SecurityCard extends StatefulWidget {
  @override
  State<_SecurityCard> createState() => _SecurityCardState();
}

class _SecurityCardState extends State<_SecurityCard> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        title: const Text('Ubah kata sandi'),
        leading: const Icon(Icons.password_outlined),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          TextField(
            controller: _currentController,
            obscureText: _obscure,
            decoration: const InputDecoration(labelText: 'Kata sandi saat ini'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newController,
            obscureText: _obscure,
            decoration: const InputDecoration(labelText: 'Kata sandi baru'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmController,
            obscureText: _obscure,
            decoration: const InputDecoration(labelText: 'Ulangi kata sandi baru'),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Checkbox(
                value: !_obscure,
                onChanged: (value) => setState(() => _obscure = !(value ?? false)),
              ),
              const Text('Tampilkan kata sandi'),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Simpan kata sandi'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_newController.text != _confirmController.text) {
      showAppSnackBar(context, 'Konfirmasi kata sandi tidak cocok.', isError: true);
      return;
    }
    if (_newController.text.length < 6) {
      showAppSnackBar(context, 'Kata sandi minimal 6 karakter.', isError: true);
      return;
    }

    setState(() => _busy = true);
    final error = await context.read<AppState>().changePassword(
          currentPassword: _currentController.text,
          newPassword: _newController.text,
        );
    if (!mounted) return;

    setState(() => _busy = false);

    if (error == null) {
      _currentController.clear();
      _newController.clear();
      _confirmController.clear();
      showAppSnackBar(context, 'Kata sandi berhasil diubah.');
    } else {
      showAppSnackBar(context, error, isError: true);
    }
  }
}

/// The device identity stamped onto every punch.
class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Perangkat ini',
              icon: Icons.smartphone_outlined,
            ),
            InfoRow(
              label: 'ID perangkat',
              value: state.deviceId.isEmpty ? '—' : state.deviceId,
              icon: Icons.fingerprint,
              monospace: true,
            ),
            Text(
              'ID ini dicatat pada setiap absen. Absen dari ID yang sama untuk '
              'dua pegawai berbeda akan terlihat oleh administrator.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                    height: 1.4,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Build identity and configuration warnings.
class _AppInfoCard extends StatelessWidget {
  const _AppInfoCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Tentang aplikasi',
              icon: Icons.info_outline,
            ),
            InfoRow(
              label: 'Organisasi',
              value: state.appSettings.orgName,
              icon: Icons.business_outlined,
            ),
            InfoRow(
              label: 'Versi aplikasi',
              value: state.appVersion.isEmpty ? '—' : state.appVersion,
              icon: Icons.tag_faces_outlined,
            ),
            if (state.appSettings.appVersion.isNotEmpty)
              InfoRow(
                label: 'Versi minimum',
                value: state.appSettings.appVersion,
                icon: Icons.upgrade,
              ),
            if (!state.isPhotoUploadConfigured) ...[
              const Divider(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.cloud_off, size: 16, color: SaeTheme.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bukti foto belum dapat diunggah pada build ini. '
                      'Absen tetap tercatat, tetapi tanpa lampiran foto.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: SaeTheme.warning,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}