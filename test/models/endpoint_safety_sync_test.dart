import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/endpoint_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const String _uid = 'AHBU-S3-AB12CD';

Map<String, dynamic> _relay(int id, String type, {bool state = false, String? act}) => <String, dynamic>{
      'id': id,
      'name': 'R$id',
      'type': type,
      'state': state,
      'act': ?act,
    };

/// 1-2 panjur (pair 1), 3-4 panjur (pair 2), 5-8 lamba; [acts] röle -> act.
Map<String, dynamic> _state({Map<int, String> acts = const <int, String>{}, bool v3 = false}) => <String, dynamic>{
      'v': v3 ? 3 : 2,
      'uid': _uid,
      if (v3) 'caps': <String>['safety', 'actuator', 'event', 'cfg'],
      if (v3) 'boot': 5,
      if (v3) 'bn': '9f3a11c0',
      if (v3) 'time_ok': false,
      'relays': <Map<String, dynamic>>[
        _relay(1, 'shutter_up'),
        _relay(2, 'shutter_down'),
        _relay(3, 'shutter_up'),
        _relay(4, 'shutter_down'),
        for (var i = 5; i <= 8; i++) _relay(i, 'light', act: acts[i]),
      ],
      'shutters': <Map<String, dynamic>>[
        <String, dynamic>{'pair': 1, 'pos': 0},
        <String, dynamic>{'pair': 2, 'pos': 0},
      ],
      'dis': <Map<String, dynamic>>[],
    };

EndpointModel _ep(int channel, String type, {int? pair, String? actuatorType}) => EndpointModel(
      id: 'e$channel',
      homeId: 'h',
      deviceUuid: _uid,
      channel: channel,
      shutterPair: pair,
      name: 'K$channel',
      room: 'Salon',
      endpointType: type,
      currentState: false,
      actuatorType: actuatorType,
    );

List<EndpointModel> _endpoints({Map<int, String> acts = const <int, String>{}}) => <EndpointModel>[
      _ep(1, 'shutter', pair: 1),
      _ep(2, 'shutter', pair: 1),
      _ep(3, 'shutter', pair: 2),
      _ep(4, 'shutter', pair: 2),
      for (var i = 5; i <= 8; i++) _ep(i, 'light', actuatorType: acts[i]),
    ];

void main() {
  group('EndpointModel: eylemci ve dimmer alanları (033)', () {
    test('fromJson / toJson gidiş-dönüş', () {
      final e = EndpointModel.fromJson(<String, dynamic>{
        'id': 'e5',
        'home_id': 'h',
        'channel_index': 5,
        'type': 'light',
        'name': 'Ana Su Vanası',
        'actuator_type': 'Valve',
        'dimmable': false,
        'dimmer_source': null,
      });
      expect(e.endpointType, 'light', reason: 'type ve knownTypes değişmez');
      expect(e.actuatorType, 'valve');
      expect(e.isActuator, isTrue);
      expect(e.dimmable, isFalse);
      expect(e.dimmerSource, isNull);
      final back = EndpointModel.fromJson(e.toJson());
      expect(back.actuatorType, 'valve');
      expect(back.dimmable, isFalse);
    });

    test('alanlar yoksa (eski sunucu) eylemci değil; toJson yeni anahtar yazmaz', () {
      final e = EndpointModel.fromJson(<String, dynamic>{'id': 'e1', 'channel_index': 1, 'type': 'light'});
      expect(e.actuatorType, isNull);
      expect(e.isActuator, isFalse);
      expect(e.dimmable, isNull);
      expect(e.toJson().containsKey('actuator_type'), isFalse);
      expect(e.toJson().containsKey('dimmable'), isFalse);
      expect(e.toJson().containsKey('dimmer_source'), isFalse);
    });

    test('dimmable + dimmer_source', () {
      final e = EndpointModel.fromJson(<String, dynamic>{
        'id': 'e2',
        'channel_index': 2,
        'type': 'light',
        'dimmable': true,
        'dimmer_source': 'modbus',
      });
      expect(e.dimmable, isTrue);
      expect(e.dimmerSource, 'modbus');
    });

    test('copyWith eylemci alanlarını korur; sameEndpointList eylemci farkını görür', () {
      final a = _ep(5, 'light', actuatorType: 'valve');
      expect(a.copyWith(currentState: true).actuatorType, 'valve');
      expect(sameEndpointList(<EndpointModel>[a], <EndpointModel>[_ep(5, 'light')]), isFalse);
      expect(sameEndpointList(<EndpointModel>[a], <EndpointModel>[_ep(5, 'light', actuatorType: 'valve')]), isTrue);
    });

    test('relayItemsFromEndpoints eylemci türünü taşır', () {
      final items = relayItemsFromEndpoints(<EndpointModel>[_ep(5, 'light', actuatorType: 'valve'), _ep(6, 'light')]);
      expect(items.first.actuator, ActuatorKind.valve);
      expect(items[1].actuator, isNull);
    });
  });

  group('eşdeğerlik: eylemcisiz panoda yerleşim ve röle görünümü BİREBİR aynı (§2.9)', () {
    test('v:2 imzası bugünkü biçimde', () {
      final st = DeviceStatus.fromJson(_state(), filterPhantomShutters: false);
      expect(deviceLayoutSignature(st), '$_uid|UDUDLLLL');
    });

    test('v:3 ekleri (act yok) imzayı, röleleri ve kontrol edilebilir röleleri değiştirmez', () {
      final v2 = DeviceStatus.fromJson(_state(), filterPhantomShutters: false);
      final v3 = DeviceStatus.fromJson(_state(v3: true), filterPhantomShutters: false);
      expect(deviceLayoutSignature(v3), deviceLayoutSignature(v2));
      expect(v3.controllableRelays.map((r) => r.id), v2.controllableRelays.map((r) => r.id));
      expect(v3.relays.map((r) => '${r.id}:${r.type}:${r.state}'), v2.relays.map((r) => '${r.id}:${r.type}:${r.state}'));
      expect(v3.shutters.map((s) => s.pair), v2.shutters.map((s) => s.pair));
      expect(v3.safety.supported, isTrue);
      expect(v3.safety.configured, isFalse);
      expect(endpointLayoutMismatch(_endpoints(), v3), isFalse);
      expect(endpointLayoutMismatch(_endpoints(), v2), isFalse);
    });

    test('eylemcisiz uç nokta listesinde röle görünümü değişmez', () {
      final items = relayItemsFromEndpoints(_endpoints());
      expect(items.map((r) => r.id), <int>[5, 6, 7, 8]);
      expect(items.every((r) => !r.isActuator), isTrue);
    });
  });

  group('yerleşim imzası ve karşılaştırma act alanını içerir [Y2]', () {
    test('lambanın vanaya çevrilmesi imzayı değiştirir', () {
      final plain = DeviceStatus.fromJson(_state(v3: true), filterPhantomShutters: false);
      final valve = DeviceStatus.fromJson(_state(v3: true, acts: <int, String>{5: 'valve'}), filterPhantomShutters: false);
      final siren = DeviceStatus.fromJson(_state(v3: true, acts: <int, String>{5: 'siren'}), filterPhantomShutters: false);
      expect(deviceLayoutSignature(valve), isNot(deviceLayoutSignature(plain)));
      expect(deviceLayoutSignature(valve), isNot(deviceLayoutSignature(siren)));
      expect(deviceLayoutSignature(valve), '$_uid|UDUDLvLLL');
    });

    test('uç noktada actuator_type yoksa ve panoda act varsa uyuşmazlık (eşitleme beklenir)', () {
      final st = DeviceStatus.fromJson(_state(v3: true, acts: <int, String>{5: 'valve'}), filterPhantomShutters: false);
      expect(endpointLayoutMismatch(_endpoints(), st), isTrue);
      expect(endpointLayoutMismatch(_endpoints(acts: <int, String>{5: 'valve'}), st), isFalse);
      expect(endpointLayoutMismatch(_endpoints(acts: <int, String>{5: 'siren'}), st), isTrue);
    });

    test('uç noktada eylemci kalmış ama pano artık lamba diyor: uyuşmazlık', () {
      final st = DeviceStatus.fromJson(_state(v3: true), filterPhantomShutters: false);
      expect(endpointLayoutMismatch(_endpoints(acts: <int, String>{6: 'fan'}), st), isTrue);
    });
  });
}
