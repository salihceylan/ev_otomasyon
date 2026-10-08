import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/qr_flow.dart';
import 'package:ev_otomasyon/ui/dashboard/welcome_cards.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/utils/version_compare.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// Wi-Fi / sahiplenme yönergesi düzeltmeleri (2026-10-08):
///
/// * bireysel-1: eski yazılımlı (v1.3.0 öncesi) pano buluta kendiliğinden bağlanamaz; sürüm karşılaştırma yardımcısı.
/// * bireysel-11: evsiz kullanıcıya Wi-Fi girişi, Wi-Fi karekodu sihirbazı açar, bitiş ve "pano bulunamadı" metinleri.
/// * bireysel-13: hazırlanmamış panoda servis rolü olmayan kullanıcı açamayacağı sihirbaza yönlendirilmez.
void main() {
  const oldFwWarning = 'Bu pano yazılımı buluta kendiliğinden bağlanamaz; yetkili servisten güncelleme isteyin.';
  const apWindowHint =
      'Kurulum ağı açılıştan sonra 10 dk açık kalır, sonra 15 dk kapanır; görünmüyorsa panonun elektriğini kapatıp açın.';

  group('sürüm karşılaştırma (bireysel-1)', () {
    test('1.2.1 < 1.3.0; 1.3.1 ve 1.3.0 >= 1.3.0; v öneki, eksik yama ve ön sürüm eki', () {
      expect(versionAtLeast('1.2.1', '1.3.0'), isFalse);
      expect(versionAtLeast('1.3.1', '1.3.0'), isTrue);
      expect(versionAtLeast('1.3.0', '1.3.0'), isTrue);
      expect(versionAtLeast('1.10.0', '1.3.0'), isTrue, reason: 'sayısal karşılaştırma (metin değil)');
      expect(versionAtLeast('v1.3.1', '1.3.0'), isTrue);
      expect(versionAtLeast('1.3', '1.3.0'), isTrue);
      expect(versionAtLeast('1.3.0-rc1', '1.3.0'), isTrue);
      expect(versionAtLeast('0.9.9', '1.3.0'), isFalse);
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.2.0', '1.2'), 0);
    });

    test('bozuk / boş değer -> null (uyarı gösterilmez)', () {
      for (final bad in <String?>[null, '', '  ', 'abc', '1', '1.x.0', '1.2.3.4', '..', '-1.2.0']) {
        expect(versionAtLeast(bad, '1.3.0'), isNull, reason: '"$bad"');
      }
    });
  });

  Future<Opened<void>> openDialog(WidgetTester tester, E2Env env, {String? deviceUuid}) => openFromHost<void>(
        tester,
        env.state,
        (context) => WifiRecoveryDialog.show(context, deviceUuid: deviceUuid),
      );

  Future<void> testConnection(WidgetTester tester, E2Env env) async {
    await tester.tap(find.byKey(const Key('btn_wifi_check')));
    await tester.pump();
    await tester.pump();
    await advanceUntil(
      tester,
      env.clock,
      () => shown('wifi_network_list') || shown('wifi_scan_error') || shown('wifi_check_error'),
    );
    await tester.pump();
  }

  group('eski yazılım uyarısı (bireysel-1)', () {
    testWidgets('servis rolü olmayan kullanıcı, fw 1.2.1 -> uyarı', (tester) async {
      final env = e2Env();
      final dev = FakeWifiDevice(fw: '1.2.1');
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);
      expect(textOf(tester, 'wifi_fw_old_warning'), startsWith(oldFwWarning));
    });

    testWidgets('fw 1.3.1 ve bozuk sürümde uyarı yok', (tester) async {
      for (final fw in <String>['1.3.1', 'bozuk']) {
        final env = e2Env();
        final dev = FakeWifiDevice(fw: fw);
        await http.runWithClient(() async {
          await openDialog(tester, env);
          await testConnection(tester, env);
        }, () => dev.api.client);
        expect(find.byKey(const Key('wifi_fw_old_warning')), findsNothing, reason: fw);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('daha önce buluta bağlanmış (evdeki) eski panoda uyarı yok: Wi-Fi değişikliği yeterli', (tester) async {
      final env = e2Env();
      env.state.setDevicesForTesting(<DeviceInfo>[
        DeviceInfo(deviceUuid: kDeviceUid, lastSeenAt: kTestNow.subtract(const Duration(days: 1))),
      ]);
      final dev = FakeWifiDevice(fw: '1.2.1');
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);
      expect(find.byKey(const Key('wifi_fw_old_warning')), findsNothing);
    });

    testWidgets('servis personelinde uyarı yok (sihirbaz bulut kimliğini kendisi verir)', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      final dev = FakeWifiDevice(fw: '1.2.1');
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);
      expect(find.byKey(const Key('wifi_fw_old_warning')), findsNothing);
    });
  });

  group('hazırlanmamış pano (bireysel-13)', () {
    testWidgets('servis rolü olmayan kullanıcı: satıcı / servis yönlendirmesi; pano kimliği hatırlanır', (tester) async {
      final env = e2Env();
      final dev = FakeWifiDevice(provisioned: false);
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);
      expect(textOf(tester, 'wifi_check_error'), kUnprovisionedBoardUserMessage);
      expect(find.textContaining('Yeni Kurulum Başlat'), findsNothing, reason: 'açamayacağı sihirbaza yönlendirilmez');
      expect(env.state.isKnownUnprovisioned(kDeviceUid), isTrue);
    });

    testWidgets('servis personeli: sihirbaz yönlendirmesi kalır', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      final dev = FakeWifiDevice(provisioned: false);
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);
      expect(textOf(tester, 'wifi_check_error'), contains('Yeni Kurulum Başlat'));
    });

    test('doğrudan kipte hazırlanmamış pano mesajı role göre', () async {
      Future<String?> directErrorFor(UserModel? user) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final h = StateHarness();
        addTearDown(h.dispose);
        if (user != null) {
          h.state
            ..setCurrentUserForTesting(user)
            ..setAuthStatusForTesting(AuthStatus.authenticated)
            ..setHomesForTesting(<HomeModel>[testHome()]);
        }
        h.directMock.on(
          'GET',
          '/api/status',
          (r) => jsonResponse(<String, dynamic>{
            'device': 'AHBU-S3-TEST01',
            'name': 'Pano',
            'fw': '1.3.1',
            'provisioned': false,
            'wifi_connected': false,
          }),
        );
        await h.state.setMode(AppMode.direct);
        await h.state.setHost('192.168.1.30');
        await h.state.refresh();
        return h.state.directError;
      }

      expect(
        await directErrorFor(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user')),
        kUnprovisionedBoardUserMessage,
      );
      expect(await directErrorFor(null), kUnprovisionedBoardUserMessage, reason: 'girişsiz kullanıcı da servis değildir');
      expect(
        await directErrorFor(const UserModel(id: 's', email: 's@b.c', fullName: 'S', role: 'service_user')),
        'Cihaz henüz kurulmamış. Servis kurulumunu tamamlayın.',
      );
    });
  });

  group('Wi-Fi yönergeleri (bireysel-11)', () {
    testWidgets('"Pano bulunamadı": kurulum ağının açık kalma süresi ve elektrik kesip açma ipucu', (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice()..statusDown = true;
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);
      final error = textOf(tester, 'wifi_check_error');
      expect(error, startsWith('Pano bulunamadı.'));
      expect(error, contains(apWindowHint));
    });

    testWidgets('bitiş metni: sahiplenildiyse buluta bağlanır, değilse 1. karekodla eşleyin', (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice(fw: '1.3.1');
      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
        await tester.tap(find.byKey(const Key('wifi_network_0')));
        await tester.pump();
        await typeInto(tester, 'field_wifi_password', 'yeni-evagi-sifresi');
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();
        dev.connectState = 'success';
        await advanceUntil(tester, env.clock, () => shown('wifi_done_text'));
      }, () => dev.api.client);
      expect(
        textOf(tester, 'wifi_done_text'),
        'Pano sahiplenildiyse birkaç dakika içinde buluta bağlanır; henüz sahiplenmediyseniz etiketteki 1. karekodla '
        'eşleyin.',
      );
    });

    testWidgets('evsiz kullanıcı: "Pano Wi-Fi Kurulumu" düğmesi (kapısız) ve kendi kurulum yönergesi', (tester) async {
      final env = e2Env(role: null);
      await pumpApp(
        tester,
        state: env.state,
        child: const Scaffold(body: SingleChildScrollView(child: HomelessWelcome())),
        size: const Size(800, 2000),
      );
      await tester.pump();
      expect(find.text("Kendi panonuzu kuruyorsanız: 1) karekodla eşleyin 2) Wi-Fi'yi yükleyin"), findsOneWidget);
      await tapKey(tester, 'btn_homeless_wifi');
      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    });

    testWidgets('Wi-Fi karekodu taranınca Wi-Fi Kurulum sihirbazı açılır', (tester) async {
      final env = e2Env();
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('btn_route_wifi'),
                onPressed: () => routeScannedCode(context, 'WIFI:T:WPA;S:EvAgi;P:parola1234;;'),
                child: const Text('wifi'),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'btn_route_wifi');
      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    });
  });
}
