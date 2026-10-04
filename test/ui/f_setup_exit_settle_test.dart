import 'dart:async';

import 'package:ev_otomasyon/ui/pages/service_setup/logic/shutter_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// PF-41 (akıcılık/kilitlenmeme, dalga 5a): panjur ölçüm **hazırlığı sürerken** sihirbazdan çıkış.
///
/// Hazırlık, panoya/sunucuya geçici 300 sn'yi yazar; önceki süre yalnız hazırlığın SONUNDA kaydediliyordu ve
/// meşgul bir `run` çıkış anındaki geri yüklemeyi sessizce atlıyordu: geri tuşu hazırlama sırasında (en çok
/// ~20 sn) basılırsa 300 sn panoda/sunucuda kalıyordu (panjur motoru her komutta 5 dakikaya kadar enerjili kalır).

void main() {
  group('PF-41: ölçüm hazırlığı sürerken çıkış (denetleyici)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.shutters);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    /// Hazırlığı başlatır ve geçici 300 sn'nin sunucuya yazıldığı (uçuşta) ana kadar ilerletir.
    Future<(Completer<void>, Future<bool>)> startPrepareInFlight() async {
      final gate = env.cloud.updateEndpointGate = Completer<void>();
      final prepare = c.shutters.prepareMeasure(1);
      await pumpEventQueue();
      expect(env.cloud.calls.where((x) => x.startsWith('updateEndpoint:')), hasLength(1),
          reason: 'geçici süre sunucuya yazılıyor (uçuşta)');
      expect(c.shutters.busy, isTrue);
      return (gate, prepare);
    }

    test('çıkış, uçuştaki hazırlığı bekler: geçici 300 sn önceki süreye (20 sn) geri yüklenir (panoda ve sunucuda)', () async {
      final (gate, prepare) = await startPrepareInFlight();

      final exit = c.settleBeforeExit(); // sayfa: "Çık" onaylandı
      gate.complete(); // sunucu isteği tamamlanır
      await drive(env, Future.wait<void>(<Future<void>>[prepare, exit]));

      expect(env.device.shutterRuntime(1), 20, reason: 'pano geçici 300 sn\'de kalmamalı');
      expect(env.cloud.endpointUpdates.last['sec'], 20, reason: 'sunucudaki kayıt da geri alındı');
      expect(c.shutters.byPair(1)!.previousSeconds, isNull);
      expect(c.shutters.byPair(1)!.phase, MeasurePhase.idle);
    });

    test('önceki süre, geçici 300 sn yazılmadan ÖNCE kayda geçer (yarım kalan hazırlık sonradan geri yüklenebilsin)', () async {
      final (gate, prepare) = await startPrepareInFlight();

      expect(c.shutters.byPair(1)!.previousSeconds, 20, reason: '300 yazımı sürerken de önceki süre biliniyor');
      expect(c.shutters.snapshot()['shutters'], <String, dynamic>{
        '1': <String, dynamic>{'dir': false, 'prev': 20},
      }, reason: 'uygulama şimdi kapanırsa kayıt önceki süreyi taşır');

      gate.complete();
      expect(await drive(env, prepare), isTrue);
      expect(c.shutters.byPair(1)!.previousSeconds, 20);
      expect(c.shutters.byPair(1)!.phase, MeasurePhase.prepared);
    });

    test('hazırlık yarıda kesilirse (sayfa kapandı) kayıt önceki süreyi taşır; devam edilince pano 20 sn\'ye döner', () async {
      final (gate, prepare) = await startPrepareInFlight();
      unawaited(prepare);

      c.dispose(); // sayfa kapandı (ör. 20 sn bekleme sınırı aşıldı ya da uygulama kapandı)
      await pumpEventQueue();
      final saved = (await env.store.list(env.access.ownerKey)).single;
      gate.complete(); // uçuştaki sunucu isteği yine de tamamlandı: pano geçici süreyi aldı
      await pumpEventQueue();
      expect(env.device.shutterRuntime(1), 300, reason: 'iptal edilen hazırlık geçici süreyi bırakmıştı');

      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      resumed.start();
      await waitUntil(env, () => resumed.shutters.loaded && !resumed.isBusy && env.device.shutterRuntime(1) == 20);
      expect(env.device.shutterRuntime(1), 20, reason: 'yarım kalan ölçümün geçici süresi devam edilirken geri yüklendi');
      expect(resumed.shutters.byPair(1)!.previousSeconds, isNull);
    });

    test('uçuştaki işlem hiç bitmezse çıkış en çok ~20 sn bekler ve sonra yine devam eder (kilitlenmez)', () async {
      final (gate, prepare) = await startPrepareInFlight();

      final started = env.clock.now();
      await drive(env, c.settleBeforeExit());
      final waited = env.clock.now().difference(started);

      expect(waited, greaterThanOrEqualTo(ServiceSetupController.exitBusyWait - const Duration(seconds: 1)),
          reason: 'önce uçuştaki işlemin bitmesi beklenir');
      expect(waited, lessThanOrEqualTo(ServiceSetupController.exitBusyWait + const Duration(seconds: 1)),
          reason: 'ama sonsuza dek değil');
      expect(c.shutters.busy, isTrue, reason: 'işlem hâlâ uçuşta (kapı kapalı)');

      gate.complete();
      expect(await drive(env, prepare), isTrue);
    });

    test('hiçbir işlem sürmüyorsa çıkış beklemez (ek gecikme yok)', () async {
      final started = env.clock.now();
      await drive(env, c.settleBeforeExit());
      expect(env.clock.now().difference(started), lessThan(const Duration(seconds: 2)));
    });
  });

  group('PF-41: ölçüm hazırlığı sürerken çıkış (arayüz)', () {
    testWidgets('onay penceresi iş sürdüğünü söyler; ikinci geri tuşu ikinci çıkış başlatmaz; hazırlık bitince pano 20 sn\'ye döner ve sihirbaz kapanır',
        (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openWizardResumedAt(
        tester,
        env,
        SetupSteps.shutters,
        data: <String, dynamic>{
          '8': <String, dynamic>{
            'shutters': <String, dynamic>{
              '1': <String, dynamic>{'dir': true},
            },
          },
        },
      );
      await pumpUntil(tester, env, () => present('btn_prepare_1'), reason: 'panjur listesi yüklenmedi');
      expect(env.device.shutterRuntime(1), 20);

      final gate = env.cloud.updateEndpointGate = Completer<void>();
      await tapKey(tester, 'btn_prepare_1');
      await pumpUntil(tester, env, () => env.cloud.calls.any((x) => x.startsWith('updateEndpoint:')),
          reason: 'geçici süre sunucuya yazılmaya başlamadı');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      await navigator.maybePop();
      await settle(tester);
      expect(find.text('Sihirbazdan çıkılsın mı?'), findsOneWidget);
      expect(find.textContaining('İlerlemeniz bu telefonda kaydedildi'), findsOneWidget);
      expect(present('exit_busy_note'), isTrue, reason: 'bir işlem sürerken çıkışın bekleyeceği söylenir');
      await tapKey(tester, 'btn_exit_confirm');
      await settle(tester);
      expect(present('setup_step_8'), isTrue, reason: 'hazırlık sürerken sayfa kapanmaz: önce pano güvenli duruma gelir');

      await navigator.maybePop();
      await settle(tester);
      expect(find.text('Sihirbazdan çıkılsın mı?'), findsNothing, reason: 'çıkış sürerken ikinci onay/çıkış başlatılmaz');

      gate.complete();
      await pumpUntil(tester, env, () => !present('setup_step_8'), reason: 'sihirbaz kapanmadı');
      expect(present('launcher'), isTrue, reason: 'yalnız sihirbaz kapandı (çift çıkış başlatıcıyı da kapatmaz)');
      expect(env.device.shutterRuntime(1), 20, reason: 'çıkışta geçici 300 sn geri yüklendi');
      expect(env.cloud.endpointUpdates.last['sec'], 20);
    });
  });
}
