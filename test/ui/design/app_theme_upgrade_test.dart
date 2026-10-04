import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/slider_shapes.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Tema yükseltmesi: `cardDecoration` imzası/davranışı, düğme türleri, bileşen temaları, açık/koyu eşitlik.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final themes = <String, ThemeData Function()>{'koyu': () => AppTheme.darkTheme, 'açık': () => AppTheme.lightTheme};

  Future<BuildContext> contextFor(WidgetTester tester, ThemeData theme) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(theme: theme, home: Builder(builder: (c) {
      captured = c;
      return const SizedBox();
    })));
    await tester.pumpAndSettle(); // MaterialApp tema değişimini animasyonla uygular: ölçümden önce bitir
    return captured;
  }

  group('AppTheme.cardDecoration (imza korunur, camsı yüzey)', () {
    testWidgets('imza: (context, {accent, radius, emphasized}) hâlâ derlenir ve BoxDecoration döner', (tester) async {
      final ctx = await contextFor(tester, AppTheme.darkTheme);
      // 60+ mevcut çağrı bu biçimde: tüm adlandırılmış parametreler isteğe bağlı.
      final BoxDecoration plain = AppTheme.cardDecoration(ctx);
      final BoxDecoration withAll = AppTheme.cardDecoration(ctx, accent: Colors.amber, radius: 16, emphasized: true);
      expect(plain, isA<BoxDecoration>());
      expect(withAll.borderRadius, BorderRadius.circular(16));
    });

    testWidgets('taban renk kart yüzey rengi KALIR (mevcut kart rengini okuyan kod/test için)', (tester) async {
      final dark = await contextFor(tester, AppTheme.darkTheme);
      expect(AppTheme.cardDecoration(dark).color, AppTheme.cardDark);
      final light = await contextFor(tester, AppTheme.lightTheme);
      expect(AppTheme.cardDecoration(light).color, AppTheme.cardLight);
    });

    for (final e in themes.entries) {
      testWidgets('${e.key}: dikey gradyan gövde, 1 px rim, çevresel gölge, varsayılan yarıçap 20', (tester) async {
        final ctx = await contextFor(tester, e.value());
        final t = SurfaceTokens.of(e.value().brightness);
        final d = AppTheme.cardDecoration(ctx);
        final g = d.gradient as LinearGradient;
        expect(g.colors, [t.cardTop, t.cardBottom]);
        expect(g.begin, Alignment.topCenter);
        expect(g.end, Alignment.bottomCenter);
        expect(g.colors.every((c) => c.a == 1.0), isTrue, reason: 'opak gradyan');
        expect(d.borderRadius, BorderRadius.circular(AppRadius.card));
        final border = d.border! as Border;
        expect(border.top.width, 1.0);
        expect(border.top.color, t.rimSolid);
        expect(d.boxShadow, hasLength(1));
        expect(d.boxShadow!.single.blurRadius, t.shadowBlur);
        expect(d.boxShadow!.single.blurRadius, lessThanOrEqualTo(24));
        expect(d.boxShadow!.single.offset, t.shadowOffset);
        expect(d.boxShadow!.single.color, t.shadow);
      });

      testWidgets('${e.key}: accent kenarı accent@0.28; emphasized: 1.4 px accent@0.55 + radyal parıltı', (tester) async {
        final ctx = await contextFor(tester, e.value());
        final t = SurfaceTokens.of(e.value().brightness);
        const accent = Color(0xFFFFB020);
        final soft = AppTheme.cardDecoration(ctx, accent: accent);
        final softBorder = soft.border! as Border;
        expect(softBorder.top.color, accent.withValues(alpha: 0.28));
        expect(softBorder.top.width, 1.0);
        expect(soft.gradient, isA<LinearGradient>());

        final strong = AppTheme.cardDecoration(ctx, accent: accent, emphasized: true);
        final strongBorder = strong.border! as Border;
        expect(strongBorder.top.color, accent.withValues(alpha: 0.55));
        expect(strongBorder.top.width, 1.4);
        final glow = strong.gradient as RadialGradient;
        expect(glow.colors.last, t.cardBottom);
        expect(glow.colors[1], t.cardTop);
        expect(glow.colors.first, isNot(t.cardTop), reason: 'sol-üst accent parıltısı');
        expect(strong.boxShadow!.every((s) => s.color != accent), isTrue, reason: 'parıltı BoxShadow DEĞİL (gradyan)');
      });
    }

    testWidgets('radius parametresi uygulanır; emphasized accent olmadan etkisizdir (çökmez)', (tester) async {
      final ctx = await contextFor(tester, AppTheme.darkTheme);
      expect(AppTheme.cardDecoration(ctx, radius: 12).borderRadius, BorderRadius.circular(12));
      expect(AppTheme.cardDecoration(ctx, emphasized: true).gradient, isA<LinearGradient>());
    });

    testWidgets('glassDecoration(solidRim: false): kenarlık yok (SurfaceCard gradyan rim çizer)', (tester) async {
      final ctx = await contextFor(tester, AppTheme.lightTheme);
      expect(AppTheme.glassDecoration(ctx, solidRim: false).border, isNull);
      expect(AppTheme.glassDecoration(ctx).border, isNotNull);
    });

    testWidgets('kart gradyanı yazı kontrastını bozmaz: readableAccent kartın her iki ucunda AA', (tester) async {
      for (final e in themes.entries) {
        final ctx = await contextFor(tester, e.value());
        final d = AppTheme.cardDecoration(ctx);
        for (final stop in (d.gradient as LinearGradient).colors) {
          for (final accent in [AppTheme.accentAmber, AppTheme.accentGreen, AppTheme.accentRed, AppTheme.primaryBlue]) {
            expect(AppTheme.contrastRatio(AppTheme.readableAccent(ctx, accent), stop), greaterThanOrEqualTo(4.5), reason: '${e.key} $accent');
          }
          expect(AppTheme.contrastRatio(AppTheme.getTextMuted(ctx), stop), greaterThanOrEqualTo(4.5), reason: '${e.key} soluk metin');
          expect(AppTheme.contrastRatio(AppTheme.getTextPrimary(ctx), stop), greaterThanOrEqualTo(4.5));
        }
      }
    });
  });

  group('ElevatedButton: TÜR KALIR, gradyan yüzey', () {
    for (final e in themes.entries) {
      testWidgets('${e.key}: find.widgetWithText(ElevatedButton, …) çalışır, min yükseklik 52, stadium, gradyan', (tester) async {
        var pressed = 0;
        await tester.pumpWidget(
          MaterialApp(theme: e.value(), home: Scaffold(body: Center(child: ElevatedButton(onPressed: () => pressed++, child: const Text('Giriş Yap'))))),
        );
        final finder = find.widgetWithText(ElevatedButton, 'Giriş Yap');
        expect(finder, findsOneWidget, reason: 'testler ElevatedButton türüne bağlı');
        expect(find.text('Giriş Yap'), findsOneWidget);
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(52));
        final style = e.value().elevatedButtonTheme.style!;
        expect(style.shape!.resolve({}), isA<StadiumBorder>());
        expect(style.minimumSize!.resolve({})!.height, 52);
        expect(style.backgroundBuilder, isNotNull);
        // Gradyan yüzey görünür ağaçta.
        expect(find.descendant(of: finder, matching: find.byType(PrimaryButtonSurface)), findsOneWidget);
        await tester.tap(finder);
        expect(pressed, 1);
      });
    }

    testWidgets('gradyan uçları ve orta tonlar beyaz metinle ≥ 4.5:1 (AA)', (tester) async {
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final c = Color.lerp(PrimaryButtonSurface.gradientStart, PrimaryButtonSurface.gradientEnd, t)!;
        expect(AppTheme.contrastRatio(Colors.white, c), greaterThanOrEqualTo(4.5), reason: 't=$t');
      }
    });

    testWidgets('basınçta ölçek 0.97 parmak değdiği karede uygulanır; bırakınca 1.0', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.darkTheme, home: Scaffold(body: Center(child: ElevatedButton(onPressed: () {}, child: const Text('Kaydet'))))));
      double scale() => tester
          .widgetList<Transform>(find.descendant(of: find.byType(PrimaryButtonSurface), matching: find.byType(Transform)))
          .first
          .transform
          .storage[0];
      expect(scale(), 1.0);
      final g = await tester.startGesture(tester.getCenter(find.text('Kaydet')));
      await tester.pump();
      expect(scale(), closeTo(0.97, 1e-9));
      await g.up();
      await tester.pumpAndSettle();
      expect(scale(), 1.0);
    });

    testWidgets('pasif düğme: düz cam yüzey (gradyan yok), dokunuş çağrılmaz', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(MaterialApp(theme: AppTheme.lightTheme, home: const Scaffold(body: Center(child: ElevatedButton(onPressed: null, child: Text('Pasif'))))));
      expect(tester.getSize(find.widgetWithText(ElevatedButton, 'Pasif')).height, greaterThanOrEqualTo(52));
      final surface = tester.widget<PrimaryButtonSurface>(find.byType(PrimaryButtonSurface));
      expect(surface.states, contains(WidgetState.disabled));
      final box = tester.widgetList<DecoratedBox>(find.descendant(of: find.byType(PrimaryButtonSurface), matching: find.byType(DecoratedBox))).first;
      expect((box.decoration as BoxDecoration).gradient, isNull);
      await tester.tap(find.text('Pasif'), warnIfMissed: false);
      expect(pressed, 0);
    });

    testWidgets('düğme metni tema yazı tipinden gelir (aile sabitlenmez): labelLarge 15 sp, KALIN (w700), aile değişmez', (tester) async {
      for (final e in themes.entries) {
        final theme = e.value();
        expect(theme.elevatedButtonTheme.style!.textStyle, isNull, reason: 'ButtonStyle.textStyle verilmez (tema geçişi güvenliği)');
        expect(theme.textTheme.labelLarge!.fontSize, 15);
        // Etiket kalın (w700): düğmeler arası tipografi tek yerden (eskiden w500 + çağrı yeri geçersiz kılmaları: aynı
        // ekranda 'Giriş Yap' bold iken 'Parmak İzi ile Aç' medium görünüyordu). AİLE değişmez (google_fonts 'Inter_500'
        // dosyası): yeni Inter ağırlığı = yeni indirme OLMAZ, kalın görünüm uygulamadaki diğer kalın metinler gibi sentezlenir.
        expect(theme.textTheme.labelLarge!.fontWeight, FontWeight.w700);
        final baseline = GoogleFonts.interTextTheme((e.key == 'koyu' ? ThemeData.dark() : ThemeData.light()).textTheme).labelLarge!;
        expect(theme.textTheme.labelLarge!.fontFamily, baseline.fontFamily, reason: 'yeni Inter ağırlığı = yeni indirme olurdu');
      }
    });
  });

  group('diğer düğmeler / bileşen temaları (koyu + açık eşit)', () {
    for (final e in themes.entries) {
      testWidgets('${e.key}: Filled/Outlined/Text min 48, stadium', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: e.value(),
            home: Scaffold(
              body: Column(children: [
                FilledButton(onPressed: () {}, child: const Text('Dolu')),
                OutlinedButton(onPressed: () {}, child: const Text('Çerçeve')),
                TextButton(onPressed: () {}, child: const Text('Metin')),
              ]),
            ),
          ),
        );
        for (final label in ['Dolu', 'Çerçeve', 'Metin']) {
          final button = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48), reason: label);
        }
        final t = e.value();
        for (final s in [t.filledButtonTheme.style!, t.outlinedButtonTheme.style!, t.textButtonTheme.style!]) {
          expect(s.shape!.resolve({}), isA<StadiumBorder>());
        }
      });

      testWidgets('${e.key}: tüm bileşen temaları dolu (eşit kalite): switch, slider, chip, snackbar, sheet, dialog, input, geçiş', (tester) async {
        final t = e.value();
        expect(t.switchTheme.thumbColor, isNotNull);
        expect(t.switchTheme.trackColor, isNotNull);
        expect(t.switchTheme.trackOutlineColor, isNotNull);
        expect(t.sliderTheme.trackShape, isA<GlowSliderTrackShape>());
        expect(t.sliderTheme.thumbShape, isA<OrbSliderThumbShape>());
        expect(t.sliderTheme.trackHeight, greaterThanOrEqualTo(6));
        expect(t.chipTheme.shape, isA<StadiumBorder>());
        expect(t.chipTheme.selectedColor, isNotNull);
        expect(t.snackBarTheme.behavior, SnackBarBehavior.floating);
        expect(t.snackBarTheme.shape, isA<RoundedRectangleBorder>());
        expect(t.bottomSheetTheme.shape, isA<RoundedRectangleBorder>());
        final sheet = (t.bottomSheetTheme.shape! as RoundedRectangleBorder).borderRadius as BorderRadius;
        expect(sheet.topLeft.x, AppRadius.sheet);
        expect(t.dialogTheme.shape, isA<RoundedRectangleBorder>());
        expect(t.inputDecorationTheme.focusedBorder, isA<OutlineInputBorder>());
        expect(t.pageTransitionsTheme.builders, isNotEmpty);
        expect(t.scaffoldBackgroundColor, Colors.transparent, reason: 'devre kartı arka planı görünür kalır');
      });

      testWidgets('${e.key}: giriş alanı odak halkası cyan ve zeminde ≥ 3:1', (tester) async {
        final t = e.value();
        final focused = t.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
        final cyan = t.brightness == Brightness.dark ? AppFamilies.cyan.base : AppFamilies.cyan.deep;
        expect(focused.borderSide.color, cyan);
        expect(focused.borderSide.width, greaterThanOrEqualTo(2));
        expect(AppTheme.contrastRatio(focused.borderSide.color, t.inputDecorationTheme.fillColor!), greaterThanOrEqualTo(3.0));
        // Odaktaki yüzen etiket halkayla aynı cyan; odak dışında SOLUK (muted): boş alan "dolu" gibi okunmasın (eskiden
        // odak dışında renk verilmiyordu ve etiket `onSurface` = birincil metin rengine düşüyordu).
        final label = t.inputDecorationTheme.floatingLabelStyle! as WidgetStateProperty<TextStyle?>;
        final muted = t.brightness == Brightness.dark ? AppTheme.textMuted : AppTheme.textMutedLight;
        expect(label.resolve({WidgetState.focused})!.color, cyan);
        expect(label.resolve(<WidgetState>{})!.color, muted);
        expect(label.resolve({WidgetState.error})!.color, AppTheme.readableAccentOn(t.brightness, AppTheme.accentRed), reason: 'hata durumunda okunur (AA) tehlike tonu');
        expect(AppTheme.contrastRatio(cyan, t.inputDecorationTheme.fillColor!), greaterThanOrEqualTo(4.5), reason: 'etiket metni AA');
        expect(t.textSelectionTheme.cursorColor, cyan, reason: 'imleç halkayla aynı renk');
      });

      testWidgets('${e.key}: odaklanınca halka cyan olur ve etiket yukarı çıkar (gerçek TextField)', (tester) async {
        final node = FocusNode();
        addTearDown(node.dispose);
        await tester.pumpWidget(MaterialApp(theme: e.value(), home: Scaffold(body: Center(child: TextField(focusNode: node, decoration: const InputDecoration(labelText: 'Parola'))))));
        await tester.tap(find.byType(TextField));
        await tester.pump(); // animasyonlar bu karede başlar
        await tester.pump(const Duration(milliseconds: 400));
        expect(node.hasFocus, isTrue);
        final decorator = tester.widget<InputDecorator>(find.byType(InputDecorator));
        expect(decorator.isFocused, isTrue);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${e.key}: çip etiketleri (M3 varsayılan renkleri) seçili/seçilmemiş zeminde ve sayfa/kart üstünde AA', (tester) async {
        final t = e.value();
        final cs = t.colorScheme;
        expect(t.chipTheme.selectedColor, cs.secondaryContainer, reason: 'seçili çip zemini ile etiket rengi aynı M3 çifti');
        final surfaces = <Color>[
          t.brightness == Brightness.dark ? AppTheme.bgDark : AppTheme.bgLight,
          SurfaceTokens.of(t.brightness).cardTop,
          SurfaceTokens.of(t.brightness).cardBottom,
        ];
        for (final surface in surfaces) {
          final unselected = Color.alphaBlend(t.chipTheme.backgroundColor!, surface);
          final selected = Color.alphaBlend(t.chipTheme.selectedColor!, surface);
          expect(AppTheme.contrastRatio(cs.onSurfaceVariant, unselected), greaterThanOrEqualTo(4.5), reason: 'seçilmemiş / $surface');
          expect(AppTheme.contrastRatio(cs.onSecondaryContainer, selected), greaterThanOrEqualTo(4.5), reason: 'seçili / $surface');
        }
        // Gerçek çizimde etiket tema yazı tipinden gelir (aile sabitlenmemiş).
        await tester.pumpWidget(MaterialApp(theme: t, home: Scaffold(body: ChoiceChip(label: const Text('Salon'), selected: true, onSelected: (_) {}))));
        expect(t.chipTheme.labelStyle, isNull, reason: 'çip etiketi labelLarge varsayılanından (Inter) gelir');
      });

      testWidgets('${e.key}: snackbar iletisi koyu zeminde AA, eylem rengi okunur; MaterialApp içinde gösterilir', (tester) async {
        final t = e.value();
        expect(AppTheme.contrastRatio(t.colorScheme.onInverseSurface, t.colorScheme.inverseSurface), greaterThanOrEqualTo(4.5));
        expect(AppTheme.contrastRatio(t.colorScheme.inversePrimary, t.colorScheme.inverseSurface), greaterThanOrEqualTo(4.5));
        await tester.pumpWidget(MaterialApp(theme: t, home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: const Text('Kaydedildi'), action: SnackBarAction(label: 'Geri al', onPressed: () {})),
            ),
            child: const Text('göster'),
          );
        }))));
        await tester.tap(find.text('göster'));
        await tester.pumpAndSettle();
        expect(find.text('Kaydedildi'), findsOneWidget);
        expect(find.text('Geri al'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${e.key}: ChoiceChip, Switch, Slider, TextField, diyalog, sheet hatasız çizilir', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: e.value(),
            home: Scaffold(
              body: Column(children: [
                ChoiceChip(label: const Text('Salon'), selected: true, onSelected: (_) {}),
                Switch(value: true, onChanged: (_) {}),
                Slider(value: 0.4, onChanged: (_) {}),
                const TextField(decoration: InputDecoration(labelText: 'E-posta')),
              ]),
            ),
          ),
        );
        expect(find.byType(Slider), findsOneWidget, reason: 'Slider widget türü KALIR');
        expect(find.byType(Switch), findsOneWidget);
        expect(find.byType(ChoiceChip), findsOneWidget);
        await tester.drag(find.byType(Slider), const Offset(60, 0));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('açık ve koyu tema aynı bileşen temaları kümesine sahip (eşit kalite denetimi)', (tester) async {
      final d = AppTheme.darkTheme;
      final l = AppTheme.lightTheme;
      bool both(Object? a, Object? b) => (a == null) == (b == null);
      expect(both(d.elevatedButtonTheme.style?.backgroundBuilder, l.elevatedButtonTheme.style?.backgroundBuilder), isTrue);
      expect(both(d.filledButtonTheme.style, l.filledButtonTheme.style), isTrue);
      expect(both(d.outlinedButtonTheme.style, l.outlinedButtonTheme.style), isTrue);
      expect(both(d.textButtonTheme.style, l.textButtonTheme.style), isTrue);
      expect(both(d.switchTheme.thumbColor, l.switchTheme.thumbColor), isTrue);
      expect(both(d.sliderTheme.trackShape, l.sliderTheme.trackShape), isTrue);
      expect(both(d.chipTheme.selectedColor, l.chipTheme.selectedColor), isTrue);
      expect(both(d.snackBarTheme.shape, l.snackBarTheme.shape), isTrue);
      expect(both(d.bottomSheetTheme.shape, l.bottomSheetTheme.shape), isTrue);
      expect(both(d.dialogTheme.shape, l.dialogTheme.shape), isTrue);
      expect(both(d.tabBarTheme.indicatorColor, l.tabBarTheme.indicatorColor), isTrue);
      expect(both(d.popupMenuTheme.shape, l.popupMenuTheme.shape), isTrue);
      expect(d.brightness, Brightness.dark);
      expect(l.brightness, Brightness.light);
    });
  });

  group('geriye uyum: mevcut AppTheme API ve sabitler', () {
    test('sabitler ve yardımcılar değişmedi', () {
      expect(AppTheme.bgDark, const Color(0xFF0B1120));
      expect(AppTheme.cardDark, const Color(0xFF1E293B));
      expect(AppTheme.cardLight, const Color(0xFFFFFFFF));
      expect(AppTheme.primaryBlue, const Color(0xFF2563EB));
      expect(AppTheme.accentAmber, const Color(0xFFF59E0B));
      expect(AppTheme.contrastRatio(Colors.black, Colors.white), closeTo(21.0, 1e-6));
      expect(AppTheme.filledAccent(AppTheme.accentAmber), isA<Color>());
    });

    test('tema getter\'ları yeni nesne döndürür ama eşdeğerdir (MaterialApp tema animasyonu güvenli)', () {
      expect(AppTheme.darkTheme.brightness, AppTheme.darkTheme.brightness);
      expect(AppTheme.darkTheme.colorScheme.primary, AppTheme.primaryBlue);
      expect(AppTheme.lightTheme.colorScheme.primary, AppTheme.primaryBlue);
    });

    testWidgets('açık<->koyu tema geçişi (ThemeData.lerp) düğme/çip/slider ile hatasız ve varsayılan temadan AppTheme\'e de', (tester) async {
      Widget app(ThemeData theme) => MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(children: [
                ElevatedButton(onPressed: () {}, child: const Text('E')),
                FilledButton(onPressed: () {}, child: const Text('F')),
                OutlinedButton(onPressed: () {}, child: const Text('O')),
                TextButton(onPressed: () {}, child: const Text('T')),
                Slider(value: 0.5, onChanged: (_) {}),
                ChoiceChip(label: const Text('C'), selected: true, onSelected: (_) {}),
              ]),
            ),
          );
      await tester.pumpWidget(app(AppTheme.darkTheme));
      await tester.pumpWidget(app(AppTheme.lightTheme));
      await tester.pump(const Duration(milliseconds: 100)); // geçişin ortası
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      // AppTheme -> varsayılan ThemeData (düğme `textStyle`ı null olan tema) geçişi: "farklı inherit" hatası YOK.
      await tester.pumpWidget(app(ThemeData()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(AppTheme.darkTheme));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });
  });

  testWidgets('MotionScope kapsamı olmayan uygulama (mevcut testler) tema yükseltmesiyle de pumpAndSettle eder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(body: Column(children: [ElevatedButton(onPressed: () {}, child: const Text('X')), Switch(value: false, onChanged: (_) {})])),
      ),
    );
    await tester.pumpAndSettle();
    expect(MotionScope, isNotNull);
  });
}
