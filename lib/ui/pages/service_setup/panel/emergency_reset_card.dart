import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../models/api_models.dart';
import '../../../../models/cloud_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/automation_state.dart';
import '../../../../utils/friendly_error.dart';
import '../../../../utils/qr_claim_parser.dart';
import '../../../common/confirm_dialogs.dart';
import '../logic/customer_logic.dart';
import '../secret_clipboard.dart';
import '../secret_value_row.dart';
import '../service_setup_wizard_page.dart';
import '../service_target.dart';
import '../setup_fields.dart';
import '../setup_steps.dart';
import '../setup_style.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb_core.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';
import '../steps/step_common.dart';
import 'uncertain_outcome_card.dart';
import '../../../theme/feature_accent.dart';

/// Acil servis sıfırlaması (yalnızca süper yönetici ve kalıcı servis personeli).
///
/// * Cihaz kimliği **önceden doldurulmaz**; etiketten okutulur ya da elle yazılır.
/// * Gerekçe en az 15 karakterdir; sıfırlama **cihaz kimliği yazılarak** onaylanır
///   ([ConfirmDestructiveDialog]).
/// * Yeni sahip (isteğe bağlı) e-posta/telefon olarak doğrulanır ve normalleştirilir.
/// * Sonuçtaki uyarılar / kısmi başarı kullanıcıya gösterilir; tek seferlik gizli değerler
///   ([EmergencyResetResultDialog]) panoya yalnızca 45 sn kalacak şekilde kopyalanır.
/// * Kalıcı servis personeli (süper olmayan) yalnızca süresi dolmamış (72 saatlik) servis üyeliği olan dairelerin
///   panolarını sıfırlayabilir (sunucu kuralı): kart bunu [staffScopeNote] ile söyler; sunucu 403 dönerse yönlendirme
///   hata kutusunda gösterilir.
class EmergencyResetCard extends StatefulWidget {
  const EmergencyResetCard({super.key, this.scanner = defaultSetupScanner});

  final SetupScanner scanner;

  /// Gerekçenin en az uzunluğu (sunucu ve istemci aynı kuralı uygular).
  static const int minReasonLength = 15;

  /// Servis personelinin (süper olmayan) sıfırlama kapsamı: sunucu yalnız süresi dolmamış servis üyeliği olan dairenin
  /// panosuna izin verir (üyelik kurulum/devirde 72 saatliğine verilir).
  static const String staffScopeNote = 'Servis personeli yalnız son 72 saat içinde kurduğu ya da devraldığı dairelerin '
      'panolarını sıfırlayabilir; diğer daireler için süper yöneticiye başvurun.';

  @override
  State<EmergencyResetCard> createState() => _EmergencyResetCardState();
}

class _EmergencyResetCardState extends State<EmergencyResetCard> {
  static const Duration _timeout = Duration(seconds: 40);
  static const Duration _checkTimeout = Duration(seconds: 20);

  final TextEditingController _uid = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final TextEditingController _owner = TextEditingController();

  bool _busy = false;
  String? _uidError;
  String? _reasonError;
  String? _ownerError;
  String? _error;

  /// [_error] sunucunun 403'üdür ve kullanıcı süper değildir: kapsam yönlendirmesi ([EmergencyResetCard.staffScopeNote])
  /// hata kutusunda gösterilir.
  bool _forbiddenHint = false;

  /// Yanıt gelmedi (zaman aşımı / ağ kesintisi) ama sunucu sıfırlamayı tamamlamış olabilir: bu cihaz için
  /// işlem **körlemesine yinelenmez**; önce durum kontrol edilir.
  String? _uncertainUid;
  bool _checking = false;
  String? _checkResult;

  @override
  void dispose() {
    _uid.dispose();
    _reason.dispose();
    _owner.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await widget.scanner(
      context,
      title: 'Sıfırlanacak panonun etiketi',
      hint: 'Panonun üzerindeki etiketin karekodunu okutun.',
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    // Etiket karekodunda PIN de bulunabilir: yalnızca cihaz kimliği alınır, PIN hiçbir yere yazılmaz.
    final uid = QrClaimParser.parse(raw)?.uid ?? QrClaimParser.normalizeUid(raw);
    setState(() {
      if (uid == null) {
        _uidError = 'Karekod tanınamadı. Etiketi yeniden okutun ya da kimliği elle yazın.';
      } else {
        _uid.text = uid;
        _uidError = null;
      }
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final state = context.read<AutomationState>();
    final uid = QrClaimParser.normalizeUid(_uid.text);
    final reason = _reason.text.trim();
    final ownerText = _owner.text.trim();
    final owner = ownerText.isEmpty ? null : parseCustomerIdentifier(ownerText);

    final uidError = uid == null ? 'Cihaz kimliği AHBU- ile başlamalıdır (örn. AHBU-S3-1234ABCD).' : null;
    final reasonError = reason.length < EmergencyResetCard.minReasonLength
        ? 'Gerekçe en az ${EmergencyResetCard.minReasonLength} karakter olmalıdır (şu an ${reason.length}).'
        : null;
    final ownerError = (ownerText.isNotEmpty && owner == null)
        ? 'Geçerli bir e-posta adresi ya da telefon numarası girin (boş bırakırsanız cihaz stoğa alınır).'
        : null;
    if (uidError != null || reasonError != null || ownerError != null) {
      setState(() {
        _uidError = uidError;
        _reasonError = reasonError;
        _ownerError = ownerError;
        _error = null;
        _forbiddenHint = false;
      });
      return;
    }
    if (!state.capabilities.canEmergencyReset) {
      setState(() {
        _error = 'Acil sıfırlama için yetkiniz yok.';
        _forbiddenHint = false;
      });
      return;
    }
    if (owner != null && isOwnIdentifier(owner, state.currentUser)) {
      setState(() {
        _ownerError = 'Kendi hesabınızı yeni sahip olarak seçemezsiniz.';
        _uidError = null;
        _reasonError = null;
        _error = null;
        _forbiddenHint = false;
      });
      return;
    }
    setState(() {
      _uidError = null;
      _reasonError = null;
      _ownerError = null;
      _error = null;
      _forbiddenHint = false;
    });

    final confirmed = await ConfirmDestructiveDialog.show(
      context,
      title: 'Acil sıfırlama onayı',
      message: owner == null
          ? '$uid cihazı sıfırlanacak: eski ailenin tüm yetkileri ve oturumları sonlanır, cihaz stoğa alınır.'
          : '$uid cihazı sıfırlanacak: eski ailenin tüm yetkileri ve oturumları sonlanır, cihaz '
              '${owner.masked} hesabına devredilir.',
      confirmPhrase: uid!,
      confirmLabel: 'Acil Sıfırla',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await state
          .emergencyResetDevice(
            deviceUuid: uid,
            confirmUid: uid,
            reason: reason,
            newOwnerIdentifier: owner?.value,
          )
          .timeout(_timeout);
      if (!mounted) return;
      _uid.clear();
      _reason.clear();
      _owner.clear();
      setState(() => _busy = false);
      final openWizard = await EmergencyResetResultDialog.show(context, result);
      if (openWizard == true && mounted) {
        final homeId = result.homeId;
        if (homeId != null) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ServiceSetupWizardPage(
                existingTarget: ServiceTarget(homeId: homeId, deviceUuid: result.deviceUuid.isEmpty ? uid : result.deviceUuid),
                startStep: SetupSteps.wifi,
                // Yanıttaki tek seferlik bulut kimliği sihirbaza (yalnızca bellek) aktarılır: 6. adım yeniden üretmez.
                initialCredential: result.deviceCredential,
                scanner: widget.scanner,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (UncertainOutcomeCard.isUncertain(e)) {
        // Sunucu işlemi tamamlamış olabilir: "tekrar dene" denmez, durum kontrolü istenir.
        setState(() {
          _busy = false;
          _error = null;
          _uncertainUid = uid;
          _checkResult = null;
        });
        return;
      }
      setState(() {
        _busy = false;
        _error = friendlyError(e, fallback: 'Acil sıfırlama tamamlanamadı. Cihazın durumunu kontrol edip tekrar deneyin.');
        // 403: servis personelinin kapsamı dışındaki daire (ya da iptal/askı): süper yönetici yönlendirmesi hatanın yanında.
        _forbiddenHint = e is ApiException && e.isForbidden && !state.capabilities.isSuperUser;
      });
    }
  }

  /// Sonucu belirsiz kalan sıfırlamada cihazın envanterdeki **gerçek** durumuna bakar.
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
      final res = await state.cloudApi.fetchDeviceInventory(search: uid, limit: 5).timeout(_checkTimeout);
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

  /// Cihaz kimliği değişince önceki cihazın belirsiz-sonuç uyarısı kalkar.
  void _onUidChanged(String text) {
    final pending = _uncertainUid;
    if (pending != null && QrClaimParser.normalizeUid(text) != pending) {
      setState(() {
        _uncertainUid = null;
        _checkResult = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = SetupColors.muted(context);
    // Kalıcı servis personeli (süper değil): sıfırlama kapsamı sunucuda 72 saatlik servis üyeliğiyle sınırlıdır.
    final limited =
        context.select<AutomationState, bool>((s) => s.capabilities.canEmergencyReset && !s.capabilities.isSuperUser);
    // 403 sonrası yönlendirme hata kutusunda gösterilir: aynı not ekranda iki kez yazılmaz.
    final hintInError = _error != null && _forbiddenHint;
    return ServiceCard(
      key: const Key('card_emergency_reset'),
      accent: SetupColors.error,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OrbIconBadge(icon: Icons.warning_amber_rounded, family: AppFeature.emergencyReset.accentFamily, pending: _busy),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Acil Servis Sıfırlaması',
                  style: TextStyle(
                    fontSize: AppText.cardTitle,
                    fontWeight: FontWeight.w800,
                    color: SetupColors.readable(context, SetupColors.error),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Eski kiracıya/ev sahibine ulaşılamıyorsa; tapu veya sözleşme ibrazıyla cihazı boşa çıkarın ya da '
            'doğrudan yeni malike devredin. Eski ailenin tüm yetkileri sonlanır. Bu işlem denetim kaydına yazılır.',
            style: TextStyle(fontSize: AppText.caption, height: 1.35, color: muted),
          ),
          if (limited && !hintInError)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: SetupInfoRow(
                key: Key('reset_staff_scope_note'),
                icon: Icons.info_outline_rounded,
                color: SetupColors.info,
                text: EmergencyResetCard.staffScopeNote,
              ),
            ),
          SetupTextField(
            key: const Key('field_reset_uid'),
            controller: _uid,
            label: 'Cihaz kimliği',
            hint: 'AHBU-...',
            helperText: 'Pano etiketindeki kimlik',
            errorText: _uidError,
            textCapitalization: TextCapitalization.characters,
            // Ön ek simgesi sondaki tarama simgesinden FARKLI (eskiden iki neredeyse aynı QR simgesi yan yanaydı).
            prefixIcon: Icons.memory_rounded,
            monospace: true,
            enabled: !_busy,
            onChanged: _onUidChanged,
            suffixIcon: IconButton(
              key: const Key('btn_reset_scan'),
              tooltip: 'Etiketi kamerayla oku',
              icon: const Icon(Icons.qr_code_scanner_rounded),
              onPressed: _busy ? null : _scan,
            ),
          ),
          SetupTextField(
            key: const Key('field_reset_reason'),
            controller: _reason,
            // Zorunluluk bilgisi etikette (kesilirdi) değil yardımcı metinde: "12 / 15 karakter (en az)".
            label: 'Sıfırlama gerekçesi',
            hint: 'Örn: Kiracı tahliye edildi, tapu teyit edildi.',
            errorText: _reasonError,
            prefixIcon: Icons.description_rounded,
            maxLines: 2,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            helperText: '${_reason.text.trim().length} / ${EmergencyResetCard.minReasonLength} karakter (en az)',
          ),
          SetupTextField(
            key: const Key('field_reset_owner'),
            controller: _owner,
            // Kısa etiket: eski "Yeni sahip e-posta veya telefon" 1.5 ölçekte yüzen etiket olarak "Yeni sahip e-posta veya t…"
            // diye kesiliyor, alanın telefon da kabul ettiği bilgisi kayboluyordu. Niteleyici ipucuna, açıklama yardımcı metne.
            label: 'Yeni sahip',
            hint: 'E-posta veya telefon',
            helperText: 'İsteğe bağlı: boş bırakırsanız cihaz stoğa alınır',
            errorText: _ownerError,
            keyboardType: TextInputType.emailAddress,
            prefixIcon: Icons.person_rounded,
            enabled: !_busy,
          ),
          if (_error != null)
            ServiceCard(
              key: const Key('reset_error'),
              accent: SetupColors.error,
              margin: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _error!),
                  if (hintInError)
                    const SetupInfoRow(
                      key: Key('reset_forbidden_hint'),
                      icon: Icons.info_outline_rounded,
                      color: SetupColors.info,
                      text: EmergencyResetCard.staffScopeNote,
                    ),
                ],
              ),
            ),
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
          const SizedBox(height: 14),
          // Yıkıcı eylem ÇERÇEVELİ rose hap: servis panelinde sayfanın TEK gradyan birincil eylemi "Yeni Kurulum Başlat"tır (eskiden
          // sayfa sonundaki gradyanlı kırmızı düğme ikinci kahraman gibi okunuyordu). Eylem zaten cihaz kimliği YAZILARAK
          // onaylanır ([ConfirmDestructiveDialog]: orada yıkıcı dolu düğme vardır), yani hafif görünmesi güvenliği azaltmaz.
          SetupSecondaryButton(
            key: const Key('btn_emergency_reset'),
            label: 'Acil Sıfırla',
            icon: Icons.restore_rounded,
            family: AppFamilies.rose,
            busy: _busy,
            // Sonucu belirsiz kalan işlem durum kontrol edilmeden yinelenemez (cihaz kimliği değişirse kilit kalkar).
            onPressed: _uncertainUid != null ? null : _submit,
          ),
          // Düğmenin neden kilitli olduğu düğmenin ALTINDA yazar (eskiden yalnız yukarıdaki kartta anlatılırdı).
          if (_uncertainUid != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Sonuç doğrulanana kadar sıfırlama kilitli: önce cihazın durumunu kontrol edin.',
                key: const Key('reset_locked_hint'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: AppText.caption, height: 1.3, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Acil sıfırlama sonucu: uyarılar/kısmi başarı + **tek seferlik** gizli değerler.
///
/// Diyalog kapanınca pano hemen temizlenir. `true` dönerse kullanıcı panoyu yeni sahibe bağlamak için
/// kurulum sihirbazını açmak istemiştir.
///
/// Yerel anahtar: sunucu panoya iletemediyse `pending` döner ([EmergencyResetResult.localKeyPending]) ve pano buluta
/// bağlanınca kendisi iletir; bu bir bilgi notudur ([keyPendingNote]). Eski sunucu yanıtındaki anahtar
/// ([EmergencyResetResult.needsManualLocalKey]) ağ üzerinden yazılamaz: yönerge [manualKeyHint].
class EmergencyResetResultDialog extends StatefulWidget {
  const EmergencyResetResultDialog({super.key, required this.result});

  final EmergencyResetResult result;

  /// `local_key_publish: pending`: yeni anahtar sunucu tarafından otomatik iletilecek.
  static const String keyPendingNote = 'Yeni yerel anahtar, pano buluta bağlandığında sunucu tarafından otomatik '
      'iletilecek; o zamana kadar panonun mevcut anahtarı geçerlidir.';

  /// Süper yöneticinin devri (M4-02): sunucu süper yöneticiye yerel anahtar vermez (6. adım anahtarsız kalır) ve
  /// süperin sıfırlaması servis personeline daire üyeliği vermez. Tek yol yeni sahibin servis PIN'i.
  static const String superHandoffNote = 'Süper yönetici hesabına cihaz anahtarı verilmez ve bu devir servis '
      "personeline daire yetkisi vermez. Panoyu bağlamak için yeni sahibin uygulamasından servis PIN'i alınıp servis "
      'girişiyle sihirbaz açılmalı.';

  /// Eski sunucu yanıtındaki (panoya iletilemeyen) anahtarın gerçek kurtarma yolu.
  static const String manualKeyHint = 'Bu anahtar panoya ağ üzerinden yazılamaz: panoyu USB ile bağlayıp seri konsolda '
      'önce RESETKEY, ardından FACTORYINIT ile yazın (fabrika aracı). Yazılana kadar yerel ağdan komut verilemez.';

  static Future<bool?> show(BuildContext context, EmergencyResetResult result) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EmergencyResetResultDialog(result: result),
    );
  }

  @override
  State<EmergencyResetResultDialog> createState() => _EmergencyResetResultDialogState();
}

class _EmergencyResetResultDialogState extends State<EmergencyResetResultDialog> {
  String? _copied;
  int _copyCount = 0;

  @override
  void dispose() {
    SecretClipboard.wipeNow();
    super.dispose();
  }

  Future<void> _copy(String label, String value) async {
    final clock = context.read<AutomationState>().clock;
    await SecretClipboard.copy(value, clock: clock);
    if (mounted) {
      setState(() {
        _copied = label;
        _copyCount++;
      });
    }
  }

  String _headline(EmergencyResetResult r) {
    if (r.isReassigned) {
      final name = r.newOwner?.fullName ?? '';
      return name.isEmpty ? 'Cihaz yeni sahibe devredildi.' : 'Cihaz $name adlı yeni sahibe devredildi.';
    }
    if (r.isUnclaimed) return 'Cihaz stoğa alındı; eski daire bağlantısı kaldırıldı.';
    return r.message.isEmpty ? 'Sıfırlama sunucuda tamamlandı.' : r.message;
  }

  String? _publishNote(String label, String? value) {
    switch (value) {
      case 'failed':
        return '$label panoya iletilemedi (hata).';
      case 'skipped_offline':
        return '$label panoya iletilemedi: pano çevrimdışıydı.';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final pin = r.setupPin;
    final shownPin = (pin != null && pin.length == 6) ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin;
    final notes = <String>[
      ?_publishNote('Yerel anahtar', r.localKeyPublish),
      ?_publishNote('Çocuk kilidi sıfırlaması', r.childLockReset),
    ];
    // Süper yöneticiye sunucu yerel anahtar vermez: sihirbaz 6. adımda anahtarsız kalır (M4-02). Ona sihirbaz önerilmez.
    final isSuper = context.select<AutomationState, bool>((s) => s.capabilities.isSuperUser);
    final superHandoff = isSuper && r.isReassigned;
    final canOpenWizard = r.isReassigned && r.homeId != null && !isSuper;
    final warnings = r.displayWarnings;
    return AlertDialog(
      title: Row(
        children: [
          OrbIconBadge(
            icon: r.hasWarnings ? Icons.warning_amber_rounded : Icons.check_rounded,
            family: r.hasWarnings ? AppFamilies.amber : AppFamilies.emerald,
            status: r.hasWarnings ? OrbStatus.none : OrbStatus.success,
            glow: true,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              r.hasWarnings ? 'Sıfırlama kısmen tamamlandı' : 'Sıfırlama tamamlandı',
              key: const Key('reset_result_title'),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_headline(r), style: TextStyle(fontSize: AppText.body, height: 1.4, color: SetupColors.text(context))),
              if (r.affectedUsersCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Eski daireden ${r.affectedUsersCount} kullanıcının erişimi kaldırıldı.',
                    style: TextStyle(fontSize: AppText.caption, color: SetupColors.muted(context)),
                  ),
                ),
              if (r.isPartial)
                const ServiceCard(
                  key: Key('reset_partial'),
                  accent: SetupColors.warn,
                  child: SetupInfoRow(
                    icon: Icons.warning_amber_rounded,
                    color: SetupColors.warn,
                    bold: true,
                    text: 'Bazı adımlar tamamlanamadı. Aşağıdaki uyarıları okuyun ve gerekeni yapın.',
                  ),
                ),
              for (var i = 0; i < warnings.length; i++)
                SetupInfoRow(
                  key: Key('reset_warning_$i'),
                  icon: Icons.info_outline_rounded,
                  color: SetupColors.warn,
                  text: warnings[i],
                ),
              for (final note in notes) SetupInfoRow(icon: Icons.info_outline_rounded, color: SetupColors.warn, text: note),
              if (r.localKeyPending)
                ServiceCard(
                  key: const Key('reset_key_pending'),
                  accent: SetupColors.info,
                  child: SetupInfoRow(
                    icon: Icons.sync_rounded,
                    color: SetupColors.info,
                    text: canOpenWizard
                        ? '${EmergencyResetResultDialog.keyPendingNote} "Panoyu şimdi bağla" ile kuruluma devam '
                            'edebilirsiniz.'
                        : EmergencyResetResultDialog.keyPendingNote,
                  ),
                ),
              if (shownPin != null || r.needsManualLocalKey)
                const ServiceCard(
                  key: Key('reset_secret_warning'),
                  accent: SetupColors.warn,
                  child: SetupInfoRow(
                    icon: Icons.lock_clock_rounded,
                    color: SetupColors.warn,
                    bold: true,
                    text: 'Aşağıdaki bilgiler yalnızca BU KEZ gösterilir. Kopyaladığınız değer panodan 45 saniye '
                        'sonra silinir.',
                  ),
                ),
              if (shownPin != null)
                SecretValueRow(
                  label: 'Yeni kurulum PIN',
                  shown: shownPin,
                  copyKey: const Key('btn_copy_reset_pin'),
                  showWipeRing: false, // kartın kendi 45 sn halkası var (çift halka olmasın)
                  onCopy: () => _copy('Kurulum PIN', pin!),
                ),
              if (r.needsManualLocalKey) ...[
                SecretValueRow(
                  label: 'Yerel anahtar (panoya iletilemedi)',
                  shown: r.localKey!,
                  copyKey: const Key('btn_copy_reset_key'),
                  showWipeRing: false, // kartın kendi 45 sn halkası var (çift halka olmasın)
                  onCopy: () => _copy('Yerel anahtar', r.localKey!),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    EmergencyResetResultDialog.manualKeyHint,
                    key: const Key('reset_key_manual_hint'),
                    style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
                  ),
                ),
              ],
              if (superHandoff)
                const ServiceCard(
                  key: Key('reset_super_note'),
                  accent: SetupColors.info,
                  child: SetupInfoRow(
                    icon: Icons.info_outline_rounded,
                    color: SetupColors.info,
                    text: EmergencyResetResultDialog.superHandoffNote,
                  ),
                ),
              if (canOpenWizard)
                const ServiceCard(
                  key: Key('reset_next_step'),
                  accent: SetupColors.info,
                  child: SetupInfoRow(
                    icon: Icons.arrow_forward_rounded,
                    color: SetupColors.info,
                    text: 'Pano yeni sahibin hesabına bağlanabilmesi için Wi-Fi ve bulut kimliğinin yeniden '
                        'yazılması gerekir. Kurulum sihirbazı bu adımları sizin için yürütür.',
                  ),
                ),
              if (_copied != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      SecretExpiryRing(key: ValueKey<int>(_copyCount)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$_copied panoya kopyalandı (45 sn sonra silinir).',
                          key: const Key('reset_copied'),
                          style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (canOpenWizard)
          TextButton(
            key: const Key('btn_reset_open_wizard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Panoyu şimdi bağla'),
          ),
        ElevatedButton(
          key: const Key('btn_reset_close'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Kaydettim, Kapat'),
        ),
      ],
    );
  }
}
