import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Telefon (SMS) ile şifresiz giriş: telefon doğrulama/normalizasyon, sunucudan gelen yeniden gönderim
/// bekleme süresi, kod geçerlilik geri sayımı, kalan deneme hakkı, başarılı giriş.
/// (Google / Apple kuralları `auth_ui_flow_test.dart` içindedir.)
void main() {
  Future<Opened<void>> open(WidgetTester tester, E2Env env) {
    return openFromHost<void>(tester, env.state, (context) => PhoneOtpDialog.show(context));
  }

  Future<void> sendCode(WidgetTester tester, {String phone = '0555 123 45 67'}) async {
    await typeInto(tester, 'field_phone', phone);
    await tapKey(tester, 'btn_otp_send');
  }

  group('kod isteme', () {
    testWidgets('giriş ekranından açılır ve "İptal" ile kapanır', (tester) async {
      final env = e2Env(authenticated: false);
      // Düğme yalnız sunucu SMS yeteneğini bildirirse görünür (UYELIK-04; `GET /auth/capabilities`).
      env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true);
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await tester.pump();

      await tapKey(tester, 'btn_phone_otp');
      expect(find.byType(PhoneOtpDialog), findsOneWidget);
      expect(find.text('Şifresiz SMS Girişi'), findsOneWidget);

      await tapKey(tester, 'btn_otp_cancel');
      expect(find.byType(PhoneOtpDialog), findsNothing);
    });

    testWidgets('geçersiz/boş telefon reddedilir; sunucuya istek gitmez', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);

      await tapKey(tester, 'btn_otp_send');
      expect(find.text('Lütfen telefon numaranızı girin'), findsOneWidget);

      await typeInto(tester, 'field_phone', '12345');
      await tapKey(tester, 'btn_otp_send');
      expect(find.textContaining('5 ile başlamalıdır'), findsOneWidget);
      expect(env.cloud.otpPhones, isEmpty);
    });

    testWidgets('telefon alanı +90 önekli, yalnız 10 hane; numara kanonik +905XXXXXXXXX gönderilir (karar 11)', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);

      await typeInto(tester, 'field_phone', 'tel: 0555-123 (45) 67');
      expect(tester.widget<TextField>(find.byKey(const Key('field_phone'))).controller!.text, '555 123 45 67');
      await tapKey(tester, 'btn_otp_send');

      expect(env.cloud.otpPhones, <String>['+905551234567']);
    });

    testWidgets('kod gönderilince telefon kilitlenir, kod alanı gelir ve sunucunun iletisi gösterilir', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);

      await sendCode(tester);

      expect(find.byKey(const Key('field_code')), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('field_phone'))).enabled, isFalse);
      expect(textOf(tester, 'otp_info'), contains('Doğrulama kodu gönderildi.'));
      expect(textOf(tester, 'otp_info'), contains('+905551234567'));
    });

    testWidgets('çift dokunuşta yalnızca BİR SMS isteği gider', (tester) async {
      final env = e2Env(authenticated: false);
      final gate = Completer<void>();
      env.cloud.otpSendGate = gate;
      await open(tester, env);
      await typeInto(tester, 'field_phone', '05551234567');

      await tester.tap(find.byKey(const Key('btn_otp_send')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_otp_send')), warnIfMissed: false);
      await tester.pump();

      expect(env.cloud.otpPhones, hasLength(1));
      gate.complete();
      await settle(tester);
    });
  });

  group('yeniden gönderim bekleme süresi (`resend_after`) ve geçerlilik süresi', () {
    testWidgets('süre dolmadan "Tekrar Kod İste" kapalıdır; sunucunun 45 sn değeri geri sayılır; dolunca yeniden gönderilebilir', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);
      await sendCode(tester);

      expect(find.text('Tekrar Kod İste (0:45)'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNull);

      env.clock.advance(const Duration(seconds: 20));
      await tester.pump();
      expect(find.text('Tekrar Kod İste (0:25)'), findsOneWidget);

      env.clock.advance(const Duration(seconds: 26));
      await tester.pump();
      expect(find.text('Tekrar Kod İste'), findsOneWidget);

      await tapKey(tester, 'btn_resend_code');
      expect(env.cloud.otpPhones, hasLength(2), reason: 'süre dolduktan sonra yeni kod istendi');
      expect(find.byKey(const Key('field_code')), findsOneWidget);
    });

    testWidgets('kodun geçerlilik süresi geri sayılır; dolunca kırmızı uyarı verilir', (tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);
      await sendCode(tester);
      expect(textOf(tester, 'otp_expiry'), 'Kod süresi: 5:00');

      env.clock.advance(const Duration(minutes: 5, seconds: 1));
      await tester.pump();
      expect(textOf(tester, 'otp_expiry'), 'Kodun süresi doldu');
    });

    testWidgets('429: sunucunun bekleme süresi (resend_after) gösterilir ve kod gönder kapanır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.otpSendError = apiError(429, 'Çok fazla SMS isteği.', code: 'RATE_LIMITED', resendAfter: const Duration(seconds: 120));
      await open(tester, env);

      await sendCode(tester);

      expect(textOf(tester, 'otp_error'), 'Çok fazla SMS isteği.');
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_otp_send'))).onPressed, isNull);

      env.clock.advance(const Duration(seconds: 121));
      await tester.pump();
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_otp_send'))).onPressed, isNotNull);
    });

    testWidgets('SMS gönderilemedi (503) açık mesajla gösterilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.otpSendError = apiError(503, 'SMS gönderilemedi.', code: 'DELIVERY_FAILED');
      await open(tester, env);

      await sendCode(tester);

      expect(textOf(tester, 'otp_error'), 'SMS gönderilemedi.');
      expect(find.byKey(const Key('field_code')), findsNothing);
    });
  });

  group('kod doğrulama', () {
    Future<E2Env> atCodeStep(WidgetTester tester) async {
      final env = e2Env(authenticated: false);
      await open(tester, env);
      await sendCode(tester);
      return env;
    }

    testWidgets('kod yalnızca rakamdır ve 6 haneyle sınırlıdır; eksik kod gönderilmez', (tester) async {
      final env = await atCodeStep(tester);
      await typeInto(tester, 'field_code', '12a-45');
      expect(tester.widget<TextField>(find.byKey(const Key('field_code'))).controller!.text, '1245');

      await tapKey(tester, 'btn_otp_verify');
      expect(textOf(tester, 'otp_error'), 'Kod tam 6 rakam olmalıdır');
      expect(env.cloud.calls.contains('verifyPhoneOtp'), isFalse);
    });

    testWidgets('doğru kodla oturum açılır ve diyalog kapanır', (tester) async {
      final env = await atCodeStep(tester);

      await typeInto(tester, 'field_code', '123456');
      await tapKey(tester, 'btn_otp_verify');
      await settle(tester);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(PhoneOtpDialog), findsNothing);
    });

    testWidgets('hatalı kodda KALAN DENEME HAKKI gösterilir; diyalog açık kalır', (tester) async {
      final env = await atCodeStep(tester);
      env.cloud.otpVerifyError = apiError(401, 'Doğrulama kodu hatalı.', code: 'INVALID_CREDENTIALS', remaining: 2);

      await typeInto(tester, 'field_code', '000000');
      await tapKey(tester, 'btn_otp_verify');

      // Kalan hak TEK yerde (iletinin içinde); sözcükler bölünmeyen boşlukla bağlı: "2." yetim satır kalmaz.
      expect(textOf(tester, 'otp_error'), 'Doğrulama kodu hatalı. Kalan deneme: 2.');
      expect(find.byKey(const Key('otp_remaining_attempts')), findsNothing, reason: 'ikinci "Kalan deneme hakkı" satırı yok');
      expect(find.textContaining('Kalan deneme hakkı'), findsNothing);
      expect(find.byType(PhoneOtpDialog), findsOneWidget);
      expect(env.state.authStatus, isNot(AuthStatus.authenticated));

      // Kod alanı HATALI çizilir (kırmızı çerçeve; odak halkası cyan kalmaz) ve ileti alanın hemen altındadır
      // (geri sayım satırının altında değil).
      final decoration = tester.widget<TextField>(find.byKey(const Key('field_code'))).decoration!;
      final danger = (decoration.errorBorder! as OutlineInputBorder).borderSide.color;
      expect((decoration.enabledBorder! as OutlineInputBorder).borderSide.color, danger);
      expect((decoration.focusedBorder! as OutlineInputBorder).borderSide.color, danger);
      final field = tester.getRect(find.byKey(const Key('field_code')));
      final message = tester.getRect(find.byKey(const Key('otp_error')));
      final expiry = tester.getRect(find.byKey(const Key('otp_expiry')));
      expect(message.top, greaterThanOrEqualTo(field.bottom), reason: 'ileti alanın altında');
      expect(message.bottom, lessThanOrEqualTo(expiry.top), reason: 'ileti geri sayım satırının ÜSTÜNDE (alana yakın)');
    });

    testWidgets('deneme hakkı bitince (429) bekleme süresi gösterilir ve yeni kod isteği o süre kapanır', (tester) async {
      final env = await atCodeStep(tester);
      env.clock.advance(const Duration(seconds: 46)); // ilk bekleme bitti
      await tester.pump();
      env.cloud.otpVerifyError = apiError(429, 'Çok fazla deneme.', code: 'RATE_LIMITED', retryAfter: const Duration(minutes: 10));

      await typeInto(tester, 'field_code', '000000');
      await tapKey(tester, 'btn_otp_verify');

      expect(textOf(tester, 'otp_error'), contains('10:00 sonra yeni kod isteyin'));
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNull);
    });

    testWidgets('süresi dolmuş kod (410) açık mesajla gösterilir', (tester) async {
      final env = await atCodeStep(tester);
      env.cloud.otpVerifyError = apiError(410, 'Süre doldu.', code: 'GONE');

      await typeInto(tester, 'field_code', '123456');
      await tapKey(tester, 'btn_otp_verify');

      expect(textOf(tester, 'otp_error'), 'Kodun süresi dolmuş. Yeni bir kod isteyin.');
    });

    testWidgets('ham istisna metni gösterilmez', (tester) async {
      final env = await atCodeStep(tester);
      env.cloud.otpVerifyError = StateError('NullPointer at com.ahbu.Sms');

      await typeInto(tester, 'field_code', '123456');
      await tapKey(tester, 'btn_otp_verify');

      expect(find.textContaining('NullPointer'), findsNothing);
      expect(textOf(tester, 'otp_error'), 'Doğrulama tamamlanamadı. Lütfen tekrar deneyin.');
    });
  });
}
