import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/button_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/relay_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis kurulum denetleyicisini (WP-F) belirli bir adıma **gerçek sunucu/pano yanıtlarıyla** götüren
/// yardımcılar. Her yardımcı, önceki adımın geçiş koşulunu gerçekten sağlar (hiçbir şey zorlanmaz).

/// Etiket karekodu içeriği (sahte PIN).
const String kLabelQr = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kDeviceUid&pin=$kSetupPin';

/// İkinci (başka) cihazın kimliği ve etiketi.
const String kOtherUid = 'AHBU-S3-B2B2B2';
const String kLabelQrOther = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kOtherUid&pin=$kSetupPin';

/// Denetleyiciyi kurar, başlatır ve 1. adımın sunucu doğrulamasını bekler.
Future<ServiceSetupController> startedController(ServiceHarness env) async {
  final c = env.newController();
  addTearDown(c.dispose);
  c.start();
  await pumpEventQueue();
  expect(c.prep.isComplete, isTrue, reason: 'oturum sunucuda doğrulanmadı');
  return c;
}

/// 1-4. adımları gerçek sunucu yanıtlarıyla (sahte bulut) tamamlar; 5. adımda döner.
Future<ServiceSetupController> completeClaim(ServiceHarness env) async {
  final c = await startedController(env);
  c.continueNext();
  expect(await c.identify.acceptLabel(kLabelQr), isTrue);
  c.continueNext();
  expect(await c.customer.sendCode(kCustomerEmail), isTrue);
  c.customer.setCode(kCustomerOtp);
  c.continueNext();
  expect(await c.claim.claim(homeName: 'Daire 5'), isTrue);
  c.continueNext();
  expect(c.currentStep, SetupSteps.wifi);
  return c;
}

/// Ev Wi-Fi bilgisini E2'nin paylaşılan Wi-Fi bileşeninin ([WifiProvisionPanel]) yaptığı gibi gönderir:
/// kurulum ağı için **anahtarsız** istemciyle `connect` + sonuç bekleme; sonuç mantığa bildirilir.
Future<WifiConnectResult> connectHomeWifi(
  ServiceHarness env,
  ServiceSetupController c, {
  String ssid = kHomeWifiSsid,
  String pass = kHomeWifiPass,
}) async {
  final result = await drive(env, c.wifi.apApi.connectWifiAndWait(ssid, pass));
  c.wifi.acceptWifiResult(result);
  return result;
}

/// 5. adım (telefon kurulum ağında: **internet YOK**, cihaz anahtarı YOK): pano kimliği anahtarsız doğrulanır,
/// ev Wi-Fi bilgisi gönderilir ve bağlandığı görülür; sonra telefon ev ağına döner (internet geri gelir).
Future<void> completeWifi(ServiceHarness env, ServiceSetupController c) async {
  env.phoneOnSetupNetwork();
  expect(await drive(env, c.wifi.checkDevice()), isTrue);
  expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
  expect(c.wifi.connected, isTrue);
  c.continueNext();
  expect(c.currentStep, SetupSteps.cloud);
  env.phoneOnHomeNetwork();
}

/// 6. adım: bulut kimliği yazılır, pano sunucuda çevrimiçi olur.
Future<void> completeCloud(ServiceHarness env, ServiceSetupController c) async {
  expect(await drive(env, c.cloud.connectAndWait()), isTrue);
  c.continueNext();
  expect(c.currentStep, SetupSteps.relays);
}

/// 5-6. adımları tamamlar (claim sonrası).
Future<void> completeNetwork(ServiceHarness env, ServiceSetupController c) async {
  await completeWifi(env, c);
  await completeCloud(env, c);
}

/// 7. adım: her röle açılıp kapatılır, yük çalıştı onayı verilir.
Future<void> completeRelays(ServiceHarness env, ServiceSetupController c) async {
  await waitUntil(env, () => c.relays.loaded && !c.isBusy);
  for (final r in List<RelayCheck>.of(c.relays.relays)) {
    expect(await drive(env, c.relays.command(r.id, true)), isTrue);
    c.relays.confirmLit(r.id, true);
    expect(await drive(env, c.relays.command(r.id, false)), isTrue);
  }
  expect(c.relays.isComplete, isTrue);
  c.continueNext();
  expect(c.currentStep, SetupSteps.shutters);
}

/// 8. adım: yön + süre ölçümü + kayıt (pano geri okumasıyla doğrulanır) her panjur için.
Future<void> completeShutter(ServiceHarness env, ServiceSetupController c, int pair, {int seconds = 24}) async {
  expect(await drive(env, c.shutters.move(pair, 'up')), isTrue);
  c.shutters.confirmDirection(pair, wentUp: true);
  expect(await drive(env, c.shutters.move(pair, 'stop')), isTrue);
  expect(await drive(env, c.shutters.prepareMeasure(pair)), isTrue);
  expect(await drive(env, c.shutters.driveToBottom(pair)), isTrue);
  expect(await drive(env, c.shutters.bottomReached(pair)), isTrue);
  expect(await drive(env, c.shutters.startMeasure(pair)), isTrue);
  env.clock.advance(Duration(seconds: seconds));
  expect(await drive(env, c.shutters.finishMeasure(pair)), isTrue);
  expect(await drive(env, c.shutters.saveRuntime(pair)), isTrue);
}

Future<void> completeShutters(ServiceHarness env, ServiceSetupController c) async {
  await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
  for (final s in List<dynamic>.of(c.shutters.shutters)) {
    await completeShutter(env, c, s.pair as int);
  }
  expect(c.shutters.isComplete, isTrue);
  c.continueNext();
  expect(c.currentStep, SetupSteps.buttons);
}

/// 9. adım: dinleme başlar, her giriş için basış görülür.
Future<void> completeButtons(ServiceHarness env, ServiceSetupController c) async {
  await waitUntil(env, () => c.buttons.loaded && !c.isBusy);
  expect(await drive(env, c.buttons.startListening()), isTrue);
  for (final b in List<ButtonCheck>.of(c.buttons.buttons)) {
    env.device.setDi(b.id, true);
    await env.clock.elapse(const Duration(milliseconds: 400));
    env.device.setDi(b.id, false);
    await env.clock.elapse(const Duration(milliseconds: 400));
  }
  expect(c.buttons.isComplete, isTrue);
  c.continueNext();
  expect(c.currentStep, SetupSteps.handover);
}

/// [step] adımına (5..10) gerçek yanıtlarla ulaşır.
Future<ServiceSetupController> reachStep(ServiceHarness env, int step) async {
  final c = await completeClaim(env);
  if (step <= SetupSteps.wifi) return c;
  await completeWifi(env, c);
  if (step <= SetupSteps.cloud) return c;
  await completeCloud(env, c);
  if (step <= SetupSteps.relays) return c;
  await completeRelays(env, c);
  if (step <= SetupSteps.shutters) return c;
  await completeShutters(env, c);
  if (step <= SetupSteps.buttons) return c;
  await completeButtons(env, c);
  await waitUntil(env, () => !c.handover.busy);
  return c;
}

// -----------------------------------------------------------------------------
// Widget testleri: sihirbazı kayıttan devam kipinde belirli bir adımda açma
// -----------------------------------------------------------------------------

/// Sihirbazı **kayıttan devam** kipinde [step] adımında açar (claim edilmiş cihaz; telefon ev Wi-Fi ağında, pano
/// ev ağındaki [kLanIp] adresinde, ev Wi-Fi'sine bağlı ve bulut kimliği yazılı). Başlatıcı sayfa `launcher`
/// anahtarını taşır; sihirbaz kapanınca ona dönülür.
///
/// [data]: kaydın adım verisi (örn. `{'8': {'shutters': {'1': {'dir': true}}}}`: 1. panjurun yönü onaylı).
/// Widget testlerinde `serviceHarness(flush: () async {})` ile kurulan [env] verilir ve `runAsync` KULLANILMAZ.
Future<void> openWizardResumedAt(
  WidgetTester tester,
  ServiceHarness env,
  int step, {
  Map<String, dynamic> data = const <String, dynamic>{},
  Size size = const Size(900, 2800),
}) async {
  env.cloud.seedClaimed();
  env.device
    ..wifiConnected = true
    ..staIp = kLanIp
    ..mqttConfigured = true
    ..mqttConnected = true;
  env.phoneOnHomeNetwork();
  final now = env.clock.now();
  final record = SetupProgressRecord(
    ownerKey: env.access.ownerKey,
    deviceUuid: kDeviceUid,
    homeId: kClaimedHome,
    homeName: 'Daire 5',
    ip: kLanIp,
    currentStep: step,
    data: data,
    createdAt: now,
    updatedAt: now,
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('launcher'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ServiceSetupWizardPage(
                    resume: record,
                    store: env.store,
                    deviceApiFactory: env.deviceFactory,
                    scanner: fakeScanner(null),
                  ),
                )),
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
