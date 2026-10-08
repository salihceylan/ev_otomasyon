import 'package:intl/intl.dart';

import '../../../../models/api_models.dart';
import '../../../../models/automation_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'button_logic.dart';
import 'claim_logic.dart';
import 'cloud_logic.dart';
import 'customer_logic.dart';
import 'relay_logic.dart';
import 'shutter_logic.dart';
import 'wifi_logic.dart';

/// Adım 10 - Teslim.
///
/// Önceki adımların **gerçek sonuçlarından** 5 zorunlu kontrol (`relays`, `buttons`, `shutters`,
/// `network`, `cloud`) ayrı alanlarla üretilir ve `POST /homes/:id/commissioning` ile sunucuya gönderilir.
/// `tests_passed` istemcide hesaplanmaz: sunucu hesaplar. Geçiş koşulu: sunucu `tests_passed=true` döndü.
///
/// Kurulum raporu (paylaş/kopyala) PIN, anahtar, kimlik, OTP ve Wi-Fi şifresi İÇERMEZ.
class HandoverLogic extends SetupLogic {
  HandoverLogic(
    super.ctx, {
    required this.wifi,
    required this.cloudLogic,
    required this.relays,
    required this.shutters,
    required this.buttons,
    required this.claim,
    required this.customer,
  });

  final WifiLogic wifi;
  final CloudLogic cloudLogic;
  final RelayLogic relays;
  final ShutterLogic shutters;
  final ButtonLogic buttons;
  final ClaimLogic claim;
  final CustomerLogic customer;

  @override
  int get number => SetupSteps.handover;

  static const int maxNotesLength = 800;

  /// Rapor tarihi biçimi (her çağrıda yeniden kurulmaz).
  static final DateFormat _reportDate = DateFormat('dd.MM.yyyy HH:mm');

  String _notes = '';
  String _receiver = '';
  bool _ownerApproved = false;
  CommissioningResult? _result;
  DateTime? _completedAt;
  bool? _cloudOnlineNow;
  DeviceStatus? _lan;

  String get notes => _notes;
  String get receiver => _receiver;
  bool get ownerApproved => _ownerApproved;
  CommissioningResult? get result => _result;
  DateTime? get completedAt => _completedAt;

  /// Son yenilemede sunucuda çevrimiçi miydi (`null` = henüz bakılmadı).
  bool? get cloudOnlineNow => _cloudOnlineNow;
  DeviceStatus? get lanStatus => _lan;

  void setNotes(String value) => _notes = value.length > maxNotesLength ? value.substring(0, maxNotesLength) : value;
  void setReceiver(String value) => _receiver = value.length > 100 ? value.substring(0, 100) : value;

  void setOwnerApproved(bool value) {
    _ownerApproved = value;
    ctx.notify();
    ctx.persist();
  }

  /// Önceki 5 adım tamamlandı mı.
  bool get allStepsReady =>
      wifi.isComplete && cloudLogic.isComplete && relays.isComplete && shutters.isComplete && buttons.isComplete;

  /// Hangi adımların tamamlanmadığı (kullanıcıya gösterim).
  List<int> get missingSteps => <int>[
        if (!wifi.isComplete) SetupSteps.wifi,
        if (!cloudLogic.isComplete) SetupSteps.cloud,
        if (!relays.isComplete) SetupSteps.relays,
        if (!shutters.isComplete) SetupSteps.shutters,
        if (!buttons.isComplete) SetupSteps.buttons,
      ];

  /// Sunucu onayı için hazır mı (butonun etkin olma koşulu).
  bool get canSubmit => allStepsReady && _ownerApproved && !busy && _result?.testsPassed != true;

  @override
  bool get isComplete => _result?.testsPassed == true;

  // ---------------------------------------------------------------------------
  // Kontroller
  // ---------------------------------------------------------------------------

  CommissioningChecks buildChecks() {
    final okRelays = relays.okCount;
    final unusedRelays = relays.unusedCount;
    final visualRelays = relays.relays.where((r) => r.verdict == RelayVerdict.ok && r.visualOnly).length;
    final relayDetail = relays.relays.isEmpty
        ? (relays.shutterRelays.isNotEmpty
            // Yalnız panjur röleli pano (servis_kurulum-6).
            ? 'Lamba/darbe rölesi yok (tüm röleler panjur; 8. adımda test edildi)'
            : 'Röle bildirilmedi')
        : '$okRelays röle doğrulandı'
            '${visualRelays > 0 ? ' ($visualRelays darbe rölesi pano geri bildirimi olmadan gözle doğrulandı)' : ''}'
            '${unusedRelays > 0 ? ', $unusedRelays kullanılmıyor (teknisyen beyanı)' : ''}';

    final buttonDetail = buttons.hasNoInputs
        ? 'Pano giriş bildirmedi (duvar butonu yok)'
        : '${buttons.detectedCount} buton algılandı${buttons.noneCount > 0 ? ', ${buttons.noneCount} girişte buton yok' : ''}';

    String shutterDetail;
    if (shutters.hasNoShutters) {
      shutterDetail = 'Panoda panjur yok';
    } else if (shutters.noMotorizedDeclared && shutters.shutters.every((s) => s.unused)) {
      // Teknisyen beyanı (servis_kurulum-3).
      shutterDetail = 'Panoda ${shutters.shutters.length} panjur çifti tanımlı; dairede motorlu panjur yok (teknisyen beyanı)';
    } else {
      final parts = <String>[
        for (final s in shutters.shutters)
          s.unused ? '${s.name}: kullanılmıyor (teknisyen beyanı)' : '${s.name}: ${s.savedSeconds ?? '?'} sn, yön doğru',
      ];
      shutterDetail = parts.join('; ');
      if (shutterDetail.length > 400) shutterDetail = '${shutters.shutters.length} panjur kalibre edildi';
    }

    final lan = _lan;
    final networkOk = wifi.isComplete && (lan == null || lan.onHomeNetwork);
    final rssi = lan != null && lan.wifiStaRssi != 0 ? ' (sinyal ${lan.wifiStaRssi} dBm)' : '';
    // Ethernet: pano bildirdiyse (durum `eth_connected`), yoksa 5. adım Ethernet yoluyla doğrulandıysa.
    final ethernet = lan != null ? (lan.netIf == 'eth' || (lan.onEthernet && !lan.wifiConnected)) : wifi.viaEthernet;
    final ethIp = (lan != null && lan.ethIp.isNotEmpty) ? lan.ethIp : (ctx.target?.ip ?? '');
    final cloudOk = cloudLogic.isComplete && (_cloudOnlineNow ?? true);

    return CommissioningChecks(
      relays: CommissionCheck(ok: relays.isComplete, detail: relayDetail),
      buttons: CommissionCheck(ok: buttons.isComplete, detail: buttonDetail),
      shutters: CommissionCheck(ok: shutters.isComplete, detail: shutterDetail),
      network: CommissionCheck(
        ok: networkOk,
        detail: !networkOk
            ? 'Pano ev ağına (Wi-Fi ya da Ethernet) bağlı görünmüyor'
            : (ethernet
                ? 'Pano ev ağına Ethernet ile bağlı${ethIp.isEmpty ? '' : ' (IP $ethIp)'}'
                : 'Pano ev Wi-Fi ağına bağlı$rssi'),
      ),
      cloud: CommissionCheck(
        ok: cloudOk,
        detail: cloudOk ? 'Sunucuda çevrimiçi' : 'Sunucuda çevrimdışı görünüyor',
      ),
    );
  }

  /// Teslimden hemen önce güncel durumu okur: sunucuda çevrimiçi mi, pano ev ağında mı (en iyi çaba).
  Future<void> _refresh() async {
    final t = ctx.requireTarget;
    // Sunucu listesi ve pano yerel durumu birbirine bağlı değil: birlikte beklenir (telefon pano ağında değilken yerel
    // kol 4 sn'lik bağlantı zaman aşımına kadar sürebilir; sunucu isteği onun arkasında beklemez).
    final (devices, _) = await awaitBoth(ctx.cloud.devices(t.homeId), _readLan());
    _cloudOnlineNow = devices.any((d) => d.deviceUuid.toUpperCase() == t.deviceUuid.toUpperCase() && d.online);
  }

  /// Panonun yerel durumunu [_lan]'a okur (en iyi çaba): yerel bağlantı yoksa (telefon başka ağda) `null` olur ve
  /// yalnızca sunucu bilgisiyle devam edilir. İptal ve oturum bitişi yukarı verilir.
  Future<void> _readLan() async {
    try {
      _lan = await ctx.deviceCall((api) => api.fetchStatus());
    } catch (error) {
      if (error is SetupCancelled || error is SetupSessionExpiredException) rethrow;
      _lan = null;
    }
  }

  /// Güncel özeti (sunucu + pano) yeniler.
  Future<bool> refreshSummary() => run('Güncel durum okunuyor', _refresh);

  /// Sonuçları sunucuya gönderir; sunucu `tests_passed` kararını verir.
  Future<bool> submit() => run('Devreye alma sunucuya gönderiliyor', () async {
        if (!allStepsReady) {
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Önceki adımlar tamamlanmadı',
            why: 'Şu adımlar henüz doğrulanmadı: ${missingSteps.join(', ')}.',
            todo: 'Eksik adımları tamamlayın; sonuçlar gerçek cihaz yanıtlarıyla doğrulanır.',
            retryable: false,
            fixStep: missingSteps.first,
          ));
        }
        if (!_ownerApproved) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Müşteri onayı gerekli',
            why: 'Teslim, müşteriye kurulum gösterilip onaylatıldıktan sonra yapılır.',
            todo: '"Müşteriye gösterdim ve teslimi onayladı" kutusunu işaretleyin.',
            retryable: false,
          ));
        }
        final t = ctx.requireTarget;
        await _ensureProvisioned(t.ip, t.deviceUuid);
        await _refresh();
        final checks = buildChecks();
        final notes = _composeNotes();
        final result = await ctx.cloud.commission(
          homeId: t.homeId,
          deviceUuid: t.deviceUuid,
          checks: checks,
          notes: notes.isEmpty ? null : notes,
        );
        _result = result;
        if (!result.testsPassed) {
          final failed = _failedChecks(result, checks);
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.rejected,
            title: 'Sunucu devreye almayı onaylamadı',
            why: failed.isEmpty
                ? 'Sunucu, zorunlu kontrollerin hepsinin başarılı olduğunu doğrulayamadı.'
                : 'Başarısız kontroller: ${failed.join(', ')}.',
            todo: 'İlgili adıma dönüp testi gerçek cihaz yanıtıyla tekrarlayın, sonra yeniden gönderin.',
          ));
        }
        _completedAt = ctx.clock.now();
      });

  /// Teslimden önce panonun hazırlığı anahtarsız denetlenir (servis_kurulum-1): [_readLan] hataları yuttuğu için ayrı
  /// denetim gerekir. Panoya ulaşılamazsa (telefon başka ağda) atlanır; hazırlanmamış panoda teslim reddedilir.
  Future<void> _ensureProvisioned(String ip, String uid) async {
    if (ip.trim().isEmpty) return;
    try {
      final identity = await ctx.link.probe(ip, expectedUid: uid);
      if (identity.provisioned == false) throw const SetupProblemException(SetupContext.unprovisionedProblem);
    } on LocalApiException catch (e) {
      if (!e.isNetwork && e.code != 'not_configured') rethrow;
    }
    ctx.ensureActive();
  }

  String _composeNotes() {
    final parts = <String>[
      if (_notes.trim().isNotEmpty) _notes.trim(),
      if (_receiver.trim().isNotEmpty) 'Teslim alan: ${_receiver.trim()}',
    ];
    final text = parts.join('\n');
    return text.length > 1000 ? text.substring(0, 1000) : text;
  }

  List<String> _failedChecks(CommissioningResult result, CommissioningChecks own) {
    const labels = <String, String>{
      'relays': 'röleler',
      'buttons': 'duvar butonları',
      'shutters': 'panjurlar',
      'network': 'Wi-Fi',
      'cloud': 'bulut',
    };
    final failed = <String>[];
    final serverChecks = asMap(result.raw['checks']);
    if (serverChecks != null) {
      for (final entry in labels.entries) {
        final c = asMap(serverChecks[entry.key]);
        if (c != null && asBool(c['ok']) == false) failed.add(entry.value);
      }
    }
    if (failed.isEmpty) {
      final mine = <String, bool>{
        'relays': own.relays.ok,
        'buttons': own.buttons.ok,
        'shutters': own.shutters.ok,
        'network': own.network.ok,
        'cloud': own.cloud.ok,
      };
      for (final entry in labels.entries) {
        if (mine[entry.key] == false) failed.add(entry.value);
      }
    }
    return failed;
  }

  // ---------------------------------------------------------------------------
  // Rapor
  // ---------------------------------------------------------------------------

  /// Kurulum raporu. **PIN, anahtar, bulut kimliği, OTP ve Wi-Fi şifresi içermez.**
  String buildReport({String? technician, String? roleLabel}) {
    final t = ctx.target;
    final when = _completedAt ?? ctx.clock.now();
    final date = _reportDate.format(when.toLocal());
    final checks = buildChecks();
    String mark(bool ok) => ok ? '[TAMAM]' : '[EKSİK]';
    final lan = _lan;
    final homeId = t?.homeId ?? '';
    final shortHome = homeId.length > 8 ? homeId.substring(0, 8) : homeId;
    final result = _result;
    final lines = <String>[
      'AHBU Akıllı Ev - Kurulum Raporu',
      'Tarih: $date',
      'Teknisyen: ${technician ?? ctx.access.technicianName}${roleLabel == null ? '' : ' ($roleLabel)'}',
      'Daire: ${(t?.homeName.isNotEmpty ?? false) ? t!.homeName : '-'}${shortHome.isEmpty ? '' : ' [$shortHome]'}',
      'Cihaz: ${t?.deviceUuid ?? '-'}${(lan?.firmware ?? '').isEmpty ? '' : ' (yazılım ${lan!.firmware})'}',
      if (customer.hint.isNotEmpty) 'Müşteri: ${customer.hint}',
      'Sonuç: ${result == null ? 'GÖNDERİLMEDİ' : (result.testsPassed ? 'BAŞARILI - sunucu devreye almayı onayladı' : 'ONAYLANMADI')}',
      '',
      'Kontroller:',
      '${mark(checks.network.ok)} Wi-Fi: ${checks.network.detail}',
      '${mark(checks.cloud.ok)} Bulut: ${checks.cloud.detail}',
      '${mark(checks.relays.ok)} Röleler: ${checks.relays.detail}',
      '${mark(checks.shutters.ok)} Panjurlar: ${checks.shutters.detail}',
      '${mark(checks.buttons.ok)} Duvar butonları: ${checks.buttons.detail}',
      if (_notes.trim().isNotEmpty) ...<String>['', 'Notlar: ${_notes.trim()}'],
      if (_receiver.trim().isNotEmpty) 'Teslim alan: ${_receiver.trim()}',
    ];
    return lines.join('\n');
  }

  @override
  Map<String, dynamic> snapshot() => <String, dynamic>{
        'notes': _notes,
        'receiver': _receiver,
        'approved': _ownerApproved,
      };

  @override
  void restore(Map<String, dynamic> json) {
    _notes = asString(json['notes']) ?? '';
    _receiver = asString(json['receiver']) ?? '';
    _ownerApproved = json['approved'] == true;
  }
}
