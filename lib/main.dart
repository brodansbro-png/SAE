import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'app/theme.dart';
import 'data/firebase_config.dart';
import 'data/notification_service.dart';
import 'data/server_time_service.dart';
import 'state/app_state.dart';
import 'ui/pages/app_gate.dart';
import 'ui/pages/home_shell.dart';

/// Entry point SAE.
///
/// Boot order:
///   1. flutter_dotenv   — baca .env (FIREBASE_*, CLOUDINARY_*, APP_NAME)
///   2. Firebase         — init sebelum frame pertama
///   3. NotificationService — FCM + local notifications
///   4. ServerTimeService  — sync waktu anti-spoof (background)
///   5. System chrome    — portrait lock, transparent status bar
///   6. runApp
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Env
  try { await dotenv.load(fileName: '.env'); } catch (_) {}

  // 2. Firebase
  await initialiseFirebase();

  // 3. Notifications (FCM + local)
  try { await NotificationService.instance.initialize(); } catch (_) {}

  // 4. Server time sync (background — tidak blokir startup)
  ServerTimeService.instance.sync().ignore();

  // 5. System chrome
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
  ));

  runApp(const SaeApp());
}

class SaeApp extends StatelessWidget {
  const SaeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appName = dotenv.env['APP_NAME'] ?? 'SAE Absensi';
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..start(),
      child: MaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: SaeTheme.light(),
        darkTheme: SaeTheme.dark(),
        themeMode: ThemeMode.system,
        home: const AppGate(builder: _home),
      ),
    );
  }

  static Widget _home(BuildContext context) => const HomeShell();
}
