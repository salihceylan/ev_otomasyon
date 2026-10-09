import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/identify_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// Servis kurulumu (2026-10-08):
///
/// * servis_kurulum-1: Ethernet yolu hazırlanmamış panoyu hazırlamadan teslim etmez (Ethernet'ten ilk hazırlık, 6-10.
///   adımlarda ve teslimde hazırlık denetimi); anahtar parmak izi (`lk_fp`) uyuşmazlığında panonun anahtarı eşitlenir.
/// * servis_kurulum-5: elle girilen anahtar ikinci kez yazdırılır; 6. adımda sunucu anahtarıyla doğrulanır ve farklıysa
///   panonun anahtarı sunucudakine çevrilir (süper yöneticide yapılmaz).
/// * servis_kurulum-7: ilk hazırlık daima kurulum ağı adresine gider; tamamlanmış 5. adım yeniden kurulabilir.
void main() {
  const ethIp = '192.168.1.77';
  const serverKey = 'sunucu-anahtari-99';
  const manualKey = 'elle-girilen-anahtar-7';
  String fpOf(String key) => key == kLocalKey ? 'aaaaaaaa' : (key == serverKey ? 'bbbbbbbb' : 'cccccccc');

  late ServiceHarness env;
  tearDown(() => env.dispose());

  group('servis_kurulum-1: Ethernet ve hazırlanmamış pano', () {
    Future<ServiceSetupController> ethUnprovisioned({bool keyAtClaim = true}) async {
      env = await serviceHarness(provisioned: false);
      env.device.apSecured = false;
      if (!keyAtClaim) env.cloud.localKeyError = ApiException.network();
      final c = await completeClaim(env);
      env.cloud.localKeyError = null;
      env.device
        ..ethConnected = true
        ..ethIp = ethIp;
      return c;
    }

    test('kurulum ağından kontrol: Ethernet bildiren ama hazırlanmamış pano hazırlık yolunda kalır', () async {
      final c = await ethUnprovisioned();
      env.phoneOnSetupNetwork();
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.needsProvision, isTrue);
      expect(c.wifi.ethernetMode, isFalse, reason: 'hazırlanmamış pano Ethernet (hazırlıksız) yoluna alınmaz');
    });

    test('Ethernet ile doğrulama hazırlanmamış panoda adımı tamamlamaz; hazırlık istenir', () async {
      final c = await ethUnprovisioned();
      env.phoneOnHomeNetwork();
      c.wifi.setEthernetMode(true);
      expect(await drive(env, c.wifi.confirmEthernet(ethIp)), isFalse);
      expect(c.wifi.isComplete, isFalse);
      expect(c.wifi.needsProvision, isTrue);
      expect(c.wifi.problem!.title, 'Pano hazırlanmamış (cihaz anahtarı yok)');
      expect(c.wifi.problem!.todo, contains('Panoyu Hazırla'));
    });

    test('Ethernet üzerinden ilk hazırlık: factory/init Ethernet adresine gider, sonra pano hazırlanmış görünür', () async {
      final c = await ethUnprovisioned(keyAtClaim: false);
      env.phoneOnHomeNetwork();
      c.wifi.setEthernetMode(true);
      expect(await drive(env, c.wifi.confirmEthernet(ethIp)), isFalse);
      expect(await c.wifi.provisionViaEthernet(ip: ethIp, apPass: 'kisa', apPassConfirm: 'kisa'), isFalse);
      expect(c.wifi.problem!.title, 'Kurulum ağı parolası geçersiz');

      expect(await drive(env, c.wifi.provisionViaEthernet(ip: ethIp, apPass: kApPass, apPassConfirm: kApPass)), isTrue);
      expect(env.device.factoryInitCount, 1);
      expect(env.device.factoryInitHosts.single, ethIp);
      expect(env.device.provisioned, isTrue);
      expect(env.device.localKey, kLocalKey, reason: 'anahtar sunucudan (internetle) alınıp yazıldı');
      expect(c.wifi.isComplete, isTrue);
      expect(c.wifi.viaEthernet, isTrue);
      expect(c.wifi.needsProvision, isFalse);
      expect(c.target!.ip, ethIp);
      expect(c.target!.localKey, kLocalKey);
    });

    test('6. adım ve sonrası hazırlanmamış panoyu reddeder: 5. adıma yönlendirilir', () async {
      env = await serviceHarness();
      final c = await completeClaim(env);
      await completeWifi(env, c);
      env.device
        ..provisioned = false
        ..localKey = null; // pano sıfırlandı
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      expect(c.cloud.problem!.title, 'Pano hazırlanmamış');
      expect(c.cloud.problem!.fixStep, SetupSteps.wifi);
      expect(env.device.mqttConfigCount, 0);
    });

    test('teslim hazırlanmamış panoda reddedilir', () async {
      env = await serviceHarness();
      final c = await reachStep(env, SetupSteps.handover);
      c.handover.setOwnerApproved(true);
      env.device
        ..provisioned = false
        ..localKey = null;
      expect(await drive(env, c.handover.submit()), isFalse);
      expect(c.handover.problem!.title, 'Pano hazırlanmamış');
      expect(c.handover.isComplete, isFalse);
      expect(env.cloud.calls.where((x) => x.startsWith('commission')), isEmpty);
    });

    Future<ServiceSetupController> ethProvisionedAtCloud() async {
      env = await serviceHarness();
      final c = await completeClaim(env);
      env.device
        ..wifiConnected = false
        ..staIp = ''
        ..ethConnected = true
        ..ethIp = ethIp
        ..lkFpOf = fpOf;
      env.phoneOnHomeNetwork();
      c.wifi.setEthernetMode(true);
      expect(await drive(env, c.wifi.confirmEthernet(ethIp)), isTrue);
      c.continueNext();
      expect(c.currentStep, SetupSteps.cloud);
      return c;
    }

    test('lk_fp uyuşmazlığı: 6. adım durur; onaylı eşitleme panonun anahtarını sunucudakine çevirir', () async {
      final c = await ethProvisionedAtCloud();
      env.cloud
        ..localKeyValue = serverKey
        ..localKeyFp = fpOf(serverKey);
      expect(await drive(env, c.cloud.connectAndWait()), isFalse);
      expect(c.cloud.problem!.title, 'Panodaki anahtar sunucudakinden farklı');
      expect(c.cloud.keyMismatch, isTrue);
      expect(env.device.mqttConfigCount, 0);

      expect(await drive(env, c.cloud.syncBoardKey()), isTrue);
      expect(env.device.rekeyCount, 1);
      expect(env.device.localKey, serverKey);
      expect(c.cloud.keyMismatch, isFalse);
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
    });

    test('lk_fp eşleşince anahtar yeniden yazılmaz', () async {
      final c = await ethProvisionedAtCloud();
      env.cloud.localKeyFp = fpOf(kLocalKey);
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.device.rekeyCount, 0);
    });
  });

  group('servis_kurulum-5: elle girilen anahtar', () {
    test('ikinci yazım uyuşmazsa anahtar kullanılmaz', () async {
      env = await serviceHarness(provisioned: false);
      env.device.apSecured = false;
      env.cloud.localKeyError = ApiException.network();
      final c = await completeClaim(env);
      env.cloud.localKeyError = null;
      env.phoneOnSetupNetwork();
      await drive(env, c.wifi.checkDevice());
      expect(c.wifi.useManualKey(manualKey, confirm: '${manualKey}x'), isFalse);
      expect(c.wifi.problem!.title, 'Anahtarlar eşleşmiyor');
      expect(c.wifi.hasProvisionKey, isFalse, reason: '"Panoyu Hazırla" kapalı kalır');
      expect(c.wifi.useManualKey(manualKey, confirm: manualKey), isTrue);
      expect(c.wifi.hasProvisionKey, isTrue);
    });

    Future<ServiceSetupController> provisionedWithManualKey({String role = 'staff'}) async {
      env = await serviceHarness(provisioned: false, role: role, inventoryListed: role == 'super');
      env.device.apSecured = false;
      env.cloud.localKeyError = ApiException.network();
      final c = await completeClaim(env);
      env.cloud.localKeyError = null;
      env.phoneOnSetupNetwork();
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.useManualKey(manualKey, confirm: manualKey), isTrue);
      expect(await drive(env, c.wifi.provision(apPass: kApPass, apPassConfirm: kApPass)), isTrue);
      expect(env.device.localKey, manualKey);
      env.device.apSecured = true;
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
      c.continueNext();
      env.phoneOnHomeNetwork();
      return c;
    }

    test('6. adım: sunucu anahtarı farklıysa panonun anahtarı sunucudakine çevrilir', () async {
      final c = await provisionedWithManualKey();
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.device.rekeyCount, 1);
      expect(env.device.localKey, kLocalKey, reason: 'sunucudaki anahtar');
      expect(c.target!.localKey, kLocalKey);
    });

    test('süper yöneticide sunucuya sorulmaz, anahtar değiştirilmez', () async {
      final c = await provisionedWithManualKey(role: 'super');
      final before = env.cloud.calls.where((x) => x.startsWith('localKey')).length;
      await drive(env, c.cloud.connectAndWait());
      expect(env.device.rekeyCount, 0);
      expect(env.device.localKey, manualKey);
      expect(env.cloud.calls.where((x) => x.startsWith('localKey')).length, before);
    });
  });

  group('servis_kurulum-7: kurulum ağı adresi ve ağ kurulumunu yeniden yapma', () {
    test('kontrol başarılıysa hedef kurulum ağı adresidir; ilk hazırlık eski ev IP\'sine gitmez', () async {
      env = await serviceHarness(provisioned: false);
      env.device.apSecured = false;
      final c = await completeClaim(env);
      c.ctx.target = c.ctx.target!.copyWith(ip: kLanIp); // mevcut cihaz / kayıttan devam: eski ev IP'si
      env.phoneOnSetupNetwork();
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.target!.ip, IdentifyLogic.apHost);

      c.ctx.target = c.ctx.target!.copyWith(ip: kLanIp); // eski adres yeniden yazılsa bile
      expect(await drive(env, c.wifi.provision(apPass: kApPass, apPassConfirm: kApPass)), isTrue);
      expect(env.device.factoryInitHosts.single, IdentifyLogic.apHost);
    });

    test('tamamlanmış 5. adım "Ağ bağlantısını yeniden kur" ile sıfırlanır ve kaydedilir', () async {
      env = await serviceHarness();
      final c = await completeClaim(env);
      await completeWifi(env, c);
      expect(c.wifi.isComplete, isTrue);
      c.wifi.restartNetworkSetup();
      expect(c.wifi.isComplete, isFalse);
      expect(c.wifi.connected, isFalse);
      expect(c.wifi.identity, isNull);
      expect(c.wifi.lastResult, isNull);
      expect(c.wifi.snapshot()['connected'], isFalse);
    });
  });

  test('DeviceStatus: lk_fp yalnız 8 küçük hex ise okunur', () {
    expect(DeviceStatus.fromJson(<String, dynamic>{'device': kDeviceUid, 'lk_fp': 'c7076562', 'relays': <dynamic>[]}).lkFp, 'c7076562');
    expect(DeviceStatus.fromJson(<String, dynamic>{'device': kDeviceUid, 'lk_fp': 'C7076562', 'relays': <dynamic>[]}).lkFp, isNull);
    expect(DeviceStatus.fromJson(<String, dynamic>{'device': kDeviceUid, 'relays': <dynamic>[]}).lkFp, isNull);
  });
}
