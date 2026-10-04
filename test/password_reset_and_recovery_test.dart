import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Şifre sıfırlama akışı: kimlik doğrulama, sunucudan gelen bekleme süresiyle yeniden gönderim,
/// kalan deneme hakkı, parola politikası, sıfırlama sonrası duruma göre mesaj.
void main() {
  Future<Opened<void>> open(WidgetTester tester, E2Env env) {
    return openFromHost<void>(tester, env.state, (context) => ForgotPasswordDialog.show(context));
  }

  Future<void> sendCode(WidgetTester tester, {String identifier = 'Ayse@Ornek.test'}) async {
    await typeInto(tester, 'field_identifier', identifier);
    await tapKey(tester, 'btn_send_code');
  }

  Future<void> fillReset(WidgetTester tester, {String code = '123456', String password = 'yepyeni-parola-1', String? confirm}) async {
    await typeInto(tester, 'field_code', code);
    await typeInto(tester, 'field_new_password', password);
    await typeInto(tester, 'field_confirm_password', confirm ?? password);
  }

  group('1. adım: kod isteme', () {
    testWidgets('geçersiz/boş kimlik reddedilir; sunucuya istek gitmez', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);

      await tapKey(tester, 'btn_send_code');
      expect(find.text('Lütfen e-posta veya telefon numaranızı girin'), findsOneWidget);

      await typeInto(tester, 'field_identifier', 'bu-ne-e-posta-ne-telefon');
      await tapKey(tester, 'btn_send_code');
      expect(find.textContaining('Geçerli bir e-posta adresi veya telefon'), findsOneWidget);
      expect(env.cloud.forgotIdentifiers, isEmpty);
    });

    testWidgets('e-posta küçük harfe, telefon yalnızca rakamlara normalleştirilerek gönderilir', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);
      await sendCode(tester, identifier: '  Ayse@Ornek.TEST ');
      expect(env.cloud.forgotIdentifiers, <String>['ayse@ornek.test']);

      await tapKey(tester, 'btn_forgot_back');
      env.clock.advance(const Duration(seconds: 61)); // bekleme dolsun
      await tester.pump();
      await typeInto(tester, 'field_identifier', '0555 123 45 67');
      await tapKey(tester, 'btn_send_code');
      expect(env.cloud.forgotIdentifiers.last, '05551234567');
    });

    testWidgets('kod gönderilince 2. adım açılır: sunucunun GENEL iletisi gösterilir (hesap varlığı sızmaz)', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);

      await sendCode(tester);

      expect(find.byKey(const Key('field_code')), findsOneWidget);
      expect(textOf(tester, 'forgot_info'), 'Hesap kayıtlıysa kod gönderildi.');
      expect(find.textContaining('ayse@ornek.test'), findsOneWidget);
    });

    testWidgets('geliştirme sunucusunun `debug_code` alanı EKRANDA GÖSTERİLMEZ', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotChallenge = const CodeChallenge(
        message: 'Hesap kayıtlıysa kod gönderildi.',
        resendAfter: Duration(seconds: 60),
        debugCode: '654321',
        debugToken: 'debug-belirteci-ornek',
      );
      await open(tester, env);
      await sendCode(tester);

      expect(find.textContaining('654321'), findsNothing);
      expect(find.textContaining('debug-belirteci-ornek'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('field_code'))).controller!.text, isEmpty);
    });

    testWidgets('sunucu iletisi yoksa aynı nitelikte genel ileti gösterilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotChallenge = const CodeChallenge(resendAfter: Duration(seconds: 60));
      await open(tester, env);
      await sendCode(tester);

      expect(textOf(tester, 'forgot_info'), 'Bu hesap kayıtlıysa kurtarma kodu ve bağlantısı iletildi.');
    });
  });

  group('yeniden gönderim bekleme süresi (sunucudan `resend_after`)', () {
    testWidgets('süre dolmadan "Kodu Tekrar Gönder" kapalıdır, geri sayım gösterilir; süre dolunca açılır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotChallenge = const CodeChallenge(message: 'Gönderildi.', expiresIn: Duration(minutes: 10), resendAfter: Duration(seconds: 90));
      await open(tester, env);
      await sendCode(tester);

      expect(find.text('Kodu Tekrar Gönder (1:30)'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNull);

      env.clock.advance(const Duration(seconds: 45));
      await tester.pump();
      expect(find.text('Kodu Tekrar Gönder (0:45)'), findsOneWidget);

      env.clock.advance(const Duration(seconds: 46));
      await tester.pump();
      expect(find.text('Kodu Tekrar Gönder'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNotNull);

      await tapKey(tester, 'btn_resend_code');
      expect(env.cloud.forgotIdentifiers, hasLength(2), reason: 'süre dolduktan sonra yeniden gönderilebildi');
    });

    testWidgets('sunucu varsayılan bekleme süresi vermezse (60 sn) yine de bekleme uygulanır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotChallenge = const CodeChallenge(message: 'Gönderildi.');
      await open(tester, env);
      await sendCode(tester);
      expect(find.text('Kodu Tekrar Gönder (1:00)'), findsOneWidget);
    });

    testWidgets('429: sunucunun bekleme süresi geri sayılır ve kod gönder düğmesi kapanır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotError = apiError(429, 'Çok fazla istek. Lütfen bekleyin.', code: 'RATE_LIMITED', resendAfter: const Duration(seconds: 75));
      await open(tester, env);
      await sendCode(tester);

      expect(textOf(tester, 'forgot_error'), 'Çok fazla istek. Lütfen bekleyin.');
      expect(find.text('Bekleyin (1:15)'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_send_code'))).onPressed, isNull);

      env.clock.advance(const Duration(seconds: 76));
      await tester.pump();
      expect(find.text('Kod Gönder'), findsOneWidget);
    });

    testWidgets('kodun geçerlilik süresi geri sayılır ve dolunca uyarı verilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotChallenge = const CodeChallenge(message: 'x', expiresIn: Duration(minutes: 10), resendAfter: Duration(seconds: 60));
      await open(tester, env);
      await sendCode(tester);
      expect(textOf(tester, 'forgot_expiry'), 'Kod geçerlilik süresi: 10:00');

      env.clock.advance(const Duration(minutes: 10, seconds: 1));
      await tester.pump();
      expect(textOf(tester, 'forgot_expiry'), contains('süresi dolmuş olabilir'));
    });

    testWidgets('e-posta gönderilemedi (503 DELIVERY_FAILED) açık mesajla gösterilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotError = apiError(503, 'E-posta gönderilemedi. Lütfen daha sonra tekrar deneyin.', code: 'DELIVERY_FAILED');
      await open(tester, env);
      await sendCode(tester);

      expect(textOf(tester, 'forgot_error'), 'E-posta gönderilemedi. Lütfen daha sonra tekrar deneyin.');
      expect(find.byKey(const Key('field_code')), findsNothing, reason: 'kod gönderilemedi: 2. adım açılmaz');
    });
  });

  group('2. adım: yeni şifre', () {
    Future<E2Env> atStepTwo(WidgetTester tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);
      await sendCode(tester);
      return env;
    }

    testWidgets('kod 6 haneli olmalı, parola politikası (10 karakter) ve eşleşme denetlenir; istek gitmez', (tester) async {
      final env = await atStepTwo(tester);

      await fillReset(tester, code: '123');
      await tapKey(tester, 'btn_reset_password');
      expect(textOf(tester, 'forgot_error'), 'Kod tam 6 rakam olmalıdır');

      await fillReset(tester, password: 'kisa');
      await tapKey(tester, 'btn_reset_password');
      expect(textOf(tester, 'forgot_error'), 'Şifre en az 10 karakter olmalıdır');

      await fillReset(tester, confirm: 'baska-parola-9');
      await tapKey(tester, 'btn_reset_password');
      expect(textOf(tester, 'forgot_error'), 'Girdiğiniz şifreler birbiriyle uyuşmuyor');
      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('kod alanı yalnızca rakam kabul eder ve 6 haneyle sınırlıdır', (tester) async {
      await atStepTwo(tester);
      await typeInto(tester, 'field_code', '12ab34-5678');
      expect(tester.widget<TextField>(find.byKey(const Key('field_code'))).controller!.text, '123456');
    });

    testWidgets('sıfırlama, sunucu OTURUM VERMEDİYSE "yeni şifrenizle giriş yapın" der ve diyaloğu kapatır', (tester) async {
      final env = await atStepTwo(tester);

      await fillReset(tester, password: '  boşluklu-parola  ');
      await tapKey(tester, 'btn_reset_password');
      await settle(tester);

      final args = env.cloud.resetArgs.single;
      expect(args['identifier'], 'ayse@ornek.test');
      expect(args['code'], '123456');
      expect(args['passwordLength'], '  boşluklu-parola  '.length, reason: 'şifre kırpılmaz');
      expect(find.byType(ForgotPasswordDialog), findsNothing);
      expect(find.text('Şifreniz yenilendi. Yeni şifrenizle giriş yapabilirsiniz.'), findsOneWidget);
      expect(env.state.authStatus, isNot(AuthStatus.authenticated));
    });

    testWidgets('sıfırlama oturum verdiyse (otomatik giriş) "oturumunuz açıldı" der', (tester) async {
      final env = await atStepTwo(tester);
      env.cloud.resetReturnsSession = true;

      await fillReset(tester);
      await tapKey(tester, 'btn_reset_password');
      await settle(tester);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.text('Şifreniz yenilendi ve oturumunuz açıldı.'), findsOneWidget);
    });

    testWidgets('hatalı kodda KALAN DENEME HAKKI gösterilir ve alanlar korunur', (tester) async {
      final env = await atStepTwo(tester);
      env.cloud.resetError = apiError(400, 'Kod hatalı.', code: 'VALIDATION', remaining: 2);

      await fillReset(tester);
      await tapKey(tester, 'btn_reset_password');

      // Kalan hak TEK yerde (iletinin içinde); sözcükler bölünmeyen boşlukla bağlı: "2." yetim satır kalmaz.
      expect(textOf(tester, 'forgot_error'), 'Kod hatalı. Kalan deneme: 2.');
      expect(find.byKey(const Key('forgot_remaining_attempts')), findsNothing, reason: 'ikinci "Kalan deneme hakkı" satırı yok');
      expect(find.textContaining('Kalan deneme hakkı'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('field_new_password'))).controller!.text, 'yepyeni-parola-1');

      // Kod alanı HATALI çizilir (kırmızı çerçeve) ve ileti kod alanının hemen altındadır (şifre alanlarının altında değil).
      final decoration = tester.widget<TextField>(find.byKey(const Key('field_code'))).decoration!;
      final danger = (decoration.errorBorder! as OutlineInputBorder).borderSide.color;
      expect((decoration.enabledBorder! as OutlineInputBorder).borderSide.color, danger);
      expect((decoration.focusedBorder! as OutlineInputBorder).borderSide.color, danger);
      final code = tester.getRect(find.byKey(const Key('field_code')));
      final message = tester.getRect(find.byKey(const Key('forgot_error')));
      final password = tester.getRect(find.byKey(const Key('field_new_password')));
      expect(message.top, greaterThanOrEqualTo(code.bottom), reason: 'ileti kod alanının altında');
      expect(message.bottom, lessThanOrEqualTo(password.top), reason: 'ileti şifre alanlarının ÜSTÜNDE (kod alanına yakın)');
    });

    testWidgets('şifre hatası (uyuşmazlık) kod alanını kırmızı yapmaz; ileti formun sonunda kalır', (tester) async {
      final env = await atStepTwo(tester);

      await fillReset(tester, confirm: 'baska-parola-9');
      await tapKey(tester, 'btn_reset_password');

      expect(textOf(tester, 'forgot_error'), 'Girdiğiniz şifreler birbiriyle uyuşmuyor');
      final decoration = tester.widget<TextField>(find.byKey(const Key('field_code'))).decoration!;
      final danger = (decoration.errorBorder! as OutlineInputBorder).borderSide.color;
      expect((decoration.enabledBorder! as OutlineInputBorder).borderSide.color, isNot(danger), reason: 'hata kodla ilgili değil');
      final message = tester.getRect(find.byKey(const Key('forgot_error')));
      final confirm = tester.getRect(find.byKey(const Key('field_confirm_password')));
      expect(message.top, greaterThanOrEqualTo(confirm.bottom), reason: 'şifre iletisi şifre alanlarının altında');
      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('süresi dolmuş kod (410) açık mesajla gösterilir', (tester) async {
      final env = await atStepTwo(tester);
      env.cloud.resetError = apiError(410, 'Süre doldu.', code: 'GONE');

      await fillReset(tester);
      await tapKey(tester, 'btn_reset_password');

      expect(textOf(tester, 'forgot_error'), 'Kodun süresi dolmuş veya kullanılmış. Yeni bir kod isteyin.');
    });

    testWidgets('deneme hakkı bitince (429) bekleme süresi gösterilir ve yeniden gönderim o süre kapanır', (tester) async {
      final env = await atStepTwo(tester);
      env.clock.advance(const Duration(seconds: 61)); // ilk bekleme bitsin
      await tester.pump();
      env.cloud.resetError = apiError(429, 'Çok fazla deneme.', code: 'RATE_LIMITED', retryAfter: const Duration(minutes: 15));

      await fillReset(tester);
      await tapKey(tester, 'btn_reset_password');

      expect(textOf(tester, 'forgot_error'), contains('15:00 sonra yeni kod isteyin'));
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNull);
    });

    testWidgets('"Geri" ilk adıma döner', (tester) async {
      await atStepTwo(tester);
      await tapKey(tester, 'btn_forgot_back');
      expect(find.byKey(const Key('field_identifier')), findsOneWidget);
    });
  });

  testWidgets('giriş ekranındaki "Şifremi Unuttum" diyaloğu açar; "İptal" kapatır', (tester) async {
    final env = e2Env(authenticated: false);
    await pumpApp(tester, state: env.state, child: const LoginPage());

    await tapKey(tester, 'btn_forgot_password');
    expect(find.byType(ForgotPasswordDialog), findsOneWidget);
    expect(find.text('Şifre Yenileme'), findsOneWidget);

    await tapKey(tester, 'btn_forgot_cancel');
    expect(find.byType(ForgotPasswordDialog), findsNothing);
  });
}
