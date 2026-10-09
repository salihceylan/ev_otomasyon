import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// Karar 3 (2026-10-09): kablolu Ethernet'te kısıt yok. Girişsiz ve anahtarsız kullanıcı yerel (LAN) modda,
/// pano anahtarsız isteği kabul ediyorsa (`GET /api/auth/check` başlıksız 200) anahtar sahibiyle aynı yerel
/// yetkileri alır ve anahtarsız çalışır. `401` gelirse eski davranış: yoklama durur, anahtar istenir.
void main() {
  Map<String, dynamic> statusBody() => <String, dynamic>{
        'device_name': 'Pano',
        'ip': '192.168.1.30',
        'wifi_connected': true,
        'uptime_sec': 100,
        'child_lock': false,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': false},
        ],
        'shutters': <Map<String, dynamic>>[],
        'dis': <Map<String, dynamic>>[],
      };
  const restrictedBody = <String, dynamic>{
    'device': 'AHBU-S3-TEST01',
    'name': 'Pano',
    'fw': '1.3.1',
    'provisioned': true,
    'wifi_connected': false,
  };

  /// Firmware ile aynı kural: başlık yoksa kısıtlı özet; Ethernet'te başlık (değeri ne olursa olsun) tam durum.
  Future<StateHarness> anonymousLan({required bool ethernet}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    h.directMock.on('GET', '/api/status', (r) {
      if (ethernet && r.headers.containsKey('X-Device-Key')) return jsonResponse(statusBody());
      return jsonResponse(restrictedBody);
    });
    h.directMock.on('GET', '/api/auth/check', (r) {
      if (ethernet) return jsonResponse(<String, dynamic>{'ok': true});
      return jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401);
    });
    await h.state.setMode(AppMode.direct);
    await h.state.setHost('192.168.1.30');
    await h.state.refresh();
    return h;
  }

  test('Ethernet: anahtarsız auth/check 200 -> yerel yetkiler + tam durum, anahtar istenmez', () async {
    final h = await anonymousLan(ethernet: true);
    addTearDown(h.dispose);

    expect(h.state.hasLocalKey, isFalse);
    expect(h.state.directKeylessAccess, isTrue);
    expect(h.state.capabilities.canControlActuators, isTrue, reason: 'anahtar sahibiyle aynı yerel yetki');
    expect(h.state.directNeedsKey, isFalse);
    expect(h.state.directError, isNull);
    expect(h.state.status, isNotNull);
    final check = h.directMock.where('GET', '/api/auth/check').first;
    expect(check.headers.containsKey('X-Device-Key'), isFalse, reason: 'yoklama anahtarsız yapılır');
  });

  test('anahtarsız auth/check 401 -> eski davranış: yetki yok, anahtar istenir', () async {
    final h = await anonymousLan(ethernet: false);
    addTearDown(h.dispose);

    expect(h.state.directKeylessAccess, isFalse);
    expect(h.state.capabilities.canControlActuators, isFalse);
    expect(h.state.directNeedsKey, isTrue);
    expect(h.state.status, isNull);
    expect(h.state.directError, contains('anahtar'));
  });

  test('anahtarsız erişim sonradan 401 alırsa düşer ve anahtar istenir', () async {
    final h = await anonymousLan(ethernet: true);
    addTearDown(h.dispose);
    expect(h.state.directKeylessAccess, isTrue);

    h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
    h.directMock.on('GET', '/api/auth/check', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
    await h.state.refresh();

    expect(h.state.directKeylessAccess, isFalse);
    expect(h.state.capabilities.canControlActuators, isFalse);
    expect(h.state.directNeedsKey, isTrue);
  });

  test('adres değişince anahtarsız erişim sıfırlanır', () async {
    final h = await anonymousLan(ethernet: true);
    addTearDown(h.dispose);
    expect(h.state.directKeylessAccess, isTrue);
    h.directMock.on('GET', '/api/auth/check', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(restrictedBody));

    await h.state.setHost('192.168.1.31');
    await h.state.refresh();

    expect(h.state.directKeylessAccess, isFalse);
    expect(h.state.capabilities.canControlActuators, isFalse);
  });
}
