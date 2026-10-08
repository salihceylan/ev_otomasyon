import 'dart:convert';

import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/relay_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/safety_config_transport.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart' show FakeCloudApi, FakeClock, kHomeA;
import 'f_flow_support.dart';
import 'f_support.dart';

/// 7. adım düzeltmeleri (2026-10-08):
///
/// * servis_kurulum-2: başarısız vana / bölge testi kayda yazılır; kayıttan devamda adım tamamlanmış sayılmaz; yalnız
///   başarısız bölgeler yeniden test edilir; eylemci testi geri bildirim hatasında gözle onayı açmaz.
/// * servis_kurulum-6: yalnız panjur rölesi olan pano 7. adımı tamamlar; teslim ayrıntısı doğru.
/// * guvenlik-4: çevrimdışı panoda bulut kuyruğu bayat plana eklenmez; 16 sınırı; zincir ortasında hata kısmi kuyruğu
///   geri alır; çakışmada kullanıcıya "iptal + yeniden gönder" sunulur.
void main() {
  const valve = ChannelAssignment(
    use: ChannelUse.valve,
    closeMode: ValveCloseMode.deenergizeToClose,
    medium: 'water',
  );

  late ServiceHarness env;
  late ServiceSetupController c;

  Future<void> atRelays({bool safety = true}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    env = await serviceHarness();
    env.device.safetyCaps = safety;
    c = await reachStep(env, SetupSteps.relays);
    await waitUntil(env, () => c.relays.loaded && !c.isBusy);
  }

  Future<void> verifyRelays() async {
    for (final r in List<RelayCheck>.of(c.relays.relays)) {
      expect(await drive(env, c.relays.command(r.id, true)), isTrue);
      c.relays.confirmLit(r.id, true);
      expect(await drive(env, c.relays.command(r.id, false)), isTrue);
    }
  }

  /// Panoda ZATEN tanımlı, geri bildirimli (`fb_di` 3) su vanası: röle 7, bölge 1 (yapılandırma kopyasında; [fbTimeoutS]
  /// verilirse `fb_timeout_s`).
  Future<void> atBoardFeedbackValve({int? fbTimeoutS}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    env = await serviceHarness();
    env.device
      ..safetyCaps = true
      ..relayAct[7] = 'valve'
      ..boardActuators.add(<String, dynamic>{
        'id': 'a1',
        'relay': 7,
        'kind': 'valve',
        'medium': 'water',
        'zones': <int>[1],
        'pos': 'open',
        'fb': false,
      })
      ..savedSafetyConfig = <String, dynamic>{
        'actuators': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'a1',
            'relay': 7,
            'kind': 'valve',
            'medium': 'water',
            'close_mode': 'deenergize',
            'zones': <int>[1],
            'fb_di': 3,
            'fb_closed_active': 1,
            'fb_timeout_s': ?fbTimeoutS,
          },
        ],
      };
    c = await reachStep(env, SetupSteps.relays);
    await waitUntil(env, () => c.relays.loaded && !c.isBusy);
  }

  group('servis_kurulum-2: başarısız bölge testi', () {
    tearDown(() => env.dispose());

    test('başarısızlık kayda yazılır; geri yüklenince adım tamamlanmaz; yeniden test başarılıysa tamamlanır', () async {
      await atRelays();
      await verifyRelays();
      c.relays.setAssignment(5, valve.copyWith(fbDi: 3));
      env.device.testResultOk = false;
      final started = env.clock.now();
      expect(await drive(env, c.relays.saveSafety()), isFalse);
      expect(env.clock.now().difference(started), greaterThanOrEqualTo(const Duration(seconds: 60)),
          reason: '"kapanmadı" sonucu firmware\'de fb_timeout_s (varsayılan 60 sn) dolunca gelir; sihirbaz bekler');
      expect(c.relays.problem!.title, 'Vana testte kapanmadı');
      expect(c.relays.isComplete, isFalse);
      final snap = jsonDecode(jsonEncode(c.relays.snapshot())) as Map<String, dynamic>;
      expect(snap['safety_failed'], <int>[1]);

      final restored = RelayLogic(c.relays.ctx)..restore(snap);
      expect(await drive(env, restored.load()), isTrue);
      expect(restored.testResults.single.failed, isTrue);
      expect(restored.isComplete, isFalse, reason: 'kayıttan devamda başarısız test adımı tamamlatmaz');
      expect(restored.canSaveSafety, isTrue, reason: 'başarısız test yeniden kaydı/testi açar');

      env.device.testResultOk = true;
      final before = env.device.alarmTests.length;
      expect(await drive(env, restored.retestFailedZones()), isTrue);
      expect(env.device.alarmTests.length, before + 1, reason: 'yalnız başarısız bölge test edildi');
      expect(restored.testResults.single.failed, isFalse);
      for (final r in List<RelayCheck>.of(restored.relays)) {
        if (r.verdict != RelayVerdict.ok) restored.setUnused(r.id, true);
      }
      expect(restored.isComplete, isTrue);
    });

    test('eylemci testi geri bildirim hatasında röleyi sorunlu yapar ve gözle onayı açmaz', () async {
      await atBoardFeedbackValve();
      env.device.testResultOk = false;

      expect(await drive(env, c.relays.testActuator(7)), isFalse);
      final r7 = c.relays.byId(7)!;
      expect(r7.verdict, RelayVerdict.problem);
      expect(r7.awaitingLitAnswer, isFalse, reason: 'geri bildirim "kapanmadı" dedi: gözle onay sorulmaz');
      expect(r7.note, 'Bölge testinde vana kapanmadı (geri bildirim)');
      expect(c.relays.testResults.single.failed, isTrue);
      expect(c.relays.isComplete, isFalse);
    });
  });

  group('servis_kurulum-2 (zamanlama): geri bildirimli vananın sonucu fb_timeout_s dolunca gelir', () {
    test('SafetyTestResult: yalnız GERİ BİLDİRİMLİ vananın sonuçsuz testi "doğrulanmadı"dır', () {
      const unconfirmed = SafetyTestResult(zone: 2, hasFeedback: true);
      expect(unconfirmed.unconfirmed, isTrue);
      expect(unconfirmed.failed, isTrue);
      expect(unconfirmed.message, contains('geri bildirim sonucu süre içinde alınamadı'));
      const noFeedback = SafetyTestResult(zone: 2);
      expect(noFeedback.unconfirmed, isFalse);
      expect(noFeedback.failed, isFalse);
      expect(noFeedback.message, contains('Geri bildirim yok'));
      const cloud = SafetyTestResult(zone: 2, hasFeedback: true, cloud: true);
      expect(cloud.unconfirmed, isFalse, reason: 'bulut testinin sonucu zaten okunmaz (karar F2-10)');
      const closed = SafetyTestResult(zone: 2, ok: true, fbMs: 4200, hasFeedback: true);
      expect(closed.failed, isFalse);
    });
  });

  group('servis_kurulum-2 (zamanlama): geri bildirimli vana ile adım akışı', () {
    tearDown(() => env.dispose());

    test('yapılandırma kopyasındaki fb_timeout_s (90 sn) + pay beklenir: kapanmayan vana başarısız sayılır', () async {
      await atBoardFeedbackValve(fbTimeoutS: 90);
      env.device.testResultOk = false;
      final started = env.clock.now();

      expect(await drive(env, c.relays.testActuator(7)), isFalse);
      expect(env.clock.now().difference(started), greaterThanOrEqualTo(const Duration(seconds: 90)));
      expect(c.relays.problem!.title, 'Vana testte kapanmadı');
      expect(c.relays.byId(7)!.verdict, RelayVerdict.problem);
      expect(c.relays.testResults.single.failed, isTrue);
    });

    test('sonuç hiç gelmezse (okunamadı): gözle onay AÇILMAZ, röle doğrulanmış sayılmaz, "sonuç alınamadı" sorunu', () async {
      await atBoardFeedbackValve();
      env.device.testResultDelay = const Duration(hours: 1);
      final started = env.clock.now();

      expect(await drive(env, c.relays.testActuator(7)), isFalse);
      final waited = env.clock.now().difference(started);
      expect(waited, greaterThanOrEqualTo(const Duration(seconds: 60)), reason: 'geri bildirim süresi beklendi');
      expect(waited, lessThan(const Duration(seconds: 75)), reason: 'süre + birkaç sn pay; sonsuz beklenmez');
      expect(c.relays.problem!.title, 'Vana test sonucu alınamadı');
      final r7 = c.relays.byId(7)!;
      expect(r7.awaitingLitAnswer, isFalse, reason: '"Geri bildirim yok, gözle doğrulayın" başarı yolu gösterilmez');
      expect(r7.verdict, isNot(RelayVerdict.ok));
      final result = c.relays.testResults.single;
      expect(result.unconfirmed, isTrue);
      expect(result.failed, isTrue, reason: 'doğrulanmamış geri bildirimli vana testi geçmiş sayılmaz');
      expect(result.message, isNot(contains('Geri bildirim yok')));
      expect(c.relays.isComplete, isFalse);
    });

    test('yeniden testte vana hâlâ takılıysa (60 sn sonra "kapanmadı") bölge başarısız kalır; yanlış geçiş yok', () async {
      await atRelays();
      await verifyRelays();
      c.relays.setAssignment(5, valve.copyWith(fbDi: 3));
      env.device.testResultOk = false;
      expect(await drive(env, c.relays.saveSafety()), isFalse);
      expect(c.relays.testResults.single.failed, isTrue);

      expect(await drive(env, c.relays.retestFailedZones()), isFalse);
      expect(c.relays.problem!.title, 'Vana testte kapanmadı');
      expect(c.relays.testResults.single.failed, isTrue);
      expect(c.relays.isComplete, isFalse);
    });

    test('yeniden testte sonuç hiç gelmezse önceki başarısızlık SİLİNMEZ', () async {
      await atRelays();
      await verifyRelays();
      c.relays.setAssignment(5, valve.copyWith(fbDi: 3));
      env.device.testResultOk = false;
      expect(await drive(env, c.relays.saveSafety()), isFalse);

      env.device.testResultDelay = const Duration(hours: 1);
      expect(await drive(env, c.relays.retestFailedZones()), isFalse);
      expect(c.relays.problem!.title, 'Vana test sonucu alınamadı');
      final result = c.relays.testResults.single;
      expect(result.ok, isFalse, reason: 'sonuçsuz yeniden test son kesin sonucu (kapanmadı) silmez');
      expect(c.relays.isComplete, isFalse);
      final snap = jsonDecode(jsonEncode(c.relays.snapshot())) as Map<String, dynamic>;
      expect(snap['safety_failed'], <int>[1]);
    });

    test('sonuçsuz test kayda "doğrulanmadı" olarak yazılır; geri yüklenince adım tamamlanmaz, yeniden test sunulur',
        () async {
      await atBoardFeedbackValve();
      env.device.testResultDelay = const Duration(hours: 1);
      expect(await drive(env, c.relays.testActuator(7)), isFalse);
      final snap = jsonDecode(jsonEncode(c.relays.snapshot())) as Map<String, dynamic>;
      expect(snap['safety_unconfirmed'], <int>[1]);
      expect(snap.containsKey('safety_failed'), isFalse);

      final restored = RelayLogic(c.relays.ctx)..restore(snap);
      expect(await drive(env, restored.load()), isTrue);
      expect(restored.testResults.single.unconfirmed, isTrue);
      expect(restored.isComplete, isFalse);
      expect(restored.canSaveSafety, isTrue);

      env.device.testResultDelay = null; // vana kapanıyor: başarılı sonuç hemen gelir
      expect(await drive(env, restored.retestFailedZones()), isTrue);
      expect(restored.testResults.single.failed, isFalse);
    });

    test('uzun beklemede ilerleme metni ne beklendiğini söyler (geri bildirimli vana: en çok fb_timeout_s + 5 sn)', () async {
      await atBoardFeedbackValve();
      env.device.testResultDelay = const Duration(seconds: 30); // vana 30 sn'de kapanır
      final action = c.relays.testActuator(7);
      await waitUntil(env, () => c.relays.busyLabel?.contains('kapanması bekleniyor') ?? false);
      expect(c.relays.busyLabel, 'Bölge 1: vananın kapanması bekleniyor (en çok 65 sn)');
      expect(await drive(env, action), isTrue);
      expect(c.relays.testResults.single.failed, isFalse);
    });

    test('çok bölgeli kayıtta geri bildirimsiz bölgenin ilerleme metni önceki vananın beklemesini göstermez', () async {
      await atRelays();
      await verifyRelays();
      c.relays.setAssignment(5, valve.copyWith(fbDi: 3)); // bölge 1: geri bildirimli vana
      c.relays.setAssignment(7, const ChannelAssignment(use: ChannelUse.siren, zone: 2)); // bölge 2: siren
      env.device.testResultDelay = const Duration(seconds: 10);
      final action = c.relays.saveSafety();
      await waitUntil(env, () => env.device.alarmTests.length == 2);
      expect(c.relays.busyLabel, 'Bölge 2 testi çalıştırılıyor');
      expect(await drive(env, action), isTrue);
      expect(env.device.alarmTests, <int>[1, 2]);
    });

    test('geri bildirimsiz bölge: 15 sn sınırı korunur (sonuç gelmezse uzun beklenmez; gözle doğrulama)', () async {
      await atRelays();
      await verifyRelays();
      c.relays.setAssignment(7, const ChannelAssignment(use: ChannelUse.siren));
      env.device.testResultDelay = const Duration(hours: 1);
      final started = env.clock.now();

      expect(await drive(env, c.relays.saveSafety()), isTrue);
      expect(env.clock.now().difference(started), lessThan(const Duration(seconds: 20)));
      final result = c.relays.testResults.single;
      expect(result.failed, isFalse);
      expect(result.unconfirmed, isFalse);
    });
  });

  group('servis_kurulum-6: yalnız panjur rölesi olan pano', () {
    tearDown(() => env.dispose());

    test('7. adım tamamlanır; teslim ayrıntısı "Lamba/darbe rölesi yok"', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      env = await serviceHarness();
      env.device.relays.removeWhere((r) => r.type == 0); // yalnız panjur röleleri kalır
      c = await reachStep(env, SetupSteps.relays);
      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
      expect(c.relays.problem, isNull);
      expect(c.relays.relays, isEmpty);
      expect(c.relays.shutterRelays, isNotEmpty);
      expect(c.relays.isComplete, isTrue);
      final checks = c.handover.buildChecks();
      expect(checks.relays.ok, isTrue);
      expect(checks.relays.detail, 'Lamba/darbe rölesi yok (tüm röleler panjur; 8. adımda test edildi)');
    });
  });

  group('guvenlik-4: bulut kuyruğu', () {
    late FakeCloudApi cloud;
    late CloudSafetyConfigTransport transport;
    Map<String, dynamic> patch(int i) => <String, dynamic>{'op': 'set', 'item': 'actuator', 'value': <String, dynamic>{'id': 'a$i'}};

    setUp(() {
      cloud = FakeCloudApi(clock: FakeClock());
      transport = CloudSafetyConfigTransport(
        cloud: cloud,
        homeId: kHomeA,
        deviceId: 'AHBU-S3-TEST01',
        clock: FakeClock(),
        delay: (d) async {},
      );
    });

    test('pano çevrimdışı bilinirken 16\'dan fazla yama hiç gönderilmez', () async {
      transport.deviceOnline = false;
      await expectLater(
        transport.apply(<Map<String, dynamic>>[for (var i = 0; i < 17; i++) patch(i)], baseRev: 3),
        throwsA(isA<SafetyQueueLimitExceeded>()),
      );
      expect(cloud.patchCalls, isEmpty);
    });

    test('ilk yanıt "kuyruğa alındı" ve plan sınırı aşıyor: kuyruğa giren yama geri alınır', () async {
      cloud.patchHandler = (call) async => <String, dynamic>{'queued': true, 'position': 1, 'command_id': call.commandId};
      await expectLater(
        transport.apply(<Map<String, dynamic>>[for (var i = 0; i < 17; i++) patch(i)], baseRev: 3),
        throwsA(isA<SafetyQueueLimitExceeded>()),
      );
      expect(cloud.patchCalls, hasLength(1));
      expect(cloud.pendingCleared, 1);
    });

    test('zincir ortasında CONFIG_QUEUE_FULL: kısmi kuyruk geri alınır', () async {
      var n = 0;
      cloud.patchHandler = (call) async {
        if (++n == 1) return <String, dynamic>{'queued': true, 'position': 1, 'command_id': call.commandId};
        throw const ApiException(statusCode: 409, code: 'CONFIG_QUEUE_FULL', message: 'Kuyruk dolu.');
      };
      await expectLater(
        transport.apply(<Map<String, dynamic>>[patch(1), patch(2), patch(3)], baseRev: 3),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CONFIG_QUEUE_FULL')),
      );
      expect(cloud.pendingCleared, 1);
    });

    test('zincir ortasında CONFIG_CHANGED_ON_DEVICE: kısmi kuyruk geri alınır, çakışma "geri alındı" işaretlidir', () async {
      var n = 0;
      cloud.patchHandler = (call) async {
        if (++n == 1) return <String, dynamic>{'queued': true, 'position': 1, 'command_id': call.commandId};
        throw const ApiException(statusCode: 409, code: 'CONFIG_CHANGED_ON_DEVICE', message: 'Değişti.');
      };
      await expectLater(
        transport.apply(<Map<String, dynamic>>[patch(1), patch(2)], baseRev: 3),
        throwsA(isA<SafetyConfigConflict>().having((e) => e.rolledBack, 'rolledBack', isTrue)),
      );
      expect(cloud.pendingCleared, 1);
    });

    group('adım mantığı', () {
      tearDown(() => env.dispose());

      Future<void> atRelaysCloud({List<Map<String, dynamic>> pending = const <Map<String, dynamic>>[]}) async {
        await atRelays();
        var currentPending = pending;
        env.cloud.safetyConfigHandler = (home, device) async => <String, dynamic>{
              'rev': env.device.safetyRev,
              'state_rev': env.device.safetyRev,
              'next_base_rev': env.device.safetyRev + currentPending.length,
              'pending': currentPending,
              ...?env.device.savedSafetyConfig,
            };
        env.cloud.onPendingCleared = () => currentPending = const <Map<String, dynamic>>[];
        c.relays.useCloudTransport();
      }

      test('kuyrukta bekleyen değişiklik varken kayıt yeni yamayı kuyruğa EKLEMEZ; onayla kuyruk silinip baştan gönderilir',
          () async {
        await atRelaysCloud(pending: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'p1', 'op': 'del', 'item': 'actuator', 'target': 'a2'},
        ]);
        c.relays.setAssignment(7, const ChannelAssignment(use: ChannelUse.siren));
        expect(await drive(env, c.relays.saveSafety()), isTrue);
        expect(env.cloud.patchCalls, isEmpty, reason: 'bayat plan kuyruğun sonuna eklenmedi');
        expect(c.relays.queueReplaceOffer, 1);

        expect(await drive(env, c.relays.replaceQueuedSafety()), isTrue);
        expect(env.cloud.pendingCleared, 1);
        expect(env.cloud.patchCalls, isNotEmpty);
        expect(env.cloud.patchCalls.first.baseRev, env.device.safetyRev, reason: 'base_rev = panonun state_rev\'i');
        expect(c.relays.queueReplaceOffer, isNull);
      });

      test('çevrimdışı kuyrukta zincir ortası çakışma: kısmi kuyruk silinir, otomatik yeniden deneme yok, yeniden gönder sunulur',
          () async {
        await atRelaysCloud();
        var n = 0;
        env.cloud.patchHandler = (call) async {
          if (++n == 1) return <String, dynamic>{'queued': true, 'position': 1, 'command_id': call.commandId};
          throw const ApiException(statusCode: 409, code: 'CONFIG_CHANGED_ON_DEVICE', message: 'Değişti.');
        };
        c.relays.setAssignment(5, valve.copyWith(fbDi: 3));
        c.relays.setAssignment(7, const ChannelAssignment(use: ChannelUse.siren));
        expect(await drive(env, c.relays.saveSafety()), isFalse);
        expect(env.cloud.patchCalls, hasLength(2), reason: 'kendiliğinden yeniden denenmedi');
        expect(env.cloud.pendingCleared, 1);
        expect(c.relays.resendOffer, isTrue);
        expect(c.relays.problem!.title, 'Pano yapılandırması değişti');
        expect(c.relays.queued, isNull);
      });

      test('ilk yamada CONFIG_PENDING (başka bekleyen kuyruk): kuyruk notu ve "Kuyruğu iptal et" görünür', () async {
        await atRelaysCloud();
        env.cloud.patchHandler = (call) async {
          throw const ApiException(statusCode: 409, code: 'CONFIG_PENDING', message: 'Bekleyen var.');
        };
        env.cloud.safetyConfigHandler = (home, device) async => <String, dynamic>{
              'rev': env.device.safetyRev,
              'state_rev': env.device.safetyRev,
              'pending': env.cloud.patchCalls.isEmpty
                  ? const <Map<String, dynamic>>[]
                  : <Map<String, dynamic>>[
                      <String, dynamic>{'id': 'x1', 'op': 'set', 'item': 'sensor'},
                    ],
            };
        c.relays.setAssignment(7, const ChannelAssignment(use: ChannelUse.siren));
        expect(await drive(env, c.relays.saveSafety()), isFalse);
        expect(c.relays.queued, isNotNull);
        expect(env.cloud.pendingCleared, 0, reason: 'bu kayıt kuyruğa bir şey eklemedi: başkasının kuyruğu silinmez');
      });
    });
  });
}
