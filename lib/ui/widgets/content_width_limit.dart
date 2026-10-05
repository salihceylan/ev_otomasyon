import 'package:flutter/widgets.dart';

/// Geniş pencerede (Windows / masaüstü / tablet yatay) uygulamanın TÜM sayfalarını ortalanmış, okunabilir bir
/// sütuna sığdırır: düğmeler ve kartlar 1900 px'e yayılmaz. Arka plan (üstteki [CircuitBackground]) tam ekran kalır.
///
/// Pencere [maxWidth]'ten darsa (telefon, dar pencere) hiçbir şey değişmez. Daralttığında alt ağaca giden
/// [MediaQuery] boyutu da sütun genişliğine çekilir; böylece `MediaQuery.sizeOf` ile kırılım seçen sayfalar
/// (ör. 640 dp eşiği) gerçek çizim genişliğine göre karar verir.
class ContentWidthLimit extends StatelessWidget {
  const ContentWidthLimit({super.key, required this.child, this.maxWidth = defaultMaxWidth});

  /// Masaüstünde içerik sütununun en büyük genişliği (mantıksal piksel).
  static const double defaultMaxWidth = 1080;

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || constraints.maxWidth <= maxWidth) return child;
        final mq = MediaQuery.of(context);
        return Center(
          child: SizedBox(
            width: maxWidth,
            child: MediaQuery(
              data: mq.copyWith(size: Size(maxWidth, mq.size.height)),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
