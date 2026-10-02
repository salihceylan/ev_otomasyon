import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:ev_otomasyon/ui/widgets/settings/appearance_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui/e1_helpers.dart';

/// Tema ve devre arka planı: **okunabilirlik** (WCAG AA), tema seçiminin kalıcılığı ve arka planın
/// içeriği engellememesi.
void main() {
  /// Verilen temada bir `BuildContext` yakalar. `MaterialApp` tema değişimini kısa bir animasyonla
  /// uygular; ölçümden önce animasyon tamamlanır (yoksa ara değer okunur).
  Future<BuildContext> contextFor(WidgetTester tester, ThemeMode mode) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        themeMode: mode,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home: Builder(builder: (context) {
          captured = context;
          return const SizedBox();
        }),
      ),
    );
    await tester.pumpAndSettle();
    return captured;
  }

  const accents = <String, Color>{
    'amber': AppTheme.accentAmber,
    'green': AppTheme.accentGreen,
    'red': AppTheme.accentRed,
    'cyan': AppTheme.accentCyan,
    'purple': AppTheme.accentPurple,
    'blue': AppTheme.primaryBlue,
    'muted': AppTheme.textMuted,
  };

  group('Okunabilirlik (WCAG AA 4.5:1)', () {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
          '${mode.name} temada tüm vurgu renklerinin okunabilir tonu kartta, sayfada ve vurgu tonlu rozet zemininde AA kontrastındadır',
          (tester) async {
        final context = await contextFor(tester, mode);
        final card = AppTheme.getCardColor(context);
        final page = AppTheme.getScaffoldBg(context);
        for (final entry in accents.entries) {
          final readable = AppTheme.readableAccent(context, entry.value);
          final reason = '${entry.key} (${mode.name})';
          expect(AppTheme.contrastRatio(readable, card), greaterThanOrEqualTo(4.5), reason: '$reason / kart');
          expect(AppTheme.contrastRatio(readable, page), greaterThanOrEqualTo(4.5), reason: '$reason / sayfa');
          for (final base in [card, page]) {
            final tinted = Color.alphaBlend(entry.value.withValues(alpha: 0.2), base);
            expect(AppTheme.contrastRatio(readable, tinted), greaterThanOrEqualTo(4.5), reason: '$reason / %20 tonlu zemin');
          }
        }
      });

      testWidgets('${mode.name} temada anlamsal metin renkleri ve ana/ikincil metin kart ve sayfa zemininde okunur',
          (tester) async {
        final context = await contextFor(tester, mode);
        final card = AppTheme.getCardColor(context);
        final page = AppTheme.getScaffoldBg(context);
        final texts = <String, Color>{
          'uyarı': AppTheme.warningText(context),
          'başarı': AppTheme.successText(context),
          'hata': AppTheme.dangerText(context),
          'bilgi': AppTheme.infoText(context),
          'ana metin': AppTheme.getTextPrimary(context),
        };
        for (final entry in texts.entries) {
          expect(AppTheme.contrastRatio(entry.value, card), greaterThanOrEqualTo(4.5), reason: '${entry.key} / kart');
          expect(AppTheme.contrastRatio(entry.value, page), greaterThanOrEqualTo(4.5), reason: '${entry.key} / sayfa');
        }
        // İkincil (soluk) metin hem kart hem sayfa zemininde AA.
        expect(AppTheme.contrastRatio(AppTheme.getTextMuted(context), card), greaterThanOrEqualTo(4.5));
        expect(AppTheme.contrastRatio(AppTheme.getTextMuted(context), page), greaterThanOrEqualTo(4.5));
      });
    }

    testWidgets('açık temada pasif hap rengi koyu temanın soluk rengi değildir (getTextMuted tema duyarlı)', (tester) async {
      final light = await contextFor(tester, ThemeMode.light);
      final lightMuted = AppTheme.getTextMuted(light);
      expect(lightMuted, AppTheme.textMutedLight);
      final dark = await contextFor(tester, ThemeMode.dark);
      expect(AppTheme.getTextMuted(dark), AppTheme.textMuted);
      expect(AppTheme.contrastRatio(lightMuted, AppTheme.cardLight), greaterThan(AppTheme.contrastRatio(AppTheme.textMuted, AppTheme.cardLight)),
          reason: 'koyu temanın soluk rengi açık zeminde yetersiz kontrastlıdır');
    });

    test('beyaz yazılı dolgulu düğme zemini tüm vurgu renklerinde AA kontrastlıdır ve ton korunur', () {
      for (final entry in accents.entries) {
        final fill = AppTheme.filledAccent(entry.value);
        expect(AppTheme.contrastRatio(fill, Colors.white), greaterThanOrEqualTo(4.5), reason: entry.key);
        // Yeterince koyu olan renk olduğu gibi kalır (gereksiz karartma yok).
        if (AppTheme.contrastRatio(entry.value, Colors.white) >= 4.5) {
          expect(fill, entry.value, reason: '${entry.key} zaten yeterli');
        }
      }
    });

    testWidgets('kart süslemesi temaya göre açık/koyu yüzey kullanır', (tester) async {
      final light = await contextFor(tester, ThemeMode.light);
      expect(AppTheme.cardDecoration(light).color, AppTheme.cardLight);
      final dark = await contextFor(tester, ThemeMode.dark);
      expect(AppTheme.cardDecoration(dark).color, AppTheme.cardDark);
    });
  });

  group('Tema seçimi', () {
    testWidgets('seçim duruma yazılır ve SharedPreferences\'a kalıcılaştırılır', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = await pumpReady(tester, scaffolded(const ThemeSelectorCard()));
      expect(h.state.themeMode, ThemeMode.dark, reason: 'varsayılan karanlık');

      await tester.tap(byKeyName('btn_theme_light'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(h.state.themeMode, ThemeMode.light);
      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      expect(prefs!.getString('saved_theme_mode'), 'light');
    });

    testWidgets('seçili düğme erişilebilirlik ağacında "seçili" olarak işaretlenir', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReady(tester, scaffolded(const ThemeSelectorCard()));
      final dark = tester.getSemantics(find.bySemanticsLabel('Koyu tema'));
      final light = tester.getSemantics(find.bySemanticsLabel('Açık tema'));
      expect(dark.flagsCollection.isSelected.toBoolOrNull(), isTrue);
      expect(light.flagsCollection.isSelected.toBoolOrNull(), isFalse);
      handle.dispose();
    });
  });

  group('Devre arka planı', () {
    testWidgets('içeriği engellemez: üzerindeki düğme dokunuşu alır', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CircuitBackground(
              child: Center(
                child: ElevatedButton(onPressed: () => taps++, child: const Text('AHBU')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('AHBU'));
      expect(taps, 1);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('zemin rengi temaya göre değişir (koyu / açık)', (tester) async {
      Future<Color?> baseColor(ThemeMode mode) async {
        await tester.pumpWidget(
          MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home: const Scaffold(body: CircuitBackground(child: SizedBox())),
          ),
        );
        await tester.pumpAndSettle();
        final container = tester.widgetList<Container>(find.descendant(of: find.byType(CircuitBackground), matching: find.byType(Container)))
            .firstWhere((c) => c.color != null);
        return container.color;
      }

      expect(await baseColor(ThemeMode.dark), const Color(0xFF0B1120));
      expect(await baseColor(ThemeMode.light), const Color(0xFFF8FAFC));
    });

    testWidgets('görsel eksik olsa da çökmez (errorBuilder)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CircuitBackground(child: Text('içerik')))),
      );
      await tester.pump();
      expect(find.text('içerik'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
