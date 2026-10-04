import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/step_progress.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/feature_accent.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/neon_app_bar.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/settings/appearance_cards.dart';
import 'package:ev_otomasyon/ui/widgets/settings/hold_to_confirm_button.dart';
import 'package:ev_otomasyon/ui/widgets/settings/settings_card.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import '../visual/support/golden_support.dart';
import 'e1_helpers.dart';
import 'e2_support.dart';

/// WP-FX-B (2. tur eleştirmen bulguları: ayarlar + giriş): düzeltmelerin KOD düzeyinde kilitleri. Görsel doğrulama
/// `test/visual/settings` ve `test/visual/auth` galerilerindedir; burada yalnız ölçülebilir sözleşmeler sınanır
/// (basılı tutma etiket kontrastı/geometrisi, biyometrik simge, boş durum orb'ları, aile hatası düğmesi, kontrol
/// sınırları >= 3:1, üst çubuk, ortak onay kabuğu).
void main() {
  // Ölçü sınamaları gerçek yazı tipiyle (Roboto): varsayılan test yazı tipi (Ahem) her karakteri yazı boyu kadar geniş
  // çizer (etiket/satır kırılımı ölçümleri gerçekçi olmaz). Bulunamazsa yalnız o sınamalar atlanır.
  var fontsLoaded = false;
  setUpAll(() async {
    try {
      await loadGoldenFonts();
      fontsLoaded = true;
    } catch (_) {}
  });

  group('HoldToConfirmButton: etiket her ilerleme noktasında okunur', () {
    // Etiket iki katmandadır: dolgusuz bölgede okunur aile tonu (tinted zemin), dolu bölgede fillStyle mürekkebi (dolgu
    // zemini). Dolgu soldan sağa yoğunlaşır (sol uç sağ ucun yarısı): ara noktalar iki ucun arasındadır.
    for (final dark in [true, false]) {
      for (final family in AppFamilies.all) {
        test('${dark ? 'koyu' : 'açık'}/${family.name}: dolgusuz bölgede ve dolgunun her yoğunluğunda >= 4.5:1', () {
          final brightness = dark ? Brightness.dark : Brightness.light;
          final style = HoldToConfirmButton.fillStyle(family: family, dark: dark);
          expect(style.endAlpha, inInclusiveRange(0.08, dark ? 0.52 : 0.42), reason: 'istenen yoğunluğu AŞMAZ');
          final surface = dark ? AppTheme.cardDark : AppTheme.bgLight;
          final tinted = Color.alphaBlend(family.base.withValues(alpha: dark ? 0.10 : 0.12), surface);
          // Dolu bölge: sol uç (alfa/2) ... sağ uç (alfa).
          for (final f in [0.5, 0.6, 0.75, 0.9, 1.0]) {
            final bg = Color.alphaBlend(family.base.withValues(alpha: style.endAlpha * f), tinted);
            expect(AppTheme.contrastRatio(style.ink, bg), greaterThanOrEqualTo(4.5), reason: 'dolu bölge, yoğunluk x$f');
          }
          // Dolgusuz bölge: okunur aile tonu, yalnız aile tonu zemin.
          final ink = AppTheme.readableAccentOn(brightness, family.base);
          expect(AppTheme.contrastRatio(ink, tinted), greaterThanOrEqualTo(4.5), reason: 'dolgusuz bölge');
        });
      }
    }

    test('kullanılan aile (amber): dolgu GÜÇLÜ kalır (koyu >= .44, açık .42); mürekkep koyuda beyaz, açıkta koyu', () {
      // İki katmanlı etiket sayesinde dolgu .52/.42'den neredeyse hiç kısılmaz (tek katmanda koyuda ~.16'ya inerdi).
      final dark = HoldToConfirmButton.fillStyle(family: AppFamilies.amber, dark: true);
      expect(dark.endAlpha, greaterThanOrEqualTo(0.44));
      expect(dark.ink, Colors.white);
      final light = HoldToConfirmButton.fillStyle(family: AppFamilies.amber, dark: false);
      expect(light.endAlpha, closeTo(0.42, 1e-9));
      expect(light.ink, isNot(Colors.white));
    });

    testWidgets('basılı tutarken etiket iki katmanda çizilir (dolu bölge kırpılmış); bırakınca tek katman', (tester) async {
      await pumpApp(
        tester,
        size: const Size(360, 400),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: HoldToConfirmButton(key: const Key('hold'), label: 'Tut', onConfirmed: () {}),
          ),
        ),
      );
      expect(find.text('Tut'), findsOneWidget, reason: 'boşta tek etiket');
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('hold'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Tut'), findsNWidgets(2), reason: 'dolgusuz + dolu bölge katmanı');
      final texts = tester.widgetList<Text>(find.text('Tut')).toList();
      expect(texts[0].style!.color, isNot(texts[1].style!.color), reason: 'katmanların mürekkebi farklı');
      // Aynı yerleşim: iki etiket de aynı dikdörtgende.
      final rects = tester.widgetList(find.text('Tut')).map((w) => tester.getRect(find.byWidget(w))).toList();
      expect(rects[0], rects[1]);
      await g.up();
      await tester.pump(); // geri sarma animasyonu bu karede başlar
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Tut'), findsOneWidget);
    });

    testWidgets('hap yüksekliği >= 63 dp: orb halkası (54 dp) hap çerçevesine değmez (>= 3 dp boşluk)', (tester) async {
      await pumpApp(
        tester,
        size: const Size(360, 400),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            // Kısa etiket (tek satır): yükseklik tabanın kendisidir.
            child: HoldToConfirmButton(key: const Key('hold'), label: 'Tut', onConfirmed: () {}),
          ),
        ),
      );
      final size = tester.getSize(find.byKey(const Key('hold')));
      expect(size.height, HoldToConfirmButton.minHeight);
      expect(HoldToConfirmButton.minHeight, greaterThanOrEqualTo(63));
      const ring = 44.0 + 2 * 5; // orb + halka payı
      const border = 1.5;
      expect((size.height - 2 * border - ring) / 2, greaterThanOrEqualTo(3), reason: 'halka çerçeveden >= 3 dp içeride');
    });
  });

  group('Biyometrik simge türü izler', () {
    test('biometricIconFor: yüz tanıma -> yüz simgesi; parmak izi / karma / bilinmeyen -> parmak izi', () {
      expect(biometricIconFor('Face ID'), Icons.face_unlock_rounded);
      expect(biometricIconFor('Yüz Tanıma'), Icons.face_unlock_rounded);
      expect(biometricIconFor('Parmak İzi'), Icons.fingerprint_rounded);
      expect(biometricIconFor('Biyometrik Giriş'), Icons.fingerprint_rounded);
      expect(biometricIconFor('Face ID / Parmak İzi'), Icons.fingerprint_rounded, reason: 'karma etiket: tür belirsiz');
      expect(biometricIconFor(''), Icons.fingerprint_rounded);
    });

    for (final entry in <String, IconData>{
      'Face ID': Icons.face_unlock_rounded,
      'Parmak İzi': Icons.fingerprint_rounded,
    }.entries) {
      testWidgets('BiometricCard: "${entry.key}" etiketinde kart simgesi ${entry.value == Icons.face_unlock_rounded ? 'yüz' : 'parmak izi'}', (tester) async {
        final h = await pumpReady(tester, scaffolded(const BiometricCard()));
        h.state.setBiometricForTesting(isSupported: true, isEnabled: true, label: entry.key);
        await tester.pump();
        final badge = tester.widget<OrbIconBadge>(
          find.descendant(of: find.byKey(const Key('card_biometric')), matching: find.byType(OrbIconBadge)),
        );
        expect(badge.icon, entry.value);
        expect(find.text('${entry.key} ile Giriş'), findsOneWidget, reason: 'başlık simgeyle aynı türü anlatır');
      });
    }
  });

  group('Boş durum orb\'ları: devre dışı gri değil, özellik renginde ve parıltılı', () {
    testWidgets('zamanlı kurallar boş durumu: kurallar ailesi (cyan), etkin, parıltılı', (tester) async {
      await pumpReady(tester, const ScheduledRulesPage(), size: const Size(360, 780));
      await tester.pump(const Duration(milliseconds: 300));
      final badge = tester.widget<OrbIconBadge>(
        find.descendant(of: find.byKey(const Key('view_rules_empty')), matching: find.byType(OrbIconBadge)),
      );
      expect(badge.enabled, isTrue, reason: 'mat gri "devre dışı" küre değil');
      expect(badge.glow, isTrue);
      expect(badge.active, isFalse, reason: 'sakin: nabız/halka yok');
      expect(badge.family, AppFeature.rules.accentFamily);
      expect(badge.family, AppFamilies.cyan);
    });

    testWidgets('aile listesi boş durumu: aile ailesi (sky), etkin, parıltılı', (tester) async {
      final env = e2Env();
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await settle(tester);
      final badge = tester.widget<OrbIconBadge>(
        find.descendant(of: find.byKey(const Key('members_empty')), matching: find.byType(OrbIconBadge)),
      );
      expect(badge.enabled, isTrue);
      expect(badge.glow, isTrue);
      expect(badge.family, AppFeature.family.accentFamily);
      expect(badge.family, isNot(AppFamilies.slate));
    });
  });

  group('Aile listesi hata durumu', () {
    testWidgets('"Tekrar Dene" çerçeveli hap düğme: mesaj metniyle aynı sol kenarda, hedef >= 48 dp, kutu r16', (tester) async {
      final env = e2Env();
      env.cloud.membersError = apiError(0, 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.', code: 'NETWORK');
      await pumpApp(tester, state: env.state, size: const Size(360, 800), child: const FamilyMembersPage());
      await settle(tester);

      final retry = find.byKey(const Key('btn_members_retry'));
      expect(tester.widget(retry), isA<OutlinedButton>(), reason: 'düz TextButton bağlantısı değil');
      final message = tester.getRect(find.text('Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.'));
      final button = tester.getRect(retry);
      expect(button.height, greaterThanOrEqualTo(48));
      expect((button.left - message.left).abs(), lessThanOrEqualTo(1.0), reason: 'etiketli düğme metinle aynı sol kenardan başlar');
      final box = tester.widget<Container>(
        find.descendant(of: find.byKey(const Key('members_error')), matching: find.byType(Container)).first,
      );
      expect((box.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(AppRadius.r16));
    });
  });

  group('Üst çubuk: kayıt / şifre değiştirme / sihirli bağlantı NeonAppBar kullanır', () {
    Future<void> push(WidgetTester tester, E2Env env, Widget page) async {
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open_host'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_host')));
      await tester.pumpAndSettle();
    }

    testWidgets('kayıt: cam geri diski (nav_back) + "Kayıt Ol" başlığı; geri sayfayı kapatır', (tester) async {
      final env = e2Env(authenticated: false);
      await push(tester, env, const RegisterPage());
      expect(find.byType(NeonAppBar), findsOneWidget);
      expect(find.descendant(of: find.byType(NeonAppBar), matching: find.text('Kayıt Ol')), findsOneWidget);
      expect(find.byKey(const Key('nav_back')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(RegisterPage), findsNothing);
    });

    testWidgets('zorunlu parola ekranı: geri diski YOK, tek çıkış yolu "Çıkış" cam disk eylemi (btn_forced_logout)', (tester) async {
      final env = e2Env(authenticated: false);
      await push(tester, env, const ChangePasswordPage(forced: true));
      expect(find.byType(NeonAppBar), findsOneWidget);
      expect(find.byKey(const Key('nav_back')), findsNothing);
      expect(find.byKey(const Key('btn_forced_logout')), findsOneWidget);
      expect(find.byTooltip('Çıkış'), findsOneWidget, reason: 'ipucu / anlam etiketi');
      // Sistem geri tuşu zorunlu ekranı kapatmaz (PopScope).
      await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ChangePasswordPage), findsOneWidget);
    });

    testWidgets('gönüllü şifre değiştirme: geri diski var, "Çıkış" yok', (tester) async {
      final env = e2Env();
      await push(tester, env, const ChangePasswordPage());
      expect(find.byKey(const Key('nav_back')), findsOneWidget);
      expect(find.byKey(const Key('btn_forced_logout')), findsNothing);
    });

    testWidgets('sihirli bağlantı: NeonAppBar başlığı', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(
        tester,
        state: env.state,
        child: const MagicLinkPage(link: MagicLink(kind: MagicLinkKind.resetPassword, token: 'ornek-belirtec')),
      );
      await tester.pump();
      expect(find.byType(NeonAppBar), findsOneWidget);
      expect(find.descendant(of: find.byType(NeonAppBar), matching: find.text('Yeni Şifre Belirle')), findsOneWidget);
    });
  });

  group('Kontrol sınırları >= 3:1 (getFieldBorder); dekoratif kart kenarı değil', () {
    test('getFieldBorder koyu/açık yüzeylerde >= 3:1; getCardBorder açıkta değil', () {
      expect(AppTheme.contrastRatio(AppTheme.fieldBorderLight, Colors.white), greaterThanOrEqualTo(3.0));
      expect(AppTheme.contrastRatio(AppTheme.fieldBorderDark, AppTheme.surfaceDark), greaterThanOrEqualTo(3.0));
      expect(AppTheme.contrastRatio(AppTheme.cardBorderLight, Colors.white), lessThan(3.0), reason: 'dekoratif kenar');
    });

    testWidgets('Görünüm kartı: seçili OLMAYAN tema kutucuğu sınırı alan çerçevesi rengindedir', (tester) async {
      await pumpReady(tester, scaffolded(const ThemeSelectorCard()), themeMode: ThemeMode.light);
      final light = tester.widget<AnimatedContainer>(
        find.descendant(of: find.byKey(const Key('btn_theme_light')), matching: find.byType(AnimatedContainer)),
      );
      final dark = tester.widget<AnimatedContainer>(
        find.descendant(of: find.byKey(const Key('btn_theme_dark')), matching: find.byType(AnimatedContainer)),
      );
      Color borderOf(AnimatedContainer c) => ((c.decoration! as BoxDecoration).border! as Border).top.color;
      // Varsayılan durum modu koyu: "Koyu" seçili (sky), "Açık"/"Sistem" seçili değil.
      expect(borderOf(dark), AppFamilies.sky.base);
      expect(borderOf(light), AppTheme.fieldBorderLight);
    });

    testWidgets('StepProgress: henüz gelinmemiş adımların pasif izi >= 3:1', (tester) async {
      await pumpApp(
        tester,
        themeMode: ThemeMode.light,
        child: const Scaffold(body: StepProgress(step: 1, color: AppFamilies.sky)),
      );
      final tracks = tester.widgetList<AnimatedContainer>(find.descendant(of: find.byType(StepProgress), matching: find.byType(AnimatedContainer)));
      final inactive = tracks.map((c) => (c.decoration! as BoxDecoration).color).whereType<Color>().toList();
      expect(inactive, hasLength(2));
      for (final color in inactive) {
        expect(color, AppTheme.fieldBorderLight);
        expect(AppTheme.contrastRatio(color, Colors.white), greaterThanOrEqualTo(3.0));
      }
    });
  });

  group('InfoRow: etiket doğal genişlikte, değer kalan alanda', () {
    testWidgets('"Bu dairedeki rolünüz" kısa değerle TEK satırda (eski 2/3 oran etiketi sarıyordu)', (tester) async {
      if (!fontsLoaded) return markTestSkipped('gerçek yazı tipi yüklenemedi: ölçü sınaması anlamsız');
      await pumpApp(
        tester,
        size: const Size(360, 400),
        themeMode: ThemeMode.light,
        theme: goldenTheme(Brightness.light),
        darkTheme: goldenTheme(Brightness.dark),
        child: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: Column(children: [InfoRow(label: 'Bu dairedeki rolünüz', value: 'Ev Sahibi')]),
          ),
        ),
      );
      final label = tester.getRect(find.text('Bu dairedeki rolünüz'));
      final value = tester.getRect(find.text('Ev Sahibi'));
      expect(label.height, lessThan(24), reason: 'etiket tek satır');
      expect(value.right, closeTo(360 - 16, 1.0), reason: 'değer sağa yaslı');
      expect((value.center.dy - label.center.dy).abs(), lessThan(2), reason: 'değer etiketle aynı satırda');
    });
  });

  group('Basit onaylar ortak kabukta (AuthDialogShell); ham AlertDialog yok', () {
    testWidgets('üye çıkarma onayı: rose kabuk + orb; anahtarlar aynı; "Vazgeç" hiçbir şey silmez', (tester) async {
      final env = e2Env();
      env.cloud.members = <HomeMember>[
        const HomeMember(userId: 'u2', fullName: 'Aile Üyesi Ayşe', role: 'resident', email: 'ayse@ornek.test'),
      ];
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await settle(tester);

      await tapKey(tester, 'btn_remove_member_u2');
      expect(find.byType(AuthDialogShell), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Üyeyi Evden Çıkar'), findsOneWidget);
      expect(find.byKey(const Key('btn_remove_confirm')), findsOneWidget);
      await tapKey(tester, 'btn_remove_cancel');
      expect(find.byType(AuthDialogShell), findsNothing);
      expect(env.cloud.removedMembers, isEmpty);
    });

    testWidgets('kural silme onayı: AuthDialogShell (dialog_delete_rule anahtarı); "Sil" yıkıcı ElevatedButton', (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        size: const Size(360, 780),
        configure: (h) => h.e1.rules = <ScheduledRule>[
          ScheduledRule(
            id: 'a',
            homeId: kHomeA,
            channel: 1,
            channelType: 'relay',
            action: 'off',
            hour: 23,
            minute: 30,
            daysOfWeek: const [1, 2, 3],
            enabled: true,
            label: 'Silinecek',
          ),
        ],
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(byKeyName('menu_rule_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_rule_delete_a'));
      await tester.pumpAndSettle();
      expect(byKeyName('dialog_delete_rule'), findsOneWidget);
      expect(tester.widget(byKeyName('dialog_delete_rule')), isA<AuthDialogShell>());
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget(byKeyName('btn_confirm_delete_rule')), isA<ElevatedButton>());
      expect(tester.widget(byKeyName('btn_cancel_delete_rule')), isA<TextButton>());
    });
  });
}
