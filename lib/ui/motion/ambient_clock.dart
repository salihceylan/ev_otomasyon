import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Sonsuz (ambient) animasyonların TEK paylaşılan saati (şartname §4.2).
///
/// * **Tek `Ticker`**, bildirim hızı en çok ≈24 Hz (kare hızına göre 20–24 Hz; ara kareler bildirilmez).
/// * **Dinleyici yoksa DURUR**: ilk dinleyici eklenince başlar, son dinleyici çıkınca `Ticker` bırakılır.
///   Uygulama arka plana geçince (`paused/hidden/detached`) durur, öne dönünce dinleyici varsa sürer; zaman
///   kaldığı yerden devam eder (`time` monoton).
/// * **Slot bütçesi**: aynı anda en çok [maxSlots] (8) nefes alan parıltı. [tryAcquireSlot] `false` dönerse
///   çağıran **statik** çizer.
/// * [AmbientClock.fixed]: ASLA çalışmayan, `time` değeri sabit saat (golden/deterministik test için).
///
/// Tüketim deseni: yalnızca küçük bir `CustomPainter`'ın `repaint:` alanına verilir; kartın tamamı yeniden
/// KURULMAZ.
///
/// ```dart
/// final ok = clock.tryAcquireSlot(this);          // false ⇒ statik çiz
/// painter = MyGlowPainter(clock: ok ? clock : null);
/// ```
class AmbientClock extends ChangeNotifier with WidgetsBindingObserver {
  AmbientClock({
    this.interval = const Duration(microseconds: 41667),
    this.maxSlots = defaultMaxSlots,
  }) : _fixed = false;

  /// Hiç tik atmayan, [time] değeri [seconds] olan saat.
  AmbientClock.fixed(double seconds)
      : interval = const Duration(microseconds: 41667),
        maxSlots = defaultMaxSlots,
        _fixed = true,
        _time = seconds;

  /// Uygulama genelinde paylaşılan saat (`MotionScope.clock` verilmediğinde).
  static final AmbientClock shared = AmbientClock();

  /// Aynı anda nefes alabilen parıltı sayısı.
  static const int defaultMaxSlots = 8;

  /// Hedef bildirim aralığı (≈24 Hz).
  final Duration interval;

  /// Slot bütçesi.
  final int maxSlots;

  final bool _fixed;

  /// Kare jitter payı: hedef aralıktan bu kadar kısa kalan kare de bildirilir (60 Hz'de 3 karede bir ≈ 20 Hz).
  static const Duration _slack = Duration(milliseconds: 5);

  Ticker? _ticker;
  bool _observing = false;
  bool _foreground = true;
  double _baseSeconds = 0;
  double _time = 0;
  double _lastEmit = -1;

  final Set<Object> _slots = HashSet<Object>.identity();

  /// Sabit (hiç çalışmayan) saat mi?
  bool get isFixed => _fixed;

  /// Ticker şu an çalışıyor mu (dinleyici var VE uygulama ön planda).
  bool get isTicking => _ticker?.isActive ?? false;

  /// Başlangıçtan beri geçen (yalnızca çalıştığı süreyi sayan) saniye; son bildirilen değer.
  double get time => _time;

  /// Şu an tutulan slot sayısı.
  int get activeSlots => _slots.length;

  /// Bir nefes alan parıltı için slot ister. Bütçe doluysa `false` (çağıran statik çizer). Aynı sahibe tekrar
  /// çağrı idempotenttir.
  bool tryAcquireSlot(Object owner) {
    if (_slots.contains(owner)) return true;
    if (_slots.length >= maxSlots) return false;
    _slots.add(owner);
    return true;
  }

  /// Slotu bırakır (tutmayan sahip için no-op).
  void releaseSlot(Object owner) {
    _slots.remove(owner);
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = !(state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached);
    if (foreground == _foreground) return;
    _foreground = foreground;
    _sync();
  }

  void _sync() {
    if (_fixed) return;
    final wantObserver = hasListeners;
    if (wantObserver && !_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      final state = WidgetsBinding.instance.lifecycleState;
      _foreground = !(state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached);
    } else if (!wantObserver && _observing) {
      _observing = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    final wantTicker = wantObserver && _foreground;
    if (wantTicker && _ticker == null) {
      _start();
    } else if (!wantTicker && _ticker != null) {
      _stop();
    }
  }

  void _start() {
    _lastEmit = _baseSeconds;
    final ticker = Ticker(_onTick, debugLabel: 'AmbientClock');
    _ticker = ticker;
    ticker.start();
  }

  void _stop() {
    final ticker = _ticker;
    if (ticker == null) return;
    _ticker = null;
    // Zaman kaldığı yerden sürsün (monoton): sonraki başlangıç son bildirilen değerden devam eder.
    _baseSeconds = _time;
    ticker.stop();
    ticker.dispose();
  }

  void _onTick(Duration elapsed) {
    final now = _baseSeconds + elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final minGap = (interval - _slack).inMicroseconds / Duration.microsecondsPerSecond;
    if (now - _lastEmit < minGap) return;
    _lastEmit = now;
    _time = now;
    notifyListeners();
    // Dinleyici bildirim SIRASINDA çıkarsa (ör. iskeletin 12 sn dolması) `ChangeNotifier.hasListeners` bildirim
    // bitene kadar eski sayıyı gösterir: saati burada yeniden değerlendir ki son dinleyici gidince DURSUN.
    _sync();
  }

  @override
  void dispose() {
    _stop();
    if (_observing) {
      _observing = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    _slots.clear();
    super.dispose();
  }
}
