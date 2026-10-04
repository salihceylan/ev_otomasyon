import 'package:flutter/widgets.dart';

import 'ambient_clock.dart';

/// Hareket kipi.
///
/// * [off]: süre 0, ara değer (tween) yok, döngü yok. Kapsam yoksa VARSAYILAN budur: mevcut testler ve
///   `pumpAndSettle` etkilenmez.
/// * [full]: tam hareket. YALNIZCA `lib/main.dart`'ta `runApp` sarmalayıcısıyla (ve açık animasyon testleri/golden
///   ile) verilir.
enum MotionMode { off, full }

/// Hareket kipini ve paylaşılan [AmbientClock]'u ağaca taşır (şartname §4.1).
///
/// Tüketiciler [MotionScope.modeOf] kullanır: kapsam yoksa **off**; `MediaQuery.disableAnimations` açıksa
/// **off** gibi davranır. Kapsam, MaterialApp'in ÜSTÜNDE de durabilir (MediaQuery denetimi tüketicide yapılır).
///
/// ```dart
/// runApp(MotionScope(mode: MotionMode.full, child: app));
/// // golden: MotionScope(mode: MotionMode.full, clock: AmbientClock.fixed(1.2), child: ...)
/// ```
class MotionScope extends InheritedWidget {
  const MotionScope({
    super.key,
    required this.mode,
    this.clock,
    required super.child,
  });

  final MotionMode mode;

  /// Ambient saat; null ise [AmbientClock.shared]. Test/golden için sabit saat ([AmbientClock.fixed]) verilir.
  final AmbientClock? clock;

  /// Geçerli kip: kapsam yoksa `off`; sistem "animasyonları kaldır" açıksa `off`.
  static MotionMode modeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MotionScope>();
    if (scope == null || scope.mode == MotionMode.off) return MotionMode.off;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return MotionMode.off;
    return MotionMode.full;
  }

  /// `modeOf(context) == MotionMode.full`.
  static bool enabledOf(BuildContext context) => modeOf(context) == MotionMode.full;

  /// Kipe göre süre: `off` iken [Duration.zero].
  static Duration durationOf(BuildContext context, Duration duration) =>
      enabledOf(context) ? duration : Duration.zero;

  /// Geçerli ambient saat (kapsamdaki ya da [AmbientClock.shared]).
  static AmbientClock clockOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.clock ?? AmbientClock.shared;

  @override
  bool updateShouldNotify(MotionScope oldWidget) => mode != oldWidget.mode || clock != oldWidget.clock;
}
