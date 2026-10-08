import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// uyelik-3 (AutomationState tarafı): yenilenen belirteçlerin kalıcı yazımı başarısız olursa bu, API istemcisine
/// BİLDİRİLİR (yenileme yine başarılı; istemci depodaki eski token'ı benimsemez) ve depolama kuyruğu kopmaz. Giriş /
/// parola değişimi yazımları gerçekten bitince istemciye bildirilir (`markRefreshPersisted`).
void main() {
  test('_onTokenRefreshed yazım hatasında hatayla biter (storageError gösterilir); kuyruk sonraki yazımları sürdürür',
      () async {
    final h = await readyHarness();
    addTearDown(h.dispose);
    final callback = h.cloud.onTokenRefreshed!;

    h.storage.memory.failWrites = true;
    await expectLater(Future<void>.sync(() => callback('access-2', 'refresh-2')), throwsA(anything));
    expect(h.state.storageError, isNotNull);

    h.storage.memory.failWrites = false;
    await Future<void>.sync(() => callback('access-3', 'refresh-3'));
    expect(await h.storage.getRefreshToken(), 'refresh-3');
    expect(await h.storage.getAuthToken(), 'access-3');
  });

  test('giriş yazımı bitince API istemcisi depodaki token\'ı bilir; yazım başarısızsa bilmez', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ok = StateHarness();
    addTearDown(ok.dispose);
    ok.cloud.homes = const [];
    await ok.state.login('a@b.c', 'parola-1234');
    await pumpEventQueue(times: 40);
    expect(ok.cloud.storedRefreshKnown, isTrue);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final failing = StateHarness();
    addTearDown(failing.dispose);
    failing.cloud.homes = const [];
    failing.storage.memory.failWrites = true;
    await failing.state.login('a@b.c', 'parola-1234');
    await pumpEventQueue(times: 40);
    expect(failing.state.storageError, isNotNull);
    expect(failing.cloud.storedRefreshKnown, isFalse, reason: 'yazılamayan token depoda sanılmaz');
  });

  test('parola değişimi yazımı bitince istemci yeni token\'ı depoda bilir', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    addTearDown(h.dispose);
    h.cloud.homes = const [];
    await h.state.login('a@b.c', 'parola-1234');
    await pumpEventQueue(times: 40);
    await h.state.changePassword(currentPassword: 'parola-1234', newPassword: 'yeni-parola-99');
    await pumpEventQueue(times: 40);
    expect(h.cloud.storedRefreshKnown, isTrue);
    expect(await h.storage.getRefreshToken(), h.cloud.currentRefreshToken);
  });
}
