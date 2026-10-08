import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/legal_models.dart';
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
import '../../widgets/neon_app_bar.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';
import '../legal/legal_document_page.dart';

/// Kayıt ekranı. Parola politikası (en az 10 karakter, kırpılmaz), geçerli e-posta, isteğe bağlı
/// telefon (doğrulanır ve ayırıcılardan arındırılarak gönderilir). Hatalar `friendlyError` ile gösterilir.
///
/// Görünüm: başlık, alt başlık, alanlar, düğme ve "Giriş Yapın" bağlantısı TEK cam plakada ([SurfaceCard]) durur:
/// metin arkadaki devre fotoğrafının üstünde kalmaz (açık temada izler alt başlığı ve bağlantıyı kesiyordu).
/// Alan etiketleri kısadır; kurallar yardımcı metindedir ("Şifre" + "En az 10 karakter"): büyük yazıda etiket
/// "…" ile kesilmez.
///
/// **Kullanıcı Sözleşmesi (zorunlu onay):** sayfa açılınca güncel sözleşme sürümü alınır (`GET /legal`); "Kullanıcı
/// Sözleşmesi'ni okudum ve kabul ediyorum." kutusu işaretlenmeden "Kayıt Ol" pasiftir ve kayıt bu sürümle
/// (`accept_terms_version`) gönderilir. Sürüm alınamazsa satır içi hata + "Tekrar Dene" (kayıt gönderilemez). Sunucu
/// `409 LEGAL_VERSION_MISMATCH` derse hesap açılmamıştır: onay kaldırılır, sürüm yeniden alınır ve yeniden sorulur.
/// Altındaki KVKK satırı yalnız BİLGİLENDİRMEDİR (onay kutusu yok; aydınlatma metni rızaya bağlanmaz).
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  late final Cooldown _cooldown;

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;
  String? _error;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  // Kullanıcı Sözleşmesi onayı: güncel sürüm (alınamadıysa null), yükleniyor/başarısız, kutu ve uyarı.
  LegalDocumentInfo? _terms;
  bool _termsLoading = true;
  bool _termsFailed = false;
  bool _termsAccepted = false;
  String? _termsNotice;
  int _termsRequest = 0;
  late final TapGestureRecognizer _termsLink;
  late final TapGestureRecognizer _privacyLink;

  @override
  void initState() {
    super.initState();
    _cooldown = Cooldown(context.read<AutomationState>().clock, () {
      if (mounted) setState(() {});
    });
    _termsLink = TapGestureRecognizer()..onTap = () => _openLegal(LegalDocumentKind.terms);
    _privacyLink = TapGestureRecognizer()..onTap = () => _openLegal(LegalDocumentKind.privacy);
    unawaited(_loadTerms(initial: true));
  }

  @override
  void dispose() {
    _cooldown.dispose();
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _termsLink.dispose();
    _privacyLink.dispose();
    super.dispose();
  }

  /// Güncel Kullanıcı Sözleşmesi sürümünü alır (`GET /legal`). Sunucuda sözleşme yoksa da "alınamadı" sayılır: kullanıcı
  /// görmediği bir sözleşmeyle kaydedilmez.
  Future<void> _loadTerms({bool initial = false}) async {
    final request = ++_termsRequest;
    final state = context.read<AutomationState>();
    if (!initial) {
      setState(() {
        _termsLoading = true;
        _termsFailed = false;
      });
    }
    LegalDocumentInfo? terms;
    try {
      final documents = await state.fetchLegalDocuments();
      for (final document in documents) {
        if (document.id == LegalDocumentKind.terms.id) {
          terms = document;
          break;
        }
      }
    } catch (_) {
      terms = null; // hata metni sabittir (aşağıda); ayrıntı gösterilmez
    }
    if (!mounted || request != _termsRequest) return;
    setState(() {
      _terms = terms;
      _termsLoading = false;
      _termsFailed = terms == null;
    });
  }

  bool get _canToggleTerms => _terms != null && !_termsLoading && !_isLoading;

  void _setTermsAccepted(bool value) {
    if (!_canToggleTerms) return;
    setState(() {
      _termsAccepted = value;
      if (value) _termsNotice = null;
    });
  }

  void _openLegal(LegalDocumentKind kind) => unawaited(LegalDocumentPage.open(context, kind));

  Future<void> _handleRegister() async {
    if (_isLoading || _cooldown.isActive) return;
    setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
    if (!_formKey.currentState!.validate()) return;
    final terms = _terms;
    if (terms == null || _termsLoading) return; // sürüm alınamadı: hata ve "Tekrar Dene" zaten görünüyor
    if (!_termsAccepted) {
      // Klavyeden gönderim (düğme zaten pasif): neden gönderilmediği söylenir.
      setState(() => _termsNotice = "Kayıt olmak için Kullanıcı Sözleşmesi'ni okuyup onaylamanız gerekir.");
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _termsNotice = null;
    });
    try {
      final state = context.read<AutomationState>();
      final phone = AuthValidators.normalizePhone(_phoneController.text);
      final success = await state.register(
        fullName: _fullNameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text, // KIRPILMAZ
        phone: phone,
        acceptTermsVersion: terms.version,
      );
      if (!mounted) return;
      if (success) {
        // Oturum açıldı; AuthGate paneli gösterir. Kayıt sayfasını yığından kaldır.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.isLegalVersionMismatch) {
        // Sözleşme bu arada güncellendi; hesap AÇILMADI. Güncel sürüm alınır ve onay yeniden istenir.
        setState(() {
          _termsAccepted = false;
          _termsNotice = e.message;
        });
        unawaited(_loadTerms());
        return;
      }
      setState(() => _error = friendlyError(e, fallback: 'Kayıt tamamlanamadı. Lütfen tekrar deneyin.'));
      if (e is ApiException && e.isRateLimited) {
        final wait = e.retryAfter ?? e.resendAfter;
        if (wait != null) _cooldown.start(wait);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    final cooling = _cooldown.isActive;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // Ortak Neon Glass üst çubuk (cam geri diski + 18/700 başlık, 16 dp oluk): çıplak Material `AppBar`ın düz ← glifi
      // ve başlığı doğrudan devre fotoğrafı üzerinde duruyordu; ikincil sayfalarla aynı dil. Sayfa gövdesinde zaten
      // büyük bir orb olduğundan çubukta özellik orb'u YOK. Geri: `Navigator.maybePop` (eski `BackButton` ile aynı).
      appBar: const NeonAppBar(title: 'Kayıt Ol'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  autovalidateMode: _autovalidate,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const StaggeredEntrance(
                        index: 0,
                        step: Duration(milliseconds: 70),
                        child: Center(
                          child: OrbIconBadge(icon: Icons.person_add_alt_1_rounded, family: AppFamilies.sky, size: OrbSize.xl, glow: true),
                        ),
                      ),
                      const SizedBox(height: 16),
                      StaggeredEntrance(
                        index: 1,
                        step: const Duration(milliseconds: 70),
                        child: SurfaceCard(
                          padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Yeni Hesap Oluşturun',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: primary),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Evinizi ve tüm cihazlarınızı güvenle yönetin',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 14, color: muted),
                              ),
                              const SizedBox(height: 22),
                              TextFormField(
                                key: const Key('field_full_name'),
                                controller: _fullNameController,
                                enabled: !_isLoading,
                                textCapitalization: TextCapitalization.words,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.name],
                                maxLength: 100,
                                style: TextStyle(color: primary),
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Ad Soyad',
                                  prefixIcon: Icons.person_outline_rounded,
                                  counterText: '',
                                ),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) return 'Lütfen adınızı ve soyadınızı girin';
                                  if (val.trim().length < 2) return 'Ad soyad en az 2 karakter olmalıdır';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const Key('field_email'),
                                controller: _emailController,
                                enabled: !_isLoading,
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.email],
                                autocorrect: false,
                                enableSuggestions: false,
                                style: TextStyle(color: primary),
                                decoration: authInputDecoration(context, label: 'E-Posta Adresi', prefixIcon: Icons.email_outlined),
                                validator: AuthValidators.emailError,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const Key('field_phone'),
                                controller: _phoneController,
                                enabled: !_isLoading,
                                keyboardType: TextInputType.phone,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.telephoneNumber],
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s().]')),
                                  LengthLimitingTextInputFormatter(20),
                                ],
                                style: TextStyle(color: primary),
                                // Etiket kısa; "isteğe bağlı" bilgisi yardımcı metinde (etiket kesilmez).
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Telefon',
                                  helper: 'İsteğe bağlı',
                                  prefixIcon: Icons.phone_outlined,
                                  hint: '0555 123 45 67',
                                ),
                                validator: (v) => AuthValidators.phoneError(v),
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const Key('field_password'),
                                controller: _passwordController,
                                enabled: !_isLoading,
                                obscureText: _obscurePassword,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.newPassword],
                                autocorrect: false,
                                enableSuggestions: false,
                                style: TextStyle(color: primary),
                                // Kural etikette değil yardımcı metinde: "Şifre (En az 10 …" gibi kesilmez.
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Şifre',
                                  helper: 'En az ${AuthValidators.passwordMinLength} karakter',
                                  prefixIcon: Icons.lock_outline_rounded,
                                  suffixIcon: passwordVisibilityButton(
                                    context: context,
                                    obscured: _obscurePassword,
                                    onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                                  ),
                                ),
                                validator: AuthValidators.passwordPolicyError,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const Key('field_password_confirm'),
                                controller: _confirmPasswordController,
                                enabled: !_isLoading,
                                obscureText: _obscureConfirmPassword,
                                textInputAction: TextInputAction.done,
                                autocorrect: false,
                                enableSuggestions: false,
                                onFieldSubmitted: (_) => _handleRegister(),
                                style: TextStyle(color: primary),
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Şifre Tekrar',
                                  prefixIcon: Icons.verified_user_outlined,
                                  suffixIcon: passwordVisibilityButton(
                                    context: context,
                                    obscured: _obscureConfirmPassword,
                                    onToggle: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                                  ),
                                ),
                                validator: (val) {
                                  if (val == null || val.isEmpty) return 'Lütfen şifrenizi tekrar girin';
                                  if (val != _passwordController.text) return 'Şifreler eşleşmiyor';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 14),
                              _buildTermsSection(context),
                              if (_error != null) ...[
                                const SizedBox(height: 16),
                                InlineMessage.error(_error!, key: const Key('register_error')),
                              ],
                              const SizedBox(height: 22),
                              // Birincil düğme: tür ElevatedButton KALIR; gradyan/şekil/gölge temadan gelir.
                              ElevatedButton(
                                key: const Key('btn_register_submit'),
                                // Sözleşme onaylanmadan (ya da sürümü alınamadan) kayıt gönderilemez.
                                onPressed: (_isLoading || cooling || !_termsAccepted || _terms == null || _termsLoading)
                                    ? null
                                    : _handleRegister,
                                child: _isLoading
                                    ? buttonSpinner()
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (cooling) ...[CooldownArc(remaining: _cooldown.remaining, color: muted), const SizedBox(width: 10)],
                                          Flexible(
                                            child: DefaultTextStyle.merge(
                                              textAlign: TextAlign.center,
                                              child: authPrimaryLabel(
                                                cooling ? 'Tekrar dene (${formatCountdown(_cooldown.remainingSeconds)})' : 'Kayıt Ol ve Giriş Yap',
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
                                prompt: 'Zaten bir hesabınız var mı? ',
                                actionLabel: 'Giriş Yapın',
                                actionKey: const Key('btn_back_to_login'),
                                onTap: _isLoading ? null : () => Navigator.of(context).pop(),
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

  /// Sözleşme onayı (zorunlu kutu; "Kullanıcı Sözleşmesi" bağlantısı metni açar) + KVKK bilgilendirme satırı (kutusuz).
  ///
  /// Kutunun ekran okuyucu etiketi kendi üzerindedir; yanındaki metne dokunmak da kutuyu işaretler (bağlantı hariç:
  /// bağlantı yalnız metni açar). Metnin dokunma alanı anlamdan hariçtir (kutu zaten erişilebilir denetimdir).
  Widget _buildTermsSection(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    final link = AppTheme.infoText(context);
    final linkStyle = TextStyle(
      color: link,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
      decorationColor: link,
    );
    final canToggle = _canToggleTerms;
    final notice = _termsNotice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notice != null) ...[
          InlineMessage.warning(notice, key: const Key('register_terms_notice')),
          const SizedBox(height: 8),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              key: const Key('chk_accept_terms'),
              value: _termsAccepted,
              onChanged: canToggle ? (value) => _setTermsAccepted(value ?? false) : null,
              semanticLabel: "Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum",
            ),
            Expanded(
              child: GestureDetector(
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: canToggle ? () => _setTermsAccepted(!_termsAccepted) : null,
                child: Padding(
                  // Metnin ilk satırı 48 dp'lik kutunun ortasıyla hizalı.
                  padding: const EdgeInsets.only(top: 13, bottom: 6),
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: 'Kullanıcı Sözleşmesi', style: linkStyle, recognizer: _termsLink),
                        const TextSpan(text: "'ni okudum ve kabul ediyorum."),
                      ],
                    ),
                    key: const Key('register_terms_text'),
                    style: TextStyle(fontSize: AppText.body, height: 1.35, color: primary),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_termsLoading)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, top: 2),
            child: Text(
              'Kullanıcı Sözleşmesi yükleniyor…',
              key: const Key('register_terms_loading'),
              style: TextStyle(fontSize: AppText.caption, color: muted),
            ),
          )
        else if (_termsFailed) ...[
          const SizedBox(height: 4),
          InlineMessage.error(
            'Kullanıcı Sözleşmesi yüklenemedi. Kayıt olmak için sözleşmeyi onaylamanız gerekir; bağlantınızı kontrol edip '
            'yeniden deneyin.',
            key: const Key('register_terms_error'),
            trailing: TextButton(
              key: const Key('btn_register_terms_retry'),
              onPressed: _isLoading ? null : _loadTerms,
              child: const Text('Tekrar Dene'),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 12),
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                const TextSpan(text: 'Kişisel verileriniz '),
                TextSpan(text: 'Gizlilik Politikası ve KVKK Aydınlatma Metni', style: linkStyle, recognizer: _privacyLink),
                const TextSpan(text: ' kapsamında işlenir.'),
              ],
            ),
            key: const Key('register_privacy_notice'),
            style: TextStyle(fontSize: AppText.caption, height: 1.4, color: muted),
          ),
        ),
      ],
    );
  }
}
