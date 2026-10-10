// ignore_for_file: avoid_function_literals_in_foreach_calls
import 'dart:ui' show Color;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../domain/models/shift.dart';

const Color _kTeal = Color(0xFF00695C);

// ─────────────────────────────────────────────────────────────────────────────
// Top-level handlers — WAJIB top-level untuk FCM background
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _bgMessageHandler(RemoteMessage msg) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  ));
  await plugin.show(
    msg.hashCode,
    msg.notification?.title ?? 'SAE Absensi',
    msg.notification?.body ?? '',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'sae_attendance', 'SAE Absensi',
        importance: Importance.max, priority: Priority.high,
        icon: '@mipmap/ic_launcher', color: _kTeal,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    ),
    payload: msg.data['route'],
  );
}

@pragma('vm:entry-point')
void _bgTapHandler(NotificationResponse _) {}

// ─────────────────────────────────────────────────────────────────────────────
// NotificationService
// ─────────────────────────────────────────────────────────────────────────────
/// Layanan notifikasi SAE.
///
/// - FCM push: masuk ke status bar saat foreground, background, maupun app mati.
/// - Shift reminder: dijadwalkan 30 menit sebelum shift, berulang tiap hari,
///   bahkan saat app tidak berjalan (exactAllowWhileIdle).
/// - Token management: disimpan ke Firestore agar dashboard/server bisa kirim
///   push langsung ke device pegawai.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _msg = FirebaseMessaging.instance;
  final _local = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Set oleh HomeShell — navigate saat notifikasi di-tap.
  void Function(String route)? onTap;

  // ── Init ───────────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    if (_ready) return;

    // Timezone untuk scheduled notifications
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));
    } catch (_) {}

    // Android notification channel
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'sae_attendance',
          'SAE Absensi',
          description: 'Pengingat absensi dan notifikasi sistem SAE',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          showBadge: true,
        ));

    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: true,
          requestSoundPermission: true,
        ),
      ),
      onDidReceiveNotificationResponse: (d) {
        if (d.payload?.isNotEmpty == true) onTap?.call(d.payload!);
      },
      onDidReceiveBackgroundNotificationResponse: _bgTapHandler,
    );

    await _msg.requestPermission(alert: true, badge: true, sound: true);
    await _msg.setForegroundNotificationPresentationOptions(
        alert: true, badge: true, sound: true);

    FirebaseMessaging.onBackgroundMessage(_bgMessageHandler);
    FirebaseMessaging.onMessage.listen(_showForeground);
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final r = m.data['route'] as String?;
      if (r != null) onTap?.call(r);
    });

    final initial = await _msg.getInitialMessage();
    if (initial != null) {
      final r = initial.data['route'] as String?;
      if (r != null) {
        Future.delayed(const Duration(milliseconds: 800), () => onTap?.call(r));
      }
    }

    _ready = true;
    if (kDebugMode) debugPrint('[Notif] initialized');
  }

  void _showForeground(RemoteMessage msg) {
    _local.show(
      msg.hashCode,
      msg.notification?.title ?? 'SAE Absensi',
      msg.notification?.body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sae_attendance', 'SAE Absensi',
          importance: Importance.max, priority: Priority.high,
          icon: '@mipmap/ic_launcher', color: _kTeal,
          enableVibration: true, playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true, presentBadge: true, presentSound: true),
      ),
      payload: msg.data['route'],
    );
  }

  // ── Token ──────────────────────────────────────────────────────────────────

  Future<void> registerToken(String uid) async {
    try {
      final token = await _msg.getToken();
      if (token != null) await _writeToken(uid, token);
      _msg.onTokenRefresh.listen((t) => _writeToken(uid, t));
    } catch (_) {}
  }

  Future<void> _writeToken(String uid, String token) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'fcmToken': token,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> unregisterToken(String uid) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'fcmToken': FieldValue.delete()});
      await _msg.deleteToken();
    } catch (_) {}
  }

  // ── Shift reminder ─────────────────────────────────────────────────────────

  Future<void> scheduleShiftReminder(Shift shift) async {
    await _local.cancel(_id(shift.id));

    final parts = shift.startTime.split(':');
    if (parts.length != 2) return;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return;

    final now = DateTime.now();
    var shiftStart = DateTime(now.year, now.month, now.day, h, m);
    var remindAt = shiftStart.subtract(const Duration(minutes: 30));

    if (remindAt.isBefore(now)) {
      shiftStart = shiftStart.add(const Duration(days: 1));
      remindAt = shiftStart.subtract(const Duration(minutes: 30));
    }

    if (shift.daysOfWeek.isNotEmpty &&
        !shift.daysOfWeek.contains(remindAt.weekday)) {
      return;
    }

    try {
      await _local.zonedSchedule(
        _id(shift.id),
        'Waktunya Absen! ⏰',
        'Shift ${shift.name} mulai pukul ${shift.startTime}. Segera ke titik absen.',
        tz.TZDateTime.from(remindAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'sae_attendance', 'SAE Absensi',
            importance: Importance.max, priority: Priority.high,
            icon: '@mipmap/ic_launcher', color: _kTeal,
            enableVibration: true, playSound: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true, presentBadge: true, presentSound: true,
            interruptionLevel: InterruptionLevel.active,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: '/attendance',
      );
      if (kDebugMode) {
        debugPrint('[Notif] Reminder: ${shift.name} @ '
            '${remindAt.hour}:${remindAt.minute.toString().padLeft(2, '0')}');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Notif] Schedule error: $e');
    }
  }

  Future<void> showNow({
    required String title,
    required String body,
    String? route,
  }) async {
    await _local.show(
      DateTime.now().millisecondsSinceEpoch.hashCode,
      title, body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sae_attendance', 'SAE Absensi',
          importance: Importance.max, priority: Priority.high,
          icon: '@mipmap/ic_launcher', color: _kTeal,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true, presentBadge: true, presentSound: true),
      ),
      payload: route,
    );
  }

  Future<void> cancelAll() => _local.cancelAll();
  Future<void> cancelShift(String shiftId) => _local.cancel(_id(shiftId));
  int _id(String id) => id.hashCode.abs() % 100000;
}
