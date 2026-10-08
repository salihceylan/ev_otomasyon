import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// pano-6: sunucu yerel anahtarı döndürdükten sonra (devir, üye çıkarma, servis oturumu sonu ...) internet kesilirse yerel
/// kip bayat anahtarla kalmasın: bulut kipinde ev yüklenince güvenli depodaki anahtar, cihaz başına en çok 12 saatte bir
/// sunucudan önden tazelenir. Hatalar yutulur; anahtar yetkisi olmayan rolde (misafir) istek yoktur.
void main() {
  const uid = 'AHBU-S3-TEST01';

  test('depodaki anahtar 12 saatte bir tazelenir; hata yutulur ve anahtar korunur', () async {
    final h = await readyHarness();
    addTearDown(h.dispose);
    await h.storage.saveLocalKey(uid, 'eski-anahtar-1');
    h.cloud.localKeyValue = 'yeni-anahtar-1';

    await h.state.fetchHomes(autoSelect: false);
    await pumpEventQueue(times: 40);
    expect(h.cloud.count('localKey'), 1);
    expect(h.cloud.localKeyHomeIds.last, kHomeA);
    expect(await h.storage.getLocalKey(uid), 'yeni-anahtar-1');

    await h.state.fetchHomes(autoSelect: false);
    await h.state.selectHome(h.state.homeById(kHomeA)!);
    await pumpEventQueue(times: 40);
    expect(h.cloud.count('localKey'), 1, reason: '12 saat dolmadan yeniden istenmez');

    await h.clock.elapse(const Duration(hours: 13));
    h.cloud.localKeyError = ApiException.network();
    await h.state.fetchHomes(autoSelect: false);
    await pumpEventQueue(times: 40);
    expect(h.cloud.count('localKey'), 2);
    expect(await h.storage.getLocalKey(uid), 'yeni-anahtar-1', reason: 'hata yutulur; depodaki anahtar korunur');
  });

  test('depoda anahtar yoksa istek yok (yalnız daha önce yerel kip kullanılmış panolar)', () async {
    final h = await readyHarness();
    addTearDown(h.dispose);
    await h.state.fetchHomes(autoSelect: false);
    await pumpEventQueue(times: 40);
    expect(h.cloud.count('localKey'), 0);
  });

  test('misafirde (yerel anahtar yetkisi yok) çağrılmaz', () async {
    final h = await readyHarness(
      home: HomeModel(
        id: kHomeA,
        name: 'Misafir Evi',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
        guestValidUntil: kTestNow.add(const Duration(hours: 5)),
      ),
    );
    addTearDown(h.dispose);
    await h.storage.saveLocalKey(uid, 'eski-anahtar-1');
    await h.state.fetchHomes(autoSelect: false);
    await pumpEventQueue(times: 40);
    expect(h.cloud.count('localKey'), 0);
  });
}
