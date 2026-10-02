import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/utils/qr_claim_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => AppConfig.current = AppConfig.defaults);

  group('AppConfig: dart-define geçersiz kılmaları', () {
    test('varsayılanlar: HTTPS, TLS açık, 192.168.4.1', () {
      final c = AppConfig.fromOverrides(releaseMode: false);
      expect(c.apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(c.apiBaseUrl, startsWith('https://'));
      expect(c.mqttUseTls, isTrue);
      expect(c.deviceApHost, '192.168.4.1');
      expect(c.overridesApplied, isFalse);
      expect(c.deviceApBaseUrl, 'http://192.168.4.1');
    });

    test('debug/QA: üç override de uygulanır (emülatör örneği)', () {
      final c = AppConfig.forTest(
        apiBaseUrl: 'http://10.0.2.2:5000/api',
        mqttTls: 'false',
        deviceApHost: '10.0.2.2:8081',
      );
      expect(c.apiBaseUrl, 'http://10.0.2.2:5000/api');
      expect(c.mqttUseTls, isFalse);
      expect(c.deviceApHost, '10.0.2.2:8081');
      expect(c.deviceApBaseUrl, 'http://10.0.2.2:8081');
      expect(c.overridesApplied, isTrue);
      expect(c.apiHost, '10.0.2.2');
    });

    test('GÜVENLİK: release derlemede üç override de YOK SAYILIR', () {
      final c = AppConfig.fromOverrides(
        apiBaseUrl: 'http://10.0.2.2:5000/api',
        mqttTls: 'false',
        deviceApHost: '10.0.2.2:8081',
        releaseMode: true,
      );
      expect(c.apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(c.mqttUseTls, isTrue);
      expect(c.deviceApHost, AppConfig.defaultDeviceApHost);
      expect(c.overridesApplied, isFalse);
      expect(identical(c, AppConfig.defaults), isTrue);
    });

    test('release: her override kombinasyonu güvenli varsayılana döner', () {
      for (final api in <String>['', 'http://evil', 'https://x.example/api']) {
        for (final tls in <String>['', 'false', 'true', '0']) {
          for (final ap in <String>['', '10.0.0.1:1', 'host']) {
            final c = AppConfig.fromOverrides(
              apiBaseUrl: api,
              mqttTls: tls,
              deviceApHost: ap,
              releaseMode: true,
            );
            expect(c.apiBaseUrl, AppConfig.defaultApiBaseUrl, reason: '$api|$tls|$ap');
            expect(c.mqttUseTls, isTrue, reason: '$api|$tls|$ap');
            expect(c.deviceApHost, AppConfig.defaultDeviceApHost, reason: '$api|$tls|$ap');
          }
        }
      }
    });

    test('geçersiz override değerleri varsayılana düşer (debug)', () {
      final bad = AppConfig.fromOverrides(
        apiBaseUrl: 'ftp://x/api',
        mqttTls: 'belki',
        deviceApHost: 'http://host/yol',
        releaseMode: false,
      );
      expect(bad.apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(bad.mqttUseTls, isTrue);
      expect(bad.deviceApHost, AppConfig.defaultDeviceApHost);
      expect(bad.overridesApplied, isFalse);
      expect(AppConfig.forTest(apiBaseUrl: 'metin').apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(AppConfig.forTest(apiBaseUrl: 'http://h?x=1').apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(AppConfig.forTest(deviceApHost: 'h:99999').deviceApHost, AppConfig.defaultDeviceApHost);
      expect(AppConfig.forTest(deviceApHost: 'bir host').deviceApHost, AppConfig.defaultDeviceApHost);
    });

    test('sondaki / atılır; MQTT_TLS büyük/küçük harf duyarsız', () {
      expect(AppConfig.forTest(apiBaseUrl: 'http://10.0.2.2:5000/api//').apiBaseUrl, 'http://10.0.2.2:5000/api');
      expect(AppConfig.forTest(mqttTls: 'FALSE').mqttUseTls, isFalse);
      expect(AppConfig.forTest(mqttTls: ' true ').mqttUseTls, isTrue);
    });

    test('bu test derlemesinde dart-define verilmediği için etkin yapılandırma varsayılandır', () {
      expect(AppConfig.current.apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(AppConfig.current.mqttUseTls, isTrue);
    });
  });

  group('AppConfig: servislerin kullanımı', () {
    test('EvCloudApiService varsayılan baseUrl AppConfig.current.apiBaseUrl', () {
      AppConfig.current = AppConfig.forTest(apiBaseUrl: 'http://10.0.2.2:5000/api');
      final api = EvCloudApiService();
      addTearDown(api.dispose);
      expect(api.baseUrl, 'http://10.0.2.2:5000/api');
      // açıkça verilen baseUrl önceliklidir
      final explicit = EvCloudApiService(baseUrl: 'https://x.test/api');
      addTearDown(explicit.dispose);
      expect(explicit.baseUrl, 'https://x.test/api');
    });

    test('AutomationApiService varsayılan host = DEVICE_AP_HOST; recoveryAp fabrikası', () {
      AppConfig.current = AppConfig.forTest(deviceApHost: '10.0.2.2:8081');
      final api = AutomationApiService();
      addTearDown(api.dispose);
      expect(api.baseUrl, 'http://10.0.2.2:8081');
      final recovery = AutomationApiService.recoveryAp(localKey: 'anahtar-1234');
      addTearDown(recovery.dispose);
      expect(recovery.baseUrl, 'http://10.0.2.2:8081');
      expect(recovery.localKey, 'anahtar-1234');

      AppConfig.current = AppConfig.defaults;
      final prod = AutomationApiService.recoveryAp();
      addTearDown(prod.dispose);
      expect(prod.baseUrl, 'http://192.168.4.1');
    });

    test('QR izin listesi: üretim sitesi + (yalnızca debug/QA override ile) API ana makinesi', () {
      expect(QrClaimParser.defaultAllowedHosts, <String>{'evotomasyon.gudeteknoloji.com.tr'});
      AppConfig.current = AppConfig.forTest(apiBaseUrl: 'http://10.0.2.2:5000/api');
      expect(QrClaimParser.defaultAllowedHosts, containsAll(<String>['evotomasyon.gudeteknoloji.com.tr', '10.0.2.2']));
      // release'de override yok -> izin listesi genişlemez
      AppConfig.current = AppConfig.fromOverrides(apiBaseUrl: 'http://10.0.2.2:5000/api', releaseMode: true);
      expect(QrClaimParser.defaultAllowedHosts, <String>{'evotomasyon.gudeteknoloji.com.tr'});
    });
  });
}
