import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';

/// Parola değiştirme ekranı.
///
/// * [forced] `true` (sunucu `must_change_password` dedi; ör. teknisyenin açtığı müşteri hesabı ilk
///   giriş): geri dönülemez, yalnızca parola değiştirilir ya da **çıkış** yapılır. `AuthGate` bu
///   durumda panoyu açmaz; parola değişince bayrak kalkar ve pano otomatik açılır.
/// * Gönüllü kullanımda (profil menüsünden) başarıda sayfa kapanır.
///
/// Parolalar **kırpılmaz**. Sunucu diğer tüm cihazların oturumlarını kapatır ve bu cihaza yeni
/// belirteçler verir (durum katmanı yazar).
///
/// Görünüm: uyarı/açıklama metni, üç alan ve düğme TEK cam plakada ([SurfaceCard]) durur (açık temada devre
/// fotoğrafı uyarı kutusunun altından geçiyordu). Etiketler kısadır; "en az 10 karakter" kuralı yardımcı
/// metindedir ("Yeni Şifre (En a…" gibi kesilmez). Her parola alanının KENDİ göster/gizle düğmesi vardır.
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key, this.forced = false});

  final bool forced;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  String? _error;
  String? _currentFieldError;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _autovalidate = AutovalidateMode.onUserInteraction;
      _currentFieldError = null;
    });
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AutomationState>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.changePassword(currentPassword: _currentController.text, newPassword: _newController.text);
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(
          content: const Text('Şifreniz değiştirildi. Diğer cihazlardaki oturumlar kapatıldı.'),
          // Beyaz iletiyle AA (ham #10B981 ile ~2.5:1'di).
          backgroundColor: AppTheme.filledAccent(AppTheme.accentGreen),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (!widget.forced) navigator.pop(true);
      // forced: bayrak kalktı; AuthGate panoyu kendisi gösterir.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e is ApiException && e.isInvalidCredentials) {
          _currentFieldError = 'Mevcut şifre hatalı.';
        } else {
          _error = friendlyError(e, fallback: 'Şifre değiştirilemedi. Lütfen tekrar deneyin.');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // PF-06: durum yalnız çıkış dokunuşunda gerekir (okuma); sayfa durum bildirimleriyle yeniden kurulmaz.
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);

    return PopScope(
      canPop: !widget.forced && !_busy,
      child: Scaffold(
        // Ortak Neon Glass üst çubuk (cam geri diski + 18/700 başlık): çıplak Material `AppBar` ve mavi "Çıkış" metin
        // düğmesi doğrudan devre fotoğrafı üzerinde duruyordu. Davranış AYNEN: zorunlu kipte (ve işlem sürerken) geri
        // düğmesi YOK (üstte `PopScope` sistem geri tuşunu da kapatır); zorunlu kipte tek çıkış yolu "Çıkış" eylemidir
        // (anahtar `btn_forced_logout`; cam disk + ipucu/anlam etiketi "Çıkış"). Sayfa gövdesinde büyük orb olduğundan
        // çubukta özellik orb'u YOK.
        appBar: NeonAppBar(
          title: widget.forced ? 'Şifrenizi Değiştirin' : 'Şifre Değiştir',
          automaticallyImplyLeading: !widget.forced && !_busy,
          actions: [
            if (widget.forced)
              NeonBarAction(
                key: const Key('btn_forced_logout'),
                icon: Icons.logout_rounded,
                tooltip: 'Çıkış',
                onTap: _busy ? null : () => confirmAndLogout(context, context.read<AutomationState>()),
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  autovalidateMode: _autovalidate,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: OrbIconBadge(
                          // Zorunlu kipte dolu güvenlik simgesi: `password_rounded` ('***' + alt çizgi) amber orb içinde
                          // "kapalı gözlü yüz" gibi okunuyordu.
                          icon: widget.forced ? Icons.shield_rounded : Icons.lock_reset_rounded,
                          family: widget.forced ? AppFamilies.amber : AppFamilies.sky,
                          size: OrbSize.xl,
                          glow: true,
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
                              if (widget.forced)
                                const InlineMessage.warning(
                                  'Güvenliğiniz için devam etmeden önce size verilen geçici şifreyi değiştirmeniz gerekiyor.',
                                  key: Key('forced_notice'),
                                )
                              else
                                Text(
                                  // Servis PIN'leri ve onlarla açılmış oturumlar da kapanır (uyelik-7).
                                  'Şifrenizi değiştirdiğinizde diğer tüm cihazlardaki oturumlarınız kapatılır. '
                                  "Ürettiğiniz servis PIN'leri ve açık servis oturumları da kapatılır.",
                                  key: const Key('change_password_info'),
                                  style: TextStyle(color: muted, fontSize: 13, height: 1.4),
                                ),
                              const SizedBox(height: 18),
                              TextFormField(
                                key: const Key('field_current_password'),
                                controller: _currentController,
                                enabled: !_busy,
                                obscureText: _obscureCurrent,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [AutofillHints.password],
                                style: TextStyle(color: primary),
                                decoration: authInputDecoration(
                                  context,
                                  label: widget.forced ? 'Geçici Şifre' : 'Mevcut Şifre',
                                  prefixIcon: Icons.lock_outline_rounded,
                                  errorText: _currentFieldError,
                                  suffixIcon: passwordVisibilityButton(
                                    context: context,
                                    obscured: _obscureCurrent,
                                    onToggle: () => setState(() => _obscureCurrent = !_obscureCurrent),
                                  ),
                                ),
                                validator: (v) => (v == null || v.isEmpty) ? 'Lütfen mevcut şifrenizi girin' : null,
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                key: const Key('field_new_password'),
                                controller: _newController,
                                enabled: !_busy,
                                obscureText: _obscureNew,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [AutofillHints.newPassword],
                                style: TextStyle(color: primary),
                                // Kural etikette değil yardımcı metinde: "Yeni Şifre (En a…" gibi kesilmez.
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Yeni Şifre',
                                  helper: 'En az ${AuthValidators.passwordMinLength} karakter',
                                  prefixIcon: Icons.lock_outline_rounded,
                                  suffixIcon: passwordVisibilityButton(
                                    context: context,
                                    obscured: _obscureNew,
                                    onToggle: () => setState(() => _obscureNew = !_obscureNew),
                                  ),
                                ),
                                validator: (v) {
                                  final policy = AuthValidators.passwordPolicyError(v, emptyMessage: 'Lütfen yeni şifrenizi girin');
                                  if (policy != null) return policy;
                                  if (v == _currentController.text) return 'Yeni şifre mevcut şifreyle aynı olamaz';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                key: const Key('field_confirm_password'),
                                controller: _confirmController,
                                enabled: !_busy,
                                obscureText: _obscureConfirm,
                                autocorrect: false,
                                enableSuggestions: false,
                                style: TextStyle(color: primary),
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
                                  if (v == null || v.isEmpty) return 'Lütfen yeni şifrenizi tekrar girin';
                                  if (v != _newController.text) return 'Şifreler eşleşmiyor';
                                  return null;
                                },
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 14),
                                InlineMessage.error(_error!, key: const Key('change_password_error')),
                              ],
                              const SizedBox(height: 22),
                              ElevatedButton(
                                key: const Key('btn_change_password'),
                                onPressed: _busy ? null : _submit,
                                child: _busy ? buttonSpinner() : authPrimaryLabel('Şifreyi Değiştir'),
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
        ),
      ),
    );
  }
}
