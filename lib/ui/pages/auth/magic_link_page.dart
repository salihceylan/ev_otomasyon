import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../../utils/magic_link_parser.dart';
import '../../common/auth_form.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';

/// E-postadaki sihirli bağlantıyla (`#token=`) giriş ya da şifre sıfırlama (CONTRACTS §1.1b).
///
/// * `magicLogin`: oturum yokken bağlantı açılır açılmaz giriş yapılır; zaten bir oturum açıksa
///   (hesap değişimi) önce **onay** istenir. Belirteç tek kullanımlıktır: otomatik yeniden deneme yok.
/// * `resetPassword`: yeni şifre (politika: en az 10 karakter, kırpılmaz) ister ve belirteçle sıfırlar.
///
/// Belirteç ekranda gösterilmez ve loglanmaz.
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
  String? _error;
  String? _success;

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
    if (e is ApiException && (e.isGone || e.statusCode == 400 || e.isUnauthorized)) {
      return 'Bu bağlantının süresi dolmuş veya daha önce kullanılmış. Yeni bir bağlantı isteyin.';
    }
    return friendlyError(e, fallback: 'Bağlantıyla işlem tamamlanamadı. Lütfen tekrar deneyin.');
  }

  Future<void> _submitReset() async {
    if (_busy || _consumed) return;
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AutomationState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Şifre KIRPILMAZ.
      await state.resetPassword(token: widget.link.token, newPassword: _passwordController.text);
      if (!mounted) return;
      _consumed = true;
      // Mesaj dönen duruma göre: sunucu oturum verdiyse otomatik giriş yapılmıştır.
      if (state.isAuthenticated) {
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
    final state = context.watch<AutomationState>();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isLogin ? 'Bağlantıyla Giriş' : 'Yeni Şifre Belirle'),
          automaticallyImplyLeading: !_busy,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: _isLogin ? _buildLogin(state) : _buildReset(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogin(AutomationState state) {
    final needsConfirm = state.isAuthenticated && !_busy && !_consumed;
    final waitingForGate = state.authStatus == AuthStatus.checking && !_busy && !_consumed && _error == null;
    return Column(
      key: const Key('magic_login_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.link_rounded, size: 56, color: AppTheme.primaryBlueLight),
        const SizedBox(height: 16),
        if (waitingForGate) ...[
          const Center(child: CircularProgressIndicator(key: Key('magic_login_waiting'))),
          const SizedBox(height: 16),
          const Text(
            'Oturum durumu kontrol ediliyor. Uygulama kilitliyse önce kilidi açın...',
            textAlign: TextAlign.center,
          ),
          TextButton(
            key: const Key('btn_magic_login_cancel'),
            onPressed: _leave,
            child: const Text('Vazgeç'),
          ),
        ] else if (_busy)
          const Column(
            children: [
              Center(child: CircularProgressIndicator(key: Key('magic_login_progress'))),
              SizedBox(height: 16),
              Text('Giriş yapılıyor...', textAlign: TextAlign.center),
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
            child: const Text('Bu Bağlantıyla Giriş Yap'),
          ),
          TextButton(
            key: const Key('btn_magic_login_cancel'),
            onPressed: _leave,
            child: const Text('Vazgeç'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          InlineMessage.error(_error!, key: const Key('magic_login_error')),
          const SizedBox(height: 12),
          if (!_consumed)
            ElevatedButton(
              key: const Key('btn_magic_login_retry'),
              onPressed: _runMagicLogin,
              child: const Text('Tekrar Dene'),
            ),
          TextButton(
            key: const Key('btn_magic_login_back'),
            onPressed: _leave,
            child: const Text('Giriş Ekranına Dön'),
          ),
        ],
      ],
    );
  }

  Widget _buildReset() {
    if (_success != null) {
      return Column(
        key: const Key('magic_reset_done'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle_outline, size: 56, color: AppTheme.accentGreen),
          const SizedBox(height: 16),
          InlineMessage.success(_success!, key: const Key('magic_reset_success')),
          const SizedBox(height: 16),
          ElevatedButton(
            key: const Key('btn_magic_reset_done'),
            onPressed: _leave,
            child: const Text('Giriş Ekranına Dön'),
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
          const Icon(Icons.lock_reset_rounded, size: 56, color: AppTheme.primaryBlueLight),
          const SizedBox(height: 16),
          Text(
            'Hesabınız için yeni bir şifre belirleyin. Şifre en az ${AuthValidators.passwordMinLength} karakter olmalıdır.',
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
            decoration: authInputDecoration(
              context,
              label: 'Yeni Şifre',
              prefixIcon: Icons.lock_outline,
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
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: authInputDecoration(context, label: 'Yeni Şifre Tekrar', prefixIcon: Icons.lock_reset),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Lütfen şifrenizi tekrar girin';
              if (v != _passwordController.text) return 'Şifreler eşleşmiyor';
              return null;
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            InlineMessage.error(_error!, key: const Key('magic_reset_error')),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            key: const Key('btn_magic_reset_submit'),
            onPressed: _busy ? null : _submitReset,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: _busy ? buttonSpinner() : const Text('Şifreyi Yenile', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
