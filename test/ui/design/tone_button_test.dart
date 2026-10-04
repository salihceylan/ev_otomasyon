// WP-V8 TONE: temanın düğme yüzeyi (PrimaryButtonSurface) düğmenin YEREL stilini okur; anlamsal renkli düğmeler
// (kırmızı/yeşil/amber/mor) mavi gradyana dönmez. accentButtonStyle / destructiveButtonStyle aynı ortak
// yüzeyi (ToneButtonSurface) kullanır.
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_style.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/theme/tone_button_surface.dart';
import 'package:ev_otomasyon/ui/widgets/settings/accent_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Çağrı yerlerinde (lib/ui/** taraması) düğme `backgroundColor:` olarak verilen renkler:
///  device_inventory_page 419 accentCyan · 814 accentAmber / accentGreen · replace_board_dialog 735 SetupColors.purple ·
///  wifi_recovery_dialog accentGreen · service_setup/** SetupColors.ok / error / warn / primary ·
///  welcome_cards / peace_notice_host / wifi_provision_panel / service_subscribers primaryBlue.
final Map<String, Color> _callSiteColors = <String, Color>{
  'AppTheme.accentCyan': AppTheme.accentCyan,
  'AppTheme.accentAmber': AppTheme.accentAmber,
  'AppTheme.accentGreen': AppTheme.accentGreen,
  'AppTheme.accentRed': AppTheme.accentRed,
  'AppTheme.accentPurple': AppTheme.accentPurple,
  'AppTheme.primaryBlue': AppTheme.primaryBlue,
  'AppTheme.primaryBlueLight': AppTheme.primaryBlueLight,
  'SetupColors.ok': SetupColors.ok,
  'SetupColors.warn': SetupColors.warn,
  'SetupColors.error': SetupColors.error,
  'SetupColors.info': SetupColors.info,
  'SetupColors.primary': SetupColors.primary,
  'SetupColors.purple': SetupColors.purple,
};

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  const label = 'Kaydet';

  ThemeData themeOf(Brightness b) => b == Brightness.dark ? AppTheme.darkTheme : AppTheme.lightTheme;

  Future<void> pumpIn(WidgetTester tester, Widget child, {Brightness brightness = Brightness.dark, double width = 400}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: themeOf(brightness),
        home: Scaffold(body: Center(child: SizedBox(width: width, child: Center(child: child)))),
      ),
    );
  }

  Widget elevated(ButtonStyle? style, {VoidCallback? onPressed, bool enabled = true, Key? key}) =>
      ElevatedButton(key: key, onPressed: enabled ? (onPressed ?? () {}) : null, style: style, child: const Text(label));

  Finder surfaceOf(Finder button) => find.descendant(of: button, matching: find.byType(ToneButtonSurface));

  Decoration decorationByKey(WidgetTester tester, Finder button, String key) => tester
      .widget<DecoratedBox>(find.descendant(of: surfaceOf(button), matching: find.byKey(ValueKey<String>(key))))
      .decoration;

  /// Gradyan yüzeyin katmanları (basılı "kuyu" HARİÇ): [0] gradyan + gölge, [1] parlaklık (sheen) + kenar.
  List<Decoration> layersOf(WidgetTester tester, Finder button) => <Decoration>[
        decorationByKey(tester, button, 'tone_base'),
        decorationByKey(tester, button, 'tone_sheen'),
      ];

  /// Pasif nötr cam yüzey.
  BoxDecoration glassOf(WidgetTester tester, Finder button) => decorationByKey(tester, button, 'tone_glass') as BoxDecoration;

  List<Color> gradientColors(Decoration d) => ((d as BoxDecoration).gradient! as LinearGradient).colors;

  double scaleOf(WidgetTester tester, Finder button) => tester
      .widgetList<Transform>(find.descendant(of: surfaceOf(button), matching: find.byType(Transform)))
      .first
      .transform
      .storage[0];

  // ---------------------------------------------------------------------------------------------------------
  group('Flutter davranışı: backgroundBuilder bağlamı düğmenin kendisidir (varsayımın kanıtı)', () {
    testWidgets('ElevatedButton / ElevatedButton.icon / FilledButton: context.widget yerel stili verir', (tester) async {
      final seen = <String, Widget>{};
      final localBg = <String, Color?>{};
      final localBgDisabled = <String, Color?>{};
      Widget spy(String tag, BuildContext ctx, Set<WidgetState> states, Widget? child) {
        final w = ctx.widget;
        seen[tag] = w;
        if (w is ButtonStyleButton) {
          localBg[tag] = w.style?.backgroundColor?.resolve(states);
          localBgDisabled[tag] = w.style?.backgroundColor?.resolve(<WidgetState>{WidgetState.disabled});
        }
        return child!;
      }

      // Düz Flutter teması (AppTheme YOK): davranış SDK'nındır, bizim temanın değil.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    backgroundBuilder: (c, s, ch) => spy('elevated', c, s, ch),
                  ),
                  child: const Text('E'),
                ),
                ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                  label: const Text('I'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    disabledBackgroundColor: Colors.blue,
                    backgroundBuilder: (c, s, ch) => spy('icon', c, s, ch),
                  ),
                ),
                FilledButton(
                  onPressed: () {},
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.purple,
                    backgroundBuilder: (c, s, ch) => spy('filled', c, s, ch),
                  ),
                  child: const Text('F'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(seen['elevated'], isA<ElevatedButton>());
      expect(seen['icon'], isA<ElevatedButton>());
      expect(seen['filled'], isA<FilledButton>());
      expect(seen.values.every((w) => w is ButtonStyleButton), isTrue);
      expect(localBg['elevated'], Colors.red);
      expect(localBg['icon'], Colors.green);
      expect(localBg['filled'], Colors.purple);
      // Devre dışı durumda yerel renk: `disabledBackgroundColor` verilmediyse null (Material tema rengine düşer).
      expect(localBgDisabled['icon'], Colors.blue);
      expect(localBgDisabled['elevated'], isNull);
    });

    testWidgets('durum değişince (basınç) builder yeni durumlarla yeniden çağrılır ve widget yine düğmedir', (tester) async {
      final calls = <Set<WidgetState>>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  backgroundBuilder: (c, s, ch) {
                    expect(c.widget, isA<ElevatedButton>());
                    calls.add({...s});
                    return ch!;
                  },
                ),
                child: const Text('B'),
              ),
            ),
          ),
        ),
      );
      final g = await tester.startGesture(tester.getCenter(find.text('B')));
      await tester.pump();
      expect(calls.any((s) => s.contains(WidgetState.pressed)), isTrue);
      await g.up();
      await tester.pumpAndSettle();
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('ButtonTone: aileler, çağrı yeri renkleri, mürekkep kontrastı (WCAG AA)', () {
    test('tüm aileler: mürekkep gradyanın HER ucunda (en açık uç dahil) ≥ 4.5:1', () {
      for (final family in AppFamilies.all) {
        final tone = ButtonTone.fromFamily(family);
        expect(tone.start.a, 1.0, reason: '${family.name} başlangıç opak');
        expect(tone.end.a, 1.0, reason: '${family.name} bitiş opak');
        expect(wcagContrast(tone.ink, tone.lightest), greaterThanOrEqualTo(4.5), reason: '${family.name} en açık uç');
        expect(wcagContrast(tone.ink, tone.darkest), greaterThanOrEqualTo(4.5), reason: '${family.name} en koyu uç');
        for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          expect(
            wcagContrast(tone.ink, Color.lerp(tone.start, tone.end, t)!),
            greaterThanOrEqualTo(4.5),
            reason: '${family.name} t=$t',
          );
        }
        expect(tone.inkContrast, greaterThanOrEqualTo(4.5), reason: family.name);
        expect(tone.glow, family.base, reason: '${family.name}: gölge rengi ailenin ana tonu');
      }
    });

    test('mürekkep politikası: açık aileler (amber, cyan) koyu mürekkep; diğerleri beyaz', () {
      for (final family in AppFamilies.all) {
        final bright = family == AppFamilies.amber || family == AppFamilies.cyan;
        expect(ButtonTone.fromFamily(family).ink, bright ? ButtonTone.darkInk : Colors.white, reason: family.name);
      }
    });

    test('gradyan açıktan koyuya (soldan sağa): ilk uç en açık; koyu mürekkepli tonlar açık, beyazlılar zengin', () {
      for (final family in AppFamilies.all) {
        final tone = ButtonTone.fromFamily(family);
        expect(tone.start.computeLuminance(), greaterThanOrEqualTo(tone.end.computeLuminance()), reason: family.name);
        expect(tone.lightest, tone.start, reason: family.name);
      }
    });

    test('çağrı yeri renkleri (AppTheme.* / SetupColors.*): her biri için mürekkep AA', () {
      for (final e in _callSiteColors.entries) {
        final tone = ButtonTone.fromColor(e.value);
        expect(wcagContrast(tone.ink, tone.lightest), greaterThanOrEqualTo(4.5), reason: '${e.key} -> ${tone.name}');
        expect(wcagContrast(tone.ink, tone.darkest), greaterThanOrEqualTo(4.5), reason: '${e.key} -> ${tone.name}');
      }
    });

    test('renk ailesine oturtma: anlamsal renkler kendi ailesine gider; gölge o renk', () {
      expect(ButtonTone.fromColor(AppTheme.accentGreen).name, 'emerald');
      expect(ButtonTone.fromColor(AppTheme.accentAmber).name, 'amber');
      expect(ButtonTone.fromColor(AppTheme.accentRed).name, 'rose');
      expect(ButtonTone.fromColor(AppTheme.accentCyan).name, 'cyan');
      expect(ButtonTone.fromColor(SetupColors.purple).name, 'violet');
      expect(ButtonTone.fromColor(AppFamilies.slate.base).name, 'slate');
      expect(ButtonTone.fromColor(const Color(0xFF94A3B8)).name, 'slate', reason: 'düşük doygunluk = nötr');
      for (final e in _callSiteColors.entries) {
        expect(ButtonTone.fromColor(e.value).glow, e.value, reason: '${e.key}: gölge rengi = o renk');
      }
      // Aile tam eşleşmesi: aynı aile tonları (accentButtonStyle ile yerel renk aynı görünür).
      for (final family in AppFamilies.all) {
        final viaColor = ButtonTone.fromColor(family.base);
        final viaFamily = ButtonTone.fromFamily(family);
        expect(viaColor.start, viaFamily.start, reason: family.name);
        expect(viaColor.end, viaFamily.end, reason: family.name);
        expect(viaColor.ink, viaFamily.ink, reason: family.name);
      }
    });

    test('hiçbir aileye yakın olmayan renk: kendi renginden türetilir (çökmez, AA)', () {
      const lime = Color(0xFF84CC16);
      expect(ButtonTone.familyFor(lime), isNull);
      final tone = ButtonTone.fromColor(lime);
      expect(tone.name, 'custom');
      expect(tone.inkContrast, greaterThanOrEqualTo(4.5));
    });

    test('renk taraması: ton/doygunluk/açıklık ızgarasında HER renk AA ve opak gradyan üretir', () {
      var checked = 0;
      for (var h = 0; h < 360; h += 12) {
        for (final s in [0.0, 0.25, 0.55, 0.85, 1.0]) {
          for (final l in [0.04, 0.12, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 0.98]) {
            final c = HSLColor.fromAHSL(1, h.toDouble(), s, l).toColor();
            final tone = ButtonTone.fromColor(c);
            expect(tone.inkContrast, greaterThanOrEqualTo(4.5), reason: '$c -> ${tone.name} ${tone.start} ${tone.end}');
            expect(tone.start.a, 1.0);
            expect(tone.end.a, 1.0);
            checked++;
          }
        }
      }
      expect(checked, greaterThan(1000));
    });

    test('aynı renk için tekrarlı çağrı aynı tonu verir (önbellek, kararlı)', () {
      final a = ButtonTone.fromColor(AppTheme.accentGreen);
      final b = ButtonTone.fromColor(AppTheme.accentGreen);
      expect(a.start, b.start);
      expect(a.end, b.end);
      expect(a.ink, b.ink);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Tema düğmesi yerel stili okur (genel çözüm; çağrı yerleri değişmeden)', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;

      testWidgets('${brightness.name}: yerel backgroundColor -> gradyan o rengin ailesinden, gölge o renkten', (tester) async {
        final cases = <Color, AccentFamily>{
          AppTheme.accentGreen: AppFamilies.emerald,
          AppTheme.accentAmber: AppFamilies.amber,
          AppTheme.accentRed: AppFamilies.rose,
          AppTheme.accentCyan: AppFamilies.cyan,
          SetupColors.purple: AppFamilies.violet,
        };
        for (final e in cases.entries) {
          await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: e.key)), brightness: brightness);
          final tone = ButtonTone.fromFamily(e.value);
          final layers = layersOf(tester, find.byType(ElevatedButton));
          expect(layers, hasLength(2), reason: e.value.name);
          expect(gradientColors(layers[0]), [tone.start, tone.end], reason: '${e.value.name} gradyan');
          final shadow = (layers[0] as BoxDecoration).boxShadow!.single;
          expect(shadow.color.withValues(alpha: 1), e.key, reason: '${e.value.name} gölge rengi = yerel renk');
          expect(
            gradientColors(layers[0]),
            isNot(equals([PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd])),
            reason: '${e.value.name}: mavi gradyana DÖNMEMELİ',
          );
        }
      });

      testWidgets('${brightness.name}: renksiz düğme ESKİ yüzeyle birebir (sky → cyan, sky gölge, hap, parlaklık, kenar)', (tester) async {
        await pumpIn(tester, elevated(null), brightness: brightness);
        final layers = layersOf(tester, find.byType(ElevatedButton));
        final base = layers[0] as BoxDecoration;
        expect((base.gradient! as LinearGradient).colors, [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd]);
        expect(base.borderRadius, const BorderRadius.all(Radius.circular(AppRadius.pill)));
        final shadow = base.boxShadow!.single;
        expect(shadow.color, AppFamilies.sky.base.withValues(alpha: dark ? 0.38 : 0.32));
        expect(shadow.blurRadius, 18);
        expect(shadow.offset, const Offset(0, 7));
        final sheen = layers[1] as BoxDecoration;
        expect(
          sheen.gradient,
          LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0)],
            stops: const [0.0, 0.58],
          ),
        );
        expect(sheen.borderRadius, const BorderRadius.all(Radius.circular(AppRadius.pill)));
        expect((sheen.border! as Border).top.color, Colors.white.withValues(alpha: 0.24));
        expect(scaleOf(tester, find.byType(ElevatedButton)), 1.0);
      });

      testWidgets('${brightness.name}: primaryBlue (tema birincil rengi) yerel renk verilse de varsayılan sky → cyan kalır', (tester) async {
        await pumpIn(
          tester,
          elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryBlue, foregroundColor: Colors.white)),
          brightness: brightness,
        );
        final layers = layersOf(tester, find.byType(ElevatedButton));
        expect(gradientColors(layers[0]), [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd]);
      });
    }

    testWidgets('yarı saydam / saydam yerel renk opak sayılmaz: varsayılan sky → cyan (eski davranış)', (tester) async {
      for (final c in [Colors.red.withValues(alpha: 0.4), Colors.transparent]) {
        await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: c)));
        final layers = layersOf(tester, find.byType(ElevatedButton));
        expect(gradientColors(layers[0]), [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd], reason: '$c');
      }
    });

    testWidgets('ElevatedButton.icon da yerel rengi okur (Clip.none varyantı)', (tester) async {
      await pumpIn(
        tester,
        ElevatedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.lightbulb_rounded),
          label: const Text(label),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber),
        ),
      );
      final tone = ButtonTone.fromFamily(AppFamilies.amber);
      expect(gradientColors(layersOf(tester, find.byType(ElevatedButton))[0]), [tone.start, tone.end]);
    });

    testWidgets('düğme başına tam 1 PrimaryButtonSurface (eski sözleşme) ve tam 1 ToneButtonSurface', (tester) async {
      await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen)));
      final button = find.byType(ElevatedButton);
      expect(find.descendant(of: button, matching: find.byType(PrimaryButtonSurface)), findsOneWidget);
      expect(find.descendant(of: button, matching: find.byType(ToneButtonSurface)), findsOneWidget);
    });

    testWidgets('PrimaryButtonSurface doğrudan: localStyle verilirse ton uygulanır, verilmezse varsayılan', (tester) async {
      Widget host(ButtonStyle? local) => MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: PrimaryButtonSurface(states: const <WidgetState>{}, dark: true, localStyle: local, child: const SizedBox(width: 100, height: 52)),
            ),
          );
      await tester.pumpWidget(host(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed)));
      expect(gradientColors(layersOf(tester, find.byType(PrimaryButtonSurface))[0]), [
        ButtonTone.fromFamily(AppFamilies.rose).start,
        ButtonTone.fromFamily(AppFamilies.rose).end,
      ]);
      await tester.pumpWidget(host(null));
      expect(gradientColors(layersOf(tester, find.byType(PrimaryButtonSurface))[0]), [
        PrimaryButtonSurface.gradientStart,
        PrimaryButtonSurface.gradientEnd,
      ]);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Şekil: yerel shape ile gradyan yüzey AYNI köşe yarıçapını kullanır', () {
    testWidgets('RoundedRectangleBorder(12): iki katman da 12; altında hap/dikdörtgen artığı yok', (tester) async {
      await pumpIn(
        tester,
        elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
      );
      for (final d in layersOf(tester, find.byType(ElevatedButton))) {
        expect((d as BoxDecoration).borderRadius, BorderRadius.circular(12));
      }
    });

    testWidgets('renksiz ama yerel shape: varsayılan gradyan, yerel yarıçap (welcome_cards / FilledButton 14)', (tester) async {
      await pumpIn(tester, elevated(ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))));
      final layers = layersOf(tester, find.byType(ElevatedButton));
      expect(gradientColors(layers[0]), [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd]);
      for (final d in layers) {
        expect((d as BoxDecoration).borderRadius, BorderRadius.circular(14));
      }
    });

    testWidgets('.icon + RoundedRectangleBorder(8) + yerel renk (device_inventory / service_subscribers kalıbı)', (tester) async {
      await pumpIn(
        tester,
        ElevatedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.person_add_alt_1, size: 16),
          label: const Text(label),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(48, 44),
            backgroundColor: AppTheme.accentCyan,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
      for (final d in layersOf(tester, find.byType(ElevatedButton))) {
        expect((d as BoxDecoration).borderRadius, BorderRadius.circular(8));
      }
    });

    testWidgets('StadiumBorder yerel shape = hap (999); daire gibi dikdörtgen olmayan şekil ShapeDecoration ile çizilir', (tester) async {
      await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed, shape: const StadiumBorder())));
      for (final d in layersOf(tester, find.byType(ElevatedButton))) {
        expect((d as BoxDecoration).borderRadius, const BorderRadius.all(Radius.circular(AppRadius.pill)));
      }
      await pumpIn(
        tester,
        elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed, shape: const BeveledRectangleBorder())),
      );
      final layers = layersOf(tester, find.byType(ElevatedButton));
      expect(layers, hasLength(2));
      expect(layers.every((d) => d is ShapeDecoration), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Devre dışı', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      // WP-FX-A (BİLİNÇLİ GÜNCELLEME): pasif cam dolgu eskiden yarı saydamdı (koyu white@0.08 = 0x14FFFFFF, açık #0B1016@0.06 =
      // 0x0F0B1016); sayfa gövdesinde duran pasif düğmenin içinden devre izleri/çip pinleri etiketin altından geçiyordu
      // (r2_wizard_a #1). Dolgu artık aynı cam tonunun kart/sayfa zeminine harmanlanmış OPAK hâlidir; gradyan ve gölge hâlâ
      // YOK, kenar aynı. (Eski sözleşmenin amacı korunur: pasif = renk DEĞİL, nötr cam; yeni: opak.)
      testWidgets('${brightness.name}: yerel renkli düğme devre dışıyken renk DEĞİL, OPAK nötr cam yüzey (gölgesiz, gradyansız)', (tester) async {
        await pumpIn(
          tester,
          elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed), enabled: false),
          brightness: brightness,
        );
        final glass = glassOf(tester, find.byType(ElevatedButton));
        expect(glass.gradient, isNull);
        expect(glass.boxShadow, isNull);
        expect(glass.color, ToneButtonSurface.disabledFillOf(dark));
        expect(glass.color!.a, 1.0, reason: 'opak: arkadaki devre izleri görünmez');
        expect(
          glass.color,
          Color.alphaBlend(
            dark ? const Color(0x0DFFFFFF) : const Color(0x0F0B1016),
            dark ? AppTheme.cardDark : AppTheme.bgLight,
          ),
          reason: 'aynı cam tonu (koyu white@0.05, açık #0B1016@0.06) kart/sayfa zeminine harmanlı',
        );
        expect((glass.border! as Border).top.color, dark ? const Color(0x1AFFFFFF) : const Color(0x140B1016));
        expect(
          find.descendant(of: surfaceOf(find.byType(ElevatedButton)), matching: find.byType(Transform)),
          findsNothing,
          reason: 'pasif yüzey ölçeklenmez',
        );
      });
    }

    testWidgets('yerel disabledBackgroundColor varsa saygı: nötr dolgu çizilmez, yalnız kenar (SetupPrimaryButton kalıbı)', (tester) async {
      await pumpIn(
        tester,
        elevated(
          ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentGreen,
            disabledBackgroundColor: AppTheme.accentGreen.withValues(alpha: 0.35),
            disabledForegroundColor: Colors.white70,
          ),
          enabled: false,
        ),
      );
      final glass = glassOf(tester, find.byType(ElevatedButton));
      expect(glass.color, isNull, reason: 'yerel pasif renk Material katmanında görünür; üstüne nötr cam bindirilmez');
      expect(glass.gradient, isNull);
      expect(glass.border, isNotNull);
      // Material'in kendi pasif rengi yerel renktir.
      final material = tester.widget<Material>(find.descendant(of: find.byType(ElevatedButton), matching: find.byType(Material)).first);
      expect(material.color, AppTheme.accentGreen.withValues(alpha: 0.35));
      // Pasif metin/simge rengi yerel `disabledForegroundColor`.
      expect(DefaultTextStyle.of(tester.element(find.text(label))).style.color, Colors.white70);
    });

    testWidgets('renksiz pasif düğme (eski sözleşme): ilk DecoratedBox gradyansız BoxDecoration', (tester) async {
      await pumpIn(tester, elevated(null, enabled: false));
      final box = tester.widgetList<DecoratedBox>(find.descendant(of: find.byType(PrimaryButtonSurface), matching: find.byType(DecoratedBox))).first;
      expect((box.decoration as BoxDecoration).gradient, isNull);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Basınç: ölçek 0.97 parmak değdiği karede, tween yok', () {
    testWidgets('yerel renkli düğme: basınçta 0.97 ve gölge sönümü ANINDA; bırakınca 1.0', (tester) async {
      await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber)));
      final button = find.byType(ElevatedButton);
      expect(scaleOf(tester, button), 1.0);
      final restShadow = (layersOf(tester, button)[0] as BoxDecoration).boxShadow!.single;
      final g = await tester.startGesture(tester.getCenter(find.text(label)));
      await tester.pump(); // tek kare: tween olsaydı ara değerde kalırdı
      expect(scaleOf(tester, button), closeTo(0.97, 1e-9));
      final pressedShadow = (layersOf(tester, button)[0] as BoxDecoration).boxShadow!.single;
      expect(pressedShadow.blurRadius, lessThan(restShadow.blurRadius));
      expect(pressedShadow.color.a, lessThan(restShadow.color.a));
      expect(pressedShadow.offset.dy, lessThan(restShadow.offset.dy));
      await g.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester, button), 1.0);
    });

    testWidgets('yerel renkli düğme basılıyken yüzeyin altında koyu "kuyu" olur (Material düz rengi halka çıkmaz); bırakınca kalkar', (tester) async {
      await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen)));
      final button = find.byType(ElevatedButton);
      final well = find.descendant(of: surfaceOf(button), matching: find.byKey(const ValueKey<String>('tone_well')));
      expect(well, findsNothing, reason: 'dinlenirken yüzey Material dolgusunu tamamen örter');
      final g = await tester.startGesture(tester.getCenter(find.text(label)));
      await tester.pump();
      expect(well, findsOneWidget);
      final tone = ButtonTone.fromFamily(AppFamilies.emerald);
      expect(
        gradientColors(tester.widget<DecoratedBox>(well).decoration),
        [Color.lerp(tone.start, Colors.black, 0.32), Color.lerp(tone.end, Colors.black, 0.32)],
        reason: 'kuyu, yüzey gradyanının koyulaştırılmışıdır (yerel düz renk DEĞİL)',
      );
      await g.up();
      await tester.pumpAndSettle();
      expect(well, findsNothing);
    });

    testWidgets('renksiz (yerel dolgusuz) düğme basılıyken kuyu YOK: eski görünüm', (tester) async {
      await pumpIn(tester, elevated(null));
      final button = find.byType(ElevatedButton);
      final g = await tester.startGesture(tester.getCenter(find.text(label)));
      await tester.pump();
      expect(find.descendant(of: surfaceOf(button), matching: find.byKey(const ValueKey<String>('tone_well'))), findsNothing);
      expect(scaleOf(tester, button), closeTo(0.97, 1e-9));
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('dokunuş çağrılır (yüzey girdiyi bloklamaz)', (tester) async {
      var taps = 0;
      await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan), onPressed: () => taps++));
      await tester.tap(find.text(label));
      expect(taps, 1);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Klavye odağı: opak yüzey Material odak katmanını örter, odak halkası yüzeyin kendisinde', () {
    setUp(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional);
    tearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);

    testWidgets('odaklı düğme: kenar 2 px ve mürekkep renginde (amber: koyu, rose: beyaz); odaksızda 1 px beyaz@0.24', (tester) async {
      for (final e in {AppTheme.accentAmber: ButtonTone.darkInk, AppTheme.accentRed: Colors.white}.entries) {
        await pumpIn(
          tester,
          ElevatedButton(autofocus: true, onPressed: () {}, style: ElevatedButton.styleFrom(backgroundColor: e.key), child: const Text(label)),
        );
        await tester.pump();
        final ring = (layersOf(tester, find.byType(ElevatedButton))[1] as BoxDecoration).border! as Border;
        expect(ring.top.width, 2, reason: '${e.key}');
        expect(ring.top.color.withValues(alpha: 1), e.value, reason: '${e.key}: halka mürekkep renginde (yüzeyde ≥ 4.5:1)');
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final rest = (layersOf(tester, find.byType(ElevatedButton))[1] as BoxDecoration).border! as Border;
      expect(rest.top.width, 1);
      expect(rest.top.color, Colors.white.withValues(alpha: 0.24));
    });

    testWidgets('FilledButton da odak halkası çizer (tema gradyanı Material odak katmanını örter)', (tester) async {
      await pumpIn(tester, FilledButton(autofocus: true, onPressed: () {}, child: const Text(label)));
      await tester.pump();
      final ring = (layersOf(tester, find.byType(FilledButton))[1] as BoxDecoration).border! as Border;
      expect(ring.top.width, 2);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Metin / simge mürekkebi', () {
    Color textColor(WidgetTester tester) => DefaultTextStyle.of(tester.element(find.text(label))).style.color!;
    Color iconColor(WidgetTester tester) => IconTheme.of(tester.element(find.byIcon(Icons.lightbulb_rounded))).color!;

    Widget iconButton(ButtonStyle? style) => ElevatedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.lightbulb_rounded),
          label: const Text(label),
          style: style,
        );

    testWidgets('yerel foregroundColor YOKSA: açık tonda (amber) koyu, koyu tonda (rose) beyaz mürekkep — metin ve simge', (tester) async {
      await pumpIn(tester, iconButton(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber)));
      expect(textColor(tester), ButtonTone.darkInk);
      expect(iconColor(tester), ButtonTone.darkInk, reason: 'tema iconColor (beyaz) yerel tona üstün gelmemeli');
      await pumpIn(tester, iconButton(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed)));
      expect(textColor(tester), Colors.white);
      expect(iconColor(tester), Colors.white);
    });

    testWidgets('yerel foregroundColor VARSA ona saygı (metin ve simge)', (tester) async {
      await pumpIn(
        tester,
        iconButton(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen, foregroundColor: const Color(0xFF111111))),
      );
      expect(textColor(tester), const Color(0xFF111111));
      expect(iconColor(tester), const Color(0xFF111111), reason: 'foregroundColor simgeye de uygulanır');
    });

    testWidgets('yerel iconColor yalnız simgeyi etkiler', (tester) async {
      await pumpIn(
        tester,
        iconButton(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen, foregroundColor: Colors.white, iconColor: Colors.amber)),
      );
      expect(textColor(tester), Colors.white);
      expect(iconColor(tester), Colors.amber);
    });

    testWidgets('renksiz varsayılan düğme: beyaz (tema) — davranış değişmedi', (tester) async {
      await pumpIn(tester, iconButton(null));
      expect(textColor(tester), Colors.white);
      expect(iconColor(tester), Colors.white);
    });

    testWidgets('uçtan uca: çizilen mürekkep, çizilen gradyanın en açık ucunda ≥ 4.5:1 (tüm çağrı yeri renkleri, koyu + açık tema)', (tester) async {
      for (final brightness in Brightness.values) {
        for (final e in _callSiteColors.entries) {
          await pumpIn(tester, iconButton(ElevatedButton.styleFrom(backgroundColor: e.value)), brightness: brightness);
          final colors = gradientColors(layersOf(tester, find.byType(ElevatedButton))[0]);
          final lightest = colors.reduce((a, b) => a.computeLuminance() >= b.computeLuminance() ? a : b);
          final darkest = colors.reduce((a, b) => a.computeLuminance() < b.computeLuminance() ? a : b);
          for (final ink in [textColor(tester), iconColor(tester)]) {
            expect(wcagContrast(ink, lightest), greaterThanOrEqualTo(4.5), reason: '${e.key} ${brightness.name} en açık uç');
            expect(wcagContrast(ink, darkest), greaterThanOrEqualTo(4.5), reason: '${e.key} ${brightness.name} en koyu uç');
          }
        }
      }
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Ortak gerçekleme: accentButtonStyle / destructiveButtonStyle', () {
    testWidgets('accentButtonStyle(aile) == yerel backgroundColor(aile.base): AYNI yüzey (tek gerçekleme)', (tester) async {
      for (final family in AppFamilies.all) {
        await pumpIn(tester, elevated(accentButtonStyle(family)));
        final viaApi = layersOf(tester, find.byType(ElevatedButton));
        await pumpIn(tester, elevated(ElevatedButton.styleFrom(backgroundColor: family.base)));
        final viaColor = layersOf(tester, find.byType(ElevatedButton));
        expect(viaApi, hasLength(2), reason: family.name);
        expect(viaApi[0], viaColor[0], reason: '${family.name} gradyan+gölge katmanı');
        expect(viaApi[1], viaColor[1], reason: '${family.name} parlaklık+kenar katmanı');
      }
    });

    testWidgets('destructiveButtonStyle() == accentButtonStyle(rose)', (tester) async {
      await pumpIn(tester, elevated(destructiveButtonStyle()));
      final destructive = layersOf(tester, find.byType(ElevatedButton));
      await pumpIn(tester, elevated(accentButtonStyle(AppFamilies.rose)));
      final rose = layersOf(tester, find.byType(ElevatedButton));
      expect(destructive, hasLength(2));
      expect(destructive[0], rose[0]);
      expect(destructive[1], rose[1]);
      final tone = ButtonTone.fromFamily(AppFamilies.rose);
      expect(gradientColors(destructive[0]), [tone.start, tone.end]);
    });

    testWidgets('AppTheme OLMADAN (düz ThemeData) da aynı görünür: yüzey stilin kendi backgroundBuilder ögesidir', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(onPressed: () {}, style: accentButtonStyle(AppFamilies.violet), child: const Text('A')),
                  ElevatedButton(onPressed: () {}, style: destructiveButtonStyle(), child: const Text('B')),
                ],
              ),
            ),
          ),
        ),
      );
      final violet = ButtonTone.fromFamily(AppFamilies.violet);
      final rose = ButtonTone.fromFamily(AppFamilies.rose);
      final surfaces = tester.widgetList<ToneButtonSurface>(find.byType(ToneButtonSurface)).toList();
      expect(surfaces, hasLength(2));
      expect(surfaces[0].tone.start, violet.start);
      expect(surfaces[0].dark, isFalse);
      expect(surfaces[1].tone.end, rose.end);
      expect(DefaultTextStyle.of(tester.element(find.text('A'))).style.color, Colors.white);
    });

    testWidgets('accentButtonStyle(null) tema düğmesi gibi (varsayılan sky → cyan); minimumSize uygulanır', (tester) async {
      await pumpIn(tester, elevated(accentButtonStyle(null, minimumSize: const Size(160, 60))));
      expect(gradientColors(layersOf(tester, find.byType(ElevatedButton))[0]), [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd]);
      expect(tester.getSize(find.byType(ElevatedButton)).height, greaterThanOrEqualTo(60));
    });

    testWidgets('accent / yıkıcı düğme devre dışıyken nötr cam yüzey', (tester) async {
      for (final style in [accentButtonStyle(AppFamilies.violet), destructiveButtonStyle()]) {
        await pumpIn(tester, elevated(style, enabled: false));
        final glass = glassOf(tester, find.byType(ElevatedButton));
        expect(glass.gradient, isNull);
        expect(glass.boxShadow, isNull);
      }
    });

    testWidgets('accent düğmede simge de aile mürekkebini alır (amber: koyu)', (tester) async {
      await pumpIn(
        tester,
        ElevatedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text(label),
          style: accentButtonStyle(AppFamilies.amber),
        ),
      );
      expect(IconTheme.of(tester.element(find.byIcon(Icons.swap_horiz_rounded))).color, ButtonTone.darkInk);
      expect(DefaultTextStyle.of(tester.element(find.text(label))).style.color, ButtonTone.darkInk);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('FilledButton: tema, ElevatedButton diliyle hizalı (tür DEĞİŞMEZ)', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: FilledButton gradyan yüzeyli, min 48, stadium; yerel primaryBlue varsayılan gradyan', (tester) async {
        final t = themeOf(brightness);
        expect(t.filledButtonTheme.style!.backgroundBuilder, isNotNull);
        expect(t.filledButtonTheme.style!.shape!.resolve({}), isA<StadiumBorder>());
        expect(t.filledButtonTheme.style!.minimumSize!.resolve({})!.height, 48);
        await pumpIn(tester, FilledButton(onPressed: () {}, child: const Text(label)), brightness: brightness);
        final button = find.byType(FilledButton);
        expect(find.descendant(of: button, matching: find.byType(PrimaryButtonSurface)), findsOneWidget);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(gradientColors(layersOf(tester, button)[0]), [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd]);
        expect(DefaultTextStyle.of(tester.element(find.text(label))).style.color, Colors.white);

        // peace_notice_host / welcome_cards kalıbı: yerel primaryBlue + beyaz.
        await pumpIn(
          tester,
          FilledButton(
            onPressed: () {},
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryBlue, foregroundColor: Colors.white),
            child: const Text(label),
          ),
          brightness: brightness,
        );
        expect(gradientColors(layersOf(tester, find.byType(FilledButton))[0]), [PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd]);
      });
    }

    testWidgets('FilledButton.icon + yerel şekil + renk: tema yüzeyi yerel yarıçap ve rengi uygular; pasifte cam', (tester) async {
      await pumpIn(
        tester,
        FilledButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.refresh),
          label: const Text(label),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.accentGreen, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        ),
      );
      final layers = layersOf(tester, find.byType(FilledButton));
      final tone = ButtonTone.fromFamily(AppFamilies.emerald);
      expect(gradientColors(layers[0]), [tone.start, tone.end]);
      expect((layers[0] as BoxDecoration).borderRadius, BorderRadius.circular(14));
      await pumpIn(tester, FilledButton(onPressed: null, child: const Text(label)));
      final glass = glassOf(tester, find.byType(FilledButton));
      expect(glass.gradient, isNull);
    });

    testWidgets('dokunma çalışır ve basınç ölçeği 0.97', (tester) async {
      var taps = 0;
      await pumpIn(tester, FilledButton(onPressed: () => taps++, child: const Text(label)));
      final g = await tester.startGesture(tester.getCenter(find.text(label)));
      await tester.pump();
      expect(scaleOf(tester, find.byType(FilledButton)), closeTo(0.97, 1e-9));
      await g.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  // ---------------------------------------------------------------------------------------------------------
  group('Yazı ölçeği ve dar ekran: taşma yok', () {
    testWidgets('360 dp, ölçek 1.5: uzun etiketli yerel renkli düğmeler taşmaz', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final c in [AppTheme.accentGreen, AppTheme.accentAmber, AppTheme.accentRed, AppTheme.accentCyan, SetupColors.purple])
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Daire listesini yenile', maxLines: 2, overflow: TextOverflow.ellipsis),
                        style: ElevatedButton.styleFrom(backgroundColor: c),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (final b in tester.widgetList(find.byType(ElevatedButton))) {
        expect(b, isA<ElevatedButton>());
      }
      expect(tester.getSize(find.byType(ElevatedButton).first).height, greaterThanOrEqualTo(52));
    });
  });
}
