import 'dart:async';

import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/ui/common/wifi_provision_panel.dart';
import 'package:ev_otomasyon/ui/common/wifi_signal_bars.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/support.dart';
import 'ui/e2_support.dart';
import 'ui/e2_wifi_support.dart';

/// Wi-Fi kurtarma sihirbazı ve yeniden kullanılabilir `WifiProvisionPanel` (servis kurulum sihirbazı da
/// kullanır): **anahtarsız ve internetsiz** (AP kaynaklı) çalışma, doğrulama, kırpmama, tarama iptali,
/// başarı YALNIZCA cihaz bağlandığında, yanlış parola / zaman aşımı / belirsiz sonuç, QR kuralları,
/// ayrı cihaz istemcisi. Giriş/yetki, sunucu çağrısı ve önbellek anahtarı kuralları:
/// `test/ui/e2_wifi_service_flow_test.dart`.

/// Anahtarlı widget'ın odak durumu.
bool hasFocus(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

void main() {
  /// Yalnızca paneli (servis sihirbazı kullanımı) pompalar. Varsayılan: anahtarsız istemci (AP kaynaklı model).
  Future<(E2Env, FakeWifiDevice, List<WifiConnectResult>)> pumpPanel(
    WidgetTester tester, {
    FakeWifiDevice? device,
    Future<String?> Function(BuildContext)? qrScanner,
    bool enabled = true,
    String? key,
    String? expectedUid,
    Future<void> Function(DeviceStatus?)? onDeviceChecked,
  }) async {
    final env = e2Env(role: 'owner');
    final dev = device ?? FakeWifiDevice();
    final results = <WifiConnectResult>[];
    await pumpApp(
      tester,
      state: env.state,
      child: Scaffold(
        body: SingleChildScrollView(
          child: WifiProvisionPanel(
            api: dev.client(env.clock, key: key),
            clock: env.clock,
            enabled: enabled,
            disabledMessage: 'Panel kapalı.',
            onResult: results.add,
            qrScanner: qrScanner,
            expectedUid: expectedUid,
            onDeviceChecked: onDeviceChecked,
          ),
        ),
      ),
      size: const Size(800, 2200),
    );
    return (env, dev, results);
  }

  /// Bağlantıyı test eder ve taramanın bitmesini bekler.
  Future<void> connectAndScan(WidgetTester tester, E2Env env) async {
    await tester.tap(find.byKey(const Key('btn_wifi_check')));
    await tester.pump();
    await advanceUntil(
      tester,
      env.clock,
      () =>
          shown('wifi_network_list') ||
          shown('wifi_no_networks') ||
          shown('wifi_scan_error'),
    );
  }

  group('bağlantı testi', () {
    testWidgets(
      'pano erişilemezse yönlendirici mesaj gösterilir (ham hata yok) ve yeniden denenebilir',
      (tester) async {
        final dev = FakeWifiDevice()..statusDown = true;
        final (env, _, _) = await pumpPanel(tester, device: dev);

        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();

        expect(textOf(tester, 'wifi_check_error'), contains('Pano bulunamadı'));
        expect(find.textContaining('ClientException'), findsNothing);

        dev.statusDown = false;
        await connectAndScan(tester, env);
        expect(find.byKey(const Key('wifi_check_error')), findsNothing);
        expect(
          textOf(tester, 'wifi_connection_title'),
          'Pano ile bağlantı kuruldu (Pano)',
        );
      },
    );

    testWidgets(
      'başarılı test YEŞİL bildirimdir: pano adı, kimliği, yazılım sürümü ve 192.168.4.1 adresi gösterilir; kısıtlı özet ANAHTARSIZ okunur',
      (tester) async {
        final (env, dev, _) = await pumpPanel(tester);
        await connectAndScan(tester, env);

        expect(
          textOf(tester, 'wifi_connection_title'),
          'Pano ile bağlantı kuruldu (Pano)',
        );
        final detail = textOf(tester, 'wifi_connection_detail');
        expect(detail, contains(kDeviceUid));
        expect(detail, contains('1.1.0'));
        expect(detail, contains('192.168.4.1'));

        // Yeşil onay orb'u ✓ (renk + simge birlikte; SnackBar değil, kalıcı kart). WP-V6: eski `Icons.check_circle`
        // simgesi yerine emerald `OrbIconBadge` (onay simgesi `Icons.check_rounded`).
        final orb = tester.widget<OrbIconBadge>(find.byKey(const Key('wifi_connection_orb')));
        expect(orb.family, AppFamilies.emerald);
        expect(orb.icon, Icons.check_rounded);
        expect(find.byType(SnackBar), findsNothing);

        final status = dev.api.requests.firstWhere(
          (r) => r.path == '/api/status',
        );
        expect(
          status.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-device-key')),
        );
      },
    );

    testWidgets(
      'cihaz henüz kurulmamışsa (provisioned:false) uyarı verilir ve ağ taraması BAŞLATILMAZ',
      (tester) async {
        final dev = FakeWifiDevice(provisioned: false);
        final (env, _, _) = await pumpPanel(tester, device: dev);

        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();
        env.clock.advance(const Duration(seconds: 3));
        await tester.pump();

        expect(
          textOf(tester, 'wifi_check_error'),
          contains('henüz kurulmamış'),
        );
        expect(dev.scanRequests, 0);
      },
    );

    testWidgets(
      'panel kapalıyken (enabled:false) düğmeler pasif ve açıklama gösterilir',
      (tester) async {
        final (_, dev, _) = await pumpPanel(tester, enabled: false);

        expect(textOf(tester, 'wifi_disabled_message'), 'Panel kapalı.');
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('btn_wifi_check')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('btn_wifi_submit')))
              .onPressed,
          isNull,
        );
        expect(dev.api.requests, isEmpty);
      },
    );

    testWidgets(
      'autoCheck: panel pasif açılıp sonradan etkinleşirse bağlantı testi OTOMATİK ve yalnızca BİR kez başlar (servis sihirbazı kullanımı)',
      (tester) async {
        final env = e2Env(role: 'owner');
        final dev = FakeWifiDevice();
        Future<void> pumpWith({required bool enabled}) => pumpApp(
          tester,
          state: env.state,
          size: const Size(800, 2200),
          child: Scaffold(
            body: SingleChildScrollView(
              child: WifiProvisionPanel(
                api: dev.client(env.clock),
                clock: env.clock,
                enabled: enabled,
                autoCheck: true,
              ),
            ),
          ),
        );

        await pumpWith(enabled: false);
        await tester.pump();
        expect(dev.api.requests, isEmpty, reason: 'pasifken test yapılmaz');

        await pumpWith(enabled: true);
        await tester.pump();
        await tester.pump();
        expect(dev.statusCalls, 1, reason: 'etkinleşince otomatik test');
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));

        await pumpWith(enabled: false);
        await pumpWith(enabled: true);
        await tester.pump();
        expect(
          dev.statusCalls,
          1,
          reason: 'yeniden etkinleşme testi yinelemez',
        );
      },
    );

    testWidgets(
      'beklenen pano ile bağlanılan pano farklıysa ENGELLEMEYEN uyarı gösterilir (yanlış pano riski)',
      (tester) async {
        final (env, dev, _) = await pumpPanel(
          tester,
          expectedUid: kOtherDeviceUid,
        );
        await connectAndScan(tester, env);

        expect(
          textOf(tester, 'wifi_target_mismatch'),
          allOf(contains(kDeviceUid), contains(kOtherDeviceUid)),
        );
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('btn_wifi_submit')))
              .onPressed,
          isNotNull,
          reason: 'engellemez',
        );
        expect(dev.scanRequests, greaterThan(0), reason: 'tarama sürer');
      },
    );

    testWidgets(
      'beklenen pano ile bağlanılan pano aynıysa uyarı yoktur (büyük/küçük harf farkı sayılmaz)',
      (tester) async {
        final (env, _, _) = await pumpPanel(
          tester,
          expectedUid: kDeviceUid.toLowerCase(),
        );
        await connectAndScan(tester, env);

        expect(shown('wifi_target_mismatch'), isFalse);
      },
    );

    testWidgets(
      'onDeviceChecked: başarıda pano durumuyla, bulunamazsa null ile çağrılır; tarama çağrı bitmeden BAŞLAMAZ',
      (tester) async {
        final calls = <String?>[];
        final gate = Completer<void>();
        final dev = FakeWifiDevice();
        final (env, _, _) = await pumpPanel(
          tester,
          device: dev,
          onDeviceChecked: (status) async {
            calls.add(status?.uid ?? 'null');
            await gate.future;
          },
        );

        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();
        expect(calls, <String?>[kDeviceUid]);
        expect(
          dev.scanRequests,
          0,
          reason: 'çağıran (ör. anahtar hazırlığı) bitmeden taranmaz',
        );

        gate.complete();
        await advanceUntil(tester, env.clock, () => dev.scanRequests >= 1);

        dev.statusDown = true;
        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();
        expect(
          calls.last,
          'null',
          reason: 'pano bulunamadı: önceki panoya ait durum bırakılmaz',
        );
      },
    );
  });

  group('ağ tarama', () {
    testWidgets(
      'ağlar listelenir; seçim SSID\'yi doldurur; açık ağ seçilince parola temizlenir',
      (tester) async {
        final (env, _, _) = await pumpPanel(tester);
        await connectAndScan(tester, env);

        expect(find.byKey(const Key('wifi_network_0')), findsOneWidget);
        expect(find.text('EvAgi'), findsOneWidget);
        await tester.tap(find.byKey(const Key('wifi_network_0')));
        await tester.pump();
        expect(fieldText(tester, 'field_wifi_ssid'), 'EvAgi');

        await typeInto(tester, 'field_wifi_password', 'eskiparola1');
        await tester.tap(
          find.byKey(const Key('wifi_network_1')),
        ); // KomsuAcik (açık)
        await tester.pump();
        expect(fieldText(tester, 'field_wifi_ssid'), 'KomsuAcik');
        expect(fieldText(tester, 'field_wifi_password'), isEmpty);
      },
    );

    testWidgets(
      'listeden ŞİFRELİ ağa dokununca şifre kutusuna ODAKLANILIR; açık ağda şifre kutusu odaklanmaz',
      (tester) async {
        final (env, _, _) = await pumpPanel(tester);
        await connectAndScan(tester, env);
        expect(hasFocus(tester, 'field_wifi_password'), isFalse);

        await tester.tap(
          find.byKey(const Key('wifi_network_0')),
        ); // EvAgi (şifreli)
        await tester.pump();
        expect(
          hasFocus(tester, 'field_wifi_password'),
          isTrue,
          reason: 'şifre yazmaya hazır',
        );

        await tester.tap(
          find.byKey(const Key('wifi_network_1')),
        ); // KomsuAcik (açık)
        await tester.pump();
        expect(
          hasFocus(tester, 'field_wifi_password'),
          isFalse,
          reason: 'açık ağda şifre gerekmez',
        );
      },
    );

    testWidgets(
      'liste: ağ adı, sinyal (dBm + çubuk simgesi) ve kilit simgesi; 2,4 GHz notu görünür',
      (tester) async {
        final (env, _, _) = await pumpPanel(tester);
        await connectAndScan(tester, env);

        expect(textOf(tester, 'wifi_24ghz_note'), contains('2,4 GHz'));
        // WP-V6: sinyal simgeleri (`Icons.wifi*`) yerine animasyonlu `WifiSignalBars` (dolu çubuk sayısı).
        for (final entry in <int, (String, int, IconData)>{
          0: ('-48 dBm', 4, Icons.lock_outline), // güçlü + şifreli
          1: ('-70 dBm', 2, Icons.lock_open), // orta + açık
          2: ('-88 dBm', 1, Icons.lock_outline), // zayıf + şifreli
        }.entries) {
          final tile = find.byKey(Key('wifi_network_${entry.key}'));
          expect(
            find.descendant(of: tile, matching: find.text(entry.value.$1)),
            findsOneWidget,
          );
          final bars = find.descendant(of: tile, matching: find.byType(WifiSignalBars));
          expect(bars, findsOneWidget, reason: 'sinyal çubukları ${entry.key}');
          expect(tester.widget<WifiSignalBars>(bars).level, entry.value.$2, reason: 'çubuk sayısı ${entry.key}');
          expect(
            find.descendant(of: tile, matching: find.byIcon(entry.value.$3)),
            findsOneWidget,
            reason: 'kilit ${entry.key}',
          );
        }
      },
    );

    testWidgets(
      'tarama "scanning" ise 1,2 sn arayla yeniden sorulur; yalnızca ilk istek refresh=1 taşır',
      (tester) async {
        final dev = FakeWifiDevice()..scanningFirst = 2;
        final (env, _, _) = await pumpPanel(tester, device: dev);
        await connectAndScan(tester, env);

        expect(dev.scanRequests, 3);
        final scans = dev.api.requests
            .where((r) => r.path == '/api/wifi/scan')
            .toList();
        expect(scans.first.url.queryParameters['refresh'], '1');
        expect(scans[1].url.queryParameters.containsKey('refresh'), isFalse);
        expect(shown('wifi_network_list'), isTrue);
      },
    );

    testWidgets(
      'tarama hatası GÖRÜNÜR ve "Tekrar Dene" (btn_wifi_scan_retry) ile yeniden denenebilir',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, _) = await pumpPanel(tester, device: dev);
        dev.scanStatus = 503;
        await connectAndScan(tester, env);

        expect(shown('wifi_scan_error'), isTrue);
        expect(textOf(tester, 'wifi_scan_error'), contains('meşgul'));

        dev.scanStatus = 200;
        await tester.tap(find.byKey(const Key('btn_wifi_scan_retry')));
        await tester.pump();
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
        expect(shown('wifi_scan_error'), isFalse);
      },
    );

    testWidgets(
      'anahtar-zorunlu (eski) yazılım anahtarsız isteği reddederse (401) açık "kurulum ağı" mesajı gösterilir',
      (tester) async {
        final dev = FakeWifiDevice(apOnlyAuth: false);
        final (env, _, _) = await pumpPanel(tester, device: dev);
        await connectAndScan(tester, env);

        final message = textOf(tester, 'wifi_scan_error');
        expect(message, contains('Pano bu isteği kabul etmedi'));
        expect(message, contains('KURULUM ağına'));
        expect(
          message,
          isNot(contains('anahtar')),
          reason:
              'kullanıcıya "anahtar yenileyin" denmez: internet/giriş gerekmez',
        );
      },
    );

    testWidgets(
      'anahtar-zorunlu yazılımda önbellekteki geçerli anahtar (api.localKey) verilmişse tarama çalışır',
      (tester) async {
        final dev = FakeWifiDevice(apOnlyAuth: false);
        final (env, _, _) = await pumpPanel(
          tester,
          device: dev,
          key: kDeviceKey,
        );
        await connectAndScan(tester, env);

        expect(shown('wifi_network_list'), isTrue);
        expect(
          dev.scanHeaders.first.entries.any(
            (e) =>
                e.key.toLowerCase() == 'x-device-key' && e.value == kDeviceKey,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'tarama İPTAL edilebilir: iptalden sonra cihaza yeni tarama isteği gitmez',
      (tester) async {
        final dev = FakeWifiDevice()
          ..scanningFirst = 1000; // tarama hiç bitmiyor
        final (env, _, _) = await pumpPanel(tester, device: dev);

        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await advanceUntil(tester, env.clock, () => dev.scanRequests >= 3);
        expect(shown('btn_wifi_scan_cancel'), isTrue);

        await tester.tap(find.byKey(const Key('btn_wifi_scan_cancel')));
        await tester.pump();
        final before = dev.scanRequests;
        env.clock.advance(const Duration(seconds: 30));
        await tester.pump();

        expect(dev.scanRequests, before, reason: 'iptal sonrası döngü durdu');
        expect(shown('btn_wifi_scan_cancel'), isFalse);
        expect(textOf(tester, 'wifi_scan_error'), 'Tarama iptal edildi.');
      },
    );

    testWidgets(
      'bileşen kapanınca tarama döngüsü DURUR (dialog kapatıldığında)',
      (tester) async {
        final dev = FakeWifiDevice()..scanningFirst = 1000;
        final (env, _, _) = await pumpPanel(tester, device: dev);
        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await advanceUntil(tester, env.clock, () => dev.scanRequests >= 2);

        await tester.pumpWidget(const SizedBox()); // panel ağaçtan kalktı
        final before = dev.scanRequests;
        env.clock.advance(const Duration(seconds: 60));
        await tester.pump();

        expect(dev.scanRequests, before);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('doğrulama (kırpma YOK)', () {
    testWidgets(
      'boş SSID, 32 bayttan uzun SSID, kısa/uzun parola reddedilir; cihaza istek gitmez',
      (tester) async {
        final (_, dev, _) = await pumpPanel(tester);

        await tapKey(tester, 'btn_wifi_submit');
        expect(
          textOf(tester, 'wifi_form_error'),
          'Lütfen Wi-Fi ağ adını (SSID) girin.',
        );

        await typeInto(tester, 'field_wifi_ssid', 'ş' * 17); // 34 bayt
        await tapKey(tester, 'btn_wifi_submit');
        expect(textOf(tester, 'wifi_form_error'), contains('32 bayt'));

        await typeInto(tester, 'field_wifi_ssid', 'ş' * 16); // tam 32 bayt
        await typeInto(tester, 'field_wifi_password', '1234567');
        await tapKey(tester, 'btn_wifi_submit');
        expect(textOf(tester, 'wifi_form_error'), contains('8 ile 63'));

        await typeInto(tester, 'field_wifi_password', 'a' * 64);
        await tapKey(tester, 'btn_wifi_submit');
        expect(textOf(tester, 'wifi_form_error'), contains('8 ile 63'));
        expect(dev.connectBodies, isEmpty);
      },
    );

    testWidgets(
      'şifreli bilinen ağda boş şifre reddedilir; açık ağda boş şifre geçerlidir',
      (tester) async {
        final (env, dev, _) = await pumpPanel(tester);
        await connectAndScan(tester, env);

        await tester.tap(find.byKey(const Key('wifi_network_0'))); // şifreli
        await tester.pump();
        await tapKey(tester, 'btn_wifi_submit');
        expect(
          textOf(tester, 'wifi_form_error'),
          contains('şifreli görünüyor'),
        );
        expect(dev.connectBodies, isEmpty);

        await tester.tap(find.byKey(const Key('wifi_network_1'))); // açık
        await tester.pump();
        await tapKey(tester, 'btn_wifi_submit');
        expect(dev.connectBodies.single['ssid'], 'KomsuAcik');
        expect(dev.connectBodies.single['pass'], '');
      },
    );

    testWidgets(
      'SSID ve şifre KIRPILMADAN (baş/son boşlukla) cihaza gider; kullanıcı uyarılır',
      (tester) async {
        final (_, dev, _) = await pumpPanel(tester);

        await typeInto(tester, 'field_wifi_ssid', ' Ev Agi ');
        await typeInto(tester, 'field_wifi_password', ' p4ssw0rd! ');
        expect(
          find.textContaining('ağ adının başında/sonunda boşluk var'),
          findsOneWidget,
        );
        expect(
          find.textContaining('şifrenin başında/sonunda boşluk var'),
          findsOneWidget,
        );

        await tapKey(tester, 'btn_wifi_submit');

        expect(dev.connectBodies.single, <String, dynamic>{
          'ssid': ' Ev Agi ',
          'pass': ' p4ssw0rd! ',
        });
      },
    );

    testWidgets(
      'anahtar verilmemişse X-Device-Key başlığı HİÇBİR istekte yok (AP kaynaklı anahtarsız model)',
      (tester) async {
        final (_, keyless, _) = await pumpPanel(tester);
        await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
        await typeInto(tester, 'field_wifi_password', 'sifre-12345');
        await tapKey(tester, 'btn_wifi_submit');

        expect(
          keyless.connectBodies,
          hasLength(1),
          reason: 'anahtarsız gönderim çalıştı (AP kaynaklı model)',
        );
        expect(keyless.anyRequestSentKey(), isFalse);
        expect(
          keyless.connectHeaders.single.map(
            (k, v) => MapEntry(k.toLowerCase(), v),
          )['content-type'],
          contains('application/json'),
        );
      },
    );

    testWidgets(
      'anahtar verilmişse (api.localKey) X-Device-Key cihaza gönderilir',
      (tester) async {
        final (_, keyed, _) = await pumpPanel(tester, key: kDeviceKey);
        await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
        await typeInto(tester, 'field_wifi_password', 'sifre-12345');
        await tapKey(tester, 'btn_wifi_submit');

        final headers = keyed.connectHeaders.single.map(
          (k, v) => MapEntry(k.toLowerCase(), v),
        );
        expect(headers['x-device-key'], kDeviceKey);
      },
    );
  });

  group('bağlanma sonucu: başarı YALNIZCA cihaz bağlandığında', () {
    Future<(E2Env, FakeWifiDevice, List<WifiConnectResult>)> submit(
      WidgetTester tester, {
      FakeWifiDevice? device,
      String? key,
    }) async {
      final r = await pumpPanel(tester, device: device, key: key);
      await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
      await typeInto(tester, 'field_wifi_password', 'dogru-parola-1');
      await tester.tap(find.byKey(const Key('btn_wifi_submit')));
      await tester.pump();
      return r;
    }

    testWidgets(
      '"connecting" yanıtı BAŞARI DEĞİLDİR: bekleme gösterilir; sonuç /api/wifi/status ile izlenir; cihaz success deyince başarı + IP + kurtarma modu bilgisi',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, results) = await submit(tester, device: dev);

        expect(shown('wifi_waiting'), isTrue);
        expect(
          shown('wifi_result_success'),
          isFalse,
          reason: 'connecting yanıtı başarı sayılmaz',
        );
        expect(results, isEmpty);

        dev.connectState = 'success';
        await advanceUntil(
          tester,
          env.clock,
          () => shown('wifi_result_success'),
        );

        expect(find.textContaining('192.168.1.57'), findsOneWidget);
        expect(
          textOf(tester, 'wifi_success_detail'),
          contains('Kurtarma modu sona eriyor'),
        );
        expect(
          textOf(tester, 'wifi_success_phone_hint'),
          contains('ev Wi-Fi ağınıza'),
        );
        expect(results.single.outcome, WifiConnectOutcome.success);
        expect(shown('wifi_waiting'), isFalse);
        expect(
          dev.wifiStatusCalls,
          greaterThan(0),
          reason: 'sonuç W1 ucundan okundu',
        );
        expect(
          dev.statusCalls,
          0,
          reason: 'tam /api/status kullanılmadı (anahtarsız kısıtlı özet sonucu taşımaz)',
        );
      },
    );

    testWidgets(
      'yanlış parola: cihaz failed(202) der -> hata mesajı + "Yeniden Dene"; başarı GÖSTERİLMEZ',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, results) = await submit(tester, device: dev);

        dev
          ..connectState = 'failed'
          ..connectReason = 202;
        await advanceUntil(
          tester,
          env.clock,
          () => shown('wifi_result_failed'),
        );

        expect(
          textOf(tester, 'wifi_result_failed'),
          contains('Wi-Fi şifresi hatalı görünüyor'),
        );
        expect(shown('wifi_result_success'), isFalse);
        expect(results.single.outcome, WifiConnectOutcome.failed);

        // Yeniden dene: form geri gelir, alanlar korunur.
        await tester.tap(find.byKey(const Key('btn_wifi_retry')));
        await tester.pump();
        expect(shown('wifi_result_failed'), isFalse);
        expect(fieldText(tester, 'field_wifi_ssid'), 'EvAgi');
      },
    );

    testWidgets('ağ bulunamadı (201) açık mesajla gösterilir', (tester) async {
      final dev = FakeWifiDevice();
      final (env, _, _) = await submit(tester, device: dev);
      dev
        ..connectState = 'failed'
        ..connectReason = 201;
      await advanceUntil(tester, env.clock, () => shown('wifi_result_failed'));
      expect(textOf(tester, 'wifi_result_failed'), contains('Ağ bulunamadı'));
    });

    testWidgets(
      'ZAMAN AŞIMI: cihaz 40 sn boyunca connecting kalırsa zaman aşımı mesajı gösterilir (başarı değil)',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, results) = await submit(tester, device: dev);

        await advanceUntil(
          tester,
          env.clock,
          () => shown('wifi_result_failed'),
          step: const Duration(seconds: 2),
        );

        expect(
          textOf(tester, 'wifi_result_failed'),
          contains('zaman aşımına uğradı'),
        );
        expect(shown('wifi_result_success'), isFalse);
        expect(results.single.outcome, WifiConnectOutcome.timedOut);
        expect(shown('btn_wifi_retry'), isTrue);
      },
    );

    testWidgets(
      'bağlantı koptu (pano AP\'yi kapattı): BELİRSİZ sonuç uyarısı (hata değil); telefonu ev ağına alma yönergesi',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, results) = await submit(tester, device: dev);

        await advanceUntil(
          tester,
          env.clock,
          () => dev.pollCalls > dev.pollCallsAtConnect,
        );
        dev.statusDown = true; // AP kapandı
        await advanceUntil(
          tester,
          env.clock,
          () => shown('wifi_result_uncertain'),
        );

        final message = textOf(tester, 'wifi_result_uncertain');
        expect(message, contains('bağlantı koptu'));
        expect(message, contains('hata olmayabilir'));
        expect(message, contains('ev Wi-Fi ağınıza'));
        expect(shown('wifi_result_success'), isFalse);
        expect(shown('wifi_result_failed'), isFalse);
        expect(results.single.outcome, WifiConnectOutcome.lostContact);
      },
    );

    testWidgets('pano meşgulse (409 busy) açık mesaj gösterilir', (
      tester,
    ) async {
      final dev = FakeWifiDevice()..connectStatus = 409;
      await submit(tester, device: dev);
      await tester.pump();
      expect(textOf(tester, 'wifi_form_error'), contains('meşgul'));
      expect(shown('wifi_result_success'), isFalse);
    });

    testWidgets(
      'hız sınırı (429): bekleme süresi gösterilir, gönder düğmesi o süre pasif kalır; süre dolunca etkinleşir ve gönderim başarılı olur',
      (tester) async {
        final dev = FakeWifiDevice()
          ..rateLimitRetryAfter = const Duration(seconds: 20);
        final (env, _, _) = await submit(tester, device: dev);
        await tester.pump();

        expect(
          textOf(tester, 'wifi_form_error'),
          allOf(contains('çok fazla deneme'), contains('20 sn')),
        );
        final button = find.byKey(const Key('btn_wifi_submit'));
        expect(tester.widget<ElevatedButton>(button).onPressed, isNull);
        expect(find.textContaining('(20 sn)'), findsOneWidget);
        expect(dev.connectBodies, hasLength(1));

        env.clock.advance(const Duration(seconds: 12));
        await tester.pump();
        expect(
          find.textContaining('(8 sn)'),
          findsOneWidget,
          reason: 'geri sayım',
        );
        await tester.tap(button, warnIfMissed: false);
        await tester.pump();
        expect(
          dev.connectBodies,
          hasLength(1),
          reason: 'bekleme sürerken ikinci istek gitmez',
        );

        env.clock.advance(const Duration(seconds: 9));
        await tester.pump();
        expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);

        dev.rateLimitRetryAfter = null;
        await tester.tap(button);
        await tester.pump();
        expect(dev.connectBodies, hasLength(2));
        expect(shown('wifi_waiting'), isTrue);
      },
    );

    testWidgets(
      'eski yazılım (/api/wifi/status yok: 404): sonuç anahtarlı /api/status ile izlenir ve başarı yine YALNIZCA success\'te',
      (tester) async {
        final dev = FakeWifiDevice(
          apOnlyAuth: false,
          wifiStatusSupported: false,
        );
        final (env, _, results) = await submit(
          tester,
          device: dev,
          key: kDeviceKey,
        );

        expect(results, isEmpty);
        dev.connectState = 'success';
        await advanceUntil(
          tester,
          env.clock,
          () => shown('wifi_result_success'),
        );

        expect(results.single.outcome, WifiConnectOutcome.success);
        expect(dev.statusCalls, greaterThan(0), reason: 'eski uca düşüldü');
        expect(
          dev.wifiStatusCalls,
          1,
          reason: 'yeni uç yalnızca bir kez denendi (404 sonrası eski uç kalıcı seçildi)',
        );
      },
    );

    testWidgets(
      'bekleme İPTAL edilebilir: iptalden sonra cihaz durumu yoklanmaz',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, results) = await submit(tester, device: dev);
        await advanceUntil(
          tester,
          env.clock,
          () => dev.pollCalls >= dev.pollCallsAtConnect + 2,
        );

        await tester.tap(find.byKey(const Key('btn_wifi_cancel')));
        await tester.pump();
        final before = dev.pollCalls;
        env.clock.advance(const Duration(seconds: 60));
        await tester.pump();

        expect(dev.pollCalls, before);
        expect(
          textOf(tester, 'wifi_form_error'),
          contains('Bekleme iptal edildi'),
        );
        expect(results, isEmpty, reason: 'iptal bir sonuç değildir');
      },
    );

    testWidgets(
      'gönderim sırasında bileşen kapanırsa istisna oluşmaz ve yoklama durur',
      (tester) async {
        final dev = FakeWifiDevice();
        final (env, _, _) = await submit(tester, device: dev);

        await tester.pumpWidget(const SizedBox());
        final before = dev.pollCalls;
        env.clock.advance(const Duration(seconds: 60));
        await tester.pump();

        expect(dev.pollCalls, before);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('karekod (WIFI:...)', () {
    testWidgets('geçerli WPA karekodu SSID ve şifreyi doldurur', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        qrScanner: (_) async => 'WIFI:T:WPA;S:Salon\\;Agi;P:parola\\:1234;;',
      );

      await tapKey(tester, 'btn_wifi_scan_qr');

      expect(fieldText(tester, 'field_wifi_ssid'), 'Salon;Agi');
      expect(fieldText(tester, 'field_wifi_password'), 'parola:1234');
      expect(shown('wifi_form_error'), isFalse);
    });

    testWidgets(
      'SSID alanındaki QR simgesi de aynı tarayıcıyı açar ve alanları doldurur',
      (tester) async {
        var opened = 0;
        await pumpPanel(
          tester,
          qrScanner: (_) async {
            opened++;
            return 'WIFI:T:WPA;S:SimgeAgi;P:simge-parola-1;;';
          },
        );

        await tapKey(tester, 'btn_wifi_ssid_qr');

        expect(opened, 1);
        expect(fieldText(tester, 'field_wifi_ssid'), 'SimgeAgi');
        expect(fieldText(tester, 'field_wifi_password'), 'simge-parola-1');
      },
    );

    testWidgets(
      'açık ağ karekodu şifreyi boş bırakır ve boş şifre geçerli olur',
      (tester) async {
        final (_, dev, _) = await pumpPanel(
          tester,
          qrScanner: (_) async => 'WIFI:T:nopass;S:MisafirAgi;;',
        );
        await tapKey(tester, 'btn_wifi_scan_qr');
        expect(fieldText(tester, 'field_wifi_ssid'), 'MisafirAgi');

        await tapKey(tester, 'btn_wifi_submit');
        expect(dev.connectBodies.single, <String, dynamic>{
          'ssid': 'MisafirAgi',
          'pass': '',
        });
      },
    );

    testWidgets(
      'WEP karekodu reddedilir: neden gösterilir, alanlar DOLDURULMAZ',
      (tester) async {
        await pumpPanel(
          tester,
          qrScanner: (_) async => 'WIFI:T:WEP;S:EskiModem;P:12345;;',
        );
        await typeInto(tester, 'field_wifi_ssid', 'ElleYazilan');

        await tapKey(tester, 'btn_wifi_scan_qr');

        expect(textOf(tester, 'wifi_form_error'), contains('WEP'));
        expect(fieldText(tester, 'field_wifi_ssid'), 'ElleYazilan');
      },
    );

    testWidgets(
      'Wi-Fi karekodu OLMAYAN ham metin ASLA SSID alanına yazılmaz; hata gösterilir',
      (tester) async {
        await pumpPanel(tester, qrScanner: (_) async => 'EvWifiAdim');

        await tapKey(tester, 'btn_wifi_scan_qr');

        expect(
          fieldText(tester, 'field_wifi_ssid'),
          isEmpty,
          reason: 'ham metin SSID olmaz',
        );
        expect(
          textOf(tester, 'wifi_form_error'),
          'Bu bir Wi-Fi karekodu değil.',
        );
      },
    );

    testWidgets('tarayıcı iptal edilirse (null) hiçbir şey değişmez', (
      tester,
    ) async {
      await pumpPanel(tester, qrScanner: (_) async => null);
      await typeInto(tester, 'field_wifi_ssid', 'Kalsin');

      await tapKey(tester, 'btn_wifi_scan_qr');

      expect(fieldText(tester, 'field_wifi_ssid'), 'Kalsin');
      expect(shown('wifi_form_error'), isFalse);
    });
  });

  group('WifiRecoveryDialog', () {
    /// Oturumsuz, internetsiz, cihaz listesi boş: teknisyenin müşteride telefonu (en zor durum).
    E2Env dialogEnv({String? role}) =>
        e2Env(role: role, authenticated: role != null);

    Future<Opened<void>> openDialog(
      WidgetTester tester,
      E2Env env, {
      AutomationApiService? api,
      String? deviceUuid,
    }) {
      return openFromHost<void>(
        tester,
        env.state,
        (context) =>
            WifiRecoveryDialog.show(context, api: api, deviceUuid: deviceUuid),
      );
    }

    testWidgets(
      'Adım 1 yönergesi: etiketteki cihaza özel parola ve İKİNCİ karekod anlatılır; sabit "ahbu1234"/"AHBU-Kurtarma" metni YOK',
      (tester) async {
        final env = dialogEnv();
        await openDialog(tester, env, api: FakeWifiDevice().client(env.clock));

        final title = textOf(tester, 'wifi_step_ap_title');
        final text = textOf(tester, 'wifi_step_ap_text');
        expect(title, contains('Adım 1'));
        expect(text, contains('AĞ PAROLASI (AP)'));
        expect(text, contains('KURULUM Wi-Fi AĞI'));
        expect(text, contains('ikinci karekod'));
        expect(text, contains('kamerasıyla'));
        expect(text, contains('internet ve hesap girişi gerekmez'));
        expect(
          find.textContaining('ahbu1234', findRichText: true),
          findsNothing,
        );
        expect(
          find.textContaining('AHBU-Kurtarma', findRichText: true),
          findsNothing,
        );
      },
    );

    testWidgets(
      'beklenen pano verilmişse kurulum ağı adı UID\'den türetilip gösterilir (AHBU-S3-1A2B3C -> AHBU-1A2B3C)',
      (tester) async {
        final env = dialogEnv();
        await openDialog(
          tester,
          env,
          api: FakeWifiDevice().client(env.clock),
          deviceUuid: kDeviceUid,
        );

        expect(textOf(tester, 'wifi_step_ap_text'), contains('"AHBU-1A2B3C"'));
      },
    );

    testWidgets(
      'AP parola alanı gizli başlar; göster/gizle çalışır; yazılan parola kopyalanabilir (kaydedilmez)',
      (tester) async {
        final env = dialogEnv();
        await openDialog(tester, env, api: FakeWifiDevice().client(env.clock));
        EditableText field() => tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('field_ap_password')),
            matching: find.byType(EditableText),
          ),
        );
        expect(field().obscureText, isTrue);
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('btn_copy_ap_password')))
              .onPressed,
          isNull,
        );

        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await typeInto(tester, 'field_ap_password', 'etiket-parolasi-77');
        await tapKey(tester, 'btn_ap_password_toggle');
        expect(field().obscureText, isFalse, reason: 'göster');
        await tapKey(tester, 'btn_ap_password_toggle');
        expect(field().obscureText, isTrue, reason: 'gizle');
        await tapKey(tester, 'btn_copy_ap_password');

        expect(copied, 'etiket-parolasi-77');
        expect(await env.h.storage.getAuthToken(), isNull);
        expect(
          env.h.storage.keys.where((k) => k.toLowerCase().contains('ap')),
          isEmpty,
          reason: 'AP parolası kaydedilmez',
        );
      },
    );

    testWidgets(
      'KENDİ cihaz istemcisi: varsayılan AP adresi (192.168.4.1) kullanılır; ana (doğrudan) istemciye ve adresine DOKUNULMAZ',
      (tester) async {
        final env = dialogEnv(role: 'owner');
        final dev = FakeWifiDevice();
        final hostBefore = env.state.host;
        final directBaseBefore = env.state.directApi.baseUrl;
        final directKeyBefore = env.state.directApi.localKey;
        expect(AppConfig.current.deviceApHost, '192.168.4.1');

        await http.runWithClient(() async {
          await openDialog(tester, env);
          await tester.tap(find.byKey(const Key('btn_wifi_check')));
          await tester.pump();
          await tester.pump();
        }, () => dev.api.client);

        expect(dev.api.requests, isNotEmpty);
        expect(
          dev.api.requests.every((r) => r.url.host == '192.168.4.1'),
          isTrue,
          reason: 'tüm istekler kurtarma AP adresine gider',
        );
        expect(
          env.h.directMock.requests,
          isEmpty,
          reason: 'ana doğrudan istemci kullanılmadı',
        );
        expect(
          env.state.host,
          hostBefore,
          reason: 'global cihaz adresi değişmedi',
        );
        expect(env.state.directApi.baseUrl, directBaseBefore);
        expect(
          env.state.directApi.localKey,
          directKeyBefore,
          reason: 'ana istemcinin anahtarı da değişmedi',
        );
      },
    );

    testWidgets(
      'AP adresi derleme ayarından (DEVICE_AP_HOST: QA\'da 10.0.2.2:8081) gelir',
      (tester) async {
        final env = dialogEnv();
        AppConfig.current = AppConfig.forTest(deviceApHost: '10.0.2.2:8081');
        addTearDown(() => AppConfig.current = AppConfig.defaults);
        final dev = FakeWifiDevice();

        await http.runWithClient(() async {
          await openDialog(tester, env);
          await tester.tap(find.byKey(const Key('btn_wifi_check')));
          await tester.pump();
          await tester.pump();
        }, () => dev.api.client);

        expect(
          dev.api.requests.any(
            (r) => r.url.host == '10.0.2.2' && r.url.port == 8081,
          ),
          isTrue,
        );
        expect(
          textOf(tester, 'wifi_connection_detail'),
          contains('10.0.2.2:8081'),
        );
      },
    );

    testWidgets(
      'uçtan uca: başarı sonrası "Tamam" gösterilir; kurtarma modunun bittiği ve telefonu ev Wi-Fi\'sine alma yönergesi verilir',
      (tester) async {
        final env = dialogEnv();
        final dev = FakeWifiDevice();
        await openDialog(tester, env, api: dev.client(env.clock));

        await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
        await typeInto(tester, 'field_wifi_password', 'yeni-wifi-sifresi');
        await tapKey(tester, 'btn_wifi_submit');
        expect(
          dev.connectBodies,
          hasLength(1),
          reason: 'gönder düğmesi gerçekten çalıştı',
        );
        dev.connectState = 'success';
        await advanceUntil(
          tester,
          env.clock,
          () => shown('wifi_result_success'),
        );
        await tester.pump();

        expect(find.byKey(const Key('btn_wifi_done')), findsOneWidget);
        expect(
          textOf(tester, 'wifi_success_detail'),
          contains('Kurtarma modu sona eriyor'),
        );
        expect(
          textOf(tester, 'wifi_success_phone_hint'),
          contains('ev Wi-Fi ağınıza'),
        );
        expect(
          find.byKey(const Key('wifi_step_ap')),
          findsNothing,
          reason: 'başarıda adım kartları gizlenir',
        );

        await tapKey(tester, 'btn_wifi_done');
        expect(find.byType(WifiRecoveryDialog), findsNothing);
      },
    );

    for (final scale in <double>[1.5, 2.0]) {
      testWidgets(
        'dar ekran (360 dp) ve yazı ölçeği $scale: sihirbaz taşmadan çizilir (adım kartı, bağlantı kartı, uzun ağ adı listesi, hata ve başarı görünümü)',
        (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearAllTestValues);
          final env = dialogEnv();
          final dev = FakeWifiDevice()
            ..networks = <Map<String, dynamic>>[
              // 32 bayta kadar (cihaz sınırı) uzun ağ adı: liste satırı taşmamalı, yalnızca kısaltılmalı.
              <String, dynamic>{
                'ssid': 'Cok Uzun Bir Ev Agi Adi 2.4 GHz',
                'rssi': -48,
                'enc': true,
              },
              <String, dynamic>{'ssid': 'KomsuAcik', 'rssi': -70, 'enc': false},
            ];

          await http.runWithClient(() async {
            await openFromHost<void>(
              tester,
              env.state,
              (context) =>
                  WifiRecoveryDialog.show(context, deviceUuid: kDeviceUid),
              size: const Size(360, 640),
            );
            await tapKey(
              tester,
              'btn_wifi_check',
              settleAfter: false,
            ); // diyalog kaydırılabilir: önce görünür kılınır
            await tester.pump();
            await tester.pump();
            await advanceUntil(
              tester,
              env.clock,
              () => shown('wifi_network_list'),
            );
            await tapKey(tester, 'wifi_network_0', settleAfter: false);
            await tester.pump();
            await typeInto(
              tester,
              'field_wifi_password',
              'cok-uzun-bir-ev-wifi-sifresi-12345',
            );
            await tapKey(tester, 'btn_wifi_submit', settleAfter: false);
            await tester.pump();
            await tester.pump();
            // Önce hata sonucu ("Yeniden Dene" eylemli hata kutusu: dar ekranda taşmamalı), sonra başarı.
            dev
              ..connectState = 'failed'
              ..connectReason = 202;
            await advanceUntil(
              tester,
              env.clock,
              () => shown('wifi_result_failed'),
            );
            expect(
              tester.takeException(),
              isNull,
              reason: 'hata kutusu taşmaz',
            );
            await tapKey(tester, 'btn_wifi_retry', settleAfter: false);
            await tester.pump();
            await tapKey(tester, 'btn_wifi_submit', settleAfter: false);
            await tester.pump();
            await tester.pump();
            dev.connectState = 'success';
            await advanceUntil(
              tester,
              env.clock,
              () => shown('wifi_result_success'),
            );
          }, () => dev.api.client);

          expect(
            tester.takeException(),
            isNull,
            reason: 'RenderFlex taşması yok',
          );
          expect(find.byKey(const Key('btn_wifi_done')), findsOneWidget);
        },
      );
    }

    testWidgets(
      'dışarı dokunmak sihirbazı KAPATMAZ (yazılan bilgiler kaybolmaz); "Kapat" düğmesi kapatır',
      (tester) async {
        final env = dialogEnv();
        await openDialog(tester, env, api: FakeWifiDevice().client(env.clock));
        await typeInto(tester, 'field_wifi_ssid', 'YazilanAg');

        await tester.tapAt(const Offset(4, 4)); // diyaloğun dışı (perde)
        await settle(tester);
        expect(find.byType(WifiRecoveryDialog), findsOneWidget);
        expect(fieldText(tester, 'field_wifi_ssid'), 'YazilanAg');

        await tapKey(tester, 'btn_close');
        expect(find.byType(WifiRecoveryDialog), findsNothing);
      },
    );

    testWidgets('diyalog kapanınca (kapat düğmesi) bekleyen işlemler durur', (
      tester,
    ) async {
      final env = dialogEnv();
      final dev = FakeWifiDevice()..scanningFirst = 1000;
      await openDialog(tester, env, api: dev.client(env.clock));
      await tester.tap(find.byKey(const Key('btn_wifi_check')));
      await tester.pump();
      await advanceUntil(tester, env.clock, () => dev.scanRequests >= 2);

      await tapKey(tester, 'btn_close');
      final before = dev.scanRequests;
      env.clock.advance(const Duration(seconds: 60));
      await tester.pump();

      expect(find.byType(WifiRecoveryDialog), findsNothing);
      expect(dev.scanRequests, before);
      expect(tester.takeException(), isNull);
    });
  });
}
