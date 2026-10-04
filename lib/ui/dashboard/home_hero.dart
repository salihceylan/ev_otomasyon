import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/surface_card.dart';
import 'connection_status.dart' show deviceKnownOffline;

/// HomeHero görünüm verisi (değer eşitliği: `context.select` ile kullanılır).
@immutable
class HomeHeroVm {
  const HomeHeroVm({
    required this.name,
    required this.lightsOn,
    required this.lightsTotal,
    required this.shuttersMoving,
    required this.shuttersTotal,
    this.offline = false,
  });

  final String name;
  final int lightsOn;
  final int lightsTotal;
  final int shuttersMoving;
  final int shuttersTotal;

  /// Pano KESİN çevrimdışı ([deviceKnownOffline]): lamba/panjur sayıları son bilinendir, kesin gibi gösterilmez.
  final bool offline;

  @override
  bool operator ==(Object other) =>
      other is HomeHeroVm &&
      other.name == name &&
      other.lightsOn == lightsOn &&
      other.lightsTotal == lightsTotal &&
      other.shuttersMoving == shuttersMoving &&
      other.shuttersTotal == shuttersTotal &&
      other.offline == offline;

  @override
  int get hashCode => Object.hash(name, lightsOn, lightsTotal, shuttersMoving, shuttersTotal, offline);
}

/// Durumdan [HomeHeroVm] türetir. Ev adı: bulutta aktif ev, yerel modda cihaz adı.
HomeHeroVm homeHeroVmOf(AutomationState s) {
  final name = s.mode == AppMode.cloud
      ? (s.activeHome?.name ?? 'Evim')
      : (s.status?.deviceName ?? 'AHBU Akıllı Ev');
  final shutters = s.shutterItems;
  return HomeHeroVm(
    name: name,
    lightsOn: s.openLightsCount,
    lightsTotal: s.relayItems.length,
    shuttersMoving: shutters.where((x) => x.isMoving).length,
    shuttersTotal: shutters.length,
    offline: deviceKnownOffline(s),
  );
}

/// Pano başı "hero" bölümü (şartname §3.7): ev adı + ev silüeti (pencereler açık lambaya göre yanar; çatı
/// marka camgöbeği) + büyük sayaçlar. **Mevcut pano metinlerini çiftlemez** (durum hapı "N Işık Açık" yazar;
/// burada yalnız sayı + farklı alt yazı vardır). Statik çizim (ambient animasyon yok); sayılar [AnimatedCount].
///
/// Yerleşim genişliğe göre iki kiptir: dar (telefon) = ad + silüet üstte, sayaçlar altta (aralarında boşluk;
/// büyük yazıda sözcük ortasından bölünme olmasın diye yığılır); geniş (>= 560 dp) = ad + sayaçlar solda toplu,
/// büyük silüet sağda (sayaçlar 1000+ dp'ye yayılmaz).
///
/// Pano **kesin** çevrimdışıyken ([deviceKnownOffline]; D16, durum şeridi ve huzur bandıyla aynı ölçüt) "Açık lamba"
/// ve "Hareketli panjur" sayaçları çizilmez ve silüetin pencereleri sönük kalır: son bilinen durum kesin gibi sunulmaz.
///
/// Anahtar: `Key('home_hero')`.
class HomeHero extends StatelessWidget {
  const HomeHero({super.key});

  /// Geniş yerleşim eşiği (kart iç genişliği, dp).
  static const double wideBreakpoint = 560;

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, HomeHeroVm>(homeHeroVmOf);
    final dark = AppTheme.isDark(context);

    // Kesin çevrimdışıyken lamba/panjur durumu bilinmez: yalnız durumdan bağımsız kontrol noktası sayısı kalır.
    final lit = vm.offline ? 0 : vm.lightsOn;
    final counters = <_CounterSpec>[
      if (!vm.offline) ...[
        _CounterSpec(vm.lightsOn, 'Açık lamba', AppFamilies.amber),
        _CounterSpec(vm.shuttersMoving, 'Hareketli panjur', AppFamilies.sky),
      ],
      _CounterSpec(vm.lightsTotal + vm.shuttersTotal, 'Kontrol noktası', AppFamilies.cyan),
    ];

    final name = Text(
      vm.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: AppTheme.getTextPrimary(context),
      ),
    );

    Widget silhouette({required double width, required double height}) => RepaintBoundary(
          child: SizedBox(
            width: width,
            height: height,
            child: CustomPaint(
              painter: HouseSilhouettePainter(windows: vm.lightsTotal, lit: lit, dark: dark),
            ),
          ),
        );

    return SurfaceCard(
      key: const Key('home_hero'),
      accent: AppFamilies.cyan.base,
      active: lit > 0,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Semantics(
        container: true,
        label: vm.offline
            ? '${vm.name}. Pano çevrimdışı; lamba ve panjur durumu bilinmiyor.'
            : '${vm.name}. ${vm.lightsOn} lamba açık, ${vm.shuttersMoving} panjur hareketli.',
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
              if (constraints.maxWidth >= wideBreakpoint) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          name,
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 40,
                            runSpacing: 12,
                            children: [
                              for (final c in counters)
                                ConstrainedBox(
                                  constraints: const BoxConstraints(minWidth: 112),
                                  child: _Counter(spec: c),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    silhouette(width: 124, height: 106),
                  ],
                );
              }
              // Dar yerleşim: en uzun sözcüğün ("Hareketli") sütuna sığıp sığmadığına bakılır; sığmazsa sayaçlar
              // alt alta yığılır (sözcük ortasından bölünme yok).
              const gap = 12.0;
              final slot = (constraints.maxWidth - 2 * gap) / 3;
              final needed = 6.3 * 9 * scale + 4;
              final stacked = slot < needed;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: name),
                      const SizedBox(width: 12),
                      silhouette(width: 92, height: 78),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (stacked)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < counters.length; i++)
                          Padding(
                            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                            child: _Counter(spec: counters[i], inline: true),
                          ),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < counters.length; i++) ...[
                          if (i > 0) const SizedBox(width: gap),
                          Expanded(child: _Counter(spec: counters[i])),
                        ],
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CounterSpec {
  const _CounterSpec(this.value, this.caption, this.family);

  final int value;
  final String caption;
  final AccentFamily family;
}

/// Sayaç: büyük rakam + alt yazı. [inline] (büyük yazıda yığılmış kip): rakam solda, alt yazı yanında.
class _Counter extends StatelessWidget {
  const _Counter({required this.spec, this.inline = false});

  final _CounterSpec spec;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final active = spec.value > 0;
    // Açık temada rakam AA okunur tona çekilir (amber.deep tek başına ~2.9:1 idi); koyuda açık ton.
    final color = active
        ? (dark ? spec.family.light : AppTheme.readableAccent(context, spec.family.deep))
        : AppTheme.getTextMuted(context);
    final number = AnimatedCount(
      value: spec.value,
      format: (v) => '$v',
      style: TextStyle(fontSize: AppText.metric, fontWeight: FontWeight.w800, height: 1.1, color: color),
    );
    final caption = Text(
      spec.caption,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: AppText.badge, fontWeight: FontWeight.w600, color: AppTheme.getTextMuted(context)),
    );
    if (inline) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(minWidth: 40), child: number),
          const SizedBox(width: 12),
          Expanded(child: caption),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        number,
        const SizedBox(height: 2),
        caption,
      ],
    );
  }
}

/// Ev silüeti: camgöbeği çatı, gövde ve [windows] pencere (en çok 6); ilk [lit] pencere amber yanar.
/// Statik (animasyon yok); parıltı `RadialGradient` ile çizilir (blur yok).
class HouseSilhouettePainter extends CustomPainter {
  const HouseSilhouettePainter({required this.windows, required this.lit, required this.dark});

  final int windows;
  final int lit;
  final bool dark;

  static const int maxWindows = 6;

  /// Yanan pencere halesi: pencere genişliğinin katı olarak yarıçap ve alfa (koyu / açık tema).
  static const double glowRadiusFactor = 1.8;
  static const double glowAlphaDark = 0.55;
  static const double glowAlphaLight = 0.40;

  /// Çizilen pencere sayısı (1..6; lamba yoksa da bir pencere görünür, sönük).
  int get windowCount => windows.clamp(1, maxWindows);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cyan = AppFamilies.cyan;
    final roofBase = h * 0.40;
    final bodyLeft = w * 0.10;
    final bodyRight = w * 0.90;

    // Gövde.
    final body = RRect.fromLTRBR(bodyLeft, roofBase - 1, bodyRight, h - 1, const Radius.circular(8));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [const Color(0xFF1B2740), const Color(0xFF141E33)]
              : [const Color(0xFFFFFFFF), const Color(0xFFE9EEF6)],
        ).createShader(body.outerRect),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = (dark ? Colors.white : const Color(0xFF0B1016)).withValues(alpha: dark ? 0.22 : 0.14),
    );

    // Çatı (marka camgöbeği).
    final roof = Path()
      ..moveTo(w * 0.02, roofBase)
      ..lineTo(w * 0.5, h * 0.03)
      ..lineTo(w * 0.98, roofBase);
    canvas.drawPath(
      Path.from(roof)..close(),
      Paint()..color = cyan.base.withValues(alpha: dark ? 0.16 : 0.12),
    );
    canvas.drawPath(
      roof,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        // Çatı çizgisi: koyuda parlak (açık → ana → sky); AÇIK temada beyaz kartta çatının sol yarısı yıkanmasın diye
        // derin tonlar (başlangıç ≈ 3.5:1, ucu ≥ 5:1; eskiden cyan.light başlangıcı 1.3:1 idi).
        ..shader = LinearGradient(
          colors: dark
              ? [cyan.light, cyan.base, AppFamilies.sky.base]
              : [Color.lerp(cyan.base, cyan.deep, 0.65)!, cyan.deep, AppFamilies.sky.deep],
        ).createShader(Offset.zero & size),
    );

    // Pencereler: 3 sütun x 2 satır içinde.
    final count = windowCount;
    final cols = count <= 2 ? count : 3;
    final rows = (count / cols).ceil();
    final areaTop = roofBase + h * 0.07;
    final areaBottom = h - h * 0.08;
    final areaLeft = bodyLeft + w * 0.07;
    final areaRight = bodyRight - w * 0.07;
    final gap = w * 0.06;
    final cellW = (areaRight - areaLeft - gap * (cols - 1)) / cols;
    final cellH = math.min((areaBottom - areaTop - gap * (rows - 1)) / rows, cellW * 1.15);
    final amber = AppFamilies.amber;
    final glowRadius = cellW * glowRadiusFactor;
    for (var i = 0; i < count; i++) {
      final r = i ~/ cols;
      final c = i % cols;
      final inRow = r == rows - 1 ? count - r * cols : cols;
      final rowWidth = inRow * cellW + (inRow - 1) * gap;
      final startX = areaLeft + ((areaRight - areaLeft) - rowWidth) / 2;
      final rect = Rect.fromLTWH(startX + c * (cellW + gap), areaTop + r * (cellH + gap), cellW, cellH);
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(3));
      if (i < lit) {
        // Hale: pencere kenarından belirgin taşar (koyuda sıcak ışık, açıkta yumuşak şeftali parıltı).
        final glowAlpha = dark ? glowAlphaDark : glowAlphaLight;
        canvas.drawCircle(
          rect.center,
          glowRadius,
          Paint()
            ..shader = RadialGradient(
              colors: [
                amber.base.withValues(alpha: glowAlpha),
                amber.base.withValues(alpha: glowAlpha * 0.35),
                amber.base.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.45, 1.0],
            ).createShader(Rect.fromCircle(center: rect.center, radius: glowRadius)),
        );
        canvas.drawRRect(
          rr,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [amber.light, amber.base],
            ).createShader(rect),
        );
      } else {
        canvas.drawRRect(rr, Paint()..color = (dark ? const Color(0xFF0B1120) : const Color(0xFFCBD5E1)).withValues(alpha: dark ? 0.9 : 0.8));
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = (dark ? Colors.white : const Color(0xFF334155)).withValues(alpha: 0.18),
        );
      }
    }
  }

  @override
  bool shouldRepaint(HouseSilhouettePainter old) =>
      old.windows != windows || old.lit != lit || old.dark != dark;
}
