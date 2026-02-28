import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/exam_config.dart';

/// Service that handles all anti-cheat / lockdown functionality.
/// This is the core security layer of ExaManmet.
class LockdownService {
  static const _channel = MethodChannel('id.sch.man1metro.examanmet/lockdown');

  ExamConfig? _config;

  /// Initialize lockdown with the given config
  void initialize(ExamConfig config) {
    _config = config;
  }

  /// Enable all security measures
  Future<void> enableLockdown() async {
    if (_config == null) return;

    // Disable screenshots
    if (!_config!.allowScreenshot) {
      await _disableScreenshots();
    }

    // Keep screen awake
    await _keepScreenAwake();

    // Hide system UI (immersive/kiosk mode) — Flutter side
    await _enableImmersiveMode();

    // Start app pinning on Android (also enables native immersive + status bar blocker)
    if (Platform.isAndroid) {
      await _startKioskMode();
    }

    // Extra: re-apply immersive mode after short delay to ensure it sticks
    await Future.delayed(const Duration(milliseconds: 500));
    await _enableImmersiveMode();
  }

  /// Disable lockdown (when exiting with password)
  Future<void> disableLockdown() async {
    await _enableScreenshots();
    await _disableImmersiveMode();
    if (Platform.isAndroid) {
      await _stopKioskMode();
    }
  }

  /// Disable screenshots and screen recording
  Future<void> _disableScreenshots() async {
    try {
      if (Platform.isAndroid) {
        // On Android: FLAG_SECURE prevents screenshots & screen recording
        await _channel.invokeMethod('setSecureFlag', {'secure': true});
      }
      // On iOS: screenshot prevention is handled natively
    } catch (e) {
      debugPrint('Failed to disable screenshots: $e');
    }
  }

  /// Re-enable screenshots
  Future<void> _enableScreenshots() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('setSecureFlag', {'secure': false});
      }
    } catch (e) {
      debugPrint('Failed to enable screenshots: $e');
    }
  }

  /// Enable immersive mode (hide status bar & navigation bar)
  Future<void> _enableImmersiveMode() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
    );
  }

  /// Disable immersive mode
  Future<void> _disableImmersiveMode() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  /// Keep screen awake during exam
  Future<void> _keepScreenAwake() async {
    try {
      await _channel.invokeMethod('keepScreenAwake', {'awake': true});
    } catch (e) {
      debugPrint('Failed to keep screen awake: $e');
    }
  }

  /// Start Android kiosk mode (screen pinning + disable back/home/recents)
  Future<void> _startKioskMode() async {
    try {
      await _channel.invokeMethod('startKioskMode');
    } catch (e) {
      debugPrint('Failed to start kiosk mode: $e');
    }
  }

  /// Stop Android kiosk mode
  Future<void> _stopKioskMode() async {
    try {
      await _channel.invokeMethod('stopKioskMode');
    } catch (e) {
      debugPrint('Failed to stop kiosk mode: $e');
    }
  }

  /// Check if there are floating/overlay apps running (Android only)
  Future<bool> hasFloatingApps() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkFloatingApps');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to check floating apps: $e');
    }
    return false;
  }

  /// Check if any blocked apps are currently running
  Future<List<String>> getRunningBlockedApps() async {
    if (_config == null || _config!.blockedApps.isEmpty) return [];
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod(
          'checkBlockedApps',
          {'packages': _config!.blockedApps},
        );
        return List<String>.from(result ?? []);
      }
    } catch (e) {
      debugPrint('Failed to check blocked apps: $e');
    }
    return [];
  }

  /// Disable clipboard if configured
  Future<void> disableClipboard() async {
    if (_config != null && !_config!.allowClipboard) {
      // Clear clipboard periodically
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }
}
