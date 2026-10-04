import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/biometric_auth_service.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/settings/appearance_cards.dart';
import 'package:ev_otomasyon/ui/widgets/settings/child_lock_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart' show byKeyName, pumpReady, scaffolded;
import 'e2_support.dart';

/// Biyometrik doğrulama başarısız olunca kullanıcıya NEDENİ söylenir: kayıtlı parmak izi yok, çok fazla
/// hatalı deneme (kilitlenme) gibi durumlar hep aynı "tamamlanamadı" yazısının arkasında kaybolmaz.
/// Kullanıcı yalnızca vazgeçtiyse mevcut genel açıklamalar aynen kalır.
void main() {
  group('İstem diyaloğu', () {
    Finder feedback(String part) =>
        find.descendant(of: find.byKey(const Key('biometric_feedback')), matching: find.textContaining(part));

    Future<E2Env> failEnable(WidgetTester tester, BiometricFailure? failure) async {
      final env = e2Env(
        role: null,
        biometric: FakeBiometric(supported: true, authResult: false)..failure = failure,
      );
      env.state.setBiometricForTesting(isSupported: true, label: 'Parmak İzi', shouldPrompt: true);
      await openFromHost<bool>(
        tester,
        env.state,
        (context) => BiometricPromptDialog.show(context, label: 'Parmak İzi'),
      );
      await tapKey(tester, 'btn_biometric_enable');
      return env;
    }

    testWidgets('çok fazla hatalı denemede kilitlendiğini söyler; diyalog açık kalır', (tester) async {
      final env = await failEnable(tester, BiometricFailure.lockedOut);

      expect(feedback('Çok fazla hatalı deneme'), findsOneWidget);
      expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'yeniden denenebilir');
      expect(env.state.isBiometricEnabled, isFalse);
    });

    testWidgets('cihazda kayıtlı parmak izi yoksa bunu söyler', (tester) async {
      await failEnable(tester, BiometricFailure.notEnrolled);

      expect(feedback('kayıtlı parmak izi'), findsOneWidget);
    });

    testWidgets('kullanıcı vazgeçtiyse genel açıklama aynen kalır', (tester) async {
      await failEnable(tester, null);

      expect(feedback('Parmak İzi doğrulaması tamamlanamadı. Tekrar deneyebilir'), findsOneWidget);
    });
  });

  group('Kilit ekranı', () {
    Future<E2Env> lockedEnv(BiometricFailure? failure) async {
      final storage = FakeStorage();
      await storage.saveAuthToken('kayitli-erisim');
      await storage.saveRefreshToken('kayitli-yenileme');
      await storage.saveUser(const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz'));
      await storage.saveBiometricEnabled(true);
      final env = e2Env(
        authenticated: false,
        autoInit: true,
        storage: storage,
        biometric: FakeBiometric(supported: true, authResult: false)..failure = failure,
      );
      await env.state.ready;
      return env;
    }

    testWidgets('kalıcı kilitlenmede telefonun kilidini açmasını söyler; çıkış yolları yerinde kalır', (tester) async {
      final env = await lockedEnv(BiometricFailure.permanentlyLockedOut);
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
      expect(find.textContaining('PIN, desen ya da şifreyle'), findsOneWidget);
      expect(find.byKey(const Key('btn_biometric_retry')), findsOneWidget);
      expect(find.byKey(const Key('btn_biometric_fallback')), findsOneWidget);
      expect(env.state.authStatus, AuthStatus.checking, reason: 'kilit açılmadı');
    });
  });

  group('Ayarlar kartı', () {
    testWidgets('açarken doğrulama kilitlenme yüzünden başarısızsa neden söylenir; ayar değişmez', (tester) async {
      final h = await pumpReady(tester, scaffolded(const BiometricCard()), biometricSupported: true);
      h.biometric
        ..authResult = false
        ..failure = BiometricFailure.lockedOut;

      await tester.tap(byKeyName('switch_biometric'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final message = tester.widget<Text>(byKeyName('text_biometric_message')).data!;
      expect(message, contains('Çok fazla hatalı deneme'));
      expect(message, contains('Biyometrik giriş açılmadı.'));
      expect(h.state.isBiometricEnabled, isFalse);
    });
  });

  group('Çocuk kilidini kaldırma onayı', () {
    testWidgets('doğrulama kilitlenme yüzünden başarısızsa neden söylenir; kilit kalkmaz', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()), biometricSupported: true);
      h.biometric
        ..authResult = false
        ..failure = BiometricFailure.lockedOut;
      h.mqtt.emitStateJson(stateJson(childLock: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(byKeyName('switch_child_lock'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(byKeyName('btn_child_lock_verify'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final error = tester.widget<Text>(byKeyName('text_child_lock_verify_error')).data!;
      expect(error, contains('Çok fazla hatalı deneme'));
      expect(error, contains('Çocuk kilidi kaldırılmadı.'));
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });
  });
}
