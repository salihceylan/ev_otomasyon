import 'dart:math';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// PF-28: yeniden bağlanma geri çekilmesi (üstel, 60 sn tavan, +-%20 jitter) bağlanır bağlanmaz
/// SIFIRLANMAMALI. Eski kod her başarılı bağlanışta sayacı sıfırlayıp beklenmeyen kopmada hep ilk
/// basamağı (~2 sn) bekliyordu: bağlanıp hemen düşen bir bağlantı (ör. kimlik geçerli ama broker/ACL
/// hemen kapatıyor) ~0,5 Hz döngüye girip her turda `mqtt-credentials` POST'u atıyordu.
///
/// Kural: yalnızca en az 30 sn yaşamış (kararlı) bir bağlantının KOPMASI sayacı sıfırlar; planlı kimlik
/// yenilemesinde bekleme yoktur ve sayaç sıfırlanır. İlk kısa kopma yine ~2 sn bekler
/// (`ev_mqtt_service_test.dart` "beklenmeyen kopma" testi aynen geçer).
void main() {
  late FakeClock clock;
  late List<FakeMqttTransport> transports;
  late List<DateTime> connectTimes;
  late int providerCalls;
  late EvMqttService service;

  MqttCredentials creds(Duration validFor) => MqttCredentials(
        host: 'broker.test',
        port: 8884,
        username: 'a_h_abc_1',
        password: 'gecici-parola',
        expiresAt: clock.now().add(validFor),
        topicId: 'h_abc',
        clientId: 'cid-1',
      );

  /// [lifetime]: n. bağlantının kurulduktan sonra karşı taraftan koparılma süresi (`drop()`);
  /// [validFor]: n. kimliğin geçerlilik süresi (varsayılan 12 saat: yenileme bu testlerde devreye girmez).
  Future<void> run({
    required Duration Function(int index) lifetime,
    Duration Function(int index)? validFor,
    required Duration total,
  }) async {
    service = EvMqttService(
      clock: clock,
      random: Random(11),
      useTls: true,
      transportFactory: () {
        final index = transports.length;
        final transport = FakeMqttTransport();
        transports.add(transport);
        connectTimes.add(clock.now());
        // FakeMqttTransport.connect anında döner: bağlantı bu an kurulmuş sayılır.
        clock.timer(lifetime(index), transport.drop);
        return transport;
      },
    );
    addTearDown(service.dispose);
    await service.start(credentialsProvider: () async {
      providerCalls++;
      return creds(validFor == null ? const Duration(hours: 12) : validFor(providerCalls - 1));
    });
    await clock.elapse(total);
  }

  /// n. kopmadan sonraki gerçek bekleme (ms): iki bağlanma başlangıcı arası eksi o bağlantının ömrü.
  List<int> waitsMs(Duration Function(int index) lifetime) => <int>[
        for (var i = 1; i < connectTimes.length; i++)
          connectTimes[i].difference(connectTimes[i - 1]).inMilliseconds - lifetime(i - 1).inMilliseconds,
      ];

  /// `_backoff(k)` taban süresi (sn): 2,4,8,16,32,60,60,...
  int baseSeconds(int k) => min(2 << min(k, 6), 60);

  Matcher jittered(int baseSeconds) => inInclusiveRange(
        (baseSeconds * 800).floor() - 1,
        (baseSeconds * 1200).ceil() + 1,
      );

  setUp(() {
    clock = FakeClock();
    transports = <FakeMqttTransport>[];
    connectTimes = <DateTime>[];
    providerCalls = 0;
  });

  group('PF-28: ömrü kısa bağlantılar geri çekilmeyi sıfırlamaz', () {
    test('her bağlantı 100 ms sonra düşerse bekleme 2,4,8,16,32,60 sn artar; 5 dakikada en çok 12 kimlik istenir', () async {
      Duration life(int _) => const Duration(milliseconds: 100);
      await run(lifetime: life, total: const Duration(minutes: 5));

      expect(
        providerCalls,
        lessThanOrEqualTo(12),
        reason: 'eski kod her turda sayacı sıfırlayıp ~2 sn bekliyordu (5 dakikada ~140 kimlik isteği)',
      );
      expect(providerCalls, greaterThanOrEqualTo(8), reason: 'döngü sürüyor (ölü değil)');
      expect(transports, hasLength(providerCalls), reason: 'her kimlik bir bağlantı denemesi');

      final waits = waitsMs(life);
      for (var k = 0; k < waits.length; k++) {
        expect(waits[k], jittered(baseSeconds(k)), reason: '${k + 1}. kopmadan sonraki bekleme');
      }
      expect(waits.first, inInclusiveRange(1500, 2600), reason: 'ilk kısa kopma yine ~2 sn');
      expect(waits.last, greaterThan(40000), reason: '60 sn tavanında doyar');
      expect(waits.reduce(max), lessThanOrEqualTo(72001), reason: 'tavan 60 sn + %20 jitter');
    });

    test('29 sn yaşayan bağlantı kararlı sayılmaz: sayaç sıfırlanmaz, bekleme büyümeye devam eder', () async {
      Duration life(int _) => const Duration(seconds: 29);
      await run(lifetime: life, total: const Duration(minutes: 6));

      final waits = waitsMs(life);
      expect(waits.length, greaterThanOrEqualTo(5));
      for (var k = 0; k < waits.length; k++) {
        expect(waits[k], jittered(baseSeconds(k)), reason: '${k + 1}. kopmadan sonraki bekleme');
      }
    });
  });

  group('PF-28: kararlı bağlantı sayacı sıfırlar', () {
    test('30 sn yaşayan bağlantının kopmasından sonra bekleme yeniden ~2 sn; sonraki kısa kopma ~4 sn', () async {
      // 0-3: 100 ms (bekleme 2,4,8,16 sn -> sayaç 4), 4: tam 30 sn (kararlı), sonrası 100 ms.
      Duration life(int i) => i == 4 ? const Duration(seconds: 30) : const Duration(milliseconds: 100);
      await run(lifetime: life, total: const Duration(minutes: 4));

      final waits = waitsMs(life);
      expect(waits.length, greaterThanOrEqualTo(8));
      expect(waits[0], jittered(2));
      expect(waits[1], jittered(4));
      expect(waits[2], jittered(8));
      expect(waits[3], jittered(16));
      expect(
        waits[4],
        jittered(2),
        reason: 'kararlı bağlantının kopmasından sonra sayaç sıfırlanır (sayaç 4 kalsaydı ~32 sn beklenirdi)',
      );
      expect(waits[5], jittered(4), reason: 'sıfırlanmış sayaçtan yeniden üstel artış');
      expect(waits[6], jittered(8));
      expect(waits[7], jittered(16));
    });

    test('40 sn yaşayan bağlantıdan sonra sayaç sıfırlanır (tavandaki geri çekilme bile)', () async {
      // 0-6: 100 ms (bekleme 2,4,8,16,32,60,60 sn: tavanda), 7: 40 sn, sonrası 100 ms.
      Duration life(int i) => i == 7 ? const Duration(seconds: 40) : const Duration(milliseconds: 100);
      await run(lifetime: life, total: const Duration(minutes: 12));

      final waits = waitsMs(life);
      expect(waits.length, greaterThanOrEqualTo(10));
      expect(waits[5], jittered(60));
      expect(waits[6], jittered(60));
      expect(waits[7], jittered(2), reason: '40 sn yaşayan bağlantıdan sonra bekleme ~2 sn');
      expect(waits[8], jittered(4));
      expect(waits[9], jittered(8));
    });

    test('kararlı bağlantı tek başına (hiç kısa kopma yokken) her kopmada ~2 sn bekler', () async {
      Duration life(int _) => const Duration(minutes: 2);
      await run(lifetime: life, total: const Duration(minutes: 15));

      final waits = waitsMs(life);
      expect(waits.length, greaterThanOrEqualTo(5));
      for (final wait in waits) {
        expect(wait, jittered(2));
      }
    });
  });

  group('PF-28: planlı kimlik yenilemesi', () {
    test('yenilemede bekleme YOKTUR ve sayaç sıfırlanır (kısa ömürlü bağlantıda bile)', () async {
      // 0-2: 100 ms (bekleme 2,4,8 sn -> sayaç 3). 3: kimlik 20 sn geçerli -> yenileme 15 sn sonra (<30 sn);
      // yenileme koptuktan sonra bağlantı 100 ms yaşar.
      Duration life(int i) => i == 3 ? const Duration(minutes: 5) : const Duration(milliseconds: 100);
      Duration valid(int providerIndex) =>
          providerIndex == 3 ? const Duration(seconds: 20) : const Duration(hours: 12);
      await run(lifetime: life, validFor: valid, total: const Duration(minutes: 3));

      expect(transports.length, greaterThanOrEqualTo(7));
      final gaps = <int>[
        for (var i = 1; i < connectTimes.length; i++) connectTimes[i].difference(connectTimes[i - 1]).inMilliseconds,
      ];
      expect(
        gaps[3],
        15000,
        reason: '20 sn geçerli kimlik: yenileme alt sınırı 15 sn; yenilemede ek bekleme YOK (hemen yeniden bağlanır)',
      );
      // Yenilemeden sonraki bağlantı (4.) 100 ms yaşadı: sayaç sıfırlanmış olmalı -> ~2 sn, sonra ~4 sn.
      expect(gaps[4] - 100, jittered(2), reason: 'yenileme sayacı sıfırladı (sayaç 3 kalsaydı ~16 sn beklenirdi)');
      expect(gaps[5] - 100, jittered(4));
    });
  });

  group('PF-28: mevcut sözleşmeler (kopma -> taze kimlik)', () {
    test('ilk kısa kopma 4 sn içinde taze kimlikle yeniden bağlanır', () async {
      Duration life(int _) => const Duration(milliseconds: 100);
      await run(lifetime: life, total: const Duration(seconds: 4));

      expect(providerCalls, greaterThanOrEqualTo(2), reason: 'her denemede taze kimlik');
      expect(transports.length, greaterThanOrEqualTo(2));
    });

    test('stop() geri çekilme beklemesini böler: sonradan yeni bağlantı kurulmaz', () async {
      Duration life(int _) => const Duration(milliseconds: 100);
      await run(lifetime: life, total: const Duration(seconds: 10));
      final calls = providerCalls;
      await service.stop();
      await clock.elapse(const Duration(minutes: 5));

      expect(providerCalls, calls);
      expect(service.linkState, MqttLinkState.disconnected);
      expect(clock.activeTimerCount, 0);
    });
  });
}
