import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/command_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

const String _uidA = 'AHBU-S3-AAAA01';
const String _uidB = 'AHBU-S3-BBBB02';

/// Güvenlik alanlı `state` (v:3) anlık görüntüsü.
DeviceStatus safetyStatus({
  String uid = _uidA,
  String valvePos = 'open',
  bool? sirenOn,
  String zoneSt = 'normal',
  bool silenced = false,
  String aid = '9f3a11c0-3',
  String? rejId,
  String rejCode = 'zone_latched',
  String? lastId,
}) {
  return DeviceStatus.fromJson(<String, dynamic>{
    'v': 3,
    'uid': uid,
    'caps': <String>['safety', 'actuator', 'event'],
    'last_id': ?lastId,
    if (rejId != null) 'last_rej': <String, dynamic>{'id': rejId, 'code': rejCode},
    'relays': <Map<String, dynamic>>[
      <String, dynamic>{'id': 1, 'name': 'Salon', 'type': 'light', 'state': false},
      <String, dynamic>{'id': 5, 'name': 'Vana', 'type': 'light', 'state': false, 'act': 'valve'},
      <String, dynamic>{'id': 6, 'name': 'Siren', 'type': 'light', 'state': sirenOn ?? false, 'act': 'siren'},
    ],
    'shutters': <Map<String, dynamic>>[],
    'actuators': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'a1', 'relay': 5, 'kind': 'valve', 'medium': 'water', 'zones': <int>[1], 'pos': valvePos},
      <String, dynamic>{'id': 'a2', 'relay': 6, 'kind': 'siren', 'zones': <int>[1], 'on': sirenOn ?? false},
    ],
    'safety': <String, dynamic>{
      'policy': 'on',
      'mode': 'normal',
      'zones': <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'st': zoneSt, 'kind': 'water', 'aid': aid, 'silenced': silenced},
      ],
    },
  }, filterPhantomShutters: false);
}

void main() {
  late FakeClock clock;
  late CommandPipeline pipeline;
  late List<CommandFailure> failures;
  late List<String> confirmations;

  setUp(() {
    clock = FakeClock();
    var n = 0;
    pipeline = CommandPipeline(clock: clock, idGenerator: () => 'cmd${++n}');
    failures = <CommandFailure>[];
    confirmations = <String>[];
    pipeline.failures.listen(failures.add);
    pipeline.confirmations.listen(confirmations.add);
  });
  tearDown(() => pipeline.dispose());

  CommandSender ok() => (id) async => CommandResult(delivered: true, deviceOnline: true, commandId: id);

  group('last_rej: ret ANINDA geri alınır (30 sn beklenmez)', () {
    test('kimlik eşleşince başarısızlık + Türkçe ret metni + kod', () async {
      await pipeline.submit(
        key: 'actuator:a1',
        original: null,
        target: null,
        send: ok(),
        confirms: CommandConfirm.valvePos('a1', closed: false),
        targetUid: _uidA,
      );
      expect(pipeline.isPending('actuator:a1'), isTrue);
      pipeline.observe(safetyStatus(rejId: 'cmd2', zoneSt: 'latched'));
      await pumpEventQueue();
      expect(pipeline.isPending('actuator:a1'), isFalse);
      expect(failures, hasLength(1));
      expect(failures.single.reason, CommandFailureReason.rejected);
      expect(failures.single.code, 'zone_latched');
      expect(failures.single.message, contains('Alarm sürerken vana açılamaz'));
    });

    test('başka komutun ret kaydı (eski last_rej) yok sayılır', () async {
      await pipeline.submit(key: 'actuator:a1', original: null, target: null, send: ok(), targetUid: _uidA);
      pipeline.observe(safetyStatus(rejId: 'eski-komut'));
      await pumpEventQueue();
      expect(pipeline.isPending('actuator:a1'), isTrue);
      expect(failures, isEmpty);
    });

    test('ret yankısı yalnız hedef panodan kabul edilir (çok panolu ev) [Y5]', () async {
      await pipeline.submit(key: 'relay:5', original: false, target: true, send: ok(), targetUid: _uidB);
      // A panosu düz relay:5 komutunu kendi vanası yüzünden reddetti; komut B'ye gidiyordu.
      pipeline.observe(safetyStatus(uid: _uidA, rejId: 'cmd2', rejCode: 'actuator_relay'));
      await pumpEventQueue();
      expect(pipeline.isPending('relay:5'), isTrue);
      expect(failures, isEmpty);
      pipeline.observe(safetyStatus(uid: _uidB, rejId: 'cmd2', rejCode: 'actuator_relay'));
      await pumpEventQueue();
      expect(failures.single.code, 'actuator_relay');
    });

    test('hedef bilinmiyorsa (LAN, tek pano) her state yankısı geçerlidir', () async {
      await pipeline.submit(key: 'relay:5', original: false, target: true, send: ok());
      pipeline.observe(safetyStatus(rejId: 'cmd2', rejCode: 'actuator_relay'));
      await pumpEventQueue();
      expect(failures.single.code, 'actuator_relay');
    });

    test('lamba komutu (last_rej yok): davranış değişmez, hedef state ile onaylanır', () async {
      await pipeline.submit(
        key: 'relay:1',
        original: false,
        target: true,
        send: ok(),
        confirms: CommandConfirm.relay(1, true),
      );
      pipeline.observe(DeviceStatus(relays: const <RelayItem>[RelayItem(id: 1, name: 'R', type: 0, state: true)]));
      await pumpEventQueue();
      expect(confirmations, <String>['relay:1']);
      expect(failures, isEmpty);
    });
  });

  group('CommandConfirm: güvenlik koşulları', () {
    test('valvePos kapalı: closed / cmd_closed / closing kabul; open değil', () {
      final p = CommandConfirm.valvePos('a1', closed: true);
      expect(p(safetyStatus(valvePos: 'closed')), isTrue);
      expect(p(safetyStatus(valvePos: 'cmd_closed')), isTrue);
      expect(p(safetyStatus(valvePos: 'closing')), isTrue);
      expect(p(safetyStatus(valvePos: 'open')), isFalse);
      expect(p(safetyStatus(valvePos: 'unknown')), isFalse);
    });

    test('valvePos açık: open / cmd_open / opening', () {
      final p = CommandConfirm.valvePos('a1', closed: false);
      expect(p(safetyStatus(valvePos: 'open')), isTrue);
      expect(p(safetyStatus(valvePos: 'cmd_open')), isTrue);
      expect(p(safetyStatus(valvePos: 'opening')), isTrue);
      expect(p(safetyStatus(valvePos: 'closed')), isFalse);
    });

    test('pano kimliği verilirse başka panonun aynı a1 kimliği onay sayılmaz', () {
      final p = CommandConfirm.valvePos('a1', closed: true, uid: _uidB);
      expect(p(safetyStatus(uid: _uidA, valvePos: 'closed')), isFalse);
      expect(p(safetyStatus(uid: _uidB, valvePos: 'closed')), isTrue);
    });

    test('actuatorOn', () {
      expect(CommandConfirm.actuatorOn('a2', false)(safetyStatus(sirenOn: false)), isTrue);
      expect(CommandConfirm.actuatorOn('a2', true)(safetyStatus(sirenOn: false)), isFalse);
      expect(CommandConfirm.actuatorOn('a2', true)(safetyStatus(sirenOn: true)), isTrue);
    });

    test('alarmSilencedOrCleared: susturuldu ya da bölge normal', () {
      final p = CommandConfirm.alarmSilencedOrCleared(1);
      expect(p(safetyStatus(zoneSt: 'latched')), isFalse);
      expect(p(safetyStatus(zoneSt: 'latched', silenced: true)), isTrue);
      expect(p(safetyStatus(zoneSt: 'fault', silenced: true)), isTrue);
      expect(p(safetyStatus(zoneSt: 'normal')), isTrue);
    });

    test('güvenlik alanı olmayan (v:2 / REST türevi) anlık görüntü hiçbir zaman onay değildir', () {
      final v2 = DeviceStatus(relays: const <RelayItem>[RelayItem(id: 5, name: 'V', type: 0, state: true)]);
      expect(CommandConfirm.valvePos('a1', closed: true)(v2), isFalse);
      expect(CommandConfirm.actuatorOn('a2', false)(v2), isFalse);
      expect(CommandConfirm.alarmSilencedOrCleared(1)(v2), isFalse);
    });
  });
}
