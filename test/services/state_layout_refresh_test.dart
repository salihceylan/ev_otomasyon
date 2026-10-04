import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/endpoint_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// WP-STATE2: panonun CANLI `state` yerleşimi (röle türleri, panjur çiftleri, kanal sayısı) bulut uç nokta listesiyle
/// uyuşmuyorsa gecikmeli, SESSİZ ve sınırlı uç nokta yenilemesi.
///
/// Sunucu köprüsü yerleşimi canlı `state`'ten ~1 sn sonra buluta eşitler (CONTRACTS §2.4b); açık uygulama listeyi
/// kendiliğinden görmezdi (5-6. kanallar panjur olunca lamba kartları kalırdı). Kısaltma (röle = dizgedeki sıra + 1):
/// `L` lamba, `P` priz (yalnız bulut satırı), `I` darbe, `U` panjur YUKARI, `D` panjur AŞAĞI; fabrika `UDUDLLLL`.
void main() {
  const board = 'AHBU-S3-TEST01';
  const otherBoard = 'AHBU-S3-OTHER02';
  const factory = 'UDUDLLLL';

  Future<void> settle() => pumpEventQueue();

  List<EndpointModel> endpointsFor(
    String kinds, {
    String homeId = kHomeA,
    String uuid = board,
    String Function(int channel)? nameOf,
    Set<int> on = const <int>{},
  }) {
    return <EndpointModel>[
      for (var i = 0; i < kinds.length; i++)
        EndpointModel(
          id: 'e-$uuid-${i + 1}',
          homeId: homeId,
          deviceId: 'dev-$uuid',
          deviceUuid: uuid,
          channel: i + 1,
          shutterPair: (kinds[i] == 'U' || kinds[i] == 'D') ? (i + 2) ~/ 2 : null,
          name: nameOf?.call(i + 1) ?? 'Bulut ${i + 1}',
          room: 'Salon',
          endpointType: switch (kinds[i]) {
            'L' => 'light',
            'P' => 'plug',
            'I' => 'impulse',
            _ => 'shutter',
          },
          currentState: on.contains(i + 1),
          shutterPosition: (kinds[i] == 'U' || kinds[i] == 'D') ? 30 : 0,
        ),
    ];
  }

  /// Cihaz `state` yükü (CONTRACTS §2.4): röle `type` metni + tutarlı `shutters[]`.
  Map<String, dynamic> layoutJson(
    String kinds, {
    String uid = board,
    Map<int, bool> on = const <int, bool>{},
    String Function(int id)? nameOf,
    String? childLock,
  }) {
    return <String, dynamic>{
      'v': 2,
      'uid': uid,
      'fw': '1.1.0',
      'seq': 1,
      'relays': <Map<String, dynamic>>[
        for (var i = 0; i < kinds.length; i++)
          <String, dynamic>{
            'id': i + 1,
            'name': nameOf?.call(i + 1) ?? 'Pano ${i + 1}',
            'type': switch (kinds[i]) {
              'U' => 'shutter_up',
              'D' => 'shutter_down',
              'I' => 'impulse',
              _ => 'light',
            },
            'state': on[i + 1] ?? false,
          },
      ],
      'shutters': <Map<String, dynamic>>[
        for (var i = 0; i < kinds.length; i++)
          if (kinds[i] == 'U') <String, dynamic>{'pair': (i + 2) ~/ 2, 'pos': 30, 'moving': false, 'dir': 0, 'target': 255},
      ],
      'dis': <Map<String, dynamic>>[],
    };
  }

  /// Fabrika yerleşimli uç noktalarla açılmış, ilk canlı `state`'i uygulanmış donanım.
  Future<StateHarness> warm({String kinds = factory, void Function(StateHarness h)? configure}) async {
    final h = await readyHarness(endpoints: endpointsFor(kinds), configure: configure);
    h.mqtt.emitStateJson(layoutJson(kinds));
    await settle();
    return h;
  }

  List<int> relayIds(StateHarness h) => h.state.relayItems.map((r) => r.id).toList();
  List<int> shutterPairs(StateHarness h) => h.state.shutterItems.map((s) => s.pair).toList();

  group('uyuşmazlıkta gecikmeli sessiz yenileme', () {
    test('5-6. kanallar panjur oldu: TAM 2 sn sonra TAM 1 uç nokta isteği (hemen değil); kartlar yeni yerleşime geçer', () async {
      final h = await warm();
      addTearDown(h.dispose);
      expect(relayIds(h), <int>[5, 6, 7, 8]);
      expect(shutterPairs(h), <int>[1, 2]);
      final base = h.cloud.count('fetchEndpoints');
      final devicesBase = h.cloud.count('devices');

      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL'); // sunucu köprüsü ~1 sn'de eşitledi
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      expect(h.cloud.count('fetchEndpoints'), base, reason: 'hemen istek yok');
      expect(relayIds(h), <int>[5, 6, 7, 8], reason: 'liste henüz eski (lamba kartları duruyor)');

      await h.clock.elapse(const Duration(milliseconds: 1900));
      expect(h.cloud.count('fetchEndpoints'), base, reason: '2 sn dolmadı');
      await h.clock.elapse(const Duration(milliseconds: 200));
      expect(h.cloud.count('fetchEndpoints'), base + 1);

      expect(shutterPairs(h), <int>[1, 2, 3], reason: 'panjur kartı oluştu');
      expect(relayIds(h), <int>[7, 8], reason: 'lamba kartları (5, 6) kayboldu');
      expect(h.cloud.count('devices'), devicesBase, reason: 'yalnız uç nokta yüklenir (hafif yol), cihaz/kilit/huzur yok');

      await h.clock.elapse(const Duration(minutes: 3));
      expect(h.cloud.count('fetchEndpoints'), base + 1, reason: 'uyuştu: başka istek yok');
      expect(h.clock.activeTimerCount, 0, reason: 'zamanlayıcı kalmadı');
    });

    test('panjur lambaya çevrildi, lamba darbe oldu, ek modül açıldı: her yerleşim değişimi yakalanır', () async {
      for (final change in <(String, String)>[
        (factory, 'UDLLLLLL'), // 3-4 panjur -> lamba
        (factory, 'UDUDLLLI'), // röle 8 lamba -> darbe
        (factory, 'UDUDLLLLLLLLLLLL'), // RS485 ek modül (9-16)
        ('UDUDLLLLLLLLLLLL', factory), // ek modül kapandı (küçülme)
      ]) {
        final h = await warm(kinds: change.$1);
        final base = h.cloud.count('fetchEndpoints');
        h.cloud.endpoints[kHomeA] = endpointsFor(change.$2);
        h.mqtt.emitStateJson(layoutJson(change.$2));
        await settle();

        await h.clock.elapse(const Duration(milliseconds: 2100));

        expect(h.cloud.count('fetchEndpoints'), base + 1, reason: '${change.$1} -> ${change.$2}');
        h.dispose();
      }
    });

    test('özdeş kalp atışları: istek YOK, zamanlayıcı YOK, bildirim YOK', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      final timers = h.clock.activeTimerCount;
      var notifications = 0;
      h.state.addListener(() => notifications++);

      for (var i = 0; i < 6; i++) {
        h.mqtt.emitStateJson(layoutJson(factory));
        await settle();
        await h.clock.elapse(const Duration(seconds: 30));
      }

      expect(h.cloud.count('fetchEndpoints'), base);
      expect(h.clock.activeTimerCount, timers);
      expect(notifications, 0, reason: 'PF-04: özdeş kalp atışı bildirim üretmez');
    });

    test('RETAINED (bayat) ileti uyuşmazlık göstersede istek YOK', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      final timers = h.clock.activeTimerCount;

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'), retained: true);
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base);
      expect(h.clock.activeTimerCount, timers);
    });

    test('yalnız AD farkı (pano ASCII fabrika adı) istek üretmez', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');

      h.mqtt.emitStateJson(layoutJson(factory, nameOf: (id) => 'Salon Aydinlatma $id'));
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base);
    });

    test('yalnız anlık değer (röle açık/kapalı) değişimi istek üretmez', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');

      h.mqtt.emitStateJson(layoutJson(factory, on: const <int, bool>{5: true, 7: true}));
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base);
      expect(ep(h.state, 5).currentState, isTrue);
    });

    test('kısmi / tutarsız state (röleler 1..N değil, panjur kümesi uyumsuz) hiçbir zaman istek üretmez', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      final timers = h.clock.activeTimerCount;

      // Mevcut testlerin ve kısıtlı cihaz yüklerinin biçimi: yalnız 1,2,5,6 numaralı (hepsi lamba) röleler.
      h.mqtt.emitStateJson(stateJson(relays: const <int, bool>{1: false, 2: false, 5: false, 6: false}));
      h.mqtt.emitStateJson(stateJson(shutters: <Map<String, dynamic>>[
        <String, dynamic>{'pair': 3, 'pos': 10, 'moving': false, 'dir': 0, 'target': 255},
      ]));
      h.mqtt.emitStateJson(<String, dynamic>{'v': 2, 'uid': board, 'relays': <dynamic>[], 'shutters': <dynamic>[]});
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base);
      expect(h.clock.activeTimerCount, timers);
    });

    test('türü bildirilmeyen eski bellenim (type yok: hepsi lamba görünür) istek üretmez', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      final json = layoutJson(factory);
      for (final relay in json['relays'] as List<Map<String, dynamic>>) {
        relay.remove('type');
      }

      h.mqtt.emitStateJson(json);
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base);
    });

    test('uç noktalar henüz yüklenmediyse (ilk REST sürüyor / başarısız) ek zamanlayıcı kurulmaz', () async {
      final h = await warm(configure: (h) => h.cloud.fetchEndpointsError = ApiException.network());
      addTearDown(h.dispose);
      expect(h.state.endpointsLoaded, isFalse);
      final base = h.cloud.count('fetchEndpoints');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100));

      expect(h.cloud.count('fetchEndpoints'), base + 1, reason: 'yalnız PF-11 yeniden denemesi; yerleşim denemesi eklenmedi');
    });
  });

  group('sınırlar', () {
    test('kalp atışı/yeni ileti bekleyen zamanlayıcıyı uzatmaz ve ikinci zamanlayıcı kurmaz (debounce)', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      final timers = h.clock.activeTimerCount;
      await h.clock.elapse(const Duration(milliseconds: 800));
      var notifications = 0;
      h.state.addListener(() => notifications++);
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 600));
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();

      expect(h.clock.activeTimerCount, timers, reason: 'tek zamanlayıcı');
      expect(h.cloud.count('fetchEndpoints'), base, reason: 't = 1,4 sn');
      expect(notifications, 0, reason: 'özdeş uyuşmaz ileti bildirim üretmez');
      await h.clock.elapse(const Duration(milliseconds: 700)); // t = 2,1 sn
      expect(h.cloud.count('fetchEndpoints'), base + 1, reason: 'ilk iletiden 2 sn sonra TEK istek');
    });

    test('kalıcı uyuşmazlık (sunucu eşitlemesi kapalı): 2, +10, +30 sn ile TAM 3 deneme, sonra DURUR', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints'); // sunucu listesi hiç değişmez (ENDPOINT_LAYOUT_SYNC=off)

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 1900));
      expect(h.cloud.count('fetchEndpoints'), base);
      await h.clock.elapse(const Duration(milliseconds: 200)); // t = 2,1
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      await h.clock.elapse(const Duration(seconds: 9)); // t = 11,1
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      await h.clock.elapse(const Duration(seconds: 1)); // t = 12,1
      expect(h.cloud.count('fetchEndpoints'), base + 2);
      await h.clock.elapse(const Duration(seconds: 29)); // t = 41,1
      expect(h.cloud.count('fetchEndpoints'), base + 2);
      await h.clock.elapse(const Duration(seconds: 1)); // t = 42,1
      expect(h.cloud.count('fetchEndpoints'), base + 3);

      // Kalp atışları sürer (30 sn'de bir özdeş uyuşmaz state): sayaç dolu, istek YOK.
      for (var i = 0; i < 20; i++) {
        h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
        await settle();
        await h.clock.elapse(const Duration(seconds: 30));
      }
      expect(h.cloud.count('fetchEndpoints'), base + 3, reason: 'sonsuz istek yok');
      expect(h.clock.activeTimerCount, 0);
      expect(relayIds(h), <int>[5, 6, 7, 8], reason: 'liste olduğu gibi (hata yüzeye çıkmadı)');
      expect(h.state.endpointsError, isNull);
    });

    test('yerleşim imzası değişince sayaç sıfırlanır ve yeniden başlar', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('fetchEndpoints'), base + 3, reason: 'ilk imza: 3 deneme');

      h.mqtt.emitStateJson(layoutJson('UDUDUDUD')); // pano yeniden ayarlandı (yeni imza), sunucu hâlâ eski
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100));
      expect(h.cloud.count('fetchEndpoints'), base + 4, reason: 'yeni imza: yine 2 sn');
      await h.clock.elapse(const Duration(seconds: 10));
      expect(h.cloud.count('fetchEndpoints'), base + 5);
      await h.clock.elapse(const Duration(seconds: 30));
      expect(h.cloud.count('fetchEndpoints'), base + 6);
      await h.clock.elapse(const Duration(minutes: 5));
      expect(h.cloud.count('fetchEndpoints'), base + 6, reason: 'yeni imza için de en çok 3 deneme');
    });

    test('bekleyen zamanlayıcı varken imza değişirse zamanlayıcı 2 sn\'ye yeniden kurulur', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100)); // deneme 1; sonraki 10 sn sonra
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      await h.clock.elapse(const Duration(seconds: 3));

      h.mqtt.emitStateJson(layoutJson('UDUDUDUD')); // yeni imza: 10 sn beklemek yerine 2 sn
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100));

      expect(h.cloud.count('fetchEndpoints'), base + 2);
    });

    test('uyuşma sağlanınca sayaç sıfırlanır: aynı imza sonradan yine uyuşmazsa yeniden 3 deneme', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      final stale = endpointsFor(factory);
      final synced = endpointsFor('UDUDUDLL');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100)); // deneme 1: sunucu henüz eşitlemedi
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      h.cloud.endpoints[kHomeA] = synced; // sunucu eşitledi (kalp atışı gecikmesi)
      await h.clock.elapse(const Duration(seconds: 10)); // deneme 2: uyuştu
      expect(h.cloud.count('fetchEndpoints'), base + 2);
      expect(shutterPairs(h), <int>[1, 2, 3]);
      expect(h.clock.activeTimerCount, 0, reason: 'uyuştu: zamanlayıcı yok');

      // Aynı yerleşim imzası, liste yeniden eski haline düştü (ör. başka bir yoldan eski veri geldi).
      h.cloud.endpoints[kHomeA] = stale;
      await h.state.refresh(silent: true);
      await settle();
      expect(h.cloud.count('fetchEndpoints'), base + 3);
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base + 6, reason: 'sayaç sıfırdı: yine tam 3 deneme');
    });

    test('uyuşan state gelince bekleyen zamanlayıcı iptal olur (istek yok)', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(seconds: 1));
      h.mqtt.emitStateJson(layoutJson(factory)); // pano eski yerleşime döndü: uç noktalarla uyuşuyor
      await settle();
      await h.clock.elapse(const Duration(minutes: 1));

      expect(h.cloud.count('fetchEndpoints'), base);
      expect(h.clock.activeTimerCount, 0);
    });

    test('liste başka bir yoldan yenilenmişse zamanlayıcı tetiklenince İSTEK ATMAZ', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();

      await h.clock.elapse(const Duration(seconds: 1));
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');
      await h.state.refresh(silent: true); // kullanıcı çekip yeniledi / ön plana dönüş
      await settle();
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      await h.clock.elapse(const Duration(minutes: 1));

      expect(h.cloud.count('fetchEndpoints'), base + 1, reason: 'liste zaten uyuşuyor: ikinci istek yok');
    });

    test('tam yenileme sürerken paralel ikinci uç nokta isteği AÇILMAZ', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL'); // sunucu eşitledi (yanıt istek anındaki listeyle üretilir)
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();

      await h.clock.elapse(const Duration(seconds: 1));
      final gate = Completer<void>();
      h.cloud.fetchEndpointsGate = gate; // REST yığını yavaş
      final refresh = h.state.refresh(silent: true);
      await settle();
      expect(h.cloud.count('fetchEndpoints'), base + 1);

      await h.clock.elapse(const Duration(seconds: 3)); // yerleşim zamanlayıcısı tetiklendi
      expect(h.cloud.count('fetchEndpoints'), base + 1, reason: 'uçuştaki yenilemeye katılır, ikinci istek yok');

      h.cloud.fetchEndpointsGate = null;
      gate.complete();
      await refresh;
      await settle();
      await h.clock.elapse(const Duration(minutes: 1));
      expect(h.cloud.count('fetchEndpoints'), base + 1, reason: 'uçuştaki yenileme listeyi getirdi: yeni istek yok');
      expect(shutterPairs(h), <int>[1, 2, 3]);
    });
  });

  group('iptal noktaları', () {
    /// Uyuşmazlık görüldü, yenileme zamanlayıcısı bekliyor (sunucu listesi çoktan eşitlenmiş).
    Future<StateHarness> pendingLayoutRefresh() async {
      final h = await warm();
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 500));
      expect(h.clock.activeTimerCount, 1, reason: 'bekleyen yerleşim zamanlayıcısı (başka zamanlayıcı yok)');
      return h;
    }

    // Her testte iptal, olayın HEMEN ardından (zaman geçmeden) zamanlayıcının kalkmasıyla doğrulanır: tetiklenme
    // anındaki koruma denetimleri (epoch, arka plan, mod...) iptal unutulsa da isteği engellerdi; ikisi ayrı sınanır.

    test('ev değişimi zamanlayıcıyı iptal eder: ESKİ ev için istek yok', () async {
      final h = await pendingLayoutRefresh();
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = endpointsFor(factory, homeId: kHomeB);
      await h.state.fetchHomes(autoSelect: false);

      await h.state.selectHome(h.state.homeById(kHomeB)!);
      expect(h.clock.activeTimerCount, 0, reason: 'bekleyen yerleşim zamanlayıcısı iptal edildi');
      final a = h.cloud.count('fetchEndpoints:$kHomeA');
      final b = h.cloud.count('fetchEndpoints:$kHomeB');
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints:$kHomeA'), a);
      expect(h.cloud.count('fetchEndpoints:$kHomeB'), b, reason: 'B: yalnız kendi ilk yüklemesi');
    });

    test('ev değişiminden sonra yeni evin canlı iletisi KENDİ izlemesini kurar (eski evin sayacı taşınmaz)', () async {
      final h = await warm();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // A: sunucu eşitlemiyor
      await settle();
      await h.clock.elapse(const Duration(minutes: 2)); // A: 3 deneme harcandı
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = endpointsFor(factory, homeId: kHomeB);
      await h.state.fetchHomes(autoSelect: false);
      await h.state.selectHome(h.state.homeById(kHomeB)!);
      final b = h.cloud.count('fetchEndpoints:$kHomeB');

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // B'de aynı imza: yeni evin sayacı sıfırdan
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100));

      expect(h.cloud.count('fetchEndpoints:$kHomeB'), b + 1);
    });

    test('dispose zamanlayıcıyı iptal eder (sızıntı yok)', () async {
      final h = await pendingLayoutRefresh();
      final calls = h.cloud.count('fetchEndpoints');
      h.dispose();
      expect(h.clock.activeTimerCount, 0, reason: 'dispose bekleyen zamanlayıcıyı iptal etti');

      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), calls);
    });

    test('arka plana geçiş zamanlayıcıyı iptal eder; ön plana dönüş yalnız TEK snapshot alır', () async {
      final h = await pendingLayoutRefresh();
      addTearDown(h.dispose);
      h.state.handleLifecycleState(AppLifecycleState.paused);
      await settle();
      expect(h.clock.activeTimerCount, 0, reason: 'bekleyen yerleşim zamanlayıcısı iptal edildi');
      final calls = h.cloud.count('fetchEndpoints');

      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('fetchEndpoints'), calls, reason: 'arka planda ağ çağrısı yok');

      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(h.cloud.count('fetchEndpoints'), calls + 1, reason: 'ön plana dönüş: tek snapshot');
      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('fetchEndpoints'), calls + 1, reason: 'eski zamanlayıcı yeniden canlanmadı');
      expect(shutterPairs(h), <int>[1, 2, 3], reason: 'snapshot yeni yerleşimi getirdi');
    });

    test('arka plandayken gelen geç canlı ileti zamanlayıcı KURMAZ', () async {
      final h = await warm();
      addTearDown(h.dispose);
      h.state.handleLifecycleState(AppLifecycleState.paused);
      await settle();
      final calls = h.cloud.count('fetchEndpoints');
      final timers = h.clock.activeTimerCount;

      h.state.applyDeviceStateForTesting(DeviceStatus.fromJson(layoutJson('UDUDUDLL'), filterPhantomShutters: false));
      expect(h.clock.activeTimerCount, timers);
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), calls);
      expect(h.clock.activeTimerCount, timers);
    });

    test('çıkış (logout) zamanlayıcıyı iptal eder', () async {
      final h = await pendingLayoutRefresh();
      addTearDown(h.dispose);
      await h.state.logout();
      expect(h.clock.activeTimerCount, 0, reason: 'bekleyen yerleşim zamanlayıcısı iptal edildi');
      final calls = h.cloud.count('fetchEndpoints');

      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), calls);
    });

    test('mod değişimi (doğrudan mod) zamanlayıcıyı iptal eder', () async {
      // Karşılaştırma: bekleyen yerleşim zamanlayıcısı OLMAYAN donanımda doğrudan moda geçildiğindeki zamanlayıcı sayısı.
      final control = await warm();
      addTearDown(control.dispose);
      expect(await control.state.setMode(AppMode.direct), isTrue);
      final expected = control.clock.activeTimerCount;

      final h = await pendingLayoutRefresh();
      addTearDown(h.dispose);
      expect(await h.state.setMode(AppMode.direct), isTrue);
      expect(h.clock.activeTimerCount, expected, reason: 'yerleşim zamanlayıcısı iptal edildi; yalnız doğrudan modun kendi zamanlayıcıları kaldı');
      final calls = h.cloud.count('fetchEndpoints');

      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), calls, reason: 'doğrudan modda bulut uç nokta isteği yok');
    });

    test('zamanlayıcı tetiklenirken oturum yoksa istek atılmaz; yeniden oturumda canlı ileti izlemeyi yeniden kurar', () async {
      final h = await pendingLayoutRefresh();
      addTearDown(h.dispose);
      final calls = h.cloud.count('fetchEndpoints');
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);

      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('fetchEndpoints'), calls, reason: 'oturum yok: REST yapılmaz');

      h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 2100));
      expect(h.cloud.count('fetchEndpoints'), calls + 1);
    });

    test('oturum yokken (kilitli/çıkış) gelen canlı ileti izleme ve zamanlayıcı KURMAZ', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final calls = h.cloud.count('fetchEndpoints');
      final timers = h.clock.activeTimerCount;
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      expect(h.clock.activeTimerCount, timers);
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), calls);
    });
  });

  group('uçuştaki istek', () {
    test('uçuş sırasında gelen yeni imza yeni zamanlayıcı kurmaz; istek bitince 2 sn sonra ele alınır', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // sunucu eşitlemiyor (liste eski)
      await settle();
      final gate = Completer<void>();
      h.cloud.fetchEndpointsGate = gate; // REST yavaş
      await h.clock.elapse(const Duration(milliseconds: 2100)); // deneme 1 uçuşta (kapıda)
      expect(h.cloud.count('fetchEndpoints'), base + 1);

      h.mqtt.emitStateJson(layoutJson('UDUDUDUD')); // uçuş sırasında pano yeniden ayarlandı
      await settle();
      expect(h.clock.activeTimerCount, 0, reason: 'uçuşta yeni zamanlayıcı kurulmaz');

      h.cloud.fetchEndpointsGate = null;
      gate.complete();
      await settle();
      expect(h.clock.activeTimerCount, 1, reason: 'istek bitti: yeni imza için zamanlayıcı kuruldu');
      await h.clock.elapse(const Duration(milliseconds: 2100));
      expect(h.cloud.count('fetchEndpoints'), base + 2, reason: 'yeni imza: 2 sn sonra (10 sn değil)');
    });

    test('uçuş sırasında dispose: sonuç işlenmez, zamanlayıcı kurulmaz', () async {
      final h = await warm();
      final base = h.cloud.count('fetchEndpoints');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      final gate = Completer<void>();
      h.cloud.fetchEndpointsGate = gate;
      await h.clock.elapse(const Duration(milliseconds: 2100));
      expect(h.cloud.count('fetchEndpoints'), base + 1);

      h.dispose();
      gate.complete();
      await settle();
      await h.clock.elapse(const Duration(minutes: 2));

      expect(h.cloud.count('fetchEndpoints'), base + 1);
      expect(h.clock.activeTimerCount, 0);
    });
  });

  group('arayüz kartları', () {
    testWidgets('yenileme sonrası kartlar yeni yerleşime geçer: panjur kartı oluşur, lamba kartları kaybolur', (tester) async {
      final h = (await tester.runAsync(() => warm()))!;
      addTearDown(h.dispose);
      await pumpApp(tester, child: const Scaffold(body: SingleChildScrollView(child: DeviceSections())), state: h.state);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('card_relay_5')), findsOneWidget);
      expect(find.byKey(const Key('card_relay_6')), findsOneWidget);
      expect(find.byKey(const Key('card_shutter_1')), findsOneWidget);
      expect(find.byKey(const Key('card_shutter_3')), findsNothing);

      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL'); // sunucu köprüsü eşitledi
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await tester.runAsync(() async {
        await settle();
        await h.clock.elapse(const Duration(milliseconds: 2100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byKey(const Key('card_shutter_3')), findsOneWidget, reason: 'yeni panjur kartı oluştu');
      expect(find.byKey(const Key('card_relay_5')), findsNothing, reason: 'lamba kartı (5) kayboldu');
      expect(find.byKey(const Key('card_relay_6')), findsNothing, reason: 'lamba kartı (6) kayboldu');
      expect(find.byKey(const Key('card_relay_7')), findsOneWidget);
      expect(find.byKey(const Key('card_relay_8')), findsOneWidget);
      expect(find.byKey(const Key('card_shutter_1')), findsOneWidget);
    });
  });

  group('komut ve arayüz güvenliği', () {
    test('bekleyen komut varken yenileme ERTELENİR (iyimser değer ve onay bozulmaz); sonra TEK istek', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();

      await h.state.setRelay(7, true); // iletildi, cihaz onayı bekleniyor (2,5 sn pencere)
      expect(h.state.commandPipeline.hasPending, isTrue);
      await h.clock.elapse(const Duration(milliseconds: 2100)); // zamanlayıcı tetiklendi: komut sürüyor -> ertelendi
      expect(h.cloud.count('fetchEndpoints'), base, reason: 'bekleyen komut varken REST ile yarışılmaz');
      expect(ep(h.state, 7).currentState, isTrue, reason: 'iyimser değer korunuyor');

      // Cihaz onayladı; sunucu köprüsü de aynı iletiyle veritabanını güncelledi (REST artık onu görür).
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL', on: const <int>{7});
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL', on: const <int, bool>{7: true}));
      await settle();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(h.cloud.count('fetchEndpoints'), base);

      await h.clock.elapse(const Duration(milliseconds: 1100)); // erteleme süresi doldu
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      expect(shutterPairs(h), <int>[1, 2, 3]);
      expect(ep(h.state, 7).currentState, isTrue, reason: 'onaylanan gerçek değer yenilemeden sonra da duruyor');
      await h.clock.elapse(const Duration(minutes: 2));
      expect(h.cloud.count('fetchEndpoints'), base + 1);
    });

    test('bekleyen komut sonsuza dek ertelemez: en çok 5 erteleme sonra yenileme yapılır; iyimser değer ezilmez', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      final reply = Completer<CommandResult>(); // komut yanıtı hiç gelmiyor (yavaş ağ)
      h.cloud.sendCommandHandler = (homeId, deviceId, command) => reply.future;
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      unawaited(h.state.setRelay(7, true));
      await settle();
      expect(h.state.commandPipeline.hasPending, isTrue);

      await h.clock.elapse(const Duration(milliseconds: 6900)); // 2 sn + 4 erteleme
      expect(h.cloud.count('fetchEndpoints'), base);
      await h.clock.elapse(const Duration(milliseconds: 300)); // t = 7,2 sn: 5 ertelemeden sonra yenileme
      expect(h.cloud.count('fetchEndpoints'), base + 1);

      expect(shutterPairs(h), <int>[1, 2, 3]);
      expect(ep(h.state, 7).currentState, isTrue, reason: 'bekleyen komutun iyimser hedefi REST eski değeriyle ezilmedi');
    });

    test('REST gecikmesi: en taze canlı state değeri veritabanının eski değeriyle ezilmez (kart geri dönmez)', () async {
      final h = await warm();
      addTearDown(h.dispose);
      // Sunucu yerleşimi eşitledi AMA veritabanı son canlı iletiden (röle 7 açıldı) milisaniyeler geride.
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL'); // röle 7 kapalı (eski)
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL', on: const <int, bool>{7: true})); // cihaz: röle 7 açık
      await settle();
      expect(ep(h.state, 7).currentState, isTrue);

      await h.clock.elapse(const Duration(milliseconds: 2100));

      expect(shutterPairs(h), <int>[1, 2, 3], reason: 'yeni yerleşim geldi');
      expect(ep(h.state, 7).currentState, isTrue, reason: 'canlı değer REST\'in gecikmeli değeriyle ezilmedi');
    });

    test('sessiz: yükleme göstergesi HİÇ açılmaz, hata göstergesi çıkmaz; yalnız liste değişince TEK bildirim', () async {
      final h = await warm();
      addTearDown(h.dispose);
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();
      final loading = <bool>[];
      var notifications = 0;
      h.state.addListener(() {
        notifications++;
        loading.add(h.state.endpointsLoading);
      });

      await h.clock.elapse(const Duration(milliseconds: 2100));

      expect(loading, isNotEmpty);
      expect(loading.any((v) => v), isFalse, reason: 'silent: _endpointsLoading hiç true olmadı');
      expect(notifications, 1, reason: 'liste değişti: tek bildirim');
      expect(h.state.endpointsLoading, isFalse);
      expect(h.state.endpointsError, isNull);
    });

    test('liste DEĞİŞMEDİYSE (sunucu henüz eşitlemedi) deneme bildirim üretmez', () async {
      final h = await warm();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // sunucu listesi eski kalıyor
      await settle();
      var notifications = 0;
      h.state.addListener(() => notifications++);

      await h.clock.elapse(const Duration(seconds: 13)); // deneme 1 ve 2

      expect(notifications, 0, reason: 'aynı içerikli liste: arayüz yeniden kurulmaz');
    });

    test('başarısız deneme hata göstergesi (endpointsError / banner) ÇIKARMAZ; sonraki deneme yeniden dener', () async {
      final h = await warm();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.cloud.fetchEndpointsError = ApiException.network();
      h.cloud.endpoints[kHomeA] = endpointsFor('UDUDUDLL');
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL'));
      await settle();

      await h.clock.elapse(const Duration(milliseconds: 2100));
      expect(h.cloud.count('fetchEndpoints'), base + 1);
      expect(h.state.endpointsError, isNull, reason: 'arka plandaki isteğe bağlı yenileme ekranı hataya çevirmez');
      expect(h.state.endpointsLoaded, isTrue);
      expect(relayIds(h), <int>[5, 6, 7, 8], reason: 'son bilinen liste korunur');

      h.cloud.fetchEndpointsError = null; // ağ geldi
      await h.clock.elapse(const Duration(seconds: 10));
      expect(h.cloud.count('fetchEndpoints'), base + 2);
      expect(shutterPairs(h), <int>[1, 2, 3]);
      expect(h.state.endpointsError, isNull);
    });

    test('daha önce görünen "güncellenemedi" hatası, başarılı sessiz yenilemeyle (liste aynı kalsa da) temizlenir ve bildirilir', () async {
      final h = await warm();
      addTearDown(h.dispose);
      h.cloud.fetchEndpointsError = ApiException.network();
      await h.state.refresh(silent: true); // başka bir yenileme hata bıraktı
      await settle();
      expect(h.state.endpointsError, isNotNull);
      h.cloud.fetchEndpointsError = null;
      h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // sunucu listesi eski kalıyor (içerik aynı)
      await settle();
      var notified = false;
      h.state.addListener(() => notified = true);

      await h.clock.elapse(const Duration(seconds: 3));

      expect(h.state.endpointsError, isNull, reason: 'başarılı yükleme hatayı temizledi');
      expect(notified, isTrue, reason: 'kaybolan "güncellenemedi" şeridi arayüze bildirildi');
    });
  });

  group('çok panolu ev', () {
    Future<StateHarness> twoBoards() async {
      final h = await readyHarness(
        endpoints: <EndpointModel>[
          ...endpointsFor(factory),
          ...endpointsFor('LLLLLLLL', uuid: otherBoard),
        ],
      );
      h.mqtt.emitStateJson(layoutJson(factory));
      h.mqtt.emitStateJson(layoutJson('LLLLLLLL', uid: otherBoard));
      await settle();
      return h;
    }

    test('uyuşan diğer panonun kalp atışı, uyuşmayan panonun bekleyen zamanlayıcısını İPTAL ETMEZ', () async {
      final h = await twoBoards();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');
      h.cloud.endpoints[kHomeA] = <EndpointModel>[
        ...endpointsFor('UDUDUDLL'),
        ...endpointsFor('LLLLLLLL', uuid: otherBoard),
      ];

      h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // A uyuşmaz
      await settle();
      await h.clock.elapse(const Duration(seconds: 1));
      h.mqtt.emitStateJson(layoutJson('LLLLLLLL', uid: otherBoard)); // B uyuşuyor
      await settle();
      await h.clock.elapse(const Duration(milliseconds: 1100));

      expect(h.cloud.count('fetchEndpoints'), base + 1);
      expect(shutterPairs(h), <int>[1, 2, 3]);
    });

    test('iki pano da kalıcı uyuşmazsa istekler ORTAK: toplam yine en çok 3 deneme (sonsuz döngü yok)', () async {
      final h = await twoBoards();
      addTearDown(h.dispose);
      final base = h.cloud.count('fetchEndpoints');

      for (var i = 0; i < 30; i++) {
        h.mqtt.emitStateJson(layoutJson('UDUDUDLL')); // A: sunucu eşitlemiyor
        h.mqtt.emitStateJson(layoutJson('LLLLLLLI', uid: otherBoard)); // B: sunucu eşitlemiyor
        await settle();
        await h.clock.elapse(const Duration(seconds: 30));
      }

      expect(h.cloud.count('fetchEndpoints'), base + 3);
      expect(h.clock.activeTimerCount, 0);
    });
  });
}
