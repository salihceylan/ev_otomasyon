import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/endpoint_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// WP-STATE2: panonun `state` yerleşimi ile bulut uç nokta listesinin uyuşmazlık denetleyicisi
/// ([endpointLayoutMismatch], [ReportedLayout], [deviceLayoutSignature], [sameEndpointList]).
///
/// Kısaltma (röle numarası = dizgedeki sıra + 1): `L` lamba/priz, `I` darbe, `U` panjur YUKARI, `D` panjur AŞAĞI.
/// Fabrika yerleşimi: `UDUDLLLL` (1-2 ve 3-4 panjur, 5-8 aydınlatma).
void main() {
  const uidA = 'AHBU-S3-TEST01';
  const uidB = 'AHBU-S3-OTHER02';

  const factory = 'UDUDLLLL';

  /// Pano `state` gösterimi: panjur çiftleri `U` konumlarından türetilir (gerçek pano gibi tutarlı).
  DeviceStatus board(
    String kinds, {
    String? uid = uidA,
    String Function(int id)? nameOf,
    bool typesKnown = true,
  }) {
    final relays = <RelayItem>[];
    final shutters = <ShutterItem>[];
    for (var i = 0; i < kinds.length; i++) {
      final id = i + 1;
      final type = switch (kinds[i]) {
        'L' => 0,
        'U' => 1,
        'D' => 2,
        'I' => 3,
        _ => throw ArgumentError('bilinmeyen tür ${kinds[i]}'),
      };
      relays.add(RelayItem(
        id: id,
        name: nameOf?.call(id) ?? 'Pano Adı $id',
        type: type,
        state: false,
        typeKnown: typesKnown,
      ));
      if (kinds[i] == 'U') shutters.add(ShutterItem(pair: (id + 1) ~/ 2, name: 'Panjur', pos: 40));
    }
    return DeviceStatus(uid: uid, relays: relays, shutters: shutters);
  }

  /// Bulut uç noktaları: `L` light, `P` plug, `I` impulse, `U`/`D` shutter satırları (`pair = (kanal+1)/2`).
  List<EndpointModel> rows(String kinds, {String? uuid = uidA, String Function(int channel)? nameOf}) {
    return <EndpointModel>[
      for (var i = 0; i < kinds.length; i++)
        EndpointModel(
          id: 'e-${uuid ?? 'x'}-${i + 1}',
          homeId: 'home',
          deviceUuid: uuid,
          channel: i + 1,
          shutterPair: (kinds[i] == 'U' || kinds[i] == 'D') ? (i + 2) ~/ 2 : null,
          name: nameOf?.call(i + 1) ?? 'Bulut Adı ${i + 1}',
          room: 'Salon',
          endpointType: switch (kinds[i]) {
            'L' => 'light',
            'P' => 'plug',
            'I' => 'impulse',
            _ => 'shutter',
          },
          currentState: false,
        ),
    ];
  }

  group('endpointLayoutMismatch: uyuşma', () {
    test('özdeş yerleşim -> false (fabrika, tümü lamba, darbeli, ek modüllü)', () {
      for (final kinds in <String>[factory, 'LLLLLLLL', 'LLLLLLLI', 'UDUDUDUD', 'UDUDLLLLLLLLLLLL', 'L']) {
        expect(endpointLayoutMismatch(rows(kinds), board(kinds)), isFalse, reason: kinds);
      }
    });

    test('yalnız AD farkı uyuşmazlık DEĞİLDİR (pano ASCII fabrika adı, bulut Türkçe ad)', () {
      final status = board(factory, nameOf: (id) => 'Salon Aydinlatma $id');
      final endpoints = rows(factory, nameOf: (c) => 'Salon Aydınlatma $c');
      expect(endpointLayoutMismatch(endpoints, status), isFalse);
      expect(endpointLayoutMismatch(rows(factory, nameOf: (c) => 'Özel $c'), status), isFalse);
    });

    test('anlık değer (açık/kapalı, konum) farkı uyuşmazlık DEĞİLDİR', () {
      final on = DeviceStatus(
        uid: uidA,
        relays: <RelayItem>[
          for (var i = 1; i <= 4; i++) RelayItem(id: i, name: 'R$i', type: i <= 2 ? (i == 1 ? 1 : 2) : 0, state: true),
        ],
        shutters: const <ShutterItem>[ShutterItem(pair: 1, name: 'P', pos: 90, isMoving: true, direction: 1, target: 100)],
      );
      expect(endpointLayoutMismatch(rows('UDLL'), on), isFalse);
    });

    test('priz (plug) satırı lamba sınıfıdır: panoda lamba -> uyuşur', () {
      expect(endpointLayoutMismatch(rows('UDUDLLLP'), board(factory)), isFalse);
      expect(endpointLayoutMismatch(rows('PPPP'), board('LLLL')), isFalse);
    });

    test('panjurun yalnız bir satırı varsa (görünür fark yok) uyuşmazlık sayılmaz', () {
      final oneRowPerPair = <EndpointModel>[rows(factory)[0], rows(factory)[2], ...rows(factory).skip(4)];
      // kanal 2 ve 4 satırları yok: çift kümesi aynı, kanal 2/4 panjur rölesi (satır yok = lamba satırı yok).
      expect(endpointLayoutMismatch(oneRowPerPair, board(factory)), isFalse);
    });
  });

  group('endpointLayoutMismatch: panjur çiftleri', () {
    test('panoda yeni panjur çifti (5-6 lamba iken state\'te panjur) -> true', () {
      expect(endpointLayoutMismatch(rows(factory), board('UDUDUDLL')), isTrue);
    });

    test('panjur çifti lambaya çevrildi (satırlar hâlâ panjur) -> true', () {
      expect(endpointLayoutMismatch(rows(factory), board('UDLLLLLL')), isTrue);
      expect(endpointLayoutMismatch(rows(factory), board('LLLLLLLL')), isTrue);
    });

    test('panjur çifti numarası değişti (1-2 panjur iken 2-3... aynı sayıda ama başka kümede) -> true', () {
      // Bulut: çiftler {1,2}; pano: çiftler {2,3}. Tutarlı ileti (röle 3-4 ve 5-6 panjur).
      expect(endpointLayoutMismatch(rows('UDUDLLLL'), board('LLUDUDLL')), isTrue);
    });

    test('panjur kartı ile lamba kartı kanalları çakışırsa (kanal 5-6 panjur, satırlar lamba) -> true', () {
      final endpoints = rows('LLLLLLLL');
      expect(endpointLayoutMismatch(endpoints, board('LLLLUDLL')), isTrue);
    });
  });

  group('endpointLayoutMismatch: lamba / darbe / kanal sayısı', () {
    test('lamba -> darbe -> true; darbe -> lamba -> true', () {
      expect(endpointLayoutMismatch(rows(factory), board('UDUDLLLI')), isTrue);
      expect(endpointLayoutMismatch(rows('UDUDLLLI'), board(factory)), isTrue);
    });

    test('priz satırı panoda darbe oldu -> true', () {
      expect(endpointLayoutMismatch(rows('UDUDLLLP'), board('UDUDLLLI')), isTrue);
    });

    test('küçülme: bulutta olup state\'te hiç bulunmayan kanal -> true', () {
      expect(endpointLayoutMismatch(rows(factory), board('UDUDLL')), isTrue);
      expect(endpointLayoutMismatch(rows('UDUDLLLLLLLLLLLL'), board(factory)), isTrue, reason: 'ek modül kapandı');
    });

    test('büyüme: panoda olup bulutta satırı olmayan kanal (ek modül) -> true', () {
      expect(endpointLayoutMismatch(rows(factory), board('UDUDLLLLLLLLLLLL')), isTrue);
      expect(endpointLayoutMismatch(<EndpointModel>[], board('LLLL')), isTrue, reason: 'hiç satır yok');
    });

    test('ek modül kanalları (9-16) normal kanal sayılır: tür farkı yakalanır', () {
      expect(endpointLayoutMismatch(rows('UDUDLLLLLLLLLLLL'), board('UDUDLLLLLLLLLLLI')), isTrue);
    });
  });

  group('endpointLayoutMismatch: karar verilemeyen (sunucunun da eşitlemeyeceği) state', () {
    test('kısıtlı özet (restricted) -> false', () {
      final restricted = DeviceStatus(uid: uidA, restricted: true, provisioned: true);
      expect(endpointLayoutMismatch(rows(factory), restricted), isFalse);
    });

    test('röle listesi boş (+ panjur listesi boş ya da dolu) -> false', () {
      expect(endpointLayoutMismatch(rows(factory), DeviceStatus(uid: uidA)), isFalse);
      final onlyShutters = DeviceStatus(uid: uidA, shutters: const <ShutterItem>[ShutterItem(pair: 3, name: 'P')]);
      expect(endpointLayoutMismatch(rows(factory), onlyShutters), isFalse);
    });

    test('röle türü bildirilmemiş (eski bellenim: typeKnown=false) -> false (hepsi lamba SANILMAZ)', () {
      expect(endpointLayoutMismatch(rows(factory), board('LLLLLLLL', typesKnown: false)), isFalse);
      expect(endpointLayoutMismatch(rows(factory), board(factory, typesKnown: false)), isFalse);
    });

    test('röle numaraları 1..N boşluksuz/yinelemesiz değilse -> false', () {
      final gap = DeviceStatus(uid: uidA, relays: <RelayItem>[
        for (final id in <int>[1, 2, 5, 6]) RelayItem(id: id, name: 'R$id', type: 0, state: false),
      ]);
      expect(endpointLayoutMismatch(rows(factory), gap), isFalse);
      final dup = DeviceStatus(uid: uidA, relays: <RelayItem>[
        for (final id in <int>[1, 1, 2]) RelayItem(id: id, name: 'R$id', type: 0, state: false),
      ]);
      expect(endpointLayoutMismatch(rows(factory), dup), isFalse);
    });

    test('panjur röleleri çift oluşturmuyorsa (yetim YUKARI/AŞAĞI, ters yön) -> false', () {
      DeviceStatus kinds(List<int> types) => DeviceStatus(uid: uidA, relays: <RelayItem>[
            for (var i = 0; i < types.length; i++) RelayItem(id: i + 1, name: 'R', type: types[i], state: false),
          ]);
      expect(endpointLayoutMismatch(rows(factory), kinds(<int>[1, 0, 0, 0])), isFalse, reason: 'yetim YUKARI');
      expect(endpointLayoutMismatch(rows(factory), kinds(<int>[0, 2, 0, 0])), isFalse, reason: 'yetim AŞAĞI');
      expect(endpointLayoutMismatch(rows(factory), kinds(<int>[2, 1, 0, 0])), isFalse, reason: 'ters yön');
      expect(endpointLayoutMismatch(rows(factory), kinds(<int>[0, 1, 2, 0])), isFalse, reason: 'çift çift sınırında değil');
    });

    test('`shutters[]` çift kümesi türlerden çıkan kümeyle tutarsızsa -> false', () {
      final base = board('UDUDLLLL');
      final missing = base.copyWith(shutters: <ShutterItem>[base.shutters.first]);
      expect(endpointLayoutMismatch(rows('LLLLLLLL'), missing), isFalse, reason: 'bir çift eksik bildirilmiş');
      final extra = base.copyWith(shutters: <ShutterItem>[...base.shutters, const ShutterItem(pair: 4, name: 'P')]);
      expect(endpointLayoutMismatch(rows('LLLLLLLL'), extra), isFalse, reason: 'olmayan çift bildirilmiş');
      final dupPair = base.copyWith(shutters: <ShutterItem>[base.shutters.first, base.shutters.first]);
      expect(endpointLayoutMismatch(rows('LLLLLLLL'), dupPair), isFalse, reason: 'yinelenen çift');
    });

    test('röle sayısı sunucu sınırını (40) aşarsa -> false; 40 ise denetlenir', () {
      final big = 'L' * 41;
      expect(endpointLayoutMismatch(rows('L' * 8), board(big)), isFalse);
      expect(endpointLayoutMismatch(rows('L' * 8), board('L' * 40)), isTrue);
    });
  });

  group('endpointLayoutMismatch: cihaz eşleştirmesi (applyStatusToEndpoints ile aynı kural)', () {
    test('başka cihaza (uid) ait satırlar yok sayılır', () {
      final endpoints = <EndpointModel>[...rows(factory), ...rows('LLLLLLLL', uuid: uidB)];
      expect(endpointLayoutMismatch(endpoints, board(factory)), isFalse, reason: 'A: kendi satırları uyuşuyor');
      expect(endpointLayoutMismatch(endpoints, board('LLLLLLLL', uid: uidB)), isFalse, reason: 'B: kendi satırları uyuşuyor');
      expect(endpointLayoutMismatch(endpoints, board('LLLLLLLL')), isTrue, reason: 'A panjur satırları var, pano lamba diyor');
      expect(endpointLayoutMismatch(endpoints, board(factory, uid: uidB)), isTrue, reason: 'B lamba satırları var, pano panjur diyor');
    });

    test('uid büyük/küçük harf duyarsız eşleşir', () {
      expect(endpointLayoutMismatch(rows(factory, uuid: uidA.toLowerCase()), board(factory)), isFalse);
      expect(endpointLayoutMismatch(rows(factory, uuid: uidA), board(factory, uid: uidA.toLowerCase())), isFalse);
    });

    test('state uid\'si yoksa ya da satırın cihaz kimliği yoksa aynı cihaz sayılır', () {
      expect(endpointLayoutMismatch(rows(factory), board(factory, uid: null)), isFalse);
      expect(endpointLayoutMismatch(rows(factory, uuid: null), board(factory)), isFalse);
      expect(endpointLayoutMismatch(rows(factory, uuid: null), board('UDUDUDLL')), isTrue);
    });

    test('hiçbir satırı olmayan yeni pano (yalnız başka cihazın satırları var) -> true', () {
      expect(endpointLayoutMismatch(rows(factory, uuid: uidB), board(factory)), isTrue);
    });

    test('bir kanalda birden çok satır (kimlik belirsiz) -> false: karar verilmez', () {
      final dup = <EndpointModel>[...rows(factory, uuid: null), ...rows('LLLLLLLL', uuid: uidB.toLowerCase())];
      // uid=null: iki cihazın satırları birlikte değerlendirilirdi; çakışan kanallar belirsizdir.
      expect(endpointLayoutMismatch(dup, board(factory, uid: null)), isFalse);
    });
  });

  group('ReportedLayout / deviceLayoutSignature', () {
    test('imza yalnız TÜR dizisine ve cihaza bağlıdır: ad, durum, konum değişince değişmez', () {
      final a = deviceLayoutSignature(board(factory));
      final renamed = deviceLayoutSignature(board(factory, nameOf: (id) => 'Başka $id'));
      expect(a, isNotNull);
      expect(renamed, a);
      final moved = board(factory);
      final shifted = moved.copyWith(
        shutters: <ShutterItem>[for (final s in moved.shutters) s.copyWith(pos: 5, isMoving: true, direction: 2)],
        relays: <RelayItem>[for (final r in moved.relays) r.copyWith(state: true)],
      );
      expect(deviceLayoutSignature(shifted), a);
    });

    test('imza tür, kanal sayısı ve cihaz değişince değişir', () {
      final base = deviceLayoutSignature(board(factory));
      expect(deviceLayoutSignature(board('UDUDLLLI')), isNot(base), reason: 'lamba -> darbe');
      expect(deviceLayoutSignature(board('UDUDUDLL')), isNot(base), reason: 'yeni panjur');
      expect(deviceLayoutSignature(board('UDUDLLLLLLLLLLLL')), isNot(base), reason: 'ek modül');
      expect(deviceLayoutSignature(board(factory, uid: uidB)), isNot(base), reason: 'başka pano');
      expect(deviceLayoutSignature(board(factory, uid: uidA.toLowerCase())), base, reason: 'uid harf duyarsız');
    });

    test('geçersiz / kısıtlı state için imza yoktur (null)', () {
      expect(deviceLayoutSignature(DeviceStatus(uid: uidA, restricted: true)), isNull);
      expect(deviceLayoutSignature(DeviceStatus(uid: uidA)), isNull);
      expect(deviceLayoutSignature(board(factory, typesKnown: false)), isNull);
      expect(ReportedLayout.from(DeviceStatus(uid: uidA)), isNull);
    });

    test('ReportedLayout.mismatches == endpointLayoutMismatch; device = büyük harf uid ("" yoksa)', () {
      final layout = ReportedLayout.from(board(factory, uid: uidA.toLowerCase()))!;
      expect(layout.device, uidA);
      expect(ReportedLayout.from(board(factory, uid: null))!.device, '');
      expect(layout.mismatches(rows(factory)), isFalse);
      expect(layout.mismatches(rows('LLLLLLLL')), isTrue);
    });
  });

  group('sameEndpointList', () {
    test('aynı içerik (farklı örnek) true; her alan farkı false', () {
      final a = rows(factory);
      final b = rows(factory);
      expect(sameEndpointList(a, a), isTrue);
      expect(sameEndpointList(a, b), isTrue);
      expect(sameEndpointList(a, b.sublist(1)), isFalse);
      expect(sameEndpointList(a, <EndpointModel>[b.first.copyWith(name: 'x'), ...b.skip(1)]), isFalse);
      expect(sameEndpointList(a, <EndpointModel>[b.first.copyWith(currentState: true), ...b.skip(1)]), isFalse);
      expect(sameEndpointList(a, <EndpointModel>[b.first.copyWith(shutterPosition: 55), ...b.skip(1)]), isFalse);
      expect(sameEndpointList(a, <EndpointModel>[b.first.copyWith(room: 'Mutfak'), ...b.skip(1)]), isFalse);
      expect(sameEndpointList(a, <EndpointModel>[b.first.copyWith(deviceOnline: true), ...b.skip(1)]), isFalse);
      expect(sameEndpointList(a, <EndpointModel>[b.first.copyWith(shutterDurationSec: 33), ...b.skip(1)]), isFalse);
      expect(sameEndpointList(<EndpointModel>[], <EndpointModel>[]), isTrue);
    });

    test('tür farkı (light -> impulse) ve sıra farkı false', () {
      final a = rows(factory);
      expect(sameEndpointList(a, rows('UDUDLLLI')), isFalse);
      expect(sameEndpointList(a, a.reversed.toList()), isFalse);
    });
  });
}
