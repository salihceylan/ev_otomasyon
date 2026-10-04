import 'package:flutter/widgets.dart';

import '../../motion/ambient_clock.dart';
import '../../motion/motion_scope.dart';

/// "Nefes alan" parıltı bileşenleri için slot + saat yönetimi (şartname §4.2).
///
/// Nefes yalnız şu hepsi doğruysa istenir: [wantsBreath], `MotionMode.full` (kapsam var, sistem animasyonları
/// kapatmamış) ve `TickerMode` etkin (rota arkada/ayrıntıda değil). Ardından [AmbientClock.tryAcquireSlot]
/// ile bütçeden (8) slot alınır; alınamazsa [breathClock] `null` kalır ve çizim STATİKtir.
///
/// Kullanım: `CustomPainter(repaint: breathClock)` verilir; yalnız painter yeniden çizilir.
mixin AmbientBreathMixin<T extends StatefulWidget> on State<T> {
  AmbientClock? _breathSource;
  bool _breathSlot = false;

  /// Bileşen şu an nefes almak istiyor mu (ör. orb `active` ve etkin)?
  bool get wantsBreath;

  /// Slot alındıysa paylaşılan saat; aksi halde `null` (statik çiz).
  AmbientClock? get breathClock => _breathSlot ? _breathSource : null;

  /// Slot durumunu eşitler. `didChangeDependencies` ve `didUpdateWidget`'ta otomatik çağrılır.
  void syncBreath() {
    final clock = MotionScope.clockOf(context);
    if (!identical(_breathSource, clock)) {
      _releaseBreath();
      _breathSource = clock;
    }
    final want = wantsBreath && MotionScope.enabledOf(context) && TickerMode.valuesOf(context).enabled;
    if (want && !_breathSlot) {
      _breathSlot = clock.tryAcquireSlot(this);
    } else if (!want && _breathSlot) {
      _releaseBreath();
    }
  }

  void _releaseBreath() {
    if (_breathSlot) _breathSource?.releaseSlot(this);
    _breathSlot = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncBreath();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncBreath();
  }

  @override
  void dispose() {
    _releaseBreath();
    super.dispose();
  }
}
