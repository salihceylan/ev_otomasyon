import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart' as sup;
import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis panelindeki "Pano Wi-Fi & Modem Kurulumu" kartı ve "Wi-Fi Kurulum & Kurtarma Sihirbazı" düğmesi
/// (canlı test listesi Aşama 16.1): **giriş durumundan bağımsız** görünür ve çalışır; düğme E2'nin
/// [WifiRecoveryDialog]'unu açar (kopya yok) ve sunucuya hiçbir istek atmaz.

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

/// Düğmeye basar, sihirbaz diyaloğunun açıldığını doğrular ve kapatır.
Future<void> openAndCloseWifiWizard(WidgetTester tester) async {
  await tapKey(tester, 'btn_wifi_setup_wizard');
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(WifiRecoveryDialog), findsOneWidget, reason: 'düğme Wi-Fi kurulum sihirbazını açmalı');
  expect(exists('wifi_dialog_title'), isTrue);
  await tapKey(tester, 'btn_close');
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(WifiRecoveryDialog), findsNothing);
}

void main() {
  group('Pano Wi-Fi & Modem Kurulumu kartı', () {
    testWidgets('girişsiz (oturumsuz) kullanıcıya da görünür; sihirbazı açar ve sunucuya istek atmaz', (tester) async {
      final h = sup.StateHarness();
      addTearDown(h.dispose);
      await sup.pumpApp(tester, child: const ServiceModePage(), state: h.state, size: const Size(900, 2800));
      await settle(tester);

      expect(h.state.isAuthenticated, isFalse);
      expect(exists('service_login_view'), isTrue, reason: 'oturum yokken PIN girişi görünür');
      expect(exists('card_wifi_setup'), isTrue);
      expect(find.text('Pano Wi-Fi & Modem Kurulumu'), findsOneWidget);
      expect(find.text('Wi-Fi Kurulum & Kurtarma Sihirbazı'), findsOneWidget);

      final before = List<String>.of(h.cloud.calls);
      await openAndCloseWifiWizard(tester);
      expect(h.cloud.calls, before, reason: 'Wi-Fi kurulumu internet/giriş gerektirmez: sunucuya istek atılmaz');
      expect(h.cloud.calls.where((c) => c.startsWith('localKey')), isEmpty, reason: 'cihaz anahtarı sunucudan alınmaz');
    });

    testWidgets('geçici servis (PIN) oturumunda panelde görünür ve sihirbazı açar', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 4200),
      );
      await settle(tester);

      expect(env.state.isServiceSession, isTrue);
      expect(exists('btn_new_setup'), isTrue);
      expect(exists('card_wifi_setup'), isTrue);
      final before = env.cloud.calls.where((c) => c.startsWith('localKey')).length;
      await openAndCloseWifiWizard(tester);
      expect(env.cloud.calls.where((c) => c.startsWith('localKey')).length, before);
    });

    testWidgets('kalıcı servis personeli ve süper yönetici panelinde görünür; yalnızca bir kez (yönetim araçlarında yinelenmez)', (tester) async {
      for (final role in <String>['staff', 'super']) {
        final env = await serviceHarness(role: role, flush: () async {});
        addTearDown(env.dispose);
        await pumpPage(
          tester,
          env,
          ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
          size: const Size(900, 4200),
        );
        await settle(tester);
        expect(find.byKey(const Key('card_wifi_setup')), findsOneWidget, reason: role);
        expect(find.byKey(const Key('btn_wifi_setup_wizard')), findsOneWidget, reason: role);
        expect(exists('card_tool_wifi'), isFalse, reason: '$role: eski, giriş kapılı "Wi-Fi Kurtarma" aracı kaldırıldı');
        await openAndCloseWifiWizard(tester);
      }
    });

    testWidgets('oturum süresi dolmuş ekranda da (giriş yokken) Wi-Fi kurulum kartı kullanılabilir', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 4200),
      );
      await settle(tester);

      env.clock.advance(const Duration(hours: 2, seconds: 5));
      await settle(tester);
      expect(env.state.isAuthenticated, isFalse);
      expect(find.text('Oturum süresi doldu'), findsOneWidget);
      expect(exists('btn_new_setup'), isFalse);
      expect(exists('card_wifi_setup'), isTrue, reason: 'Wi-Fi kurulum sihirbazı giriş gerektirmez');
      await openAndCloseWifiWizard(tester);
    });

    testWidgets('servis yetkisi olmayan oturum açık hesapta da (giriş ekranı) kart görünür ve çalışır', (tester) async {
      final h = sup.StateHarness();
      addTearDown(h.dispose);
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'owner-1', email: 'sahip@ornek.test', fullName: 'Ev Sahibi', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await sup.pumpApp(tester, child: const ServiceModePage(), state: h.state, size: const Size(900, 2800));
      await settle(tester);

      expect(exists('service_denied'), isTrue, reason: 'servis paneli açılmaz');
      expect(exists('btn_new_setup'), isFalse);
      expect(exists('card_wifi_setup'), isTrue, reason: 'pano Wi-Fi kurulumu servis yetkisinden bağımsız');
      await openAndCloseWifiWizard(tester);
    });

    testWidgets('dar ekranda ve büyük yazıda kart taşma olmadan çalışır', (tester) async {
      final h = sup.StateHarness();
      addTearDown(h.dispose);
      await sup.pumpApp(tester, child: const ServiceModePage(), state: h.state, size: const Size(360, 800));
      await settle(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(exists('card_wifi_setup'), isTrue);
    });
  });
}
