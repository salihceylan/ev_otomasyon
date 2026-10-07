import 'package:flutter/foundation.dart';

import '../../../../models/automation_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'safety_assignment.dart';

export 'safety_assignment.dart';

enum RelayVerdict { untested, ok, problem, unused }

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
  bool _extEnabled = false;
  int? _extAddress;
  List<SafetyTestResult> _testResults = const <SafetyTestResult>[];

  List<RelayCheck> get relays => _relays;
  bool get loaded => _loaded;

  /// Girişler: panonun DI'leri (sırayla) + eklenen kablosuz (köprü) yuvaları.
  List<InputAssignment> get inputs => _inputs;

  /// Pano güvenlik modülünü destekliyor mu (`caps` içinde `safety`; v1.2.0+).
  bool get safetySupported => _safetySupported;
  bool get extEnabled => _extEnabled;
  int? get extAddress => _extAddress;

  /// Son kayıttaki bölge testlerinin sonuçları.
  List<SafetyTestResult> get testResults => _testResults;

  Map<int, ChannelAssignment> get assignments => <int, ChannelAssignment>{for (final r in _relays) r.id: r.assign};

  List<SafetyIssue> get safetyIssues => validateSafetyPlan(assignments, _inputs);
  List<SafetyIssue> get blockingIssues => <SafetyIssue>[for (final i in safetyIssues) if (i.blocking) i];

  /// Panoya yazılmamış değişiklik var (dimmer dahil).
  bool get safetyDirty => _safetyDirty;

  /// Güvenlik cihazı ataması panoya yazılmadı: adım tamamlanmaz.
  bool get needsSafetySave => _safetyDirty && (hasSafetyDevices(assignments, _inputs) || _boardHasDevices);

  /// Kaydet düğmesi anlamlı mı (panoya yazılacak bir şey ve değişiklik var).
  bool get canSaveSafety => _safetyDirty && (hasSafetyPlan(assignments, _inputs) || _boardHasDevices);

  /// İki röleli vanaların açma röleleri (kanal -> vana kanalı): bu kanalların kendi kullanım sorusu kilitlidir.
  Map<int, int> get openRelayOwners => openRelayOwnersOf(assignments);

  int get okCount => _relays.where((r) => r.verdict == RelayVerdict.ok).length;
  int get unusedCount => _relays.where((r) => r.verdict == RelayVerdict.unused).length;
  int get problemCount => _relays.where((r) => r.verdict == RelayVerdict.problem).length;
  int get untestedCount => _relays.where((r) => r.verdict == RelayVerdict.untested).length;

  @override
  bool get isComplete =>
      _loaded &&
      _relays.isNotEmpty &&
      okCount >= 1 &&
      _relays.every((r) => r.verdict == RelayVerdict.ok || r.verdict == RelayVerdict.unused) &&
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
        final skip = status.shutterRelayIds;
        final items = status.relays
            .where((r) => (r.isLight || r.isImpulse) && !skip.contains(r.id))
            .toList(growable: false);
        if (items.isEmpty) {
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
      });

  /// Panonun güvenlik yeteneği, ek modül adresi ve mevcut güvenlik yapılandırması (en iyi çaba: okunamazsa boş).
  /// Öncelik: yapılandırma kopyası (`GET /api/safety/config`) > `state` özeti (`actuators[]`, `sensors[]`).
  Future<({Map<int, ChannelAssignment> channels, List<InputAssignment> inputs})> _readBoardSafety(
    DeviceStatus status,
  ) async {
    _safetySupported = status.safety.supported;
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

  /// Boş ilk köprü (Zigbee/Thread hub) yuvasına kablosuz su sensörü ekler (K2). Yuvalar doluysa bir şey yapmaz.
  void addBridgeSensor() {
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
        final status = await ctx.deviceCall((api) => api.fetchStatus());
        _safetySupported = status.safety.supported;
        if (!_safetySupported) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano yazılımı güvenlik modülünü desteklemiyor',
            why: 'Bu pano yazılımı güvenlik modülünü desteklemiyor, v1.2.0\'a güncelleyin.',
            todo: 'Pano yazılımını v1.2.0 ya da üstüne güncelleyin; o zamana kadar bu kanalları "Lamba / priz" olarak bırakın.',
            retryable: false,
          ));
        }
        final current = await ctx.deviceCall((api) => api.fetchSafetyConfig());
        final patches = buildSafetyPatches(
          current: current,
          channels: assignments,
          inputs: _inputs,
          extEnabled: _extEnabled,
          extAddress: _extAddress,
        );
        // Tek öğelik yamalar sırayla (her biri bir öncekinin `rev`'iyle; CONTRACTS §2.6).
        await ctx.deviceCall((api) => api.applySafetyConfigPatches(patches, baseRev: asInt(current['rev']) ?? 0));
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
          results.add(await _runZoneTest(zone, hasValve: hasValve));
        }
        _testResults = List<SafetyTestResult>.unmodifiable(results);
        final failed = results.where((t) => t.failed).toList();
        if (failed.isNotEmpty) {
          throw SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Vana testte kapanmadı',
            why: failed.first.message,
            todo: 'Vana kablolamasını, kapanma kipi yanıtını ve geri bildirim kontağını kontrol edip yeniden kaydedin.',
          ));
        }
      });

  /// Bölge testini gönderir ve sonucu (`test_result`) panonun olay halkasından okur (en çok 15 sn).
  Future<SafetyTestResult> _runZoneTest(int zone, {required bool hasValve}) async {
    Set<String> seen;
    try {
      seen = <String>{for (final e in await ctx.deviceCall((api) => api.fetchEvents())) e.eid};
    } on LocalApiException {
      seen = <String>{};
    }
    await ctx.deviceCall((api) => api.testAlarm(zone));
    final deadline = ctx.clock.now().add(const Duration(seconds: 15));
    while (true) {
      ctx.ensureActive();
      try {
        final events = await ctx.deviceCall((api) => api.fetchEvents());
        for (final e in events.reversed) {
          if (e.type == 'test_result' && e.zone == zone && !seen.contains(e.eid)) {
            return SafetyTestResult(zone: zone, ok: e.ok, fbMs: e.fbMs, hasValve: hasValve);
          }
        }
      } on LocalApiException {
        // Olay halkası okunamadı: süre dolana kadar yeniden denenir.
      }
      if (!ctx.clock.now().add(const Duration(milliseconds: 750)).isBefore(deadline)) break;
      await ctx.delay(const Duration(milliseconds: 750));
    }
    return SafetyTestResult(zone: zone, hasValve: hasValve);
  }

  /// Panoda tanımlı eylemcinin doğrulaması: bölge testi (vana kapanır, siren kısa çalar); sonucu teknisyen gözle teyit
  /// eder ([confirmLit]). Düz röle komutu eylemci kanalında açma yönünde reddedileceği için kullanılmaz.
  Future<bool> testActuator(int id) => run('Bölge testi gönderiliyor', () async {
        final current = byId(id);
        if (current == null || !current.boardActuator) return;
        await ctx.deviceCall((api) => api.testAlarm(current.assign.zone));
        _put((byId(id) ?? current).copyWith(
          cmdSent: true,
          problem: false,
          clearNote: true,
          info: 'Bölge testi gönderildi: vananın kapandığını / cihazın çalıştığını gözle doğrulayın. '
              'Test bitince su vanası önceki konumuna döner; gaz vanası kapalı kalır.',
        ));
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
