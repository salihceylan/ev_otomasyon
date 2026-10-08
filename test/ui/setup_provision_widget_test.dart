import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_setup_wifi_step_widget_test.dart' show openAtStep;
import 'f_support.dart';
import 'f_widget_support.dart';

/// servis_kurulum-1 / -7 arayüzü: Ethernet'le ev ağındaki hazırlanmamış pano 5. adımda Ethernet adresinden hazırlanır;
/// tamamlanmış ağ adımı "Ağ bağlantısını yeniden kur" ile baştan yapılabilir.
void main() {
  const ethIp = '192.168.1.77';

  testWidgets('Ethernet + hazırlanmamış pano: hazırlık kartı (anahtar otomatik), Panoyu Hazırla Ethernet adresine yazar',
      (tester) async {
    final env = await serviceHarness(provisioned: false, flush: () async {});
    addTearDown(env.dispose);
    env.cloud.seedClaimed();
    env.device
      ..ethConnected = true
      ..ethIp = ethIp;
    env.phoneOnHomeNetwork();
    await openAtStep(tester, env);

    await tapKey(tester, 'check_ethernet_mode');
    await pumpUntil(tester, env, () => present('wifi_ethernet_card'));
    await typeKey(tester, 'field_eth_ip', ethIp);
    await tapKey(tester, 'btn_confirm_ethernet');
    await pumpUntil(tester, env, () => present('wifi_provision_card'));
    expect(present('wifi_connected_card'), isFalse, reason: 'hazırlanmamış pano adımı tamamlamaz');
    expect(present('wifi_provision_key_auto'), isTrue);
    expect(buttonEnabled(tester, 'btn_factory_init'), isTrue);

    await typeKey(tester, 'field_ap_pass', kApPass);
    await tapKey(tester, 'btn_factory_init');
    await pumpUntil(tester, env, () => present('wifi_connected_ethernet'));
    expect(env.device.factoryInitHosts.single, ethIp);
    expect(env.device.provisioned, isTrue);

    // servis_kurulum-7: ağ adımı baştan yapılabilir.
    await tapKey(tester, 'btn_restart_network_setup');
    await pumpUntil(tester, env, () => !present('wifi_connected_card'));
    expect(present('setup_step_${SetupSteps.wifi}'), isTrue);
  });
}
