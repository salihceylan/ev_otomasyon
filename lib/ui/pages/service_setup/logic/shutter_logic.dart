import 'package:flutter/foundation.dart';

import '../../../../models/automation_models.dart';
import '../../../../models/cloud_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/api_exception.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';

/// Panjur yönü testinin sonucu.
enum ShutterDirectionVerdict {
  /// Henüz yanıtlanmadı.
  unknown,

  /// "Yukarı" komutunda panjur gerçekten yukarı gitti.
  ok,

  /// Panjur ters yöne gitti: YUKARI/AŞAĞI kabloları yer değiştirmeli.
  reversed,
}

/// Süre ölçüm aşaması.
enum MeasurePhase {
  /// Ölçüm başlamadı.
  idle,

  /// Ölçüm süresi (300 sn) panoya uygulandı; panjur alta indirilebilir.
  prepared,

  /// Panjur alta indirildi ve durduruldu; ölçüm başlatılabilir.
  atBottom,

  /// Kronometre çalışıyor (panjur yukarı gidiyor).
  running,

  /// Süre ölçüldü; kaydedilebilir.
  measured,
}

/// Bir panjurun test/kalibrasyon durumu.
@immutable
class ShutterCheck {
  const ShutterCheck({
    required this.pair,
    required this.name,
    this.moving = false,
    this.direction = 0,
    this.pos = 0,
    this.upAcked = false,
    this.stopAcked = false,
    this.verdict = ShutterDirectionVerdict.unknown,
    this.phase = MeasurePhase.idle,
    this.measureStartedAt,
    this.measuredSeconds,
    this.savedSeconds,
    this.unused = false,
    this.note,
    this.previousSeconds,
  });

  /// 1 tabanlı panjur numarası.
  final int pair;
  final String name;

  /// Panonun bildirdiği anlık durum.
  final bool moving;
  final int direction;
  final int pos;

  /// "Yukarı" komutuna pano gerçekten yukarı hareketle karşılık verdi.
  final bool upAcked;

  /// "Dur" komutuna pano gerçekten durarak karşılık verdi.
  final bool stopAcked;
  final ShutterDirectionVerdict verdict;
  final MeasurePhase phase;

  /// Kronometrenin başladığı an (çalışırken).
  final DateTime? measureStartedAt;

  /// Ölçülen / elle girilen süre (saniye, kayıttan önce).
  final int? measuredSeconds;

  /// Sunucuya kaydedilen **ve panoda uygulandığı doğrulanan** süre (1..300).
  final int? savedSeconds;
  final bool unused;
  final String? note;

  /// Ölçüm için panoya yazılan geçici 300 sn'den ÖNCEKİ süre: `null` değilse pano şu an geçici ölçüm
  /// süresini taşıyor ve ölçüm bırakılırsa bu değer geri yüklenmelidir.
  final int? previousSeconds;

  /// Panoda geçici ölçüm süresi duruyor ya da ölçüm yarım: ayrılırken/iptalde süre geri yüklenir.
  bool get hasMeasureOverride => previousSeconds != null;

  bool get isReady =>
      unused || (verdict == ShutterDirectionVerdict.ok && savedSeconds != null);

  /// Gerçekten test edilip kaydedildi ("kullanılmıyor" beyanı değil).
  bool get isVerified => !unused && verdict == ShutterDirectionVerdict.ok && savedSeconds != null;

  ShutterCheck copyWith({
    bool? moving,
    int? direction,
    int? pos,
    bool? upAcked,
    bool? stopAcked,
    ShutterDirectionVerdict? verdict,
    MeasurePhase? phase,
    DateTime? measureStartedAt,
    bool clearStart = false,
    int? measuredSeconds,
    bool clearMeasured = false,
    int? savedSeconds,
    bool clearSaved = false,
    bool? unused,
    String? note,
    bool clearNote = false,
    int? previousSeconds,
    bool clearPrevious = false,
  }) =>
      ShutterCheck(
        pair: pair,
        name: name,
        moving: moving ?? this.moving,
        direction: direction ?? this.direction,
        pos: pos ?? this.pos,
        upAcked: upAcked ?? this.upAcked,
        stopAcked: stopAcked ?? this.stopAcked,
        verdict: verdict ?? this.verdict,
        phase: phase ?? this.phase,
        measureStartedAt: clearStart ? null : (measureStartedAt ?? this.measureStartedAt),
        measuredSeconds: clearMeasured ? null : (measuredSeconds ?? this.measuredSeconds),
        savedSeconds: clearSaved ? null : (savedSeconds ?? this.savedSeconds),
        unused: unused ?? this.unused,
        note: clearNote ? null : (note ?? this.note),
        previousSeconds: clearPrevious ? null : (previousSeconds ?? this.previousSeconds),
      );
}

/// Adım 8 - Panjur Testi ve Kalibrasyon.
///
/// * **Yön testi:** "Yukarı" komutu yerel ağdan gönderilir; pano gerçekten yukarı hareket bildirirse
///   cihaz geri bildirimi alınmış sayılır, teknisyen panjurun gerçekten yukarı gittiğini onaylar. Ters ise
///   düzeltme talimatı gösterilir (YUKARI/AŞAĞI kablolarını yer değiştirin).
/// * **Süre ölçümü:** ölçüm süresi (300 sn) panoya yazılır (`PUT /endpoints` -> `set_runtime`), panjur alta
///   indirilir, kronometre ile yukarı çıkış süresi ölçülür; kayıttan sonra pano `/api/config` ile **geri
///   okunarak** değerin uygulandığı doğrulanır. Pano hareket halindeyken süre değişimini reddettiği için
///   panjur her zaman önce durdurulur.
///
/// Ölçüm sırasında panoya yazılan geçici 300 sn, ölçüm iptal edilince / adımdan ayrılınca / "kullanılmıyor"
/// işaretlenince **önceki değere geri yüklenir** (panjur motoru her komutta 5 dakikaya kadar enerjili kalmasın).
///
/// Geçiş koşulu: her panjur için yön onaylı + süre (1..300) kayıtlı ve panoda doğrulanmış (veya
/// "kullanılmıyor" beyanı); **en az bir panjur gerçekten test edilmiş** olmalıdır (tümünün "kullanılmıyor"
/// işaretlenmesiyle test yapılmadan geçilemez). Panjur yoksa adım tamamlanmış sayılır.
class ShutterLogic extends SetupLogic {
  ShutterLogic(super.ctx);

  @override
  int get number => SetupSteps.shutters;

  /// Ölçüm sırasında rölenin erken kapanmaması için geçici süre.
  static const int measureRuntimeSec = 300;

  /// Bundan kısa ölçüm gerçekçi değildir (panjur tam açılmadan basılmıştır).
  static const int minPlausibleSeconds = 3;

  List<ShutterCheck> _shutters = const <ShutterCheck>[];
  bool _loaded = false;
  Map<int, String> _endpointIds = const <int, String>{};
  Map<int, Map<String, dynamic>> _saved = const <int, Map<String, dynamic>>{};

  List<ShutterCheck> get shutters => _shutters;
  bool get loaded => _loaded;
  bool get hasNoShutters => _loaded && _shutters.isEmpty;

  @override
  bool get isComplete =>
      _loaded && _shutters.every((s) => s.isReady) && (_shutters.isEmpty || _shutters.any((s) => s.isVerified));

  ShutterCheck? byPair(int pair) {
    for (final s in _shutters) {
      if (s.pair == pair) return s;
    }
    return null;
  }

  void _put(ShutterCheck next) {
    _shutters = <ShutterCheck>[
      for (final s in _shutters) s.pair == next.pair ? next : s,
    ];
  }

  /// Panodan panjur listesini, sunucudan uç noktaları okur (test ilerlemesi korunur).
  Future<bool> load() => run('Panjurlar okunuyor', () async {
        final t = ctx.requireTarget;
        // Pano (yerel ağ) ve sunucu istekleri birbirine bağlı değil: birlikte beklenir (hata önceliği: önce pano).
        final (status, endpoints) = await awaitBoth(
          ctx.deviceCall((api) => api.fetchStatus()),
          ctx.cloud.fetchEndpoints(t.homeId),
        );
        _endpointIds = _idsByPair(endpoints);
        final existing = <int, ShutterCheck>{for (final s in _shutters) s.pair: s};
        _shutters = <ShutterCheck>[
          for (final item in status.shutters)
            existing.containsKey(item.pair)
                ? _syncLive(existing[item.pair]!, item)
                : _fromDevice(item),
        ];
        _loaded = true;
        // Önceki oturumda ölçüm yarım kaldıysa panoda geçici 300 sn duruyor olabilir: önceki süre geri yüklenir.
        for (final s in List<ShutterCheck>.of(_shutters)) {
          if (s.hasMeasureOverride && s.phase == MeasurePhase.idle) {
            await _ensureStopped(s.pair);
            await _restorePrevious(s.pair);
          }
        }
      });

  /// Panjur numarası → sunucudaki uç nokta kimliği (panjurun YUKARI/birincil satırı; yoksa ilk görülen satır).
  static Map<int, String> _idsByPair(List<EndpointModel> endpoints) {
    final ids = <int, String>{};
    for (final e in endpoints) {
      if (!e.isShutter) continue;
      if (e.isPrimaryShutterRow || !ids.containsKey(e.pair)) ids[e.pair] = e.id;
    }
    return ids;
  }

  ShutterCheck _syncLive(ShutterCheck check, ShutterItem item) =>
      check.copyWith(moving: item.isMoving, direction: item.direction, pos: item.pos);

  ShutterCheck _fromDevice(ShutterItem item) {
    final base = ShutterCheck(
      pair: item.pair,
      name: item.name,
      moving: item.isMoving,
      direction: item.direction,
      pos: item.pos,
    );
    final saved = _saved[item.pair];
    if (saved == null) return base;
    final prev = asInt(saved['prev']);
    final previous = (prev != null && prev >= 1 && prev <= 300) ? prev : null;
    if (saved['unused'] == true) return base.copyWith(unused: true, previousSeconds: previous);
    final seconds = asInt(saved['sec']);
    return base.copyWith(
      verdict: saved['dir'] == true ? ShutterDirectionVerdict.ok : ShutterDirectionVerdict.unknown,
      savedSeconds: (seconds != null && seconds >= 1 && seconds <= 300) ? seconds : null,
      previousSeconds: previous,
    );
  }

  ShutterCheck _require(int pair) {
    final s = byPair(pair);
    if (s == null) {
      throw const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.notFound,
        title: 'Panjur bulunamadı',
        why: 'Seçilen panjur pano durumunda yok.',
        todo: 'Listeyi yenileyip tekrar deneyin.',
      ));
    }
    return s;
  }

  /// Panonun gerçek durumundan [pair] panjurunu okur ve canlı alanları günceller.
  Future<ShutterItem?> _readLive(int pair, {bool Function(ShutterItem item)? until, Duration? timeout}) async {
    final status = await ctx.pollStatus(
      (s) {
        final item = s.shutterByPair(pair);
        return item != null && (until == null || until(item));
      },
      timeout: timeout ?? const Duration(seconds: 3),
      interval: const Duration(milliseconds: 300),
    );
    final item = status?.shutterByPair(pair);
    if (item != null) {
      final s = byPair(pair);
      if (s != null) _put(_syncLive(s, item));
    }
    return item;
  }

  // ---------------------------------------------------------------------------
  // Yön testi
  // ---------------------------------------------------------------------------

  /// `up` / `down` / `stop` komutu gönderir ve panonun gerçek geri bildirimini bekler.
  Future<bool> move(int pair, String action) {
    assert(action == 'up' || action == 'down' || action == 'stop');
    final label = switch (action) {
      'up' => 'Panjur yukarı çıkıyor',
      'down' => 'Panjur aşağı iniyor',
      _ => 'Panjur durduruluyor',
    };
    return run(label, () async {
      _require(pair);
      await ctx.deviceCall((api) => api.cmdShutter(pair, action));
      final item = await _readLive(
        pair,
        until: (i) => switch (action) {
          'up' => i.isMoving && i.direction == 1,
          'down' => i.isMoving && i.direction == 2,
          _ => !i.isMoving,
        },
      );
      final current = _require(pair);
      if (item == null) {
        throw SetupProblemException(SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano panjur komutuna cevap vermedi',
          why: 'Komut panoya ulaştı ama ${current.name} beklenen şekilde '
              '${action == 'stop' ? 'durmadı' : 'hareket etmedi'}.',
          todo: 'Birkaç saniye bekleyip yeniden deneyin. Olmazsa panjur rölelerini ve motor sigortasını kontrol edin.',
        ));
      }
      switch (action) {
        case 'up':
          _put(current.copyWith(upAcked: true));
        case 'stop':
          _put(current.copyWith(stopAcked: true));
        default:
          break;
      }
    });
  }

  /// "Panjur gerçekten yukarı mı gitti?" yanıtı.
  void confirmDirection(int pair, {required bool wentUp}) {
    final s = byPair(pair);
    if (s == null) return;
    if (wentUp) {
      _put(s.copyWith(verdict: ShutterDirectionVerdict.ok, clearNote: true));
    } else {
      _put(s.copyWith(
        verdict: ShutterDirectionVerdict.reversed,
        upAcked: false,
        note: 'Yön ters: panoda bu panjurun YUKARI ve AŞAĞI röle kablolarını (klemens) yer değiştirin, sonra yeniden deneyin.',
      ));
    }
    ctx.notify();
    ctx.persist();
  }

  /// Ters yön düzeltildi: testi yeniden başlatır.
  void retestDirection(int pair) {
    final s = byPair(pair);
    if (s == null) return;
    _put(s.copyWith(
      verdict: ShutterDirectionVerdict.unknown,
      upAcked: false,
      stopAcked: false,
      clearNote: true,
    ));
    ctx.notify();
  }

  /// Kayıtlı süreyi yeniden ölçmek için: kayıt silinir (adım yeniden kayıt gerektirir).
  void remeasure(int pair) {
    final s = byPair(pair);
    if (s == null) return;
    _put(s.copyWith(clearSaved: true, phase: MeasurePhase.idle, clearMeasured: true, clearStart: true));
    ctx.notify();
    ctx.persist();
  }

  /// Panjuru "kullanılmıyor" işaretler / geri alır. Ölçüm için panoya geçici süre yazılmışsa önce önceki
  /// süre geri yüklenir (asenkron); aksi halde anında uygulanır.
  Future<bool> setUnused(int pair, bool unused) async {
    final s = byPair(pair);
    if (s == null) return false;
    if (unused && (s.hasMeasureOverride || s.phase != MeasurePhase.idle)) {
      return run('Panjur süresi geri yükleniyor', () async {
        await _ensureStopped(pair);
        _put(_require(pair).copyWith(phase: MeasurePhase.idle, clearStart: true, clearMeasured: true));
        await _restorePrevious(pair);
        _put(_require(pair).copyWith(unused: true));
      });
    }
    _put(s.copyWith(unused: unused));
    ctx.notify();
    ctx.persist();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Süre ölçümü ve kayıt
  // ---------------------------------------------------------------------------

  String _endpointFor(int pair) {
    final id = _endpointIds[pair];
    if (id == null) {
      throw const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.notFound,
        title: 'Sunucuda bu panjur için kayıt yok',
        why: 'Panjurun kanal kaydı sunucuda bulunamadı; süre kaydedilemez.',
        todo: 'Listeyi yenileyin. Sorun sürerse cihazın kanal yapılandırmasını yöneticiyle kontrol edin.',
      ));
    }
    return id;
  }

  /// Panjur durdurulur ve panonun durduğu doğrulanır (süre değişimi hareket halindeyken reddedilir).
  Future<void> _ensureStopped(int pair) async {
    final live = (await ctx.deviceCall((api) => api.fetchStatus())).shutterByPair(pair);
    if (live != null && !live.isMoving) return;
    await ctx.deviceCall((api) => api.cmdShutter(pair, 'stop'));
    final item = await _readLive(pair, until: (i) => !i.isMoving, timeout: const Duration(seconds: 4));
    if (item == null) {
      throw const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Panjur durdurulamadı',
        why: 'Pano "dur" komutuna rağmen panjurun durduğunu bildirmiyor.',
        todo: 'Panjuru duvar butonuyla durdurup tekrar deneyin.',
      ));
    }
  }

  /// Panonun `runtime_sec` değerini (`/api/config`) geri okuyarak [seconds] uygulandı mı doğrular.
  Future<bool> _awaitRuntime(int pair, int seconds) async {
    final upRelay = 2 * pair - 1;
    final deadline = ctx.clock.now().add(const Duration(seconds: 10));
    while (true) {
      ctx.ensureActive();
      final config = await ctx.deviceCall((api) => api.fetchConfig());
      for (final item in asList(config['relays']) ?? const <dynamic>[]) {
        final map = asMap(item);
        if (map != null && asInt(map['id']) == upRelay && asInt(map['runtime_sec']) == seconds) return true;
      }
      if (!ctx.clock.now().add(const Duration(seconds: 1)).isBefore(deadline)) return false;
      await ctx.delay(const Duration(seconds: 1));
    }
  }

  /// Panonun şu anki `runtime_sec` değeri (`/api/config`); okunamazsa `null`.
  Future<int?> _readRuntime(int pair) async {
    final upRelay = 2 * pair - 1;
    final config = await ctx.deviceCall((api) => api.fetchConfig());
    for (final item in asList(config['relays']) ?? const <dynamic>[]) {
      final map = asMap(item);
      if (map != null && asInt(map['id']) == upRelay) {
        final value = asInt(map['runtime_sec']);
        return (value != null && value >= 1 && value <= 300) ? value : null;
      }
    }
    return null;
  }

  /// Ölçüm için yazılan geçici süre yerine [ShutterCheck.previousSeconds] değerini sunucuya ve panoya geri yazar.
  Future<void> _restorePrevious(int pair) async {
    final previous = byPair(pair)?.previousSeconds;
    if (previous == null) return;
    await _writeRuntime(pair, previous);
    final s = byPair(pair);
    if (s != null) _put(s.copyWith(clearPrevious: true));
  }

  /// Süreyi sunucuya (`PUT /endpoints/:id`) yazar. Sunucu `409 CONFLICT` ("Kanal tipi değişti; listeyi yenileyin.")
  /// derse pano yerleşimi sunucuda bu arada eşitlenmiş demektir (CONTRACTS §2.4b; sunucu `set_runtime`'ı yayınlar ama
  /// çift artık panjur değilse veritabanına yazmaz): uç nokta listesi yeniden okunur (`_endpointFor` bu listeden
  /// beslenir) ve yazım BİR KEZ yinelenir. Yine 409 gelirse anlaşılır bir sorun bildirilir; "Tekrar dene" aynı yolu
  /// baştan yürütür (yeniden okur, yeniden dener). Çakışma dışındaki hatalar (çevrimdışı pano `409 DEVICE_OFFLINE`,
  /// 5xx, ağ ...) olduğu gibi yükselir; yenileme/yeniden deneme yapılmaz.
  Future<void> _putRuntime(String homeId, int pair, int seconds) async {
    try {
      await ctx.cloud.updateEndpoint(homeId: homeId, endpointId: _endpointFor(pair), shutterDurationSec: seconds);
      return;
    } on ApiException catch (e) {
      if (!e.isConflict) rethrow;
    }
    // Çakışma: sunucudaki liste sihirbazın okuduğundan ilerlemiş. Yenile, sonra TEK yeniden deneme.
    ctx.ensureActive();
    _endpointIds = _idsByPair(await ctx.cloud.fetchEndpoints(homeId));
    ctx.ensureActive();
    try {
      await ctx.cloud.updateEndpoint(homeId: homeId, endpointId: _endpointFor(pair), shutterDurationSec: seconds);
    } on ApiException catch (e) {
      if (!e.isConflict) rethrow;
      throw SetupProblemException(SetupProblem(
        kind: SetupProblemKind.conflict,
        title: 'Kanal yerleşimi değişti',
        why: e.message,
        todo: 'Listeyi yenileyip "Tekrar dene"ye basın.',
      ));
    }
  }

  Future<void> _writeRuntime(int pair, int seconds) async {
    final t = ctx.requireTarget;
    await _ensureStopped(pair);
    // Durdurma beklenirken sayfa kapanmış / oturum bitmiş olabilir: bu durumda sunucuya yeni süre yazılmaz.
    ctx.ensureActive();
    await _putRuntime(t.homeId, pair, seconds);
    final applied = await _awaitRuntime(pair, seconds);
    if (!applied) {
      throw SetupProblemException(SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Süre panoda uygulanmadı',
        why: 'Sunucu $seconds sn değerini kaydetti ama pano 10 saniye içinde uygulandığını bildirmedi '
            '(pano buluta bağlı değil ya da panjur hareket ediyordu).',
        todo: 'Panjurun durduğundan ve bir önceki adımda bulutun çevrimiçi olduğundan emin olup "Tekrar dene"ye basın.',
      ));
    }
  }

  /// Ölçüm için süreyi 300 sn'ye çıkarır (röle erken kapanmasın); panjur önce durdurulur.
  Future<bool> prepareMeasure(int pair) => run('Ölçüm süresi panoya yazılıyor', () async {
        final current = _require(pair);
        // Geri yüklenecek değer: yarım kalmış bir hazırlıktan kalan değer korunur, yoksa panodan okunur.
        final previous = current.previousSeconds ?? await _readRuntime(pair);
        final restoreTo = (previous != null && previous != measureRuntimeSec) ? previous : null;
        if (restoreTo != null) {
          // Önceki süre geçici 300 sn YAZILMADAN ÖNCE kayda geçer: hazırlık yarıda kesilirse (sayfa/uygulama kapandı)
          // pano geçici süreyle kalmış olabilir; çıkış geri yüklemesi ve kayıttan devam bu değeri bilmelidir.
          _put(_require(pair).copyWith(previousSeconds: restoreTo));
          ctx.persist();
        }
        try {
          await _writeRuntime(pair, measureRuntimeSec);
        } catch (_) {
          // Sunucu 300 sn'yi yazmış ama pano uygulamamış olabilir: önceki değere dönülmeye çalışılır.
          if (restoreTo != null) {
            try {
              await _writeRuntime(pair, restoreTo);
              _put(_require(pair).copyWith(clearPrevious: true)); // pano önceki değere döndü: geçici süre kalmadı
            } catch (_) {
              // geri yükleme de başarısızsa önceki süre kayıtta kalır (çıkışta / devam edilince yeniden denenir);
              // asıl hata bildirilir
            }
          }
          rethrow;
        }
        _put(_require(pair).copyWith(
          phase: MeasurePhase.prepared,
          clearMeasured: true,
          clearStart: true,
          previousSeconds: previous,
        ));
      });

  /// Panjuru en alta indirir (hazırlık sonrası).
  Future<bool> driveToBottom(int pair) => move(pair, 'down');

  /// Teknisyen panjurun en alta indiğini bildirdi: panjur durdurulur ve ölçüme hazır olur.
  Future<bool> bottomReached(int pair) => run('Panjur durduruluyor', () async {
        _require(pair);
        await _ensureStopped(pair);
        _put(_require(pair).copyWith(phase: MeasurePhase.atBottom));
      });

  /// Kronometreyi başlatır: panjur yukarı çıkar; pano yukarı hareket bildirince süre sayılmaya başlar.
  Future<bool> startMeasure(int pair) => run('Ölçüm başlıyor', () async {
        final current = _require(pair);
        if (current.phase != MeasurePhase.atBottom) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Önce panjuru alta indirin',
            why: 'Ölçüm panjur en alttayken başlamalıdır.',
            todo: '"Alta İndir"e basın, panjur tam inince "Alta indi"ye basın.',
            retryable: false,
          ));
        }
        await ctx.deviceCall((api) => api.cmdShutter(pair, 'up'));
        final item = await _readLive(pair, until: (i) => i.isMoving && i.direction == 1);
        if (item == null) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Panjur yukarı çıkmadı',
            why: 'Pano yukarı hareket bildirmedi, süre ölçülemez.',
            todo: 'Yön testini tekrarlayın; panjurun yukarı çıktığından emin olun.',
          ));
        }
        _put(_require(pair).copyWith(
          phase: MeasurePhase.running,
          measureStartedAt: ctx.clock.now(),
          clearMeasured: true,
        ));
      });

  /// "Bitti": panjur tam açıldı. Panjur durdurulur ve süre hesaplanır.
  Future<bool> finishMeasure(int pair) => run('Süre ölçülüyor', () async {
        final current = _require(pair);
        final started = current.measureStartedAt;
        if (current.phase != MeasurePhase.running || started == null) return;
        final elapsed = ctx.clock.now().difference(started);
        final live = (await ctx.deviceCall((api) => api.fetchStatus())).shutterByPair(pair);
        if (live != null && !live.isMoving) {
          // Pano süreyi kendisi doldurup durdurdu: ölçüm süresi (300 sn) uygulanmamış demektir.
          _put(current.copyWith(phase: MeasurePhase.idle, clearStart: true, clearMeasured: true));
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano panjuru kendiliğinden durdurdu',
            why: 'Pano, ayarlı süresi dolduğu için panjuru durdurmuş; ölçüm geçerli değil.',
            todo: 'Ölçümü baştan başlatın: önce "Ölçüme Hazırla"ya basarak ölçüm süresinin panoya yazılmasını bekleyin.',
          ));
        }
        await ctx.deviceCall((api) => api.cmdShutter(pair, 'stop'));
        final seconds = clampInt((elapsed.inMilliseconds / 1000).ceil(), 1, 300);
        if (seconds < minPlausibleSeconds) {
          _put(current.copyWith(phase: MeasurePhase.idle, clearStart: true, clearMeasured: true));
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Ölçüm çok kısa',
            why: 'Süre 3 saniyeden kısa; panjur tam açılmadan "Bitti"ye basılmış olabilir.',
            todo: 'Ölçümü baştan yapın: panjuru en alta indirip yeniden başlatın ve tam açılınca "Bitti"ye basın.',
            retryable: false,
          ));
        }
        _put(current.copyWith(
          phase: MeasurePhase.measured,
          measuredSeconds: seconds,
          clearStart: true,
        ));
      });

  /// Ölçülen/elle girilen süreyi [delta] saniye ayarlar (1..300).
  void adjustMeasured(int pair, int delta) {
    final s = byPair(pair);
    final value = s?.measuredSeconds;
    if (s == null || value == null) return;
    _put(s.copyWith(measuredSeconds: clampInt(value + delta, 1, 300)));
    ctx.notify();
  }

  /// Süreyi elle girer (ölçüm yapmadan): 1..300.
  bool setManualSeconds(int pair, int seconds) {
    final s = byPair(pair);
    if (s == null) return false;
    if (seconds < 1 || seconds > 300) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Süre geçersiz',
        why: 'Panjur süresi 1 ile 300 saniye arasında olmalıdır.',
        todo: 'Süreyi düzeltin.',
        retryable: false,
      ));
      return false;
    }
    _put(s.copyWith(phase: MeasurePhase.measured, measuredSeconds: seconds, clearStart: true));
    clearProblem();
    ctx.notify();
    return true;
  }

  /// Ölçülen süreyi sunucuya kaydeder ve panoda uygulandığını **geri okuyarak** doğrular.
  Future<bool> saveRuntime(int pair) => run('Süre kaydediliyor', () async {
        final current = _require(pair);
        final seconds = current.measuredSeconds;
        if (seconds == null || seconds < 1 || seconds > 300) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Kaydedilecek süre yok',
            why: 'Önce süreyi ölçün veya elle girin (1-300 sn).',
            todo: 'Ölçümü tamamlayın.',
            retryable: false,
          ));
        }
        await _writeRuntime(pair, seconds);
        _put(_require(pair).copyWith(
          savedSeconds: seconds,
          phase: MeasurePhase.idle,
          clearMeasured: true,
          clearPrevious: true,
        ));
      });

  /// Ölçümü iptal eder (panjur durdurulur).
  Future<bool> cancelMeasure(int pair) => run('Ölçüm iptal ediliyor', () async {
        _require(pair);
        await _ensureStopped(pair);
        _put(_require(pair).copyWith(phase: MeasurePhase.idle, clearStart: true, clearMeasured: true));
        // Ölçüm için yazılan geçici süre geri alınır (başarısızsa hata görünür ve "Tekrar dene" geri yüklemeyi yineler).
        await _restorePrevious(pair);
      });

  /// Yarım kalan ölçüm / geçici ölçüm süresi varsa panjurları durdurur ve önceki süreleri geri yükler
  /// (adımdan ayrılırken, geri dönerken ve sihirbazdan çıkarken çağrılır). Bir şey yoksa hemen `true`.
  Future<bool> settleMeasurements() async {
    final pending = _shutters.where((s) => s.hasMeasureOverride || s.phase != MeasurePhase.idle).toList();
    if (pending.isEmpty) return true;
    return run('Panjur süreleri geri yükleniyor', () async {
      for (final s in pending) {
        await _ensureStopped(s.pair);
        final current = byPair(s.pair);
        if (current != null) {
          _put(current.copyWith(phase: MeasurePhase.idle, clearStart: true, clearMeasured: true));
        }
        await _restorePrevious(s.pair);
      }
    });
  }

  @override
  Map<String, dynamic> snapshot() {
    final out = <String, dynamic>{};
    if (!_loaded) {
      for (final e in _saved.entries) {
        out['${e.key}'] = e.value;
      }
    } else {
      for (final s in _shutters) {
        if (s.unused) {
          out['${s.pair}'] = <String, dynamic>{'unused': true, 'prev': ?s.previousSeconds};
        } else if (s.verdict == ShutterDirectionVerdict.ok || s.savedSeconds != null || s.hasMeasureOverride) {
          out['${s.pair}'] = <String, dynamic>{
            'dir': s.verdict == ShutterDirectionVerdict.ok,
            'sec': ?s.savedSeconds,
            // Ölçüm için panoda geçici süre duruyorsa önceki değer saklanır: uygulama kapanırsa devam edilince geri yüklenir.
            'prev': ?s.previousSeconds,
          };
        }
      }
    }
    return <String, dynamic>{'shutters': out};
  }

  @override
  void restore(Map<String, dynamic> json) {
    final raw = asMap(json['shutters']);
    if (raw == null) return;
    _saved = <int, Map<String, dynamic>>{
      for (final e in raw.entries)
        if (int.tryParse(e.key) != null && asMap(e.value) != null) int.parse(e.key): asMap(e.value)!,
    };
  }
}
