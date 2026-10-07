import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';

/// Faz 2 WP-I5 (tasarım F2.B.7, F2.B.9): `state.safety.arm` ayrıştırması, yetenek, ön denetim.
Map<String, dynamic> armStateJson({
  Map<String, dynamic>? arm,
  bool intrusionCap = true,
  List<Map<String, dynamic>> contacts = const <Map<String, dynamic>>[],
}) {
  final base = safetyStateJson();
  return <String, dynamic>{
    ...base,
    'caps': <String>['safety', 'actuator', 'event', 'cfg', if (intrusionCap) 'intrusion'],
    'sensors': <Map<String, dynamic>>[...(base['sensors'] as List).cast<Map<String, dynamic>>(), ...contacts],
    'safety': <String, dynamic>{
      ...(base['safety'] as Map<String, dynamic>),
      'arm': ?arm,
    },
  };
}

Map<String, dynamic> contact(String id, String kind, {bool active = false, bool ok = true, int zone = 1}) =>
    <String, dynamic>{'id': id, 'src': 'di', 'kind': kind, 'zone': zone, 'active': active, 'ok': ok};

void main() {
  group('ArmState ayrıştırma', () {
    test('kip/durum/ok/until_up/aid/srcs', () {
      final s = SafetyState.fromStateJson(armStateJson(arm: <String, dynamic>{
        'mode': 'away',
        'st': 'alarm',
        'ok': true,
        'aid': '9f3a11c0-7',
        'srcs': <String>['d5', 'd6'],
      }));
      expect(s.supportsIntrusion, isTrue);
      final arm = s.arm!;
      expect(arm.mode, ArmMode.away);
      expect(arm.st, ArmStatus.alarm);
      expect(arm.ok, isTrue);
      expect(arm.aid, '9f3a11c0-7');
      expect(arm.srcs, <String>['d5', 'd6']);
      expect(s.intrusionAlarmActive, isTrue);

      final exit = SafetyState.fromStateJson(armStateJson(arm: <String, dynamic>{
        'mode': 'home',
        'st': 'exit',
        'ok': true,
        'until_up': 3045,
      }));
      expect(exit.arm!.untilUp, 3045);
      expect(exit.intrusionAlarmActive, isFalse);
    });

    test('arm yoksa null; caps intrusion yoksa supportsIntrusion false; bilinmeyen değer unknown (fırlatmaz)', () {
      expect(SafetyState.fromStateJson(armStateJson()).arm, isNull);
      expect(SafetyState.fromStateJson(armStateJson(intrusionCap: false)).supportsIntrusion, isFalse);
      final odd = SafetyState.fromStateJson(armStateJson(arm: <String, dynamic>{'mode': 'party', 'st': 'x', 'ok': 'evet'}));
      expect(odd.arm!.mode, ArmMode.unknown);
      expect(odd.arm!.st, ArmStatus.unknown);
      expect(odd.arm!.ok, isFalse);
    });

    test('srcs en çok 8; eşitlik ve hash', () {
      Map<String, dynamic> arm() => <String, dynamic>{
            'mode': 'away',
            'st': 'alarm',
            'ok': true,
            'aid': 'x-1',
            'srcs': <String>[for (var i = 1; i <= 12; i++) 'd$i'],
          };
      final a = SafetyState.fromStateJson(armStateJson(arm: arm()));
      final b = SafetyState.fromStateJson(armStateJson(arm: arm()));
      expect(a.arm!.srcs, hasLength(8));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      final c = SafetyState.fromStateJson(armStateJson(arm: <String, dynamic>{...arm(), 'st': 'idle'}));
      expect(c, isNot(a));
    });
  });

  group('armBlockReason (F2.B.9 ön denetim)', () {
    SafetyState state(List<Map<String, dynamic>> contacts) => SafetyState.fromStateJson(
          armStateJson(arm: <String, dynamic>{'mode': 'off', 'st': 'idle', 'ok': true}, contacts: contacts),
        );

    test('açık pencere (anlık) -> kurulamaz; giriş yolu kapı açık olabilir', () {
      final s = state(<Map<String, dynamic>>[contact('d5', 'door', active: true), contact('d6', 'window', active: true)]);
      final block = s.armBlockSensors(ArmMode.away);
      expect(block.map((b) => b.id), <String>['d6'], reason: 'kapı varsayılan giriş yolu: açık olması engel değil');
    });

    test('ok=false sensör hazır değil', () {
      final s = state(<Map<String, dynamic>>[contact('d6', 'window', ok: false)]);
      expect(s.armBlockSensors(ArmMode.home).single.id, 'd6');
    });

    test('evde kipinde hareket sensörü sayılmaz (varsayılan yalnız dışarıda)', () {
      final s = state(<Map<String, dynamic>>[contact('d7', 'motion', active: true)]);
      expect(s.armBlockSensors(ArmMode.home), isEmpty);
      expect(s.armBlockSensors(ArmMode.away).single.id, 'd7');
    });

    test('yapılandırma bayrakları varsayılanı ezer (giriş yolu pencere)', () {
      final s = state(<Map<String, dynamic>>[contact('d6', 'window', active: true)])
          .withNames(sensorFlags: const <String, int>{'d6': 0x01 | 0x08});
      expect(s.armBlockSensors(ArmMode.away), isEmpty);
    });

    test('SF_REACT kapalı sensör alarm sistemine dahil değil', () {
      final s = state(<Map<String, dynamic>>[contact('d6', 'window', active: true)])
          .withNames(sensorFlags: const <String, int>{'d6': 0x00});
      expect(s.armBlockSensors(ArmMode.away), isEmpty);
    });

    test('su sensörü ve kumanda rolleri hesaba katılmaz', () {
      final s = state(const <Map<String, dynamic>>[]);
      expect(s.armBlockSensors(ArmMode.away), isEmpty);
    });
  });

  test('SensorItem.displayName: ad yoksa okunur kimlik', () {
    expect(const SensorItem(id: 'd6').displayName, 'Giriş 6');
    expect(const SensorItem(id: 'b2').displayName, 'Kablosuz sensör 2');
    expect(const SensorItem(id: 'd6', name: 'Salon penceresi').displayName, 'Salon penceresi');
  });
}
