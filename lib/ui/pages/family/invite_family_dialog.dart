import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../models/cloud_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';

/// Aile bireyi / süreli misafir davet diyaloğu.
///
/// * Kod **yalnızca "Üret" düğmesiyle** üretilir (açılışta otomatik üretim yok; her açılış sunucuda
///   kullanılmayan bir davet bırakmasın).
/// * Misafir süre çipleri **yalnızca seçimdir** (seçmek kod üretmez); süre en çok 72 saattir.
/// * Sunucu UTC zamanları **yerel saatle** (`toLocal`) gösterilir.
/// * Her üretim isteği bir **sıra numarası** taşır: bayat/iptal edilmiş istek yanıtı, daha yeni bir
///   isteğin (veya "Vazgeç"in) sonucunu ezemez.
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
    return showDialog(
      context: context,
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
  const _InviteView({required this.code, required this.qrContent, this.expiresAt, this.accessUntil});

  final String code;
  final String qrContent;

  /// Kodun son kullanım zamanı (bilinmiyorsa `null`).
  final DateTime? expiresAt;

  /// Misafirin erişim bitişi (yalnızca misafir daveti).
  final DateTime? accessUntil;
}

class _InviteFamilyDialogState extends State<InviteFamilyDialog> with SingleTickerProviderStateMixin {
  /// Misafir süre seçenekleri (saat); sunucu üst sınırı 72.
  static const List<int> guestHourOptions = <int>[2, 4, 8, 24, 48, 72];

  late TabController _tabController;
  final _guestNameController = TextEditingController();

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final initial = widget.initialInviteCode;
    if (initial != null && initial.isNotEmpty) {
      _member = _InviteView(code: initial, qrContent: 'AHBU-INVITE:$initial');
    }
  }

  @override
  void dispose() {
    _memberSeq++;
    _guestSeq++;
    _tabController.dispose();
    _guestNameController.dispose();
    super.dispose();
  }

  _InviteView _toView(InvitationModel inv) => _InviteView(
        code: inv.code,
        qrContent: inv.qrContent,
        expiresAt: inv.expiresAt,
        accessUntil: inv.guestValidUntil,
      );

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
      } else {
        _memberLoading = true;
        _memberError = null;
        _member = null;
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

  Future<void> _copyToClipboard(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.copy_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text('Davet kodu ($code) panoya kopyalandı!')),
          ],
        ),
        backgroundColor: AppTheme.accentGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final homeName = widget.initialHomeName ?? state.activeHome?.name ?? 'Evim';
    final allowed = state.capabilities.canInvite || widget.initialInviteCode != null;

    return Dialog(
      backgroundColor: AppTheme.getSurfaceColor(context),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppTheme.getCardBorder(context), width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.group_add_outlined, color: AppTheme.primaryBlueLight, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Erişim Paylaş & Davet Et',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.getTextPrimary(context),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          homeName,
                          style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
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
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppTheme.getCardColor(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.getCardBorder(context)),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: AppTheme.primaryBlue,
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  labelColor: Colors.white,
                  unselectedLabelColor: AppTheme.getTextMuted(context),
                  labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  tabs: const [
                    Tab(key: Key('tab_invite_member'), icon: Icon(Icons.family_restroom, size: 18), text: 'Aile Bireyi'),
                    Tab(key: Key('tab_invite_guest'), icon: Icon(Icons.hourglass_top_outlined, size: 18), text: 'Süreli Misafir'),
                  ],
                ),
              ),
              Flexible(
                child: SizedBox(
                  height: 520,
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildFamilyTab(homeName),
                      _buildGuestTab(),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _qrCard(String data, Color glow) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.25), blurRadius: 18, spreadRadius: 2)],
        ),
        child: QrImageView(
          // Test/erişilebilirlik için içerik anahtarı (QrImageView içeriği dışarı açmaz).
          key: ValueKey<String>('qr_payload:$data'),
          data: data,
          version: QrVersions.auto,
          size: 160,
          backgroundColor: Colors.white,
        ),
      ),
    );
  }

  Widget _generateButton({
    required Key key,
    required bool loading,
    required bool hasCode,
    required Color color,
    required VoidCallback onGenerate,
    required VoidCallback onCancel,
    required String firstLabel,
    required String againLabel,
  }) {
    if (loading) {
      return Row(
        children: [
          const Expanded(
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))),
          ),
          TextButton(
            key: const Key('btn_invite_cancel_pending'),
            onPressed: onCancel,
            child: const Text('Vazgeç'),
          ),
        ],
      );
    }
    return ElevatedButton.icon(
      key: key,
      onPressed: onGenerate,
      icon: const Icon(Icons.qr_code_2_rounded, size: 18),
      label: Text(hasCode ? againLabel : firstLabel),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _codeCard({
    required String caption,
    required String code,
    required Color color,
    required List<Widget> details,
    Key? codeKey,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Text(
            caption,
            style: TextStyle(
              color: AppTheme.getTextMuted(context),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            code,
            key: codeKey,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2, color: color),
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
      padding: const EdgeInsets.all(20),
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
            color: AppTheme.primaryBlue,
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
            _qrCard(member.qrContent, AppTheme.primaryBlue),
            const SizedBox(height: 14),
            _codeCard(
              caption: 'AİLE KATILIM KODU',
              code: member.code,
              color: AppTheme.primaryBlueLight,
              codeKey: const Key('invite_member_code'),
              details: [
                const SizedBox(height: 4),
                Text(
                  member.expiresAt == null
                      ? '24 saat geçerli'
                      : 'Son geçerlilik: ${formatLocalDateTime(member.expiresAt!)}',
                  key: const Key('invite_member_expiry'),
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              key: const Key('btn_copy_member_code'),
              onPressed: () => _copyToClipboard(member.code),
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Kodu Kopyala & Paylaş'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Aile bireyiniz AHBU uygulamasını açıp karekod tarayıcıya bu kodu gösterdiğinde veya kodu '
              '"Bir Eve Katıl" ekranına yazdığında eve bağlanır.',
              style: TextStyle(color: muted, fontSize: 11.5, height: 1.3),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGuestTab() {
    final muted = AppTheme.getTextMuted(context);
    final guest = _guest;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.accentAmber.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, color: AppTheme.accentAmber, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Süreli misafir / temizlikçi: süre kodun üretildiği andan başlar ve bittiğinde yetki '
                    'otomatik kapanır. En fazla ${guestHourOptions.last} saat.',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.getTextPrimary(context)),
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
          TextField(
            key: const Key('field_guest_name'),
            controller: _guestNameController,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: 'Misafir / Görevli Adı (İsteğe Bağlı)',
              hintText: 'Örn: Temizlikçi Fatma Hanım, Misafir Ali',
              counterText: '',
              filled: true,
              fillColor: AppTheme.getCardColor(context),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 12),
          _generateButton(
            key: const Key('btn_generate_guest_invite'),
            loading: _guestLoading,
            hasCode: guest != null,
            color: AppTheme.accentPurple,
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
            _qrCard(guest.qrContent, AppTheme.accentPurple),
            const SizedBox(height: 12),
            _codeCard(
              caption: 'GEÇİCİ MİSAFİR KODU',
              code: guest.code,
              color: AppTheme.accentPurple,
              codeKey: const Key('invite_guest_code'),
              details: [
                if (guest.accessUntil != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Son erişim: ${formatLocalDateTime(guest.accessUntil!)}',
                    key: const Key('invite_guest_until'),
                    style: const TextStyle(color: AppTheme.accentAmber, fontWeight: FontWeight.bold, fontSize: 11.5),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('btn_copy_guest_code'),
              onPressed: () => _copyToClipboard(guest.code),
              icon: const Icon(Icons.copy_rounded, size: 16, color: AppTheme.accentPurple),
              label: const Text('Kodu Kopyala & Paylaş', style: TextStyle(color: AppTheme.accentPurple)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.accentPurple),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Süreyi değiştirmek için yeni bir kod üretin; önceki kod süresi bitene (ya da kullanılana) '
              'kadar geçerli kalır.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.3),
              textAlign: TextAlign.center,
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
    return ChoiceChip(
      key: Key('chip_guest_$hours'),
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : AppTheme.getTextPrimary(context)),
      ),
      selected: isSelected,
      selectedColor: AppTheme.accentPurple,
      backgroundColor: AppTheme.getCardColor(context),
      side: BorderSide(color: isSelected ? AppTheme.accentPurple : AppTheme.getCardBorder(context)),
      onSelected: (selected) {
        if (selected) setState(() => _guestHours = hours);
      },
    );
  }
}
