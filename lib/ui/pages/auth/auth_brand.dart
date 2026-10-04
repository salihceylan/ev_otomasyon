import 'package:flutter/material.dart';

import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Açılış ve giriş ekranlarının marka logosu: yuvarlak logo + giriş koreografisi.
///
/// * **Giriş (tek sefer, 480 ms):** ölçek 0.82 -> 1 (yaylanma) + solma; ardından **tek seferlik** parıltı halkası
///   ([PulseRing], `playOnMount`). Sonsuz döngü YOK; `MotionMode.off` (varsayılan) ve "hareketi azalt"ta logo
///   anında tam görünür, halka çizilmez.
/// * [splash] `true`: açılış ekranının iki katmanlı büyük parıltısı (boyama testleri bu yapıyı pinler);
///   `false`: giriş ekranı için tek, daha yumuşak parıltı.
/// * Girdiyi bloklamaz; her kontrolcü `dispose` edilir.
///
/// **Görünüm (WP-F4):**
///  * `round_app_logo.png` neon halkanın dışında kalın siyah bir pay taşır (halka çapı plaka çapının ~%74'ü):
///    görsel [logoCrop] ile büyütülüp daire içinde kırpılır; parlak zeminde "sert siyah madeni para" görünümü yok.
///  * Parlak kenar halkası görselin ÜSTÜNE çizilir (`DecorationPosition.foreground`): eskiden görselin altında
///    kalıp tamamen örtülüyordu.
///  * Renkler tasarım belirteçlerindendir ([AppFamilies]); koyu temada parıltı alfası yüksektir (parlak devre
///    zemininde kaybolmaz).
class AuthLogoMark extends StatefulWidget {
  const AuthLogoMark({super.key, required this.size, this.splash = false});

  final double size;
  final bool splash;

  /// Logo görselinin kırpma ölçeği: neon halka kenara yakın kalır, siyah pay ~%9'a iner.
  static const double logoCrop = 1.22;

  @override
  State<AuthLogoMark> createState() => _AuthLogoMarkState();
}

class _AuthLogoMarkState extends State<AuthLogoMark> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: AppMotion.hero);
  late final Animation<double> _scale = Tween<double>(begin: 0.82, end: 1.0).animate(
    CurvedAnimation(parent: _controller, curve: AppMotion.spring),
  );
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.6, curve: Curves.easeOut));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MotionScope.enabledOf(context)) {
      _controller.forward();
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final dark = AppTheme.isDark(context);
    // Parıltı: koyuda cyan (alfa yüksek: parlak devre zemininde kaybolmasın), açıkta sky (beyaz sayfada belirgin).
    final glow = dark ? AppFamilies.cyan.base : AppFamilies.sky.base;
    final logo = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: widget.splash
            ? [
                BoxShadow(color: glow.withValues(alpha: dark ? 0.55 : 0.50), blurRadius: 36, spreadRadius: 6),
                BoxShadow(color: AppFamilies.sky.base.withValues(alpha: dark ? 0.38 : 0.30), blurRadius: 60, spreadRadius: 10),
              ]
            : [BoxShadow(color: glow.withValues(alpha: dark ? 0.45 : 0.35), blurRadius: 30, spreadRadius: 4)],
      ),
      child: DecoratedBox(
        // Kenar halkası görselin ÜSTÜNDE: ClipOval çocuğu kutuyu tamamen kapattığından arkada kalan kenar görünmezdi.
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppFamilies.cyan.base.withValues(alpha: 0.85), width: widget.splash ? 2.5 : 1.6),
        ),
        child: SizedBox.square(
          dimension: size,
          child: ClipOval(
            child: Transform.scale(
              scale: AuthLogoMark.logoCrop,
              child: Image.asset(
                'assets/images/round_app_logo.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: AppTheme.surfaceDark,
                  child: Icon(Icons.home_work_rounded, color: AppFamilies.cyan.base, size: size * 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Center(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Tek seferlik parıltı halkası: logonun ARKASINDA genişleyip söner (kendi RepaintBoundary'sinde).
            PulseRing(color: AppFamilies.cyan.light, diameter: size, playOnMount: true, maxScale: 1.6),
            FadeTransition(
              opacity: _fade,
              child: ScaleTransition(scale: _scale, child: logo),
            ),
          ],
        ),
      ),
    );
  }
}
