import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/config_service.dart';
import '../services/lockdown_service.dart';
import '../services/notification_service.dart';
import '../models/exam_config.dart';

class ExamBrowserScreen extends StatefulWidget {
  const ExamBrowserScreen({super.key});

  @override
  State<ExamBrowserScreen> createState() => _ExamBrowserScreenState();
}

class _ExamBrowserScreenState extends State<ExamBrowserScreen>
    with WidgetsBindingObserver {
  late WebViewController _webController;
  final ConfigService _configService = ConfigService();
  final LockdownService _lockdownService = LockdownService();
  final NotificationService _notifService = NotificationService();

  ExamConfig? _config;
  bool _isLoading = true;
  bool _isPageLoading = true;
  double _loadingProgress = 0;
  String _pageTitle = '';
  bool _canGoBack = false;
  Timer? _clipboardTimer;
  Timer? _floatingCheckTimer;
  Timer? _immersiveTimer;
  Timer? _configRefreshTimer;
  Timer? _notifCheckTimer;
  int _violationCount = 0;
  static const int _maxViolations = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initExam();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardTimer?.cancel();
    _floatingCheckTimer?.cancel();
    _immersiveTimer?.cancel();
    _configRefreshTimer?.cancel();
    _notifCheckTimer?.cancel();
    _lockdownService.disableLockdown();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      // Only count as violation when app is fully paused (user switched away)
      // Do NOT count 'inactive' — it triggers on WebView dropdowns, popups,
      // system dialogs, and Moodle matching question answer selectors
      _violationCount++;
    } else if (state == AppLifecycleState.resumed) {
      // Re-enable lockdown when coming back
      _lockdownService.enableLockdown();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _checkForFloatingApps();

      // Show violation warning if user actually left the app
      if (_violationCount > 0) {
        _showViolationWarning();
      }
    }
  }

  Future<void> _initExam() async {
    // Fetch config
    final config = await _configService.fetchConfig();

    setState(() {
      _config = config;
    });

    // Initialize lockdown
    _lockdownService.initialize(config);
    await _lockdownService.enableLockdown();

    // Keep screen awake
    await WakelockPlus.enable();

    // Setup WebView
    _setupWebView(config);

    // Start clipboard clearing timer
    if (!config.allowClipboard) {
      _clipboardTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _lockdownService.disableClipboard(),
      );
    }

    // Start floating app checker
    if (Platform.isAndroid) {
      _floatingCheckTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _checkForFloatingApps(),
      );
    }

    // Periodically re-apply immersive mode from Flutter side (extra hardening)
    _immersiveTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );

    // Periodically refresh config from server (keep passwords/settings in sync)
    _configRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _refreshConfig(),
    );

    // Check for admin notifications every 30 seconds while app is open
    _notifCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkNotifications(),
    );
    // Also check immediately
    _checkNotifications();

    setState(() => _isLoading = false);
  }

  /// Refresh config from server silently to keep passwords and settings in sync
  Future<void> _refreshConfig() async {
    try {
      final latestConfig = await _configService.fetchConfig();
      if (mounted) {
        setState(() => _config = latestConfig);
      }
    } catch (_) {
      // Silently ignore - use existing config
    }
  }

  /// Poll server for new admin notifications and display them
  Future<void> _checkNotifications() async {
    try {
      final notifications = await _notifService.checkForNotifications();
      if (!mounted || notifications.isEmpty) return;

      // Show in-app dialog for urgent notifications
      for (final notif in notifications) {
        if (notif['type'] == 'urgent' && mounted) {
          _showUrgentNotificationDialog(
            notif['title'] ?? 'Pemberitahuan',
            notif['message'] ?? '',
          );
        }
      }
    } catch (_) {
      // Silently ignore notification errors
    }
  }

  /// Show a blocking dialog for urgent admin notifications
  void _showUrgentNotificationDialog(String title, String message) {
    _showAnimatedDialog(
      icon: Icons.notification_important_rounded,
      iconColor: Colors.red,
      iconBgColor: Colors.red.shade50,
      title: title,
      message: message,
      buttonText: 'Mengerti',
      buttonColor: Colors.red,
    );
  }

  void _setupWebView(ExamConfig config) {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(config.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() => _isPageLoading = true);
          },
          onProgress: (progress) {
            setState(() => _loadingProgress = progress / 100);
          },
          onPageFinished: (url) async {
            setState(() => _isPageLoading = false);

            // Get page title
            final title = await _webController.getTitle();
            setState(() => _pageTitle = title ?? '');

            // Check if can go back
            final canGoBack = await _webController.canGoBack();
            setState(() => _canGoBack = canGoBack);

            // Inject custom CSS
            if (config.customCss != null && config.customCss!.isNotEmpty) {
              await _webController.runJavaScript('''
                var style = document.createElement('style');
                style.textContent = `${config.customCss}`;
                document.head.appendChild(style);
              ''');
            }

            // Inject custom JS
            if (config.customJs != null && config.customJs!.isNotEmpty) {
              await _webController.runJavaScript(config.customJs!);
            }

            // Inject anti-copy/paste CSS if clipboard is disabled
            if (!config.allowClipboard) {
              await _webController.runJavaScript('''
                var antiCopyStyle = document.createElement('style');
                antiCopyStyle.textContent = `
                  * {
                    -webkit-user-select: none !important;
                    -moz-user-select: none !important;
                    -ms-user-select: none !important;
                    user-select: none !important;
                  }
                  input, textarea {
                    -webkit-user-select: text !important;
                    user-select: text !important;
                  }
                `;
                document.head.appendChild(antiCopyStyle);
                
                document.addEventListener('copy', function(e) { e.preventDefault(); });
                document.addEventListener('cut', function(e) { e.preventDefault(); });
                document.addEventListener('contextmenu', function(e) { e.preventDefault(); });
              ''');
            }

            // Inject SEB headers for Moodle compatibility
            if (config.sebConfigKey != null &&
                config.sebConfigKey!.isNotEmpty) {
              await _webController.runJavaScript('''
                // Set SEB headers for Moodle Safe Exam Browser validation
                if (typeof window.__sebConfigKey === 'undefined') {
                  window.__sebConfigKey = '${config.sebConfigKey}';
                }
              ''');
            }

            // Convert all sebs:// and seb:// links to https:// so they work in WebView
            // Moodle "Launch Safe Exam Browser" button uses sebs:// which WebView can't handle natively
            await _webController.runJavaScript('''
              (function() {
                // Convert all anchor hrefs with seb/sebs protocol
                document.querySelectorAll('a[href^="sebs://"], a[href^="seb://"]').forEach(function(link) {
                  var href = link.getAttribute('href');
                  if (href.startsWith('sebs://')) {
                    link.setAttribute('href', href.replace('sebs://', 'https://'));
                  } else if (href.startsWith('seb://')) {
                    link.setAttribute('href', href.replace('seb://', 'http://'));
                  }
                });
                
                // Also intercept any dynamically created seb links via click handler
                document.addEventListener('click', function(e) {
                  var target = e.target.closest('a');
                  if (target) {
                    var href = target.getAttribute('href') || '';
                    if (href.startsWith('sebs://')) {
                      e.preventDefault();
                      e.stopPropagation();
                      window.location.href = href.replace('sebs://', 'https://');
                    } else if (href.startsWith('seb://')) {
                      e.preventDefault();
                      e.stopPropagation();
                      window.location.href = href.replace('seb://', 'http://');
                    }
                  }
                }, true);
                
                // Handle window.location assignments and form actions with seb protocol
                document.querySelectorAll('form[action^="sebs://"], form[action^="seb://"]').forEach(function(form) {
                  var action = form.getAttribute('action');
                  if (action.startsWith('sebs://')) {
                    form.setAttribute('action', action.replace('sebs://', 'https://'));
                  } else if (action.startsWith('seb://')) {
                    form.setAttribute('action', action.replace('seb://', 'http://'));
                  }
                });
              })();
            ''');
          },
          onNavigationRequest: (request) {
            final url = request.url;

            // Handle SEB protocol URLs — convert sebs:// to https:// and seb:// to http://
            if (url.startsWith('sebs://')) {
              final httpsUrl = url.replaceFirst('sebs://', 'https://');
              _webController.loadRequest(Uri.parse(httpsUrl));
              return NavigationDecision.prevent;
            }
            if (url.startsWith('seb://')) {
              final httpUrl = url.replaceFirst('seb://', 'http://');
              _webController.loadRequest(Uri.parse(httpUrl));
              return NavigationDecision.prevent;
            }

            // Block navigation to non-allowed URLs
            if (!config.isUrlAllowed(url)) {
              _showBlockedUrlDialog(url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(config.moodleUrl));
  }

  void _showViolationWarning() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_violationCount >= _maxViolations) {
        _showAnimatedDialog(
          icon: Icons.gpp_bad_rounded,
          iconColor: Colors.white,
          iconBgColor: Colors.red,
          title: 'PELANGGARAN BERAT!',
          titleColor: Colors.red,
          message:
              'Anda telah mencoba keluar dari aplikasi ujian sebanyak $_violationCount kali.\n\n'
              'Tindakan ini telah dicatat dan akan dilaporkan ke pengawas ujian.\n\n'
              'Jika terus melanggar, ujian Anda dapat dibatalkan.',
          buttonText: 'Saya Mengerti',
          buttonColor: Colors.red,
        );
      } else {
        _showAnimatedDialog(
          icon: Icons.warning_amber_rounded,
          iconColor: Colors.white,
          iconBgColor: Colors.orange,
          title: 'PERINGATAN!',
          titleColor: Colors.orange.shade800,
          message:
              'Terdeteksi percobaan keluar dari aplikasi ujian!\n\n'
              'Pelanggaran: $_violationCount dari $_maxViolations\n\n'
              'Anda TIDAK diperbolehkan membuka aplikasi lain selama ujian berlangsung.',
          buttonText: 'Kembali ke Ujian',
          buttonColor: Colors.orange.shade700,
        );
      }
    });
  }

  Future<void> _checkForFloatingApps() async {
    if (!mounted || _config == null) return;

    final hasFloating = await _lockdownService.hasFloatingApps();
    if (hasFloating && mounted) {
      _showAnimatedDialog(
        icon: Icons.layers_clear_rounded,
        iconColor: Colors.white,
        iconBgColor: Colors.deepOrange,
        title: 'Aplikasi Overlay Terdeteksi',
        titleColor: Colors.deepOrange,
        message:
            'Terdeteksi aplikasi floating/overlay yang sedang berjalan.\n\n'
            'Silakan tutup semua aplikasi floating untuk melanjutkan ujian.',
        buttonText: 'Mengerti',
        buttonColor: Colors.deepOrange,
      );
    }
  }

  void _showBlockedUrlDialog(String url) {
    _showAnimatedDialog(
      icon: Icons.block_rounded,
      iconColor: Colors.white,
      iconBgColor: Colors.red.shade400,
      title: 'URL Diblokir',
      titleColor: Colors.red,
      message:
          'Anda tidak diperbolehkan mengakses:\n$url\n\n'
          'Hanya halaman Moodle ujian yang diizinkan.',
      buttonText: 'OK',
      buttonColor: Colors.red.shade400,
    );
  }

  void _showExitDialog() async {
    // Always fetch latest config from server to get current exit password
    try {
      final latestConfig = await _configService.fetchConfig();
      _config = latestConfig;
    } catch (_) {
      // Use cached config if server unreachable
    }

    if (!mounted) return;

    if (_config?.exitPassword != null && _config!.exitPassword!.isNotEmpty) {
      Navigator.pushNamed(context, '/exit-password');
    } else {
      _showAnimatedConfirmDialog(
        icon: Icons.exit_to_app_rounded,
        iconColor: Colors.white,
        iconBgColor: Colors.blueGrey,
        title: 'Keluar dari Ujian?',
        message: 'Apakah Anda yakin ingin keluar dari mode ujian?\nPastikan Anda sudah selesai mengerjakan.',
        cancelText: 'Batal',
        confirmText: 'Keluar',
        confirmColor: Colors.red,
        onConfirm: () => _exitExam(),
      );
    }
  }

  Future<void> _exitExam() async {
    await _lockdownService.disableLockdown();
    await WakelockPlus.disable();
    if (mounted) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _config == null) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0D47A1), Color(0xFF1976D2)],
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Mempersiapkan ujian...',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _showExitDialog();
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            // Toolbar (if enabled)
            if (_config!.showToolbar) _buildToolbar(),

            // Loading indicator
            if (_isPageLoading)
              LinearProgressIndicator(
                value: _loadingProgress > 0 ? _loadingProgress : null,
                backgroundColor: Colors.grey.shade200,
                color: const Color(0xFF1565C0),
                minHeight: 3,
              ),

            // WebView
            Expanded(
              child: WebViewWidget(controller: _webController),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF0D47A1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Back button
          if (_canGoBack)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              onPressed: () => _webController.goBack(),
              tooltip: 'Kembali',
            ),

          // Page title
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _pageTitle.isNotEmpty ? _pageTitle : _config!.appName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          // Reload button
          if (_config!.allowReload)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white, size: 20),
              onPressed: () => _webController.reload(),
              tooltip: 'Muat Ulang',
            ),

          // Lock indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock, color: Colors.greenAccent, size: 14),
                SizedBox(width: 4),
                Text(
                  'EXAM',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // Exit button
          IconButton(
            icon: const Icon(Icons.exit_to_app, color: Colors.white70, size: 20),
            onPressed: _showExitDialog,
            tooltip: 'Keluar',
          ),
        ],
      ),
    );
  }

  // ==================== BEAUTIFUL ANIMATED DIALOGS ====================

  /// Show a smooth animated dialog with icon, title, message and single button
  void _showAnimatedDialog({
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required String title,
    required String message,
    required String buttonText,
    required Color buttonColor,
    Color? titleColor,
  }) {
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, secondAnim, child) {
        final curvedAnim = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(
            opacity: anim.value,
            child: Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              elevation: 16,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Animated Icon Circle
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: iconBgColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: iconBgColor.withOpacity(0.3),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(icon, color: iconColor, size: 36),
                    ),
                    const SizedBox(height: 20),
                    // Title
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: titleColor ?? Colors.grey.shade800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    // Message
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Button
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: buttonColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          buttonText,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Show a smooth animated confirm dialog with two buttons
  void _showAnimatedConfirmDialog({
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required String title,
    required String message,
    required String cancelText,
    required String confirmText,
    required Color confirmColor,
    required VoidCallback onConfirm,
  }) {
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, secondAnim, child) {
        final curvedAnim = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(
            opacity: anim.value,
            child: Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              elevation: 16,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon Circle
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: iconBgColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: iconBgColor.withOpacity(0.3),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(icon, color: iconColor, size: 36),
                    ),
                    const SizedBox(height: 20),
                    // Title
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    // Message
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Buttons Row
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.grey.shade600,
                                side: BorderSide(color: Colors.grey.shade300),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () => Navigator.pop(ctx),
                              child: Text(
                                cancelText,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: confirmColor,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                elevation: 2,
                              ),
                              onPressed: () {
                                Navigator.pop(ctx);
                                onConfirm();
                              },
                              child: Text(
                                confirmText,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
