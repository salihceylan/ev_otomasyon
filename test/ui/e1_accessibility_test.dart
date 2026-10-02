import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/widgets/settings/child_lock_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Erişilebilirlik kılavuz denetimleri (Flutter'ın yerleşik kılavuzları): dokunma hedefi en az
/// 48 dp, her dokunma hedefinin okunabilir etiketi ve metin kontrastı (WCAG AA 4.5:1). Farklı
/// rol / durum / tema birleşimlerinde ve açık-koyu temada denetlenir.
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> expectAccessible(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  ScheduledRule rule(String id, {int channel = 1, String action = 'off', int hour = 22, String? label}) =>
      ScheduledRule(
        id: id,
        homeId: kHomeA,
        channel: channel,
        channelType: 'relay',
        action: action,
        hour: hour,
        minute: 0,
        daysOfWeek: const <int>[0, 1, 2, 3, 4, 5, 6],
        enabled: true,
        label: label,
      );

  Map<String, dynamic> lanStatus({bool childLock = false}) => <String, dynamic>{
        'device': 'AHBU-S3-TEST01',
        'name': 'Salon Panosu',
        'fw': '1.1.0',
        'provisioned': true,
        'wifi_connected': true,
        'wifi_sta_ssid': 'EvAgi',
        'wifi_sta_ip': '192.168.1.20',
        'ip': '192.168.1.20',
        'child_lock': childLock,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': false},
          <String, dynamic>{'id': 2, 'name': 'Spot', 'type': 0, 'state': true},
        ],
        'shutters': <dynamic>[],
        'dis': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'state': true},
          <String, dynamic>{'id': 2, 'state': false},
        ],
      };

  for (final theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    final tag = theme == ThemeMode.light ? 'açık tema' : 'koyu tema';

    group('Pano ($tag)', () {
      testWidgets('ev sahibi: açık lambalar, huzur bandı, senaryolar ve cihaz kartları', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const DashboardPage(),
            role: 'owner', endpoints: litEndpoints(), size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        expect(byKeyName('banner_peace'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('aile üyesi', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const DashboardPage(), role: 'resident', size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('süresi dolmamış misafir', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const DashboardPage(),
            role: 'guest', home: guestHome(), size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('boş daire: karşılama kartları', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const DashboardPage(),
            role: 'owner', endpoints: <EndpointModel>[], size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        expect(find.text('Evinize Hoş Geldiniz!'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('cihaz listesi hatası: hata kartı ve yeniden dene', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(
          tester,
          const DashboardPage(),
          role: 'owner',
          configure: (h) => h.e1.fetchEndpointsError = kServerError,
          size: const Size(400, 3000),
          themeMode: theme,
        );
        await flush(tester);
        expect(byKeyName('error_card'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('pano çevrimdışı: kurtarma bildirimi', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const DashboardPage(),
            role: 'owner', deviceOnline: false, size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        await expectAccessible(tester);
        handle.dispose();
      });

      for (final role in <String>['super_user', 'service_user']) {
        testWidgets('$role konsolu', (tester) async {
          final handle = tester.ensureSemantics();
          await pumpReady(tester, const DashboardPage(),
              role: 'owner', globalRole: role, size: const Size(400, 3000), themeMode: theme);
          await flush(tester);
          await expectAccessible(tester);
          handle.dispose();
        });
      }
    });

    group('Özel durumlar ($tag)', () {
      testWidgets('çocuk kilitliyken pano: kilit simgeleri ve duvar anahtarı notu', (tester) async {
        final handle = tester.ensureSemantics();
        final h = await pumpReady(tester, const DashboardPage(),
            role: 'owner', endpoints: litEndpoints(), size: const Size(400, 3000), themeMode: theme);
        h.mqtt.emitStateJson(stateJson(childLock: true));
        await flush(tester);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('çevrimdışı açılış: önbellekteki daire ve yeniden dene şeridi', (tester) async {
        final handle = tester.ensureSemantics();
        final h = StateHarness();
        addTearDown(h.dispose);
        h.state
          ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe Yılmaz', role: 'user'))
          ..setAuthStatusForTesting(AuthStatus.authenticated);
        h.cloud.fetchHomesError = kNetworkError;
        h.cloud.endpoints[kHomeA] = testEndpoints();
        h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', online: true)];
        await tester.runAsync(() async {
          await h.storage.saveHomesCache('user-1', <HomeModel>[testHome()]);
          await h.state.fetchHomes();
        });
        await pumpPage(tester, h.state, const DashboardPage(), size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        expect(byKeyName('banner_offline'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('doğrudan (LAN) mod: çocuk kilidi notu ve giriş durumları', (tester) async {
        final handle = tester.ensureSemantics();
        final h = await anonymousLocalHarness();
        addTearDown(h.dispose);
        h.directMock.on('GET', '/api/status', (request) => jsonResponse(lanStatus(childLock: true)));
        await tester.runAsync(() => h.state.setHost('192.168.1.20'));
        await pumpPage(tester, h.state, const DashboardPage(), size: const Size(400, 3000), themeMode: theme);
        await flush(tester);
        expect(byKeyName('card_di_1'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      for (final role in <String>['super_user', 'service_user']) {
        testWidgets('$role çekmecesi açık', (tester) async {
          final handle = tester.ensureSemantics();
          await pumpReady(tester, const DashboardPage(),
              role: 'owner', globalRole: role, size: const Size(400, 1000), themeMode: theme);
          await flush(tester);
          await tester.tap(byKeyName('nav_menu'));
          await tester.pumpAndSettle();
          expect(byKeyName('nav_drawer'), findsOneWidget);
          await expectAccessible(tester);
          handle.dispose();
        });
      }
    });

    group('Ayarlar ($tag)', () {
      for (final role in <String>['owner', 'resident', 'guest']) {
        testWidgets('rol: $role', (tester) async {
          final handle = tester.ensureSemantics();
          await pumpReady(tester, const DeviceSettingsPage(),
              role: role,
              home: role == 'guest' ? guestHome() : null,
              size: const Size(400, 4200),
              themeMode: theme);
          await flush(tester);
          await expectAccessible(tester);
          handle.dispose();
        });
      }

      testWidgets('yetkili servis personeli', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const DeviceSettingsPage(),
            role: 'owner', globalRole: 'service_user', size: const Size(400, 4200), themeMode: theme);
        await flush(tester);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('çocuk kilidi kilitliyken (amber vurgu)', (tester) async {
        final handle = tester.ensureSemantics();
        final h = await pumpReady(tester, const DeviceSettingsPage(),
            role: 'owner', size: const Size(400, 4200), themeMode: theme);
        h.mqtt.emitStateJson(stateJson(childLock: true));
        await flush(tester);
        expect(find.text('Kilitli: duvar anahtarları devre dışı'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });
    });

    group('Zamanlı kurallar ($tag)', () {
      testWidgets('kurallar listesi', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(
          tester,
          const ScheduledRulesPage(),
          configure: (h) => h.e1.rules = <ScheduledRule>[
            rule('a', label: 'Gece kapat'),
            rule('b', channel: 5, action: 'on', hour: 7),
          ],
          size: const Size(400, 1600),
          themeMode: theme,
        );
        await flush(tester);
        expect(byKeyName('card_rule_a'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('boş liste', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const ScheduledRulesPage(), size: const Size(400, 1600), themeMode: theme);
        await flush(tester);
        expect(byKeyName('view_rules_empty'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('kural ekleme diyaloğu', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, const ScheduledRulesPage(), size: const Size(400, 1600), themeMode: theme);
        await flush(tester);
        await tester.tap(byKeyName('btn_add_rule'));
        await tester.pumpAndSettle();
        expect(byKeyName('dialog_rule'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });
    });

    group('Çocuk kilidi sayfaları ($tag)', () {
      testWidgets('bilgi sayfası', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpReady(tester, scaffolded(const ChildLockCard()), size: const Size(400, 1200), themeMode: theme);
        await flush(tester);
        await tester.tap(byKeyName('btn_child_lock_info'));
        await tester.pumpAndSettle();
        expect(byKeyName('child_lock_info_sheet'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });

      testWidgets('kilidi kaldırma onayı (basılı tutma)', (tester) async {
        final handle = tester.ensureSemantics();
        final h = await pumpReady(tester, scaffolded(const ChildLockCard()), size: const Size(400, 1200), themeMode: theme);
        h.mqtt.emitStateJson(stateJson(childLock: true));
        await flush(tester);
        await tester.tap(byKeyName('switch_child_lock'));
        await tester.pumpAndSettle();
        expect(byKeyName('child_lock_disable_sheet'), findsOneWidget);
        await expectAccessible(tester);
        handle.dispose();
      });
    });
  }
}
