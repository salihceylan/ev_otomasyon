@Tags(['visual'])
library;

// Servis kurulum sihirbazı görsel galerisi (WP-V6).
//
//   flutter test --tags visual --update-goldens test/visual/wizard   -> test/visual/wizard/goldens/*.png
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/wizard        -> kayıtlı PNG'lerle karşılaştırır
//
// Gerçek sihirbaz sayfası, sahte sunucu + sahte pano üzerinde 10 adımın tamamında sürülür; her adım için tipik durum,
// başarı ve (ayrı testlerde) hata durumu çizilir. MotionScope(full) + AmbientClock.fixed ile deterministiktir.
// Koyu + açık, yazı ölçeği 1.0 + 1.5, 360 dp telefon genişliği.
//
// Adlandırma: sNN_<durum>  (tipik/başarı/özel durumlar), eNN_<durum> (hata durumları), NN = adım numarası.

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../ui/f_support.dart';
import '../../ui/f_widget_support.dart';
import '../support/golden_support.dart';
import 'wizard_support.dart';

Size _phone(double scale) => Size(360, scale > 1 ? 1400 : 980);

Future<void> _mount(
  WidgetTester tester,
  ServiceHarness env,
  GlobalKey key,
  Brightness brightness,
  double scale, {
  ServiceTarget? existing,
  int? startStep,
  SetupProgressRecord? resume,
  String? scanContent,
  Size? size,
}) async {
  await pumpGallery(
    tester,
    boundaryKey: key,
    brightness: brightness,
    textScale: scale,
    size: size ?? _phone(scale),
    // Üretimdeki GERÇEK devre kartı zemini: sihirbaz Scaffold'u saydamdır (küresel katman görünür); üst şeridin ve alt
    // çubuğun zemin perdesi (scrim) gerçek PCB üstünde değerlendirilir.
    realBackground: true,
    child: ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: ServiceSetupWizardPage(
        key: UniqueKey(),
        existingTarget: existing,
        startStep: startStep,
        resume: resume,
        store: env.store,
        deviceApiFactory: env.deviceFactory,
        scanner:
            (BuildContext context, {required String title, required String hint}) async =>
                scanContent ?? (title.contains('Wi-Fi') ? kWifiQr : kLabelQrForWidget),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

/// Sihirbazı claim edilmiş cihazla [step] adımında (kayıttan devam) açar.
Future<void> _mountResumed(
  WidgetTester tester,
  ServiceHarness env,
  GlobalKey key,
  Brightness brightness,
  double scale,
  int step, {
  Map<String, dynamic> data = const <String, dynamic>{},
  Size? size,
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
  await _mount(tester, env, key, brightness, scale, resume: record, size: size);
  await pumpUntil(tester, env, () => present('setup_step_$step'), reason: 'adım $step açılmadı');
}

/// Dikey kaydırmaları başa alır (tipik durum çekimlerinde adımın başı görünsün).
void _scrollTop(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.position.axis == Axis.vertical) state.position.jumpTo(0);
  }
}

/// [key] anahtarlı öğeyi görünür alanın üstüne (alignment ~0) kaydırır: uzun adımlarda sonucun çekimde görünmesi için.
Future<void> _scrollTo(WidgetTester tester, String key, {double alignment = 0.02}) async {
  final finder = find.byKey(Key(key));
  await tester.pump();
  await Scrollable.ensureVisible(tester.element(finder), alignment: alignment);
  await tester.pump(const Duration(milliseconds: 120));
}

/// GERÇEK telefon boyu (360x800 dp; sabit alan oranı doğrudan görünür) çekimi: kare 1.5 piksel yoğunluğunda.
Future<void> _phoneShot(WidgetTester tester, GlobalKey key, String name, {bool top = false}) async {
  for (var i = 0; i < 7; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  if (top) {
    _scrollTop(tester);
    await tester.pump(const Duration(milliseconds: 120));
  }
  await expectGolden(tester, key, name, pixelRatio: 1.5);
}

/// PNG çeker: geçişler (fade-through, orb geçişleri, tek seferlik halkalar) bitsin; [top] ise başa kaydırılır.
Future<void> _shot(WidgetTester tester, GlobalKey key, String name, {required double scale, bool top = false}) async {
  for (var i = 0; i < 7; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  if (top) {
    _scrollTop(tester);
    await tester.pump(const Duration(milliseconds: 120));
  }
  await expectGolden(tester, key, name, pixelRatio: scale > 1 ? 1.0 : 1.5);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Servis kurulum sihirbazı galerisi', () {
    setUpAll(() async {
      await loadGoldenFonts();
      await loadWizardGalleryExtras();
    });

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';

        testWidgets('10 adım: tipik + başarı durumları ($tag)', (tester) async {
          final env = await serviceHarness(flush: () async {});
          addTearDown(env.dispose);
          final key = GlobalKey();
          await _mount(tester, env, key, brightness, scale);

          // 1) Hazırlık
          await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
          await _shot(tester, key, 's01_typical_$tag.png', scale: scale, top: true);
          await goNext(tester, env);

          // 2) Cihazı tanı
          await _shot(tester, key, 's02_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'btn_scan_label');
          await pumpUntil(tester, env, () => present('step2_accepted_card'));
          await _shot(tester, key, 's02_success_$tag.png', scale: scale);
          await goNext(tester, env);

          // 3) Müşteri
          await _shot(tester, key, 's03_typical_$tag.png', scale: scale, top: true);
          await typeKey(tester, 'field_customer', kCustomerEmail);
          await tapKey(tester, 'btn_send_otp');
          await pumpUntil(tester, env, () => present('field_otp'));
          await typeKey(tester, 'field_otp', kCustomerOtp);
          await _shot(tester, key, 's03_success_$tag.png', scale: scale);
          await goNext(tester, env);

          // 4) Claim
          await typeKey(tester, 'field_home_name', 'Daire 5');
          await _shot(tester, key, 's04_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'btn_claim');
          await tester.pump(const Duration(milliseconds: 300));
          await tapKey(tester, 'btn_claim_confirm');
          await pumpUntil(tester, env, () => present('claim_result_card'));
          await _shot(tester, key, 's04_success_$tag.png', scale: scale);
          await goNext(tester, env);

          // 5) Wi-Fi (kurulum ağında)
          env.phoneOnSetupNetwork();
          await _shot(tester, key, 's05_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'btn_check_device');
          await pumpUntil(tester, env, () => present('wifi_provision_panel'));
          await pumpUntil(tester, env, () => present('wifi_network_list'));
          await _scrollTo(tester, 'wifi_provision_panel');
          await _shot(tester, key, 's05_networks_$tag.png', scale: scale);
          await tapKey(tester, 'btn_wifi_scan_qr');
          await pumpUntil(
            tester,
            env,
            () => tester.widget<TextField>(find.byKey(const Key('field_wifi_ssid'))).controller!.text == kHomeWifiSsid,
          );
          await tapKey(tester, 'btn_wifi_submit');
          await pumpUntil(tester, env, () => present('wifi_connected_card'));
          await _scrollTo(tester, 'wifi_connected_card', alignment: 0.1);
          await _shot(tester, key, 's05_success_$tag.png', scale: scale);
          env.phoneOnHomeNetwork();
          await goNext(tester, env);

          // 6) Bulut
          await _shot(tester, key, 's06_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'btn_cloud_connect');
          await pumpUntil(tester, env, () => present('cloud_online_card'));
          await _shot(tester, key, 's06_success_$tag.png', scale: scale);
          await goNext(tester, env);

          // 7) Röleler
          await pumpUntil(tester, env, () => present('card_relay_5'));
          await _shot(tester, key, 's07_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'btn_relay_on_5');
          await pumpUntil(tester, env, () => present('btn_relay_lit_yes_5'));
          await _shot(tester, key, 's07_testing_$tag.png', scale: scale);
          for (final id in <int>[5, 6, 7, 8]) {
            if (id != 5) {
              await tapKey(tester, 'btn_relay_on_$id');
              await pumpUntil(tester, env, () => present('btn_relay_lit_yes_$id'));
            }
            await tapKey(tester, 'btn_relay_lit_yes_$id');
            await tapKey(tester, 'btn_relay_off_$id');
            await pumpUntil(tester, env, () => !env.device.relayState(id));
          }
          await pumpUntil(tester, env, () => find.textContaining('4 doğrulandı').evaluate().isNotEmpty);
          await _shot(tester, key, 's07_success_$tag.png', scale: scale, top: true);
          await goNext(tester, env);

          // 8) Panjurlar
          await pumpUntil(tester, env, () => present('card_shutter_1'));
          await _shot(tester, key, 's08_typical_$tag.png', scale: scale, top: true);
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
            if (pair == 1) await _shot(tester, key, 's08_measuring_$tag.png', scale: scale);
            await tapKey(tester, 'btn_finish_measure_$pair');
            await pumpUntil(tester, env, () => present('btn_save_runtime_$pair'));
            if (pair == 1) await _shot(tester, key, 's08_measured_$tag.png', scale: scale);
            await tapKey(tester, 'btn_save_runtime_$pair');
            await pumpUntil(tester, env, () => present('btn_remeasure_$pair'));
          }
          await _shot(tester, key, 's08_success_$tag.png', scale: scale, top: true);
          await goNext(tester, env);

          // 9) Duvar butonları
          await pumpUntil(tester, env, () => present('btn_listen_toggle'));
          await _shot(tester, key, 's09_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'btn_listen_toggle');
          await pumpUntil(tester, env, () => find.text('Dinlemeyi Durdur').evaluate().isNotEmpty);
          for (var id = 1; id <= 4; id++) {
            env.device.setDi(id, true);
            await pumpUntil(
              tester,
              env,
              () =>
                  find
                      .descendant(of: find.byKey(Key('card_button_$id')), matching: find.text('Algılandı'))
                      .evaluate()
                      .isNotEmpty,
            );
            // Yakalandığı anda (nabız halkası oynarken) çekim.
            if (id == 2) {
              await tester.pump(const Duration(milliseconds: 120));
              await expectGolden(tester, key, 's09_listening_$tag.png', pixelRatio: scale > 1 ? 1.0 : 1.5);
            }
            env.device.setDi(id, false);
            env.clock.advance(const Duration(milliseconds: 400));
            await tester.pump();
          }
          await _shot(tester, key, 's09_success_$tag.png', scale: scale, top: true);
          await goNext(tester, env);

          // 10) Teslim
          await pumpUntil(tester, env, () => present('handover_checklist'));
          await pumpUntil(tester, env, () => env.cloud.calls.where((c) => c.startsWith('devices:')).length >= 2);
          await _shot(tester, key, 's10_typical_$tag.png', scale: scale, top: true);
          await tapKey(tester, 'chk_owner_approved');
          await tester.pump();
          // Sunucu önce devreye almayı reddeder (hata kutusu), sonra "Tekrar dene" ile onaylar.
          env.cloud.serverCommissionRejects = true;
          await tapKey(tester, 'btn_commission');
          await pumpUntil(tester, env, () => present('setup_retry') || present('setup_fix_step'));
          await _shot(tester, key, 'e10_rejected_$tag.png', scale: scale);
          env.cloud.serverCommissionRejects = false;
          await tapKey(tester, present('setup_retry') ? 'setup_retry' : 'btn_commission');
          await pumpUntil(tester, env, () => present('handover_success_card'));
          // Kutlama (<= 900 ms): başlangıcında ve bitişinde.
          await tester.ensureVisible(find.byKey(const Key('handover_celebration')));
          _scrollTop(tester);
          await tester.pump(const Duration(milliseconds: 220));
          await expectGolden(tester, key, 's10_celebrate_$tag.png', pixelRatio: scale > 1 ? 1.0 : 1.5);
          await _shot(tester, key, 's10_success_$tag.png', scale: scale, top: true);
          expect(tester.takeException(), isNull);
        });

        testWidgets('hata durumları 1-5 ($tag)', (tester) async {
          final key = GlobalKey();

          // 1) Hazırlık: sunucuya ulaşılamıyor.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            env.cloud.internetUp = false;
            await _mount(tester, env, key, brightness, scale);
            await pumpUntil(tester, env, () => present('setup_retry'));
            await _shot(tester, key, 'e01_error_$tag.png', scale: scale, top: true);
          }

          // 2) Cihazı tanı: etiket yerine Wi-Fi karekodu okutuldu.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mount(tester, env, key, brightness, scale, scanContent: kWifiQr);
            await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
            await goNext(tester, env);
            await tapKey(tester, 'btn_scan_label');
            await tester.pump();
            await _shot(tester, key, 'e02_error_$tag.png', scale: scale, top: true);
          }

          // 3) Müşteri: kendi hesabı adına kurulum engeli.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mount(tester, env, key, brightness, scale);
            await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
            await goNext(tester, env);
            await tapKey(tester, 'btn_scan_label');
            await pumpUntil(tester, env, () => present('step2_accepted_card'));
            await goNext(tester, env);
            await typeKey(tester, 'field_customer', 'servis@ornek.test');
            await tapKey(tester, 'btn_send_otp');
            await tester.pump();
            await _shot(tester, key, 'e03_error_$tag.png', scale: scale);
          }

          // 4) Claim: müşterinin söylediği kod yanlış.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mount(tester, env, key, brightness, scale);
            await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
            await goNext(tester, env);
            await tapKey(tester, 'btn_scan_label');
            await pumpUntil(tester, env, () => present('step2_accepted_card'));
            await goNext(tester, env);
            await typeKey(tester, 'field_customer', kCustomerEmail);
            await tapKey(tester, 'btn_send_otp');
            await pumpUntil(tester, env, () => present('field_otp'));
            await typeKey(tester, 'field_otp', '000000');
            await goNext(tester, env);
            await tapKey(tester, 'btn_claim');
            await tester.pump(const Duration(milliseconds: 300));
            await tapKey(tester, 'btn_claim_confirm');
            await pumpUntil(tester, env, () => present('setup_retry') || present('setup_fix_step'));
            await _shot(tester, key, 'e04_error_$tag.png', scale: scale, top: true);
          }

          // 5) Wi-Fi: telefon panonun kurulum ağında değil.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            env.cloud.seedClaimed(online: true);
            env.phoneOnHomeNetwork();
            await _mount(
              tester,
              env,
              key,
              brightness,
              scale,
              existing: ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: ''),
              startStep: SetupSteps.wifi,
            );
            await pumpUntil(tester, env, () => present('setup_step_5'));
            await tapKey(tester, 'btn_check_device');
            await pumpUntil(tester, env, () => present('setup_retry'));
            await _shot(tester, key, 'e05_error_$tag.png', scale: scale);
          }
          expect(tester.takeException(), isNull);
        });

        testWidgets('hata durumları 6-10 ($tag)', (tester) async {
          final key = GlobalKey();

          // 6) Bulut: telefon internetsiz -> hata kutusu.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.cloud);
            env.cloud.internetUp = false;
            await tapKey(tester, 'btn_cloud_connect');
            await pumpUntil(tester, env, () => present('setup_retry'));
            await _shot(tester, key, 'e06_error_$tag.png', scale: scale);
          }

          // 7) Röleler: pano ulaşılmaz -> bağlantı paneli + hata kutusu.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.relays);
            await pumpUntil(tester, env, () => present('card_relay_5'));
            env.device.lanReachable = false;
            await tapKey(tester, 'btn_relay_on_5');
            await pumpUntil(tester, env, () => present('setup_retry') || present('device_connection_panel'));
            await _shot(tester, key, 'e07_error_$tag.png', scale: scale);
          }

          // 8) Panjurlar: pano ulaşılmaz.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.shutters);
            await pumpUntil(tester, env, () => present('card_shutter_1'));
            env.device.lanReachable = false;
            await tapKey(tester, 'btn_shutter_up_1');
            await pumpUntil(tester, env, () => present('setup_retry') || present('device_connection_panel'));
            await _shot(tester, key, 'e08_error_$tag.png', scale: scale);
          }

          // 9) Duvar butonları: pano ulaşılmaz.
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.buttons);
            await pumpUntil(tester, env, () => present('btn_listen_toggle'));
            env.device.lanReachable = false;
            await tapKey(tester, 'btn_listen_toggle');
            await pumpUntil(tester, env, () => present('setup_retry') || present('device_connection_panel'));
            await _shot(tester, key, 'e09_error_$tag.png', scale: scale);
          }

          // 10) Teslim: önceki adımlar tamamlanmadan gelindi -> kontrol listesi kırmızı, "Devreye Al" pasif.
          // (Sunucunun devreye almayı reddetmesi: "10 adım" testinde, e10_rejected.)
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.handover);
            await pumpUntil(tester, env, () => present('handover_checklist'));
            await tapKey(tester, 'chk_owner_approved');
            await tester.pump();
            await _shot(tester, key, 'e10_missing_$tag.png', scale: scale);
          }
          expect(tester.takeException(), isNull);
        });

        testWidgets('gerçek telefon boyu 360x800: sabit alan oranı ve hata görünürlüğü ($tag)', (tester) async {
          const phone = Size(360, 800);
          final key = GlobalKey();

          // 5) Wi-Fi: telefon kurulum ağında, yönerge + panel (sabit üst/alt alan ekranın yarısından az mı?).
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            env.cloud.seedClaimed(online: true);
            // Önce ev ağında açılır (sunucu doğrulaması geçer: "Sunucuya ulaşılamadı" uyarısı çıkmaz), sonra telefon pano ağına alınır.
            env.phoneOnHomeNetwork();
            await _mount(
              tester,
              env,
              key,
              brightness,
              scale,
              size: phone,
              existing: ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: ''),
              startStep: SetupSteps.wifi,
            );
            await pumpUntil(tester, env, () => present('setup_step_5'));
            env.phoneOnSetupNetwork();
            await tester.pump(const Duration(milliseconds: 200));
            await _phoneShot(tester, key, 'p05_typical_$tag.png', top: true);
          }

          // 7) Röleler: pano ulaşılmaz -> hata kutusu kaydırma alanında görünür alana getirilir (e07).
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
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
              currentStep: SetupSteps.relays,
              createdAt: now,
              updatedAt: now,
            );
            await _mount(tester, env, key, brightness, scale, size: phone, resume: record);
            await pumpUntil(tester, env, () => present('card_relay_5'));
            env.device.lanReachable = false;
            await tapKey(tester, 'btn_relay_on_5');
            await pumpUntil(tester, env, () => present('setup_retry') || present('device_connection_panel'));
            await _phoneShot(tester, key, 'p07_error_$tag.png');
          }

          // 8) Panjurlar: tipik durum (kontroller ilk ekranda mı?).
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.shutters, size: phone);
            await pumpUntil(tester, env, () => present('card_shutter_1'));
            await _phoneShot(tester, key, 'p08_typical_$tag.png', top: true);
          }
          expect(tester.takeException(), isNull);
        });

        testWidgets('özel durumlar: bulut bekleme, geçici oturum cihaz listesi ($tag)', (tester) async {
          final key = GlobalKey();

          // 6) Bulut: pano sunucuya bağlanıyor (geri sayım + dönen yay).
          {
            final env = await serviceHarness(flush: () async {});
            addTearDown(env.dispose);
            await _mountResumed(tester, env, key, brightness, scale, SetupSteps.cloud);
            env.device.onMqttConfigured = (server, port, user, pass) {};
            await tapKey(tester, 'btn_cloud_connect');
            await pumpUntil(tester, env, () => present('cloud_waiting_card'));
            env.clock.advance(const Duration(seconds: 12));
            await tester.pump();
            await _shot(tester, key, 's06_waiting_$tag.png', scale: scale);
          }

          // 2) Geçici servis oturumu: dairedeki panolardan seçim.
          {
            final env = await serviceHarness(role: 'pin', flush: () async {});
            addTearDown(env.dispose);
            await _mount(tester, env, key, brightness, scale);
            await pumpUntil(tester, env, () => present('setup_step_1'));
            await goNext(tester, env);
            await pumpUntil(tester, env, () => present('btn_load_devices') || present('card_device_$kDeviceUid'));
            if (present('btn_load_devices')) await tapKey(tester, 'btn_load_devices');
            await pumpUntil(tester, env, () => present('card_device_$kDeviceUid'));
            await tapKey(tester, 'card_device_$kDeviceUid');
            await _shot(tester, key, 's02_pin_devices_$tag.png', scale: scale, top: true);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }, skip: visualSkipReason);
}
