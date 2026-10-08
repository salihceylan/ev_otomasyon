import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../../utils/magic_link_parser.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart' show authPrimaryLabel;
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';

/// Sayfanın durumdan okuduğu oturum kapısı değerleri (PF-06: `context.select`).
typedef _GateView = ({bool isAuthenticated, bool checking});

/// E-postadaki sihirli bağlantıyla (`#token=`) giriş ya da şifre sıfırlama (CONTRACTS §1.1b).
///
/// * `magicLogin`: oturum yokken bağlantı açılır açılmaz giriş yapılır; zaten bir oturum açıksa
///   (hesap değişimi) önce **onay** istenir. Belirteç tek kullanımlıktır: otomatik yeniden deneme yok.
/// * `resetPassword`: yeni şifre (politika: en az 10 karakter, kırpılmaz) ister ve belirteçle sıfırlar. Sunucu
///   sıfırlama yanıtında bağlantının hesabıyla oturum açtığından, zaten bir oturum açıksa magic-login'deki ile
///   AYNI uyarı ve onay istenir; onaysız oturum değişmez (UYELIK-05).
/// * İki kol da açılış / biyometrik kilit sürerken (oturum durumu bilinmiyor) bekler: istek atılmaz, kilit
///   atlatılmaz (UYELIK-K2).
///
/// Belirteç ekranda gösterilmez ve loglanmaz.
///
/// Görünüm: orb rozetinin altındaki tüm metin ve eylemler TEK cam plakada ([SurfaceCard]) durur (devre fotoğrafı
/// metnin altından geçmez); yükleme göstergesi marka yayıdır ([ProgressArc]).
class MagicLinkPage extends StatefulWidget {
  const MagicLinkPage({super.key, required this.link});

  final MagicLink link;

  @override
  State<MagicLinkPage> createState() => _MagicLinkPageState();
}

class _MagicLinkPageState extends State<MagicLinkPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _busy = false;
  bool _consumed = false;
  bool _obscure = true;
  bool _obscureConfirm = true;
  String? _error;
  String? _success;

  /// Şifre sıfırlama: oturum açıkken kullanıcı "mevcut oturum kapanır" uyarısını onayladı (UYELIK-05).
  bool _resetConfirmed = false;

  /// Açılış / biyometrik kilit sürerken durumu izlenen oturum durumu (giriş kararı bekler).
  AutomationState? _gateState;

  bool get _isLogin => widget.link.kind == MagicLinkKind.magicLogin;

  @override
  void initState() {
    super.initState();
    if (_isLogin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _decideLogin(context.read<AutomationState>());
      });
    }
  }

  @override
  void dispose() {
    _gateState?.removeListener(_onGateChanged);
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  /// Giriş kararı: oturum durumu bilinmeden (açılış ya da biyometrik kilit sürerken) istek atılmaz;
  /// kilit atlatılmaz ve kayıtlı oturum sessizce değiştirilmez. Zaten oturum açıksa (hesap değişimi)
  /// kullanıcı onayı beklenir.
  void _decideLogin(AutomationState state) {
    if (state.authStatus == AuthStatus.checking) {
      _gateState = state..addListener(_onGateChanged);
      return;
    }
    if (!state.isAuthenticated) unawaited(_runMagicLogin());
  }

  void _onGateChanged() {
    final state = _gateState;
    if (state == null || !mounted || state.authStatus == AuthStatus.checking) return;
    state.removeListener(_onGateChanged);
    _gateState = null;
    if (!state.isAuthenticated) unawaited(_runMagicLogin());
  }

  void _leave() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _runMagicLogin() async {
    if (_busy || _consumed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AutomationState>().loginWithMagicLink(widget.link.token);
      if (!mounted) return;
      _consumed = true;
      _leave();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _linkError(e);
      });
    }
  }

  String _linkError(Object e) {
    if (e is ApiException && e.isAccountPending) {
      return '${friendlyError(e)} $kAccountActivationHint'; // davet bekleyen hesap (uyelik-10)
    }
    if (e is ApiException && (e.isGone || e.statusCode == 400 || e.isUnauthorized)) {
      return 'Bu bağlantının süresi dolmuş veya daha önce kullanılmış. Yeni bir bağlantı isteyin.';
    }
    return friendlyError(e, fallback: 'Bağlantıyla işlem tamamlanamadı. Lütfen tekrar deneyin.');
  }

  Future<void> _submitReset() async {
    if (_busy || _consumed) return;
    final state = context.read<AutomationState>();
    // Savunma (görünüm zaten formu göstermez): oturum durumu bilinmeden (açılış / biyometrik kilit) ya da açık oturum
    // onaysızken sıfırlama gönderilmez; yanıt oturum taşıyıp mevcut oturumu değiştirebilir.
    if (state.authStatus == AuthStatus.checking) return;
    if (state.isAuthenticated && !_resetConfirmed) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Şifre KIRPILMAZ.
      final adopted = await state.resetPassword(token: widget.link.token, newPassword: _passwordController.text);
      if (!mounted) return;
      _consumed = true;
      // Mesaj dönen duruma göre: sunucu oturum verdiyse otomatik giriş yapılmıştır (bağlantının hesabı açıldı).
      // Vermediyse (açık oturum sürüyor olsa bile) sessizce kapanılmaz: başarı iletisi gösterilir.
      if (adopted && state.isAuthenticated) {
        _leave();
        return;
      }
      setState(() {
        _busy = false;
        _success = 'Şifreniz yenilendi. Yeni şifrenizle giriş yapabilirsiniz.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _linkError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final gate = context.select<AutomationState, _GateView>(
      (s) => (isAuthenticated: s.isAuthenticated, checking: s.authStatus == AuthStatus.checking),
    );
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        // Ortak Neon Glass üst çubuk (cam geri diski + başlık); işlem sürerken geri düğmesi yok (`PopScope` ile aynı kapı).
        appBar: NeonAppBar(title: _isLogin ? 'Bağlantıyla Giriş' : 'Yeni Şifre Belirle', automaticallyImplyLeading: !_busy),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: _isLogin ? _buildLogin(gate) : _buildReset(gate),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Marka yükleme göstergesi (stok çark yerine [ProgressArc]; `MotionMode.off`'ta statik yay).
  Widget _progress(Key key) => Center(
    child: ProgressArc(
      key: key,
      diameter: 36,
      strokeWidth: 3.2,
      color: AppTheme.isDark(context) ? AppFamilies.cyan.light : AppFamilies.sky.deep,
      maxSpin: const Duration(seconds: 60),
    ),
  );

  Widget _buildLogin(_GateView gate) {
    final needsConfirm = gate.isAuthenticated && !_busy && !_consumed;
    final waitingForGate = gate.checking && !_busy && !_consumed && _error == null;
    final muted = AppTheme.getTextMuted(context);
    return Column(
      key: const Key('magic_login_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StaggeredEntrance(
          index: 0,
          step: Duration(milliseconds: 70),
          child: Center(
            child: OrbIconBadge(icon: Icons.link_rounded, family: AppFamilies.cyan, size: OrbSize.xl, glow: true),
          ),
        ),
        const SizedBox(height: 16),
        StaggeredEntrance(
          index: 1,
          step: const Duration(milliseconds: 70),
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (waitingForGate) ...[
                  _progress(const Key('magic_login_waiting')),
                  const SizedBox(height: 16),
                  Text(
                    'Oturum durumu kontrol ediliyor. Uygulama kilitliyse önce kilidi açın...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 13, height: 1.4),
                  ),
                  TextButton(key: const Key('btn_magic_login_cancel'), onPressed: _leave, child: const Text('Vazgeç')),
                ] else if (_busy)
                  Column(
                    children: [
                      _progress(const Key('magic_login_progress')),
                      const SizedBox(height: 16),
                      Text(
                        'Giriş yapılıyor...',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted, fontSize: 13, height: 1.4),
                      ),
                    ],
                  )
                else if (needsConfirm) ...[
                  InlineMessage.warning(
                    'Bu cihazda şu anda başka bir hesap açık. Bağlantıyla giriş yaparsanız mevcut oturum kapanır '
                    've bağlantının hesabı açılır.',
                    key: const Key('magic_login_confirm_notice'),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    key: const Key('btn_magic_login_confirm'),
                    onPressed: _runMagicLogin,
                    child: authPrimaryLabel('Bu Bağlantıyla Giriş Yap'),
                  ),
                  TextButton(key: const Key('btn_magic_login_cancel'), onPressed: _leave, child: const Text('Vazgeç')),
                ],
                if (_error != null) ...[
                  if (waitingForGate || _busy || needsConfirm) const SizedBox(height: 16),
                  InlineMessage.error(_error!, key: const Key('magic_login_error')),
                  const SizedBox(height: 12),
                  if (!_consumed)
                    ElevatedButton(
                      key: const Key('btn_magic_login_retry'),
                      onPressed: _runMagicLogin,
                      child: authPrimaryLabel('Tekrar Dene'),
                    ),
                  TextButton(key: const Key('btn_magic_login_back'), onPressed: _leave, child: const Text('Giriş Ekranına Dön')),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Şifre sıfırlamadan ÖNCEKİ kapı (UYELIK-K2 / UYELIK-05): açılış / biyometrik kilit sürerken bekleme; oturum
  /// açıkken magic-login'deki ile aynı "mevcut oturum kapanır" uyarısı ve onayı. Gerekmiyorsa `null` (form).
  Widget? _buildResetGate(_GateView gate) {
    if (_busy || _consumed) return null;
    final waitingForGate = gate.checking;
    final needsConfirm = !waitingForGate && gate.isAuthenticated && !_resetConfirmed;
    if (!waitingForGate && !needsConfirm) return null;
    final muted = AppTheme.getTextMuted(context);
    return Column(
      key: const Key('magic_reset_gate'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StaggeredEntrance(
          index: 0,
          step: Duration(milliseconds: 70),
          child: Center(
            child: OrbIconBadge(icon: Icons.lock_reset_rounded, family: AppFamilies.sky, size: OrbSize.xl, glow: true),
          ),
        ),
        const SizedBox(height: 16),
        StaggeredEntrance(
          index: 1,
          step: const Duration(milliseconds: 70),
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (waitingForGate) ...[
                  _progress(const Key('magic_reset_waiting')),
                  const SizedBox(height: 16),
                  Text(
                    'Oturum durumu kontrol ediliyor. Uygulama kilitliyse önce kilidi açın...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 13, height: 1.4),
                  ),
                ] else ...[
                  InlineMessage.warning(
                    'Bu cihazda şu anda başka bir hesap açık. Bağlantıyla şifre yenilerseniz mevcut oturum kapanır '
                    've bağlantının hesabı açılır.',
                    key: const Key('magic_reset_confirm_notice'),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    key: const Key('btn_magic_reset_confirm'),
                    onPressed: () => setState(() => _resetConfirmed = true),
                    child: authPrimaryLabel('Bu Bağlantıyla Devam Et'),
                  ),
                ],
                TextButton(key: const Key('btn_magic_reset_cancel'), onPressed: _leave, child: const Text('Vazgeç')),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReset(_GateView gate) {
    final pending = _buildResetGate(gate);
    if (pending != null) return pending;
    if (_success != null) {
      return Column(
        key: const Key('magic_reset_done'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StaggeredEntrance(
            index: 0,
            step: Duration(milliseconds: 70),
            child: Center(
              child: OrbIconBadge(icon: Icons.check_rounded, family: AppFamilies.emerald, size: OrbSize.xl, glow: true),
            ),
          ),
          const SizedBox(height: 16),
          StaggeredEntrance(
            index: 1,
            step: const Duration(milliseconds: 70),
            child: SurfaceCard(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InlineMessage.success(_success!, key: const Key('magic_reset_success')),
                  const SizedBox(height: 16),
                  ElevatedButton(key: const Key('btn_magic_reset_done'), onPressed: _leave, child: authPrimaryLabel('Giriş Ekranına Dön')),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return Form(
      key: _formKey,
      child: Column(
        key: const Key('magic_reset_view'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StaggeredEntrance(
            index: 0,
            step: Duration(milliseconds: 70),
            child: Center(
              child: OrbIconBadge(icon: Icons.lock_reset_rounded, family: AppFamilies.sky, size: OrbSize.xl, glow: true),
            ),
          ),
          const SizedBox(height: 16),
          StaggeredEntrance(
            index: 1,
            step: const Duration(milliseconds: 70),
            child: SurfaceCard(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Hesabınız için yeni bir şifre belirleyin.',
                    style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    key: const Key('field_new_password'),
                    controller: _passwordController,
                    enabled: !_busy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.newPassword],
                    style: TextStyle(color: AppTheme.getTextPrimary(context)),
                    // Şifre kuralı diğer üç akıştaki gibi ALAN ALTINDA yardımcı metinde (yazarken kural görünür kalır);
                    // eskiden açıklama paragrafının içinde kalıyordu.
                    decoration: authInputDecoration(
                      context,
                      label: 'Yeni Şifre',
                      helper: 'En az ${AuthValidators.passwordMinLength} karakter',
                      prefixIcon: Icons.lock_outline_rounded,
                      suffixIcon: passwordVisibilityButton(
                        context: context,
                        obscured: _obscure,
                        onToggle: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => AuthValidators.passwordPolicyError(v, emptyMessage: 'Lütfen yeni şifrenizi girin'),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    key: const Key('field_confirm_password'),
                    controller: _confirmController,
                    enabled: !_busy,
                    obscureText: _obscureConfirm,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: TextStyle(color: AppTheme.getTextPrimary(context)),
                    decoration: authInputDecoration(
                      context,
                      label: 'Yeni Şifre Tekrar',
                      prefixIcon: Icons.verified_user_outlined,
                      suffixIcon: passwordVisibilityButton(
                        context: context,
                        obscured: _obscureConfirm,
                        onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Lütfen şifrenizi tekrar girin';
                      if (v != _passwordController.text) return 'Şifreler eşleşmiyor';
                      return null;
                    },
                  ),
                  if (_error != null) ...[const SizedBox(height: 14), InlineMessage.error(_error!, key: const Key('magic_reset_error'))],
                  const SizedBox(height: 22),
                  ElevatedButton(
                    key: const Key('btn_magic_reset_submit'),
                    onPressed: _busy ? null : _submitReset,
                    child: _busy ? buttonSpinner() : authPrimaryLabel('Şifreyi Yenile'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
