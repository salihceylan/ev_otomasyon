import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// Bağlanma (TCP/TLS) süre sınırları.
///
/// * PF-27 (MQTT): `connectTimeoutPeriod` yalnızca CONNACK beklemesini sınırlar; soket/TLS kurulumu
///   (`SecureSocket.connect`, `socketTimeout` null) süre sınırsızdır. Sessizce paket düşüren ağda bağlanma
///   işletim sistemi zaman aşımına kadar döngüyü bloklardı (Android'de ölçülmedi, tahmin 75-130 sn). Servis
///   artık `transport.connect(...)`'i Clock yarışıyla (CONNACK süresi 10 sn + 5 sn) sınırlar; süre dolunca
///   `MqttFailure.timeout` olarak geri çekilmeyle yeniden dener.
/// * PF-36 (LAN HTTP): varsayılan (enjekte edilmemiş) `http.Client`'ta `HttpClient.connectionTimeout` yoktu;
///   Dart düzeyindeki `future.timeout(...)` dart:io bağlantı denemesini iptal etmez. Gerçek bir takılı bağlanma
///   ağ/cihaz gerektirdiğinden test YAPISALDIR: istemcinin yapılandırması (`connectionTimeout`) ve mevcut
///   enjeksiyon yollarının (`client:`, `http.runWithClient`) korunduğu doğrulanır.
void main() {
  late FakeClock clock;
  late List<FakeMqttTransport> transports;
  late int providerCalls;
  late EvMqttService service;
  late List<DeviceStateMessage> states;

  MqttCredentials creds({int port = 8884, String host = 'broker.test'}) => MqttCredentials(
        host: host,
        port: port,
        username: 'a_h_abc_1',
        password: 'gecici-parola',
        expiresAt: clock.now().add(const Duration(hours: 12)),
        topicId: 'h_abc',
        clientId: 'cid-1',
      );

  Future<MqttCredentials> provider() async {
    providerCalls++;
    return creds();
  }

  const stateJson = '{"v":2,"uid":"AHBU-S3-ABC123","relays":[{"id":1,"name":"R","type":"light","state":true}],"shutters":[]}';

  /// n. aktarımın (0 tabanlı) `connect`'i takılsın mı? Takılanın `connectGate`'i bir `Completer`dır.
  void build({required bool Function(int index) hangs}) {
    service = EvMqttService(
      clock: clock,
      random: Random(7),
      useTls: true,
      transportFactory: () {
        final transport = FakeMqttTransport();
        if (hangs(transports.length)) transport.connectGate = Completer<void>();
        transports.add(transport);
        return transport;
      },
    );
    addTearDown(service.dispose);
    service.stateMessages.listen(states.add);
  }

  setUp(() {
    clock = FakeClock();
    transports = <FakeMqttTransport>[];
    providerCalls = 0;
    states = <DeviceStateMessage>[];
  });

  group('PF-27: takılan TCP/TLS kurulumu Clock sınırıyla bırakılır', () {
    test('takılan bağlanma 15 sn sonra zaman aşımı sayılır; geri çekilmeyle taze kimlikle yeniden denenir', () async {
      build(hangs: (_) => true);
      await service.start(credentialsProvider: provider);

      await clock.elapse(const Duration(seconds: 14, milliseconds: 900));
      expect(service.linkState, MqttLinkState.connecting, reason: 'sınırdan 100 ms önce hâlâ ilk bağlantı bekleniyor');
      expect(service.lastFailure, MqttFailure.none);
      expect(providerCalls, 1);
      expect(transports.single.closed, isFalse);

      await clock.elapse(const Duration(milliseconds: 200)); // 15,1 sn
      expect(service.lastFailure, MqttFailure.timeout, reason: 'CONNACK 10 sn + soket/TLS payı 5 sn');
      expect(service.linkState, MqttLinkState.reconnecting);
      expect(transports.first.closed, isTrue, reason: 'bırakılan deneme kapatılır');

      await clock.elapse(const Duration(seconds: 5)); // 20,1 sn: geri çekilme (~2 sn) doldu
      expect(providerCalls, 2, reason: 'her denemede taze kimlik');
      expect(transports, hasLength(2));
      expect(service.linkState, MqttLinkState.reconnecting);
      expect(transports.last.closed, isFalse, reason: 'ikinci deneme sürüyor');
    });

    test('takılı denemeler üst üste: her biri 15 sn sonra bırakılır, bekleme büyür (2 sn, sonra 4 sn)', () async {
      build(hangs: (_) => true);
      await service.start(credentialsProvider: provider);

      // 1. deneme 0-15 sn, bekleme ~2 sn, 2. deneme ~17-32 sn, bekleme ~4 sn, 3. deneme ~36-51 sn.
      await clock.elapse(const Duration(seconds: 40));
      expect(providerCalls, 3);
      expect(transports, hasLength(3));
      expect(transports[0].closed, isTrue);
      expect(transports[1].closed, isTrue);
      expect(transports[2].closed, isFalse, reason: '3. deneme henüz sınıra varmadı');
      expect(service.lastFailure, MqttFailure.timeout);
      expect(service.linkState, MqttLinkState.reconnecting);
    });

    test('sınıra girmeden (9 sn) tamamlanan yavaş bağlanma BAŞARILIDIR ve sınır zamanlayıcısı bırakılmaz', () async {
      build(hangs: (_) => true);
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 9));
      expect(service.linkState, MqttLinkState.connecting);

      transports.single.connectGate!.complete(); // yavaş ama dönen TLS kurulumu
      await clock.elapse(const Duration(milliseconds: 100));
      expect(service.linkState, MqttLinkState.connected);
      expect(service.lastFailure, MqttFailure.none);
      expect(transports.single.subscriptions, <String>['ev/h_abc/state', 'ev/h_abc/status']);
      expect(clock.activeTimerCount, 1, reason: 'yalnızca kimlik yenileme zamanlayıcısı; bağlanma sınırı zamanlayıcısı iptal edildi');

      await clock.elapse(const Duration(minutes: 1));
      expect(service.linkState, MqttLinkState.connected, reason: 'iptal edilen sınır sonradan tetiklenmez');
      expect(service.lastFailure, MqttFailure.none);
      expect(providerCalls, 1);
      expect(transports, hasLength(1));
      expect(transports.single.closed, isFalse);
    });

    test('sınırdan sonra geç tamamlanan eski aktarım: kapalı kalır, abone olmaz, ileti iletmez, durumu bozmaz', () async {
      build(hangs: (index) => index == 0); // 1. deneme takılır, 2. deneme hemen bağlanır
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 20));
      expect(service.linkState, MqttLinkState.connected, reason: '2. deneme bağlandı');
      expect(transports, hasLength(2));
      expect(transports[0].closed, isTrue);
      expect(providerCalls, 2);

      // Eski (bırakılmış) aktarımın bağlanması sonunda dönüyor: kimse artık beklemiyor.
      transports[0].connectGate!.complete();
      await clock.elapse(const Duration(seconds: 1));
      transports[0].deliver(<MqttInboundMessage>[const MqttInboundMessage(topic: 'ev/h_abc/state', payload: stateJson)]);
      await clock.elapse(const Duration(seconds: 1));

      expect(transports[0].closed, isTrue);
      expect(transports[0].subscriptions, isEmpty, reason: 'geç dönen eski aktarıma hiç abone olunmaz');
      expect(states, isEmpty, reason: 'eski aktarımdan ileti iletilmez');
      expect(service.linkState, MqttLinkState.connected, reason: 'canlı bağlantı etkilenmez');
      expect(service.topicId, 'h_abc');
      expect(transports, hasLength(2), reason: 'geç tamamlanma yeni deneme tetiklemez');
      expect(providerCalls, 2);

      // Kontrol: canlı (2.) aktarımdan gelen ileti iletilir.
      transports[1].deliver(<MqttInboundMessage>[const MqttInboundMessage(topic: 'ev/h_abc/state', payload: stateJson)]);
      await clock.elapse(const Duration(seconds: 1));
      expect(states, hasLength(1));
    });

    test('geç tamamlanan eski aktarım HATA ile dönerse de yutulur (ele alınmamış hata yok)', () async {
      build(hangs: (index) => index == 0);
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 20));
      expect(service.linkState, MqttLinkState.connected);

      transports[0].outcome = const MqttConnectOutcome.failed(MqttFailure.tls);
      transports[0].connectGate!.complete();
      await clock.elapse(const Duration(seconds: 1));

      expect(service.linkState, MqttLinkState.connected);
      expect(service.lastFailure, MqttFailure.none, reason: 'bırakılmış denemenin geç sonucu son hatayı ezmez');
    });

    test('stop() takılı bağlanmayı bırakır: eski döngü sonradan hiçbir şey yapmaz', () async {
      build(hangs: (_) => true);
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 5));
      await service.stop();
      expect(service.linkState, MqttLinkState.disconnected);
      expect(transports.single.closed, isTrue);

      await clock.elapse(const Duration(minutes: 3));
      expect(providerCalls, 1);
      expect(transports, hasLength(1));
      expect(service.linkState, MqttLinkState.disconnected);
      expect(clock.activeTimerCount, 0, reason: 'sınır zamanlayıcısı dolup bitti; döngü sonlandı');
    });

    test('stop() sonrası eski aktarımın kapısı açılsa bile bağlantı durumu değişmez', () async {
      build(hangs: (_) => true);
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 5));
      await service.stop();
      transports.single.connectGate!.complete();
      await clock.elapse(const Duration(seconds: 1));

      expect(service.linkState, MqttLinkState.disconnected);
      expect(transports.single.subscriptions, isEmpty);
      expect(service.topicId, isNull);
    });

    test('start() yeniden çağrılırsa takılı eski deneme bırakılır; yeni döngü bağımsız bağlanır', () async {
      build(hangs: (index) => index == 0);
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 5));

      await service.start(credentialsProvider: provider); // ör. ev değişimi: önceki döngü durdurulur
      await clock.elapse(const Duration(milliseconds: 100));
      expect(transports, hasLength(2));
      expect(transports[0].closed, isTrue);
      expect(service.linkState, MqttLinkState.connected);

      await clock.elapse(const Duration(minutes: 1)); // eski döngünün sınırı dolsa da yeni bağlantıya dokunmaz
      expect(service.linkState, MqttLinkState.connected);
      expect(transports[1].closed, isFalse);
      expect(transports, hasLength(2));
      expect(providerCalls, 2);
    });

    test('dispose() takılı bağlanma sırasında: sonradan hiçbir şey çalışmaz', () async {
      build(hangs: (_) => true);
      await service.start(credentialsProvider: provider);
      await clock.elapse(const Duration(seconds: 5));
      service.dispose();
      expect(transports.single.closed, isTrue);

      await clock.elapse(const Duration(minutes: 3));
      expect(providerCalls, 1);
      expect(transports, hasLength(1));
      expect(clock.activeTimerCount, 0);
    });
  });

  group('PF-27: kaynak korumaları (mqtt_client tuzakları)', () {
    late String source;

    setUp(() => source = File('lib/services/ev_mqtt_service.dart').readAsStringSync());

    test('socketTimeout ATANMAZ: atanırsa connectTimeoutPeriod 10 ms olur ve CONNACK beklemesi kapanır', () {
      expect(
        RegExp(r'\bsocketTimeout\s*=').hasMatch(source),
        isFalse,
        reason: 'mqtt_client socketTimeout atanınca CONNACK beklemesini 10 ms yapar (maxConnectionAttempts: 1 ile her bağlantı başarısız olur)',
      );
      expect(source.contains('..connectTimeoutPeriod = timeout.inMilliseconds'), isTrue);
    });

    test('MqttClientTransport.connect: connect() döndükten sonra kapatılmışsa bağlantıyı akışa bağlamadan bırakır (savunma)', () {
      expect(
        RegExp(r'await client\.connect\(\);\s*if \(_closed\) \{').hasMatch(source),
        isTrue,
        reason: 'close() bağlanma sürerken çağrıldıysa geç tamamlanan bağlantı abonelik akışına bağlanmadan bırakılmalı '
            '(davranış testi için gerçek mqtt_client bu yolda connect() döndürmez: NoConnectionException fırlatır)',
      );
    });
  });

  group('PF-27: gerçek MqttClientTransport + yerel sahte aracı (loopback; ağ/cihaz YOK)', () {
    test('CONNACK gecikse de (300 ms) bağlanır (socketTimeout tuzağına karşı davranış koruması); close() soketi kapatır', () async {
      final broker = await _LoopbackBroker.start(connackDelay: const Duration(milliseconds: 300));
      addTearDown(broker.close);
      final transport = MqttClientTransport();
      addTearDown(transport.close);

      final outcome = await transport.connect(
        credentials: creds(host: '127.0.0.1', port: broker.port),
        clientId: 'cid-loopback',
        secure: false,
        timeout: const Duration(seconds: 5),
      );
      expect(outcome.ok, isTrue, reason: 'ok değilse: ${outcome.failure}');
      expect(broker.connects, 1);

      transport.close();
      await _waitFor(() => broker.closedByPeer >= 1, 'aracı soketin kapandığını görmedi');
      expect(broker.closedByPeer, 1);
    });

    test('aracı CONNACK ile yetkisiz (kod 5) derse authRejected döner', () async {
      final broker = await _LoopbackBroker.start(connackDelay: Duration.zero, returnCode: 5);
      addTearDown(broker.close);
      final transport = MqttClientTransport();
      addTearDown(transport.close);

      final outcome = await transport.connect(
        credentials: creds(host: '127.0.0.1', port: broker.port),
        clientId: 'cid-loopback',
        secure: false,
        timeout: const Duration(seconds: 5),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure, MqttFailure.authRejected);
    });

    test('CONNACK hiç gelmezse aktarım kendi CONNACK sınırıyla (connectTimeoutPeriod) bırakır', () async {
      final broker = await _LoopbackBroker.start(); // TCP kabul eder, CONNECT'e yanıt vermez
      addTearDown(broker.close);
      final transport = MqttClientTransport();
      addTearDown(transport.close);

      final watch = Stopwatch()..start();
      final outcome = await transport.connect(
        credentials: creds(host: '127.0.0.1', port: broker.port),
        clientId: 'cid-loopback',
        secure: false,
        timeout: const Duration(seconds: 1),
      );
      watch.stop();
      expect(outcome.ok, isFalse);
      expect(outcome.failure, isNot(MqttFailure.none));
      expect(broker.connects, 1);
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)), reason: 'CONNACK beklemesi sınırlıdır (soket kurulumundan farklı)');
    });

    test('close() bağlanma sürerken çağrılırsa geç açılan soketten CONNECT GÖNDERİLMEZ (aynı clientId düşürülmez)', () async {
      final broker = await _LoopbackBroker.start(connackDelay: const Duration(milliseconds: 100));
      addTearDown(broker.close);
      final transport = MqttClientTransport();

      final pending = transport.connect(
        credentials: creds(host: '127.0.0.1', port: broker.port),
        clientId: 'cid-loopback',
        secure: false,
        timeout: const Duration(seconds: 1),
      );
      transport.close(); // soket aşamasında: servis süre sınırında denemeyi bıraktı / durduruldu

      final outcome = await pending;
      expect(outcome.ok, isFalse);
      expect(broker.accepted, 1, reason: 'işletim sistemi bağlantıyı yine kurdu (geç soket)');
      expect(
        broker.connects,
        0,
        reason: 'kapatılmış aktarım CONNECT göndermez: broker, aynı clientId ile bağlı canlı oturumu düşüremez '
            '(mqtt_client 10.11.11 davranışı; kütüphane yükseltilirse bu varsayım yeniden doğrulanmalı)',
      );
    });

    test('sessiz TLS el sıkışması (TCP kurulur, TLS yanıtı gelmez): servis 15 sn sonra bırakır ve yeniden dener', () async {
      final blackHole = await _LoopbackBroker.start(); // TCP kabul eder, TLS ServerHello hiç gelmez
      addTearDown(blackHole.close);
      final svc = EvMqttService(clock: clock, random: Random(5), useTls: true); // gerçek MqttClientTransport
      addTearDown(svc.dispose);

      await svc.start(credentialsProvider: () async {
        providerCalls++;
        return creds(host: '127.0.0.1', port: blackHole.port);
      });
      await _waitFor(() => blackHole.accepted >= 1, 'gerçek aktarım TCP bağlantısı kurmadı');

      await clock.elapse(const Duration(seconds: 14, milliseconds: 900));
      expect(svc.linkState, MqttLinkState.connecting, reason: 'TLS el sıkışması sürüyor (CONNACK sınırı bunu kapsamaz)');
      expect(svc.lastFailure, MqttFailure.none);

      await clock.elapse(const Duration(milliseconds: 200));
      expect(svc.lastFailure, MqttFailure.timeout);
      expect(svc.linkState, MqttLinkState.reconnecting);

      await clock.elapse(const Duration(seconds: 5));
      expect(providerCalls, 2, reason: 'geri çekilmeden sonra taze kimlikle yeni deneme');
      await svc.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100)); // kütüphanenin geç olayları testin içinde bitsin
    });
  });

  group('PF-36: varsayılan LAN HTTP istemcisinin bağlanma süresi sınırlıdır', () {
    /// Enjekte edilmemiş istemcinin kurulduğu dart:io `HttpClient`'ı yakalar (ağ erişimi YOK).
    List<_RecordingHttpClient> captureHttpClients(void Function() body) {
      final created = <_RecordingHttpClient>[];
      HttpOverrides.runZoned(
        body,
        createHttpClient: (context) {
          final client = _RecordingHttpClient();
          created.add(client);
          return client;
        },
      );
      return created;
    }

    test('enjekte edilmemiş istemci: HttpClient.connectionTimeout 4 sn (Future.timeout soketi iptal etmez)', () {
      late AutomationApiService service;
      final created = captureHttpClients(() => service = AutomationApiService(baseUrl: 'http://192.168.1.30'));
      expect(created, hasLength(1));
      expect(created.single.connectionTimeout, const Duration(seconds: 4));

      service.dispose();
      expect(created.single.closed, isTrue, reason: 'varsayılan istemci servise aittir: dispose kapatır');
    });

    test('kurtarma AP fabrikası ve LAN adresi de aynı sınırlı istemciyi kullanır', () {
      final created = captureHttpClients(() {
        AutomationApiService.recoveryAp().dispose();
        AutomationApiService(baseUrl: '').dispose();
      });
      expect(created, hasLength(2));
      for (final client in created) {
        expect(client.connectionTimeout, const Duration(seconds: 4));
      }
    });

    test('enjekte edilen istemci DEĞİŞTİRİLMEZ: yeni HttpClient açılmaz, dispose() onu kapatmaz (istemci çağırana aittir)', () {
      final injected = _CloseCountingClient();
      late AutomationApiService service;
      final created = captureHttpClients(() {
        service = AutomationApiService(baseUrl: 'http://192.168.1.30', client: injected);
        service.copyWith(localKey: 'devicekey-1234');
      });
      expect(created, isEmpty, reason: 'client: veren testler (MockApi vb.) etkilenmez');
      service.dispose();
      expect(injected.closeCalls, 0);
    });

    test('http.runWithClient ile verilen istemci KORUNUR (mevcut Wi-Fi sihirbazı testleri buna dayanır): dart:io HttpClient açılmaz', () async {
      final api = MockApi()
        ..on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'device': 'AHBU-S3-TEST01', 'provisioned': true}));
      late AutomationApiService service;
      final created = captureHttpClients(() {
        service = http.runWithClient(() => AutomationApiService(baseUrl: 'http://192.168.1.30'), () => api.client);
      });
      expect(created, isEmpty, reason: 'http.Client() sonucu aynen korunur; doğrudan IOClient kurulsaydı bu geçersiz kılma atlanırdı');

      final status = await service.fetchStatus();
      expect(status.uid, 'AHBU-S3-TEST01');
      expect(api.requests, hasLength(1), reason: 'istek runWithClient istemcisinden geçti');
      service.dispose();
    });

    test('varsayılan istemciyi kullanan copyWith kopyası yeni HttpClient AÇMAZ (aynı sınırlı istemci paylaşılır)', () {
      final created = captureHttpClients(() {
        final service = AutomationApiService(baseUrl: 'http://192.168.1.30');
        service.copyWith(localKey: 'devicekey-1234');
      });
      expect(created, hasLength(1));
      expect(created.single.connectionTimeout, const Duration(seconds: 4));
    });

    test('gerçek dart:io istemcisi (loopback): yoklama başarılı; dinleyen olmayan porta ağ hatası (LocalApiException.network)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"device":"AHBU-S3-TEST01","name":"Pano","fw":"1.1.0","provisioned":true,"wifi_connected":true}')
          ..close();
      });
      final service = AutomationApiService(baseUrl: 'http://127.0.0.1:${server.port}');
      addTearDown(service.dispose);

      final status = await service.fetchStatus();
      expect(status.uid, 'AHBU-S3-TEST01');
      expect(status.restricted, isTrue);
      expect(requests, 1);

      // Sunucu kapatılınca (dinleyen yok): bağlantı reddedilir -> sınırsız bekleme yok, ağ hatası.
      await server.close(force: true);
      await expectLater(
        service.fetchStatus(),
        throwsA(isA<LocalApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
      );
    });
  });
}

/// Enjekte edilen `http.Client`: hiçbir istek göndermez; yalnızca `close()` çağrılarını sayar.
class _CloseCountingClient extends http.BaseClient {
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => throw UnimplementedError('bu testte istek gönderilmez');

  @override
  void close() => closeCalls++;
}

/// `HttpClient` yerine geçen kayıtçı: yalnızca ayarlanan özellikleri tutar (ağ erişimi YOK).
class _RecordingHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  bool closed = false;

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Yerel (127.0.0.1) sahte MQTT aracısı: ham TCP kabul eder. [connackDelay] verilirse CONNECT paketine o
/// gecikmeyle `returnCode`'lu CONNACK döner; verilmezse hiç yanıt vermez (CONNACK gelmez / TLS sessiz).
class _LoopbackBroker {
  _LoopbackBroker._(this._server);

  final ServerSocket _server;
  final List<Socket> _sockets = <Socket>[];
  int accepted = 0;
  int connects = 0;
  int closedByPeer = 0;

  int get port => _server.port;

  static Future<_LoopbackBroker> start({Duration? connackDelay, int returnCode = 0}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final broker = _LoopbackBroker._(server);
    server.listen((socket) {
      broker.accepted++;
      broker._sockets.add(socket);
      socket.listen(
        (data) {
          if (data.isNotEmpty && data.first == 0x10) {
            broker.connects++; // MQTT CONNECT
            if (connackDelay != null) {
              Timer(connackDelay, () {
                try {
                  socket.add(<int>[0x20, 0x02, 0x00, returnCode]); // CONNACK
                } catch (_) {}
              });
            }
          }
        },
        onDone: () => broker.closedByPeer++,
        onError: (Object _) => broker.closedByPeer++,
        cancelOnError: true,
      );
    });
    return broker;
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// Gerçek (saat dışı) bekleme: [condition] sağlanana kadar 10 ms aralıkla yoklar.
Future<void> _waitFor(bool Function() condition, String message, {Duration limit = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(message, limit);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
