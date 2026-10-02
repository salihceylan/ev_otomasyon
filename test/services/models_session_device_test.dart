import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Oturum / ev erişimi / cihaz kimliği / huzur bildirimi / Wi-Fi modelleri (A paketi + D11).
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);

  group('UserModel: zorunlu parola değişimi', () {
    test('must_change_password ve email_verified okunur (bool, sayı, metin); yoksa false', () {
      UserModel parse(Map<String, dynamic> extra) =>
          UserModel.fromJson(<String, dynamic>{'id': 'u1', 'email': 'a@b.c', 'full_name': 'Ayşe', ...extra});

      expect(parse(<String, dynamic>{}).mustChangePassword, isFalse);
      expect(parse(<String, dynamic>{'must_change_password': true}).mustChangePassword, isTrue);
      expect(parse(<String, dynamic>{'must_change_password': 1}).mustChangePassword, isTrue);
      expect(parse(<String, dynamic>{'must_change_password': 'true'}).mustChangePassword, isTrue);
      expect(parse(<String, dynamic>{'must_change_password': 'garip'}).mustChangePassword, isFalse);
      expect(parse(<String, dynamic>{'mustChangePassword': true}).mustChangePassword, isTrue);
      expect(parse(<String, dynamic>{'email_verified': true}).emailVerified, isTrue);
      expect(parse(<String, dynamic>{}).emailVerified, isFalse);
    });

    test('kalıcılaştırma gidiş-dönüş (güvenli depodaki kullanıcı kaydı) ve copyWith', () {
      const user = UserModel(id: 'u1', email: 'a@b.c', fullName: 'Ayşe', mustChangePassword: true, emailVerified: true);
      final restored = UserModel.fromJson(user.toJson());
      expect(restored.mustChangePassword, isTrue);
      expect(restored.emailVerified, isTrue);
      expect(restored.copyWith(mustChangePassword: false).mustChangePassword, isFalse);
      expect(restored.copyWith(fullName: 'Ali').mustChangePassword, isTrue, reason: 'diğer alanlar korunur');
    });
  });

  group('HomeAccessState ve HomeModel.access_state', () {
    test('parse tablosu (sözleşme `guest_expired` yazar, sunucu `expired` döndürür)', () {
      for (final entry in <String?, HomeAccessState>{
        'active': HomeAccessState.active,
        'ACTIVE': HomeAccessState.active,
        'not_started': HomeAccessState.notStarted,
        'notstarted': HomeAccessState.notStarted,
        'pending': HomeAccessState.notStarted,
        'expired': HomeAccessState.expired,
        'guest_expired': HomeAccessState.expired,
        'GUEST-EXPIRED': HomeAccessState.expired,
        ' expired ': HomeAccessState.expired,
        'weird': HomeAccessState.unknown,
        '': HomeAccessState.unknown,
        null: HomeAccessState.unknown,
      }.entries) {
        expect(HomeAccessState.parse(entry.key), entry.value, reason: '${entry.key}');
      }
      expect(HomeAccessState.expired.isBlocked, isTrue);
      expect(HomeAccessState.notStarted.isBlocked, isTrue);
      expect(HomeAccessState.active.isBlocked, isFalse);
      expect(HomeAccessState.unknown.isBlocked, isFalse, reason: 'bilinmeyen durum pencere alanlarıyla değerlendirilir');
    });

    test('GET /homes öğesi: access_state, mqtt_topic_id, valid_until okunur', () {
      final home = HomeModel.fromJson(<String, dynamic>{
        'id': '11111111-1111-4111-8111-111111111111',
        'name': 'Misafir Evi',
        'role': 'guest',
        'timezone': 'Europe/Istanbul',
        'mqtt_topic_id': 'h_abc123',
        'valid_from': '2026-10-01T10:00:00.000Z',
        'valid_until': '2026-10-01T20:00:00.000Z',
        'access_state': 'active',
        'is_expired': false,
      });
      expect(home.accessState, HomeAccessState.active);
      expect(home.mqttTopicId, 'h_abc123');
      expect(home.guestValidUntil, DateTime.utc(2026, 10, 1, 20));
      expect(home.serverMarkedExpired, isFalse);
      expect(home.isGuestExpiredAt(now), isFalse);
    });

    test('süresi dolmuş erişim: topic gizlenmiş (null), engelleyici durum -> serverMarkedExpired', () {
      final home = HomeModel.fromJson(<String, dynamic>{
        'id': '11111111-1111-4111-8111-111111111111',
        'name': 'Eski Misafir Evi',
        'role': 'guest',
        'mqtt_topic_id': null,
        'valid_until': '2026-10-01T20:00:00.000Z',
        'access_state': 'expired',
        'is_expired': true,
      });
      expect(home.mqttTopicId, isEmpty);
      expect(home.accessState, HomeAccessState.expired);
      expect(home.serverMarkedExpired, isTrue);
      expect(home.isGuestExpiredAt(now), isTrue, reason: 'pencere gelecekte görünse de sunucu kapalı diyor');
    });

    test('çelişki: is_expired false ama access_state engelleyici -> güvenli taraf (kapalı)', () {
      for (final state in <String>['expired', 'guest_expired', 'not_started']) {
        final home = HomeModel.fromJson(<String, dynamic>{
          'id': 'h1',
          'role': 'guest',
          'valid_until': '2027-01-01T00:00:00.000Z',
          'access_state': state,
          'is_expired': false,
        });
        expect(home.serverMarkedExpired, isTrue, reason: state);
        expect(home.isGuestExpiredAt(now), isTrue, reason: state);
      }
    });

    test('is_expired true ama access_state active: yine kapalı (fail-closed)', () {
      final home = HomeModel.fromJson(<String, dynamic>{
        'id': 'h1',
        'role': 'guest',
        'valid_until': '2027-01-01T00:00:00.000Z',
        'access_state': 'active',
        'is_expired': true,
      });
      expect(home.serverMarkedExpired, isTrue);
    });

    test('access_state yok (eski sunucu): unknown; owner evinde engel yok', () {
      final home = HomeModel.fromJson(<String, dynamic>{'id': 'h1', 'role': 'owner', 'mqtt_username': 'h_old'});
      expect(home.accessState, HomeAccessState.unknown);
      expect(home.serverMarkedExpired, isFalse);
      expect(home.mqttTopicId, 'h_old', reason: 'geçiş dönemi: mqtt_username');
      expect(home.isGuestExpiredAt(now), isFalse);
    });

    test('önbellek gidiş-dönüş: access_state korunur; copyWith erişim durumunu değiştirir', () {
      final home = HomeModel.fromJson(<String, dynamic>{
        'id': 'h1',
        'role': 'guest',
        'valid_until': '2026-10-02T00:00:00.000Z',
        'access_state': 'not_started',
      });
      final restored = HomeModel.fromJson(home.toJson());
      expect(restored.accessState, HomeAccessState.notStarted);
      expect(restored.serverMarkedExpired, isTrue);
      expect(home.copyWith(accessState: HomeAccessState.expired, serverMarkedExpired: true).accessState, HomeAccessState.expired);
    });
  });

  group('DeviceMqttCredential', () {
    final json = <String, dynamic>{
      'host': 'broker.example.test',
      'port': 8884,
      'username': 'd_h_abc123',
      'password': 'sifre-yer-tutucu-xyz',
      'client_id': 'ESP32S3_AABBCCDDEEFF',
      'topic_id': 'h_abc123',
    };

    test('geçerli yanıt; takma ad alanları (server/user/pass) da okunur', () {
      expect(DeviceMqttCredential.fromJson(json).topicId, 'h_abc123');
      final alias = DeviceMqttCredential.fromJson(<String, dynamic>{
        'server': 'broker.example.test',
        'port': '8884',
        'user': 'd_x',
        'pass': 'p-yer-tutucu',
        'topic_id': 'h_x',
      });
      expect(alias.host, 'broker.example.test');
      expect(alias.port, 8884);
      expect(alias.username, 'd_x');
    });

    test('tryParse: bozuk / eksik / liste değil -> null (istisna yok)', () {
      expect(DeviceMqttCredential.tryParse(null), isNull);
      expect(DeviceMqttCredential.tryParse('metin'), isNull);
      expect(DeviceMqttCredential.tryParse(<dynamic>[]), isNull);
      expect(DeviceMqttCredential.tryParse(<String, dynamic>{...json}..remove('password')), isNull);
      expect(DeviceMqttCredential.tryParse(<String, dynamic>{...json, 'port': 70000}), isNull);
      expect(DeviceMqttCredential.tryParse(<String, dynamic>{...json, 'host': ''}), isNull);
      expect(DeviceMqttCredential.tryParse(json), isNotNull);
    });

    test('toString parolayı ve konu kimliğini içermez', () {
      final text = DeviceMqttCredential.fromJson(json).toString();
      expect(text, isNot(contains('sifre-yer-tutucu-xyz')));
      expect(text, isNot(contains('h_abc123')));
    });
  });

  group('PeaceNotificationSettings', () {
    test('sunucunun uzun anahtarları (peace_notification_enabled/_time)', () {
      final settings = PeaceNotificationSettings.fromJson(<String, dynamic>{
        'home_id': 'h1',
        'peace_notification_enabled': true,
        'peace_notification_time': '23:30',
        'open_lights_count': 3,
        'open_shutters_count': 1,
        'summary_text': 'Açık lamba tespit edildi (3 adet).',
        'open_lights': <dynamic>[],
      });
      expect(settings.enabled, isTrue);
      expect(settings.time, '23:30');
      expect(settings.openLightsCount, 3);
      expect(settings.openShuttersCount, 1);
      expect(settings.summaryText, contains('3 adet'));
    });

    test('kısa anahtarlar (enabled/time) ve v2 alanları ham haritada', () {
      final settings = PeaceNotificationSettings.fromJson(<String, dynamic>{
        'enabled': false,
        'time': '22:15',
        'timezone': 'Europe/Istanbul',
        'last_notice': <String, dynamic>{'id': 'n1'},
      });
      expect(settings.enabled, isFalse);
      expect(settings.time, '22:15');
      expect(settings.timezone, 'Europe/Istanbul');
      expect((settings.raw['last_notice'] as Map)['id'], 'n1');
    });

    test('PUT yanıtı iç içe `settings` altında gelirse okunur', () {
      final settings = PeaceNotificationSettings.fromJson(<String, dynamic>{
        'message': 'Güncellendi',
        'settings': <String, dynamic>{'peace_notification_enabled': false, 'peace_notification_time': '21:00'},
      });
      expect(settings.enabled, isFalse);
      expect(settings.time, '21:00');
    });

    test('saat normalleştirme: 23:30:00 -> 23:30, 9:05 -> 09:05; bilinmeyen biçim olduğu gibi; yoksa null', () {
      PeaceNotificationSettings parse(Object? time) =>
          PeaceNotificationSettings.fromJson(<String, dynamic>{'peace_notification_time': time});
      expect(parse('23:30:00').time, '23:30');
      expect(parse('9:05').time, '09:05');
      expect(parse('gece').time, 'gece');
      expect(parse(null).time, isNull);
      expect(PeaceNotificationSettings.fromJson(<String, dynamic>{}).enabled, isNull, reason: 'söylenmedi = bilinmiyor');
    });
  });

  group('CloseAllResult', () {
    test('sunucu yanıtı: closed_count, delivered, command_id', () {
      final result = CloseAllResult.fromJson(<String, dynamic>{
        'closed_count': 3,
        'delivered': true,
        'device_online': true,
        'command_id': 'abc123',
        'message': 'Huzur modu: 3 lamba kapatma komutu cihaza iletildi.',
      });
      expect(result.closedCount, 3);
      expect(result.delivered, isTrue);
      expect(result.deviceOnline, isTrue);
      expect(result.commandId, 'abc123');
      expect(result.message, contains('3 lamba'));
    });

    test('eski anahtar adları ve eksik alanlar', () {
      expect(CloseAllResult.fromJson(<String, dynamic>{'closed': 2}).closedCount, 2);
      expect(CloseAllResult.fromJson(<String, dynamic>{'count': 4}).closedCount, 4);
      expect(CloseAllResult.fromJson(<String, dynamic>{}).closedCount, isNull);
    });
  });

  group('WifiNetwork', () {
    test('ssid + rssi + enc (bool); gizli/boş ad FormatException', () {
      final secured = WifiNetwork.fromJson(<String, dynamic>{'ssid': 'EvAgi', 'rssi': -55, 'enc': true});
      expect(secured.ssid, 'EvAgi');
      expect(secured.rssi, -55);
      expect(secured.secured, isTrue);
      expect(WifiNetwork.fromJson(<String, dynamic>{'ssid': 'Açık', 'rssi': -80, 'enc': false}).secured, isFalse);
      expect(WifiNetwork.fromJson(<String, dynamic>{'ssid': 'X'}).secured, isTrue, reason: 'bilinmiyorsa güvenli taraf: şifreli');
      expect(() => WifiNetwork.fromJson(<String, dynamic>{'ssid': ''}), throwsFormatException);
      expect(() => WifiNetwork.fromJson(<String, dynamic>{'rssi': -50}), throwsFormatException);
    });
  });

  group('ServiceTokenSummary / ServiceSessionSummary', () {
    test('kimlik zorunlu; durum alanlardan türetilir', () {
      expect(() => ServiceTokenSummary.fromJson(<String, dynamic>{'status': 'active'}), throwsFormatException);
      expect(ServiceTokenSummary.fromJson(<String, dynamic>{'id': 'a'}).status, 'active');
      expect(ServiceTokenSummary.fromJson(<String, dynamic>{'id': 'a', 'used_at': '2026-10-01T10:00:00Z'}).status, 'used');
      expect(ServiceTokenSummary.fromJson(<String, dynamic>{'id': 'a', 'is_used': true}).status, 'used');
      expect(ServiceTokenSummary.fromJson(<String, dynamic>{'id': 'a', 'revoked_at': '2026-10-01T10:00:00Z', 'used_at': '2026-10-01T09:00:00Z'}).status, 'revoked');
      expect(ServiceTokenSummary.fromJson(<String, dynamic>{'id': 'a', 'status': 'EXPIRED'}).status, 'expired');
      expect(() => ServiceSessionSummary.fromJson(<String, dynamic>{}), throwsFormatException);
      expect(ServiceSessionSummary.fromJson(<String, dynamic>{'id': 's'}).technicianName, isEmpty);
    });
  });
}
