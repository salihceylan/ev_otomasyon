import 'dart:async';

import '../../services/clock.dart';

/// Sunucudan gelen bekleme süresini (`resend_after` / `retry_after`) geri sayan küçük yardımcı.
///
/// Zaman kaynağı [Clock]'tur (`AutomationState.clock`): testlerde sahte saatle hızlı ilerletilir.
/// Kalan süre bitiş anına göre hesaplanır (zamanlayıcı kayması birikmez). [dispose] sonrası geri
/// çağrı çalışmaz.
class Cooldown {
  Cooldown(this._clock, this._onChanged);

  final Clock _clock;
  final void Function() _onChanged;

  Timer? _timer;
  DateTime? _deadline;
  bool _disposed = false;

  /// Kalan tam saniye (0 = bekleme yok / bitti).
  int get remainingSeconds {
    final deadline = _deadline;
    if (deadline == null) return 0;
    final ms = deadline.difference(_clock.now()).inMilliseconds;
    if (ms <= 0) return 0;
    return (ms / 1000).ceil();
  }

  bool get isActive => remainingSeconds > 0;

  /// [duration] boyunca beklemeyi başlatır (önceki bekleme yerine geçer).
  void start(Duration duration) {
    if (_disposed) return;
    _timer?.cancel();
    if (duration <= Duration.zero) {
      _deadline = null;
      _timer = null;
      _onChanged();
      return;
    }
    _deadline = _clock.now().add(duration);
    _timer = _clock.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      if (!isActive) {
        timer.cancel();
        _timer = null;
        _deadline = null;
      }
      _onChanged();
    });
    _onChanged();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
