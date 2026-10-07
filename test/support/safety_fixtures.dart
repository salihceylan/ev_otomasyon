import 'package:ev_otomasyon/models/cloud_models.dart';

import 'fakes.dart';

/// Güvenlik arayüzü testlerinin ortak örnekleri (WP-A3/A4). `support.dart` dışa aktarmaz (ad çakışması olmasın):
/// `import '../support/safety_fixtures.dart';`

const String kSafetyUid = 'AHBU-S3-TEST01';

/// Kanal 7 su vanası (a1), kanal 8 siren (a2), kanal 9 gaz vanası (a3); 1-6 [testEndpoints].
List<EndpointModel> safetyUiEndpoints() {
  EndpointModel act(String id, int ch, String name, String type) => EndpointModel(
        id: id,
        homeId: kHomeA,
        deviceId: 'dev-internal',
        deviceUuid: kSafetyUid,
        channel: ch,
        name: name,
        room: 'Mutfak',
        endpointType: 'light',
        currentState: true,
        actuatorType: type,
      );
  return <EndpointModel>[
    ...testEndpoints(),
    act('e7', 7, 'Ana Su Vanası', 'valve'),
    act('e8', 8, 'Siren', 'siren'),
    act('e9', 9, 'Gaz Vanası', 'valve'),
  ];
}

/// `state v:3` (§3.2) örneği. [zoneSt] `normal|latched|fault|test`; [valvePos] su vanasının konumu.
Map<String, dynamic> safetyStateJson({
  String zoneSt = 'normal',
  bool silenced = false,
  String aid = '9f3a11c0-3',
  String valvePos = 'open',
  bool? valveFb,
  bool sirenOn = false,
  bool sensorActive = false,
  bool sensorOk = true,
  bool bridgeOk = true,
  bool bridgeActive = false,
  String mode = 'normal',
  int? since,
  String? lastId,
  Map<int, bool> lights = const <int, bool>{},
}) {
  final base = stateJson(relays: lights, lastId: lastId);
  return <String, dynamic>{
    ...base,
    'v': 3,
    'caps': <String>['safety', 'actuator', 'event', 'cfg'],
    'relays': <Map<String, dynamic>>[
      ...(base['relays'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 7, 'name': 'Ana Su Vanası', 'type': 'light', 'state': true, 'act': 'valve'},
      <String, dynamic>{'id': 8, 'name': 'Siren', 'type': 'light', 'state': sirenOn, 'act': 'siren'},
      <String, dynamic>{'id': 9, 'name': 'Gaz Vanası', 'type': 'light', 'state': false, 'act': 'valve'},
    ],
    'sensors': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'd3', 'src': 'di', 'kind': 'water', 'zone': 1, 'active': sensorActive, 'ok': sensorOk},
      <String, dynamic>{'id': 'b1', 'src': 'bridge', 'kind': 'water', 'zone': 1, 'active': bridgeActive, 'ok': bridgeOk},
    ],
    'actuators': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'a1',
        'relay': 7,
        'kind': 'valve',
        'medium': 'water',
        'zones': <int>[1],
        'pos': valvePos,
        'fb': valveFb,
      },
      <String, dynamic>{'id': 'a2', 'relay': 8, 'kind': 'siren', 'zones': <int>[1], 'on': sirenOn},
      <String, dynamic>{'id': 'a3', 'relay': 9, 'kind': 'valve', 'medium': 'gas', 'zones': <int>[1], 'pos': 'closed'},
    ],
    'safety': <String, dynamic>{
      'policy': 'on',
      'mode': mode,
      'zones': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 1,
          'st': zoneSt,
          'kind': 'water',
          'aid': aid,
          'silenced': silenced,
          'since': ?since,
          'since_up': 3000,
          'srcs': <String>['d3'],
        },
      ],
    },
  };
}
