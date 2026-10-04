import 'package:flutter/material.dart';

import '../widgets/orb/progress_arc.dart';

/// Belirsiz süreli bekleme göstergesi: soluk halka izi + dönen yay ([ProgressArc]). `CircularProgressIndicator`
/// yerine kullanılır.
///
/// * Dönüş paylaşılan `AmbientClock`'tan türer ve yalnız `MotionMode.full`'da vardır; en çok [maxSpin] sürer,
///   sonra yay statik kalır (sonsuz animasyon bırakılmaz). Bekleme süresi bilinen yerlerde [maxSpin] bu süreye
///   eşitlenir (ör. bağlanma beklemesi 40 sn).
/// * `MotionMode.off`: dönmez, sabit bir yay çizer (durum yine görülür).
/// * Etkileşimi engellemez; anlamdan hariçtir (bekleme durumu yanındaki metinde/canlı bölgede söylenir).
/// * [child] (ör. geri sayım rakamı) halkanın ortasına konur.
class ArcSpinner extends StatelessWidget {
  const ArcSpinner({
    super.key,
    required this.color,
    this.size = 24,
    this.strokeWidth = 3,
    this.maxSpin = const Duration(seconds: 10),
    this.child,
  });

  final Color color;
  final double size;
  final double strokeWidth;
  final Duration maxSpin;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 0.22), width: strokeWidth),
                ),
              ),
            ),
            Positioned.fill(
              child: ProgressArc(diameter: size, color: color, strokeWidth: strokeWidth, maxSpin: maxSpin),
            ),
            if (child != null) Center(child: child),
          ],
        ),
      ),
    );
  }
}
