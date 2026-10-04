import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/theme/tone_button_surface.dart';
import 'package:ev_otomasyon/ui/widgets/accent_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design_support.dart';

/// `AccentFab` (WP-FX-A): düz #2563EB Material FAB'ın yerine gradyan + cila + 1 px kenar + renkli parıltı taşıyan birincil FAB.
/// Gerçek bir `FloatingActionButton` (şeffaf, yükseltmesiz) + ortak `ToneButtonSurface` yüzeyi.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  ThemeData themeOf(Brightness b) => guardedAppTheme(b);

  Future<void> pumpFab(
    WidgetTester tester,
    Widget fab, {
    Brightness brightness = Brightness.dark,
    double scale = 1.0,
    Size size = const Size(400, 800),
    Widget? body,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeOf(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: body ?? const SizedBox.expand(), floatingActionButton: fab),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder surfaceOf(Finder fab) => find.descendant(of: fab, matching: find.byType(ToneButtonSurface));

  DecoratedBox layer(WidgetTester tester, String key) =>
      tester.widget<DecoratedBox>(find.descendant(of: find.byType(AccentFab), matching: find.byKey(ValueKey<String>(key))));

  List<Color> gradientOf(DecoratedBox box) => ((box.decoration as BoxDecoration).gradient! as LinearGradient).colors;

  double scaleOf(WidgetTester tester) => tester
      .widgetList<Transform>(find.descendant(of: find.byType(ToneButtonSurface), matching: find.byType(Transform)))
      .first
      .transform
      .storage[0];

  group('görünüm: gradyan + cila + kenar + renkli parıltı (düz Material FAB DEĞİL)', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: genişletilmiş FAB tema birincil gradyanı (sky → koyu cyan), sheen, 1 px kenar, renkli glow', (tester) async {
        await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.person_add_alt_1_rounded, label: 'Hesap Ekle'), brightness: brightness);
        final tone = PrimaryButtonSurface.primaryTone;
        final base = layer(tester, 'tone_base');
        expect(gradientOf(base), [tone.start, tone.end], reason: 'düz #2563EB yerine tema birincil gradyanı');
        expect(gradientOf(base).toSet(), hasLength(2), reason: 'düz tek renkli dolgu DEĞİL: iki farklı uçlu gradyan (eski FAB düz #2563EB idi)');
        final shadow = (base.decoration as BoxDecoration).boxShadow!.single;
        expect(shadow.color.withValues(alpha: 1), tone.glow, reason: 'renkli glow (sky)');
        expect(shadow.blurRadius, 18);
        // Cila (üst beyaz → şeffaf) + 1 px parlak kenar.
        final sheen = layer(tester, 'tone_sheen').decoration as BoxDecoration;
        final sheenColors = (sheen.gradient! as LinearGradient).colors;
        expect(sheenColors.first.a, greaterThan(0.15));
        expect(sheenColors.last.a, 0);
        expect((sheen.border! as Border).top.width, 1);
        expect((sheen.border! as Border).top.color, Colors.white.withValues(alpha: 0.24));
        // Hap.
        expect((base.decoration as BoxDecoration).borderRadius, const BorderRadius.all(Radius.circular(AppRadius.pill)));
      });
    }

    testWidgets('altındaki FloatingActionButton ŞEFFAF ve yükseltmesiz (gradyanı örtmez; gölge/gradyan yüzeyden gelir)', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle'));
      final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(fab.backgroundColor, Colors.transparent);
      expect(fab.elevation, 0);
      expect(fab.highlightElevation, 0);
      expect(fab.hoverElevation, 0);
      expect(fab.focusElevation, 0);
      expect(fab.disabledElevation, 0);
      expect(fab.shape, isA<StadiumBorder>());
      expect((fab.shape! as StadiumBorder).side, BorderSide.none, reason: 'kenarı yüzey çizer (iki kat kenar yok)');
    });

    testWidgets('aile verilirse o ailenin tonu (rose gradyanı, rose glow)', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.delete_rounded, label: 'Sil', family: AppFamilies.rose));
      final tone = ButtonTone.fromFamily(AppFamilies.rose);
      expect(gradientOf(layer(tester, 'tone_base')), [tone.start, tone.end]);
      expect(((layer(tester, 'tone_base').decoration as BoxDecoration).boxShadow!.single.color).withValues(alpha: 1), tone.glow);
    });

    test('mürekkep (metin/simge) gradyanın her ucunda ≥ 4.5:1 (birincil ton ve tüm aileler)', () {
      expect(PrimaryButtonSurface.primaryTone.inkContrast, greaterThanOrEqualTo(4.5));
      for (final f in AppFamilies.all) {
        expect(ButtonTone.fromFamily(f).inkContrast, greaterThanOrEqualTo(4.5), reason: f.name);
      }
    });
  });

  group('varyantlar', () {
    testWidgets('genişletilmiş: simge + etiket; yükseklik 56 dp; Key doğrudan AccentFab\'ta tek widget', (tester) async {
      await pumpFab(tester, AccentFab(key: const Key('btn_add_account'), onPressed: () {}, icon: Icons.person_add_alt_1_rounded, label: 'Hesap Ekle'));
      expect(find.byKey(const Key('btn_add_account')), findsOneWidget);
      expect(tester.widget(find.byKey(const Key('btn_add_account'))), isA<AccentFab>());
      expect(find.text('Hesap Ekle'), findsOneWidget);
      expect(find.byIcon(Icons.person_add_alt_1_rounded), findsOneWidget);
      expect(tester.getSize(find.byType(FloatingActionButton)).height, AccentFab.size);
      expect(tester.getSize(find.byType(FloatingActionButton)).width, greaterThan(AccentFab.size * 2), reason: 'etiketli hap');
      expect(tester.getSize(surfaceOf(find.byType(AccentFab))), tester.getSize(find.byType(FloatingActionButton)));
    });

    testWidgets('yuvarlak: yalnız simge, 56×56 daire (hap yarıçapı kare kutuda daire)', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle'));
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      expect(tester.getSize(find.byType(FloatingActionButton)), const Size(AccentFab.size, AccentFab.size));
      expect(tester.getSize(surfaceOf(find.byType(AccentFab))), const Size(AccentFab.size, AccentFab.size));
      expect(AccentFab.size, greaterThanOrEqualTo(AppTouch.minTarget));
    });

    test('yuvarlak FAB tooltip olmadan kurulamaz (anlam etiketi zorunlu)', () {
      expect(() => AccentFab(onPressed: () {}, icon: Icons.add_rounded), throwsAssertionError);
      expect(() => AccentFab(onPressed: () {}, icon: Icons.add_rounded, label: 'Ekle'), returnsNormally);
      expect(() => AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle'), returnsNormally);
    });

    testWidgets('Hero varsayılan KAPALI (gradyansız saydam FAB uçuşu yok); heroTag verilirse açılır', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle'));
      expect(find.byType(Hero), findsNothing);
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle', heroTag: 'fab_a'));
      expect(find.byType(Hero), findsOneWidget);
    });
  });

  group('davranış: dokunuş gecikmesiz, basılı görünüm ANINDA, pasifte dokunuş yok', () {
    testWidgets('dokununca onPressed (aynı karede); Key ile bulunur', (tester) async {
      var taps = 0;
      await pumpFab(tester, AccentFab(key: const Key('btn_add_account'), onPressed: () => taps++, icon: Icons.person_add_alt_1_rounded, label: 'Hesap Ekle'));
      await tester.tap(find.byKey(const Key('btn_add_account')));
      expect(taps, 1, reason: 'gecikme/kuyruk yok');
    });

    testWidgets('basılı: yüzey parmak değdiği karede 0.97 ve glow sönümü; bırakınca 1.0 (tween yok)', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, label: 'Ekle'));
      expect(scaleOf(tester), 1.0);
      final restShadow = (layer(tester, 'tone_base').decoration as BoxDecoration).boxShadow!.single;
      final g = await tester.startGesture(tester.getCenter(find.byType(AccentFab)));
      await tester.pump(); // tek kare
      expect(scaleOf(tester), closeTo(ToneButtonSurface.pressedScale, 1e-9));
      final pressedShadow = (layer(tester, 'tone_base').decoration as BoxDecoration).boxShadow!.single;
      expect(pressedShadow.blurRadius, lessThan(restShadow.blurRadius));
      expect(pressedShadow.color.a, lessThan(restShadow.color.a));
      await g.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1.0);
    });

    testWidgets('parmak kayarsa (kaydırma) basılı görünüm bırakılır', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, label: 'Ekle'));
      final g = await tester.startGesture(tester.getCenter(find.byType(AccentFab)));
      await tester.pump();
      expect(scaleOf(tester), closeTo(0.97, 1e-9));
      await g.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(scaleOf(tester), 1.0);
      await g.up();
    });

    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: pasif (onPressed null): opak nötr cam, gradyan/gölge yok, dokunuş yok, anlam devre dışı', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpFab(tester, const AccentFab(onPressed: null, icon: Icons.add_rounded, label: 'Hesap Ekle'), brightness: brightness);
        final glass = layer(tester, 'tone_glass').decoration as BoxDecoration;
        expect(glass.gradient, isNull);
        expect(glass.boxShadow, isNull);
        expect(glass.color, ToneButtonSurface.disabledFillOf(brightness == Brightness.dark));
        expect(glass.color!.a, 1.0, reason: 'opak');
        expect(
          tester.getSemantics(find.byType(FloatingActionButton)),
          matchesSemantics(label: 'Hesap Ekle', isButton: true, hasEnabledState: true, isEnabled: false),
          reason: 'pasif: devre dışı düğme (dokunma/odak eylemi yok)',
        );
        // Pasif etiket kendi zemininde okunur (AA).
        final ink = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).foregroundColor!;
        expect(AppTheme.contrastRatio(ink, glass.color!), greaterThanOrEqualTo(4.5), reason: brightness.name);
        await tester.tap(find.byType(AccentFab), warnIfMissed: false);
        await tester.pump();
        expect(find.descendant(of: find.byType(ToneButtonSurface), matching: find.byType(Transform)), findsNothing, reason: 'pasifte basılı ölçek/görünüm yok');
        handle.dispose();
      });
    }

    testWidgets('klavye odağı: 2 px halka (mürekkep renginde); odak gidince 1 px', (tester) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle'));
      Border ring() => (layer(tester, 'tone_sheen').decoration as BoxDecoration).border! as Border;
      expect(ring().top.width, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab); // tek odaklanabilir öğe: FAB
      await tester.pump();
      expect(ring().top.width, 2, reason: 'odak halkası');
      expect(ring().top.color.withValues(alpha: 1), PrimaryButtonSurface.primaryTone.ink);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(ring().top.width, 1);
    });
  });

  group('erişilebilirlik ve yerleşim', () {
    testWidgets('anlam: düğme, etiket görünen metin; yuvarlakta tooltip anlam etiketi', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.person_add_alt_1_rounded, label: 'Hesap Ekle'));
      expect(
        tester.getSemantics(find.byType(FloatingActionButton)),
        matchesSemantics(
          label: 'Hesap Ekle',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Yeni ekle'));
      expect(
        tester.getSemantics(find.byType(FloatingActionButton)),
        matchesSemantics(
          tooltip: 'Yeni ekle',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    for (final scale in <double>[1.0, 1.5, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('${brightness.name}, yazı ölçeği x$scale, 360 dp: uzun etiket taşmaz, sağ alt köşede ekran içinde', (tester) async {
          await pumpFab(
            tester,
            AccentFab(onPressed: () {}, icon: Icons.person_add_alt_1_rounded, label: 'Müşteri Ekle'),
            brightness: brightness,
            scale: scale,
            size: const Size(360, 740),
          );
          expect(tester.takeException(), isNull);
          final rect = tester.getRect(find.byType(AccentFab));
          expect(rect.height, closeTo(AccentFab.size, 0.01));
          // (Birim testinde yazı tipi Ahem'dir: her glif 1 em genişliğinde; gerçek Inter/Roboto genişliği galeri PNG'lerinde
          // doğrulanır. Burada sağ-alt yerleşim ve taşma hatası yokluğu denetlenir.)
          expect(rect.right, lessThanOrEqualTo(360));
          expect(rect.bottom, lessThanOrEqualTo(740));
        });
      }
    }

    testWidgets('Scaffold yerleşimi/animasyonu: snackbar çıkınca FAB yukarı kayar, hatasız (gerçek FAB konumlanır)', (tester) async {
      await pumpFab(tester, AccentFab(onPressed: () {}, icon: Icons.add_rounded, label: 'Ekle'));
      final before = tester.getTopLeft(find.byType(AccentFab));
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).showSnackBar(const SnackBar(content: Text('İleti'), behavior: SnackBarBehavior.fixed));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(AccentFab)).dy, lessThan(before.dy));
      expect(tester.takeException(), isNull);
    });

    testWidgets('onPressed pasiften etkine geçince basılı durum sıfırlanır; pasife dönünce takılı kalmaz', (tester) async {
      var enabled = true;
      late StateSetter set;
      await tester.pumpWidget(
        MaterialApp(
          theme: themeOf(Brightness.dark),
          home: Scaffold(
            floatingActionButton: StatefulBuilder(builder: (context, setState) {
              set = setState;
              return AccentFab(onPressed: enabled ? () {} : null, icon: Icons.add_rounded, tooltip: 'Ekle');
            }),
          ),
        ),
      );
      final g = await tester.startGesture(tester.getCenter(find.byType(AccentFab)));
      await tester.pump();
      expect(scaleOf(tester), closeTo(0.97, 1e-9));
      set(() => enabled = false);
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('tone_glass')), findsOneWidget);
      await g.up();
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(ToneButtonSurface), matching: find.byType(Transform)), findsNothing, reason: 'pasifte basılı ölçek takılı kalmaz');
    });
  });
}
