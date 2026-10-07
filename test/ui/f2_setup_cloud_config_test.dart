import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// Faz 2 WP-C3 (tasarım F2.D.5): sihirbazın bulut yapılandırma yazım yolu. LAN önceliklidir (K5); LAN gevşetme
/// reddinde (`403 local_loosen_forbidden`) bulut önerilir; LAN'a ulaşılamıyorsa bulut kullanılır; çevrimdışı panoda
/// yamalar kuyruğa alınır ve adım tamamlanmaz; `409 CONFIG_CHANGED_ON_DEVICE` sonrası plan yeniden hesaplanıp bir kez
/// daha denenir.
void main() {
  Future<ServiceHarness> open(WidgetTester tester) async {
    final env = await serviceHarness(flush: () async {});
    addTearDown(env.dispose);
    env.device.safetyCaps = true;
    env.cloud.safetyConfigHandler = (home, device) async => <String, dynamic>{
          'rev': env.device.safetyRev,
          'state_rev': env.device.safetyRev,
          'next_base_rev': env.device.safetyRev,
          ...?env.device.savedSafetyConfig,
        };
    await openWizardResumedAt(tester, env, SetupSteps.relays, size: const Size(900, 6000));
    await pumpUntil(tester, env, () => present('card_relay_5'), reason: 'röle listesi yüklenmedi');
    return env;
  }

  Finder inKey(String key, Finder matching) => find.descendant(of: find.byKey(Key(key)), matching: matching);

  testWidgets('LAN gevşetme reddi -> bulut önerisi; vazgeç: bulut yaması yok; onay: bulut taşımasıyla yazılır', (tester) async {
    final env = await open(tester);
    env.device.loosenForbidden = true;
    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_cloud_offer_cancel'), reason: 'bulut önerisi gelmedi');
    expect(find.textContaining('Bu değişiklik güvenliği azaltır ve yerel ağdan yapılamaz.'), findsOneWidget);
    await tapKey(tester, 'btn_cloud_offer_cancel');
    expect(env.cloud.patchCalls, isEmpty);

    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_cloud_offer_confirm'), reason: 'bulut önerisi gelmedi');
    await tapKey(tester, 'btn_cloud_offer_confirm');
    await pumpUntil(tester, env, () => present('safety_test_result_1'), reason: 'bulut yazımı/testi bitmedi');
    expect(env.cloud.patchCalls, isNotEmpty);
    expect(env.cloud.patchCalls.first.baseRev, env.device.safetyRev);
    expect(env.cloud.alarmTestCalls.single.zone, 1);
    expect(
      inKey('safety_test_result_1', find.textContaining('Geri bildirim sonucu yalnız yerel bağlantıda görünür')),
      findsOneWidget,
    );
    expect(buttonEnabled(tester, 'btn_save_safety'), isFalse, reason: 'panoya yazıldı: değişiklik kalmadı');
  });

  testWidgets('LAN\'a ulaşılamıyor -> bulut kullanılır', (tester) async {
    final env = await open(tester);
    await tapKey(tester, 'chip_use_7_siren');
    env.device.lanReachable = false;
    env.device.apReachable = false;
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => env.cloud.patchCalls.isNotEmpty, reason: 'bulut yolu seçilmedi');
  });

  testWidgets('pano çevrimdışı -> kuyruk notu, adım tamamlanmaz, "Kuyruğu iptal et"', (tester) async {
    final env = await open(tester);
    env.device.loosenForbidden = true;
    env.cloud.patchHandler = (call) async => <String, dynamic>{
          'queued': true,
          'position': env.cloud.patchCalls.length,
          'expires_at': '2026-10-08T03:00:00Z',
          'command_id': call.commandId,
        };
    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_cloud_offer_confirm'));
    await tapKey(tester, 'btn_cloud_offer_confirm');
    await pumpUntil(tester, env, () => present('safety_queue_note'), reason: 'kuyruk notu yok');
    expect(
      inKey('safety_queue_note', find.textContaining('Pano çevrimdışı. Değişiklikler pano bağlanınca (24 saat içinde) uygulanacak.')),
      findsOneWidget,
    );
    expect(find.text('Panoya yazılmadı'), findsOneWidget, reason: 'adım tamamlanmış sayılmaz');
    await tapKey(tester, 'btn_cancel_safety_queue');
    await pumpUntil(tester, env, () => env.cloud.pendingCleared == 1, reason: 'kuyruk iptal edilmedi');
    await pumpUntil(tester, env, () => !present('safety_queue_note'));
  });

  testWidgets('409 CONFIG_CHANGED_ON_DEVICE -> kopya beklenir, plan yeniden hesaplanır, bir kez yeniden denenir', (tester) async {
    final env = await open(tester);
    env.device.loosenForbidden = true;
    var first = true;
    env.cloud.patchHandler = (call) async {
      if (first) {
        first = false;
        env.device.safetyRev += 2; // panoda yerel değişiklik oldu
        throw ApiException(
          statusCode: 409,
          code: 'CONFIG_CHANGED_ON_DEVICE',
          message: ApiException.clientMessages['CONFIG_CHANGED_ON_DEVICE']!,
          details: <String, dynamic>{
            'data': <String, dynamic>{'rev': env.device.safetyRev},
          },
        );
      }
      return <String, dynamic>{'applied': true, 'rev': call.baseRev + 1, 'command_id': call.commandId};
    };
    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_cloud_offer_confirm'));
    await tapKey(tester, 'btn_cloud_offer_confirm');
    await pumpUntil(tester, env, () => present('safety_test_result_1'), reason: 'yeniden deneme başarılı olmadı');
    expect(env.cloud.patchCalls.first.baseRev, env.device.safetyRev - 2);
    expect(env.cloud.patchCalls[1].baseRev, env.device.safetyRev, reason: 'yeni kopyanın rev\'iyle yeniden denendi');
  });

  // Faz 2 incelemesi R3: çakışma sonrası kopya, 409'daki rev'e ulaşsa da panonun son bildirdiği rev'den (state_rev) geride
  // olabilir. Plan bayat kopyadan hesaplanıp daha yeni bir base_rev ile gönderilmez: kopya state_rev'e ulaşana kadar beklenir ve
  // yama kopyanın rev'iyle gider.
  testWidgets('409 sonrası kopya state_rev\'e ulaşana kadar beklenir; base_rev planın hesaplandığı kopyanın rev\'i (R3)', (tester) async {
    final env = await open(tester);
    env.device.loosenForbidden = true;
    final base = env.device.safetyRev;
    var conflicted = false;
    var copyRev = base;
    var stateRev = base;
    var readsAfterConflict = 0;
    env.cloud.safetyConfigHandler = (home, device) async {
      if (conflicted && ++readsAfterConflict >= 3) copyRev = stateRev; // kopya birkaç okuma sonra yetişir
      return <String, dynamic>{
        'rev': copyRev,
        'state_rev': stateRev,
        'next_base_rev': stateRev,
        ...?env.device.savedSafetyConfig,
      };
    };
    final copyAtPatch = <int>[];
    env.cloud.patchHandler = (call) async {
      copyAtPatch.add(copyRev);
      if (!conflicted) {
        conflicted = true;
        copyRev = base + 1; // 409 verisindeki rev'e (bayat) ulaşmış kopya
        stateRev = base + 2; // pano iki kez değişti
        throw ApiException(
          statusCode: 409,
          code: 'CONFIG_CHANGED_ON_DEVICE',
          message: ApiException.clientMessages['CONFIG_CHANGED_ON_DEVICE']!,
          details: <String, dynamic>{
            'data': <String, dynamic>{'rev': base + 1},
          },
        );
      }
      return <String, dynamic>{'applied': true, 'rev': call.baseRev + 1, 'command_id': call.commandId};
    };
    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_cloud_offer_confirm'));
    await tapKey(tester, 'btn_cloud_offer_confirm');
    await pumpUntil(tester, env, () => present('safety_test_result_1'), reason: 'yeniden deneme başarılı olmadı');
    expect(env.cloud.patchCalls[1].baseRev, base + 2);
    expect(copyAtPatch[1], base + 2, reason: 'plan güncel kopyadan hesaplandı (bayat kopya + yeni base_rev değil)');
  });
}
