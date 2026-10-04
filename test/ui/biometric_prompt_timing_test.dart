import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// İlk giriş sonrası biyometrik istemin NE ZAMAN açıldığı.
///
/// İstem yalnızca pano rotası en üstteyken açılır. Giriş akışının kendi sayfası ya da diyaloğu (kayıt,
/// telefon kodu) hâlâ yığındayken açılırsa akış biterken kapattığı rota istemin kendisi olur: pencere
/// kullanıcı hiçbir şey seçmeden kaybolur ve "daha sonra" diye kaydedilir.
///
/// Gerçek ağ sırası sahte API'de `fetchHomesGate` ile kurulur: oturum açılır (pano hazır), ev listesi
/// sonra gelir, giriş çağrısı ancak ondan sonra döner ve akış kendi rotasını kapatır.
void main() {
  E2Env signedOut() => e2Env(authenticated: false, biometric: FakeBiometric(supported: true));

  Future<void> expectPromptAwaitingDecision(WidgetTester tester, E2Env env) async {
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'istem kullanıcı karar verene kadar açık');
    expect(env.state.shouldPromptBiometrics, isTrue, reason: 'kullanıcı henüz karar vermedi');
    expect(await env.h.storage.isBiometricPromptShown(), isFalse, reason: 'karar verilmeden "gösterildi" yazılmaz');
  }

  group('Giriş akışı kendi rotasını kapatırken istem kapanmaz', () {
    testWidgets('kayıt: kayıt sayfası kapanır, istem panonun üstünde açık kalır ve etkinleştirilebilir', (tester) async {
      final env = signedOut();
      env.cloud.fetchHomesGate = Completer<void>();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      await tapKey(tester, 'btn_register');
      await settle(tester, frames: 10); // sayfa geçişi bitsin (giriş formu sahneden çıksın)
      await typeInto(tester, 'field_full_name', 'Ayşe Yılmaz');
      await typeInto(tester, 'field_email', 'yeni@ornek.com.tr');
      await typeInto(tester, 'field_password', kStrongPassword);
      await typeInto(tester, 'field_password_confirm', kStrongPassword);
      await tapKey(tester, 'btn_register_submit');
      await settle(tester, frames: 8); // oturum açıldı; ev listesi henüz gelmedi

      env.cloud.fetchHomesGate!.complete();
      await settle(tester, frames: 12);

      expect(find.byType(RegisterPage), findsNothing, reason: 'kayıt sayfası kapandı');
      await expectPromptAwaitingDecision(tester, env);

      await tapKey(tester, 'btn_biometric_enable');
      expect(env.state.isBiometricEnabled, isTrue);
      expect(find.byType(BiometricPromptDialog), findsNothing);
    });

    testWidgets('telefon kodu: kod diyaloğu kapanır (panonun üstünde kalmaz), istem açık kalır', (tester) async {
      final env = signedOut();
      env.cloud.fetchHomesGate = Completer<void>();
      // SMS ile giriş düğmesi yalnız sunucu yeteneği bildirirse görünür (UYELIK-04).
      env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true);
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      await tapKey(tester, 'btn_phone_otp');
      await typeInto(tester, 'field_phone', '0555 123 45 67');
      await tapKey(tester, 'btn_otp_send');
      await typeInto(tester, 'field_code', '123456');
      await tapKey(tester, 'btn_otp_verify');
      await settle(tester, frames: 8); // oturum açıldı; ev listesi henüz gelmedi

      env.cloud.fetchHomesGate!.complete();
      await settle(tester, frames: 8);

      expect(find.byType(PhoneOtpDialog), findsNothing, reason: 'kod diyaloğu kapandı');
      await expectPromptAwaitingDecision(tester, env);
    });

    testWidgets('e-posta ve şifreyle giriş: istem panoda açılır', (tester) async {
      final env = signedOut();
      env.cloud.fetchHomesGate = Completer<void>();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', kStrongPassword);
      await tapKey(tester, 'btn_login');
      await settle(tester, frames: 8);
      env.cloud.fetchHomesGate!.complete();
      await settle(tester, frames: 8);

      await expectPromptAwaitingDecision(tester, env);
    });
  });

  group('İstem yalnızca pano rotası en üstteyken açılır', () {
    E2Env signedIn() => e2Env(biometric: FakeBiometric(supported: true));

    testWidgets('pano açıldıktan SONRA istenirse de açılır', (tester) async {
      final env = signedIn();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);
      expect(find.byType(BiometricPromptDialog), findsNothing);

      env.state.setBiometricForTesting(isSupported: true, shouldPrompt: true);
      await settle(tester);

      expect(find.byType(BiometricPromptDialog), findsOneWidget);
    });

    testWidgets('üstte başka bir sayfa varken açılmaz; sayfa kapanınca bir kez açılır', (tester) async {
      final env = signedIn();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(key: Key('other_page'), body: Text('Başka sayfa'))),
      ));
      await settle(tester);

      env.state.setBiometricForTesting(isSupported: true, shouldPrompt: true);
      await settle(tester);
      expect(find.byType(BiometricPromptDialog), findsNothing, reason: 'başka sayfanın üstüne binmez');

      navigator.pop();
      await settle(tester, frames: 8);

      expect(find.byKey(const Key('other_page')), findsNothing);
      expect(find.byType(BiometricPromptDialog), findsOneWidget);
    });
  });
}
