import 'package:flutter/foundation.dart';

import '../../../../models/automation_models.dart';
import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';

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

  /// Doğrulama yalnızca teknisyen gözlemine dayanıyor (darbe rölesinde pano geri bildirimi yok).
  bool get visualOnly => isImpulse && !sawOn && cmdSent && lit == true;

  /// Yük çalıştı mı sorusu gösterilmeli: pano geri bildirimi geldi ya da darbe komutu kabul edildi.
  bool get awaitingLitAnswer => lit == null && !unused && (sawOn || (isImpulse && cmdSent));

  RelayVerdict get verdict {
    if (unused) return RelayVerdict.unused;
    if (problem || lit == false) return RelayVerdict.problem;
    final deviceOk = isImpulse ? (sawOn || cmdSent) : (sawOn && sawOff);
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
      );
}

/// Adım 7 - Röle Testi.
///
/// Her röle için "Aç/Kapat" komutu **yerel ağdan** gönderilir ve panonun **gerçek durum bildirimi**
/// (`GET /api/status` -> `relays[].state` eşleşmesi) beklenir. Teknisyen ayrıca yükün gerçekten çalıştığını
/// ("yanıyor mu?") onaylar. Kullanılmayan çıkış işaretlenebilir. Geçiş koşulu: her röle doğrulanmış veya
/// "kullanılmıyor" ve en az biri doğrulanmış; sorunlu röle varsa geçilmez.
class RelayLogic extends SetupLogic {
  RelayLogic(super.ctx);

  @override
  int get number => SetupSteps.relays;

  List<RelayCheck> _relays = const <RelayCheck>[];
  bool _loaded = false;
  Map<int, String> _saved = const <int, String>{};

  List<RelayCheck> get relays => _relays;
  bool get loaded => _loaded;

  int get okCount => _relays.where((r) => r.verdict == RelayVerdict.ok).length;
  int get unusedCount => _relays.where((r) => r.verdict == RelayVerdict.unused).length;
  int get problemCount => _relays.where((r) => r.verdict == RelayVerdict.problem).length;
  int get untestedCount => _relays.where((r) => r.verdict == RelayVerdict.untested).length;

  @override
  bool get isComplete =>
      _loaded &&
      _relays.isNotEmpty &&
      okCount >= 1 &&
      _relays.every((r) => r.verdict == RelayVerdict.ok || r.verdict == RelayVerdict.unused);

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

  RelayCheck _fromDevice(RelayItem item) {
    final base = RelayCheck(
      id: item.id,
      name: item.name,
      isImpulse: item.isImpulse,
      state: item.state,
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

  /// Panodan röle listesini okur (test ilerlemesi korunur).
  Future<bool> load() => run('Röleler panodan okunuyor', () async {
        final status = await ctx.deviceCall((api) => api.fetchStatus());
        final items = status.controllableRelays;
        if (items.isEmpty) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.deviceRejected,
            title: 'Pano röle bildirmedi',
            why: 'Pano durumunda test edilecek bir röle çıkışı yok (yalnızca panjur olabilir).',
            todo: 'Panonun yapılandırmasını kontrol edin; panjur varsa bir sonraki adımda test edilir. '
                'Röle olması gerekiyorsa panoyu yeniden başlatıp tekrar deneyin.',
          ));
        }
        final existing = <int, RelayCheck>{for (final r in _relays) r.id: r};
        _relays = <RelayCheck>[
          for (final item in items)
            existing.containsKey(item.id)
                ? existing[item.id]!.copyWith(state: item.state)
                : _fromDevice(item),
        ];
        _loaded = true;
      });

  /// Röleyi açar/kapatır ve panonun gerçek geri bildirimini bekler.
  Future<bool> command(int id, bool on) => run(on ? 'Röle açılıyor' : 'Röle kapatılıyor', () async {
        final current = byId(id);
        if (current == null) return;
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
    _put(RelayCheck(id: r.id, name: r.name, isImpulse: r.isImpulse, state: r.state));
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

  @override
  Map<String, dynamic> snapshot() => <String, dynamic>{
        'relays': !_loaded
            ? <String, String>{for (final e in _saved.entries) '${e.key}': e.value}
            : _currentVerdicts(),
      };

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
