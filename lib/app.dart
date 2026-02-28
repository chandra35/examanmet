import 'package:flutter/material.dart';
import 'screens/splash_screen.dart';
import 'screens/password_screen.dart';
import 'screens/exam_browser_screen.dart';
import 'screens/exit_password_screen.dart';

class ExaManmetApp extends StatelessWidget {
  const ExaManmetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ExaManmet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      themeMode: ThemeMode.light,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/password': (context) => const PasswordScreen(),
        '/exam': (context) => const ExamBrowserScreen(),
        '/exit-password': (context) => const ExitPasswordScreen(),
      },
    );
  }
}
