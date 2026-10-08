import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// Ethernet'li pano (firmware v1.3.0: `eth_connected`, `eth_ip`, `net_if`; kablolu IP'ye gelen istek anahtarsız
/// yetkili): "ev ağında" = Wi-Fi YA DA Ethernet. 5. adımda Ethernet yolu, 6. adım teşhisi ve teslim ağ satırı.
void main() {
  late ServiceHarness env;
  late ServiceSetupController c;

  const ethIp = '192.168.1.77';

  /// Claim sonrası 5. adım; pano yalnız kabloyla ev ağında (Wi-Fi yok, kurulum ağı kapalı), telefon ev ağında.
  Future<void> atWifiStepOnEthernet() async {
    env = await serviceHarness();
    c = await completeClaim(env);
    env.device
      ..wifiConnected = false
      ..staIp = ''
      ..ethConnected = true
      ..ethIp = ethIp;
    env.phoneOnHomeNetwork();
  }

  tearDown(() => env.dispose());

  test('5. adım Ethernet yolu: Ethernet IP\'sinden doğrulanır, adım tamamlanır, kayıt "eth" taşır', () async {
    await atWifiStepOnEthernet();
    expect(c.wifi.ethernetMode, isFalse);
    c.wifi.setEthernetMode(true);
    expect(await drive(env, c.wifi.confirmEthernet(ethIp)), isTrue);
    expect(c.wifi.isComplete, isTrue);
    expect(c.wifi.viaEthernet, isTrue);
    expect(c.target!.ip, ethIp);
    expect(c.wifi.snapshot()['eth'], isTrue);
    expect(c.canContinue, isTrue);
    expect(env.device.keylessWifiCalls + env.device.keyedWifiCalls, 0, reason: 'Wi-Fi bilgisi gönderilmedi');
  });

  test('"Pano zaten ev ağında: IP ile bağlan" Ethernet panoda da başarılı (eskiden "Wi-Fi\'ye bağlı görünmüyor")',
      () async {
    await atWifiStepOnEthernet();
    expect(await drive(env, c.wifi.confirmLanIp(ethIp)), isTrue);
    expect(c.wifi.isComplete, isTrue);
    expect(c.wifi.viaEthernet, isTrue);
  });

  test('Ethernet bildirmeyen panoda (Wi-Fi\'li, eski yazılım) Ethernet yolu açıklamayla reddedilir', () async {
    env = await serviceHarness();
    c = await completeClaim(env);
    env.device
      ..wifiConnected = true
      ..staIp = kLanIp;
    env.phoneOnHomeNetwork();
    c.wifi.setEthernetMode(true);
    expect(await drive(env, c.wifi.confirmEthernet(kLanIp)), isFalse);
    expect(c.wifi.problem?.title, 'Pano Ethernet bağlantısı bildirmiyor');
    expect(c.wifi.isComplete, isFalse);
    expect(env.device.wrongKeyTotal, 0, reason: 'yanlış anahtar denemesi yapılmadı');
  });

  test('restore: Ethernet ile tamamlanan adım geri yüklenir', () async {
    await atWifiStepOnEthernet();
    c.wifi.restore(<String, dynamic>{'connected': true, 'eth': true});
    expect(c.wifi.viaEthernet, isTrue);
    expect(c.wifi.ethernetMode, isTrue);
    c.wifi.restore(<String, dynamic>{'connected': true});
    expect(c.wifi.viaEthernet, isFalse);
  });

  test('Ethernet panoyla 6-10: bulut bağlanır, teslim ağ satırı "Ethernet ile bağlı (IP …)"', () async {
    await atWifiStepOnEthernet();
    c.wifi.setEthernetMode(true);
    expect(await drive(env, c.wifi.confirmEthernet(ethIp)), isTrue);
    c.continueNext();
    expect(c.currentStep, SetupSteps.cloud);
    await completeCloud(env, c);
    await completeRelays(env, c);
    await completeShutters(env, c);
    await completeButtons(env, c);
    await waitUntil(env, () => !c.handover.busy);
    final network = c.handover.buildChecks().network;
    expect(network.ok, isTrue);
    expect(network.detail, 'Pano ev ağına Ethernet ile bağlı (IP $ethIp)');
  });

  test('6. adım teşhisi: Ethernet panoya "Wi-Fi\'den düştü" denmez', () async {
    await atWifiStepOnEthernet();
    c.wifi.setEthernetMode(true);
    expect(await drive(env, c.wifi.confirmEthernet(ethIp)), isTrue);
    c.continueNext();
    env.cloud.deviceOnline = false;
    env.device.onMqttConfigured = (server, port, user, pass) {}; // kimlik yazılır ama buluta bağlanamaz
    expect(await drive(env, c.cloud.connectAndWait()), isFalse);
    final problem = c.cloud.problem!;
    expect(problem.title, isNot('Pano ev Wi-Fi ağından düştü'));
    expect(problem.fixStep, isNot(SetupSteps.wifi));
    expect(problem.kind, isNot(SetupProblemKind.deviceNetwork));
  });

  test('Wi-Fi panoda teslim ağ satırı aynen kalır', () async {
    env = await serviceHarness();
    c = await reachStep(env, SetupSteps.handover);
    expect(c.handover.buildChecks().network.detail, startsWith('Pano ev Wi-Fi ağına bağlı'));
  });
}
