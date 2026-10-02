import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/services/push/push_config.dart';
import 'package:ev_otomasyon/services/push/push_gateway.dart';
import 'package:ev_otomasyon/services/push/push_gateway_factory.dart';

// Push gönderim katmanı yapılandırılmadı: fabrika, yapılandırma ne olursa olsun hareketsiz (no-op) ağ geçidi verir.
// Firebase/APNs kullanılmaz; bu dosya Firebase paketlerine BAĞLI DEĞİLDİR (firebase_core/firebase_messaging import
// edilmez). İleride gerçek push istenirse ayrıca eklenir (ENTEGRASYON.md, "Ek: Firebase ileride istenirse").

const PushConfig _config = PushConfig(
  apiKey: 'test-api-key',
  appId: '1:111:android:aaa',
  messagingSenderId: '111',
  projectId: 'test-project',
);

Future<void> _expectInert(PushGateway gateway) async {
  expect(gateway.isSupported, isFalse);
  await gateway.initialize();
  expect(gateway.isSupported, isFalse);
  expect(await gateway.permissionStatus(), PushPermission.unsupported);
  expect(await gateway.requestPermission(), PushPermission.unsupported);
  expect(await gateway.getToken(), isNull);
  expect(await gateway.getInitialMessage(), isNull);
  expect(await gateway.onTokenRefresh.isEmpty, isTrue);
  expect(await gateway.onForegroundMessage.isEmpty, isTrue);
  expect(await gateway.onMessageOpened.isEmpty, isTrue);
  await gateway.deleteToken();
}

void main() {
  group('createPushGateway', () {
    test('yapılandırma yoksa (FCM_* verilmemiş) hiçbir şey yapmayan ağ geçidi döner', () async {
      final gateway = createPushGateway(null);
      expect(gateway, isA<UnsupportedPushGateway>());
      await _expectInert(gateway);
    });

    test('push katmanı yapılandırılmadığından, yapılandırma verilse bile hareketsiz ağ geçidi döner', () async {
      final gateway = createPushGateway(_config);
      expect(gateway, isA<UnsupportedPushGateway>());
      await _expectInert(gateway);
    });
  });
}
