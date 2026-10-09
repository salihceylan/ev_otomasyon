import 'package:flutter/foundation.dart';

import '../../../../models/automation_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/api_exception.dart';
import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'safety_assignment.dart';
import 'safety_config_transport.dart';

export 'safety_assignment.dart';

enum RelayVerdict { untested, ok, problem, unused }

/// Bulutta bu kurulumdan önce bekleyen değişiklik var (guvenlik-4): yeni plan kuyruğun sonuna EKLENMEZ.
class _QueueReplaceNeeded implements Exception {
  const _QueueReplaceNeeded(this.count);

  final int count;
}

/// Bir rölenin test durumu.
@immutable
class RelayCheck {
  const RelayCheck({
    required this.id,
    required this.name,
    this.isImpulse = false,
    this.state = false,
    this.sawOn = false,
    this.sawOff = false,
    this.lit,
    this.problem = false,
    this.unused = false,
    this.note,
    this.cmdSent = false,
    this.info,
    this.assign = ChannelAssignment.none,
    this.boardActuator = false,
  });

  /// 1 tabanlı röle numarası.
  final int id;
  final String name;

  /// Darbe/tetik rölesi (kısa süre açılıp kendiliğinden kapanır).
  final bool isImpulse;

  /// Panonun bildirdiği son durum.
  final bool state;

  /// Pano "açık" bildirdi (komuttan sonra gerçek geri bildirim).
  final bool sawOn;

  /// Pano "kapalı" bildirdi (komuttan sonra gerçek geri bildirim).
  final bool sawOff;

  /// Teknisyen yükün gerçekten çalıştığını onayladı (`true`) / çalışmadı (`false`) / henüz yanıtlamadı.
  final bool? lit;
  final bool problem;
  final bool unused;
  final String? note;

  /// Darbe rölesinde komut pano tarafından **kabul edildi** (HTTP 2xx) ama darbe çok kısa sürdüğü için
  /// pano durum bildirimi görülemedi: geri bildirim yoktur, doğrulama yalnızca teknisyenin gözleminedir.
  final bool cmdSent;

  /// Bilgi notu (sorun değil; ör. "geri bildirim görülemedi, yükü gözle doğrulayın").
  final String? info;

  /// "Bu kanala ne bağlı?" yanıtı ve vana / siren / fan / dimmer ayrıntıları (WP-A4; tasarım §4.4).
  final ChannelAssignment assign;

  /// Pano bu kanalı ZATEN güvenlik eylemcisi olarak bildiriyor (`relays[].act`): düz röle komutu açma yönünde
  /// reddedilir (`actuator_relay`), doğrulama bölge testiyle ([RelayLogic.testActuator]) ve gözle yapılır.
  final bool boardActuator;

  /// Doğrulama gözleme dayanır (darbe rölesi ya da bölge testiyle sınanan eylemci; pano röle geri bildirimi yok).
  bool get _visualCheck => isImpulse || boardActuator;

  /// Doğrulama yalnızca teknisyen gözlemine dayanıyor (darbe rölesinde pano geri bildirimi yok).
  bool get visualOnly => _visualCheck && !sawOn && cmdSent && lit == true;

  /// Yük çalıştı mı sorusu gösterilmeli: pano geri bildirimi geldi ya da darbe komutu / bölge testi kabul edildi.
  bool get awaitingLitAnswer => lit == null && !unused && (sawOn || (_visualCheck && cmdSent));

  RelayVerdict get verdict {
    if (unused) return RelayVerdict.unused;
    if (problem || lit == false) return RelayVerdict.problem;
    final deviceOk = boardActuator ? cmdSent : (isImpulse ? (sawOn || cmdSent) : (sawOn && sawOff));
    if (deviceOk && lit == true) return RelayVerdict.ok;
    return RelayVerdict.untested;
  }

  RelayCheck copyWith({
    bool? state,
    bool? sawOn,
    bool? sawOff,
    bool? lit,
    bool clearLit = false,
    bool? problem,
    bool? unused,
    String? note,
    bool clearNote = false,
    bool? cmdSent,
    String? info,
    bool clearInfo = false,
    ChannelAssignment? assign,
  }) =>
      RelayCheck(
        id: id,
        name: name,
        isImpulse: isImpulse,
        state: state ?? this.state,
        sawOn: sawOn ?? this.sawOn,
        sawOff: sawOff ?? this.sawOff,
        lit: clearLit ? null : (lit ?? this.lit),
        problem: problem ?? this.problem,
        unused: unused ?? this.unused,
        note: clearNote ? null : (note ?? this.note),
        cmdSent: cmdSent ?? this.cmdSent,
        info: clearInfo ? null : (info ?? this.info),
        assign: assign ?? this.assign,
        boardActuator: boardActuator,
      );
}

/// Adım 7 - Röle Testi.
///
/// Her röle için "Aç/Kapat" komutu **yerel ağdan** gönderilir ve panonun **gerçek durum bildirimi**
/// (`GET /api/status` -> `relays[].state` eşleşmesi) beklenir. Teknisyen ayrıca yükün gerçekten çalıştığını
/// ("yanıyor mu?") onaylar. Kullanılmayan çıkış işaretlenebilir. Geçiş koşulu: her röle doğrulanmış veya
/// "kullanılmıyor" ve en az biri doğrulanmış; sorunlu röle varsa geçilmez.
///
/// **Güvenlik ataması (WP-A4; tasarım §4.4, §4.5).** Aynı adımda her kanal için "Bu kanala ne bağlı?" (lamba, vana,
/// siren, fan, diğer cihaz), vana ayrıntıları (kapanma kipi, su/gaz, tek/iki röle, geri bildirim girişi, bölge), fan
/// ATEX onayı ve lamba için K4 "parlaklık ayarı yapılacak mı?" sorusu yanıtlanır; girişler (DI ya da köprü yuvası)
/// sensör / yerel kumanda rolü alır. Plan [saveSafety] ile panoya (`POST /api/safety/config`; asıl kaynak pano NVS'i,
/// K5) yazılır ve eylemcili her bölge için bir `alarm_test` çalıştırılır. Güvenlik cihazı atanmış ama panoya
/// yazılmamış plan adımı TAMAMLATMAZ ([needsSafetySave]); yalnız dimmer yanıtı engellemez (yönerge niteliğinde).
class RelayLogic extends SetupLogic {
  RelayLogic(super.ctx);

  @override
  int get number => SetupSteps.relays;

  List<RelayCheck> _relays = const <RelayCheck>[];
  bool _loaded = false;
  Map<int, String> _saved = const <int, String>{};

  // Güvenlik ataması (kayıttan gelen; yüklemede kanallara/girişlere uygulanır).
  Map<int, ChannelAssignment> _savedAssign = const <int, ChannelAssignment>{};
  List<InputAssignment>? _savedInputs;
  List<InputAssignment> _inputs = const <InputAssignment>[];
  bool _safetyDirty = false;
  bool _boardHasDevices = false;
  bool _safetySupported = false;
  bool _intrusionSupported = false;
  bool _bridgeSupported = false;

  // Buluttan yapılandırma yazımı (Faz 2 WP-C3; tasarım F2.D.5).
  bool _boardCfgCap = false;
  bool _preferCloud = false;
  bool _cloudOffer = false;
  bool _usedCloud = false;
  SafetyApplyResult? _queued;
  bool _unconfirmed = false;

  /// Bulut kuyruğunda bekleyen değişiklik sayısı: kayıt yapılmadı, "iptal edip baştan sırala" onayı bekleniyor (guvenlik-4).
  int? _queueReplaceOffer;

  /// Çevrimdışı kuyrukta zincir geçersiz çıktı ve kısmi kuyruk geri alındı: "Planı Yeniden Gönder" sunulur (guvenlik-4).
  bool _resendOffer = false;
  int _exitDelay = kDefaultExitDelaySec;
  int _entryDelay = kDefaultEntryDelaySec;
  bool _extEnabled = false;
  int? _extAddress;
  List<SafetyTestResult> _testResults = const <SafetyTestResult>[];

  List<RelayCheck> get relays => _relays;
  bool get loaded => _loaded;

  TemplateRef? _boardTemplate;

  /// Panoda yüklü kurulum şablonu (durumdaki `tpl`; firmware v1.3.0+, şablon yoksa `null`).
  TemplateRef? get boardTemplate => _boardTemplate;

  /// Şablon panoya uygulandı (İP-4.3): bu adımın test ilerlemesi, kayıttaki atamalar ve bulut yazım durumu bırakılır;
  /// sonraki [load] röle adlarını, türlerini ve güvenlik atamalarını panonun (şablonun) yeni değerlerinden okur.
  /// Dönüş: sunucu kuyruğunda bekleyen güvenlik değişikliği vardı (çağıran [dropQueuedSafetyQuietly] ile siler; şablon
  /// güvenlik tablosunu tamamen değiştirdiği için eski yamalar sonradan üstüne uygulanmamalı).
  bool resetForTemplate() {
    final hadQueued = _queued != null;
    _queued = null;
    _preferCloud = false;
    _relays = const <RelayCheck>[];
    _shutterRelays = const <RelayItem>[];
    _loaded = false;
    _saved = const <int, String>{};
    _savedAssign = const <int, ChannelAssignment>{};
    _savedInputs = null;
    _inputs = const <InputAssignment>[];
    _safetyDirty = false;
    _boardHasDevices = false;
    _cloudOffer = false;
    _usedCloud = false;
    _unconfirmed = false;
    _queueReplaceOffer = null;
    _resendOffer = false;
    _testResults = const <SafetyTestResult>[];
    clearProblem();
    return hadQueued;
  }

  /// Sunucu kuyruğundaki bekleyen güvenlik yamalarını siler (`DELETE …/safety-config/pending`); en iyi çaba: hedef yoksa
  /// ya da istek başarısızsa sessizce geçilir.
  Future<void> dropQueuedSafetyQuietly() async {
    final t = ctx.target;
    if (t == null) return;
    try {
      await ctx.cloud.clearSafetyConfigPending(t.homeId, t.deviceUuid);
    } on Exception {
      // Kuyruk silinemedi: pano yeni şablonla çalışır; kurulumcu gerekirse "Kuyruğu iptal et" ile sürdürür.
    }
  }

  List<RelayItem> _shutterRelays = const <RelayItem>[];

  /// Panoda panjura ayrılmış röleler (numara sırasıyla). Listede bilgi kartı olarak görünür (saha geri bildirimi
  /// 2026-10-08: "Röle 1-4 neden yok?"), ama burada komut gönderilmez ve sayaçlara katılmaz: yukarı/aşağı röleleri
  /// tek tek sürmek motoru zorlayabilir; Adım 8'de panjur olarak test edilir.
  List<RelayItem> get shutterRelays => _shutterRelays;

  /// Girişler: panonun DI'leri (sırayla) + eklenen kablosuz (köprü) yuvaları.
  List<InputAssignment> get inputs => _inputs;

  /// Pano güvenlik modülünü destekliyor mu (`caps` içinde `safety`; v1.2.0+).
  bool get safetySupported => _safetySupported;

  /// Pano hırsız alarmı katmanını destekliyor mu (`caps` `intrusion`; v1.2.1+). Değilse kapı/pencere bayrakları,
  /// alarm anahtarı rolü ve gecikmeler gösterilmez ve panoya yazılmaz (F2.B.7).
  bool get intrusionSupported => _intrusionSupported;

  /// Pano kablosuz (köprü) sensör sürücüsünü ilan ediyor mu (`caps` `bridge`; sözleşme C1). Değilse kablosuz sensör
  /// eklenmez; kayıtlı olan uyarıyla gösterilir ve kaldırılana dek plan yazılamaz.
  bool get bridgeSupported => _bridgeSupported;
  /// Pano `caps` `cfg` ilan ediyor ve hedef (ev + pano) belli: bulut yazımı mümkün. Sihirbaz erişimi (servis
  /// personeli, servis oturumu, süper kullanıcı) sunucu `safety_config` yeteneğinin içindedir (F2.D.4).
  bool get cloudConfigAllowed => _boardCfgCap && ctx.target != null;

  /// LAN `403 local_loosen_forbidden` döndü ve bulut mümkün: arayüz "İnternet üzerinden uygulansın mı?" sorar.
  bool get cloudOffer => _cloudOffer;

  /// Son kayıt bulut taşımasıyla yapıldı.
  bool get usedCloud => _usedCloud;

  /// Pano çevrimdışıydı: yamalar sunucu kuyruğunda (adım tamamlanmaz; F2.D.5).
  SafetyApplyResult? get queued => _queued;

  /// Pano 10 sn içinde yanıt vermedi (`202 applied:null`): sonuç state'te görünecek.
  bool get unconfirmed => _unconfirmed;

  /// Bulut kuyruğunda bekleyen değişiklik sayısı (kayıt yapılmadı; onay bekleniyor).
  int? get queueReplaceOffer => _queueReplaceOffer;

  /// Kısmi kuyruk geri alındı: plan baştan yeniden gönderilebilir.
  bool get resendOffer => _resendOffer;

  void dismissQueueReplaceOffer() {
    if (_queueReplaceOffer == null) return;
    _queueReplaceOffer = null;
    ctx.notify();
  }

  /// Bekleyen bulut kuyruğunu iptal edip planı baştan (panonun güncel yapılandırmasından, `base_rev = state_rev`) gönderir
  /// (guvenlik-4).
  Future<bool> replaceQueuedSafety() async {
    final ok = await run('Bekleyen değişiklikler iptal ediliyor', () async {
      final t = ctx.requireTarget;
      await ctx.cloud.clearSafetyConfigPending(t.homeId, t.deviceUuid);
      _queued = null;
      _queueReplaceOffer = null;
    });
    if (!ok) return false;
    return saveSafety();
  }

  /// Bulut önerisi onaylandı: planın kalanı bulut taşımasıyla sürer.
  void useCloudTransport() {
    _preferCloud = true;
    _cloudOffer = false;
    ctx.notify();
  }

  void dismissCloudOffer() {
    if (!_cloudOffer) return;
    _cloudOffer = false;
    ctx.notify();
  }

  /// Bekleyen (kuyruklanmış) yapılandırma değişikliklerini iptal eder (`DELETE …/safety-config/pending`).
  Future<bool> cancelQueuedSafety() => run('Bekleyen değişiklikler iptal ediliyor', () async {
        final t = ctx.requireTarget;
        await ctx.cloud.clearSafetyConfigPending(t.homeId, t.deviceUuid);
        _queued = null;
        _queueReplaceOffer = null;
      });

  /// Sunucu kuyruğunda bekleyen değişiklik varsa "Kuyruğu iptal et" görünsün diye kuyruk durumu benimsenir (guvenlik-4:
  /// `CONFIG_PENDING` / `CONFIG_QUEUE_FULL`). En iyi çaba.
  Future<void> _adoptServerQueue() async {
    try {
      final t = ctx.requireTarget;
      final data = await ctx.cloud.safetyConfig(t.homeId, t.deviceUuid);
      if ((asList(data['pending']) ?? const <dynamic>[]).isNotEmpty) {
        _queued = const SafetyApplyResult(rev: 0, queued: true);
        ctx.persist();
      }
    } on Exception {
      // Okunamadı: hata mesajı yeterli.
    }
  }

  /// Panonun sunucudaki çevrimiçi bilgisi (en iyi çaba; `null` = bilinmiyor).
  Future<bool?> _boardOnlineHint() async {
    try {
      final t = ctx.requireTarget;
      final devices = await ctx.cloud.devices(t.homeId);
      for (final d in devices) {
        if (d.deviceUuid.toUpperCase() == t.deviceUuid.toUpperCase()) return d.online;
      }
    } on Exception {
      // Bilinmiyor.
    }
    return null;
  }

  /// Adım yeniden açılınca kuyruk durumu sunucudan okunur (F2.D.5); kuyruk boşaldıysa not kalkar. En iyi çaba.
  Future<void> _refreshQueue() async {
    if (_queued == null || !cloudConfigAllowed) return;
    try {
      final t = ctx.requireTarget;
      final data = await ctx.cloud.safetyConfig(t.homeId, t.deviceUuid); // tek okuma: yükleme bekletilmez
      if ((asList(data['pending']) ?? const <dynamic>[]).isEmpty) _queued = null;
    } on Exception {
      // Okunamadı: not kalır (kurulumcu "Kuyruğu iptal et" ya da yeniden kaydet ile sürdürür).
    }
  }

  SafetyConfigTransport _transportFor({required bool cloud}) {
    if (!cloud) {
      return LanSafetyConfigTransport(
        readConfig: () => ctx.deviceCall((api) => api.fetchSafetyConfig()),
        applyPatches: (patches, baseRev) =>
            ctx.deviceCall((api) => api.applySafetyConfigPatches(patches, baseRev: baseRev)),
      );
    }
    final t = ctx.requireTarget;
    return CloudSafetyConfigTransport(
      cloud: ctx.cloud,
      homeId: t.homeId,
      deviceId: t.deviceUuid,
      clock: ctx.clock,
      delay: (d) async {
        await ctx.delay(d);
        ctx.ensureActive();
      },
    );
  }

  /// Planı taşımayla yazar; `CONFIG_CHANGED_ON_DEVICE` olursa kopyanın yeni sürüme ulaşmasını bekler, planı YENİDEN
  /// HESAPLAR (fark tabanlı) ve bir kez daha dener; ikinci çakışma kullanıcıya gösterilir (F2.D.3).
  Future<SafetyApplyResult> _writePlan(SafetyConfigTransport transport) async {
    var current = await transport.read();
    for (var attempt = 0; ; attempt++) {
      // Bulutta bekleyen değişiklik varken yeni plan kuyruğun sonuna eklenmez: bayat kopyadan hesaplanan plan, kuyruk
      // uygulanınca beklenmedik sonuç verir (guvenlik-4). Kullanıcı onaylarsa kuyruk silinip plan baştan gönderilir.
      if (transport is CloudSafetyConfigTransport && transport.pending.isNotEmpty) {
        throw _QueueReplaceNeeded(transport.pending.length);
      }
      final patches = buildSafetyPatches(
        current: current,
        channels: assignments,
        inputs: _inputs,
        extEnabled: _extEnabled,
        extAddress: _extAddress,
        intrusion: _intrusionSupported,
        intrusionDelays: (exit: _exitDelay, entry: _entryDelay),
      );
      // base_rev planın hesaplandığı kopyanın rev'idir (bekleyen kuyruk yok: yukarıda). Kopya bayatsa sunucu/pano 409 döner;
      // bayat plan daha yeni bir base_rev ile gönderilmez (R3).
      final baseRev = asInt(current['rev']) ?? 0;
      try {
        // Tek öğelik yamalar sırayla (her biri bir öncekinin `rev`'iyle; CONTRACTS §2.6).
        return await transport.apply(patches, baseRev: baseRev);
      } on SafetyConfigConflict catch (e) {
        if (attempt > 0 || e.rolledBack) {
          // Çevrimdışı kuyrukta zincir geçersiz: kısmi kuyruk geri alındı; otomatik yeniden deneme yok, kullanıcıya
          // "yeniden gönder" sunulur (guvenlik-4).
          if (e.rolledBack) _resendOffer = true;
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano yapılandırması değişti',
            why: e.message,
            todo: e.rolledBack
                ? 'Kuyruğa alınan kısmi değişiklikler iptal edildi. "Planı Yeniden Gönder" ile planı baştan gönderin.'
                : 'Panodaki son değişikliği kontrol edip yeniden kaydedin.',
          ));
        }
        current = await transport.read(minRev: e.rev);
      }
    }
  }
  int get exitDelay => _exitDelay;
  int get entryDelay => _entryDelay;

  /// Çıkış / giriş gecikmesi (sn, 1..255; F2.B.1).
  void setIntrusionDelays({int? exit, int? entry}) {
    final nextExit = (exit ?? _exitDelay).clamp(1, 255);
    final nextEntry = (entry ?? _entryDelay).clamp(1, 255);
    if (nextExit == _exitDelay && nextEntry == _entryDelay) return;
    _exitDelay = nextExit;
    _entryDelay = nextEntry;
    _changedSafety();
  }
  bool get extEnabled => _extEnabled;
  int? get extAddress => _extAddress;

  /// Son kayıttaki bölge testlerinin sonuçları.
  List<SafetyTestResult> get testResults => _testResults;

  Map<int, ChannelAssignment> get assignments => <int, ChannelAssignment>{for (final r in _relays) r.id: r.assign};

  List<SafetyIssue> get safetyIssues => validateSafetyPlan(assignments, _inputs, bridgeSupported: _bridgeSupported);
  List<SafetyIssue> get blockingIssues => <SafetyIssue>[for (final i in safetyIssues) if (i.blocking) i];

  /// Panoya yazılmamış değişiklik var (dimmer dahil).
  bool get safetyDirty => _safetyDirty;

  /// Güvenlik cihazı ataması panoya yazılmadı: adım tamamlanmaz.
  bool get needsSafetySave => _safetyDirty && (hasSafetyDevices(assignments, _inputs) || _boardHasDevices);

  /// Kaydet düğmesi anlamlı mı (panoya yazılacak bir şey ve değişiklik ya da başarısız bölge testi var; servis_kurulum-2).
  bool get canSaveSafety =>
      (_safetyDirty || _testResults.any((t) => t.failed)) && (hasSafetyPlan(assignments, _inputs) || _boardHasDevices);

  /// İki röleli vanaların açma röleleri (kanal -> vana kanalı): bu kanalların kendi kullanım sorusu kilitlidir.
  Map<int, int> get openRelayOwners => openRelayOwnersOf(assignments);

  int get okCount => _relays.where((r) => r.verdict == RelayVerdict.ok).length;
  int get unusedCount => _relays.where((r) => r.verdict == RelayVerdict.unused).length;
  int get problemCount => _relays.where((r) => r.verdict == RelayVerdict.problem).length;
  int get untestedCount => _relays.where((r) => r.verdict == RelayVerdict.untested).length;

  /// Yalnız panjur rölesi olan panoda (lamba / darbe rölesi yok) röleler 8. adımda panjur olarak test edilir: adım listesiz
  /// tamamlanır (servis_kurulum-6).
  @override
  bool get isComplete =>
      _loaded &&
      (_relays.isEmpty
          ? _shutterRelays.isNotEmpty
          : (okCount >= 1 && _relays.every((r) => r.verdict == RelayVerdict.ok || r.verdict == RelayVerdict.unused))) &&
      !needsSafetySave &&
      !_testResults.any((t) => t.failed);

  RelayCheck? byId(int id) {
    for (final r in _relays) {
      if (r.id == id) return r;
    }
    return null;
  }

  void _put(RelayCheck next) {
    _relays = <RelayCheck>[
      for (final r in _relays) r.id == next.id ? next : r,
    ];
  }

  RelayCheck _fromDevice(RelayItem item, ChannelAssignment assign) {
    final base = RelayCheck(
      id: item.id,
      name: item.name,
      isImpulse: item.isImpulse,
      state: item.state,
      assign: assign,
      boardActuator: item.isActuator,
    );
    switch (_saved[item.id]) {
      case 'ok':
        return base.copyWith(sawOn: true, sawOff: true, lit: true);
      case 'visual':
        // Darbe rölesi: pano geri bildirimi yoktu, teknisyen gözle doğruladı.
        return base.copyWith(cmdSent: true, lit: true);
      case 'unused':
        return base.copyWith(unused: true);
      case 'problem':
        return base.copyWith(problem: true);
    }
    return base;
  }

  /// Panodan röle listesini okur (test ilerlemesi korunur). Güvenlik eylemcisi olarak tanımlı kanallar da listelenir
  /// (bölge testiyle doğrulanır); panjur röleleri hariçtir. Eylemcisiz panoda liste bugünkü `controllableRelays` ile
  /// birebir aynıdır.
  Future<bool> load() => run('Röleler panodan okunuyor', () async {
        final status = await ctx.deviceCall((api) => api.fetchStatus());
        _boardTemplate = status.template;
        final skip = status.shutterRelayIds;
        _shutterRelays = List<RelayItem>.unmodifiable(
          status.relays.where((r) => skip.contains(r.id)).toList()..sort((a, b) => a.id.compareTo(b.id)),
        );
        final items = status.relays
            .where((r) => (r.isLight || r.isImpulse) && !skip.contains(r.id))
            .toList(growable: false);
        // Yalnız panjur rölesi olan pano hata değildir (servis_kurulum-6): röleler 8. adımda panjur olarak test edilir.
        if (items.isEmpty && _shutterRelays.isEmpty) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano röle bildirmedi',
            why: 'Pano durumunda test edilecek bir röle çıkışı yok (yalnızca panjur olabilir).',
            todo: 'Panonun yapılandırmasını kontrol edin; panjur varsa bir sonraki adımda test edilir. '
                'Röle olması gerekiyorsa panoyu yeniden başlatıp tekrar deneyin.',
          ));
        }
        final board = await _readBoardSafety(status);
        final existing = <int, RelayCheck>{for (final r in _relays) r.id: r};
        _relays = <RelayCheck>[
          for (final item in items)
            existing.containsKey(item.id)
                ? existing[item.id]!.copyWith(state: item.state)
                : _fromDevice(item, _savedAssign[item.id] ?? board.channels[item.id] ?? ChannelAssignment.none),
        ];
        _inputs = _mergeInputs(status, board.inputs);
        _boardHasDevices = hasSafetyDevices(board.channels, board.inputs);
        _loaded = true;
        await _refreshQueue();
      });

  /// Panonun güvenlik yeteneği, ek modül adresi ve mevcut güvenlik yapılandırması (en iyi çaba: okunamazsa boş).
  /// Öncelik: yapılandırma kopyası (`GET /api/safety/config`) > `state` özeti (`actuators[]`, `sensors[]`).
  Future<({Map<int, ChannelAssignment> channels, List<InputAssignment> inputs})> _readBoardSafety(
    DeviceStatus status,
  ) async {
    _safetySupported = status.safety.supported;
    _intrusionSupported = status.safety.supportsIntrusion;
    _bridgeSupported = status.safety.supportsBridge;
    _boardCfgCap = status.safety.caps.contains('cfg');
    _extEnabled = status.extModuleEnabled ?? false;
    if (_extEnabled) {
      try {
        final cfg = await ctx.deviceCall((api) => api.fetchConfig());
        _extAddress = asInt(cfg['ext_module_address']);
      } on LocalApiException {
        _extAddress = null;
      }
    }
    final channels = <int, ChannelAssignment>{};
    final inputs = <InputAssignment>[];
    if (!_safetySupported) return (channels: channels, inputs: inputs);
    for (final a in status.safety.actuators) {
      channels[a.relay] = ChannelAssignment.fromBoard(<String, dynamic>{
        'kind': a.kind.wire,
        'medium': a.medium,
        'zones': a.zones,
      });
    }
    for (final sensor in status.safety.sensors) {
      final input = InputAssignment.fromBoard(<String, dynamic>{
        'id': sensor.id,
        'src': sensor.src,
        'kind': sensor.kind,
        'zone': sensor.zone,
      });
      if (input != null) inputs.add(input);
    }
    try {
      final cfg = await ctx.deviceCall((api) => api.fetchSafetyConfig());
      final intrusion = asMap(cfg['intrusion']);
      if (intrusion != null && !_safetyDirty) {
        final exit = asInt(intrusion['exit_s']);
        final entry = asInt(intrusion['entry_s']);
        _exitDelay = (exit == null || exit <= 0) ? kDefaultExitDelaySec : exit.clamp(1, 255);
        _entryDelay = (entry == null || entry <= 0) ? kDefaultEntryDelaySec : entry.clamp(1, 255);
      }
      for (final raw in asList(cfg['actuators']) ?? const <dynamic>[]) {
        final map = asMap(raw);
        final relay = map == null ? null : asInt(map['relay']);
        if (map != null && relay != null) channels[relay] = ChannelAssignment.fromBoard(map);
      }
      final fromCfg = <InputAssignment>[];
      for (final raw in asList(cfg['sensors']) ?? const <dynamic>[]) {
        final map = asMap(raw);
        final input = map == null ? null : InputAssignment.fromBoard(map);
        if (input != null) fromCfg.add(input);
      }
      if (fromCfg.isNotEmpty) {
        inputs
          ..clear()
          ..addAll(fromCfg);
      }
      for (final raw in asList(cfg['lights']) ?? const <dynamic>[]) {
        final map = asMap(raw);
        final relay = map == null ? null : asInt(map['relay']);
        if (map == null || relay == null || asBool(map['dimmable']) != true) continue;
        // Firmware `src`: 1 = Modbus, 2 = köprü (CONTRACTS §2.6); eski taslak `dimmer_src` metni de okunur.
        final src = asInt(map['src']) == 2 ? DimmerSource.bridge : DimmerSource.parse(map['dimmer_src']);
        channels[relay] = (channels[relay] ?? ChannelAssignment.none).copyWith(wantsDimming: true, dimmerSource: src);
      }
    } on LocalApiException {
      // Yapılandırma kopyası okunamadı: state özetiyle sürdürülür.
    }
    return (channels: channels, inputs: inputs);
  }

  /// Girişler: panonun DI'leri sırayla (önceki yükleme > kayıt > pano > duvar butonu) + köprü yuvaları.
  List<InputAssignment> _mergeInputs(DeviceStatus status, List<InputAssignment> board) {
    final saved = _savedInputs;
    final previous = <String, InputAssignment>{for (final i in _inputs) i.id: i};
    InputAssignment? find(List<InputAssignment>? list, String id) {
      if (list == null) return null;
      for (final i in list) {
        if (i.id == id) return i;
      }
      return null;
    }

    final out = <InputAssignment>[
      for (final di in status.dis)
        previous['d${di.id}'] ??
            find(saved, 'd${di.id}') ??
            find(board, 'd${di.id}') ??
            InputAssignment(src: 'di', index: di.id),
    ];
    final bridges = <InputAssignment>[
      for (final i in _inputs.isNotEmpty ? _inputs : (saved ?? board))
        if (i.isBridge) i,
    ]..sort((a, b) => a.index.compareTo(b.index));
    return List<InputAssignment>.unmodifiable(<InputAssignment>[...out, ...bridges]);
  }

  void _changedSafety() {
    _safetyDirty = true;
    _testResults = const <SafetyTestResult>[];
    ctx.notify();
    ctx.persist();
  }

  /// Kanal atamasını değiştirir. Vana geri bildirim girişi seçildiyse o giriş "Vana geri bildirimi" olarak işaretlenir.
  void setAssignment(int id, ChannelAssignment next) {
    final r = byId(id);
    if (r == null || r.assign == next) return;
    final fb = next.isValve ? next.fbDi : null;
    if (fb != null) {
      _inputs = List<InputAssignment>.unmodifiable(<InputAssignment>[
        for (final i in _inputs)
          (!i.isBridge && i.index == fb) ? i.copyWith(role: InputRole.valveFeedback) : i,
      ]);
    }
    _put(r.copyWith(assign: next));
    _changedSafety();
  }

  /// Bir girişin rolünü / kontak tipini / bölgesini değiştirir (gaz/duman NC'ye zorlanır).
  void setInput(InputAssignment next) {
    final normalized = next.normalized();
    var changed = false;
    final out = <InputAssignment>[];
    for (final i in _inputs) {
      if (i.id == normalized.id) {
        changed = i != normalized;
        out.add(normalized);
      } else {
        out.add(i);
      }
    }
    _inputs = List<InputAssignment>.unmodifiable(out);
    if (changed) _changedSafety();
  }

  /// Boş ilk köprü (Zigbee/Thread hub) yuvasına kablosuz su sensörü ekler (K2). Yuvalar doluysa ya da pano kablosuz
  /// sensörü desteklemiyorsa (`caps` `bridge` yok; sözleşme C1) bir şey yapmaz.
  void addBridgeSensor() {
    if (!_bridgeSupported) return;
    final used = <int>{
      for (final i in _inputs)
        if (i.isBridge) i.index,
    };
    for (var slot = 1; slot <= kMaxBridgeSlots; slot++) {
      if (used.contains(slot)) continue;
      _inputs = List<InputAssignment>.unmodifiable(<InputAssignment>[
        ..._inputs,
        InputAssignment(src: 'bridge', index: slot, role: InputRole.water),
      ]);
      _changedSafety();
      return;
    }
  }

  /// Kablosuz yuvayı kaldırır.
  void removeBridgeSensor(int slot) {
    final before = _inputs.length;
    _inputs = List<InputAssignment>.unmodifiable(<InputAssignment>[
      for (final i in _inputs)
        if (!(i.isBridge && i.index == slot)) i,
    ]);
    if (_inputs.length != before) _changedSafety();
  }

  /// K4 yönergesi: [id] kanalı için dimmer çıkışı = dimmer isteyen kanallar arasındaki sırası (+1).
  DimmerGuide dimmerGuide(int id) {
    final ids = <int>[
      for (final r in _relays)
        if (r.assign.isDimmable || r.id == id) r.id,
    ]..sort();
    return dimmerGuideFor(
      relay: id,
      dimmerChannel: ids.indexOf(id) + 1,
      extEnabled: _extEnabled,
      extAddress: _extAddress,
    );
  }

  /// Planı panoya yazar ve eylemcili her bölgede bir `alarm_test` çalıştırır (§4.4 madde 3).
  Future<bool> saveSafety() => run('Güvenlik ayarları panoya yazılıyor', () async {
        final blocking = blockingIssues;
        if (blocking.isNotEmpty) {
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Güvenlik ayarları eksik',
            why: blocking.first.message,
            todo: 'İşaretli soruları yanıtlayıp yeniden kaydedin.',
            retryable: false,
          ));
        }
        _cloudOffer = false;
        _unconfirmed = false;
        _queueReplaceOffer = null;
        _resendOffer = false;
        // Seçim kuralı (K5: yerel öncelikli): LAN erişilebilirse LAN; değilse yetki + `caps cfg` varsa bulut. Bu kurulumun
        // bulut kuyruğu bekliyorsa yeni plan da buluttan, kuyruğu değiştirme onayıyla gider (guvenlik-4).
        var cloud = (_preferCloud || _queued != null) && cloudConfigAllowed;
        if (!cloud) {
          try {
            final status = await ctx.deviceCall((api) => api.fetchStatus());
            _safetySupported = status.safety.supported;
            _intrusionSupported = status.safety.supportsIntrusion;
            _bridgeSupported = status.safety.supportsBridge;
            _boardCfgCap = status.safety.caps.contains('cfg');
          } on LocalApiException catch (e) {
            if (!e.isNetwork) rethrow;
            if (!cloudConfigAllowed) {
              throw const SetupProblemException(SetupProblem(
                kind: SetupProblemKind.deviceNetwork,
                title: 'Panoya ulaşılamadı',
                why: 'Yapılandırma için panoya yerel ağdan bağlanın ya da yetkili bir hesapla internet üzerinden deneyin.',
                todo: 'Telefonu panonun ağına bağlayıp yeniden deneyin.',
              ));
            }
            cloud = true;
          }
        }
        if (!_safetySupported) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano yazılımı güvenlik modülünü desteklemiyor',
            why: 'Bu pano yazılımı güvenlik modülünü desteklemiyor, v1.2.0\'a güncelleyin.',
            todo: 'Pano yazılımını v1.2.0 ya da üstüne güncelleyin; o zamana kadar bu kanalları "Lamba / priz" olarak bırakın.',
            retryable: false,
          ));
        }
        final transport = _transportFor(cloud: cloud);
        if (transport is CloudSafetyConfigTransport) transport.deviceOnline = await _boardOnlineHint();
        SafetyApplyResult result;
        try {
          result = await _writePlan(transport);
        } on _QueueReplaceNeeded catch (e) {
          // Kayıt yapılmadı: arayüz "Bekleyen N değişiklik iptal edilip plan baştan sıraya alınsın mı?" diye sorar.
          _queueReplaceOffer = e.count;
          return;
        } on SafetyQueueLimitExceeded catch (e) {
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Çevrimdışı kuyruk sınırı aşıldı',
            why: e.message,
            todo: 'Telefonu panonun ağına bağlayıp planı yerel ağdan yazın.',
            retryable: false,
          ));
        } on ApiException catch (e) {
          if (transport.isCloud && (e.code == 'CONFIG_PENDING' || e.code == 'CONFIG_QUEUE_FULL')) await _adoptServerQueue();
          rethrow;
        } on LocalApiException catch (e) {
          // Yerel anahtarla gevşetme yasak (7.2b-7): yetkili hesapla bulut önerilir (F2.D.5).
          if (e.code == 'local_loosen_forbidden' && cloudConfigAllowed) {
            _cloudOffer = true;
            return;
          }
          rethrow;
        }
        _usedCloud = transport.isCloud;
        if (result.queued) {
          // Pano çevrimdışı: 24 sa içinde uygulanacak; adım TAMAMLANMAZ (panoya yazılmış olmak koşuldur).
          _queued = result;
          ctx.persist();
          return;
        }
        _queued = null;
        if (result.unconfirmed) {
          _unconfirmed = true;
          ctx.persist();
          return;
        }
        _preferCloud = false;
        _safetyDirty = false;
        _boardHasDevices = hasSafetyDevices(assignments, _inputs);
        _testResults = const <SafetyTestResult>[];
        ctx.persist();

        final zones = <int>{
          for (final a in assignments.values)
            if (a.use.isActuator) a.zone,
        }.toList()
          ..sort();
        final results = <SafetyTestResult>[];
        for (final zone in zones) {
          final hasValve = assignments.values.any((a) => a.isValve && a.zone == zone);
          results.add(transport.isCloud
              ? await _runCloudZoneTest(zone, hasValve: hasValve)
              : await _runZoneTest(zone, hasValve: hasValve));
        }
        _testResults = List<SafetyTestResult>.unmodifiable(results);
        final failed = results.where((t) => t.failed).toList();
        // Başarısızlık / doğrulanamayan geri bildirim kayda yazılır (servis_kurulum-2): kayıttan devamda adım tamamlanmış
        // sayılmaz.
        if (failed.isNotEmpty) ctx.persist();
        if (failed.isNotEmpty) {
          throw SetupProblemException(_zoneTestProblem(
            failed,
            todo: 'Vana kablolamasını, kapanma kipi yanıtını ve geri bildirim kontağını kontrol edip yeniden kaydedin.',
          ));
        }
      });

  /// Geçmeyen bölge testleri için sorun: kesin "kapanmadı" sonucu önce; yoksa geri bildirim sonucu alınamadı
  /// (servis_kurulum-2).
  SetupProblem _zoneTestProblem(List<SafetyTestResult> notPassed, {required String todo}) {
    for (final t in notPassed) {
      if (t.ok == false) {
        return SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Vana testte kapanmadı',
          why: t.message,
          todo: todo,
        );
      }
    }
    return SetupProblem(
      kind: SetupProblemKind.timeout,
      title: 'Vana test sonucu alınamadı',
      why: notPassed.first.message,
      todo: 'Panonun yerel ağ bağlantısını kontrol edip bölge testini yeniden çalıştırın; vana kapanmıyorsa kablolamayı ve '
          'geri bildirim kontağını kontrol edin.',
    );
  }

  /// Bulutta bölge testi (`POST …/alarm-test`): sonuç sunucuda saklanmaz (karar F2-10); yalnız gönderim doğrulanır.
  Future<SafetyTestResult> _runCloudZoneTest(int zone, {required bool hasValve}) async {
    final t = ctx.requireTarget;
    final id = 'tst${ctx.clock.now().microsecondsSinceEpoch.toRadixString(36)}$zone';
    await ctx.cloud.alarmTest(homeId: t.homeId, deviceId: t.deviceUuid, zone: zone, commandId: id);
    return SafetyTestResult(zone: zone, hasValve: hasValve, cloud: true);
  }

  /// Geri bildirimsiz bölgede test sonucunun beklenme süresi (firmware sonucu ~5 sn'de verir).
  static const Duration _zoneTestWait = Duration(seconds: 15);

  /// Geri bildirimli vanada `fb_timeout_s` üstüne pay (pano döngüsü + olay halkası yoklaması).
  static const Duration _zoneTestFeedbackSlack = Duration(seconds: 5);

  /// Firmware varsayılan geri bildirim süresi (`FB_TIMEOUT_DEFAULT_S`; `fb_timeout_s` 0 ya da yoksa).
  static const int _feedbackTimeoutDefaultSec = 60;

  /// Bölgedeki geri bildirimli (`fb_di`) vanaların en uzun geri bildirim süresi (firmware `SafetyFsm.stepTest`:
  /// `fb_timeout_s`, 0 / yoksa 60 sn); bölgede geri bildirimli vana yoksa `null`. Kaynak panonun GÜNCEL yapılandırma
  /// kopyasıdır (testi pano kendi yapılandırmasıyla yürütür); okunamazsa plan (geri bildirim girişi seçili vana ->
  /// varsayılan süre).
  Future<Duration?> _zoneFeedbackTimeout(int zone) async {
    List<dynamic>? actuators;
    try {
      actuators = asList((await ctx.deviceCall((api) => api.fetchSafetyConfig()))['actuators']);
    } on LocalApiException {
      actuators = null;
    }
    if (actuators == null) {
      final planned = assignments.values.any((a) => a.isValve && a.zone == zone && a.fbDi != null);
      return planned ? const Duration(seconds: _feedbackTimeoutDefaultSec) : null;
    }
    int? longest;
    for (final raw in actuators) {
      final a = asMap(raw);
      if (a == null || ChannelUse.parse(a['kind']) != ChannelUse.valve || (asInt(a['fb_di']) ?? 0) <= 0) continue;
      if (!(asList(a['zones']) ?? const <dynamic>[]).any((z) => asInt(z) == zone)) continue;
      final configured = asInt(a['fb_timeout_s']);
      final seconds = (configured == null || configured <= 0) ? _feedbackTimeoutDefaultSec : configured;
      if (longest == null || seconds > longest) longest = seconds;
    }
    return longest == null ? null : Duration(seconds: longest);
  }

  /// Bölge testini gönderir ve sonucu (`test_result`) panonun olay halkasından okur. Bekleme (servis_kurulum-2): bölgede
  /// geri bildirimli vana varsa en uzun `fb_timeout_s` + 5 sn (pano kapanmayan vanayı ancak bu süre dolunca bildirir),
  /// yoksa 15 sn. Geri bildirimli vananın sonucu gelmezse sonuç "doğrulanmadı"dır ([SafetyTestResult.unconfirmed];
  /// geçmiş sayılmaz).
  Future<SafetyTestResult> _runZoneTest(int zone, {required bool hasValve}) async {
    final feedbackTimeout = await _zoneFeedbackTimeout(zone);
    final hasFeedback = feedbackTimeout != null;
    final valve = hasValve || hasFeedback;
    Set<String> seen;
    try {
      seen = <String>{for (final e in await ctx.deviceCall((api) => api.fetchEvents())) e.eid};
    } on LocalApiException {
      seen = <String>{};
    }
    await ctx.deviceCall((api) => api.testAlarm(zone));
    final wait = hasFeedback ? feedbackTimeout + _zoneTestFeedbackSlack : _zoneTestWait;
    updateBusyLabel(hasFeedback
        ? 'Bölge $zone: vananın kapanması bekleniyor (en çok ${wait.inSeconds} sn)'
        : 'Bölge $zone testi çalıştırılıyor');
    final started = ctx.clock.now();
    final deadline = started.add(wait);
    while (true) {
      ctx.ensureActive();
      try {
        final events = await ctx.deviceCall((api) => api.fetchEvents());
        for (final e in events.reversed) {
          if (e.type == 'test_result' && e.zone == zone && !seen.contains(e.eid)) {
            return SafetyTestResult(zone: zone, ok: e.ok, fbMs: e.fbMs, hasValve: valve, hasFeedback: hasFeedback);
          }
        }
      } on LocalApiException {
        // Olay halkası okunamadı: süre dolana kadar yeniden denenir.
      }
      // İlk 15 sn sık, sonrası seyrek yoklanır (uzun geri bildirim beklemesinde panoyu yormamak için).
      final now = ctx.clock.now();
      final interval = now.difference(started) < _zoneTestWait
          ? const Duration(milliseconds: 750)
          : const Duration(milliseconds: 1500);
      if (!now.add(interval).isBefore(deadline)) break;
      await ctx.delay(interval);
    }
    return SafetyTestResult(zone: zone, hasValve: valve, hasFeedback: hasFeedback);
  }

  /// Panoda tanımlı eylemcinin doğrulaması: bölge testi (vana kapanır, siren kısa çalar); sonucu teknisyen gözle teyit
  /// eder ([confirmLit]). Düz röle komutu eylemci kanalında açma yönünde reddedileceği için kullanılmaz.
  Future<bool> testActuator(int id) => run('Bölge testi gönderiliyor', () async {
        final current = byId(id);
        if (current == null || !current.boardActuator) return;
        final zone = current.assign.zone;
        // Test gönderilir ve sonucu (`test_result`) olay halkasından okunur (servis_kurulum-2): geri bildirim "kapanmadı"
        // derse ya da geri bildirimli vananın sonucu alınamazsa gözle onay açılmaz.
        final result = await _runZoneTest(zone, hasValve: current.assign.isValve);
        _putTestResult(result);
        if (result.unconfirmed) {
          // Sonuç yok: vana doğrulanmadı (önceki doğrulama da geçersiz; önceki sorun notu silinmez).
          _put((byId(id) ?? current).copyWith(
            cmdSent: false,
            clearLit: true,
            info: 'Bölge testinin geri bildirim sonucu alınamadı: vana doğrulanmadı. Testi yeniden çalıştırın.',
          ));
          ctx.persist();
          throw SetupProblemException(_zoneTestProblem(
            <SafetyTestResult>[result],
            todo: 'Vana kablolamasını ve geri bildirim kontağını kontrol edip bölge testini yeniden çalıştırın.',
          ));
        }
        if (result.failed) {
          _put((byId(id) ?? current).copyWith(
            cmdSent: false,
            problem: true,
            clearLit: true,
            note: 'Bölge testinde vana kapanmadı (geri bildirim)',
            clearInfo: true,
          ));
          ctx.persist();
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Vana testte kapanmadı',
            why: result.message,
            todo: 'Vana kablolamasını ve geri bildirim kontağını kontrol edip bölge testini yeniden çalıştırın.',
          ));
        }
        _put((byId(id) ?? current).copyWith(
          cmdSent: true,
          problem: false,
          clearNote: true,
          info: 'Bölge testi gönderildi: vananın kapandığını / cihazın çalıştığını gözle doğrulayın. '
              'Test bitince su vanası önceki konumuna döner; gaz vanası kapalı kalır.',
        ));
      });

  /// Bir bölgenin test sonucunu kaydeder (aynı bölgenin önceki sonucu değişir). Sonuçsuz test
  /// ([SafetyTestResult.unconfirmed]) önceki "kapanmadı" sonucunu SİLMEZ (servis_kurulum-2): hâlâ takılı vana yanlışlıkla
  /// geçmiş sayılmasın; son kesin sonuç kalır.
  void _putTestResult(SafetyTestResult result) {
    if (result.unconfirmed && _testResults.any((t) => t.zone == result.zone && t.ok == false)) return;
    _testResults = List<SafetyTestResult>.unmodifiable(
      <SafetyTestResult>[
        for (final t in _testResults)
          if (t.zone != result.zone) t,
        result,
      ]..sort((a, b) => a.zone.compareTo(b.zone)),
    );
  }

  /// Yalnız geçmeyen (başarısız ya da doğrulanamayan) bölgelerin testini yeniden çalıştırır (servis_kurulum-2); kesin
  /// sonuç kaydı günceller, sonuçsuz yeniden test önceki başarısızlığı silmez.
  Future<bool> retestFailedZones() => run('Bölge testi yeniden çalıştırılıyor', () async {
        final failed = <int>{
          for (final t in _testResults)
            if (t.failed) t.zone,
        }.toList()
          ..sort();
        final fresh = <SafetyTestResult>[];
        for (final zone in failed) {
          final hasValve = assignments.values.any((a) => a.isValve && a.zone == zone);
          final result = await _runZoneTest(zone, hasValve: hasValve);
          fresh.add(result);
          _putTestResult(result);
        }
        ctx.persist();
        final still = fresh.where((t) => t.failed).toList();
        if (still.isNotEmpty) {
          throw SetupProblemException(_zoneTestProblem(
            still,
            todo: 'Vana kablolamasını, kapanma kipi yanıtını ve geri bildirim kontağını kontrol edip yeniden deneyin.',
          ));
        }
      });

  /// Röleyi açar/kapatır ve panonun gerçek geri bildirimini bekler.
  Future<bool> command(int id, bool on) => run(on ? 'Röle açılıyor' : 'Röle kapatılıyor', () async {
        final current = byId(id);
        if (current == null) return;
        if (current.boardActuator) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Güvenlik cihazı röle komutuyla denenmez',
            why: 'Bu kanal panoda güvenlik cihazı olarak tanımlı; açma yönündeki röle komutunu pano reddeder.',
            todo: '"Bölge Testi" ile deneyin.',
            retryable: false,
          ));
        }
        await ctx.deviceCall((api) => api.setRelay(id, on));
        final interval = current.isImpulse ? const Duration(milliseconds: 150) : const Duration(milliseconds: 300);
        final status = await ctx.pollStatus(
          (s) => s.relayById(id)?.state == on,
          timeout: const Duration(seconds: 3),
          interval: interval,
        );
        final latest = byId(id) ?? current;
        if (status == null) {
          if (current.isImpulse && on) {
            // Darbe çok kısa olabilir: komut pano tarafından kabul edildi (HTTP 2xx) ama durum yoklamasında
            // görülemedi. Pano geri bildirimi YOKTUR; "çalıştı mı?" teyidi teknisyenin gözlemine bırakılır
            // (bilgi notu düşülür; sorun sayılmaz ve teyit düğmeleri açılır).
            _put(latest.copyWith(
              cmdSent: true,
              info: 'Darbe kısa sürdüğü için pano geri bildirimi görülemedi. Pano komutu kabul etti: '
                  'yükün (kapı, zil vb.) gerçekten çalıştığını gözle doğrulayın.',
            ));
            return;
          }
          _put(latest.copyWith(
            problem: true,
            note: 'Komut gönderildi ama pano röleyi ${on ? 'açmadı' : 'kapatmadı'}.',
          ));
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano röle komutuna cevap vermedi',
            why: 'Komut panoya ulaştı ama ${current.name} rölesi ${on ? 'açık' : 'kapalı'} duruma geçmedi.',
            todo: 'Panjur hareketi ya da çocuk kilidi gibi bir durum engelliyor olabilir; birkaç saniye bekleyip yeniden deneyin. '
                'Olmazsa röle kartını/sigortasını kontrol edin.',
          ));
        }
        _put(latest.copyWith(
          state: on,
          sawOn: on ? true : latest.sawOn,
          sawOff: on ? latest.sawOff : true,
          problem: false,
          clearNote: true,
          clearInfo: true,
        ));
        if (on && current.isImpulse) {
          // Darbe röleleri kendiliğinden kapanır: kapanış da geri bildirim sayılır.
          final off = await ctx.pollStatus(
            (s) => s.relayById(id)?.state == false,
            timeout: const Duration(seconds: 5),
            interval: const Duration(milliseconds: 300),
          );
          if (off != null) _put((byId(id) ?? latest).copyWith(state: false, sawOff: true));
        }
      });

  /// "Yük çalıştı mı?" yanıtı.
  void confirmLit(int id, bool lit) {
    final r = byId(id);
    if (r == null) return;
    _put(r.copyWith(
      lit: lit,
      problem: lit ? false : true,
      note: lit ? null : 'Pano komutu aldı ama yük çalışmadı: klemens bağlantısını ve sigortayı kontrol edin.',
      clearNote: lit,
      clearInfo: !lit,
    ));
    ctx.notify();
    ctx.persist();
  }

  /// Rölenin kullanılmadığını işaretler / geri alır.
  void setUnused(int id, bool unused) {
    final r = byId(id);
    if (r == null) return;
    _put(r.copyWith(unused: unused));
    ctx.notify();
    ctx.persist();
  }

  /// Testi yeniden başlatmak için bir rölenin ilerlemesini sıfırlar.
  void resetRelay(int id) {
    final r = byId(id);
    if (r == null) return;
    _put(RelayCheck(
      id: r.id,
      name: r.name,
      isImpulse: r.isImpulse,
      state: r.state,
      assign: r.assign,
      boardActuator: r.boardActuator,
    ));
    ctx.notify();
    ctx.persist();
  }

  /// Adımdan çıkarken evi güvenli duruma getirmek için tüm lambaları kapatır (en iyi çaba).
  Future<void> allLightsOff() async {
    try {
      await ctx.deviceCall((api) => api.cmdAll('lightsoff'));
    } on LocalApiException {
      // Bağlantı yoksa sessizce vazgeçilir.
    } on SetupProblemException {
      // Pano doğrulanamadı: komut gönderilmez.
    }
  }

  /// Kayıt: güvenlik ataması yoksa bugünkü biçimle BİREBİR aynıdır (yalnız `relays`); `assign` / `inputs` /
  /// `safety_dirty` yalnız doluyken yazılır.
  @override
  Map<String, dynamic> snapshot() {
    final assign = <String, dynamic>{
      if (!_loaded)
        for (final e in _savedAssign.entries) '${e.key}': e.value.toJson()
      else
        for (final r in _relays)
          if (!r.assign.isDefault) '${r.id}': r.assign.toJson(),
    };
    final inputs = <Map<String, dynamic>>[
      for (final i in (!_loaded ? (_savedInputs ?? const <InputAssignment>[]) : _inputs))
        if (i.isBridge || i.role != InputRole.button) i.toJson(),
    ];
    return <String, dynamic>{
      'relays': !_loaded
          ? <String, String>{for (final e in _saved.entries) '${e.key}': e.value}
          : _currentVerdicts(),
      if (assign.isNotEmpty) 'assign': assign,
      if (inputs.isNotEmpty) 'inputs': inputs,
      if (_safetyDirty) 'safety_dirty': true,
      if (_queued != null) 'safety_queued': true,
      // Geçmeyen bölge testi (servis_kurulum-2): kayıttan devamda adım tamamlanmış sayılmaz. "Kapanmadı" ve "geri
      // bildirim sonucu alınamadı" ayrı tutulur (geri yüklenince doğru metin görünsün).
      if (_testResults.any((t) => t.ok == false))
        'safety_failed': <int>[
          for (final t in _testResults)
            if (t.ok == false) t.zone,
        ],
      if (_testResults.any((t) => t.unconfirmed))
        'safety_unconfirmed': <int>[
          for (final t in _testResults)
            if (t.unconfirmed) t.zone,
        ],
    };
  }

  Map<String, String> _currentVerdicts() => <String, String>{
        for (final r in _relays)
          if (r.verdict == RelayVerdict.ok)
            '${r.id}': r.visualOnly ? 'visual' : 'ok'
          else if (r.verdict == RelayVerdict.unused)
            '${r.id}': 'unused'
          else if (r.verdict == RelayVerdict.problem)
            '${r.id}': 'problem',
      };

  @override
  void restore(Map<String, dynamic> json) {
    final assign = asMap(json['assign']);
    if (assign != null) {
      _savedAssign = <int, ChannelAssignment>{
        for (final e in assign.entries)
          if (int.tryParse(e.key) != null) int.parse(e.key): ChannelAssignment.fromJson(e.value),
      };
    }
    final inputs = asList(json['inputs']);
    if (inputs != null) {
      final parsed = <InputAssignment>[];
      for (final raw in inputs) {
        final input = InputAssignment.fromJson(raw);
        if (input != null) parsed.add(input);
      }
      _savedInputs = parsed;
    }
    _safetyDirty = asBool(json['safety_dirty']) ?? _safetyDirty;
    if (asBool(json['safety_queued']) == true) _queued ??= const SafetyApplyResult(rev: 0, queued: true);
    final failed = asList(json['safety_failed']);
    final unconfirmed = asList(json['safety_unconfirmed']);
    if (failed != null || unconfirmed != null) {
      _testResults = List<SafetyTestResult>.unmodifiable(<SafetyTestResult>[
        for (final z in failed ?? const <dynamic>[])
          if (asInt(z) != null) SafetyTestResult(zone: asInt(z)!, ok: false),
        for (final z in unconfirmed ?? const <dynamic>[])
          if (asInt(z) != null) SafetyTestResult(zone: asInt(z)!, hasFeedback: true),
      ]..sort((a, b) => a.zone.compareTo(b.zone)));
    }
    final raw = json['relays'];
    if (raw is Map) {
      _saved = <int, String>{
        for (final e in raw.entries)
          if (int.tryParse(e.key.toString()) != null && e.value is String)
            int.parse(e.key.toString()): e.value as String,
      };
    }
  }
}
