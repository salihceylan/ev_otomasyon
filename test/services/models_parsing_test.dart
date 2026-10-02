import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/json_utils.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('json_utils', () {
    test('asInt: int/num/String/geçersiz', () {
      expect(asInt(5), 5);
      expect(asInt(5.9), 5);
      expect(asInt(' 7 '), 7);
      expect(asInt('7.0'), 7);
      expect(asInt('x'), isNull);
      expect(asInt(null), isNull);
      expect(asInt(double.nan), isNull);
      expect(asInt(true), isNull);
    });

    test('asBool: bool/sayı/metin', () {
      expect(asBool(true), isTrue);
      expect(asBool(1), isTrue);
      expect(asBool(0), isFalse);
      expect(asBool('TRUE'), isTrue);
      expect(asBool('off'), isFalse);
      expect(asBool('belki'), isNull);
    });

    test('asDate: saat dilimi eki yoksa UTC kabul edilir', () {
      final withZone = asDate('2026-10-01T10:00:00Z')!;
      final naive = asDate('2026-10-01T10:00:00')!;
      expect(withZone.isUtc, isTrue);
      expect(naive.isUtc, isTrue);
      expect(naive, withZone);
      expect(asDate('2026-10-01T13:00:00+03:00'), withZone);
      expect(asDate('geçersiz'), isNull);
    });

    test('parseList: bozuk kayıt listeyi düşürmez', () {
      final out = parseList<int>(
        <dynamic>[
          <String, dynamic>{'v': 1},
          'bozuk',
          <String, dynamic>{'v': 'x'},
          <String, dynamic>{'v': 3},
        ],
        (m) => asInt(m['v']) ?? (throw const FormatException('v')),
      );
      expect(out, <int>[1, 3]);
      expect(parseList<int>(null, (m) => 1), isEmpty);
      expect(parseList<int>('liste değil', (m) => 1), isEmpty);
    });
  });

  group('UserModel', () {
    test('UUID kimlik String kalır; rol normalleştirilir; token alanı yok', () {
      final user = UserModel.fromJson(<String, dynamic>{
        'id': '9f1c2e3a-0000-4000-8000-000000000001',
        'email': 'a@b.c',
        'full_name': 'Ayşe',
        'phone': null,
        'role': ' Super_User ',
      });
      expect(user.id, '9f1c2e3a-0000-4000-8000-000000000001');
      expect(user.role, 'super_user');
      expect(user.isSuperUser, isTrue);
      expect(user.phone, '');
      expect(user.toJson().containsKey('token'), isFalse);
      expect(UserModel.fromJson(user.toJson()).id, user.id);
    });

    test('tanınmayan rol yetki vermez ama kaybolmaz; rol yoksa user', () {
      final unknown = UserModel.fromJson(<String, dynamic>{'id': 'u', 'role': 'Hacker'});
      expect(unknown.role, 'hacker');
      expect(unknown.globalRole, GlobalRole.unknown);
      expect(UserModel.fromJson(<String, dynamic>{'id': 'u'}).role, 'user');
    });

    test('kimliksiz kayıt reddedilir', () {
      expect(() => UserModel.fromJson(<String, dynamic>{'email': 'x'}), throwsFormatException);
    });
  });

  group('HomeModel', () {
    test('id String; mqtt_topic_id ve eski mqtt_username kabul edilir; eski rol adları eşlenir', () {
      final a = HomeModel.fromJson(<String, dynamic>{
        'id': kUuid,
        'name': 'Ev',
        'role': 'member',
        'mqtt_topic_id': 'h_abc',
      });
      expect(a.id, kUuid);
      expect(a.role, 'resident');
      expect(a.mqttTopicId, 'h_abc');
      expect(a.timezone, 'Europe/Istanbul');

      final b = HomeModel.fromJson(<String, dynamic>{'id': 5, 'mqtt_username': 'home_5'});
      expect(b.id, '5');
      expect(b.mqttTopicId, 'home_5');
      expect(b.name, 'Evim');
    });

    test('misafir penceresi: pencere dışı ve pencere bilinmiyorsa süresi dolmuş', () {
      final now = DateTime.utc(2026, 10, 1, 12);
      final valid = HomeModel(
        id: 'h',
        name: 'x',
        role: 'guest',
        guestValidFrom: now.subtract(const Duration(hours: 1)),
        guestValidUntil: now.add(const Duration(hours: 1)),
      );
      expect(valid.isGuestExpiredAt(now), isFalse);
      expect(valid.isGuestExpiredAt(now.add(const Duration(hours: 2))), isTrue);
      expect(valid.isGuestExpiredAt(now.subtract(const Duration(hours: 2))), isTrue); // henüz başlamadı
      expect(const HomeModel(id: 'h', name: 'x', role: 'guest').isGuestExpiredAt(now), isTrue);
      expect(const HomeModel(id: 'h', name: 'x', role: 'owner').isGuestExpiredAt(now), isFalse);
      expect(
        HomeModel(id: 'h', name: 'x', role: 'guest', guestValidUntil: now.add(const Duration(hours: 1)), serverMarkedExpired: true)
            .isGuestExpiredAt(now),
        isTrue,
      );
    });

    test('toJson/fromJson gidiş-dönüş', () {
      final home = HomeModel(
        id: kUuid,
        name: 'Ev',
        role: 'guest',
        mqttTopicId: 'h_1',
        guestValidUntil: DateTime.utc(2026, 10, 2),
      );
      final copy = HomeModel.fromJson(home.toJson());
      expect(copy.id, home.id);
      expect(copy.role, 'guest');
      expect(copy.guestValidUntil, home.guestValidUntil);
    });
  });

  group('EndpointModel', () {
    test('UUID uç nokta kimliği korunur (eskiden int.tryParse ile 0 oluyordu)', () {
      final e = EndpointModel.fromJson(<String, dynamic>{
        'id': '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
        'home_id': kUuid,
        'device_id': 'dd',
        'channel_index': 3,
        'type': 'light',
        'name': 'Avize',
        'current_state': true,
      });
      expect(e.id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
      expect(e.homeId, kUuid);
      expect(e.channel, 3);
      expect(e.isLight, isTrue);
      expect(e.currentState, isTrue);
    });

    test('sunucunun iki adlandırması da çözülür (channel_index/type/current_position ve channel/endpoint_type/shutter_position)', () {
      final server = EndpointModel.fromJson(<String, dynamic>{
        'id': 'a',
        'channel_index': '4',
        'type': 'shutter',
        'shutter_pair_index': 2,
        'current_position': '55',
        'shutter_duration_sec': 24,
      });
      final legacy = EndpointModel.fromJson(<String, dynamic>{
        'id': 'b',
        'channel': 4,
        'endpoint_type': 'shutter',
        'shutter_position': 55,
      });
      expect(server.channel, 4);
      expect(server.isShutter, isTrue);
      expect(server.pair, 2);
      expect(server.shutterPosition, 55);
      expect(server.shutterDurationSec, 24);
      expect(legacy.channel, 4);
      expect(legacy.isShutter, isTrue);
      expect(legacy.pair, 2); // pair yoksa (channel+1)~/2
    });

    test('konum 0..100, süre 1..300 aralığına sıkıştırılır', () {
      final e = EndpointModel.fromJson(<String, dynamic>{
        'id': 'a',
        'channel': 1,
        'type': 'shutter',
        'current_position': 250,
        'shutter_duration_sec': 9999,
      });
      expect(e.shutterPosition, 100);
      expect(e.shutterDurationSec, 300);
    });

    test('birincil panjur satırı channel == 2*pair-1', () {
      EndpointModel row(int channel, {int? pair}) => EndpointModel.fromJson(<String, dynamic>{
            'id': 'x$channel',
            'channel_index': channel,
            'type': 'shutter',
            'shutter_pair_index': ?pair,
          });
      expect(row(3, pair: 2).isPrimaryShutterRow, isTrue);
      expect(row(4, pair: 2).isPrimaryShutterRow, isFalse);
      expect(row(1).isPrimaryShutterRow, isTrue);
      expect(row(2).isPrimaryShutterRow, isFalse);
    });

    test('geçersiz kanal / bilinmeyen tip / kimliksiz kayıt reddedilir', () {
      expect(() => EndpointModel.fromJson(<String, dynamic>{'id': 'a', 'channel': 0, 'type': 'light'}), throwsFormatException);
      expect(() => EndpointModel.fromJson(<String, dynamic>{'id': 'a', 'type': 'light'}), throwsFormatException);
      expect(() => EndpointModel.fromJson(<String, dynamic>{'id': 'a', 'channel': 1, 'type': 'bomba'}), throwsFormatException);
      expect(() => EndpointModel.fromJson(<String, dynamic>{'channel': 1, 'type': 'light'}), throwsFormatException);
    });

    test('bozuk bir kayıt listeyi silmez', () {
      final list = parseList(
        <dynamic>[
          <String, dynamic>{'id': 'a', 'channel': 1, 'type': 'light'},
          <String, dynamic>{'id': 'b', 'channel': 'xx', 'type': 'light'},
          <String, dynamic>{'id': 'c', 'channel': 2, 'type': 'plug'},
        ],
        EndpointModel.fromJson,
      );
      expect(list.map((e) => e.id), <String>['a', 'c']);
    });

    test('shutterBaseName yön ekini atar', () {
      expect(shutterBaseName('Salon Panjur Yukarı'), 'Salon Panjur');
      expect(shutterBaseName('Salon Panjur AŞAĞI'), 'Salon Panjur');
      expect(shutterBaseName('Yatak (Yukari)'), 'Yatak');
      expect(shutterBaseName('Balkon'), 'Balkon');
      expect(shutterBaseName('Yukarı', fallback: 'Panjur 2'), 'Panjur 2');
    });
  });

  group('HomeMember', () {
    test('userId UUID String; camelCase ve snake_case kabul edilir', () {
      final a = HomeMember.fromJson(<String, dynamic>{
        'userId': kUuid,
        'fullName': 'Ali',
        'role': 'guest',
        'validUntil': '2026-10-02T00:00:00Z',
        'isExpired': false,
      });
      final b = HomeMember.fromJson(<String, dynamic>{
        'user_id': kUuid,
        'full_name': 'Ali',
        'role': 'member',
        'valid_until': '2026-10-02T00:00:00Z',
        'is_expired': true,
      });
      expect(a.userId, kUuid);
      expect(a.isGuest, isTrue);
      expect(a.validUntil, DateTime.utc(2026, 10, 2));
      expect(b.userId, kUuid);
      expect(b.role, 'resident');
      expect(b.isExpired, isTrue);
    });
  });

  group('ScheduledRule', () {
    test('kimlikler String; 1 tabanlı kanal; her iki adlandırma', () {
      final rule = ScheduledRule.fromJson(<String, dynamic>{
        'id': kUuid,
        'home_id': kUuid,
        'device_id': 'dev',
        'channel': 3,
        'channel_type': 'shutter',
        'action': 'open',
        'hour': 7,
        'minute': 5,
        'days_of_week': <int>[1, 3, 5],
        'enabled': true,
      });
      expect(rule.id, kUuid);
      expect(rule.channel, 3);
      expect(rule.channelLabel, 'Panjur 3'); // ek +1 yok
      expect(rule.daysOfWeek, <int>[1, 3, 5]);
      expect(rule.timeString, '07:05');

      final camel = ScheduledRule.fromJson(<String, dynamic>{
        'id': 7,
        'homeId': 5,
        'channel': 1,
        'channelType': 'relay',
        'action': 'on',
        'hour': 22,
        'minute': 30,
        'daysOfWeek': '[0,6]',
      });
      expect(camel.id, '7');
      expect(camel.daysOfWeek, <int>[0, 6]);
    });

    test('days_of_week doğrulaması: aralık dışı/tekrar/tip hatası', () {
      Map<String, dynamic> base(Object? days) => <String, dynamic>{
            'id': 'r',
            'channel': 1,
            'action': 'on',
            'hour': 1,
            'minute': 1,
            'days_of_week': days,
          };
      expect(() => ScheduledRule.fromJson(base(<int>[7])), throwsFormatException);
      expect(() => ScheduledRule.fromJson(base(<int>[-1])), throwsFormatException);
      expect(() => ScheduledRule.fromJson(base('x')), throwsFormatException);
      expect(() => ScheduledRule.fromJson(base(<String>['a'])), throwsFormatException);
      expect(ScheduledRule.fromJson(base(<int>[3, 3, 1])).daysOfWeek, <int>[1, 3]); // tekrar silinir, sıralı
      expect(ScheduledRule.fromJson(base(null)).daysOfWeek, hasLength(7));
      expect(ScheduledRule.fromJson(base(<int>[])).daysShortString, 'Gün seçilmedi');
    });

    test('geçersiz saat/dakika/kanal reddedilir; bozuk kural listeyi düşürmez', () {
      final list = parseList(
        <dynamic>[
          <String, dynamic>{'id': '1', 'channel': 1, 'action': 'on', 'hour': 24, 'minute': 0},
          <String, dynamic>{'id': '2', 'channel': 1, 'action': 'on', 'hour': 23, 'minute': 59},
          <String, dynamic>{'id': '3', 'channel': 0, 'action': 'on', 'hour': 1, 'minute': 0},
          <String, dynamic>{'id': '4', 'channel': 2, 'hour': 1, 'minute': 0},
        ],
        ScheduledRule.fromJson,
      );
      expect(list.map((r) => r.id), <String>['2']);
    });

    test('validate + createPayload (snake_case, 1 tabanlı)', () {
      expect(
        ScheduledRule.validate(
            channel: 1, channelType: 'relay', action: 'on', hour: 8, minute: 0, daysOfWeek: <int>[1, 2]),
        isNull,
      );
      expect(
        ScheduledRule.validate(
            channel: 0, channelType: 'relay', action: 'on', hour: 8, minute: 0, daysOfWeek: <int>[1]),
        isNotNull,
      );
      expect(
        ScheduledRule.validate(
            channel: 1, channelType: 'relay', action: 'zap', hour: 8, minute: 0, daysOfWeek: <int>[1]),
        isNotNull,
      );
      expect(
        ScheduledRule.validate(
            channel: 1, channelType: 'relay', action: 'on', hour: 8, minute: 0, daysOfWeek: <int>[1, 1]),
        isNotNull,
      );
      final payload = ScheduledRule.createPayload(
        channel: 2,
        channelType: 'shutter',
        action: 'close',
        hour: 21,
        minute: 15,
        daysOfWeek: <int>[5, 1],
        label: '  Akşam  ',
        deviceId: 'dev',
      );
      expect(payload['channel_type'], 'shutter');
      expect(payload['days_of_week'], <int>[1, 5]);
      expect(payload['label'], 'Akşam');
      expect(payload['device_id'], 'dev');
      expect(payload.containsKey('channelType'), isFalse);
    });
  });

  group('DeviceStatus', () {
    test('MQTT v2 state: moving/dir/target/child_lock/last_id güvenle çözülür', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'v': 2,
        'uid': 'AHBU-S3-ABC123',
        'fw': '1.1.0',
        'seq': 1234,
        'uptime': 3600,
        'ip': '192.168.1.30',
        'child_lock': true,
        'last_id': 'abc123',
        'relays': <dynamic>[
          <String, dynamic>{'id': 1, 'name': 'Salon', 'type': 'light', 'state': true},
        ],
        'shutters': <dynamic>[
          <String, dynamic>{'pair': 1, 'pos': 100, 'moving': false, 'dir': 0, 'target': 255},
          <String, dynamic>{'pair': 2, 'pos': 40, 'moving': true, 'dir': 2, 'target': 10},
        ],
        'dis': <dynamic>[
          <String, dynamic>{'id': 1, 'state': false},
        ],
      });
      expect(s.uid, 'AHBU-S3-ABC123');
      expect(s.lastId, 'abc123');
      expect(s.seq, 1234);
      expect(s.childLock, isTrue);
      expect(s.childLockKnown, isTrue);
      expect(s.uptimeSec, 3600);
      expect(s.shutters, hasLength(2));
      expect(s.shutterByPair(1)!.target, isNull); // 255 = hedef yok
      expect(s.shutterByPair(2)!.isMoving, isTrue);
      expect(s.shutterByPair(2)!.direction, 2);
      expect(s.shutterByPair(2)!.target, 10);
      expect(s.shutterByPair(2)!.pos, 40);
      expect(s.relayById(1)!.state, isTrue);
    });

    test('tip hatalı / eksik alanlar çökmez, bozuk girişler atılır', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'relays': <dynamic>[
          <String, dynamic>{'id': 'x'},
          <String, dynamic>{'id': '2', 'state': 'true'},
          'bozuk',
          <String, dynamic>{'id': 999},
        ],
        'shutters': <dynamic>[
          <String, dynamic>{'pair': 'a'},
          <String, dynamic>{'pair': '1', 'pos': 'yarım', 'dir': 7},
        ],
        'child_lock': 'yes',
      });
      expect(s.relays.map((r) => r.id), <int>[2]);
      expect(s.relays.single.state, isTrue);
      // pair 'a' -> sıra numarası 1; '1' -> 1: yinelenen çift atılır.
      expect(s.shutters, hasLength(1));
      expect(s.shutters.single.direction, 0); // dir=7 aralık dışı -> 0
      expect(s.shutters.single.pos, 0); // 'yarım' sayı değil -> 0
      expect(s.childLock, isTrue);
      expect(DeviceStatus.fromJson(<String, dynamic>{}).childLockKnown, isFalse);
    });

    test('0 tabanlı eski bellenim: pair 0 görülürse tümü +1 kaydırılır', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'relays': <dynamic>[
          <String, dynamic>{'id': 1, 'type': 1},
          <String, dynamic>{'id': 2, 'type': 2},
          <String, dynamic>{'id': 3, 'type': 1},
          <String, dynamic>{'id': 4, 'type': 2},
        ],
        'shutters': <dynamic>[
          <String, dynamic>{'pair': 0, 'pos': 10},
          <String, dynamic>{'pair': 1, 'pos': 20},
        ],
      });
      expect(s.shutters.map((x) => x.pair), <int>[1, 2]);
      expect(s.shutterByPair(1)!.pos, 10);
      expect(s.shutterByPair(2)!.pos, 20);
    });

    test('hayalet panjur filtresi: iki rölesi de lamba olan çift atılır; tipi bilinmeyen korunur', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'relays': <dynamic>[
          <String, dynamic>{'id': 1, 'name': 'Salon Panjur Yukarı', 'type': 1},
          <String, dynamic>{'id': 2, 'name': 'Salon Panjur Aşağı', 'type': 2},
          <String, dynamic>{'id': 3, 'name': 'Avize', 'type': 0},
          <String, dynamic>{'id': 4, 'name': 'Spot', 'type': 0},
          <String, dynamic>{'id': 5, 'name': 'Bilinmeyen'},
          <String, dynamic>{'id': 6, 'name': 'Bilinmeyen 2'},
        ],
        'shutters': <dynamic>[
          <String, dynamic>{'pair': 1, 'pos': 50},
          <String, dynamic>{'pair': 2, 'pos': 0}, // hayalet: 3 ve 4 lamba
          <String, dynamic>{'pair': 3, 'pos': 0}, // tipi bilinmiyor: korunur
        ],
      });
      expect(s.shutters.map((x) => x.pair), <int>[1, 3]);
      expect(s.shutters.first.name, 'Salon Panjur');
      // Panjur röleleri lamba kartı olmaz; hayalet çiftin lambaları görünür.
      expect(s.controllableRelays.map((r) => r.id), containsAll(<int>[3, 4]));
      expect(s.controllableRelays.map((r) => r.id), isNot(contains(1)));
      expect(s.controllableRelays.map((r) => r.id), isNot(contains(2)));
    });

    test('röle tipi metin biçimi (MQTT v2) çözülür', () {
      expect(RelayItem.fromJson(<String, dynamic>{'id': 1, 'type': 'light'}).isLight, isTrue);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 1, 'type': 'shutter_up'}).isShutterUp, isTrue);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 2, 'type': 'shutter_down'}).isShutterDown, isTrue);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 3, 'type': 'impulse'}).isImpulse, isTrue);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 3, 'type': 'shutter'}).isShutterUp, isTrue);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 4, 'type': 'shutter'}).isShutterDown, isTrue);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 4, 'type': 'ufo'}).typeKnown, isFalse);
      expect(RelayItem.fromJson(<String, dynamic>{'id': 4}).typeKnown, isFalse);
    });

    test('kısıtlı (anahtarsız) durum özeti çözülür', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'device': 'AHBU-S3-ABC123',
        'name': 'Pano',
        'fw': '1.1.0',
        'provisioned': true,
        'wifi_connected': true,
      });
      expect(s.deviceName, 'Pano');
      expect(s.firmware, '1.1.0');
      expect(s.provisioned, isTrue);
      expect(s.wifiConnected, isTrue);
      expect(s.relays, isEmpty);
    });
  });

  group('api_models', () {
    test('MqttCredentials: eksik alan reddedilir, parola toString\'de yok', () {
      final c = MqttCredentials.fromJson(<String, dynamic>{
        'host': 'h.example',
        'port': '8884',
        'username': 'a_h_x_1',
        'password': 'çok-gizli-parola',
        'client_id': 'cid',
        'expires_at': '2026-10-01T20:00:00Z',
        'topic_id': 'h_x',
      });
      expect(c.port, 8884);
      expect(c.topicId, 'h_x');
      expect(c.toString(), isNot(contains('çok-gizli-parola')));
      expect(() => MqttCredentials.fromJson(<String, dynamic>{'host': 'h'}), throwsFormatException);
      expect(
        () => MqttCredentials.fromJson(<String, dynamic>{
          'host': 'h',
          'port': 99999,
          'username': 'u',
          'password': 'p',
          'expires_at': '2026-10-01T20:00:00Z',
          'topic_id': 't',
        }),
        throwsFormatException,
      );
    });

    test('CommandResult: delivered yoksa 2xx iletildi sayılır; device_online ve command_id okunur', () {
      expect(CommandResult.fromJson(<String, dynamic>{}).delivered, isTrue);
      final r = CommandResult.fromJson(<String, dynamic>{
        'delivered': false,
        'device_online': false,
        'command_id': 'c1',
      });
      expect(r.delivered, isFalse);
      expect(r.deviceOnline, isFalse);
      expect(r.commandId, 'c1');
    });

    test('CommissioningChecks gövdesi tests_passed içermez', () {
      const ok = CommissionCheck(ok: true, detail: 'tamam');
      const checks = CommissioningChecks(
        relays: ok,
        buttons: ok,
        shutters: ok,
        network: ok,
        cloud: CommissionCheck(ok: false, detail: 'bulut yok'),
      );
      final json = checks.toJson();
      expect(json.keys, containsAll(<String>['relays', 'buttons', 'shutters', 'network', 'cloud']));
      expect(json.containsKey('tests_passed'), isFalse);
      expect(checks.allOk, isFalse);
    });

    test('InvitationModel hem snake_case hem camelCase', () {
      final a = InvitationModel.fromJson(<String, dynamic>{
        'inviteCode': 'ABCD123456',
        'role': 'guest',
        'qrPayload': 'AHBU-INVITE:ABCD123456',
        'expiresAt': '2026-10-02T00:00:00Z',
        'guestValidUntil': '2026-10-02T00:00:00Z',
      });
      expect(a.code, 'ABCD123456');
      expect(a.qrContent, 'AHBU-INVITE:ABCD123456');
      expect(a.guestValidUntil, DateTime.utc(2026, 10, 2));
      final b = InvitationModel.fromJson(<String, dynamic>{'invite_code': 'XYZ', 'role': 'member'});
      expect(b.role, 'resident');
      expect(b.qrContent, 'AHBU-INVITE:XYZ');
    });
  });
}

const String kUuid = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
