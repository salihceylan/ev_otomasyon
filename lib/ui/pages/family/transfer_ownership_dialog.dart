import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../models/api_models.dart';
import '../../../models/cloud_models.dart';
import '../../../models/json_utils.dart';
import '../../../services/automation_state.dart';
import '../../../services/clock.dart';
import '../../../utils/friendly_error.dart';
import '../../../utils/qr_claim_parser.dart';
import '../../../utils/qr_router.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../claim/qr_scanner_page.dart';
import '../service_setup/panel/emergency_reset_card.dart' show EmergencyResetCard, EmergencyResetResultDialog;
import '../service_setup/panel/uncertain_outcome_card.dart';
import '../../motion/motion_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/settings/accent_button.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';
import 'countdown_ring.dart';
import '../../theme/feature_accent.dart';

/// Daire devri (ev sahibi) ve acil pano sıfırlama (süper kullanıcı / kalıcı servis personeli).
///
/// Sekmeler **yetkiye göre** gösterilir: devir yalnızca `canTransferOwnership`, acil sıfırlama
/// yalnızca `canEmergencyReset` olanlara; yetkisi olmayan sekme hiç görünmez.
///
/// * Devir: hedef (e-posta/telefon) **zorunlu**, biçimi doğrulanır, kendini hedefleme engellenir ve
///   "X kullanıcısına devredilecek" onayı **yazarak** (`DEVRET`) alınır.
/// * Acil sıfırlama: cihaz UID'si yazarak teyit edilir, gerekçe en az 15 karakterdir; sonuçtaki
///   uyarılar (`warnings` / `partial`) ve tek seferlik gizli değerler gösterilir. Ön-dolu değer yoktur.
///   **Sonucu belirsiz kesinti (PF-45):** yanıt 40 sn içinde gelmez ya da ağ kesilirse işlem sunucuda
///   tamamlanmış olabilir; "tekrar deneyin" DENMEZ (kör tekrar yeni PIN üretir ve devredilen sahibi bozabilir),
///   envanterde "Durumu Kontrol Et" sunulur ve belirsizken gönder düğmesi pasiftir (servis panelindeki
///   `EmergencyResetCard` ile aynı sözleşme).
///   Kalıcı servis personeli (süper değil) kapsam notunu görür; 403'te yönlendirme hatanın altında gösterilir. Yerel
///   anahtar `pending` ise bilgi notu, eski sunucu yanıtındaki anahtar için seri konsol (RESETKEY + FACTORYINIT)
///   yönergesi gösterilir (metinler [EmergencyResetCard] / [EmergencyResetResultDialog] ile ortak).
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

/// Diyaloğun durumdan okuduğu değerler (PF-06: `context.select`; `Capabilities` yerine skalerler).
/// [resetLimited]: acil sıfırlama yetkisi var ama süper değil (kalıcı servis personeli: 72 saatlik kapsam).
/// [isSuper]: süper yönetici (sunucu ona yerel anahtar vermez; devrinde sihirbaz yolu yok, M4-02).
typedef _TransferView = ({bool canTransfer, bool canReset, bool resetLimited, bool isSuper, String homeName});

class _TransferOwnershipDialogState extends State<TransferOwnershipDialog> {
  static const Duration _loadTimeout = Duration(seconds: 15);

  /// Acil sıfırlama yanıtı için üst süre (servis panelindeki `EmergencyResetCard` ile aynı).
  static const Duration _resetTimeout = Duration(seconds: 40);
  static const Duration _checkTimeout = Duration(seconds: 20);

  /// Devir başlatma/iptal bu süreyi aşarsa "Kapat" sunulur (PF-50). Acil sıfırlama için YOKTUR: yeni PIN yalnızca
  /// yanıtla birlikte gösterilir, 40 sn sınırı ve belirsiz-sonuç kartı o yolu zaten kapatır.
  static const Duration _slowAfter = Duration(seconds: 25);
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
  Timer? _slowTimer;
  bool _slow = false;

  // Acil sıfırlama
  bool _resetting = false;
  String? _resetError;

  /// [_resetError] sunucunun 403'üdür ve kullanıcı süper değildir: kapsam yönlendirmesi hatanın altında gösterilir.
  bool _resetForbidden = false;
  String? _uidFieldError;
  String? _reasonFieldError;
  String? _ownerFieldError;
  EmergencyResetResult? _resetResult;

  /// Yanıt gelmedi (zaman aşımı / ağ kesintisi) ama sunucu sıfırlamayı tamamlamış olabilir: bu cihaz için işlem
  /// **körlemesine yinelenmez**; önce durum kontrol edilir (PF-45).
  String? _uncertainUid;
  bool _checking = false;
  String? _checkResult;

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
    _slowTimer?.cancel();
    _resetReasonController.removeListener(_rebuild);
    _targetController.dispose();
    _resetUidController.dispose();
    _resetReasonController.dispose();
    _resetNewOwnerController.dispose();
    super.dispose();
  }

  static _TransferView _viewOf(AutomationState state) {
    final caps = state.capabilities;
    return (
      canTransfer: caps.canTransferOwnership,
      canReset: caps.canEmergencyReset,
      resetLimited: caps.canEmergencyReset && !caps.isSuperUser,
      isSuper: caps.isSuperUser,
      homeName: state.activeHome?.name ?? 'Evim',
    );
  }

  _Tab? _effectiveTab(_TransferView view) {
    final allowed = <_Tab>[
      if (view.canTransfer) _Tab.transfer,
      if (view.canReset) _Tab.emergency,
    ];
    if (allowed.isEmpty) return null;
    return allowed.contains(_selected) ? _selected : allowed.first;
  }

  /// Devir başlatma/iptal işlemini başlatır ve [_slowAfter] sonra "yavaş" bayrağını kurar (`setState` içinde
  /// çağrılır). Zamanlayıcı `Clock`'tandır (testlerde sahte saat).
  void _beginAction() {
    _actionLoading = true;
    _slow = false;
    _slowTimer?.cancel();
    _slowTimer = context.read<AutomationState>().clock.timer(_slowAfter, () {
      if (mounted && _actionLoading) setState(() => _slow = true);
    });
  }

  /// İşlemi bitirir (`setState` içinde çağrılır).
  void _endAction() {
    _actionLoading = false;
    _slow = false;
    _slowTimer?.cancel();
    _slowTimer = null;
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
      _beginAction();
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
        _endAction();
        _statusLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transferError = friendlyError(e, fallback: 'Devir başlatılamadı. Lütfen tekrar deneyin.');
        _endAction();
      });
    }
  }

  Future<void> _cancelTransfer() async {
    if (_actionLoading) return;
    final state = context.read<AutomationState>();
    setState(() {
      _beginAction();
      _transferError = null;
    });
    try {
      await state.cancelHomeTransfer();
      if (!mounted) return;
      setState(() {
        _pendingTransfer = null;
        _generated = null;
        _endAction();
        _startingNew = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: const Text('Daire devir işlemi iptal edildi.'),
          // Beyaz yazılı dolgu tonu (ham yeşil zeminde beyaz metin ≈2.5:1 idi).
          backgroundColor: AppTheme.filledAccent(AppTheme.accentGreen),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transferError = friendlyError(e, fallback: 'Devir iptal edilemedi. Lütfen tekrar deneyin.');
        _endAction();
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
        if (_uncertainUid != null && QrClaimParser.normalizeUid(payload.uid) != _uncertainUid) {
          _uncertainUid = null; // başka cihaz: önceki cihazın belirsizlik kilidi kalkar
          _checkResult = null;
        }
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
      _resetForbidden = false;
    });
    try {
      // PF-45: üst süre (40 sn). Zamanlayıcı `Clock`'tandır; geç dönen yanıt yok sayılır.
      final res = await state.clock.bound<EmergencyResetResult>(
        state.emergencyResetDevice(
          deviceUuid: uid,
          confirmUid: uid,
          reason: reason,
          newOwnerIdentifier: newOwner,
        ),
        _resetTimeout,
        () => throw TimeoutException('Acil sıfırlama yanıtı zamanında gelmedi.', _resetTimeout),
      );
      if (!mounted) return;
      setState(() {
        _resetResult = res;
        _resetting = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (UncertainOutcomeCard.isUncertain(e)) {
        // Sunucu işlemi tamamlamış olabilir: "tekrar dene" denmez, durum kontrolü istenir.
        setState(() {
          _resetting = false;
          _resetError = null;
          _uncertainUid = uid;
          _checkResult = null;
        });
        return;
      }
      setState(() {
        _resetError = friendlyError(e, fallback: 'Acil sıfırlama tamamlanamadı. Lütfen tekrar deneyin.');
        // 403: servis personelinin kapsamı dışındaki daire (ya da iptal/askı): süper yönetici yönlendirmesi hatanın altında.
        _resetForbidden = e is ApiException && e.isForbidden && !state.capabilities.isSuperUser;
        _resetting = false;
      });
    }
  }

  /// Sonucu belirsiz kalan sıfırlamada cihazın envanterdeki **gerçek** durumuna bakar (PF-45).
  Future<void> _checkOutcome() async {
    final uid = _uncertainUid;
    if (uid == null || _checking) return;
    final state = context.read<AutomationState>();
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    String result;
    try {
      final res = await state.clock.bound<Map<String, dynamic>>(
        state.cloudApi.fetchDeviceInventory(search: uid, limit: 5),
        _checkTimeout,
        () => throw TimeoutException('Envanter yanıtı zamanında gelmedi.', _checkTimeout),
      );
      if (!mounted) return;
      final items = parseList(res['items'], InventoryDeviceModel.fromJson, label: 'Inventory');
      InventoryDeviceModel? match;
      for (final item in items) {
        if (item.deviceUuid.toUpperCase() == uid.toUpperCase()) match = item;
      }
      if (match == null) {
        result = 'Bu hesapla cihazın durumu görüntülenemiyor (cihaz sizin stoğunuzda değil). Süper yöneticiden '
            'cihazın durumuna bakmasını isteyin; durum doğrulanmadan sıfırlamayı yinelemeyin.';
      } else if (match.isInStock) {
        result = 'Cihaz şu an STOKTA: sıfırlama sunucuda tamamlanmış görünüyor. Yeni kurulum PIN\'i yanıt gelmediği '
            'için alınamadı; PIN gerekiyorsa süper yöneticiden Cihaz Envanteri > "Etiketi Yeniden Üret" ile yeni PIN '
            'almasını isteyin.';
      } else if (match.isClaimed) {
        final home = match.claimedHomeName;
        result = 'Cihaz şu an bir daireye bağlı${home == null || home.isEmpty ? '' : ' ("$home")'}. Sıfırlama yapılmamış '
            'olabilir ya da cihaz yeni sahibe devredilmiş olabilir; daire adını kontrol edin. Emin olmadan yinelemeyin.';
      } else {
        result = 'Cihazın durumu: ${match.statusLabel}. Sıfırlama yetkisi bu durumda sınırlıdır; süper yöneticiye danışın.';
      }
    } catch (e) {
      if (!mounted) return;
      result = 'Durum kontrol edilemedi: ${friendlyError(e, fallback: 'Bağlantınızı kontrol edip yeniden deneyin.')}';
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkResult = result;
    });
  }

  /// Cihaz kimliği değişince önceki cihazın belirsiz-sonuç uyarısı kalkar; alan hatası temizlenir.
  void _onResetUidChanged(String text) {
    final pending = _uncertainUid;
    final clearUncertain = pending != null && QrClaimParser.normalizeUid(text) != pending;
    if (_uidFieldError != null || clearUncertain) {
      setState(() {
        _uidFieldError = null;
        if (clearUncertain) {
          _uncertainUid = null;
          _checkResult = null;
        }
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
    // PF-06: yalnız bu diyaloğun okuduğu yetkiler ve ev adı izlenir; ilgisiz bildirim diyaloğu yeniden kurmaz.
    final view = context.select<AutomationState, _TransferView>(_viewOf);
    final tab = _effectiveTab(view);
    final homeName = view.homeName;
    final bothTabs = view.canTransfer && view.canReset;
    // Sıfırlama sürerken kapatılamaz (yeni PIN yalnızca yanıtla gelir); devir başlatma/iptal 25 sn sonra kapatılabilir.
    final busyLocked = _resetting || (_actionLoading && !_slow);

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
      canPop: !busyLocked,
      // Yüzey ve şekil temanın diyalog stilinden gelir (yerel zemin/şekil override'ı yok).
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
                    OrbIconBadge(
                      icon: tab == _Tab.emergency ? Icons.restore_rounded : Icons.swap_horiz_rounded,
                      family: tab == _Tab.emergency ? AppFeature.emergencyReset.accentFamily : AppFeature.ownershipTransfer.accentFamily,
                      active: true,
                      pending: _actionLoading || _resetting,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                            maxLines: 2,
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
                      onPressed: busyLocked ? null : () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Divider(height: 24, color: AppTheme.getCardBorder(context)),
                // PF-50: yalnız düğme içi küçük çark değil, belirgin ilerleme + beklenen süre.
                if (_actionLoading || _resetting) ...[
                  DialogBusyNotice(
                    key: Key(_resetting ? 'reset_busy_notice' : 'transfer_busy_notice'),
                    message: _resetting
                        ? 'Acil sıfırlama sürüyor… Yanıt en çok ${_resetTimeout.inSeconds} sn beklenir; bu sırada '
                            'pencereyi kapatmayın (yeni PIN yalnızca yanıtla birlikte gösterilir).'
                        : 'İşlem sürüyor…',
                    slow: _slow && !_resetting,
                    slowMessage: 'Sunucu yanıtı gecikiyor. Pencereyi kapatabilirsiniz; işlem arka planda sürer. '
                        'Not: devir kodu yalnızca üretildiği anda bu pencerede gösterilir.',
                  ),
                  const SizedBox(height: 12),
                ],
                if (tab == null)
                  const InlineMessage.error('Bu işlem için yetkiniz yok.', key: Key('transfer_forbidden'))
                else ...[
                  if (bothTabs) ...[_buildTabSelector(tab), const SizedBox(height: 16)],
                  if (tab == _Tab.transfer) _buildTransfer() else _buildEmergency(limited: view.resetLimited, isSuper: view.isSuper),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabSelector(_Tab current) {
    Widget tabButton(_Tab tab, String label, AccentFamily family, Key key) {
      final selected = current == tab;
      final color = family.base;
      // Seçili etiket OKUNUR tonda (ham amber/kırmızı açık temada ≈2–3.8:1 idi); kenar açıkta koyu ton.
      final ink = AppTheme.readableAccent(context, color);
      final edge = AppTheme.isDark(context) ? color : family.deep;
      return Expanded(
        child: InkWell(
          key: key,
          onTap: () => setState(() => _selected = tab),
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: AnimatedContainer(
            duration: MotionScope.durationOf(context, AppMotion.fast),
            curve: AppMotion.standard,
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            decoration: BoxDecoration(
              gradient: selected
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      // Okunur ton, bu tintin (en çok %16) üstünde de AA (≥ 4.5:1) kalır (hesaplandı: ≥ 5.2:1).
                      colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0.08)],
                    )
                  : null,
              borderRadius: BorderRadius.circular(AppRadius.r12),
              // Seçili olmayan sekme bir KONTROLDÜR: sınırı ≥ 3:1 (alan çerçevesiyle aynı dil; dekoratif kart kenarı değil).
              border: Border.all(color: selected ? edge : AppTheme.getFieldBorder(context), width: selected ? 1.4 : 1),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? ink : AppTheme.getTextMuted(context),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tabButton(_Tab.transfer, 'Daire Devri (Kod & QR)', AppFeature.ownershipTransfer.accentFamily, const Key('tab_transfer')),
        const SizedBox(width: 8),
        tabButton(_Tab.emergency, 'Acil Pano Sıfırlama', AppFeature.emergencyReset.accentFamily, const Key('tab_emergency')),
      ],
    );
  }

  // ---- Devir sekmesi ----

  Widget _buildTransfer() {
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
    return _buildNewTransferForm();
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
          SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            accent: AppFamilies.amber.base,
            active: true,
            radius: AppRadius.r16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (expires != null) ...[
                  CountdownRing(
                    expiresAt: expires,
                    total: const Duration(hours: 48),
                    now: context.read<AutomationState>().clock.now,
                    color: AppFamilies.amber.base,
                    diameter: 36,
                  ),
                  const SizedBox(width: 12),
                ],
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DEVİR KODU (48 saat geçerli)', style: TextStyle(fontSize: 12, color: muted)),
                      const SizedBox(height: 2),
                      // Kod tek satırda ve eksiksiz: sığmazsa küçülür (ortadan bölünüp kaybolmaz).
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: SelectableText(
                          generated.code,
                          key: const Key('transfer_code'),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                            // Açık temada ham amber ≈2.1:1 idi: okunur uyarı tonu.
                            color: AppTheme.warningText(context),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('btn_copy_transfer_code'),
                  icon: Icon(Icons.copy_rounded, size: 20, color: AppTheme.infoText(context)),
                  tooltip: 'Kodu Kopyala',
                  onPressed: () => _copy(generated.code, 'Devir kodu'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Bu kod yalnızca şimdi gösterilir; sunucuda yalnızca özeti saklanır.',
            style: TextStyle(fontSize: 12, color: muted),
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
            style: TextStyle(fontSize: 12, color: muted, fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ],
        if (expires != null) ...[
          const SizedBox(height: 4),
          Text(
            'Son geçerlilik: ${formatLocalDateTime(expires)}',
            key: const Key('transfer_expiry_text'),
            style: TextStyle(fontSize: 12, color: muted),
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
              : Icon(Icons.cancel_outlined, size: accentIconSize(context)),
          label: const Text('Devir İşlemini İptal Et', textAlign: TextAlign.center),
          // Metin, simge ve çerçeve aynı aileden ve okunur tonda (açık temada ham kırmızı ≈3.8:1).
          style: accentOutlinedButtonStyle(context, AppFeature.emergencyReset.accentFamily),
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

  Widget _buildNewTransferForm() {
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
            // Uzun etiket 1.0'da bile "…" ile kesiliyordu: kısa etiket ('Yeni Sahip'); "e-posta ya da telefon, zorunlu"
            // bilgisi yardımcı metinde (1.5 ölçekte de kesilmez).
            labelText: 'Yeni Sahip',
            helperText: 'E-posta veya telefon · Zorunlu',
            helperMaxLines: 2,
            helperStyle: TextStyle(fontSize: 12, color: muted),
            hintText: 'ornek@email.com veya 0555 123 45 67',
            labelStyle: TextStyle(fontSize: 12, color: muted),
            hintStyle: TextStyle(fontSize: 12, color: muted),
            prefixIcon: const Icon(Icons.person_outline, size: 20),
            errorText: _targetFieldError,
            errorMaxLines: 2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Devri yalnızca bu hesap kabul edebilir. Hesap sahibine kodu güvenli bir kanaldan iletin.',
          style: TextStyle(fontSize: 12, color: muted),
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
          style: accentButtonStyle(AppFeature.ownershipTransfer.accentFamily),
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

  /// [limited]: kalıcı servis personeli (süper değil); sıfırlama kapsamı notu gösterilir.
  Widget _buildEmergency({required bool limited, required bool isSuper}) {
    final result = _resetResult;
    if (result != null) return _buildResetResult(result, isSuper: isSuper);
    final muted = AppTheme.getTextMuted(context);
    final reasonLength = _resetReasonController.text.trim().length;
    // 403 sonrası kapsam yönlendirmesi hatanın altında gösterilir: aynı not ekranda iki kez yazılmaz.
    final hintInError = _resetError != null && _resetForbidden;

    InputDecoration deco(String label, String hint, IconData icon, {String? error, Widget? suffix, String? helper}) =>
        InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          helperStyle: TextStyle(fontSize: 12, color: muted),
          hintText: hint,
          labelStyle: TextStyle(fontSize: 12, color: muted),
          hintStyle: TextStyle(fontSize: 12, color: muted),
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: suffix,
          errorText: error,
          errorMaxLines: 2,
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
        if (limited && !hintInError) ...[
          const SizedBox(height: 8),
          const InlineMessage.info(EmergencyResetCard.staffScopeNote, key: Key('reset_staff_scope_note')),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('btn_reset_scan'),
            onPressed: _resetting ? null : _scanDeviceQr,
            icon: Icon(Icons.qr_code_scanner, size: accentIconSize(context, base: 20)),
            label: const Text(
              'Pano QR Kodunu Tara (Kamera)',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            style: accentOutlinedButtonStyle(context, AppFeature.emergencyReset.accentFamily),
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
          onChanged: _onResetUidChanged,
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
            'Sıfırlama Gerekçesi',
            'Örn: Kiracı tahliye edildi, sözleşme ibraz edildi',
            Icons.description_outlined,
            error: _reasonFieldError,
            helper: 'En az 15 karakter',
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
          // Kısa etiket ('Yeni Sahip'): 1.5 ölçekte "Yeni Sahip E-posta / Tel…" diye kesiliyordu; e-posta/telefon bilgisi
          // yardımcı metinde.
          decoration: deco(
            'Yeni Sahip',
            'Boş bırakılırsa cihaz stoğa alınır',
            Icons.person_outline,
            error: _ownerFieldError,
            helper: 'E-posta veya telefon · Opsiyonel',
          ),
        ),
        if (_resetError != null) ...[
          const SizedBox(height: 12),
          InlineMessage.error(_resetError!, key: const Key('reset_error')),
          if (hintInError) ...[
            const SizedBox(height: 8),
            const InlineMessage.info(EmergencyResetCard.staffScopeNote, key: Key('reset_forbidden_hint')),
          ],
        ],
        if (_uncertainUid != null)
          UncertainOutcomeCard(
            key: const Key('reset_uncertain'),
            title: 'Sıfırlamanın sonucu belirsiz',
            message: 'Sunucudan yanıt alınamadı (zaman aşımı ya da bağlantı kesintisi). Sıfırlama sunucuda '
                'TAMAMLANMIŞ olabilir; aynı işlemi körlemesine yinelemek yeni PIN üretir ve devredilen sahibi '
                'bozabilir. Önce "Durumu Kontrol Et" ile cihazın gerçek durumuna bakın.',
            checkButtonKey: const Key('btn_reset_check'),
            onCheck: _checkOutcome,
            checking: _checking,
            checkResult: _checkResult,
          ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          key: const Key('btn_reset_submit'),
          // Sonucu belirsiz kalan işlem durum kontrol edilmeden yinelenemez (cihaz kimliği değişirse kilit kalkar).
          onPressed: (_resetting || _uncertainUid != null) ? null : _executeEmergencyReset,
          icon: _resetting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.restore, size: 18),
          label: const Text('Acil Sıfırla & Eski Aileyi Çıkar'),
          style: accentButtonStyle(AppFeature.emergencyReset.accentFamily),
        ),
      ],
    );
  }

  Widget _buildResetResult(EmergencyResetResult res, {required bool isSuper}) {
    final muted = AppTheme.getTextMuted(context);
    // Bekleyen anahtar uyarısı (eski sunucu) aşağıdaki bilgi notunda verilir; uyarı satırı olarak tekrarlanmaz.
    final shown = res.displayWarnings;
    final warnings = <String>[
      ...shown,
      if (res.isPartial && shown.isEmpty)
        'İşlem kısmen tamamlandı: bazı adımlar uygulanamadı. Cihazın ve ev durumunu kontrol edin.',
    ];
    // Süper yöneticiye sunucu yerel anahtar vermez: sihirbaz yolu onun için çıkmaz (M4-02).
    final superHandoff = res.isReassigned && isSuper;
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
        if (res.localKeyPending) ...[
          const SizedBox(height: 12),
          const InlineMessage.info(EmergencyResetResultDialog.keyPendingNote, key: Key('reset_key_pending')),
        ],
        if (res.needsManualLocalKey) ...[
          // Eski sunucu yanıtı: anahtar panoya iletilemedi ve ağ üzerinden yazılamaz (seri konsol yolu).
          const SizedBox(height: 12),
          _secretCard(
            caption: 'YEREL ANAHTAR (panoya iletilemedi)',
            value: res.localKey!,
            valueKey: const Key('reset_local_key'),
            copyKey: const Key('btn_copy_local_key'),
            label: 'Yerel anahtar',
          ),
          const SizedBox(height: 6),
          Text(
            EmergencyResetResultDialog.manualKeyHint,
            key: const Key('reset_key_manual_hint'),
            style: TextStyle(fontSize: 12.5, color: muted),
          ),
        ],
        if (superHandoff) ...[
          const SizedBox(height: 12),
          const InlineMessage.info(EmergencyResetResultDialog.superHandoffNote, key: Key('reset_super_note')),
        ] else if (res.isReassigned && res.deviceCredential != null) ...[
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
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      accent: AppFamilies.amber.base,
      active: true,
      radius: AppRadius.r16,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(caption, style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context))),
                const SizedBox(height: 2),
                // Cihazda ELLE girilecek gizli değer (yerel anahtar, PIN): tek satırda ve eksiksiz kalır; sığmazsa küçülür
                // (davet/devir kodlarıyla aynı kural). Satır kırılımı rakam grubunu ortadan bölüp aktarım hatasına yol açardı.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: SelectableText(
                    value,
                    key: valueKey,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      color: AppTheme.warningText(context),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: copyKey,
            icon: Icon(Icons.copy, size: 20, color: AppTheme.infoText(context)),
            tooltip: 'Kopyala',
            onPressed: () => _copy(value, label),
          ),
        ],
      ),
    );
  }
}
