import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// guvenlik-4 arayüzü: bulut kuyruğunda bekleyen değişiklik varken "Panoya Yaz" yeni planı kuyruğa EKLEMEZ; onay
/// penceresi sorar ("Bekleyen N değişiklik iptal edilip plan baştan sıraya alınsın mı?"); onayda kuyruk silinip plan
/// baştan gönderilir, vazgeçte hiçbir şey gönderilmez.
void main() {
  testWidgets('kuyruk varken kayıt: onay sorulur; vazgeç -> yama yok; onay -> kuyruk silinir, plan baştan gönderilir',
      (tester) async {
    final env = await serviceHarness(flush: () async {});
    addTearDown(env.dispose);
    env.device.safetyCaps = true;
    var pending = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'p1', 'op': 'del', 'item': 'actuator', 'target': 'a2'},
    ];
    env.cloud.safetyConfigHandler = (home, device) async => <String, dynamic>{
          'rev': env.device.safetyRev,
          'state_rev': env.device.safetyRev,
          'pending': pending,
          ...?env.device.savedSafetyConfig,
        };
    env.cloud.onPendingCleared = () => pending = <Map<String, dynamic>>[];
    await openWizardResumedAt(tester, env, SetupSteps.relays, size: const Size(900, 6000));
    await pumpUntil(tester, env, () => present('card_relay_5'), reason: 'röle listesi yüklenmedi');
    env.device
      ..lanReachable = false
      ..apReachable = false; // pano yerel ağdan erişilemez: bulut yolu

    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_queue_replace_cancel'), reason: 'onay penceresi gelmedi');
    expect(find.text('Bekleyen 1 değişiklik iptal edilip plan baştan sıraya alınsın mı?'), findsOneWidget);
    await tapKey(tester, 'btn_queue_replace_cancel');
    await tester.pump();
    expect(env.cloud.patchCalls, isEmpty);
    expect(env.cloud.pendingCleared, 0);

    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('btn_queue_replace_confirm'));
    await tapKey(tester, 'btn_queue_replace_confirm');
    await pumpUntil(tester, env, () => env.cloud.patchCalls.isNotEmpty, reason: 'plan gönderilmedi');
    expect(env.cloud.pendingCleared, 1);
    expect(env.cloud.patchCalls.first.baseRev, env.device.safetyRev);
  });
}
