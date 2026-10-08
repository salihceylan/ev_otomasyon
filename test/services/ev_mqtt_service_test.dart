import 'dart:io';
import 'dart:math';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

MqttCredentials creds({
  String topic = 'h_abc',
  String? clientId = 'cid-1',
  Duration validFor = const Duration(hours: 12),
  required DateTime now,
  String user = 'a_h_abc_1',
}) =>
    MqttCredentials(
      host: 'broker.test',
      port: 8884,
      username: user,
      password: 'gecici-parola',
      expiresAt: now.add(validFor),
      topicId: topic,
      clientId: clientId,
    );

String stateText({int relay = 1, bool on = true, bool? childLock, String? lastId, List<Map<String, dynamic>>? shutters}) {
  final parts = <String>[
    '"v":2',
    '"uid":"AHBU-S3-ABC123"',
    '"relays":[{"id":$relay,"name":"R","type":"light","state":$on}]',
    '"shutters":${shutters == null ? '[]' : _json(shutters)}',
    if (childLock != null) '"child_lock":$childLock',
    if (lastId != null) '"last_id":"$lastId"',
  ];
  return '{${parts.join(',')}}';
}

String _json(Object o) => const JsonEncoderCompat().encode(o);

class JsonEncoderCompat {
  const JsonEncoderCompat();
  String encode(Object o) => pretty(o).replaceAll('\n', '').replaceAll(RegExp(r'\s+'), '');
}

void main() {
  late FakeClock clock;
  late List<FakeMqttTransport> transports;
  late EvMqttService service;
  late List<MqttLinkState> links;
  late List<DeviceStateMessage> states;
  late List<DevicePresenceMessage> presences;
  late int providerCalls;
  late List<MqttCredentials> issued;

  Future<MqttCredentials> Function() providerOf(MqttCredentials Function(int call) make) => () async {
        providerCalls++;
        final c = make(providerCalls);
        issued.add(c);
        return c;
      };

  setUp(() {
    clock = FakeClock();
    transports = <FakeMqttTransport>[];
    providerCalls = 0;
    issued = <MqttCredentials>[];
    service = EvMqttService(
      clock: clock,
      random: Random(7),
      useTls: true,
      transportFactory: () {
        final t = FakeMqttTransport();
        transports.add(t);
        return t;
      },
    );
    links = <MqttLinkState>[];
    states = <DeviceStateMessage>[];
    presences = <DevicePresenceMessage>[];
    service.linkStates.listen(links.add);
    service.stateMessages.listen(states.add);
    service.statusMessages.listen(presences.add);
  });

  tearDown(() => service.dispose());

  Future<void> settle([Duration d = const Duration(milliseconds: 50)]) => clock.elapse(d);

  group('bağlantı ve abonelik', () {
    test('kimlik sunucudan alınır, yalnızca state/status abone olunur, durumlar canlı yayınlanır', () async {
      await service.start(
        credentialsProvider: providerOf((_) => creds(now: clock.now())),
        installId: 'abcdef0123456789',
      );
      await settle();
      expect(providerCalls, 1);
      final t = transports.single;
      expect(t.credentials!.username, 'a_h_abc_1');
      expect(t.credentials!.host, 'broker.test');
      expect(t.clientId, 'cid-1', reason: 'sunucunun verdiği oturuma özgü client_id kullanılır');
      expect(t.secure, isTrue);
      expect(t.subscriptions, <String>['ev/h_abc/state', 'ev/h_abc/status']);
      expect(t.subscriptions.any((s) => s.endsWith('/cmd') || s.endsWith('/sys')), isFalse);
      expect(links, <MqttLinkState>[MqttLinkState.connecting, MqttLinkState.connected]);
      expect(service.linkState, MqttLinkState.connected);
      expect(service.isConnected, isTrue);
      expect(service.topicId, 'h_abc');
    });

    test('sunucu client_id vermezse: app_<kalıcı kurulum kimliği>_<oturum eki>; oturumlar farklı', () async {
      Future<String?> startAndGetId() async {
        await service.start(
          credentialsProvider: providerOf((_) => creds(clientId: null, now: clock.now())),
          installId: 'ABCDEF01-2345-6789-abcd-ef0123456789',
        );
        await settle();
        return transports.last.clientId;
      }

      final first = await startAndGetId();
      final second = await startAndGetId();
      expect(first, matches(RegExp(r'^app_abcdef01_[0-9a-f]{12}$')));
      expect(second, matches(RegExp(r'^app_abcdef01_[0-9a-f]{12}$')));
      expect(first, isNot(second), reason: 'her oturumda benzersiz ek');
    });

    test('TLS bayrağı yapılandırmadan gelir (QA için kapatılabilir)', () async {
      final plain = EvMqttService(
        clock: clock,
        random: Random(1),
        useTls: false,
        transportFactory: () {
          final t = FakeMqttTransport();
          transports.add(t);
          return t;
        },
      );
      addTearDown(plain.dispose);
      await plain.start(credentialsProvider: providerOf((_) => creds(now: clock.now())));
      await settle();
      expect(transports.last.secure, isFalse);
      expect(transports.last.credentials!.port, 8884, reason: 'host/port sunucunun kimlik yanıtından');
    });

    test('kimlik yanıtında topic_id yoksa yedek konu kimliği kullanılır', () async {
      await service.start(
        credentialsProvider: providerOf((_) => creds(topic: '', now: clock.now())),
        fallbackTopicId: 'h_fallback',
      );
      await settle();
      expect(transports.single.subscriptions.first, 'ev/h_fallback/state');
    });

    test('yayın (publish) yolu YOK: servis yalnızca abonelik yapar', () {
      final source = File('lib/services/ev_mqtt_service.dart').readAsStringSync();
      expect(source.contains('publishMessage'), isFalse);
      expect(source.contains('publishCommand'), isFalse);
      expect(source.contains('sendRelayCommand'), isFalse);
      expect(source.contains('sendShutterCommand'), isFalse);
      expect(source.contains('sendScenarioCommand'), isFalse);
      expect(source.contains('withWillQos'), isFalse);
    });

    test('stop(): bağlantı kapanır, durum disconnected, sonradan zamanlayıcılar hiçbir şey yapmaz', () async {
      await service.start(credentialsProvider: providerOf((_) => creds(now: clock.now())));
      await settle();
      await service.stop();
      expect(service.linkState, MqttLinkState.disconnected);
      expect(transports.single.closed, isTrue);
      final calls = providerCalls;
      await clock.elapse(const Duration(hours: 13)); // yenileme zamanı geçse bile
      expect(providerCalls, calls);
      expect(transports, hasLength(1));
    });
  });

  group('ileti işleme', () {
    setUp(() async {
      await service.start(credentialsProvider: providerOf((_) => creds(now: clock.now())));
      await settle();
    });

    test('abonelik grubundaki TÜM iletiler işlenir (eski kod yalnızca ilkini işliyordu)', () async {
      transports.single.deliver(<MqttInboundMessage>[
        MqttInboundMessage(topic: 'ev/h_abc/state', payload: stateText(relay: 1, on: true)),
        const MqttInboundMessage(topic: 'ev/h_abc/status', payload: 'online'),
        MqttInboundMessage(topic: 'ev/h_abc/state', payload: stateText(relay: 2, on: false)),
        const MqttInboundMessage(topic: 'ev/h_abc/status', payload: 'offline'),
      ]);
      await settle();
      expect(states, hasLength(2));
      expect(states[0].status.relayById(1)!.state, isTrue);
      expect(states[1].status.relayById(2)!.state, isFalse);
      expect(presences.map((p) => p.online), <bool>[true, false]);
    });

    test('state: moving/dir/target/child_lock/last_id güvenle çözülür; retained bayrağı taşınır', () async {
      transports.single.deliver(<MqttInboundMessage>[
        MqttInboundMessage(
          topic: 'ev/h_abc/state',
          retained: true,
          payload: stateText(
            childLock: true,
            lastId: 'cmd42',
            shutters: <Map<String, dynamic>>[
              <String, dynamic>{'pair': 1, 'pos': 40, 'moving': true, 'dir': 2, 'target': 10},
            ],
          ),
        ),
      ]);
      await settle();
      final m = states.single;
      expect(m.retained, isTrue);
      expect(m.topicId, 'h_abc');
      expect(m.status.childLock, isTrue);
      expect(m.status.lastId, 'cmd42');
      final s = m.status.shutterByPair(1)!;
      expect(s.isMoving, isTrue);
      expect(s.direction, 2);
      expect(s.target, 10);
      expect(s.pos, 40);
    });

    test('status düz metin ve JSON biçimi; retained bayrağı', () async {
      transports.single.deliver(<MqttInboundMessage>[
        const MqttInboundMessage(topic: 'ev/h_abc/status', payload: ' Online \n', retained: true),
        const MqttInboundMessage(topic: 'ev/h_abc/status', payload: '{"status":"offline"}'),
      ]);
      await settle();
      expect(presences.map((p) => p.online), <bool>[true, false]);
      expect(presences.first.retained, isTrue);
      expect(presences.last.retained, isFalse);
    });

    test('bozuk yük akışı BOZMAZ: atılır, sayılır, sonraki iletiler işlenmeye devam eder', () async {
      final big = '{"relays":[${List<String>.filled(7000, '{"id":1,"state":true}').join(',')}]}';
      transports.single.deliver(<MqttInboundMessage>[
        const MqttInboundMessage(topic: 'ev/h_abc/state', payload: '{bozuk json'),
        const MqttInboundMessage(topic: 'ev/h_abc/state', payload: '[1,2,3]'),
        const MqttInboundMessage(topic: 'ev/h_abc/state', payload: '"düz metin"'),
        const MqttInboundMessage(topic: 'ev/h_abc/state', payload: ''),
        const MqttInboundMessage(topic: 'ev/h_abc/status', payload: 'belki'),
        const MqttInboundMessage(topic: 'ev/h_abc/status', payload: '{"status": 5}'),
        const MqttInboundMessage(topic: 'ev/h_DIGER/state', payload: '{"relays":[]}'), // başka eve ait
        const MqttInboundMessage(topic: 'ev/h_abc/cmd', payload: '{"relay":1,"state":true}'),
        const MqttInboundMessage(topic: 'ev/h_abc', payload: '{}'),
        const MqttInboundMessage(topic: 'baska/h_abc/state', payload: '{}'),
        const MqttInboundMessage(topic: 'ev/h_abc/state/ekstra', payload: '{}'),
        MqttInboundMessage(topic: 'ev/h_abc/state', payload: big), // 64 KB sınırı
        MqttInboundMessage(topic: 'ev/h_abc/state', payload: stateText(relay: 5, on: true)), // geçerli
      ]);
      await settle();
      expect(states, hasLength(1), reason: 'yalnızca geçerli ileti iletilir');
      expect(states.single.status.relayById(5)!.state, isTrue);
      expect(presences, isEmpty);
      expect(service.droppedMessageCount, 12);
      expect(service.linkState, MqttLinkState.connected, reason: 'bozuk yük bağlantıyı etkilemez');
    });

    test('tip hatalı alanlar çökertmez (relay id metin, state metin, pos taşması)', () async {
      transports.single.deliver(<MqttInboundMessage>[
        const MqttInboundMessage(
          topic: 'ev/h_abc/state',
          payload: '{"relays":[{"id":"3","state":"true"},{"id":null},"x"],'
              '"shutters":[{"pair":"2","pos":"55","moving":"false","dir":"9","target":300}],"child_lock":"yes"}',
        ),
      ]);
      await settle();
      final status = states.single.status;
      expect(status.relayById(3)!.state, isTrue);
      final shutter = status.shutterByPair(2)!;
      expect(shutter.pos, 55);
      expect(shutter.direction, 0);
      expect(shutter.target, isNull);
      expect(status.childLock, isTrue);
    });

    test('stop() sonrası gelen iletiler iletilmez', () async {
      final transport = transports.single;
      await service.stop();
      transport.deliver(<MqttInboundMessage>[
        MqttInboundMessage(topic: 'ev/h_abc/state', payload: stateText()),
      ]);
      await settle();
      expect(states, isEmpty);
    });
  });

  group('kimlik yenileme ve yeniden bağlanma', () {
    test('kimlik süresi dolmadan yenilenir: taze kimlikle yeni bağlantı kurulur, ara durum reconnecting', () async {
      await service.start(
        credentialsProvider: providerOf((call) => creds(
              now: clock.now(),
              validFor: const Duration(hours: 1),
              user: 'a_h_abc_$call',
              clientId: 'cid-$call',
            )),
      );
      await settle();
      expect(providerCalls, 1);

      // 1 saatlik kimlik: bitişten 5 dk önce (55. dk) yenilenir.
      await clock.elapse(const Duration(minutes: 50));
      expect(providerCalls, 1, reason: '50. dk: henüz yenileme zamanı değil');
      await clock.elapse(const Duration(minutes: 6));
      expect(providerCalls, 2, reason: 'süre dolmadan taze kimlik alındı');
      expect(transports, hasLength(2));
      expect(transports.first.closed, isTrue);
      expect(transports.last.credentials!.username, 'a_h_abc_2');
      expect(transports.last.clientId, 'cid-2');
      expect(transports.last.subscriptions, <String>['ev/h_abc/state', 'ev/h_abc/status']);
      expect(links, <MqttLinkState>[
        MqttLinkState.connecting,
        MqttLinkState.connected,
        MqttLinkState.reconnecting,
        MqttLinkState.connected,
      ]);
      expect(service.isConnected, isTrue);
    });

    test('kullanim-10: telefon saati 13 sa ileri + expires_in 12 sa -> yenileme ~11 sa 55 dk sonra (15 sn döngüsü yok)',
        () async {
      await service.start(
        credentialsProvider: providerOf((call) => MqttCredentials(
              host: 'broker.test',
              port: 8884,
              username: 'a_h_abc_$call',
              password: 'gecici-parola',
              // Sunucu saatine göre 12 sa sonra biter; telefon 13 sa ileride olduğundan yerel saate göre GEÇMİŞTE.
              expiresAt: clock.now().subtract(const Duration(hours: 1)),
              expiresIn: const Duration(hours: 12),
              topicId: 'h_abc',
              clientId: 'cid-$call',
            )),
      );
      await settle();
      expect(providerCalls, 1);
      await clock.elapse(const Duration(hours: 11, minutes: 50));
      expect(providerCalls, 1, reason: 'sunucunun verdiği süre esas: erken yenileme döngüsü yok');
      await clock.elapse(const Duration(minutes: 6));
      expect(providerCalls, 2);
    });

    test('kullanim-10: expires_in yok (eski sunucu) ve yerel saate göre süresi geçmiş: en az 5 dk beklenir', () async {
      await service.start(
        credentialsProvider: providerOf((call) => creds(
              now: clock.now(),
              validFor: const Duration(hours: -1),
              user: 'a_h_abc_$call',
            )),
      );
      await settle();
      expect(providerCalls, 1);
      await clock.elapse(const Duration(minutes: 4));
      expect(providerCalls, 1, reason: 'eskiden 15 sn\'de bir yeni kimlik istenirdi');
      await clock.elapse(const Duration(minutes: 2));
      expect(providerCalls, 2);
    });

    test('kullanim-10: MqttCredentials expires_in ayrıştırılır (tam sayı saniye)', () {
      final c = MqttCredentials.fromJson(<String, dynamic>{
        'host': 'broker.test',
        'port': 8884,
        'username': 'u',
        'password': 'p',
        'topic_id': 't',
        'expires_at': '2026-10-08T12:00:00Z',
        'expires_in': 43200,
      });
      expect(c.expiresIn, const Duration(hours: 12));
      final old = MqttCredentials.fromJson(<String, dynamic>{
        'host': 'broker.test',
        'port': 8884,
        'username': 'u',
        'password': 'p',
        'topic_id': 't',
        'expires_at': '2026-10-08T12:00:00Z',
      });
      expect(old.expiresIn, isNull);
    });

    test('beklenmeyen kopma -> kısa bekleme + TAZE kimlikle yeniden bağlanma', () async {
      await service.start(credentialsProvider: providerOf((call) => creds(now: clock.now(), user: 'u$call')));
      await settle();
      transports.single.drop();
      await settle();
      expect(service.linkState, MqttLinkState.reconnecting);
      await clock.elapse(const Duration(seconds: 4));
      expect(providerCalls, 2);
      expect(transports, hasLength(2));
      expect(transports.last.credentials!.username, 'u2');
      expect(service.linkState, MqttLinkState.connected);
    });

    test('kimlik reddi (auth) -> üstel geri çekilmeyle tekrar dener, her turda taze kimlik ister', () async {
      final queue = <MqttConnectOutcome>[
        const MqttConnectOutcome.failed(MqttFailure.authRejected),
        const MqttConnectOutcome.failed(MqttFailure.authRejected),
        const MqttConnectOutcome.ok(),
      ];
      final factoryCalls = <FakeMqttTransport>[];
      final svc = EvMqttService(
        clock: clock,
        random: Random(3),
        useTls: true,
        transportFactory: () {
          final t = FakeMqttTransport()..outcome = queue.removeAt(0);
          factoryCalls.add(t);
          return t;
        },
      );
      addTearDown(svc.dispose);
      final seen = <MqttLinkState>[];
      svc.linkStates.listen(seen.add);
      await svc.start(credentialsProvider: providerOf((call) => creds(now: clock.now(), user: 'u$call')));
      await clock.elapse(const Duration(seconds: 1));
      expect(svc.lastFailure, MqttFailure.authRejected);
      expect(svc.linkState, MqttLinkState.reconnecting);
      await clock.elapse(const Duration(seconds: 30));
      expect(factoryCalls, hasLength(3));
      expect(providerCalls, 3, reason: 'her denemede taze kimlik');
      expect(svc.linkState, MqttLinkState.connected);
      expect(svc.lastFailure, MqttFailure.none);
      expect(seen.first, MqttLinkState.connecting);
      expect(seen.last, MqttLinkState.connected);
    });

    test('geri çekilme üstel artar ve 60 sn ile sınırlıdır (±%20 jitter)', () async {
      final times = <DateTime>[];
      final svc = EvMqttService(
        clock: clock,
        random: Random(5),
        useTls: true,
        transportFactory: () {
          times.add(clock.now());
          return FakeMqttTransport()..outcome = const MqttConnectOutcome.failed(MqttFailure.unreachable);
        },
      );
      addTearDown(svc.dispose);
      await svc.start(credentialsProvider: providerOf((_) => creds(now: clock.now())));
      await clock.elapse(const Duration(minutes: 10), step: const Duration(milliseconds: 500));
      final gaps = <int>[
        for (var i = 1; i < times.length; i++) times[i].difference(times[i - 1]).inMilliseconds,
      ];
      expect(gaps.length, greaterThan(6));
      expect(gaps.first, inInclusiveRange(1500, 2600)); // ~2 sn
      expect(gaps[1], inInclusiveRange(3000, 5000)); // ~4 sn
      expect(gaps[2], inInclusiveRange(6000, 10000)); // ~8 sn
      expect(gaps.reduce(max), lessThanOrEqualTo(72500)); // 60 sn + %20 jitter
      expect(gaps.last, greaterThan(40000));
      svc.dispose();
    });

    test('kimlik sağlayıcı 403 verirse (ör. GUEST_EXPIRED) KALICI durur; ağ hatasında yeniden dener', () async {
      var mode = 'net';
      final svc = EvMqttService(
        clock: clock,
        random: Random(9),
        useTls: true,
        transportFactory: () {
          final t = FakeMqttTransport();
          transports.add(t);
          return t;
        },
      );
      addTearDown(svc.dispose);
      await svc.start(credentialsProvider: () async {
        providerCalls++;
        if (mode == 'net') throw ApiException.network();
        throw const ApiException(statusCode: 403, code: 'GUEST_EXPIRED', message: 'süre doldu');
      });
      await clock.elapse(const Duration(seconds: 10));
      expect(providerCalls, greaterThan(1), reason: 'ağ hatasında tekrar denenir');
      expect(transports, isEmpty);
      expect(svc.linkState, MqttLinkState.reconnecting);

      mode = 'forbidden';
      await clock.elapse(const Duration(seconds: 70));
      expect(svc.linkState, MqttLinkState.disconnected);
      final calls = providerCalls;
      await clock.elapse(const Duration(minutes: 5));
      expect(providerCalls, calls, reason: 'kalıcı yetki hatasında döngü durur');
    });

    test('start() tekrar çağrılırsa önceki bağlantı kapatılır (tek aktif döngü)', () async {
      await service.start(credentialsProvider: providerOf((_) => creds(now: clock.now(), topic: 'h_one')));
      await settle();
      await service.start(credentialsProvider: providerOf((_) => creds(now: clock.now(), topic: 'h_two')));
      await settle();
      expect(transports.first.closed, isTrue);
      expect(service.topicId, 'h_two');
      transports.first.deliver(<MqttInboundMessage>[
        MqttInboundMessage(topic: 'ev/h_one/state', payload: stateText()),
      ]);
      await settle();
      expect(states, isEmpty, reason: 'eski bağlantıdan ileti gelmez');
    });

    test('dispose sonrası hiçbir şey çalışmaz; akışlar kapanır', () async {
      await service.start(credentialsProvider: providerOf((_) => creds(now: clock.now())));
      await settle();
      service.dispose();
      expect(transports.single.closed, isTrue);
      await clock.elapse(const Duration(hours: 24));
      expect(transports, hasLength(1));
      // dispose sonrası start no-op
      await service.start(credentialsProvider: providerOf((_) => creds(now: clock.now())));
      expect(transports, hasLength(1));
    });
  });
}
