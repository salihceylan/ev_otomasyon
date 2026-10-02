import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/services/push/push_gateway.dart';

// Bu dosya Firebase paketlerine BAĞLI DEĞİLDİR (Firebase/APNs kullanılmaz; firebase_core/firebase_messaging import
// edilmez): yalnızca UnsupportedPushGateway ve PushMessage test edilir.

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
  await gateway.deleteToken(); // hareketsiz: fırlatmaz, hiçbir kanala dokunmaz
}

void main() {
  group('UnsupportedPushGateway', () {
    test('hiçbir şey yapmaz', () async {
      await _expectInert(const UnsupportedPushGateway());
    });
  });

  group('PushMessage', () {
    test('veriyi ve isteğe bağlı başlık/gövdeyi taşır', () {
      const message = PushMessage(data: <String, dynamic>{'a': '1'}, title: 't', body: 'b');
      expect(message.data['a'], '1');
      expect(message.title, 't');
      expect(message.body, 'b');
      expect(const PushMessage(data: <String, dynamic>{}).title, isNull);
    });
  });
}
