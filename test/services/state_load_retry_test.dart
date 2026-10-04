import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// PF-11 (WP-STATE, S4): ilk uç nokta / cihaz listesi yüklemesi başarısız kalırsa sınırlı otomatik yeniden deneme
/// (2, 5, 15, 30 sn; en çok 4; sessiz) ve cihaz listesi alınamadığında çevrimiçiliğin uç noktaların
/// `device_online` bilgisinden türetilmesi (rozet sonsuza dek "Bağlanıyor…" kalmaz).
void main() {
  Future<void> settle() => pumpEventQueue();

  List<EndpointModel> endpointsOnline(bool? online) => testEndpoints().map((e) => online == null ? e : e.copyWith(deviceOnline: online)).toList();

  group('uç nokta yüklemesi', () {
    test('ilk yükleme başarısız: 2 sn sonra otomatik yeniden denenir; başarıdan sonra durur', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      addTearDown(h.dispose);
      expect(h.state.endpointsLoaded, isFalse);
      expect(h.state.endpointsError, isNotNull);
      expect(h.cloud.count('fetchEndpoints'), 1);

      h.cloud.fetchEndpointsError = null; // ağ geldi
      await h.clock.elapse(const Duration(seconds: 3));

      expect(h.cloud.count('fetchEndpoints'), 2);
      expect(h.state.endpointsLoaded, isTrue);
      expect(h.state.endpointsError, isNull);
      expect(h.state.cloudEndpoints, isNotEmpty);

      await h.clock.elapse(const Duration(minutes: 3));
      expect(h.cloud.count('fetchEndpoints'), 2, reason: 'yüklendi: ek deneme yok');
    });

    test('sürekli hata: en çok 4 deneme (2, 5, 15, 30 sn aralıklarla), sonra DURUR', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      addTearDown(h.dispose);
      expect(h.cloud.count('fetchEndpoints'), 1);

      await h.clock.elapse(const Duration(milliseconds: 1900));
      expect(h.cloud.count('fetchEndpoints'), 1, reason: '2 sn dolmadı');
      await h.clock.elapse(const Duration(milliseconds: 300)); // t = 2,2 sn
      expect(h.cloud.count('fetchEndpoints'), 2);
      await h.clock.elapse(const Duration(seconds: 5)); // t = 7,2 sn
      expect(h.cloud.count('fetchEndpoints'), 3);
      await h.clock.elapse(const Duration(seconds: 15)); // t = 22,2 sn
      expect(h.cloud.count('fetchEndpoints'), 4);
      await h.clock.elapse(const Duration(seconds: 30)); // t = 52,2 sn
      expect(h.cloud.count('fetchEndpoints'), 5);

      await h.clock.elapse(const Duration(minutes: 10));
      expect(h.cloud.count('fetchEndpoints'), 5, reason: 'ilk + 4 deneme = 5 istek; sonra elle "Yeniden dene"');
      expect(h.state.endpointsError, isNotNull);
      expect(h.state.endpointsLoaded, isFalse);
    });

    test('elle "Yeniden dene" (refresh) yeni bir otomatik deneme zinciri başlatır', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(minutes: 2));
      final before = h.cloud.count('fetchEndpoints');
      expect(before, 5);

      await h.state.refresh(); // kullanıcı
      expect(h.cloud.count('fetchEndpoints'), before + 1);
      h.cloud.fetchEndpointsError = null;
      await h.clock.elapse(const Duration(seconds: 3));

      expect(h.cloud.count('fetchEndpoints'), before + 2, reason: 'elle yenileme sonrası da 2 sn\'lik otomatik deneme çalıştı');
      expect(h.state.endpointsLoaded, isTrue);
    });

    test('arka plana geçince deneme DURUR; ön plana dönünce tek snapshot yeniden yükler', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      addTearDown(h.dispose);
      h.state.handleLifecycleState(AppLifecycleState.paused);
      await settle();
      final before = h.cloud.count('fetchEndpoints');

      await h.clock.elapse(const Duration(seconds: 60));
      expect(h.cloud.count('fetchEndpoints'), before, reason: 'arka planda ağ çağrısı yok');

      h.cloud.fetchEndpointsError = null;
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(h.cloud.count('fetchEndpoints'), before + 1);
      expect(h.state.endpointsLoaded, isTrue);
    });

    test('ev değişince ESKİ ev için deneme yapılmaz', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      await h.state.fetchHomes(autoSelect: false);
      h.cloud.fetchEndpointsError = null;

      await h.state.selectHome(h.state.homeById(kHomeB)!);
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints:$kHomeA'), 1, reason: 'A için yalnız ilk istek');
      expect(h.cloud.count('fetchEndpoints:$kHomeB'), 1, reason: 'B yüklendi: yeniden deneme yok');
      expect(h.state.endpointsLoaded, isTrue);
    });

    test('çıkış ve dispose zamanlayıcıyı iptal eder', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      final timersBefore = h.clock.activeTimerCount;
      expect(timersBefore, greaterThan(0), reason: 'yeniden deneme zamanlayıcısı kurulu');
      await h.state.logout();
      final afterLogout = h.cloud.count('fetchEndpoints');
      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('fetchEndpoints'), afterLogout, reason: 'çıkıştan sonra deneme yok');

      final h2 = await readyHarness(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      final calls = h2.cloud.count('fetchEndpoints');
      h2.dispose();
      await h2.clock.elapse(const Duration(minutes: 2));
      expect(h2.cloud.count('fetchEndpoints'), calls, reason: 'dispose sonrası deneme yok');
      expect(h2.clock.activeTimerCount, 0);
    });

    test('hata yokken (normal açılış) yeniden deneme zamanlayıcısı KURULMAZ', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final calls = h.cloud.count('fetchEndpoints');

      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), calls);
      expect(h.cloud.count('devices'), 1);
    });
  });

  group('cihaz listesi ve çevrimiçilik', () {
    test('devices() hatası: rozet "Bağlanıyor…" kalır AMA otomatik yeniden denenir ve düzelince çevrimiçi olur', () async {
      final h = await readyHarness(configure: (h) => h.cloud.devicesError = ApiException.network());
      addTearDown(h.dispose);
      expect(h.state.devicePresence, DevicePresence.unknown);
      expect(h.state.connState, ConnectionStateEnum.connecting);
      expect(h.cloud.count('devices'), 1);

      h.cloud.devicesError = null;
      await h.clock.elapse(const Duration(seconds: 3));

      expect(h.cloud.count('devices'), 2);
      expect(h.state.devicePresence, DevicePresence.online);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.devices, isNotEmpty);
      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('devices'), 2);
    });

    test('devices() hatası + uç noktalarda device_online: varlık uç noktalardan türetilir (çevrimiçi)', () async {
      final h = await readyHarness(
        endpoints: endpointsOnline(true),
        configure: (h) => h.cloud.devicesError = ApiException.network(),
      );
      addTearDown(h.dispose);

      expect(h.state.devicePresence, DevicePresence.online);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.deviceOnline, isTrue);
    });

    test('devices() hatası + uç noktalar device_online=false: varlık çevrimdışı olarak türetilir', () async {
      final h = await readyHarness(
        endpoints: endpointsOnline(false),
        configure: (h) => h.cloud.devicesError = ApiException.network(),
      );
      addTearDown(h.dispose);

      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.connState, ConnectionStateEnum.offline);
    });

    test('uç noktalarda device_online bilinmiyorsa (null) varlık UYDURULMAZ', () async {
      final h = await readyHarness(
        endpoints: endpointsOnline(null),
        configure: (h) => h.cloud.devicesError = ApiException.network(),
      );
      addTearDown(h.dispose);

      expect(h.state.devicePresence, DevicePresence.unknown);
    });

    test('varlık yedeği canlı kanal BAĞLIYKEN canlı bilgiyi ezmez', () async {
      final h = await readyHarness(endpoints: endpointsOnline(false), deviceOnline: true);
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(stateJson(relays: const <int, bool>{1: false, 2: false, 5: false, 6: false}));
      await settle();
      expect(h.state.deviceOnline, isTrue, reason: 'canlı state cihazın yaşadığını gösteriyor');

      await h.state.refresh(silent: true); // REST uç noktaları device_online=false diyor
      await settle();

      expect(h.state.deviceOnline, isTrue, reason: 'canlı kanal bağlı: REST varlık yedeği devreye girmez');
    });

    test('cihaz listesi BAŞARIYLA geldiyse o esastır: uç noktalardaki device_online yedeği ona üstün gelmez', () async {
      // devices(): online=false (canlı kanal yok); uç noktalar: online=true. Liste yüklendi: yedek devreye girmez.
      final h = await readyHarness(endpoints: endpointsOnline(true), brokerConnected: false, deviceOnline: false);
      addTearDown(h.dispose);

      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.connState, ConnectionStateEnum.offline);
    });

    test('devices() hatası + canlı kanal KOPUKKEN yedek uygulanır; canlı ileti gelince canlı bilgi esas olur', () async {
      final h = await readyHarness(
        endpoints: endpointsOnline(false),
        brokerConnected: false,
        configure: (h) => h.cloud.devicesError = ApiException.network(),
      );
      addTearDown(h.dispose);
      expect(h.state.devicePresence, DevicePresence.offline, reason: 'uç noktalar: cihaz çevrimdışı');

      h.mqtt.emitStateJson(stateJson(relays: const <int, bool>{1: false, 2: false, 5: false, 6: false}));
      await settle();
      expect(h.state.devicePresence, DevicePresence.online, reason: 'canlı state kesin kanıt');
    });
  });
}
