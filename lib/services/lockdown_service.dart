import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/exam_config.dart';

/// Protection level for the device.
/// Level 1: Basic (safe for all devices including aggressive OEMs)
/// Level 2: Full (all protections, only for capable devices)
enum ProtectionLevel {
  basic,  // Level 1: immersive, screenshot block, violation report, auto-lock
  full,   // Level 2: + overlay, bring-to-front, kill apps, root check, BT/headset
}

/// Service that handles all anti-cheat / lockdown functionality.
/// This is the core security layer of ExaManmet.
class LockdownService {
  static const _channel = MethodChannel('id.sch.man1metro.examanmet/lockdown');
  static const _eventChannel = EventChannel('id.sch.man1metro.examanmet/security_events');

  ExamConfig? _config;
  StreamSubscription? _securityEventSub;
  ProtectionLevel _protectionLevel = ProtectionLevel.basic;
  String _manufacturer = 'unknown';
  bool _oemPermissionGranted = false;

  /// Current protection level
  ProtectionLevel get protectionLevel => _protectionLevel;
  String get manufacturer => _manufacturer;
  bool get isFullProtection => _protectionLevel == ProtectionLevel.full;
  
  /// Callback for security events from native side
  void Function(String event)? onSecurityEvent;

  /// Initialize lockdown with the given config
  void initialize(ExamConfig config) {
    _config = config;
  }

  /// Determine the protection level based on device capabilities.
  /// Call this BEFORE enableLockdown() to set the level.
  /// Checks: manufacturer, OEM permission, overlay permission, SDK version.
  Future<ProtectionLevel> determineProtectionLevel() async {
    if (!Platform.isAndroid) {
      _protectionLevel = ProtectionLevel.basic;
      return _protectionLevel;
    }

    try {
      // Get device info
      final deviceInfo = await getDeviceInfo();
      _manufacturer = (deviceInfo['manufacturer'] ?? 'unknown').toString().toLowerCase();
      final sdkInt = deviceInfo['sdk_int'] ?? 0;

      // Check OEM permission status
      final oemInfo = await checkOemPermission();
      final needsOemPermission = oemInfo['needs_permission'] == true;

      // Check overlay permission
      final hasOverlay = await hasOverlayPermission();

      // Check if user previously chose to enable full protection
      final prefs = await SharedPreferences.getInstance();
      _oemPermissionGranted = prefs.getBool('oem_permission_granted') ?? false;

      // Decision logic:
      // - Stock Android / Pixel / non-aggressive OEM → Level 2 (full)
      // - Aggressive OEM (Vivo/Oppo/Xiaomi) + API <= 28 + no OEM perm → Level 1
      // - Aggressive OEM + OEM permission granted → Level 2
      // - Aggressive OEM + API >= 29 → Level 2 (newer OEM ROMs are less aggressive)
      
      final isAggressiveOem = needsOemPermission;
      final isOldApi = (sdkInt as int) <= 28;

      if (!isAggressiveOem) {
        // Stock Android, Pixel, etc. — full protection
        _protectionLevel = ProtectionLevel.full;
      } else if (_oemPermissionGranted && hasOverlay) {
        // OEM but user granted permissions — full protection
        _protectionLevel = ProtectionLevel.full;
      } else if (isOldApi) {
        // Aggressive OEM + old API (e.g. Vivo Android 9) — basic only
        _protectionLevel = ProtectionLevel.basic;
      } else {
        // Aggressive OEM + newer API — try full, but gentler
        _protectionLevel = hasOverlay ? ProtectionLevel.full : ProtectionLevel.basic;
      }

      debugPrint('[PROTECTION] Level: $_protectionLevel, OEM: $_manufacturer, SDK: $sdkInt, overlay: $hasOverlay, oemGranted: $_oemPermissionGranted');
    } catch (e) {
      debugPrint('[PROTECTION] Detection failed, defaulting to basic: $e');
      _protectionLevel = ProtectionLevel.basic;
    }

    return _protectionLevel;
  }

  /// Mark that user has granted OEM permissions (persist across restarts)
  Future<void> markOemPermissionGranted() async {
    _oemPermissionGranted = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('oem_permission_granted', true);
    // Re-evaluate level
    await determineProtectionLevel();
  }

  /// Enable all security measures
  Future<void> enableLockdown() async {
    if (_config == null) return;

    // Sync protection level to native side
    try {
      await _channel.invokeMethod('setProtectionLevel', {
        'level': _protectionLevel == ProtectionLevel.full ? 'full' : 'basic',
      });
    } catch (_) {}

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

    // Start listening for security events from native
    _startSecurityEventListener();

    // Extra: re-apply immersive mode after short delay to ensure it sticks
    await Future.delayed(const Duration(milliseconds: 500));
    await _enableImmersiveMode();
  }

  /// Disable lockdown (when exiting with password)
  Future<void> disableLockdown() async {
    await _enableScreenshots();
    await _disableImmersiveMode();
    _securityEventSub?.cancel();
    _securityEventSub = null;
    if (Platform.isAndroid) {
      await _stopKioskMode();
    }
  }

  Future<bool> closeApp() async {
    try {
      await disableLockdown();
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('closeApp');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to close app natively: $e');
    }
    return false;
  }

  /// Start listening to native security events
  void _startSecurityEventListener() {
    _securityEventSub?.cancel();
    _securityEventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        final eventStr = event.toString();
        debugPrint('[SECURITY] Native event: $eventStr');
        onSecurityEvent?.call(eventStr);
      },
      onError: (error) {
        debugPrint('[SECURITY] Event stream error: $error');
      },
    );
  }

  /// Perform a full security audit — returns threat map
  Future<Map<String, dynamic>> performSecurityAudit() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('securityAudit');
        return Map<String, dynamic>.from(result ?? {});
      }
    } catch (e) {
      debugPrint('Security audit failed: $e');
    }
    return {};
  }

  /// Check if device has security threats
  Future<SecurityAuditResult> getSecurityThreats() async {
    final audit = await performSecurityAudit();
    return SecurityAuditResult(
      developerOptionsEnabled: audit['developer_options'] == true,
      usbDebuggingEnabled: audit['usb_debugging'] == true,
      accessibilityServices: audit['accessibility_services'] != null
          ? List<String>.from(audit['accessibility_services'])
          : [],
      isMultiWindow: audit['is_multi_window'] == true,
      hasOverlayPermission: audit['overlay_permission'] == true,
      isInPiP: audit['is_in_picture_in_picture'] == true,
      isRooted: audit['is_rooted'] == true,
      bluetoothEnabled: audit['bluetooth_enabled'] == true,
      bluetoothDevices: audit['bluetooth_connected_devices'] != null
          ? List<String>.from(audit['bluetooth_connected_devices'])
          : [],
      headsetConnected: audit['headset_connected'] == true,
    );
  }

  /// Disable screenshots and screen recording
  Future<void> _disableScreenshots() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('setSecureFlag', {'secure': true});
      }
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

  /// Check if overlay permission is granted (needed for status bar blocker)
  Future<bool> hasOverlayPermission() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkOverlayPermission');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to check overlay permission: $e');
    }
    return false;
  }

  /// Request overlay permission (opens system settings)
  Future<void> requestOverlayPermission() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('requestOverlayPermission');
      }
    } catch (e) {
      debugPrint('Failed to request overlay permission: $e');
    }
  }

  /// Get device info (manufacturer, brand, model, SDK version)
  Future<Map<String, dynamic>> getDeviceInfo() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('getDeviceInfo');
        return Map<String, dynamic>.from(result ?? {});
      }
    } catch (e) {
      debugPrint('Failed to get device info: $e');
    }
    return {};
  }

  /// Check if this device's OEM needs special autostart/background permission
  Future<Map<String, dynamic>> checkOemPermission() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('needsOemPermission');
        return Map<String, dynamic>.from(result ?? {});
      }
    } catch (e) {
      debugPrint('Failed to check OEM permission: $e');
    }
    return {'needs_permission': false, 'manufacturer': 'unknown', 'has_intent': false};
  }

  /// Open OEM-specific autostart/background permission settings
  Future<bool> openOemPermissionSettings() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('openOemPermissionSettings');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to open OEM permission settings: $e');
    }
    return false;
  }

  /// Check if DND (Do Not Disturb) policy access is granted.
  /// Required to block WhatsApp notifications & calls during exam.
  Future<bool> hasDndAccess() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkDndAccess');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to check DND access: $e');
    }
    return false;
  }

  Future<bool> hasBluetoothPermission() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkBluetoothPermission');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to check Bluetooth permission: $e');
    }
    return !Platform.isAndroid;
  }

  Future<bool> requestBluetoothPermission() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('requestBluetoothPermission');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to request Bluetooth permission: $e');
    }
    return !Platform.isAndroid;
  }

  /// Request DND policy access (opens system settings page).
  /// User must manually enable DND access for ExaManmet.
  Future<bool> requestDndAccess() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('requestDndAccess');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to request DND access: $e');
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

  /// Kill suspicious background apps (cheating, bloatware, adware)
  Future<List<String>> killSuspiciousApps() async {
    try {
      final result = await _channel.invokeMethod('killSuspiciousApps');
      if (result is List) {
        return result.map((e) => e.toString()).toList();
      }
      return [];
    } catch (e) {
      debugPrint('Failed to kill suspicious apps: $e');
      return [];
    }
  }

  /// Check current keyboard (IME) for adware
  Future<KeyboardCheckResult> checkKeyboard() async {
    try {
      final result = await _channel.invokeMethod('checkKeyboard');
      if (result is Map) {
        return KeyboardCheckResult(
          currentIme: result['current_ime']?.toString() ?? '',
          packageName: result['package_name']?.toString() ?? '',
          keyboardName: result['keyboard_name']?.toString() ?? '',
          isSafe: result['is_safe'] == true,
          isAdware: result['is_adware'] == true,
        );
      }
    } catch (e) {
      debugPrint('Failed to check keyboard: $e');
    }
    return KeyboardCheckResult(
      currentIme: '', packageName: '', keyboardName: '',
      isSafe: true, isAdware: false,
    );
  }

  /// Disable clipboard if configured — uses native method to avoid Android 13+ toast
  Future<void> disableClipboard() async {
    if (_config != null && !_config!.allowClipboard) {
      try {
        if (Platform.isAndroid) {
          await _channel.invokeMethod('clearClipboard');
        } else {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (e) {
        debugPrint('Failed to clear clipboard: $e');
      }
    }
  }

  // ==================== Bluetooth Detection ====================

  /// Check Bluetooth status and connected devices
  Future<BluetoothStatus> checkBluetooth() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkBluetooth');
        final map = Map<String, dynamic>.from(result ?? {});
        return BluetoothStatus(
          enabled: map['enabled'] == true,
          connectedDevices: map['connected_devices'] != null
              ? List<String>.from(map['connected_devices'])
              : [],
        );
      }
    } catch (e) {
      debugPrint('Failed to check Bluetooth: $e');
    }
    return BluetoothStatus(enabled: false, connectedDevices: []);
  }

  /// Open Bluetooth settings so user can turn it off
  Future<void> openBluetoothSettings() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('openBluetoothSettings');
      }
    } catch (e) {
      debugPrint('Failed to open Bluetooth settings: $e');
    }
  }

  // ==================== Headset Detection ====================

  /// Check if headset/earphone is connected
  Future<bool> isHeadsetConnected() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkHeadset');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to check headset: $e');
    }
    return false;
  }

  // ==================== Root Detection ====================

  /// Check if device is rooted
  Future<bool> isDeviceRooted() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('checkRoot');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to check root: $e');
    }
    return false;
  }

  // ==================== Alert Sound ====================

  /// Play alert sound for security violations
  Future<void> playAlertSound() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('playAlertSound');
      }
    } catch (e) {
      debugPrint('Failed to play alert sound: $e');
    }
  }

  /// Stop alert sound
  Future<void> stopAlertSound() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('stopAlertSound');
      }
    } catch (e) {
      debugPrint('Failed to stop alert sound: $e');
    }
  }

  /// Open Developer Options settings page
  Future<bool> openDeveloperSettings() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('openDeveloperSettings');
        return result == true;
      }
    } catch (e) {
      debugPrint('Failed to open developer settings: $e');
    }
    return false;
  }
}

/// Result of a security audit
class SecurityAuditResult {
  final bool developerOptionsEnabled;
  final bool usbDebuggingEnabled;
  final List<String> accessibilityServices;
  final bool isMultiWindow;
  final bool hasOverlayPermission;
  final bool isInPiP;
  final bool isRooted;
  final bool bluetoothEnabled;
  final List<String> bluetoothDevices;
  final bool headsetConnected;

  SecurityAuditResult({
    required this.developerOptionsEnabled,
    required this.usbDebuggingEnabled,
    required this.accessibilityServices,
    required this.isMultiWindow,
    required this.hasOverlayPermission,
    required this.isInPiP,
    this.isRooted = false,
    this.bluetoothEnabled = false,
    this.bluetoothDevices = const [],
    this.headsetConnected = false,
  });

  /// Whether any security threat is detected
  bool get hasThreats =>
      developerOptionsEnabled ||
      usbDebuggingEnabled ||
      accessibilityServices.isNotEmpty ||
      isMultiWindow ||
      isInPiP ||
      isRooted;

  /// Whether critical (acute) threats are present — these deserve alarm sound.
  /// Developer Options / USB Debugging are settings-based, handled by blocking dialog only.
  bool get hasCriticalThreats =>
      accessibilityServices.isNotEmpty ||
      isMultiWindow ||
      isInPiP ||
      isRooted;

  /// Get human-readable list of threats
  List<String> get threatDescriptions {
    final threats = <String>[];
    if (developerOptionsEnabled) threats.add('Developer Options aktif');
    if (usbDebuggingEnabled) threats.add('USB Debugging aktif');
    if (accessibilityServices.isNotEmpty) {
      threats.add('Accessibility Service mencurigakan: ${accessibilityServices.join(", ")}');
    }
    if (isMultiWindow) threats.add('Mode Split Screen terdeteksi');
    if (isInPiP) threats.add('Picture-in-Picture terdeteksi');
    if (isRooted) threats.add('Perangkat di-ROOT (keamanan terancam)');
    return threats;
  }
}

/// Bluetooth connection status
class BluetoothStatus {
  final bool enabled;
  final List<String> connectedDevices;

  BluetoothStatus({
    required this.enabled,
    required this.connectedDevices,
  });

  bool get hasConnectedDevices => connectedDevices.isNotEmpty;
}

/// Result of keyboard (IME) check
class KeyboardCheckResult {
  final String currentIme;
  final String packageName;
  final String keyboardName;
  final bool isSafe;
  final bool isAdware;

  KeyboardCheckResult({
    required this.currentIme,
    required this.packageName,
    required this.keyboardName,
    required this.isSafe,
    required this.isAdware,
  });
}
