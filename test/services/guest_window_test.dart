import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// cekirdek-1 (sözleşme C5): misafir penceresi açılınca/uzatılınca canlı kanal başlar; pencere başlangıcı için
/// zamanlayıcı; başlangıç/bitiş `GET /homes` `access_starts_in` / `access_expires_in` ile SUNUCU saatine göre.
void main() {
  Future<void> settle() => pumpEventQueue(times: 40);

  HomeModel guest({
    required DateTime from,
    required DateTime until,
    HomeAccessState state = HomeAccessState.active,
  }) =>
      HomeModel(
        id: kHomeA,
        name: 'Misafir Evi',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidFrom: from,
        guestValidUntil: until,
        accessState: state,
        serverMarkedExpired: state.isBlocked,
      );

  test('pencere başlamamışken seçilen ev: erişim açılınca (ev listesi) REST + canlı kanal başlar', () async {
    final now = kTestNow;
    final h = await readyHarness(
      home: guest(
        from: now.add(const Duration(hours: 1)),
        until: now.add(const Duration(hours: 5)),
        state: HomeAccessState.notStarted,
      ),
    );
    addTearDown(h.dispose);
    expect(h.state.capabilities.isGuestExpired, isTrue);
    expect(h.state.cloudEndpoints, isEmpty);
    final starts = h.mqtt.startCount;

    h.cloud.homes = <HomeModel>[
      guest(from: now.subtract(const Duration(minutes: 1)), until: now.add(const Duration(hours: 5))),
    ];
    await h.state.fetchHomes(autoSelect: false);
    await settle();

    expect(h.state.capabilities.isGuestExpired, isFalse);
    expect(h.mqtt.startCount, greaterThan(starts), reason: 'erişim açıldı: canlı kanal başlamalı');
    expect(h.state.cloudEndpoints, isNotEmpty);
  });

  test('süresi dolan misafir uzatılınca canlı kanal yeniden başlar', () async {
    final now = kTestNow;
    final h = await readyHarness(
      home: guest(from: now.subtract(const Duration(hours: 1)), until: now.add(const Duration(minutes: 10))),
    );
    addTearDown(h.dispose);
    h.cloud.homes = <HomeModel>[
      guest(
        from: now.subtract(const Duration(hours: 1)),
        until: now.add(const Duration(minutes: 10)),
        state: HomeAccessState.expired,
      ),
    ];
    await h.clock.elapse(const Duration(minutes: 10, seconds: 2));
    await settle();
    expect(h.state.capabilities.isGuestExpired, isTrue);
    final starts = h.mqtt.startCount;

    h.cloud.homes = <HomeModel>[
      guest(from: now.subtract(const Duration(hours: 1)), until: now.add(const Duration(hours: 3))),
    ];
    await h.state.fetchHomes(autoSelect: false);
    await settle();

    expect(h.state.capabilities.isGuestExpired, isFalse);
    expect(h.mqtt.startCount, greaterThan(starts));
  });

  test('pencere başlangıcında (valid_from) ev listesi sunucudan tazelenir ve erişim açılır', () async {
    final now = kTestNow;
    final h = await readyHarness(
      home: guest(
        from: now.add(const Duration(minutes: 30)),
        until: now.add(const Duration(hours: 5)),
        state: HomeAccessState.notStarted,
      ),
    );
    addTearDown(h.dispose);
    final fetches = h.cloud.count('fetchHomes');
    final starts = h.mqtt.startCount;
    h.cloud.homes = <HomeModel>[
      guest(from: now.add(const Duration(minutes: 30)), until: now.add(const Duration(hours: 5))),
    ];

    await h.clock.elapse(const Duration(minutes: 29));
    await settle();
    expect(h.cloud.count('fetchHomes'), fetches, reason: 'başlangıç gelmeden yenileme yok');

    await h.clock.elapse(const Duration(minutes: 1, seconds: 2));
    await settle();
    expect(h.cloud.count('fetchHomes'), greaterThan(fetches));
    expect(h.state.capabilities.isGuestExpired, isFalse);
    expect(h.mqtt.startCount, greaterThan(starts));
  });

  test('telefon saati sunucudan 2 sa ileri: access_expires_in ile pencere sunucu saatine göre açık', () async {
    final serverNow = kTestNow.subtract(const Duration(hours: 2)); // telefon (FakeClock) 2 sa ileri
    final home = HomeModel.fromJson(<String, dynamic>{
      'id': kHomeA,
      'name': 'Misafir Evi',
      'role': 'guest',
      'mqtt_topic_id': 'h_test',
      'valid_from': serverNow.subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
      'valid_until': serverNow.add(const Duration(hours: 1)).toUtc().toIso8601String(),
      'access_state': 'active',
      'access_starts_in': 0,
      'access_expires_in': 3600,
    });
    expect(home.accessExpiresIn, 3600);
    final h = await readyHarness(home: home);
    addTearDown(h.dispose);

    expect(h.state.capabilities.isGuestExpired, isFalse, reason: 'yerel saat ileri; sunucuya göre 1 sa kaldı');
    expect(h.state.cloudEndpoints, isNotEmpty);

    // Sunucu saatine göre bitişte (1 sa sonra) erişim kapanır (zamanlayıcı yerel saatle 1 sa sonra kurulur).
    await h.clock.elapse(const Duration(minutes: 59));
    await settle();
    expect(h.state.capabilities.isGuestExpired, isFalse);
    h.cloud.homes = <HomeModel>[
      HomeModel.fromJson(<String, dynamic>{
        ...home.toJson(),
        'access_state': 'expired',
        'access_starts_in': 0,
        'access_expires_in': 0,
      }),
    ];
    await h.clock.elapse(const Duration(minutes: 1, seconds: 2));
    await settle();
    expect(h.state.capabilities.isGuestExpired, isTrue);
  });

  test('eski sunucu (alanlar yok): yerel saatle karar verilir', () async {
    final now = kTestNow;
    final h = await readyHarness(
      home: guest(from: now.subtract(const Duration(hours: 3)), until: now.subtract(const Duration(hours: 1))),
    );
    addTearDown(h.dispose);
    expect(h.state.capabilities.isGuestExpired, isTrue);
  });
}
