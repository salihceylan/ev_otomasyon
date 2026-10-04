import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart' show authPrimaryLabel;
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';
import '../wifi_recovery_dialog.dart';
import 'auth_brand.dart';
import 'forgot_password_dialog.dart';
import 'magic_link_dialog.dart';
import 'phone_otp_dialog.dart';
import 'register_page.dart';
import 'service_pin_dialog.dart';
import 'social_sign_in.dart';

/// Giriş ekranı: e-posta + şifre, Google, Apple (yalnızca iOS/macOS), SMS kodu (yalnız sunucu `sms_otp`
/// yeteneğini bildirirse), servis PIN'i, yerel mod.
///
/// * Giriş formu yalnızca **boş mu** kontrolü yapar (en az uzunluk politikası kayıtta); şifre
///   **kırpılmaz**, e-posta kırpılır.
/// * Hatalar `friendlyError` ile Türkçe gösterilir; hız sınırında (429) geri sayım ve düğme kilidi.
/// * Oturum süresi dolduysa (`sessionNotice`) açıklayıcı bir ileti gösterilir.
///
/// Görsel hiyerarşi (WP-F4): birincil eylem "Giriş Yap" gradyan düğmesidir. Alternatif girişler iki gruptur:
/// hesapla giriş yöntemleri (Google, Apple, SMS, e-posta bağlantısı) renkli orb'lu cam satırlar; nadir kullanılan
/// **servis ve kurulum** araçları (servis PIN'i, pano Wi-Fi kurulumu, yerel ağ modu) "Servis ve kurulum" başlığı
/// altında sade (nötr slate orb, saydam zemin) satırlardır: altı doygun orb birincil eylemle yarışmaz.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.googleIdTokenProvider, this.appleProvider});

  /// Yalnızca testlerde: Google kimlik jetonu sağlayıcısı (`null` dönerse kullanıcı vazgeçmiştir).
  final Future<String?> Function()? googleIdTokenProvider;

  /// Yalnızca testlerde: Apple kimlik bilgisi sağlayıcısı (`null` dönerse kullanıcı vazgeçmiştir).
  final Future<AppleSignInResult?> Function()? appleProvider;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final Cooldown _loginCooldown;

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _error;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  /// Sunucu telefonla (SMS kodu) girişi destekliyor mu (`GET /auth/capabilities` -> `sms_otp`; UYELIK-04). Yanıt
  /// gelene kadar ve uç yoksa / hata alınırsa düğme GİZLİDİR (fail-closed): SMS göndericisi bağlı olmayan sunucuda
  /// her denemesi 503 olan ölü bir seçenek sunulmaz. Form yanıtı beklemez.
  bool _smsOtpAvailable = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _loginCooldown = Cooldown(state.clock, () {
      if (mounted) setState(() {});
    });
    final known = state.authCapabilities;
    if (known != null) {
      _smsOtpAvailable = known.smsOtp;
    } else {
      unawaited(
        state.loadAuthCapabilities().then((caps) {
          if (mounted && caps.smsOtp != _smsOtpAvailable) setState(() => _smsOtpAvailable = caps.smsOtp);
        }),
      );
    }
  }

  @override
  void dispose() {
    _loginCooldown.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _applyRateLimit(Object e) {
    if (e is ApiException && e.isRateLimited) {
      final wait = e.retryAfter ?? e.resendAfter;
      if (wait != null) _loginCooldown.start(wait);
    }
  }

  Future<void> _handleLogin() async {
    if (_isLoading || _loginCooldown.isActive) return;
    setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final state = context.read<AutomationState>();
      // E-posta kırpılır; şifre ASLA kırpılmaz (başında/sonunda boşluk geçerli olabilir).
      await state.login(_emailController.text.trim(), _passwordController.text);
      // Başarıda AuthGate otomatik panele geçirir.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Giriş yapılamadı. Lütfen tekrar deneyin.'));
      _applyRateLimit(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final provider = widget.googleIdTokenProvider ?? SocialSignIn.googleIdToken;
      final idToken = await provider();
      if (idToken == null || !mounted) return; // kullanıcı vazgeçti
      // İstemci jetonsuz e-posta göndermez: yalnızca doğrulanmış kimlik jetonu.
      await context.read<AutomationState>().loginWithGoogle(idToken: idToken);
    } on SocialAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Google ile giriş başarısız oldu. Lütfen tekrar deneyin.'));
      _applyRateLimit(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleAppleSignIn() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final provider = widget.appleProvider ?? SocialSignIn.apple;
      final result = await provider();
      if (result == null || !mounted) return; // iptal: sessiz
      await context.read<AutomationState>().loginWithApple(
            identityToken: result.identityToken,
            fullName: result.fullName,
            nonce: result.rawNonce,
          );
    } on SocialAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Apple ile giriş başarısız oldu. Lütfen tekrar deneyin.'));
      _applyRateLimit(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleDirectMode() async {
    if (_isLoading) return;
    final state = context.read<AutomationState>();
    final ok = await state.setMode(AppMode.direct);
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = 'Yerel ağ moduna geçilemedi.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = context.select<AutomationState, String?>((s) => s.sessionNotice);
    final cooling = _loginCooldown.isActive;
    final dark = AppTheme.isDark(context);
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    final link = AppTheme.infoText(context);
    // Zemin temaya uyar: koyu = marka devre kartı JPEG'i + koyu karartma, açık = açık devre JPEG'i + açık örtü.
    final base = AppTheme.getScaffoldBg(context);
    final bgAsset = dark ? 'assets/images/ai_circuit_bg.jpg' : 'assets/images/ai_circuit_bg_light.jpg';

    return Scaffold(
      backgroundColor: base,
      body: Stack(
        children: [
          // Statik arka plan (JPEG + karartma gradyanı) TEK yeniden-çizim sınırında; resim açılış ekranı ve küresel
          // arka planla AYNI yol ve çözümleme boyutu verilmeden yüklenir (tek ImageCache girdisi; PF-15).
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
                        colors: dark
                            ? [base.withValues(alpha: 0.65), base.withValues(alpha: 0.88), base.withValues(alpha: 0.98)]
                            : [base.withValues(alpha: 0.55), base.withValues(alpha: 0.80), base.withValues(alpha: 0.94)],
                        stops: const [0.0, 0.40, 0.85],
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
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      autovalidateMode: _autovalidate,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 12),
                          const AuthLogoMark(size: 104),
                          const SizedBox(height: 20),
                          StaggeredEntrance(
                            index: 1,
                            step: const Duration(milliseconds: 70),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'AHBU OTOMASYON',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2,
                                    color: primary,
                                    shadows: dark ? [Shadow(color: AppFamilies.cyan.base.withValues(alpha: 0.85), blurRadius: 14)] : null,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Yapay Zeka Destekli Akıllı Yaşam',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.5, color: link),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 28),
                          // Giriş formu: camsı kart (kenar ışığı + yumuşak gölge); alan çerçevesi/odak halkası authInputDecoration'dan.
                          StaggeredEntrance(
                            index: 2,
                            step: const Duration(milliseconds: 70),
                            child: SurfaceCard(
                              padding: const EdgeInsets.fromLTRB(18, 20, 18, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (notice != null) ...[
                                    InlineMessage.warning(
                                      notice,
                                      key: const Key('login_session_notice'),
                                      // "Tamam" mesaj metniyle AYNI sol kenardan başlar (TextButton'ın 12 dp iç boşluğu
                                      // etiketi metnin 12 dp içine itiyordu); hedef yine ≥ 48 dp.
                                      trailing: TextButton(
                                        key: const Key('btn_dismiss_notice'),
                                        onPressed: () => context.read<AutomationState>().clearSessionNotice(),
                                        style: TextButton.styleFrom(
                                          padding: EdgeInsets.zero,
                                          alignment: AlignmentDirectional.centerStart,
                                          minimumSize: const Size(AppTouch.minTarget, AppTouch.minTarget),
                                        ),
                                        child: const Text('Tamam'),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  TextFormField(
                                    key: const Key('field_email'),
                                    controller: _emailController,
                                    enabled: !_isLoading,
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.next,
                                    autofillHints: const [AutofillHints.username, AutofillHints.email],
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    style: TextStyle(color: primary),
                                    decoration: authInputDecoration(context, label: 'E-Posta Adresi', prefixIcon: Icons.email_outlined),
                                    validator: AuthValidators.emailError,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    key: const Key('field_password'),
                                    controller: _passwordController,
                                    enabled: !_isLoading,
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    autofillHints: const [AutofillHints.password],
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    onFieldSubmitted: (_) => _handleLogin(),
                                    style: TextStyle(color: primary),
                                    decoration: authInputDecoration(
                                      context,
                                      label: 'Şifre',
                                      prefixIcon: Icons.lock_outline_rounded,
                                      suffixIcon: passwordVisibilityButton(
                                        key: const Key('btn_toggle_password'),
                                        context: context,
                                        obscured: _obscurePassword,
                                        onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                                      ),
                                    ),
                                    // Giriş formu: yalnızca "boş mu" (min uzunluk politikası kayıtta).
                                    validator: AuthValidators.loginPasswordError,
                                  ),
                                  // "Şifremi Unuttum": hedef 48 dp (TextButton min), görsel boşluk alanlarla aynı ritimde
                                  // (üstte ek boşluk yok, altta 4 dp): bağlantı kartın birincil eylemine aittir.
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      key: const Key('btn_forgot_password'),
                                      onPressed: _isLoading ? null : () => ForgotPasswordDialog.show(context),
                                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4)),
                                      child: Text(
                                        'Şifremi Unuttum',
                                        style: TextStyle(color: link, fontSize: 13, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ),
                                  if (_error != null) ...[
                                    const SizedBox(height: 8),
                                    InlineMessage.error(_error!, key: const Key('login_error')),
                                  ],
                                  SizedBox(height: _error != null ? 16 : 4),
                                  // Birincil düğme: tür ElevatedButton KALIR; gradyan/şekil/gölge temadan gelir.
                                  ElevatedButton(
                                    key: const Key('btn_login'),
                                    onPressed: (_isLoading || cooling) ? null : _handleLogin,
                                    child: _isLoading
                                        ? buttonSpinner()
                                        : Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (cooling) ...[
                                                CooldownArc(remaining: _loginCooldown.remaining, color: muted),
                                                const SizedBox(width: 10),
                                              ],
                                              Flexible(
                                                child: DefaultTextStyle.merge(
                                                  textAlign: TextAlign.center,
                                                  child: authPrimaryLabel(
                                                    cooling ? 'Tekrar dene (${formatCountdown(_loginCooldown.remainingSeconds)})' : 'Giriş Yap',
                                                    // Bekleme: kalan süre TEK bilgi; pasif düğmenin soluk ön planı (≈3.4:1) yerine tam soluk metin.
                                                    color: cooling ? muted : null,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                  const SizedBox(height: 4),
                                  AuthLinkRow(
                                    prompt: 'Hesabınız yok mu? ',
                                    actionLabel: 'Kayıt Olun',
                                    actionKey: const Key('btn_register'),
                                    onTap: _isLoading
                                        ? null
                                        : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterPage())),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          StaggeredEntrance(
                            index: 3,
                            step: const Duration(milliseconds: 70),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const Expanded(child: Divider()),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: Text(
                                        'VEYA',
                                        style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1),
                                      ),
                                    ),
                                    const Expanded(child: Divider()),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                // --- Hesapla giriş yöntemleri: renkli orb'lu cam satırlar ---
                                _altButton(
                                  key: const Key('btn_google_sign_in'),
                                  onPressed: _isLoading ? null : _handleGoogleSignIn,
                                  // Google: kalın "G" harfi (g_mobiledata simgesi orb içinde ~8 dp'lik leke kalıyordu).
                                  badge: _MethodBadge(letter: 'G', family: AppFamilies.sky, enabled: !_isLoading),
                                  label: 'Google ile Devam Et',
                                ),
                                if (SocialSignIn.appleSupported) ...[
                                  const SizedBox(height: 10),
                                  _altButton(
                                    key: const Key('btn_apple_sign_in'),
                                    onPressed: _isLoading ? null : _handleAppleSignIn,
                                    badge: _MethodBadge(icon: Icons.apple_rounded, family: AppFamilies.slate, enabled: !_isLoading),
                                    label: 'Apple ile Giriş Yap',
                                  ),
                                ],
                                // SMS ile giriş: yalnız sunucu `sms_otp` yeteneğini bildirdiyse (bkz. `_smsOtpAvailable`).
                                if (_smsOtpAvailable) ...[
                                  const SizedBox(height: 10),
                                  _altButton(
                                    key: const Key('btn_phone_otp'),
                                    onPressed: _isLoading ? null : () => PhoneOtpDialog.show(context),
                                    badge: _MethodBadge(icon: Icons.sms_rounded, family: AppFamilies.violet, enabled: !_isLoading),
                                    label: 'Telefon Numarası ile Şifresiz Giriş (SMS)',
                                  ),
                                ],
                                const SizedBox(height: 10),
                                _altButton(
                                  key: const Key('btn_magic_link'),
                                  onPressed: _isLoading ? null : () => MagicLinkDialog.show(context),
                                  badge: _MethodBadge(icon: Icons.link_rounded, family: AppFamilies.cyan, enabled: !_isLoading),
                                  label: 'E-postadaki Bağlantım Var',
                                ),
                                // --- Servis ve kurulum araçları: nadir kullanılır, sade (nötr orb, saydam zemin) ---
                                const SizedBox(height: 22),
                                Padding(
                                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                                  child: Text(
                                    'Servis ve kurulum',
                                    style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5),
                                  ),
                                ),
                                _altButton(
                                  key: const Key('btn_service_pin'),
                                  onPressed: _isLoading ? null : () => ServicePinDialog.show(context),
                                  badge: _MethodBadge(icon: Icons.handyman_rounded, family: AppFamilies.slate, glow: false, enabled: !_isLoading),
                                  label: 'Yetkili Servis Girişi (PIN)',
                                  quiet: true,
                                ),
                                const SizedBox(height: 8),
                                // Wi-Fi kurulum/kurtarma: giriş ve internet GEREKMEZ (pano kendi WPA2 kurulum
                                // ağından anahtarsız Wi-Fi uçlarını açar; teknisyen müşteride internetsizdir).
                                _altButton(
                                  key: const Key('btn_wifi_setup'),
                                  onPressed: _isLoading ? null : () => WifiRecoveryDialog.show(context),
                                  badge: _MethodBadge(icon: Icons.router_rounded, family: AppFamilies.slate, glow: false, enabled: !_isLoading),
                                  label: 'Pano Wi-Fi Kurulumu (İnternet Gerekmez)',
                                  quiet: true,
                                ),
                                const SizedBox(height: 8),
                                _altButton(
                                  key: const Key('btn_local_mode'),
                                  onPressed: _isLoading ? null : _handleDirectMode,
                                  badge: _MethodBadge(icon: Icons.lan_rounded, family: AppFamilies.slate, glow: false, enabled: !_isLoading),
                                  label: 'Yerel Ağ Modu (ESP32 Doğrudan Erişim)',
                                  quiet: true,
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
          ),
        ],
      ),
    );
  }

  /// Alternatif giriş satırı: cam yüzeyli [OutlinedButton] (tür/Key/metin sözleşmesi pinli) + soldaki orb rozeti.
  /// Etiket kısaltılmaz (yazı ölçeği 2.0'da alt satırlara iner); satır en az 56 dp ([quiet] satırlar 52 dp).
  /// Köşe yarıçapı kart yarıçapıyla aynıdır ([AppRadius.card]); renkler yüzey belirteçlerindendir.
  Widget _altButton({
    required Key key,
    required VoidCallback? onPressed,
    required Widget badge,
    required String label,
    bool quiet = false,
  }) {
    final dark = AppTheme.isDark(context);
    final tokens = SurfaceTokens.of(dark ? Brightness.dark : Brightness.light);
    return OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.symmetric(vertical: quiet ? 2 : 6, horizontal: 10),
        minimumSize: Size(64, quiet ? 52 : 56),
        side: BorderSide(color: quiet ? tokens.rimSolid : (dark ? tokens.rimStart : tokens.rimSolid)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        // Koyuda ana satırlar yarı saydam cam, sade satırlar saydam; açıkta opaklık yüksek (devre izleri metnin
        // altından geçmesin): ana 0.92, sade 0.55.
        backgroundColor: dark
            ? (quiet ? Colors.transparent : tokens.cardTop.withValues(alpha: 0.62))
            : tokens.cardTop.withValues(alpha: quiet ? 0.55 : 0.92),
      ),
      child: Row(
        children: [
          badge,
          const SizedBox(width: 12),
          Expanded(
            // BalancedText: sarılan etiketin son satırında tek sözcük ("(SMS)", "Gerekmez)") yetim kalmaz; metin DEĞİŞMEZ
            // (aynı `Text.data`).
            child: BalancedText(
              label,
              maxLines: 3,
              style: TextStyle(
                color: quiet ? AppTheme.getTextMuted(context) : AppTheme.getTextPrimary(context),
                fontSize: 14,
                fontWeight: quiet ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Giriş yöntemi rozeti: küçük orb ([OrbSize.sm]) + simge ya da harf ([letter]; marka harfi gibi simge olmayan
/// işaretler için, ör. Google "G"). Etkileşimsizdir (dokunuş satıra geçer) ve anlamdan hariçtir (etiket satırda).
class _MethodBadge extends StatelessWidget {
  const _MethodBadge({this.icon, this.letter, required this.family, this.glow = true, this.enabled = true})
    : assert(icon != null || letter != null);

  final IconData? icon;
  final String? letter;
  final AccentFamily family;

  /// Koyu temada soluk dış parıltı (açık temada orb zaten renkli gölge çizer): koyu/açık aynı derinlik.
  final bool glow;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: OrbSize.sm.diameter,
        child: OrbCore(
          size: OrbSize.sm,
          family: family,
          icon: icon,
          iconBuilder: letter == null
              ? null
              : (context, color, size) => Text(
                  letter!,
                  style: TextStyle(color: color, fontSize: size * 1.12, fontWeight: FontWeight.w800, height: 1.0),
                ),
          enabled: enabled,
          glow: glow,
        ),
      ),
    );
  }
}
