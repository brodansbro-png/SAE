import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../data/notification_service.dart';
import '../../domain/logic/access.dart';
import '../../domain/logic/time_keys.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import 'attendance_page.dart';
import 'history_page.dart';
import 'permissions_page.dart';
import 'profile_page.dart';

/// Shell navigasi utama dengan bottom nav (phone) / rail (tablet).
///
/// 4 tab:
///   0 — Absensi   : presensi hari ini, foto wajah wajib, peta lokasi
///   1 — Riwayat   : tab Hari Ini + Log dengan filter kalender & modal peta
///   2 — Izin      : tab Ajukan Izin + Riwayat Izin
///   3 — Profil    : info akun, ganti kata sandi, logout
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  static const double _railBreak = 720;

  static const _tabs = [
    _Tab(
      label: 'Absensi',
      icon: Icons.fingerprint_outlined,
      active: Icons.fingerprint,
      svg: 'assets/icons/home.svg',
      page: AccessPage.dashboard,
      idx: 0,
    ),
    _Tab(
      label: 'Riwayat',
      icon: Icons.history_outlined,
      active: Icons.history,
      svg: null,
      page: AccessPage.attendance,
      idx: 1,
    ),
    _Tab(
      label: 'Izin',
      icon: Icons.description_outlined,
      active: Icons.description,
      svg: 'assets/icons/inbox.svg',
      page: AccessPage.permissions,
      idx: 2,
    ),
    _Tab(
      label: 'Profil',
      icon: Icons.person_outline,
      active: Icons.person,
      svg: 'assets/icons/karyawan.svg',
      page: AccessPage.profile,
      idx: 3,
    ),
  ];

  final _pages = const [
    AttendancePage(),
    HistoryPage(),
    PermissionsPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.onTap = _handleNotificationRoute;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<AppState>().startLocation();
    }
  }

  void _handleNotificationRoute(String route) {
    if (!mounted) return;
    switch (route) {
      case '/attendance':
        setState(() => _index = 0);
      case '/permissions':
      case '/izin':
        setState(() => _index = 2);
      case '/profile':
        setState(() => _index = 3);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tabs = _tabs.where((t) => state.canOpen(t.page)).toList();

    if (tabs.isEmpty) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'Tidak ada halaman yang dapat diakses',
          message: 'Hubungi administrator untuk membuka akses.',
        ),
      );
    }

    final safe = _index.clamp(0, tabs.length - 1);
    final body = IndexedStack(
      index: safe,
      children: [for (final t in tabs) _pages[t.idx]],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= _railBreak;
        return Scaffold(
          appBar: _buildAppBar(context, tabs, safe, state),
          body: Column(
            children: [
              if (state.isDeviceTimeSuspicious)
                _TimeBanner(message: state.deviceTimeWarning ?? ''),
              Expanded(
                child: Row(
                  children: [
                    if (useRail) _buildRail(context, tabs, safe),
                    Expanded(child: body),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar:
              useRail ? null : _buildBottomNav(context, tabs, safe),
        );
      },
    );
  }

  AppBar _buildAppBar(
    BuildContext ctx,
    List<_Tab> tabs,
    int safe,
    AppState state,
  ) {
    final theme = Theme.of(ctx);
    return AppBar(
      title: Row(
        children: [
          // Logo
          Container(
            width: 32,
            height: 32,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Image.asset(
              'assets/image/sae_logo.png',
              errorBuilder: (_, _, _) => Icon(
                Icons.verified_user,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tabs[safe].label,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (state.appSettings.orgName.isNotEmpty)
                Text(
                  state.appSettings.orgName,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
            ],
          ),
        ],
      ),
      actions: [
        // Badge cuti hari ini
        if (state.approvedLeaveToday != null)
          Tooltip(
            message: 'Sedang cuti hari ini',
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.beach_access,
                color: theme.colorScheme.tertiary,
                size: 22,
              ),
            ),
          ),
        // Tanggal + spinner GPS
        _SyncChip(state: state),
        const SizedBox(width: 8),
      ],
    );
  }

  NavigationRail _buildRail(BuildContext ctx, List<_Tab> tabs, int safe) =>
      NavigationRail(
        selectedIndex: safe,
        onDestinationSelected: (i) => setState(() => _index = i),
        labelType: NavigationRailLabelType.all,
        destinations: [
          for (final t in tabs)
            NavigationRailDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.active),
              label: Text(t.label),
            ),
        ],
      );

  NavigationBar _buildBottomNav(
    BuildContext ctx,
    List<_Tab> tabs,
    int safe,
  ) =>
      NavigationBar(
        selectedIndex: safe,
        onDestinationSelected: (i) => setState(() => _index = i),
        animationDuration: const Duration(milliseconds: 300),
        destinations: [
          for (final t in tabs)
            NavigationDestination(
              icon: t.svg != null
                  ? SvgPicture.asset(
                      t.svg!,
                      width: 22,
                      height: 22,
                      colorFilter: ColorFilter.mode(
                        Theme.of(ctx).colorScheme.onSurfaceVariant,
                        BlendMode.srcIn,
                      ),
                    )
                  : Icon(t.icon),
              selectedIcon: t.svg != null
                  ? SvgPicture.asset(
                      t.svg!,
                      width: 22,
                      height: 22,
                      colorFilter: ColorFilter.mode(
                        Theme.of(ctx).colorScheme.primary,
                        BlendMode.srcIn,
                      ),
                    )
                  : Icon(t.active),
              label: t.label,
            ),
        ],
      );
}

// ── Supporting types ──────────────────────────────────────────────────────────

class _Tab {
  const _Tab({
    required this.label,
    required this.icon,
    required this.active,
    required this.svg,
    required this.page,
    required this.idx,
  });

  final String label;
  final IconData icon;
  final IconData active;
  final String? svg;
  final AccessPage page;
  final int idx;
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatDisplayDate(todayIso()),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        if (state.isLocating) ...[
          const SizedBox(width: 6),
          const SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ],
    );
  }
}

class _TimeBanner extends StatelessWidget {
  const _TimeBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.error.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.access_time_filled,
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
