import 'dart:convert';
import 'dart:math';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// D12: cihaz `state`/`status` iletilerini QoS 0 yayınlar; kaybolan bir "online" status'u, broker'daki
/// retained "offline" (LWT) iletisini geçerli bırakabilir. Çevrimiçilik türetmesi:
///
/// * canlı (retained olmayan) `state` -> çevrimiçi;
/// * canlı `status:offline` -> kesin çevrimdışı;
/// * retained `status:offline` -> yalnızca taze canlı `state` yoksa çevrimdışı; **kalıcı değil**;
/// * retained `state` çevrimiçiliği kanıtlamaz.
void main() {
  Map<String, dynamic> live([bool on = true]) => stateJson(relays: <int, bool>{1: on});

  Future<void> settle() => pumpEventQueue();

  group('canlı state retained offline\'ı düzeltir', () {
    test('retained offline -> çevrimdışı; ilk canlı state -> çevrimiçi', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.deviceOnline, isFalse);
      expect(h.state.connState, ConnectionStateEnum.offline);

      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.devicePresence, DevicePresence.online);
      expect(h.state.deviceOnline, isTrue);
      expect(h.state.isConnected, isTrue);
    });

    test('canlı state taze iken gelen retained offline YOK SAYILIR (abonelik sırası: state önce, status sonra)', () async {
      final h = await readyHarness(deviceOnline: false);
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.deviceOnline, isTrue);

      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.deviceOnline, isTrue, reason: 'retained offline tarihsel değer; canlı state cihazın yaşadığını gösteriyor');
      expect(h.state.devicePresence, DevicePresence.online);
    });

    test('retained offline ardından canlı state geldikçe çevrimiçi kalır (kalıcı çevrimdışı olmaz)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitPresence(false, retained: true);
      await settle();
      for (var i = 0; i < 3; i++) {
        h.mqtt.emitStateJson(live(i.isEven));
        await settle();
        expect(h.state.deviceOnline, isTrue, reason: 'canlı state #$i');
        h.mqtt.emitPresence(false, retained: true); // yeniden abonelikte tekrar teslim edilebilir
        await settle();
        expect(h.state.deviceOnline, isTrue, reason: 'taze canlı state varken retained offline #$i');
      }
    });

    test('canlı state eskiyse (> 90 sn) retained offline geçerlidir; sonra yeni canlı state düzeltir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      h.clock.advance(const Duration(seconds: 91));

      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.deviceOnline, isFalse, reason: 'canlı state bayat: retained offline kabul edilir');

      h.mqtt.emitStateJson(live(false));
      await settle();
      expect(h.state.deviceOnline, isTrue);
    });

    test('tazelik sınırı: 90 sn içinde yok sayılır, 90 sn sonrasında kabul edilir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      h.clock.advance(const Duration(seconds: 89));
      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.deviceOnline, isTrue);

      h.clock.advance(const Duration(seconds: 2)); // toplam 91 sn
      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.deviceOnline, isFalse);
    });
  });

  group('canlı status kesindir', () {
    test('canlı (retained olmayan) offline: taze canlı state olsa bile çevrimdışı; sonraki canlı state düzeltir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.deviceOnline, isTrue);

      h.mqtt.emitPresence(false); // LWT / planlı yeniden başlatma öncesi offline
      await settle();
      expect(h.state.deviceOnline, isFalse);

      h.mqtt.emitStateJson(live(false));
      await settle();
      expect(h.state.deviceOnline, isTrue, reason: 'cihaz yeniden bağlandı ve canlı state yayınladı');
    });

    test('online status (canlı veya retained) çevrimiçi yapar', () async {
      final h = await readyHarness(deviceOnline: false);
      addTearDown(h.dispose);
      h.mqtt.emitPresence(false);
      await settle();
      expect(h.state.deviceOnline, isFalse);

      h.mqtt.emitPresence(true);
      await settle();
      expect(h.state.deviceOnline, isTrue);

      h.mqtt.emitPresence(false);
      await settle();
      h.mqtt.emitPresence(true, retained: true);
      await settle();
      expect(h.state.deviceOnline, isTrue);
    });
  });

  group('retained state', () {
    test('retained state çevrimiçiliği kanıtlamaz ve "canlı state" tazeliği başlatmaz', () async {
      final h = await readyHarness(deviceOnline: false);
      addTearDown(h.dispose);
      h.state.setPresenceForTesting(DevicePresence.offline);
      h.mqtt.emitStateJson(live(), retained: true);
      await settle();
      expect(h.state.deviceOnline, isFalse);
      expect(ep(h.state, 1).currentState, isTrue, reason: 'son bilinen değer gösterilir');

      // Retained state canlı kanıt sayılmadığı için ardından gelen retained offline kabul edilir.
      h.state.setPresenceForTesting(DevicePresence.online);
      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.deviceOnline, isFalse);
    });
  });

  group('diğer kaynaklarla etkileşim', () {
    test('komut 409 DEVICE_OFFLINE cihazı çevrimdışı gösterir; canlı state düzeltir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.sendCommandHandler = (home, device, command) async => throw const ApiException(
            statusCode: 409,
            code: 'DEVICE_OFFLINE',
            message: 'Cihaz çevrimdışı.',
          );
      await h.state.setRelay(1, true);
      await settle();
      expect(h.state.deviceOnline, isFalse);

      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.deviceOnline, isTrue);
    });

    test('ev değişince tazelik sıfırlanır: önceki evin canlı state\'i yeni evin retained offline\'ını bastırmaz', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      await h.state.fetchHomes(autoSelect: false);
      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.deviceOnline, isTrue);

      await h.state.selectHome(h.state.homeById(kHomeB)!);
      await settle();
      h.mqtt.emitPresence(false, retained: true);
      await settle();
      expect(h.state.activeHome?.id, kHomeB);
      expect(h.state.deviceOnline, isFalse);
    });

    test('REST cihaz listesi canlı kanal bağlıyken MQTT bilgisini ezmez', () async {
      final h = await readyHarness(deviceOnline: false);
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.deviceOnline, isTrue);
      await h.state.refresh(silent: true); // REST: online=false
      expect(h.state.deviceOnline, isTrue);
    });
  });

  group('uçtan uca (gerçek EvMqttService + sahte taşıyıcı)', () {
    test('retained bayrağı taşıyıcıdan duruma kadar korunur: retained offline + canlı state -> çevrimiçi', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final clock = FakeClock();
      final transports = <FakeMqttTransport>[];
      final mqtt = EvMqttService(
        clock: clock,
        random: Random(3),
        useTls: true,
        transportFactory: () {
          final t = FakeMqttTransport();
          transports.add(t);
          return t;
        },
      );
      final cloud = FakeCloudApi(clock: clock)
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints()
        ..credentials = MqttCredentials(
          host: 'broker.test',
          port: 8884,
          username: 'a_h_test_1',
          password: 'gecici-parola',
          expiresAt: clock.now().add(const Duration(hours: 12)),
          topicId: 'h_test',
          clientId: 'cid-1',
        );
      final state = AutomationState(
        cloudApi: cloud,
        mqttService: mqtt,
        secureStorage: FakeStorage(),
        biometricService: FakeBiometric(),
        directApi: AutomationApiService(baseUrl: ''),
        clock: clock,
        autoInit: false,
        observeAppLifecycle: false,
      );
      addTearDown(state.dispose);
      state
        ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await state.fetchHomes();
      await clock.elapse(const Duration(milliseconds: 200));
      final transport = transports.single;
      expect(transport.subscriptions, contains('ev/h_test/status'));

      // Abonelik anı: retained offline (eski LWT) + retained state; cihaz aslında yaşıyor.
      transport.deliver(<MqttInboundMessage>[
        const MqttInboundMessage(topic: 'ev/h_test/status', payload: 'offline', retained: true),
        MqttInboundMessage(topic: 'ev/h_test/state', payload: jsonEncode(stateJson(relays: <int, bool>{1: true})), retained: true),
      ]);
      await clock.elapse(const Duration(milliseconds: 50));
      expect(state.deviceOnline, isFalse, reason: 'canlı kanıt yok: retained offline kabul edilir');

      // Cihazın canlı kalp atışı (retained değil) durumu düzeltir.
      transport.deliver(<MqttInboundMessage>[
        MqttInboundMessage(topic: 'ev/h_test/state', payload: jsonEncode(stateJson(relays: <int, bool>{1: false}))),
      ]);
      await clock.elapse(const Duration(milliseconds: 50));
      expect(state.deviceOnline, isTrue);
      expect(ep(state, 1).currentState, isFalse);

      // Yeniden abonelikte tekrar teslim edilen retained offline taze canlı state varken yok sayılır.
      transport.deliver(<MqttInboundMessage>[
        const MqttInboundMessage(topic: 'ev/h_test/status', payload: 'offline', retained: true),
      ]);
      await clock.elapse(const Duration(milliseconds: 50));
      expect(state.deviceOnline, isTrue);

      // Gerçek (canlı) offline kesindir.
      transport.deliver(<MqttInboundMessage>[
        const MqttInboundMessage(topic: 'ev/h_test/status', payload: 'offline'),
      ]);
      await clock.elapse(const Duration(milliseconds: 50));
      expect(state.deviceOnline, isFalse);
    });
  });
}
