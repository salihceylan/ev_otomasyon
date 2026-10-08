import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/dashboard/labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';
import 'e1_helpers.dart';

/// Daire panosu durumları: yükleme / hata / boş ayrımı, çevrimdışı açılış, sistem durumu,
/// oda çipleri, doğrudan (LAN) mod ve erişim süresi dolmuş misafir.
void main() {
  Widget body() => const Scaffold(body: ApartmentDashboard());

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Giriş yapmış ama henüz ev yüklenmemiş durum (REST çağrıları testte denetlenir).
  Future<StateHarness> loggedInHarness({void Function(StateHarness h)? configure}) async {
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe Yılmaz', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    configure?.call(h);
    return h;
  }

  Map<String, dynamic> lanStatus({bool childLock = false}) => <String, dynamic>{
        'device': 'AHBU-S3-TEST01',
        'name': 'Salon Panosu',
        'fw': '1.1.0',
        'provisioned': true,
        'wifi_connected': true,
        'wifi_sta_ssid': 'EvAgi',
        'wifi_sta_ip': '192.168.1.20',
        'ip': '192.168.1.20',
        'child_lock': childLock,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': false},
          <String, dynamic>{'id': 2, 'name': 'Spot', 'type': 0, 'state': true},
        ],
        'shutters': <dynamic>[],
        'dis': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'state': true},
          <String, dynamic>{'id': 2, 'state': false},
        ],
      };

  group('Ev listesi: yükleme / hata / boş ayrımı', () {
    testWidgets('yüklenirken spinner gösterilir; zaman aşımından sonra "Yeniden dene" çıkar', (tester) async {
      final gate = Completer<void>();
      final h = await loggedInHarness(configure: (h) => h.cloud.fetchHomesGate = gate);
      addTearDown(h.dispose);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      unawaited(h.state.fetchHomes());
      await pumpPage(tester, h.state, body());

      expect(byKeyName('loading_view'), findsOneWidget);
      expect(find.text('Daireleriniz yükleniyor…'), findsOneWidget);
      expect(find.text('Henüz kayıtlı bir daireniz yok'), findsNothing, reason: 'yükleme "daire yok" sanılmaz');

      h.clock.advance(const Duration(seconds: 16));
      await flush(tester);
      expect(byKeyName('btn_retry'), findsOneWidget);
    });

    testWidgets('ev listesi HATASI "daire yok" değildir: hata kartı + yeniden dene; başarılı yanıtta içerik gelir',
        (tester) async {
      final h = await loggedInHarness(configure: (h) {
        h.cloud.fetchHomesError = kServerError;
        h.cloud.homes = <HomeModel>[testHome()];
        h.cloud.endpoints[kHomeA] = testEndpoints();
      });
      addTearDown(h.dispose);
      await tester.runAsync(() => h.state.fetchHomes());
      await pumpPage(tester, h.state, body());

      expect(byKeyName('error_card'), findsOneWidget);
      expect(find.text('Daireler yüklenemedi'), findsOneWidget);
      expect(find.text('Henüz kayıtlı bir daireniz yok'), findsNothing);
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);

      h.cloud.fetchHomesError = null;
      await tester.tap(byKeyName('btn_retry'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);
      expect(byKeyName('error_card'), findsNothing);
      expect(byKeyName('card_relay_1'), findsOneWidget);
    });

    testWidgets('başarılı BOŞ ev listesi "Henüz kayıtlı daireniz yok" karşılamasını gösterir', (tester) async {
      final h = await loggedInHarness();
      addTearDown(h.dispose);
      await tester.runAsync(() => h.state.fetchHomes());
      await pumpPage(tester, h.state, body());

      expect(byKeyName('view_homeless'), findsOneWidget);
      expect(find.text('Henüz kayıtlı bir daireniz yok'), findsOneWidget);
      expect(find.text('Hoş Geldiniz, Ayşe!'), findsOneWidget);
      expect(byKeyName('btn_join_code'), findsOneWidget);
      expect(byKeyName('btn_scan_qr'), findsOneWidget);
      expect(byKeyName('btn_claim_manual'), findsOneWidget, reason: 'daire sahibi olmayan kullanıcı ilk cihazını eşleyebilir');
      expect(byKeyName('error_card'), findsNothing);
    });

    testWidgets('daire silinmiş ama başka dairesi varsa daire seçici gösterilir; seçince içerik gelir', (tester) async {
      final h = await pumpReady(tester, body());
      final other = HomeModel(id: kHomeB, name: 'Yazlık', role: 'resident', mqttTopicId: 'h_other');
      h.e1.homes = <HomeModel>[other];
      h.e1.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      await tester.runAsync(() => h.state.fetchHomes(autoSelect: false));
      await flush(tester);

      expect(byKeyName('view_pick_home'), findsOneWidget);
      expect(find.text('Yazlık'), findsOneWidget);

      await tester.tap(byKeyName('card_home_$kHomeB'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);
      expect(h.state.activeHome?.id, kHomeB);
      expect(byKeyName('card_relay_1'), findsOneWidget);
    });
  });

  group('Cihaz listesi: yükleme / hata / boş ayrımı', () {
    testWidgets('ev sahibine, başarılı BOŞ cihaz yanıtında "Evinize Hoş Geldiniz" ve karekod eşleme gösterilir',
        (tester) async {
      await pumpReady(tester, body(), role: 'owner', endpoints: <EndpointModel>[]);
      expect(byKeyName('card_welcome_claim'), findsOneWidget);
      expect(find.text('Evinize Hoş Geldiniz!'), findsOneWidget);
      expect(byKeyName('btn_scan_qr'), findsOneWidget);
    });

    for (final role in <String>['resident', 'service_user']) {
      testWidgets('$role için boş cihaz yanıtı cihaz eşleme önermez (yalnızca bilgi kartı)', (tester) async {
        // uyelik-13: evdeki service_user üyeliği yalnız küresel personel hesabında geçerlidir.
        await pumpReady(
          tester,
          body(),
          role: role,
          globalRole: role == 'service_user' ? 'service_user' : 'user',
          endpoints: <EndpointModel>[],
        );
        expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
        expect(byKeyName('btn_scan_qr'), findsNothing);
        expect(byKeyName('card_empty_home'), findsOneWidget);
      });
    }

    testWidgets('misafire boş cihaz yanıtında eşleme önerilmez', (tester) async {
      await pumpReady(tester, body(), home: guestHome(), endpoints: <EndpointModel>[]);
      expect(byKeyName('card_welcome_claim'), findsNothing);
      expect(byKeyName('card_empty_home'), findsOneWidget);
    });

    testWidgets('cihaz listesi HATASI "cihaz yok" değildir: hata kartı + yeniden dene (ev sahibinde bile karşılama yok)',
        (tester) async {
      final h = await pumpReady(
        tester,
        body(),
        role: 'owner',
        configure: (h) => h.e1.fetchEndpointsError = kServerError,
      );
      expect(byKeyName('error_card'), findsOneWidget);
      expect(find.text('Cihazlar yüklenemedi'), findsOneWidget);
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);

      h.e1.fetchEndpointsError = null;
      await tester.tap(byKeyName('btn_retry'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);
      expect(byKeyName('card_relay_1'), findsOneWidget);
    });
  });

  group('Çevrimdışı açılış (önbellekten daireler)', () {
    Future<StateHarness> pumpCached(WidgetTester tester) async {
      final h = await loggedInHarness(configure: (h) {
        h.cloud.fetchHomesError = kNetworkError;
        h.cloud.endpoints[kHomeA] = testEndpoints();
        h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', online: true)];
      });
      addTearDown(h.dispose);
      await tester.runAsync(() async {
        await h.storage.saveHomesCache('user-1', <HomeModel>[testHome()]);
        await h.state.fetchHomes();
      });
      await pumpPage(tester, h.state, body());
      return h;
    }

    testWidgets('kayıtlı daire gösterilir, "çevrimdışı" şeridi ve yeniden dene çıkar', (tester) async {
      final h = await pumpCached(tester);
      expect(h.state.homesFromCache, isTrue);
      expect(byKeyName('banner_offline'), findsOneWidget);
      expect(find.textContaining('Çevrimdışısınız'), findsOneWidget);
      expect(byKeyName('btn_banner_retry'), findsOneWidget);
      expect(byKeyName('btn_go_local'), findsOneWidget, reason: 'ev sahibi yerel moda geçebilir');
      expect(byKeyName('card_relay_1'), findsOneWidget, reason: 'kayıtlı daire kontrolleri görünür');
    });

    testWidgets('bağlantı geri gelince yeniden dene şeridi kaldırır', (tester) async {
      final h = await pumpCached(tester);
      h.cloud.fetchHomesError = null;
      h.cloud.homes = <HomeModel>[testHome()];
      await tester.tap(byKeyName('btn_banner_retry'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);
      expect(byKeyName('banner_offline'), findsNothing);
    });

    testWidgets('"Yerel moda geç" yerel moda geçirir', (tester) async {
      final h = await pumpCached(tester);
      await tester.tap(byKeyName('btn_go_local'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await flush(tester);
      expect(h.state.mode, AppMode.direct);
    });
  });

  group('Sistem durumu ve cihaz çevrimdışı bildirimi', () {
    testWidgets('"Sistem Hazır" yalnızca broker bağlı ve cihaz çevrimiçiyken görünür', (tester) async {
      await pumpReady(tester, body());
      expect(find.text('Sistem Hazır'), findsOneWidget);
    });

    testWidgets('broker koptuysa "Canlı izleme kesik" (Sistem Hazır DEĞİL)', (tester) async {
      await pumpReady(tester, body(), brokerConnected: false);
      expect(find.text('Sistem Hazır'), findsNothing);
      expect(find.text('Canlı izleme kesik'), findsOneWidget);
    });

    testWidgets('cihaz çevrimdışıysa "Pano çevrimdışı" + ev sahibine Wi-Fi kurtarma önerilir', (tester) async {
      final h = await pumpReady(tester, body());
      h.mqtt.emitPresence(false);
      await flush(tester);

      expect(find.text('Sistem Hazır'), findsNothing);
      expect(find.text('Pano çevrimdışı'), findsWidgets);
      expect(byKeyName('notice_device_offline'), findsOneWidget);
      expect(byKeyName('btn_wifi_recovery'), findsOneWidget);
      expect(byKeyName('btn_system_doctor'), findsOneWidget);
    });

    testWidgets('misafire Wi-Fi kurtarma ve sistem doktoru önerilmez (cihaz çevrimdışı olsa da)', (tester) async {
      final h = await pumpReady(tester, body(), home: guestHome());
      h.mqtt.emitPresence(false);
      await flush(tester);
      expect(byKeyName('notice_device_offline'), findsOneWidget);
      expect(byKeyName('btn_wifi_recovery'), findsNothing);
      expect(byKeyName('btn_system_doctor'), findsNothing);
    });

    testWidgets('cihaz çevrimiçiyken kurtarma bildirimi görünmez', (tester) async {
      await pumpReady(tester, body());
      expect(byKeyName('notice_device_offline'), findsNothing);
    });

    testWidgets('"Panjur Hareketli" yalnızca gerçekten hareket eden panjurları sayar (açık konum hareket değildir)',
        (tester) async {
      final h = await pumpReady(tester, body());
      expect(find.text('Panjurlar Sabit'), findsOneWidget, reason: 'panjur %30 açık ama hareket etmiyor');

      h.mqtt.emitStateJson(stateJson(shutters: <Map<String, dynamic>>[
        <String, dynamic>{'pair': 2, 'pos': 40, 'moving': true, 'dir': 1, 'target': 100},
      ]));
      await flush(tester);
      expect(find.text('1 Panjur Hareketli'), findsOneWidget);
    });
  });

  group('Oda çipleri (bulut)', () {
    List<EndpointModel> rooms() => <EndpointModel>[
          EndpointModel(id: 'a', homeId: kHomeA, deviceUuid: 'AHBU-S3-TEST01', channel: 1, name: 'Avize', room: 'salon', endpointType: 'light', currentState: false),
          EndpointModel(id: 'b', homeId: kHomeA, deviceUuid: 'AHBU-S3-TEST01', channel: 2, name: 'Yatak Lambası', room: 'yatak_odasi', endpointType: 'light', currentState: false),
          EndpointModel(id: 'c', homeId: kHomeA, deviceUuid: 'AHBU-S3-TEST01', channel: 5, name: 'Komodin', room: 'Yatak Odası', endpointType: 'light', currentState: false),
        ];

    testWidgets('çipler uç noktalardan türetilir; yazım biçimleri tek odada birleşir ve etiketler normalleşir', (tester) async {
      await pumpReady(tester, body(), endpoints: rooms());
      expect(byKeyName('chip_room_all'), findsOneWidget);
      expect(find.text('Salon'), findsOneWidget);
      expect(find.text('Yatak Odası'), findsOneWidget, reason: 'yatak_odasi ve "Yatak Odası" aynı oda');
      expect(find.textContaining('yatak_odasi'), findsNothing, reason: 'slug ham görünmez');
      expect(find.text('Balkon'), findsNothing, reason: 'sabit oda listesi yok');
    });

    testWidgets('bir odayı seçmek yalnızca o odanın kartlarını gösterir', (tester) async {
      await pumpReady(tester, body(), endpoints: rooms());
      expect(byKeyName('card_relay_1'), findsOneWidget);
      expect(byKeyName('card_relay_2'), findsOneWidget);

      await tester.tap(byKeyName('chip_room_yatak_odasi'));
      await flush(tester);
      expect(byKeyName('card_relay_1'), findsNothing);
      expect(byKeyName('card_relay_2'), findsOneWidget);
      expect(byKeyName('card_relay_5'), findsOneWidget);

      await tester.tap(byKeyName('chip_room_all'));
      await flush(tester);
      expect(byKeyName('card_relay_1'), findsOneWidget);
    });

    testWidgets('tek oda varsa çip satırı gösterilmez', (tester) async {
      await pumpReady(tester, body());
      expect(byKeyName('chip_room_all'), findsNothing);
    });

    test('oda etiketi/anahtarı normalleştirme', () {
      expect(roomLabel('yatak_odasi'), 'Yatak Odası');
      expect(roomLabel('YATAK ODASI'), 'Yatak Odası');
      expect(roomLabel('cocuk-odasi'), 'Çocuk Odası');
      expect(roomLabel('çamaşır odası'), 'Çamaşır Odası');
      expect(roomLabel('  '), 'Genel');
      expect(roomKey('Yatak Odası'), roomKey('yatak_odasi'));
      expect(roomKey('İÇ AVLU'), 'ic avlu');
    });
  });

  group('Doğrudan (LAN) mod', () {
    Future<StateHarness> localHarness(WidgetTester tester, {bool reachable = true, Map<String, dynamic>? status}) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (request) {
        if (!reachable) throw http.ClientException('erişilemiyor');
        return jsonResponse(status ?? lanStatus());
      });
      await tester.runAsync(() => h.state.setHost('192.168.1.20'));
      return h;
    }

    testWidgets('cihaz yanıt verince kartlar gösterilir; oda çipleri GİZLİDİR', (tester) async {
      final h = await localHarness(tester);
      await pumpPage(tester, h.state, body());

      expect(byKeyName('card_relay_1'), findsOneWidget);
      expect(byKeyName('card_relay_2'), findsOneWidget);
      expect(byKeyName('chip_room_all'), findsNothing);
      expect(find.text('Sistem Hazır'), findsOneWidget);
      expect(byKeyName('card_di_1'), findsOneWidget);
      expect(byKeyName('card_di_2'), findsOneWidget);
    });

    testWidgets('çocuk kilidi açıkken duvar butonu bölümü neden çalışmadığını açıklar', (tester) async {
      final h = await localHarness(tester, status: lanStatus(childLock: true));
      await pumpPage(tester, h.state, body());
      expect(byKeyName('note_child_lock_wall'), findsOneWidget);
      expect(find.textContaining('duvar anahtarları devre dışı'), findsWidgets);
    });

    testWidgets('cihaza ulaşılamazsa sonsuz spinner yerine hata kartı, yeniden dene ve bulut yolu çıkar', (tester) async {
      final h = await localHarness(tester, reachable: false);
      await pumpPage(tester, h.state, body());

      expect(h.state.connState, ConnectionStateEnum.offline);
      expect(byKeyName('error_card'), findsOneWidget);
      expect(find.text('Cihaza ulaşılamıyor'), findsWidgets);
      expect(byKeyName('btn_retry'), findsOneWidget);
      expect(byKeyName('btn_open_settings'), findsOneWidget);
      expect(byKeyName('btn_go_cloud'), findsOneWidget);
      expect(byKeyName('btn_wifi_recovery'), findsNothing, reason: 'girişsiz yerel modda Wi-Fi kurtarma yetkisi yoktur');
    });

    testWidgets('bağlantı kurulurken zaman aşımı sonrası "Yeniden dene" çıkar', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      await pumpPage(tester, h.state, body());
      expect(byKeyName('loading_view'), findsOneWidget);
      expect(find.text('Cihaza bağlanılıyor…'), findsOneWidget);

      h.clock.advance(const Duration(seconds: 16));
      await flush(tester);
      expect(byKeyName('btn_retry'), findsOneWidget);
    });
  });

  group('Erişim süresi dolmuş misafir', () {
    testWidgets('"Erişim süreniz doldu" ekranı gösterilir; cihaz kartı ve senaryolar yoktur', (tester) async {
      final h = await pumpReady(tester, body(), home: guestHome(hours: 1, name: 'Yazlık'));
      expect(byKeyName('card_relay_1'), findsOneWidget);

      h.clock.advance(const Duration(hours: 2));
      await flush(tester);

      expect(byKeyName('view_guest_expired'), findsOneWidget);
      expect(find.text('Erişim süreniz doldu'), findsOneWidget);
      expect(find.textContaining('Yazlık için misafir erişiminiz'), findsOneWidget);
      expect(byKeyName('card_relay_1'), findsNothing);
      expect(byKeyName('card_scenario_leaving'), findsNothing);
      expect(byKeyName('btn_refresh_homes'), findsOneWidget);
    });

    testWidgets('bireysel-2: süresi dolan misafir kendi panosunu karekodla ya da elle eşleyebilir', (tester) async {
      final h = await pumpReady(tester, body(), home: guestHome(hours: 1, name: 'Yazlık'));
      h.clock.advance(const Duration(hours: 2));
      await flush(tester);
      expect(byKeyName('view_guest_expired'), findsOneWidget);
      expect(h.state.capabilities.canClaimDevice, isTrue);
      expect(byKeyName('btn_guest_scan_qr'), findsOneWidget);
      expect(find.text('Karekod ile Cihaz Eşle'), findsOneWidget);
      expect(byKeyName('btn_guest_claim_manual'), findsOneWidget);
      expect(find.text('Cihaz Kodunu Elle Gir'), findsOneWidget);
    });

    testWidgets('başka (süresi dolmamış) dairesi varsa "Başka daireye geç" ile geçilebilir', (tester) async {
      final h = await pumpReady(
        tester,
        body(),
        configure: (h) {
          h.e1.homes = <HomeModel>[guestHome(hours: 1, name: 'Yazlık'), testHome(id: kHomeB, name: 'Ev B')];
          h.e1.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
        },
      );
      h.clock.advance(const Duration(hours: 2));
      await flush(tester);
      expect(byKeyName('btn_switch_home'), findsOneWidget);

      await tester.tap(byKeyName('btn_switch_home'));
      await tester.pumpAndSettle();
      expect(byKeyName('sheet_home_switcher'), findsOneWidget);
      await tester.tap(byKeyName('card_home_$kHomeB'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(h.state.activeHome?.id, kHomeB);
      expect(byKeyName('view_guest_expired'), findsNothing);
    });
  });

  group('Yerleşim: açık tema, dar ekran ve yazı ölçeği 1.5', () {
    for (final scale in <double>[1.0, 1.5]) {
      testWidgets('daire içeriği 320 dp ve ölçek $scale iken taşmaz (açık tema)', (tester) async {
        final h = await pumpReady(
          tester,
          body(),
          endpoints: litEndpoints(),
          size: const Size(320, 720),
          textScale: scale,
          themeMode: ThemeMode.light,
        );
        h.mqtt.emitStateJson(stateJson(childLock: true));
        await flush(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('boş ev / hata / misafir ekranları dar ekranda taşmaz', (tester) async {
      await pumpReady(
        tester,
        body(),
        endpoints: <EndpointModel>[],
        size: const Size(320, 720),
        textScale: 1.5,
        themeMode: ThemeMode.light,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
