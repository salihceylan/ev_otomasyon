import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class EvMqttService {
  final String brokerHost;
  final int brokerPort;
  MqttServerClient? _client;
  bool _isConnected = false;

  final _stateController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get stateStream => _stateController.stream;
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;
  bool get isConnected => _isConnected;

  EvMqttService({
    this.brokerHost = 'evotomasyon.gudeteknoloji.com.tr',
    this.brokerPort = 8884,
  });

  Future<bool> connect({
    required String username,
    required String password,
    required String homeId,
  }) async {
    try {
      final clientIdentifier = 'flutter_app_${DateTime.now().millisecondsSinceEpoch % 100000}';
      _client = MqttServerClient.withPort(brokerHost, clientIdentifier, brokerPort);

      _client!.secure = true;
      if (!kIsWeb) {
        _client!.securityContext = SecurityContext.defaultContext;
      } else {
        _client!.useWebSocket = true;
      }
      _client!.keepAlivePeriod = 20;
      _client!.autoReconnect = true;
      _client!.logging(on: false);

      _client!.onConnected = () {
        _isConnected = true;
        debugPrint('[MQTTS] EMQX Broker bağlantısı başarılı (TLS 1.3 / Port 8884)');
      };

      _client!.onDisconnected = () {
        _isConnected = false;
        debugPrint('[MQTTS] EMQX Broker bağlantısı koptu');
      };

      _client!.onAutoReconnect = () {
        debugPrint('[MQTTS] Otomatik yeniden bağlanılıyor...');
      };

      final connMsg = MqttConnectMessage()
          .withClientIdentifier(clientIdentifier)
          .authenticateAs(username, password)
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);

      _client!.connectionMessage = connMsg;

      debugPrint('[MQTTS] Bağlanılıyor: $brokerHost:$brokerPort (Kullanıcı: $username)...');
      final status = await _client!.connect();
      if (status?.state == MqttConnectionState.connected) {
        _isConnected = true;
        _listenMessages();
        subscribeToHome(homeId);
        return true;
      } else {
        debugPrint('[MQTTS] Bağlantı reddedildi: ${status?.returnCode}');
        _client!.disconnect();
        return false;
      }
    } catch (e) {
      debugPrint('[MQTTS] Bağlantı istisnası: $e');
      _client?.disconnect();
      return false;
    }
  }

  void subscribeToHome(String homeId) {
    if (_client == null || !_isConnected) return;

    final stateTopic = 'ev/$homeId/state';
    final statusTopic = 'ev/$homeId/status';

    debugPrint('[MQTTS] Konulara abone olunuyor: $stateTopic & $statusTopic');
    _client!.subscribe(stateTopic, MqttQos.atLeastOnce);
    _client!.subscribe(statusTopic, MqttQos.atLeastOnce);
  }

  void _listenMessages() {
    _client?.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final recMess = c[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      final topic = c[0].topic;

      try {
        if (topic.endsWith('/status')) {
          final trimmed = payload.trim();
          if (trimmed.startsWith('{')) {
            final decoded = jsonDecode(trimmed) as Map<String, dynamic>;
            _statusController.add(decoded);
          } else {
            _statusController.add({'status': trimmed});
          }
        } else if (topic.endsWith('/state')) {
          final decoded = jsonDecode(payload) as Map<String, dynamic>;
          _stateController.add(decoded);
        }
      } catch (e) {
        debugPrint('[MQTTS] Mesaj ayrıştırma hatası ($topic): $e');
      }
    });
  }

  /// Röle Kontrol Komutu Yayınla
  bool sendRelayCommand(String homeId, int relayIndex, bool state) {
    return publishCommand(homeId, {
      'relay': relayIndex,
      'state': state,
    });
  }

  /// Panjur Kontrol Komutu Yayınla
  bool sendShutterCommand(String homeId, int pairIndex, String action, {int? percent}) {
    final payload = <String, dynamic>{
      'shutter': pairIndex,
      'action': action, // 'up', 'down', 'stop', 'pos'
    };
    if (percent != null) {
      payload['percent'] = percent;
    }
    return publishCommand(homeId, payload);
  }

  /// Toplu Senaryo Komutu Yayınla
  bool sendScenarioCommand(String homeId, String scenario) {
    return publishCommand(homeId, {
      'scenario': scenario, // 'leave_home', 'welcome', 'all_lights_off', 'all_shutters_close'
    });
  }

  /// Genel Komut Yayınlama Metodu (ev/{home_id}/cmd)
  bool publishCommand(String homeId, Map<String, dynamic> data) {
    if (_client == null || !_isConnected) {
      debugPrint('[MQTTS] Komut gönderilemedi: Broker bağlı değil');
      return false;
    }

    final topic = 'ev/$homeId/cmd';
    final builder = MqttClientPayloadBuilder();
    final jsonStr = jsonEncode(data);
    builder.addString(jsonStr);

    try {
      _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      debugPrint('[MQTTS] Komut gönderildi ($topic): $jsonStr');
      return true;
    } catch (e) {
      debugPrint('[MQTTS] Yayınlama hatası: $e');
      return false;
    }
  }

  void disconnect() {
    _client?.disconnect();
    _isConnected = false;
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _statusController.close();
  }
}

