import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

/// Service to manage exam session, heartbeat, and violation reporting
/// to the simansav3 backend.
class ExamSessionService {
  static const String _sessionIdKey = 'exam_session_id';

  final Dio _dio;
  String? _sessionId;
  String? _deviceId;
  String? _deviceModel;
  String? _appVersion;
  String? _osVersion;
  String? _moodleUsername;
  String? _moodleFullname;
  bool _isLocked = false;
  String? _lockReason;
  int _violationCount = 0;
  Timer? _heartbeatTimer;
  String? _baseUrl;

  // Callback when lock status changes
  void Function(bool isLocked, String? reason)? onLockStatusChanged;

  ExamSessionService()
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
        ));

  bool get isLocked => _isLocked;
  String? get lockReason => _lockReason;
  int get violationCount => _violationCount;
  String? get sessionId => _sessionId;
  String? get moodleUsername => _moodleUsername;

  /// Initialize device info
  Future<void> _initDeviceInfo() async {
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        _deviceId = info.id; // Android ID
        _deviceModel = '${info.brand} ${info.model}';
        _osVersion = 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
      }
    } catch (_) {}

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _appVersion = packageInfo.version;
    } catch (_) {}
  }

  /// Get the API base URL from shared preferences (same as ConfigService)
  Future<String> _getBaseUrl() async {
    if (_baseUrl != null) return _baseUrl!;
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('api_base_url') ?? 'https://simansa.man1metro.sch.id';
    return _baseUrl!;
  }

  /// Start a new exam session
  Future<void> startSession() async {
    await _initDeviceInfo();
    final baseUrl = await _getBaseUrl();

    try {
      final response = await _dio.post(
        '$baseUrl/api/exam-browser/session/start',
        data: {
          'device_id': _deviceId ?? 'unknown',
          'device_model': _deviceModel,
          'moodle_username': _moodleUsername,
          'moodle_fullname': _moodleFullname,
          'app_version': _appVersion,
          'os_version': _osVersion,
        },
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        _sessionId = response.data['data']['session_id'];
        _isLocked = response.data['data']['is_locked'] ?? false;
        _lockReason = response.data['data']['lock_reason'];
        _violationCount = response.data['data']['violation_count'] ?? 0;

        // Save session ID locally
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_sessionIdKey, _sessionId!);

        // Start heartbeat
        _startHeartbeat();
      }
    } catch (e) {
      // Session start failed — continue exam without server tracking
      debugPrint('ExaManmet: Session start failed: $e');
    }
  }

  /// Update Moodle user info (called after JS extraction from WebView)
  void updateMoodleUser(String? username, String? fullname) {
    _moodleUsername = username;
    _moodleFullname = fullname;
  }

  /// Start heartbeat timer (every 30 seconds — balanced between real-time and server load)
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendHeartbeat(),
    );
  }

  /// Send heartbeat to server
  Future<void> _sendHeartbeat() async {
    if (_sessionId == null) return;

    // Check for pending lock state from background FCM delivery
    final pendingLock = await NotificationService.consumePendingLockState();
    if (pendingLock != null) {
      final myId = _sessionId.toString();
      if (pendingLock.sessionId == myId || pendingLock.sessionId.isEmpty) {
        if (pendingLock.isLocked != _isLocked) {
          _isLocked = pendingLock.isLocked;
          _lockReason = pendingLock.reason;
          onLockStatusChanged?.call(_isLocked, _lockReason);
        }
      }
    }

    try {
      final baseUrl = await _getBaseUrl();
      final response = await _dio.post(
        '$baseUrl/api/exam-browser/session/heartbeat',
        data: {
          'session_id': _sessionId,
          'moodle_username': _moodleUsername,
          'moodle_fullname': _moodleFullname,
        },
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final data = response.data['data'];
        final newLocked = data['is_locked'] ?? false;
        final newReason = data['lock_reason'];
        _violationCount = data['violation_count'] ?? _violationCount;

        // Notify if lock status changed
        if (newLocked != _isLocked) {
          _isLocked = newLocked;
          _lockReason = newReason;
          onLockStatusChanged?.call(_isLocked, _lockReason);
        }
      } else if (response.statusCode == 404) {
        // Session expired — stop heartbeat
        _heartbeatTimer?.cancel();
        _sessionId = null;
      }
    } catch (_) {
      // Network error — continue silently, retry on next heartbeat
    }
  }

  /// Report a violation to the server
  Future<void> reportViolation(String type, {String? detail}) async {
    if (_sessionId == null) return;

    try {
      final baseUrl = await _getBaseUrl();
      final response = await _dio.post(
        '$baseUrl/api/exam-browser/session/violation',
        data: {
          'session_id': _sessionId,
          'violation_type': type,
          'violation_detail': detail,
        },
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final data = response.data['data'];
        _violationCount = data['violation_count'] ?? _violationCount;

        final newLocked = data['is_locked'] ?? false;
        if (newLocked != _isLocked) {
          _isLocked = newLocked;
          _lockReason = data['lock_reason'];
          onLockStatusChanged?.call(_isLocked, _lockReason);
        }
      }
    } catch (_) {
      // Network error — violation not reported, continue silently
    }
  }

  /// End the exam session
  Future<void> endSession() async {
    _heartbeatTimer?.cancel();

    if (_sessionId == null) return;

    try {
      final baseUrl = await _getBaseUrl();
      await _dio.post(
        '$baseUrl/api/exam-browser/session/end',
        data: {'session_id': _sessionId},
      );
    } catch (_) {}

    _sessionId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionIdKey);
  }

  /// Dispose resources
  void dispose() {
    _heartbeatTimer?.cancel();
  }
}
