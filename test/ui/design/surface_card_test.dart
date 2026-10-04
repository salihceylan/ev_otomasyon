import 'dart:ui' as ui;

import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/slider_shapes.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/surface_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `SurfaceCard` ve cam/orb bileşenlerinin ortak kuralları (BackdropFilter/Opacity yok, RepaintBoundary, dokunma).
void main() {
  SurfaceCard card({VoidCallback? onTap, Color? accent, bool active = false, String? label, PressHaptic haptic = PressHaptic.none, EdgeInsetsGeometry? margin}) => SurfaceCard(
        key: const Key('c'),
        accent: accent,
        active: active,
        onTap: onTap,
        semanticLabel: label,
        haptic: haptic,
        margin: margin,
        child: const Text('İçerik'),
      );

  group('SurfaceCard', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: gradyan gövde (AppTheme.glassDecoration) + gradyan rim + RepaintBoundary', (tester) async {
        await tester.pumpWidget(designHost(card(), brightness: brightness));
        expect(find.text('İçerik'), findsOneWidget);
        final box = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(DecoratedBox)).first);
        final decoration = box.decoration as BoxDecoration;
        final t = SurfaceTokens.of(brightness);
        expect((decoration.gradient as LinearGradient).colors, [t.cardTop, t.cardBottom]);
        expect(decoration.border, isNull, reason: 'rim gradyan olarak foregroundPainter\'da');
        expect(decoration.borderRadius, BorderRadius.circular(AppRadius.card));
        expect(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(RepaintBoundary)), findsWidgets);
        final paint = tester.widgetList<CustomPaint>(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(CustomPaint))).firstWhere((c) => c.foregroundPainter is SurfaceRimPainter);
        final rim = paint.foregroundPainter! as SurfaceRimPainter;
        expect((rim.rimStart, rim.rimEnd, rim.accent, rim.emphasized), (t.rimStart, t.rimEnd, null, false));
      });
    }

    testWidgets('active + accent: radyal parıltı gradyanı ve accent@0.55 rim; active accent olmadan sıradan kart', (tester) async {
      const accent = Color(0xFFFFB020);
      await tester.pumpWidget(designHost(card(accent: accent, active: true)));
      final decoration = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration;
      expect(decoration.gradient, isA<RadialGradient>());
      final rim = tester.widgetList<CustomPaint>(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(CustomPaint))).map((c) => c.foregroundPainter).whereType<SurfaceRimPainter>().single;
      expect(rim.emphasized, isTrue);
      expect(rim.accent, accent);

      await tester.pumpWidget(designHost(card(active: true)));
      final plain = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration;
      expect(plain.gradient, isA<LinearGradient>());
    });

    testWidgets('onTap: pointer-up ile eşzamanlı; pressed ölçeği parmak değdiği AN 0.985; haptik tek çağrı', (tester) async {
      final calls = recordHaptics(tester);
      var taps = 0;
      await tester.pumpWidget(designHost(card(onTap: () => taps++, haptic: PressHaptic.light), mode: MotionMode.full));
      final p = find.descendant(of: find.byKey(const Key('c')), matching: find.byType(Pressable));
      expect(pressableScale(tester, p), 1.0);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('c'))));
      await tester.pump();
      expect(pressableScale(tester, p), closeTo(0.985, 1e-9));
      await g.up();
      expect(taps, 1);
      expect(calls, ['HapticFeedbackType.lightImpact']);
      await tester.pumpAndSettle();
    });

    testWidgets('onTap yoksa Pressable YOK (pasif yüzey), dokunuş etkisiz', (tester) async {
      await tester.pumpWidget(designHost(card()));
      expect(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(Pressable)), findsNothing);
    });

    testWidgets('semanticLabel + onTap: tek button düğümü; etiketsiz kartta çocuk anlamı korunur', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(designHost(card(onTap: () {}, label: 'Salon Avize')));
      final node = tester.getSemantics(find.byKey(const Key('c')));
      expect(node.label, contains('Salon Avize'));
      expect(node.flagsCollection.isButton, isTrue);
      await tester.pumpWidget(designHost(card()));
      expect(find.bySemanticsLabel('İçerik'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('margin dışarıdan boşluk bırakır; yazı ölçeği 2.0 ve 320 dp ekranda taşma yok', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(designHost(SizedBox(width: double.infinity, child: card(margin: const EdgeInsets.all(12))), textScale: 2.0, center: false));
      expect(tester.takeException(), isNull);
      // SurfaceCard'ın kökü margin Padding'idir (320); kartın görünür yüzeyi iki yandan 12 dp içeridedir.
      expect(tester.getSize(find.byKey(const Key('c'))).width, 320);
      final surface = find.descendant(of: find.byKey(const Key('c')), matching: find.byType(DecoratedBox)).first;
      expect(tester.getSize(surface).width, 320 - 24);
      expect(tester.getTopLeft(surface).dx, 12);
    });
  });

  group('kural: BackdropFilter / Opacity yok, her animasyonlu orb RepaintBoundary içinde', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: kart + orb + cam düğme + iskelet ağaçta BackdropFilter/Opacity içermez', (tester) async {
        await tester.pumpWidget(
          designHost(
            Column(mainAxisSize: MainAxisSize.min, children: [
              card(accent: Colors.amber, active: true),
              OrbButton(icon: Icons.add, family: AppFamilies.sky, semanticLabel: 'a', onTap: () {}, active: true, pending: true),
              OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline, family: AppFamilies.amber, semanticLabel: 'b'),
              GlassIconButton(icon: Icons.menu, onTap: () {}, semanticLabel: 'c', showBadge: true),
              const SkeletonCard(),
            ]),
            mode: MotionMode.full,
            clock: AmbientClock.fixed(0.3),
            brightness: brightness,
          ),
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(Opacity), findsNothing);
        expect(find.byType(ImageFiltered), findsNothing);
        // Her orb gövdesi bir RepaintBoundary içindedir.
        for (final orb in [find.byType(OrbButton), find.byType(OrbToggle)]) {
          expect(find.descendant(of: orb, matching: find.byType(RepaintBoundary)), findsWidgets);
        }
        await tester.pumpWidget(designHost(const SizedBox()));
      });
    }
  });

  group('Slider özel şekilleri (tür KALIR)', () {
    testWidgets('gerçek pikseller: aktif iz mavi gradyan, pasif iz sönük, başparmak orb (speküler)', (tester) async {
      tester.view.physicalSize = const Size(400, 120);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: guardedAppTheme(Brightness.dark),
          home: Scaffold(
            backgroundColor: const Color(0xFF0B1120),
            body: RepaintBoundary(key: key, child: Center(child: SizedBox(width: 300, child: Slider(value: 0.5, onChanged: (_) {})))),
          ),
        ),
      );
      expect(find.byType(Slider), findsOneWidget);
      final centerY = tester.getCenter(find.byType(Slider)).dy;
      final thumbX = tester.getCenter(find.byType(Slider)).dx;
      final data = await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        final image = await boundary.toImage(pixelRatio: 1.0);
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba), image.width);
      });
      final bytes = data!.$1!;
      final width = data.$2;
      Color at(double x, double y) {
        final o = (y.round() * width + x.round()) * 4;
        return Color.fromARGB(255, bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2));
      }

      final active = at(thumbX - 60, centerY);
      final inactive = at(thumbX + 70, centerY);
      final thumbTop = at(thumbX, centerY - 7);
      // (Color.r/g/b/a 0..1 aralığındadır.)
      expect(active.b, greaterThan(0.58), reason: 'aktif iz parlak mavi gradyan');
      expect(active.r, lessThan(0.55));
      expect(active.computeLuminance(), greaterThan(inactive.computeLuminance() + 0.05), reason: 'pasif iz sönük');
      expect(inactive.b - inactive.r, lessThan(0.16), reason: 'pasif iz renksiz');
      expect(thumbTop.computeLuminance(), greaterThan(active.computeLuminance()), reason: 'başparmak üstünde speküler/açık ton');
    });

    test('OrbSliderThumbShape: basılıyken büyüme payı tercih edilen boyuta dahildir; devre dışı rengi kullanır', () {
      const shape = OrbSliderThumbShape(radius: 13);
      final size = shape.getPreferredSize(true, false);
      expect(size.width, greaterThanOrEqualTo(2 * 13 * 1.18 - 1e-9));
      expect(size.height, size.width);
    });

    testWidgets('pasif (onChanged null) kaydırıcı hatasız çizilir', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.lightTheme, home: const Scaffold(body: Center(child: Slider(value: 0.3, onChanged: null)))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('RTL: aktif iz sağdan başlar (hatasız)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: Center(child: Slider(value: 0.3, onChanged: (_) {})))),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
