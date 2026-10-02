import 'dart:async';
import 'dart:io';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/app_shell.dart';
import 'package:ev_otomasyon/ui/common/qr_flow.dart';
import 'package:ev_otomasyon/ui/common/validators.dart';
import 'package:ev_otomasyon/ui/common/wifi_provision_panel.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/claim/qr_scanner_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// WP-E2 kapanış doğrulamaları (denetim boşlukları ve ekstra bulgular):
///
/// * biyometrik yeniden kilit / oturum kapanışı itilmiş sayfaları ve diyalogları KAPATIR;
/// * derin bağlantı gerçek uygulama kabuğuna bağlıdır (soğuk açılış dahil) ve claim bağlantısı sayfası
///   oturum durumu sonradan belli olunca da çalışır;
/// * üye silme sonrası doğrulama okuması başarısız olursa "hâlâ listede" denmez;
/// * kalıcı servis personeli cihazı yalnızca müşteri adına eşleyebilir;
/// * küçük anahtar (Key) eksikleri.
void main() {
  setUpAll(() {
    // Testte ağdan yazı tipi indirilmez (AppShell temaları).
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // Gerçek olmayan, biçimi geçerli sahte belirteç.
  const token = 'test-magic-token-0001-abcdef';

  // ---------------------------------------------------------------------------
  // AuthGate: kilit / oturum geçişinde itilmiş sayfalar
  // ---------------------------------------------------------------------------

  group('AuthGate: kilit ve oturum geçişinde itilmiş sayfalar ile diyaloglar kapanır', () {
    const memberName = 'Gizli Üye Veli';

    /// Biyometrik kilidi açık, giriş yapmış ev sahibi; kök rota `AuthGate`.
    Future<E2Env> pumpApp0(WidgetTester tester, {bool authResult = false}) async {
      final env = e2Env(
        role: 'owner',
        biometric: FakeBiometric(supported: true, authResult: authResult, label: 'Parmak İzi'),
      );
      env.cloud.homes = <HomeModel>[testHome()];
      env.cloud.members = const <HomeMember>[
        HomeMember(userId: 'uye-1', fullName: memberName, role: 'resident', email: 'veli@ornek.test'),
      ];
      env.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      await pumpApp(tester, state: env.state, child: const AuthGate());
      await settle(tester, frames: 6);
      return env;
    }

    /// Üye listesi sayfasını itip üstünde bir diyalog açar.
    Future<void> pushMembersPageWithDialog(WidgetTester tester) async {
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const FamilyMembersPage())));
      await settle(tester, frames: 6);
      expect(find.textContaining(memberName), findsOneWidget, reason: 'kilitten önce liste görünür');

      unawaited(showDialog<void>(
        context: tester.element(find.byType(FamilyMembersPage)),
        builder: (_) => const AlertDialog(key: Key('secret_dialog'), content: Text('Gizli diyalog')),
      ));
      await settle(tester);
      expect(find.byKey(const Key('secret_dialog')), findsOneWidget);
    }

    Future<void> relock(WidgetTester tester, E2Env env, {Duration away = const Duration(seconds: 31)}) async {
      env.state.handleLifecycleState(AppLifecycleState.paused);
      env.clock.advance(away);
      env.state.handleLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      await settle(tester, frames: 6);
    }

    testWidgets('arka plandan >= 30 sn sonra yeniden kilit: üye listesi ve açık diyalog KAPANIR, veri kilit ekranının üstünde kalmaz', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);

      await relock(tester, env);

      expect(env.state.authStatus, AuthStatus.checking);
      expect(find.byKey(const Key('biometric_locked')), findsOneWidget, reason: 'doğrulama başarısız: kilit ekranı');
      expect(find.byType(FamilyMembersPage), findsNothing);
      expect(find.byKey(const Key('secret_dialog')), findsNothing);
      expect(find.textContaining(memberName), findsNothing, reason: 'üye verisi kilit ekranında görünmez');
      expect(find.byType(DashboardPage), findsNothing);
    });

    testWidgets('kilitliyken itilmiş sayfa yenilenemez: sunucuya üye listesi isteği GİTMEZ', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);
      final before = env.cloud.calls.where((c) => c.startsWith('getHomeMembers')).length;
      expect(before, greaterThan(0));

      await relock(tester, env);
      env.clock.advance(const Duration(minutes: 5));
      await tester.pump();

      expect(env.cloud.calls.where((c) => c.startsWith('getHomeMembers')).length, before);
    });

    testWidgets('kilit açılınca pano gelir ama kapatılan sayfa geri GELMEZ', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);
      await relock(tester, env);

      (env.state.biometricService as FakeBiometric).authResult = true;
      await tapKey(tester, 'btn_biometric_retry');
      await env.state.ready;
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byKey(const Key('biometric_locked')), findsNothing);
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.byType(FamilyMembersPage), findsNothing);
    });

    testWidgets('kısa arka plan (< 30 sn) kilitlemez: itilmiş sayfa yerinde kalır', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);

      await relock(tester, env, away: const Duration(seconds: 10));

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(FamilyMembersPage), findsOneWidget);
      expect(find.byKey(const Key('biometric_locked')), findsNothing);
    });

    testWidgets('Wi-Fi sihirbazı açıkken kilitlenirse: kilit ekranında sihirbaz GÖRÜNMEZ; kilit açılınca sihirbaz yeniden açılır, üye sayfası GELMEZ', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);
      Navigator.of(tester.element(find.byKey(const Key('secret_dialog')))).pop(); // yalnız sihirbaz kalsın
      await settle(tester);
      unawaited(WifiRecoveryDialog.show(tester.element(find.byType(FamilyMembersPage))));
      await settle(tester);
      expect(find.byType(WifiRecoveryDialog), findsOneWidget, reason: 'kilitten önce sihirbaz açık');

      await relock(tester, env);

      expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
      expect(find.byType(WifiRecoveryDialog), findsNothing, reason: 'kilit ekranının üstünde hiçbir şey kalmaz');
      expect(find.byType(FamilyMembersPage), findsNothing);

      (env.state.biometricService as FakeBiometric).authResult = true;
      await tapKey(tester, 'btn_biometric_retry');
      await env.state.ready;
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(WifiRecoveryDialog), findsOneWidget, reason: 'kullanıcı kaldığı yerden devam eder');
      expect(find.byType(FamilyMembersPage), findsNothing, reason: 'oturum verisi gösteren sayfa geri gelmez');
      expect(env.cloud.calls.where((c) => c.startsWith('localKey')), isEmpty, reason: 'sihirbaz sunucuya gitmez');
    });

    testWidgets('sihirbaz açık DEĞİLKEN kilit açılınca hiçbir diyalog kendiliğinden açılmaz', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);
      await relock(tester, env);

      (env.state.biometricService as FakeBiometric).authResult = true;
      await tapKey(tester, 'btn_biometric_retry');
      await env.state.ready;
      await settle(tester, frames: 8);

      expect(find.byType(WifiRecoveryDialog), findsNothing);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('kilitteyken "Şifre ile Giriş Yap" ile çıkılırsa sihirbaz kendiliğinden AÇILMAZ', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);
      Navigator.of(tester.element(find.byKey(const Key('secret_dialog')))).pop();
      await settle(tester);
      unawaited(WifiRecoveryDialog.show(tester.element(find.byType(FamilyMembersPage))));
      await settle(tester);
      await relock(tester, env);

      await tapKey(tester, 'btn_biometric_fallback');
      await tapKey(tester, 'btn_logout_confirm');
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(WifiRecoveryDialog), findsNothing);
    });

    testWidgets('oturum kapanınca (unauthenticated) itilmiş sayfa kapanır ve giriş ekranı gelir', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await tester.pump();
      await settle(tester, frames: 6);

      expect(find.byType(FamilyMembersPage), findsNothing);
      expect(find.byKey(const Key('secret_dialog')), findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.textContaining(memberName), findsNothing);
    });

    testWidgets('kapıyı ilgilendirmeyen durum değişimleri itilmiş sayfayı KAPATMAZ', (tester) async {
      final env = await pumpApp0(tester);
      await pushMembersPageWithDialog(tester);

      env.state.setDevicesForTesting(const <DeviceInfo>[DeviceInfo(deviceUuid: 'AHBU-S3-1A2B3C', name: 'Pano', online: true)]);
      await tester.pump();
      env.state.setCurrentUserForTesting(const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz'));
      await tester.pump();

      expect(find.byType(FamilyMembersPage), findsOneWidget);
      expect(find.byKey(const Key('secret_dialog')), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Derin bağlantı: gerçek uygulama kabuğu
  // ---------------------------------------------------------------------------

  group('derin bağlantı gerçek uygulama kabuğuna (AppShell) bağlıdır', () {
    Future<GlobalKey<NavigatorState>> pumpShell(WidgetTester tester, E2Env env) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: env.state,
          child: AppShell(
            navigatorKey: navKey,
            home: const Scaffold(body: Center(child: Text('Ana ekran'))),
          ),
        ),
      );
      await tester.pump();
      return navKey;
    }

    testWidgets('uygulama açıkken gelen sihirli bağlantı sayfayı açar; istisna oluşmaz ve rota adı belirteç taşımaz', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpShell(tester, env);

      unawaited(navKey.currentState!.pushNamed('/reset-password#token=$token'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.textContaining(token), findsNothing);
    });

    testWidgets('soğuk açılış: platformun ilk rotası şifre sıfırlama bağlantısıysa ana sayfanın üstünde form açılır; kullanıcı onaylamadan istek atılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      tester.platformDispatcher.defaultRouteNameTestValue = '/reset-password#token=$token';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);

      await pumpShell(tester, env);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(env.cloud.calls, isEmpty);
      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('soğuk açılış: giriş bağlantısı belirteci TEK kez tüketir, oturum açılır ve ana sayfaya dönülür', (tester) async {
      final env = e2Env(authenticated: false);
      tester.platformDispatcher.defaultRouteNameTestValue = '/magic-login#token=$token';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);

      await pumpShell(tester, env);
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, <String>[token], reason: 'belirteç bir kez kullanıldı');
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.text('Ana ekran'), findsOneWidget, reason: 'bağlantı sayfası kapandı');
      expect(find.textContaining(token), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('geçersiz ve bilinmeyen bağlantılar istisna fırlatmaz: açık Türkçe sayfa gösterilir', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpShell(tester, env);

      unawaited(navKey.currentState!.pushNamed('/reset-password'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'deep_link_invalid'), 'Bağlantıda doğrulama kodu yok.');
      await tapKey(tester, 'btn_deep_link_back');
      await tester.pumpAndSettle();
      expect(find.text('Ana ekran'), findsOneWidget);

      unawaited(navKey.currentState!.pushNamed('/bilinmeyen-sayfa'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'deep_link_invalid'), 'Bu bağlantı açılamadı.');
      expect(tester.takeException(), isNull);
    });

    test('Android manifestinde derin bağlantı açıksa uygulama kabuğunda yönlendirme üreteci de bağlıdır (yarım bağlı durum yok)', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      final shell = File('lib/ui/app_shell.dart').readAsStringSync();
      final enabled = RegExp(r'flutter_deeplinking_enabled"\s+android:value="true"').hasMatch(manifest);
      final wired = shell.contains('onGenerateRoute: deepLinkOnGenerateRoute') && shell.contains('onUnknownRoute: deepLinkOnUnknownRoute');
      if (enabled) {
        expect(wired, isTrue, reason: 'bayrak açık ama MaterialApp.onGenerateRoute/onUnknownRoute bağlı değil: gelen bağlantıda istisna oluşur');
      }
    });
  });

  group('claim bağlantısı sayfası oturum durumu sonradan belli olunca da çalışır', () {
    const claimRoute = '/claim?uid=AHBU-S3-1A2B3C&pin=482916';

    Future<GlobalKey<NavigatorState>> pumpShell(WidgetTester tester, E2Env env) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: env.state,
          child: AppShell(navigatorKey: navKey, home: const Scaffold(body: Center(child: Text('Ana ekran')))),
        ),
      );
      await tester.pump();
      return navKey;
    }

    testWidgets('soğuk açılış/kilit: önce "doğrulanıyor" gösterilir; oturum sonradan açılınca eşleştirme penceresi AÇILIR', (tester) async {
      final env = e2Env(role: null);
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      final navKey = await pumpShell(tester, env);

      unawaited(navKey.currentState!.pushNamed(claimRoute));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'deep_link_claim_text'), 'Oturum doğrulanıyor...');
      expect(find.byKey(const Key('field_claim_uid')), findsNothing);

      env.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await settle(tester, frames: 6);

      expect(fieldText(tester, 'field_claim_uid'), 'AHBU-S3-1A2B3C');
      expect(fieldText(tester, 'field_claim_pin'), '482916');
    });

    testWidgets('biyometrik kilit: kilit açıklaması gösterilir; "açılıyor" metni takılı kalmaz', (tester) async {
      final env = e2Env(role: null);
      env.state.setBiometricForTesting(isSupported: true, isEnabled: true, failed: true, authStatus: AuthStatus.checking);
      final navKey = await pumpShell(tester, env);

      unawaited(navKey.currentState!.pushNamed(claimRoute));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'deep_link_claim_text'), contains('Oturum kilitli'));
      expect(find.textContaining('açılıyor'), findsNothing);
      expect(find.textContaining('482916'), findsNothing, reason: 'PIN ekranda gösterilmez');
    });

    testWidgets('oturum yoksa: giriş yönlendirmesi; eşleştirme penceresi açılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpShell(tester, env);

      unawaited(navKey.currentState!.pushNamed(claimRoute));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'deep_link_claim_text'), contains('önce hesabınızla giriş yapın'));
      expect(find.byKey(const Key('field_claim_uid')), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Aile: silme sonrası doğrulama okuması
  // ---------------------------------------------------------------------------

  group('üye silme: doğrulama amaçlı yeniden okuma başarısız olursa sonuç yanlış bildirilmez', () {
    const idOwner = 'aaaaaaaa-0000-4000-8000-000000000001';
    const idResident = 'aaaaaaaa-0000-4000-8000-000000000002';

    Future<E2Env> pumpMembers(WidgetTester tester) async {
      final env = e2Env();
      env.cloud.members = const <HomeMember>[
        HomeMember(userId: idOwner, fullName: 'Ev Sahibi Ali', role: 'owner', email: 'ali@ornek.test'),
        HomeMember(userId: idResident, fullName: 'Aile Üyesi Ayşe', role: 'resident', email: 'ayse@ornek.test'),
      ];
      env.state.setCurrentUserForTesting(const UserModel(id: idOwner, email: 'ali@ornek.test', fullName: 'Ev Sahibi Ali'));
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await settle(tester);
      return env;
    }

    testWidgets('silme başarılı ama liste yenilenemedi: "listede görünmeye devam ediyor" DENMEZ, sonuç doğrulanamadı uyarısı verilir', (tester) async {
      final env = await pumpMembers(tester);
      env.cloud.membersError = apiError(0, 'Sunucuya ulaşılamadı.', code: 'NETWORK');

      await tapKey(tester, 'btn_remove_member_$idResident');
      await tapKey(tester, 'btn_remove_confirm');

      expect(env.cloud.removedMembers, <String>[idResident], reason: 'silme isteği gitti');
      expect(find.textContaining('listede görünmeye devam ediyor'), findsNothing, reason: 'yükleme hatası silme sonucu sanılmaz');
      expect(find.textContaining('yetkisi iptal edildi'), findsNothing, reason: 'doğrulanmayan sonuç başarı denmez');
      expect(find.textContaining('doğrulanamadı'), findsOneWidget);
      // Hata kartı + yeniden dene yolu görünür; sonsuz spinner yok.
      expect(find.byKey(const Key('members_error')), findsOneWidget);
      expect(find.byKey(const Key('btn_members_retry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('yeniden okuma başarılı ve üye yok: başarı bildirilir (ayrım korunur)', (tester) async {
      final env = await pumpMembers(tester);

      await tapKey(tester, 'btn_remove_member_$idResident');
      await tapKey(tester, 'btn_remove_confirm');

      expect(env.cloud.removedMembers, <String>[idResident]);
      expect(find.textContaining('yetkisi iptal edildi'), findsOneWidget);
      expect(find.byKey(const Key('card_member_$idResident')), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Claim: kalıcı servis personeli yalnızca müşteri adına eşler
  // ---------------------------------------------------------------------------

  group('cihaz eşleştirme: kalıcı servis personeli yalnızca müşteri adına eşleyebilir', () {
    const uid = 'AHBU-S3-1A2B3C';
    const pin = '482916';

    Future<Opened<bool>> open(WidgetTester tester, E2Env env) =>
        openFromHost<bool>(tester, env.state, (context) => ClaimManualDialog.show(context));

    Future<void> fill(WidgetTester tester) async {
      await typeInto(tester, 'field_claim_uid', uid);
      await typeInto(tester, 'field_claim_pin', pin);
    }

    testWidgets('servis personelinde müşteri alanı baştan açıktır ve kapatılamaz (sunucu kendi adına eşlemeyi reddeder)', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await open(tester, env);

      final switchTile = tester.widget<SwitchListTile>(find.byKey(const Key('switch_claim_for_customer')));
      expect(switchTile.value, isTrue);
      expect(switchTile.onChanged, isNull, reason: 'personel için kapatılamaz');
      expect(find.byKey(const Key('field_claim_customer')), findsOneWidget, reason: 'anahtara dokunmadan müşteri alanı görünür');
      expect(textOf(tester, 'claim_for_customer_hint'), contains('yalnızca müşteri adına'));
    });

    testWidgets('servis personeli müşteri bilgisi ve OTP olmadan eşleme GÖNDEREMEZ; istek sunucuya gitmez', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await open(tester, env);
      await fill(tester);

      await tapKey(tester, 'btn_claim_submit');

      expect(find.byKey(const Key('claim_error')), findsOneWidget);
      expect(env.cloud.claimArgs, isEmpty);
    });

    testWidgets('süper kullanıcıda anahtar isteğe bağlıdır: kapalı başlar ve açılabilir', (tester) async {
      final env = e2Env(role: null, globalRole: 'super_user');
      await open(tester, env);

      var switchTile = tester.widget<SwitchListTile>(find.byKey(const Key('switch_claim_for_customer')));
      expect(switchTile.value, isFalse);
      expect(switchTile.onChanged, isNotNull);
      expect(find.byKey(const Key('field_claim_customer')), findsNothing);

      await tapKey(tester, 'switch_claim_for_customer');
      switchTile = tester.widget<SwitchListTile>(find.byKey(const Key('switch_claim_for_customer')));
      expect(switchTile.value, isTrue);
      expect(find.byKey(const Key('field_claim_customer')), findsOneWidget);
    });

    testWidgets('ev sahibi için müşteri anahtarı hiç görünmez', (tester) async {
      final env = e2Env();
      await open(tester, env);
      expect(find.byKey(const Key('switch_claim_for_customer')), findsNothing);
    });

    testWidgets('OTP gönderildikten sonra cihaz kimliği/PIN/müşteri kilitlenir; daire adı OTP\'ye bağlı olmadığından düzenlenebilir kalır', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await open(tester, env);
      await fill(tester);
      await typeInto(tester, 'field_claim_customer', 'musteri@ornek.test');

      await tapKey(tester, 'btn_claim_send_otp');

      expect(env.cloud.claimOtpArgs, hasLength(1));
      for (final key in <String>['field_claim_uid', 'field_claim_pin', 'field_claim_customer']) {
        expect(isReadOnly(tester, key), isTrue, reason: '$key kilitli');
      }
      expect(isReadOnly(tester, 'field_claim_home_name'), isFalse, reason: 'daire adı OTP\'ye bağlı değildir');
      await typeInto(tester, 'field_claim_home_name', 'Daire 7');
      expect(fieldText(tester, 'field_claim_home_name'), 'Daire 7');
    });
  });

  // ---------------------------------------------------------------------------
  // Wi-Fi: panonun KENDİ kurulum ağı modem bilgisi sayılmaz
  // ---------------------------------------------------------------------------

  group('Wi-Fi sihirbazı hiçbir rol/giriş koşulu aramaz (rol matrisi)', () {
    // `canOpenWifiRecovery` yalnızca giriş yapmış alanlardaki giriş noktalarını gizler; diyalog kapısızdır.
    // Süper kullanıcı için eski sürümde çıkmaz yol vardı (kapı açık ama cihaz anahtarı hiç istenmiyordu).
    final cases = <String, E2Env Function()>{
      'ev sahibi': () => e2Env(role: 'owner'),
      'aile üyesi': () => e2Env(role: 'resident'),
      'misafir': () => e2Env(role: 'guest'),
      'kalıcı servis personeli': () => e2Env(role: null, globalRole: 'service_user'),
      'süper kullanıcı': () => e2Env(role: null, globalRole: 'super_user'),
      'servis PIN oturumu': () => e2Env(role: 'service_session', globalRole: 'service_session'),
      'girişsiz kullanıcı': () => e2Env(authenticated: false),
    };
    for (final entry in cases.entries) {
      testWidgets('${entry.key}: sihirbaz açılır, "yetkiniz yok" denmez, test düğmesi etkindir ve sunucuya hiçbir istek gitmez', (tester) async {
        final env = entry.value();
        await openFromHost<void>(tester, env.state, (context) => WifiRecoveryDialog.show(context));

        expect(find.byType(WifiRecoveryDialog), findsOneWidget);
        expect(find.byKey(const Key('wifi_provision_panel')), findsOneWidget);
        expect(find.text('Bu işlem için yetkiniz yok.'), findsNothing);
        expect(tester.widget<OutlinedButton>(find.byKey(const Key('btn_wifi_check'))).onPressed, isNotNull);
        expect(env.cloud.calls, isEmpty, reason: 'internet/sunucu gerekmez');
        expect(env.h.directMock.requests, isEmpty, reason: 'ana doğrudan istemciye dokunulmaz');
      });
    }
  });

  group('Wi-Fi sihirbazı: panonun kendi kurulum ağı (AHBU-XXXXXX) ev Wi-Fi bilgisi olarak yüklenemez', () {
    // Etiketteki İKİNCİ karekodun biçimi (telefon kamerasıyla okutulur); parola sahte yer tutucudur.
    const boardApQr = r'WIFI:T:WPA;S:AHBU-1A2B3C;P:ornek-parola-1234;;';

    Future<FakeWifiDevice> pumpPanel(WidgetTester tester, {Future<String?> Function(BuildContext)? qrScanner}) async {
      final env = e2Env(role: 'owner');
      final dev = FakeWifiDevice();
      await pumpApp(
        tester,
        state: env.state,
        size: const Size(800, 2200),
        child: Scaffold(
          body: SingleChildScrollView(
            child: WifiProvisionPanel(api: dev.client(env.clock), clock: env.clock, qrScanner: qrScanner),
          ),
        ),
      );
      return dev;
    }

    test('isBoardSetupNetwork yalnızca AHBU-<6 büyük hex> biçimini tanır', () {
      expect(WifiValidators.isBoardSetupNetwork('AHBU-1A2B3C'), isTrue);
      expect(WifiValidators.isBoardSetupNetwork('AHBU-000000'), isTrue);
      expect(WifiValidators.isBoardSetupNetwork('AHBU-Misafir'), isFalse);
      expect(WifiValidators.isBoardSetupNetwork('AHBU-1A2B3'), isFalse);
      expect(WifiValidators.isBoardSetupNetwork('AHBU-1A2B3CD'), isFalse);
      expect(WifiValidators.isBoardSetupNetwork('ahbu-1a2b3c'), isFalse);
      expect(WifiValidators.isBoardSetupNetwork('EvAgi'), isFalse);
      expect(WifiValidators.ssidError('AHBU-1A2B3C'), contains('KENDİ kurulum ağı'));
      expect(WifiValidators.ssidError('AHBU-Misafir'), isNull);
    });

    testWidgets('etiketteki kurulum ağı karekodu okutulursa alanlar DOLDURULMAZ; telefon kamerasını öneren açık hata gösterilir', (tester) async {
      await pumpPanel(tester, qrScanner: (_) async => boardApQr);

      await tapKey(tester, 'btn_wifi_scan_qr');

      expect(fieldText(tester, 'field_wifi_ssid'), isEmpty);
      expect(fieldText(tester, 'field_wifi_password'), isEmpty, reason: 'AP parolası ev Wi-Fi şifresi alanına yazılmaz');
      expect(textOf(tester, 'wifi_form_error'), contains('KENDİ kurulum ağına'));
      expect(textOf(tester, 'wifi_form_error'), contains('kamerasıyla'));
    });

    testWidgets('SSID alanına elle yazılan kurulum ağı adı gönderilmez; cihaza istek gitmez', (tester) async {
      final dev = await pumpPanel(tester);
      await typeInto(tester, 'field_wifi_ssid', 'AHBU-1A2B3C');
      await typeInto(tester, 'field_wifi_password', 'ornek-parola-1234');

      await tapKey(tester, 'btn_wifi_submit');

      expect(textOf(tester, 'wifi_form_error'), contains('KENDİ kurulum ağıdır'));
      expect(dev.connectBodies, isEmpty);
    });

    testWidgets('AHBU- ile başlayan ama kurulum ağı biçiminde olmayan gerçek bir ev ağı adı normal gönderilir', (tester) async {
      final dev = await pumpPanel(tester);
      await typeInto(tester, 'field_wifi_ssid', 'AHBU-Misafir');
      await typeInto(tester, 'field_wifi_password', 'ornek-parola-1234');

      await tapKey(tester, 'btn_wifi_submit');

      expect(dev.connectBodies.single['ssid'], 'AHBU-Misafir');
    });

    testWidgets('modem karekodu normal okunur (kurulum ağı koruması modem bilgisini engellemez)', (tester) async {
      await pumpPanel(tester, qrScanner: (_) async => r'WIFI:T:WPA;S:EvAgi;P:ornek-parola-1234;;');

      await tapKey(tester, 'btn_wifi_scan_qr');

      expect(fieldText(tester, 'field_wifi_ssid'), 'EvAgi');
      expect(fieldText(tester, 'field_wifi_password'), 'ornek-parola-1234');
    });
  });

  // ---------------------------------------------------------------------------
  // Wi-Fi paneli sağlamlaştırma (testsiz kalan hata yolları)
  // ---------------------------------------------------------------------------

  group('Wi-Fi paneli: hata yolları ve şifre alanı', () {
    Future<(E2Env, FakeWifiDevice)> pumpPanel(WidgetTester tester) async {
      final env = e2Env(role: 'owner');
      final dev = FakeWifiDevice();
      await pumpApp(
        tester,
        state: env.state,
        size: const Size(800, 2200),
        child: Scaffold(
          body: SingleChildScrollView(
            child: WifiProvisionPanel(api: dev.client(env.clock), clock: env.clock),
          ),
        ),
      );
      return (env, dev);
    }

    /// Bağlantıyı test eder ve taramanın hata ya da liste ile bitmesini bekler.
    Future<void> checkAndWaitScan(WidgetTester tester, E2Env env) async {
      await tester.tap(find.byKey(const Key('btn_wifi_check')));
      await tester.pump();
      await advanceUntil(tester, env.clock, () => shown('wifi_scan_error') || shown('wifi_network_list'));
    }

    testWidgets('şifre alanı gizli başlar; göster/gizle düğmesi iki yönde çalışır', (tester) async {
      await pumpPanel(tester);
      bool obscured() => tester
          .widget<EditableText>(find.descendant(of: find.byKey(const Key('field_wifi_password')), matching: find.byType(EditableText)))
          .obscureText;

      expect(obscured(), isTrue);
      await tapKey(tester, 'btn_wifi_password_toggle');
      expect(obscured(), isFalse);
      await tapKey(tester, 'btn_wifi_password_toggle');
      expect(obscured(), isTrue);
    });

    testWidgets('tarama 423 (pano kilitli) dönerse bekleme süresiyle açık mesaj gösterilir; ham hata yok', (tester) async {
      final (env, dev) = await pumpPanel(tester);
      dev.api.on('GET', '/api/wifi/scan', (r) => jsonResponse(<String, dynamic>{'error': 'locked', 'retry_after': 45}, status: 423));

      await checkAndWaitScan(tester, env);

      final message = textOf(tester, 'wifi_scan_error');
      expect(message, contains('geçici olarak kilitlendi'));
      expect(message, contains('45 sn'));
      expect(find.textContaining('locked'), findsNothing);
    });

    testWidgets('beklenmeyen istisna (bozuk yanıt/iç hata): genel Türkçe mesaj gösterilir, ham istisna metni gösterilmez', (tester) async {
      final (env, dev) = await pumpPanel(tester);
      dev.api.on('GET', '/api/wifi/scan', (r) => throw StateError('ham-ic-hata-metni'));

      await checkAndWaitScan(tester, env);

      expect(textOf(tester, 'wifi_scan_error'), contains('İşlem tamamlanamadı'));
      expect(find.textContaining('ham-ic-hata-metni'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('gönderim sırasında beklenmeyen istisna: genel mesaj; gönder düğmesi yeniden kullanılabilir', (tester) async {
      final (env, dev) = await pumpPanel(tester);
      dev.api.on('POST', '/api/wifi/connect', (r) => throw StateError('ham-ic-hata-metni'));
      await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
      await typeInto(tester, 'field_wifi_password', 'ornek-parola-1234');

      await tapKey(tester, 'btn_wifi_submit');

      expect(textOf(tester, 'wifi_form_error'), contains('İşlem tamamlanamadı'));
      expect(find.textContaining('ham-ic-hata-metni'), findsNothing);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_wifi_submit'))).onPressed, isNotNull);
      expect(env.cloud.calls, isEmpty);
    });
  });

  group('Wi-Fi sihirbazı dar ekranda ve büyük yazı ölçeğinde taşmaz', () {
    /// Özel durum varsa (ör. RenderFlex taşması) ayrıntılı tanıyla başarısız olur.
    void expectNoException(WidgetTester tester, String reason) {
      final exception = tester.takeException();
      if (exception != null) fail('$reason: ${exception is FlutterError ? exception.toStringDeep() : exception}');
    }

    for (final (Size size, double scale) in <(Size, double)>[
      (const Size(360, 640), 1.5),
      (const Size(360, 640), 2.0),
      (const Size(320, 568), 2.0),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} ekran, yazı ölçeği $scale: adımlar, uzun ağ adları, hata ve başarı görünümleri taşma/istisna üretmez', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final env = e2Env(authenticated: false);
        // Türkçe harfli uzun ağ adı: UTF-8'de 30 bayt (cihaz sınırı 32).
        final dev = FakeWifiDevice()
          ..networks = <Map<String, dynamic>>[
            <String, dynamic>{'ssid': 'Çok Uzun Ev Ağı Adı 2.4GHz', 'rssi': -48, 'enc': true},
            <String, dynamic>{'ssid': 'KomşuAçık', 'rssi': -70, 'enc': false},
            <String, dynamic>{'ssid': 'Uzak', 'rssi': -88, 'enc': true},
          ];
        await openFromHost<void>(
          tester,
          env.state,
          size: size,
          (context) => WifiRecoveryDialog.show(context, api: dev.client(env.clock)),
        );
        expectNoException(tester, 'açılış');

        // Adım 2: bağlantı testi ve tarama listesi.
        await tester.ensureVisible(find.byKey(const Key('btn_wifi_check')));
        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
        expectNoException(tester, 'bağlantı testi + liste');

        // Uzun adlı şifreli ağ seçilir; yanlış parola hatası görünür.
        await tester.ensureVisible(find.byKey(const Key('wifi_network_0')));
        await tester.tap(find.byKey(const Key('wifi_network_0')));
        await tester.pump();
        await typeInto(tester, 'field_wifi_password', 'yanlis-parola-1');
        await tester.ensureVisible(find.byKey(const Key('btn_wifi_submit')));
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        dev.connectState = 'failed';
        dev.connectReason = 202;
        await advanceUntil(tester, env.clock, () => shown('wifi_result_failed'));
        expectNoException(tester, 'hata görünümü');

        // Yeniden dene -> doğru parola -> başarı.
        await tester.ensureVisible(find.byKey(const Key('btn_wifi_retry')));
        await tester.tap(find.byKey(const Key('btn_wifi_retry')));
        await tester.pump();
        dev.connectState = 'idle';
        await typeInto(tester, 'field_wifi_password', 'dogru-parola-12');
        await tester.ensureVisible(find.byKey(const Key('btn_wifi_submit')));
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        dev.connectState = 'success';
        await advanceUntil(tester, env.clock, () => shown('wifi_result_success'));
        await tester.pump();
        expectNoException(tester, 'başarı görünümü');
        expect(find.byKey(const Key('btn_wifi_done')), findsOneWidget);
      });
    }
  });

  group('karekod tarayıcı girişi (scanAndRouteQr)', () {
    testWidgets('kamera desteklenmeyen platformda "Kodu Elle Gir" eşleştirme penceresini açar', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final env = e2Env(role: null);
        await openFromHost<void>(tester, env.state, (context) => scanAndRouteQr(context));
        expect(find.byKey(const Key('scanner_unsupported_title')), findsOneWidget);

        await tapKey(tester, 'btn_manual_entry', settleAfter: false);
        await tester.pumpAndSettle();

        expect(find.byType(QrScannerPage), findsNothing);
        expect(find.byType(ClaimManualDialog), findsOneWidget);
        expect(find.byKey(const Key('field_claim_uid')), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Anahtar (Key) sözleşmesi: küçük eksikler
  // ---------------------------------------------------------------------------

  group('test anahtarları', () {
    testWidgets('kamera hatası ekranındaki "Kodu Elle Gir" anahtarlıdır ve elle girişe yönlendirir', (tester) async {
      final controller = _ErrorScannerController();
      controller.value = controller.value.copyWith(
        isInitialized: true,
        error: const MobileScannerException(errorCode: MobileScannerErrorCode.genericError),
      );
      addTearDown(controller.dispose);
      var manual = 0;
      final env = e2Env(role: null, authenticated: false);
      await openFromHost<String>(
        tester,
        env.state,
        (context) => Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => QrScannerPage(controller: controller, supportedOverride: true, onManualFallback: () => manual++),
          ),
        ),
      );

      expect(find.byKey(const Key('btn_scanner_error_manual')), findsOneWidget);
      await tapKey(tester, 'btn_scanner_error_manual', settleAfter: false);
      await tester.pumpAndSettle();

      expect(manual, 1);
      expect(find.byType(QrScannerPage), findsNothing);
    });

    testWidgets('bekleyen devir varken "Bekleyen devire dön" düğmesi anahtarlıdır ve devir görünümüne döner', (tester) async {
      final env = e2Env();
      env.cloud.pendingTransfer = <String, dynamic>{
        'id': 't1',
        'target_identifier': 'bekleyen@ornek.test',
        'status': 'PENDING',
        'expires_at': '2026-10-03T10:00:00.000Z',
      };
      await openFromHost<void>(tester, env.state, (context) => TransferOwnershipDialog.show(context));
      expect(find.byKey(const Key('transfer_active')), findsOneWidget);

      await tapKey(tester, 'btn_start_new_transfer');
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
      expect(find.byKey(const Key('btn_pending_transfer_back')), findsOneWidget);

      await tapKey(tester, 'btn_pending_transfer_back');
      expect(find.byKey(const Key('transfer_active')), findsOneWidget);
    });
  });
}

/// Kamerayı başlatmayan (platform kanalı yok) sahte denetleyici.
class _ErrorScannerController extends MobileScannerController {
  _ErrorScannerController() : super(autoStart: false);

  @override
  Future<void> start({CameraFacing? cameraDirection, CameraLensType? cameraLensType}) async {}

  @override
  Future<void> stop() async {}
}
