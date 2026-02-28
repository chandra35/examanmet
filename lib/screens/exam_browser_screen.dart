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
  Timer? _securityAuditTimer;
  int _violationCount = 0;
  static const int _maxViolations = 5;
  bool _securityWarningShown = false;

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
    _securityAuditTimer?.cancel();
    _lockdownService.onSecurityEvent = null;
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

    // Listen for real-time security events from native
    _lockdownService.onSecurityEvent = _handleSecurityEvent;

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

    // Periodic security audit (check developer options, ADB, accessibility, etc.)
    _securityAuditTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _performSecurityAudit(),
    );
    // Run initial audit after short delay
    Future.delayed(const Duration(seconds: 2), _performSecurityAudit);

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

            // Inject custom styled select dropdowns to replace native Android picker
            await _webController.runJavaScript('''
              (function() {
                if (window.__customSelectInjected) return;
                window.__customSelectInjected = true;

                var style = document.createElement('style');
                style.textContent = \`
                  .csb-overlay {
                    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
                    background: rgba(0,0,0,0.45); z-index: 99998;
                    opacity: 0; transition: opacity 0.25s ease;
                    backdrop-filter: blur(2px); -webkit-backdrop-filter: blur(2px);
                  }
                  .csb-overlay.show { opacity: 1; }
                  .csb-dropdown {
                    position: fixed; left: 50%; top: 50%;
                    transform: translate(-50%, -50%) scale(0.8);
                    width: 88%; max-width: 360px; max-height: 65vh;
                    background: #fff; border-radius: 20px;
                    z-index: 99999; overflow: hidden;
                    box-shadow: 0 20px 60px rgba(0,0,0,0.25);
                    transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1), opacity 0.25s;
                    display: flex; flex-direction: column;
                    opacity: 0;
                  }
                  .csb-dropdown.show { transform: translate(-50%, -50%) scale(1); opacity: 1; }
                  .csb-header {
                    padding: 16px 20px 12px; border-bottom: 1px solid #f0f0f0;
                    display: flex; align-items: center; justify-content: space-between;
                    background: linear-gradient(135deg, #0D47A1, #1565C0);
                    border-radius: 20px 20px 0 0;
                  }
                  .csb-header-title {
                    color: #fff; font-size: 16px; font-weight: 700;
                    letter-spacing: 0.3px;
                  }
                  .csb-header-close {
                    width: 30px; height: 30px; border-radius: 50%;
                    background: rgba(255,255,255,0.2); border: none;
                    color: #fff; font-size: 18px; cursor: pointer;
                    display: flex; align-items: center; justify-content: center;
                  }
                  .csb-options {
                    overflow-y: auto; flex: 1; padding: 8px 0;
                    -webkit-overflow-scrolling: touch;
                  }
                  .csb-option {
                    padding: 14px 20px; cursor: pointer;
                    display: flex; align-items: center; justify-content: space-between;
                    font-size: 15px; color: #333;
                    border-bottom: 1px solid #f5f5f5;
                  }
                  .csb-option:active { background: #e3f2fd; }
                  .csb-option.selected {
                    background: linear-gradient(135deg, #e3f2fd, #bbdefb);
                    color: #0D47A1; font-weight: 600;
                  }
                  .csb-option .csb-check {
                    width: 22px; height: 22px; border-radius: 50%;
                    border: 2px solid #ccc; display: flex;
                    align-items: center; justify-content: center;
                    flex-shrink: 0; margin-left: 12px;
                  }
                  .csb-option.selected .csb-check {
                    border-color: #0D47A1; background: #0D47A1;
                  }
                  .csb-option.selected .csb-check::after {
                    content: ''; width: 6px; height: 10px;
                    border: solid #fff; border-width: 0 2px 2px 0;
                    transform: rotate(45deg); margin-top: -2px;
                  }
                  .csb-handle {
                    width: 40px; height: 4px; background: #ddd;
                    border-radius: 2px; margin: 8px auto 0;
                  }
                  .csb-trigger {
                    display: inline-flex; align-items: center;
                    padding: 8px 14px; background: #fff;
                    border: 2px solid #1565C0; border-radius: 10px;
                    font-size: 14px; color: #0D47A1; font-weight: 500;
                    cursor: pointer; min-width: 100px;
                    box-shadow: 0 2px 6px rgba(13,71,161,0.12);
                    transition: all 0.2s;
                  }
                  .csb-trigger:active {
                    background: #e3f2fd; transform: scale(0.97);
                  }
                  .csb-trigger-text {
                    flex: 1; margin-right: 8px;
                    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
                  }
                  .csb-trigger-arrow {
                    width: 0; height: 0;
                    border-left: 5px solid transparent;
                    border-right: 5px solid transparent;
                    border-top: 6px solid #1565C0;
                    flex-shrink: 0;
                  }
                  select[data-csb-hidden] {
                    position: absolute !important; 
                    opacity: 0 !important; 
                    pointer-events: none !important;
                    width: 0 !important; height: 0 !important;
                    overflow: hidden !important;
                  }
                \`;
                document.head.appendChild(style);

                function openCustomSelect(selectEl, triggerEl) {
                  var overlay = document.createElement('div');
                  overlay.className = 'csb-overlay';
                  var dropdown = document.createElement('div');
                  dropdown.className = 'csb-dropdown';

                  var header = document.createElement('div');
                  header.className = 'csb-header';
                  var htitle = document.createElement('span');
                  htitle.className = 'csb-header-title';
                  htitle.textContent = 'Pilih Jawaban';
                  var closeBtn = document.createElement('button');
                  closeBtn.className = 'csb-header-close';
                  closeBtn.innerHTML = '\\u2715';
                  header.appendChild(htitle);
                  header.appendChild(closeBtn);
                  dropdown.appendChild(header);

                  var optionsDiv = document.createElement('div');
                  optionsDiv.className = 'csb-options';

                  for (var i = 0; i < selectEl.options.length; i++) {
                    (function(idx) {
                      var opt = document.createElement('div');
                      opt.className = 'csb-option' + (selectEl.selectedIndex === idx ? ' selected' : '');
                      var lbl = document.createElement('span');
                      lbl.textContent = selectEl.options[idx].text || '(kosong)';
                      var chk = document.createElement('div');
                      chk.className = 'csb-check';
                      opt.appendChild(lbl);
                      opt.appendChild(chk);
                      opt.addEventListener('click', function() {
                        selectEl.selectedIndex = idx;
                        selectEl.dispatchEvent(new Event('change', {bubbles: true}));
                        if (triggerEl) {
                          triggerEl.querySelector('.csb-trigger-text').textContent = selectEl.options[idx].text;
                        }
                        doClose();
                      });
                      optionsDiv.appendChild(opt);
                    })(i);
                  }
                  dropdown.appendChild(optionsDiv);

                  document.body.appendChild(overlay);
                  document.body.appendChild(dropdown);

                  requestAnimationFrame(function() {
                    overlay.classList.add('show');
                    dropdown.classList.add('show');
                  });

                  function doClose() {
                    overlay.classList.remove('show');
                    dropdown.style.transform = 'translate(-50%, -50%) scale(0.8)';
                    dropdown.style.opacity = '0';
                    setTimeout(function() { overlay.remove(); dropdown.remove(); }, 300);
                  }
                  overlay.addEventListener('click', doClose);
                  closeBtn.addEventListener('click', doClose);
                }

                function replaceSelects() {
                  document.querySelectorAll('select:not([data-csb-hidden])').forEach(function(sel) {
                    sel.setAttribute('data-csb-hidden', '1');

                    var trigger = document.createElement('div');
                    trigger.className = 'csb-trigger';
                    var txt = document.createElement('span');
                    txt.className = 'csb-trigger-text';
                    txt.textContent = sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : 'Pilih...';
                    var arrow = document.createElement('div');
                    arrow.className = 'csb-trigger-arrow';
                    trigger.appendChild(txt);
                    trigger.appendChild(arrow);

                    trigger.addEventListener('click', function(e) {
                      e.preventDefault();
                      e.stopPropagation();
                      openCustomSelect(sel, trigger);
                    });

                    sel.parentNode.insertBefore(trigger, sel.nextSibling);

                    sel.addEventListener('change', function() {
                      txt.textContent = sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : 'Pilih...';
                    });
                  });
                }

                replaceSelects();
                var obs = new MutationObserver(function() { replaceSelects(); });
                obs.observe(document.body, { childList: true, subtree: true });
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

  /// Handle real-time security events from native Android
  void _handleSecurityEvent(String event) {
    if (!mounted) return;
    debugPrint('[SECURITY_EVENT] $event');

    // Increment violation for critical events
    if (event == 'home_pressed' || event == 'recent_pressed' || event == 'multi_window_detected') {
      _violationCount++;
    }
  }

  /// Perform periodic security audit
  Future<void> _performSecurityAudit() async {
    if (!mounted || _config == null) return;

    try {
      final threats = await _lockdownService.getSecurityThreats();

      if (!mounted) return;

      if (threats.hasThreats && !_securityWarningShown) {
        _securityWarningShown = true;
        final descriptions = threats.threatDescriptions;

        _showAnimatedDialog(
          icon: Icons.security_rounded,
          iconColor: Colors.white,
          iconBgColor: Colors.red.shade700,
          title: 'ANCAMAN KEAMANAN!',
          titleColor: Colors.red.shade700,
          message:
              'Terdeteksi potensi kecurangan pada perangkat Anda:\n\n'
              '${descriptions.map((d) => '• $d').join('\n')}\n\n'
              'Silakan nonaktifkan sebelum melanjutkan ujian.\n'
              'Tindakan ini dicatat dan dilaporkan ke pengawas.',
          buttonText: 'Saya Mengerti',
          buttonColor: Colors.red.shade700,
        );

        // Reset flag after 30 seconds to allow re-check
        Future.delayed(const Duration(seconds: 30), () {
          _securityWarningShown = false;
        });
      }
    } catch (e) {
      debugPrint('Security audit error: $e');
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
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF0277BD)],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Pulsing shield icon
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.1),
                    border: Border.all(color: Colors.white.withOpacity(0.2)),
                  ),
                  child: const Icon(Icons.shield_rounded, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Mempersiapkan ujian...',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
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
              Container(
                height: 3,
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1565C0).withOpacity(0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: LinearProgressIndicator(
                  value: _loadingProgress > 0 ? _loadingProgress : null,
                  backgroundColor: Colors.grey.shade100,
                  color: const Color(0xFF1565C0),
                  minHeight: 3,
                ),
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
      height: 52,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF0D47A1)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          // Back button
          if (_canGoBack)
            _toolbarButton(
              icon: Icons.arrow_back_ios_rounded,
              onTap: () => _webController.goBack(),
              tooltip: 'Kembali',
            ),

          // Page title
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                _pageTitle.isNotEmpty ? _pageTitle : _config!.appName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          // Quiz navigation button
          _toolbarButton(
            icon: Icons.grid_view_rounded,
            onTap: _showQuizNavigation,
            tooltip: 'Navigasi Soal',
          ),

          // Reload button
          if (_config!.allowReload)
            _toolbarButton(
              icon: Icons.refresh_rounded,
              onTap: () => _webController.reload(),
              tooltip: 'Muat Ulang',
            ),

          // Lock indicator badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.green.shade700.withOpacity(0.5),
                  Colors.green.shade800.withOpacity(0.4),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.greenAccent.withOpacity(0.3),
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.greenAccent,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.greenAccent.withOpacity(0.6),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                const Text(
                  'EXAM',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),

          // Exit button
          _toolbarButton(
            icon: Icons.power_settings_new_rounded,
            onTap: _showExitDialog,
            tooltip: 'Keluar',
            color: Colors.redAccent.shade100,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    Color color = Colors.white,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.white.withOpacity(0.15),
        highlightColor: Colors.white.withOpacity(0.08),
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 21),
          ),
        ),
      ),
    );
  }

  // ==================== QUIZ NAVIGATION PANEL ====================

  void _showQuizNavigation() {
    _webController.runJavaScript('''
      (function() {
        // Remove old panel if exists
        var old = document.getElementById('csb-nav-overlay');
        if (old) { old.remove(); }
        var oldP = document.getElementById('csb-nav-panel');
        if (oldP) { oldP.remove(); }

        // Find all quiz nav links from Moodle
        var navLinks = document.querySelectorAll('.qn_buttons a, .navbutton a, #quiz-nav-block a, .mod_quiz-nav-block a');
        
        // Fallback: try finding by quiz navigation panel
        if (navLinks.length === 0) {
          navLinks = document.querySelectorAll('[id*="quiznavbutton"] a, .quiznavigation a');
        }
        // Another fallback
        if (navLinks.length === 0) {
          navLinks = document.querySelectorAll('a[href*="attempt.php"][href*="page="]');
        }

        // Also check for "Finish attempt" link
        var finishLink = document.querySelector('a[href*="summary.php"], a[href*="processattempt"], input[value*="Selesaikan"], input[value*="Submit"], a.endtestlink');

        if (navLinks.length === 0 && !finishLink) {
          // No quiz navigation found — notify via a toast
          var toast = document.createElement('div');
          toast.style.cssText = 'position:fixed;bottom:80px;left:50%;transform:translateX(-50%);background:#333;color:#fff;padding:12px 24px;border-radius:25px;font-size:14px;z-index:99999;box-shadow:0 4px 15px rgba(0,0,0,0.3);';
          toast.textContent = 'Navigasi soal tidak ditemukan';
          document.body.appendChild(toast);
          setTimeout(function() { toast.style.opacity = '0'; toast.style.transition = 'opacity 0.3s'; }, 2000);
          setTimeout(function() { toast.remove(); }, 2500);
          return;
        }

        // Create overlay
        var overlay = document.createElement('div');
        overlay.id = 'csb-nav-overlay';
        overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.5);z-index:99998;opacity:0;transition:opacity 0.25s;backdrop-filter:blur(2px);-webkit-backdrop-filter:blur(2px);';

        // Create panel
        var panel = document.createElement('div');
        panel.id = 'csb-nav-panel';
        panel.style.cssText = 'position:fixed;bottom:0;left:50%;transform:translateX(-50%) translateY(100%);width:94%;max-width:420px;max-height:70vh;background:#fff;border-radius:20px 20px 0 0;z-index:99999;box-shadow:0 -8px 30px rgba(0,0,0,0.25);transition:transform 0.35s cubic-bezier(0.34, 1.56, 0.64, 1);display:flex;flex-direction:column;overflow:hidden;';

        // Handle bar
        var handle = document.createElement('div');
        handle.style.cssText = 'width:40px;height:4px;background:#ddd;border-radius:2px;margin:8px auto 0;';
        panel.appendChild(handle);

        // Header
        var header = document.createElement('div');
        header.style.cssText = 'padding:14px 20px 12px;display:flex;align-items:center;justify-content:space-between;background:linear-gradient(135deg,#0D47A1,#1565C0);';
        var htitle = document.createElement('div');
        htitle.style.cssText = 'display:flex;align-items:center;gap:8px;';
        htitle.innerHTML = '<span style="font-size:18px;">\\u2630</span><span style="color:#fff;font-size:16px;font-weight:700;">Navigasi Soal</span>';
        var hcount = document.createElement('span');
        hcount.style.cssText = 'color:rgba(255,255,255,0.8);font-size:13px;background:rgba(255,255,255,0.2);padding:3px 10px;border-radius:12px;';
        hcount.textContent = navLinks.length + ' soal';
        var closeBtn = document.createElement('button');
        closeBtn.style.cssText = 'width:32px;height:32px;border-radius:50%;background:rgba(255,255,255,0.2);border:none;color:#fff;font-size:18px;cursor:pointer;display:flex;align-items:center;justify-content:center;';
        closeBtn.innerHTML = '\\u2715';
        header.appendChild(htitle);
        header.appendChild(hcount);
        header.appendChild(closeBtn);
        panel.appendChild(header);

        // Grid container
        var grid = document.createElement('div');
        grid.style.cssText = 'padding:16px;display:grid;grid-template-columns:repeat(5,1fr);gap:10px;overflow-y:auto;-webkit-overflow-scrolling:touch;flex:1;';

        for (var i = 0; i < navLinks.length; i++) {
          (function(link, idx) {
            var btn = document.createElement('div');
            var num = link.textContent.trim() || (idx + 1);
            
            // Detect state from Moodle classes
            var isCurrentPage = link.classList.contains('thispage') || link.getAttribute('aria-current') === 'true' || link.closest('.thispage');
            var isAnswered = link.classList.contains('answersaved') || link.classList.contains('complete') || link.querySelector('.answersaved, .complete');
            var isFlagged = link.classList.contains('flagged') || link.querySelector('.flagged');
            
            var bg = '#f5f5f5'; var color = '#666'; var border = '#e0e0e0'; var shadow = 'none';
            if (isCurrentPage) {
              bg = 'linear-gradient(135deg,#0D47A1,#1565C0)'; color = '#fff'; border = '#0D47A1'; shadow = '0 3px 10px rgba(13,71,161,0.35)';
            } else if (isAnswered) {
              bg = 'linear-gradient(135deg,#e8f5e9,#c8e6c9)'; color = '#2e7d32'; border = '#81c784';
            }
            
            btn.style.cssText = 'width:100%;aspect-ratio:1;display:flex;flex-direction:column;align-items:center;justify-content:center;border-radius:12px;background:' + bg + ';color:' + color + ';font-size:16px;font-weight:600;cursor:pointer;border:2px solid ' + border + ';box-shadow:' + shadow + ';position:relative;transition:transform 0.15s;';
            btn.textContent = num;
            
            // Flag indicator  
            if (isFlagged) {
              var flag = document.createElement('div');
              flag.style.cssText = 'position:absolute;top:3px;right:3px;width:8px;height:8px;background:#f44336;border-radius:50%;box-shadow:0 0 4px rgba(244,67,54,0.5);';
              btn.appendChild(flag);
            }

            btn.addEventListener('click', function() {
              link.click();
              doClose();
            });
            btn.addEventListener('touchstart', function() { btn.style.transform = 'scale(0.92)'; });
            btn.addEventListener('touchend', function() { btn.style.transform = 'scale(1)'; });
            grid.appendChild(btn);
          })(navLinks[i], i);
        }
        panel.appendChild(grid);

        // Finish button if found
        if (finishLink) {
          var finishDiv = document.createElement('div');
          finishDiv.style.cssText = 'padding:12px 16px 16px;border-top:1px solid #f0f0f0;';
          var finishBtn = document.createElement('div');
          finishBtn.style.cssText = 'width:100%;padding:14px;background:linear-gradient(135deg,#e53935,#c62828);color:#fff;border-radius:14px;text-align:center;font-size:15px;font-weight:700;cursor:pointer;box-shadow:0 4px 12px rgba(229,57,53,0.3);letter-spacing:0.5px;';
          finishBtn.textContent = 'Selesaikan Kuis';
          finishBtn.addEventListener('click', function() {
            if (finishLink.tagName === 'INPUT') { finishLink.click(); }
            else { finishLink.click(); }
            doClose();
          });
          finishDiv.appendChild(finishBtn);
          panel.appendChild(finishDiv);
        }

        document.body.appendChild(overlay);
        document.body.appendChild(panel);

        requestAnimationFrame(function() {
          overlay.style.opacity = '1';
          panel.style.transform = 'translateX(-50%) translateY(0)';
        });

        function doClose() {
          overlay.style.opacity = '0';
          panel.style.transform = 'translateX(-50%) translateY(100%)';
          setTimeout(function() { overlay.remove(); panel.remove(); }, 300);
        }
        overlay.addEventListener('click', doClose);
        closeBtn.addEventListener('click', doClose);
      })();
    ''');
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
              elevation: 20,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 360),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: Colors.white,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Gradient Icon Circle with glow
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [iconBgColor, iconBgColor.withOpacity(0.7)],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: iconBgColor.withOpacity(0.4),
                              blurRadius: 20,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: Icon(icon, color: iconColor, size: 38),
                      ),
                      const SizedBox(height: 20),
                      // Title
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: titleColor ?? Colors.grey.shade800,
                          letterSpacing: 0.3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      // Decorative line
                      Container(
                        width: 36,
                        height: 3,
                        decoration: BoxDecoration(
                          color: buttonColor.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Message in subtle container
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          message,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Button with gradient effect
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: buttonColor,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 4,
                            shadowColor: buttonColor.withOpacity(0.4),
                          ),
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(
                            buttonText,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
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
              elevation: 20,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 360),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: Colors.white,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Gradient Icon Circle with glow
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [iconBgColor, iconBgColor.withOpacity(0.7)],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: iconBgColor.withOpacity(0.4),
                              blurRadius: 20,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: Icon(icon, color: iconColor, size: 38),
                      ),
                      const SizedBox(height: 20),
                      // Title
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade800,
                          letterSpacing: 0.3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: 36,
                        height: 3,
                        decoration: BoxDecoration(
                          color: confirmColor.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Message in subtle container
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          message,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Buttons Row
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 50,
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
                              height: 50,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: confirmColor,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  elevation: 4,
                                  shadowColor: confirmColor.withOpacity(0.4),
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
          ),
        );
      },
    );
  }
}
