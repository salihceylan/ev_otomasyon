import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis kurulum sihirbazı yerleşim taraması: küçük ekran (320x568 ve 360x640) ve büyük yazı (2.0x) ile 5-10.
/// adımlar taşma ya da çizim istisnası olmadan açılır; "Devam" düğmesi ve adım gövdesi erişilebilir kalır.

Future<void> openSweep(WidgetTester tester, ServiceHarness env, int step, Size size, double textScale) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await pumpLauncher(
    tester,
    env,
    (context) async {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ServiceSetupWizardPage(
            existingTarget: ServiceTarget(
              homeId: kClaimedHome,
              deviceUuid: kDeviceUid,
              homeName: 'Daire 5',
              ip: step == SetupSteps.wifi ? '' : kLanIp,
            ),
            startStep: step,
            store: env.store,
            deviceApiFactory: env.deviceFactory,
            scanner: fakeScanner(kWifiQr),
          ),
        ),
      );
    },
    size: size,
  );
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 25);
  await pumpUntil(tester, env, () => present('setup_step_$step'), reason: 'adım $step açılmadı');
}

void main() {
  for (final config in <({Size size, double scale})>[
    (size: const Size(320, 568), scale: 2.0),
    (size: const Size(360, 640), scale: 1.5),
  ]) {
    group('yerleşim taraması ${config.size.width.toInt()}x${config.size.height.toInt()}, yazı ${config.scale}x', () {
      Future<ServiceHarness> deployed() async {
        final env = await serviceHarness(flush: () async {});
        env.cloud.seedClaimed(online: true);
        env.device
          ..wifiConnected = true
          ..staIp = kLanIp
          ..mqttConfigured = true
          ..mqttConnected = true;
        return env;
      }

      testWidgets('1-4. adımlar (hazırlık, cihazı tanı, müşteri + kod, claim özeti ve sonucu) taşmaz', (tester) async {
        final env = await serviceHarness(inventoryListed: true, flush: () async {});
        addTearDown(env.dispose);
        await openWizard(tester, env, size: config.size, textScale: config.scale);
        expect(tester.takeException(), isNull);
        await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
        expect(tester.takeException(), isNull);
        await goNext(tester, env);

        expect(present('setup_step_2'), isTrue);
        await tapKey(tester, 'btn_scan_label');
        await pumpUntil(tester, env, () => present('step2_accepted_card'));
        expect(tester.takeException(), isNull);
        await goNext(tester, env);

        expect(present('setup_step_3'), isTrue);
        await typeKey(tester, 'field_customer', kCustomerEmail);
        await tapKey(tester, 'btn_send_otp');
        await pumpUntil(tester, env, () => present('field_otp'));
        await typeKey(tester, 'field_otp', kCustomerOtp);
        expect(tester.takeException(), isNull);
        await goNext(tester, env);

        expect(present('setup_step_4'), isTrue);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'btn_claim');
        await tester.pump(const Duration(milliseconds: 300));
        await tapKey(tester, 'btn_claim_confirm');
        await pumpUntil(tester, env, () => present('claim_result_card'));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('setup_continue')), findsOneWidget);
      });

      for (final role in <String>['staff', 'pin', 'super']) {
        testWidgets('servis paneli ($role oturumu): kartlar, Wi-Fi kartı, devam eden kurulumlar ve araçlar taşmaz', (tester) async {
          final env = await serviceHarness(role: role, flush: () async {});
          addTearDown(env.dispose);
          await pumpPage(
            tester,
            env,
            ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
            size: config.size,
            textScale: config.scale,
          );
          await settle(tester, frames: 20);
          expect(tester.takeException(), isNull);
          // Liste tembeldir: Wi-Fi kartına kaydırarak ulaşılır, listenin sonuna kadar inilir.
          await tester.scrollUntilVisible(find.byKey(const Key('card_wifi_setup')), 300,
              scrollable: find.descendant(of: find.byKey(const Key('service_panel')), matching: find.byType(Scrollable)).first);
          expect(present('card_wifi_setup'), isTrue);
          await tester.drag(find.byKey(const Key('service_panel')), const Offset(0, -3000));
          await settle(tester, frames: 10);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('servis paneli (oturumsuz): PIN girişi ve Wi-Fi kartı taşmaz', (tester) async {
        final env = await serviceHarness(flush: () async {});
        addTearDown(env.dispose);
        await env.state.logout();
        await pumpPage(
          tester,
          env,
          ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
          size: config.size,
          textScale: config.scale,
        );
        await settle(tester, frames: 20);
        expect(tester.takeException(), isNull);
        expect(present('card_wifi_setup'), isTrue);
      });

      testWidgets('5. adım: kurulum ağı yönergesi, Wi-Fi bileşeni ve hata kutusu taşmaz', (tester) async {
        final env = await deployed();
        addTearDown(env.dispose);
        env.phoneOnSetupNetwork();
        await openSweep(tester, env, SetupSteps.wifi, config.size, config.scale);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'btn_check_device');
        await pumpUntil(tester, env, () => present('wifi_network_list'));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('setup_continue')), findsOneWidget);
      });

      testWidgets('5. adım: hazırlanmamış pano (ilk hazırlık kartı, anahtar yok açıklaması) taşmaz', (tester) async {
        final env = await serviceHarness(provisioned: false, flush: () async {});
        addTearDown(env.dispose);
        env.device.apSecured = false;
        env.cloud.seedClaimed();
        env.phoneOnSetupNetwork();
        await openSweep(tester, env, SetupSteps.wifi, config.size, config.scale);
        await tapKey(tester, 'btn_check_device');
        await pumpUntil(tester, env, () => present('wifi_provision_card'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('6. adım: ev Wi-Fi yönergesi, pano bağlantı paneli ve çevrimiçi kartı taşmaz', (tester) async {
        final env = await deployed();
        addTearDown(env.dispose);
        await openSweep(tester, env, SetupSteps.cloud, config.size, config.scale);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'btn_cloud_connect');
        await pumpUntil(tester, env, () => present('cloud_online_card'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('7. adım: röle kartları (darbe rölesi teyidi dahil) taşmaz', (tester) async {
        final env = await deployed();
        addTearDown(env.dispose);
        env.device.relays.add(SimRelay(9, 'Kapı Zili', 3));
        await openSweep(tester, env, SetupSteps.relays, config.size, config.scale);
        await pumpUntil(tester, env, () => present('card_relay_9'));
        await tapKey(tester, 'btn_relay_on_9');
        await pumpUntil(tester, env, () => present('btn_relay_lit_yes_9'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('8. adım: panjur kartları ve ölçüm bölümü taşmaz', (tester) async {
        final env = await deployed();
        addTearDown(env.dispose);
        await openSweep(tester, env, SetupSteps.shutters, config.size, config.scale);
        await pumpUntil(tester, env, () => present('card_shutter_1'));
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'btn_shutter_up_1');
        await pumpUntil(tester, env, () => present('btn_dir_ok_1'));
        await tapKey(tester, 'btn_dir_ok_1');
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('9. adım: duvar butonu kartları taşmaz', (tester) async {
        final env = await deployed();
        addTearDown(env.dispose);
        await openSweep(tester, env, SetupSteps.buttons, config.size, config.scale);
        await pumpUntil(tester, env, () => present('btn_listen_toggle'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('10. adım: teslim özeti taşmaz', (tester) async {
        final env = await deployed();
        addTearDown(env.dispose);
        await openSweep(tester, env, SetupSteps.handover, config.size, config.scale);
        await pumpUntil(tester, env, () => present('handover_checklist'));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
