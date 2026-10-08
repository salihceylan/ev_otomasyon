import 'dart:io';

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';
import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// Wi-Fi SERVİS AKIŞI (canlı test listesi Aşama 16): teknisyen müşteride, telefon panonun kurulum ağında
/// (SoftAP) ve **internet YOK, giriş YOK**. Sihirbaz anahtarsız ve girişsiz çalışmalı; sunucuya hiç
/// istek atılmamalı (CONTRACTS §3d). Panel ayrıntıları: `test/wifi_recovery_mode_test.dart`.
void main() {
  Future<Opened<void>> openDialog(
    WidgetTester tester,
    E2Env env, {
    Future<String?> Function(BuildContext)? qrScanner,
    String? deviceUuid,
  }) {
    return openFromHost<void>(
      tester,
      env.state,
      (context) => WifiRecoveryDialog.show(context, qrScanner: qrScanner, deviceUuid: deviceUuid),
    );
  }

  /// Sihirbazı açar, bağlantıyı test eder ve tarama listesinin gelmesini bekler (HTTP, sahte panoya yönlenir).
  Future<void> testConnection(WidgetTester tester, E2Env env) async {
    await tester.tap(find.byKey(const Key('btn_wifi_check')));
    await tester.pump();
    await tester.pump();
    await advanceUntil(tester, env.clock, () => shown('wifi_network_list') || shown('wifi_scan_error') || shown('wifi_check_error'));
  }

  group('giriş ve internet olmadan çalışır', () {
    testWidgets('GİRİŞSİZ kullanıcı: sihirbaz açılır; test -> tarama -> ağ seçimi (şifreye odak) -> yükleme -> başarı; sunucuya ve cihaz anahtarına HİÇ dokunulmaz', (tester) async {
      final env = e2Env(authenticated: false);
      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(env.state.capabilities.canOpenWifiRecovery, isFalse, reason: 'kapı yok: yetki bu akışı belirlemez');
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        expect(find.byType(WifiRecoveryDialog), findsOneWidget);
        expect(find.text('Bu işlem için yetkiniz yok.'), findsNothing);

        await testConnection(tester, env);
        expect(textOf(tester, 'wifi_connection_title'), 'Pano ile bağlantı kuruldu (Pano)');
        expect(find.byKey(const Key('wifi_network_0')), findsOneWidget);

        // Eski yazılımlı (1.1.0) sahte panoda bulut uyarısı da çıkar (bireysel-1): ağ satırı görünür alana kaydırılır.
        await tester.ensureVisible(find.byKey(const Key('wifi_network_0')));
        await tester.tap(find.byKey(const Key('wifi_network_0')));
        await tester.pump();
        expect(fieldText(tester, 'field_wifi_ssid'), 'EvAgi');
        expect(
          tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('field_wifi_password')), matching: find.byType(EditableText))).focusNode.hasFocus,
          isTrue,
          reason: 'şifre kutusuna odaklanıldı',
        );

        await typeInto(tester, 'field_wifi_password', 'yeni-evagi-sifresi');
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();
        expect(dev.connectBodies.single, <String, dynamic>{'ssid': 'EvAgi', 'pass': 'yeni-evagi-sifresi'});

        dev.connectState = 'success';
        await advanceUntil(tester, env.clock, () => shown('wifi_result_success'));
      }, () => dev.api.client);

      expect(textOf(tester, 'wifi_success_detail'), contains('Kurtarma modu sona eriyor'));
      expect(env.cloud.calls, isEmpty, reason: 'sunucuya HİÇBİR istek gitmedi (internet yok senaryosu)');
      expect(dev.anyRequestSentKey(), isFalse, reason: 'X-Device-Key HİÇBİR istekte yok');
      expect(dev.api.requests.every((r) => r.url.host == '192.168.4.1'), isTrue);
      final paths = dev.api.requests.map((r) => '${r.method} ${r.path}').toList();
      expect(paths.first, 'GET /api/status', reason: 'önce kısıtlı özet (pano kimliği)');
      expect(paths, containsAllInOrder(<String>['GET /api/wifi/scan', 'POST /api/wifi/connect', 'GET /api/wifi/status']));
      expect(env.state.authStatus, AuthStatus.unauthenticated, reason: 'oturum açılmadı');
      expect(env.h.storage.keys, isEmpty, reason: 'güvenli depoya hiçbir şey yazılmadı (anahtar sunucudan alınıp saklanmaz)');
    });

    testWidgets('MİSAFİR (canOpenWifiRecovery=false) de sihirbazı açabilir; "yetkiniz yok" denmez', (tester) async {
      final env = e2Env(role: 'guest');
      expect(env.state.capabilities.canOpenWifiRecovery, isFalse);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
      expect(find.text('Bu işlem için yetkiniz yok.'), findsNothing);
      expect(shown('wifi_network_list'), isTrue);
      expect(env.cloud.calls, isEmpty);
    });

    testWidgets('cihaz listesi/aktif ev YOKKEN de açılır (eski sürümdeki "pano bulunamadı" takılı durumu yok)', (tester) async {
      final env = e2Env(authenticated: true, role: null);
      expect(env.state.devices, isEmpty);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      expect(shown('wifi_network_list'), isTrue);
      expect(find.textContaining('pano bulunamadı'), findsNothing);
      expect(env.cloud.calls, isEmpty);
    });

    testWidgets('giriş sayfasında "Pano Wi-Fi Kurulumu (İnternet Gerekmez)" girişi vardır ve girişsiz kullanıcıda sihirbazı açar', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage(), size: const Size(800, 2000));

      expect(find.text('Pano Wi-Fi Kurulumu (İnternet Gerekmez)'), findsOneWidget);
      await tapKey(tester, 'btn_wifi_setup');

      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
      expect(find.byKey(const Key('wifi_step_ap')), findsOneWidget);
      expect(env.cloud.calls, isEmpty);
    });

    testWidgets('modem Wi-Fi karekodu (tarayıcı) SSID ve parolayı doldurur; yükleme anahtarsız gider', (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env, qrScanner: (_) async => 'WIFI:T:WPA;S:MusteriModem;P:musteri-sifre-1;;');
        await tapKey(tester, 'btn_wifi_scan_qr');
        expect(fieldText(tester, 'field_wifi_ssid'), 'MusteriModem');
        expect(fieldText(tester, 'field_wifi_password'), 'musteri-sifre-1');

        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();
      }, () => dev.api.client);

      expect(dev.connectBodies.single, <String, dynamic>{'ssid': 'MusteriModem', 'pass': 'musteri-sifre-1'});
      expect(dev.anyRequestSentKey(), isFalse);
      expect(env.cloud.calls, isEmpty);
    });
  });

  group('önbellekteki cihaz anahtarı (isteğe bağlı; asla internet beklenmez)', () {
    testWidgets('kimliği doğrulanmış panonun anahtarı yerel depoda varsa cihaza gönderilir (anahtar-zorunlu yazılımda da çalışır); kısıtlı özet yine anahtarsız okunur', (tester) async {
      final env = e2Env(authenticated: false);
      await env.h.storage.saveLocalKey(kDeviceUid, kDeviceKey);
      final dev = FakeWifiDevice(apOnlyAuth: false); // eski yazılım: anahtarsız Wi-Fi isteği 401 olurdu

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      expect(shown('wifi_network_list'), isTrue, reason: 'önbellek anahtarıyla tarama yetkilendi');
      expect(dev.scanHeaders.first.entries.any((e) => e.key.toLowerCase() == 'x-device-key' && e.value == kDeviceKey), isTrue);
      final status = dev.api.requests.firstWhere((r) => r.path == '/api/status');
      expect(status.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-device-key')));
      expect(env.cloud.calls, isEmpty, reason: 'anahtar sunucudan istenmedi');
    });

    testWidgets('yalnızca FARKLI bir panonun anahtarı varsa o anahtar bu panoya GÖNDERİLMEZ', (tester) async {
      final env = e2Env(authenticated: false);
      await env.h.storage.saveLocalKey(kOtherDeviceUid, kOtherDeviceKey);
      final dev = FakeWifiDevice(); // pano kimliği kDeviceUid

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      expect(shown('wifi_network_list'), isTrue);
      expect(dev.anyRequestSentKey(), isFalse, reason: 'başka panonun anahtarı sızmaz');
    });

    testWidgets('güvenli depo okunamıyorsa çökmeden anahtarsız (AP kaynaklı) devam edilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.h.storage.memory.failReads = true;
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      expect(shown('wifi_network_list'), isTrue);
      expect(dev.anyRequestSentKey(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pano bulunamayınca önceki panoya ait anahtar bırakılmaz: sonraki gönderim anahtarsız gider', (tester) async {
      final env = e2Env(authenticated: false);
      await env.h.storage.saveLocalKey(kDeviceUid, kDeviceKey);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env); // anahtar uygulandı
        expect(dev.scanHeaders.first.keys.map((k) => k.toLowerCase()), contains('x-device-key'));

        dev.statusDown = true; // telefon başka ağa geçti: pano bulunamıyor
        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();
        expect(shown('wifi_check_error'), isTrue);

        dev.statusDown = false;
        await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
        await typeInto(tester, 'field_wifi_password', 'yeni-evagi-sifresi');
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();
      }, () => dev.api.client);

      expect(dev.connectBodies, hasLength(1));
      expect(dev.connectHeaders.single.keys.map((k) => k.toLowerCase()), isNot(contains('x-device-key')));
    });
  });

  group('sabit parola/ad YOK (kaynak taraması)', () {
    test('lib/ içinde sabit kurtarma ağı adı/parolası metni bulunmaz (ahbu1234, AHBU-Kurtarma)', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync().toLowerCase();
        for (final banned in <String>['ahbu1234', 'ahbu-kurtarma']) {
          if (text.contains(banned)) offenders.add('${entity.path}: $banned');
        }
      }
      expect(offenders, isEmpty);
    });

    test('Wi-Fi sihirbazı kaynağı sunucudan cihaz anahtarı almaz/kaydetmez (localKeyFor / saveLocalKey / cloudApi yok)', () {
      for (final path in <String>['lib/ui/pages/wifi_recovery_dialog.dart', 'lib/ui/common/wifi_provision_panel.dart']) {
        final code = File(path).readAsStringSync();
        for (final banned in <String>['localKeyFor', 'saveLocalKey', 'cloudApi', 'canFetchLocalKey', 'canOpenWifiRecovery']) {
          expect(
            RegExp('^(?!\\s*//).*\\b$banned\\b', multiLine: true).hasMatch(code),
            isFalse,
            reason: '$path: $banned kod olarak geçmemeli (yalnızca açıklama satırlarında olabilir)',
          );
        }
      }
    });
  });
}
