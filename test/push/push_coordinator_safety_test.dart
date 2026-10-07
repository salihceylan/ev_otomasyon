import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/services/push/push_gateway.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Faz 2 WP-N2 (tasarım F2.C.4): koordinatör güvenlik push'unu ayrı akışa (`safetyNotices`) verir; gece hatırlatması
/// yolu değişmez (mevcut `push_coordinator_test.dart` aynen geçer).
const String _home = '3f2b8c1e-9d4a-4e7b-a1c2-5d6e7f8a9b0c';

PushMessage _alarm({String alarmId = '41', String status = 'latched'}) => PushMessage(
      data: <String, dynamic>{
        'type': 'safety_alarm',
        'v': '1',
        'home_id': _home,
        'device_id': 'dev-1',
        'device_uuid': 'AHBU-S3-TEST01',
        'alarm_id': alarmId,
        'zone': '1',
        'kind': 'water',
        'status': status,
      },
      title: 'Su baskını alarmı',
      body: 'Su algılandı.',
    );

PushMessage _peace() => const PushMessage(
      data: <String, dynamic>{
        'type': 'peace_open_devices',
        'home_id': _home,
        'notice_id': '9',
        'open_lights': '2',
        'open_shutters': '0',
        'action': 'close_all',
        'v': '1',
      },
      title: 'Evim',
      body: '2 lamba açık.',
    );

void main() {
  late DateTime Function() now;

  PushCoordinator build(FakeAsync async, FakeGateway gateway) {
    final clock = async.getClock(DateTime.utc(2026, 10, 7, 3));
    now = clock.now;
    return PushCoordinator(
      gateway: gateway,
      api: FakeApi(),
      platform: 'android',
      now: clock.now,
      random: FixedRandom(0.5),
    );
  }

  test('güvenlik mesajı safetyNotices akışına gider, notices (gece) akışına gitmez', () {
    fakeAsync((async) {
      final gateway = FakeGateway();
      final c = build(async, gateway);
      final peace = <PeaceNotice>[];
      final safety = <SafetyPushNotice>[];
      c.notices.listen(peace.add);
      c.safetyNotices.listen(safety.add);
      c.start();
      async.flushMicrotasks();
      gateway.foreground.add(_alarm());
      gateway.foreground.add(_peace());
      async.flushMicrotasks();
      expect(safety, hasLength(1));
      expect(safety.single.alarmId, '41');
      expect(safety.single.source, PeaceNoticeSource.foreground);
      expect(peace.map((n) => n.noticeId), <int?>[9]);
    });
  });

  test('aynı alarm foreground + opened -> tek olay; fault ayrı olay', () {
    fakeAsync((async) {
      final gateway = FakeGateway();
      final c = build(async, gateway);
      final safety = <SafetyPushNotice>[];
      c.safetyNotices.listen(safety.add);
      c.start();
      async.flushMicrotasks();
      gateway.foreground.add(_alarm());
      gateway.opened.add(_alarm());
      gateway.opened.add(_alarm(status: 'fault'));
      async.flushMicrotasks();
      expect(safety.map((n) => n.status), <String?>['latched', 'fault']);
    });
  });

  test('dinleyici yokken tamponlanır (en çok 8), ilk dinleyiciye iletilir; 30 dk sonra atılır', () {
    fakeAsync((async) {
      final gateway = FakeGateway();
      final c = build(async, gateway);
      c.start();
      async.flushMicrotasks();
      for (var i = 1; i <= 10; i++) {
        gateway.opened.add(_alarm(alarmId: '$i'));
      }
      async.flushMicrotasks();
      final first = <SafetyPushNotice>[];
      final sub = c.safetyNotices.listen(first.add);
      async.flushMicrotasks();
      expect(first.map((n) => n.alarmId), <String?>['3', '4', '5', '6', '7', '8', '9', '10']);
      sub.cancel();

      gateway.opened.add(_alarm(alarmId: '99'));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 31));
      final late = <SafetyPushNotice>[];
      c.safetyNotices.listen(late.add);
      async.flushMicrotasks();
      expect(late, isEmpty, reason: '30 dakikadan eski güvenlik bildirimi tampondan iletilmez');
      expect(now().isAfter(DateTime.utc(2026, 10, 7, 3, 30)), isTrue);
    });
  });

  test('başlangıç mesajı (uygulama kapalıyken dokunuş) initial kaynağıyla gelir', () {
    fakeAsync((async) {
      final gateway = FakeGateway()..initialMessageProvider = () async => _alarm();
      final c = build(async, gateway);
      final safety = <SafetyPushNotice>[];
      c.safetyNotices.listen(safety.add);
      c.start();
      async.flushMicrotasks();
      expect(safety.single.source, PeaceNoticeSource.initial);
    });
  });
}
