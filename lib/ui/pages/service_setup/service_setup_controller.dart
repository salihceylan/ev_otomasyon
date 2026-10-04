import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/api_models.dart';
import '../../../services/automation_state.dart';
import 'device_link.dart';
import 'logic/button_logic.dart';
import 'logic/claim_logic.dart';
import 'logic/cloud_logic.dart';
import 'logic/connection_logic.dart';
import 'logic/customer_logic.dart';
import 'logic/handover_logic.dart';
import 'logic/identify_logic.dart';
import 'logic/preparation_logic.dart';
import 'logic/relay_logic.dart';
import 'logic/shutter_logic.dart';
import 'logic/wifi_logic.dart';
import 'service_target.dart';
import 'setup_context.dart';
import 'setup_problem.dart';
import 'setup_steps.dart';
import 'setup_store.dart';

/// Bir adımın rozet durumu.
enum StepPhase {
  /// Henüz ulaşılmadı / bekliyor.
  pending,

  /// Bir işlem çalışıyor.
  working,

  /// Geçiş koşulu gerçek yanıtla sağlandı.
  done,

  /// Son işlem başarısız (açıklama + "Tekrar dene").
  failed,

  /// Bu oturum türünde gerekmiyor (ör. geçici servis oturumunda claim).
  skipped,
}

/// Servis kurulum sihirbazının **durum makinesi**.
///
/// * 10 adım; hiçbir adım "tamam" denildi diye geçilmez: [canContinue] yalnızca adımın mantığı
///   ([SetupLogic.isComplete]) gerçek cihaz/sunucu yanıtıyla sağlandığında doğrudur.
/// * İlerleme **cihaz bazında** `SharedPreferences`'ta saklanır ([SetupStore]); gizli değer (anahtar, PIN,
///   OTP, bulut kimliği, Wi-Fi şifresi) kaydedilmez. Yarıda bırakılan kurulum kaldığı yerden sürer.
/// * Oturum süresi (geçici servis PIN'i) izlenir; süre dolunca eylemler "Oturum süresi doldu" ile durur,
///   kaydedilen ilerleme korunur.
/// * Claim sonrası tüm adımlar [target]'a (ev + cihaz) işlem yapar; aktif ev kullanılmaz.
class ServiceSetupController extends ChangeNotifier {
  ServiceSetupController({
    required this.state,
    required this.access,
    SetupStore? store,
    DeviceApiFactory? deviceApiFactory,
    SetupProgressRecord? resume,
    ServiceTarget? existingTarget,
    int? startStep,
    DeviceMqttCredential? initialCredential,
  })  : store = store ?? SetupStore(),
        link = DeviceLink(deviceApiFactory ?? defaultDeviceApiFactory(state.clock)) {
    ctx = SetupContext(
      state: state,
      access: access,
      link: link,
      onNotify: _notify,
      onPersist: _schedulePersist,
    );
    // Acil sıfırlama / pano değişimi yanıtındaki tek seferlik bulut kimliği (varsa): 6. adımda panoya yazılır;
    // yalnızca bellekte tutulur, kayda yazılmaz.
    ctx.pendingCredential = initialCredential;
    prep = PreparationLogic(ctx, onVerified: _applyPendingStart);
    identify = IdentifyLogic(ctx);
    customer = CustomerLogic(ctx, identify);
    claim = ClaimLogic(ctx, identify, customer);
    wifi = WifiLogic(ctx);
    cloud = CloudLogic(ctx, canReuseOnline: () => isExistingDevice);
    conn = ConnectionLogic(ctx);
    ctx.onLanVerified = wifi.markConnectedOnLan;
    relays = RelayLogic(ctx);
    shutters = ShutterLogic(ctx);
    buttons = ButtonLogic(ctx);
    handover = HandoverLogic(
      ctx,
      wifi: wifi,
      cloudLogic: cloud,
      relays: relays,
      shutters: shutters,
      buttons: buttons,
      claim: claim,
      customer: customer,
    );

    // Geçici servis oturumunda cihaz ev sahibi tarafından zaten eşlenmiştir: müşteri (3) ve claim (4)
    // adımları yoktur; ilerleme "cihaz seçildi" (2. adım) koşuluna bağlıdır.
    if (access.isPinSession) {
      _skipped.addAll(<int>{SetupSteps.customer, SetupSteps.claim});
    }
    if (resume != null) {
      _applyRecord(resume);
    } else if (existingTarget != null) {
      _applyExisting(existingTarget, startStep ?? SetupSteps.wifi);
    }
    state.addListener(_onStateChanged);
    _ticker = ctx.periodic(const Duration(seconds: 1), _onTick);
  }

  final AutomationState state;
  final ServiceSetupAccess access;
  final SetupStore store;
  final DeviceLink link;
  late final SetupContext ctx;

  late final PreparationLogic prep;
  late final IdentifyLogic identify;
  late final CustomerLogic customer;
  late final ClaimLogic claim;
  late final WifiLogic wifi;
  late final CloudLogic cloud;

  /// 6-9. adımların ortak pano bağlantısı (adres düzenle + bağlan).
  late final ConnectionLogic conn;
  late final RelayLogic relays;
  late final ShutterLogic shutters;
  late final ButtonLogic buttons;
  late final HandoverLogic handover;

  int _currentStep = SetupSteps.preparation;
  final Set<int> _skipped = <int>{};
  DateTime? _createdAt;
  Timer? _ticker;
  bool _disposed = false;

  /// Kullanıcı kurulumu bıraktı ([discardProgress]): bundan sonra ilerleme yeniden yazılmaz.
  bool _discarded = false;
  bool _persistQueued = false;
  bool _wasOver = false;

  /// Her saniye artar: geri sayım rozetleri bunu dinler (tüm sayfayı yeniden çizmeden).
  final ValueNotifier<int> clockTick = ValueNotifier<int>(0);

  int get currentStep => _currentStep;
  int get stepCount => SetupSteps.total;
  Set<int> get skippedSteps => Set<int>.unmodifiable(_skipped);
  ServiceTarget? get target => ctx.target;

  /// Bu kurulum devam eden/mevcut bir cihaz için mi (2-4. adımlar atlanır).
  bool get isExistingDevice => _skipped.contains(SetupSteps.identify);

  // ---------------------------------------------------------------------------
  // Mantık eşlemesi
  // ---------------------------------------------------------------------------

  SetupLogic logicFor(int step) {
    switch (step) {
      case SetupSteps.preparation:
        return prep;
      case SetupSteps.identify:
        return identify;
      case SetupSteps.customer:
        return customer;
      case SetupSteps.claim:
        return claim;
      case SetupSteps.wifi:
        return wifi;
      case SetupSteps.cloud:
        return cloud;
      case SetupSteps.relays:
        return relays;
      case SetupSteps.shutters:
        return shutters;
      case SetupSteps.buttons:
        return buttons;
      default:
        return handover;
    }
  }

  List<SetupLogic> get _allLogics =>
      <SetupLogic>[prep, identify, customer, claim, wifi, cloud, conn, relays, shutters, buttons, handover];

  /// Adımın geçiş koşulu gerçek yanıtla sağlandı mı (atlanan adımlar dahil).
  bool isStepComplete(int step) {
    if (_skipped.contains(step)) return ctx.target != null;
    switch (step) {
      case SetupSteps.preparation:
        return prep.isComplete;
      case SetupSteps.identify:
        return claim.isComplete || identify.isComplete;
      case SetupSteps.customer:
        return claim.isComplete || customer.isComplete;
      case SetupSteps.claim:
        return claim.isComplete;
      default:
        return logicFor(step).isComplete;
    }
  }

  /// İlk tamamlanmamış adım (ilerleme çizgisi); hepsi bittiyse 10.
  int get firstIncompleteStep {
    for (var n = 1; n <= SetupSteps.total; n++) {
      if (!isStepComplete(n)) return n;
    }
    return SetupSteps.total;
  }

  /// Ulaşılabilecek en ileri adım (tamamlanmamış adımın ötesine geçilmez).
  int get maxReachableStep => firstIncompleteStep;

  bool get isBusy => _allLogics.any((l) => l.busy);

  /// Geçerli adımın rozeti.
  StepPhase phaseOf(int step) {
    if (_skipped.contains(step)) return StepPhase.skipped;
    final logic = logicFor(step);
    if (logic.busy) return StepPhase.working;
    if (logic.problem != null) return StepPhase.failed;
    if (isStepComplete(step)) return StepPhase.done;
    return StepPhase.pending;
  }

  /// "Devam" düğmesi: geçerli adım **gerçek yanıtla** tamamlandı ve işlem sürmüyor.
  bool get canContinue =>
      !sessionExpired &&
      !isBusy &&
      _currentStep < SetupSteps.total &&
      isStepComplete(_currentStep);

  /// Kurulum tamamlandı: sunucu `tests_passed=true` döndürdü.
  bool get isFinished => handover.isComplete;

  // ---------------------------------------------------------------------------
  // Oturum
  // ---------------------------------------------------------------------------

  bool get sessionExpired => ctx.isSessionOver;

  /// Geçici servis oturumunun kalan süresi (kalıcı personelde `null`).
  Duration? get sessionRemaining {
    final expires = access.sessionExpiresAt;
    if (expires == null) return null;
    final left = expires.difference(ctx.clock.now());
    return left.isNegative ? Duration.zero : left;
  }

  void _onTick() {
    if (_disposed) return;
    clockTick.value++;
    _checkSession();
  }

  void _onStateChanged() => _checkSession();

  void _checkSession() {
    final over = ctx.isSessionOver;
    if (over && !_wasOver) {
      _wasOver = true;
      ctx.sessionEnded = true;
      buttons.stopListening();
      _persistNow();
      _notify();
    }
  }

  // ---------------------------------------------------------------------------
  // Başlatma / adım geçişleri
  // ---------------------------------------------------------------------------

  /// Sayfa açılınca: oturum doğrulaması ve geçerli adımın ilk işlemleri.
  ///
  /// Mevcut cihaz kipinde bekleyen başlangıç adımı ([_pendingStartStep]) oturum doğrulaması **hangi yoldan
  /// olursa olsun** (açılış, "Bağlantıyı Doğrula", "Tekrar dene") başarıyla bitince uygulanır
  /// ([PreparationLogic.onVerified]).
  ///
  /// Sunucuya **ulaşılamıyorsa** (internet yok: ör. telefon panonun kurulum ağında, Wi-Fi kurtarma) mevcut
  /// cihazda bekleyen başlangıç adımına yine de geçilir: 5. adım ve yerel (LAN) adımlar sunucu gerektirmez;
  /// uyarı şeridi ("Sunucu bağlantısı doğrulanamadı") görünür. 401/oturum bitişinde geçilmez.
  void start() {
    if (!prep.isComplete) {
      unawaited(prep.verify().then((ok) {
        final kind = prep.problem?.kind;
        if (!ok && (kind == SetupProblemKind.network || kind == SetupProblemKind.timeout)) _applyPendingStart();
      }));
    } else {
      _applyPendingStart();
    }
    _enterStep(_currentStep);
  }

  void _enterStep(int step) {
    if (_disposed || sessionExpired) return;
    // Sunucu doğrulaması internetsiz (kurulum ağı) başlangıç yüzünden eksik kaldıysa: internet gerektiren adımlara
    // (6 ve sonrası) girince sessizce yeniden denenir; uyarı şeridi yanlış yere takılı kalmasın.
    if (step >= SetupSteps.cloud && !prep.isComplete && !prep.busy) unawaited(prep.verify());
    switch (step) {
      case SetupSteps.identify:
        if (access.isPinSession && !identify.devicesLoaded && !identify.isComplete) {
          unawaited(identify.loadHomeDevices());
        }
      case SetupSteps.relays:
        if (!relays.loaded && ctx.target != null) unawaited(relays.load());
      case SetupSteps.shutters:
        if (!shutters.loaded && ctx.target != null) unawaited(shutters.load());
      case SetupSteps.buttons:
        if (!buttons.loaded && ctx.target != null) unawaited(buttons.load());
      case SetupSteps.handover:
        if (ctx.target != null && handover.result == null) unawaited(handover.refreshSummary());
    }
  }

  /// Pano bağlantısı kuruldu (6-9. adım paneli): adımın bekleyen yüklemeleri yeniden denenir.
  void onDeviceConnected() => _enterStep(_currentStep);

  void _leaveStep(int step) {
    switch (step) {
      case SetupSteps.buttons:
        buttons.stopListening();
      case SetupSteps.relays:
        if (relays.loaded && relays.okCount > 0) unawaited(relays.allLightsOff());
      case SetupSteps.shutters:
        // Yarım kalan süre ölçümü: panjur durdurulur, ölçüm için yazılan geçici 300 sn önceki değere döner.
        unawaited(shutters.settleMeasurements());
    }
  }

  /// Çıkışta uçuştaki panjur işleminin (ör. ölçüm hazırlığı: panoya geçici 300 sn yazılıyor) bitmesi için en çok bu kadar
  /// beklenir. Hazırlık en kötü ~20 sn sürebilir; sınır dolarsa çıkış yine sürer (kilitlenmez) ve önceki süre kayıttan
  /// sonraki açılışta geri yüklenir.
  static const Duration exitBusyWait = Duration(seconds: 20);

  /// Sihirbazdan çıkmadan önce panoyu güvenli duruma getirir: dinleme durur, yanan lambalar kapanır,
  /// yarım kalan panjur ölçümünün geçici süresi geri yüklenir. Sayfa çıkış onayından sonra çağırır.
  ///
  /// Panjur mantığı meşgulken (ör. ölçüm hazırlığı geçici süreyi yazıyor) `run` yeni işi reddeder: bu yüzden önce
  /// uçuştaki işin bitmesi ([exitBusyWait] sınırıyla) beklenir; aksi halde geri yükleme sessizce atlanır ve 300 sn
  /// panoda/sunucuda kalırdı.
  Future<void> settleBeforeExit() async {
    if (_disposed) return;
    buttons.stopListening();
    await _awaitShuttersIdle();
    if (_disposed) return;
    if (_currentStep == SetupSteps.shutters || shutters.shutters.any((s) => s.hasMeasureOverride)) {
      await shutters.settleMeasurements();
    }
    if (_currentStep == SetupSteps.relays && relays.loaded && relays.okCount > 0) {
      await relays.allLightsOff();
    }
  }

  /// Panjur mantığındaki uçuştaki işlem bitene kadar (en çok [exitBusyWait]) 200 ms aralıkla bekler.
  Future<void> _awaitShuttersIdle() async {
    if (!shutters.busy) return;
    final deadline = ctx.clock.now().add(exitBusyWait);
    while (shutters.busy && !_disposed && ctx.clock.now().isBefore(deadline)) {
      await ctx.delay(const Duration(milliseconds: 200));
    }
  }

  /// Bir sonraki (atlanmayan) adıma geçer; yalnızca [canContinue] doğruysa.
  void continueNext() {
    if (!canContinue) return;
    _leaveStep(_currentStep);
    var next = _currentStep + 1;
    while (next < SetupSteps.total && _skipped.contains(next)) {
      next++;
    }
    _currentStep = next;
    _notify();
    _schedulePersist();
    _enterStep(next);
  }

  /// Önceki (atlanmayan) adıma döner.
  void goBack() {
    if (_currentStep <= 1 || isBusy) return;
    _leaveStep(_currentStep);
    var prev = _currentStep - 1;
    while (prev > 1 && _skipped.contains(prev)) {
      prev--;
    }
    _currentStep = prev;
    _notify();
    _schedulePersist();
  }

  /// Hata kutusundaki "N. adıma dön" (PIN -> 2, müşteri kodu -> 3 ...).
  void goToStep(int step) {
    if (step < 1 || step > SetupSteps.total || isBusy) return;
    if (step > maxReachableStep && step > _currentStep) return;
    _leaveStep(_currentStep);
    _currentStep = step;
    _notify();
    _schedulePersist();
    _enterStep(step);
  }

  // ---------------------------------------------------------------------------
  // Kayıt / devam
  // ---------------------------------------------------------------------------

  void _applyRecord(SetupProgressRecord record) {
    _createdAt = record.createdAt;
    final target = ServiceTarget(
      homeId: record.homeId,
      deviceUuid: record.deviceUuid,
      homeName: record.homeName,
      ip: record.ip,
    );
    ctx.target = target;
    identify.adoptTarget(target);
    if (record.skipped.isNotEmpty) {
      _skipped.addAll(record.skipped);
    } else {
      claim.adopt(target);
    }
    customer.restore(<String, dynamic>{'hint': record.customerHint});
    for (final logic in <SetupLogic>[wifi, cloud, relays, shutters, buttons, handover]) {
      final raw = record.data['${logic.number}'];
      if (raw is Map) logic.restore(Map<String, dynamic>.from(raw));
    }
    // Atlanan adımlar yoksa (personel akışı) 2-4 gerçekten yapılmıştır.
    _currentStep = record.currentStep.clamp(1, SetupSteps.total);
  }

  void _applyExisting(ServiceTarget target, int startStep) {
    ctx.target = target;
    identify.adoptTarget(target);
    _skipped.addAll(<int>{SetupSteps.identify, SetupSteps.customer, SetupSteps.claim});
    _currentStep = SetupSteps.preparation;
    // Oturum doğrulanınca (1. adım) bu adıma atlanır.
    _pendingStartStep = startStep.clamp(SetupSteps.wifi, SetupSteps.handover);
  }

  int? _pendingStartStep;

  void _applyPendingStart() {
    final step = _pendingStartStep;
    if (step == null || _disposed || sessionExpired) return;
    _pendingStartStep = null;
    if (_currentStep == SetupSteps.preparation) {
      _currentStep = step;
      _notify();
      _schedulePersist();
      _enterStep(step);
    }
  }

  SetupProgressRecord? _buildRecord() {
    final t = ctx.target;
    if (t == null) return null;
    final now = ctx.clock.now();
    _createdAt ??= now;
    return SetupProgressRecord(
      ownerKey: access.ownerKey,
      deviceUuid: t.deviceUuid,
      homeId: t.homeId,
      homeName: t.homeName,
      ip: t.ip,
      currentStep: _currentStep,
      completed: <int>{
        for (var n = 2; n <= SetupSteps.total; n++)
          if (isStepComplete(n)) n,
      },
      skipped: Set<int>.of(_skipped),
      customerHint: customer.hint,
      data: <String, dynamic>{
        for (final logic in <SetupLogic>[wifi, cloud, relays, shutters, buttons, handover])
          '${logic.number}': logic.snapshot(),
      },
      createdAt: _createdAt!,
      updatedAt: now,
    );
  }

  void _schedulePersist() {
    if (_disposed || _discarded || _persistQueued) return;
    _persistQueued = true;
    scheduleMicrotask(() {
      _persistQueued = false;
      _persistNow();
    });
  }

  void _persistNow() {
    if (_discarded) return;
    final record = _buildRecord();
    if (record == null) return;
    if (handover.isComplete) {
      unawaited(store.delete(record.ownerKey, record.deviceUuid));
    } else {
      unawaited(store.save(record));
    }
  }

  /// İlerlemeyi siler (kullanıcı kurulumu bıraktı).
  Future<void> discardProgress() async {
    _discarded = true; // sayfa kapanırken (dispose) kayıt yeniden yazılmasın
    final t = ctx.target;
    if (t != null) await store.delete(access.ownerKey, t.deviceUuid);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _persistNow();
    _disposed = true;
    state.removeListener(_onStateChanged);
    ctx.cancelTimer(_ticker);
    for (final logic in _allLogics) {
      logic.dispose();
    }
    ctx.dispose();
    link.dispose();
    ctx.pendingCredential = null;
    clockTick.dispose();
    super.dispose();
  }
}
