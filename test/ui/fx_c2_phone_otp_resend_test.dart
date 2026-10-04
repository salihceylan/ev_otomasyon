import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/auth_form.dart' show remainingAttemptsText;
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2_support.dart';

/// UYELIK-01 (D19): SMS kod penceresinde "Tekrar Kod İste" BAŞARISIZ olursa (saatlik sınır 429, 503, ağ)
/// önceki kod sunucuda hâlâ geçerlidir: kod alanı ve "Giriş Yap" görünür kalır, yalnız hata iletisi gösterilir.
/// Başarılı yeniden gönderimde mevcut davranış sürer (alan temizlenir, yeni ileti).
void main() {
  Future<E2Env> atCodeStep(WidgetTester tester) async {
    final env = e2Env(authenticated: false);
    await openFromHost<void>(tester, env.state, (context) => PhoneOtpDialog.show(context));
    await typeInto(tester, 'field_phone', '0555 123 45 67');
    await tapKey(tester, 'btn_otp_send');
    expect(find.byKey(const Key('field_code')), findsOneWidget, reason: 'hazırlık: kod adımı');
    // İlk yeniden gönderim beklemesi (sunucu: 45 sn) biter.
    env.clock.advance(const Duration(seconds: 46));
    await tester.pump();
    return env;
  }

  Color enabledBorderOf(WidgetTester tester) =>
      (tester.widget<TextField>(find.byKey(const Key('field_code'))).decoration!.enabledBorder! as OutlineInputBorder).borderSide.color;

  Color errorBorderOf(WidgetTester tester) =>
      (tester.widget<TextField>(find.byKey(const Key('field_code'))).decoration!.errorBorder! as OutlineInputBorder).borderSide.color;

  testWidgets('429 (resend_after 3600): kod alanı ve "Giriş Yap" KALIR, yalnız hata iletisi; eldeki kodla giriş tamamlanır', (tester) async {
    final env = await atCodeStep(tester);
    await typeInto(tester, 'field_code', '123');
    env.cloud.otpSendError = apiError(
      429,
      'Saatlik SMS sınırına ulaşıldı.',
      code: 'RATE_LIMITED',
      resendAfter: const Duration(seconds: 3600),
    );

    await tapKey(tester, 'btn_resend_code');

    expect(env.cloud.otpPhones, hasLength(2), reason: 'yeniden gönderim isteği gitti');
    expect(find.byKey(const Key('field_code')), findsOneWidget, reason: 'kod alanı kaybolmaz');
    expect(find.byKey(const Key('btn_otp_verify')), findsOneWidget, reason: '"Giriş Yap" kalır');
    expect(find.byKey(const Key('btn_otp_send')), findsNothing, reason: 'telefon adımına dönülmez');
    expect(textOf(tester, 'otp_error'), 'Saatlik SMS sınırına ulaşıldı.');
    expect(find.text('Tekrar Kod İste (60:00)'), findsOneWidget, reason: 'sunucunun bekleme süresi geri sayılır');
    expect(tester.widget<TextField>(find.byKey(const Key('field_code'))).enabled, isTrue);
    expect(enabledBorderOf(tester), isNot(errorBorderOf(tester)), reason: 'kod hâlâ geçerli: alan HATALI çizilmez');

    // Eldeki (hâlâ geçerli) kod girilir ve oturum açılır.
    await typeInto(tester, 'field_code', '123456');
    await tapKey(tester, 'btn_otp_verify');
    await settle(tester);
    expect(env.cloud.calls, contains('verifyPhoneOtp'));
    expect(env.state.authStatus, AuthStatus.authenticated);
    expect(find.byType(PhoneOtpDialog), findsNothing);
  });

  testWidgets('503 DELIVERY_FAILED ve ağ hatası: kod alanı ve "Giriş Yap" kalır; telefon kilitli kalır', (tester) async {
    final env = await atCodeStep(tester);
    env.cloud.otpSendError = apiError(503, 'SMS gönderilemedi.', code: 'DELIVERY_FAILED');

    await tapKey(tester, 'btn_resend_code');

    expect(find.byKey(const Key('field_code')), findsOneWidget);
    expect(find.byKey(const Key('btn_otp_verify')), findsOneWidget);
    expect(textOf(tester, 'otp_error'), 'SMS gönderilemedi.');
    expect(tester.widget<TextField>(find.byKey(const Key('field_phone'))).enabled, isFalse, reason: 'aynı numara');
    expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNotNull,
        reason: 'bekleme süresi verilmedi: yeniden denenebilir');

    env.cloud.otpSendError = ApiException.network();
    await tapKey(tester, 'btn_resend_code');
    expect(env.cloud.otpPhones, hasLength(3));
    expect(find.byKey(const Key('field_code')), findsOneWidget);
    expect(find.byKey(const Key('btn_otp_verify')), findsOneWidget);
  });

  testWidgets('başarılı yeniden gönderim: mevcut davranış (kod alanı temizlenir, yeni ileti, bekleme yeniden başlar)', (tester) async {
    final env = await atCodeStep(tester);
    await typeInto(tester, 'field_code', '111111');

    await tapKey(tester, 'btn_resend_code');

    expect(env.cloud.otpPhones, hasLength(2));
    expect(find.byKey(const Key('field_code')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('field_code'))).controller!.text, isEmpty, reason: 'yeni kod için alan temizlenir');
    expect(find.byKey(const Key('otp_error')), findsNothing);
    expect(find.text('Tekrar Kod İste (0:45)'), findsOneWidget);
  });

  testWidgets('hatalı KOD iletisi yine alanı kırmızı çizer (kapsam yalnız yeniden gönderim hatası)', (tester) async {
    final env = await atCodeStep(tester);
    env.cloud.otpVerifyError = apiError(401, 'Doğrulama kodu hatalı.', code: 'INVALID_CREDENTIALS', remaining: 2);

    await typeInto(tester, 'field_code', '000000');
    await tapKey(tester, 'btn_otp_verify');

    // "Kalan deneme: N." eki bölünmeyen boşluklarla üretilir: metin üreticinin kendisiyle karşılaştırılır.
    expect(textOf(tester, 'otp_error'), 'Doğrulama kodu hatalı. ${remainingAttemptsText(2)}');
    expect(enabledBorderOf(tester), errorBorderOf(tester));
  });
}
