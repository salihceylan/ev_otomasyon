import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../models/cloud_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/app_dialogs.dart';
import '../../common/confirm_dialogs.dart' show showSimpleConfirm;
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../motion/motion_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/settings/accent_button.dart';
import '../../widgets/surface_card.dart';
import 'countdown_ring.dart';
import 'step_progress.dart';

/// Aile bireyi / süreli misafir davet diyaloğu.
///
/// * Kod **yalnızca "Üret" düğmesiyle** üretilir (açılışta otomatik üretim yok; her açılış sunucuda
///   kullanılmayan bir davet bırakmasın).
/// * Misafir süre çipleri **yalnızca seçimdir** (seçmek kod üretmez); süre en çok 72 saattir.
/// * Sunucu UTC zamanları **yerel saatle** (`toLocal`) gösterilir.
/// * Her üretim isteği bir **sıra numarası** taşır: bayat/iptal edilmiş istek yanıtı, daha yeni bir
///   isteğin (veya "Vazgeç"in) sonucunu ezemez.
///
/// Düzen (WP-F2): içerik yüksekliği **içeriğe göre** belirlenir (sabit yükseklik yok; üst sınır 680 dp, aşınca
/// kaydırılır); üretilen kodun asıl eylemi "Kodu Kopyala & Paylaş" içerik kaydırılsa da HER ZAMAN görünen alt
/// eylem çubuğundadır; kod bir kez üretilince sonuç görünür bölgeye kaydırılır. Kod, yazı ölçeği ne olursa olsun
/// TEK satırda ve eksiksiz görünür (sığmazsa küçülür; `FittedBox`).
class InviteFamilyDialog extends StatefulWidget {
  final String? initialInviteCode;
  final String? initialHomeName;

  const InviteFamilyDialog({
    super.key,
    this.initialInviteCode,
    this.initialHomeName,
  });

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showAppDialog(
      context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const InviteFamilyDialog(),
      ),
    );
  }

  @override
  State<InviteFamilyDialog> createState() => _InviteFamilyDialogState();
}

/// Ekranda gösterilen üretilmiş davet.
class _InviteView {
  const _InviteView({required this.code, required this.qrContent, this.expiresAt, this.accessUntil, this.id});

  final String code;
  final String qrContent;

  /// Sunucu kimliği (iptal için; ev_uyelik-6). Eski sunucuda / dışarıdan verilen kodda `null`.
  final String? id;

  /// Kodun son kullanım zamanı (bilinmiyorsa `null`).
  final DateTime? expiresAt;

  /// Misafirin erişim bitişi (yalnızca misafir daveti).
  final DateTime? accessUntil;
}

class _InviteFamilyDialogState extends State<InviteFamilyDialog> {
  /// Misafir süre seçenekleri (saat); sunucu üst sınırı 72.
  static const List<int> guestHourOptions = <int>[2, 4, 8, 24, 48, 72];

  /// 0: aile bireyi, 1: süreli misafir.
  int _tab = 0;
  final _guestNameController = TextEditingController();
  final _memberResultKey = GlobalKey();
  final _guestResultKey = GlobalKey();

  // Aile üyesi
  bool _memberLoading = false;
  _InviteView? _member;
  String? _memberError;
  int _memberSeq = 0;

  // Misafir
  bool _guestLoading = false;
  _InviteView? _guest;
  String? _guestError;
  int _guestSeq = 0;
  int _guestHours = 8;
  bool _memberCopied = false;
  bool _guestCopied = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialInviteCode;
    if (initial != null && initial.isNotEmpty) {
      _member = _InviteView(code: initial, qrContent: 'AHBU-INVITE:$initial');
    }
  }

  @override
  void dispose() {
    _memberSeq++;
    _guestSeq++;
    _guestNameController.dispose();
    super.dispose();
  }

  _InviteView _toView(InvitationModel inv) => _InviteView(
        code: inv.code,
        qrContent: inv.qrContent,
        expiresAt: inv.expiresAt,
        accessUntil: inv.guestValidUntil,
        id: inv.id,
      );

  bool _revoking = false;

  /// Bu pencerede üretilen daveti iptal eder (ev_uyelik-6): kod ekrandan kalkar.
  Future<void> _revoke({required bool guest}) async {
    final view = guest ? _guest : _member;
    final id = view?.id;
    if (id == null || _revoking) return;
    final ok = await showSimpleConfirm(
      context,
      title: 'Davet iptal edilsin mi?',
      message: 'Bu davet kodu artık kullanılamaz.',
      confirmLabel: 'İptal Et',
      cancelLabel: 'Vazgeç',
      destructive: true,
      icon: Icons.cancel_schedule_send_rounded,
    );
    if (!ok || !mounted) return;
    final state = context.read<AutomationState>();
    setState(() => _revoking = true);
    String message;
    try {
      await state.revokeInvitation(id);
      message = 'Davet iptal edildi.';
    } catch (e) {
      message = e is ApiException && e.statusCode == 404
          ? 'Davet zaten kullanılmış ya da süresi dolmuş.'
          : friendlyError(e, fallback: 'Davet iptal edilemedi. Lütfen tekrar deneyin.');
      if (!(e is ApiException && e.statusCode == 404)) {
        if (mounted) setState(() => _revoking = false);
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _revoking = false;
      if (guest) {
        _guest = null;
      } else {
        _member = null;
      }
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _generate({required bool guest}) async {
    final state = context.read<AutomationState>();
    if (guest ? _guestLoading : _memberLoading) return; // çift dokunuş koruması
    if (!state.capabilities.canInvite) {
      setState(() {
        if (guest) {
          _guestError = 'Bu işlem için yetkiniz yok.';
        } else {
          _memberError = 'Bu işlem için yetkiniz yok.';
        }
      });
      return;
    }
    final seq = guest ? ++_guestSeq : ++_memberSeq;
    setState(() {
      if (guest) {
        _guestLoading = true;
        _guestError = null;
        _guest = null; // bayat kod ekranda kalmasın
        _guestCopied = false;
      } else {
        _memberLoading = true;
        _memberError = null;
        _member = null;
        _memberCopied = false;
      }
    });
    try {
      final name = _guestNameController.text.trim();
      final inv = await state.createHomeInvitation(
        role: guest ? 'guest' : 'resident',
        durationHours: guest ? _guestHours : null,
        guestName: guest && name.isNotEmpty ? name : null,
      );
      if (!mounted || seq != (guest ? _guestSeq : _memberSeq)) return; // bayat / iptal edilmiş
      setState(() {
        if (guest) {
          _guest = _toView(inv);
          _guestLoading = false;
        } else {
          _member = _toView(inv);
          _memberLoading = false;
        }
      });
      _revealResult(guest: guest);
    } catch (e) {
      if (!mounted || seq != (guest ? _guestSeq : _memberSeq)) return;
      final message = friendlyError(e, fallback: 'Davet kodu üretilemedi. Lütfen tekrar deneyin.');
      setState(() {
        if (guest) {
          _guestError = message;
          _guestLoading = false;
        } else {
          _memberError = message;
          _memberLoading = false;
        }
      });
    }
  }

  /// Üretilen sonuç (QR + kod) görünür bölgeye kaydırılır: kod formun altında kalıp fark edilmesin. Hareket kapalıyken
  /// (ve "hareketi azalt"ta) anında atlar; girdiyi bloklamaz.
  void _revealResult({required bool guest}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = (guest ? _guestResultKey : _memberResultKey).currentContext;
      if (target == null || !target.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          duration: MotionScope.durationOf(context, AppMotion.base),
          curve: AppMotion.standard,
        ),
      );
    });
  }

  /// Bekleyen üretim isteğini bırakır: yanıtı gelse bile ekrana yansımaz.
  void _cancelPending({required bool guest}) {
    setState(() {
      if (guest) {
        _guestSeq++;
        _guestLoading = false;
      } else {
        _memberSeq++;
        _memberLoading = false;
      }
    });
  }

  Future<void> _copyToClipboard(String code, {required bool guest}) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() {
      if (guest) {
        _guestCopied = true;
      } else {
        _memberCopied = true;
      }
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.copy_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text('Davet kodu ($code) panoya kopyalandı!')),
          ],
        ),
        // Beyaz yazılı dolgu: ham yeşil zeminde beyaz metin ≈2.5:1 idi.
        backgroundColor: AppTheme.filledAccent(AppTheme.accentGreen),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // PF-06: yalnız ev adı ve davet yetkisi izlenir; ilgisiz bildirim diyaloğu yeniden kurmaz.
    final view = context.select<AutomationState, ({String? homeName, bool canInvite})>(
      (s) => (homeName: s.activeHome?.name, canInvite: s.capabilities.canInvite),
    );
    final homeName = widget.initialHomeName ?? view.homeName ?? 'Evim';
    final allowed = view.canInvite || widget.initialInviteCode != null;
    final guestTab = _tab == 1;
    final loading = guestTab ? _guestLoading : _memberLoading;
    final current = guestTab ? _guest : _member;

    // Yüzey ve şekil temanın diyalog stilinden gelir (yerel zemin/şekil override'ı yok).
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              // Sağ boşluk: kapat düğmesinin iç boşluğu kadar eksik (simge içerik sağ kenarıyla hizalı).
              padding: const EdgeInsets.fromLTRB(20, 16, 6, 12),
              child: Row(
                children: [
                  const OrbIconBadge(icon: Icons.group_add_rounded, family: AppFamilies.sky, active: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // En çok 2 satır: büyük yazıda "Davet Et" kesilmesin.
                        Text(
                          'Erişim Paylaş & Davet Et',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.getTextPrimary(context),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          homeName,
                          style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_close'),
                    tooltip: 'Kapat',
                    icon: Icon(Icons.close, color: AppTheme.getTextMuted(context), size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (!allowed)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: InlineMessage.error('Bu işlem için yetkiniz yok.', key: Key('invite_forbidden')),
              )
            else ...[
              StepProgress(
                step: current != null ? 3 : (loading ? 2 : 1),
                color: guestTab ? AppFamilies.violet : AppFamilies.sky,
              ),
              _SegmentBar(selected: _tab, onSelect: (index) => setState(() => _tab = index)),
              const SizedBox(height: 4),
              Flexible(child: guestTab ? _buildGuestTab() : _buildFamilyTab(homeName)),
              if (current != null) _buildCopyBar(current, guest: guestTab),
            ],
          ],
        ),
      ),
    );
  }

  /// Alt eylem çubuğu: üretilen kodun asıl ardıl eylemi HER ZAMAN görünür (içerik kaydırılsa da, yazı ölçeği
  /// büyüse de).
  Widget _buildCopyBar(_InviteView invite, {required bool guest}) {
    final copied = guest ? _guestCopied : _memberCopied;
    return DecoratedBox(
      // İnce üst çizgi: kaydırılan içerik çubuğun altında kesilirken sınır belli olsun.
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.getCardBorder(context).withValues(alpha: 0.6))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: ElevatedButton.icon(
          key: Key(guest ? 'btn_copy_guest_code' : 'btn_copy_member_code'),
          onPressed: () => _copyToClipboard(invite.code, guest: guest),
          icon: Icon(copied ? Icons.check_rounded : Icons.copy_rounded, size: accentIconSize(context)),
          label: const Text('Kodu Kopyala & Paylaş', textAlign: TextAlign.center),
          style: accentButtonStyle(guest ? AppFamilies.violet : null),
        ),
      ),
    );
  }

  Widget _qrCard(String data, Color glow) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.r16),
          boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.25), blurRadius: 18, spreadRadius: 2)],
        ),
        child: QrImageView(
          // Test/erişilebilirlik için içerik anahtarı (QrImageView içeriği dışarı açmaz).
          key: ValueKey<String>('qr_payload:$data'),
          data: data,
          version: QrVersions.auto,
          size: 132,
          backgroundColor: Colors.white,
        ),
      ),
    );
  }

  Widget _generateButton({
    required Key key,
    required bool loading,
    required bool hasCode,
    required AccentFamily family,
    required VoidCallback onGenerate,
    required VoidCallback onCancel,
    required String firstLabel,
    required String againLabel,
  }) {
    if (loading) {
      // Bekleme: düz spinner yerine ortak "bekliyor" yayı (+ vazgeç yolu).
      return Row(
        children: [
          Expanded(
            child: Center(
              child: ProgressArc(
                diameter: 30,
                color: AppTheme.isDark(context) ? family.light : family.deep,
                strokeWidth: 3,
              ),
            ),
          ),
          TextButton(
            key: const Key('btn_invite_cancel_pending'),
            onPressed: onCancel,
            child: const Text('Vazgeç'),
          ),
        ],
      );
    }
    final icon = Icon(Icons.qr_code_2_rounded, size: accentIconSize(context));
    if (hasCode) {
      // Kod varken asıl eylem alttaki "Kodu Kopyala & Paylaş"tır: yeniden üretme ikincil (çerçeveli) görünür.
      return OutlinedButton.icon(
        key: key,
        onPressed: onGenerate,
        icon: icon,
        label: Text(againLabel, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
        style: accentOutlinedButtonStyle(context, family),
      );
    }
    return ElevatedButton.icon(
      key: key,
      onPressed: onGenerate,
      icon: icon,
      label: Text(firstLabel, textAlign: TextAlign.center),
      style: accentButtonStyle(identical(family, AppFamilies.violet) ? AppFamilies.violet : null),
    );
  }

  /// Kod kartı. Kod **tek satırda ve eksiksiz** görünür: kart genişliğine sığmazsa (büyük yazı ölçeği, 13 karakterli
  /// misafir kodu) `FittedBox` ile küçülür; ortadan bölünüp son karakterler kaybolmaz. Test anahtarı
  /// ([codeKey]) `SelectableText` üzerindedir.
  Widget _codeCard({
    required String caption,
    required String code,
    required AccentFamily family,
    required Color ink,
    required List<Widget> details,
    Key? codeKey,
  }) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      accent: family.base,
      active: true,
      radius: AppRadius.r16,
      child: Column(
        children: [
          Text(
            caption,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.getTextMuted(context),
              fontSize: AppTouch.minFontSize,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: SelectableText(
              code,
              key: codeKey,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
                color: ink,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          ...details,
        ],
      ),
    );
  }

  Widget _buildFamilyTab(String homeName) {
    final muted = AppTheme.getTextMuted(context);
    final member = _member;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '"$homeName" evini sürekli kontrol edebilmesi için aile bireyine 24 saat geçerli, tek kullanımlık '
            'bir katılım kodu ve QR üretin.',
            style: TextStyle(color: muted, fontSize: 12.5, height: 1.3),
          ),
          const SizedBox(height: 14),
          _generateButton(
            key: const Key('btn_generate_member_invite'),
            loading: _memberLoading,
            hasCode: member != null,
            family: AppFamilies.sky,
            onGenerate: () => _generate(guest: false),
            onCancel: () => _cancelPending(guest: false),
            firstLabel: 'Aile Katılım Kodu Üret',
            againLabel: 'Yeni Kod Üret',
          ),
          if (_memberError != null) ...[
            const SizedBox(height: 10),
            InlineMessage.error(_memberError!, key: const Key('invite_member_error')),
          ],
          if (member != null) ...[
            const SizedBox(height: 16),
            KeyedSubtree(key: _memberResultKey, child: _qrCard(member.qrContent, AppFamilies.sky.base)),
            const SizedBox(height: 14),
            _codeCard(
              caption: 'AİLE KATILIM KODU',
              code: member.code,
              family: AppFamilies.sky,
              // Açık temada ham #60A5FA ≈2.2:1 idi; bilgi tonu (açık: #1D4ED8, koyu: #60A5FA).
              ink: AppTheme.infoText(context),
              codeKey: const Key('invite_member_code'),
              details: [
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (member.expiresAt != null) ...[
                      CountdownRing(
                        expiresAt: member.expiresAt!,
                        total: const Duration(hours: 24),
                        now: context.read<AutomationState>().clock.now,
                        color: AppFamilies.sky.base,
                        diameter: 28,
                        strokeWidth: 3,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        member.expiresAt == null
                            ? '24 saat geçerli'
                            : 'Son geçerlilik: ${formatLocalDateTime(member.expiresAt!)}',
                        key: const Key('invite_member_expiry'),
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Aile bireyiniz AHBU uygulamasını açıp karekod tarayıcıya bu kodu gösterdiğinde veya kodu '
              '"Bir Eve Katıl" ekranına yazdığında eve bağlanır.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.3),
              textAlign: TextAlign.center,
            ),
            if (member.id != null)
              Center(
                child: TextButton.icon(
                  key: const Key('btn_revoke_member_invite'),
                  onPressed: _revoking ? null : () => _revoke(guest: false),
                  icon: const Icon(Icons.cancel_outlined, size: 18),
                  label: const Text('Bu daveti iptal et'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildGuestTab() {
    final muted = AppTheme.getTextMuted(context);
    final guest = _guest;
    final warning = AppTheme.warningText(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppFamilies.amber.base.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.r12),
              border: Border.all(color: AppFamilies.amber.base.withValues(alpha: 0.30)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, color: warning, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Süreli misafir / temizlikçi: süre kodun üretildiği andan başlar ve bittiğinde yetki '
                    'otomatik kapanır. En fazla ${guestHourOptions.last} saat.',
                    style: TextStyle(fontSize: 12, color: AppTheme.getTextPrimary(context)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Erişim Süresi Seçin:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: AppTheme.getTextPrimary(context)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final hours in guestHourOptions) _buildDurationChip(hours),
            ],
          ),
          const SizedBox(height: 12),
          // Alan biçimi (dolgu, köşe, odak halkası) temanın giriş stilinden gelir. "İsteğe bağlı" bilgisi etiketten
          // çıkarıldı (uzun etiket 1.0'da bile "…" ile kesiliyordu).
          TextField(
            key: const Key('field_guest_name'),
            controller: _guestNameController,
            maxLength: 100,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Misafir / Görevli Adı',
              helperText: 'İsteğe bağlı',
              hintText: 'Örn: Temizlikçi Fatma Hanım, Misafir Ali',
              counterText: '',
              labelStyle: TextStyle(color: muted),
              helperStyle: TextStyle(color: muted),
            ),
          ),
          const SizedBox(height: 12),
          _generateButton(
            key: const Key('btn_generate_guest_invite'),
            loading: _guestLoading,
            hasCode: guest != null,
            family: AppFamilies.violet,
            onGenerate: () => _generate(guest: true),
            onCancel: () => _cancelPending(guest: true),
            firstLabel: 'Geçici Misafir QR\'ı Üret',
            againLabel: 'Yeni Misafir QR\'ı Üret',
          ),
          if (_guestError != null) ...[
            const SizedBox(height: 10),
            InlineMessage.error(_guestError!, key: const Key('invite_guest_error')),
          ],
          if (guest != null) ...[
            const SizedBox(height: 16),
            KeyedSubtree(key: _guestResultKey, child: _qrCard(guest.qrContent, AppFamilies.violet.base)),
            const SizedBox(height: 12),
            _codeCard(
              caption: 'GEÇİCİ MİSAFİR KODU',
              code: guest.code,
              family: AppFamilies.violet,
              ink: AppTheme.readableAccent(context, AppFamilies.violet.base),
              codeKey: const Key('invite_guest_code'),
              details: [
                if (guest.accessUntil != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CountdownRing(
                        expiresAt: guest.accessUntil!,
                        total: Duration(hours: _guestHours),
                        now: context.read<AutomationState>().clock.now,
                        color: AppFamilies.amber.base,
                        diameter: 28,
                        strokeWidth: 3,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Son erişim: ${formatLocalDateTime(guest.accessUntil!)}',
                          key: const Key('invite_guest_until'),
                          style: TextStyle(color: warning, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Süreyi değiştirmek için yeni bir kod üretin; önceki kod süresi bitene (ya da kullanılana) '
              'kadar geçerli kalır.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.3),
              textAlign: TextAlign.center,
            ),
            if (guest.id != null)
              Center(
                child: TextButton.icon(
                  key: const Key('btn_revoke_guest_invite'),
                  onPressed: _revoking ? null : () => _revoke(guest: true),
                  icon: const Icon(Icons.cancel_outlined, size: 18),
                  label: const Text('Bu daveti iptal et'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Süre çipi **yalnızca seçimdir**: kod üretmez.
  Widget _buildDurationChip(int hours) {
    final isSelected = _guestHours == hours;
    final label = switch (hours) {
      24 => '24 Saat (1 Gün)',
      48 => '48 Saat (2 Gün)',
      72 => '72 Saat (3 Gün)',
      8 => '8 Saat (Mesai)',
      _ => '$hours Saat',
    };
    // Ortak çip ([AppChip]): seçili = misafir moru tonlu dolgu + parlak kenar + onay işareti, AA okunur etiket (eskiden koyu mor
    // zemin + beyaz metin elle verilirdi); süre çipi YALNIZCA seçimdir, kod üretmez.
    return AppChip(
      key: Key('chip_guest_$hours'),
      label: label,
      selected: isSelected,
      family: AppFamilies.violet,
      onTap: () => setState(() => _guestHours = hours),
    );
  }
}

/// Cam segment çubuğu (Aile Bireyi / Süreli Misafir): seçili segment sky→cyan gradyan hap, etiket büyük yazıda iki
/// satıra sarar (sabit yükseklik yok; `Tab`'in tek satır + solma kırpması yok). Dokunma hedefi ≥ 48 dp.
class _SegmentBar extends StatelessWidget {
  const _SegmentBar({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Yatay 20: başlık/ilerleme çubuğu/içerikle aynı sol-sağ hiza.
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.getInsetColor(context),
        borderRadius: BorderRadius.circular(AppRadius.r16),
        // Segment kabı bir KONTROLÜN sınırıdır: ≥ 3:1 (alan çerçevesiyle aynı dil); dekoratif kart kenarı açıkta 1.5:1'di.
        border: Border.all(color: AppTheme.getFieldBorder(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Segment(
              key: const Key('tab_invite_member'),
              icon: Icons.groups_rounded,
              label: 'Aile Bireyi',
              selected: selected == 0,
              onTap: () => onSelect(0),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _Segment(
              key: const Key('tab_invite_guest'),
              icon: Icons.hourglass_top_rounded,
              label: 'Süreli Misafir',
              selected: selected == 1,
              onTap: () => onSelect(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({super.key, required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? Colors.white : AppTheme.getTextMuted(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        child: AnimatedContainer(
          duration: MotionScope.durationOf(context, AppMotion.fast),
          curve: AppMotion.standard,
          constraints: const BoxConstraints(minHeight: AppTouch.minTarget + 8),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(colors: [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd])
                : null,
            borderRadius: BorderRadius.circular(AppRadius.r12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: ink),
              const SizedBox(height: 2),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
