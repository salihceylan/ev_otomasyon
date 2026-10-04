/// Hareket katmanı (şartname `gorsel-tasarim-v2.md` §2.4, §3.3, §4): tek giriş noktası.
///
/// ```dart
/// import 'package:ev_otomasyon/ui/motion/motion.dart';
/// ```
///
/// Süre/eğri belirteçleri ([AppMotion], [SpringCurve]) `lib/ui/theme/tokens.dart` içindedir ve buradan da
/// dışa aktarılır.
library;

export '../theme/tokens.dart' show AppMotion, PressHaptic, SpringCurve;
export 'ambient_clock.dart';
export 'animated_count.dart';
export 'fade_through_transitions.dart';
export 'motion_scope.dart';
export 'pressable.dart';
export 'pulse_ring.dart';
export 'shared_axis.dart';
export 'skeleton.dart';
export 'staggered_entrance.dart';
export 'state_switcher.dart';
