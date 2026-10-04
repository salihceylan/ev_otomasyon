import 'dart:ui' as ui;

import 'package:ev_otomasyon/ui/dashboard/module_badge.dart';
import 'package:ev_otomasyon/ui/motion/pressable.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/service_glass.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/app_pill.dart';
// Eski içe aktarma yolu KIRILMADI: GlassPill/ScrollCue/AvatarOrb user_profile_dialog.dart'tan da erişilir.
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart' show AvatarOrb, GlassPill, ScrollCue;
import 'package:ev_otomasyon/ui/widgets/orb/glow_dot.dart';
import 'package:ev_otomasyon/ui/widgets/settings/status_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// `AppPill` / `AppChip` (WP-V9 B): TEK stadium rozet/çip dili. Mevcut rozet sınıfları (GlassPill, StatusBadge, ModuleBadge,
/// ServiceStatusPill, StatusPill) bunun ince sarmalayıcılarıdır: ortak ton (.14) + kenar (.40), >= 12 sp, okunur (AA) etiket.
void main() {
  // Düz ThemeData: AppTheme (google_fonts) testte ağ/yazı tipi yüklemeye çalışır; rozet yalnız parlaklığı okur.
  Widget host(Widget child, {Brightness brightness = Brightness.dark, double scale = 1.0, double? width}) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: c!,
        ),
        home: Scaffold(body: Center(child: width == null ? child : SizedBox(width: width, child: child))),
      );

  /// Rozetin gövde `Container`'ı ([AppPillShell] içindeki ilk Container).
  Container bodyOf(WidgetTester tester, Finder pill) =>
      tester.widget<Container>(find.descendant(of: pill, matching: find.byType(Container)).first);

  BoxDecoration decorationOf(WidgetTester tester, Finder pill) => bodyOf(tester, pill).decoration! as BoxDecoration;

  List<Color> gradientOf(WidgetTester tester, Finder pill) => (decorationOf(tester, pill).gradient! as LinearGradient).colors;

  group('AppPillTokens', () {
    test('ton .14, kenar .40, seçili .20/.70 (1.4 px); yatay dolgular GlassPill.chromeWidth ile uyumlu', () {
      expect(AppPillTokens.tint, 0.14);
      expect(AppPillTokens.rim, 0.40);
      expect(AppPillTokens.selectedTint, 0.20, reason: 'readableAccent %20 tonlu zeminde AA varsayar');
      expect(AppPillTokens.selectedRim, 0.70);
      expect(AppPillTokens.selectedRimWidth, 1.4);
      expect(AppPill.chromeWidth(), 12 + 12 + 2);
      expect(AppPill.chromeWidth(leadingWidth: 8), 12 + (8 + 8 + 6) + 2);
      expect(GlassPill.chromeWidth(leadingWidth: 8), AppPill.chromeWidth(leadingWidth: 8), reason: 'üst çubuk ölçümü ortak');
    });
  });

  group('AppPill', () {
    testWidgets('stadium (hap), >= 12 sp, w700, aile tonu .14 + kenar .40, OPAK dolgu', (tester) async {
      await tester.pumpWidget(host(const AppPill(label: 'Evde', family: AppFamilies.emerald)));
      final pill = find.byType(AppPill);
      final d = decorationOf(tester, pill);
      expect(d.borderRadius, BorderRadius.circular(AppRadius.pill));
      final style = tester.widget<Text>(find.text('Evde')).style!;
      expect(style.fontSize!, greaterThanOrEqualTo(AppTouch.minFontSize));
      expect(style.fontWeight, FontWeight.w700);
      final tokens = SurfaceTokens.dark;
      expect(gradientOf(tester, pill), [
        Color.alphaBlend(AppFamilies.emerald.base.withValues(alpha: 0.14), tokens.cardTop),
        Color.alphaBlend(AppFamilies.emerald.base.withValues(alpha: 0.14), tokens.cardBottom),
      ]);
      expect(gradientOf(tester, pill).every((c) => (c.a * 255).round() == 255), isTrue,
          reason: 'opak: doğrudan devre kartı zemininde de iz çizgileri metnin altından geçmez');
      final border = d.border! as Border;
      expect(border.top.width, 1);
      final context = tester.element(find.text('Evde'));
      expect(border.top.color, AppTheme.readableAccent(context, AppFamilies.emerald.base).withValues(alpha: 0.40));
    });

    for (final brightness in Brightness.values) {
      testWidgets('etiket her ailede GERÇEK zeminde (gradyanın iki ucu) AA >= 4.5:1: ${brightness.name}', (tester) async {
        await tester.pumpWidget(host(
          Column(mainAxisSize: MainAxisSize.min, children: [for (final f in AppFamilies.all) AppPill(label: f.name, family: f)]),
          brightness: brightness,
        ));
        await tester.pump(const Duration(milliseconds: 400)); // tema geçişi
        for (final family in AppFamilies.all) {
          final fg = tester.widget<Text>(find.text(family.name)).style!.color!;
          final pill = find.ancestor(of: find.text(family.name), matching: find.byType(AppPill));
          for (final bg in gradientOf(tester, pill)) {
            expect(wcagContrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '${family.name} ${brightness.name}');
          }
        }
      });
    }

    testWidgets('gösterge: dot ⇒ GlowDot(8) aile rengi; icon ⇒ 14 dp simge; leading öncelikli; yoksa hiçbiri', (tester) async {
      await tester.pumpWidget(host(const AppPill(label: 'A', family: AppFamilies.sky, dot: true)));
      final dot = tester.widget<GlowDot>(find.byType(GlowDot));
      expect(dot.size, 8);
      expect(dot.color, AppFamilies.sky.base);

      await tester.pumpWidget(host(const AppPill(label: 'A', family: AppFamilies.sky, icon: Icons.lock_outline)));
      expect(find.byType(GlowDot), findsNothing);
      expect(tester.widget<Icon>(find.byIcon(Icons.lock_outline)).size, 14);

      await tester.pumpWidget(host(const AppPill(label: 'A', family: AppFamilies.sky, dot: true, icon: Icons.lock_outline, leading: SizedBox(key: Key('lead'), width: 9, height: 9))));
      expect(find.byKey(const Key('lead')), findsOneWidget);
      expect(find.byType(GlowDot), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);

      await tester.pumpWidget(host(const AppPill(label: 'A', family: AppFamilies.sky)));
      expect(find.byType(GlowDot), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('chromeWidth, gerçek genişlikle uyuşur (nokta 8 dp, simge 14 dp, gösterge yok)', (tester) async {
      Future<double> chrome(Widget pill) async {
        await tester.pumpWidget(host(pill));
        return tester.getSize(find.byType(AppPill)).width - tester.getSize(find.text('Sistem Hazır')).width;
      }

      expect(await chrome(const AppPill(label: 'Sistem Hazır', family: AppFamilies.emerald, maxLines: 1)), closeTo(AppPill.chromeWidth(), 0.5));
      expect(
        await chrome(const AppPill(label: 'Sistem Hazır', family: AppFamilies.emerald, maxLines: 1, dot: true)),
        closeTo(AppPill.chromeWidth(leadingWidth: 8), 0.5),
      );
      expect(
        await chrome(const AppPill(label: 'Sistem Hazır', family: AppFamilies.emerald, maxLines: 1, icon: Icons.check)),
        closeTo(AppPill.chromeWidth(leadingWidth: 14), 0.5),
      );
    });

    testWidgets('maxLines > 1 dar yerde sarılır (kesilmez); maxLines 1 tek satır + üç nokta; compact dikey dolgu 2 dp', (tester) async {
      const label = 'SÜPER YÖNETİCİ KONSOLU';
      await tester.pumpWidget(host(const AppPill(label: label, family: AppFamilies.violet), width: 200));
      final wrapped = find.text(label);
      expect(tester.renderObject<RenderParagraph>(wrapped).didExceedMaxLines, isFalse, reason: '2 satıra sığar');
      expect(tester.widget<Text>(wrapped).softWrap, isTrue);

      await tester.pumpWidget(host(const AppPill(label: label, family: AppFamilies.violet, maxLines: 1), width: 200));
      expect(tester.widget<Text>(find.text(label)).softWrap, isFalse);

      await tester.pumpWidget(host(const AppPill(label: 'A', family: AppFamilies.violet, maxLines: 1)));
      final normal = tester.getSize(find.byType(AppPill)).height;
      await tester.pumpWidget(host(const AppPill(label: 'A', family: AppFamilies.violet, maxLines: 1, compact: true)));
      expect(normal - tester.getSize(find.byType(AppPill)).height, 4, reason: 'dikey dolgu 4 -> 2 (iki yan)');
    });

    testWidgets('active: false ⇒ nötr cam: tonsuz gradyan (kart yüzeyi), kenar rimSolid, etiket soluk', (tester) async {
      await tester.pumpWidget(host(const AppPill(label: 'Pasif', family: AppFamilies.amber, active: false)));
      final pill = find.byType(AppPill);
      final tokens = SurfaceTokens.dark;
      expect(gradientOf(tester, pill), [tokens.cardTop, tokens.cardBottom]);
      expect(((decorationOf(tester, pill).border! as Border).top.color), tokens.rimSolid);
      final context = tester.element(find.text('Pasif'));
      expect(tester.widget<Text>(find.text('Pasif')).style!.color, AppTheme.getTextMuted(context));
    });

    testWidgets('textColor ezer; AppPill.tinted ham renkle çizer (aile yok)', (tester) async {
      await tester.pumpWidget(host(const AppPill.tinted(label: 'X', color: Color(0xFF123456), textColor: Colors.white)));
      expect(tester.widget<Text>(find.text('X')).style!.color, Colors.white);
      expect(gradientOf(tester, find.byType(AppPill)).first, Color.alphaBlend(const Color(0xFF123456).withValues(alpha: 0.14), SurfaceTokens.dark.cardTop));
    });

    testWidgets('anlamsal düğüm EKLEMEZ: görünen metin tek etiket; simge anlamdan hariç', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(const AppPill(label: 'Sağlıklı', family: AppFamilies.emerald, icon: Icons.check_circle)));
      expect(find.bySemanticsLabel('Sağlıklı'), findsOneWidget);
      handle.dispose();
    });

    for (final scale in <double>[1.5, 2.0]) {
      testWidgets('yazı ölçeği x$scale, 120 dp: taşma yok', (tester) async {
        await tester.pumpWidget(host(const AppPill(label: 'Servis Soruml. Yöneticisi', family: AppFamilies.cyan, dot: true), scale: scale, width: 120));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('AppChip', () {
    Widget chip({bool selected = false, VoidCallback? onTap, AccentFamily family = AppFamilies.cyan, IconData? icon}) =>
        AppChip(key: const Key('c'), label: 'Stokta Hazır', selected: selected, onTap: onTap, family: family, icon: icon);

    testWidgets('seçili: onay işareti + aile tonlu dolgu (.20) + kalın kenar (.70, 1.4 px); seçili değil: nötr cam, onay yok', (tester) async {
      await tester.pumpWidget(host(chip(selected: true, onTap: () {})));
      expect(find.byIcon(Icons.check_rounded), findsOneWidget, reason: 'seçili durum yalnız renkle anlatılmaz');
      final d = decorationOf(tester, find.byKey(const Key('c')));
      final tokens = SurfaceTokens.dark;
      expect(gradientOf(tester, find.byKey(const Key('c'))), [
        Color.alphaBlend(AppFamilies.cyan.base.withValues(alpha: 0.20), tokens.cardTop),
        Color.alphaBlend(AppFamilies.cyan.base.withValues(alpha: 0.20), tokens.cardBottom),
      ]);
      expect((d.border! as Border).top.width, 1.4);
      final context = tester.element(find.text('Stokta Hazır'));
      expect((d.border! as Border).top.color, AppTheme.readableAccent(context, AppFamilies.cyan.base).withValues(alpha: 0.70));

      await tester.pumpWidget(host(chip(selected: false, onTap: () {})));
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(gradientOf(tester, find.byKey(const Key('c'))), [tokens.cardTop, tokens.cardBottom]);
      // WP-FX-A (BİLİNÇLİ GÜNCELLEME): seçili OLMAYAN etkin çipin kenarı artık alan çerçevesi (≥ 3:1); eskiden rimSolid (≈ 1.3:1)
      // idi (interaktif kontrol sınırı). Dolgu (nötr cam) aynı kalır.
      expect(((decorationOf(tester, find.byKey(const Key('c'))).border! as Border).top.color), AppTheme.fieldBorderDark);
    });

    // WP-FX-A (koordinatör isteği): AppChip'in SEÇİLİ OLMAYAN kenarı etkileşimli bir kontrolün sınırıdır: kart/diyalog/sayfa
    // yüzeyinde ≥ 3:1 (WCAG 1.4.11). Envanter/rol/oda filtresi, misafir süre ve hesap rol çipleri tek kuralla düzelir.
    group('seçili olmayan çip kenarı ≥ 3:1', () {
      List<Color> surfacesFor(Brightness b) => b == Brightness.dark
          ? <Color>[SurfaceTokens.dark.cardTop, SurfaceTokens.dark.cardBottom, AppTheme.cardDark, const Color(0xFF141E33), AppTheme.bgDark]
          : <Color>[Colors.white, SurfaceTokens.light.cardBottom, AppTheme.bgLight, AppTheme.fieldFillLight];

      for (final brightness in Brightness.values) {
        testWidgets('${brightness.name}: kenar = alan çerçevesi, 1 px, her yüzeyde ≥ 3:1; dolgu nötr cam; aile fark etmez', (tester) async {
          final fieldBorder = brightness == Brightness.dark ? AppTheme.fieldBorderDark : AppTheme.fieldBorderLight;
          final tokens = SurfaceTokens.of(brightness);
          for (final family in AppFamilies.all) {
            await tester.pumpWidget(host(chip(selected: false, onTap: () {}, family: family), brightness: brightness));
            await tester.pump(const Duration(milliseconds: 400)); // tema geçişi
            final d = decorationOf(tester, find.byKey(const Key('c')));
            final border = (d.border! as Border).top;
            expect(border.color, fieldBorder, reason: '${family.name}: ${brightness.name}');
            expect(border.width, AppPillTokens.border, reason: 'kalınlık aynı (1 px)');
            expect(gradientOf(tester, find.byKey(const Key('c'))), [tokens.cardTop, tokens.cardBottom], reason: 'dolgu aynı (nötr cam)');
            for (final surface in [...surfacesFor(brightness), tokens.cardTop, tokens.cardBottom]) {
              expect(wcagContrast(border.color, surface), greaterThanOrEqualTo(3.0), reason: '${family.name} ${brightness.name} / $surface');
            }
          }
        });

        testWidgets('${brightness.name}: GERÇEK çizim: çipin kenar pikseli zeminde ve kendi dolgusunda ≥ 3:1', (tester) async {
          final key = GlobalKey();
          // Diyalog/kart yüzeyi (beyaz üstüne beyaz çip senaryosu: eleştirmen r2_service #10).
          final surface = brightness == Brightness.dark ? const Color(0xFF141E33) : Colors.white;
          tester.view.physicalSize = const Size(400, 200);
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(
                backgroundColor: surface,
                body: RepaintBoundary(
                  key: key,
                  child: ColoredBox(color: surface, child: Center(child: chip(selected: false, onTap: () {}))),
                ),
              ),
            ),
          );
          await tester.pump();
          final origin = tester.getTopLeft(find.byKey(key));
          final shell = tester.getRect(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(Container)).first).shift(-origin);
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

          final x = shell.center.dx;
          var best = 0.0; // kenar çizgisi: zeminle en yüksek kontrastlı piksel
          for (var y = shell.top - 2; y <= shell.top + 3; y += 0.5) {
            final c = wcagContrast(at(x, y), surface);
            if (c > best) best = c;
          }
          expect(best, greaterThanOrEqualTo(3.0), reason: '${brightness.name}: çip sınırı zeminde okunur (en iyi piksel $best)');
          // Kenar, çipin kendi nötr dolgusuna karşı da ≥ 3:1 (beyaz üstü beyaz çip yalnız metin değildir).
          final inner = at(x, shell.top + 8);
          var borderPixel = at(x, shell.top + 0.5);
          for (var y = shell.top - 1; y <= shell.top + 2; y += 0.5) {
            final c = at(x, y);
            if (wcagContrast(c, surface) > wcagContrast(borderPixel, surface)) borderPixel = c;
          }
          expect(wcagContrast(borderPixel, inner), greaterThanOrEqualTo(3.0), reason: '${brightness.name}: kenar / iç dolgu');
        });
      }

      testWidgets('pasif çip (onTap null) kenarı YUMUŞAK kalır (pasif bileşenler muaf); seçili çipin kenarı değişmedi', (tester) async {
        await tester.pumpWidget(host(chip(selected: false, onTap: null)));
        expect((decorationOf(tester, find.byKey(const Key('c'))).border! as Border).top.color, SurfaceTokens.dark.rimSolid);
        await tester.pumpWidget(host(chip(selected: true, onTap: null)));
        expect((decorationOf(tester, find.byKey(const Key('c'))).border! as Border).top.color, SurfaceTokens.dark.rimSolid, reason: 'pasif+seçili: nötr yumuşak kenar (eski davranış)');
        await tester.pumpWidget(host(chip(selected: true, onTap: () {})));
        final context = tester.element(find.text('Stokta Hazır'));
        expect(
          (decorationOf(tester, find.byKey(const Key('c'))).border! as Border).top.color,
          AppTheme.readableAccent(context, AppFamilies.cyan.base).withValues(alpha: AppPillTokens.selectedRim),
          reason: 'seçili çip: aile tonlu kalın kenar AYNI',
        );
      });

      testWidgets('pasif AppPill (active: false) kenarı rimSolid KALIR: yalnız ETKİLEŞİMLİ çip sınırı güçlendi', (tester) async {
        await tester.pumpWidget(host(const AppPill(label: 'Pasif', family: AppFamilies.amber, active: false)));
        expect((decorationOf(tester, find.byType(AppPill)).border! as Border).top.color, SurfaceTokens.dark.rimSolid);
      });

      testWidgets('AppPillShell.neutralRim yalnız nötr hâlde (active: false) uygulanır; tonlu hapta etkisiz', (tester) async {
        const rim = Color(0xFFFF00FF);
        await tester.pumpWidget(host(const AppPillShell(key: Key('s'), color: Color(0xFF3B82F6), neutralRim: rim, active: false, child: Text('a'))));
        expect(((bodyOf(tester, find.byKey(const Key('s'))).decoration! as BoxDecoration).border! as Border).top.color, rim);
        await tester.pumpWidget(host(const AppPillShell(key: Key('s'), color: Color(0xFF3B82F6), neutralRim: rim, child: Text('a'))));
        expect(((bodyOf(tester, find.byKey(const Key('s'))).decoration! as BoxDecoration).border! as Border).top.color, isNot(rim));
      });
    });

    for (final brightness in Brightness.values) {
      testWidgets('etiket seçili ve seçili değilken kendi zemininde AA (>= 4.5:1), her ailede: ${brightness.name}', (tester) async {
        for (final selected in [true, false]) {
          for (final family in AppFamilies.all) {
            await tester.pumpWidget(host(chip(selected: selected, onTap: () {}, family: family), brightness: brightness));
            await tester.pump(const Duration(milliseconds: 400)); // tema geçişi + AnimatedContainer
            final fg = tester.widget<Text>(find.text('Stokta Hazır')).style!.color!;
            for (final bg in gradientOf(tester, find.byKey(const Key('c')))) {
              expect(wcagContrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '${family.name} selected=$selected ${brightness.name}');
            }
          }
        }
      });
    }

    testWidgets('dokunma hedefi >= 48 dp (görsel çip daha kısa, dikey ortalı); Wrap içinde içerik genişliğinde', (tester) async {
      await tester.pumpWidget(
        host(
          const Wrap(
            spacing: 8,
            children: [
              AppChip(key: Key('a'), label: 'Tümü', selected: true, onTap: _noop),
              AppChip(key: Key('b'), label: 'Stokta', selected: false, onTap: _noop),
              AppChip(key: Key('c'), label: 'Askıda', selected: false, onTap: _noop),
            ],
          ),
          width: 360,
        ),
      );
      for (final key in ['a', 'b', 'c']) {
        expect(tester.getSize(find.byKey(Key(key))).height, greaterThanOrEqualTo(48), reason: key);
      }
      // Hepsi AYNI satırda (Center her çipi tam satıra genişletmez).
      expect(tester.getTopLeft(find.byKey(const Key('b'))).dy, tester.getTopLeft(find.byKey(const Key('a'))).dy);
      expect(tester.getTopLeft(find.byKey(const Key('c'))).dy, tester.getTopLeft(find.byKey(const Key('a'))).dy);
      expect(tester.getSize(find.byKey(const Key('a'))).width, lessThan(120));
      // Görsel çip 48 dp kutudan KISA.
      final visual = tester.getSize(find.descendant(of: find.byKey(const Key('a')), matching: find.byType(Container)).first);
      expect(visual.height, lessThan(48));
      expect(visual.height, greaterThanOrEqualTo(34));
    });

    testWidgets('dokununca onTap (gecikmesiz); onTap null ⇒ dokunuş yok ve anlam devre dışı', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(chip(onTap: () => taps++)));
      await tester.tap(find.byKey(const Key('c')));
      expect(taps, 1, reason: 'aynı karede');

      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(chip(selected: true, onTap: () {})));
      expect(tester.getSemantics(find.byKey(const Key('c'))), matchesSemantics(label: 'Stokta Hazır', isButton: true, isSelected: true, hasSelectedState: true, hasEnabledState: true, isEnabled: true, hasTapAction: true));
      await tester.pumpWidget(host(chip(selected: false, onTap: null)));
      expect(tester.getSemantics(find.byKey(const Key('c'))), matchesSemantics(label: 'Stokta Hazır', isButton: true, hasSelectedState: true, hasEnabledState: true, isEnabled: false));
      await tester.tap(find.byKey(const Key('c')), warnIfMissed: false);
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('seçili değilken isteğe bağlı simge; seçiliyken onay işareti onun yerine geçer', (tester) async {
      await tester.pumpWidget(host(chip(icon: Icons.inventory_2_rounded, onTap: () {})));
      expect(find.byIcon(Icons.inventory_2_rounded), findsOneWidget);
      await tester.pumpWidget(host(chip(icon: Icons.inventory_2_rounded, selected: true, onTap: () {})));
      expect(find.byIcon(Icons.inventory_2_rounded), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('basınca ölçek geri bildirimi (Pressable 0.95) ve seçim haptiği', (tester) async {
      await tester.pumpWidget(host(chip(onTap: () {})));
      final pressable = tester.widget<Pressable>(find.descendant(of: find.byKey(const Key('c')), matching: find.byType(Pressable)));
      expect(pressable.pressedScale, 0.95);
      expect(pressable.haptic, PressHaptic.selection);
    });

    for (final scale in <double>[1.5, 2.0]) {
      testWidgets('yazı ölçeği x$scale, 200 dp Wrap: taşma yok', (tester) async {
        await tester.pumpWidget(
          host(
            const Wrap(children: [
              AppChip(label: 'Tümü', selected: true, onTap: _noop),
              AppChip(label: 'Stokta Hazır', selected: false, onTap: _noop),
              AppChip(label: 'Devrede / Aktif', selected: false, onTap: _noop),
            ]),
            scale: scale,
            width: 200,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('sarmalayıcılar AppPill kabuğunu çizer (adlar ve imzalar korundu)', () {
    testWidgets('GlassPill, StatusBadge, ModuleBadge, ServiceStatusPill, ServicePillShell', (tester) async {
      await tester.pumpWidget(host(
        Column(mainAxisSize: MainAxisSize.min, children: [
          GlassPill(color: AppFamilies.cyan.base, label: 'ENVANTER'),
          const StatusBadge(label: 'Sen', family: AppFamilies.sky, maxLines: 1),
          const ModuleBadge(text: 'RS485'),
          const ServiceStatusPill(label: 'Çevrimiçi', color: Color(0xFF10B981)),
          const ServicePillShell(color: Color(0xFFF59E0B), child: Text('Kabuk')),
        ]),
      ));
      expect(find.byType(AppPill), findsNWidgets(4));
      expect(find.byType(AppPillShell), findsNWidgets(5));
      expect(find.text('ENVANTER'), findsOneWidget);
      expect(find.text('Kabuk'), findsOneWidget);
    });

    testWidgets('ScrollCue ve AvatarOrb eski yoldan erişilir ve çizilir', (tester) async {
      await tester.pumpWidget(host(
        Column(mainAxisSize: MainAxisSize.min, children: [
          const AvatarOrb(letter: 'A', family: AppFamilies.sky, size: 40),
          SizedBox(
            height: 60,
            width: 100,
            child: ScrollCue(color: Colors.grey, builder: (context, controller) => ListView(controller: controller, children: const [SizedBox(height: 300)])),
          ),
        ]),
      ));
      expect(find.byType(AvatarOrb), findsOneWidget);
      expect(find.byType(ScrollCue), findsOneWidget);
      expect(find.byType(Scrollbar), findsOneWidget);
    });
  });

  // WP-FX-A: 2. tur 'ENVANTER' regresyonu (r2_consoles #1): 320 dp telefonda 1.5 yazı ölçeğinde sarılan (maxLines > 1) rozet
  // etiketi KELİMENİN ORTASINDAN kırılıyordu ('ENVANTE' + 'R'), rozet iki satırlı kapsüle dönüp komşu rozetle yüksekliği bozuyordu.
  // (Birim testinde yazı tipi Ahem'dir: her glif tam 1 em genişliğindedir, bu yüzden genişlikler kesindir.)
  group('AppPill etiketi sözcük ortasından KIRILMAZ (WordSafeLabel)', () {
    RenderParagraph paragraphOf(WidgetTester tester, String text) => tester.renderObject<RenderParagraph>(find.text(text));

    /// Her harfin kutusunun üst kenarı: aynı değer = aynı satır (RenderParagraph satır ölçüsünü açmaz).
    List<double> lineTops(WidgetTester tester, String text) {
      final paragraph = paragraphOf(tester, text);
      return <double>[
        for (var i = 0; i < text.length; i++)
          paragraph.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1)).first.top.roundToDouble(),
      ];
    }

    int lineCount(WidgetTester tester, String text) => lineTops(tester, text).toSet().length;

    Future<void> pumpPill(WidgetTester tester, String label, {required double width, double scale = 1.5, int maxLines = 2}) =>
        tester.pumpWidget(host(AppPill(label: label, family: AppFamilies.cyan, maxLines: maxLines), scale: scale, width: width));

    testWidgets('en uzun sözcük yere sığmazsa etiket TEK satırda kalır ve küçülür (1.5 ölçek, dar yuva)', (tester) async {
      // 'ENVANTER' Ahem 12 sp x 1.5 = 8 x 18 = 144 px; yuva 140 - 26 (dolgu+kenar) = 114 px: sığmaz.
      await pumpPill(tester, 'ENVANTER', width: 140);
      expect(lineCount(tester, 'ENVANTER'), 1, reason: 'sözcük harf düzeyinde bölünmedi');
      final label = tester.getRect(find.text('ENVANTER'));
      final pill = tester.getRect(find.byType(AppPill));
      expect(label.width, lessThanOrEqualTo(114 + 0.1), reason: 'küçültülmüş etiket yuvaya sığar');
      expect(label.width, greaterThan(144 * (1 / 1.5)), reason: 'ama 12 sp tabanının (1/1.5) altına inmez');
      expect(label.left, greaterThanOrEqualTo(pill.left));
      expect(label.right, lessThanOrEqualTo(pill.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('rozet yüksekliği komşu tek satırlı rozetle AYNI (şerit yüksekliği bozulmaz)', (tester) async {
      await tester.pumpWidget(
        host(
          Row(mainAxisSize: MainAxisSize.min, children: const [
            SizedBox(width: 140, child: AppPill(label: 'ENVANTER', family: AppFamilies.cyan, key: Key('narrow'))),
            SizedBox(width: 8),
            SizedBox(width: 200, child: AppPill(label: 'YÖNETİCİ', family: AppFamilies.violet, key: Key('wide'))),
          ]),
          scale: 1.5,
        ),
      );
      expect(tester.getSize(find.byKey(const Key('narrow'))).height, closeTo(tester.getSize(find.byKey(const Key('wide'))).height, 0.01));
      expect(lineCount(tester, 'YÖNETİCİ'), 1);
    });

    testWidgets('yazı ölçeği 2.0: yine tek satır (12 sp tabanı 1/2.0\'a kadar küçülmeye izin verir)', (tester) async {
      await pumpPill(tester, 'ENVANTER', width: 200, scale: 2.0);
      expect(lineCount(tester, 'ENVANTER'), 1);
      expect(tester.getRect(find.text('ENVANTER')).width, lessThanOrEqualTo(200 - 26 + 0.1));
    });

    testWidgets('çok sözcüklü etiket SÖZCÜK SINIRINDA sarılır (hiçbir sözcük bölünmez)', (tester) async {
      const text = 'STOK & PANO';
      await pumpPill(tester, text, width: 140);
      final tops = lineTops(tester, text);
      expect(tops.toSet(), hasLength(2), reason: 'iki satır');
      for (var i = 1; i < text.length; i++) {
        if (tops[i] != tops[i - 1]) expect(text[i - 1], ' ', reason: 'satır başı yalnız boşluktan sonra');
      }
      expect(tester.getRect(find.text(text)).width, lessThanOrEqualTo(114 + 0.1));
    });

    testWidgets('sığan etiket DEĞİŞMEZ: ölçek yok, tek satır, sözcük genişliği', (tester) async {
      await pumpPill(tester, 'ENVANTER', width: 220);
      final r = tester.getRect(find.text('ENVANTER'));
      expect(r.width, closeTo(144, 3), reason: 'ölçek yok: sözcüğün doğal genişliği');
      expect(lineCount(tester, 'ENVANTER'), 1);
      // Yükseklik: Ahem 12 x 1.5 = 18 sp, height 1.2 → 21.6 (ölçeksiz).
      expect(r.height, closeTo(21.6, 0.5));
    });

    testWidgets('yazı ölçeği 1.0: etiket 12 sp tabanının altına küçülmez (son çare: bölünür) — taban kuralı', (tester) async {
      // 'ENVANTER' Ahem 12 sp = 96 px; yuva 70 - 26 = 44 px. Ölçek tabanı 1/1.0 = 1.0: küçülme yok.
      await pumpPill(tester, 'ENVANTER', width: 70, scale: 1.0);
      expect(tester.getRect(find.text('ENVANTER')).height, greaterThan(12 * 1.2 + 0.5), reason: 'ölçeklenmedi: sözcük son çare bölündü (2+ satır)');
      expect(tester.takeException(), isNull);
    });

    testWidgets('minLabelScale: 1.0 → 1; 1.5 → 1/1.5; 2.0 → 1/2; küçük ölçekte 1', (tester) async {
      late BuildContext captured;
      Future<double> minScaleAt(double scale) async {
        await tester.pumpWidget(host(Builder(builder: (c) {
          captured = c;
          return const SizedBox();
        }), scale: scale));
        return AppPill.minLabelScale(captured);
      }

      expect(await minScaleAt(1.0), 1.0);
      expect(await minScaleAt(1.5), closeTo(1 / 1.5, 1e-9));
      expect(await minScaleAt(2.0), closeTo(0.5, 1e-9));
      expect(await minScaleAt(0.8), 1.0, reason: 'yazı ölçeği küçükken etiket büyütülmez/küçültülmez');
    });

    testWidgets('maxLines: 1 yolu DEĞİŞMEDİ: WordSafeLabel yok, tek satır + üç nokta; sarmalı yolda var', (tester) async {
      await pumpPill(tester, 'ENVANTER', width: 140, maxLines: 1);
      expect(find.byType(WordSafeLabel), findsNothing);
      expect(tester.widget<Text>(find.text('ENVANTER')).softWrap, isFalse);
      await pumpPill(tester, 'ENVANTER', width: 140);
      expect(find.byType(WordSafeLabel), findsOneWidget);
    });

    testWidgets('IntrinsicHeight/IntrinsicWidth içinde çalışır (LayoutBuilder gibi iç boyutta ÇÖKMEZ)', (tester) async {
      for (final scale in [1.0, 1.5, 2.0]) {
        await tester.pumpWidget(
          host(
            SizedBox(
              width: 150,
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
                  Expanded(child: AppPill(label: 'ENVANTER', family: AppFamilies.cyan)),
                  SizedBox(width: 8),
                  SizedBox(width: 30, height: 70),
                ]),
              ),
            ),
            scale: scale,
          ),
        );
        expect(tester.takeException(), isNull, reason: 'ölçek $scale');
      }
      await tester.pumpWidget(host(const IntrinsicWidth(child: AppPill(label: 'STOK & PANO', family: AppFamilies.amber)), scale: 1.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('kuru yerleşim gerçek yerleşimle AYNI boyutu verir (ölçekli ve ölçeksiz yol)', (tester) async {
      for (final width in [140.0, 220.0]) {
        await pumpPill(tester, 'ENVANTER', width: width);
        final box = tester.renderObject<RenderBox>(find.byType(WordSafeLabel));
        final constraints = BoxConstraints(maxWidth: width - 26);
        expect(box.getDryLayout(constraints), box.size, reason: 'yuva $width');
      }
    });

    testWidgets('anlam: etiket metni tek düğümde okunur (yeni sarmalayıcı anlam eklemez)', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPill(tester, 'ENVANTER', width: 140);
      expect(find.bySemanticsLabel('ENVANTER'), findsOneWidget);
      handle.dispose();
    });
  });
}

void _noop() {}
