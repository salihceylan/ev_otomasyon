import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// KİLİT testi (PF-04, LAN yarısı): cihaz her yoklamada AYNI `/api/status` yanıtını veriyorsa
/// `AutomationState` bildirim ÜRETMEZ (1,5 sn'lik yoklamada tüm arayüz yeniden çizilmesin). Bu davranış
/// bugün vardır (`_directRefreshImpl` değişim-koşullu bildirir); test onun geri bozulmasını yakalar.
/// Yoklama durdurma / geri çekilme (PF-01) davranışı BU testin konusu değildir.
void main() {
  Map<String, dynamic> statusBody({bool r3 = false}) => <String, dynamic>{
        'device_name': 'Pano',
        'ip': '192.168.1.30',
        'wifi_connected': true,
        'child_lock': false,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 1, 'state': false},
          <String, dynamic>{'id': 2, 'name': 'Avize Aşağı', 'type': 2, 'state': false},
          <String, dynamic>{'id': 3, 'name': 'Mutfak', 'type': 0, 'state': r3},
          <String, dynamic>{'id': 4, 'name': 'Spot', 'type': 0, 'state': false},
        ],
        'shutters': <Map<String, dynamic>>[
          <String, dynamic>{'pair': 1, 'pos': 20, 'is_moving': false, 'dir': 0, 'target': 255},
        ],
        'dis': <Map<String, dynamic>>[],
      };

  /// Doğrudan (LAN) mod, anahtar tanımlı, ilk durum alınmış (1,5 sn'lik periyodik yoklama çalışıyor).
  Future<StateHarness> directHarness() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    h.state.setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'));
    h.state.setAuthStatusForTesting(AuthStatus.authenticated);
    h.state.setHomesForTesting(<HomeModel>[testHome()]);
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody()));
    await h.state.setMode(AppMode.direct);
    await h.state.setHost('192.168.1.30');
    h.direct.localKey = 'devicekey-1234';
    await h.state.refresh();
    return h;
  }

  test('aynı /api/status yanıtı: 15 sn boyunca (yoklama çalışırken) HİÇ bildirim üretilmez', () async {
    final h = await directHarness();
    addTearDown(h.dispose);
    expect(h.state.connState, ConnectionStateEnum.connected);
    expect(h.state.status, isNotNull);

    var notifications = 0;
    h.state.addListener(() => notifications++);
    h.directMock.requests.clear();

    await h.clock.elapse(const Duration(seconds: 15));

    final polls = h.directMock.count('GET', '/api/status');
    expect(polls, greaterThanOrEqualTo(9), reason: 'yoklama gerçekten çalıştı (kilit boş geçmesin): 15 sn / 1,5 sn ≈ 10 istek');
    expect(notifications, 0, reason: 'değişmeyen durum bildirim üretmemeli ($polls yoklama)');
    expect(h.state.connState, ConnectionStateEnum.connected);
  });

  test('pozitif kontrol: yanıt DEĞİŞİNCE bildirim gelir; sonra aynı yanıt yine sessizdir', () async {
    final h = await directHarness();
    addTearDown(h.dispose);
    var notifications = 0;
    h.state.addListener(() => notifications++);

    h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody(r3: true)));
    await h.clock.elapse(const Duration(seconds: 3));
    expect(notifications, greaterThanOrEqualTo(1), reason: 'röle 3 açıldı: yoklama bunu bildirmeli');
    expect(h.state.status!.relayById(3)!.state, isTrue);

    final afterChange = notifications;
    await h.clock.elapse(const Duration(seconds: 15));
    expect(notifications, afterChange, reason: 'durum yeniden sabitlendi: yeni bildirim yok');
  });
}
