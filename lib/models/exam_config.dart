/// Configuration model for ExaManmet app.
/// This data is fetched from the admin API (simansav3).
class ExamConfig {
  final String appName;
  final String schoolName;
  final String? logoUrl;
  final String moodleUrl;
  final String userAgent;
  final String? appPassword;
  final String? exitPassword;
  final String? sebConfigKey;
  final String? sebExamKey;
  final bool allowScreenshot;
  final bool allowClipboard;
  final bool allowNavigation;
  final bool allowReload;
  final bool showToolbar;
  final bool detectBluetooth;
  final bool detectHeadset;
  final bool detectRoot;
  final bool alertSoundOnViolation;
  final List<String> allowedUrls;
  final List<String> blockedApps;
  final String? customCss;
  final String? customJs;
  final String minimumAppVersion;
  final bool isActive;
  final String? announcement;
  final String? updatedAt;

  ExamConfig({
    required this.appName,
    required this.schoolName,
    this.logoUrl,
    required this.moodleUrl,
    required this.userAgent,
    this.appPassword,
    this.exitPassword,
    this.sebConfigKey,
    this.sebExamKey,
    this.allowScreenshot = false,
    this.allowClipboard = false,
    this.allowNavigation = false,
    this.allowReload = true,
    this.showToolbar = true,
    this.detectBluetooth = true,
    this.detectHeadset = true,
    this.detectRoot = true,
    this.alertSoundOnViolation = true,
    this.allowedUrls = const [],
    this.blockedApps = const [],
    this.customCss,
    this.customJs,
    this.isActive = true,
    this.minimumAppVersion = '1.0.0',
    this.announcement,
    this.updatedAt,
  });

  /// Mobile User-Agent constant - always used regardless of server config
  static const String mobileUserAgent = 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 SEB/3.0 ExaManmet/1.0';

  /// Ensure User-Agent always has mobile identifiers for responsive layout
  static String _ensureMobileUA(String? ua) {
    if (ua == null || ua.isEmpty) return mobileUserAgent;
    // If server UA doesn't contain Mobile browser prefix, use our mobile UA
    if (!ua.contains('Mozilla/5.0') || !ua.contains('Mobile')) {
      return mobileUserAgent;
    }
    return ua;
  }

  /// Create from API JSON response
  factory ExamConfig.fromJson(Map<String, dynamic> json) {
    return ExamConfig(
      appName: json['app_name'] ?? 'ExaManmet',
      schoolName: json['school_name'] ?? '',
      logoUrl: json['logo_url'],
      moodleUrl: json['moodle_url'] ?? 'https://elearning.man1metro.sch.id',
      userAgent: _ensureMobileUA(json['user_agent']),
      appPassword: json['app_password'],
      exitPassword: json['exit_password'],
      sebConfigKey: json['seb_config_key'],
      sebExamKey: json['seb_exam_key'],
      allowScreenshot: json['allow_screenshot'] ?? false,
      allowClipboard: json['allow_clipboard'] ?? false,
      allowNavigation: json['allow_navigation'] ?? false,
      allowReload: json['allow_reload'] ?? true,
      showToolbar: json['show_toolbar'] ?? true,
      detectBluetooth: json['detect_bluetooth'] ?? true,
      detectHeadset: json['detect_headset'] ?? true,
      detectRoot: json['detect_root'] ?? true,
      alertSoundOnViolation: json['alert_sound_on_violation'] ?? true,
      allowedUrls: json['allowed_urls'] != null
          ? List<String>.from(json['allowed_urls'])
          : [],
      blockedApps: json['blocked_apps'] != null
          ? List<String>.from(json['blocked_apps'])
          : [],
      customCss: json['custom_css'],
      customJs: json['custom_js'],
      isActive: json['is_active'] ?? true,
      minimumAppVersion: json['minimum_app_version'] ?? '1.0.0',
      announcement: json['announcement'],
      updatedAt: json['updated_at'],
    );
  }

  /// Convert to JSON for local caching
  Map<String, dynamic> toJson() {
    return {
      'app_name': appName,
      'school_name': schoolName,
      'logo_url': logoUrl,
      'moodle_url': moodleUrl,
      'user_agent': userAgent,
      'app_password': appPassword,
      'exit_password': exitPassword,
      'seb_config_key': sebConfigKey,
      'seb_exam_key': sebExamKey,
      'allow_screenshot': allowScreenshot,
      'allow_clipboard': allowClipboard,
      'allow_navigation': allowNavigation,
      'allow_reload': allowReload,
      'show_toolbar': showToolbar,
      'detect_bluetooth': detectBluetooth,
      'detect_headset': detectHeadset,
      'detect_root': detectRoot,
      'alert_sound_on_violation': alertSoundOnViolation,
      'allowed_urls': allowedUrls,
      'blocked_apps': blockedApps,
      'custom_css': customCss,
      'custom_js': customJs,
      'is_active': isActive,
      'minimum_app_version': minimumAppVersion,
      'announcement': announcement,
      'updated_at': updatedAt,
    };
  }

  /// Check if a URL is allowed
  bool isUrlAllowed(String url) {
    // Always allow the main moodle URL
    if (url.startsWith(moodleUrl)) return true;

    // Allow SEB protocol URLs (sebs:// and seb://) for the same Moodle domain
    // Moodle sends sebs:// URLs for SEB config when it detects a SEB browser
    final moodleDomain = Uri.parse(moodleUrl).host;
    if (url.startsWith('sebs://') || url.startsWith('seb://')) {
      final sebUri = Uri.tryParse(url);
      if (sebUri != null && sebUri.host == moodleDomain) return true;
    }

    // Check additional allowed URLs
    for (final allowedUrl in allowedUrls) {
      if (url.startsWith(allowedUrl)) return true;
    }

    return allowNavigation;
  }

  /// Default fallback config when API is not available
  factory ExamConfig.defaults() {
    return ExamConfig(
      appName: 'ExaManmet',
      schoolName: 'MAN 1 Metro',
      moodleUrl: 'https://elearning.man1metro.sch.id',
      userAgent: mobileUserAgent,
    );
  }
}
