import 'package:flutter/material.dart';
import 'dart:ui';
import '../services/config_service.dart';

class PasswordScreen extends StatefulWidget {
  const PasswordScreen({super.key});

  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen>
    with TickerProviderStateMixin {
  final _passwordController = TextEditingController();
  final _configService = ConfigService();
  final _focusNode = FocusNode();
  bool _isLoading = false;
  bool _obscureText = true;
  String? _errorText;
  int _attempts = 0;
  static const int _maxAttempts = 5;

  late AnimationController _slideController;
  late AnimationController _shakeController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
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
    _focusNode.dispose();
    _slideController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _shake() {
    _shakeController.forward(from: 0);
  }

  Future<void> _verifyPassword() async {
    if (_passwordController.text.isEmpty) {
      setState(() => _errorText = 'Masukkan password');
      _shake();
      return;
    }

    if (_attempts >= _maxAttempts) {
      setState(() => _errorText =
          'Terlalu banyak percobaan. Silakan hubungi pengawas ujian.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final verified = await _configService.verifyPassword(
        _passwordController.text,
        'app',
      );

      if (!mounted) return;

      if (verified) {
        Navigator.pushReplacementNamed(context, '/exam');
      } else {
        _attempts++;
        _shake();
        setState(() {
          _errorText =
              'Password salah. Percobaan $_attempts/$_maxAttempts';
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
              Color(0xFF0D47A1),
              Color(0xFF1565C0),
              Color(0xFF0277BD),
              Color(0xFF01579B),
            ],
            stops: [0.0, 0.3, 0.7, 1.0],
          ),
        ),
        child: Stack(
          children: [
            // Decorative circles
            Positioned(
              top: -80,
              right: -60,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.05),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -80,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.04),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).size.height * 0.3,
              left: -40,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.03),
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
                          // Shield Icon with glow
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withOpacity(0.25),
                                  Colors.white.withOpacity(0.10),
                                ],
                              ),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.3),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.shade900.withOpacity(0.5),
                                  blurRadius: 30,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.shield_rounded,
                              size: 48,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 28),

                          const Text(
                            'Masukkan Password',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Masukkan password yang diberikan\npengawas ujian untuk memulai',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 40),

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
                                    color: Colors.white.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.2),
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      // Password Field
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
                                          focusNode: _focusNode,
                                          obscureText: _obscureText,
                                          enabled: !_isLoading && _attempts < _maxAttempts,
                                          style: const TextStyle(fontSize: 17, letterSpacing: 1),
                                          decoration: InputDecoration(
                                            hintText: 'Password ujian',
                                            hintStyle: TextStyle(color: Colors.grey.shade400),
                                            prefixIcon: Icon(
                                              Icons.key_rounded,
                                              color: Colors.blue.shade700,
                                            ),
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
                                            contentPadding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 16,
                                            ),
                                          ),
                                          onSubmitted: (_) => _verifyPassword(),
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

                                      // Login Button
                                      SizedBox(
                                        width: double.infinity,
                                        height: 52,
                                        child: ElevatedButton(
                                          onPressed: _isLoading || _attempts >= _maxAttempts
                                              ? null
                                              : _verifyPassword,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.white,
                                            foregroundColor: const Color(0xFF0D47A1),
                                            disabledBackgroundColor: Colors.white.withOpacity(0.5),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(14),
                                            ),
                                            elevation: 6,
                                            shadowColor: Colors.black.withOpacity(0.2),
                                          ),
                                          child: _isLoading
                                              ? SizedBox(
                                                  width: 24,
                                                  height: 24,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2.5,
                                                    color: Colors.blue.shade700,
                                                  ),
                                                )
                                              : const Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.play_circle_filled, size: 22),
                                                    SizedBox(width: 8),
                                                    Text(
                                                      'MULAI UJIAN',
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.bold,
                                                        letterSpacing: 1.2,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                        ),
                                      ),

                                      // Attempts indicator dots
                                      if (_attempts > 0) ...[
                                        const SizedBox(height: 16),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: List.generate(_maxAttempts, (i) {
                                            return Container(
                                              width: 8,
                                              height: 8,
                                              margin: const EdgeInsets.symmetric(horizontal: 3),
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: i < _attempts
                                                    ? Colors.red.shade400
                                                    : Colors.white.withOpacity(0.3),
                                              ),
                                            );
                                          }),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 40),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.verified_user_rounded,
                                  size: 14, color: Colors.white.withOpacity(0.3)),
                              const SizedBox(width: 6),
                              Text(
                                'ExaManmet - Safe Exam Browser',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                  fontSize: 12,
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
            ),
          ],
        ),
      ),
    );
  }

  double _sinFromProgress(double x) {
    // Approximation of sin for shake animation
    final mod = x % 2;
    return mod < 1 ? mod : 2 - mod;
  }
}
