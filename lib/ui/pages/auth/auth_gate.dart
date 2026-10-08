import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../services/biometric_auth_service.dart';
import '../../common/confirm_dialogs.dart';
import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart' show SurfaceRimPainter;
import '../dashboard_page.dart';
import '../legal/terms_acceptance_page.dart';
import '../wifi_recovery_dialog.dart';
import 'auth_brand.dart';
import 'change_password_page.dart';
import 'login_page.dart';

/// Hangi ekranın gösterileceği. **Tek karar noktası**: biyometrik kilit, yerel mod, zorunlu parola
/// değişimi ve Kullanıcı Sözleşmesi onayı burada çözülür.
enum AuthGateView {
  /// Durum henüz hazır değil **veya** biyometrik kilit açık: panonun hiçbir türü açılmaz.
  splash,
  login,
  dashboard,

  /// Oturumsuz yerel (LAN) mod.
  localDashboard,

  /// Sunucu parola değişimini zorunlu kıldı.
  forcedPasswordChange,

  /// Kullanıcı Sözleşmesi'nin güncel sürümü onaylanmalı (`user.legal.needs_acceptance`; yalnız bulut kipinde, personel ve
  /// servis PIN oturumu hariç).
  termsAcceptance,
}

/// [state]'e göre gösterilecek görünümü belirler.
///
/// * `checking` (başlatma **ve** biyometrik kilit) -> [AuthGateView.splash]: yerel mod dahil hiçbir
///   pano açılmaz (kilitli oturumda doğrudan mod ile kilidi atlama kapalıdır).
/// * Yerel pano yalnızca **oturumsuz** (`unauthenticated`) ve doğrudan mod seçiliyken açılır.
/// * Oturum açıkken `mustChangePassword` ise parola değiştirme ekranına zorlanır.
/// * Ardından (parola kapısı ÖNCE gelir) sunucu onay istiyorsa ([AutomationState.needsTermsAcceptance]) Kullanıcı
///   Sözleşmesi onay ekranı gösterilir; yerel ağ (LAN) kipinde, servis PIN oturumunda ve personelde hiç gösterilmez.
@visibleForTesting
AuthGateView gateViewFor(AutomationState state) {
  switch (state.authStatus) {
    case AuthStatus.checking:
      return AuthGateView.splash;
    case AuthStatus.authenticated:
      if (state.mustChangePassword) return AuthGateView.forcedPasswordChange;
      if (state.needsTermsAcceptance) return AuthGateView.termsAcceptance;
      return AuthGateView.dashboard;
    case AuthStatus.unauthenticated:
      return state.mode == AppMode.direct ? AuthGateView.localDashboard : AuthGateView.login;
  }
}

/// Oturum açık (pano) görünümleri: bunların üstüne itilen sayfa/diyaloglar oturumun verisini gösterir.
bool _isSignedInView(AuthGateView? view) => view == AuthGateView.dashboard || view == AuthGateView.localDashboard;

/// Uygulama kapısı: açılışta oturum/biyometrik durumu çözülene kadar açılış ekranını gösterir, sonra
/// giriş, pano (bulut/yerel), zorunlu parola değişimi ya da Kullanıcı Sözleşmesi onay ekranına geçer.
///
/// Açılış ekranı **durum hazır olunca biter**; sabit bir bekleme süresi yoktur.
///
/// **Kilit/oturum geçişinde itilmiş sayfalar kapatılır:** pano görünümünden açılış/kilit ekranına
/// (arka plandan >= 30 sn sonra biyometrik yeniden kilit), girişe (oturum kapandı), zorunlu parola ya da sözleşme onay
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
      case AuthGateView.termsAcceptance:
        screen = const TermsAcceptancePage(key: ValueKey('terms_acceptance_screen'));
    }

    // Geçiş sürerken çıkan ve giren tam ekran birlikte canlı kalır (iki ekran ağacı); kısa tutulur (PF-12).
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      child: screen,
    );
  }
}

/// Açılış ekranının okuduğu durum parçası: yalnız bu dört alan değişince ekran yeniden kurulur (PF-21).
/// `failure`: son doğrulamanın başarısızlık nedeni (kilit ekranı nedeni söyler; `biometricFailed` ile birlikte değişir).
typedef _SplashView = ({bool failed, bool checking, String label, BiometricFailure? failure});

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
    // Yalnız biyometrik alanlar okunur: ilgisiz durum bildirimleri (cihaz varlığı, REST yenilemeleri, tema...)
    // açılış ekranını yeniden kurmaz. Eylemler (yeniden dene / şifre ile giriş) güncel durumu
    // basış anında `context.read` ile alır (PF-21).
    final view = context.select<AutomationState, _SplashView>(
      (s) => (
        failed: s.biometricFailed,
        checking: s.biometricChecking,
        label: s.biometricLabel,
        failure: s.biometricService.lastFailure,
      ),
    );
    final showBiometricRetry = view.failed;

    // Açılış/kilit ekranı kullanıcının TEMA seçimine uyar (zemin, başlık, hap); orta panel ise bilinçli olarak her
    // temada koyu camdır (güvenlik/kilit paneli; içindeki metin ve düğmeler koyu zemin için tasarlandı).
    final dark = AppTheme.isDark(context);
    final base = AppTheme.getScaffoldBg(context);
    final bgAsset = dark ? 'assets/images/ai_circuit_bg.jpg' : 'assets/images/ai_circuit_bg_light.jpg';
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: base,
      body: Stack(
        children: [
          // Statik arka plan (JPEG + karartma gradyanı) TEK yeniden-çizim sınırında: sayfada yeniden boyanan bir
          // şey (gösterge, geçiş) bu katmanı yeniden kaydettirmez. Resim üç yerde (küresel arka plan, açılış,
          // giriş) AYNI yolla ve çözümleme boyutu verilmeden yüklenir: tek ImageCache girdisi paylaşılır (PF-15 b).
          Positioned.fill(
            child: RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    bgAsset,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(color: base),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // Koyu: canlı devre görseli (marka açılışı); açık: giriş ekranının açık örtüsü (iki ekran aynı netlikte).
                        colors: dark
                            ? [base.withValues(alpha: 0.35), base.withValues(alpha: 0.50), base.withValues(alpha: 0.70)]
                            : [base.withValues(alpha: 0.55), base.withValues(alpha: 0.80), base.withValues(alpha: 0.94)],
                        stops: const [0.0, 0.50, 1.0],
                      ),
                    ),
                  ),
                ],
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
                    // Logo giriş koreografisi: ölçek + solma, ardından tek seferlik parıltı halkası (AuthLogoMark).
                    const AuthLogoMark(size: 130, splash: true),
                    const SizedBox(height: 28),
                    StaggeredEntrance(
                      index: 1,
                      step: const Duration(milliseconds: 80),
                      child: Text(
                        'AHBU OTOMASYON',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.5,
                          color: AppTheme.getTextPrimary(context),
                          shadows: dark ? [Shadow(color: AppFamilies.cyan.base, blurRadius: 18)] : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    StaggeredEntrance(
                      index: 2,
                      step: const Duration(milliseconds: 80),
                      child: _TaglinePill(dark: dark, base: base),
                    ),
                    const SizedBox(height: 36),
                    StaggeredEntrance(
                      index: 3,
                      step: const Duration(milliseconds: 80),
                      // Panel içi düğme etiketleri (ör. kilit ekranındaki "... ile Aç") diğer birincil düğmelerle AYNI
                      // tipografide: tema `labelLarge` kalın. (Metinlere/mantığa dokunulmaz; yalnız kapsamlı tema.)
                      child: _SplashPanel(
                        child: Theme(
                          data: theme.copyWith(
                            textTheme: theme.textTheme.copyWith(
                              labelLarge: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                          child: showBiometricRetry ? _buildBiometricFailed(context, view) : _buildChecking(context, view),
                        ),
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

  Widget _buildBiometricFailed(BuildContext context, _SplashView view) {
    return Column(
      key: const Key('biometric_locked'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Biyometrik kilit: orb parmak izi simgesi (amber, nefes alır; ambient yalnız MotionScope full'de).
        const OrbIconBadge(icon: Icons.fingerprint_rounded, family: AppFamilies.amber, size: OrbSize.lg, active: true),
        const SizedBox(height: 14),
        Text(
          biometricFailureMessage(view.failure, label: view.label),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: AppTheme.accentAmber, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const Key('btn_biometric_retry'),
            onPressed: () => unawaited(context.read<AutomationState>().retryBiometricAuth()),
            icon: const Icon(Icons.fingerprint_rounded, size: 20),
            label: Text('${view.label} ile Aç'),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          key: const Key('btn_biometric_fallback'),
          // Şifre ile girişe düşmek oturumu kapatır (belirteçler silinir): onay istenir.
          onPressed: () => unawaited(confirmAndLogout(context, context.read<AutomationState>())),
          child: const Text(
            'Şifre ile Giriş Yap',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildChecking(BuildContext context, _SplashView view) {
    return Column(
      key: const Key('splash_checking'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Sürekli dönen gösterge KENDİ yeniden-çizim sınırında: her karede yalnız 20x20'lik katman yeniden
            // kaydedilir; sayfa (logo halkası + büyük bulanık gölgeler, metin gölgesi, panel gölgesi) boyanmaz.
            RepaintBoundary(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2, valueColor: AlwaysStoppedAnimation<Color>(AppFamilies.cyan.base)),
              ),
            ),
            const SizedBox(width: 14),
            // Metin ortalı ve en uzun satır genişliğinde: iki satıra sarılınca sağda boş şerit kalmaz.
            Flexible(
              child: Text(
                'Oturum güvenli şekilde doğrulanıyor...',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textWidthBasis: TextWidthBasis.longestLine,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppFamilies.slate.light),
              ),
            ),
          ],
        ),
        if (_slow && !view.checking) ...[
          const SizedBox(height: 16),
          Text(
            'Başlatma beklenenden uzun sürüyor. Bekleyebilir ya da şifre ile giriş yapabilirsiniz.',
            key: const Key('splash_slow_notice'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppFamilies.amber.base, height: 1.35),
          ),
          TextButton(
            key: const Key('btn_splash_fallback'),
            onPressed: () => unawaited(confirmAndLogout(context, context.read<AutomationState>())),
            child: const Text('Şifre ile Giriş Yap', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          ),
        ],
      ],
    );
  }
}

/// Açılış/kilit ekranının alt başlık hapı: opak koyu/açık taban + vurgu tonu (devre izleri metnin altından
/// geçmez), >= 12 sp, harf aralığı 1.2. Metin TEK satırdır: büyük yazı ölçeğinde `FittedBox(scaleDown)` küçültür
/// ("YAŞAM" tek başına ikinci satıra düşmez); 2.0 ölçekte bile ~12 sp'de kalır.
class _TaglinePill extends StatelessWidget {
  const _TaglinePill({required this.dark, required this.base});

  final bool dark;
  final Color base;

  @override
  Widget build(BuildContext context) {
    final sky = AppFamilies.sky;
    final fill = Color.alphaBlend(sky.base.withValues(alpha: dark ? 0.28 : 0.14), dark ? base : SurfaceTokens.light.cardTop);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: (dark ? sky.light : sky.deep).withValues(alpha: 0.40), width: 1),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          'YAPAY ZEKA DESTEKLİ AKILLI YAŞAM',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: dark ? sky.light : sky.deep),
        ),
      ),
    );
  }
}

/// Açılış/kilit ekranının orta paneli: HER temada koyu camsı yüzey ([SurfaceTokens.dark]: opak gradyan + rim +
/// gölge). Arkadaki parlak devre izleri metnin/orb'un arkasından görünmez (eskiden %70 saydam düz kutuydu).
/// Boyama izolasyonu: panel kendi `RepaintBoundary`'sindedir; içindeki dönen gösterge paneli yeniden boyatmaz.
class _SplashPanel extends StatelessWidget {
  const _SplashPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const t = SurfaceTokens.dark;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: SizedBox(
        width: double.infinity,
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.cardBottom,
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [t.cardTop, t.cardBottom]),
              borderRadius: BorderRadius.circular(AppRadius.card),
              boxShadow: [BoxShadow(color: t.shadow, blurRadius: t.shadowBlur, offset: t.shadowOffset)],
            ),
            child: CustomPaint(
              foregroundPainter: SurfaceRimPainter(
                radius: AppRadius.card,
                rimStart: t.rimStart,
                rimEnd: t.rimEnd,
                accent: AppFamilies.sky.base,
              ),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22), child: child),
            ),
          ),
        ),
      ),
    );
  }
}
