import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/delete_account_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Üyelik yönergesi düzeltmeleri (2026-10-08): uyelik-7 (servis PIN'leri de kapanır), uyelik-8 (REAUTH_REQUIRED),
/// uyelik-9 (devredecek kimse yok), uyelik-10 (davet bekleyen hesap girişi), uyelik-16 (şifremi unuttum metinleri),
/// ev_uyelik-2 (devir kabulünde personel/yönetici reddi sunucu mesajıyla).
void main() {
  const pinsClosed = "Ürettiğiniz servis PIN'leri ve açık servis oturumları da kapatılır.";
  const activationHint = 'Hesabınızı servis açtıysa ve hiç şifre belirlemediyseniz e-postadaki etkinleştirme '
      'bağlantısını kullanın ya da Şifremi unuttum ile şifre belirleyin.';

  group('uyelik-7: oturum kapatma metinleri', () {
    testWidgets('Tüm Cihazlardan Çıkış onayı servis PIN\'lerinin de kapandığını söyler', (tester) async {
      final env = e2Env();
      await openFromHost<void>(tester, env.state, (context) => UserProfileDialog.show(context));
      await tapKey(tester, 'btn_logout_all');
      expect(find.textContaining(pinsClosed), findsOneWidget);
    });

    testWidgets('Şifre değiştirme açıklaması servis PIN\'lerinin de kapandığını söyler', (tester) async {
      final env = e2Env();
      await pumpApp(tester, state: env.state, child: const ChangePasswordPage());
      expect(find.textContaining(pinsClosed), findsOneWidget);
    });
  });

  group('hesap silme', () {
    Future<void> submitDelete(WidgetTester tester, E2Env env) async {
      await openFromHost<void>(tester, env.state, (context) => DeleteAccountDialog.show(context));
      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');
    }

    testWidgets('uyelik-8: REAUTH_REQUIRED -> şifresiz kullanıcıya "Şifremi unuttum" yönlendirmesi', (tester) async {
      final env = e2Env();
      env.cloud.deleteAccountError =
          apiError(403, 'Bu işlem için mevcut şifrenizi girin.', code: 'REAUTH_REQUIRED');
      await submitDelete(tester, env);
      expect(
        find.textContaining('Şifreniz yoksa ya da bilmiyorsanız çıkış yapıp Şifremi unuttum ile şifre belirleyin.'),
        findsOneWidget,
      );
      expect(find.byType(DeleteAccountDialog), findsOneWidget);
    });

    testWidgets('uyelik-9: SOLE_OWNER paneli devredecek kimse yoksa yolu söyler', (tester) async {
      final env = e2Env();
      env.cloud.deleteAccountError = apiError(
        409,
        'Önce dairelerin sahipliğini devredin.',
        code: 'SOLE_OWNER',
        details: <String, dynamic>{
          'code': 'SOLE_OWNER',
          'homes': <Map<String, dynamic>>[
            <String, dynamic>{'id': kHomeA, 'name': 'Daire 5'},
          ],
        },
      );
      await submitDelete(tester, env);
      expect(find.byKey(const Key('sole_owner_notice')), findsOneWidget);
      expect(
        textOf(tester, 'sole_owner_no_heir'),
        'Devredecek kimse yoksa yetkili servise başvurun; servis panoyu sıfırlayıp daireyi boşaltabilir, ardından '
        'hesabınızı silebilirsiniz.',
      );
    });
  });

  group('uyelik-10: davet bekleyen / şifresiz hesap girişi', () {
    testWidgets('401 INVALID_CREDENTIALS: sunucu mesajı + etkinleştirme ipucu ve öne çıkan "Şifremi Unuttum"', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.loginError = apiError(401, 'Geçersiz e-posta / telefon veya şifre.', code: 'INVALID_CREDENTIALS');
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', 'yanlis-parola');
      await tapKey(tester, 'btn_login');

      expect(textOf(tester, 'login_error'), 'Geçersiz e-posta / telefon veya şifre.');
      expect(textOf(tester, 'login_activation_hint'), activationHint);
      await tapKey(tester, 'btn_login_hint_forgot');
      expect(find.byType(ForgotPasswordDialog), findsOneWidget);
    });

    testWidgets('başka hatada (sunucu yoğun) ipucu yok', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.loginError = apiError(503, 'Sunucu şu anda yanıt veremiyor.');
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', 'parola-123456');
      await tapKey(tester, 'btn_login');
      expect(find.byKey(const Key('login_activation_hint')), findsNothing);
    });

    testWidgets('telefon-OTP doğrulamasında ACCOUNT_PENDING aynı yönlendirmeyi verir', (tester) async {
      final env = e2Env(authenticated: false);
      await openFromHost<void>(tester, env.state, (context) => PhoneOtpDialog.show(context));
      await typeInto(tester, 'field_phone', '0555 123 45 67');
      await tapKey(tester, 'btn_otp_send');
      env.cloud.otpVerifyError = apiError(403, 'Hesabınız henüz etkinleştirilmedi.', code: 'ACCOUNT_PENDING');
      await typeInto(tester, 'field_code', '123456');
      await tapKey(tester, 'btn_otp_verify');
      expect(textOf(tester, 'otp_error'), 'Hesabınız henüz etkinleştirilmedi. $activationHint');
    });

    testWidgets('sihirli bağlantıyla girişte ACCOUNT_PENDING aynı yönlendirmeyi verir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.magicError = apiError(403, 'Hesabınız henüz etkinleştirilmedi.', code: 'ACCOUNT_PENDING');
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open_host'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MagicLinkPage(
                      link: MagicLink(kind: MagicLinkKind.magicLogin, token: 'test-magic-token-0001-abcdef'),
                    ),
                  ),
                ),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_host')));
      await settle(tester);
      expect(textOf(tester, 'magic_login_error'), 'Hesabınız henüz etkinleştirilmedi. $activationHint');
    });
  });

  group('uyelik-16: şifremi unuttum metinleri', () {
    Future<void> sendFor(WidgetTester tester, E2Env env, String identifier) async {
      await openFromHost<void>(tester, env.state, (context) => ForgotPasswordDialog.show(context));
      await typeInto(tester, 'field_identifier', identifier);
      await tapKey(tester, 'btn_send_code');
    }

    testWidgets('telefonla istendiğinde kodun e-postaya gittiği söylenir (SMS yok)', (tester) async {
      final env = e2Env(authenticated: false);
      await sendFor(tester, env, '0555 123 45 67');
      expect(
        textOf(tester, 'forgot_sent_to'),
        'Kod, bu numaraya bağlı hesabın e-posta adresine gönderildi (hesap varsa). E-postanızı kontrol edin; SMS '
        'gönderilmez.',
      );
      expect(
        textOf(tester, 'forgot_phone_hint'),
        'Telefonla açılmış (e-postasız) hesaplara kod gönderilemez; diğer hesaplarda kod kayıtlı e-postaya gider.',
      );
    });

    testWidgets('e-postayla istendiğinde "<e-posta> adresine gönderilen 6 haneli kodu girin."', (tester) async {
      final env = e2Env(authenticated: false);
      await sendFor(tester, env, 'ayse@ornek.com.tr');
      expect(textOf(tester, 'forgot_sent_to'), 'ayse@ornek.com.tr adresine gönderilen 6 haneli kodu girin.');
    });
  });

  group('ev_uyelik-2: devir kabulünde personel/yönetici reddi', () {
    const serverMessage = 'Servis personeli ve yönetici hesapları daire sahibi olamaz. Devri bir müşteri hesabına yapın.';

    test('bulut istemcisi 403 FORBIDDEN gövdesindeki sunucu mesajını taşır (önizleme ve kabul)', () async {
      final api = MockApi();
      final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
      addTearDown(service.dispose);
      service.setAuthToken('tok');
      api
        ..on('POST', '/api/v1/homes/join-preview', (r) => errorResponse(403, serverMessage, code: 'FORBIDDEN'))
        ..on('POST', '/api/v1/homes/transfer-accept', (r) => errorResponse(403, serverMessage, code: 'FORBIDDEN'));
      await expectLater(
        service.previewJoinCode('AHBU-TR-ABCDEF123456'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', serverMessage)),
      );
      await expectLater(
        service.acceptTransfer('AHBU-TR-ABCDEF123456'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', serverMessage)),
      );
    });

    testWidgets('katılma diyaloğu önizleme ve kabul reddinde sunucu mesajını gösterir', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      env.cloud.previewError = apiError(403, serverMessage, code: 'FORBIDDEN');
      await openFromHost<bool>(tester, env.state, (context) => JoinHomeDialog.show(context));
      await typeInto(tester, 'field_join_code', 'AHBU-TRANSFER:ABCDEF123456');
      await tapKey(tester, 'btn_join_continue');
      expect(textOf(tester, 'join_error'), serverMessage);

      env.cloud.previewError = null;
      env.cloud.acceptError = apiError(403, serverMessage, code: 'FORBIDDEN');
      await tapKey(tester, 'btn_join_continue');
      await typeInto(tester, 'field_join_confirm_phrase', 'DEVRAL');
      await tapKey(tester, 'btn_join_confirm');
      expect(textOf(tester, 'join_error'), serverMessage);
    });
  });
}
