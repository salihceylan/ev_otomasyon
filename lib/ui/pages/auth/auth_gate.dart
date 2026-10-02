import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../common/confirm_dialogs.dart';
import '../../theme/app_theme.dart';
import '../dashboard_page.dart';
import '../wifi_recovery_dialog.dart';
import 'change_password_page.dart';
import 'login_page.dart';

/// Hangi ekranın gösterileceği. **Tek karar noktası**: biyometrik kilit, yerel mod ve zorunlu parola
/// değişimi burada çözülür.
enum AuthGateView {
  /// Durum henüz hazır değil **veya** biyometrik kilit açık: panonun hiçbir türü açılmaz.
  splash,
  login,
  dashboard,

  /// Oturumsuz yerel (LAN) mod.
  localDashboard,

  /// Sunucu parola değişimini zorunlu kıldı.
  forcedPasswordChange,
}

/// [state]'e göre gösterilecek görünümü belirler.
///
/// * `checking` (başlatma **ve** biyometrik kilit) -> [AuthGateView.splash]: yerel mod dahil hiçbir
///   pano açılmaz (kilitli oturumda doğrudan mod ile kilidi atlama kapalıdır).
/// * Yerel pano yalnızca **oturumsuz** (`unauthenticated`) ve doğrudan mod seçiliyken açılır.
/// * Oturum açıkken `mustChangePassword` ise parola değiştirme ekranına zorlanır.
@visibleForTesting
AuthGateView gateViewFor(AutomationState state) {
  switch (state.authStatus) {
    case AuthStatus.checking:
      return AuthGateView.splash;
    case AuthStatus.authenticated:
      return state.mustChangePassword ? AuthGateView.forcedPasswordChange : AuthGateView.dashboard;
    case AuthStatus.unauthenticated:
      return state.mode == AppMode.direct ? AuthGateView.localDashboard : AuthGateView.login;
  }
}

/// Oturum açık (pano) görünümleri: bunların üstüne itilen sayfa/diyaloglar oturumun verisini gösterir.
bool _isSignedInView(AuthGateView? view) => view == AuthGateView.dashboard || view == AuthGateView.localDashboard;

/// Uygulama kapısı: açılışta oturum/biyometrik durumu çözülene kadar açılış ekranını gösterir, sonra
/// giriş, pano (bulut/yerel) ya da zorunlu parola değişimi ekranına geçer.
///
/// Açılış ekranı **durum hazır olunca biter**; sabit bir bekleme süresi yoktur.
///
/// **Kilit/oturum geçişinde itilmiş sayfalar kapatılır:** pano görünümünden açılış/kilit ekranına
/// (arka plandan >= 30 sn sonra biyometrik yeniden kilit), girişe (oturum kapandı) ya da zorunlu parola
/// ekranına geçilirken Navigator'a itilmiş tüm sayfa ve diyaloglar kapanır; aksi halde kilit ekranının
/// üstünde (ör. üye listesi) oturumun verisi görünür kalırdı. Kök rota (bu kapı) kalır.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AutomationState? _state;
  AuthGateView? _lastView;

  /// Biyometrik kilitte Wi-Fi kurulum sihirbazı açıktı: kilit açılıp pano görününce yeniden açılır.
  /// (Sihirbazın doğası gereği kullanıcı telefonun Wi-Fi ayarlarına gidip panonun kurulum ağına bağlanır ve
  /// uygulamaya >= 30 sn sonra döner; sihirbaz hassas veri göstermez ve girişsiz de açılabilir.)
  bool _resumeWifiWizard = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _state = state;
    _lastView = gateViewFor(state);
    state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _state?.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    final state = _state;
    if (state == null) return;
    final view = gateViewFor(state);
    final previous = _lastView;
    _lastView = view;
    if (_isSignedInView(previous) && !_isSignedInView(view)) {
      _closePushedRoutes(lockedByBiometrics: view == AuthGateView.splash);
    }
    if (_resumeWifiWizard) {
      if (view == AuthGateView.dashboard) {
        _resumeWifiWizard = false;
        _openWifiWizard();
      } else if (view != AuthGateView.splash) {
        _resumeWifiWizard = false; // çıkış / zorunlu parola ekranı: sihirbaz kendiliğinden açılmaz
      }
    }
  }

  /// Çerçeve sonunda (kapının yeni görünümü kurulduktan sonra) tüm itilmiş rotaları kapatır. Kapatılanlar
  /// arasında Wi-Fi sihirbazı varsa ve kilit biyometrik kilitse, kilit açılınca sihirbaz yeniden açılır.
  void _closePushedRoutes({required bool lockedByBiometrics}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var wizardWasOpen = false;
      Navigator.of(context).popUntil((route) {
        if (route.settings.name == WifiRecoveryDialog.routeName) wizardWasOpen = true;
        return route.isFirst;
      });
      if (!wizardWasOpen || !lockedByBiometrics) return;
      final state = _state;
      if (state != null && gateViewFor(state) == AuthGateView.dashboard) {
        _openWifiWizard(); // kilit çoktan açıldı (hızlı doğrulama)
      } else {
        _resumeWifiWizard = true;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _openWifiWizard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(WifiRecoveryDialog.show(context));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, AuthGateView>(gateViewFor);

    final Widget screen;
    switch (view) {
      case AuthGateView.splash:
        screen = const _AuthSplashScreen(key: ValueKey('splash_screen'));
      case AuthGateView.login:
        screen = const LoginPage(key: ValueKey('login_screen'));
      case AuthGateView.dashboard:
      case AuthGateView.localDashboard:
        screen = const DashboardPage(key: ValueKey('dashboard_screen'));
      case AuthGateView.forcedPasswordChange:
        screen = const ChangePasswordPage(key: ValueKey('forced_password_screen'), forced: true);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      child: screen,
    );
  }
}

class _AuthSplashScreen extends StatefulWidget {
  const _AuthSplashScreen({super.key});

  @override
  State<_AuthSplashScreen> createState() => _AuthSplashScreenState();
}

class _AuthSplashScreenState extends State<_AuthSplashScreen> {
  /// Başlatma bu süreden uzun sürerse kullanıcıya çıkış yolu sunulur (sonsuz spinner yok).
  static const Duration _slowStartAfter = Duration(seconds: 15);

  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _slowTimer = context.read<AutomationState>().clock.timer(_slowStartAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final showBiometricRetry = state.biometricFailed;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/ai_circuit_bg.jpg',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(color: const Color(0xFF0B1120)),
            ),
          ),
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
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      height: 130,
                      width: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF38BDF8), width: 2.5),
                        boxShadow: [
                          BoxShadow(color: const Color(0xFF38BDF8).withValues(alpha: 0.55), blurRadius: 36, spreadRadius: 6),
                          BoxShadow(color: const Color(0xFF0284C7).withValues(alpha: 0.35), blurRadius: 60, spreadRadius: 10),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/round_app_logo.png',
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: AppTheme.surfaceDark,
                            child: const Icon(Icons.home_work_rounded, color: Color(0xFF38BDF8), size: 64),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'AHBU OTOMASYON',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                        color: Colors.white,
                        shadows: [Shadow(color: Color(0xFF38BDF8), blurRadius: 18)],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.25), width: 1),
                      ),
                      child: const Text(
                        'YAPAY ZEKA DESTEKLİ AKILLI YAŞAM',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: Color(0xFF7DD3FC)),
                      ),
                    ),
                    const SizedBox(height: 36),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxWidth: 340),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.70),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.22), width: 1.2),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 20, offset: const Offset(0, 8)),
                        ],
                      ),
                      child: showBiometricRetry ? _buildBiometricFailed(context, state) : _buildChecking(context, state),
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

  Widget _buildBiometricFailed(BuildContext context, AutomationState state) {
    return Column(
      key: const Key('biometric_locked'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.fingerprint_rounded, size: 40, color: AppTheme.accentAmber),
        const SizedBox(height: 12),
        Text(
          '${state.biometricLabel} doğrulaması tamamlanamadı.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: AppTheme.accentAmber, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const Key('btn_biometric_retry'),
            onPressed: () => unawaited(state.retryBiometricAuth()),
            icon: const Icon(Icons.fingerprint_rounded, size: 20),
            label: Text('${state.biometricLabel} ile Aç'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 4,
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          key: const Key('btn_biometric_fallback'),
          // Şifre ile girişe düşmek oturumu kapatır (belirteçler silinir): onay istenir.
          onPressed: () => unawaited(confirmAndLogout(context, state)),
          child: const Text(
            'Şifre ile Giriş Yap',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildChecking(BuildContext context, AutomationState state) {
    return Column(
      key: const Key('splash_checking'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFCBD5E1)),
              ),
            ),
          ],
        ),
        if (_slow && !state.biometricChecking) ...[
          const SizedBox(height: 16),
          const Text(
            'Başlatma beklenenden uzun sürüyor. Bekleyebilir ya da şifre ile giriş yapabilirsiniz.',
            key: Key('splash_slow_notice'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.accentAmber, height: 1.35),
          ),
          TextButton(
            key: const Key('btn_splash_fallback'),
            onPressed: () => unawaited(confirmAndLogout(context, state)),
            child: const Text('Şifre ile Giriş Yap', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
          ),
        ],
      ],
    );
  }
}
