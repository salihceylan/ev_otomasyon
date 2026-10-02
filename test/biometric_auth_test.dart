import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Biyometrik kilit ve kapı mantığı: kilitli oturumda hiçbir pano (yerel mod dahil) açılmaz; çıkış
/// yolları onaylıdır; açılış ekranı durum hazır olunca biter; zorunlu parola değişimi.
void main() {
  const savedUser = UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz');

  /// Kayıtlı oturum + açık biyometrik kilit ile **otomatik başlatılan** durum.
  Future<E2Env> lockedEnv({bool authResult = false, Map<String, Object> prefs = const <String, Object>{}}) async {
    final storage = FakeStorage();
    await storage.saveAuthToken('kayitli-erisim');
    await storage.saveRefreshToken('kayitli-yenileme');
    await storage.saveUser(savedUser);
    await storage.saveBiometricEnabled(true);
    final env = e2Env(
      authenticated: false,
      autoInit: true,
      storage: storage,
      biometric: FakeBiometric(supported: true, authResult: authResult, label: 'Parmak İzi'),
      prefs: prefs,
    );
    await env.state.ready;
    return env;
  }

  group('AuthGate: biyometrik kilit atlatılamaz', () {
    testWidgets('kilitli oturumda doğrulama başarısızsa YEREL MOD kayıtlı olsa bile pano açılmaz', (tester) async {
      final env = await lockedEnv(prefs: <String, Object>{'saved_app_mode': 'direct'});
      expect(env.state.mode, AppMode.direct, reason: 'kayıtlı mod: doğrudan');
      expect(env.state.authStatus, AuthStatus.checking, reason: 'kilit açılana kadar oturum doğrulanmadı');

      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
      expect(find.text('Parmak İzi doğrulaması tamamlanamadı.'), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing, reason: 'yerel mod dahil hiçbir pano açılmaz');
      expect(find.byType(LoginPage), findsNothing, reason: 'oturum hâlâ geçerli: giriş formu da yok');
      expect(env.cloud.calls, isEmpty, reason: 'kilitliyken ağa çıkılmaz');
      expect(env.h.mqtt.startCount, 0, reason: 'kilitliyken MQTT başlamaz');
    });

    testWidgets('kilit ekranında "Parmak İzi ile Aç": başarıda oturum başlar ve pano açılır', (tester) async {
      final env = await lockedEnv();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);
      expect(find.byKey(const Key('biometric_locked')), findsOneWidget);

      (env.state.biometricService as FakeBiometric).authResult = true;
      await tapKey(tester, 'btn_biometric_retry');
      await env.state.ready;
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byKey(const Key('biometric_locked')), findsNothing);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('"Şifre ile Giriş Yap" ONAY ister; onayla çıkış yapılır (belirteçler silinir) ve giriş formu açılır', (tester) async {
      final env = await lockedEnv(prefs: <String, Object>{'saved_app_mode': 'direct'});
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      await tapKey(tester, 'btn_biometric_fallback');
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget, reason: 'onaysız çıkış yok');
      expect(env.state.authStatus, AuthStatus.checking, reason: 'onaylanmadan oturum silinmez');

      await tapKey(tester, 'btn_logout_confirm');
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(await env.h.storage.getAuthToken(), isNull);
      expect(await env.h.storage.getRefreshToken(), isNull);
      expect(env.state.mode, AppMode.cloud, reason: 'doğrudan mod kolu oturum kapanınca sıfırlanır');
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
    });

    testWidgets('onay verilmezse kilit ekranı ve oturum korunur', (tester) async {
      final env = await lockedEnv();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      await tapKey(tester, 'btn_biometric_fallback');
      await tapKey(tester, 'btn_logout_cancel');

      expect(env.state.authStatus, AuthStatus.checking);
      expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
      expect(await env.h.storage.getRefreshToken(), 'kayitli-yenileme');
    });
  });

  group('AuthGate: oturum/kilit geçişinde itilmiş sayfa ve diyaloglar kapanır', () {
    const secretMember = HomeMember(userId: 'u-secret', fullName: 'Gizli Üye', role: 'resident', email: 'gizli@ornek.test');

    /// Oturum açık + biyometrik kilit açık; pano açık, üstüne üye listesi sayfası itilmiş.
    Future<E2Env> signedInWithMembersPage(WidgetTester tester, {bool authResult = false}) async {
      final env = e2Env(
        role: 'owner',
        biometric: FakeBiometric(supported: true, authResult: authResult, label: 'Parmak İzi'),
      );
      env.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      env.cloud.members = const <HomeMember>[secretMember];
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);
      expect(find.byType(DashboardPage), findsOneWidget);

      unawaited(Navigator.of(tester.element(find.byType(DashboardPage))).push(
        MaterialPageRoute<void>(builder: (_) => const FamilyMembersPage()),
      ));
      await settle(tester, frames: 6);
      expect(find.text('Gizli Üye'), findsOneWidget, reason: 'üye listesi açıldı (hazırlık)');
      return env;
    }

    /// Uygulama arka plana gider, [away] sonra döner (biyometrik yeniden kilit eşiği 30 sn).
    Future<void> backgroundAndReturn(WidgetTester tester, E2Env env, Duration away) async {
      env.state.handleLifecycleState(AppLifecycleState.paused);
      env.clock.advance(away);
      env.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle(tester, frames: 8);
    }

    int memberReads(E2Env env) => env.cloud.calls.where((c) => c.startsWith('getHomeMembers')).length;

    testWidgets('arka plandan >= 30 sn sonra dönüş: kilit ekranı gelir, İTİLMİŞ SAYFA (üye listesi) KAPANIR ve veri görünmez; doğrulama başarısızken ağa çıkılmaz', (tester) async {
      final env = await signedInWithMembersPage(tester);
      final readsBefore = memberReads(env);

      await backgroundAndReturn(tester, env, const Duration(seconds: 45));

      expect(env.state.authStatus, AuthStatus.checking, reason: 'yeniden kilit');
      expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
      expect(find.byType(FamilyMembersPage), findsNothing, reason: 'itilmiş sayfa kilit ekranının üstünde KALMAZ');
      expect(find.text('Gizli Üye'), findsNothing);
      expect(find.text('gizli@ornek.test'), findsNothing);
      expect(find.byType(DashboardPage), findsNothing);
      expect(memberReads(env), readsBefore, reason: 'kilitliyken üye verisi yenilenmedi');
    });

    testWidgets('kilitliyken üye/devir verisi hiçbir yoldan okunmaz (state kapısı: yasak)', (tester) async {
      final env = await signedInWithMembersPage(tester);
      await backgroundAndReturn(tester, env, const Duration(seconds: 45));
      final readsBefore = memberReads(env);

      await expectLater(env.state.fetchHomeMembers(), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      await expectLater(env.state.getHomeTransferStatus(), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      expect(memberReads(env), readsBefore);
      expect(env.cloud.calls.where((c) => c.startsWith('getTransferStatus')), isEmpty);
    });

    testWidgets('açık DİYALOG da kapanır; kilit açılınca pano gelir ama kapatılan sayfa/diyalog geri gelmez', (tester) async {
      final env = await signedInWithMembersPage(tester);
      unawaited(showDialog<void>(
        context: tester.element(find.byType(FamilyMembersPage)),
        builder: (_) => const AlertDialog(key: Key('test_dialog'), title: Text('Açık diyalog')),
      ));
      await settle(tester);
      expect(find.byKey(const Key('test_dialog')), findsOneWidget);

      await backgroundAndReturn(tester, env, const Duration(seconds: 45));
      expect(find.byKey(const Key('test_dialog')), findsNothing, reason: 'diyalog da kapandı');
      expect(find.byType(FamilyMembersPage), findsNothing);

      (env.state.biometricService as FakeBiometric).authResult = true;
      await tapKey(tester, 'btn_biometric_retry');
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.byType(FamilyMembersPage), findsNothing, reason: 'kilit çözülünce eski sayfa açılmaz');
      expect(find.text('Gizli Üye'), findsNothing);
    });

    testWidgets('kısa süre (< 30 sn) arka planda kalma: kilit YOK, itilmiş sayfa yerinde kalır', (tester) async {
      final env = await signedInWithMembersPage(tester);

      await backgroundAndReturn(tester, env, const Duration(seconds: 10));

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(FamilyMembersPage), findsOneWidget);
      expect(find.byKey(const Key('biometric_locked')), findsNothing);
    });

    testWidgets('oturum açıkken parola değişimi ZORUNLU olursa itilmiş sayfalar kapanır; parola ekranı açık kalır (atlatılamaz)', (tester) async {
      final env = await signedInWithMembersPage(tester);

      env.state.setCurrentUserForTesting(
        const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz', mustChangePassword: true),
      );
      await settle(tester, frames: 8);

      expect(find.byType(FamilyMembersPage), findsNothing);
      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
    });

    testWidgets('oturum kapanınca (giriş ekranına dönüş) itilmiş sayfalar kapanır', (tester) async {
      final env = await signedInWithMembersPage(tester);

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await settle(tester, frames: 8);

      expect(find.byType(FamilyMembersPage), findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
    });
  });

  group('AuthGate: güvenli depo okunamıyor', () {
    testWidgets('açılışta çökmez: pano açılmaz, giriş formu gösterilir ve depo hatası durumda yüzeye çıkar', (tester) async {
      final storage = FakeStorage();
      storage.memory.failReads = true;
      final env = e2Env(authenticated: false, autoInit: true, storage: storage);
      await env.state.ready;

      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester);

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(env.state.storageError, isNotNull, reason: 'okunamayan depo "oturum yok" ile karışmaz: hata görünür');
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('gateViewFor (tek karar noktası)', () {
    test('checking durumu her modda açılış/kilit ekranıdır; yerel pano yalnızca OTURUMSUZ ve doğrudan modda açılır', () {
      final env = e2Env(authenticated: false);
      final state = env.state;

      state.setAuthStatusForTesting(AuthStatus.checking);
      state.setModeForTesting(AppMode.direct);
      expect(gateViewFor(state), AuthGateView.splash, reason: 'kilitli/yükleniyor + doğrudan mod: BYPASS yok');
      state.setModeForTesting(AppMode.cloud);
      expect(gateViewFor(state), AuthGateView.splash);

      state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      expect(gateViewFor(state), AuthGateView.login);
      state.setModeForTesting(AppMode.direct);
      expect(gateViewFor(state), AuthGateView.localDashboard, reason: 'oturumsuz yerel mod meşrudur');

      state.setAuthStatusForTesting(AuthStatus.authenticated);
      expect(gateViewFor(state), AuthGateView.dashboard);
    });

    test('oturum açıkken parola değişimi zorunluysa pano yerine parola ekranı seçilir', () {
      final env = e2Env(authenticated: false);
      env.state
        ..setCurrentUserForTesting(const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe', mustChangePassword: true))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      expect(gateViewFor(env.state), AuthGateView.forcedPasswordChange);
    });

    test('servis PIN oturumunda zorunlu parola ekranı çıkmaz (parola yok)', () {
      final env = e2Env(authenticated: false);
      env.state
        ..setCurrentUserForTesting(const UserModel(id: '', email: '', fullName: 'Servis', role: 'service_session', mustChangePassword: true))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      env.cloud.restoreServiceSession(
        accessToken: 'servis',
        info: ServiceSessionInfo(homeId: kHomeA, homeName: 'Servis Evi', expiresAt: kTestNow.add(const Duration(hours: 2))),
      );
      expect(env.state.mustChangePassword, isFalse);
      expect(gateViewFor(env.state), AuthGateView.dashboard);
    });
  });

  group('AuthGate: açılış ekranı sabit süre beklemez', () {
    testWidgets('durum hazırsa (oturumsuz) giriş ekranı sabit bekleme olmadan (0,5 sn içinde) gelir', (tester) async {
      final env = e2Env(authenticated: false);
      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byKey(const Key('splash_checking')), findsNothing);
    });

    testWidgets('durum hazır olunca açılış biter (checking -> unauthenticated)', (tester) async {
      final env = e2Env(authenticated: false);
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpApp(tester, state: env.state, child: const AuthGate());
      expect(find.byKey(const Key('splash_checking')), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await settle(tester, frames: 6);

      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('başlatma 15 sn\'den uzun sürerse sonsuz spinner yerine çıkış yolu sunulur', (tester) async {
      final env = e2Env(authenticated: false);
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpApp(tester, state: env.state, child: const AuthGate());
      expect(find.byKey(const Key('splash_slow_notice')), findsNothing);

      env.clock.advance(const Duration(seconds: 16));
      await tester.pump();

      expect(find.byKey(const Key('splash_slow_notice')), findsOneWidget);
      expect(find.byKey(const Key('btn_splash_fallback')), findsOneWidget);
    });
  });

  group('Zorunlu parola değişimi (must_change_password)', () {
    Future<E2Env> forcedEnv() async {
      final env = e2Env(authenticated: false);
      env.cloud.loginUser = const UserModel(id: kUserId, email: kUserEmail, fullName: 'Müşteri', mustChangePassword: true);
      await env.state.login(kUserEmail, 'gecici-parola-9');
      return env;
    }

    testWidgets('pano açılmaz: parola değiştirme ekranına zorlanır ve geri dönülemez', (tester) async {
      final env = await forcedEnv();
      expect(env.state.mustChangePassword, isTrue);

      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);

      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
      expect(find.byKey(const Key('forced_notice')), findsOneWidget);
      expect(find.byType(BackButton), findsNothing, reason: 'zorunlu ekranda geri düğmesi yok');
      final guards = tester.widgetList<PopScope>(find.descendant(of: find.byType(ChangePasswordPage), matching: find.byType(PopScope)));
      expect(guards.any((guard) => !guard.canPop), isTrue, reason: 'sistem geri tuşu zorunlu ekranı kapatamaz');
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await settle(tester);
      expect(find.byType(ChangePasswordPage), findsOneWidget);
    });

    testWidgets('politika dışı/aynı/uyuşmayan yeni şifre reddedilir, istek gitmez', (tester) async {
      final env = await forcedEnv();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);

      await typeInto(tester, 'field_current_password', 'gecici-parola-9');
      await typeInto(tester, 'field_new_password', 'kisa');
      await typeInto(tester, 'field_confirm_password', 'baska');
      await tapKey(tester, 'btn_change_password');
      expect(find.text('Şifre en az 10 karakter olmalıdır'), findsOneWidget);
      expect(find.text('Şifreler eşleşmiyor'), findsOneWidget);

      await typeInto(tester, 'field_new_password', 'gecici-parola-9');
      await typeInto(tester, 'field_confirm_password', 'gecici-parola-9');
      await tapKey(tester, 'btn_change_password');
      expect(find.text('Yeni şifre mevcut şifreyle aynı olamaz'), findsOneWidget);
      expect(env.cloud.calls.contains('changePassword'), isFalse);
    });

    testWidgets('yanlış mevcut şifre alan hatası olarak gösterilir', (tester) async {
      final env = await forcedEnv();
      env.cloud.changePasswordError = apiError(400, 'Mevcut şifre hatalı.', code: 'INVALID_CREDENTIALS');
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);

      await typeInto(tester, 'field_current_password', 'yanlis-gecici');
      await typeInto(tester, 'field_new_password', 'yepyeni-parola-123');
      await typeInto(tester, 'field_confirm_password', 'yepyeni-parola-123');
      await tapKey(tester, 'btn_change_password');

      expect(find.text('Mevcut şifre hatalı.'), findsOneWidget);
      expect(env.state.mustChangePassword, isTrue);
    });

    testWidgets('başarılı değişimde zorunluluk kalkar ve pano otomatik açılır', (tester) async {
      final env = await forcedEnv();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);

      await typeInto(tester, 'field_current_password', 'gecici-parola-9');
      await typeInto(tester, 'field_new_password', 'yepyeni-parola-123');
      await typeInto(tester, 'field_confirm_password', 'yepyeni-parola-123');
      await tapKey(tester, 'btn_change_password');
      await settle(tester, frames: 8);

      expect(env.cloud.calls.contains('changePassword'), isTrue);
      expect(env.state.mustChangePassword, isFalse);
      expect(find.byType(ChangePasswordPage), findsNothing);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('zorunlu ekrandan ONAYLI çıkış yapılabilir', (tester) async {
      final env = await forcedEnv();
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);

      await tapKey(tester, 'btn_forced_logout');
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_logout_confirm');
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(find.byType(LoginPage), findsOneWidget);
    });
  });

  group('BiometricPromptDialog', () {
    Future<Opened<bool>> open(WidgetTester tester, E2Env env) {
      return openFromHost<bool>(tester, env.state, (context) => BiometricPromptDialog.show(context, label: 'Face ID'));
    }

    E2Env promptEnv({bool authResult = true}) {
      final env = e2Env(role: null, biometric: FakeBiometric(supported: true, authResult: authResult, label: 'Face ID'));
      env.state.setBiometricForTesting(isSupported: true, label: 'Face ID', shouldPrompt: true);
      return env;
    }

    testWidgets('başarılı doğrulama özelliği açar, diyaloğu kapatır ve bilgi verir', (tester) async {
      final env = promptEnv();
      final opened = await open(tester, env);
      expect(find.text('Face ID Kullanılsın mı?'), findsOneWidget);

      await tapKey(tester, 'btn_biometric_enable');

      expect(env.state.isBiometricEnabled, isTrue);
      expect(opened.result, isTrue);
      expect(find.byType(BiometricPromptDialog), findsNothing);
      expect(find.textContaining('etkinleştirildi'), findsOneWidget);
    });

    testWidgets('doğrulama başarısızsa diyalog AÇIK kalır, geri bildirim verir ve yeniden denenebilir', (tester) async {
      final env = promptEnv(authResult: false);
      final opened = await open(tester, env);

      await tapKey(tester, 'btn_biometric_enable');

      expect(env.state.isBiometricEnabled, isFalse);
      expect(opened.done, isFalse);
      expect(find.byKey(const Key('biometric_feedback')), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsOneWidget);

      (env.state.biometricService as FakeBiometric).authResult = true;
      await tapKey(tester, 'btn_biometric_enable');
      expect(env.state.isBiometricEnabled, isTrue);
      expect(opened.result, isTrue);
    });

    testWidgets('doğrulama sürerken (meşgul) çift dokunuş ikinci doğrulama başlatmaz ve geri tuşu kapatmaz', (tester) async {
      final env = promptEnv();
      final biometric = env.state.biometricService as FakeBiometric;
      biometric.pending = Completer<bool>();
      final opened = await open(tester, env);

      await tester.tap(find.byKey(const Key('btn_biometric_enable')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_biometric_enable')), warnIfMissed: false);
      await tester.pump();
      expect(biometric.authenticateCalls, 1);

      await tester.binding.handlePopRoute(); // sistem geri tuşu
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'meşgulken geri tuşu kapatmaz');

      biometric.pending!.complete(true);
      await settle(tester);
      expect(opened.result, isTrue);
    });

    testWidgets('doğrulama istisna fırlatırsa çökmez; geri bildirim gösterilir', (tester) async {
      final env = e2Env(role: null, biometric: _ThrowingBiometric());
      env.state.setBiometricForTesting(isSupported: true, label: 'Face ID', shouldPrompt: true);
      await open(tester, env);

      await tapKey(tester, 'btn_biometric_enable');

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('biometric_feedback')), findsOneWidget);
    });

    testWidgets('"Daha Sonra" istemi bir daha göstermeyecek şekilde kapatır', (tester) async {
      final env = promptEnv();
      final opened = await open(tester, env);

      await tapKey(tester, 'btn_biometric_later');

      expect(opened.result, isFalse);
      expect(env.state.shouldPromptBiometrics, isFalse);
      expect(env.state.isBiometricEnabled, isFalse);
    });

    testWidgets('geri tuşu (meşgul değilken) "Daha Sonra" gibi davranır: istem tekrar etmez', (tester) async {
      final env = promptEnv();
      final opened = await open(tester, env);

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(opened.done, isTrue);
      expect(env.state.shouldPromptBiometrics, isFalse);
    });
  });
}

/// `authenticate` çağrısında platform istisnası fırlatan biyometrik sahte.
class _ThrowingBiometric extends FakeBiometric {
  _ThrowingBiometric() : super(supported: true, label: 'Face ID');

  @override
  Future<bool> authenticate({String reason = '', bool biometricOnly = false}) async {
    throw StateError('platform hatası');
  }
}
