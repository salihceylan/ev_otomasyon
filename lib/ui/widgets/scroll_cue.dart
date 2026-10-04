import 'package:flutter/material.dart';

/// Kaydırılabilir alanın SAĞ kenarında **kalıcı ince kaydırma çubuğu** gösterir (kaydırma ipucu: uzun diyalog / çekmece
/// listesinde gizli içerik olduğu ve konumu anlaşılsın; içerik sığıyorsa çubuk çizilmez). Çubuk içeriğin ÜSTÜNE
/// binmez: [builder] çıktısının sağ kenarında [gutter] dp boşluk bırakılmalıdır (diyalogda içerik dolgusunun sağ
/// boşluğu, çekmecede liste dolgusu). Metni solduran bir solma/gradyan YOKTUR (kısmen görünen metnin kontrastı bozulmaz).
///
/// [builder] kaydırıcıyı verilen [ScrollController] ile kurmalıdır.
class ScrollCue extends StatefulWidget {
  const ScrollCue({super.key, required this.color, required this.builder});

  /// Çubuk (başparmak) rengi.
  final Color color;
  final Widget Function(BuildContext context, ScrollController controller) builder;

  /// Çubuğun kapladığı sağ şerit genişliği (kalınlık + kenar boşluğu).
  static const double gutter = 6;

  @override
  State<ScrollCue> createState() => _ScrollCueState();
}

class _ScrollCueState extends State<ScrollCue> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll<Color>(widget.color),
        thickness: const WidgetStatePropertyAll<double>(4),
        radius: const Radius.circular(2),
        crossAxisMargin: 2,
        mainAxisMargin: 4,
        thumbVisibility: const WidgetStatePropertyAll<bool>(true),
      ),
      child: Scrollbar(controller: _controller, child: widget.builder(context, _controller)),
    );
  }
}
