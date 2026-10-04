import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// WP-BIO2 (A, arayüz): saklı oturum GERİ YÜKLENİRKEN (soğuk açılış, giriş formu yok) DashboardPage "Biyometrik
/// kullanılsın mı?" istemini ilk kullanımda BİR kez açar; "Daha Sonra" sonrası sonraki açılışlarda açmaz;
/// biyometrik zaten açıksa kilit ekranı gelir ve kilit açılınca istem çıkmaz. `DashboardPage._maybePromptBiometrics`
/// değişmedi: yalnız `shouldPromptBiometrics` üzerinden sürülür.
void main() {
  UserModel user(String id) => UserModel(id: id, email: '$id@example.test', fullName: 'Kullanıcı $id', role: 'user');

  FakeStorage storedSession({bool biometricEnabled = false}) {
    final storage = FakeStorage();
    storage.memory.data
      ..['ahbu_auth_token'] = 'stored-access'
      ..['ahbu_refresh_token'] = 'stored-refresh'
      ..['ahbu_current_user'] = jsonEncode(user('user-1').toJson())
      ..['ahbu_biometric_enabled'] = biometricEnabled ? 'true' : 'false';
    return storage;
  }

  /// Soğuk açılış: durum otomatik başlar ve saklı oturumu geri yükler (giriş formuna uğramaz).
  Future<E2Env> coldStart(FakeStorage storage, {bool authResult = true}) async {
    final env = e2Env(
      authenticated: false,
      autoInit: true,
      storage: storage,
      biometric: FakeBiometric(supported: true, authResult: authResult, label: 'Parmak İzi'),
    );
    env.cloud
      ..homes = <HomeModel>[testHome()]
      ..endpoints[kHomeA] = testEndpoints();
    await env.state.ready;
    return env;
  }

  testWidgets('geri yükleme: pano açılır açılmaz istem bir kez açılır; "Daha Sonra" sonrası ikinci açılışta istem YOK', (tester) async {
    final storage = storedSession();
    final env = await coldStart(storage);
    await pumpApp(tester, state: env.state, child: const AuthGate());
    await settle(tester, frames: 8);

    expect(find.byType(LoginPage), findsNothing, reason: 'saklı oturum: giriş formu yok');
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'ilk kullanım: istem panonun üstünde');
    expect(find.text('Parmak İzi Kullanılsın mı?'), findsOneWidget);
    expect(env.state.shouldPromptBiometrics, isTrue);
    expect(await storage.isBiometricPromptShown(), isFalse, reason: 'karar verilmeden "gösterildi" yazılmaz');
    expect(tester.takeException(), isNull);

    await tapKey(tester, 'btn_biometric_later');
    await settle(tester);
    expect(find.byType(BiometricPromptDialog), findsNothing);
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(env.state.shouldPromptBiometrics, isFalse);
    expect(env.state.isBiometricEnabled, isFalse);
    expect(await storage.isBiometricPromptShown(), isTrue);
    env.h.dispose();

    // İkinci soğuk açılış (aynı depo): istem bir daha sorulmaz.
    final again = await coldStart(storage);
    await pumpApp(tester, state: again.state, child: const AuthGate());
    await settle(tester, frames: 8);

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(BiometricPromptDialog), findsNothing, reason: '"Daha Sonra" kalıcıdır');
    expect(again.state.shouldPromptBiometrics, isFalse);
  });

  testWidgets('geri yükleme: "Evet, Etkinleştir" biyometrik girişi açar; sonraki açılış KİLİT ekranıyla başlar, istem yok', (tester) async {
    final storage = storedSession();
    final env = await coldStart(storage);
    await pumpApp(tester, state: env.state, child: const AuthGate());
    await settle(tester, frames: 8);
    expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'hazırlık');

    await tapKey(tester, 'btn_biometric_enable');
    await settle(tester);

    expect(env.state.isBiometricEnabled, isTrue);
    expect(find.byType(BiometricPromptDialog), findsNothing);
    expect(find.textContaining('etkinleştirildi'), findsOneWidget);
    expect(await storage.isBiometricEnabled(), isTrue);
    expect(await storage.isBiometricPromptShown(), isTrue);
    env.h.dispose();

    // Sonraki soğuk açılış: doğrulama başarısız -> kilit ekranı (pano yok); başarı -> pano, istem yok.
    final locked = await coldStart(storage, authResult: false);
    await pumpApp(tester, state: locked.state, child: const AuthGate());
    await settle(tester, frames: 8);

    expect(locked.state.authStatus, AuthStatus.checking);
    expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
    expect(find.byType(DashboardPage), findsNothing);
    expect(find.byType(BiometricPromptDialog), findsNothing);

    (locked.state.biometricService as FakeBiometric).authResult = true;
    await tapKey(tester, 'btn_biometric_retry');
    await locked.state.ready;
    await settle(tester, frames: 8);

    expect(locked.state.authStatus, AuthStatus.authenticated);
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(BiometricPromptDialog), findsNothing, reason: 'biyometrik zaten açık: istem gerekmez');
    expect(locked.state.shouldPromptBiometrics, isFalse);
  });

  testWidgets('biyometrik AÇIK saklı oturum (istem kaydı olmasa da): kilit ekranı; kilit açılınca pano ve istem YOK', (tester) async {
    final storage = storedSession(biometricEnabled: true);
    final env = await coldStart(storage, authResult: false);
    await pumpApp(tester, state: env.state, child: const AuthGate());
    await settle(tester, frames: 8);

    expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
    expect(find.byType(DashboardPage), findsNothing);
    expect(env.cloud.calls, isEmpty, reason: 'kilitliyken ağa çıkılmaz');

    (env.state.biometricService as FakeBiometric).authResult = true;
    await tapKey(tester, 'btn_biometric_retry');
    await env.state.ready;
    await settle(tester, frames: 8);

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(BiometricPromptDialog), findsNothing);
    expect(env.state.shouldPromptBiometrics, isFalse);
    expect(await storage.isBiometricPromptShown(), isFalse, reason: 'istem hiç sunulmadı: kayıt yazılmaz');
  });

  testWidgets('servis PIN oturumu geri yüklenirken pano açılır, istem açılmaz', (tester) async {
    final storage = FakeStorage();
    storage.memory.data
      ..['ahbu_auth_token'] = 'service-access'
      ..['ahbu_service_session'] = jsonEncode(ServiceSessionInfo(
        homeId: kHomeA,
        homeName: 'Servis Evi',
        expiresAt: kTestNow.add(const Duration(hours: 1)),
        technicianName: 'Usta',
      ).toJson());
    final env = await coldStart(storage);
    await pumpApp(tester, state: env.state, child: const AuthGate());
    await settle(tester, frames: 8);

    expect(env.state.isServiceSession, isTrue);
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.byType(BiometricPromptDialog), findsNothing);
    expect(env.state.shouldPromptBiometrics, isFalse);
    expect((env.state.biometricService as FakeBiometric).authenticateCalls, 0);
  });

  testWidgets('programatik kapanış (çıkış) karar değildir; yeni girişte istem yeniden sunulur (mevcut kural korunur)', (tester) async {
    final storage = storedSession();
    final env = await coldStart(storage);
    await pumpApp(tester, state: env.state, child: const AuthGate());
    await settle(tester, frames: 8);
    expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'hazırlık');

    unawaited(env.state.logout()); // istem açıkken oturum kapanır: kapı istemi kapatır
    await settle(tester, frames: 8);

    expect(find.byType(BiometricPromptDialog), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(await storage.isBiometricPromptShown(), isFalse, reason: 'kullanıcı karar vermedi: "gösterildi" yazılmaz');
    expect(tester.takeException(), isNull);
  });
}
