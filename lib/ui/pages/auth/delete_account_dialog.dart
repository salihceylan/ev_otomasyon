import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/cloud_models.dart';
import '../../../services/automation_state.dart';
import '../../../services/ev_cloud_api_service.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../family/transfer_ownership_dialog.dart';
import 'social_sign_in.dart';

/// Hesabı kalıcı olarak silme (mağaza gereksinimi).
///
/// * Parolalı hesap: parola girilir; Google/Apple/SMS hesabı: parola boş bırakılır. İki durumda da
///   onay için `SİL` **yazılır** (düğme ifade doğru yazılana kadar pasiftir).
/// * Kullanıcı, başka üyesi ya da panosu olan bazı evlerin **tek sahibi** ise sunucu `409 SOLE_OWNER` döndürür:
///   hiçbir şey silinmez, ilgili daireler listelenir ve **önce devir** yönlendirmesi yapılır. İstemci bu kuralı
///   önceden hesaplayıp engellemez (kararı sunucu verir): üyesiz + panosuz tek sahipli daireler engel değildir ve
///   hesapla birlikte silinir (`released_homes`; başarı iletisinde belirtilir).
/// * Başarıda yerel oturum tamamen temizlenir ve uygulama giriş ekranına döner.
///
/// Görünüm: auth/onay akışının ORTAK diyalog kabuğu ([AuthDialogShell]).
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(value: state, child: const DeleteAccountDialog()),
    );
  }

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  static const String _phrase = 'SİL';

  final _passwordController = TextEditingController();
  final _phraseController = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  String? _error;
  List<SoleOwnedHome>? _soleOwned;

  @override
  void initState() {
    super.initState();
    _phraseController.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _phraseController.removeListener(_rebuild);
    _passwordController.dispose();
    _phraseController.dispose();
    super.dispose();
  }

  bool get _canDelete => !_busy && confirmPhraseMatches(_phraseController.text, _phrase);

  Future<void> _delete() async {
    if (!_canDelete) return; // çift dokunuş / ifade doğru değil
    final state = context.read<AutomationState>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final password = _passwordController.text; // KIRPILMAZ
    setState(() {
      _busy = true;
      _error = null;
      _soleOwned = null;
    });
    try {
      final result = await state.deleteAccount(password: password.isEmpty ? null : password, confirm: password.isEmpty ? _phrase : null);
      unawaited(SocialSignIn.signOutGoogle());
      // Oturum temizlendi: açık tüm sayfalar kapanır, kapı giriş ekranını gösterir.
      navigator.popUntil((route) => route.isFirst);
      // Sunucu üyesiz + panosuz tek sahipli daireleri hesapla birlikte sildiyse kısa bilgi (UYELIK-03).
      final released = result.releasedHomes;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            released > 0 ? 'Hesabınız silindi. Üyesi ve panosu olmayan $released daireniz de kaldırıldı.' : 'Hesabınız silindi.',
          ),
          // Beyaz iletiyle AA (ham #10B981 ile ~2.5:1'di).
          backgroundColor: AppTheme.filledAccent(AppTheme.accentGreen),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.isSoleOwner) {
        var homes = soleOwnedHomesOf(e);
        if (homes.isEmpty) {
          // Sunucu liste vermediyse: kullanıcının kendi sahibi olduğu daireler.
          homes = <SoleOwnedHome>[
            for (final h in state.homes)
              if (h.isOwnerRole) SoleOwnedHome(id: h.id, name: h.name),
          ];
        }
        setState(() {
          _busy = false;
          _soleOwned = homes;
        });
        return;
      }
      setState(() {
        _busy = false;
        _error = friendlyError(e, fallback: 'Hesap silinemedi. Lütfen tekrar deneyin.');
      });
    }
  }

  Future<void> _transferFor(SoleOwnedHome home) async {
    final state = context.read<AutomationState>();
    HomeModel? target = state.homeById(home.id);
    if (target == null) {
      setState(() => _error = 'Bu daire listenizde görünmüyor. Daire listesini yenileyip tekrar deneyin.');
      return;
    }
    // Devir diyaloğu aktif evde çalışır.
    if (state.activeHome?.id != target.id) await state.selectHome(target);
    if (!mounted) return;
    await TransferOwnershipDialog.show(context);
  }

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    final soleOwned = _soleOwned;

    return PopScope(
      canPop: !_busy,
      child: AuthDialogShell(
        icon: Icons.delete_forever_rounded,
        family: AppFamilies.rose,
        title: 'Hesabı Sil',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [if (soleOwned != null) ..._buildSoleOwnerPanel(soleOwned) else ..._buildForm(muted, primary)],
        ),
        actions: AuthDialogActions(
          secondaryLabel: soleOwned != null ? 'Kapat' : 'Vazgeç',
          secondary: TextButton(
            key: const Key('btn_delete_cancel'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: authSecondaryLabel(context, soleOwned != null ? 'Kapat' : 'Vazgeç'),
          ),
          primaryLabel: soleOwned == null ? 'Hesabı Kalıcı Olarak Sil' : 'Tekrar Dene',
          primary: soleOwned == null
              ? ElevatedButton(
                  key: const Key('btn_delete_account'),
                  onPressed: _canDelete ? _delete : null,
                  style: destructiveButtonStyle(),
                  child: _busy ? buttonSpinner() : authPrimaryLabel('Hesabı Kalıcı Olarak Sil'),
                )
              : ElevatedButton(
                  key: const Key('btn_delete_retry'),
                  onPressed: _busy ? null : () => setState(() => _soleOwned = null),
                  child: authPrimaryLabel('Tekrar Dene'),
                ),
        ),
      ),
    );
  }

  List<Widget> _buildForm(Color muted, Color primary) {
    return [
      Text(
        'Hesabınız, kişisel verileriniz ve bu hesaba bağlı tüm oturumlarınız kalıcı olarak silinir. '
        'Bu işlem geri alınamaz.',
        style: TextStyle(color: muted, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('field_delete_password'),
        controller: _passwordController,
        enabled: !_busy,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(color: primary),
        decoration: authInputDecoration(
          context,
          label: 'Şifreniz',
          prefixIcon: Icons.lock_outline_rounded,
          helper: 'Google, Apple veya SMS ile giriş yapıyorsanız boş bırakın.',
          suffixIcon: passwordVisibilityButton(context: context, obscured: _obscure, onToggle: () => setState(() => _obscure = !_obscure)),
        ),
      ),
      const SizedBox(height: 14),
      Text.rich(
        TextSpan(
          style: TextStyle(color: primary, fontSize: 13),
          children: [
            const TextSpan(text: 'Onaylamak için '),
            TextSpan(
              text: _phrase,
              // Anahtar sözcük AA kontrastlı kırmızı (ham #EF4444 açık zeminde ~3.8:1'di).
              style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.dangerText(context)),
            ),
            const TextSpan(text: ' yazın:'),
          ],
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('field_delete_confirm'),
        controller: _phraseController,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        style: TextStyle(color: primary),
        decoration: authInputDecoration(
          context,
          hint: _phrase,
          suffixIcon: confirmPhraseMatches(_phraseController.text, _phrase)
              ? Icon(Icons.check_circle_rounded, color: AppTheme.successText(context), size: 20)
              : null,
        ),
      ),
      if (_error != null) ...[const SizedBox(height: 12), InlineMessage.error(_error!, key: const Key('delete_error'))],
    ];
  }

  /// "2 üye · 1 pano" (sunucu sayıları verdiyse).
  String? _homeDetail(SoleOwnedHome home) {
    final parts = <String>[
      if (home.otherMemberCount != null) '${home.otherMemberCount} diğer üye',
      if (home.deviceCount != null) '${home.deviceCount} pano',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  List<Widget> _buildSoleOwnerPanel(List<SoleOwnedHome> homes) {
    return [
      const InlineMessage.warning(
        'Hesabınızı silmeden önce aşağıdaki dairelerin sahipliğini devretmelisiniz; aksi halde bu dairelerin '
        'kontrolü kimsede kalmaz. Hiçbir şey silinmedi.',
        key: Key('sole_owner_notice'),
      ),
      const SizedBox(height: 12),
      if (homes.isEmpty)
        Text(
          'Tek sahibi olduğunuz daireleri ana ekrandaki daire listesinden kontrol edin.',
          style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 12.5),
        ),
      for (final home in homes)
        Container(
          key: Key('sole_home_${home.id}'),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.getCardColor(context),
            borderRadius: BorderRadius.circular(AppRadius.r12),
            border: Border.all(color: AppTheme.getCardBorder(context)),
          ),
          // Devret düğmesi metnin ALTINDA, sağa hizalıdır: yan yana Row dar ekranda / büyük yazıda taşardı.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.home_outlined, size: 20, color: AppTheme.infoText(context)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          home.name,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.getTextPrimary(context)),
                        ),
                        if (_homeDetail(home) != null)
                          Text(
                            _homeDetail(home)!,
                            key: Key('sole_home_detail_${home.id}'),
                            style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: Key('btn_transfer_sole_${home.id}'),
                  onPressed: () => _transferFor(home),
                  child: const Text('Devret'),
                ),
              ),
            ],
          ),
        ),
      if (_error != null) ...[const SizedBox(height: 8), InlineMessage.error(_error!, key: const Key('delete_error'))],
    ];
  }
}
