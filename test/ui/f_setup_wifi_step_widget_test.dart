import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis sihirbazı arayüzü: Wi-Fi servis akışı (5. adım: kurulum ağında internetsiz ve anahtarsız, E2'nin
/// paylaşılan Wi-Fi bileşeniyle), 6. adım (ev ağına dönüş), darbe rölesi, panjur "kullanılmıyor" onayı ve
/// 2. adımda sunucu kontrolü başarısız olduğunda görünen durum.

/// Sihirbazı bir başlatıcıdan, mevcut cihaz kipinde [startStep] adımında açar.
Future<void> openAtStep(
  WidgetTester tester,
  ServiceHarness env, {
  int startStep = SetupSteps.wifi,
  String ip = '',
  AutomationApiService Function(String host)? factory,
  Future<String?> Function(BuildContext context, {required String title, required String hint})? scanner,
}) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpLauncher(tester, env, (context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          existingTarget: ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: ip),
          startStep: startStep,
          store: env.store,
          deviceApiFactory: factory ?? env.deviceFactory,
          scanner: scanner ?? fakeScanner(kWifiQr),
        ),
      ),
    );
  });
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 25);
  await pumpUntil(tester, env, () => present('setup_step_$startStep'), reason: 'başlangıç adımı açılmadı');
}

/// Kurulum ağındaki (AP) panoya telefondan bağlandı; internet yok.
Future<ServiceHarness> wifiEnv({bool provisioned = true}) async {
  final env = await serviceHarness(provisioned: provisioned, flush: () async {});
  if (!provisioned) env.device.apSecured = false;
  env.cloud.seedClaimed();
  env.phoneOnSetupNetwork(); // internet yok: sihirbaz yine de 5. adımda açılır (sunucu gerektirmez)
  return env;
}

void main() {
  group('5. adım arayüzü: kurulum ağında internetsiz ve anahtarsız Wi-Fi', () {
    testWidgets('pano kimliği doğrulanmadan Wi-Fi bileşeni açılmaz; doğrulanınca açılır ve ağlar anahtarsız taranır', (tester) async {
      final env = await wifiEnv();
      addTearDown(env.dispose);
      await openAtStep(tester, env);

      expect(present('wifi_connect_card'), isTrue);
      expect(present('wifi_provision_panel'), isFalse);
      expect(find.textContaining('AHBU-A1B2C3'), findsWidgets);
      expect(find.textContaining('AĞ PAROLASI (AP)'), findsWidgets, reason: 'kurulum ağı parolası etiketten okunur (sabit parola yok)');
      expect(find.textContaining('ahbu1234'), findsNothing);
      expect(find.textContaining('AHBU-Kurtarma'), findsNothing);

      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_provision_panel'));
      expect(present('wifi_identity_card'), isTrue);
      expect(find.textContaining('Doğru pano bulundu: $kDeviceUid'), findsOneWidget);
      await pumpUntil(tester, env, () => present('wifi_network_list'));
      expect(find.text(kHomeWifiSsid), findsWidgets, reason: 'tarama listesi gerçek pano yanıtından gelir');
      expect(env.device.keylessWifiCalls, greaterThan(0));
      expect(env.device.keyHeaderHosts, isEmpty);
      expect(env.cloud.calls.where((c) => c.startsWith('localKey')), isEmpty, reason: 'kurulum ağında anahtar sunucudan istenmez');
      expect(continueEnabled(tester), isFalse);
    });

    testWidgets('yanlış panoya bağlıysanız Wi-Fi bileşeni hiç açılmaz ve panoya hiçbir bilgi gönderilmez', (tester) async {
      final env = await wifiEnv();
      addTearDown(env.dispose);
      final other = FakeDevice(uid: 'AHBU-S3-ZZZZZZ', localKey: 'baska-anahtar-1', clock: env.clock);
      addTearDown(other.dispose);
      await openAtStep(
        tester,
        env,
        factory: (host) => AutomationApiService(baseUrl: '', client: other.api.client, clock: env.clock)..updateHost(host),
      );
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => find.text('Başka bir panoya bağlısınız').evaluate().isNotEmpty);
      expect(find.textContaining('AHBU-S3-ZZZZZZ'), findsWidgets);
      expect(present('wifi_provision_panel'), isFalse);
      expect(other.keylessWifiCalls, 0);
      expect(other.keyHeaderHosts, isEmpty);
      expect(continueEnabled(tester), isFalse);
    });

    testWidgets('yanlış Wi-Fi şifresi: bileşen ve "Neden / Ne yapmalıyım" kutusu hatayı açıklar; doğru şifreyle bağlanır', (tester) async {
      final env = await wifiEnv();
      addTearDown(env.dispose);
      await openAtStep(tester, env);
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_network_list'));

      await typeKey(tester, 'field_wifi_ssid', kHomeWifiSsid);
      await typeKey(tester, 'field_wifi_password', 'yanlis-sifre-99');
      await tapKey(tester, 'btn_wifi_submit');
      await pumpUntil(tester, env, () => present('wifi_result_failed'));
      expect(find.text('Pano ev Wi-Fi ağına bağlanamadı'), findsOneWidget, reason: 'adım hata kutusu');
      expect(find.textContaining('şifresini kontrol edin'), findsWidgets);
      expect(present('wifi_connected_card'), isFalse);
      expect(continueEnabled(tester), isFalse);

      await typeKey(tester, 'field_wifi_password', kHomeWifiPass);
      await tapKey(tester, 'btn_wifi_submit');
      await pumpUntil(tester, env, () => present('wifi_connected_card'));
      expect(find.text('Pano ev Wi-Fi ağına bağlanamadı'), findsNothing, reason: 'başarıdan sonra eski hata kalkar');
      expect(continueEnabled(tester), isTrue);
    });

    testWidgets('bağlantı koptuysa (pano kurulum ağını kapattı) belirsiz sonuç açıklanır; ev ağında IP ile doğrulanınca tamamlanır',
        (tester) async {
      final env = await wifiEnv();
      addTearDown(env.dispose);
      env.device.dropApOnConnect = true;
      await openAtStep(tester, env);
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_network_list'));
      await typeKey(tester, 'field_wifi_ssid', kHomeWifiSsid);
      await typeKey(tester, 'field_wifi_password', kHomeWifiPass);
      await tapKey(tester, 'btn_wifi_submit');
      await pumpUntil(tester, env, () => present('wifi_result_uncertain'));
      expect(present('wifi_lan_card'), isTrue, reason: 'bağlantı koptu: ev ağındaki IP ile doğrulama kartı açılır');
      expect(continueEnabled(tester), isFalse, reason: 'kanıt olmadan geçilmez');

      env.device.apReachable = false;
      env.device.lanReachable = true; // telefon ev Wi-Fi'sine geçti (bu denemede internet yok: gerekmez)
      await typeKey(tester, 'field_lan_ip', kLanIp);
      await tapKey(tester, 'btn_confirm_lan');
      await pumpUntil(tester, env, () => present('wifi_connected_card'));
      expect(env.device.keyHeaderHosts, isEmpty, reason: 'ev ağı doğrulaması anahtarsızdır');
      expect(continueEnabled(tester), isTrue);
    });

    testWidgets('hazırlanmamış pano: kurulum ağının açık olduğu söylenir; anahtar yoksa hazırlık pasiftir, elle anahtarla yapılır', (tester) async {
      final env = await wifiEnv(provisioned: false);
      addTearDown(env.dispose);
      await openAtStep(tester, env);
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_provision_card'));
      expect(find.textContaining('parolasız (açık)'), findsWidgets);
      expect(present('wifi_provision_panel'), isFalse, reason: 'hazırlanmamış panoya Wi-Fi bilgisi gönderilmez');
      expect(present('wifi_provision_nokey'), isTrue, reason: 'internet yok ve bellekte anahtar yok: açıklama');
      expect(buttonEnabled(tester, 'btn_factory_init'), isFalse);

      // servis_kurulum-5: anahtar iki kez yazılır; ikinci yazım uyuşmazsa "Panoyu Hazırla" kapalı kalır.
      expect(present('manual_key_warning'), isTrue);
      await typeKey(tester, 'field_local_key', kLocalKey);
      await typeKey(tester, 'field_local_key_confirm', '${kLocalKey}x');
      await tapKey(tester, 'btn_use_key');
      await tester.pump();
      expect(buttonEnabled(tester, 'btn_factory_init'), isFalse);
      expect(find.text('Anahtarlar eşleşmiyor'), findsWidgets);
      await typeKey(tester, 'field_local_key_confirm', kLocalKey);
      await tapKey(tester, 'btn_use_key');
      await pumpUntil(tester, env, () => buttonEnabled(tester, 'btn_factory_init'));
      expect(present('wifi_provision_nokey'), isFalse);
      await typeKey(tester, 'field_ap_pass', kApPass);
      await typeKey(tester, 'field_ap_pass_confirm', kApPass);
      await tapKey(tester, 'btn_factory_init');
      await pumpUntil(tester, env, () => present('wifi_reconnect_card'));
      expect(env.device.factoryInitCount, 1);
      expect(find.textContaining(kApPass), findsNothing, reason: 'kurulum ağı parolası ekranda açık yazılmaz');
    });

    testWidgets('uygulama-ekranlar-3: kurulum ağı parolası iki kez yazılır; uyuşmazsa hazırlanmaz, etiket karekodu dolu alanın üstüne yazar',
        (tester) async {
      final env = await wifiEnv(provisioned: false);
      addTearDown(env.dispose);
      await openAtStep(
        tester,
        env,
        scanner: (context, {required title, required hint}) async => 'WIFI:T:WPA;S:AHBU-A1B2C3;P:$kApPass;;',
      );
      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_provision_card'));
      await typeKey(tester, 'field_local_key', kLocalKey);
      await typeKey(tester, 'field_local_key_confirm', kLocalKey);
      await tapKey(tester, 'btn_use_key');
      await pumpUntil(tester, env, () => buttonEnabled(tester, 'btn_factory_init'));

      String fieldText(String key) => tester
          .widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField)))
          .controller!
          .text;

      await typeKey(tester, 'field_ap_pass', 'yanlis-parola-1');
      await typeKey(tester, 'field_ap_pass_confirm', 'yanlis-parola-2');
      await tapKey(tester, 'btn_factory_init');
      await tester.pump();
      expect(env.device.factoryInitCount, 0, reason: 'uyuşmayan parola panoya yazılmaz');
      expect(find.textContaining('Kurulum ağı parolaları eşleşmiyor.'), findsWidgets);

      // Elle yazılmış (yanlış) parola varken etiket karekodu okunur: alanlar etiketteki parolayla değişir.
      await tapKey(tester, 'btn_scan_ap_qr');
      await pumpUntil(tester, env, () => present('ap_label_password'));
      expect(fieldText('field_ap_pass'), kApPass);
      expect(fieldText('field_ap_pass_confirm'), kApPass);

      await tapKey(tester, 'btn_factory_init');
      await pumpUntil(tester, env, () => present('wifi_reconnect_card'));
      expect(env.device.factoryInitCount, 1);
    });

    testWidgets('etiketteki 2. karekod (kurulum ağı) uygulamayla okununca parola gizli gösterilir, kopyalanamaz; başka panonun karekodu reddedilir',
        (tester) async {
      final env = await wifiEnv();
      addTearDown(env.dispose);
      var raw = 'WIFI:T:WPA;S:AHBU-A1B2C3;P:$kApPass;;';
      await openAtStep(
        tester,
        env,
        scanner: (context, {required title, required hint}) async => raw,
      );
      await tapKey(tester, 'btn_scan_ap_qr');
      await pumpUntil(tester, env, () => present('ap_label_password'));
      expect(tester.widget<Text>(find.byKey(const Key('ap_label_password'))).data, isNot(contains(kApPass)), reason: 'varsayılan gizli');
      await tapKey(tester, 'btn_toggle_ap_password');
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('ap_label_password'))).data, kApPass);
      expect(find.byTooltip('Kopyala'), findsNothing);
      expect(find.byType(SelectableText), findsNothing, reason: 'parola seçilebilir/kopyalanabilir metin değildir');

      raw = 'WIFI:T:WPA;S:AHBU-FFFFFF;P:baska-pano-parola;;';
      await tapKey(tester, 'btn_scan_ap_qr');
      await pumpUntil(tester, env, () => present('ap_label_scan_error'));
      expect(find.textContaining('başka bir panonun'), findsOneWidget);

      // Modemin (ev) karekodu bu düğmeyle okutulursa: parola alanına yazılmaz, doğru yer tarif edilir.
      raw = 'WIFI:T:WPA;S:Ev_Modem;P:modem-sifre-123;;';
      await tapKey(tester, 'btn_scan_ap_qr');
      await pumpUntil(tester, env, () => find.textContaining('modemin (ev) Wi-Fi karekodu').evaluate().isNotEmpty);
      expect(find.textContaining('Bağlandım: Panoyu Kontrol Et'), findsWidgets);
      await tapKey(tester, 'btn_toggle_ap_password');
      await tester.pump();
      expect(find.textContaining('modem-sifre-123'), findsNothing, reason: 'modem parolası kurulum ağı parolası sayılmaz');
    });
  });

  group('mevcut cihaz (pano ev ağında)', () {
    testWidgets('pano ev ağında görünüyorsa kurulum ağı yönergesi ve "IP ile bağlan" kartı birlikte açılır; IP ile doğrulama anahtarsızdır',
        (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      await openAtStep(tester, env, startStep: SetupSteps.wifi, ip: kLanIp);
      expect(present('wifi_on_lan_note'), isTrue, reason: 'Wi-Fi bilgisini değiştirmek için kurulum ağına bağlanılması gerektiği söylenir');
      expect(present('wifi_lan_card'), isTrue, reason: 'yalnızca doğrulamak isteyen için IP kartı baştan açık');
      expect(present('btn_scan_ap_qr'), isTrue);

      await typeKey(tester, 'field_lan_ip', kLanIp);
      await tapKey(tester, 'btn_confirm_lan');
      await pumpUntil(tester, env, () => present('wifi_connected_card'));
      expect(env.device.keyHeaderHosts, isEmpty, reason: 'ev ağı doğrulaması anahtar gerektirmez');
      expect(continueEnabled(tester), isTrue);
    });
  });

  group('yerleşim', () {
    testWidgets('360x800 ekranda ve 1.5x yazıda 5. adım (sunucu uyarı şeridiyle ve Wi-Fi bileşeni açıkken) taşma olmadan çalışır', (tester) async {
      final env = await wifiEnv(); // internet yok: "Sunucu bağlantısı doğrulanamadı" uyarı şeridi de görünür
      addTearDown(env.dispose);
      await openAtStep(tester, env);
      expect(present('prep_warning'), isTrue, reason: 'internetsiz açılışta sunucu doğrulanamadı uyarısı görünür');
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5; // 1.5x yazı büyütme
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'uyarı şeridi adım iskeletinin sabit alanını taşırmamalı');
      expect(find.byKey(const Key('setup_continue')), findsOneWidget, reason: '"Devam" düğmesi büyük yazıda da görünür');

      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_network_list'));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('setup_continue')), findsOneWidget);

      // Hata durumu (bileşenin satır içi iletisi + adımın "Neden / Ne yapmalıyım" kutusu) da taşmamalı.
      await typeKey(tester, 'field_wifi_ssid', kHomeWifiSsid);
      await typeKey(tester, 'field_wifi_password', 'yanlis-sifre-99');
      await tapKey(tester, 'btn_wifi_submit');
      await pumpUntil(tester, env, () => present('wifi_result_failed'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('setup_continue')), findsOneWidget);
    });
  });

  group('6. adım arayüzü', () {
    testWidgets('önce telefonu ev Wi-Fi ağına geri alma yönergesi görünür; zaten çevrimiçi pano için kimlik değiştirilmediği söylenir',
        (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      await openAtStep(tester, env, startStep: SetupSteps.cloud, ip: kLanIp);
      expect(present('cloud_home_wifi_card'), isTrue);
      expect(find.textContaining('ev Wi-Fi ağına geri alın'), findsWidgets);
      expect(find.textContaining('192.168.1.42'), findsWidgets, reason: 'panonun ev ağındaki adresi gösterilir');

      await tapKey(tester, 'btn_cloud_connect');
      await pumpUntil(tester, env, () => present('cloud_online_card'));
      expect(find.textContaining('DEĞİŞTİRİLMEDİ'), findsOneWidget);
      expect(env.device.mqttConfigCount, 0);
      expect(env.cloud.calls.where((c) => c.startsWith('reissueDeviceMqttCredential')), isEmpty);
    });
  });

  group('7-8. adım arayüzü', () {
    Future<ServiceHarness> deployedEnv() async {
      final env = await serviceHarness(flush: () async {});
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      return env;
    }

    testWidgets('darbe rölesi: pano geri bildirimi görülemese de "çalıştı mı?" teyidi gelir ve gözle doğrulama röleyi tamamlar', (tester) async {
      final env = await deployedEnv();
      addTearDown(env.dispose);
      env.device.relays.add(SimRelay(9, 'Kapı Zili', 3));
      await openAtStep(tester, env, startStep: SetupSteps.relays, ip: kLanIp);
      await pumpUntil(tester, env, () => present('card_relay_9'));

      await tapKey(tester, 'btn_relay_on_9');
      await pumpUntil(tester, env, () => present('btn_relay_lit_yes_9'), reason: 'darbe geri bildirimi olmasa da teyit düğmeleri gelmeli');
      expect(present('relay_info_9'), isTrue);
      expect(find.textContaining('gözle doğrulayın'), findsOneWidget);
      expect(env.device.impulseTriggers, 1);
      await tapKey(tester, 'btn_relay_lit_yes_9');
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('card_relay_9')), matching: find.text('Doğrulandı')), findsOneWidget);
    });

    testWidgets('panjur "kullanılmıyor" onay ister; tümü işaretlenirse devam açılmaz ve en az bir panjuru test etme ipucu görünür', (tester) async {
      final env = await deployedEnv();
      addTearDown(env.dispose);
      await openAtStep(tester, env, startStep: SetupSteps.shutters, ip: kLanIp);
      await pumpUntil(tester, env, () => present('card_shutter_1') && present('card_shutter_2'));

      await tapKey(tester, 'btn_shutter_unused_1');
      await settle(tester);
      expect(find.text('Bu panjur kullanılmıyor mu?'), findsOneWidget);
      await tapKey(tester, 'btn_shutter_unused_cancel');
      await settle(tester);
      expect(find.descendant(of: find.byKey(const Key('shutter_status_1')), matching: find.text('Kullanılmıyor')), findsNothing);

      for (final pair in <int>[1, 2]) {
        await tapKey(tester, 'btn_shutter_unused_$pair');
        await settle(tester);
        await tapKey(tester, 'btn_shutter_unused_confirm');
        await pumpUntil(tester, env, () => find.descendant(of: find.byKey(Key('shutter_status_$pair')), matching: find.text('Kullanılmıyor')).evaluate().isNotEmpty);
      }
      expect(continueEnabled(tester), isFalse);
      expect(find.textContaining('En az bir panjuru gerçekten test edin'), findsOneWidget);
    });
  });

  group('2. adım arayüzü', () {
    testWidgets('sunucu kontrolü ağ hatasıyla düşerse kart "kontrol ediliyor" yazmaz; hata ve Tekrar dene görünür, düzelince tamamlanır', (tester) async {
      final env = await serviceHarness(inventoryListed: true, flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env);
      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      await goNext(tester, env);

      env.cloud.inventoryError = ApiException.network();
      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => present('step2_accepted_card') && present('setup_retry'));
      expect(find.textContaining('Sunucuda kontrol ediliyor'), findsNothing);
      expect(find.textContaining('Sunucu kontrolü tamamlanamadı'), findsOneWidget);
      expect(continueEnabled(tester), isFalse);

      env.cloud.inventoryError = null;
      await tapKey(tester, 'setup_retry');
      await pumpUntil(tester, env, () => find.textContaining('Sunucuda stokta görünüyor').evaluate().isNotEmpty);
      expect(continueEnabled(tester), isTrue);
    });
  });
}
