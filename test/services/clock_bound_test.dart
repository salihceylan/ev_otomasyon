import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/clock.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// `ClockBound.bound` (PF-02): platform kanalı gibi dönmeyebilen çağrıları bekleyen kodun sonsuza dek
/// takılmamasını sağlayan süre sınırı. Zamanlayıcı `Clock`'tan kurulur (burada `FakeClock.elapse`).
/// Dosyanın sonunda, `bound`'u kullanacak paketlerin takılı çağrı simüle ettiği test kancaları
/// (`FakeCloudApi.fetchEndpointsGate/devicesError/localKeyGate`, `FakeMqttTransport.connectGate`) da sınanır.
void main() {
  const limit = Duration(seconds: 5);

  /// Sonucu (değer ya da hata) bir kutuya yazar; "henüz dönmedi" de gözlenebilsin diye.
  _Box<T> track<T>(Future<T> future) {
    final box = _Box<T>();
    future.then<void>((value) {
      box.done = true;
      box.value = value;
    }, onError: (Object error) {
      box.done = true;
      box.error = error;
    });
    return box;
  }

  group('süre dolmadan tamamlanan çağrı', () {
    test('değer aynen iletilir, zamanlayıcı iptal edilir, onTimeout çağrılmaz', () async {
      final clock = FakeClock();
      final gate = Completer<int>();
      var timeouts = 0;
      final result = clock.bound<int>(gate.future, limit, () {
        timeouts++;
        return -1;
      });
      expect(clock.activeTimerCount, 1, reason: 'sınır zamanlayıcısı kuruldu');

      gate.complete(42);
      expect(await result, 42);
      expect(clock.activeTimerCount, 0, reason: 'tamamlanınca zamanlayıcı iptal edilir');

      await clock.elapse(const Duration(minutes: 1));
      expect(timeouts, 0, reason: 'iptal edilen zamanlayıcı geç de olsa tetiklenmez');
    });

    test('hata aynen iletilir (sarmalanmaz) ve zamanlayıcı iptal edilir', () async {
      final clock = FakeClock();
      final gate = Completer<int>();
      final result = clock.bound<int>(gate.future, limit, () => -1);
      final expectation = expectLater(result, throwsA(isA<StateError>().having((e) => e.message, 'message', 'platform hatası')));

      gate.completeError(StateError('platform hatası'));
      await expectation;
      expect(clock.activeTimerCount, 0);
    });

    test('zaten tamamlanmış gelecek: değer döner (eşzamanlı advance bile onu zaman aşımına uğratmaz)', () async {
      final clock = FakeClock();
      var timeouts = 0;
      final result = clock.bound<int>(Future<int>.value(5), limit, () {
        timeouts++;
        return -1;
      });
      // Eşzamanlı advance zamanlayıcıyı tetikler; ama hazır sonucun devamı bir mikro görev önce çalışır.
      clock.advance(const Duration(seconds: 30));
      expect(await result, 5);
      expect(timeouts, 0);
    });

    test('T null olabilir: null değer ve null onTimeout sonucu desteklenir', () async {
      final clock = FakeClock();
      expect(await clock.bound<String?>(Future<String?>.value(null), limit, () => 'x'), isNull);

      final pending = Completer<String?>();
      final result = clock.bound<String?>(pending.future, limit, () => null);
      await clock.elapse(limit);
      expect(await result, isNull);
    });
  });

  group('süre dolunca', () {
    test('tam sınırda onTimeout sonucu döner; öncesinde beklenir', () async {
      final clock = FakeClock();
      final gate = Completer<int>();
      final box = track(clock.bound<int>(gate.future, limit, () => -1));

      await clock.elapse(const Duration(seconds: 4, milliseconds: 999));
      expect(box.done, isFalse, reason: 'sınırdan 1 ms önce hâlâ bekler');

      await clock.elapse(const Duration(milliseconds: 1));
      expect(box.done, isTrue);
      expect(box.value, -1);
      expect(clock.activeTimerCount, 0);
    });

    test('onTimeout hata fırlatırsa dönen gelecek o hatayla tamamlanır', () async {
      final clock = FakeClock();
      final result = clock.bound<int>(Completer<int>().future, limit, () => throw TimeoutException('süre doldu', limit));
      final expectation = expectLater(result, throwsA(isA<TimeoutException>()));

      await clock.elapse(limit);
      await expectation;
    });

    test('onTimeout istisnası eşzamanlı advance çağıranına SIZMAZ (zamanlayıcı geri çağrısı patlamaz)', () async {
      final clock = FakeClock();
      final result = clock.bound<int>(Completer<int>().future, limit, () => throw StateError('süre doldu'));
      final expectation = expectLater(result, throwsA(isA<StateError>()));

      expect(() => clock.advance(const Duration(seconds: 10)), returnsNormally);
      await expectation;
    });

    test('hâlâ bekleyen çağrı eşzamanlı advance sonrası zaman aşımına uğrar', () async {
      final clock = FakeClock();
      final result = clock.bound<int>(Completer<int>().future, limit, () => -1);
      clock.advance(const Duration(seconds: 10));
      expect(await result, -1);
    });
  });

  group('süreyi aşan çağrının geç sonucu', () {
    test('geç dönen DEĞER yutulur: sonuç zaman aşımı sonucu olarak kalır', () async {
      final clock = FakeClock();
      final gate = Completer<int>();
      final box = track(clock.bound<int>(gate.future, limit, () => -1));
      await clock.elapse(limit);
      expect(box.value, -1);

      gate.complete(99);
      await clock.elapse(Duration.zero);
      expect(box.value, -1, reason: 'geç değer sonucu ezmez');
    });

    test('geç dönen HATA yutulur: ele alınmamış (zone) hata üretmez', () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final clock = FakeClock();
        final gate = Completer<int>();
        final box = track(clock.bound<int>(gate.future, limit, () => -1));
        await clock.elapse(limit);
        expect(box.value, -1);

        gate.completeError(StateError('geç gelen platform hatası'));
        await clock.elapse(Duration.zero);
        expect(box.value, -1);
        expect(box.error, isNull);
      }, (error, stack) => uncaught.add(error));

      expect(uncaught, isEmpty, reason: 'main.dart onError\'una düşecek ele alınmamış hata olmamalı');
    });
  });

  group('gerçek saat', () {
    test('SystemClock ile de çalışır: dönmeyen çağrı sınırda onTimeout sonucunu verir', () async {
      final result = const SystemClock().bound<int>(Completer<int>().future, const Duration(milliseconds: 30), () => -1);
      expect(await result, -1);
    });

    test('SystemClock: sınırdan önce dönen değer iletilir', () async {
      final result = const SystemClock().bound<int>(
        Future<int>.delayed(const Duration(milliseconds: 5), () => 7),
        const Duration(seconds: 30),
        () => -1,
      );
      expect(await result, 7);
    });
  });

  // `bound`'u kullanacak paketlerin (REST bütçesi, MQTT bağlanma sınırı, açılış) takılı çağrıyı simüle ettiği
  // test kancaları (`fakes.dart`): burada belgelendiği gibi çalıştıkları ve `ClockBound` ile birleştikleri sabitlenir.
  group('askıda kalan çağrı kancaları (fakes.dart)', () {
    const homeId = kHomeA;
    final credentials = MqttCredentials(
      host: 'broker.fake.invalid',
      port: 8884,
      username: 'a_h_test_1',
      password: 'fake-secret-not-real',
      expiresAt: DateTime.utc(2030),
      topicId: 'h_test',
    );

    test('FakeCloudApi.fetchEndpointsGate: kapı açılana kadar dönmez; liste İSTEK ANINDAKİ; hata kapıdan SONRA okunur', () async {
      final cloud = FakeCloudApi()..endpoints[homeId] = testEndpoints();
      final gate = Completer<void>();
      cloud.fetchEndpointsGate = gate;
      final out = track(cloud.fetchEndpoints(homeId));
      await pumpEventQueue();
      expect(out.done, isFalse);
      expect(cloud.calls, <String>['fetchEndpoints:$homeId']);

      cloud.endpoints[homeId] = <EndpointModel>[]; // kapı açılmadan liste değişir (bayat yanıt simülasyonu)
      gate.complete();
      await pumpEventQueue();
      expect(out.value, hasLength(6), reason: 'yanıt istek anındaki listeyle üretilir');

      final secondGate = Completer<void>();
      cloud
        ..fetchEndpointsGate = secondGate
        ..endpoints[homeId] = testEndpoints();
      final failing = track(cloud.fetchEndpoints(homeId));
      cloud.fetchEndpointsError = StateError('ağ yok'); // kapı beklerken kurulan hata
      secondGate.complete();
      await pumpEventQueue();
      expect(failing.error, isA<StateError>());

      cloud
        ..fetchEndpointsGate = null
        ..fetchEndpointsError = null;
      expect(await cloud.fetchEndpoints(homeId), hasLength(6), reason: 'kapı yokken eski davranış');
    });

    test('FakeCloudApi.devicesError: devices bu hatayı fırlatır; temizlenince liste döner', () async {
      final cloud = FakeCloudApi()
        ..devicesByHome[homeId] = <DeviceInfo>[const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true)];
      expect(await cloud.devices(homeId), hasLength(1));

      cloud.devicesError = StateError('cihaz listesi alınamadı');
      await expectLater(cloud.devices(homeId), throwsA(isA<StateError>()));
      expect(cloud.calls.where((c) => c == 'devices:$homeId'), hasLength(2), reason: 'hatalı çağrı da günlüğe yazılır');

      cloud.devicesError = null;
      expect(await cloud.devices(homeId), hasLength(1));
    });

    test('FakeCloudApi.localKeyGate: kapı açılana kadar dönmez; anahtar istek anındaki değer; hata kapıdan SONRA', () async {
      final cloud = FakeCloudApi()..localKeyValue = 'anahtar-1';
      final gate = Completer<void>();
      cloud.localKeyGate = gate;
      final out = track(cloud.localKey(homeId, 'AHBU-S3-TEST01'));
      await pumpEventQueue();
      expect(out.done, isFalse);
      expect(cloud.localKeyHomeIds, <String>[homeId]);

      cloud.localKeyValue = 'anahtar-2';
      gate.complete();
      await pumpEventQueue();
      expect(out.value, 'anahtar-1');

      final secondGate = Completer<void>();
      cloud.localKeyGate = secondGate;
      final failing = track(cloud.localKey(homeId, 'AHBU-S3-TEST01'));
      cloud.localKeyError = StateError('anahtar alınamadı');
      secondGate.complete();
      await pumpEventQueue();
      expect(failing.error, isA<StateError>());
    });

    test('FakeMqttTransport.connectGate: bağlanma kapı açılana kadar dönmez; alanlar kapıdan ÖNCE yazılır; sonra outcome döner', () async {
      final transport = FakeMqttTransport();
      final gate = Completer<void>();
      transport.connectGate = gate;
      final out = track(transport.connect(
        credentials: credentials,
        clientId: 'client-1',
        secure: true,
        timeout: const Duration(seconds: 10),
      ));
      await pumpEventQueue();
      expect(out.done, isFalse, reason: 'TCP/TLS kurulumu takılı');
      expect(transport.clientId, 'client-1', reason: 'takılı bağlanma denemesi izlenebilir');
      expect(transport.secure, isTrue);

      gate.complete();
      await pumpEventQueue();
      expect(out.value!.ok, isTrue);

      transport.connectGate = null;
      transport.outcome = const MqttConnectOutcome.failed(MqttFailure.timeout);
      expect((await transport.connect(credentials: credentials, clientId: 'c2', secure: false, timeout: const Duration(seconds: 1))).ok, isFalse);
    });

    test('ClockBound + kapı: takılı REST / MQTT çağrısı FakeClock ile deterministik zaman aşımına uğrar', () async {
      final clock = FakeClock();
      final cloud = FakeCloudApi(clock: clock)
        ..endpoints[homeId] = testEndpoints()
        ..fetchEndpointsGate = Completer<void>();
      final rest = track(clock.bound<List<EndpointModel>>(
        cloud.fetchEndpoints(homeId),
        const Duration(seconds: 14),
        () => throw TimeoutException('REST bütçesi doldu', const Duration(seconds: 14)),
      ));

      final transport = FakeMqttTransport()..connectGate = Completer<void>();
      final mqtt = track(clock.bound<MqttConnectOutcome>(
        transport.connect(credentials: credentials, clientId: 'c', secure: true, timeout: const Duration(seconds: 10)),
        const Duration(seconds: 15),
        () => const MqttConnectOutcome.failed(MqttFailure.timeout),
      ));

      await clock.elapse(const Duration(seconds: 13));
      expect(rest.done, isFalse);
      expect(mqtt.done, isFalse);

      await clock.elapse(const Duration(seconds: 1));
      expect(rest.error, isA<TimeoutException>());
      expect(mqtt.done, isFalse, reason: 'MQTT sınırı 15 sn');

      await clock.elapse(const Duration(seconds: 1));
      expect(mqtt.value!.ok, isFalse);
      expect(mqtt.value!.failure, MqttFailure.timeout);
      expect(clock.activeTimerCount, 0);
    });
  });
}

class _Box<T> {
  bool done = false;
  T? value;
  Object? error;
}
