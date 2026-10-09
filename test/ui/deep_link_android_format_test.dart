import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/app_shell.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Android uygulama bağlantısı (App Links) zinciri, motorun GERÇEKTEN ilettiği biçimle.
///
/// Flutter 3.47 Android gömücüsü (`FlutterActivityAndFragmentDelegate.maybeGetInitialRouteFromIntent`) bağlantıyı
/// `intent.getData().toString()` ile, yani TAM URL olarak iletir (motorun kendi testi:
/// `setInitialRoute("http://myApp/custom/route?query=test")`):
///
/// * soğuk açılış: `PlatformDispatcher.defaultRouteName` = `https://<site>/claim?uid=..&pin=..`;
/// * sıcak açılış (`onNewIntent`, `launchMode=singleTop`): `flutter/navigation` kanalında
///   `pushRouteInformation {location: <tam URL>}`; çerçeve (`WidgetsApp.didPushRouteInformation`) bunu yol + sorgu +
///   parçaya indirip `pushNamed` eder. Android `onNewIntent`'i `onResume`'dan ÖNCE çağırır: bağlantı sayfası ön plana
///   dönüşten (ve olası biyometrik yeniden kilitten) ÖNCE itilir.
void main() {
  setUpAll(() {
    // Testte ağdan yazı tipi indirilmez (AppShell temaları).
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  const host = 'evotomasyon.gudeteknoloji.com.tr';
  // Gerçek olmayan, biçimi geçerli sahte belirteç ve etiket değerleri.
  const token = 'test-magic-token-0001-abcdef';
  const uid = 'AHBU-S3-1A2B3C';
  const pin = '482916';
  const claimUrl = 'https://$host/claim?uid=$uid&pin=$pin';

  /// Soğuk açılış: motor ilk rotayı tam URL olarak verir (Dart kodu çalışmadan önce).
  void coldStartWith(WidgetTester tester, String url) {
    tester.platformDispatcher.defaultRouteNameTestValue = url;
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
  }

  /// Sıcak açılış: motorun `onNewIntent` sonrası gönderdiği ileti (gerçek kanal yolu).
  Future<void> deliverWarmLink(WidgetTester tester, String url) async {
    final message = const JSONMethodCodec().encodeMethodCall(
      MethodCall('pushRouteInformation', <String, Object?>{'location': url}),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(SystemChannels.navigation.name, message, (_) {});
  }

  Future<void> pumpShell(
    WidgetTester tester,
    E2Env env, {
    Widget home = const Scaffold(body: Center(child: Text('Ana ekran'))),
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(value: env.state, child: AppShell(home: home)),
    );
    await tester.pump();
  }

  group('soğuk açılış: Android ilk rotayı TAM URL olarak verir; ana sayfa bağlantı sayfasının ALTINDA kurulur', () {
    testWidgets('giriş bağlantısı: belirteç TEK kez tüketilir, oturum açılır ve ana ekrana dönülür', (tester) async {
      final env = e2Env(authenticated: false);
      coldStartWith(tester, 'https://$host/magic-login#token=$token');

      await pumpShell(tester, env);
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, <String>[token], reason: 'belirteç bir kez kullanıldı');
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.text('Ana ekran'), findsOneWidget, reason: 'bağlantı sayfası kapandı ve altındaki ana sayfa göründü');
      expect(find.textContaining(token), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('şifre sıfırlama bağlantısı: form açılır; Android geri tuşu ana ekrana döner, istek atılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      coldStartWith(tester, 'https://$host/reset-password#token=$token');

      await pumpShell(tester, env);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);

      await tester.binding.handlePopRoute(); // Android geri tuşu
      await tester.pumpAndSettle();

      expect(find.text('Ana ekran'), findsOneWidget, reason: 'geri tuşu uygulamayı kapatmaz, ana ekrana döner');
      expect(env.cloud.calls, isEmpty);
      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('etiket bağlantısı, oturum yok: giriş yönlendirmesi; "Ana Ekrana Dön" ana ekranı (giriş) açar', (tester) async {
      final env = e2Env(authenticated: false);
      coldStartWith(tester, claimUrl);

      await pumpShell(tester, env);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'deep_link_claim_text'), contains('önce hesabınızla giriş yapın'));
      expect(find.byKey(const Key('field_claim_uid')), findsNothing);

      await tapKey(tester, 'btn_deep_link_back');
      await tester.pumpAndSettle();

      expect(find.text('Ana ekran'), findsOneWidget);
      expect(find.textContaining(pin), findsNothing, reason: 'PIN ekranda gösterilmez');
    });

    testWidgets('etiket bağlantısı, oturum açık: pencere UID/PIN dolu açılır; eşleştirme sonrası ana ekrana dönülür', (tester) async {
      final env = e2Env(role: null);
      coldStartWith(tester, claimUrl);

      await pumpShell(tester, env);
      await settle(tester, frames: 6);
      expect(fieldText(tester, 'field_claim_uid'), uid);
      expect(fieldText(tester, 'field_claim_pin'), pin);
      expect(env.cloud.claimArgs, isEmpty, reason: 'eşleştirme kullanıcı onayı olmadan gönderilmez');

      await tapKey(tester, 'btn_claim_submit');
      await tester.pumpAndSettle();

      expect(env.cloud.claimArgs.single['uid'], uid);
      expect(env.cloud.claimArgs.single['pinLength'], pin.length);
      expect(find.text('Ana ekran'), findsOneWidget);
    });

    testWidgets('bilinen yol, belirteçsiz bağlantı: açıklama sayfası; "Ana Ekrana Dön" ana ekranı açar', (tester) async {
      final env = e2Env(authenticated: false);
      coldStartWith(tester, 'https://$host/reset-password');

      await pumpShell(tester, env);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'deep_link_invalid'), 'Bağlantıda doğrulama kodu yok.');

      await tapKey(tester, 'btn_deep_link_back');
      await tester.pumpAndSettle();

      expect(find.text('Ana ekran'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('manifest önekine takılan bilinmeyen yol (/claim-x): yalnız ana ekran açılır, istisna oluşmaz', (tester) async {
      final env = e2Env(authenticated: false);
      coldStartWith(tester, 'https://$host/claim-x?uid=$uid&pin=$pin');

      await pumpShell(tester, env);
      await tester.pumpAndSettle();

      expect(find.text('Ana ekran'), findsOneWidget);
      expect(find.byKey(const Key('deep_link_invalid')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('sıcak açılış: motor pushRouteInformation ile TAM URL gönderir', () {
    testWidgets('etiket bağlantısı (oturum açık): pencere UID/PIN dolu açılır; kapatılınca ana ekran kalır', (tester) async {
      final env = e2Env(role: null);
      await pumpShell(tester, env);

      await deliverWarmLink(tester, claimUrl);
      await settle(tester, frames: 6);
      expect(fieldText(tester, 'field_claim_uid'), uid);
      expect(fieldText(tester, 'field_claim_pin'), pin);

      await tapKey(tester, 'btn_claim_cancel');
      await tester.pumpAndSettle();

      expect(find.text('Ana ekran'), findsOneWidget);
      expect(env.cloud.claimArgs, isEmpty);
    });

    testWidgets('şifre sıfırlama bağlantısı: form açılır; geri tuşu ana ekrana döner', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpShell(tester, env);

      await deliverWarmLink(tester, 'https://$host/reset-password#token=$token');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Ana ekran'), findsOneWidget);
      expect(env.cloud.calls, isEmpty);
    });

    testWidgets(
        'biyometrik kilit: >= 30 sn arka plandan bağlantıyla dönülürse bağlantı sayfası kilitle KAPANMAZ; '
        'kilit açılınca eşleştirme penceresi UID/PIN dolu açılır', (tester) async {
      final bio = FakeBiometric(supported: true, authResult: true, label: 'Parmak İzi');
      final env = e2Env(role: 'owner', biometric: bio);
      env.cloud.homes = <HomeModel>[testHome()];
      env.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      await pumpShell(tester, env, home: const AuthGate());
      await settle(tester, frames: 6);
      expect(find.byType(DashboardPage), findsOneWidget);

      // Uygulama >= 30 sn arka planda. Android sırası: onNewIntent (bağlantı) -> onResume (ön plan + yeniden kilit).
      env.state.handleLifecycleState(AppLifecycleState.paused);
      env.clock.advance(const Duration(seconds: 31));
      bio.pending = Completer<bool>(); // sistem biyometrik istemi açık; kullanıcı henüz doğrulamadı
      await deliverWarmLink(tester, claimUrl);
      env.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle(tester, frames: 6);

      expect(env.state.authStatus, AuthStatus.checking, reason: 'yeniden kilit');
      expect(textOf(tester, 'deep_link_claim_text'), 'Oturum doğrulanıyor...', reason: 'bağlantı kilitte kaybolmadı');
      expect(find.byKey(const Key('field_claim_uid')), findsNothing, reason: 'kilit açılmadan pencere açılmaz');
      expect(find.byType(DashboardPage), findsNothing, reason: 'kilit ekranının üstünde oturum verisi yok');

      bio.pending!.complete(true);
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(fieldText(tester, 'field_claim_uid'), uid);
      expect(fieldText(tester, 'field_claim_pin'), pin);
    });

    testWidgets('biyometrik kilit, bağlantı sayfasının ALTINDAKİ oturum sayfalarını yine kapatır; geri tuşu kilit ekranına döner',
        (tester) async {
      final bio = FakeBiometric(supported: true, authResult: true, label: 'Parmak İzi');
      final env = e2Env(role: 'owner', biometric: bio);
      env.cloud.homes = <HomeModel>[testHome()];
      env.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      await pumpShell(tester, env, home: const AuthGate());
      await settle(tester, frames: 6);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Gizli oturum sayfası')))));
      await settle(tester, frames: 6);

      env.state.handleLifecycleState(AppLifecycleState.paused);
      env.clock.advance(const Duration(seconds: 31));
      bio.pending = Completer<bool>();
      await deliverWarmLink(tester, claimUrl);
      env.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle(tester, frames: 6);

      expect(textOf(tester, 'deep_link_claim_text'), 'Oturum doğrulanıyor...');
      expect(find.text('Gizli oturum sayfası', skipOffstage: false), findsNothing, reason: 'kilit altındaki sayfa kapandı');

      await tester.binding.handlePopRoute(); // Android geri tuşu: bağlantı sayfası kapanır
      await settle(tester, frames: 6);

      expect(find.byKey(const Key('deep_link_claim_text')), findsNothing);
      expect(find.text('Gizli oturum sayfası', skipOffstage: false), findsNothing);
      expect(find.byType(DashboardPage), findsNothing, reason: 'kilit sürüyor: pano görünmez');
      bio.pending!.complete(false);
      await settle(tester);
    });

    testWidgets('oturum kapanınca (biyometrik kilit DEĞİL) bağlantı sayfası yeniden AÇILMAZ; giriş ekranı gelir', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.homes = <HomeModel>[testHome()];
      await pumpShell(tester, env, home: const AuthGate());
      await settle(tester, frames: 6);
      await deliverWarmLink(tester, claimUrl);
      await settle(tester, frames: 6);
      expect(fieldText(tester, 'field_claim_uid'), uid);

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await tester.pump();
      await settle(tester, frames: 6);

      expect(find.byKey(const Key('deep_link_claim_text')), findsNothing);
      expect(find.byKey(const Key('field_claim_uid')), findsNothing);
      expect(find.byKey(const Key('login_screen')), findsOneWidget);
    });
  });

  group('belirteç ve PIN sızmaz (günlük, motora bildirilen rota, kalıcı depo)', () {
    testWidgets('soğuk + sıcak bağlantı akışında belirteç/PIN debugPrint günlüğüne ve motora bildirilen rotaya düşmez', (tester) async {
      final announced = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.navigation, (call) async {
        announced.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.navigation, null));
      final logs = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
      try {
        final env = e2Env(role: null);
        coldStartWith(tester, claimUrl);
        await pumpShell(tester, env);
        await settle(tester, frames: 6);
        expect(fieldText(tester, 'field_claim_pin'), pin, reason: 'akış gerçekten çalıştı');
        await tapKey(tester, 'btn_claim_cancel');
        await tester.pumpAndSettle();

        await deliverWarmLink(tester, 'https://$host/reset-password#token=$token');
        await tester.pumpAndSettle();
        // Oturum açık: sıfırlama sayfası önce "başka hesap açık" onayını gösterir (UYELIK-05).
        expect(find.byKey(const Key('magic_reset_gate')), findsOneWidget);
      } finally {
        debugPrint = previousPrint;
      }

      final routes = announced
          .where((c) => c.method == 'routeInformationUpdated')
          .map((c) => jsonEncode(c.arguments))
          .toList();
      expect(routes, isNotEmpty, reason: 'gezgin rota değişimini motora bildiriyor (denetim anlamlı)');
      for (final text in <String>[...routes, ...logs]) {
        expect(text, isNot(contains(token)));
        expect(text, isNot(contains(pin)));
        expect(text, isNot(contains('uid=')));
      }
    });

    testWidgets('bağlantıyla giriş ve eşleştirme sonrası belirteç/PIN güvenli depoya ve SharedPreferences\'a yazılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      coldStartWith(tester, 'https://$host/magic-login#token=$token');
      await pumpShell(tester, env);
      await tester.pumpAndSettle();
      expect(env.state.authStatus, AuthStatus.authenticated, reason: 'giriş gerçekleşti (depoya oturum yazıldı)');

      await deliverWarmLink(tester, claimUrl);
      await settle(tester, frames: 6);
      await tapKey(tester, 'btn_claim_submit');
      await tester.pumpAndSettle();
      expect(env.cloud.claimArgs, hasLength(1), reason: 'eşleştirme gerçekleşti');

      final prefs = await SharedPreferences.getInstance();
      final stored = <Object?>[
        ...env.h.storage.memory.data.values,
        for (final key in prefs.getKeys()) prefs.get(key),
      ].join('\n');
      expect(env.h.storage.memory.data, isNotEmpty, reason: 'oturum güvenli depoya yazıldı (denetim anlamlı)');
      expect(stored, isNot(contains(token)));
      expect(stored, isNot(contains(pin)));
    });
  });
}
