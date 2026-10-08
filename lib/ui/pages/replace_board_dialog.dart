import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/api_models.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../../utils/qr_claim_parser.dart';
import '../common/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/glass_icon_button.dart';
import '../widgets/orb/orb_core.dart';
import '../widgets/orb/orb_icon_badge.dart';
import '../widgets/settings/accent_button.dart';
import 'claim/claim_manual_dialog.dart' show claimCloudBootstrapNote;
import 'service_setup/panel/service_glass.dart';
import 'service_setup/panel/uncertain_outcome_card.dart';
import 'service_setup/service_setup_wizard_page.dart';
import 'service_setup/service_target.dart';
import 'service_setup/setup_fields.dart';
import 'service_setup/setup_steps.dart';
import 'service_setup/setup_style.dart';
import 'service_setup/setup_widgets.dart';
import 'service_setup/steps/step_common.dart';
import '../theme/feature_accent.dart';
import 'wifi_recovery_dialog.dart';

/// Pano değişimi (arızalı panonun ayarlarını yeni panoya aktarma).
///
/// **Yanlış daire riski yoktur:** hedef daire en üstte adıyla gösterilir, onay penceresinde yeniden
/// yazılır ve pencere açıkken aktif daire değişirse işlem engellenir. Değiştirilecek **eski pano**
/// açıkça seçilir (`old_device_uuid` her zaman gönderilir); yeni panonun özeti onay penceresinde
/// gösterilir. Sonuçtaki uyarılar, kısmi başarı ve bekleyen pano-çevrimiçi eşitlemeleri
/// ([ReplaceBoardResult.runtimeSync], çocuk kilidi) kullanıcıya bildirilir.
class ReplaceBoardDialog extends StatefulWidget {
  const ReplaceBoardDialog({super.key, this.scanner = defaultSetupScanner});

  final SetupScanner scanner;

  static Future<void> show(BuildContext context, {SetupScanner scanner = defaultSetupScanner}) {
    final state = context.read<AutomationState>();
    return showAppDialog<void>(
      context,
      // Bariyere dokunmak diyaloğu kapatmaz (PF-46): değişim geri alınamaz bir işlemdir ve sonucu (uyarılar, tek
      // seferlik bulut kimliği) yalnızca bu pencerede gösterilir. Kapatma X düğmesiyle/Kapat ile yapılır; işlem
      // sürerken ikisi de ([PopScope] ile sistem geri tuşu da) engellenir.
      barrierDismissible: false,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: ReplaceBoardDialog(scanner: scanner),
      ),
    );
  }

  @override
  State<ReplaceBoardDialog> createState() => _ReplaceBoardDialogState();
}

class _ReplaceBoardDialogState extends State<ReplaceBoardDialog> {
  static const Duration _requestTimeout = Duration(seconds: 30);

  final TextEditingController _newUid = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _reason = TextEditingController();

  /// Pencere açıldığındaki hedef daire (aktif daire değişirse işlem engellenir).
  String? _homeId;
  String _homeName = '';

  List<DeviceInfo> _devices = const <DeviceInfo>[];
  bool _loadingDevices = false;
  String? _devicesError;
  String? _oldUid;

  bool _submitting = false;
  String? _uidError;
  String? _pinError;
  String? _oldError;
  String? _error;
  ReplaceBoardResult? _result;

  /// Yanıt gelmedi (zaman aşımı / ağ kesintisi) ama sunucu değişimi tamamlamış olabilir: işlem körlemesine
  /// yinelenmez, önce dairenin pano listesinden durum kontrol edilir.
  String? _uncertainNewUid;
  String? _uncertainOldUid;
  bool _checking = false;
  String? _checkResult;

  /// Sonuç sunucu yanıtından değil, belirsiz kesintiden sonraki durum kontrolünden geldi (ayrıntı bilinmiyor).
  bool _resultFromCheck = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    final home = state.activeHome;
    _homeId = home?.id;
    _homeName = home?.name ?? '';
    _devices = state.devices;
    if (_devices.length == 1) _oldUid = _devices.first.deviceUuid;
    if (home != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadDevices());
      });
    }
  }

  @override
  void dispose() {
    _newUid.dispose();
    _pin.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final homeId = _homeId;
    if (homeId == null) return;
    final state = context.read<AutomationState>();
    setState(() {
      _loadingDevices = true;
      _devicesError = null;
    });
    try {
      final list = await state.cloudApi.devices(homeId).timeout(_requestTimeout);
      if (!mounted) return;
      setState(() {
        _devices = list;
        _loadingDevices = false;
        if (_oldUid != null && !list.any((d) => d.deviceUuid == _oldUid)) _oldUid = null;
        if (list.length == 1) _oldUid = list.first.deviceUuid;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDevices = false;
        _devicesError = friendlyError(e, fallback: 'Dairedeki panolar yüklenemedi.');
      });
    }
  }

  Future<void> _scan() async {
    final raw = await widget.scanner(
      context,
      title: 'Yeni pano etiketi',
      hint: 'Yeni panonun üzerindeki etiketin karekodunu okutun.',
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    final data = QrClaimParser.parse(raw);
    final uid = data?.uid ?? QrClaimParser.normalizeUid(raw);
    setState(() {
      if (uid == null) {
        _uidError = 'Karekod tanınamadı. Etiketi yeniden okutun ya da kimliği elle yazın.';
        return;
      }
      _newUid.text = uid;
      _uidError = null;
      // Etiketteki PIN gizli alana yazılır; ekranda gösterilmez, hiçbir yere kaydedilmez.
      if (data != null) {
        _pin.text = data.pin;
        _pinError = null;
      }
    });
  }

  DeviceInfo? get _oldDevice {
    final uid = _oldUid;
    if (uid == null) return null;
    for (final d in _devices) {
      if (d.deviceUuid == uid) return d;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final state = context.read<AutomationState>();
    final homeId = _homeId;
    if (homeId == null || state.activeHome?.id != homeId) {
      setState(() => _error = 'Aktif daire değişti. Pencereyi kapatıp yeniden açın.');
      return;
    }
    if (!state.capabilities.canReplaceBoard) {
      setState(() => _error = 'Pano değişimi için yetkiniz yok.');
      return;
    }
    final newUid = QrClaimParser.normalizeUid(_newUid.text);
    final pin = _pin.text.trim();
    final old = _oldDevice;
    String? uidError;
    if (newUid == null) {
      uidError = 'Yeni pano kimliği AHBU- ile başlamalıdır (örn. AHBU-S3-1234ABCD).';
    } else if (old != null && old.deviceUuid.toUpperCase() == newUid) {
      uidError = 'Yeni pano, değiştirilecek eski panoyla aynı olamaz.';
    }
    final pinError = QrClaimParser.isValidPin(pin) ? null : 'Kurulum PIN\'i tam 6 rakam olmalıdır.';
    final oldError = old == null ? 'Değiştirilecek eski panoyu seçin.' : null;
    if (uidError != null || pinError != null || oldError != null || old == null || newUid == null) {
      setState(() {
        _uidError = uidError;
        _pinError = pinError;
        _oldError = oldError;
        _error = null;
      });
      return;
    }
    setState(() {
      _uidError = null;
      _pinError = null;
      _oldError = null;
      _error = null;
    });

    final reason = _reason.text.trim();
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => _ConfirmReplaceDialog(
        homeName: _homeName,
        oldBoard: old,
        newUid: newUid,
        reason: reason,
      ),
    );
    if (confirmed != true || !mounted) return;
    // Onay penceresi açıkken daire değişmiş olabilir.
    if (state.activeHome?.id != homeId) {
      setState(() => _error = 'Aktif daire değişti; işlem yapılmadı. Pencereyi kapatıp yeniden açın.');
      return;
    }

    setState(() => _submitting = true);
    try {
      final result = await state
          .replaceBoard(
            oldDeviceUuid: old.deviceUuid,
            newDeviceUuid: newUid,
            setupPin: pin,
            reason: reason.isEmpty ? null : reason,
          )
          .timeout(_requestTimeout);
      if (!mounted) return;
      _pin.clear();
      setState(() {
        _submitting = false;
        _result = result;
      });
    } catch (e) {
      if (!mounted) return;
      // PIN yanlış girildiyse yeniden denemede doğru değer yazılmalı: alan temizlenir.
      _pin.clear();
      if (UncertainOutcomeCard.isUncertain(e)) {
        // Yanıt gelmedi ama sunucu değişimi tamamlamış olabilir: "tekrar dene" denmez, durum kontrol edilir.
        setState(() {
          _submitting = false;
          _error = null;
          _uncertainNewUid = newUid;
          _uncertainOldUid = old.deviceUuid;
          _checkResult = null;
        });
        return;
      }
      setState(() {
        _submitting = false;
        _error = friendlyError(e, fallback: 'Pano değişimi tamamlanamadı. Bağlantınızı kontrol edip tekrar deneyin.');
      });
    }
  }

  /// Sonucu belirsiz kalan değişimde dairedeki panoları sunucudan yeniden okuyup yeni panonun listede olup
  /// olmadığına bakar.
  Future<void> _checkOutcome() async {
    final homeId = _homeId;
    final newUid = _uncertainNewUid;
    if (homeId == null || newUid == null || _checking) return;
    final state = context.read<AutomationState>();
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    try {
      final list = await state.cloudApi.devices(homeId).timeout(_requestTimeout);
      if (!mounted) return;
      final present = list.any((d) => d.deviceUuid.toUpperCase() == newUid.toUpperCase());
      setState(() {
        _checking = false;
        _devices = list;
        if (present) {
          // Değişim sunucuda tamamlanmış: kalan iş yeni panoyu bağlamaktır (tek seferlik bulut kimliği
          // gelmediği için sihirbaz 6. adımda yenisini üretir).
          _result = ReplaceBoardResult(
            newDeviceUuid: newUid,
            oldDeviceUuid: _uncertainOldUid,
            homeId: homeId,
            migratedEndpointsCount: 0,
            warnings: const <String>[
              'Sunucudan yanıt alınamadığı için aktarılan kanal sayısı ve uyarılar bilinmiyor; dairedeki '
                  'kanalları ve panjur sürelerini kontrol edin.',
            ],
          );
          _resultFromCheck = true;
          _uncertainNewUid = null;
        } else {
          _checkResult = 'Yeni pano ($newUid) dairenin pano listesinde görünmüyor: değişim yapılmamış görünüyor. '
              'PIN\'i yeniden girip tekrar deneyebilirsiniz.';
          _uncertainNewUid = null;
          _uncertainOldUid = null;
          _oldUid = list.length == 1 ? list.first.deviceUuid : _oldUid;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkResult = 'Durum kontrol edilemedi: ${friendlyError(e, fallback: 'Bağlantınızı kontrol edip yeniden deneyin.')}';
      });
    }
  }

  /// Sihirbaz bir kez açıldı (PF-47): aynı karede gelen ikinci etkinleştirme (erişilebilirlik eylemi, klavye Enter
  /// tekrarı) `pop()` ile az önce açılan sihirbazı kapatıp ikincisini açardı (çift denetleyici, çift kurulum durumu).
  bool _wizardOpened = false;

  /// Kurulum sihirbazı yalnız personel / servis PIN oturumu için açılır (bireysel-4): ev sahibi sihirbaza giremez, süper
  /// yöneticiye sihirbazda cihaz anahtarı verilmez.
  bool get _canOpenWizard {
    final access = ServiceSetupAccess.fromState(context.read<AutomationState>());
    return access != null && !access.isSuperUser;
  }

  void _openWizard(ReplaceBoardResult result) {
    final homeId = result.homeId ?? _homeId;
    // Sihirbaz açılamıyorsa diyalog kapanmaz (sonuç ekranı kaybolmasın).
    if (homeId == null || _wizardOpened || !_canOpenWizard) return;
    _wizardOpened = true;
    final navigator = Navigator.of(context);
    final scanner = widget.scanner;
    navigator.pop();
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          existingTarget: ServiceTarget(homeId: homeId, deviceUuid: result.newDeviceUuid, homeName: _homeName),
          startStep: SetupSteps.wifi,
          // Yanıttaki tek seferlik bulut kimliği sihirbaza (yalnızca bellek) aktarılır: 6. adım yeniden üretmez.
          initialCredential: result.deviceCredential,
          scanner: scanner,
        ),
      ),
    );
  }

  /// Ev sahibi (sihirbazsız) yolu: diyalog kapanır ve yeni pano için Wi-Fi Kurulum & Kurtarma sihirbazı açılır (bireysel-4).
  void _openWifi(ReplaceBoardResult result) {
    if (_wizardOpened) return;
    _wizardOpened = true;
    final navigator = Navigator.of(context);
    navigator.pop();
    unawaited(WifiRecoveryDialog.show(navigator.context, deviceUuid: result.newDeviceUuid));
  }

  @override
  Widget build(BuildContext context) {
    // Tüm durumu izlemek yerine yetki bayrağı ve aktif daire kimliği seçilir (PF-06): pencere açıkken gelen ilgisiz
    // bildirimler (canlı durum, çevrimiçi/çevrimdışı geçişleri) formu yeniden kurmaz.
    final view = context.select<AutomationState, ({bool canReplace, String? activeHomeId})>(
      (s) => (canReplace: s.capabilities.canReplaceBoard, activeHomeId: s.activeHome?.id),
    );
    final homeChanged = _homeId != null && view.activeHomeId != _homeId;
    // İşlem sürerken pencere kapatılamaz (PF-46): istek ≤ 30 sn sürer ve eski panoyu devre dışı bırakır; pencere
    // kapanırsa sonuç `if (!mounted) return;` ile hiç gösterilmeden atılırdı. Sistem geri tuşu da engellenir
    // (bariyer zaten kapatmaz: `show` -> `barrierDismissible: false`; X düğmesi işlem sürerken pasiftir).
    return PopScope(
      canPop: !_submitting,
      child: _dialog(context, canReplace: view.canReplace, homeChanged: homeChanged),
    );
  }

  Widget _dialog(BuildContext context, {required bool canReplace, required bool homeChanged}) {
    final done = _result != null;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ServiceCard(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          radius: AppRadius.dialog,
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  OrbIconBadge(
                    icon: Icons.sync_alt_rounded,
                    family: AppFeature.boardReplace.accentFamily,
                    pending: _submitting,
                    status: done && !_result!.hasWarnings ? OrbStatus.success : OrbStatus.none,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pano Değişimi',
                          style: TextStyle(fontSize: AppText.title, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                        ),
                        const SizedBox(height: 6),
                        ServiceStepDots(
                          current: done ? 3 : (_submitting || _uncertainNewUid != null ? 2 : 1),
                          total: 3,
                          family: AppFeature.boardReplace.accentFamily,
                          label: done ? 'Adım 3 / 3: sonuç' : 'Adım ${_submitting ? 2 : 1} / 3',
                        ),
                      ],
                    ),
                  ),
                  // Kapat: cam disk (Sistem Doktoru diyaloğuyla AYNI dil; eskiden çıplak gri ✕ IconButton'du). İşlem sürerken pasif.
                  GlassIconButton(
                    key: const Key('btn_replace_x'),
                    icon: Icons.close_rounded,
                    semanticLabel: 'Kapat',
                    onTap: _submitting ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Divider(color: SetupColors.border(context), height: 24),
              if (_result != null)
                Builder(
                  builder: (context) {
                    final state = context.read<AutomationState>();
                    final access = ServiceSetupAccess.fromState(state);
                    final canWizard = access != null && !access.isSuperUser;
                    final isSuper = access?.isSuperUser ?? false;
                    return _ResultView(
                      result: _result!,
                      fromStatusCheck: _resultFromCheck,
                      homeName: _homeName,
                      onOpenWizard: canWizard ? () => _openWizard(_result!) : null,
                      superNote: isSuper,
                      onOpenWifi: !canWizard && !isSuper && state.capabilities.canOpenWifiRecovery
                          ? () => _openWifi(_result!)
                          : null,
                      onClose: () => Navigator.of(context).pop(),
                    );
                  },
                )
              else if (_homeId == null)
                const ServiceCard(
                  key: Key('replace_no_home'),
                  accent: SetupColors.warn,
                  margin: EdgeInsets.zero,
                  child: SetupInfoRow(
                    icon: Icons.home_outlined,
                    color: SetupColors.warn,
                    bold: true,
                    text: 'Önce bir daire seçin. Pano değişimi, ekranda seçili olan dairede yapılır.',
                  ),
                )
              else if (!canReplace)
                const ServiceCard(
                  key: Key('replace_forbidden'),
                  accent: SetupColors.warn,
                  margin: EdgeInsets.zero,
                  child: SetupInfoRow(
                    icon: Icons.lock_outline_rounded,
                    color: SetupColors.warn,
                    bold: true,
                    text: 'Pano değişimi için yetkiniz yok.',
                  ),
                )
              else
                _form(context, homeChanged),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context, bool homeChanged) {
    final muted = SetupColors.muted(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServiceCard(
          key: const Key('replace_target_home'),
          accent: SetupColors.info,
          margin: EdgeInsets.zero,
          child: Row(
            children: [
              const OrbIconBadge(icon: Icons.home_rounded, family: AppFamilies.cyan),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Değişim yapılacak daire', style: TextStyle(fontSize: AppText.badge, color: muted)),
                    Text(
                      _homeName.isEmpty ? 'İsimsiz daire' : _homeName,
                      style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (homeChanged)
          const ServiceCard(
            key: Key('replace_home_changed'),
            accent: SetupColors.error,
            child: SetupInfoRow(
              icon: Icons.error_outline_rounded,
              color: SetupColors.error,
              bold: true,
              text: 'Aktif daire değişti. Yanlış daireye işlem yapılmaması için pencereyi kapatıp yeniden açın.',
            ),
          ),
        const SetupSectionTitle('1. Değiştirilecek (eski) pano'),
        if (_loadingDevices && _devices.isEmpty)
          Semantics(
            label: 'Panolar yükleniyor',
            liveRegion: true,
            child: const ServiceListSkeleton(key: Key('replace_devices_loading'), count: 2, lines: 1),
          ),
        if (_devicesError != null)
          ServiceCard(
            key: const Key('replace_devices_error'),
            accent: SetupColors.error,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_devicesError!, style: TextStyle(color: SetupColors.text(context))),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('btn_devices_retry'),
                    onPressed: _loadingDevices ? null : _loadDevices,
                    child: const Text('Tekrar dene'),
                  ),
                ),
              ],
            ),
          ),
        if (!_loadingDevices && _devicesError == null && _devices.isEmpty)
          ServiceCard(
            key: const Key('replace_no_devices'),
            child: Text(
              'Bu dairede kayıtlı pano yok; değiştirilecek bir pano bulunamadı.',
              style: TextStyle(color: muted),
            ),
          ),
        for (final d in _devices)
          _OldBoardTile(
            device: d,
            selected: d.deviceUuid == _oldUid,
            onTap: _submitting ? null : () => setState(() {
                  _oldUid = d.deviceUuid;
                  _oldError = null;
                }),
          ),
        if (_oldError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _oldError!,
              key: const Key('replace_old_error'),
              style: TextStyle(color: SetupColors.readable(context, SetupColors.error), fontSize: AppText.caption, fontWeight: FontWeight.w600),
            ),
          ),
        const SetupSectionTitle('2. Yeni pano'),
        SetupTextField(
          key: const Key('field_new_uid'),
          controller: _newUid,
          label: 'Yeni pano kimliği',
          hint: 'AHBU-...',
          helperText: 'Yeni pano etiketindeki kimlik',
          errorText: _uidError,
          textCapitalization: TextCapitalization.characters,
          // Ön ek simgesi sondaki tarama simgesinden FARKLI (eskiden iki neredeyse aynı QR simgesi yan yanaydı).
          prefixIcon: Icons.memory_rounded,
          monospace: true,
          enabled: !_submitting,
          suffixIcon: IconButton(
            key: const Key('btn_scan_new_board'),
            tooltip: 'Etiketi kamerayla oku',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: _submitting ? null : _scan,
          ),
        ),
        SecretField(
          key: const Key('field_new_pin'),
          controller: _pin,
          label: 'Kurulum PIN\'i',
          hint: '6 rakam',
          helperText: 'Yeni pano etiketindeki 6 haneli PIN',
          maxLength: 6,
          keyboardType: TextInputType.number,
          inputFormatters: [digitsOnly, LengthLimitingTextInputFormatter(6)],
          errorText: _pinError,
          monospace: true,
        ),
        SetupTextField(
          key: const Key('field_replace_reason'),
          controller: _reason,
          label: 'Değişim nedeni',
          hint: 'Örn: yıldırım düştü, pano arızalandı',
          helperText: 'İsteğe bağlı',
          prefixIcon: Icons.note_alt_rounded,
          enabled: !_submitting,
        ),
        if (_error != null)
          ServiceCard(
            key: const Key('replace_error'),
            accent: SetupColors.error,
            child: SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _error!),
          ),
        if (_uncertainNewUid != null)
          UncertainOutcomeCard(
            key: const Key('replace_uncertain'),
            title: 'Değişimin sonucu belirsiz',
            message: 'Sunucudan yanıt alınamadı (zaman aşımı ya da bağlantı kesintisi). Değişim sunucuda '
                'TAMAMLANMIŞ olabilir; aynı işlemi körlemesine yinelemeyin. "Durumu Kontrol Et" dairenin pano '
                'listesinden yeni panonun durumuna bakar.',
            checkButtonKey: const Key('btn_replace_check'),
            onCheck: _checkOutcome,
            checking: _checking,
            checkResult: _checkResult,
          )
        else if (_checkResult != null)
          // Durum netleşti (değişim yapılmamış görünüyor): belirsizlik uyarısı kalkar, yalnızca sonuç yazılır.
          ServiceCard(
            key: const Key('replace_check_result'),
            accent: SetupColors.info,
            child: SetupInfoRow(icon: Icons.info_outline_rounded, color: SetupColors.info, bold: true, text: _checkResult!),
          ),
        const SizedBox(height: 16),
        SetupPrimaryButton(
          key: const Key('btn_replace_submit'),
          label: 'Eski Panonun Ayarlarını Yeni Panoya Aktar',
          icon: Icons.cloud_download_rounded,
          color: SetupColors.purple,
          busy: _submitting,
          // Sonucu belirsiz kalan değişim durum kontrol edilmeden yinelenemez.
          onPressed: (homeChanged || _uncertainNewUid != null || (_devices.isEmpty && !_loadingDevices)) ? null : _submit,
        ),
      ],
    );
  }
}

class _OldBoardTile extends StatelessWidget {
  const _OldBoardTile({required this.device, required this.selected, required this.onTap});

  final DeviceInfo device;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = device.online ? SetupColors.ok : SetupColors.warn;
    final title = device.name.isEmpty ? device.deviceUuid : device.name;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: ServiceCard(
        key: Key('card_oldboard_${device.deviceUuid}'),
        accent: selected ? SetupColors.purple : null,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.s12, vertical: AppSpace.s12),
              child: Row(
                children: [
                  OrbIconBadge(
                    icon: selected ? Icons.check_rounded : Icons.developer_board_rounded,
                    family: selected ? AppFeature.boardReplace.accentFamily : AppFamilies.slate,
                    active: selected,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                        ),
                        // Kimlik tek satır: tireden bölünüp iki satıra yayılmaz, sığmazsa küçülür.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            device.deviceUuid,
                            maxLines: 1,
                            softWrap: false,
                            style: SetupText.mono(fontSize: AppText.badge, color: SetupColors.muted(context)),
                          ),
                        ),
                        // Durum hapı adın ALTINDA: dar diyalogda (ve büyük yazıda) adı iki satıra sıkıştırmaz ("Salon / Panosu").
                        const SizedBox(height: 6),
                        Wrap(children: [ServiceStatusPill(label: device.online ? 'Çevrimiçi' : 'Çevrimdışı', color: color)]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Onay penceresi: hedef daire + eski pano + yeni pano özeti.
class _ConfirmReplaceDialog extends StatelessWidget {
  const _ConfirmReplaceDialog({
    required this.homeName,
    required this.oldBoard,
    required this.newUid,
    required this.reason,
  });

  final String homeName;
  final DeviceInfo oldBoard;
  final String newUid;
  final String reason;

  Widget _row(BuildContext context, String label, String value, {bool mono = false}) {
    final valueText = Text(
      value,
      maxLines: mono ? 1 : null,
      softWrap: !mono,
      style: mono
          ? SetupText.mono(fontSize: AppText.body, fontWeight: FontWeight.w700, color: SetupColors.text(context))
          : TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700, color: SetupColors.text(context)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: AppText.badge, color: SetupColors.muted(context))),
          // Kimlik tek satır: tireden bölünmez, sığmazsa küçülür.
          if (mono) FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: valueText) else valueText,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final oldName = oldBoard.name.isEmpty ? oldBoard.deviceUuid : '${oldBoard.name} (${oldBoard.deviceUuid})';
    return AlertDialog(
      title: const Text('Pano değişimi onayı'),
      content: SingleChildScrollView(
        child: Column(
          key: const Key('replace_summary'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(context, 'Daire', homeName.isEmpty ? 'İsimsiz daire' : homeName),
            _row(context, 'Eski pano (devre dışı bırakılacak)', '$oldName - ${oldBoard.online ? 'çevrimiçi' : 'çevrimdışı'}'),
            _row(context, 'Yeni pano', newUid, mono: true),
            if (reason.isNotEmpty) _row(context, 'Neden', reason),
            const SizedBox(height: 8),
            Text(
              'Eski panonun bu daireyle bağlantısı kaldırılır ve yetkisi iptal edilir. Kanallar, isimler ve '
              'panjur süreleri yeni panoya aktarılır. Bu işlem geri alınamaz.',
              style: TextStyle(fontSize: AppText.caption, height: 1.35, color: SetupColors.muted(context)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_replace_cancel'),
          style: AppTheme.quietTextButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Vazgeç'),
        ),
        ElevatedButton(
          key: const Key('btn_replace_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          // Anlamsal renk ortak ton yüzeyiyle (yerel `backgroundColor` kırpılmış yüzeyin altında "hayalet köşe" bırakıyordu).
          style: accentButtonStyle(AppFeature.boardReplace.accentFamily),
          child: const Text('Panoyu Değiştir'),
        ),
      ],
    );
  }
}

/// Başarılı yanıt: ne yapıldı, ne bekliyor, hangi uyarılar var.
class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.result,
    this.fromStatusCheck = false,
    required this.homeName,
    required this.onOpenWizard,
    this.superNote = false,
    this.onOpenWifi,
    required this.onClose,
  });

  final ReplaceBoardResult result;

  /// Sonuç sunucu yanıtından değil, durum kontrolünden: aktarılan kanal sayısı bilinmiyor.
  final bool fromStatusCheck;
  final String homeName;

  /// Kurulum sihirbazını açar; yalnız personel / servis PIN oturumunda (diğer rollerde `null`: düğme ve metin yok).
  final VoidCallback? onOpenWizard;

  /// Süper yönetici: sihirbaz anahtar vermez; panonun bağlanma yolu notu gösterilir.
  final bool superNote;

  /// Ev sahibi / sakin: yeni panoyu Wi-Fi'ye bağlama (Wi-Fi Kurulum & Kurtarma) yolu.
  final VoidCallback? onOpenWifi;
  final VoidCallback onClose;

  /// Ev sahibine sonraki adım (bireysel-4): Ethernet'te iş yok; Wi-Fi'de ev ağı yüklenir; hazırlanmamış / bağlanmayan pano
  /// için servis PIN'i.
  static const String ownerNextStep = 'Yeni pano Ethernet ile bağlıysa bir şey yapmanız gerekmez. Wi-Fi ile bağlanacaksa '
      'ev ağını yükleyin; hazırlanmış pano (v1.3.0+) internete çıkınca bulut kimliğini kendisi alır. Pano hazırlanmamışsa '
      "ya da 10 dk içinde çevrimiçi olmazsa Servis PIN'i oluşturup yetkili servise verin.";

  /// Süper yöneticiye sonraki adım: sihirbazda cihaz anahtarı verilmez (M4-02).
  static const String superNextStep = 'Süper yönetici hesabına cihaz anahtarı verilmediği için kurulum sihirbazı buradan '
      'açılmaz. Yeni panonun ağ ve bulut bağlantısını servis yazılımıyla (USB) yapın ya da ev sahibinden servis PIN\'i '
      'alıp servis girişiyle sihirbazı açın.';

  /// "Etiket: KİMLİK" satırı: kimlik tek satır mono, sığmazsa küçülür (tireden bölünmez).
  Widget _idRow(BuildContext context, String label, String uid) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text('$label: ', style: TextStyle(fontSize: AppText.caption, color: SetupColors.muted(context))),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                uid,
                maxLines: 1,
                softWrap: false,
                style: SetupText.mono(fontSize: AppText.body, fontWeight: FontWeight.w700, color: SetupColors.text(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    final warn = r.hasWarnings;
    final color = warn ? SetupColors.warn : SetupColors.ok;
    final pendingRuntime = r.runtimeSync == 'pending_device_online';
    final text = SetupColors.text(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            OrbIconBadge(
              icon: warn ? Icons.warning_amber_rounded : Icons.check_rounded,
              family: warn ? AppFamilies.amber : AppFamilies.emerald,
              size: OrbSize.md,
              status: warn ? OrbStatus.none : OrbStatus.success,
              glow: true,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                warn ? 'Pano değişimi kısmen tamamlandı' : 'Pano değişimi tamamlandı',
                key: const Key('replace_result_title'),
                style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: SetupColors.readable(context, color)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Kimlikler cümlenin İÇİNDE değil ayrı satırlarda: 1.5 yazıda "AHBU-" / "S3-0A0B0C" diye tireden bölünüyordu.
        Text(
          fromStatusCheck
              ? '${homeName.isEmpty ? 'Daire' : homeName}: yeni pano dairenin pano listesinde '
                  'görünüyor; değişim sunucuda tamamlanmış. Aktarılan kanal sayısı bilinmiyor.'
              : '${homeName.isEmpty ? 'Daire' : homeName}: eski pano yerine yeni pano tanımlandı. '
                  '${r.migratedEndpointsCount} kanal yeni panoya aktarıldı.',
          key: const Key('replace_result_text'),
          style: TextStyle(fontSize: AppText.body, height: 1.4, color: text),
        ),
        if (!fromStatusCheck && r.oldDeviceUuid != null) _idRow(context, 'Eski pano', r.oldDeviceUuid!),
        _idRow(context, 'Yeni pano', r.newDeviceUuid),
        if (r.partial)
          const ServiceCard(
            key: Key('replace_partial'),
            accent: SetupColors.warn,
            child: SetupInfoRow(
              icon: Icons.warning_amber_rounded,
              color: SetupColors.warn,
              bold: true,
              text: 'Bazı adımlar tamamlanamadı. Aşağıdaki uyarıları okuyun ve gerekeni yapın.',
            ),
          ),
        for (var i = 0; i < r.warnings.length; i++)
          SetupInfoRow(
            key: Key('replace_warning_$i'),
            icon: Icons.info_outline_rounded,
            color: SetupColors.warn,
            text: r.warnings[i],
          ),
        if (pendingRuntime || r.shutterRuntimes.isNotEmpty)
          ServiceCard(
            key: const Key('replace_runtime_pending'),
            accent: SetupColors.info,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetupInfoRow(
                  icon: Icons.window_rounded,
                  color: SetupColors.info,
                  bold: true,
                  text: pendingRuntime
                      ? 'Panjur süreleri yeni pano çevrimiçi olunca otomatik uygulanacak.'
                      : 'Panjur süreleri yeni panoya aktarıldı.',
                ),
                for (final s in r.shutterRuntimes)
                  Padding(
                    padding: const EdgeInsets.only(left: 26, top: 2),
                    child: Text('Panjur ${s.shutter}: ${s.seconds} sn', style: TextStyle(fontSize: AppText.caption, color: text)),
                  ),
              ],
            ),
          ),
        if (r.childLockPending)
          const ServiceCard(
            key: Key('replace_childlock_pending'),
            accent: SetupColors.info,
            child: SetupInfoRow(
              icon: Icons.child_care_rounded,
              color: SetupColors.info,
              text: 'Çocuk kilidi, yeni pano çevrimiçi olunca yeniden uygulanacak.',
            ),
          ),
        if (onOpenWizard != null) ...[
          const ServiceCard(
            key: Key('replace_next_step'),
            accent: SetupColors.primary,
            child: SetupInfoRow(
              icon: Icons.arrow_forward_rounded,
              color: SetupColors.primary,
              text: 'Sıradaki iş: yeni panoya Wi-Fi ve bulut kimliğinin yazılması. Kurulum sihirbazı bu adımları sizin '
                  'için yürütür.',
            ),
          ),
          const SizedBox(height: 14),
          SetupPrimaryButton(
            key: const Key('btn_replace_open_wizard'),
            label: 'Yeni Panoyu Şimdi Bağla',
            icon: Icons.wifi_rounded,
            onPressed: onOpenWizard,
          ),
        ] else if (superNote)
          const ServiceCard(
            key: Key('replace_super_note'),
            accent: SetupColors.info,
            child: SetupInfoRow(icon: Icons.info_outline_rounded, color: SetupColors.info, text: superNextStep),
          )
        else ...[
          const ServiceCard(
            key: Key('replace_owner_next'),
            accent: SetupColors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetupInfoRow(icon: Icons.arrow_forward_rounded, color: SetupColors.primary, text: ownerNextStep),
                SizedBox(height: 6),
                SetupInfoRow(icon: Icons.cloud_sync_outlined, color: SetupColors.info, text: claimCloudBootstrapNote),
              ],
            ),
          ),
          if (onOpenWifi != null) ...[
            const SizedBox(height: 14),
            SetupPrimaryButton(
              key: const Key('btn_replace_open_wifi'),
              label: "Yeni Panoyu Wi-Fi'ye Bağla",
              icon: Icons.wifi_rounded,
              onPressed: onOpenWifi,
            ),
          ],
        ],
        const SizedBox(height: 8),
        TextButton(
          key: const Key('btn_replace_close'),
          style: AppTheme.quietTextButtonStyle(context),
          onPressed: onClose,
          child: const Text('Kapat'),
        ),
      ],
    );
  }
}
