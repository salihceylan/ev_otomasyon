import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../models/api_models.dart';
import '../../../models/json_utils.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../../utils/qr_claim_parser.dart';
import '../../../utils/qr_router.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../claim/qr_scanner_page.dart';
import '../../theme/app_theme.dart';

/// Daire devri (ev sahibi) ve acil pano sıfırlama (süper kullanıcı / kalıcı servis personeli).
///
/// Sekmeler **yetkiye göre** gösterilir: devir yalnızca `canTransferOwnership`, acil sıfırlama
/// yalnızca `canEmergencyReset` olanlara; yetkisi olmayan sekme hiç görünmez.
///
/// * Devir: hedef (e-posta/telefon) **zorunlu**, biçimi doğrulanır, kendini hedefleme engellenir ve
///   "X kullanıcısına devredilecek" onayı **yazarak** (`DEVRET`) alınır.
/// * Acil sıfırlama: cihaz UID'si yazarak teyit edilir, gerekçe en az 15 karakterdir; sonuçtaki
///   uyarılar (`warnings` / `partial`) ve tek seferlik gizli değerler gösterilir. Ön-dolu değer yoktur.
class TransferOwnershipDialog extends StatefulWidget {
  /// 0: daire devri, 1: acil sıfırlama (yetkisi olmayan sekme yerine ilk yetkili sekme açılır).
  final int initialTab;
  const TransferOwnershipDialog({super.key, this.initialTab = 0});

  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: TransferOwnershipDialog(initialTab: initialTab),
      ),
    );
  }

  @override
  State<TransferOwnershipDialog> createState() => _TransferOwnershipDialogState();
}

enum _Tab { transfer, emergency }

class _TransferOwnershipDialogState extends State<TransferOwnershipDialog> {
  static const Duration _loadTimeout = Duration(seconds: 15);
  static const String _transferPhrase = 'DEVRET';

  final _targetController = TextEditingController();
  final _resetUidController = TextEditingController();
  final _resetReasonController = TextEditingController();
  final _resetNewOwnerController = TextEditingController();

  late _Tab _selected;

  // Devir
  bool _statusLoading = false;
  bool _statusLoaded = false;
  bool _actionLoading = false;
  String? _transferError;
  Map<String, dynamic>? _pendingTransfer;
  TransferInfo? _generated; // yalnızca bu oturumda üretilen kodu gösterebiliriz
  bool _startingNew = false;
  String? _targetFieldError;
  int _statusSeq = 0;

  // Acil sıfırlama
  bool _resetting = false;
  String? _resetError;
  String? _uidFieldError;
  String? _reasonFieldError;
  String? _ownerFieldError;
  EmergencyResetResult? _resetResult;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialTab == 1 ? _Tab.emergency : _Tab.transfer;
    _resetReasonController.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _statusSeq++;
    _resetReasonController.removeListener(_rebuild);
    _targetController.dispose();
    _resetUidController.dispose();
    _resetReasonController.dispose();
    _resetNewOwnerController.dispose();
    super.dispose();
  }

  _Tab? _effectiveTab(AutomationState state) {
    final caps = state.capabilities;
    final allowed = <_Tab>[
      if (caps.canTransferOwnership) _Tab.transfer,
      if (caps.canEmergencyReset) _Tab.emergency,
    ];
    if (allowed.isEmpty) return null;
    return allowed.contains(_selected) ? _selected : allowed.first;
  }

  // ---------------------------------------------------------------------------
  // Devir
  // ---------------------------------------------------------------------------

  Future<void> _loadTransferStatus() async {
    final state = context.read<AutomationState>();
    final seq = ++_statusSeq;
    setState(() {
      _statusLoading = true;
      _transferError = null;
    });
    try {
      final transfer = await state.getHomeTransferStatus().timeout(_loadTimeout);
      if (!mounted || seq != _statusSeq) return;
      setState(() {
        _pendingTransfer = transfer;
        _statusLoading = false;
        _statusLoaded = true;
      });
    } catch (e) {
      if (!mounted || seq != _statusSeq) return;
      setState(() {
        _transferError = friendlyError(e, fallback: 'Devir durumu alınamadı. Lütfen tekrar deneyin.');
        _statusLoading = false;
      });
    }
  }

  /// Hedef kimlik: zorunlu, biçim geçerli, kendi hesabı değil.
  ParsedIdentifier? _validateTarget(AutomationState state) {
    final text = _targetController.text.trim();
    if (text.isEmpty) {
      _targetFieldError = 'Devir için yeni sahibin e-posta veya telefonu zorunludur.';
      return null;
    }
    final parsed = AuthValidators.parseIdentifier(text);
    if (parsed == null) {
      _targetFieldError = 'Geçerli bir e-posta adresi veya telefon numarası girin.';
      return null;
    }
    if (_isSelf(state, parsed)) {
      _targetFieldError = 'Dairenizi kendinize devredemezsiniz.';
      return null;
    }
    _targetFieldError = null;
    return parsed;
  }

  bool _isSelf(AutomationState state, ParsedIdentifier parsed) {
    final me = state.currentUser;
    if (me == null) return false;
    final myEmail = me.email.trim().toLowerCase();
    final myPhone = AuthValidators.normalizePhone(me.phone);
    return (parsed.isEmail && myEmail.isNotEmpty && parsed.value == myEmail) ||
        (parsed.isPhone && myPhone != null && parsed.value == myPhone);
  }

  Future<void> _initiateTransfer() async {
    if (_actionLoading) return;
    final state = context.read<AutomationState>();
    final parsed = _validateTarget(state);
    if (parsed == null) {
      setState(() {});
      return;
    }
    setState(() {});
    final homeName = state.activeHome?.name ?? 'Bu daire';
    final confirmed = await ConfirmDestructiveDialog.show(
      context,
      title: 'Daire Devri Onayı',
      message: '"$homeName" dairesi ${parsed.value} kullanıcısına devredilecek.\n\n'
          'Kod kabul edildiği anda siz dahil mevcut tüm sakinlerin ve misafirlerin bu evdeki erişimi kalıcı '
          'olarak kaldırılır ve tüm oturumları kapatılır. Bu işlem geri alınamaz.',
      confirmPhrase: _transferPhrase,
      confirmLabel: 'Devri Başlat',
      icon: Icons.transfer_within_a_station,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _actionLoading = true;
      _transferError = null;
    });
    try {
      final info = await state.initiateHomeTransfer(targetIdentifier: parsed.value);
      if (!mounted) return;
      setState(() {
        _generated = info;
        _pendingTransfer = <String, dynamic>{
          'target_identifier': info.targetIdentifier ?? parsed.value,
          'expires_at': info.expiresAt?.toUtc().toIso8601String(),
        };
        _startingNew = false;
        _actionLoading = false;
        _statusLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transferError = friendlyError(e, fallback: 'Devir başlatılamadı. Lütfen tekrar deneyin.');
        _actionLoading = false;
      });
    }
  }

  Future<void> _cancelTransfer() async {
    if (_actionLoading) return;
    final state = context.read<AutomationState>();
    setState(() {
      _actionLoading = true;
      _transferError = null;
    });
    try {
      await state.cancelHomeTransfer();
      if (!mounted) return;
      setState(() {
        _pendingTransfer = null;
        _generated = null;
        _actionLoading = false;
        _startingNew = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Daire devir işlemi iptal edildi.'),
          backgroundColor: AppTheme.accentGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transferError = friendlyError(e, fallback: 'Devir iptal edilemedi. Lütfen tekrar deneyin.');
        _actionLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Acil sıfırlama
  // ---------------------------------------------------------------------------

  Future<void> _scanDeviceQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => QrScannerPage(
          title: 'Pano Karekodunu Tara',
          validator: (raw) => QrRouter.route(raw) is QrClaim ? null : 'Bu bir pano (cihaz etiketi) karekodu değil.',
        ),
      ),
    );
    if (raw == null || !mounted) return;
    final payload = QrRouter.route(raw);
    if (payload is QrClaim) {
      // Yalnızca cihaz kimliği alınır; etiketteki kurulum PIN'i kullanılmaz ve saklanmaz.
      setState(() {
        _resetUidController.text = payload.uid;
        _uidFieldError = null;
      });
    } else {
      setState(() => _uidFieldError = 'Okunan karekod bir pano etiketi değil.');
    }
  }

  bool _validateReset(AutomationState state) {
    var ok = true;
    final uid = QrClaimParser.normalizeUid(_resetUidController.text);
    if (uid == null) {
      _uidFieldError = _resetUidController.text.trim().isEmpty
          ? 'Cihaz kimliğini (UID) girin veya etiketini tarayın.'
          : 'Geçerli bir cihaz kimliği girin (AHBU- ile başlar).';
      ok = false;
    } else {
      _uidFieldError = null;
    }
    if (_resetReasonController.text.trim().length < 15) {
      _reasonFieldError = 'Gerekçe en az 15 karakter olmalıdır.';
      ok = false;
    } else {
      _reasonFieldError = null;
    }
    final ownerText = _resetNewOwnerController.text.trim();
    if (ownerText.isNotEmpty) {
      final parsed = AuthValidators.parseIdentifier(ownerText);
      if (parsed == null) {
        _ownerFieldError = 'Geçerli bir e-posta adresi veya telefon numarası girin.';
        ok = false;
      } else if (_isSelf(state, parsed)) {
        _ownerFieldError = 'Kendinizi yeni sahip olarak atayamazsınız.';
        ok = false;
      } else {
        _ownerFieldError = null;
      }
    } else {
      _ownerFieldError = null;
    }
    return ok;
  }

  Future<void> _executeEmergencyReset() async {
    if (_resetting) return;
    final state = context.read<AutomationState>();
    if (!_validateReset(state)) {
      setState(() {});
      return;
    }
    setState(() {});
    final uid = QrClaimParser.normalizeUid(_resetUidController.text)!;
    final reason = _resetReasonController.text.trim();
    final ownerText = _resetNewOwnerController.text.trim();
    final newOwner = ownerText.isEmpty ? null : AuthValidators.parseIdentifier(ownerText)!.value;

    // Cihaz kimliği YAZARAK teyit edilir (confirmUid).
    final confirmed = await ConfirmDestructiveDialog.show(
      context,
      title: 'Acil Sıfırlama Onayı',
      message: '$uid kimlikli cihaz sıfırlanacak; eski ailenin tüm yetkileri ve oturumları sonlandırılacak'
          '${newOwner == null ? ' ve cihaz stoğa alınacak' : ' ve cihaz $newOwner kullanıcısına devredilecek'}. '
          'Bu işlem geri alınamaz ve denetim kaydına işlenir.',
      confirmPhrase: uid,
      confirmLabel: 'Sıfırla',
      icon: Icons.restore,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _resetting = true;
      _resetError = null;
    });
    try {
      final res = await state.emergencyResetDevice(
        deviceUuid: uid,
        confirmUid: uid,
        reason: reason,
        newOwnerIdentifier: newOwner,
      );
      if (!mounted) return;
      setState(() {
        _resetResult = res;
        _resetting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resetError = friendlyError(e, fallback: 'Acil sıfırlama tamamlanamadı. Lütfen tekrar deneyin.');
        _resetting = false;
      });
    }
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$label panoya kopyalandı.'), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------------------------------------------------------------------------
  // Arayüz
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final caps = state.capabilities;
    final tab = _effectiveTab(state);
    final homeName = state.activeHome?.name ?? 'Evim';
    final bothTabs = caps.canTransferOwnership && caps.canEmergencyReset;

    // Devir sekmesi ilk kez göründüğünde durumu yükle.
    if (tab == _Tab.transfer && !_statusLoaded && !_statusLoading && _transferError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_statusLoaded && !_statusLoading && _transferError == null) {
          unawaited(_loadTransferStatus());
        }
      });
    }

    final title = bothTabs
        ? 'Daire Devri & Acil Sıfırlama'
        : (tab == _Tab.emergency ? 'Acil Pano Sıfırlama' : 'Daire Devri (Mülkiyet Transferi)');

    return PopScope(
      canPop: !(_actionLoading || _resetting),
      child: Dialog(
        backgroundColor: AppTheme.getSurfaceColor(context),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppTheme.getCardBorder(context)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: (tab == _Tab.emergency ? AppTheme.accentRed : AppTheme.accentAmber).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        tab == _Tab.emergency ? Icons.restore : Icons.transfer_within_a_station,
                        color: tab == _Tab.emergency ? AppTheme.accentRed : AppTheme.accentAmber,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (tab == _Tab.transfer)
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
                      onPressed: (_actionLoading || _resetting) ? null : () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Divider(height: 24, color: AppTheme.getCardBorder(context)),
                if (tab == null)
                  const InlineMessage.error('Bu işlem için yetkiniz yok.', key: Key('transfer_forbidden'))
                else ...[
                  if (bothTabs) ...[_buildTabSelector(tab), const SizedBox(height: 16)],
                  if (tab == _Tab.transfer) _buildTransfer(state) else _buildEmergency(state),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabSelector(_Tab current) {
    Widget tabButton(_Tab tab, String label, Color color, Key key) {
      final selected = current == tab;
      return Expanded(
        child: InkWell(
          key: key,
          onTap: () => setState(() => _selected = tab),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? color : AppTheme.getCardBorder(context)),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? color : AppTheme.getTextMuted(context),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tabButton(_Tab.transfer, 'Daire Devri (Kod & QR)', AppTheme.accentAmber, const Key('tab_transfer')),
        const SizedBox(width: 8),
        tabButton(_Tab.emergency, 'Acil Pano Sıfırlama', AppTheme.accentRed, const Key('tab_emergency')),
      ],
    );
  }

  // ---- Devir sekmesi ----

  Widget _buildTransfer(AutomationState state) {
    if (_statusLoading && !_statusLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator(key: Key('transfer_loading'))),
      );
    }
    if (_transferError != null && !_statusLoaded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineMessage.error(_transferError!, key: const Key('transfer_error')),
          const SizedBox(height: 12),
          ElevatedButton(
            key: const Key('btn_transfer_retry'),
            onPressed: _statusLoading ? null : _loadTransferStatus,
            child: const Text('Tekrar Dene'),
          ),
        ],
      );
    }
    if (_pendingTransfer != null && !_startingNew) return _buildActiveTransfer();
    return _buildNewTransferForm(state);
  }

  Widget _buildActiveTransfer() {
    final transfer = _pendingTransfer!;
    final generated = _generated;
    final target = asNonEmptyString(transfer['target_identifier'] ?? transfer['targetIdentifier']);
    final expires = generated?.expiresAt ?? asDate(transfer['expires_at'] ?? transfer['expiresAt']);
    final muted = AppTheme.getTextMuted(context);

    return Column(
      key: const Key('transfer_active'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InlineMessage.warning(
          'Bekleyen bir devir var. Yeni sahip kodu girdiği anda eski ailenin tüm yetkileri silinir.',
          key: const Key('transfer_pending_notice'),
        ),
        if (generated != null) ...[
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: AppTheme.accentAmber.withValues(alpha: 0.2), blurRadius: 16, spreadRadius: 2)],
              ),
              child: QrImageView(
                key: ValueKey<String>('qr_payload:${generated.qrContent}'),
                data: generated.qrContent,
                version: QrVersions.auto,
                size: 160.0,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.getCardColor(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.getCardBorder(context)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DEVİR KODU (48 saat geçerli)', style: TextStyle(fontSize: 10, color: muted)),
                      const SizedBox(height: 2),
                      SelectableText(
                        generated.code,
                        key: const Key('transfer_code'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: AppTheme.accentAmber),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('btn_copy_transfer_code'),
                  icon: const Icon(Icons.copy, size: 20, color: AppTheme.primaryBlueLight),
                  tooltip: 'Kodu Kopyala',
                  onPressed: () => _copy(generated.code, 'Devir kodu'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Bu kod yalnızca şimdi gösterilir; sunucuda yalnızca özeti saklanır.',
            style: TextStyle(fontSize: 11, color: muted),
            textAlign: TextAlign.center,
          ),
        ] else ...[
          const SizedBox(height: 12),
          Text(
            'Devir kodu güvenlik nedeniyle yalnızca üretildiği anda gösterilir. Kodu kaybettiyseniz devri iptal edip '
            'yeniden başlatın.',
            key: const Key('transfer_code_hidden'),
            style: TextStyle(fontSize: 12, color: muted, height: 1.35),
          ),
        ],
        if (target != null) ...[
          const SizedBox(height: 8),
          Text(
            'Yalnızca $target kullanıcısı devralabilir.',
            key: const Key('transfer_target_text'),
            style: TextStyle(fontSize: 11.5, color: muted, fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ],
        if (expires != null) ...[
          const SizedBox(height: 4),
          Text(
            'Son geçerlilik: ${formatLocalDateTime(expires)}',
            key: const Key('transfer_expiry_text'),
            style: TextStyle(fontSize: 11.5, color: muted),
            textAlign: TextAlign.center,
          ),
        ],
        if (_transferError != null) ...[
          const SizedBox(height: 10),
          InlineMessage.error(_transferError!, key: const Key('transfer_error')),
        ],
        const SizedBox(height: 18),
        OutlinedButton.icon(
          key: const Key('btn_cancel_transfer'),
          onPressed: _actionLoading ? null : _cancelTransfer,
          icon: _actionLoading
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.cancel_outlined, size: 18, color: AppTheme.accentRed),
          label: const Text('Devir İşlemini İptal Et', style: TextStyle(color: AppTheme.accentRed)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accentRed),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('btn_start_new_transfer'),
          onPressed: _actionLoading ? null : () => setState(() => _startingNew = true),
          child: const Text('Yeni Devir Başlat (öncekini geçersiz kılar)'),
        ),
      ],
    );
  }

  Widget _buildNewTransferForm(AutomationState state) {
    final muted = AppTheme.getTextMuted(context);
    return Column(
      key: const Key('transfer_form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InlineMessage.error(
          'DİKKAT: Devir kodu kabul edildiğinde dairenizin tüm sakinleri (siz dahil) kalıcı olarak silinir ve '
          'tüm oturumları kapatılır. Yalnızca daire satıldığında veya kiracı değiştiğinde kullanın.',
          key: const Key('transfer_warning'),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('field_transfer_target'),
          controller: _targetController,
          enabled: !_actionLoading,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) {
            if (_targetFieldError != null) setState(() => _targetFieldError = null);
          },
          decoration: InputDecoration(
            labelText: 'Yeni Sahip E-posta / Telefon (Zorunlu)',
            hintText: 'ornek@email.com veya 0555 123 45 67',
            labelStyle: TextStyle(fontSize: 12, color: muted),
            hintStyle: TextStyle(fontSize: 12, color: muted),
            prefixIcon: const Icon(Icons.person_outline, size: 20),
            errorText: _targetFieldError,
            errorMaxLines: 2,
            filled: true,
            fillColor: AppTheme.getCardColor(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Devri yalnızca bu hesap kabul edebilir. Hesap sahibine kodu güvenli bir kanaldan iletin.',
          style: TextStyle(fontSize: 11, color: muted),
        ),
        if (_transferError != null) ...[
          const SizedBox(height: 10),
          InlineMessage.error(_transferError!, key: const Key('transfer_error')),
        ],
        const SizedBox(height: 18),
        ElevatedButton.icon(
          key: const Key('btn_initiate_transfer'),
          onPressed: _actionLoading ? null : _initiateTransfer,
          icon: _actionLoading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.qr_code_2, size: 18),
          label: const Text('48 Saatlik Devir Kodu & QR Üret'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentAmber,
            foregroundColor: Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        if (_pendingTransfer != null) ...[
          const SizedBox(height: 8),
          TextButton(
            key: const Key('btn_pending_transfer_back'),
            onPressed: _actionLoading ? null : () => setState(() => _startingNew = false),
            child: const Text('Bekleyen devire dön'),
          ),
        ],
      ],
    );
  }

  // ---- Acil sıfırlama sekmesi ----

  Widget _buildEmergency(AutomationState state) {
    final result = _resetResult;
    if (result != null) return _buildResetResult(result);
    final muted = AppTheme.getTextMuted(context);
    final reasonLength = _resetReasonController.text.trim().length;

    InputDecoration deco(String label, String hint, IconData icon, {String? error, Widget? suffix}) => InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(fontSize: 12, color: muted),
          hintStyle: TextStyle(fontSize: 12, color: muted),
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: suffix,
          errorText: error,
          errorMaxLines: 2,
          filled: true,
          fillColor: AppTheme.getCardColor(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        );

    return Column(
      key: const Key('emergency_form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InlineMessage.error(
          'Eski kiracı ulaşılamıyorsa veya telefonu kayıpsa: panonun etiketini okutarak cihazı boşa çıkarabilir '
          'ya da doğrudan yeni sahibe devredebilirsiniz. Yetkiniz denetim kaydına işlenir.',
          key: Key('emergency_warning'),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('btn_reset_scan'),
            onPressed: _resetting ? null : _scanDeviceQr,
            icon: const Icon(Icons.qr_code_scanner, color: AppTheme.accentRed, size: 20),
            label: const Text(
              'Pano QR Kodunu Tara (Kamera)',
              style: TextStyle(color: AppTheme.accentRed, fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppTheme.accentRed.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('field_reset_uid'),
          controller: _resetUidController,
          enabled: !_resetting,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
            LengthLimitingTextInputFormatter(37),
          ],
          onChanged: (_) {
            if (_uidFieldError != null) setState(() => _uidFieldError = null);
          },
          decoration: deco('Cihaz UID (Pano Etiketi)', 'AHBU-S3-XXXXXX', Icons.qr_code, error: _uidFieldError),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('field_reset_reason'),
          controller: _resetReasonController,
          enabled: !_resetting,
          minLines: 1,
          maxLines: 3,
          maxLength: 300,
          onChanged: (_) {
            if (_reasonFieldError != null) setState(() => _reasonFieldError = null);
          },
          decoration: deco(
            'Sıfırlama Gerekçesi (en az 15 karakter)',
            'Örn: Kiracı tahliye edildi, sözleşme ibraz edildi',
            Icons.description_outlined,
            error: _reasonFieldError,
          ).copyWith(counterText: '$reasonLength / 15+'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('field_reset_new_owner'),
          controller: _resetNewOwnerController,
          enabled: !_resetting,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) {
            if (_ownerFieldError != null) setState(() => _ownerFieldError = null);
          },
          decoration: deco(
            'Yeni Sahip E-posta / Telefon (Opsiyonel)',
            'Boş bırakılırsa cihaz stoğa alınır',
            Icons.person_outline,
            error: _ownerFieldError,
          ),
        ),
        if (_resetError != null) ...[
          const SizedBox(height: 12),
          InlineMessage.error(_resetError!, key: const Key('reset_error')),
        ],
        const SizedBox(height: 16),
        ElevatedButton.icon(
          key: const Key('btn_reset_submit'),
          onPressed: _resetting ? null : _executeEmergencyReset,
          icon: _resetting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.restore, size: 18),
          label: const Text('Acil Sıfırla & Eski Aileyi Çıkar'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentRed,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildResetResult(EmergencyResetResult res) {
    final muted = AppTheme.getTextMuted(context);
    final warnings = <String>[
      ...res.warnings,
      if (res.partial && res.warnings.isEmpty)
        'İşlem kısmen tamamlandı: bazı adımlar uygulanamadı. Cihazın ve ev durumunu kontrol edin.',
    ];
    final String headline;
    if (res.isUnclaimed) {
      headline = 'Cihaz sıfırlandı ve stoğa alındı.';
    } else if (res.isReassigned) {
      final owner = res.newOwner;
      headline = owner == null || owner.fullName.isEmpty
          ? 'Cihaz yeni sahibine devredildi.'
          : 'Cihaz ${owner.fullName} hesabına devredildi.';
    } else {
      headline = res.message.isNotEmpty ? res.message : 'Acil sıfırlama tamamlandı.';
    }

    return Column(
      key: const Key('emergency_result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        res.hasWarnings
            ? InlineMessage.warning('$headline Bazı adımlar eksik kaldı; aşağıdaki uyarılara bakın.', key: const Key('reset_headline'))
            : InlineMessage.success(headline, key: const Key('reset_headline')),
        if (res.affectedUsersCount > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${res.affectedUsersCount} kullanıcının erişimi kaldırıldı.',
            key: const Key('reset_affected'),
            style: TextStyle(fontSize: 12.5, color: muted),
          ),
        ],
        for (var i = 0; i < warnings.length; i++) ...[
          const SizedBox(height: 8),
          InlineMessage.warning(warnings[i], key: Key('reset_warning_$i')),
        ],
        if (res.setupPin != null) ...[
          const SizedBox(height: 12),
          _secretCard(
            caption: 'YENİ KURULUM PIN (yalnızca bir kez gösterilir)',
            value: res.setupPin!,
            valueKey: const Key('reset_setup_pin'),
            copyKey: const Key('btn_copy_setup_pin'),
            label: 'Kurulum PIN\'i',
          ),
        ],
        if (res.needsManualLocalKey) ...[
          const SizedBox(height: 12),
          _secretCard(
            caption: 'YEREL ANAHTAR (cihaza iletilemedi; yerinde girilmeli)',
            value: res.localKey!,
            valueKey: const Key('reset_local_key'),
            copyKey: const Key('btn_copy_local_key'),
            label: 'Yerel anahtar',
          ),
        ],
        if (res.isReassigned && res.deviceCredential != null) ...[
          const SizedBox(height: 12),
          const InlineMessage.info(
            'Yeni sahip için bulut kimliği üretildi; panoya yazılması gerekir. Servis kurulum sihirbazının '
            '"Bulut Bağlantısı" adımını kullanın (kimlik gerekirse yeniden üretilebilir).',
            key: Key('reset_credential_note'),
          ),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          key: const Key('btn_reset_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Kapat'),
        ),
      ],
    );
  }

  Widget _secretCard({
    required String caption,
    required String value,
    required Key valueKey,
    required Key copyKey,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(caption, style: TextStyle(fontSize: 10, color: AppTheme.getTextMuted(context))),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  key: valueKey,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: AppTheme.accentAmber),
                ),
              ],
            ),
          ),
          IconButton(
            key: copyKey,
            icon: const Icon(Icons.copy, size: 20, color: AppTheme.primaryBlueLight),
            tooltip: 'Kopyala',
            onPressed: () => _copy(value, label),
          ),
        ],
      ),
    );
  }
}
