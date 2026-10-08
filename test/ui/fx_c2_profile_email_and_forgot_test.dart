import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/auth/delete_account_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2_support.dart';

/// UYELIK-07 (D24): telefonla / Apple-gizli e-postayla açılmış hesapta sunucunun teknik yer tutucu e-postası
/// profilde gösterilmez ("Belirtilmedi"); yeni sunucu `email:null` döner ve istemci bunu güvenle karşılar.
///
/// UYELIK-08 (D25): "Şifremi Unuttum"da kimlik telefon numarasıysa (yalnız BİÇİMDEN; sunucu yanıtına bağlı
/// değil, hesap varlığı sızmaz) bilgi ipucu gösterilir.
void main() {
  // uyelik-16: kod telefonla istense de hesabın e-postasına gider; yalnız e-postasız (telefonla açılmış) hesaba gitmez.
  const phoneHint = 'Telefonla açılmış (e-postasız) hesaplara kod gönderilemez; diğer hesaplarda kod kayıtlı e-postaya gider.';

  group('UYELIK-07 (D24): profil e-postası', () {
    Future<void> openProfile(WidgetTester tester, E2Env env) async {
      await openFromHost<void>(tester, env.state, (context) => UserProfileDialog.show(context));
    }

    for (final placeholder in const <String>[
      'phone_905551234567@ahbu.local',
      'apple.0123456789abcdef01234567@users.noreply.invalid',
      'deleted+99999999-9999-4999-8999-999999999999@deleted.invalid',
      'PHONE_905551234567@AHBU.LOCAL',
    ]) {
      testWidgets('yer tutucu e-posta ($placeholder) "Belirtilmedi" görünür', (tester) async {
        final env = e2Env(email: placeholder);
        await openProfile(tester, env);

        expect(textOf(tester, 'profile_email'), 'Belirtilmedi');
        expect(find.textContaining('@ahbu.local'), findsNothing);
        expect(find.textContaining('noreply.invalid'), findsNothing);
        expect(find.textContaining('deleted.invalid'), findsNothing);
      });
    }

    testWidgets('sunucu e-postayı null verdiyse (yeni sunucu) profil "Belirtilmedi" der', (tester) async {
      final env = e2Env();
      env.state.setCurrentUserForTesting(
        UserModel.fromJson(const <String, dynamic>{'id': kUserId, 'email': null, 'full_name': 'Ayşe Yılmaz', 'phone': kUserPhone}),
      );
      await openProfile(tester, env);

      expect(textOf(tester, 'profile_email'), 'Belirtilmedi');
    });

    testWidgets('gerçek e-posta aynen gösterilir', (tester) async {
      final env = e2Env(email: 'ayse@ornek.com.tr');
      await openProfile(tester, env);

      expect(textOf(tester, 'profile_email'), 'ayse@ornek.com.tr');
    });

    testWidgets('e-postasız (telefonla açılmış) hesap: hesap silme onay ifadesiyle çalışır (e-postaya bağlı değil)', (tester) async {
      final env = e2Env(email: '');
      await openFromHost<void>(tester, env.state, (context) => DeleteAccountDialog.show(context));

      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');
      await tester.pumpAndSettle();

      expect(env.cloud.deleteAccountArgs.single, <String, Object?>{'hasPassword': false, 'passwordLength': null, 'confirm': 'SİL'});
      expect(find.text('Hesabınız silindi.'), findsOneWidget);
    });
  });

  group('UYELIK-08 (D25): şifremi unuttum, telefon kimliği ipucu', () {
    Future<void> openForgot(WidgetTester tester, E2Env env) async {
      await openFromHost<void>(tester, env.state, (context) => ForgotPasswordDialog.show(context));
    }

    testWidgets('telefon numarası yazılınca (biçimden) ipucu çıkar; e-postada çıkmaz; istek gerekmez', (tester) async {
      final env = e2Env(authenticated: false);
      await openForgot(tester, env);
      expect(find.byKey(const Key('forgot_phone_hint')), findsNothing, reason: 'boş alan');

      await typeInto(tester, 'field_identifier', '0555 123 45 67');
      expect(textOf(tester, 'forgot_phone_hint'), phoneHint);
      expect(env.cloud.forgotIdentifiers, isEmpty, reason: 'ipucu sunucu yanıtına bağlı değil');

      await typeInto(tester, 'field_identifier', 'ayse@ornek.com.tr');
      expect(find.byKey(const Key('forgot_phone_hint')), findsNothing);

      await typeInto(tester, 'field_identifier', '+905551234567');
      expect(find.byKey(const Key('forgot_phone_hint')), findsOneWidget);
    });

    testWidgets('telefonla kod istendiğinde ikinci adımda da ipucu kalır; e-postayla istenince yoktur', (tester) async {
      final env = e2Env(authenticated: false);
      await openForgot(tester, env);

      await typeInto(tester, 'field_identifier', '0555 123 45 67');
      await tapKey(tester, 'btn_send_code');
      expect(env.cloud.forgotIdentifiers, <String>['05551234567']);
      expect(find.byKey(const Key('field_code')), findsOneWidget, reason: 'hazırlık: ikinci adım');
      expect(textOf(tester, 'forgot_phone_hint'), phoneHint);

      await tapKey(tester, 'btn_forgot_back');
      await typeInto(tester, 'field_identifier', 'ayse@ornek.com.tr');
      env.clock.advance(const Duration(seconds: 61));
      await tester.pump();
      await tapKey(tester, 'btn_send_code');
      expect(find.byKey(const Key('field_code')), findsOneWidget);
      expect(find.byKey(const Key('forgot_phone_hint')), findsNothing);
    });

    testWidgets('ipucu sunucu yanıtından bağımsızdır: gönderim hatasında da aynı (hesap varlığı sızmaz)', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotError = apiError(503, 'E-posta gönderilemedi.', code: 'DELIVERY_FAILED');
      await openForgot(tester, env);

      await typeInto(tester, 'field_identifier', '05551234567');
      await tapKey(tester, 'btn_send_code');

      expect(textOf(tester, 'forgot_error'), 'E-posta gönderilemedi.');
      expect(textOf(tester, 'forgot_phone_hint'), phoneHint);
    });
  });
}
