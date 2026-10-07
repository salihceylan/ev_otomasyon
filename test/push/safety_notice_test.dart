import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Faz 2 WP-N2 (tasarım F2.C.3): güvenlik push'u `data` ayrıştırması. `data` güvenilmeyen girdidir; asla fırlatmaz.
const String _home = '3f2b8c1e-9d4a-4e7b-a1c2-5d6e7f8a9b0c';

Map<String, dynamic> alarmData({Map<String, dynamic> over = const <String, dynamic>{}}) => <String, dynamic>{
      'type': 'safety_alarm',
      'v': '1',
      'home_id': _home,
      'device_id': 'dev-1',
      'device_uuid': 'AHBU-S3-TEST01',
      'alarm_id': '41',
      'zone': '1',
      'kind': 'gas',
      'status': 'latched',
      ...over,
    };

Map<String, dynamic> infoData({Map<String, dynamic> over = const <String, dynamic>{}}) => <String, dynamic>{
      'type': 'safety_info',
      'v': '1',
      'home_id': _home,
      'device_id': 'dev-1',
      'alarm_id': '41',
      'reason': 'alarm_lost',
      ...over,
    };

void main() {
  final now = DateTime.utc(2026, 10, 7, 3);

  SafetyPushNotice? parse(Map<String, dynamic> data, {String? title, String? body}) =>
      SafetyPushNotice.tryParse(data, title: title, body: body, source: PeaceNoticeSource.opened, now: now);

  group('geçerli', () {
    test('alarm: bütün alanlar', () {
      final n = parse(alarmData(), title: 'Gaz kaçağı alarmı', body: 'Gaz kaçağı algılandı (bölge 1).')!;
      expect(n.isAlarm, isTrue);
      expect(n.homeId, _home);
      expect(n.deviceId, 'dev-1');
      expect(n.deviceUuid, 'AHBU-S3-TEST01');
      expect(n.alarmId, '41');
      expect(n.zone, 1);
      expect(n.kind, 'gas');
      expect(n.status, 'latched');
      expect(n.reason, isNull);
      expect(n.title, 'Gaz kaçağı alarmı');
      expect(n.source, PeaceNoticeSource.opened);
      expect(n.receivedAt, now);
      expect(n.dedupeKey, 'a:41:latched');
    });

    test('bilgi: alarm_lost, policy_*, cfg_pending_dropped; alarm_id yok/boş olabilir', () {
      for (final reason in <String>['alarm_lost', 'policy_off', 'policy_on', 'cfg_pending_dropped']) {
        final n = parse(infoData(over: <String, dynamic>{'reason': reason}))!;
        expect(n.isAlarm, isFalse);
        expect(n.reason, reason);
        expect(n.zone, isNull);
      }
      final noId = parse(infoData(over: <String, dynamic>{'alarm_id': '', 'reason': 'policy_off'}))!;
      expect(noId.alarmId, isNull);
      expect(noId.dedupeKey, 'i:$_home:policy_off');
      expect(parse(infoData())!.dedupeKey, 'i:41:alarm_lost');
    });

    test('device_uuid yok -> null (eski sunucu); boş metin de yok sayılır', () {
      final data = alarmData()..remove('device_uuid');
      expect(parse(data)!.deviceUuid, isNull);
      expect(parse(alarmData(over: <String, dynamic>{'device_uuid': ''}))!.deviceUuid, isNull);
    });

    test('bilinmeyen kısa tür -> generic; intrusion tanınır', () {
      expect(parse(alarmData(over: <String, dynamic>{'kind': 'flood_x'}))!.kind, 'generic');
      expect(parse(alarmData(over: <String, dynamic>{'kind': 'intrusion'}))!.kind, 'intrusion');
      expect(parse(alarmData(over: <String, dynamic>{'kind': 'water'}))!.kind, 'water');
    });

    test('latched ve fault ayrı bildirimdir (dedupeKey)', () {
      final a = parse(alarmData())!;
      final b = parse(alarmData(over: <String, dynamic>{'status': 'fault'}))!;
      expect(a.dedupeKey, isNot(b.dedupeKey));
    });

    test('denetim/çift yön karakterleri temizlenir, uzunluk kırpılır', () {
      final n = parse(alarmData(), title: 'Gaz\u202E kaçağı\u0000', body: 'x' * 400)!;
      expect(n.title, 'Gaz kaçağı');
      expect(n.body!.length, 300);
    });
  });

  group('geçersiz -> null (fırlatmaz)', () {
    final cases = <String, Map<String, dynamic>>{
      'tür peace': alarmData(over: <String, dynamic>{'type': 'peace_open_devices'}),
      'tür bilinmiyor': alarmData(over: <String, dynamic>{'type': 'x'}),
      'v yok': alarmData()..remove('v'),
      'v 2': alarmData(over: <String, dynamic>{'v': '2'}),
      'home_id boş': alarmData(over: <String, dynamic>{'home_id': ''}),
      'home_id kötü karakter': alarmData(over: <String, dynamic>{'home_id': 'a/b'}),
      'home_id uzun': alarmData(over: <String, dynamic>{'home_id': 'a' * 65}),
      'device_id yok': alarmData()..remove('device_id'),
      'device_uuid küçük harf': alarmData(over: <String, dynamic>{'device_uuid': 'ahbu-1'}),
      'device_uuid uzun': alarmData(over: <String, dynamic>{'device_uuid': 'A' * 33}),
      'alarm_id harf': alarmData(over: <String, dynamic>{'alarm_id': '4a'}),
      'alarm_id 19 hane': alarmData(over: <String, dynamic>{'alarm_id': '1' * 19}),
      'alarm alarm_id yok': alarmData()..remove('alarm_id'),
      'zone 0': alarmData(over: <String, dynamic>{'zone': '0'}),
      'zone 5': alarmData(over: <String, dynamic>{'zone': '5'}),
      'zone yok': alarmData()..remove('zone'),
      'zone int': alarmData(over: <String, dynamic>{'zone': 1}),
      'status bilinmiyor': alarmData(over: <String, dynamic>{'status': 'cleared'}),
      'reason bilinmiyor': infoData(over: <String, dynamic>{'reason': 'x'}),
      'kind uzun': alarmData(over: <String, dynamic>{'kind': 'k' * 40}),
    };
    cases.forEach((name, data) {
      test(name, () => expect(parse(data), isNull));
    });

    test('okunurken fırlatan harita', () {
      expect(SafetyPushNotice.tryParse(_ThrowingMap()), isNull);
    });
  });

  test('toString kişisel veri yazdırmaz', () {
    final n = parse(alarmData(), title: 'Evim', body: 'Gizli')!;
    expect(n.toString(), isNot(contains(_home)));
    expect(n.toString(), isNot(contains('Evim')));
    expect(n.toString(), isNot(contains('Gizli')));
  });
}

class _ThrowingMap implements Map<String, dynamic> {
  @override
  dynamic operator [](Object? key) => throw StateError('kötü');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('kötü');
}
