import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

void main() {
  group('servis kurulum sihirbazı arayüzü: 10 adım uçtan uca (sahte sunucu + sahte pano)', () {
    testWidgets('teknisyen yalnızca ekrandaki yönergelerle ve gerçek yanıtlarla kurulumu tamamlar', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env);

      // --- 1) Hazırlık: "Devam" yalnızca sunucu doğrulanınca etkin ---
      expect(find.byKey(const Key('setup_step_1')), findsOneWidget);
      expect(find.text('Adım 1 / 10'), findsOneWidget);
      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      await goNext(tester, env);

      // --- 2) Cihazı tanı ---
      expect(find.byKey(const Key('setup_step_2')), findsOneWidget);
      expect(continueEnabled(tester), isFalse, reason: 'cihaz tanıtılmadan devam edilemez');
      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => present('step2_accepted_card'));
      expect(find.textContaining(kDeviceUid), findsWidgets);
      expect(find.textContaining(kSetupPin), findsNothing, reason: 'PIN ekranda açık yazılmaz');
      await goNext(tester, env);

      // --- 3) Müşteri ---
      expect(find.byKey(const Key('setup_step_3')), findsOneWidget);
      await typeKey(tester, 'field_customer', 'servis@ornek.test');
      await tapKey(tester, 'btn_send_otp');
      await tester.pump();
      expect(find.textContaining('Kendi hesabınız adına'), findsWidgets, reason: 'kendi adına kurulum engellenir');
      expect(env.cloud.otpRequests, 0);
      await typeKey(tester, 'field_customer', kCustomerEmail);
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => present('field_otp'));
      expect(env.cloud.otpRequests, 1);
      expect(continueEnabled(tester), isFalse, reason: 'kod yazılmadan devam edilemez');
      await typeKey(tester, 'field_otp', kCustomerOtp);
      await goNext(tester, env);

      // --- 4) Claim ---
      expect(find.byKey(const Key('setup_step_4')), findsOneWidget);
      await typeKey(tester, 'field_home_name', 'Daire 5');
      await tapKey(tester, 'btn_claim');
      await tester.pump(const Duration(milliseconds: 300));
      await tapKey(tester, 'btn_claim_confirm');
      await pumpUntil(tester, env, () => present('claim_result_card'));
      expect(find.textContaining('Daire 5'), findsWidgets);
      await goNext(tester, env);

      // --- 5) Wi-Fi: telefon panonun kurulum ağında (internet YOK, cihaz anahtarı YOK); E2'nin Wi-Fi bileşeni ---
      expect(find.byKey(const Key('setup_step_5')), findsOneWidget);
      env.phoneOnSetupNetwork();
      final callsAtSetupNetwork = List<String>.of(env.cloud.calls);
      expect(find.textContaining('AHBU-A1B2C3'), findsWidgets, reason: 'kurulum ağı adı ekranda yazar');
      expect(find.textContaining('internet GEREKTİRMEZ'), findsWidgets, reason: 'bu adımın internetsiz olduğu söylenir');
      expect(continueEnabled(tester), isFalse);
      expect(present('wifi_provision_panel'), isFalse, reason: 'pano kimliği doğrulanmadan Wi-Fi bileşeni açılmaz');
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_provision_panel'));
      await pumpUntil(tester, env, () => present('wifi_network_list'), reason: 'bileşen açılınca ağ taraması otomatik başlar');
      await tapKey(tester, 'btn_wifi_scan_qr');
      await pumpUntil(tester, env, () => tester.widget<TextField>(find.byKey(const Key('field_wifi_ssid'))).controller!.text == kHomeWifiSsid);
      await tapKey(tester, 'btn_wifi_submit');
      await pumpUntil(tester, env, () => present('wifi_connected_card'), reason: 'pano ev ağına bağlanmadı');
      expect(env.device.wifiConnected, isTrue);
      expect(env.device.keyHeaderHosts, isEmpty, reason: 'kurulum ağında cihaz anahtarı gönderilmez');
      expect(env.cloud.calls, callsAtSetupNetwork, reason: 'kurulum ağında sunucuya istek atılmaz');
      expect(find.textContaining('ev Wi-Fi ağına geri bağlayın'), findsWidgets, reason: 'telefonu ev ağına döndürme yönergesi');
      env.phoneOnHomeNetwork();
      await goNext(tester, env);

      // --- 6) Bulut (telefon ev Wi-Fi'sinde, internet var) ---
      expect(find.byKey(const Key('setup_step_6')), findsOneWidget);
      expect(present('cloud_home_wifi_card'), isTrue, reason: 'önce telefonu ev Wi-Fi ağına geri alın yönergesi');
      await tapKey(tester, 'btn_cloud_connect');
      await pumpUntil(tester, env, () => present('cloud_online_card'), reason: 'pano buluta bağlanmadı');
      expect(env.device.receivedMqttPass, kCredentialPassword);
      await goNext(tester, env);

      // --- 7) Röleler ---
      expect(find.byKey(const Key('setup_step_7')), findsOneWidget);
      await pumpUntil(tester, env, () => present('card_relay_5'));
      expect(continueEnabled(tester), isFalse);
      for (final id in <int>[5, 6, 7, 8]) {
        await tapKey(tester, 'btn_relay_on_$id');
        await pumpUntil(tester, env, () => present('btn_relay_lit_yes_$id'), reason: 'röle $id geri bildirimi');
        await tapKey(tester, 'btn_relay_lit_yes_$id');
        await tapKey(tester, 'btn_relay_off_$id');
        await pumpUntil(tester, env, () => !env.device.relayState(id) && find.text('Pano: kapandı ✔').evaluate().isNotEmpty);
      }
      await pumpUntil(tester, env, () => find.textContaining('4 doğrulandı').evaluate().isNotEmpty);
      await goNext(tester, env);

      // --- 8) Panjurlar ---
      expect(find.byKey(const Key('setup_step_8')), findsOneWidget);
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
        expect(find.byKey(Key('shutter_measured_$pair')), findsOneWidget);
        await tapKey(tester, 'btn_save_runtime_$pair');
        await pumpUntil(tester, env, () => present('btn_remeasure_$pair'), reason: 'süre panoda doğrulanmadı');
        expect(env.device.shutterRuntime(pair), 18 + pair * 6);
      }
      await goNext(tester, env);

      // --- 9) Duvar butonları ---
      expect(find.byKey(const Key('setup_step_9')), findsOneWidget);
      await pumpUntil(tester, env, () => present('btn_listen_toggle'));
      await tapKey(tester, 'btn_listen_toggle');
      await pumpUntil(tester, env, () => env.state.clock.now().isAfter(DateTime(2000)) && find.text('Dinlemeyi Durdur').evaluate().isNotEmpty);
      expect(continueEnabled(tester), isFalse);
      for (var id = 1; id <= 4; id++) {
        env.device.setDi(id, true);
        await pumpUntil(tester, env, () => find.byKey(Key('card_button_$id')).evaluate().isNotEmpty && find.descendant(of: find.byKey(Key('card_button_$id')), matching: find.text('Algılandı')).evaluate().isNotEmpty);
        env.device.setDi(id, false);
        env.clock.advance(const Duration(milliseconds: 400));
        await tester.pump();
      }
      await goNext(tester, env);

      // --- 10) Teslim ---
      expect(find.byKey(const Key('setup_step_10')), findsOneWidget);
      await pumpUntil(tester, env, () => present('handover_checklist'));
      await pumpUntil(tester, env, () => env.cloud.calls.where((c) => c.startsWith('devices:')).length >= 2);
      expect(buttonEnabled(tester, 'btn_commission'), isFalse, reason: 'müşteri teslimi onaylanmadan gönderilemez');
      await tapKey(tester, 'chk_owner_approved');
      await tester.pump();
      await tapKey(tester, 'btn_commission');
      await pumpUntil(tester, env, () => present('handover_success_card'));
      expect(env.cloud.commissionChecks, hasLength(1));
      expect(find.byKey(const Key('handover_report')), findsOneWidget);
      final reportText = (tester.widget<SelectableText>(find.byKey(const Key('handover_report')))).data!;
      for (final secret in <String>[kSetupPin, kCredentialPassword, kLocalKey, kHomeWifiPass]) {
        expect(reportText, isNot(contains(secret)));
      }
      await goNext(tester, env);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('launcher')), findsOneWidget, reason: 'Bitir sihirbazı kapatır');
      expect(await env.store.list(env.access.ownerKey), isEmpty, reason: 'tamamlanan kurulum "devam eden" listede kalmaz');
    });
  });
}
