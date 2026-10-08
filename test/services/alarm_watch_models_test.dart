import 'dart:isolate';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_watch_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/refresh_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// Arka plan alarm bildirimi: rol kapısı, paylaşılan ayar kaydı, kalıcı tekilleştirme, geri çekilme ve isolate'ler arası
/// yenileme kapısı (saf mantık).
HomeModel _home(String id, String? role, {String name = 'Ev'}) => HomeModel(id: id, name: name, role: role);

class _MemoryRegistry implements PortRegistry {
  final Map<String, SendPort> map = <String, SendPort>{};

  @override
  bool register(SendPort port, String name) {
    if (map.containsKey(name)) return false;
    map[name] = port;
    return true;
  }

  @override
  SendPort? lookup(String name) => map[name];

  @override
  bool remove(String name) => map.remove(name) != null;
}

void main() {
  group('rol kapısı: yalnız ev sahibi ve sakin', () {
    final homes = <HomeModel>[
      _home('h1', 'owner', name: ' Evim '),
      _home('h2', 'resident'),
      _home('h3', 'guest'),
      _home('h4', 'service_user'),
      _home('h5', 'member'), // eski ad -> resident
      _home('h6', null),
    ];

    test('müşteri hesabı: owner + resident evleri', () {
      final out = eligibleWatchHomes(globalRole: 'user', homes: homes);
      expect(out.map((h) => h.id), <String>['h1', 'h2', 'h5']);
      expect(out.first.name, 'Evim');
    });

    test('servis oturumu ve bilinmeyen rol hiçbir evi izleyemez', () {
      for (final role in <String?>['service_session', null, 'bilinmeyen']) {
        expect(eligibleWatchHomes(globalRole: role, homes: homes), isEmpty, reason: '$role');
      }
    });

    test('guvenlik-12: kendi evinin sahibi/sakini olan personel ve süper kullanıcı izler; müşteri evindeki servis rolü izlemez',
        () {
      for (final role in <String>['service_user', 'super_user', 'installer']) {
        final out = eligibleWatchHomes(globalRole: role, homes: homes);
        expect(out.map((h) => h.id), <String>['h1', 'h2', 'h5'], reason: role);
      }
      // Müşteri evindeki servis üyeliği (ev rolü service_user) hiçbir küresel rolde izlenmez.
      expect(
        eligibleWatchHomes(globalRole: 'service_user', homes: <HomeModel>[_home('c1', 'service_user')]),
        isEmpty,
      );
    });
  });

  group('ayar kaydı (iki isolate paylaşır; sır yok)', () {
    test('kapalı başlar; yaz-oku gidiş dönüşü; bozuk kayıt kapalı sayılır', () async {
      final store = MemoryAlarmWatchStore();
      final repo = AlarmWatchSettingsRepository(store);
      expect(await repo.load(), AlarmWatchSettings.off);
      const s = AlarmWatchSettings(
        enabled: true,
        userId: 'u1',
        homes: <WatchedHome>[WatchedHome(id: 'h1', name: 'Evim')],
      );
      await repo.save(s);
      expect(await AlarmWatchSettingsRepository(store).load(), s);
      expect(store.data[AlarmWatchSettingsRepository.key], isNot(contains('token')));

      store.data[AlarmWatchSettingsRepository.key] = '{bozuk';
      expect((await repo.load()).enabled, isFalse);
      store.data[AlarmWatchSettingsRepository.key] = '{"enabled":"evet","homes":[{"name":"kimliksiz"}]}';
      final odd = await repo.load();
      expect(odd.enabled, isFalse);
      expect(odd.homes, isEmpty);
    });
  });

  group('tekilleştirme (kalıcı)', () {
    test('aynı anahtar bir kez; yeni örnek (servis yeniden başladı) aynı kaydı görür', () async {
      final store = MemoryAlarmWatchStore();
      final a = AlarmDedupeStore(store);
      expect(await a.markIfNew('z|h|u|1|aid-1'), isTrue);
      expect(await a.markIfNew('z|h|u|1|aid-1'), isFalse);
      expect(await AlarmDedupeStore(store).markIfNew('z|h|u|1|aid-1'), isFalse);
      expect(await a.markIfNew('z|h|u|1|aid-2'), isTrue, reason: 'yeni alarm kimliği yeniden bildirilir');
    });

    test('unut / önek; eski kayıtlar ve üst sınır', () async {
      var now = DateTime(2026, 10, 9, 12);
      final store = MemoryAlarmWatchStore();
      final d = AlarmDedupeStore(store, now: () => now, maxEntries: 3);
      await d.markIfNew('s|h|u');
      await d.forget('s|h|u');
      expect(await d.markIfNew('s|h|u'), isTrue);
      await d.markIfNew('z|h|u|1|-');
      await d.forgetPrefix('z|h|u|1|-');
      expect(await d.markIfNew('z|h|u|1|-'), isTrue);

      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(minutes: 1));
        await d.markIfNew('k$i');
      }
      expect(await AlarmDedupeStore(store).markIfNew('k4'), isFalse);
      expect(await AlarmDedupeStore(store).markIfNew('k0'), isTrue, reason: 'en eski taşma ile atıldı');

      now = now.add(const Duration(days: 8));
      expect(await d.markIfNew('k4'), isTrue, reason: '7 günden eski kayıt atılır');
    });

    test('guvenlik-9: touch hâlâ etkin alarmın kayıt zamanını tazeler (yalnız var olan kayıt)', () async {
      var now = DateTime(2026, 10, 9, 12);
      final d = AlarmDedupeStore(MemoryAlarmWatchStore(), now: () => now);
      expect(await d.markIfNew('z|h|u|1|aid-1'), isTrue);
      now = now.add(const Duration(days: 6));
      await d.touch(<String>['z|h|u|1|aid-1', 'yok']);
      now = now.add(const Duration(days: 6));
      expect(await d.markIfNew('z|h|u|1|aid-1'), isFalse, reason: 'tazelendi: 12 gün sonra hâlâ kayıtlı');
      expect(await d.markIfNew('yok'), isTrue, reason: 'touch kayıt EKLEMEZ');
    });

    test('bozuk kayıt boş sayılır', () async {
      final store = MemoryAlarmWatchStore()..data[AlarmDedupeStore.key] = '[1,2';
      expect(await AlarmDedupeStore(store).markIfNew('x'), isTrue);
    });
  });

  group('geri çekilme', () {
    test('5, 10, 20 ... sn; üst sınır 5 dk; sıfırlanır', () {
      final b = AlarmBackoff(random: () => 0.5); // oynama yok (0.8 + 0.5*0.4 = 1.0)
      expect(b.next(), const Duration(seconds: 5));
      expect(b.next(), const Duration(seconds: 10));
      expect(b.next(), const Duration(seconds: 20));
      for (var i = 0; i < 20; i++) {
        b.next();
      }
      expect(b.next(), const Duration(minutes: 5));
      b.reset();
      expect(b.next(), const Duration(seconds: 5));
    });

    test('oynama ±%20 içinde', () {
      expect(AlarmBackoff(random: () => 0).next(), const Duration(seconds: 4));
      expect(AlarmBackoff(random: () => 1).next(), const Duration(seconds: 6));
    });
  });

  group('isolate\'ler arası yenileme kapısı', () {
    test('aynı anda tek yenileme: ikinci çağrı birincisi bitene kadar bekler', () async {
      final registry = _MemoryRegistry();
      final a = IsolateRefreshGate(registry: registry);
      final b = IsolateRefreshGate(registry: registry);
      final order = <String>[];
      final first = a.run(() async {
        order.add('a-start');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        order.add('a-end');
        return 1;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = b.run(() async {
        order.add('b');
        return 2;
      });
      expect(await first, 1);
      expect(await second, 2);
      expect(order, <String>['a-start', 'a-end', 'b']);
      expect(registry.map, isEmpty, reason: 'kapı bırakıldı');
    });

    test('ölü sahip (yanıt vermeyen port) devralınır', () async {
      final registry = _MemoryRegistry();
      final dead = ReceivePort()..close();
      registry.map[IsolateRefreshGate.defaultName] = dead.sendPort;
      final gate = IsolateRefreshGate(registry: registry, pingTimeout: const Duration(milliseconds: 100));
      expect(await gate.run(() async => 'ok'), 'ok');
      expect(registry.map, isEmpty);
    });

    test('işlem hata verse de kapı bırakılır', () async {
      final registry = _MemoryRegistry();
      final gate = IsolateRefreshGate(registry: registry);
      await expectLater(gate.run<void>(() async => throw StateError('x')), throwsStateError);
      expect(registry.map, isEmpty);
      expect(await gate.run(() async => 3), 3);
    });
  });
}
