import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// Acil sıfırlama ve pano değişimi yanıtındaki **tek seferlik** bulut kimliği sihirbaza aktarılır
/// (`ServiceSetupWizardPage.initialCredential`): 6. adım panoya BUNU yazar, sunucudan yenisini üretmez
/// (gereksiz kimlik dönüşü ve çalışan panonun buluttan düşme riski olmaz). Kimlik yalnızca bellekte tutulur.

const String kHandoffPassword = 'tek-seferlik-kimlik-parolasi-77';

const DeviceMqttCredential kHandoffCredential = DeviceMqttCredential(
  host: 'mqtt.ornek.test',
  port: 8884,
  username: 'd_h_yeni',
  password: kHandoffPassword,
  topicId: 'h_yeni',
);

/// "Mevcut cihaz" kipinde (pano değişimi / acil sıfırlama sonrası) 5. adımdan başlayan denetleyici.
ServiceSetupController handoffController(ServiceHarness env, {DeviceMqttCredential? credential}) {
  final c = ServiceSetupController(
    state: env.state,
    access: env.access,
    store: env.store,
    deviceApiFactory: env.deviceFactory,
    existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5'),
    startStep: SetupSteps.wifi,
    initialCredential: credential,
  );
  addTearDown(c.dispose);
  return c;
}

/// 5. adımı (kurulum ağında, anahtarsız) tamamlayıp 6. adımda (ev ağı, internet var) döner.
Future<void> reachCloudStep(ServiceHarness env, ServiceSetupController c) async {
  c.start();
  await waitUntil(env, () => c.currentStep == SetupSteps.wifi);
  env.phoneOnSetupNetwork();
  expect(await drive(env, c.wifi.checkDevice()), isTrue);
  expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
  c.continueNext();
  env.phoneOnHomeNetwork();
  expect(c.currentStep, SetupSteps.cloud);
}

void main() {
  group('acil sıfırlama / pano değişimi sonrası sihirbaz: tek seferlik bulut kimliği', () {
    test('yanıttaki kimlik 6. adımda panoya yazılır; sunucudan yenisi ÜRETİLMEZ ve hiçbir yere kaydedilmez', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed(); // sunucuda claim edilmiş ev; pano henüz çevrimdışı
      final c = handoffController(env, credential: kHandoffCredential);
      await reachCloudStep(env, c);
      expect(c.ctx.pendingCredential, isNotNull, reason: 'kimlik 5. adım boyunca bellekte bekler');

      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.device.receivedMqttPass, kHandoffPassword, reason: 'panoya yanıttaki kimlik yazıldı');
      expect(env.device.receivedMqttUser, 'd_h_yeni');
      expect(env.cloud.calls.where((call) => call.startsWith('reissueDeviceMqttCredential')), isEmpty,
          reason: 'yeni kimlik zaten elde: sunucudan yeniden üretilmez');
      expect(c.ctx.pendingCredential, isNull, reason: 'panoya yazıldıktan sonra bellekten bırakılır');

      // Hiçbir kalıcı depoda yok.
      expect(await dumpPrefs(), isNot(contains(kHandoffPassword)));
      expect(env.dumpSecureStore(), isNot(contains(kHandoffPassword)));
    });

    test('kimlik verilmezse (ör. uygulama kapanıp açıldı) 6. adım sunucudan yenisini üretir', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed();
      final c = handoffController(env);
      await reachCloudStep(env, c);
      expect(c.ctx.pendingCredential, isNull);

      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.cloud.calls.where((call) => call.startsWith('reissueDeviceMqttCredential')), hasLength(1));
      expect(env.device.receivedMqttPass, isNot(kHandoffPassword));
    });

    test('denetleyici atılınca bekleyen kimlik bellekten silinir', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed();
      final c = handoffController(env, credential: kHandoffCredential);
      expect(c.ctx.pendingCredential, isNotNull);
      c.dispose();
      expect(c.ctx.pendingCredential, isNull);
    });
  });
}
