import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// M4-01 (SERVIS-01 bilinen sınırı): sunucu bekleyen yerel anahtarı panoya 6. adım BİTTİKTEN sonra iletip takas ederse
/// 7. adımın ilk LAN çağrısı eldeki eski anahtarla 401 alır. `SetupContext.deviceCall` 401'i kaydeder (bağlantı düşer,
/// reddedilen anahtar hedeften silinir) ve TEK kez kendiliğinden yeniden dener: `ensureDeviceReady` sunucudan taze
/// anahtarı alır. Firmware anahtarı komuttan önce denetlediği için 401 komutun uygulanmadığı anlamına gelir; yeniden
/// deneme güvenlidir. Sunucu hâlâ reddedilen anahtarı verirse ikinci yanlış deneme panoya GİTMEZ.
void main() {
  test('takas 6. adımdan sonra: 7. adımın ilk komutu kendiliğinden kurtarılır (tek yanlış deneme, sunucuya +1 anahtar '
      'isteği)', () async {
    final env = await serviceHarness();
    addTearDown(env.dispose);
    final c = await reachStep(env, SetupSteps.relays);
    await waitUntil(env, () => c.relays.loaded && !c.isBusy);

    // Uzlaştırıcı bekleyen anahtarı panoya iletti ve sunucuda takas etti.
    const fresh = 'yeni-anahtar-K2-1234';
    env.device.localKey = fresh;
    env.cloud.localKeyValue = fresh;
    final keyCalls = env.cloud.calls.where((x) => x.startsWith('localKey')).length;
    final wrongBefore = env.device.wrongKeyTotal;

    final id = c.relays.relays.first.id;
    final ok = await drive(env, c.relays.command(id, true));

    expect(ok, isTrue, reason: 'ilk komut kullanıcıya sorun göstermeden tamamlanır');
    expect(c.relays.problem, isNull);
    expect(env.device.wrongKeyTotal - wrongBefore, 1, reason: 'eski anahtarla yalnız bir yanlış deneme');
    expect(env.cloud.calls.where((x) => x.startsWith('localKey')).length, keyCalls + 1,
        reason: 'taze anahtar sunucudan bir kez alındı');
    expect(c.target!.localKey, fresh);
  });

  test('sunucu hâlâ reddedilen anahtarı verirse yeniden deneme panoya ikinci yanlış anahtar GÖNDERMEZ', () async {
    final env = await serviceHarness();
    addTearDown(env.dispose);
    final c = await reachStep(env, SetupSteps.relays);
    await waitUntil(env, () => c.relays.loaded && !c.isBusy);

    env.device.localKey = 'baska-anahtar-K9-5678'; // sunucu bunu bilmiyor (localKeyValue eski K1)
    final wrongBefore = env.device.wrongKeyTotal;

    final id = c.relays.relays.first.id;
    expect(await drive(env, c.relays.command(id, true)), isFalse);

    expect(c.relays.problem!.title, 'Pano cihaz anahtarını kabul etmedi');
    expect(env.device.wrongKeyTotal - wrongBefore, 1, reason: 'aynı reddedilen anahtar ikinci kez gönderilmedi');
  });
}
