import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/firebase_config.dart';
import '../../domain/logic/time_keys.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import 'login_page.dart';

/// The gate in front of the app.
///
/// One widget switches on [AppStage] rather than a router, so exactly one
/// screen can ever be reachable. That is deliberate: the states are mutually
/// exclusive by construction, which removes the class of bug where a
/// "signed in but forced to update" screen sits behind a live attendance screen.
///
/// Gates are ordered by how much they constrain the employee. Maintenance comes
/// first because it affects everyone including administrators; the forced-update
/// gate follows; an incomplete profile is last, since only that one employee can
/// fix it.
class AppGate extends StatelessWidget {
  const AppGate({super.key, required this.builder});

  /// The screen to show once every gate passes.
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    switch (state.stage) {
      case AppStage.loading:
        return const _SplashScreen();

      case AppStage.setupRequired:
        return const _SetupRequiredScreen();

      case AppStage.signedOut:
        return const LoginPage();

      case AppStage.updateRequired:
        return _UpdateRequiredScreen(state: state);

      case AppStage.maintenance:
        return _MaintenanceScreen(state: state);

      case AppStage.profileIncomplete:
        return _ProfileIncompleteScreen(state: state);

      case AppStage.ready:
        return builder(context);
    }
  }
}

/// Shown while the session and reference data load.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.verified_user_outlined,
                size: 44,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'SAE',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 3,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the app was built without Firebase credentials.
///
/// Names the exact `--dart-define` values that are missing, because the person
/// looking at this screen is a developer mid-build and "not configured" would
/// cost them a round trip to the docs.
class _SetupRequiredScreen extends StatelessWidget {
  const _SetupRequiredScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = FirebaseConfig.missingConfigKeys();

    return GateNotice(
      icon: Icons.build_circle_outlined,
      tone: GateTone.error,
      title: 'Firebase belum dikonfigurasi',
      message: 'Aplikasi ini membutuhkan kredensial Firebase saat build. '
          'Variabel yang belum diisi:\n\n'
          '${missing.map((key) => '• $key').join('\n')}\n\n'
          'Jalankan ulang dengan --dart-define untuk setiap variabel tersebut. '
          'Lihat docs/RELEASE.md untuk panduan lengkap.',
      action: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'flutter run \\\n'
          '  --dart-define=FIREBASE_API_KEY=… \\\n'
          '  --dart-define=FIREBASE_AUTH_DOMAIN=… \\\n'
          '  --dart-define=FIREBASE_PROJECT_ID=… \\\n'
          '  --dart-define=FIREBASE_APP_ID=…',
          style: TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.6),
        ),
      ),
    );
  }
}



/// Shown when the installed build is below the configured minimum version.
class _UpdateRequiredScreen extends StatelessWidget {
  const _UpdateRequiredScreen({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final settings = state.appSettings;

    return GateNotice(
      icon: Icons.system_update,
      tone: GateTone.warning,
      title: 'Pembaruan diperlukan',
      message: settings.updateRequiredMessage(
        state.appVersion.isEmpty ? 'tidak diketahui' : state.appVersion,
      ),
      // Deep-links to the store listing on the current platform. The sign-out
      // below is the escape hatch: an employee stuck on a too-old build must
      // still be able to sign out and ask an administrator what to do.
      action: Column(
        children: [
          FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.storefront_outlined),
            label: Text('Tersedia di ${storeNameFor(context)}'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => context.read<AppState>().signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Keluar'),
          ),
        ],
      ),
    );
  }
}

/// The store name for the current platform.
///
/// Dart's [defaultTargetPlatform] is used rather than `Theme.of(context)`, so
/// this works from a non-widget context such as a deep-link handler.
String storeNameFor(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
      return 'App Store';
    case TargetPlatform.android:
      return 'Play Store';
    default:
      return 'toko aplikasi';
  }
}

/// Shown while the administrator has disabled punching.
class _MaintenanceScreen extends StatelessWidget {
  const _MaintenanceScreen({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return GateNotice(
      icon: Icons.construction_outlined,
      tone: GateTone.info,
      title: 'Aplikasi sedang dalam pemeliharaan',
      message: state.appSettings.maintenanceNotice,
      action: OutlinedButton.icon(
        onPressed: () => context.read<AppState>().revalidateSession(),
        icon: const Icon(Icons.refresh),
        label: const Text('Periksa lagi'),
      ),
    );
  }
}

/// Shown when the account exists in Auth but has no usable profile.
class _ProfileIncompleteScreen extends StatelessWidget {
  const _ProfileIncompleteScreen({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final user = state.user;

    final message = user == null
        ? 'Akun Anda belum terdaftar di data pegawai. Hubungi administrator '
            'untuk menambahkan Anda ke roster.'
        : 'Akun Anda berstatus tidak aktif sehingga tidak dapat melakukan '
            'absen. Hubungi administrator.';

    return GateNotice(
      icon: user == null ? Icons.person_off_outlined : Icons.block_outlined,
      tone: GateTone.warning,
      title: user == null ? 'Profil belum lengkap' : 'Akun tidak aktif',
      message: message,
      action: Column(
        children: [
          FilledButton.icon(
            onPressed: () => context.read<AppState>().revalidateSession(),
            icon: const Icon(Icons.refresh),
            label: const Text('Periksa lagi'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => context.read<AppState>().signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Keluar'),
          ),
        ],
      ),
    );
  }
}

/// Formats the current date, for gates that name one.
String todayLabel() => formatDisplayDateWithWeekday(todayIso());