import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/status_pills.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// PF-04 (WP-STATE, S4): bulut tarafında bildirim yağmuru yok.
///
/// * Cihaz `state` iletisi (MQTT) yalnız GÖRÜNÜR bir şey değiştiyse bildirir (röle/panjur/çocuk kilidi değeri,
///   panjur hareketi, cihaz IP'si, çevrimiçi geçişi); özdeş ileti bildirim ÜRETMEZ. Bekleyen komut onayı kendi
///   bildirimini yapar.
/// * REST yenilemesi (`refresh`) uç nokta + cihaz + kilit + huzur yüklemelerini TEK bildirimle bitirir.
///   (LAN yarısının kilidi: `lan_poll_lock_test.dart`.)
void main() {
  Future<void> settle() => pumpEventQueue();

  /// Sahte-zamanlı bölgede ileti akışını boşaltır ve kareyi çizer (iki pompa: ileti + kare).
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Map<String, dynamic> live({Map<int, bool> relays = const <int, bool>{1: false, 2: false, 5: false, 6: false}, bool? childLock, String? ip}) =>
      stateJson(relays: relays, childLock: childLock, ip: ip);

  Map<String, dynamic> shutterState({bool moving = false, int pos = 30, int target = 255}) => stateJson(
        relays: const <int, bool>{1: false, 2: false, 5: false, 6: false},
        shutters: <Map<String, dynamic>>[
          <String, dynamic>{'pair': 2, 'pos': pos, 'moving': moving, 'dir': moving ? 1 : 0, 'target': target},
        ],
      );

  /// İlk canlı ileti uygulanmış donanım (ilk iletinin meşru bildirimleri sayaca girmez).
  Future<StateHarness> warmHarness({bool deviceOnline = true, bool brokerConnected = true}) async {
    final h = await readyHarness(deviceOnline: deviceOnline, brokerConnected: brokerConnected);
    h.mqtt.emitStateJson(live());
    await settle();
    return h;
  }

  group('MQTT state iletisi', () {
    test('aynı ileti ikinci kez gelince bildirim YOK; röle değişince VAR', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      h.mqtt.emitStateJson(live());
      await settle();
      h.mqtt.emitStateJson(live());
      await settle();
      expect(n, 0, reason: 'özdeş iletiler (eskiden her ileti bildirirdi)');

      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}));
      await settle();
      expect(n, 1);
      expect(ep(h.state, 1).currentState, isTrue);
      expect(h.state.relayItems.firstWhere((r) => r.id == 1).state, isTrue);

      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}));
      await settle();
      expect(n, 1, reason: 'yeni değer sabitlendi: tekrar bildirim yok');
    });

    test('panjur: konum/hareket/hedef değişince bildirir; aynı hareket tekrarında bildirmez', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(shutterState());
      await settle();
      var n = 0;
      h.state.addListener(() => n++);

      h.mqtt.emitStateJson(shutterState(moving: true, pos: 40, target: 100));
      await settle();
      expect(n, 1);
      expect(h.state.shutterItems.single.isMoving, isTrue);

      for (var i = 0; i < 5; i++) {
        h.mqtt.emitStateJson(shutterState(moving: true, pos: 40, target: 100));
        await settle();
      }
      expect(n, 1, reason: 'aynı hareket iletisi 5 kez: bildirim yok');

      h.mqtt.emitStateJson(shutterState(moving: true, pos: 40, target: 20)); // yalnız hedef değişti
      await settle();
      expect(n, 2);
      expect(h.state.shutterItems.single.target, 20);

      h.mqtt.emitStateJson(shutterState(pos: 20)); // durdu
      await settle();
      expect(n, 3);
      expect(h.state.shutterItems.single.isMoving, isFalse);
    });

    test('çocuk kilidi: değer değişince bildirir; aynı değer gelince bildirmez AMA kilit zamanı tazelenir', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live(childLock: true));
      await settle();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      final first = h.state.childLockUpdatedAt;
      expect(first, isNotNull);
      var n = 0;
      h.state.addListener(() => n++);

      h.clock.advance(const Duration(seconds: 7));
      h.mqtt.emitStateJson(live(childLock: true));
      await settle();
      expect(n, 0, reason: 'değer aynı: bildirim yok');
      expect(h.state.childLockUpdatedAt!.isAfter(first!), isTrue, reason: '"son bilinen" etiket saati bayat kalmaz');

      h.mqtt.emitStateJson(live(childLock: false));
      await settle();
      expect(n, 1);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
    });

    test('çevrimdışı görünen pano: ilk canlı ileti çevrimiçi yapar (bildirir); sonrakiler özdeşse susar', () async {
      final h = await readyHarness(deviceOnline: false);
      addTearDown(h.dispose);
      expect(h.state.deviceOnline, isFalse);
      var n = 0;
      h.state.addListener(() => n++);

      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.deviceOnline, isTrue);
      expect(n, 1, reason: 'çevrimdışı -> çevrimiçi geçişi görünür bir değişimdir');

      h.mqtt.emitStateJson(live());
      await settle();
      expect(n, 1);
    });

    test('cihaz IP\'si değişince bildirir (lastKnownDeviceIp); aynı IP tekrarında bildirmez', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      h.mqtt.emitStateJson(live(ip: '192.168.1.40'));
      await settle();
      expect(h.state.lastKnownDeviceIp, '192.168.1.40');
      expect(n, 1);
      h.mqtt.emitStateJson(live(ip: '192.168.1.40'));
      await settle();
      expect(n, 1);
    });

    test('retained iletiler de yalnız değişimde bildirir (çevrimiçilik kanıtı sayılmaz)', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      h.mqtt.emitStateJson(live(), retained: true);
      await settle();
      expect(n, 0);
      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}), retained: true);
      await settle();
      expect(n, 1);
    });

    test('bekleyen komutun onayı KENDİ bildirimini yapar (iyimser hedef doğrulanınca arayüz güncellenir)', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      await h.state.setRelay(1, true);
      expect(h.state.commandPipeline.hasPending, isTrue);
      expect(h.state.relayItems.firstWhere((r) => r.id == 1).state, isTrue, reason: 'iyimser');
      var n = 0;
      h.state.addListener(() => n++);

      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}));
      await settle();

      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(n, greaterThanOrEqualTo(1), reason: 'onay + gerçek değer arayüze bildirilmeli');
      expect(h.state.relayItems.firstWhere((r) => r.id == 1).state, isTrue);
    });

    test('bekleyen komut varken cihaz eski değeri bildirirse görünen değer iyimser kalır, geri alınınca gerçek görünür', () async {
      final h = await warmHarness();
      addTearDown(h.dispose);
      await h.state.setRelay(1, true);
      h.mqtt.emitStateJson(live()); // cihaz henüz uygulamadı (röle 1 kapalı)
      await settle();
      expect(h.state.relayItems.firstWhere((r) => r.id == 1).state, isTrue, reason: 'bekleyen hedef REST/MQTT eski değeriyle ezilmez');

      await h.clock.elapse(const Duration(seconds: 3)); // onay penceresi doldu: geri alma
      await settle();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(h.state.relayItems.firstWhere((r) => r.id == 1).state, isFalse, reason: 'gerçek değer');
    });
  });

  group('REST yenilemesi', () {
    test('refresh(silent: true): en çok 2 bildirim (eskiden uç nokta + cihaz + kilit + huzur = 4-5)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      await h.state.refresh(silent: true);
      await settle();

      expect(n, greaterThanOrEqualTo(1));
      expect(n, lessThanOrEqualTo(2), reason: 'yükleyiciler yalnız alan atar, tek bildirim');
    });

    test('refresh(): yükleme başlangıcı + sonuç; en çok 3 bildirim; sonuç eksiksiz', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      await h.state.refresh();
      await settle();

      expect(n, lessThanOrEqualTo(3));
      expect(h.state.endpointsLoaded, isTrue);
      expect(h.state.endpointsLoading, isFalse);
    });

    test('tek bildirim TÜM yüklemeler bittikten sonra gelir: dinleyici eksiksiz veri görür', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.endpoints[kHomeA] = testEndpoints().map((e) => e.isLight ? e.copyWith(currentState: true) : e).toList();
      h.cloud.peaceNotification = <String, dynamic>{...h.cloud.peaceNotification, 'open_lights_count': 3};
      final seen = <(int, Object?)>[];
      h.state.addListener(() => seen.add((h.state.openLightsCount, h.state.peaceNotificationData?['open_lights_count'])));

      await h.state.refresh(silent: true);
      await settle();

      expect(seen, isNotEmpty);
      expect(seen.last, (3, 3), reason: 'son (tek) bildirimde uç noktalar ve huzur verisi birlikte güncel');
      expect(seen.where((s) => s.$1 == 3 && s.$2 != 3), isEmpty, reason: 'yarım güncel görünüm bildirilmedi');
    });

    test('genel API sözleşmesi korunur: fetchEndpoints() ve fetchPeaceNotification() KENDİ bildirimini yapar', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      await h.state.fetchEndpoints();
      expect(n, greaterThanOrEqualTo(1));
      final afterEndpoints = n;
      await h.state.fetchPeaceNotification();
      expect(n, greaterThan(afterEndpoints));
      expect(h.state.peaceNotificationData, isNotNull);
    });

    test('MQTT kopukken REST yenilemesi bekleyen komutu ONAYLAR (hasPending koruması onayı engellemez)', () async {
      final h = await readyHarness(brokerConnected: false);
      addTearDown(h.dispose);
      await h.state.setRelay(1, true); // kanal yok: iletim sonrası REST ile uzlaşma beklenir
      expect(h.state.commandPipeline.hasPending, isTrue);
      h.cloud.endpoints[kHomeA] = testEndpoints().map((e) => e.channel == 1 ? e.copyWith(currentState: true) : e).toList();

      await h.state.refresh(silent: true); // REST yanıtı hedefi doğrular
      await settle();

      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(ep(h.state, 1).currentState, isTrue);
    });
  });

  group('widget kilidi (yeniden kurulum sayacı)', () {
    testWidgets('ChildLockChip: kilit açıkken 10 özdeş iletide (saat ilerlese de) 0 yeniden kurulum', (tester) async {
      final counter = RebuildCounter.install();
      final h = (await tester.runAsync(() => readyHarness()))!;
      addTearDown(h.dispose);
      await pumpApp(tester, child: const Scaffold(body: ChildLockChip()), state: h.state);

      h.mqtt.emitStateJson(live(childLock: true));
      await flush(tester);
      expect(find.byKey(const Key('chip_child_lock')), findsOneWidget, reason: 'kilit açık: rozet görünür (kilit boş geçmesin)');
      counter.reset();

      for (var i = 0; i < 10; i++) {
        h.clock.advance(const Duration(seconds: 1)); // childLockUpdatedAt her iletide farklı
        h.mqtt.emitStateJson(live(childLock: true));
        await flush(tester);
      }

      expect(counter.of<ChildLockChip>(), 0, reason: 'eskiden: etiket saati her iletide değişir, rozet yeniden kurulurdu. ${counter.describe()}');
      expect(counter.of<StatusPill>(), 0, reason: counter.describe());
    });

    testWidgets('kilit gerçekten değişince rozet yeniden kurulur (kontrol: kilit boş geçmesin)', (tester) async {
      final counter = RebuildCounter.install();
      final h = (await tester.runAsync(() => readyHarness()))!;
      addTearDown(h.dispose);
      await pumpApp(tester, child: const Scaffold(body: ChildLockChip()), state: h.state);
      h.mqtt.emitStateJson(live(childLock: true));
      await flush(tester);
      expect(find.byKey(const Key('chip_child_lock')), findsOneWidget);
      counter.reset();

      h.mqtt.emitStateJson(live(childLock: false));
      await flush(tester);

      expect(counter.of<ChildLockChip>(), 1, reason: counter.describe());
      expect(find.byKey(const Key('chip_child_lock')), findsNothing, reason: 'kilit kapalı: rozet gizlenir');
    });
  });
}
