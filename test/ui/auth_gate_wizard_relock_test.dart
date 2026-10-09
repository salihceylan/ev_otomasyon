import 'dart:async';

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'f_support.dart';
import 'f_widget_support.dart' hide settle;
import 'f_widget_support.dart' as fw show settle;

/// Sayfa geçişleri (Android varsayılanı) 300 ms'den uzun sürebilir: kapanan rotalar ağaçtan tam çıksın.
Future<void> settle(WidgetTester tester) => fw.settle(tester, frames: 30);

/// uygulama-ekranlar-1: biyometrik yeniden kilit servis kurulum sihirbazını KAPATMAZ. Teknisyen 5. adımda telefonun
/// Wi-Fi ayarlarında 30 sn'den uzun kalır; dönüşte kilit ekranı sihirbazın ÜSTÜNE gelir, kilit açılınca aynı sihirbaz
/// (aynı denetleyici, bellekteki cihaz anahtarı) kaldığı yerden sürer. Oturum kapanınca sihirbaz kapanır.
void main() {
  /// Personel oturumu + açık biyometrik kilit; kapı (AuthGate) kök, üstünde 5. adımda kayıttan açılmış sihirbaz.
  Future<ServiceHarness> wizardOverGate(WidgetTester tester) async {
    final env = await serviceHarness(flush: () async {});
    addTearDown(env.dispose);
    env.h.biometric
      ..supported = true
      ..authResult = false;
    env.state.setBiometricForTesting(isSupported: true, isEnabled: true);
    env.cloud.seedClaimed();
    env.device
      ..wifiConnected = true
      ..staIp = kLanIp
      ..mqttConfigured = true
      ..mqttConnected = true;
    env.phoneOnHomeNetwork();
    final now = env.clock.now();
    final record = SetupProgressRecord(
      ownerKey: env.access.ownerKey,
      deviceUuid: kDeviceUid,
      homeId: kClaimedHome,
      homeName: 'Daire 5',
      ip: kLanIp,
      currentStep: SetupSteps.wifi,
      createdAt: now,
      updatedAt: now,
    );
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(
        value: env.state,
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await settle(tester);
    expect(find.byType(DashboardPage), findsOneWidget);
    unawaited(Navigator.of(tester.element(find.byType(DashboardPage))).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: ServiceSetupWizardPage.routeName),
      builder: (_) => ServiceSetupWizardPage(
        resume: record,
        store: env.store,
        deviceApiFactory: env.deviceFactory,
        scanner: fakeScanner(null),
      ),
    )));
    await settle(tester);
    expect(find.byType(ServiceSetupWizardPage), findsOneWidget, reason: 'sihirbaz açıldı (hazırlık)');
    return env;
  }

  Future<void> backgroundAndReturn(WidgetTester tester, ServiceHarness env, Duration away) async {
    env.state.handleLifecycleState(AppLifecycleState.paused);
    env.clock.advance(away);
    env.state.handleLifecycleState(AppLifecycleState.resumed);
    await settle(tester);
  }

  final wizardInStack = find.byType(ServiceSetupWizardPage, skipOffstage: false);

  testWidgets('arka plandan 31 sn sonra dönüş: kilit sihirbazın üstüne gelir; kilit açılınca AYNI sihirbaz sürer', (tester) async {
    final env = await wizardOverGate(tester);
    final wizardState = tester.state(find.byType(ServiceSetupWizardPage));

    await backgroundAndReturn(tester, env, const Duration(seconds: 31));

    expect(env.state.authStatus, AuthStatus.checking, reason: 'yeniden kilit');
    expect(find.byKey(const Key('biometric_locked')), findsOneWidget, reason: 'kilit ekranı en üstte');
    expect(find.byType(ServiceSetupWizardPage), findsNothing, reason: 'kilitliyken sihirbaz görünmez');
    expect(wizardInStack, findsOneWidget, reason: 'sihirbaz rotası yığında kalır');

    // Kilit rotası geri tuşuyla kapanmaz.
    final lockNavigator = Navigator.of(tester.element(find.byKey(const Key('biometric_locked'))));
    await lockNavigator.maybePop();
    await settle(tester);
    expect(find.byKey(const Key('biometric_locked')), findsOneWidget);

    env.h.biometric.authResult = true;
    await tapKey(tester, 'btn_biometric_retry');
    await settle(tester);

    expect(env.state.authStatus, AuthStatus.authenticated);
    expect(find.byKey(const Key('biometric_locked')), findsNothing);
    expect(find.byType(ServiceSetupWizardPage), findsOneWidget, reason: 'sihirbaz yeniden görünür');
    expect(identical(tester.state(find.byType(ServiceSetupWizardPage)), wizardState), isTrue,
        reason: 'aynı sihirbaz durumu = aynı denetleyici (bellekteki cihaz anahtarı korunur)');
    expect(find.text('Oturum süresi doldu'), findsNothing, reason: 'biyometrik kilit oturum bitişi sayılmaz');
  });

  testWidgets('kilitliyken "Şifre ile Giriş Yap" (çıkış): kilit ve sihirbaz kapanır, giriş ekranı gelir', (tester) async {
    final env = await wizardOverGate(tester);

    await backgroundAndReturn(tester, env, const Duration(seconds: 31));
    expect(wizardInStack, findsOneWidget);

    await tapKey(tester, 'btn_biometric_fallback');
    await tapKey(tester, 'btn_logout_confirm');
    await settle(tester);

    expect(env.state.authStatus, AuthStatus.unauthenticated);
    expect(wizardInStack, findsNothing, reason: 'oturum kapanınca sihirbaz kapanır');
    expect(find.byKey(const Key('biometric_locked')), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('sihirbaz açık değilken yeniden kilit bugünkü gibi: itilmiş sayfalar kapanır, kilit rotası itilmez', (tester) async {
    final env = await serviceHarness(flush: () async {});
    addTearDown(env.dispose);
    env.h.biometric
      ..supported = true
      ..authResult = false;
    env.state.setBiometricForTesting(isSupported: true, isEnabled: true);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(value: env.state, child: const MaterialApp(home: AuthGate())),
    );
    await settle(tester);
    unawaited(Navigator.of(tester.element(find.byType(DashboardPage))).push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(key: Key('other_page'), body: Text('Başka sayfa')),
    )));
    await settle(tester);
    expect(present('other_page'), isTrue);

    await backgroundAndReturn(tester, env, const Duration(seconds: 31));

    expect(find.byKey(const Key('other_page'), skipOffstage: false), findsNothing);
    expect(find.byKey(const Key('biometric_locked')), findsOneWidget);
  });
}
