import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../models/arm_state_test.dart' show armStateJson, contact;
import '../support/safety_fixtures.dart';
import '../support/support.dart';

/// Faz 2 WP-I5 (tasarım F2.B.9): alarm kipi kurma/çözme komutu (iyimser değil), ön denetim, ret metinleri, yetki.
void main() {
  late List<CommandFailure> failures;
  setUp(() => failures = <CommandFailure>[]);

  Future<StateHarness> harness({String role = 'owner', String globalRole = 'user'}) async {
    final home = role == 'guest'
        ? HomeModel(
            id: kHomeA,
            name: 'Misafir Evi',
            role: 'guest',
            mqttTopicId: 'h_test',
            guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
            guestValidUntil: kTestNow.add(const Duration(hours: 5)),
          )
        : null;
    final h = await readyHarness(role: role, globalRole: globalRole, home: home, endpoints: safetyUiEndpoints());
    h.state.commandFailures.listen(failures.add);
    return h;
  }

  Map<String, dynamic> armed(String mode, String st, {List<Map<String, dynamic>> contacts = const [], String? lastId}) {
    final json = armStateJson(
      arm: <String, dynamic>{'mode': mode, 'st': st, 'ok': true, if (st == 'exit') 'until_up': 3045},
      contacts: contacts,
    );
    if (lastId != null) json['last_id'] = lastId;
    return json;
  }

  group('yetki (F2.B.6)', () {
    test('owner ve resident kurabilir; misafir ve servis rolleri kuramaz', () async {
      for (final (role, global, can) in <(String, String, bool)>[
        ('owner', 'user', true),
        ('resident', 'user', true),
        ('guest', 'user', false),
        ('service_user', 'user', false),
        ('owner', 'super_user', true),
      ]) {
        final h = await harness(role: role, globalRole: global);
        // guvenlik-12: ev rolü belirleyicidir (kendi evinin sahibi olan süper kullanıcı kurabilir).
        expect(h.state.capabilities.canArm, can, reason: '$role/$global');
        h.dispose();
      }
    });
  });

  group('bulut', () {
    test('kurma: POST …/arm {mode,id}; iyimser DEĞİL; panonun state onayıyla biter', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(armed('off', 'idle'));
      await pumpEventQueue();
      final future = h.state.setArmMode(kSafetyUid, ArmMode.away);
      await pumpEventQueue();
      expect(h.cloud.armCalls.single.mode, 'away');
      expect(h.cloud.armCalls.single.deviceId, kSafetyUid);
      expect(h.state.isArmPending(kSafetyUid), isTrue);
      expect(h.state.safetyByDevice[kSafetyUid]!.arm!.mode, ArmMode.off, reason: 'iyimser değil');
      h.mqtt.emitStateJson(armed('away', 'exit'));
      expect(await future, isTrue);
      await pumpEventQueue();
      expect(h.state.isArmPending(kSafetyUid), isFalse);
      expect(h.state.safetyByDevice[kSafetyUid]!.arm!.mode, ArmMode.away);
    });

    test('çözme de iyimser değil (off)', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(armed('away', 'alarm'));
      await pumpEventQueue();
      final future = h.state.setArmMode(kSafetyUid, ArmMode.off);
      await pumpEventQueue();
      expect(h.state.safetyByDevice[kSafetyUid]!.arm!.st, ArmStatus.alarm);
      h.mqtt.emitStateJson(armed('off', 'idle'));
      expect(await future, isTrue);
    });

    test('ön denetim: açık pencere -> ağa çıkmadan ret ve sensör adı', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(armed('off', 'idle', contacts: <Map<String, dynamic>>[contact('d6', 'window', active: true)]));
      await pumpEventQueue();
      expect(h.state.armBlockReason(kSafetyUid, ArmMode.away), 'Kurulamaz: Giriş 6 açık.');
      expect(await h.state.setArmMode(kSafetyUid, ArmMode.away), isFalse);
      await pumpEventQueue();
      expect(h.cloud.armCalls, isEmpty);
      expect(failures.single.message, 'Kurulamaz: Giriş 6 açık.');
      // Çözme ön denetime takılmaz.
      expect(h.state.armBlockReason(kSafetyUid, ArmMode.off), isNull);
    });

    test('panonun not_ready reddi Türkçe metne çevrilir', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(armed('off', 'idle'));
      await pumpEventQueue();
      final future = h.state.setArmMode(kSafetyUid, ArmMode.home);
      await pumpEventQueue();
      final id = h.cloud.armCalls.single.commandId;
      h.mqtt.emitStateJson(armed('off', 'idle')..['last_rej'] = <String, dynamic>{'id': id, 'code': 'not_ready'});
      await future; // dönüş "iletildi"dir; ret komut hattının hata akışından gelir
      await pumpEventQueue();
      expect(failures.single.message, 'Alarm kurulamadı: açık kapı ya da pencere var.');
      expect(h.state.isArmPending(kSafetyUid), isFalse);
    });

    test('caps intrusion yoksa ağa çıkmadan "v1.2.1\'e güncelleyin"; sunucu 409 FIRMWARE_UNSUPPORTED aynı metin', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyStateJson());
      await pumpEventQueue();
      expect(await h.state.setArmMode(kSafetyUid, ArmMode.away), isFalse);
      await pumpEventQueue();
      expect(h.cloud.armCalls, isEmpty);
      expect(failures.single.message, "Bu pano yazılımı alarm kipini desteklemiyor; v1.2.1'e güncelleyin.");

      failures.clear();
      h.mqtt.emitStateJson(armed('off', 'idle'));
      await pumpEventQueue();
      h.cloud.armHandler = (call) async =>
          throw const ApiException(statusCode: 409, code: 'FIRMWARE_UNSUPPORTED', message: 'x');
      expect(await h.state.setArmMode(kSafetyUid, ArmMode.away), isFalse);
      await pumpEventQueue();
      expect(failures.single.message, "Bu pano yazılımı alarm kipini desteklemiyor; v1.2.1'e güncelleyin.");
    });

    test('misafir: yetki yok, ağa çıkmaz', () async {
      final h = await harness(role: 'guest');
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(armed('off', 'idle'));
      await pumpEventQueue();
      expect(await h.state.setArmMode(kSafetyUid, ArmMode.away), isFalse);
      expect(h.cloud.armCalls, isEmpty);
    });
  });

  group('onay araması hırsız satırını atlar (F2.B.9)', () {
    test('aynı bölgede açık intrusion kaydı varsa alarm_ack su kaydını kullanır', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true, aid: ''));
      await pumpEventQueue();
      h.cloud.alarmRecords = const <AlarmRecord>[
        AlarmRecord(id: '90', zone: 1, aid: '9f3a11c0-9', kind: 'intrusion', status: 'latched', deviceUuid: kSafetyUid),
        AlarmRecord(id: '41', zone: 1, aid: '9f3a11c0-3', kind: 'water', status: 'latched', deviceUuid: kSafetyUid),
      ];
      final alarm = h.state.alarmItems.single;
      expect(alarm.aid, isNull);
      await h.state.ackAlarm(alarm);
      expect(h.cloud.ackCalls.single.alarmId, '41');
    });
  });

  group('LAN (doğrudan kip, K5)', () {
    test('POST /api/arm {mode, id}', () async {
      final h = StateHarness();
      addTearDown(h.dispose);
      var mode = 'off';
      Map<String, dynamic> status() {
        final json = armed(mode, mode == 'off' ? 'idle' : 'exit')
          ..remove('v')
          ..remove('uid')
          ..['device'] = kSafetyUid;
        return json;
      }

      h.state.setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'));
      h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      h.state.setHomesForTesting(<HomeModel>[testHome()]);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(status()));
      h.directMock.on('POST', '/api/arm', (r) {
        mode = r.json!['mode'] as String;
        return jsonResponse(<String, dynamic>{'ok': true, 'id': r.json?['id']});
      });
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      expect(await h.state.setArmMode(kSafetyUid, ArmMode.away), isTrue);
      final post = h.directMock.where('POST', '/api/arm').single;
      expect(post.json!['mode'], 'away');
      expect(post.json!['id'], isA<String>());
      expect(post.headers['X-Device-Key'], 'devicekey-1234');
    });
  });
}
