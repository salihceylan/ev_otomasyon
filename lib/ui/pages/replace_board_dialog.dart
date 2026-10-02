import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/api_models.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../../utils/qr_claim_parser.dart';
import 'service_setup/panel/uncertain_outcome_card.dart';
import 'service_setup/service_setup_wizard_page.dart';
import 'service_setup/service_target.dart';
import 'service_setup/setup_fields.dart';
import 'service_setup/setup_steps.dart';
import 'service_setup/setup_style.dart';
import 'service_setup/setup_widgets.dart';
import 'service_setup/steps/step_common.dart';

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
    return showDialog<void>(
      context: context,
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
    final confirmed = await showDialog<bool>(
      context: context,
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

  void _openWizard(ReplaceBoardResult result) {
    final homeId = result.homeId ?? _homeId;
    if (homeId == null) return;
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final caps = state.capabilities;
    final homeChanged = _homeId != null && state.activeHome?.id != _homeId;
    return Dialog(
      backgroundColor: SetupColors.surface(context),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: SetupColors.border(context)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.sync_alt_rounded, color: SetupColors.purple, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pano Değişimi',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_replace_x'),
                    tooltip: 'Kapat',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Divider(color: SetupColors.border(context)),
              if (_result != null)
                _ResultView(
                  result: _result!,
                  fromStatusCheck: _resultFromCheck,
                  homeName: _homeName,
                  onOpenWizard: () => _openWizard(_result!),
                  onClose: () => Navigator.of(context).pop(),
                )
              else if (_homeId == null)
                const SetupCard(
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
              else if (!caps.canReplaceBoard)
                const SetupCard(
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
    );
  }

  Widget _form(BuildContext context, bool homeChanged) {
    final muted = SetupColors.muted(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupCard(
          key: const Key('replace_target_home'),
          accent: SetupColors.info,
          margin: EdgeInsets.zero,
          child: Row(
            children: [
              const Icon(Icons.home_rounded, color: SetupColors.info),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Değişim yapılacak daire', style: TextStyle(fontSize: 12, color: muted)),
                    Text(
                      _homeName.isEmpty ? 'İsimsiz daire' : _homeName,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (homeChanged)
          const SetupCard(
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
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(key: Key('replace_devices_loading'))),
          ),
        if (_devicesError != null)
          SetupCard(
            key: const Key('replace_devices_error'),
            accent: SetupColors.error,
            child: Row(
              children: [
                Expanded(child: Text(_devicesError!)),
                TextButton(
                  key: const Key('btn_devices_retry'),
                  onPressed: _loadingDevices ? null : _loadDevices,
                  child: const Text('Tekrar dene'),
                ),
              ],
            ),
          ),
        if (!_loadingDevices && _devicesError == null && _devices.isEmpty)
          SetupCard(
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
            child: Text(_oldError!, key: const Key('replace_old_error'), style: const TextStyle(color: SetupColors.error, fontSize: 12.5)),
          ),
        const SetupSectionTitle('2. Yeni pano'),
        SetupTextField(
          key: const Key('field_new_uid'),
          controller: _newUid,
          label: 'Yeni pano kimliği',
          hint: 'AHBU-...',
          errorText: _uidError,
          textCapitalization: TextCapitalization.characters,
          prefixIcon: Icons.qr_code_rounded,
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
          label: 'Yeni panonun 6 haneli kurulum PIN\'i',
          maxLength: 6,
          keyboardType: TextInputType.number,
          inputFormatters: [digitsOnly, LengthLimitingTextInputFormatter(6)],
          errorText: _pinError,
          monospace: true,
        ),
        SetupTextField(
          key: const Key('field_replace_reason'),
          controller: _reason,
          label: 'Değişim nedeni (isteğe bağlı)',
          hint: 'Örn: yıldırım düştü, pano arızalandı',
          prefixIcon: Icons.note_alt_outlined,
          enabled: !_submitting,
        ),
        if (_error != null)
          SetupCard(
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
          SetupCard(
            key: const Key('replace_check_result'),
            accent: SetupColors.info,
            child: SetupInfoRow(icon: Icons.info_outline_rounded, color: SetupColors.info, bold: true, text: _checkResult!),
          ),
        const SizedBox(height: 16),
        SetupPrimaryButton(
          key: const Key('btn_replace_submit'),
          label: 'Eski Panonun Ayarlarını Yeni Panoya Aktar',
          icon: Icons.cloud_download_outlined,
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
      child: SetupCard(
        key: Key('card_oldboard_${device.deviceUuid}'),
        accent: selected ? SetupColors.purple : null,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: selected ? SetupColors.purple : SetupColors.muted(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                        ),
                        Text(
                          device.deviceUuid,
                          style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: SetupColors.muted(context)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    device.online ? 'Çevrimiçi' : 'Çevrimdışı',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: SetupColors.readable(context, color)),
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

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: SetupColors.muted(context))),
          Text(value, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: SetupColors.text(context))),
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
            _row(context, 'Yeni pano', newUid),
            if (reason.isNotEmpty) _row(context, 'Neden', reason),
            const SizedBox(height: 8),
            Text(
              'Eski panonun bu daireyle bağlantısı kaldırılır ve yetkisi iptal edilir. Kanallar, isimler ve '
              'panjur süreleri yeni panoya aktarılır. Bu işlem geri alınamaz.',
              style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_replace_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Vazgeç'),
        ),
        ElevatedButton(
          key: const Key('btn_replace_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: ElevatedButton.styleFrom(backgroundColor: SetupColors.purple, foregroundColor: Colors.white),
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
    required this.onClose,
  });

  final ReplaceBoardResult result;

  /// Sonuç sunucu yanıtından değil, durum kontrolünden: aktarılan kanal sayısı bilinmiyor.
  final bool fromStatusCheck;
  final String homeName;
  final VoidCallback onOpenWizard;
  final VoidCallback onClose;

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
            Icon(warn ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: color, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                warn ? 'Pano değişimi kısmen tamamlandı' : 'Pano değişimi tamamlandı',
                key: const Key('replace_result_title'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: SetupColors.readable(context, color)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          fromStatusCheck
              ? '${homeName.isEmpty ? 'Daire' : homeName}: yeni pano ${r.newDeviceUuid} dairenin pano listesinde '
                  'görünüyor; değişim sunucuda tamamlanmış. Aktarılan kanal sayısı bilinmiyor.'
              : '${homeName.isEmpty ? 'Daire' : homeName}: '
                  '${r.oldDeviceUuid == null ? 'eski pano' : r.oldDeviceUuid!} yerine ${r.newDeviceUuid} tanımlandı. '
                  '${r.migratedEndpointsCount} kanal yeni panoya aktarıldı.',
          key: const Key('replace_result_text'),
          style: TextStyle(fontSize: 13.5, height: 1.4, color: text),
        ),
        if (r.partial)
          const SetupCard(
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
          SetupCard(
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
                    child: Text('Panjur ${s.shutter}: ${s.seconds} sn', style: TextStyle(fontSize: 13, color: text)),
                  ),
              ],
            ),
          ),
        if (r.childLockPending)
          const SetupCard(
            key: Key('replace_childlock_pending'),
            accent: SetupColors.info,
            child: SetupInfoRow(
              icon: Icons.child_care_rounded,
              color: SetupColors.info,
              text: 'Çocuk kilidi, yeni pano çevrimiçi olunca yeniden uygulanacak.',
            ),
          ),
        const SetupCard(
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
          icon: Icons.wifi_find_rounded,
          onPressed: onOpenWizard,
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('btn_replace_close'),
          onPressed: onClose,
          child: const Text('Kapat'),
        ),
      ],
    );
  }
}
