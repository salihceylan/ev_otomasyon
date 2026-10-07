import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

/// Güvenlik yetenekleri (tasarım §5.2.4 rol matrisi; 7.2b karar 4):
/// * `actuator_close` (vanayı kapat / sireni sustur): misafir DAHİL herkes.
/// * `safety_ack`, `actuator_control` (su vanası açma, siren/fan açma): super, staff, session, owner, resident.
/// * `safety_test`: super, staff, session, owner.
void main() {
  final now = DateTime.utc(2026, 10, 6, 12);
  Capabilities caps(String global, String? home, {bool guestValid = true}) => Capabilities(
        globalRole: global,
        homeRole: home,
        guestValidUntil: home == 'guest' ? (guestValid ? now.add(const Duration(days: 1)) : now.subtract(const Duration(days: 1))) : null,
        now: now,
        hasActiveHome: true,
      );

  final matrix = <String, ({String g, String? h, bool close, bool ack, bool control, bool test})>{
    'owner': (g: 'user', h: 'owner', close: true, ack: true, control: true, test: true),
    'resident': (g: 'user', h: 'resident', close: true, ack: true, control: true, test: false),
    'guest': (g: 'user', h: 'guest', close: true, ack: false, control: false, test: false),
    'service_user (ev)': (g: 'service_user', h: 'service_user', close: true, ack: true, control: true, test: true),
    'service_session': (g: 'service_session', h: 'service_session', close: true, ack: true, control: true, test: true),
    'super_user': (g: 'super_user', h: null, close: true, ack: true, control: true, test: true),
  };

  for (final entry in matrix.entries) {
    test('rol matrisi: ${entry.key}', () {
      final r = entry.value;
      final c = caps(r.g, r.h);
      expect(c.canCloseActuators, r.close, reason: 'canCloseActuators');
      expect(c.canAckAlarm, r.ack, reason: 'canAckAlarm');
      expect(c.canControlActuators, r.control, reason: 'canControlActuators');
      expect(c.canTestSafety, r.test, reason: 'canTestSafety');
    });
  }

  test('süresi dolmuş misafir ve oturumsuz: hiçbir güvenlik yetkisi yok', () {
    for (final c in <Capabilities>[caps('user', 'guest', guestValid: false), const Capabilities.none()]) {
      expect(c.canCloseActuators, isFalse);
      expect(c.canAckAlarm, isFalse);
      expect(c.canControlActuators, isFalse);
      expect(c.canTestSafety, isFalse);
    }
  });

  test('yerel anahtar sahibi (LAN, resident düzeyi): kapat/onay/kontrol var, test yok', () {
    const c = Capabilities.localKeyHolder();
    expect(c.canCloseActuators, isTrue);
    expect(c.canAckAlarm, isTrue);
    expect(c.canControlActuators, isTrue);
    expect(c.canTestSafety, isFalse);
  });

  test('toMap yeni bayrakları içerir; eşitlik yeni bayrakları ayırt eder', () {
    final owner = caps('user', 'owner');
    final resident = caps('user', 'resident');
    expect(owner.toMap().keys, containsAll(<String>['canCloseActuators', 'canAckAlarm', 'canControlActuators', 'canTestSafety']));
    expect(owner == caps('user', 'owner'), isTrue);
    expect(owner == resident, isFalse);
  });
}
