import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/config_service.dart';
import '../services/lockdown_service.dart';
import '../services/notification_service.dart';
import '../services/exam_session_service.dart';
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
  final ExamSessionService _sessionService = ExamSessionService();

  ExamConfig? _config;
  bool _isLoading = true;
  bool _isPageLoading = true;
  double _loadingProgress = 0;
  String _pageTitle = '';
  bool _canGoBack = false;
  bool _canGoForward = false;
  int _pingMs = -1;
  Timer? _pingTimer;
  Timer? _clipboardTimer;
  Timer? _floatingCheckTimer;
  Timer? _immersiveTimer;
  Timer? _configRefreshTimer;
  Timer? _notifCheckTimer;
  Timer? _securityAuditTimer;
  Timer? _bluetoothCheckTimer;
  Timer? _headsetCheckTimer;
  Timer? _killAppsTimer;
  int _violationCount = 0;
  static const int _maxViolations = 5;
  static const int _autoLockThreshold = 3;  // Client-side auto-lock (matches server)
  bool _securityWarningShown = false;
  bool _bluetoothWarningShown = false;
  bool _isExiting = false;  // Prevents lifecycle hooks from fighting exit
  DateTime? _lastNativeViolationTime;  // Debounce to avoid double-counting
  bool _headsetWarningShown = false;
  bool _rootWarningShown = false;
  bool _isRemoteLocked = false;
  String? _remoteLockReason;
  ProtectionLevel _protectionLevel = ProtectionLevel.basic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initExam();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingTimer?.cancel();
    _clipboardTimer?.cancel();
    _floatingCheckTimer?.cancel();
    _immersiveTimer?.cancel();
    _configRefreshTimer?.cancel();
    _notifCheckTimer?.cancel();
    _securityAuditTimer?.cancel();
    _bluetoothCheckTimer?.cancel();
    _headsetCheckTimer?.cancel();
    _killAppsTimer?.cancel();
    _sessionService.dispose();
    _notifService.onLockCommandReceived = null;
    _lockdownService.onSecurityEvent = null;
    _lockdownService.stopAlertSound();
    _lockdownService.disableLockdown();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Don't process lifecycle events during exit
    if (_isExiting) return;

    if (state == AppLifecycleState.paused) {
      // Only count as violation when app is fully paused (user switched away)
      // Do NOT count 'inactive' — it triggers on WebView dropdowns, popups,
      // system dialogs, and Moodle matching question answer selectors
      //
      // Debounce: skip if native side already reported this violation recently
      // (home_pressed/recent_pressed events from onUserLeaveHint/onPause arrive faster)
      final now = DateTime.now();
      if (_lastNativeViolationTime != null &&
          now.difference(_lastNativeViolationTime!).inMilliseconds < 3000) {
        // Native event already reported this — skip to avoid double-counting
        return;
      }
      _violationCount++;
      _sessionService.reportViolation('app_switch', detail: 'App went to background');
      _checkAutoLock();  // Client-side auto-lock check
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

    // Determine protection level (checks OEM, permissions, SDK)
    _protectionLevel = await _lockdownService.determineProtectionLevel();
    debugPrint('[EXAM] Protection level: $_protectionLevel');

    // Enable lockdown (wrapped in try-catch for OEM compatibility)
    try {
      await _lockdownService.enableLockdown();
    } catch (e) {
      debugPrint('Lockdown init error (non-fatal): $e');
    }

    // Listen for real-time security events from native
    _lockdownService.onSecurityEvent = _handleSecurityEvent;

    // Keep screen awake
    await WakelockPlus.enable();

    // Setup WebView
    _setupWebView(config);

    final isFull = _protectionLevel == ProtectionLevel.full;

    // ========================================================
    // LEVEL 1 (ALL DEVICES): Essential protections
    // These are lightweight and safe for all OEMs
    // ========================================================

    // Clipboard clearing
    if (!config.allowClipboard) {
      _clipboardTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _lockdownService.disableClipboard(),
      );
    }

    // Immersive mode re-apply
    _immersiveTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );

    // Config refresh (lightweight network call)
    _configRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _refreshConfig(),
    );

    // Notification check
    _notifCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkNotifications(),
    );
    Future.delayed(const Duration(seconds: 3), _checkNotifications);

    // ========================================================
    // LEVEL 2 (CAPABLE DEVICES ONLY): Aggressive protections
    // Only enabled when device can handle it without OEM kill
    // ========================================================

    if (isFull) {
      // Phase A (after 2s): Security monitors
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;

        // Floating app checker
        if (Platform.isAndroid) {
          _floatingCheckTimer = Timer.periodic(
            const Duration(seconds: 3),
            (_) => _checkForFloatingApps(),
          );
        }

        // Security audit (developer options, ADB, accessibility)
        _securityAuditTimer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => _performSecurityAudit(),
        );
        _performSecurityAudit();
      });

      // Phase B (after 6s): Heavy operations
      Future.delayed(const Duration(seconds: 6), () {
        if (!mounted) return;

        // Kill suspicious background apps
        if (Platform.isAndroid) {
          _lockdownService.killSuspiciousApps();
          _killAppsTimer = Timer.periodic(
            const Duration(seconds: 15),
            (_) => _lockdownService.killSuspiciousApps(),
          );
        }

        // Bluetooth detection
        if (config.detectBluetooth && Platform.isAndroid) {
          _bluetoothCheckTimer = Timer.periodic(
            const Duration(seconds: 8),
            (_) => _checkBluetooth(),
          );
          _checkBluetooth();
        }

        // Headset detection
        if (config.detectHeadset && Platform.isAndroid) {
          _headsetCheckTimer = Timer.periodic(
            const Duration(seconds: 5),
            (_) => _checkHeadset(),
          );
          _checkHeadset();
        }

        // Root detection
        if (config.detectRoot && Platform.isAndroid) {
          _checkRoot();
        }

        // Keyboard check
        if (Platform.isAndroid) {
          _checkKeyboard();
        }
      });
    } else {
      // LEVEL 1: Only lightweight security audit (no kill, no shell exec)
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        // Light audit — only checks developer options & USB debugging
        _securityAuditTimer = Timer.periodic(
          const Duration(seconds: 15),  // Less frequent on basic level
          (_) => _performSecurityAudit(),
        );
      });
    }

    // Ping indicator — measure latency every 5 seconds
    _measurePing();
    _pingTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _measurePing(),
    );

    // Start exam session (server-side tracking + lock/unlock)
    _sessionService.onLockStatusChanged = (isLocked, reason) {
      if (mounted) {
        setState(() {
          _isRemoteLocked = isLocked;
          _remoteLockReason = reason;
        });
      }
    };

    // FCM push lock/unlock — instant delivery even if heartbeat hasn't fired
    _notifService.onLockCommandReceived = (sessionId, isLocked, reason) {
      // Only apply if this FCM targets our session (or no session yet)
      final mySession = _sessionService.sessionId;
      if (mySession != null && sessionId != mySession.toString()) return;
      if (mounted) {
        setState(() {
          _isRemoteLocked = isLocked;
          _remoteLockReason = reason;
        });
      }
    };

    // Report protection level to server
    _sessionService.setProtectionLevel(
      _protectionLevel == ProtectionLevel.full ? 'full' : 'basic',
    );

    await _sessionService.startSession();

    setState(() => _isLoading = false);
  }

  /// Update back/forward navigation state after navigation
  Future<void> _updateNavState() async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final canGoBack = await _webController.canGoBack();
    final canGoForward = await _webController.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
      });
    }
  }

  /// Extract Moodle username (NISN) and fullname from the loaded page via JavaScript
  Future<void> _extractMoodleUser() async {
    try {
      final result = await _webController.runJavaScriptReturningResult('''
        (function() {
          try {
            var username = '';
            var fullname = '';

            // === Priority 1: M.cfg.username (Moodle JS config — most reliable) ===
            // This contains the actual login username (NISN), available on ALL pages when logged in
            if (typeof M !== 'undefined' && M.cfg) {
              if (M.cfg.username && M.cfg.username !== '' && M.cfg.username !== 'guest') {
                username = M.cfg.username;  // This is the NISN
              }
              // M.cfg.fullname available in some Moodle versions
              if (M.cfg.fullname) {
                fullname = M.cfg.fullname;
              }
            }

            // === Priority 2: Get fullname from user menu ===
            if (!fullname) {
              // Moodle 3.x
              var userText = document.querySelector('.usertext');
              if (userText) fullname = userText.textContent.trim();
            }
            if (!fullname) {
              // Moodle 4.x
              var userFullname = document.querySelector('.userfullname');
              if (userFullname) fullname = userFullname.textContent.trim();
            }
            if (!fullname) {
              // Moodle user button
              var menuText = document.querySelector('.userbutton .usertext, .userbutton .userbutton-name');
              if (menuText) fullname = menuText.textContent.trim();
            }

            // === Priority 3: logininfo text (e.g. "Anda login sebagai USERNAME") ===
            if (!username) {
              var loginInfo = document.querySelector('.logininfo');
              if (loginInfo) {
                var loginText = loginInfo.textContent.trim();
                // Pattern: "You are logged in as XXXX" or "Anda login sebagai XXXX"
                var m = loginText.match(/(?:logged in as|login sebagai|masuk sebagai)\\s+(.+)/i);
                if (m) {
                  var extracted = m[1].replace(/[\\(\\)]/g, '').trim();
                  // Remove "Log out" / "Keluar" suffix
                  extracted = extracted.replace(/\\s*(Log out|Keluar|Logout).*\$/i, '').trim();
                  if (extracted) username = extracted;
                }
              }
            }

            // === Priority 4: Login page username field ===
            if (!username) {
              var usernameInput = document.querySelector('#username');
              if (usernameInput && usernameInput.value) {
                username = usernameInput.value;
              }
            }

            // === Priority 5: data-username attribute (some themes) ===
            if (!username) {
              var userEl = document.querySelector('[data-username]');
              if (userEl) username = userEl.getAttribute('data-username');
            }

            if (username || fullname) {
              return JSON.stringify({type: 'moodle_user', fullname: fullname, username: username});
            }

            return JSON.stringify({type: 'no_user'});
          } catch(e) {
            return JSON.stringify({type: 'error', message: e.toString()});
          }
        })()
      ''');

      // Parse result (runJavaScriptReturningResult returns quoted string)
      String jsonStr = result.toString();
      // Remove surrounding quotes if present
      if (jsonStr.startsWith('"') && jsonStr.endsWith('"')) {
        jsonStr = jsonStr.substring(1, jsonStr.length - 1);
      }
      // Unescape
      jsonStr = jsonStr.replaceAll('\\"', '"').replaceAll('\\\\', '\\');

      _handleJsBridgeMessage(jsonStr);
    } catch (e) {
      debugPrint('ExaManmet: Error extracting Moodle user: $e');
    }
  }

  /// Handle messages from JavaScript bridge (ExaManmetBridge channel or JS eval)
  void _handleJsBridgeMessage(String message) {
    try {
      final data = json.decode(message) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';

      switch (type) {
        case 'moodle_user':
          final username = data['username'] as String? ?? '';
          final fullname = data['fullname'] as String? ?? '';
          if (username.isNotEmpty || fullname.isNotEmpty) {
            debugPrint('ExaManmet: Moodle user detected - username: $username, fullname: $fullname');
            _sessionService.updateMoodleUser(
              username.isNotEmpty ? username : null,
              fullname.isNotEmpty ? fullname : null,
            );
          }
          break;
        case 'no_user':
          // No user logged in yet, will retry on next page load
          break;
        case 'error':
          debugPrint('ExaManmet: JS bridge error: ${data['message']}');
          break;
        default:
          debugPrint('ExaManmet: Unknown JS bridge message type: $type');
      }
    } catch (e) {
      debugPrint('ExaManmet: Error handling JS bridge message: $e');
    }
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
    _showWarningBanner(
      icon: Icons.notification_important_rounded,
      color: Colors.red,
      text: '$title: $message',
      durationSeconds: 6,
    );
  }

  void _setupWebView(ExamConfig config) {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(config.userAgent)
      ..addJavaScriptChannel('ExaManmetBridge', onMessageReceived: (message) {
        _handleJsBridgeMessage(message.message);
      })
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

            // Check if can go back/forward
            final canGoBack = await _webController.canGoBack();
            final canGoForward = await _webController.canGoForward();
            setState(() {
              _canGoBack = canGoBack;
              _canGoForward = canGoForward;
            });

            // Extract Moodle username for session tracking
            _extractMoodleUser();

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

            // Restore Moodle navigation elements hidden by SEB mode
            // When SEB user-agent is detected, Moodle hides nav drawer, user menu, logout etc.
            // We force them back visible so students can navigate.
            await _webController.runJavaScript('''
              (function() {
                if (window.__moodleNavRestored) return;
                window.__moodleNavRestored = true;

                var style = document.createElement('style');
                style.textContent = \`
                  /* Force show Moodle elements hidden by SEB mode */
                  #nav-drawer, .drawer, [data-region="drawer"],
                  .usermenu, #user-menu-toggle, .user-menu,
                  .navbar .nav-link[data-toggle="dropdown"],
                  #page-footer, .logininfo,
                  .course-content .activity a,
                  a[href*="logout.php"],
                  .nav-tabs, .breadcrumb,
                  [data-region="drawer-toggle"] {
                    display: block !important;
                    visibility: visible !important;
                    opacity: 1 !important;
                    pointer-events: auto !important;
                  }
                  /* But keep our toolbar area clean */
                  body { padding-top: 0 !important; }
                \`;
                document.head.appendChild(style);

                // Re-enable hidden links and buttons
                document.querySelectorAll('[aria-hidden="true"]').forEach(function(el) {
                  if (el.closest('.usermenu') || el.closest('#nav-drawer') ||
                      el.closest('.drawer') || el.id === 'nav-drawer') {
                    el.setAttribute('aria-hidden', 'false');
                    el.style.display = '';
                    el.style.visibility = 'visible';
                  }
                });

                // Re-enable disabled links
                document.querySelectorAll('.disabled, [disabled]').forEach(function(el) {
                  if (el.tagName === 'A' || el.closest('.usermenu') || el.closest('.breadcrumb')) {
                    el.classList.remove('disabled');
                    el.removeAttribute('disabled');
                    el.style.pointerEvents = 'auto';
                  }
                });
              })();
            ''');

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

    // Play alert sound on violation
    if (_config?.alertSoundOnViolation == true) {
      _lockdownService.playAlertSound();
    }

    // Use lightweight non-blocking banner instead of dialog
    // Dialog blocks the screen and conflicts with bring-to-front / screen pinning
    _showWarningBanner(
      icon: _violationCount >= _maxViolations
          ? Icons.gpp_bad_rounded
          : Icons.warning_amber_rounded,
      color: _violationCount >= _maxViolations ? Colors.red : Colors.orange,
      text: _violationCount >= _maxViolations
          ? 'PELANGGARAN BERAT! ($_violationCount/$_maxViolations) - Dilaporkan ke pengawas'
          : 'Peringatan! Percobaan keluar terdeteksi ($_violationCount/$_maxViolations)',
    );
  }

  Future<void> _checkForFloatingApps() async {
    if (!mounted || _config == null) return;

    final hasFloating = await _lockdownService.hasFloatingApps();
    if (hasFloating && mounted) {
      // Log but don't count as violation — just warn
      _sessionService.reportViolation('floating_app', detail: 'Floating/overlay app detected');
      _showWarningBanner(
        icon: Icons.layers_clear_rounded,
        color: Colors.deepOrange,
        text: 'Aplikasi overlay terdeteksi! Tutup semua aplikasi floating.',
      );
    }
  }

  /// Client-side auto-lock: if violations reach threshold, lock immediately
  /// without waiting for server response. This ensures lock works even when:
  /// - Network is slow/unreliable during rapid app-switch cycles
  /// - Session failed to start (no session_id)
  /// - Server response gets lost
  void _checkAutoLock() {
    if (_isRemoteLocked || !mounted) return;  // Already locked

    if (_violationCount >= _autoLockThreshold) {
      debugPrint('[AUTO-LOCK] Client-side lock triggered: $_violationCount violations >= $_autoLockThreshold threshold');
      setState(() {
        _isRemoteLocked = true;
        _remoteLockReason = 'Otomatis dikunci: $_violationCount pelanggaran terdeteksi';
      });
      // Play alert sound
      if (_config?.alertSoundOnViolation == true) {
        _lockdownService.playAlertSound();
      }
    }
  }

  /// Handle real-time security events from native Android
  void _handleSecurityEvent(String event) {
    if (!mounted || _isExiting) return;
    debugPrint('[SECURITY_EVENT] $event');

    // === VIOLATIONS: Only count actual app exits ===
    // home_pressed = user pressed Home button
    // recent_pressed = user opened Recent Apps
    // multi_window_detected = user opened split screen
    if (event == 'home_pressed' || event == 'recent_pressed' || event == 'multi_window_detected') {
      _violationCount++;
      _lastNativeViolationTime = DateTime.now();
      _sessionService.reportViolation('app_switch', detail: 'Security event: $event');
      _checkAutoLock();
      if (_config?.alertSoundOnViolation == true) {
        _lockdownService.playAlertSound();
      }
    }

    // === NON-VIOLATIONS: Just log, no counter increment ===
    // notification_pulled, system_dialog, screen_off, bluetooth, headset, incoming_call
    // These are informational only — swipe-down, calls, etc. are handled by DND
  }

  /// Perform periodic security audit
  Future<void> _performSecurityAudit() async {
    if (!mounted || _config == null) return;

    try {
      final threats = await _lockdownService.getSecurityThreats();

      if (!mounted) return;

      if (threats.hasThreats && !_securityWarningShown) {
        _securityWarningShown = true;

        // Report each threat type
        if (threats.developerOptionsEnabled) {
          _sessionService.reportViolation('developer_mode', detail: 'Developer options enabled');
        }
        if (threats.usbDebuggingEnabled) {
          _sessionService.reportViolation('usb_debugging', detail: 'USB debugging enabled');
        }

        // Play alert sound
        if (_config?.alertSoundOnViolation == true) {
          _lockdownService.playAlertSound();
        }

        // Show BLOCKING dialog — cannot continue until threats resolved
        await _showBlockingSecurityDialog(threats);
      }
    } catch (e) {
      debugPrint('Security audit error: $e');
    }
  }

  /// Show a blocking security dialog — forces exit from app.
  /// Student must fix device settings and reopen the app.
  Future<void> _showBlockingSecurityDialog(SecurityAuditResult threats) async {
    if (!mounted) return;

    final descriptions = threats.threatDescriptions;
    final instructions = _getThreatFixInstructions(threats);

    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (dialogContext, _, __) {
        return PopScope(
          canPop: false,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            elevation: 20,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 380),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: Colors.white,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Red shield icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.red.shade700, Colors.red.shade400],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.shade700.withOpacity(0.5),
                              blurRadius: 24,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.gpp_bad_rounded, color: Colors.white, size: 44),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'UJIAN DIBLOKIR',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.red.shade700,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 40, height: 3,
                        decoration: BoxDecoration(
                          color: Colors.red.shade200,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Threat list
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Ancaman terdeteksi:',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
                            const SizedBox(height: 8),
                            ...descriptions.map((d) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.dangerous_rounded, size: 16, color: Colors.red.shade600),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(d,
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.red.shade800))),
                                ],
                              ),
                            )),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Instructions
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.help_outline_rounded, size: 16, color: Colors.orange.shade800),
                              const SizedBox(width: 6),
                              Text('Cara memperbaiki:',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.orange.shade800)),
                            ]),
                            const SizedBox(height: 10),
                            Text(instructions,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.6)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      // EXIT button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 4,
                            shadowColor: Colors.red.shade700.withOpacity(0.4),
                          ),
                          onPressed: () => _exitAppDueToSecurity(),
                          icon: const Icon(Icons.exit_to_app_rounded, size: 22),
                          label: const Text('Keluar dari Aplikasi',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Nonaktifkan ancaman di Setelan HP,\nlalu buka kembali aplikasi ini.',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.4),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondAnim, child) {
        final curvedAnim = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(opacity: anim.value, child: child),
        );
      },
    );
  }

  /// Get human-readable fix instructions for each threat type
  String _getThreatFixInstructions(SecurityAuditResult t) {
    final instructions = <String>[];
    if (t.developerOptionsEnabled) {
      instructions.add(
        '🔧 Developer Options:\n'
        '   Setelan → Opsi Pengembang → NONAKTIFKAN toggle di atas');
    }
    if (t.usbDebuggingEnabled) {
      instructions.add(
        '🔌 USB Debugging:\n'
        '   Setelan → Opsi Pengembang → USB Debugging → NONAKTIFKAN');
    }
    if (t.accessibilityServices.isNotEmpty) {
      instructions.add(
        '♿ Accessibility Service:\n'
        '   Setelan → Aksesibilitas → Nonaktifkan: ${t.accessibilityServices.join(", ")}');
    }
    if (t.isMultiWindow) {
      instructions.add('📱 Split Screen: Tutup layar terbagi');
    }
    if (t.isInPiP) {
      instructions.add('🪟 Picture-in-Picture: Tutup jendela PiP');
    }
    if (t.isRooted) {
      instructions.add('⚠️ Perangkat ROOT: Hubungi pengawas ujian');
    }
    return instructions.join('\n\n');
  }

  /// Exit app completely due to security threat
  Future<void> _exitAppDueToSecurity() async {
    _isExiting = true;
    // Stop alert sound
    _lockdownService.stopAlertSound();
    // Disable lockdown so app can exit cleanly
    await _lockdownService.disableLockdown();
    // Force kill the app process — exit(0) is reliable unlike SystemNavigator.pop()
    exit(0);
  }

  /// Reusable blocking exit dialog for security violations (Bluetooth, Headset, etc.)
  Future<void> _showBlockingExitDialog({
    required IconData icon,
    required Color iconColor,
    required List<Color> iconGradient,
    required String title,
    required Color titleColor,
    required String threatDescription,
    required String instructions,
    required String buttonText,
    required Color buttonColor,
  }) async {
    if (!mounted) return;

    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (dialogContext, _, __) {
        return PopScope(
          canPop: false,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            elevation: 20,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 380),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: Colors.white,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: iconGradient,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: iconGradient.first.withOpacity(0.5),
                              blurRadius: 24,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Icon(icon, color: iconColor, size: 44),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          color: titleColor,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 40, height: 3,
                        decoration: BoxDecoration(
                          color: titleColor.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Threat description
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: titleColor.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: titleColor.withOpacity(0.2)),
                        ),
                        child: Text(
                          threatDescription,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade800,
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Instructions
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.help_outline_rounded, size: 16, color: Colors.orange.shade800),
                              const SizedBox(width: 6),
                              Text('Cara memperbaiki:',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.orange.shade800)),
                            ]),
                            const SizedBox(height: 10),
                            Text(instructions,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.6)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      // Exit button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: buttonColor,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 4,
                            shadowColor: buttonColor.withOpacity(0.4),
                          ),
                          onPressed: () => _exitAppDueToSecurity(),
                          icon: const Icon(Icons.exit_to_app_rounded, size: 22),
                          label: Text(buttonText,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Perbaiki masalah di atas, lalu buka kembali aplikasi ini.',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.4),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondAnim, child) {
        final curvedAnim = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(opacity: anim.value, child: child),
        );
      },
    );
  }

  void _showBlockedUrlDialog(String url) {
    _showWarningBanner(
      icon: Icons.block_rounded,
      color: Colors.red.shade400,
      text: 'URL diblokir: hanya halaman Moodle ujian yang diizinkan.',
    );
  }

  // ==================== Bluetooth Detection ====================

  Future<void> _checkBluetooth() async {
    if (!mounted || _config == null || !_config!.detectBluetooth) return;

    final btStatus = await _lockdownService.checkBluetooth();
    if (!mounted) return;

    if (btStatus.enabled && !_bluetoothWarningShown) {
      _bluetoothWarningShown = true;
      _sessionService.reportViolation('bluetooth', detail: 'Bluetooth active, devices: ${btStatus.connectedDevices.join(", ")}');

      // Play alert sound
      if (_config?.alertSoundOnViolation == true) {
        _lockdownService.playAlertSound();
      }

      final deviceInfo = btStatus.connectedDevices.isNotEmpty
          ? btStatus.connectedDevices.map((d) => '• $d').join('\n')
          : 'Tidak ada perangkat terpasang';

      await _showBlockingExitDialog(
        icon: Icons.bluetooth_rounded,
        iconColor: Colors.white,
        iconGradient: [Colors.blue.shade700, Colors.blue.shade400],
        title: 'BLUETOOTH AKTIF!',
        titleColor: Colors.blue.shade700,
        threatDescription: 'Bluetooth pada perangkat Anda dalam keadaan AKTIF!\n\n'
            'Perangkat Bluetooth terdeteksi:\n$deviceInfo\n\n'
            'Penggunaan earpiece/headset Bluetooth saat ujian '
            'dianggap sebagai KECURANGAN.',
        instructions: '1. Buka Setelan (Settings)\n'
            '2. Buka menu Bluetooth\n'
            '3. Matikan toggle Bluetooth\n'
            '4. Buka kembali aplikasi ini',
        buttonText: 'Keluar & Matikan Bluetooth',
        buttonColor: Colors.blue.shade700,
      );
    }
  }

  // ==================== Headset Detection ====================

  Future<void> _checkHeadset() async {
    if (!mounted || _config == null || !_config!.detectHeadset) return;

    final connected = await _lockdownService.isHeadsetConnected();
    if (!mounted) return;

    if (connected && !_headsetWarningShown) {
      _headsetWarningShown = true;
      _sessionService.reportViolation('headset', detail: 'Headset/earphone connected');

      // Play alert sound
      if (_config?.alertSoundOnViolation == true) {
        _lockdownService.playAlertSound();
      }

      await _showBlockingExitDialog(
        icon: Icons.headset_rounded,
        iconColor: Colors.white,
        iconGradient: [Colors.purple.shade700, Colors.purple.shade400],
        title: 'HEADSET TERDETEKSI!',
        titleColor: Colors.purple.shade700,
        threatDescription: 'Terdeteksi headset/earphone terhubung ke perangkat Anda!\n\n'
            'Penggunaan headset/earphone saat ujian berlangsung '
            'TIDAK DIPERBOLEHKAN.',
        instructions: '1. Cabut/lepaskan headset/earphone dari HP\n'
            '2. Jika wireless, matikan Bluetooth\n'
            '3. Buka kembali aplikasi ini',
        buttonText: 'Keluar & Lepas Headset',
        buttonColor: Colors.purple.shade700,
      );
    }
  }

  // ==================== Root Detection ====================

  Future<void> _checkRoot() async {
    if (!mounted || _config == null || !_config!.detectRoot) return;

    final rooted = await _lockdownService.isDeviceRooted();
    if (!mounted) return;

    if (rooted && !_rootWarningShown) {
      _rootWarningShown = true;
      _sessionService.reportViolation('root_detected', detail: 'Rooted device detected');

      // Play alert sound for rooted device
      if (_config?.alertSoundOnViolation == true) {
        _lockdownService.playAlertSound();
      }

      _showWarningBanner(
        icon: Icons.warning_rounded,
        color: Colors.red.shade900,
        text: 'Perangkat di-ROOT terdeteksi! Dilaporkan ke pengawas.',
        durationSeconds: 6,
      );
    }
  }

  // ==================== Ping Indicator ====================

  Future<void> _measurePing() async {
    if (!mounted) return;
    try {
      final stopwatch = Stopwatch()..start();
      final socket = await Socket.connect('8.8.8.8', 53,
          timeout: const Duration(seconds: 3));
      stopwatch.stop();
      socket.destroy();
      if (mounted) {
        setState(() => _pingMs = stopwatch.elapsedMilliseconds);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _pingMs = -1);
      }
    }
  }

  // ==================== Keyboard (IME) Check ====================

  Future<void> _checkKeyboard() async {
    if (!mounted) return;

    final kb = await _lockdownService.checkKeyboard();
    if (!mounted) return;

    if (kb.isAdware) {
      _sessionService.reportViolation('adware_keyboard', detail: 'Adware keyboard detected: ${kb.keyboardName}');

      // Play alert sound
      if (_config?.alertSoundOnViolation == true) {
        _lockdownService.playAlertSound();
      }

      // Show blocking dialog — must change keyboard or exit
      await _showBlockingKeyboardDialog(kb);
    }
  }

  Future<void> _showBlockingKeyboardDialog(KeyboardCheckResult kb) async {
    if (!mounted) return;

    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (dialogContext, _, __) {
        return PopScope(
          canPop: false,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            elevation: 20,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 380),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: Colors.white,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Keyboard warning icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.orange.shade700, Colors.orange.shade400],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.orange.shade700.withOpacity(0.5),
                              blurRadius: 24,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.keyboard_alt_outlined, color: Colors.white, size: 44),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'KEYBOARD BERMASALAH!',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Colors.orange.shade800,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 40, height: 3,
                        decoration: BoxDecoration(
                          color: Colors.orange.shade200,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Info
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Keyboard aktif saat ini:',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              kb.keyboardName,
                              style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700,
                                color: Colors.orange.shade900,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Keyboard ini diketahui mengandung IKLAN yang dapat '
                              'muncul tiba-tiba dan mengganggu jalannya ujian.\n\n'
                              'Ganti ke keyboard yang aman (Gboard) sebelum melanjutkan.',
                              style: TextStyle(
                                fontSize: 13, color: Colors.grey.shade700, height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Instructions
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.help_outline_rounded, size: 16, color: Colors.blue.shade700),
                              const SizedBox(width: 6),
                              Text('Cara mengganti keyboard:',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.blue.shade700)),
                            ]),
                            const SizedBox(height: 10),
                            Text(
                              '1. Buka Setelan (Settings)\n'
                              '2. Cari "Bahasa & Input" atau "Keyboard"\n'
                              '3. Pilih "Keyboard Default"\n'
                              '4. Ganti ke Gboard atau keyboard bawaan HP\n'
                              '5. Buka kembali aplikasi ini',
                              style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade800, height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      // Exit button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 4,
                            shadowColor: Colors.orange.shade700.withOpacity(0.4),
                          ),
                          onPressed: () => _exitAppDueToSecurity(),
                          icon: const Icon(Icons.exit_to_app_rounded, size: 22),
                          label: const Text('Keluar & Ganti Keyboard',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Ganti keyboard di Setelan HP,\nlalu buka kembali aplikasi ini.',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.4),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondAnim, child) {
        final curvedAnim = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(opacity: anim.value, child: child),
        );
      },
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
    _isExiting = true;
    await _sessionService.endSession();
    await _lockdownService.disableLockdown();
    await WakelockPlus.disable();
    // Force kill the app process — exit(0) is reliable unlike SystemNavigator.pop()
    exit(0);
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
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Column(
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

              // Remote lock overlay
              if (_isRemoteLocked) _buildLockOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// Show dialog for supervisor password unlock (offline fallback)
  void _showSupervisorPasswordDialog() {
    final controller = TextEditingController();
    String? errorText;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1B1B2F),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.vpn_key_rounded, color: Colors.amber.shade300, size: 22),
                  const SizedBox(width: 10),
                  const Text(
                    'Password Pengawas',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Masukkan password pengawas untuk membuka kunci ujian.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    obscureText: true,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Password',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      errorText: errorText,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.amber.shade300),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.red),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.red),
                      ),
                    ),
                    onSubmitted: (_) {
                      // Allow submit with Enter key
                      _verifySupervisorPassword(controller.text, ctx, setDialogState, (msg) {
                        errorText = msg;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('Batal', style: TextStyle(color: Colors.white.withOpacity(0.5))),
                ),
                ElevatedButton(
                  onPressed: () {
                    _verifySupervisorPassword(controller.text, ctx, setDialogState, (msg) {
                      errorText = msg;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Unlock'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Verify entered password against cached supervisor password
  void _verifySupervisorPassword(
    String entered,
    BuildContext dialogContext,
    void Function(void Function()) setDialogState,
    void Function(String?) setError,
  ) {
    final correctPassword = _config?.supervisorPassword;
    if (correctPassword == null || correctPassword.isEmpty) {
      setDialogState(() => setError('Password pengawas belum dikonfigurasi'));
      return;
    }
    if (entered.isEmpty) {
      setDialogState(() => setError('Password tidak boleh kosong'));
      return;
    }
    if (entered == correctPassword) {
      // Password correct — unlock
      Navigator.of(dialogContext).pop();
      setState(() {
        _isRemoteLocked = false;
        _remoteLockReason = null;
      });
      // Report the supervisor unlock as a violation note so admin knows
      _sessionService.reportViolation(
        'supervisor_unlock',
        detail: 'Ujian di-unlock oleh pengawas menggunakan password offline',
      );
    } else {
      setDialogState(() => setError('Password salah'));
    }
  }

  /// Build the full-screen lock overlay shown when admin locks this session
  Widget _buildLockOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xEE1B1B2F),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Lock icon with animated ring
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.withOpacity(0.15),
                    border: Border.all(color: Colors.red.withOpacity(0.4), width: 3),
                  ),
                  child: const Icon(Icons.lock_rounded, color: Colors.red, size: 52),
                ),
                const SizedBox(height: 28),
                const Text(
                  'UJIAN ANDA DIKUNCI',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                if (_remoteLockReason != null && _remoteLockReason!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Text(
                      _remoteLockReason!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber.shade300, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Hubungi pengawas untuk membuka kunci',
                      style: TextStyle(
                        color: Colors.amber.shade300,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Offline password unlock button
                if (_config?.supervisorPassword != null &&
                    _config!.supervisorPassword!.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _showSupervisorPasswordDialog,
                    icon: const Icon(Icons.vpn_key_rounded, size: 18),
                    label: const Text('Unlock dengan Password Pengawas'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.amber.shade300,
                      side: BorderSide(color: Colors.amber.shade300.withOpacity(0.5)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                const SizedBox(height: 28),
                // Subtle pulsing indicator
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Menunggu pengawas...',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    // Ping color coding
    Color pingColor;
    String pingText;
    if (_pingMs < 0) {
      pingColor = Colors.redAccent;
      pingText = '---';
    } else if (_pingMs < 80) {
      pingColor = Colors.greenAccent;
      pingText = '${_pingMs}ms';
    } else if (_pingMs < 200) {
      pingColor = Colors.orangeAccent;
      pingText = '${_pingMs}ms';
    } else {
      pingColor = Colors.redAccent;
      pingText = '${_pingMs}ms';
    }

    return Container(
      height: 48,
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
          const SizedBox(width: 2),

          // Back button
          _toolbarButton(
            icon: Icons.arrow_back_rounded,
            onTap: _canGoBack ? () async {
              await _webController.goBack();
              _updateNavState();
            } : null,
            tooltip: 'Kembali',
            enabled: _canGoBack,
          ),

          // Forward button
          _toolbarButton(
            icon: Icons.arrow_forward_rounded,
            onTap: _canGoForward ? () async {
              await _webController.goForward();
              _updateNavState();
            } : null,
            tooltip: 'Maju',
            enabled: _canGoForward,
          ),

          // Reload button
          if (_config!.allowReload)
            _toolbarButton(
              icon: Icons.refresh_rounded,
              onTap: () => _webController.reload(),
              tooltip: 'Muat Ulang',
            ),

          // Ping indicator
          GestureDetector(
            onTap: _measurePing,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: pingColor,
                      boxShadow: [
                        BoxShadow(
                          color: pingColor.withOpacity(0.6),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    pingText,
                    style: TextStyle(
                      color: pingColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),

          const Spacer(),

          // EXAM lock badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  width: 6,
                  height: 6,
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

          const SizedBox(width: 4),

          // Moodle menu button (Dashboard, Kursusku, Logout)
          _toolbarButton(
            icon: Icons.menu_rounded,
            onTap: _showMoodleMenu,
            tooltip: 'Menu Moodle',
          ),

          // Quiz navigation button
          _toolbarButton(
            icon: Icons.grid_view_rounded,
            onTap: _showQuizNavigation,
            tooltip: 'Navigasi Soal',
          ),

          // Exit button
          _toolbarButton(
            icon: Icons.power_settings_new_rounded,
            onTap: _showExitDialog,
            tooltip: 'Keluar',
            color: Colors.redAccent.shade100,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    VoidCallback? onTap,
    required String tooltip,
    Color color = Colors.white,
    bool enabled = true,
  }) {
    final effectiveColor = enabled ? color : color.withOpacity(0.3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.white.withOpacity(0.15),
        highlightColor: Colors.white.withOpacity(0.08),
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            child: Icon(icon, color: effectiveColor, size: 20),
          ),
        ),
      ),
    );
  }

  // ==================== MOODLE MENU (Dashboard, Kursusku, Logout) ====================

  void _showMoodleMenu() {
    final moodleUrl = _config!.moodleUrl.replaceAll(RegExp(r'/+$'), '');

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.blue.shade800, Colors.blue.shade600],
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.school_rounded, color: Colors.white, size: 22),
                  SizedBox(width: 10),
                  Text('Menu Moodle',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            // Menu items
            _moodleMenuItem(
              icon: Icons.dashboard_rounded,
              color: Colors.blue.shade700,
              title: 'Dashboard',
              subtitle: 'Halaman utama e-learning',
              onTap: () {
                Navigator.pop(ctx);
                _webController.loadRequest(Uri.parse('$moodleUrl/my/'));
              },
            ),
            _moodleMenuItem(
              icon: Icons.book_rounded,
              color: Colors.green.shade700,
              title: 'Kursusku',
              subtitle: 'Daftar kursus yang diikuti',
              onTap: () {
                Navigator.pop(ctx);
                _webController.loadRequest(Uri.parse('$moodleUrl/my/courses.php'));
              },
            ),
            _moodleMenuItem(
              icon: Icons.person_rounded,
              color: Colors.orange.shade700,
              title: 'Profil',
              subtitle: 'Lihat profil pengguna',
              onTap: () {
                Navigator.pop(ctx);
                _webController.runJavaScript('''
                  (function() {
                    var profileLink = document.querySelector('a[href*="/user/profile.php"], a[data-title="profile,moodle"]');
                    if (profileLink) { profileLink.click(); }
                    else { window.location.href = "$moodleUrl/user/profile.php"; }
                  })();
                ''');
              },
            ),
            _moodleMenuItem(
              icon: Icons.calendar_month_rounded,
              color: Colors.purple.shade700,
              title: 'Kalender',
              subtitle: 'Jadwal & event',
              onTap: () {
                Navigator.pop(ctx);
                _webController.loadRequest(Uri.parse('$moodleUrl/calendar/view.php'));
              },
            ),
            const Divider(height: 1),
            _moodleMenuItem(
              icon: Icons.logout_rounded,
              color: Colors.red.shade600,
              title: 'Logout',
              subtitle: 'Keluar dari Moodle',
              onTap: () {
                Navigator.pop(ctx);
                _confirmMoodleLogout(moodleUrl);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _moodleMenuItem({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14,
                      color: color == Colors.red.shade600 ? Colors.red.shade600 : Colors.grey.shade800,
                    )),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmMoodleLogout(String moodleUrl) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Colors.red, size: 24),
            SizedBox(width: 10),
            Text('Logout Moodle?', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: const Text('Anda akan keluar dari akun Moodle. Pastikan semua jawaban sudah tersimpan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              // Moodle logout via sesskey extraction
              _webController.runJavaScript('''
                (function() {
                  var sessKeyEl = document.querySelector('[name="sesskey"]');
                  var sessKey = sessKeyEl ? sessKeyEl.value : null;
                  if (!sessKey) {
                    var match = document.cookie.match(/MoodleSession=([^;]+)/);
                    var links = document.querySelectorAll('a[href*="logout.php"]');
                    if (links.length > 0) { links[0].click(); return; }
                  }
                  if (sessKey) {
                    window.location.href = "$moodleUrl/login/logout.php?sesskey=" + sessKey;
                  } else {
                    window.location.href = "$moodleUrl/login/logout.php";
                  }
                })();
              ''');
            },
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Logout'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
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

  // ==================== NON-BLOCKING WARNING BANNER ====================

  /// Lightweight non-blocking warning banner shown at top of screen.
  /// Auto-dismisses after [durationSeconds]. Does NOT block the exam screen.
  /// Replaces heavy dialog popups that caused conflicts with bring-to-front
  /// and screen pinning.
  OverlayEntry? _currentBanner;

  void _showWarningBanner({
    required IconData icon,
    required Color color,
    required String text,
    int durationSeconds = 4,
  }) {
    if (!mounted) return;

    // Remove previous banner if still showing
    _currentBanner?.remove();
    _currentBanner = null;

    final overlay = Overlay.of(context);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _WarningBannerWidget(
        icon: icon,
        color: color,
        text: text,
        durationSeconds: durationSeconds,
        onDismiss: () {
          entry.remove();
          if (_currentBanner == entry) _currentBanner = null;
        },
      ),
    );

    _currentBanner = entry;
    overlay.insert(entry);
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

/// Lightweight animated warning banner widget.
/// Slides down from top, auto-dismisses, non-blocking.
class _WarningBannerWidget extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String text;
  final int durationSeconds;
  final VoidCallback onDismiss;

  const _WarningBannerWidget({
    required this.icon,
    required this.color,
    required this.text,
    required this.durationSeconds,
    required this.onDismiss,
  });

  @override
  State<_WarningBannerWidget> createState() => _WarningBannerWidgetState();
}

class _WarningBannerWidgetState extends State<_WarningBannerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(_controller);

    _controller.forward();

    // Auto-dismiss
    Future.delayed(Duration(seconds: widget.durationSeconds), () {
      if (mounted) {
        _controller.reverse().then((_) {
          widget.onDismiss();
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: () {
                _controller.reverse().then((_) => widget.onDismiss());
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(widget.icon, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.close, color: Colors.white70, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

