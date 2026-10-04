import 'dart:async';
import 'dart:math';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// UYELIK-02 (D20), istemci savunması. Sunucu (S2) logout-all / parola değişimi / parola sıfırlamada kullanıcının
/// TÜM uygulama MQTT kimliklerini (bu cihazınki dahil) siler ve bağlantıları atar.
///
/// * Bağlantı kimlik reddiyle (CONNACK bad username/password / not authorized) düşünce bayat kimlik ATILIR ve
///   beklemeden BİR kez sunucudan (REST) taze kimlik alınır; taze kimlik de reddedilirse olağan geri çekilme.
/// * REST 401 verirse mevcut oturum-sonu akışı işler (refresh reddi -> oturum olayı) ve MQTT döngüsü durur.
/// * Parola değişiminden sonra bu cihaz YENİ kimlikle yeniden bağlanır; atılan bağlantı, değişim yanıtı (yeni
///   belirteçler) gelmeden ESKİ belirteçle kimlik istemez (eski belirteç 401 -> iptal edilmiş refresh -> yanlışlıkla
///   oturum sonu yarışı).
void main() {
  late FakeClock clock;

  setUp(() {
    clock = FakeClock();
  });

  MqttCredentials creds(String user) => MqttCredentials(
        host: 'broker.test',
        port: 8884,
        username: user,
        password: 'gecici-parola',
        expiresAt: clock.now().add(const Duration(hours: 12)),
        topicId: 'h_test',
      );

  group('EvMqttService: sahte aracı (broker) + sahte kimlik sağlayıcı', () {
    test('CONNACK kimlik reddi: bayat kimlik atılır, BEKLEMEDEN bir kez taze kimlik alınır ve bağlanılır', () async {
      final broker = _FakeBroker(clock)..valid.add('a_h_test_2'); // ilk kimlik sunucuda silinmiş (bayat)
      final svc = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      addTearDown(svc.dispose);
      var issued = 0;

      await svc.start(credentialsProvider: () async => creds('a_h_test_${++issued}'));
      await clock.elapse(const Duration(milliseconds: 300));

      expect(broker.attempts, <String>['a_h_test_1', 'a_h_test_2'], reason: 'ret sonrası geri çekilme beklenmeden taze kimlik');
      expect(issued, 2);
      expect(svc.linkState, MqttLinkState.connected);
      expect(broker.transports.first.closed, isTrue, reason: 'reddedilen bağlantı bırakıldı');
      expect(broker.transports.last.credentials!.username, 'a_h_test_2');
    });

    test('taze kimlik de reddedilirse sıkı döngü YOK: tek beklemesiz deneme, sonra olağan üstel geri çekilme', () async {
      final broker = _FakeBroker(clock); // hiçbir kimlik kabul edilmiyor (ör. aracı kimlik arka ucu bozuk)
      final svc = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      addTearDown(svc.dispose);
      var issued = 0;

      await svc.start(credentialsProvider: () async => creds('a_h_test_${++issued}'));
      await clock.elapse(const Duration(milliseconds: 500));
      expect(broker.attempts, hasLength(2), reason: 'ilk ret: bir kez beklemesiz taze kimlik');
      expect(svc.lastFailure, MqttFailure.authRejected);
      expect(svc.linkState, MqttLinkState.reconnecting);

      await clock.elapse(const Duration(seconds: 10));
      expect(broker.attempts.length, lessThanOrEqualTo(4), reason: 'sonraki retler geri çekilmeyle (~2 sn, ~4 sn)');
      final gap = broker.attemptTimes[2].difference(broker.attemptTimes[1]);
      expect(gap, greaterThanOrEqualTo(const Duration(milliseconds: 1500)), reason: 'ikinci retten sonra bekleme var');
    });

    test('başarılı bağlantıdan sonraki yeni ret yine beklemeden bir taze kimlik hakkı verir', () async {
      final broker = _FakeBroker(clock);
      final svc = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      addTearDown(svc.dispose);
      var issued = 0;
      await svc.start(credentialsProvider: () async {
        final user = 'a_h_test_${++issued}';
        // 1. ve 3. kimlik aracıda geçersiz (ör. sunucuda silinmiş): her ret serisinde ilk deneme reddedilir.
        if (issued.isEven) broker.valid.add(user);
        return creds(user);
      });
      await clock.elapse(const Duration(milliseconds: 300));
      expect(broker.attempts, <String>['a_h_test_1', 'a_h_test_2']);
      expect(svc.linkState, MqttLinkState.connected);

      broker.revokeAllAndKick(); // kimlikler silindi + bağlantı atıldı
      await clock.elapse(const Duration(seconds: 3)); // kopma sonrası olağan kısa bekleme (~2 sn) -> 3. kimlik REDDEDİLİR
      await clock.elapse(const Duration(milliseconds: 300)); // beklemeden 4. kimlik
      expect(broker.attempts, <String>['a_h_test_1', 'a_h_test_2', 'a_h_test_3', 'a_h_test_4']);
      expect(svc.linkState, MqttLinkState.connected);
    });

    test('parola değişimi: sunucu tüm kimlikleri silip bağlantıyı atınca bu cihaz YENİ kimlikle yeniden bağlanır', () async {
      final broker = _FakeBroker(clock);
      final svc = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      addTearDown(svc.dispose);
      var issued = 0;
      // Sağlayıcı sunucuyu taklit eder: her çağrı aracıda geçerli YENİ bir kimlik üretir.
      await svc.start(credentialsProvider: () async {
        final user = 'a_h_test_${++issued}';
        broker.valid.add(user);
        return creds(user);
      });
      await clock.elapse(const Duration(milliseconds: 200));
      expect(svc.linkState, MqttLinkState.connected);

      broker.revokeAllAndKick();
      await clock.elapse(const Duration(seconds: 5));

      expect(svc.linkState, MqttLinkState.connected);
      expect(broker.transports.last.credentials!.username, 'a_h_test_2', reason: 'eski kimlik yeniden kullanılmadı');
      expect(broker.attempts.skip(1), everyElement(isNot('a_h_test_1')), reason: 'silinen kimlikle yeniden deneme yok');
    });
  });

  group('REST 401: mevcut oturum-sonu akışı (gerçek API istemcisi + sahte HTTP)', () {
    test('kimlik isteği 401 INVALID_TOKEN + refresh reddi -> oturum olayı; MQTT döngüsü KALICI durur', () async {
      final api = MockApi();
      final cloud = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock);
      addTearDown(cloud.dispose);
      final expired = <SessionEndReason>[];
      cloud.onSessionExpired = expired.add;
      cloud
        ..setAuthToken('access-old')
        ..setRefreshToken('refresh-old');
      var revoked = false;
      var issued = 0;
      final broker = _FakeBroker(clock);
      api.on('POST', RegExp(r'^/api/v1/homes/[^/]+/mqtt-credentials$'), (r) {
        if (revoked) return errorResponse(401, 'Oturum geçersiz.', code: 'INVALID_TOKEN');
        final user = 'a_h_test_${++issued}';
        broker.valid.add(user);
        return okResponse(<String, dynamic>{
          'host': 'broker.test',
          'port': 8884,
          'username': user,
          'password': 'gecici-parola',
          'expires_at': clock.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
          'topic_id': 'h_test',
        });
      });
      api.on('POST', '/api/v1/auth/refresh', (r) => errorResponse(401, 'Oturum sonlandırıldı.', code: 'INVALID_REFRESH_TOKEN'));

      final svc = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      addTearDown(svc.dispose);
      await svc.start(credentialsProvider: () => cloud.mqttCredentials(kHomeA));
      await clock.elapse(const Duration(milliseconds: 200));
      expect(svc.linkState, MqttLinkState.connected);

      // Başka cihazdan "Tüm Cihazlardan Çıkış": oturum iptali + kimlik silme + bağlantı atma.
      revoked = true;
      broker.revokeAllAndKick();
      await clock.elapse(const Duration(seconds: 5));

      expect(expired, <SessionEndReason>[SessionEndReason.invalidToken], reason: 'tek oturum olayı (oturum-sonu akışı)');
      expect(cloud.authToken, isNull);
      expect(svc.linkState, MqttLinkState.disconnected);
      expect(svc.lastFailure, MqttFailure.authRejected);
      final requests = api.count('POST', RegExp(r'/mqtt-credentials$'));
      await clock.elapse(const Duration(minutes: 5));
      expect(api.count('POST', RegExp(r'/mqtt-credentials$')), requests, reason: 'kalıcı yetki hatasında döngü durur');
      expect(broker.attempts, <String>['a_h_test_1'], reason: 'atılan cihaz yeniden bağlanamadı');
    });
  });

  group('AutomationState: parola değişimi sırasında atılan bağlantı', () {
    test('yanıt gelmeden ESKİ belirteçle kimlik İSTENMEZ; yanıt gelince yeni kimlikle bağlanır ve oturum sürer', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final broker = _FakeBroker(clock);
      final mqtt = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      final cloud = _RotationCloud(clock, broker)
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      final state = AutomationState(
        cloudApi: cloud,
        mqttService: mqtt,
        secureStorage: FakeStorage(),
        biometricService: FakeBiometric(),
        directApi: AutomationApiService(baseUrl: ''),
        clock: clock,
        autoInit: false,
        observeAppLifecycle: false,
      );
      addTearDown(state.dispose);
      cloud.beginSession(accessToken: 'access-old', refreshToken: 'refresh-old');
      state
        ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await state.fetchHomes();
      await clock.elapse(const Duration(milliseconds: 200));
      expect(mqtt.linkState, MqttLinkState.connected, reason: 'hazırlık: canlı kanal');
      expect(broker.attempts, <String>['a_h_test_1']);

      // Sunucu değişimi işler, kimlikleri silip bağlantıyı atar; yanıt (yeni belirteçler) gecikir.
      cloud.changeGate = Completer<void>();
      cloud.onServerRotated = broker.revokeAllAndKick;
      final change = state.changePassword(currentPassword: 'eski-parola-123', newPassword: 'yeni-parola-456');
      await clock.elapse(const Duration(seconds: 10));

      expect(cloud.credentialTokens, <String?>['access-old'], reason: 'atılan bağlantı eski belirteçle kimlik istemedi');
      expect(mqtt.linkState, isNot(MqttLinkState.disconnected), reason: 'döngü durmadı; yanıt bekleniyor');

      cloud.changeGate!.complete();
      await change;
      await clock.elapse(const Duration(seconds: 5));

      expect(cloud.credentialTokens.last, cloud.authToken, reason: 'taze kimlik YENİ belirteçle istendi');
      expect(cloud.authToken, isNot('access-old'));
      expect(mqtt.linkState, MqttLinkState.connected, reason: 'bu cihaz yeni kimlikle yeniden bağlandı');
      expect(broker.attempts.last, 'a_h_test_2');
      expect(state.isAuthenticated, isTrue, reason: 'parolayı değiştiren cihazın oturumu sürer');
    });
  });

  // M2-F1: UYELIK-02 beklemesinin öteki iki çağrı yeri (logoutAll, resetPassword). Bekleme kaldırılırsa atılan bağlantı
  // yanıt gelmeden ESKİ (iptal edilmiş) belirteçle kimlik ister ve bu testler düşer.
  group('AutomationState: tüm cihazlardan çıkış / parola sıfırlama sırasında atılan bağlantı', () {
    Future<({AutomationState state, _RotationCloud cloud, EvMqttService mqtt, _FakeBroker broker})> connected() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final broker = _FakeBroker(clock);
      final mqtt = EvMqttService(clock: clock, random: Random(3), useTls: true, transportFactory: broker.transport);
      final cloud = _RotationCloud(clock, broker)
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      final state = AutomationState(
        cloudApi: cloud,
        mqttService: mqtt,
        secureStorage: FakeStorage(),
        biometricService: FakeBiometric(),
        directApi: AutomationApiService(baseUrl: ''),
        clock: clock,
        autoInit: false,
        observeAppLifecycle: false,
      );
      addTearDown(state.dispose);
      cloud.beginSession(accessToken: 'access-old', refreshToken: 'refresh-old');
      state
        ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await state.fetchHomes();
      await clock.elapse(const Duration(milliseconds: 200));
      expect(mqtt.linkState, MqttLinkState.connected, reason: 'hazırlık: canlı kanal');
      cloud.changeGate = Completer<void>();
      cloud.onServerRotated = broker.revokeAllAndKick;
      return (state: state, cloud: cloud, mqtt: mqtt, broker: broker);
    }

    test('logoutAll: yanıt gelmeden ESKİ belirteçle kimlik İSTENMEZ; yanıt gelince çıkış yapılır', () async {
      final r = await connected();
      final done = r.state.logoutAll();
      await clock.elapse(const Duration(seconds: 10));

      expect(r.cloud.credentialTokens, <String?>['access-old'], reason: 'atılan bağlantı eski belirteçle kimlik istemedi');

      r.cloud.changeGate!.complete();
      await done;
      await clock.elapse(const Duration(seconds: 5));

      expect(r.cloud.credentialTokens.where((t) => t == 'access-old'), hasLength(1),
          reason: 'iptal edilmiş belirteçle ikinci kimlik isteği yok');
      expect(r.state.isAuthenticated, isFalse, reason: 'tüm cihazlardan çıkış bu cihazdan da çıkar');
    });

    test('resetPassword: yanıt gelmeden ESKİ belirteçle kimlik İSTENMEZ; yanıt gelince yeni kimlikle bağlanır', () async {
      final r = await connected();
      final done = r.state.resetPassword(identifier: 'a@b.c', code: '123456', newPassword: 'yeni-parola-456');
      await clock.elapse(const Duration(seconds: 10));

      expect(r.cloud.credentialTokens, <String?>['access-old'], reason: 'atılan bağlantı eski belirteçle kimlik istemedi');

      r.cloud.changeGate!.complete();
      expect(await done, isTrue, reason: 'yanıt oturum taşıdı');
      await clock.elapse(const Duration(seconds: 5));

      expect(r.cloud.credentialTokens.last, r.cloud.authToken, reason: 'taze kimlik YENİ belirteçle istendi');
      expect(r.cloud.authToken, isNot('access-old'));
      expect(r.mqtt.linkState, MqttLinkState.connected);
      expect(r.state.isAuthenticated, isTrue);
    });
  });
}

/// Sahte MQTT aracısı: yalnız [valid] kümesindeki kullanıcı adları bağlanır (diğerleri CONNACK "bad username or
/// password"); [revokeAllAndKick] sunucunun "tüm uygulama kimliklerini sil + bağlantıları at" işlemidir.
class _FakeBroker {
  _FakeBroker(this.clock);

  final FakeClock clock;
  final Set<String> valid = <String>{};
  final List<String> attempts = <String>[];

  /// Bağlanma denemelerinin (sahte saatle) zamanları.
  final List<DateTime> attemptTimes = <DateTime>[];
  final List<_BrokerTransport> transports = <_BrokerTransport>[];

  MqttTransport transport() {
    final t = _BrokerTransport(this);
    transports.add(t);
    return t;
  }

  void revokeAllAndKick() {
    valid.clear();
    for (final t in List<_BrokerTransport>.of(transports)) {
      if (!t.closed && t.connected) t.drop();
    }
  }
}

class _BrokerTransport extends FakeMqttTransport {
  _BrokerTransport(this.broker);

  final _FakeBroker broker;
  bool connected = false;

  @override
  Future<MqttConnectOutcome> connect({
    required MqttCredentials credentials,
    required String clientId,
    required bool secure,
    required Duration timeout,
  }) async {
    broker.attempts.add(credentials.username);
    broker.attemptTimes.add(broker.clock.now());
    outcome = broker.valid.contains(credentials.username)
        ? const MqttConnectOutcome.ok()
        : const MqttConnectOutcome.failed(MqttFailure.authRejected);
    final result = await super.connect(credentials: credentials, clientId: clientId, secure: secure, timeout: timeout);
    connected = result.ok;
    return result;
  }
}

/// Sunucuyu taklit eden sahte bulut: parola değişimi eski erişim belirtecini geçersiz kılar (token_version++),
/// tüm uygulama MQTT kimliklerini silip bağlantıları atar ([onServerRotated]); yanıt [changeGate] açılınca gelir.
class _RotationCloud extends FakeCloudApi {
  _RotationCloud(this._clockRef, this.broker) : super(clock: _clockRef);

  final FakeClock _clockRef;
  final _FakeBroker broker;
  Completer<void>? changeGate;
  void Function()? onServerRotated;
  final Set<String> revokedAccess = <String>{};

  /// Her kimlik isteğindeki erişim belirteci (sır değildir: sahte test değerleri).
  final List<String?> credentialTokens = <String?>[];
  int issued = 0;

  @override
  Future<Map<String, dynamic>> changePassword({required String currentPassword, required String newPassword}) async {
    revokedAccess.add(authToken ?? '');
    onServerRotated?.call();
    final gate = changeGate;
    if (gate != null) await gate.future;
    return super.changePassword(currentPassword: currentPassword, newPassword: newPassword);
  }

  /// Tüm cihazlardan çıkış: sunucu kimlikleri silip bağlantıları atar; yanıt [changeGate] ile geciktirilir.
  @override
  Future<void> logoutAll() async {
    revokedAccess.add(authToken ?? '');
    onServerRotated?.call();
    final gate = changeGate;
    if (gate != null) await gate.future;
    return super.logoutAll();
  }

  /// Parola sıfırlama (açık oturumun hesabı): aynı kimlik döndürme; yanıt yeni oturum taşır.
  @override
  Future<Map<String, dynamic>> resetPassword({
    String? identifier,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    revokedAccess.add(authToken ?? '');
    onServerRotated?.call();
    final gate = changeGate;
    if (gate != null) await gate.future;
    // Yeni oturum yanıtı (sahte): değişimdeki ile aynı biçim.
    return super.changePassword(currentPassword: 'kullanilmaz', newPassword: newPassword);
  }

  @override
  Future<MqttCredentials> mqttCredentials(String homeId) async {
    calls.add('mqttCredentials:$homeId');
    credentialTokens.add(authToken);
    if (revokedAccess.contains(authToken)) {
      // Gerçek istemci burada (iptal edilmiş) refresh ile yenilemeyi dener ve oturum yanlışlıkla sona ererdi.
      throw const ApiException(statusCode: 401, code: 'INVALID_TOKEN', message: 'Oturum geçersiz.');
    }
    final user = 'a_h_test_${++issued}';
    broker.valid.add(user);
    return MqttCredentials(
      host: 'broker.test',
      port: 8884,
      username: user,
      password: 'gecici-parola',
      expiresAt: _clockRef.now().add(const Duration(hours: 12)),
      topicId: 'h_test',
    );
  }
}
