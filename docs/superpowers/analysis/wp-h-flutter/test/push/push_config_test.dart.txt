import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/services/push/push_config.dart';

// Gerçek olmayan, açıkça uydurma değerler.
const Map<String, String?> _full = <String, String?>{
  'FCM_API_KEY': 'test-api-key',
  'FCM_APP_ID': '1:111:android:aaa',
  'FCM_SENDER_ID': '111',
  'FCM_PROJECT_ID': 'test-project',
};

void main() {
  group('PushConfig.fromMap', () {
    test('dört değer de doluysa yapılandırma üretir', () {
      final config = PushConfig.fromMap(_full);
      expect(config, isNotNull);
      expect(config!.apiKey, 'test-api-key');
      expect(config.appId, '1:111:android:aaa');
      expect(config.messagingSenderId, '111');
      expect(config.projectId, 'test-project');
    });

    for (final key in _full.keys) {
      test('$key eksikse null döner', () {
        final values = Map<String, String?>.of(_full)..remove(key);
        expect(PushConfig.fromMap(values), isNull);
      });

      test('$key boş ya da yalnızca boşluksa null döner', () {
        expect(PushConfig.fromMap({..._full, key: ''}), isNull);
        expect(PushConfig.fromMap({..._full, key: '   '}), isNull);
        expect(PushConfig.fromMap({..._full, key: null}), isNull);
      });
    }

    test('değerler kırpılır', () {
      final config = PushConfig.fromMap({..._full, 'FCM_PROJECT_ID': '  test-project \n'});
      expect(config!.projectId, 'test-project');
    });

    test('boş harita null döner', () {
      expect(PushConfig.fromMap(const <String, String?>{}), isNull);
    });
  });

  group('PushConfig.fromEnvironment', () {
    test('dart-define verilmeyen derlemede null döner (push sessizce kapalı)', () {
      // Test koşusunda FCM_* tanımlı değildir; tanımlıysa bu test bilerek yapılandırmaya duyarlıdır.
      expect(PushConfig.fromEnvironment(), isNull);
    });
  });

  group('PushConfig kimlik ve gizlilik', () {
    test('eşitlik ve hashCode değerlere bağlıdır', () {
      final a = PushConfig.fromMap(_full)!;
      final b = PushConfig.fromMap(_full)!;
      final c = PushConfig.fromMap({..._full, 'FCM_SENDER_ID': '222'})!;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toString hiçbir değeri sızdırmaz', () {
      final text = PushConfig.fromMap(_full)!.toString();
      for (final secret in _full.values) {
        expect(text.contains(secret!), isFalse);
      }
    });
  });
}
