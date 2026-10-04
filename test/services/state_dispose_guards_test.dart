import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// PF-34 (WP-STATE, S5): `dispose()` sırasında süren bir zincir sonradan periyodik zamanlayıcı, yoklama, MQTT
/// bağlantısı ya da ağ isteği KURMAZ (sızıntı: kapatılmış durumun zamanlayıcısı sonsuza dek döner / yetim istek).
/// Kanıt: `FakeClock.activeTimerCount == 0`, doğrudan cihaza giden istek yok, `FakeMqtt.startCount` artmaz.
void main() {
  Future<void> settle() => pumpEventQueue();

  Map<String, dynamic> statusBody() => <String, dynamic>{
        'device_name': 'Pano',
        'ip': '192.168.1.30',
        'wifi_connected': true,
        'child_lock': false,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 3, 'name': 'Mutfak', 'type': 0, 'state': false},
        ],
        'shutters': <Map<String, dynamic>>[],
        'dis': <Map<String, dynamic>>[],
      };

  /// Giriş yapmış ev sahibi, cihaz kimliği/adresi bilinen donanım (anahtar sunucudan alınabilir).
  StateHarness authedHarness() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setHomesForTesting(<HomeModel>[testHome()])
      ..setSelectedDeviceForTesting(uuid: 'AHBU-S3-TEST01', ip: '192.168.1.30');
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody()));
    return h;
  }

  group('doğrudan mod', () {
    test('setMode(direct) anahtar yenilemesini beklerken dispose: yoklama zamanlayıcısı ve cihaz isteği KURULMAZ', () async {
      final h = authedHarness();
      final gate = Completer<void>();
      h.cloud.localKeyGate = gate; // yerel anahtar sunucudan geliyor (yavaş)

      final mode = h.state.setMode(AppMode.direct);
      await settle();
      expect(h.cloud.count('localKey'), 1, reason: 'anahtar yenilemesi uçuşta');

      h.dispose();
      gate.complete();
      expect(await mode, isTrue);
      await settle();
      await h.clock.elapse(const Duration(seconds: 30));

      expect(h.clock.activeTimerCount, 0, reason: 'dispose sonrası periyodik yoklama zamanlayıcısı kurulmamalı');
      expect(h.directMock.requests, isEmpty, reason: 'dispose sonrası cihaza istek atılmamalı');
    });

    test('komut gönderimi sürerken dispose: dönen yanıt sonrası hızlı-yoklama zamanlayıcısı (_pollSoon) KURULMAZ', () async {
      final h = authedHarness();
      await h.state.setMode(AppMode.direct);
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      final gate = Completer<void>();
      h.directMock.on('POST', '/api/relay', (r) async {
        await gate.future;
        return jsonResponse(<String, dynamic>{'status': 'ok'});
      });

      final toggle = h.state.toggleRelay(3);
      await settle();
      h.dispose();
      gate.complete();
      expect(await toggle, isFalse, reason: 'dispose: komut hattı iptal etti');
      await settle();

      expect(h.clock.activeTimerCount, 0);
      final pollsAfter = h.directMock.count('GET', '/api/status');
      await h.clock.elapse(const Duration(seconds: 30));
      expect(h.directMock.count('GET', '/api/status'), pollsAfter, reason: 'dispose sonrası yoklama yok');
    });

    test('dispose sonrası refresh() ağa çıkmaz (doğrudan ve bulut)', () async {
      final h = authedHarness();
      await h.state.setMode(AppMode.direct);
      h.direct.localKey = 'devicekey-1234';
      h.dispose();
      h.directMock.requests.clear();
      final calls = h.cloud.calls.length;

      await h.state.refresh();
      await h.state.refresh(silent: true);

      expect(h.directMock.requests, isEmpty);
      expect(h.cloud.calls.length, calls);
      expect(h.clock.activeTimerCount, 0);
    });
  });

  group('bulut', () {
    test('claim sonrası ev yenilemesi sürerken dispose: sonradan ev seçimi MQTT/REST BAŞLATMAZ', () async {
      final h = await readyHarness(role: 'owner');
      h.cloud.fetchHomesGate = Completer<void>();

      final claim = h.state.claimDevice('AHBU-S3-NEW001', '123456');
      await settle();
      final starts = h.mqtt.startCount;
      final endpoints = h.cloud.count('fetchEndpoints');

      h.dispose();
      h.cloud.fetchHomesGate!.complete();
      await claim;
      await settle();

      expect(h.mqtt.startCount, starts, reason: 'dispose sonrası canlı kanal başlatılmaz');
      expect(h.cloud.count('fetchEndpoints'), endpoints, reason: 'dispose sonrası REST yenilemesi başlatılmaz');
      expect(h.clock.activeTimerCount, 0);
    });

    test('misafir penceresi zamanlayıcısı: ev listesi dispose SONRASI dönse de zamanlayıcı kurulmaz', () async {
      final window = HomeModel(
        id: kHomeA,
        name: 'Misafir',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
        guestValidUntil: kTestNow.add(const Duration(hours: 2)),
      );
      final h = await readyHarness(home: window);
      expect(h.state.activeHome?.id, kHomeA);
      // Sunucu pencereyi uzattı: uzlaştırma `_scheduleGuestExpiry` çağırır.
      h.cloud.homes = <HomeModel>[
        HomeModel(
          id: kHomeA,
          name: 'Misafir',
          role: 'guest',
          mqttTopicId: 'h_test',
          guestValidFrom: window.guestValidFrom,
          guestValidUntil: kTestNow.add(const Duration(hours: 5)),
        ),
      ];
      h.cloud.fetchHomesGate = Completer<void>();

      final fetch = h.state.fetchHomes(autoSelect: false);
      await settle();
      h.dispose();
      h.cloud.fetchHomesGate!.complete();
      await fetch;
      await settle();

      expect(h.clock.activeTimerCount, 0);
    });

    test('servis PIN üretimi sürerken dispose: PIN süre zamanlayıcısı kurulmaz', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cloud = _SlowTokenCloud()
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      final h = StateHarness(cloud: cloud);
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'A', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await h.state.fetchHomes();
      await settle();
      cloud.tokenGate = Completer<void>();

      final pin = h.state.generateServicePin();
      await settle();
      h.dispose();
      cloud.tokenGate!.complete();
      expect(await pin, '123456', reason: 'iptal edilmiş çağrı da PIN\'i döndürür (tek seferlik sır kaybolmaz)');
      await settle();

      expect(h.clock.activeTimerCount, 0);
      expect(h.state.servicePin, isNull, reason: 'dispose edilmiş durum PIN tutmaz');
    });

    test('ön plan/arka plan yaşam döngüsü dispose sonrası etkisizdir (zamanlayıcı/MQTT yok)', () async {
      final h = await readyHarness();
      h.dispose();
      final starts = h.mqtt.startCount;

      h.state.handleLifecycleState(AppLifecycleState.paused);
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();

      expect(h.mqtt.startCount, starts);
      expect(h.clock.activeTimerCount, 0);
    });
  });
}

/// `createServiceToken` yanıtını kapıyla geciktiren sahte (dispose yarışı için).
class _SlowTokenCloud extends FakeCloudApi {
  Completer<void>? tokenGate;

  @override
  Future<ServiceTokenModel> createServiceToken(String homeId) async {
    final gate = tokenGate;
    if (gate != null) await gate.future;
    return super.createServiceToken(homeId);
  }
}
