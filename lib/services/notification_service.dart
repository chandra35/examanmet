import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config_service.dart';

/// Manages polling for notifications from the simansav3 API
/// and displaying them as local notifications.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const String _lastCheckKey = 'notif_last_check';
  static const String _seenIdsKey = 'notif_seen_ids';

  final FlutterLocalNotificationsPlugin _localNotif =
      FlutterLocalNotificationsPlugin();
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'Accept': 'application/json'},
  ));

  bool _initialized = false;

  /// Initialize the local notification plugin
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotif.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        // Handle notification tap — could navigate to specific screen
        debugPrint('Notification tapped: ${response.payload}');
      },
    );

    // Request permissions on Android 13+
    await _localNotif.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();

    _initialized = true;
  }

  /// Check for new notifications from the server.
  /// Returns list of NEW (unseen) notifications for in-app handling.
  Future<List<Map<String, dynamic>>> checkForNotifications() async {
    final List<Map<String, dynamic>> newNotifications = [];
    try {
      final configService = ConfigService();
      final baseUrl = await configService.getApiBaseUrl();
      final prefs = await SharedPreferences.getInstance();
      final lastCheck = prefs.getString(_lastCheckKey);

      // Build URL with 'since' parameter
      String url = '$baseUrl/api/exam-browser/notifications';
      if (lastCheck != null) {
        url += '?since=${Uri.encodeComponent(lastCheck)}';
      }

      final response = await _dio.get(url);

      if (response.statusCode == 200 && response.data['success'] == true) {
        final List notifications = response.data['data'] ?? [];
        final serverTime = response.data['server_time'] as String?;

        // Get list of already shown notification IDs
        final seenIds = prefs.getStringList(_seenIdsKey) ?? [];

        for (final notif in notifications) {
          final id = notif['id'] as String;
          if (!seenIds.contains(id)) {
            // Show local notification
            await _showNotification(notif);
            seenIds.add(id);
            newNotifications.add(Map<String, dynamic>.from(notif));
          }
        }

        // Save state
        if (serverTime != null) {
          await prefs.setString(_lastCheckKey, serverTime);
        }
        // Keep only last 100 seen IDs to avoid unbounded growth
        if (seenIds.length > 100) {
          await prefs.setStringList(
              _seenIdsKey, seenIds.sublist(seenIds.length - 100));
        } else {
          await prefs.setStringList(_seenIdsKey, seenIds);
        }
      }
    } catch (e) {
      debugPrint('Failed to check notifications: $e');
    }
    return newNotifications;
  }

  /// Show a local notification
  Future<void> _showNotification(Map<String, dynamic> notif) async {
    final type = notif['type'] as String? ?? 'info';
    final title = notif['title'] as String? ?? 'ExaManmet';
    final message = notif['message'] as String? ?? '';
    final id = notif['id'] as String;

    // Different notification importance based on type
    AndroidNotificationDetails androidDetails;
    switch (type) {
      case 'urgent':
        androidDetails = const AndroidNotificationDetails(
          'exam_urgent',
          'Notifikasi Urgent',
          channelDescription: 'Notifikasi penting dari pengawas ujian',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          icon: '@mipmap/ic_launcher',
        );
        break;
      case 'warning':
        androidDetails = const AndroidNotificationDetails(
          'exam_warning',
          'Notifikasi Peringatan',
          channelDescription: 'Peringatan dari pengawas ujian',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          icon: '@mipmap/ic_launcher',
        );
        break;
      default:
        androidDetails = const AndroidNotificationDetails(
          'exam_info',
          'Notifikasi Info',
          channelDescription: 'Informasi dari pengawas ujian',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          icon: '@mipmap/ic_launcher',
        );
    }

    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    // Use hashCode of ID for the int notification ID
    await _localNotif.show(
      id.hashCode,
      title,
      message,
      details,
      payload: jsonEncode(notif),
    );
  }

  /// Get notifications for in-app display (returns list of notification maps)
  Future<List<Map<String, dynamic>>> getActiveNotifications() async {
    try {
      final configService = ConfigService();
      final baseUrl = await configService.getApiBaseUrl();

      final response = await _dio.get('$baseUrl/api/exam-browser/notifications');

      if (response.statusCode == 200 && response.data['success'] == true) {
        return List<Map<String, dynamic>>.from(response.data['data'] ?? []);
      }
    } catch (e) {
      debugPrint('Failed to get notifications: $e');
    }
    return [];
  }
}
