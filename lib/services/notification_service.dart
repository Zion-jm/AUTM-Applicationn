import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import '../domain/models/sensor_data.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ─────────────────────────────────────────────────────────────
// FCM BACKGROUND HANDLER — must be top-level function
// Called when app is terminated or in background
// ═══════════════════════════════════════════════════════════
// FIX #2: Background isolate gets its OWN fresh plugin instance.
// The static NotificationService._plugin is NOT available here —
// this handler runs in a separate isolate where the class was
// never initialized. We create, init, and show all locally.
// ═══════════════════════════════════════════════════════════
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final plugin = FlutterLocalNotificationsPlugin();

  const androidSettings = AndroidInitializationSettings('@mipmap/launcher_icon');
  await plugin.initialize(
    const InitializationSettings(android: androidSettings),
  );

  // Re-create the channel (safe to call even if it already exists)
  const channel = AndroidNotificationChannel(
    'autm_alerts',
    'AuTOMATO Alerts',
    description: 'Real-time sensor alert notifications',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  final notification = message.notification;
  final title = notification?.title ?? message.data['title'] ?? 'AuTOMATO';
  final body = notification?.body ?? message.data['body'] ?? '';

  await plugin.show(
    message.hashCode & 0x7FFFFFFF,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'autm_alerts',
        'AuTOMATO Alerts',
        importance: Importance.max,
        priority: Priority.high,
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────
// NOTIFICATION SERVICE
// Handles both local notifications + FCM push notifications
// ─────────────────────────────────────────────────────────────

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static final _fcm = FirebaseMessaging.instance;
  static final _auth = FirebaseAuth.instance;

  static const _channelId   = 'autm_alerts';
  static const _channelName = 'AuTOMATO Alerts';
  static const _channelDesc = 'Real-time sensor alert notifications';

  // ── Init ────────────────────────────────────────────────────
  static Future<void> init() async {
    // ── Local notifications setup ────────────────────────────
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings     = DarwinInitializationSettings(
      requestAlertPermission:     true,
      requestBadgePermission:     true,
      requestSoundPermission:     true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Create high-importance Android channel
    const androidChannel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.max,
      showBadge: true,
      playSound: true,
      enableVibration: true,
    );
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(androidChannel);
    await androidPlugin?.requestNotificationsPermission();

    // ── FCM setup ────────────────────────────────────────────
    // FIX #1: Removed duplicate FirebaseMessaging.onBackgroundMessage() call.
    // The background handler is registered once in main() (main.dart).
    // Registering it here too caused a double-registration crash.

    // Request permission (iOS + Android 13+)
    await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );

    // FIX #3: Removed dead saveFCMToken() call.
    // This always hit the user == null guard because init() runs before
    // auth is ready. Token saving is correctly handled in main.dart's
    // _onSplashFinished() after authentication is confirmed.

    // Listen for token refresh
    _fcm.onTokenRefresh.listen(_updateFCMToken);

    // ── Foreground FCM messages ──────────────────────────────
    // When app is OPEN — FCM doesn't show notification automatically
    // We show it manually via local notifications (uses initialized _plugin)
    FirebaseMessaging.onMessage.listen((message) {
      _showFCMNotification(message);
    });

    // ── Notification tap when app in background ──────────────
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _handleNotificationTap(message.data);
    });

    // ── Check if app was opened from a terminated notification
    final initial = await _fcm.getInitialMessage();
    if (initial != null) {
      _handleNotificationTap(initial.data);
    }
  }

  // ── Save FCM token to Firebase (Authenticated Only) ──────────
  static Future<void> saveFCMToken() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        // Postpone token upload silently: user is not authenticated yet.
        return;
      }

      final token = await _fcm.getToken();
      if (token == null) return;

      final db = FirebaseDatabase.instance.ref();
      // FIX #4: Use defaultTargetPlatform instead of hardcoded 'android'
      await db.child('/system/fcmTokens/$token').set({
        'token': token,
        'userId': user.uid,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    } catch (e) {
      debugPrint('FCM token registration postponed: $e');
    }
  }

  static Future<void> _updateFCMToken(String token) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final db = FirebaseDatabase.instance.ref();
      // FIX #4: Use defaultTargetPlatform instead of hardcoded 'android'
      await db.child('/system/fcmTokens/$token').set({
        'token': token,
        'userId': user.uid,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    } catch (_) {}
  }

  // ── Show FCM notification as local notification (FOREGROUND ONLY) ─
  // This uses the static _plugin which is only valid in the main isolate.
  // The background handler (firebaseMessagingBackgroundHandler) has its own
  // fresh plugin instance and does NOT call this method.
  static Future<void> _showFCMNotification(RemoteMessage message) async {
    final notification = message.notification;
    final title = notification?.title ?? message.data['title'] ?? 'AuTOMATO';
    final body = notification?.body ?? message.data['body'] ?? '';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'AuTOMATO Alert',
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'AuTOMATO',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      message.hashCode & 0x7FFFFFFF,
      title,
      body,
      details,
      payload: jsonEncode(message.data),
    );
  }

  // ── Handle notification tap ──────────────────────────────────
  static void _onNotificationTap(NotificationResponse response) {
    if (response.payload == null) return;
    try {
      final data = jsonDecode(response.payload!) as Map<String, dynamic>;
      _handleNotificationTap(data);
    } catch (_) {}
  }

  static void _handleNotificationTap(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    if (type == 'alert') {
      // Handled via main.dart navigator
    }
  }

  // ── Update badge count ───────────────────────────────────────
  static Future<void> updateBadgeCount(int count) async {
    try {
      final iOSPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      await iOSPlugin?.requestPermissions(badge: true);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════
  // 1. SENSOR ALERT NOTIFICATION
  // ═══════════════════════════════════════════════════════════

  static Future<void> showAlertNotification(AlertRecord alert,
      {int badgeCount = 0}) async {
    Uint8List? logoBytes;
    try {
      final byteData = await rootBundle.load('assets/icon/AUTM-Logo.png');
      logoBytes = byteData.buffer.asUint8List();
    } catch (_) {}

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'AuTOMATO Alert',
      largeIcon: logoBytes != null ? ByteArrayAndroidBitmap(logoBytes) : null,
      styleInformation: BigTextStyleInformation(
        _bodyFor(alert),
        contentTitle: _titleFor(alert),
        summaryText: 'AuTOMATO Sensor Alert',
      ),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      badgeNumber: badgeCount > 0 ? badgeCount : null,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      alert.id.hashCode & 0x7FFFFFFF, 
      _titleFor(alert),
      _bodyFor(alert),
      details,
      payload: jsonEncode({'type': 'alert', 'alertId': alert.id}),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 2. DEVICE TRIGGER NOTIFICATION
  // ═══════════════════════════════════════════════════════════
  static Future<void> showDeviceTriggerNotification({
    required String deviceLabel,
    required bool isOn,
    String? reason,
  }) async {
    final title = isOn ? 'System Activated' : 'System Deactivated';
    final body = reason != null
        ? '$deviceLabel turned ${isOn ? "ON" : "OFF"} via $reason.'
        : '$deviceLabel is now ${isOn ? "ON" : "OFF"}.';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'AuTOMATO Automation',
      ),
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );  

    await _plugin.show(
      deviceLabel.hashCode & 0x7FFFFFFF,
      title,
      body,
      details,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 3. DAILY HEALTH REPORT NOTIFICATION
  // ═══════════════════════════════════════════════════════════
  static Future<void> showDailyHealthNotification(int percent) async {
    const title = 'AuTOMATO Morning Report';
    final body = 'Greenhouse is $percent% optimal. Tap to view today\'s summary.';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'Daily Greenhouse Summary',
      ),
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    await _plugin.show(
      'daily_report'.hashCode & 0x7FFFFFFF,
      title,
      body,
      details,
    );
  }

  static String _titleFor(AlertRecord alert) {
    final severity = alert.alertType == SensorStatus.alert ? 'CRITICAL' : 'WARNING';
    return '$severity: ${alert.sensorLabel}';
  }

  static String _bodyFor(AlertRecord alert) {
    final severity = alert.alertType == SensorStatus.alert ? 'critical' : 'warning';
    return '${alert.sensorLabel} is at '
        '${alert.value.toStringAsFixed(2)} ${alert.unit} '
        '— $severity threshold exceeded. Tap to view details.';
  }
}