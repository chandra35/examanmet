import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/config_service.dart';
import '../services/lockdown_service.dart';
import '../models/exam_config.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final ConfigService _configService = ConfigService();
  final LockdownService _lockdownService = LockdownService();

  String _appVersion = '';
  String _statusText = 'Memuat...';
  bool _hasError = false;
  String _errorMessage = '';
  bool _loading = true;

  String _formatVersionLabel(PackageInfo info) {
    final buildNumber = info.buildNumber.trim();
    if (buildNumber.isEmpty) return info.version;
    return '${info.version}+${info.buildNumber}';
  }

  bool _isVersionLower(String current, String minimum) {
    List<int> parse(String value) => value
        .split('.')
        .map(
          (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
        )
        .toList();

    final currentParts = parse(current);
    final minimumParts = parse(minimum);
    final maxLength = currentParts.length > minimumParts.length
        ? currentParts.length
        : minimumParts.length;

    for (var i = 0; i < maxLength; i++) {
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      final minimumPart = i < minimumParts.length ? minimumParts[i] : 0;
      if (currentPart < minimumPart) return true;
      if (currentPart > minimumPart) return false;
    }

    return false;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<bool> _ensureAndroidPermissions(ExamConfig config) async {
    if (!Platform.isAndroid) return true;

    setState(() => _statusText = 'Memeriksa izin proteksi...');

    var hasOverlay = await _lockdownService.hasOverlayPermission();
    if (!hasOverlay) {
      await _lockdownService.requestOverlayPermission();
      await Future.delayed(const Duration(seconds: 2));
      hasOverlay = await _lockdownService.hasOverlayPermission();
    }

    var hasDnd = await _lockdownService.hasDndAccess();
    if (!hasDnd) {
      await _lockdownService.requestDndAccess();
      await Future.delayed(const Duration(seconds: 2));
      hasDnd = await _lockdownService.hasDndAccess();
    }

    final missing = <String>[];
    if (!hasOverlay) {
      missing.add(
        'Izin tampil di atas aplikasi lain belum aktif. Tanpa izin ini, swipe status bar/notifikasi masih bisa lolos.',
      );
    }
    if (!hasDnd) {
      missing.add(
        'Akses Jangan Ganggu (DND) belum aktif. Notifikasi dan panggilan belum bisa diblokir penuh.',
      );
    }

    if (config.detectBluetooth) {
      var hasBluetoothPermission = await _lockdownService.hasBluetoothPermission();
      if (!hasBluetoothPermission) {
        await _lockdownService.requestBluetoothPermission();
        await Future.delayed(const Duration(seconds: 1));
        hasBluetoothPermission = await _lockdownService.hasBluetoothPermission();
      }

      if (!hasBluetoothPermission) {
        missing.add(
          'Izin perangkat terdekat / Bluetooth belum aktif. Tanpa izin ini, aplikasi tidak bisa mendeteksi headset Bluetooth.',
        );
      }
    }

    if (missing.isNotEmpty) {
      if (!mounted) return false;
      setState(() {
        _hasError = true;
        _loading = false;
        _statusText = 'Proteksi belum siap';
        _errorMessage = missing.join('\n\n');
      });
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final oemGranted = prefs.getBool('oem_permission_granted') ?? false;
    final oemInfo = await _lockdownService.checkOemPermission();
    if (!oemGranted &&
        oemInfo['needs_permission'] == true &&
        oemInfo['has_intent'] == true) {
      await _lockdownService.openOemPermissionSettings();
      await Future.delayed(const Duration(seconds: 2));
      await _lockdownService.markOemPermissionGranted();
    }

    return true;
  }

  Future<void> _init() async {
    // Load version
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = _formatVersionLabel(info);
    } catch (_) {
      _appVersion = '';
    }
    if (mounted) setState(() {});

    // Fetch config
    setState(() => _statusText = 'Menghubungi server...');
    ExamConfig? config;
    try {
      config = await _configService.fetchConfig(
        allowRuntimeFallback: false,
        allowCacheFallback: false,
        allowDefaultFallback: false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _loading = false;
        _errorMessage = '$e';
        _statusText = 'Gagal terhubung ke server';
      });
      return;
    }

    if (!mounted) return;
    final resolvedConfig = config;

    if (_appVersion.isNotEmpty &&
        _isVersionLower(
          _appVersion.split('+').first,
          resolvedConfig.minimumAppVersion,
        )) {
      setState(() {
        _hasError = true;
        _loading = false;
        _errorMessage =
            'Versi aplikasi terlalu lama. Minimal ${resolvedConfig.minimumAppVersion}, versi terpasang $_appVersion.';
        _statusText = 'Perlu update aplikasi';
      });
      return;
    }

    // Check active
    if (!resolvedConfig.isActive) {
      setState(() {
        _hasError = true;
        _loading = false;
        _errorMessage = 'Exam Browser tidak aktif. Hubungi admin.';
        _statusText = 'Tidak aktif';
      });
      return;
    }

    // Permissions
    final permissionsReady = await _ensureAndroidPermissions(resolvedConfig);
    if (!permissionsReady) {
      return;
    }

    if (Platform.isAndroid) {
      // Bluetooth: always check every launch (not just first time)
      if (mounted) setState(() => _statusText = 'Memeriksa Bluetooth...');
      final btStatus = await _lockdownService.checkBluetooth();
      if (btStatus.enabled) {
        await _lockdownService.openBluetoothSettings();
        // Wait for user to turn off, re-check periodically (max 20s)
        for (int i = 0; i < 10; i++) {
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          final recheck = await _lockdownService.checkBluetooth();
          if (!recheck.enabled) break;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _statusText = 'Siap!';
      _loading = false;
    });

    // Announcement
    if (resolvedConfig.announcement != null &&
        resolvedConfig.announcement!.isNotEmpty) {
      if (!mounted) return;
      await _showAnnouncement(resolvedConfig);
    }

    // Navigate
    if (!mounted) return;
    if (resolvedConfig.appPassword != null &&
        resolvedConfig.appPassword!.isNotEmpty) {
      Navigator.pushReplacementNamed(context, '/password');
    } else {
      Navigator.pushReplacementNamed(context, '/exam');
    }
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _loading = true;
      _statusText = 'Memuat...';
      _errorMessage = '';
    });
    _init();
  }

  Future<void> _showAnnouncement(ExamConfig config) async {
    if (!mounted) return;

    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, secondAnim, child) {
        final curvedAnim = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutBack,
        );
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(
            opacity: anim.value,
            child: Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              elevation: 20,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 380),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white, Color(0xFFFFF8E1)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.orange.shade300,
                              Colors.deepOrange.shade400,
                            ],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.orange.withOpacity(0.4),
                              blurRadius: 20,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.campaign_rounded,
                          color: Colors.white,
                          size: 38,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          colors: [
                            Colors.orange.shade700,
                            Colors.deepOrange.shade600,
                          ],
                        ).createShader(bounds),
                        child: const Text(
                          'Pengumuman',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 40,
                        height: 3,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.orange.shade300,
                              Colors.deepOrange.shade300,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.orange.shade100),
                        ),
                        child: Text(
                          config.announcement!,
                          style: TextStyle(
                            fontSize: 14.5,
                            color: Colors.grey.shade700,
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange.shade600,
                            foregroundColor: Colors.white,
                            elevation: 4,
                            shadowColor: Colors.orange.withOpacity(0.4),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle_outline, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Mengerti',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 3),

              // Shield icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  size: 56,
                  color: Colors.white,
                ),
              ),

              const SizedBox(height: 24),

              // App name
              const Text(
                'ExaManmet',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),

              const SizedBox(height: 6),

              // Subtitle
              Text(
                _appVersion.isNotEmpty
                    ? 'Secure Exam Browser v$_appVersion'
                    : 'Secure Exam Browser',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),

              const Spacer(flex: 2),

              // Loading or error
              if (_hasError) ...[
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.red.shade300.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Colors.red.shade200,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage,
                        style: TextStyle(
                          color: Colors.red.shade100,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _retry,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.red.shade700,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 12,
                          ),
                        ),
                        icon: const Icon(Icons.refresh, size: 20),
                        label: const Text(
                          'Coba Lagi',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _statusText,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.7),
                  ),
                ),
              ],

              const Spacer(flex: 3),

              // Bottom label with version
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    Text(
                      'MAN 1 Metro',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.4),
                      ),
                    ),
                    if (_appVersion.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'v$_appVersion',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white.withOpacity(0.3),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
