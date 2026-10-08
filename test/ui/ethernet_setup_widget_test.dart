import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// 5. adım Ethernet kartı ("Pano kabloyla (Ethernet) bağlı"): seçilince kurulum ağı / Wi-Fi kartları gizlenir, Ethernet IP
/// ile doğrulanır; küçük ekran + büyük yazıda taşmaz.
const String _ethIp = '192.168.1.77';

Future<void> _open(WidgetTester tester, ServiceHarness env, Size size, double scale) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await pumpLauncher(tester, env, (context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5'),
          startStep: SetupSteps.wifi,
          store: env.store,
          deviceApiFactory: env.deviceFactory,
          scanner: fakeScanner(null),
        ),
      ),
    );
  }, size: size);
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 25);
  await pumpUntil(tester, env, () => present('setup_step_${SetupSteps.wifi}'), reason: '5. adım açılmadı');
}

Future<ServiceHarness> _ethernetBoard() async {
  final env = await serviceHarness(flush: () async {});
  env.cloud.seedClaimed(online: true);
  env.device
    ..wifiConnected = false
    ..staIp = ''
    ..ethConnected = true
    ..ethIp = _ethIp;
  env.phoneOnHomeNetwork();
  return env;
}

bool _has(String key) => find.byKey(Key(key), skipOffstage: false).evaluate().isNotEmpty;

void main() {
  testWidgets('Ethernet seçimi Wi-Fi kartlarını gizler; kapatılınca Wi-Fi akışı aynen döner', (tester) async {
    final env = await _ethernetBoard();
    addTearDown(env.dispose);
    await _open(tester, env, const Size(900, 2400), 1.0);
    expect(_has('wifi_ethernet_choice'), isTrue);
    expect(_has('wifi_connect_card'), isTrue);
    await tapKey(tester, 'check_ethernet_mode');
    await settle(tester);
    expect(_has('wifi_ethernet_card'), isTrue);
    expect(_has('wifi_connect_card'), isFalse);
    expect(_has('btn_toggle_lan'), isFalse);
    await tapKey(tester, 'check_ethernet_mode');
    await settle(tester);
    expect(_has('wifi_ethernet_card'), isFalse);
    expect(_has('wifi_connect_card'), isTrue);
  });

  for (final config in <({Size size, double scale})>[
    (size: const Size(360, 640), scale: 2.0),
    (size: const Size(320, 568), scale: 2.0),
  ]) {
    testWidgets(
        'yerleşim ${config.size.width.toInt()}x${config.size.height.toInt()} yazı ${config.scale}x: Ethernet kartı, '
        'hata ve "Ethernet ile bağlı" taşmaz', (tester) async {
      final env = await _ethernetBoard();
      addTearDown(env.dispose);
      await _open(tester, env, config.size, config.scale);
      await tapKey(tester, 'check_ethernet_mode');
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'Ethernet kartı');

      // Yanlış adres (pano yok): hata kutusu.
      await typeKey(tester, 'field_eth_ip', '192.168.1.99');
      await tapKey(tester, 'btn_confirm_ethernet');
      await pumpUntil(tester, env, () => _has('setup_retry'));
      expect(tester.takeException(), isNull, reason: 'hata');

      await typeKey(tester, 'field_eth_ip', _ethIp);
      await tapKey(tester, 'btn_confirm_ethernet');
      await pumpUntil(tester, env, () => _has('wifi_connected_ethernet'));
      expect(find.textContaining('Ethernet ile bağlı (IP: $_ethIp)', skipOffstage: false), findsOneWidget);
      expect(_has('wifi_return_home_notice'), isFalse);
      expect(continueEnabled(tester), isTrue);
      expect(tester.takeException(), isNull, reason: 'Ethernet ile bağlı');
    });
  }
}
