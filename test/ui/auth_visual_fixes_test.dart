import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/auth_form.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/common/cooldown.dart';
import 'package:ev_otomasyon/ui/common/inline_message.dart';
import 'package:ev_otomasyon/ui/common/validators.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_brand.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import '../visual/support/golden_support.dart';
import 'e2_support.dart';

/// WP-F4 (auth tasarım eleştirmeni bulguları): düzeltmelerin KOD düzeyinde kilitleri. Görsel doğrulama
/// `test/visual/auth` galerisindedir; burada yalnız ölçülebilir sözleşmeler sınanır (kontrast, dokunma hedefi,
/// etiket/yardımcı metin ayrımı, ortak diyalog kabuğu, eylem satırı düzeni, dengeli başlık, kadran, yükleme
/// göstergesi, logo kenarı, giriş satırı hiyerarşisi, açılış paneli).
void main() {
  // Düzen/ölçü sınamaları gerçek yazı tipiyle (Roboto) çalışır: varsayılan test yazı tipi (Ahem) her karakteri
  // yazı boyu kadar geniş çizer ve eylem satırı/etiket genişliği ölçümlerini gerçekçi olmaktan çıkarır.
  var fontsLoaded = false;
  setUpAll(() async {
    try {
      await loadGoldenFonts();
      fontsLoaded = true;
    } catch (_) {
      // Flutter SDK yazı tipi dizini bulunamadı: yalnız ölçüye bağlı sınamalar atlanır (aşağıda).
    }
  });

  /// Ekran yüksekliği/genişliği verilen uygulamada [child]'ı pompalar (varsayılan koyu tema). [configure] pompalamadan
  /// ÖNCE sahte bulutu hazırlar (ör. giriş ekranının açılışta sorduğu `GET /auth/capabilities` yanıtı).
  Future<E2Env> pumpScreen(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(360, 1400),
    double textScale = 1.0,
    ThemeMode themeMode = ThemeMode.dark,
    bool authenticated = false,
    void Function(E2Env env)? configure,
  }) async {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final env = e2Env(authenticated: authenticated);
    configure?.call(env);
    await pumpApp(
      tester,
      state: env.state,
      size: size,
      themeMode: themeMode,
      theme: goldenTheme(Brightness.light),
      darkTheme: goldenTheme(Brightness.dark),
      child: child,
    );
    await settle(tester);
    return env;
  }

  group('Alan çerçevesi kontrastı (auth.json: dinlenme çerçevesi >= 3:1)', () {
    test('koyu: çerçeve alan dolgusuna (#0F172A) ve kart yüzeyine >= 3:1', () {
      const fill = Color(0xFF0F172A);
      final card = SurfaceTokens.dark.cardBottom;
      expect(wcagContrast(AuthFieldColors.rest(true), fill), greaterThanOrEqualTo(3.0));
      expect(wcagContrast(AuthFieldColors.rest(true), card), greaterThanOrEqualTo(3.0));
    });

    test('açık: çerçeve beyaz karta >= 3:1 (alan dolgusu #F8FAFC için ~3.0)', () {
      expect(wcagContrast(AuthFieldColors.rest(false), Colors.white), greaterThanOrEqualTo(3.0));
      expect(wcagContrast(AuthFieldColors.rest(false), const Color(0xFFF8FAFC)), greaterThanOrEqualTo(2.95));
    });

    test('kilitli alan çerçevesi etkin alandan SOLUK (vurgu tersine dönmez)', () {
      for (final dark in [true, false]) {
        expect(AuthFieldColors.disabled(dark).a, lessThan(AuthFieldColors.rest(dark).a));
      }
    });

    testWidgets('authInputDecoration: dinlenme/odak/hata çerçeveleri tanımlı; odak 2 px cyan', (tester) async {
      late InputDecoration d;
      await pumpScreen(
        tester,
        Builder(
          builder: (context) {
            d = authInputDecoration(context, label: 'Şifre', helper: 'En az 10 karakter', prefixIcon: Icons.lock_outline_rounded);
            return const SizedBox();
          },
        ),
      );
      final enabled = (d.enabledBorder! as OutlineInputBorder).borderSide;
      expect(enabled.color, AuthFieldColors.restDark);
      final focused = (d.focusedBorder! as OutlineInputBorder).borderSide;
      expect(focused.width, 2);
      expect(focused.color, AuthFieldColors.focus(true));
      expect(d.errorBorder, isNotNull);
      expect(d.focusedErrorBorder, isNotNull);
      expect(d.disabledBorder, isNotNull);
    });

    test('auth alan çerçevesi TEK kaynak: temanın alan çerçevesi (>= 3:1) ile aynı renk', () {
      expect(AuthFieldColors.restDark, AppTheme.fieldBorderDark);
      expect(AuthFieldColors.restLight, AppTheme.fieldBorderLight);
    });

    testWidgets('authInputDecoration(hasError): errorText OLMADAN da kırmızı çerçeve (odak halkası cyan kalmaz)', (tester) async {
      late InputDecoration plain;
      late InputDecoration failed;
      late Color danger;
      await pumpScreen(
        tester,
        Builder(
          builder: (context) {
            plain = authCodeInputDecoration(context, label: 'Kod', hint: '000000');
            failed = authCodeInputDecoration(context, label: 'Kod', hint: '000000', hasError: true);
            danger = AppTheme.dangerText(context);
            return const SizedBox();
          },
        ),
      );
      Color colorOf(InputBorder? border) => (border! as OutlineInputBorder).borderSide.color;
      expect(colorOf(failed.enabledBorder), danger);
      expect(colorOf(failed.border), danger);
      expect(colorOf(failed.focusedBorder), danger, reason: 'odakta da kırmızı: yanlış kod "geçerli" görünmez');
      expect((failed.focusedBorder! as OutlineInputBorder).borderSide.width, 2);
      expect(failed.errorText, isNull, reason: 'ek hata satırı yer tutmaz (ileti alan altında ayrı bileşende)');
      expect(colorOf(plain.enabledBorder), isNot(danger));
      expect(colorOf(plain.focusedBorder), AuthFieldColors.focus(true));
    });

    testWidgets('kod/PIN alanlarının ön ek simgesi TEK glif: pin_outlined (SMS kodu, kurtarma kodu, servis PIN\'i)', (tester) async {
      late InputDecoration d;
      await pumpScreen(
        tester,
        Builder(
          builder: (context) {
            d = authCodeInputDecoration(context, label: 'Kod', hint: '000000');
            return const SizedBox();
          },
        ),
      );
      expect((d.prefixIcon! as Icon).icon, Icons.pin_outlined);
    });

    test('remainingAttemptsText: sözcükler bölünmeyen boşlukla bağlı ("2." yetim satır kalmaz)', () {
      expect(remainingAttemptsText(2), 'Kalan deneme: 2.');
      expect(remainingAttemptsText(2).contains(' '), isFalse, reason: 'normal (bölünebilir) boşluk yok');
    });
  });

  group('Etiketler kısa, kurallar yardımcı metinde (kesilme bulgusu)', () {
    String? labelOf(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField))).decoration!.labelText;
    String? helperOf(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField))).decoration!.helperText;

    testWidgets('kayıt: parantezli etiket yok; kural ve "isteğe bağlı" yardımcı metinde', (tester) async {
      await pumpScreen(tester, const RegisterPage());
      expect(labelOf(tester, 'field_password'), 'Şifre');
      expect(helperOf(tester, 'field_password'), 'En az ${AuthValidators.passwordMinLength} karakter');
      expect(labelOf(tester, 'field_phone'), 'Telefon');
      expect(helperOf(tester, 'field_phone'), 'İsteğe bağlı');
      for (final key in ['field_full_name', 'field_email', 'field_phone', 'field_password', 'field_password_confirm']) {
        expect(labelOf(tester, key), isNot(contains('(')), reason: '$key etiketi parantez taşımaz (kesilirdi)');
      }
    });

    testWidgets('zorunlu parola: "Geçici Şifre" + yeni şifre yardımcı metni', (tester) async {
      await pumpScreen(tester, const ChangePasswordPage(forced: true));
      expect(labelOf(tester, 'field_current_password'), 'Geçici Şifre');
      expect(labelOf(tester, 'field_new_password'), 'Yeni Şifre');
      expect(helperOf(tester, 'field_new_password'), 'En az ${AuthValidators.passwordMinLength} karakter');
    });

    testWidgets('1.5 yazı ölçeği: etiketler tam görünür (çizilen etiket genişliği alana sığar)', (tester) async {
      if (!fontsLoaded) return markTestSkipped('gerçek yazı tipi yüklenemedi: ölçü sınaması anlamsız');
      await pumpScreen(tester, const RegisterPage(), textScale: 1.5);
      for (final key in ['field_phone', 'field_password', 'field_password_confirm']) {
        final field = tester.getRect(find.byKey(Key(key)));
        final label = find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)).first;
        final textWidget = tester.widget<Text>(label);
        expect(textWidget.data, isNotNull);
        final painter = TextPainter(
          text: TextSpan(text: textWidget.data, style: DefaultTextStyle.of(tester.element(label)).style.merge(textWidget.style)),
          textDirection: TextDirection.ltr,
          textScaler: const TextScaler.linear(1.5),
        )..layout();
        // Ön ek simgesi (48) + iç boşluk (~12+12) çıkarılınca kalan genişlik etikete yeter.
        expect(painter.width, lessThan(field.width - 48 - 24), reason: '$key etiketi 1.5x yazıda kesilmez');
        painter.dispose();
      }
    });

    testWidgets('kod alanı: etiket kenarlıkta sabit ve ortalı (hiza sıçramaz, kesilmez)', (tester) async {
      final env = await pumpScreen(tester, const Scaffold(body: SizedBox.expand()));
      unawaited(PhoneOtpDialog.show(tester.element(find.byType(Scaffold))));
      await settle(tester);
      await typeInto(tester, 'field_phone', '0555 123 45 67');
      await tapKey(tester, 'btn_otp_send');
      expect(env.cloud.otpPhones, isNotEmpty);
      final code = tester.widget<TextField>(find.byKey(const Key('field_code'))).decoration!;
      expect(code.floatingLabelBehavior, FloatingLabelBehavior.always);
      expect(code.floatingLabelAlignment, FloatingLabelAlignment.center);
      expect(code.labelText, 'Doğrulama Kodu');
      // Telefon alanı ile AYNI etiket stili (soluk 14 sp): kod etiketi artık "girilmiş değer" gibi görünmez.
      final phone = tester.widget<TextField>(find.byKey(const Key('field_phone'))).decoration!;
      expect(code.labelStyle, phone.labelStyle);
      expect(code.labelStyle!.fontSize, 14);
      // Kilitli telefon alanının çerçevesi etkin kod alanından daha soluk.
      expect((phone.disabledBorder! as OutlineInputBorder).borderSide.color.a, lessThan((code.enabledBorder! as OutlineInputBorder).borderSide.color.a));
    });
  });

  group('Dokunma hedefi ve ortak bağlantı satırı', () {
    testWidgets('kayıt: "Giriş Yapın" bağlantısı >= 48 dp; giriş: "Kayıt Olun" >= 48 dp (aynı bileşen)', (tester) async {
      await pumpScreen(tester, const RegisterPage());
      expect(tester.getSize(find.byKey(const Key('btn_back_to_login'))).height, greaterThanOrEqualTo(48));
      expect(find.descendant(of: find.byKey(const Key('btn_back_to_login')), matching: find.byType(Text)), findsOneWidget);

      await pumpScreen(tester, const LoginPage());
      expect(tester.getSize(find.byKey(const Key('btn_register'))).height, greaterThanOrEqualTo(48));
      expect(find.byType(AuthLinkRow), findsOneWidget);
    });
  });

  group('InlineMessage: opak taban + AA tonlar', () {
    Future<Container> pumpMessage(WidgetTester tester, InlineMessageKind kind, ThemeMode mode) async {
      await pumpScreen(
        tester,
        Scaffold(body: InlineMessage('Dikkat: bilgi mesajı', key: const Key('msg'), kind: kind)),
        themeMode: mode,
      );
      return tester.widget<Container>(find.descendant(of: find.byKey(const Key('msg')), matching: find.byType(Container)).first);
    }

    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      for (final kind in InlineMessageKind.values) {
        testWidgets('${mode.name}/${kind.name}: zemin OPAK; simge zemine >= 3:1', (tester) async {
          final box = await pumpMessage(tester, kind, mode);
          final decoration = box.decoration! as BoxDecoration;
          expect(decoration.color!.a, 1.0, reason: 'arkadaki devre izleri metnin altından geçmez');
          final icon = tester.widget<Icon>(find.descendant(of: find.byKey(const Key('msg')), matching: find.byType(Icon)));
          expect(wcagContrast(icon.color!, decoration.color!), greaterThanOrEqualTo(3.0), reason: 'simge (UI bileşeni) >= 3:1');
          final text = tester.widget<Text>(find.text('Dikkat: bilgi mesajı'));
          expect(wcagContrast(text.style!.color!, decoration.color!), greaterThanOrEqualTo(4.5), reason: 'metin AA');
        });
      }
    }

    // Son tur (WP-FX-B): kart/diyalog dili. Sayfa düzeyindeki hata kutusu (aile listesi hatası) yanındaki r20 kartlardan
    // r12 ile keskin ayrılıyordu; r16 (alan çerçevesi r12'den ayrışır, kart r20 / diyalog r24'e yaklaşır).
    testWidgets('köşe yarıçapı token r16 (kart/diyalog dili; alan çerçevesi r12 değil)', (tester) async {
      final box = await pumpMessage(tester, InlineMessageKind.error, ThemeMode.dark);
      expect((box.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(AppRadius.r16));
    });
  });

  group('Yıkıcı onay: AA tonlar', () {
    testWidgets('açık tema: "SİL" anahtar sözcüğü ve eşleşme simgesi AA/UI kontrastında', (tester) async {
      await pumpScreen(tester, const Scaffold(body: SizedBox.expand()), themeMode: ThemeMode.light);
      unawaited(ConfirmDestructiveDialog.show(tester.element(find.byType(Scaffold)), title: 'Silinsin mi?', message: 'Geri alınamaz.'));
      await settle(tester);

      final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText().contains('Onaylamak için'));
      TextSpan? phrase;
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == 'SİL') phrase = span;
        return true;
      });
      expect(phrase, isNotNull);
      final card = SurfaceTokens.light.cardTop;
      expect(wcagContrast(phrase!.style!.color!, card), greaterThanOrEqualTo(4.5));

      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'sil');
      await tester.pump();
      final check = tester.widget<Icon>(find.byIcon(Icons.check_circle_rounded));
      expect(wcagContrast(check.color!, const Color(0xFFF8FAFC)), greaterThanOrEqualTo(3.0));
    });
  });

  group('Ortak diyalog kabuğu (auth.json: 4 diyalog 3 kabuk)', () {
    Future<void> open(WidgetTester tester, Future<Object?> Function(BuildContext) show, {Size size = const Size(360, 740), double textScale = 1.0}) async {
      await pumpScreen(tester, const Scaffold(body: SizedBox.expand()), size: size, textScale: textScale);
      unawaited(show(tester.element(find.byType(Scaffold))));
      await settle(tester);
    }

    Future<void> openOtp(WidgetTester tester) => open(tester, (c) => PhoneOtpDialog.show(c));
    Future<void> openConfirm(WidgetTester tester, {double textScale = 1.0, Size size = const Size(360, 740)}) => open(
      tester,
      (c) => ConfirmDestructiveDialog.show(c, title: 'Daire Silinsin mi?', message: 'Geri alınamaz.', confirmLabel: 'Evet, Sil'),
      textScale: textScale,
      size: size,
    );
    Future<void> openBiometric(WidgetTester tester, {double textScale = 1.0}) =>
        open(tester, (c) => BiometricPromptDialog.show(c, label: 'Parmak İzi'), textScale: textScale);

    testWidgets('OTP, onay ve biyometrik istem AYNI kabuğu kullanır; AlertDialog kalmadı', (tester) async {
      await openOtp(tester);
      expect(find.byType(AuthDialogShell), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      Navigator.of(tester.element(find.byType(AuthDialogShell))).pop();
      await settle(tester);

      await openConfirm(tester);
      expect(find.byType(AuthDialogShell), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('genişlik: ekran - 36 dp (360 dp telefonda 324 dp); eskiden 280 dp\'ydi', (tester) async {
      for (final open in <Future<void> Function()>[() => openOtp(tester), () => openBiometric(tester)]) {
        await open();
        final dialog = tester.getSize(find.descendant(of: find.byType(AuthDialogShell), matching: find.byType(DecoratedBox)).first);
        expect(dialog.width, 324);
        Navigator.of(tester.element(find.byType(AuthDialogShell))).pop();
        await settle(tester);
      }
    });

    testWidgets('en çok 440 dp (tablet)', (tester) async {
      await openConfirm(tester, size: const Size(900, 900));
      final dialog = tester.getSize(find.descendant(of: find.byType(AuthDialogShell), matching: find.byType(DecoratedBox)).first);
      expect(dialog.width, 440);
    });

    testWidgets('yıkıcı onay: 1.0 ölçekte İKİ düğme tek satırda (ikincil solda, birincil sağda, birincil geniş)', (tester) async {
      if (!fontsLoaded) return markTestSkipped('gerçek yazı tipi yüklenemedi: ölçü sınaması anlamsız');
      await openConfirm(tester);
      final cancel = tester.getRect(find.byKey(const Key('btn_cancel_destructive')));
      final confirm = tester.getRect(find.byKey(const Key('btn_confirm_destructive')));
      expect((cancel.center.dy - confirm.center.dy).abs(), lessThan(6), reason: 'aynı satır');
      expect(cancel.right, lessThan(confirm.left));
      expect(confirm.width, greaterThan(cancel.width));
    });

    testWidgets('biyometrik istem: uzun birincil etiket -> birincil ÜSTTE, ikincil altta, ikisi tam genişlik', (tester) async {
      await openBiometric(tester);
      final later = tester.getRect(find.byKey(const Key('btn_biometric_later')));
      final enable = tester.getRect(find.byKey(const Key('btn_biometric_enable')));
      expect(enable.bottom, lessThanOrEqualTo(later.top + 1), reason: 'birincil üstte');
      expect((enable.width - later.width).abs(), lessThan(1), reason: 'ikisi de tam genişlik: sağ kenarlar hizalı');
      expect((enable.right - later.right).abs(), lessThan(1));
    });

    testWidgets('2.0 yazı ölçeği: eylemler yığılır, taşma yok, düğmeler >= 48 dp', (tester) async {
      await openConfirm(tester, textScale: 2.0, size: const Size(360, 640));
      expect(tester.takeException(), isNull);
      final cancel = tester.getRect(find.byKey(const Key('btn_cancel_destructive')));
      final confirm = tester.getRect(find.byKey(const Key('btn_confirm_destructive')));
      expect(confirm.bottom, lessThanOrEqualTo(cancel.top + 1));
      expect(cancel.height, greaterThanOrEqualTo(48));
      expect(confirm.height, greaterThanOrEqualTo(48));
    });

    testWidgets('eylem satırı gövdeyle KAYMAZ: kısa ekranda gövde kaydırılır, düğmeler görünür kalır', (tester) async {
      await open(
        tester,
        (c) => ConfirmDestructiveDialog.show(c, title: 'Silinsin mi?', message: List.filled(40, 'Uzun açıklama cümlesi.').join(' '), confirmLabel: 'Sil'),
        size: const Size(360, 480),
      );
      expect(tester.takeException(), isNull);
      final confirm = tester.getRect(find.byKey(const Key('btn_confirm_destructive')));
      expect(confirm.bottom, lessThanOrEqualTo(480));
      expect(find.descendant(of: find.byType(AuthDialogShell), matching: find.byType(SingleChildScrollView)), findsOneWidget);
    });

    testWidgets('ekran okuyucu: kabuk rota adı/kapsamı taşır (AlertDialog ile aynı)', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await openConfirm(tester);
        expect(find.bySemanticsLabel('Alert'), findsWidgets, reason: 'namesRoute etiketi');
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        handle.dispose();
      }
    });
  });

  group('BalancedText: yetim kelime yok, metin DEĞİŞMEZ', () {
    test('iki satıra sarılan başlık dengelenir (son satırda tek kelime kalmaz)', () {
      const style = TextStyle(fontSize: 10, fontFamily: 'Ahem'); // Ahem: her karakter 10 dp
      const text = 'Parmak İzi Kullanılsın mı?';
      final width = BalancedText.balancedWidth(
        text: text,
        style: style,
        direction: TextDirection.ltr,
        scaler: TextScaler.noScaling,
        maxWidth: 250, // greedy: "Parmak İzi Kullanılsın" / "mı?"
      );
      expect(width, lessThan(250));
      final painter = TextPainter(text: const TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout(maxWidth: width);
      final lines = painter.computeLineMetrics();
      expect(lines.length, 2, reason: 'satır sayısı korunur');
      final firstLineEnd = painter.getLineBoundary(const TextPosition(offset: 0)).end;
      final lastLine = text.substring(firstLineEnd).trim();
      expect(lastLine.split(' ').length, greaterThan(1), reason: 'son satır yetim değil: "$lastLine"');
      painter.dispose();
    });

    test('tek satıra sığan metin ve sınırsız genişlik değişmez', () {
      const style = TextStyle(fontSize: 10, fontFamily: 'Ahem');
      expect(BalancedText.balancedWidth(text: 'Kısa', style: style, direction: TextDirection.ltr, scaler: TextScaler.noScaling, maxWidth: 300), 300);
      expect(
        BalancedText.balancedWidth(text: 'Çok uzun bir metin', style: style, direction: TextDirection.ltr, scaler: TextScaler.noScaling, maxWidth: double.infinity),
        double.infinity,
      );
    });

    testWidgets('widget aynı Text.data ile tek Text üretir (find.text çalışır)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 120, child: Row(children: [Expanded(child: BalancedText('Daire Silinsin mi?'))])),
          ),
        ),
      );
      expect(find.text('Daire Silinsin mi?'), findsOneWidget);
    });
  });

  group('Geri sayım kadranı (radyo düğmesi gibi okunan halka yerine)', () {
    testWidgets('bekleme sürerken çizilir; bitince yer tutmaz', (tester) async {
      final remaining = ValueNotifier<int>(30);
      addTearDown(remaining.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: CooldownArc(remaining: remaining, color: Colors.blue)))),
      );
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.getSize(find.byType(CooldownArc)), const Size(16, 16));
      remaining.value = 15;
      await tester.pump();
      expect(tester.takeException(), isNull);
      remaining.value = 0;
      await tester.pump();
      expect(tester.getSize(find.byType(CooldownArc)), Size.zero);
    });

    testWidgets('OTP: bekleme sürerken yeniden gönder etiketi SOLUK (etkin bağlantı gibi görünmez)', (tester) async {
      final env = await pumpScreen(tester, const Scaffold(body: SizedBox.expand()));
      unawaited(PhoneOtpDialog.show(tester.element(find.byType(Scaffold))));
      await settle(tester);
      await typeInto(tester, 'field_phone', '0555 123 45 67');
      await tapKey(tester, 'btn_otp_send');
      final label = tester.widget<Text>(find.text('Tekrar Kod İste (0:45)'));
      expect(label.style!.color, AppTheme.textMuted);
      env.clock.advance(const Duration(seconds: 46));
      await tester.pump();
      final active = tester.widget<Text>(find.text('Tekrar Kod İste'));
      expect(active.style!.color, AppTheme.infoText(tester.element(find.text('Tekrar Kod İste'))));
    });
  });

  group('Yükleme göstergesi: marka yayı', () {
    testWidgets('kayıt düğmesi yüklenirken ProgressArc gösterir (stok çark yok)', (tester) async {
      final env = await pumpScreen(tester, const RegisterPage());
      env.cloud.registerGate = Completer<void>();
      await typeInto(tester, 'field_full_name', 'Ayşe Yılmaz');
      await typeInto(tester, 'field_email', 'ayse@ornek.test');
      await typeInto(tester, 'field_password', 'dogru-parola-1234');
      await typeInto(tester, 'field_password_confirm', 'dogru-parola-1234');
      await tapKey(tester, 'btn_register_submit', settleAfter: false);
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('btn_register_submit')), matching: find.byType(ProgressArc)), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      env.cloud.registerGate!.complete();
      await tester.pump();
    });
  });

  group('Marka logosu', () {
    testWidgets('kenar halkası görselin ÜSTÜNDE (foreground) ve görsel siyah payı kırpacak şekilde ölçeklenir', (tester) async {
      await pumpScreen(tester, const Scaffold(body: Center(child: AuthLogoMark(size: 104))));
      final boxes = tester.widgetList<DecoratedBox>(find.descendant(of: find.byType(AuthLogoMark), matching: find.byType(DecoratedBox)));
      final foreground = boxes.where((b) => b.position == DecorationPosition.foreground && (b.decoration as BoxDecoration).border != null);
      expect(foreground, hasLength(1), reason: 'kenar ClipOval çocuğunun ALTINDA kalıp görünmez oluyordu');
      expect(find.descendant(of: find.byType(AuthLogoMark), matching: find.byType(ClipOval)), findsOneWidget);
      final scale = tester.widget<Transform>(find.descendant(of: find.byType(ClipOval), matching: find.byType(Transform)).first);
      expect(scale.transform.getMaxScaleOnAxis(), closeTo(AuthLogoMark.logoCrop, 1e-6));
    });
  });

  group('Giriş: alternatif satır hiyerarşisi', () {
    Iterable<OrbCore> orbsIn(WidgetTester tester, String key) =>
        tester.widgetList<OrbCore>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(OrbCore)));

    testWidgets('hesapla giriş yöntemleri renkli, servis/kurulum araçları nötr (slate) ve başlıklı grupta', (tester) async {
      // SMS ile giriş satırı yalnız sunucu yeteneği bildirirse görünür (UYELIK-04).
      await pumpScreen(
        tester,
        const LoginPage(),
        size: const Size(360, 1500),
        configure: (env) => env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true),
      );
      expect(orbsIn(tester, 'btn_google_sign_in').single.family, AppFamilies.sky);
      expect(orbsIn(tester, 'btn_phone_otp').single.family, AppFamilies.violet);
      expect(orbsIn(tester, 'btn_magic_link').single.family, AppFamilies.cyan);
      for (final key in ['btn_service_pin', 'btn_wifi_setup', 'btn_local_mode']) {
        expect(orbsIn(tester, key).single.family, AppFamilies.slate, reason: '$key sade/nötr');
        expect(orbsIn(tester, key).single.glow, isFalse);
      }
      expect(find.text('Servis ve kurulum'), findsOneWidget);
      // İki satır aynı aileyi paylaşmaz: Google (sky) ve Pano Wi-Fi (artık slate).
      expect(orbsIn(tester, 'btn_google_sign_in').single.family, isNot(orbsIn(tester, 'btn_wifi_setup').single.family));
    });

    testWidgets('Google rozeti kalın "G" harfidir; Wi-Fi kurulumu yelpaze+büyüteç (göz gibi okunan) simge değil', (tester) async {
      await pumpScreen(tester, const LoginPage(), size: const Size(360, 1500));
      expect(find.descendant(of: find.byKey(const Key('btn_google_sign_in')), matching: find.text('G')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('btn_wifi_setup')), matching: find.byIcon(Icons.router_rounded)), findsOneWidget);
      expect(find.byIcon(Icons.wifi_find_rounded), findsNothing);
    });

    testWidgets('satır köşe yarıçapı kart yarıçapıyla aynı (r20) ve ana satırlar koyuda glow\'lu', (tester) async {
      await pumpScreen(tester, const LoginPage(), size: const Size(360, 1500));
      final button = tester.widget<OutlinedButton>(find.byKey(const Key('btn_google_sign_in')));
      final shape = button.style!.shape!.resolve(<WidgetState>{}) as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(AppRadius.card));
      expect(orbsIn(tester, 'btn_google_sign_in').single.glow, isTrue);
    });

    testWidgets('açık tema: satır zemini yüksek opaklık (devre izleri satırın içinden görünmez)', (tester) async {
      await pumpScreen(tester, const LoginPage(), size: const Size(360, 1500), themeMode: ThemeMode.light);
      final button = tester.widget<OutlinedButton>(find.byKey(const Key('btn_google_sign_in')));
      expect(button.style!.backgroundColor!.resolve(<WidgetState>{})!.a, greaterThanOrEqualTo(0.9));
    });
  });

  group('Açılış / kilit ekranı', () {
    Future<void> pumpGate(WidgetTester tester, {ThemeMode mode = ThemeMode.dark, double textScale = 1.0, bool locked = false}) async {
      final env = e2Env(authenticated: false);
      if (locked) {
        env.state.setBiometricForTesting(isSupported: true, isEnabled: true, failed: true, label: 'Parmak İzi', authStatus: AuthStatus.checking);
      } else {
        env.state.setAuthStatusForTesting(AuthStatus.checking);
      }
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpApp(
        tester,
        state: env.state,
        size: const Size(360, 740),
        themeMode: mode,
        theme: goldenTheme(Brightness.light),
        darkTheme: goldenTheme(Brightness.dark),
        child: const AuthGate(),
      );
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('alt başlık hapı >= 12 sp, tek satır (FittedBox) ve metni aynı', (tester) async {
      await pumpGate(tester);
      final text = tester.widget<Text>(find.text('YAPAY ZEKA DESTEKLİ AKILLI YAŞAM'));
      expect(text.style!.fontSize, greaterThanOrEqualTo(12));
      expect(find.ancestor(of: find.text('YAPAY ZEKA DESTEKLİ AKILLI YAŞAM'), matching: find.byType(FittedBox)), findsOneWidget);
    });

    testWidgets('1.5 yazı ölçeği: hap tek satır kalır ("YAŞAM" tek başına ikinci satıra düşmez)', (tester) async {
      await pumpGate(tester, textScale: 1.5);
      final pill = tester.getSize(find.ancestor(of: find.text('YAPAY ZEKA DESTEKLİ AKILLI YAŞAM'), matching: find.byType(Container)).first);
      expect(pill.height, lessThan(60), reason: 'tek satır: iki satıra sarılsaydı ~80 dp olurdu');
      expect(tester.takeException(), isNull);
    });

    testWidgets('panel her temada KOYU cam (opak gradyan); açık temada zemin açık görsel', (tester) async {
      await pumpGate(tester, mode: ThemeMode.light);
      final panel = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).firstWhere(
        (b) => b.decoration is BoxDecoration && ((b.decoration as BoxDecoration).boxShadow?.length ?? 0) == 1,
      );
      final gradient = (panel.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors, [SurfaceTokens.dark.cardTop, SurfaceTokens.dark.cardBottom]);
      expect(gradient.colors.every((c) => c.a == 1.0), isTrue, reason: 'opak: devre izleri metnin arkasından görünmez');
      final images = tester.widgetList<Image>(find.byType(Image)).map((i) => (i.image as AssetImage).assetName);
      expect(images, contains('assets/images/ai_circuit_bg_light.jpg'));
    });

    testWidgets('kilit ekranı: metin ve Key sözleşmesi aynen; panel içi birincil düğme kalın (diğer düğmelerle aynı tipografi)', (tester) async {
      await pumpGate(tester, locked: true);
      expect(find.text('Parmak İzi doğrulaması tamamlanamadı.'), findsOneWidget);
      expect(find.text('Parmak İzi ile Aç'), findsOneWidget);
      expect(find.byKey(const Key('btn_biometric_fallback')), findsOneWidget);
      final label = tester.widget<DefaultTextStyle>(
        find.descendant(of: find.byKey(const Key('btn_biometric_retry')), matching: find.byType(DefaultTextStyle)).first,
      );
      expect(label.style.fontWeight, FontWeight.bold);
    });
  });
}
