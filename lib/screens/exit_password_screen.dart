import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import '../services/config_service.dart';
import '../services/lockdown_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ExitPasswordScreen extends StatefulWidget {
  const ExitPasswordScreen({super.key});

  @override
  State<ExitPasswordScreen> createState() => _ExitPasswordScreenState();
}

class _ExitPasswordScreenState extends State<ExitPasswordScreen>
    with TickerProviderStateMixin {
  final _passwordController = TextEditingController();
  final _configService = ConfigService();
  final _lockdownService = LockdownService();
  bool _isLoading = false;
  bool _obscureText = true;
  String? _errorText;
  int _attempts = 0;

  late AnimationController _slideController;
  late AnimationController _shakeController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.25),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _slideController, curve: Curves.easeOut),
    );
    _slideController.forward();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _slideController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _shake() {
    _shakeController.forward(from: 0);
  }

  double _sinFromProgress(double x) {
    final mod = x % 2;
    return mod < 1 ? mod : 2 - mod;
  }

  Future<void> _verifyExitPassword() async {
    if (_passwordController.text.isEmpty) {
      setState(() => _errorText = 'Masukkan password keluar');
      _shake();
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final verified = await _configService.verifyPassword(
        _passwordController.text,
        'exit',
      );

      if (!mounted) return;

      if (verified) {
        // Disable lockdown and exit
        await _lockdownService.disableLockdown();
        await WakelockPlus.disable();
        if (mounted) {
          SystemNavigator.pop();
        }
      } else {
        _attempts++;
        _shake();
        setState(() {
          _errorText = 'Password salah. Percobaan: $_attempts';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      _shake();
      setState(() {
        _errorText = 'Gagal verifikasi: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1a1a2e),
              Color(0xFF16213e),
              Color(0xFF0f3460),
              Color(0xFF1a1a2e),
            ],
            stops: [0.0, 0.3, 0.7, 1.0],
          ),
        ),
        child: Stack(
          children: [
            // Decorative circles
            Positioned(
              top: -60,
              left: -40,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withOpacity(0.06),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              right: -60,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withOpacity(0.04),
                ),
              ),
            ),
            // Main content
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: SlideTransition(
                      position: _slideAnim,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Exit Icon with red glow
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.red.withOpacity(0.3),
                                  Colors.red.withOpacity(0.15),
                                ],
                              ),
                              border: Border.all(
                                color: Colors.redAccent.withOpacity(0.4),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.red.withOpacity(0.3),
                                  blurRadius: 30,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.logout_rounded,
                              size: 48,
                              color: Colors.redAccent,
                            ),
                          ),
                          const SizedBox(height: 28),

                          const Text(
                            'Password Keluar',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Masukkan password keluar dari pengawas\nuntuk mengakhiri sesi ujian',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 36),

                          // Glassmorphism card
                          AnimatedBuilder(
                            animation: _shakeController,
                            builder: (context, child) {
                              final progress = _shakeController.value;
                              final shake = _shakeController.status == AnimationStatus.forward
                                  ? 10.0 * (1 - progress) * _sinFromProgress(progress * 4)
                                  : 0.0;
                              return Transform.translate(
                                offset: Offset(shake, 0),
                                child: child,
                              );
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                child: Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.15),
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      // Password field
                                      Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(14),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.08),
                                              blurRadius: 12,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: TextField(
                                          controller: _passwordController,
                                          obscureText: _obscureText,
                                          enabled: !_isLoading,
                                          style: const TextStyle(fontSize: 17, letterSpacing: 1),
                                          decoration: InputDecoration(
                                            hintText: 'Password keluar',
                                            hintStyle: TextStyle(color: Colors.grey.shade400),
                                            prefixIcon: Icon(Icons.key_rounded, color: Colors.red.shade600),
                                            suffixIcon: IconButton(
                                              icon: Icon(
                                                _obscureText
                                                    ? Icons.visibility_off_rounded
                                                    : Icons.visibility_rounded,
                                                color: Colors.grey.shade500,
                                              ),
                                              onPressed: () =>
                                                  setState(() => _obscureText = !_obscureText),
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(14),
                                              borderSide: BorderSide.none,
                                            ),
                                            filled: true,
                                            fillColor: Colors.white,
                                          ),
                                          onSubmitted: (_) => _verifyExitPassword(),
                                        ),
                                      ),

                                      // Error text with animation
                                      AnimatedSize(
                                        duration: const Duration(milliseconds: 300),
                                        curve: Curves.easeInOut,
                                        child: _errorText != null
                                            ? Padding(
                                                padding: const EdgeInsets.only(top: 14),
                                                child: Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.symmetric(
                                                      horizontal: 14, vertical: 10),
                                                  decoration: BoxDecoration(
                                                    gradient: LinearGradient(
                                                      colors: [
                                                        Colors.red.shade800.withOpacity(0.8),
                                                        Colors.red.shade900.withOpacity(0.7),
                                                      ],
                                                    ),
                                                    borderRadius: BorderRadius.circular(10),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      const Icon(Icons.error_outline,
                                                          color: Colors.white, size: 18),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: Text(
                                                          _errorText!,
                                                          style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 13,
                                                            fontWeight: FontWeight.w500,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              )
                                            : const SizedBox.shrink(),
                                      ),

                                      const SizedBox(height: 20),

                                      // Buttons Row
                                      Row(
                                        children: [
                                          Expanded(
                                            child: SizedBox(
                                              height: 50,
                                              child: OutlinedButton(
                                                onPressed: () => Navigator.pop(context),
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Colors.white.withOpacity(0.9),
                                                  side: BorderSide(color: Colors.white.withOpacity(0.3)),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.circular(14),
                                                  ),
                                                ),
                                                child: const Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.arrow_back_rounded, size: 18),
                                                    SizedBox(width: 6),
                                                    Text(
                                                      'Kembali',
                                                      style: TextStyle(
                                                        fontSize: 14, fontWeight: FontWeight.w500,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: SizedBox(
                                              height: 50,
                                              child: ElevatedButton(
                                                onPressed: _isLoading ? null : _verifyExitPassword,
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.red.shade600,
                                                  foregroundColor: Colors.white,
                                                  disabledBackgroundColor: Colors.red.shade600.withOpacity(0.5),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.circular(14),
                                                  ),
                                                  elevation: 4,
                                                  shadowColor: Colors.red.withOpacity(0.4),
                                                ),
                                                child: _isLoading
                                                    ? const SizedBox(
                                                        width: 22,
                                                        height: 22,
                                                        child: CircularProgressIndicator(
                                                          strokeWidth: 2.5,
                                                          color: Colors.white,
                                                        ),
                                                      )
                                                    : const Row(
                                                        mainAxisAlignment: MainAxisAlignment.center,
                                                        children: [
                                                          Icon(Icons.exit_to_app_rounded, size: 18),
                                                          SizedBox(width: 6),
                                                          Text(
                                                            'KELUAR',
                                                            style: TextStyle(
                                                              fontSize: 14,
                                                              fontWeight: FontWeight.bold,
                                                              letterSpacing: 0.8,
                                                            ),
                                                          ),
                                                        ],
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

                          const SizedBox(height: 36),
                          // Warning text
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.orange.withOpacity(0.2)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.warning_amber_rounded,
                                    size: 16, color: Colors.orange.shade300),
                                const SizedBox(width: 8),
                                Text(
                                  'Keluar akan mengakhiri sesi ujian',
                                  style: TextStyle(
                                    color: Colors.orange.shade300,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
