/// Exam session service — NO-OP stub.
///
/// Previously this service sent session/start, heartbeat (every 30s),
/// violation reports, and session/end to the simansa backend.
/// This caused "Resource Limit Reached" on simansa during exams
/// (heartbeat alone = N students × 2 req/min).
///
/// All methods now do nothing. The same public interface is kept so
/// callers (exam_browser_screen) don't need changes.
///
/// Kept endpoints (in ConfigService, not here):
///   GET  /api/exam-browser/config          — splash config fetch
///   POST /api/exam-browser/verify-password  — password login
///   POST /api/exam-browser/ping            — manual ping test
///
/// Removed endpoints (were in this service):
///   POST /api/exam-browser/session/start
///   POST /api/exam-browser/session/heartbeat
///   POST /api/exam-browser/session/violation
///   POST /api/exam-browser/session/end
///
/// Local violation detection (counter, auto-lock, alert sound) still
/// works — it just doesn't report to the server anymore.
class ExamSessionService {
  String? _moodleUsername;
  String? _moodleFullname;

  // Callback kept for interface compatibility — never fired now.
  void Function(bool isLocked, String? reason)? onLockStatusChanged;

  bool get isLocked => false;
  String? get lockReason => null;
  int get violationCount => 0;
  String? get sessionId => null;
  String? get moodleUsername => _moodleUsername;

  void setProtectionLevel(String level) {}

  Future<void> startSession() async {}

  void updateMoodleUser(String? username, String? fullname) {
    _moodleUsername = username;
    _moodleFullname = fullname;
  }

  Future<void> reportViolation(String type, {String? detail}) async {}

  Future<void> endSession() async {}

  void dispose() {}
}
