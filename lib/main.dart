import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'app.dart';
import 'services/notification_service.dart';

/// Top-level background message handler for FCM.
/// Must be a top-level function (not a class method).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final notifService = NotificationService();
  await notifService.initialize();
  // handleFcmMessage + _handleLockCommand will persist lock state to
  // SharedPreferences even from background — heartbeat picks it up on resume.
  await notifService.handleFcmMessage(message);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize Firebase (reads from google-services.json on Android)
  try {
    await Firebase.initializeApp();
    // Register background message handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('[Firebase] Init failed (FCM disabled): $e');
  }

  // Initialize local notifications + FCM subscription
  final notifService = NotificationService();
  await notifService.initialize();

  runApp(const ExaManmetApp());
}
