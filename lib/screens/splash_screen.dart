import 'dart:async';
import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../models/exam_config.dart';

/// Boot line entry for the terminal animation.
class _BootLine {
  final String text;
  final Color color;
  final bool isStatus; // [  OK  ] or [FAIL]
  final Duration delay;

  const _BootLine(this.text, {this.color = const Color(0xFFB0BEC5), this.isStatus = false, this.delay = const Duration(milliseconds: 70)});
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final ConfigService _configService = ConfigService();
  final ScrollController _scrollController = ScrollController();
  final List<_BootLine> _displayedLines = [];
  Timer? _cursorTimer;
  bool _showCursor = true;
  bool _hasError = false;
  String _errorMessage = '';
  bool _bootDone = false;

  // Terminal green color palette
  static const _green = Color(0xFF00FF41);
  static const _dimGreen = Color(0xFF00CC33);
  static const _cyan = Color(0xFF00E5FF);
  static const _yellow = Color(0xFFFFD600);
  static const _white = Color(0xFFE0E0E0);
  static const _red = Color(0xFFFF1744);
  static const _dimWhite = Color(0xFF78909C);

  // The full boot sequence
  static final List<_BootLine> _bootSequence = [
    _BootLine('', delay: Duration(milliseconds: 300)),
    _BootLine('ExaManmet Secure Exam Environment v3.0.0', color: _green, delay: Duration(milliseconds: 100)),
    _BootLine('Copyright (c) 2025 MAN 1 Metro - Digital Education Div.', color: _dimWhite, delay: Duration(milliseconds: 80)),
    _BootLine('', delay: Duration(milliseconds: 200)),
    _BootLine('[    0.0000] Kernel: SEB Engine 3.0 initialized', color: _white, delay: Duration(milliseconds: 60)),
    _BootLine('[    0.0134] CPU: ${1} core(s) detected, ARM64', color: _white, delay: Duration(milliseconds: 50)),
    _BootLine('[    0.0271] Memory: Allocating secure heap...', color: _white, delay: Duration(milliseconds: 50)),
    _BootLine('[    0.0408] Display: Framebuffer initialized', color: _white, delay: Duration(milliseconds: 50)),
    _BootLine('', delay: Duration(milliseconds: 150)),
    _BootLine(':: Loading security modules...', color: _cyan, delay: Duration(milliseconds: 120)),
    _BootLine('', delay: Duration(milliseconds: 80)),
    _BootLine('  [  OK  ] Clipboard interception', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Screenshot prevention', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] App switching blocker', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Kiosk mode engine', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Screen pin service', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Bluetooth monitoring', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Headset detection', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Root/jailbreak scanner', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Alert sound system', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('  [  OK  ] Wakelock persistent', color: _green, isStatus: true, delay: Duration(milliseconds: 90)),
    _BootLine('', delay: Duration(milliseconds: 100)),
    _BootLine(':: Initializing WebView sandbox...', color: _cyan, delay: Duration(milliseconds: 100)),
    _BootLine('  [  OK  ] WebView engine loaded', color: _green, isStatus: true, delay: Duration(milliseconds: 80)),
    _BootLine('  [  OK  ] JavaScript bridge ready', color: _green, isStatus: true, delay: Duration(milliseconds: 80)),
    _BootLine('  [  OK  ] Navigation guard active', color: _green, isStatus: true, delay: Duration(milliseconds: 80)),
    _BootLine('', delay: Duration(milliseconds: 100)),
    _BootLine(':: Establishing network connection...', color: _cyan, delay: Duration(milliseconds: 120)),
    _BootLine('[    1.2840] Net: Resolving simansa.man1metro.sch.id...', color: _white, delay: Duration(milliseconds: 200)),
    _BootLine('[    1.4120] Net: TLS handshake established', color: _white, delay: Duration(milliseconds: 100)),
    _BootLine('  [  OK  ] Server connection', color: _green, isStatus: true, delay: Duration(milliseconds: 80)),
    _BootLine('', delay: Duration(milliseconds: 100)),
    _BootLine(':: Fetching exam configuration...', color: _cyan, delay: Duration(milliseconds: 100)),
  ];

  // Lines added after config fetch completes
  static final List<_BootLine> _bootSuccessEnd = [
    _BootLine('  [  OK  ] Configuration loaded', color: _green, isStatus: true, delay: Duration(milliseconds: 80)),
    _BootLine('', delay: Duration(milliseconds: 80)),
    _BootLine('[    2.0810] System: All 14 modules operational', color: _white, delay: Duration(milliseconds: 60)),
    _BootLine('[    2.1344] Boot: Security audit PASSED', color: _green, delay: Duration(milliseconds: 80)),
    _BootLine('', delay: Duration(milliseconds: 120)),
    _BootLine('  ExaManmet is ready. Starting secure session...', color: _yellow, delay: Duration(milliseconds: 200)),
    _BootLine('', delay: Duration(milliseconds: 500)),
  ];

  @override
  void initState() {
    super.initState();
    // Blinking cursor
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (mounted) setState(() => _showCursor = !_showCursor);
    });
    _runBootSequence();
  }

  @override
  void dispose() {
    _cursorTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 50),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _addLine(_BootLine line) async {
    await Future.delayed(line.delay);
    if (!mounted) return;
    setState(() => _displayedLines.add(line));
    _scrollToBottom();
  }

  Future<void> _runBootSequence() async {
    // Phase 1: Show pre-boot lines (visual only)
    for (final line in _bootSequence) {
      await _addLine(line);
    }

    // Phase 2: Actually fetch config while "Fetching exam configuration..." is shown
    ExamConfig? config;
    try {
      config = await _configService.fetchConfig();
    } catch (e) {
      if (!mounted) return;
      await _addLine(_BootLine('  [ FAIL ] Configuration fetch error', color: _red, isStatus: true, delay: Duration(milliseconds: 80)));
      await _addLine(_BootLine('', delay: Duration(milliseconds: 80)));
      await _addLine(_BootLine('KERNEL PANIC: $e', color: _red, delay: Duration(milliseconds: 100)));
      await _addLine(_BootLine('', delay: Duration(milliseconds: 80)));
      await _addLine(_BootLine('--- Press RETRY to reboot ---', color: _yellow, delay: Duration(milliseconds: 100)));
      setState(() {
        _hasError = true;
        _errorMessage = '$e';
        _bootDone = true;
      });
      return;
    }

    if (!mounted) return;

    // Check if app is active
    if (!config.isActive) {
      await _addLine(_BootLine('  [ FAIL ] App configuration inactive', color: _red, isStatus: true, delay: Duration(milliseconds: 80)));
      await _addLine(_BootLine('', delay: Duration(milliseconds: 80)));
      await _addLine(_BootLine('SYSTEM HALT: Exam browser tidak aktif. Hubungi admin.', color: _red, delay: Duration(milliseconds: 100)));
      await _addLine(_BootLine('', delay: Duration(milliseconds: 80)));
      await _addLine(_BootLine('--- Press RETRY to reboot ---', color: _yellow, delay: Duration(milliseconds: 100)));
      setState(() {
        _hasError = true;
        _errorMessage = 'Konfigurasi Exam Browser tidak aktif. Hubungi admin.';
        _bootDone = true;
      });
      return;
    }

    // Phase 3: Config loaded, continue boot success sequence
    for (final line in _bootSuccessEnd) {
      await _addLine(line);
    }

    setState(() => _bootDone = true);

    // Show announcement if any
    if (config.announcement != null && config.announcement!.isNotEmpty) {
      if (!mounted) return;
      await _showAnnouncement(config);
    }

    // Navigate
    if (!mounted) return;
    if (config.appPassword != null && config.appPassword!.isNotEmpty) {
      Navigator.pushReplacementNamed(context, '/password');
    } else {
      Navigator.pushReplacementNamed(context, '/exam');
    }
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
        final curvedAnim = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return Transform.scale(
          scale: curvedAnim.value,
          child: Opacity(
            opacity: anim.value,
            child: Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
                            colors: [Colors.orange.shade300, Colors.deepOrange.shade400],
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
                        child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 38),
                      ),
                      const SizedBox(height: 20),
                      ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          colors: [Colors.orange.shade700, Colors.deepOrange.shade600],
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
                            colors: [Colors.orange.shade300, Colors.deepOrange.shade300],
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
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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

  Widget _buildBootLine(_BootLine line) {
    if (line.text.isEmpty) return const SizedBox(height: 6);

    if (line.isStatus) {
      // Parse "[  OK  ] text" or "[ FAIL ] text" style
      final isOk = line.text.contains('[  OK  ]');
      final isFail = line.text.contains('[ FAIL ]');
      final statusTag = isOk ? '[  OK  ]' : (isFail ? '[ FAIL ]' : '');
      final rest = line.text.replaceFirst(statusTag, '').trim();
      final indent = line.text.startsWith('  ') ? '  ' : '';

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 0.5),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35),
            children: [
              TextSpan(text: indent, style: TextStyle(color: _white)),
              TextSpan(
                text: statusTag,
                style: TextStyle(
                  color: isOk ? _green : _red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextSpan(text: ' $rest', style: TextStyle(color: _white)),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: Text(
        line.text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          height: 1.35,
          color: line.color,
          fontWeight: line.color == _green || line.color == _yellow
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E14), // Deep dark background
      body: SafeArea(
        child: Stack(
          children: [
            // Subtle scanline effect overlay
            Positioned.fill(
              child: CustomPaint(painter: _ScanlinePainter()),
            ),
            // Terminal content
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Terminal title bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1F2B),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                      border: Border.all(color: const Color(0xFF2A3040)),
                    ),
                    child: Row(
                      children: [
                        // Terminal dots
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFFFF5F57), shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFFFEBC2E), shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFF28C840), shape: BoxShape.circle)),
                        const Spacer(),
                        Text(
                          'examanmet — secure-boot',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: _dimWhite,
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(width: 50), // balance
                      ],
                    ),
                  ),
                  // Terminal body
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D1117),
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                        border: Border.all(color: const Color(0xFF2A3040)),
                      ),
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _displayedLines.length + 1, // +1 for cursor line
                        physics: const BouncingScrollPhysics(),
                        itemBuilder: (context, index) {
                          if (index < _displayedLines.length) {
                            return _buildBootLine(_displayedLines[index]);
                          }
                          // Blinking cursor at the end
                          if (!_bootDone || _hasError) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                _showCursor ? '█' : ' ',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  color: _green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                  // Error retry button (terminal style)
                  if (_hasError) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _hasError = false;
                            _bootDone = false;
                            _displayedLines.clear();
                          });
                          _runBootSequence();
                        },
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: _green),
                          foregroundColor: _green,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: const Text(
                          '[ RETRY BOOT SEQUENCE ]',
                          style: TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Bottom label
                  Center(
                    child: Text(
                      'MAN 1 Metro · Secure Exam Browser',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: _dimWhite.withOpacity(0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws subtle horizontal scanlines like a CRT monitor.
class _ScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.06)
      ..strokeWidth = 1;

    for (double y = 0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
