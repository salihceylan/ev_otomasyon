import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../models/automation_models.dart';
import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';

enum ButtonVerdict { untested, detected, none }

/// Bir dijital giriş (duvar butonu) kontrolü.
@immutable
class ButtonCheck {
  const ButtonCheck({
    required this.id,
    required this.name,
    this.pressed = false,
    this.verdict = ButtonVerdict.untested,
    this.detectedAt,
  });

  /// 1 tabanlı giriş numarası.
  final int id;
  final String name;

  /// Panonun bildirdiği anlık durum (basılı mı).
  final bool pressed;
  final ButtonVerdict verdict;
  final DateTime? detectedAt;

  ButtonCheck copyWith({bool? pressed, ButtonVerdict? verdict, DateTime? detectedAt}) => ButtonCheck(
        id: id,
        name: name,
        pressed: pressed ?? this.pressed,
        verdict: verdict ?? this.verdict,
        detectedAt: detectedAt ?? this.detectedAt,
      );
}

/// Adım 9 - Duvar Butonları.
///
/// "Dinlemeyi başlat" ile panonun giriş durumu (`dis[]`) kısa aralıkla yoklanır; bir giriş **basılı**
/// bildirilince "algılandı" işaretlenir. (Çocuk kilidi açıkken röleler tetiklenmez ama giriş durumu
/// yine okunur; kilit uyarısı gösterilir.) Butonu bağlı olmayan giriş "Buton yok" işaretlenebilir.
/// Geçiş koşulu: her giriş algılandı veya "buton yok".
class ButtonLogic extends SetupLogic {
  ButtonLogic(super.ctx);

  @override
  int get number => SetupSteps.buttons;

  /// Yoklama aralığı: kısa basışları kaçırmamak için sık.
  static const Duration pollInterval = Duration(milliseconds: 200);
  static const int maxConsecutiveFailures = 5;

  List<ButtonCheck> _buttons = const <ButtonCheck>[];
  bool _loaded = false;
  bool _listening = false;
  bool _childLockOn = false;
  Timer? _timer;
  bool _polling = false;
  int _failures = 0;
  Map<int, String> _saved = const <int, String>{};

  List<ButtonCheck> get buttons => _buttons;
  bool get loaded => _loaded;

  /// Şablon panoya uygulandı (İP-4.3): giriş listesi ve kayıttaki algılama ilerlemesi bırakılır; adıma girilince
  /// panodan (şablonun giriş adlarıyla) yeniden okunur.
  void resetForTemplate() {
    stopListening();
    _buttons = const <ButtonCheck>[];
    _loaded = false;
    _saved = const <int, String>{};
    clearProblem();
  }
  bool get listening => _listening;

  /// Pano çocuk kilidinin AÇIK olduğunu bildiriyor (duvar butonları röleleri tetiklemez).
  bool get childLockOn => _childLockOn;

  int get detectedCount => _buttons.where((b) => b.verdict == ButtonVerdict.detected).length;
  int get noneCount => _buttons.where((b) => b.verdict == ButtonVerdict.none).length;
  int get untestedCount => _buttons.where((b) => b.verdict == ButtonVerdict.untested).length;

  /// Pano hiç giriş bildirmedi (duvar butonu girişi yok).
  bool get hasNoInputs => _loaded && _buttons.isEmpty;

  @override
  bool get isComplete =>
      _loaded && _buttons.every((b) => b.verdict == ButtonVerdict.detected || b.verdict == ButtonVerdict.none);

  void _put(ButtonCheck next) {
    _buttons = <ButtonCheck>[
      for (final b in _buttons) b.id == next.id ? next : b,
    ];
  }

  ButtonCheck _fromDevice(DIItem item) {
    final base = ButtonCheck(id: item.id, name: item.name, pressed: item.state);
    switch (_saved[item.id]) {
      case 'detected':
        return base.copyWith(verdict: ButtonVerdict.detected);
      case 'none':
        return base.copyWith(verdict: ButtonVerdict.none);
    }
    return base;
  }

  /// Panodan giriş listesini okur (ilerleme korunur).
  Future<bool> load() => run('Girişler panodan okunuyor', () async {
        final status = await ctx.deviceCall((api) => api.fetchStatus());
        _applyStatus(status, initial: true);
        _loaded = true;
      });

  /// Pano durumunu girişlere işler. Arayüzü ilgilendiren bir şey (basılı göstergesi, karar, giriş listesi, çocuk kilidi
  /// uyarısı) **değiştiyse** `true` döner; hiçbir şey değişmediyse mevcut liste olduğu gibi kalır (yeni liste üretilmez).
  bool _applyStatus(DeviceStatus status, {bool initial = false}) {
    final existing = <int, ButtonCheck>{for (final b in _buttons) b.id: b};
    final now = ctx.clock.now();
    final next = <ButtonCheck>[
      for (final item in status.dis)
        () {
          final old = existing[item.id];
          if (old == null) return _fromDevice(item);
          // Yalnızca YÜKSELEN KENAR (bırakılmış -> basılı) basış sayılır: sürekli "basılı" görünen
          // (tele takılı/kısa devre) bir giriş yanlışlıkla "algılandı" olmaz.
          final pressedNow = !initial && item.state && !old.pressed;
          if (pressedNow && old.verdict != ButtonVerdict.detected) {
            return old.copyWith(pressed: true, verdict: ButtonVerdict.detected, detectedAt: now);
          }
          return old.copyWith(pressed: item.state);
        }(),
    ];
    final childLockOn = status.childLockKnown && status.childLock;
    final changed = childLockOn != _childLockOn || !_sameChecks(_buttons, next);
    _childLockOn = childLockOn;
    if (changed) _buttons = next;
    return changed;
  }

  /// İki giriş listesi arayüz açısından aynı mı (sıra, kimlik, ad, basılı göstergesi, karar, algılanma anı).
  static bool _sameChecks(List<ButtonCheck> a, List<ButtonCheck> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.name != y.name ||
          x.pressed != y.pressed ||
          x.verdict != y.verdict ||
          x.detectedAt != y.detectedAt) {
        return false;
      }
    }
    return true;
  }

  /// Dinlemeyi başlatır: giriş durumu kısa aralıkla yoklanır.
  Future<bool> startListening() async {
    if (_listening) return true;
    if (!_loaded) {
      final ok = await load();
      if (!ok) return false;
    }
    _listening = true;
    _failures = 0;
    clearProblem();
    _timer = ctx.periodic(pollInterval, () => unawaited(_tick()));
    ctx.notify();
    return true;
  }

  void stopListening() {
    if (!_listening && _timer == null) return;
    _listening = false;
    ctx.cancelTimer(_timer);
    _timer = null;
    ctx.notify();
    ctx.persist();
  }

  Future<void> _tick() async {
    if (_polling || !_listening || ctx.disposed) return;
    _polling = true;
    try {
      ctx.ensureActive();
      final status = await ctx.deviceCall((api) => api.fetchStatus());
      _failures = 0;
      // 200 ms'lik yoklamada her turda bildirmek tüm sayfayı saniyede 5 kez yeniden kurardı: yalnız değişimde bildirilir.
      if (_listening && _applyStatus(status)) ctx.notify();
    } on SetupCancelled {
      // sayfa kapandı
    } on SetupSessionExpiredException {
      ctx.sessionEnded = true;
      stopListening();
      fail(SetupProblems.expired());
    } catch (error) {
      if (ctx.disposed) return;
      if (error is LocalApiException && !error.isNetwork) {
        _failures = maxConsecutiveFailures; // anahtar/kilit hatası: tekrar denemenin anlamı yok
      } else {
        _failures++;
      }
      if (_failures >= maxConsecutiveFailures) {
        stopListening();
        fail(SetupProblems.fromError(error, step: number), retry: startListening);
      }
    } finally {
      _polling = false;
    }
  }

  /// Bu girişte buton olmadığını işaretler / geri alır.
  void markNone(int id, bool none) {
    ButtonCheck? b;
    for (final item in _buttons) {
      if (item.id == id) b = item;
    }
    if (b == null) return;
    _put(b.copyWith(verdict: none ? ButtonVerdict.none : ButtonVerdict.untested));
    ctx.notify();
    ctx.persist();
  }

  /// Bir girişin algılanma işaretini sıfırlar (yeniden denemek için).
  void reset(int id) {
    for (final b in _buttons) {
      if (b.id == id) {
        _put(ButtonCheck(id: b.id, name: b.name, pressed: b.pressed));
        break;
      }
    }
    ctx.notify();
    ctx.persist();
  }

  @override
  Map<String, dynamic> snapshot() => <String, dynamic>{
        'buttons': !_loaded
            ? <String, String>{for (final e in _saved.entries) '${e.key}': e.value}
            : <String, String>{
                for (final b in _buttons)
                  if (b.verdict == ButtonVerdict.detected)
                    '${b.id}': 'detected'
                  else if (b.verdict == ButtonVerdict.none)
                    '${b.id}': 'none',
              },
      };

  @override
  void restore(Map<String, dynamic> json) {
    final raw = json['buttons'];
    if (raw is Map) {
      _saved = <int, String>{
        for (final e in raw.entries)
          if (int.tryParse(e.key.toString()) != null && e.value is String)
            int.parse(e.key.toString()): e.value as String,
      };
    }
  }
}
