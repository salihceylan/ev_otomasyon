import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/slider_shapes.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/theme/tone_button_surface.dart';
import 'package:ev_otomasyon/ui/widgets/neon_app_bar.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/settings/accent_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design_support.dart';

/// WP-FX-A (SON TUR, tema/ortak bileşenler): 2. tur eleştirmen bulgularından çıkan sözleşmeler.
///
///  * çerçeveli düğme kenarı: TEK ton kuralı, ≥ 3:1 (tüm aileler × iki tema × kart/sayfa zemini; gerçek piksellerle de);
///  * pasif gradyan düğme: OPAK cam yüzey, etiket kendi zemininde ≥ 4.5:1, devre izleri etiketin altından geçmez;
///  * AppBar `scrolled-under` tonu tema düzeyinde kapalı;
///  * pasif iz belirteci (`getInactiveTrack`) ≥ 3:1;
///  * açık temada soluk (dimmed / salt-okunur AÇIK) orb etkinden baskın değil; kaydırıcı başparmağı beyaz kartta kaybolmaz.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final themes = <Brightness, ThemeData Function()>{
    Brightness.dark: () => guardedAppTheme(Brightness.dark),
    Brightness.light: () => guardedAppTheme(Brightness.light),
  };

  Future<BuildContext> contextFor(WidgetTester tester, ThemeData theme) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(theme: theme, home: Builder(builder: (c) {
      captured = c;
      return const SizedBox();
    })));
    await tester.pumpAndSettle();
    return captured;
  }

  /// Bir çerçeveli düğmenin durabileceği yüzeyler (kütüphanedeki listeden BAĞIMSIZ yazılmıştır).
  List<Color> surfacesFor(Brightness b) => b == Brightness.dark
      ? <Color>[
          SurfaceTokens.dark.cardTop,
          SurfaceTokens.dark.cardBottom,
          AppTheme.cardDark,
          const Color(0xFF141E33), // diyalog
          AppTheme.bgDark,
        ]
      : <Color>[Colors.white, SurfaceTokens.light.cardBottom, AppTheme.bgLight, AppTheme.fieldFillLight];

  double worstOver(Color border, List<Color> surfaces) {
    var worst = double.infinity;
    for (final s in surfaces) {
      final c = AppTheme.contrastRatio(Color.alphaBlend(border, s), s);
      if (c < worst) worst = c;
    }
    return worst;
  }

  // -----------------------------------------------------------------------------------------
  // (1) Çerçeveli düğme kenarı
  // -----------------------------------------------------------------------------------------
  group('çerçeveli düğme kenarı: TEK ton kuralı (≥ 3:1)', () {
    for (final b in Brightness.values) {
      test('${b.name}: her aile için kenar, düğmenin durabileceği TÜM yüzeylerde ≥ 3:1 (WCAG 1.4.11)', () {
        for (final family in AppFamilies.all) {
          final border = AppTheme.outlinedBorderOn(b, family);
          expect(worstOver(border, surfacesFor(b)), greaterThanOrEqualTo(3.0), reason: '${b.name} ${family.name}');
          expect(worstOver(border, AppTheme.outlineSurfacesOn(b)), greaterThanOrEqualTo(AppTheme.outlineMinContrast),
              reason: '${family.name}: kütüphane hedefi ${AppTheme.outlineMinContrast}');
        }
      });
    }

    test('tema OutlinedButton kenarı = kural (koyuda cyan, açıkta sky), 1.5 dp; pasifte rimSolid', () {
      for (final b in Brightness.values) {
        final style = themes[b]!().outlinedButtonTheme.style!;
        final side = style.side!.resolve(<WidgetState>{})!;
        expect(side.color, AppTheme.outlinedBorderOn(b, b == Brightness.dark ? AppFamilies.cyan : AppFamilies.sky), reason: b.name);
        expect(side.width, 1.5);
        expect(style.side!.resolve({WidgetState.disabled})!.color, SurfaceTokens.of(b).rimSolid, reason: 'pasif bilerek sönük');
      }
    });

    test('AÇIKTA eski tema kenarı (sky@0.70 ≈ 2.4:1) artık yok: varsayılan çerçeve pastel mavi değil', () {
      final side = themes[Brightness.light]!().outlinedButtonTheme.style!.side!.resolve(<WidgetState>{})!;
      final old = Color.alphaBlend(AppFamilies.sky.base.withValues(alpha: 0.70), Colors.white);
      expect(AppTheme.contrastRatio(old, Colors.white), lessThan(3.0), reason: 'eski kenar yetersizdi (kanıt)');
      expect(side.color.a, 1.0, reason: 'açıkta opak');
      expect(AppTheme.contrastRatio(side.color, Colors.white), greaterThanOrEqualTo(3.0));
      expect(AppTheme.contrastRatio(side.color, AppTheme.bgLight), greaterThanOrEqualTo(3.0));
    });

    testWidgets('accentOutlinedButtonStyle: kenar = AppTheme.outlinedBorder (her aile, iki tema); pasifte tema kenarı', (tester) async {
      for (final b in Brightness.values) {
        final ctx = await contextFor(tester, themes[b]!());
        for (final family in AppFamilies.all) {
          final style = accentOutlinedButtonStyle(ctx, family);
          final side = style.side!.resolve(<WidgetState>{})!;
          expect(side.color, AppTheme.outlinedBorder(ctx, family), reason: '${b.name} ${family.name}');
          expect(side.width, 1.5);
          expect(style.side!.resolve({WidgetState.disabled}), isNull, reason: 'pasifte tema çerçevesi geçerli');
          expect(worstOver(side.color, surfacesFor(b)), greaterThanOrEqualTo(3.0), reason: '${b.name} ${family.name}');
        }
      }
    });

    testWidgets('AÇIKTA aynı ekranda İKİ farklı çerçeve tonu YOK: tema varsayılanı == accentOutlinedButtonStyle(sky)', (tester) async {
      final theme = themes[Brightness.light]!();
      final ctx = await contextFor(tester, theme);
      final themeSide = theme.outlinedButtonTheme.style!.side!.resolve(<WidgetState>{})!;
      final accentSide = accentOutlinedButtonStyle(ctx, AppFamilies.sky).side!.resolve(<WidgetState>{})!;
      expect(accentSide.color, themeSide.color);
      expect(accentSide.width, themeSide.width);
    });

    test('açık: yeterli tonlar DEĞİŞMEZ (sky/rose/violet = base), yetersizler yalnız koyulaşır (ton korunur); hepsi opak', () {
      for (final family in [AppFamilies.sky, AppFamilies.rose, AppFamilies.violet]) {
        expect(AppTheme.outlinedBorderOn(Brightness.light, family), family.base, reason: family.name);
      }
      for (final family in [AppFamilies.amber, AppFamilies.emerald, AppFamilies.cyan]) {
        final border = AppTheme.outlinedBorderOn(Brightness.light, family);
        final before = HSLColor.fromColor(family.base);
        final after = HSLColor.fromColor(border);
        expect(after.lightness, lessThan(before.lightness), reason: '${family.name} koyulaşır');
        var hueDelta = (before.hue - after.hue).abs();
        if (hueDelta > 180) hueDelta = 360 - hueDelta;
        expect(hueDelta, lessThan(12), reason: '${family.name}: ton korunur');
      }
      for (final family in AppFamilies.all) {
        expect(AppTheme.outlinedBorderOn(Brightness.light, family).a, 1.0, reason: family.name);
      }
    });

    test('koyu: alfa 0.70\'ten başlar (amber/emerald/cyan 0.70\'te kalır); sky/rose/violet 3:1 için artar', () {
      for (final family in [AppFamilies.amber, AppFamilies.emerald, AppFamilies.cyan]) {
        expect(AppTheme.outlinedBorderOn(Brightness.dark, family), family.base.withValues(alpha: AppTheme.outlineBaseAlpha), reason: family.name);
      }
      for (final family in [AppFamilies.sky, AppFamilies.rose, AppFamilies.violet]) {
        final border = AppTheme.outlinedBorderOn(Brightness.dark, family);
        expect(border.a, greaterThan(AppTheme.outlineBaseAlpha), reason: family.name);
        // Eski kural (family.base@0.70) bu ailelerde 3:1'i vermiyordu (eleştirmen: sky 2.8, rose 2.8, violet 2.7).
        expect(worstOver(family.base.withValues(alpha: 0.70), surfacesFor(Brightness.dark)), lessThan(3.0), reason: '${family.name} eski kural yetersiz (kanıt)');
        expect(border.hue(), closeTo(HSLColor.fromColor(family.base).hue, 0.5), reason: '${family.name}: ton korunur');
      }
    });

    test('nötr (slate) de AYNI kuralı izler (özel durum yok): açıkta slate.base, koyuda bir kademe açık; alan çerçevesiyle aynı ≥ 3:1 ailesi', () {
      expect(AppTheme.outlinedBorderOn(Brightness.light, AppFamilies.slate), AppFamilies.slate.base, reason: 'açıkta zaten ≥ 3.2:1');
      final dark = AppTheme.outlinedBorderOn(Brightness.dark, AppFamilies.slate);
      expect(dark.a, 1.0, reason: 'koyuda slate opak ton bile 3.2:1 vermez: açıklık artar');
      expect(HSLColor.fromColor(dark).lightness, greaterThan(HSLColor.fromColor(AppFamilies.slate.base).lightness));
      // Alan çerçevesinin (≥ 3:1) hemen yanında: iki nötr bileşen sınırı aynı ailede.
      expect((AppTheme.contrastRatio(dark, AppTheme.cardDark) - AppTheme.contrastRatio(AppTheme.fieldBorderDark, AppTheme.cardDark)).abs(), lessThan(0.5));
    });

    testWidgets('outlinedBorder bağlamlı = bağlamsız; outlinedSide 1.5 dp; outlinedBorderOfColor ham rengi ailesine oturtur', (tester) async {
      for (final b in Brightness.values) {
        final ctx = await contextFor(tester, themes[b]!());
        for (final family in AppFamilies.all) {
          expect(AppTheme.outlinedBorder(ctx, family), AppTheme.outlinedBorderOn(b, family));
          expect(AppTheme.outlinedSide(ctx, family).color, AppTheme.outlinedBorderOn(b, family));
          expect(AppTheme.outlinedSide(ctx, family).width, 1.5);
        }
        // Ham amber (#F59E0B) ve ana amber aynı aileye oturur: AYNI kenar.
        expect(AppTheme.outlinedBorderOfColor(ctx, AppTheme.accentAmber), AppTheme.outlinedBorderOn(b, AppFamilies.amber));
        expect(AppTheme.outlinedBorderOfColor(ctx, AppTheme.accentRed), AppTheme.outlinedBorderOn(b, AppFamilies.rose));
        // Aileye yakın olmayan renk: kendi renginden türer, yine ≥ 3:1.
        const lime = Color(0xFF84CC16);
        expect(ButtonTone.familyFor(lime), isNull);
        expect(worstOver(AppTheme.outlinedBorderOfColor(ctx, lime), surfacesFor(b)), greaterThanOrEqualTo(3.0), reason: 'lime ${b.name}');
        // Çok koyu özel renk (koyu temada kartta görünmezdi): açıklık artırılır.
        const navy = Color(0xFF1E3A8A);
        expect(worstOver(AppTheme.outlinedBorderOfColor(ctx, navy), surfacesFor(b)), greaterThanOrEqualTo(3.0), reason: 'navy ${b.name}');
      }
    });

    // Gerçek piksellerle: kenarın GERÇEKTEN çizilen rengi zeminde ≥ 3:1 (formül değil, boyanan sonuç).
    Future<double> borderPixelContrast(WidgetTester tester, ThemeData theme, Color surface, Widget Function(BuildContext) button) async {
      final key = GlobalKey();
      tester.view.physicalSize = const Size(600, 300);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            backgroundColor: surface,
            body: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: surface,
                child: Center(child: SizedBox(width: 240, child: Builder(builder: button))),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundaryOrigin = tester.getTopLeft(find.byKey(key));
      final rect = tester.getRect(find.byType(OutlinedButton)).shift(-boundaryOrigin);
      final data = await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        final image = await boundary.toImage(pixelRatio: 2);
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba), image.width);
      });
      final bytes = data!.$1!;
      final width = data.$2;
      Color at(int x, int y) {
        final o = (y * width + x) * 4;
        return Color.fromARGB(255, bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2));
      }

      // Düğmenin üst kenarı: orta sütunda, kenarın çevresindeki piksellerin en yüksek zemin kontrastı = kenar çizgisi.
      final x = ((rect.left + rect.right) / 2 * 2).round();
      var best = 0.0;
      for (var y = ((rect.top - 3) * 2).round(); y <= ((rect.top + 4) * 2).round(); y++) {
        final c = AppTheme.contrastRatio(at(x, y), surface);
        if (c > best) best = c;
      }
      return best;
    }

    for (final b in Brightness.values) {
      testWidgets('${b.name}: GERÇEK çizimde tema ve accent çerçeveli düğme kenarı zeminde ≥ 3:1 (her aile)', (tester) async {
        final theme = themes[b]!();
        final surfaces = b == Brightness.dark ? [AppTheme.cardDark, SurfaceTokens.dark.cardBottom] : [Colors.white, AppTheme.bgLight];
        for (final surface in surfaces) {
          final themed = await borderPixelContrast(tester, theme, surface, (_) => OutlinedButton(onPressed: () {}, child: const Text('Çerçeve')));
          expect(themed, greaterThanOrEqualTo(3.0), reason: '${b.name} tema varsayılanı / $surface');
          for (final family in AppFamilies.all) {
            final accent = await borderPixelContrast(
              tester,
              theme,
              surface,
              (ctx) => OutlinedButton(onPressed: () {}, style: accentOutlinedButtonStyle(ctx, family), child: Text(family.name)),
            );
            expect(accent, greaterThanOrEqualTo(3.0), reason: '${b.name} ${family.name} / $surface');
          }
        }
      });
    }
  });

  // -----------------------------------------------------------------------------------------
  // (3) Pasif gradyan düğme: OPAK cam
  // -----------------------------------------------------------------------------------------
  group('pasif gradyan düğme: opak cam yüzey', () {
    for (final b in Brightness.values) {
      final dark = b == Brightness.dark;
      test('${b.name}: pasif dolgu OPAK; tema pasif etiketi opak `muted` ve kendi zemininde ≥ 4.5:1', () {
        final fill = ToneButtonSurface.disabledFillOf(dark);
        expect(fill.a, 1.0, reason: 'opak: devre izleri etiketin altından geçmez');
        final style = themes[b]!().elevatedButtonTheme.style!;
        final muted = dark ? AppTheme.textMuted : AppTheme.textMutedLight;
        final fg = style.foregroundColor!.resolve({WidgetState.disabled})!;
        final icon = style.iconColor!.resolve({WidgetState.disabled})!;
        expect(fg, muted);
        expect(icon, muted);
        expect(fg.a, 1.0, reason: 'etiket de opak (eskiden muted@0.75 ≈ 3.3:1 idi)');
        expect(AppTheme.contrastRatio(fg, fill), greaterThanOrEqualTo(4.5), reason: '${b.name} etiket pasif zeminde AA');
        expect(AppTheme.contrastRatio(fg, fill), greaterThanOrEqualTo(4.5));
        // FilledButton da aynı birincil stil.
        expect(themes[b]!().filledButtonTheme.style!.foregroundColor!.resolve({WidgetState.disabled}), muted);
      });
    }

    for (final b in Brightness.values) {
      testWidgets('${b.name}: GERÇEK çizim: pasif düğmenin iç yüzeyi arkadaki desenden etkilenmez (opak), etiket AA', (tester) async {
        final dark = b == Brightness.dark;
        final key = GlobalKey();
        tester.view.physicalSize = const Size(800, 300);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: themes[b]!(),
            home: Scaffold(
              backgroundColor: Colors.transparent,
              body: RepaintBoundary(
                key: key,
                child: Stack(
                  children: [
                    // Yüksek karşıtlıklı dikey şeritler: yarı saydam yüzeyin içinden mutlaka görünürdü.
                    Positioned.fill(child: CustomPaint(painter: _StripesPainter(dark ? Colors.white : Colors.black))),
                    Center(
                      child: SizedBox(
                        width: 360,
                        child: ElevatedButton(
                          onPressed: null,
                          style: accentButtonStyle(AppFamilies.emerald),
                          child: const Text('Devreye Almayı Tamamla'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final origin = tester.getTopLeft(find.byKey(key));
        final rect = tester.getRect(find.byType(ElevatedButton)).shift(-origin);
        final data = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = await boundary.toImage(pixelRatio: 2);
          return (await image.toByteData(format: ui.ImageByteFormat.rawRgba), image.width);
        });
        final bytes = data!.$1!;
        final width = data.$2;
        Color at(double lx, double ly) {
          final o = (ly * 2).round() * width * 4 + (lx * 2).round() * 4;
          return Color.fromARGB(255, bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2));
        }

        // Etiketin dışında kalan sol/sağ iç bölge (pill'in dönüş yarıçapının iç tarafı): şeritler görünmemeli.
        final fill = ToneButtonSurface.disabledFillOf(dark);
        final samples = <Color>[
          for (var dx = 0.0; dx < 24; dx += 1.0) at(rect.left + 26 + dx, rect.center.dy),
          for (var dx = 0.0; dx < 24; dx += 1.0) at(rect.right - 50 + dx, rect.center.dy),
        ];
        for (final c in samples) {
          expect((c.r - fill.r).abs() * 255, lessThan(2.0), reason: 'kırmızı bileşen dolgu ile aynı (şerit görünmez)');
          expect((c.g - fill.g).abs() * 255, lessThan(2.0));
          expect((c.b - fill.b).abs() * 255, lessThan(2.0));
        }
        // Etiket de opak yüzeyde okunur: düğme içindeki en yüksek kontrast (etiket pikselleri) ≥ 4.5:1.
        var bestText = 0.0;
        for (var y = rect.center.dy - 8; y <= rect.center.dy + 8; y += 0.5) {
          for (var x = rect.center.dx - 90; x <= rect.center.dx + 90; x += 0.5) {
            final c = AppTheme.contrastRatio(at(x, y), fill);
            if (c > bestText) bestText = c;
          }
        }
        expect(bestText, greaterThanOrEqualTo(4.5), reason: '${b.name}: pasif etiket kendi zemininde AA (en iyi piksel)');
      });
    }

    test('yerel disabledBackgroundColor varsa saygı: nötr dolgu ÇİZİLMEZ (renk Material katmanında)', () {
      // (tone_button_test'te widget düzeyinde pinli; burada yalnız sabitin iki temada farklı ve opak olduğu doğrulanır)
      expect(ToneButtonSurface.disabledFillDark, isNot(ToneButtonSurface.disabledFillLight));
      expect(ToneButtonSurface.disabledFillOf(true), ToneButtonSurface.disabledFillDark);
      expect(ToneButtonSurface.disabledFillOf(false), ToneButtonSurface.disabledFillLight);
    });
  });

  // -----------------------------------------------------------------------------------------
  // (4) AppBar scrolled-under
  // -----------------------------------------------------------------------------------------
  group('AppBar: scrolled-under tonu YOK', () {
    for (final b in Brightness.values) {
      test('${b.name}: appBarTheme scrolledUnderElevation 0 ve surfaceTint saydam', () {
        final t = themes[b]!();
        expect(t.appBarTheme.scrolledUnderElevation, 0);
        expect(t.appBarTheme.surfaceTintColor, Colors.transparent);
        expect(t.appBarTheme.backgroundColor, Colors.transparent);
        expect(t.appBarTheme.elevation, 0);
      });

      testWidgets('${b.name}: düz AppBar kaydırılınca tonlanmaz (Material saydam, yükseltme 0, tint saydam)', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themes[b]!(),
            home: Scaffold(
              appBar: AppBar(title: const Text('Yeni Kurulum')),
              body: ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('satır $i'))]),
            ),
          ),
        );
        Material appBarMaterial() => tester.widget<Material>(
              find.descendant(of: find.byType(AppBar), matching: find.byType(Material)).first,
            );
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
        final m = appBarMaterial();
        expect(m.elevation, 0, reason: 'kaydırılmış çubukta yükseltme yok');
        expect(m.surfaceTintColor, Colors.transparent, reason: 'M3 yüzey tonu yok');
        expect(m.color, Colors.transparent);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('NeonAppBar: cam disk gölgesi çubuğun alt kenarında KESİLMEZ', () {
    testWidgets('AppBar araç çubuğu kırpmaz (Clip.none); açık temada disk gölgesi çubuk dışına gerçekten taşar (piksel)', (tester) async {
      // flutter_test gölgeleri sert bloklara çevirir (blur kapalı): yumuşak gölgenin çubuk dışına taşmasını ölçmek için açılır
      // (golden_support.expectGolden ile aynı yöntem; değişmezlik denetimi için test sonunda geri alınır).
      debugDisableShadows = false;
      try {
        final key = GlobalKey();
        tester.view.physicalSize = const Size(800, 400);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: themes[Brightness.light]!(),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                backgroundColor: Colors.white,
                appBar: NeonAppBar(
                  title: 'Başlık',
                  automaticallyImplyLeading: false,
                  actions: [NeonBarAction(key: const Key('act'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: () {})],
                ),
                body: const ColoredBox(color: Colors.white, child: SizedBox.expand()),
              ),
            ),
          ),
        );
        await tester.pump();
        final appBar = tester.widget<AppBar>(find.byType(AppBar));
        expect(appBar.clipBehavior, Clip.none);
        for (final clip in tester.widgetList<ClipRect>(find.descendant(of: find.byType(AppBar), matching: find.byType(ClipRect)))) {
          expect(clip.clipBehavior, Clip.none, reason: 'araç çubuğu içeriği kırpılmaz');
        }
        final disk = tester.getRect(find.byKey(const Key('act')));
        final barBottom = tester.getRect(find.byType(AppBar)).bottom;
        expect(barBottom, 64);
        final data = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = await boundary.toImage(pixelRatio: 2);
          return (await image.toByteData(format: ui.ImageByteFormat.rawRgba), image.width);
        });
        final bytes = data!.$1!;
        final width = data.$2;
        int redAt(double lx, double ly) => bytes.getUint8((ly * 2).round() * width * 4 + (lx * 2).round() * 4);
        // Disk merkezinin hemen altında, çubuğun ALT KENARININ 1-2 dp dışında: gölge beyazı koyulaştırmalı.
        final reference = redAt(8, barBottom + 1.5);
        final underDisk = redAt(disk.center.dx, barBottom + 1.5);
        expect(reference, 255, reason: 'uzak nokta saf beyaz');
        expect(underDisk, lessThan(reference - 2), reason: 'gölge çubuk sınırında kesilmedi (kesilseydi saf beyaz kalırdı): $underDisk');
        // Sınırda basamak YOK: çubuğun hemen içi (barBottom-1.5) ile dışı (barBottom+1.5) arasında sıçrama küçük.
        final inside = redAt(disk.center.dx, barBottom - 1.5);
        expect((inside - underDisk).abs(), lessThan(8), reason: 'çubuk sınırında yatay bant (basamak) yok');
      } finally {
        debugDisableShadows = true;
      }
    });
  });

  // -----------------------------------------------------------------------------------------
  // (6) Pasif iz belirteci
  // -----------------------------------------------------------------------------------------
  group('pasif iz belirteci (getInactiveTrack)', () {
    for (final b in Brightness.values) {
      test('${b.name}: kart/diyalog/sayfa yüzeylerinde ≥ 3:1 (nokta, halka izi, çevrimdışı iz)', () {
        final c = AppTheme.inactiveTrackOn(b);
        expect(c.a, 1.0, reason: 'opak');
        for (final s in surfacesFor(b)) {
          expect(AppTheme.contrastRatio(c, s), greaterThanOrEqualTo(3.0), reason: '${b.name} / $s');
        }
        expect(c, b == Brightness.dark ? AppTheme.fieldBorderDark : AppTheme.fieldBorderLight, reason: 'alan çerçevesiyle aynı nötr ton');
      });
    }

    testWidgets('bağlamlı getInactiveTrack = bağlamsız; eski ServiceStepDots tonundan (muted@0.28 ≈ 1.5:1) çok daha belirgin', (tester) async {
      for (final b in Brightness.values) {
        final ctx = await contextFor(tester, themes[b]!());
        expect(AppTheme.getInactiveTrack(ctx), AppTheme.inactiveTrackOn(b));
        final muted = b == Brightness.dark ? AppTheme.textMuted : AppTheme.textMutedLight;
        final oldDot = Color.alphaBlend(muted.withValues(alpha: 0.28), SurfaceTokens.of(b).cardTop);
        expect(AppTheme.contrastRatio(oldDot, SurfaceTokens.of(b).cardTop), lessThan(2.0), reason: 'eski nokta yetersizdi (kanıt)');
        expect(AppTheme.contrastRatio(AppTheme.getInactiveTrack(ctx), SurfaceTokens.of(b).cardTop), greaterThanOrEqualTo(3.0));
      }
    });
  });

  // -----------------------------------------------------------------------------------------
  // (7) Açık temada soluk orb + kaydırıcı başparmağı
  // -----------------------------------------------------------------------------------------
  group('açık tema: soluk (dimmed / salt-okunur AÇIK) orb etkinden baskın değil', () {
    final lightSurfaces = <Color>[Colors.white, SurfaceTokens.light.cardBottom, AppTheme.bgLight];

    test('soluk orb kenarı kartta ≥ 3:1 (her aile) ve ESKİ devre dışı kenarından (≈ 5.0:1) hafif', () {
      for (final family in AppFamilies.all) {
        final colors = OrbColors.mutedFamily(family, Brightness.light, OrbCore.mutedFamilyMix);
        for (final surface in lightSurfaces) {
          for (final rim in [colors.rimStart, colors.rimEnd]) {
            final c = AppTheme.contrastRatio(Color.alphaBlend(rim, surface), surface);
            expect(c, greaterThanOrEqualTo(3.0), reason: '${family.name} kenar / $surface');
            expect(c, lessThan(4.6), reason: '${family.name}: eskiden slate.deep@0.75 ≈ 5:1 idi (sayfanın en koyu konturu)');
          }
        }
      }
    });

    test('soluk orb simgesi TEK soluk mürekkep (hiçbir ailede near-black\'e düşmez) ve gövdede ≥ 3.3:1', () {
      final inks = <Color>{};
      for (final family in AppFamilies.all) {
        final colors = OrbColors.mutedFamily(family, Brightness.light, OrbCore.mutedFamilyMix);
        inks.add(colors.icon);
        expect(colors.icon, OrbColors.glass(Brightness.light).icon, reason: '${family.name}: tek mürekkep (glass simgesi)');
        for (final body in [colors.light, colors.base, Color.lerp(colors.base, colors.deep, 0.3)!]) {
          expect(AppTheme.contrastRatio(colors.icon, body), greaterThanOrEqualTo(3.3), reason: '${family.name} gövde $body');
        }
      }
      expect(inks, hasLength(1));
      expect(AppTheme.contrastRatio(inks.single, Colors.black), greaterThan(2.5), reason: 'near-black değil');
    });

    test('soluk gövde PASTEL: etkin gövdeden AÇIK ve daha az doygun (bej/haki karışımı yok)', () {
      for (final family in AppFamilies.all) {
        if (family == AppFamilies.slate) continue;
        final muted = OrbColors.mutedFamily(family, Brightness.light, OrbCore.mutedFamilyMix);
        final active = OrbColors.family(family);
        expect(muted.base.computeLuminance(), greaterThan(active.base.computeLuminance()), reason: '${family.name} gövde etkinden açık');
        expect(HSVColor.fromColor(muted.base).saturation, lessThan(HSVColor.fromColor(active.base).saturation), reason: '${family.name} (HSV: pastel daha az doygun)');
        expect(muted.glowScale, 0.0, reason: 'parıltı yok');
      }
    });

    test('aile hâlâ okunur: soluk gövde ailesinin tonuna yakın (amber sarımsı, sky mavimsi)', () {
      double hue(Color c) => HSLColor.fromColor(c).hue;
      double delta(double a, double b) {
        final d = (a - b).abs();
        return d > 180 ? 360 - d : d;
      }

      for (final family in [AppFamilies.amber, AppFamilies.emerald, AppFamilies.sky, AppFamilies.rose, AppFamilies.violet, AppFamilies.cyan]) {
        final muted = OrbColors.mutedFamily(family, Brightness.light, OrbCore.mutedFamilyMix);
        expect(delta(hue(muted.light), hue(family.light)), lessThan(30), reason: family.name);
      }
    });

    test('toggle geçişi: karışım 0 → devre dışı gri; arttıkça gövde pastele kayar (monoton)', () {
      for (final family in [AppFamilies.rose, AppFamilies.amber]) {
        final grey = OrbColors.disabled(Brightness.light);
        expect(OrbColors.mutedFamily(family, Brightness.light, 0.0), grey);
        double dist(Color a, Color b) => ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs());
        final half = OrbColors.mutedFamily(family, Brightness.light, 0.2);
        final full = OrbColors.mutedFamily(family, Brightness.light, 0.4);
        expect(dist(half.base, grey.base), lessThan(dist(full.base, grey.base)), reason: family.name);
      }
    });

    test('devre dışı (düz gri) açık orb: kenar kartta hâlâ ≥ 3:1 ama eskisinden hafif; simge `muted` metin rengi', () {
      final c = OrbColors.disabled(Brightness.light);
      expect(c.icon, AppTheme.textMutedLight);
      for (final surface in lightSurfaces) {
        for (final rim in [c.rimStart, c.rimEnd]) {
          final r = AppTheme.contrastRatio(Color.alphaBlend(rim, surface), surface);
          expect(r, greaterThanOrEqualTo(3.0));
        }
      }
      expect(AppTheme.contrastRatio(Color.alphaBlend(c.rimStart, Colors.white), Colors.white), lessThan(4.5), reason: 'eskiden ≈ 5.0:1');
    });

    test('KOYU tema soluk/devre dışı orb tarifi DEĞİŞMEDİ (yalnız açık tema düzeltildi)', () {
      final d = OrbColors.disabled(Brightness.dark);
      expect(d.icon, const Color(0xFFC3CEE0));
      expect(d.rimStart, AppFamilies.slate.light.withValues(alpha: 0.60));
      final m = OrbColors.mutedFamily(AppFamilies.rose, Brightness.dark, OrbCore.mutedFamilyMix);
      expect(m.rimStart, d.rimStart);
      expect(m.rimEnd, d.rimEnd);
    });
  });

  group('kaydırıcı başparmağı: açıkta beyaz kartta kaybolmaz', () {
    test('tema: açıkta outlined (ince koyu halka), koyuda değil', () {
      expect((themes[Brightness.light]!().sliderTheme.thumbShape! as OrbSliderThumbShape).outlined, isTrue);
      expect((themes[Brightness.dark]!().sliderTheme.thumbShape! as OrbSliderThumbShape).outlined, isFalse);
      expect(const OrbSliderThumbShape().outlined, isFalse, reason: 'varsayılan davranış korunur');
    });

    testWidgets('GERÇEK çizim: açık tonlu başparmağın kenarı beyaz kartta ≥ 3:1 (halka ile); halkasız < 3:1', (tester) async {
      Future<double> ringContrast({required bool outlined}) async {
        final key = GlobalKey();
        tester.view.physicalSize = const Size(700, 200);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: themes[Brightness.light]!(),
            home: Scaffold(
              backgroundColor: Colors.white,
              body: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: Colors.white,
                  child: Center(
                    child: SizedBox(
                      width: 300,
                      child: SliderTheme(
                        data: themes[Brightness.light]!().sliderTheme.copyWith(
                          thumbColor: AppFamilies.sky.light,
                          thumbShape: OrbSliderThumbShape(outlined: outlined),
                        ),
                        child: Slider(value: 0.4, onChanged: (_) {}),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final origin = tester.getTopLeft(find.byKey(key));
        final sliderRect = tester.getRect(find.byType(Slider)).shift(-origin);
        // Başparmak merkezi: iz [sol+24, sağ-24] (overlay 48 dp), değer 0.4.
        final cx = sliderRect.left + 24 + 0.4 * (sliderRect.width - 48);
        final cy = sliderRect.center.dy;
        final data = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = await boundary.toImage(pixelRatio: 2);
          return (await image.toByteData(format: ui.ImageByteFormat.rawRgba), image.width);
        });
        final bytes = data!.$1!;
        final width = data.$2;
        Color at(double lx, double ly) {
          final o = (ly * 2).round() * width * 4 + (lx * 2).round() * 4;
          return Color.fromARGB(255, bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2));
        }

        // Başparmağın dış kenarı (r ≈ 13): HER açıda en iyi (en koyu) kenar pikseli; sonra açılar arasında EN ZAYIF olan.
        // (Siluetin kopuk bir yayı varsa o yay kartta kaybolur: asıl ölçü en zayıf açıdır.)
        var weakest = double.infinity;
        for (var i = 0; i < 24; i++) {
          final a = i * math.pi * 2 / 24;
          var best = 0.0;
          for (var r = 11.5; r <= 13.5; r += 0.25) {
            final c = AppTheme.contrastRatio(at(cx + r * math.cos(a), cy + r * math.sin(a)), Colors.white);
            if (c > best) best = c;
          }
          if (best < weakest) weakest = best;
        }
        return weakest;
      }

      final withRing = await ringContrast(outlined: true);
      expect(withRing, greaterThanOrEqualTo(3.0), reason: 'halkalı başparmağın HER açısı beyaz kartta belirgin ($withRing)');
      // Halkasız açık tonlu başparmak (sky.light ≈ #93C5FD) kartta kaybolan yaylar taşırdı.
      final without = await ringContrast(outlined: false);
      expect(without, lessThan(3.0), reason: 'halkasız başparmak en zayıf açıda 3:1 vermiyordu (kanıt: $without)');
      expect(withRing, greaterThan(without), reason: 'halka kenarı belirgin biçimde koyulaştırır ($without → $withRing)');
    });
  });
}

extension on Color {
  double hue() => HSLColor.fromColor(this).hue;
}

class _StripesPainter extends CustomPainter {
  _StripesPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 3, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_StripesPainter oldDelegate) => oldDelegate.color != color;
}
