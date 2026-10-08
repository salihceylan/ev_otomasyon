import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_notice.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Arka plan alarm bildirimi: pano `state` geçişi -> telefon bildirimi eşlemesi (uygulama kimliği `ev/{t}/event`'e abone
/// olamadığı için alarm state'ten türetilir) ve bildirime dokunuşun uygulama yönlendirmesine çevrilmesi.
const String _uid = 'AHBU-S3-TEST01';
const String _home = '11111111-1111-4111-8111-111111111111';

SafetyState _state({
  String st = 'normal',
  String kind = 'water',
  String aid = '9f3a11c0-3',
  List<String> srcs = const <String>['d3'],
  String mode = 'normal',
  Map<String, dynamic>? arm,
}) =>
    SafetyState.fromStateJson(<String, dynamic>{
      'v': 3,
      'uid': _uid,
      'caps': <String>['safety', 'actuator', 'event', 'cfg', 'intrusion'],
      'sensors': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd3', 'src': 'di', 'kind': kind, 'zone': 1, 'active': st != 'normal', 'ok': true},
      ],
      'safety': <String, dynamic>{
        'policy': 'on',
        'mode': mode,
        'zones': <Map<String, dynamic>>[
          if (st != 'normal')
            <String, dynamic>{'id': 1, 'st': st, 'kind': kind, 'aid': aid, 'since_up': 10, 'srcs': srcs},
        ],
        'arm': ?arm,
      },
    });

AlarmNoticePlan _plan(SafetyState? before, SafetyState after, {Map<String, String> names = const <String, String>{}}) =>
    planAlarmNotices(homeId: _home, homeName: 'Evim', before: before, after: after, sensorName: (id) => names[id]);

void main() {
  group('alarm -> bildirim metni (uygulama içi alarm kartıyla aynı adlar)', () {
    test('su baskını: "Su baskını: <sensör> — <ev>"; sensör adı yoksa bölge', () {
      final plan = _plan(_state(), _state(st: 'latched'), names: <String, String>{'d3': 'Mutfak Su'});
      final n = plan.show.single;
      expect(n.type, AlarmNoticeType.alarm);
      expect(n.title, 'Su baskını: Mutfak Su — Evim');
      expect(n.body, contains('dokunun'));
      expect(n.zone, 1);
      expect(n.dedupeKey, 'z|$_home|$_uid|1|9f3a11c0-3');

      final unnamed = _plan(_state(), _state(st: 'latched')).show.single;
      expect(unnamed.title, 'Su baskını: Bölge 1 — Evim');
    });

    test('gaz ve duman: talimat gövdede; bilinmeyen tür "Güvenlik alarmı"', () {
      final gas = _plan(_state(kind: 'gas'), _state(st: 'latched', kind: 'gas')).show.single;
      expect(gas.title, startsWith('Gaz kaçağı:'));
      expect(gas.body, contains('187'));
      final smoke = _plan(_state(kind: 'smoke'), _state(st: 'latched', kind: 'smoke')).show.single;
      expect(smoke.title, startsWith('Duman algılandı:'));
      expect(smoke.body, contains('112'));
    });

    test('vana arızası ayrı bildirim; ev adı boşsa "Eviniz"', () {
      final plan = planAlarmNotices(
        homeId: _home,
        homeName: '  ',
        before: _state(st: 'latched'),
        after: _state(st: 'fault'),
      );
      final n = plan.show.single;
      expect(n.type, AlarmNoticeType.valveFault);
      expect(n.title, 'Vana kapanmadı (arıza) — Eviniz');
      expect(n.body, contains('Ana vanayı elle kapatın'));
    });

    test('güvenli kip ve hırsız alarmı', () {
      final safe = _plan(_state(), _state(mode: 'safe')).show.single;
      expect(safe.type, AlarmNoticeType.safeMode);
      expect(safe.title, 'Pano güvenli kipe girdi — Evim');

      final intrusion = _plan(
        _state(arm: <String, dynamic>{'mode': 'away', 'st': 'idle', 'ok': true}),
        _state(arm: <String, dynamic>{'mode': 'away', 'st': 'alarm', 'ok': true, 'aid': '77aa-1', 'srcs': <String>['d5']}),
        names: <String, String>{'d5': 'Giriş Kapısı'},
      ).show.single;
      expect(intrusion.type, AlarmNoticeType.intrusion);
      expect(intrusion.title, 'Hırsız alarmı: Giriş Kapısı — Evim');
      expect(intrusion.dedupeKey, 'i|$_home|$_uid|77aa-1');
    });

    test('ilk görüntüde (bağlanış / retained) süren alarm bildirilir; özdeş görüntü bildirim üretmez', () {
      final first = _plan(null, _state(st: 'latched'));
      expect(first.show.single.type, AlarmNoticeType.alarm);
      expect(_plan(_state(st: 'latched'), _state(st: 'latched')).show, isEmpty);
    });

    test('susturma, sensör arızası ve komut reddi bildirim değildir', () {
      final latched = _state(st: 'latched');
      expect(_plan(latched, latched).isEmpty, isTrue);
    });
  });

  group('kalkış -> bildirim silinir', () {
    test('alarm kalkınca bölgenin alarm ve arıza bildirimleri silinir, aid\'siz kayıt unutulur', () {
      final plan = _plan(_state(st: 'latched'), _state());
      final ids = plan.cancel.map((c) => c.notificationId).toSet();
      expect(ids, contains(stableNotificationId('z|$_home|$_uid|1')));
      expect(ids, contains(stableNotificationId('f|$_home|$_uid|1')));
      expect(plan.cancel.map((c) => c.forgetPrefix), contains('z|$_home|$_uid|1|-'));
    });

    test('hırsız alarmı ve güvenli kip bitince silinir', () {
      final intrusionEnd = _plan(
        _state(arm: <String, dynamic>{'mode': 'away', 'st': 'alarm', 'ok': true, 'aid': 'x-1'}),
        _state(arm: <String, dynamic>{'mode': 'off', 'st': 'idle', 'ok': true}),
      );
      expect(intrusionEnd.cancel.map((c) => c.notificationId), contains(stableNotificationId('i|$_home|$_uid')));
      final safeEnd = _plan(_state(mode: 'safe'), _state());
      expect(safeEnd.cancel.map((c) => c.forgetKey), contains('s|$_home|$_uid'));
    });
  });

  test('bildirim kimliği kararlı (süreçten bağımsız) ve ön plan servisininkiyle çakışmaz', () {
    expect(stableNotificationId('z|a|b|1'), stableNotificationId('z|a|b|1'));
    expect(stableNotificationId('z|a|b|1'), isNot(stableNotificationId('z|a|b|2')));
    expect(stableNotificationId('x'), greaterThanOrEqualTo(1000));
  });

  test('eski pano (güvenlik yok) hiçbir bildirim üretmez', () {
    expect(_plan(null, SafetyState.unsupported).isEmpty, isTrue);
  });

  group('dokunuş yükü -> uygulama yönlendirmesi', () {
    test('alarm: ev, pano, bölge ve tür taşınır; "opened" kaynağı', () {
      final n = _plan(_state(), _state(st: 'latched')).show.single;
      final notice = alarmPayloadToNotice(n.payload)!;
      expect(notice.type, SafetyPushType.alarm);
      expect(notice.homeId, _home);
      expect(notice.deviceUuid, _uid);
      expect(notice.zone, 1);
      expect(notice.kind, 'water');
      expect(notice.status, 'latched');
      expect(notice.source, PeaceNoticeSource.opened);
      expect(n.payload, isNot(contains('Evim')), reason: 'yükte ev adı yok');
    });

    test('vana arızası -> fault; hırsız -> intrusion; güvenli kip -> bilgi', () {
      final fault = _plan(_state(st: 'latched'), _state(st: 'fault')).show.single;
      expect(alarmPayloadToNotice(fault.payload)!.status, 'fault');
      final intrusion = _plan(null, _state(arm: <String, dynamic>{'mode': 'away', 'st': 'alarm', 'ok': true})).show.single;
      expect(alarmPayloadToNotice(intrusion.payload)!.isIntrusion, isTrue);
      final safe = _plan(_state(), _state(mode: 'safe')).show.single;
      expect(alarmPayloadToNotice(safe.payload)!.type, SafetyPushType.info);
    });

    test('bozuk / yabancı yük yok sayılır', () {
      expect(alarmPayloadToNotice(null), isNull);
      expect(alarmPayloadToNotice('{bozuk'), isNull);
      expect(alarmPayloadToNotice('{"v":2,"h":"x","t":"alarm"}'), isNull);
      expect(alarmPayloadToNotice('{"v":1,"t":"alarm"}'), isNull);
      expect(alarmPayloadToNotice('{"v":1,"h":"x","t":"nightly"}'), isNull);
    });
  });
}
