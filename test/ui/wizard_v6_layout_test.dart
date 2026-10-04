import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// WP-V6 sihirbaz yerleşim taraması: yeni orb/halka bileşenli durumlar (panjur ölçüm kronometresi, ölçülen/kayıtlı süre,
/// duvar butonu algılama, bulut bekleme, teslim kutlaması, geçici oturum bandı) küçük ekran (320x568, 360x640) ve büyük
/// yazı (2.0x) ile taşma ya da çizim istisnası olmadan açılır; eylem düğmeleri erişilebilir kalır.

Future<void> _open(
  WidgetTester tester,
  ServiceHarness env,
  int step,
  Size size,
  double textScale, {
  bool fresh = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await pumpLauncher(tester, env, (context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          existingTarget: fresh
              ? null
              : ServiceTarget(
                  homeId: kClaimedHome,
                  deviceUuid: kDeviceUid,
                  homeName: 'Daire 5',
                  ip: step == SetupSteps.wifi ? '' : kLanIp,
                ),
          startStep: fresh ? null : step,
          store: env.store,
          deviceApiFactory: env.deviceFactory,
          scanner: fakeScanner(kWifiQr),
        ),
      ),
    );
  }, size: size);
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 25);
  await pumpUntil(tester, env, () => present('setup_step_$step'), reason: 'adım $step açılmadı');
}

Future<ServiceHarness> _deployed({String role = 'staff'}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.seedClaimed(online: true);
  env.device
    ..wifiConnected = true
    ..staIp = kLanIp
    ..mqttConfigured = true
    ..mqttConnected = true;
  return env;
}

void main() {
  for (final config in <({Size size, double scale})>[
    (size: const Size(320, 568), scale: 2.0),
    (size: const Size(360, 640), scale: 2.0),
  ]) {
    group('WP-V6 yerleşim ${config.size.width.toInt()}x${config.size.height.toInt()}, yazı ${config.scale}x', () {
      testWidgets('8. adım: panjur ölçümü (kronometre halkası) -> ölçülen süre (±) -> kayıtlı süre taşmaz', (
        tester,
      ) async {
        final env = await _deployed();
        addTearDown(env.dispose);
        await _open(tester, env, SetupSteps.shutters, config.size, config.scale);
        await pumpUntil(tester, env, () => present('card_shutter_1'));
        await tapKey(tester, 'btn_shutter_up_1');
        await pumpUntil(tester, env, () => present('btn_dir_ok_1'));
        await tapKey(tester, 'btn_dir_ok_1');
        expect(tester.takeException(), isNull, reason: 'yön testi (orb düğmeleri + mini panjur)');
        await tapKey(tester, 'btn_prepare_1');
        await pumpUntil(tester, env, () => present('btn_to_bottom_1'));
        await tapKey(tester, 'btn_to_bottom_1');
        await pumpUntil(tester, env, () => env.device.shutterMoving(1));
        await tapKey(tester, 'btn_at_bottom_1');
        await pumpUntil(tester, env, () => present('btn_start_measure_1'));
        await tapKey(tester, 'btn_start_measure_1');
        await pumpUntil(tester, env, () => present('btn_finish_measure_1'));
        env.clock.advance(const Duration(seconds: 24));
        await tester.pump();
        expect(find.byKey(const Key('shutter_stopwatch_1')), findsOneWidget, reason: 'canlı sayaç');
        expect(tester.takeException(), isNull, reason: 'ölçüm sürerken (kronometre halkası)');
        await tapKey(tester, 'btn_finish_measure_1');
        await pumpUntil(tester, env, () => present('btn_save_runtime_1'));
        expect(find.byKey(const Key('shutter_measured_1')), findsOneWidget);
        expect(find.byKey(const Key('btn_sec_minus_1')), findsOneWidget);
        expect(find.byKey(const Key('btn_sec_plus_1')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'ölçülen süre (± düğmeleri)');
        await tapKey(tester, 'btn_save_runtime_1');
        await pumpUntil(tester, env, () => present('btn_remeasure_1'));
        expect(tester.takeException(), isNull, reason: 'kayıtlı süre');
      });

      testWidgets('9. adım: dinleme, yakalanan giriş (✓ + nabız), basılı giriş ve "buton yok" taşmaz', (tester) async {
        final env = await _deployed();
        addTearDown(env.dispose);
        await _open(tester, env, SetupSteps.buttons, config.size, config.scale);
        await pumpUntil(tester, env, () => present('btn_listen_toggle'));
        await tapKey(tester, 'btn_listen_toggle');
        await pumpUntil(tester, env, () => find.text('Dinlemeyi Durdur').evaluate().isNotEmpty);
        expect(tester.takeException(), isNull, reason: 'dinleniyor');
        env.device.setDi(1, true);
        await pumpUntil(
          tester,
          env,
          () => find
              .descendant(of: find.byKey(const Key('card_button_1')), matching: find.text('Algılandı'))
              .evaluate()
              .isNotEmpty,
        );
        expect(tester.takeException(), isNull, reason: 'yakalandı (basılı)');
        await tapKey(tester, 'btn_button_none_3');
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '"buton yok" işaretli giriş');
      });

      testWidgets('6. adım: bulut bekleme kartı (dönen yay + geri sayım) ve çevrimiçi kartı taşmaz', (tester) async {
        final env = await _deployed();
        addTearDown(env.dispose);
        env.cloud.deviceOnline = false;
        env.device
          ..mqttConfigured = false
          ..mqttConnected = false
          ..onMqttConfigured = (server, port, user, pass) {};
        await _open(tester, env, SetupSteps.cloud, config.size, config.scale);
        await tapKey(tester, 'btn_cloud_connect');
        await pumpUntil(tester, env, () => present('cloud_waiting_card'));
        expect(find.byKey(const Key('cloud_waiting_countdown')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'bekleniyor');
      });

      testWidgets('10. adım: teslim özeti (kontrol listesi, not alanları) taşmaz', (tester) async {
        final env = await _deployed();
        addTearDown(env.dispose);
        await _open(tester, env, SetupSteps.handover, config.size, config.scale);
        await pumpUntil(tester, env, () => present('handover_checklist'));
        expect(tester.takeException(), isNull, reason: 'özet');
        expect(find.byKey(const Key('handover_celebration')), findsNothing, reason: 'başarıdan önce kutlama yok');
      });

      testWidgets('geçici servis oturumu bandı (kalan süre halkası) 1. adımda taşmaz', (tester) async {
        final env = await _deployed(role: 'pin');
        addTearDown(env.dispose);
        await _open(tester, env, SetupSteps.preparation, config.size, config.scale, fresh: true);
        expect(find.byKey(const Key('service_session_banner')), findsOneWidget);
        expect(find.byKey(const Key('service_session_text')), findsOneWidget);
        expect(tester.takeException(), isNull);
        // 2 dakikadan az kalınca uyarı rengi + canlı bölge.
        env.clock.advance(const Duration(hours: 1, minutes: 59));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });
    });
  }

  // WP-FX-D: hata/ilk ekranlarda TEK gradyan birincil eylem (2. tur eleştirmen bulgusu: e07/e08/e09 ve 6. adım ilk ekranında
  // 2-3 eş ağırlıklı gradyan hap; asıl kurtarma eylemi belli değildi). Etkin gradyan hap = etkin `ElevatedButton`
  // (alt çubuğun pasif "Devam"ı sayılmaz: `onPressed == null`).
  group('WP-FX-D tek gradyan birincil eylem (360x800, 1.0x)', () {
    const phone = Size(360, 800);

    int enabledGradientButtons(WidgetTester tester) =>
        tester.widgetList<ElevatedButton>(find.byType(ElevatedButton)).where((b) => b.onPressed != null).length;

    Finder inside(String key, Type type) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(type));

    testWidgets('6. adım ilk ekran: "Buluta Bağla ve Bekle" gradyan birincil; "Panoya Bağlan" çerçeveli ikincil', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      env.cloud.deviceOnline = false;
      env.device
        ..mqttConfigured = false
        ..mqttConnected = false;
      await _open(tester, env, SetupSteps.cloud, phone, 1.0);
      expect(present('device_connection_panel'), isTrue, reason: 'bağlantı paneli görünür');
      expect(inside('btn_connect_device', OutlinedButton), findsOneWidget);
      expect(inside('btn_connect_device', ElevatedButton), findsNothing);
      expect(inside('btn_cloud_connect', ElevatedButton), findsOneWidget);
      expect(enabledGradientButtons(tester), 1, reason: 'ekranda tek etkin gradyan hap');
    });

    testWidgets('7. adım pano ulaşılmaz (e07): "Panoya Bağlan" gradyan birincil; "Tekrar dene" çerçeveli', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      await _open(tester, env, SetupSteps.relays, phone, 1.0);
      await pumpUntil(tester, env, () => present('card_relay_5'));
      env.device.lanReachable = false;
      await tapKey(tester, 'btn_relay_on_5');
      await pumpUntil(tester, env, () => present('setup_retry') || present('device_connection_panel'));
      await settle(tester);
      expect(inside('btn_connect_device', ElevatedButton), findsOneWidget);
      for (final retry in find.byKey(const Key('setup_retry')).evaluate()) {
        expect(retry.widget, isA<OutlinedButton>(), reason: 'her "Tekrar dene" çerçeveli ikincil');
      }
      expect(enabledGradientButtons(tester), 1, reason: 'ekranda tek etkin gradyan hap ("Panoya Bağlan")');
    });

    testWidgets('9. adım pano ulaşılmaz (e09): dinleme düğmesi de çerçeveli; tek gradyan "Panoya Bağlan"', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      await _open(tester, env, SetupSteps.buttons, phone, 1.0);
      await pumpUntil(tester, env, () => present('btn_listen_toggle'));
      env.device.lanReachable = false;
      await tapKey(tester, 'btn_listen_toggle');
      await pumpUntil(tester, env, () => present('setup_retry') || present('device_connection_panel'));
      await settle(tester);
      expect(present('device_connection_panel'), isTrue);
      expect(inside('btn_listen_toggle', ElevatedButton), findsNothing, reason: 'bağlantı yokken dinleme gradyan birincil değil');
      expect(inside('btn_listen_toggle', OutlinedButton), findsOneWidget);
      expect(enabledGradientButtons(tester), 1, reason: 'ekranda tek etkin gradyan hap ("Panoya Bağlan")');
    });

    testWidgets('9. adım tüm girişler algılandı: "Dinlemeyi Durdur" çerçeveli rose; tek gradyan alt çubuktaki "Devam"', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      await _open(tester, env, SetupSteps.buttons, phone, 1.0);
      await pumpUntil(tester, env, () => present('btn_listen_toggle'));
      // Dinleme sürerken (henüz hiçbir giriş algılanmadı) "Dinlemeyi Durdur" tek gradyan birincildir.
      await tapKey(tester, 'btn_listen_toggle');
      await pumpUntil(tester, env, () => find.text('Dinlemeyi Durdur').evaluate().isNotEmpty);
      expect(inside('btn_listen_toggle', ElevatedButton), findsOneWidget);
      for (var id = 1; id <= 4; id++) {
        env.device.setDi(id, true);
        await pumpUntil(
          tester,
          env,
          () => find
              .descendant(of: find.byKey(Key('card_button_$id')), matching: find.text('Algılandı'))
              .evaluate()
              .isNotEmpty,
        );
        env.device.setDi(id, false);
        env.clock.advance(const Duration(milliseconds: 400));
        await tester.pump();
      }
      await settle(tester);
      expect(find.text('Dinlemeyi Durdur'), findsOneWidget);
      expect(inside('btn_listen_toggle', ElevatedButton), findsNothing);
      expect(inside('btn_listen_toggle', OutlinedButton), findsOneWidget);
      expect(continueEnabled(tester), isTrue, reason: '"Devam" etkin');
      expect(enabledGradientButtons(tester), 1, reason: 'yalnız "Devam" gradyan');
    });
  });

  testWidgets(
    '10 adım tam akış (sahte sunucu + pano): 360x640, 2.0x yazıda taşmadan tamamlanır; teslim kutlaması görünür',
    (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env, size: const Size(360, 640), textScale: 2.0);
      expect(find.byKey(const Key('setup_step_strip')), findsOneWidget);

      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      await goNext(tester, env);
      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => present('step2_accepted_card'));
      await goNext(tester, env);
      await typeKey(tester, 'field_customer', kCustomerEmail);
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => present('field_otp'));
      await typeKey(tester, 'field_otp', kCustomerOtp);
      await goNext(tester, env);
      await typeKey(tester, 'field_home_name', 'Daire 5');
      await tapKey(tester, 'btn_claim');
      await tester.pump(const Duration(milliseconds: 300));
      await tapKey(tester, 'btn_claim_confirm');
      await pumpUntil(tester, env, () => present('claim_result_card'));
      expect(tester.takeException(), isNull, reason: '4. adım sonucu');
      await goNext(tester, env);

      env.phoneOnSetupNetwork();
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_provision_panel'));
      await pumpUntil(tester, env, () => present('wifi_network_list'));
      await tapKey(tester, 'btn_wifi_scan_qr');
      await pumpUntil(
        tester,
        env,
        () => tester.widget<TextField>(find.byKey(const Key('field_wifi_ssid'))).controller!.text == kHomeWifiSsid,
      );
      await tapKey(tester, 'btn_wifi_submit');
      await pumpUntil(tester, env, () => present('wifi_connected_card'));
      expect(tester.takeException(), isNull, reason: '5. adım sonucu');
      env.phoneOnHomeNetwork();
      await goNext(tester, env);

      await tapKey(tester, 'btn_cloud_connect');
      await pumpUntil(tester, env, () => present('cloud_online_card'));
      await goNext(tester, env);

      await pumpUntil(tester, env, () => present('card_relay_5'));
      for (final id in <int>[5, 6, 7, 8]) {
        await tapKey(tester, 'btn_relay_on_$id');
        await pumpUntil(tester, env, () => present('btn_relay_lit_yes_$id'));
        await tapKey(tester, 'btn_relay_lit_yes_$id');
        await tapKey(tester, 'btn_relay_off_$id');
        await pumpUntil(tester, env, () => !env.device.relayState(id));
      }
      await pumpUntil(tester, env, () => find.textContaining('4 doğrulandı').evaluate().isNotEmpty);
      await goNext(tester, env);

      await pumpUntil(tester, env, () => present('card_shutter_1'));
      for (final pair in <int>[1, 2]) {
        await tapKey(tester, 'btn_shutter_up_$pair');
        await pumpUntil(tester, env, () => present('btn_dir_ok_$pair'));
        await tapKey(tester, 'btn_dir_ok_$pair');
        await tapKey(tester, 'btn_shutter_stop_$pair');
        await pumpUntil(tester, env, () => !env.device.shutterMoving(pair));
        await tapKey(tester, 'btn_prepare_$pair');
        await pumpUntil(tester, env, () => present('btn_to_bottom_$pair'));
        await tapKey(tester, 'btn_to_bottom_$pair');
        await pumpUntil(tester, env, () => env.device.shutterMoving(pair));
        await tapKey(tester, 'btn_at_bottom_$pair');
        await pumpUntil(tester, env, () => present('btn_start_measure_$pair'));
        await tapKey(tester, 'btn_start_measure_$pair');
        await pumpUntil(tester, env, () => present('btn_finish_measure_$pair'));
        env.clock.advance(Duration(seconds: 18 + pair * 6));
        await tester.pump();
        await tapKey(tester, 'btn_finish_measure_$pair');
        await pumpUntil(tester, env, () => present('btn_save_runtime_$pair'));
        await tapKey(tester, 'btn_save_runtime_$pair');
        await pumpUntil(tester, env, () => present('btn_remeasure_$pair'));
      }
      await goNext(tester, env);

      await pumpUntil(tester, env, () => present('btn_listen_toggle'));
      await tapKey(tester, 'btn_listen_toggle');
      await pumpUntil(tester, env, () => find.text('Dinlemeyi Durdur').evaluate().isNotEmpty);
      for (var id = 1; id <= 4; id++) {
        env.device.setDi(id, true);
        await pumpUntil(
          tester,
          env,
          () => find
              .descendant(of: find.byKey(Key('card_button_$id')), matching: find.text('Algılandı'))
              .evaluate()
              .isNotEmpty,
        );
        env.device.setDi(id, false);
        env.clock.advance(const Duration(milliseconds: 400));
        await tester.pump();
      }
      await goNext(tester, env);

      await pumpUntil(tester, env, () => present('handover_checklist'));
      await pumpUntil(tester, env, () => env.cloud.calls.where((c) => c.startsWith('devices:')).length >= 2);
      await tapKey(tester, 'chk_owner_approved');
      await tester.pump();
      await tapKey(tester, 'btn_commission');
      await pumpUntil(tester, env, () => present('handover_success_card'));
      expect(find.byKey(const Key('handover_celebration')), findsOneWidget, reason: 'başarıda tek seferlik kutlama');
      expect(tester.takeException(), isNull, reason: 'teslim başarısı (kutlama + rapor)');
    },
  );
}
