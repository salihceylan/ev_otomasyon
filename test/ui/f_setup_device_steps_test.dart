import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/button_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/relay_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/shutter_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// 5-10. adımlar: Wi-Fi, bulut, röle, panjur, duvar butonları ve teslim - gerçek (sahte) pano ve sunucu
/// yanıtlarına bağlı geçiş koşulları, başarısızlık yolları ve yanlış cihaz/ev ve gizli değer denetimleri.

void main() {
  group('5. adım: Wi-Fi (kurulum ağı: internetsiz ve anahtarsız)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    /// [keyAtClaim]: claim sırasında cihaz anahtarı hazırlansın mı (sunucu hatası enjekte etmek için `false`).
    Future<void> setUpEnv({bool provisioned = true, bool keyAtClaim = true}) async {
      env = await serviceHarness(provisioned: provisioned);
      if (!provisioned) env.device.apSecured = false; // fabrika sonrası pano AÇIK kurulum ağı yayınlar
      if (!keyAtClaim) env.cloud.localKeyError = ApiException.network();
      c = await completeClaim(env);
      env.cloud.localKeyError = null;
      env.phoneOnSetupNetwork(); // telefon panonun kurulum ağına bağlandı: internet YOK
    }

    tearDown(() => env.dispose());

    test('internet ve cihaz anahtarı olmadan: kimlik doğrulanır, ev Wi-Fi bilgisi gönderilir, sunucuya hiç istek atılmaz', () async {
      await setUpEnv();
      final callsBefore = List<String>.of(env.cloud.calls);

      expect(c.canContinue, isFalse);
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.deviceReady, isTrue);
      expect(c.canContinue, isFalse, reason: '"gönderildi" bağlandı demek değildir');
      final result = await connectHomeWifi(env, c);
      expect(result.isSuccess, isTrue);
      expect(c.canContinue, isTrue);
      expect(c.target!.ip, kLanIp, reason: 'pano ev ağındaki IP (wifi_sta_ip) hedefe yazıldı');

      expect(env.cloud.calls, callsBefore, reason: 'kurulum ağında internet yok: hiçbir sunucu çağrısı yapılmamalı');
      expect(env.device.keylessWifiCalls, greaterThan(0), reason: 'Wi-Fi uçları AP\'den anahtarsız kullanıldı');
      expect(env.device.keyHeaderHosts, isEmpty, reason: 'kurulum ağında cihaz anahtarı başlığı HİÇ gönderilmez');
    });

    test('kurulum ağında internet yokken sunucuya gitmek gerekse bile adım ağ hatasıyla düşmez (anahtar zaten istenmez)', () async {
      await setUpEnv(keyAtClaim: false);
      expect(c.target!.localKey, isNull, reason: 'anahtar claim sırasında alınamadı');
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
      expect(c.wifi.connected, isTrue);
      expect(env.cloud.calls.where((x) => x.startsWith('localKey')).length, 1, reason: 'yalnızca claim sırasındaki (başarısız) deneme');
    });

    test('yanlış panoya bağlıysanız hiçbir gizli bilgi gönderilmez ve açıklama gelir', () async {
      await setUpEnv();
      final other = FakeDevice(uid: 'AHBU-S3-ZZZZZZ', localKey: 'baska-anahtar-1', clock: env.clock);
      addTearDown(other.dispose);
      final w = env.newController(
        existingTarget: c.target,
        startStep: SetupSteps.wifi,
        factory: (host) => AutomationApiService(baseUrl: '', client: other.api.client, clock: env.clock)..updateHost(host),
      );
      addTearDown(w.dispose);
      w.start();
      await waitUntil(env, () => w.currentStep == SetupSteps.wifi);

      expect(await drive(env, w.wifi.checkDevice()), isFalse);
      expect(w.wifi.problem!.kind, SetupProblemKind.wrongDevice);
      expect(w.wifi.problem!.why, contains('AHBU-S3-ZZZZZZ'));
      expect(w.wifi.deviceReady, isFalse, reason: 'doğrulanmayan pano için Wi-Fi bileşeni etkinleşmez');
      expect(other.keyHeaderHosts, isEmpty, reason: 'yanlış panoya cihaz anahtarı gönderilmemeli');
      expect(other.keylessWifiCalls, 0);
      expect(other.mqttConfigCount, 0);
      expect(w.canContinue, isFalse);
    });

    test('hazırlanmamış pano: kurulum ağı AÇIKTIR, ilk hazırlık anahtarı yazar, ağ parolalı yeniden başlar, sonra doğrulama geçer', () async {
      await setUpEnv(provisioned: false);
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.needsProvision, isTrue);
      expect(c.wifi.deviceReady, isFalse, reason: 'hazırlanmamış panoya Wi-Fi bilgisi gönderilmez');

      expect(await c.wifi.provision(apPass: 'kisa'), isFalse, reason: 'parola 8-32 karakter olmalı');
      expect(c.wifi.problem!.title, 'Kurulum ağı parolası geçersiz');
      expect(await drive(env, c.wifi.provision(apPass: kApPass)), isTrue);
      expect(env.device.factoryInitCount, 1);
      expect(env.device.provisioned, isTrue);
      expect(c.wifi.awaitingReconnect, isTrue);

      env.device.apSecured = true; // kurulum ağı artık WPA2
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.deviceReady, isTrue);
      expect(c.wifi.awaitingReconnect, isFalse);
      expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
    });

    test('hazırlanmamış pano ve bellekte anahtar yok: internetsiz kurulum ağında anahtar alınamaz, açıklama gelir; internetle alınınca hazırlık yapılır',
        () async {
      await setUpEnv(provisioned: false, keyAtClaim: false);
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.hasProvisionKey, isFalse);

      expect(await drive(env, c.wifi.provision(apPass: kApPass)), isFalse);
      expect(c.wifi.problem!.title, 'Cihaz anahtarı yok');
      expect(env.device.factoryInitCount, 0);

      expect(await drive(env, c.wifi.fetchKeyForProvision()), isFalse, reason: 'internet yok');
      expect(c.wifi.problem!.kind, SetupProblemKind.network);
      expect(c.wifi.problem!.todo, contains('internet'));

      env.cloud.internetUp = true; // telefon geçici olarak internete alındı
      expect(await drive(env, c.wifi.fetchKeyForProvision()), isTrue);
      expect(c.wifi.hasProvisionKey, isTrue);
      expect(await dumpPrefs(), isNot(contains(kLocalKey)));
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)), reason: 'anahtar güvenli depoya YAZILMAZ');

      env.phoneOnSetupNetwork();
      expect(await drive(env, c.wifi.provision(apPass: kApPass)), isTrue);
      expect(env.device.factoryInitCount, 1);
    });

    test('geçersiz biçimli elle anahtar reddedilir; geçerli anahtar ilk hazırlıkta kullanılır', () async {
      await setUpEnv(provisioned: false, keyAtClaim: false);
      await drive(env, c.wifi.checkDevice());
      expect(c.wifi.useManualKey('kisa'), isFalse);
      expect(c.wifi.problem!.title, 'Cihaz anahtarı geçersiz');
      expect(c.wifi.useManualKey(kLocalKey), isTrue);
      expect(c.wifi.hasProvisionKey, isTrue);
      expect(await drive(env, c.wifi.provision(apPass: kApPass)), isTrue);
    });

    test('yanlış Wi-Fi şifresi: neden ve çözüm yazılır; doğru şifreyle tekrar denenince bağlanır', () async {
      await setUpEnv();
      await drive(env, c.wifi.checkDevice());
      final bad = await connectHomeWifi(env, c, pass: 'yanlis-sifre-99');
      expect(bad.outcome, WifiConnectOutcome.failed);
      final p = c.wifi.problem!;
      expect(p.kind, SetupProblemKind.deviceRejected);
      expect(p.todo, contains('şifresini kontrol edin'));
      expect(c.wifi.connected, isFalse);
      expect(c.canContinue, isFalse);
      expect(env.device.wifiConnected, isFalse);

      expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
      expect(c.wifi.connected, isTrue);
      expect(c.wifi.problem, isNull, reason: 'başarılı denemeden sonra eski hata kalkar');
    });

    test('ağ bulunamadı (5 GHz/uzak modem) hatası 2.4 GHz uyarısıyla açıklanır', () async {
      await setUpEnv();
      await drive(env, c.wifi.checkDevice());
      await connectHomeWifi(env, c, ssid: 'Olmayan Ag');
      expect(c.wifi.problem!.todo, contains('2.4 GHz'));
      expect(c.wifi.connected, isFalse);
    });

    test('ağ taraması anahtarsız yapılır ve sonuçları gerçek pano listesidir', () async {
      await setUpEnv();
      await drive(env, c.wifi.checkDevice());
      final networks = await drive(env, c.wifi.apApi.scanWifi(refresh: true));
      expect(networks.map((n) => n.ssid), contains(kHomeWifiSsid));
      expect(env.device.keyHeaderHosts, isEmpty);
    });

    test('kurulum ağı kapanırsa (bağlantı koptu) sonuç belirsiz sayılır; ev ağındaki IP ile (anahtarsız, internetsiz) doğrulanınca tamamlanır',
        () async {
      await setUpEnv();
      env.device.dropApOnConnect = true;
      await drive(env, c.wifi.checkDevice());
      final result = await connectHomeWifi(env, c);
      expect(result.outcome, WifiConnectOutcome.lostContact);
      expect(c.wifi.lostContact, isTrue);
      expect(c.wifi.connected, isFalse);
      expect(c.canContinue, isFalse, reason: 'bağlantı koptu: kanıt olmadan geçilmez');

      // Telefon ev Wi-Fi'sine geçti ama bu denemede internet YOK (sunucuya erişim gerekmez).
      env.device.apReachable = false;
      env.device.lanReachable = true;
      expect(await c.wifi.confirmLanIp('bu-bir-ip-degil'), isFalse);
      expect(c.wifi.problem!.title, 'Pano adresi geçersiz');
      expect(await drive(env, c.wifi.confirmLanIp(kLanIp)), isTrue);
      expect(c.wifi.connected, isTrue);
      expect(c.target!.ip, kLanIp);
      expect(env.device.keyHeaderHosts, isEmpty, reason: 'ev ağı doğrulaması da anahtarsızdır');
    });

    test('kayıttan devam: bağlantı kopmuş (belirsiz) durum ve ev ağı adresi korunur', () async {
      await setUpEnv();
      env.device.dropApOnConnect = true;
      await drive(env, c.wifi.checkDevice());
      await connectHomeWifi(env, c);
      expect(c.wifi.snapshot(), <String, dynamic>{'connected': false, 'lost': true});
      c.wifi.restore(<String, dynamic>{'connected': false, 'lost': true});
      expect(c.wifi.lostContact, isTrue);
    });

    test('ev ağındaki IP\'ye ulaşılamazsa açıklama gelir', () async {
      await setUpEnv();
      env.device.wifiConnected = true;
      env.device.staIp = kLanIp;
      env.device.lanReachable = false;
      expect(await drive(env, c.wifi.confirmLanIp(kLanIp)), isFalse);
      expect(c.wifi.problem!.kind, SetupProblemKind.deviceNetwork);
    });

    test('Wi-Fi şifresi, kurulum ağı parolası ve cihaz anahtarı hiçbir kayıtta/anlık görüntüde (kalıcı depo ve güvenli depo) saklanmaz', () async {
      await setUpEnv(provisioned: false);
      await drive(env, c.wifi.checkDevice());
      await drive(env, c.wifi.provision(apPass: kApPass));
      env.device.apSecured = true;
      await drive(env, c.wifi.checkDevice());
      await connectHomeWifi(env, c);
      expect(c.wifi.snapshot().keys, <String>['connected', 'lost']);
      final prefs = await dumpPrefs();
      final secure = env.dumpSecureStore();
      for (final secret in <String>[kHomeWifiPass, kApPass, kLocalKey]) {
        expect(prefs, isNot(contains(secret)));
        expect(secure, isNot(contains(secret)));
      }
    });
  });

  group('6. adım: bulut (telefon ev Wi-Fi\'sine döndü, internet geri geldi)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await completeClaim(env);
      await completeWifi(env, c); // 5. adım kurulum ağında yapıldı; telefon ev ağına döndü
    });
    tearDown(() => env.dispose());

    test('kimlik panoya yazılır, sunucuda çevrimiçi görülmeden devam açılmaz; kimlik bellekten bırakılır', () async {
      expect(c.canContinue, isFalse);
      expect(c.ctx.pendingCredential, isNotNull);
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.device.receivedMqttPass, kCredentialPassword);
      expect(env.device.receivedMqttPort, 8884);
      expect(c.ctx.pendingCredential, isNull, reason: 'yazıldıktan sonra bellekte tutulmaz');
      expect(c.canContinue, isTrue);
      expect(await dumpPrefs(), isNot(contains(kCredentialPassword)));
      expect(env.dumpSecureStore(), isNot(contains(kCredentialPassword)));
    });

    test('cihaz anahtarı bu adımda internetle sunucudan alınır, panoda doğrulanır ve hiçbir yere kaydedilmez', () async {
      // Claim sırasında anahtar alınamamıştı (örn. o an sunucu hatası): 6. adımda internet geri gelince alınır.
      c.ctx.target = c.ctx.target!.copyWith(clearLocalKey: true);
      c.ctx.link.invalidate(dropKey: true);
      final before = env.cloud.calls.where((x) => x.startsWith('localKey')).length;
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.cloud.calls.where((x) => x.startsWith('localKey')).length, before + 1);
      expect(env.cloud.localKeyHomeIds.last, kClaimedHome, reason: 'anahtar claim edilen evden istenir (aktif ev DEĞİL)');
      expect(c.target!.localKey, kLocalKey, reason: 'yalnızca bellekte');
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)));
      expect(await dumpPrefs(), isNot(contains(kLocalKey)));
    });

    test('telefon hâlâ kurulum ağındaysa (internet yok) açıklama gelir: ev Wi-Fi\'sine dönün', () async {
      env.phoneOnSetupNetwork();
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      final p = c.cloud.problem!;
      expect(p.kind, SetupProblemKind.network);
      expect(p.todo, contains('ev Wi-Fi'));
      env.phoneOnHomeNetwork();
      expect(await drive(env, c.cloud.retry().then((_) => c.cloud.isComplete)), isTrue);
    });

    test('pano buluta bağlanamazsa 90 sn sonra nedeni açıklanır: sunucuya güvenli bağlantı kurulamıyor', () async {
      env.device.onMqttConfigured = (_, _, _, _) {}; // kimlik yazıldı ama pano buluta bağlanamıyor
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      final p = c.cloud.problem!;
      expect(p.title, 'Pano sunucuya güvenli bağlanamıyor');
      expect(p.todo, contains('Kimliği Yeniden Yaz'));
      expect(c.canContinue, isFalse);
      expect(c.cloud.credentialWritten, isTrue);
    });

    test('pano saati alamıyorsa (NTP) bu neden olarak söylenir', () async {
      env.device.onMqttConfigured = (_, _, _, _) {};
      env.device.timeSynced = false;
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      expect(c.cloud.problem!.title, 'Pano saati internetten alamıyor');
    });

    test('pano ev Wi-Fi\'sinden düşmüşse 5. adıma dönülmesi önerilir', () async {
      env.device.onMqttConfigured = (_, _, _, _) {};
      env.device.wifiConnected = false;
      // Kimlik yazıldıktan sonra pano ağdan düştü: yerel durum wifi_connected=false.
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      expect(c.cloud.problem, isNotNull);
    });

    test('kimliği yeniden yaz: sunucudan yeni kimlik alınıp panoya yazılır (eski kimlik geçersiz olur)', () async {
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      env.clock.advance(const Duration(seconds: 30)); // yeni kimlikle yeni bir durum iletisi gelmesi için zaman geçer
      env.cloud.deviceCredentialToReturn = const DeviceMqttCredential(
        host: 'mqtt.ornek.test',
        port: 8884,
        username: 'd_h_kurulum',
        password: 'yeni-kimlik-parolasi',
        topicId: 'h_kurulum',
      );
      expect(await drive(env, c.cloud.rewriteCredential()), isTrue);
      expect(env.cloud.calls, contains('reissueDeviceMqttCredential:$kDeviceUid'));
      expect(env.device.receivedMqttPass, 'yeni-kimlik-parolasi');
      expect(env.device.mqttConfigCount, 2);
    });

    test('yeni kurulumda (claim edilen pano) sunucuda çevrimiçi görünse bile bulut kimliği yazılır: çevrimiçi atlama yalnızca mevcut cihazlar içindir',
        () async {
      env.cloud.deviceOnline = true; // bayat "çevrimiçi" bilgisi (claim kimliği yeniledi)
      env.cloud.deviceLastSeen = env.clock.now().toUtc().subtract(const Duration(seconds: 30));
      env.device.onMqttConfigured = (server, port, user, pass) {
        env.cloud.deviceOnline = true;
        env.cloud.deviceLastSeen = env.clock.now().toUtc().add(const Duration(seconds: 5));
        env.device.mqttConnected = true;
      };
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(c.cloud.alreadyOnline, isFalse);
      expect(env.device.mqttConfigCount, 1, reason: 'claim sonucundaki tek seferlik kimlik panoya yazıldı');
    });

    test('uygulama kapanıp açılmış gibi (bellekte kimlik yok): kimlik sunucudaki yeniden üretme ucuyla alınır ve yazılır', () async {
      c.ctx.pendingCredential = null; // uygulama adımlar arasında kapandı: tek seferlik kimlik kayboldu
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.cloud.calls, contains('reissueDeviceMqttCredential:$kDeviceUid'));
      expect(env.device.mqttConfigCount, 1);
    });

    test('pano kimliği reddederse hata gösterilir ve bir sonraki denemede yeni kimlik üretilir', () async {
      env.device.onMqttConfigured = null;
      env.cloud.deviceCredentialToReturn = const DeviceMqttCredential(
        host: 'mqtt.ornek.test',
        port: 8884,
        username: 'd_h_kurulum',
        password: '',
        topicId: 'h_kurulum',
      );
      c.ctx.pendingCredential = const DeviceMqttCredential(
        host: 'mqtt.ornek.test',
        port: 8884,
        username: 'd_h_kurulum',
        password: '',
        topicId: 'h_kurulum',
      );
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      expect(c.cloud.problem, isNotNull);
      expect(c.ctx.pendingCredential, isNull, reason: 'reddedilen kimlik bellekten atılır');
    });

    test('yerel ağdan pano kaybolursa (telefon başka ağda) açıklama gelir', () async {
      env.device.lanReachable = false;
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      expect(c.cloud.problem!.kind, SetupProblemKind.deviceNetwork);
    });
  });

  group('6-9. adımlar: pano anahtarı reddederse (yeniden anahtarlanmış) aynı anahtar tekrar tekrar gönderilmez', () {
    late ServiceHarness env;
    late ServiceSetupController c;
    const String newKey = 'yeni-pano-anahtari-77';

    setUp(() async {
      env = await serviceHarness();
      c = await completeClaim(env);
      await completeWifi(env, c);
      expect(c.target!.localKey, kLocalKey);
      env.device.localKey = newKey; // pano yeniden anahtarlandı (etiket yenileme / acil sıfırlama / factory init)
    });
    tearDown(() => env.dispose());

    test('sunucudaki anahtar da eskiyse: reddedilen anahtar hedeften silinir ve pano kilitlenene kadar yeniden DENENMEZ', () async {
      for (var i = 0; i < 8; i++) {
        expect(await drive(env, c.conn.connect()), isFalse, reason: 'deneme $i');
      }
      expect(env.device.wrongKeyAttempts, 1, reason: 'aynı yanlış anahtar yalnızca bir kez gönderildi (5. denemede pano kilitlenirdi)');
      expect(c.target!.localKey, isNull, reason: 'reddedilen anahtar hedefte bırakılmaz');
      expect(c.conn.problem!.title, 'Pano cihaz anahtarını kabul etmedi');
      expect(c.conn.problem!.todo, contains('elle girin'));

      // Elle doğru anahtar girilince bağlanır.
      expect(await drive(env, c.conn.useManualKey(newKey)), isTrue);
      expect(c.conn.ready, isTrue);
      expect(c.target!.localKey, newKey);
    });

    test('sunucuda taze anahtar varsa: eskimiş anahtar reddedilince taze anahtar bir kez denenir ve bağlanılır', () async {
      env.cloud.localKeyValue = newKey; // sunucu güncel anahtarı verir
      final before = env.cloud.calls.where((x) => x.startsWith('localKey')).length;
      expect(await drive(env, c.conn.connect()), isTrue);
      expect(c.conn.ready, isTrue);
      expect(c.target!.localKey, newKey);
      expect(env.cloud.calls.where((x) => x.startsWith('localKey')).length, before + 1);
      expect(env.device.wrongKeyAttempts, 0, reason: 'başarılı doğrulama sayacı sıfırlar');
      expect(env.dumpSecureStore(), isNot(contains(newKey)));
    });

    test('süper yönetici: 5. adım anahtarsız tamamlanır; 6. adımda sunucu anahtar vermez, yanlış elle anahtar reddedilir, doğrusu kabul edilir', () async {
      final superEnv = await serviceHarness(role: 'super', inventoryListed: true);
      addTearDown(superEnv.dispose);
      final sc = await completeClaim(superEnv);
      expect(sc.target!.localKey, isNull, reason: 'süper kullanıcıya yerel anahtar verilmez');
      await completeWifi(superEnv, sc); // kurulum ağında anahtar gerekmedi
      expect(sc.wifi.connected, isTrue);

      expect(await drive(superEnv, sc.conn.connect()), isFalse);
      expect(sc.conn.problem!.title, 'Cihaz anahtarı alınamadı');
      expect(superEnv.cloud.localKeyHomeIds, isEmpty, reason: 'sunucu süper yöneticiye anahtar vermediği için hiç sorulmaz');
      expect(await drive(superEnv, sc.conn.useManualKey('yanlis-anahtar-123')), isFalse);
      expect(sc.conn.problem!.title, 'Pano cihaz anahtarını kabul etmedi');
      expect(await drive(superEnv, sc.conn.useManualKey(kLocalKey)), isTrue);
      expect(sc.conn.ready, isTrue);
    });

    test('pano kilitlenmişse (423) bekleme süresi söylenir ve yeniden denenmez', () async {
      env.device.wrongKeyAttempts = 5;
      env.cloud.localKeyValue = newKey;
      expect(await drive(env, c.conn.connect()), isFalse);
      expect(c.conn.problem!.kind, SetupProblemKind.locked);
      expect(c.conn.problem!.retryAfter, const Duration(seconds: 60));
    });

    test('7-9. adımlarda yapılan keyli çağrı reddedilirse anahtar hedeften silinir (deviceCall)', () async {
      env.device.localKey = kLocalKey;
      expect(await drive(env, c.conn.connect()), isTrue);
      env.device.localKey = newKey; // bağlandıktan sonra pano yeniden anahtarlandı (önbellekli bağlantı hâlâ "hazır")
      await drive(env, c.relays.load());
      expect(c.relays.problem, isNotNull);
      expect(c.target!.localKey, isNull);
      final attempts = env.device.wrongKeyAttempts;
      await drive(env, c.relays.load());
      expect(env.device.wrongKeyAttempts, attempts, reason: 'reddedilen anahtar yeniden gönderilmedi');
    });
  });

  group('7. adım: röle testi', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.relays);
      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    test('röleler panodan okunur; hiçbiri doğrulanmadan devam açılmaz', () async {
      expect(c.relays.relays.map((r) => r.id), <int>[5, 6, 7, 8]);
      expect(c.canContinue, isFalse);
      expect(c.relays.untestedCount, 4);
    });

    test('pano komutu uygulamazsa "röle komutuna cevap vermedi" denir ve röle sorunlu işaretlenir', () async {
      env.device.unresponsiveRelays.add(5);
      expect(await drive(env, c.relays.command(5, true)), isFalse);
      expect(c.relays.problem!.title, 'Pano röle komutuna cevap vermedi');
      expect(c.relays.byId(5)!.verdict, RelayVerdict.problem);
      expect(c.relays.canRetry, isTrue);
      expect(c.canContinue, isFalse);
    });

    test('pano açtı ama teknisyen yük çalışmadı derse röle sorunlu sayılır ve geçilemez', () async {
      expect(await drive(env, c.relays.command(5, true)), isTrue);
      c.relays.confirmLit(5, false);
      expect(c.relays.byId(5)!.verdict, RelayVerdict.problem);
      expect(c.relays.byId(5)!.note, contains('klemens'));
      expect(c.relays.isComplete, isFalse);

      // Düzeltme: testi sıfırla, yeniden dene.
      c.relays.resetRelay(5);
      expect(c.relays.byId(5)!.verdict, RelayVerdict.untested);
    });

    test('kullanılmayan çıkışlar işaretlenebilir ama en az bir röle gerçekten doğrulanmalıdır', () async {
      for (final r in c.relays.relays) {
        c.relays.setUnused(r.id, true);
      }
      expect(c.relays.isComplete, isFalse, reason: 'hiç röle doğrulanmadı');
      c.relays.setUnused(5, false);
      expect(await drive(env, c.relays.command(5, true)), isTrue);
      c.relays.confirmLit(5, true);
      expect(await drive(env, c.relays.command(5, false)), isTrue);
      expect(c.relays.isComplete, isTrue);
      expect(c.canContinue, isTrue);
    });

    test('adımdan çıkarken yanan lambalar kapatılır', () async {
      expect(await drive(env, c.relays.command(5, true)), isTrue);
      c.relays.confirmLit(5, true);
      for (final r in c.relays.relays) {
        if (r.id != 5) c.relays.setUnused(r.id, true);
      }
      expect(await drive(env, c.relays.command(5, false)), isTrue);
      expect(await drive(env, c.relays.command(5, true)), isTrue);
      c.relays.confirmLit(5, true);
      // Röle 5 açıkken ve test tamam sayılırken adımdan çıkılır: lambalar kapanır.
      expect(await drive(env, c.relays.command(5, false)), isTrue);
      expect(c.relays.isComplete, isTrue);
      c.continueNext();
      await env.clock.elapse(const Duration(seconds: 1));
      expect(env.device.relayState(5), isFalse);
    });

    test('darbe rölesinde pano geri bildirimi görülemezse teyit düğmeleri gelir; gözle doğrulama röleyi tamamlar ve raporda belirtilir', () async {
      // Panoya bir darbe (impulse) rölesi (type 3) eklenir: durum bildiriminde hiç "açık" görünmez.
      env.device.relays.add(SimRelay(9, 'Kapı Zili', 3));
      for (final r in c.relays.relays) {
        if (r.id != 9) c.relays.setUnused(r.id, true);
      }
      expect(await drive(env, c.relays.load()), isTrue);
      final before = c.relays.byId(9)!;
      expect(before.isImpulse, isTrue);

      expect(await drive(env, c.relays.command(9, true)), isTrue, reason: 'komut pano tarafından kabul edildi');
      expect(env.device.impulseTriggers, 1);
      final r = c.relays.byId(9)!;
      expect(r.sawOn, isFalse, reason: 'darbe çok kısa: pano geri bildirimi görülemedi');
      expect(r.cmdSent, isTrue);
      expect(r.awaitingLitAnswer, isTrue, reason: 'teknisyen "çalıştı mı?" sorusunu yanıtlayabilmeli (çıkmaz yok)');
      expect(r.verdict, RelayVerdict.untested);
      expect(r.info, contains('gözle doğrulayın'));
      expect(r.note, isNull, reason: 'bu bir sorun değil, bilgi notudur');
      expect(c.relays.problem, isNull);

      c.relays.confirmLit(9, true);
      expect(c.relays.byId(9)!.verdict, RelayVerdict.ok);
      expect(c.relays.byId(9)!.visualOnly, isTrue);
      expect(c.relays.isComplete, isTrue);
      expect((c.relays.snapshot()['relays'] as Map<String, String>)['9'], 'visual');
      c.handover.setOwnerApproved(true);
      expect(c.handover.buildChecks().relays.detail, contains('gözle doğrulandı'));
    });

    test('kayıttan devam: gözle doğrulanan darbe rölesi ("visual") geri yüklenir ve yeniden test istenmez', () async {
      env.device.relays.add(SimRelay(9, 'Kapı Zili', 3));
      c.relays.restore(<String, dynamic>{
        'relays': <String, String>{'9': 'visual'},
      });
      expect(await drive(env, c.relays.load()), isTrue);
      expect(c.relays.byId(9)!.verdict, RelayVerdict.ok);
      expect(c.relays.byId(9)!.visualOnly, isTrue);
      expect(c.relays.byId(9)!.awaitingLitAnswer, isFalse);
    });

    test('darbe rölesinde teknisyen "çalışmadı" derse röle sorunlu sayılır', () async {
      env.device.relays.add(SimRelay(9, 'Kapı Zili', 3));
      for (final r in c.relays.relays) {
        if (r.id != 9) c.relays.setUnused(r.id, true);
      }
      await drive(env, c.relays.load());
      await drive(env, c.relays.command(9, true));
      c.relays.confirmLit(9, false);
      expect(c.relays.byId(9)!.verdict, RelayVerdict.problem);
      expect(c.relays.isComplete, isFalse);
    });

    test('doğrulanan röleler ilerleme kaydına yazılır ve kayıttan geri yüklenir', () async {
      expect(await drive(env, c.relays.command(5, true)), isTrue);
      c.relays.confirmLit(5, true);
      expect(await drive(env, c.relays.command(5, false)), isTrue);
      c.relays.setUnused(8, true);
      final snap = c.relays.snapshot();
      expect(snap['relays'], <String, String>{'5': 'ok', '8': 'unused'});
    });
  });

  group('8. adım: panjur testi ve kalibrasyon', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.shutters);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    test('yön ters çıkarsa düzeltme talimatı verilir, adım geçilemez; yeniden test sıfırlar', () async {
      expect(await drive(env, c.shutters.move(1, 'up')), isTrue);
      c.shutters.confirmDirection(1, wentUp: false);
      final s = c.shutters.byPair(1)!;
      expect(s.verdict, ShutterDirectionVerdict.reversed);
      expect(s.note, contains('yer değiştirin'));
      expect(c.shutters.isComplete, isFalse);
      c.shutters.retestDirection(1);
      expect(c.shutters.byPair(1)!.verdict, ShutterDirectionVerdict.unknown);
    });

    test('erken bitirilen ölçüm (3 sn\'den kısa) reddedilir ve baştan istenir', () async {
      expect(await drive(env, c.shutters.move(1, 'up')), isTrue);
      c.shutters.confirmDirection(1, wentUp: true);
      expect(await drive(env, c.shutters.move(1, 'stop')), isTrue);
      expect(await drive(env, c.shutters.prepareMeasure(1)), isTrue);
      expect(env.device.shutterRuntime(1), 300);
      expect(await drive(env, c.shutters.driveToBottom(1)), isTrue);
      expect(await drive(env, c.shutters.bottomReached(1)), isTrue);
      expect(await drive(env, c.shutters.startMeasure(1)), isTrue);
      env.clock.advance(const Duration(seconds: 1));
      expect(await drive(env, c.shutters.finishMeasure(1)), isFalse);
      expect(c.shutters.problem!.title, 'Ölçüm çok kısa');
      expect(c.shutters.byPair(1)!.phase, MeasurePhase.idle);
      expect(c.shutters.byPair(1)!.measuredSeconds, isNull);
    });

    test('süre ölçüm sırası zorunludur: alta inmeden ölçüm başlatılamaz', () async {
      expect(await drive(env, c.shutters.startMeasure(1)), isFalse);
      expect(c.shutters.problem!.title, 'Önce panjuru alta indirin');
    });

    test('sunucu süreyi kaydetti ama pano uygulamadıysa "panoda uygulanmadı" denir ve kayıt başarılı sayılmaz', () async {
      env.device.rejectRuntimeApply = true;
      expect(await drive(env, c.shutters.prepareMeasure(1)), isFalse);
      expect(c.shutters.problem!.title, 'Süre panoda uygulanmadı');
      expect(c.shutters.byPair(1)!.phase, isNot(MeasurePhase.prepared));
    });

    test('elle süre 1-300 sn aralığında olmalıdır; kaydedilen süre pano geri okunarak doğrulanır', () async {
      expect(c.shutters.setManualSeconds(1, 0), isFalse);
      expect(c.shutters.problem!.title, 'Süre geçersiz');
      expect(c.shutters.setManualSeconds(1, 301), isFalse);
      expect(c.shutters.setManualSeconds(1, 31), isTrue);
      expect(await drive(env, c.shutters.saveRuntime(1)), isTrue);
      expect(env.device.shutterRuntime(1), 31);
      expect(c.shutters.byPair(1)!.savedSeconds, 31);
      expect(env.cloud.endpointUpdates.last['sec'], 31);
      expect(env.cloud.endpointUpdates.last['home_id'], kClaimedHome);
    });

    test('ölçülen süre yokken kayıt reddedilir; sunucu hatasında süre kaydedilmiş sayılmaz', () async {
      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);
      expect(c.shutters.problem!.title, 'Kaydedilecek süre yok');
      c.shutters.setManualSeconds(1, 25);
      env.cloud.updateEndpointError = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'x');
      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);
      expect(c.shutters.problem!.kind, SetupProblemKind.server);
      expect(c.shutters.byPair(1)!.savedSeconds, isNull);
      expect(c.shutters.isComplete, isFalse);
    });

    test('kullanılmayan panjur işaretlenebilir ama en az bir panjur gerçekten test edilmeden adım tamamlanmaz', () async {
      await drive(env, c.shutters.setUnused(1, true));
      expect(c.shutters.isComplete, isFalse, reason: 'diğer panjur henüz hazır değil');
      await drive(env, c.shutters.setUnused(2, true));
      expect(c.shutters.shutters.every((s) => s.unused), isTrue);
      expect(c.shutters.isComplete, isFalse, reason: 'hiç panjur test edilmedi: yalnızca beyanla geçilemez');
      expect(c.canContinue, isFalse);

      // Bir panjur geri alınıp gerçekten test edilirse adım tamamlanır.
      await drive(env, c.shutters.setUnused(2, false));
      await completeShutter(env, c, 2);
      expect(c.shutters.isComplete, isTrue);
      expect(c.canContinue, isTrue);
    });

    test('ölçüm iptal edilince geçici 300 sn önceki süreye geri yüklenir (panoda ve sunucuda)', () async {
      expect(env.device.shutterRuntime(1), 20);
      expect(await drive(env, c.shutters.prepareMeasure(1)), isTrue);
      expect(env.device.shutterRuntime(1), 300);
      expect(c.shutters.byPair(1)!.previousSeconds, 20);

      expect(await drive(env, c.shutters.cancelMeasure(1)), isTrue);
      expect(env.device.shutterRuntime(1), 20, reason: 'ölçüm bırakıldı: pano geçici 300 sn\'de kalmamalı');
      expect(env.cloud.endpointUpdates.last['sec'], 20, reason: 'sunucudaki kayıt da geri alındı');
      expect(c.shutters.byPair(1)!.previousSeconds, isNull);
      expect(c.shutters.byPair(1)!.phase, MeasurePhase.idle);
    });

    test('ölçüm sürerken "bu panjur kullanılmıyor" işaretlenirse önce önceki süre geri yüklenir', () async {
      await drive(env, c.shutters.prepareMeasure(1));
      expect(env.device.shutterRuntime(1), 300);
      expect(await drive(env, c.shutters.setUnused(1, true)), isTrue);
      expect(env.device.shutterRuntime(1), 20);
      expect(c.shutters.byPair(1)!.unused, isTrue);
      expect(c.shutters.byPair(1)!.previousSeconds, isNull);
    });

    test('yarım kalan ölçümde adımdan geri dönülünce panjur durdurulur ve önceki süre geri yüklenir', () async {
      await drive(env, c.shutters.prepareMeasure(1));
      await drive(env, c.shutters.driveToBottom(1));
      expect(env.device.shutterMoving(1), isTrue);
      c.goBack();
      await waitUntil(env, () => !c.isBusy && env.device.shutterRuntime(1) == 20);
      expect(env.device.shutterMoving(1), isFalse, reason: 'panjur durduruldu');
      expect(env.device.shutterRuntime(1), 20);
      expect(c.shutters.byPair(1)!.phase, MeasurePhase.idle);
    });

    test('sihirbazdan çıkmadan önce (settleBeforeExit) yarım ölçümün geçici süresi geri yüklenir', () async {
      await drive(env, c.shutters.prepareMeasure(2));
      expect(env.device.shutterRuntime(2), 300);
      await drive(env, c.settleBeforeExit());
      expect(env.device.shutterRuntime(2), 20);
    });

    test('uygulama ölçüm sırasında kapanırsa kayıtta önceki süre vardır ve devam edilince panoya geri yazılır', () async {
      await drive(env, c.shutters.prepareMeasure(1));
      expect(c.shutters.snapshot()['shutters'], <String, dynamic>{
        '1': <String, dynamic>{'dir': false, 'prev': 20},
      });
      await pumpEventQueue();
      final saved = (await env.store.list(env.access.ownerKey)).single;
      c.dispose(); // uygulama kapandı: pano hâlâ geçici 300 sn'de
      expect(env.device.shutterRuntime(1), 300);

      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      resumed.start();
      await waitUntil(env, () => resumed.shutters.loaded && !resumed.isBusy);
      expect(env.device.shutterRuntime(1), 20, reason: 'yarım kalan ölçümün geçici süresi devam edilirken geri yüklendi');
      expect(resumed.shutters.byPair(1)!.previousSeconds, isNull);
    });

    test('yeniden ölçmek kayıtlı süreyi geçersiz kılar (adım yeniden kayıt ister)', () async {
      c.shutters.setManualSeconds(1, 20);
      c.shutters.confirmDirection(1, wentUp: true);
      expect(await drive(env, c.shutters.saveRuntime(1)), isTrue);
      expect(c.shutters.byPair(1)!.isReady, isTrue);
      c.shutters.remeasure(1);
      expect(c.shutters.byPair(1)!.isReady, isFalse);
    });

    test('hazırlık aşamasında panjur hareket halindeyse önce durdurulur', () async {
      expect(await drive(env, c.shutters.move(1, 'up')), isTrue);
      expect(env.device.shutterMoving(1), isTrue);
      expect(await drive(env, c.shutters.prepareMeasure(1)), isTrue);
      expect(env.device.shutterMoving(1), isFalse, reason: 'süre değişimi hareket halindeyken reddedilir');
      expect(env.device.shutterRuntime(1), 300);
    });
  });

  group('9. adım: duvar butonları', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.buttons);
      await waitUntil(env, () => c.buttons.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    test('hiçbir giriş basılmadıysa adım tamamlanmaz', () async {
      expect(await drive(env, c.buttons.startListening()), isTrue);
      await env.clock.elapse(const Duration(seconds: 3));
      expect(c.buttons.detectedCount, 0);
      expect(c.buttons.isComplete, isFalse);
      expect(c.canContinue, isFalse);
    });

    test('dinleme başlamadan önce basılı bir buton sayılmaz; yalnızca gerçek basış (kenar) algılanır', () async {
      env.device.setDi(1, true);
      expect(await drive(env, c.buttons.load()), isTrue, reason: 'giriş zaten basılıyken durum okunur');
      expect(await drive(env, c.buttons.startListening()), isTrue);
      await env.clock.elapse(const Duration(seconds: 2));
      expect(c.buttons.buttons.firstWhere((b) => b.id == 1).verdict, ButtonVerdict.untested,
          reason: 'zaten basılı bir giriş basış sayılmaz');
      env.device.setDi(1, false);
      await env.clock.elapse(const Duration(milliseconds: 400));
      env.device.setDi(1, true);
      await env.clock.elapse(const Duration(milliseconds: 400));
      expect(c.buttons.buttons.firstWhere((b) => b.id == 1).verdict, ButtonVerdict.detected);
    });

    test('butonu olmayan giriş "buton yok" işaretlenir; kalan girişler algılanınca adım tamamlanır', () async {
      expect(await drive(env, c.buttons.startListening()), isTrue);
      c.buttons.markNone(4, true);
      for (var id = 1; id <= 3; id++) {
        env.device.setDi(id, true);
        await env.clock.elapse(const Duration(milliseconds: 400));
        env.device.setDi(id, false);
        await env.clock.elapse(const Duration(milliseconds: 400));
      }
      expect(c.buttons.isComplete, isTrue);
      expect(c.buttons.noneCount, 1);
      expect(c.canContinue, isTrue);
    });

    test('adımdan çıkınca dinleme durur ve yoklama zamanlayıcısı kalmaz', () async {
      expect(await drive(env, c.buttons.startListening()), isTrue);
      for (var id = 1; id <= 4; id++) {
        c.buttons.markNone(id, true);
      }
      c.continueNext();
      expect(c.buttons.listening, isFalse);
    });
  });

  group('10. adım: teslim', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.handover);
    });
    tearDown(() => env.dispose());

    test('müşteri onayı olmadan gönderilemez; onay verilince sunucu karar verir (istemci tests_passed göndermez)', () async {
      expect(c.handover.allStepsReady, isTrue);
      expect(c.handover.canSubmit, isFalse);
      expect(await drive(env, c.handover.submit()), isFalse);
      expect(c.handover.problem!.title, 'Müşteri onayı gerekli');
      expect(env.cloud.commissionChecks, isEmpty);

      c.handover.setOwnerApproved(true);
      expect(c.handover.canSubmit, isTrue);
      expect(await drive(env, c.handover.submit()), isTrue);
      expect(c.isFinished, isTrue);
      expect(c.handover.canSubmit, isFalse, reason: 'bir kez onaylandıktan sonra yeniden gönderilmez');
    });

    test('5 zorunlu kontrol ayrı alanlarla ve gerçek ayrıntılarla gönderilir; hepsi claim edilen eve gider', () async {
      c.handover.setOwnerApproved(true);
      c.handover.setNotes('  Montaj tamam  ');
      c.handover.setReceiver('Ayşe Hanım');
      expect(await drive(env, c.handover.submit()), isTrue);
      final checks = env.cloud.commissionChecks.single;
      expect(checks.relays.detail, contains('4 röle doğrulandı'));
      expect(checks.buttons.detail, contains('4 buton algılandı'));
      expect(checks.shutters.detail, contains('Panjur 1'));
      expect(checks.network.detail, contains('Wi-Fi'));
      expect(checks.cloud.detail, 'Sunucuda çevrimiçi');
      expect(env.cloud.commissionNotes.single, 'Montaj tamam\nTeslim alan: Ayşe Hanım');
      expect(env.cloud.homeIdsUsed.every((id) => id == kClaimedHome), isTrue);
    });

    test('sunucu devreye almayı onaylamazsa kurulum bitmiş sayılmaz ve neden gösterilir', () async {
      env.cloud.serverCommissionRejects = true;
      c.handover.setOwnerApproved(true);
      expect(await drive(env, c.handover.submit()), isFalse);
      expect(c.isFinished, isFalse);
      expect(c.handover.problem!.kind, SetupProblemKind.rejected);
      expect(c.handover.problem!.why, contains('bulut'));
      expect(c.handover.isComplete, isFalse);
    });

    test('gönderim ağ hatasıyla düşerse tekrar denenebilir ve tekrar başarılı olur', () async {
      env.cloud.commissionError = ApiException.network();
      c.handover.setOwnerApproved(true);
      expect(await drive(env, c.handover.submit()), isFalse);
      expect(c.handover.canRetry, isTrue);
      env.cloud.commissionError = null;
      await drive(env, c.handover.retry());
      expect(c.handover.isComplete, isTrue);
    });

    test('önceki adımlardan biri bozulursa eksik adım adıyla gösterilir ve gönderilmez', () async {
      c.relays.resetRelay(5);
      c.handover.setOwnerApproved(true);
      expect(c.handover.missingSteps, <int>[SetupSteps.relays]);
      expect(await drive(env, c.handover.submit()), isFalse);
      expect(c.handover.problem!.fixStep, SetupSteps.relays);
      expect(env.cloud.commissionChecks, isEmpty);
    });

    test('rapor PIN, anahtar, bulut kimliği, OTP, Wi-Fi şifresi ve müşteri e-postasını içermez', () async {
      c.handover.setOwnerApproved(true);
      expect(await drive(env, c.handover.submit()), isTrue);
      final report = c.handover.buildReport(roleLabel: 'Servis personeli');
      expect(report, contains('BAŞARILI'));
      expect(report, contains(kDeviceUid));
      for (final secret in <String>[kSetupPin, kCustomerOtp, kCredentialPassword, kLocalKey, kHomeWifiPass, kApPass, kCustomerEmail]) {
        expect(report, isNot(contains(secret)));
      }
      expect(report, contains('m***@o***.test'));
    });
  });

  group('yanlış cihaz / yanlış ev sızıntısı', () {
    test('tüm bulut çağrıları claim edilen eve gider; aktif ev hiç kullanılmaz; anahtar yalnızca beklenen adreslere gider', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await reachStep(env, SetupSteps.handover);
      c.handover.setOwnerApproved(true);
      await drive(env, c.handover.submit());

      expect(env.state.activeHome, isNull);
      expect(env.cloud.homeIdsUsed, isNotEmpty);
      expect(env.cloud.homeIdsUsed.toSet(), <String>{kClaimedHome});
      expect(env.cloud.localKeyHomeIds.toSet(), <String>{kClaimedHome});
      expect(env.device.keyHeaderHosts.toSet().difference(<String>{kLanIp}), isEmpty,
          reason: 'cihaz anahtarı yalnızca ev ağı adresine gönderilir (kurulum ağında anahtarsız çalışılır)');
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)), reason: 'cihaz anahtarı güvenli depoya da yazılmaz');
    });

    test('ServiceTarget metin gösterimi anahtarı maskeler', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await completeClaim(env);
      expect(c.target!.localKey, kLocalKey);
      expect(c.target.toString(), isNot(contains(kLocalKey)));
      expect(c.target.toString(), contains('******'));
    });

    test('hiçbir adımda gizli değer hata/özet nesnelerinde yer almaz', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.expectedPin = '999999';
      final c = await startedController(env);
      c.continueNext();
      await c.identify.acceptLabel(kLabelQr);
      c.continueNext();
      await c.customer.sendCode(kCustomerEmail);
      c.customer.setCode(kCustomerOtp);
      c.continueNext();
      await c.claim.claim();
      final p = c.claim.problem!;
      for (final text in <String>[p.title, p.why, p.todo, p.toString()]) {
        expect(text, isNot(contains(kSetupPin)));
        expect(text, isNot(contains(kCustomerOtp)));
      }
    });
  });
}
