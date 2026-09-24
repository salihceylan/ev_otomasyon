import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';
import '../dashboard_page.dart';
import 'login_page.dart';

class AuthGate extends StatefulWidget {
  final Duration minSplashDuration;

  const AuthGate({
    super.key,
    this.minSplashDuration = Duration.zero,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _minSplashPassed = false;
  Timer? _splashTimer;

  @override
  void initState() {
    super.initState();
    if (widget.minSplashDuration == Duration.zero) {
      _minSplashPassed = true;
    } else {
      _splashTimer = Timer(widget.minSplashDuration, () {
        if (mounted) {
          setState(() {
            _minSplashPassed = true;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _splashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AutomationState>(
      builder: (context, state, _) {
        // Kullanıcının açılış ekranındaki zengin elektronik devreleri ve logoyu görmesi için
        if (!_minSplashPassed || state.authStatus == AuthStatus.checking) {
          return const _AuthSplashScreen();
        }

        // Doğrudan ESP32 yerel modundaysa doğrudan Dashboard'a yönlendir
        if (state.mode == AppMode.direct) {
          return const DashboardPage();
        }

        // Bulut Modu Oturum Durumu Kontrolü
        switch (state.authStatus) {
          case AuthStatus.checking:
            return const _AuthSplashScreen();
          case AuthStatus.authenticated:
            return const DashboardPage();
          case AuthStatus.unauthenticated:
            return const LoginPage();
        }
      },
    );
  }
}

class _AuthSplashScreen extends StatelessWidget {
  const _AuthSplashScreen();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();

    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      body: Stack(
        children: [
          // 1. Elektronik & Yapay Zeka Temalı Arka Plan Görseli
          Positioned.fill(
            child: Image.asset(
              'assets/images/ai_circuit_bg.jpg',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: const Color(0xFF0B1120),
              ),
            ),
          ),

          // 2. Siber Gradyan & Karartma Katmanı (Elektronik devreler net görünsün)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0B1120).withValues(alpha: 0.35),
                    const Color(0xFF0B1120).withValues(alpha: 0.50),
                    const Color(0xFF0B1120).withValues(alpha: 0.70),
                  ],
                  stops: const [0.0, 0.50, 1.0],
                ),
              ),
            ),
          ),

          // 3. İçerik Katmanı
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Dairesel Neon AI & IoT Logo (Kesinlikle köşeli değil, orijinal fütüristik çember)
                    Container(
                      height: 130,
                      width: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF38BDF8),
                          width: 2.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.55),
                            blurRadius: 36,
                            spreadRadius: 6,
                          ),
                          BoxShadow(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.35),
                            blurRadius: 60,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/round_app_logo.png',
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: AppTheme.surfaceDark,
                            child: const Icon(
                              Icons.home_work_rounded,
                              color: Color(0xFF38BDF8),
                              size: 64,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Başlık
                    const Text(
                      'AHBU OTOMASYON',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Color(0xFF38BDF8),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Fütüristik Alt Başlık
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                      child: const Text(
                        'YAPAY ZEKA DESTEKLİ AKILLI YAŞAM',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.6,
                          color: Color(0xFF7DD3FC),
                        ),
                      ),
                    ),
                    const SizedBox(height: 36),

                    // Durum & Doğrulama Kartı (Glassmorphic)
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxWidth: 340),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.70),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.22),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state.biometricFailed) ...[
                            const Icon(
                              Icons.fingerprint_rounded,
                              size: 40,
                              color: AppTheme.accentAmber,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${state.biometricLabel} doğrulaması tamamlanamadı.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                color: AppTheme.accentAmber,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () => state.retryBiometricAuth(),
                                icon: const Icon(Icons.fingerprint_rounded, size: 20),
                                label: Text('${state.biometricLabel} ile Aç'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0284C7),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  elevation: 4,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextButton(
                              onPressed: () => state.fallbackToPasswordLogin(),
                              child: const Text(
                                'Şifre ile Giriş Yap',
                                style: TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ] else ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                                  ),
                                ),
                                SizedBox(width: 14),
                                Flexible(
                                  child: Text(
                                    'Oturum güvenli şekilde doğrulanıyor...',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFFCBD5E1),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
