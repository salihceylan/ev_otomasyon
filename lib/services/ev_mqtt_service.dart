import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config/app_config.dart';
import '../models/api_models.dart';
import '../models/automation_models.dart';
import '../models/json_utils.dart';
import 'api_exception.dart';
import 'clock.dart';

/// Canlı MQTT bağlantı durumu.
enum MqttLinkState {
  /// Bağlı değil (başlatılmadı / durduruldu / kalıcı hata).
  disconnected,

  /// İlk bağlantı kuruluyor.
  connecting,

  /// Bağlı ve `state`/`status` konularına abone.
  connected,

  /// Koptu; yeniden bağlanılıyor (kimlik yenilemesi dahil).
  reconnecting,
}

/// Bağlantı hatası türü.
enum MqttFailure { none, authRejected, unreachable, tls, timeout, other }

/// Aboneliklerden gelen ham ileti.
class MqttInboundMessage {
  const MqttInboundMessage({required this.topic, required this.payload, this.retained = false});

  final String topic;
  final String payload;

  /// Abonelik anında brokerın verdiği "retained" ileti (canlı değil, son bilinen değer).
  final bool retained;
}

/// `ev/{t}/state` iletisi (tam anlık cihaz durumu).
class DeviceStateMessage {
  const DeviceStateMessage({
    required this.topicId,
    required this.status,
    required this.retained,
    required this.receivedAt,
  });

  final String topicId;
  final DeviceStatus status;

  /// `true`: brokerın saklı son değeri (canlı değil; cihazın çevrimiçi olduğunu **kanıtlamaz**).
  final bool retained;
  final DateTime receivedAt;
}

/// `ev/{t}/status` iletisi (`online` / `offline`; LWT dahil).
class DevicePresenceMessage {
  const DevicePresenceMessage({
    required this.topicId,
    required this.online,
    required this.retained,
    required this.receivedAt,
  });

  final String topicId;
  final bool online;
  final bool retained;
  final DateTime receivedAt;
}

/// Bağlantı denemesi sonucu.
class MqttConnectOutcome {
  const MqttConnectOutcome.ok()
      : ok = true,
        failure = MqttFailure.none;
  const MqttConnectOutcome.failed(this.failure) : ok = false;

  final bool ok;
  final MqttFailure failure;
}

/// MQTT istemcisi soyutlaması (gerçek: `mqtt_client`; testte sahte aktarım enjekte edilir).
abstract class MqttTransport {
  /// Bir "güncelleme grubundaki" **tüm** iletiler tek liste olarak gelir.
  Stream<List<MqttInboundMessage>> get messageBatches;

  /// Bağlantı koptuğunda (sunucu/ağ kaynaklı) bir olay üretir.
  Stream<void> get disconnected;

  /// Abonelik reddedilirse (ACL) konu adı gelir.
  Stream<String> get subscribeFailures;

  Future<MqttConnectOutcome> connect({
    required MqttCredentials credentials,
    required String clientId,
    required bool secure,
    required Duration timeout,
  });

  void subscribe(String topic);

  /// Bağlantıyı kapatır ve kaynakları bırakır (tekrar kullanılmaz).
  void close();
}

typedef MqttTransportFactory = MqttTransport Function();

/// Kimlik sağlayıcı: her (yeniden) bağlantıda sunucudan **taze** süreli kimlik alınır.
typedef MqttCredentialsProvider = Future<MqttCredentials> Function();

/// `mqtt_client` tabanlı gerçek aktarım. **Yalnızca abonelik**: yayın yolu yoktur.
class MqttClientTransport implements MqttTransport {
  MqttServerClient? _client;
  bool _closed = false;
  final _batches = StreamController<List<MqttInboundMessage>>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  final _subscribeFailures = StreamController<String>.broadcast();
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;

  @override
  Stream<List<MqttInboundMessage>> get messageBatches => _batches.stream;

  @override
  Stream<void> get disconnected => _disconnected.stream;

  @override
  Stream<String> get subscribeFailures => _subscribeFailures.stream;

  @override
  Future<MqttConnectOutcome> connect({
    required MqttCredentials credentials,
    required String clientId,
    required bool secure,
    required Duration timeout,
  }) async {
    final client = MqttServerClient.withPort(
      credentials.host,
      clientId,
      credentials.port,
      maxConnectionAttempts: 1, // yeniden deneme döngüsü serviste (taze kimlikle)
    );
    _client = client;
    client
      ..secure = secure
      ..keepAlivePeriod = 30
      ..autoReconnect = false
      ..connectTimeoutPeriod = timeout.inMilliseconds
      ..logging(on: false)
      ..setProtocolV311();
    if (secure) {
      // Sertifika doğrulaması AÇIK (onBadCertificate atanmaz): sistem kök sertifikaları kullanılır.
      client.securityContext = SecurityContext.defaultContext;
    }
    client.onDisconnected = () {
      if (!_closed && !_disconnected.isClosed) _disconnected.add(null);
    };
    client.onSubscribeFail = (String topic) {
      if (!_subscribeFailures.isClosed) _subscribeFailures.add(topic);
    };
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(credentials.username, credentials.password)
        .startClean();

    try {
      final status = await client.connect();
      if (_closed) {
        // close() bağlanma SÜRERKEN çağrıldı (servis süre sınırında denemeyi bıraktı ya da durduruldu): geç
        // tamamlanan bağlantı sahipsizdir; gelen-ileti akışına bağlanmaz (kapanmış akışlara abonelik sızmaz) ve
        // bırakılır. Savunma amaçlıdır: mqtt_client 10.11.11'de close()'taki disconnect() işleyiciyi
        // `disconnected` yapar, geç soketten CONNECT GÖNDERİLMEZ ve connect() genellikle NoConnectionException
        // ile biter (aşağıdaki catch). O yolda geç açılan soket kütüphanenin içinde kalır (dışarıdan
        // kapatılamaz; CONNECT'siz boşta durur, ömrü broker/işletim sistemi zaman aşımına bağlıdır).
        try {
          client.disconnect();
        } catch (_) {}
        return const MqttConnectOutcome.failed(MqttFailure.other);
      }
      if (status?.state == MqttConnectionState.connected) {
        _updatesSub = client.updates?.listen(_onUpdates);
        return const MqttConnectOutcome.ok();
      }
      final code = status?.returnCode;
      final authRejected = code == MqttConnectReturnCode.badUsernameOrPassword ||
          code == MqttConnectReturnCode.notAuthorized ||
          code == MqttConnectReturnCode.identifierRejected;
      client.disconnect();
      return MqttConnectOutcome.failed(authRejected ? MqttFailure.authRejected : MqttFailure.other);
    } on HandshakeException {
      client.disconnect();
      return const MqttConnectOutcome.failed(MqttFailure.tls);
    } on TlsException {
      client.disconnect();
      return const MqttConnectOutcome.failed(MqttFailure.tls);
    } on SocketException {
      client.disconnect();
      return const MqttConnectOutcome.failed(MqttFailure.unreachable);
    } on TimeoutException {
      client.disconnect();
      return const MqttConnectOutcome.failed(MqttFailure.timeout);
    } on NoConnectionException {
      final code = client.connectionStatus?.returnCode;
      final authRejected = code == MqttConnectReturnCode.badUsernameOrPassword ||
          code == MqttConnectReturnCode.notAuthorized;
      client.disconnect();
      return MqttConnectOutcome.failed(authRejected ? MqttFailure.authRejected : MqttFailure.unreachable);
    } catch (_) {
      client.disconnect();
      return const MqttConnectOutcome.failed(MqttFailure.other);
    }
  }

  void _onUpdates(List<MqttReceivedMessage<MqttMessage>> updates) {
    final batch = <MqttInboundMessage>[];
    // Gruptaki TÜM iletiler işlenir (eski kod yalnızca ilkini işliyordu).
    for (final update in updates) {
      final message = update.payload;
      if (message is! MqttPublishMessage) continue;
      try {
        final bytes = message.payload.message;
        batch.add(
          MqttInboundMessage(
            topic: update.topic,
            payload: utf8.decode(bytes),
            retained: message.header?.retain ?? false,
          ),
        );
      } catch (_) {
        // Geçersiz UTF-8: ileti atılır.
      }
    }
    if (batch.isNotEmpty && !_batches.isClosed) _batches.add(batch);
  }

  @override
  void subscribe(String topic) {
    _client?.subscribe(topic, MqttQos.atLeastOnce);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _updatesSub?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    _batches.close();
    _disconnected.close();
    _subscribeFailures.close();
  }
}

/// Bulut MQTT **abonelik** hizmeti (CONTRACTS §2).
///
/// * Uygulama MQTT'ye **yayın yapmaz** (yayın yolları yoktur): tüm komutlar REST ile gider.
/// * Kimlik **sunucudan** gelir ([MqttCredentialsProvider] -> `POST /homes/:id/mqtt-credentials`);
///   gömülü parola yoktur. Kimlik süre dolmadan yenilenir; kopmada **taze** kimlikle üstel
///   geri çekilme + jitter ile yeniden bağlanılır. Aracı kimliği reddederse (sunucuda silinmiş / süresi dolmuş)
///   bayat kimlik atılır ve beklemeden **bir kez** taze kimlik alınır; sağlayıcı 401/403/404 verirse döngü durur.
/// * İstemci kimliği: sunucunun verdiği `client_id`; yoksa `app_<kalıcı kurulum kimliği>_<oturum eki>`.
/// * Canlı [linkStates]; abonelik grubundaki **tüm** iletiler işlenir; bozuk yük atılır ve sayılır.
class EvMqttService {
  EvMqttService({
    MqttTransportFactory? transportFactory,
    this._clock = const SystemClock(),
    Random? random,
    bool? useTls,
  })  : _transportFactory = transportFactory ?? MqttClientTransport.new,
        _random = random ?? Random.secure(),
        _useTls = useTls ?? AppConfig.current.mqttUseTls;

  final MqttTransportFactory _transportFactory;
  final Clock _clock;
  final Random _random;
  final bool _useTls;

  static const int _maxPayloadChars = 64 * 1024;

  /// CONNACK (broker onayı) bekleme süresi (`mqtt_client` `connectTimeoutPeriod`). Soket/TLS kurulumunu
  /// KAPSAMAZ: onu [_connectBounded] sınırlar (`_connectTimeout + _connectGrace` = 15 sn).
  static const Duration _connectTimeout = Duration(seconds: 10);

  /// TCP/TLS kurulumu için CONNACK süresinin ÜSTÜNE tanınan pay (yavaş mobil ağda erken pes etmemek için).
  static const Duration _connectGrace = Duration(seconds: 5);

  static const Duration _maxBackoff = Duration(seconds: 60);

  /// Bu kadar (ya da daha uzun) yaşayan bağlantı "kararlı" sayılır: kopmasında geri çekilme sayacı sıfırlanır
  /// (PF-28). Daha kısa ömürlü bağlantılar (bağlanıp hemen düşen) üstel geri çekilmeyi sürdürür.
  static const Duration _stableConnection = Duration(seconds: 30);

  final _linkController = StreamController<MqttLinkState>.broadcast();
  final _stateController = StreamController<DeviceStateMessage>.broadcast();
  final _statusController = StreamController<DevicePresenceMessage>.broadcast();

  MqttLinkState _link = MqttLinkState.disconnected;
  int _generation = 0;
  String? _topicId;
  MqttTransport? _transport;
  final List<StreamSubscription<dynamic>> _transportSubs = [];
  Timer? _renewTimer;
  Completer<void>? _sessionEnded;
  int _dropped = 0;
  MqttFailure _lastFailure = MqttFailure.none;
  bool _disposed = false;
  bool _everConnected = false;

  /// Bağlantı durumu akışı (yalnızca değişimlerde olay üretir).
  Stream<MqttLinkState> get linkStates => _linkController.stream;
  MqttLinkState get linkState => _link;
  bool get isConnected => _link == MqttLinkState.connected;

  /// Cihaz `state` iletileri (tam anlık durum).
  Stream<DeviceStateMessage> get stateMessages => _stateController.stream;

  /// Cihaz `status` iletileri (`online`/`offline`).
  Stream<DevicePresenceMessage> get statusMessages => _statusController.stream;

  /// Çözülemeyen / sınır dışı / yanlış konulu ileti sayısı (tanılama).
  int get droppedMessageCount => _dropped;

  /// Son bağlantı hatası türü (sır içermez).
  MqttFailure get lastFailure => _lastFailure;

  /// Abone olunan ev konu kimliği (bağlıyken).
  String? get topicId => _topicId;

  // ---------------------------------------------------------------------------
  // Yaşam döngüsü
  // ---------------------------------------------------------------------------

  /// Bağlantı döngüsünü başlatır (önceki bağlantı durdurulur). Döngü arka planda sürer;
  /// ilk deneme sonucu için [linkStates]'i izleyin.
  ///
  /// [installId]: kalıcı kurulum kimliği (istemci kimliği ön eki). [fallbackTopicId]: kimlik
  /// yanıtı `topic_id` vermezse kullanılacak ev konu kimliği.
  Future<void> start({
    required MqttCredentialsProvider credentialsProvider,
    String? installId,
    String? fallbackTopicId,
  }) async {
    if (_disposed) return;
    await stop();
    if (kIsWeb) {
      // Tarayıcıda ham TCP/TLS soketi yoktur (MqttServerClient dart:io kullanır; SecurityContext web'de
      // UnsupportedError atar): canlı kanal kurulamaz. Döngü hiç başlatılmaz (her denemede sunucudan boşuna
      // MQTT kimliği üretilmez); bağlantı "kesik" kalır ve uygulama REST ile çalışmayı sürdürür.
      _lastFailure = MqttFailure.unreachable;
      return;
    }
    final generation = ++_generation;
    _everConnected = false;
    _setLink(MqttLinkState.connecting);
    final sessionSuffix = _randomHex(6);
    unawaited(_run(generation, credentialsProvider, installId, fallbackTopicId, sessionSuffix));
  }

  /// Bağlantıyı ve zamanlayıcıları durdurur; [linkState] `disconnected` olur.
  Future<void> stop() async {
    _generation++;
    _cancelRenewTimer();
    final ended = _sessionEnded;
    if (ended != null && !ended.isCompleted) ended.complete();
    _closeTransport();
    _topicId = null;
    _setLink(MqttLinkState.disconnected);
  }

  /// Eski ad: [stop].
  Future<void> disconnect() => stop();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelRenewTimer();
    final ended = _sessionEnded;
    if (ended != null && !ended.isCompleted) ended.complete();
    _closeTransport();
    _linkController.close();
    _stateController.close();
    _statusController.close();
  }

  void _setLink(MqttLinkState value) {
    if (_link == value) return;
    _link = value;
    if (!_linkController.isClosed) _linkController.add(value);
  }

  bool _isActive(int generation) => !_disposed && generation == _generation;

  void _cancelRenewTimer() {
    _renewTimer?.cancel();
    _renewTimer = null;
  }

  void _closeTransport() {
    for (final sub in _transportSubs) {
      sub.cancel();
    }
    _transportSubs.clear();
    final transport = _transport;
    _transport = null;
    transport?.close();
  }

  String _randomHex(int bytes) {
    final out = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      out.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  Duration _backoff(int attempt) {
    final exp = min(attempt, 6); // 2,4,8,16,32,60...
    final base = Duration(seconds: min(2 << exp, _maxBackoff.inSeconds));
    final jitter = 0.8 + _random.nextDouble() * 0.4; // ±%20
    return Duration(milliseconds: (base.inMilliseconds * jitter).round());
  }

  Future<void> _sleep(Duration duration, int generation) {
    final completer = Completer<void>();
    final timer = _clock.timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    // stop()/dispose() uykuyu bölsün diye oturum tamamlayıcısına bağlanır.
    _sessionEnded = completer;
    return completer.future.whenComplete(() {
      timer.cancel();
      if (identical(_sessionEnded, completer)) _sessionEnded = null;
    });
  }

  /// [transport] bağlanmasını en çok `_connectTimeout + _connectGrace` (15 sn) bekler (PF-27).
  ///
  /// Neden: `mqtt_client`'ın `connectTimeoutPeriod`'u yalnızca CONNACK beklemesidir; soket/TLS kurulumu
  /// (`SecureSocket.connect`) süre sınırsızdır ve sessizce paket düşüren ağda işletim sistemi zaman aşımına
  /// kadar döngüyü bloklardı (Windows VM'de yönlendirilemeyen adreste ölçülen: 21 sn, `connectTimeoutPeriod`
  /// 10 sn olduğu hâlde; Android için tahmin 75-130 sn, ÖLÇÜLMEDİ). İstemcinin `socketTimeout`'u ATANMAZ
  /// (atanınca CONNACK beklemesi 10 ms olur) ve `Future.timeout` soketi iptal etmez: sınır burada Clock ile
  /// uygulanır. Süre dolunca [MqttFailure.timeout]; geç dönen sonuç/hata yutulur. Başarısızlıkta çağıran
  /// aktarımı kapatır; kapatılmış aktarımın geç tamamlanan bağlantısı için bkz. `MqttClientTransport.connect`.
  Future<MqttConnectOutcome> _connectBounded(
    MqttTransport transport,
    MqttCredentials credentials,
    String clientId,
  ) async {
    try {
      return await _clock.bound<MqttConnectOutcome>(
        transport.connect(
          credentials: credentials,
          clientId: clientId,
          secure: _useTls,
          timeout: _connectTimeout,
        ),
        _connectTimeout + _connectGrace,
        () => const MqttConnectOutcome.failed(MqttFailure.timeout),
      );
    } catch (_) {
      // Aktarım istisna fırlatırsa döngü sessizce ölmesin (bağlantı sonsuza dek "bağlanıyor" kalırdı).
      return const MqttConnectOutcome.failed(MqttFailure.other);
    }
  }

  /// `true`: bu hata türüyle yeniden denemek anlamsız (yetki kalıcı olarak yok).
  bool _isPermanent(Object error) {
    if (error is ApiException) {
      return error.statusCode == 401 || error.statusCode == 403 || error.statusCode == 404;
    }
    return false;
  }

  Future<void> _run(
    int generation,
    MqttCredentialsProvider provider,
    String? installId,
    String? fallbackTopicId,
    String sessionSuffix,
  ) async {
    var attempt = 0;
    // Kimlik reddinden sonra BEKLEMESİZ tek taze-kimlik hakkı (UYELIK-02): başarılı bağlantıda yeniden kazanılır.
    var rejectRetryUsed = false;
    while (_isActive(generation)) {
      if (_everConnected || attempt > 0) _setLink(MqttLinkState.reconnecting);

      MqttCredentials credentials;
      try {
        credentials = await provider();
      } catch (e) {
        if (!_isActive(generation)) return;
        if (_isPermanent(e)) {
          _lastFailure = MqttFailure.authRejected;
          _setLink(MqttLinkState.disconnected);
          return;
        }
        _lastFailure = MqttFailure.unreachable;
        _setLink(MqttLinkState.reconnecting);
        await _sleep(_backoff(attempt++), generation);
        continue;
      }
      if (!_isActive(generation)) return;

      final topic = credentials.topicId.isNotEmpty ? credentials.topicId : (fallbackTopicId ?? '');
      if (topic.isEmpty) {
        _lastFailure = MqttFailure.other;
        _setLink(MqttLinkState.reconnecting);
        await _sleep(_backoff(attempt++), generation);
        continue;
      }

      final clientId = credentials.clientId ??
          'app_${_installPrefix(installId)}_$sessionSuffix';
      final transport = _transportFactory();
      _transport = transport;
      final outcome = await _connectBounded(transport, credentials, clientId);
      if (!_isActive(generation)) {
        transport.close();
        if (identical(_transport, transport)) _transport = null;
        return;
      }
      if (!outcome.ok) {
        _lastFailure = outcome.failure;
        _closeTransport();
        _setLink(MqttLinkState.reconnecting);
        // Kimlik reddi (CONNACK bad username/password / not authorized): bu kimlik ATILIR, sonraki tur her zaman
        // sunucudan taze kimlik ister (süresi dolmuş ya da sunucuda silinmiş olabilir: oturum iptali / parola
        // değişimi tüm uygulama kimliklerini siler). İlk retten sonra BEKLEMEDEN bir kez taze kimlik alınır; REST
        // 401 verirse oturum-sonu akışı (API istemcisi) işler ve döngü durur ([_isPermanent]). Taze kimlik de
        // reddedilirse olağan üstel geri çekilme sürer (sıkı döngü yok).
        if (outcome.failure == MqttFailure.authRejected && !rejectRetryUsed) {
          rejectRetryUsed = true;
          continue;
        }
        await _sleep(_backoff(attempt++), generation);
        continue;
      }

      // Bağlandı. Geri çekilme sayacı BURADA sıfırlanmaz (PF-28): bağlanıp hemen düşen bağlantı ~0,5 Hz
      // döngüye (ve her turda kimlik isteğine) yol açardı. Sayaç, kararlı bağlantının kopmasında sıfırlanır.
      final connectedAt = _clock.now();
      _everConnected = true;
      rejectRetryUsed = false;
      _lastFailure = MqttFailure.none;
      _topicId = topic;
      final ended = Completer<void>();
      _sessionEnded = ended;
      var renewal = false;
      _transportSubs
        ..add(transport.messageBatches.listen(ingestBatch))
        ..add(transport.disconnected.listen((_) {
          if (!ended.isCompleted) ended.complete();
        }))
        ..add(transport.subscribeFailures.listen((_) {
          _lastFailure = MqttFailure.authRejected;
        }));
      transport
        ..subscribe('ev/$topic/state')
        ..subscribe('ev/$topic/status');
      _setLink(MqttLinkState.connected);

      // Kimlik süresi dolmadan yenile: bağlantı kapatılıp taze kimlikle yeniden kurulur.
      _scheduleRenewal(credentials, ended, () => renewal = true);

      await ended.future;
      _cancelRenewTimer();
      if (identical(_sessionEnded, ended)) _sessionEnded = null;
      _closeTransport();
      if (!_isActive(generation)) return;
      _setLink(MqttLinkState.reconnecting);
      if (renewal) {
        // Planlı yenileme: bekleme yok, hemen taze kimlikle yeniden bağlan; geri çekilme sıfırlanır.
        attempt = 0;
      } else {
        // Beklenmeyen kopma. En az [_stableConnection] yaşayan bağlantı sorunsuz sayılır: sayaç sıfırlanır,
        // bekleme baştan (~2 sn) başlar. Ömrü kısa bağlantı üstel geri çekilmeyi (2,4,8,...60 sn) sürdürür.
        if (_clock.now().difference(connectedAt) >= _stableConnection) attempt = 0;
        await _sleep(_backoff(attempt++), generation);
      }
    }
  }

  String _installPrefix(String? installId) {
    final cleaned = (installId ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.length >= 8) return cleaned.substring(0, 8).toLowerCase();
    return _randomHex(4);
  }

  void _scheduleRenewal(MqttCredentials credentials, Completer<void> ended, void Function() onDue) {
    _cancelRenewTimer();
    final remaining = credentials.expiresAt.difference(_clock.now());
    // Süre dolmadan en geç 5 dk önce (kalan sürenin yarısından fazla değil) yenile.
    final lead = remaining.inSeconds > 600 ? const Duration(minutes: 5) : remaining ~/ 2;
    var delay = remaining - lead;
    if (delay < const Duration(seconds: 15)) delay = const Duration(seconds: 15);
    _renewTimer = _clock.timer(delay, () {
      onDue();
      if (!ended.isCompleted) ended.complete();
    });
  }

  // ---------------------------------------------------------------------------
  // İleti işleme
  // ---------------------------------------------------------------------------

  /// Bir abonelik grubundaki **tüm** iletileri işler. Hiçbir ileti akışı bozmaz: geçersiz yük
  /// atılır ve [droppedMessageCount] artar.
  @visibleForTesting
  void ingestBatch(List<MqttInboundMessage> batch) {
    for (final message in batch) {
      try {
        _ingest(message);
      } catch (_) {
        _dropped++;
      }
    }
  }

  void _ingest(MqttInboundMessage message) {
    final expected = _topicId;
    if (expected == null || message.payload.length > _maxPayloadChars) {
      _dropped++;
      return;
    }
    final parts = message.topic.split('/');
    if (parts.length != 3 || parts[0] != 'ev' || parts[1] != expected) {
      _dropped++; // başka eve / beklenmeyen konuya ait ileti
      return;
    }
    final now = _clock.now();
    switch (parts[2]) {
      case 'state':
        final decoded = jsonDecode(message.payload);
        final map = asMap(decoded);
        if (map == null) {
          _dropped++;
          return;
        }
        if (!_stateController.isClosed) {
          _stateController.add(
            DeviceStateMessage(
              topicId: expected,
              status: DeviceStatus.fromJson(map, filterPhantomShutters: false),
              retained: message.retained,
              receivedAt: now,
            ),
          );
        }
      case 'status':
        final online = _parsePresence(message.payload);
        if (online == null) {
          _dropped++;
          return;
        }
        if (!_statusController.isClosed) {
          _statusController.add(
            DevicePresenceMessage(
              topicId: expected,
              online: online,
              retained: message.retained,
              receivedAt: now,
            ),
          );
        }
      default:
        _dropped++;
    }
  }

  /// `online` / `offline` düz metni veya `{"status":"online"}` JSON'u.
  static bool? _parsePresence(String payload) {
    var text = payload.trim();
    if (text.startsWith('{')) {
      final map = asMap(jsonDecode(text));
      text = asString(map?['status'] ?? map?['state']) ?? '';
    }
    switch (text.trim().toLowerCase()) {
      case 'online':
        return true;
      case 'offline':
        return false;
    }
    return null;
  }
}
