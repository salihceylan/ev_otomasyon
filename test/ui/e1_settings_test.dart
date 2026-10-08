import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/widgets/settings/alarm_watch_card.dart';
import 'package:ev_otomasyon/ui/widgets/settings/appearance_cards.dart';
import 'package:ev_otomasyon/ui/widgets/settings/device_host_card.dart';
import 'package:ev_otomasyon/ui/widgets/settings/info_cards.dart';
import 'package:ev_otomasyon/ui/widgets/settings/service_pin_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';
import 'e1_helpers.dart';

/// Cihaz ayarları: rol matrisi (kartların `Capabilities`'e göre görünürlüğü) ve kartların davranışı
/// (servis PIN'i, cihaz adresi, biyometrik, tema, hesap).
void main() {
  const allCards = <String>[
    'card_hardware_notice',
    'notice_role',
    'card_system_doctor',
    'card_child_lock',
    'card_peace',
    'card_rules',
    'card_biometric',
    'card_theme',
    'card_service_pin',
    'card_wifi_recovery',
    'card_replace_board',
    'card_host',
    'card_telemetry',
    'card_account',
  ];

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Sayfadaki tüm kartları görünür kılmak için yüksek bir ekran kullanılır.
  const tall = Size(800, 4200);

  void expectCards(Set<String> visible) {
    for (final name in allCards) {
      expect(
        byKeyName(name),
        visible.contains(name) ? findsOneWidget : findsNothing,
        reason: '$name ${visible.contains(name) ? 'görünmeli' : 'gizli olmalı'}',
      );
    }
  }

  group('Ayarlar sayfası rol matrisi (kartlar Capabilities\'ten)', () {
    testWidgets('ev sahibi: servis PIN\'i, pano değişimi, Wi-Fi kurtarma, adres ve tüm ayarlar', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: tall);
      expectCards({
        'card_hardware_notice',
        'card_system_doctor',
        'card_child_lock',
        'card_peace',
        'card_rules',
        'card_biometric',
        'card_theme',
        'card_service_pin',
        'card_wifi_recovery',
        'card_replace_board',
        'card_host',
        'card_account',
      });
    });

    testWidgets('aile üyesi: servis PIN\'i ve pano değişimi YOK; kilit, kural, adres ve Wi-Fi kurtarma var', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'resident', size: tall);
      expectCards({
        'card_hardware_notice',
        'notice_role',
        'card_system_doctor',
        'card_child_lock',
        'card_peace',
        'card_rules',
        'card_biometric',
        'card_theme',
        'card_wifi_recovery',
        'card_host',
        'card_account',
      });
      expect(find.textContaining('Aile üyesi hesabı'), findsOneWidget);
    });

    testWidgets('misafir: cihaz adresi, Wi-Fi kurtarma, pano değişimi, servis PIN\'i, doktor GÖRÜNMEZ; kilit salt-okunur',
        (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), home: guestHome(), size: tall);
      expectCards({
        'card_hardware_notice',
        'notice_role',
        'card_child_lock',
        'card_biometric',
        'card_theme',
        'card_account',
      });
      expect(byKeyName('text_child_lock_readonly'), findsOneWidget);
      expect(find.textContaining('Misafir erişimi'), findsOneWidget);
    });

    testWidgets('servis PIN oturumu: kural ve servis PIN\'i yok; pano değişimi, Wi-Fi kurtarma, adres var', (tester) async {
      await pumpReady(
        tester,
        const DeviceSettingsPage(),
        role: 'service_session',
        globalRole: 'service_session',
        size: tall,
      );
      expectCards({
        'card_hardware_notice',
        'card_system_doctor',
        'card_child_lock',
        'card_peace',
        'card_biometric',
        'card_theme',
        'card_wifi_recovery',
        'card_replace_board',
        'card_host',
        'card_account',
      });
    });

    testWidgets('kalıcı servis personeli (evde service_user): kural + pano değişimi var; servis PIN\'i yok', (tester) async {
      await pumpReady(
        tester,
        const DeviceSettingsPage(),
        role: 'service_user',
        globalRole: 'service_user',
        size: tall,
      );
      expectCards({
        'card_hardware_notice',
        'card_system_doctor',
        'card_child_lock',
        'card_peace',
        'card_rules',
        'card_biometric',
        'card_theme',
        'card_wifi_recovery',
        'card_replace_board',
        'card_host',
        'card_account',
      });
    });

    testWidgets('guvenlik-12: arka plan alarm kartı ev rolüne bağlı (kendi evinin sahibi personel görür)', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', globalRole: 'service_user', size: tall);
      expect(find.byType(AlarmWatchCard), findsOneWidget);
    });

    testWidgets('guvenlik-12: müşteri evindeki servis personeli arka plan alarm kartını görmez', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'service_user', globalRole: 'service_user', size: tall);
      expect(find.byType(AlarmWatchCard), findsNothing);
    });

    testWidgets('süper kullanıcı (aktif ev yok): yalnızca uygulama ayarları (tema, biyometrik, hesap)', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'su-1', email: 'su@b.c', fullName: 'Süper', role: 'super_user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await pumpPage(tester, h.state, const DeviceSettingsPage(), size: tall);
      expectCards({'card_biometric', 'card_theme', 'card_account'});
    });

    testWidgets('girişsiz yerel mod: yalnızca kilit, cihaz adresi/anahtarı ve tema; hesap/biyometrik/bulut kartları yok',
        (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      await pumpPage(tester, h.state, const DeviceSettingsPage(), size: tall);
      expectCards({'card_hardware_notice', 'card_child_lock', 'card_theme', 'card_host'});
      expect(byKeyName('field_local_key'), findsOneWidget);
    });

    testWidgets('doğrudan modda huzur bildirimi ve zamanlı kural kartları gizlidir (bulut özellikleri)', (tester) async {
      final h = await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: tall);
      expect(byKeyName('card_peace'), findsOneWidget);
      h.state.setModeForTesting(AppMode.direct);
      await flush(tester);
      expect(byKeyName('card_peace'), findsNothing);
      expect(byKeyName('card_rules'), findsNothing);
      expect(byKeyName('card_service_pin'), findsNothing);
    });

    testWidgets('açık temada ve 320 dp / yazı ölçeği 1.5 iken ayarlar sayfası taşmaz', (tester) async {
      await pumpReady(
        tester,
        const DeviceSettingsPage(),
        role: 'owner',
        size: const Size(320, 4800),
        textScale: 1.5,
        themeMode: ThemeMode.light,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Servis PIN kartı (ev sahibi)', () {
    Widget card() => scaffolded(const ServicePinCard());

    /// PIN'in bitişi test saatine göre sabitlenir (sahte `createServiceToken` gerçek saati kullanır).
    void fixedPin(StateHarness h) => h.e1.serviceTokenToReturn =
        ServiceTokenModel(pin: '123456', expiresAt: kTestNow.add(const Duration(hours: 2)));

    testWidgets('PIN üretilir ve YALNIZCA bir kez gösterilir; kalan süre geri sayar', (tester) async {
      final h = await pumpReady(tester, card(), size: tall, configure: fixedPin);
      expect(find.text('Şu an açık servis oturumu yok.'), findsOneWidget);

      await tester.tap(byKeyName('btn_generate_service_pin'));
      await flush(tester);

      expect(h.e1.count('createServiceToken'), 1);
      expect(find.text('123 456'), findsOneWidget);
      expect(find.textContaining('yalnızca şimdi gösterilir'), findsOneWidget);
      expect(find.text('Kalan süre 2 sa 00 dk 00 sn'), findsOneWidget);

      h.clock.advance(const Duration(minutes: 61, seconds: 1));
      await flush(tester);
      expect(find.text('Kalan süre 58:59'), findsOneWidget);
    });

    testWidgets('süre bitince PIN kendiliğinden gizlenir', (tester) async {
      final h = await pumpReady(tester, card(), size: tall, configure: fixedPin);
      await tester.tap(byKeyName('btn_generate_service_pin'));
      await flush(tester);
      expect(byKeyName('text_service_pin'), findsOneWidget);

      h.clock.advance(const Duration(hours: 2, seconds: 5));
      await flush(tester);
      expect(byKeyName('text_service_pin'), findsNothing);
    });

    testWidgets('"PIN\'i gizle" PIN\'i siler; kart yeniden kurulunca PIN yeniden gösterilmez', (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      await tester.tap(byKeyName('btn_generate_service_pin'));
      await flush(tester);
      await tester.tap(byKeyName('btn_hide_service_pin'));
      await flush(tester);
      expect(byKeyName('text_service_pin'), findsNothing);
      expect(h.state.servicePin, isNotNull, reason: 'durum bellekte tutsa da arayüz yeniden göstermez');

      // Sayfa yeniden kurulur (ör. ayarlardan çıkıp girme).
      await pumpPage(tester, h.state, scaffolded(const SizedBox()), size: tall);
      await pumpPage(tester, h.state, card(), size: tall);
      expect(byKeyName('text_service_pin'), findsNothing);
    });

    testWidgets('yeniden üretimde eski PIN\'in iptal edileceği uyarısı çıkar; vazgeçilirse yeni PIN üretilmez', (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      await tester.tap(byKeyName('btn_generate_service_pin'));
      await flush(tester);
      expect(find.text('Yeni PIN Üret'), findsOneWidget);

      await tester.tap(byKeyName('btn_generate_service_pin'));
      await tester.pumpAndSettle();
      expect(byKeyName('dialog_replace_service_pin'), findsOneWidget);
      expect(find.textContaining('iptal olur'), findsOneWidget);
      await tester.tap(byKeyName('btn_replace_pin_cancel'));
      await tester.pumpAndSettle();
      expect(h.e1.count('createServiceToken'), 1);

      await tester.tap(byKeyName('btn_generate_service_pin'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_replace_pin_confirm'));
      await flush(tester);
      expect(h.e1.count('createServiceToken'), 2);
    });

    testWidgets('sunucuda etkin bir PIN zaten varsa ilk üretimde de iptal uyarısı çıkar', (tester) async {
      final h = await pumpReady(
        tester,
        card(),
        size: tall,
        configure: (h) => h.e1.serviceTokens = <ServiceTokenSummary>[
          const ServiceTokenSummary(id: 't1', status: 'active'),
        ],
      );
      await flush(tester);
      await tester.tap(byKeyName('btn_generate_service_pin'));
      await tester.pumpAndSettle();
      expect(byKeyName('dialog_replace_service_pin'), findsOneWidget);
      expect(h.e1.count('createServiceToken'), 0, reason: 'onaydan önce üretilmez');
    });

    testWidgets('açık servis oturumları listelenir; erişim kapatılınca PIN ve oturumlar iptal edilir', (tester) async {
      final h = await pumpReady(
        tester,
        card(),
        size: tall,
        configure: (h) {
          fixedPin(h);
          h.e1.serviceSessions = <ServiceSessionSummary>[
            ServiceSessionSummary(id: 's1', technicianName: 'Usta Mehmet', expiresAt: kTestNow.add(const Duration(hours: 1))),
          ];
        },
      );
      await flush(tester);
      expect(byKeyName('card_service_session_s1'), findsOneWidget);
      expect(find.text('Usta Mehmet'), findsOneWidget);

      await tester.tap(byKeyName('btn_generate_service_pin'));
      await flush(tester);
      expect(byKeyName('text_service_pin'), findsOneWidget);

      await tester.tap(byKeyName('btn_revoke_service_access'));
      await tester.pumpAndSettle();
      expect(byKeyName('dialog_revoke_service_access'), findsOneWidget);
      expect(h.e1.count('revokeServiceAccess'), 0, reason: 'onaydan önce iptal edilmez');
      await tester.tap(byKeyName('btn_revoke_confirm'));
      await flush(tester);

      expect(h.e1.count('revokeServiceAccess'), 1);
      expect(byKeyName('text_service_pin'), findsNothing, reason: 'ekrandaki PIN de silinir');
      expect(find.textContaining('1 PIN ve 1 oturum iptal edildi'), findsOneWidget);
    });

    testWidgets('PIN üretme hatası ham istisna değil Türkçe mesajla gösterilir', (tester) async {
      final h = await pumpReady(
        tester,
        card(),
        size: tall,
        configure: (h) => h.e1.serviceTokenError = kServerError,
      );
      await tester.tap(byKeyName('btn_generate_service_pin'));
      await flush(tester);
      expect(find.text(kServerError.message), findsOneWidget);
      expect(byKeyName('text_service_pin'), findsNothing);
      expect(h.e1.count('createServiceToken'), 1);
      expect(tester.widget<OutlinedButton>(byKeyName('btn_generate_service_pin')).onPressed, isNotNull);
    });

    testWidgets('oturum listesi yüklenemezse "yüklenemedi" + yeniden dene gösterilir', (tester) async {
      final h = await pumpReady(
        tester,
        card(),
        size: tall,
        configure: (h) {
          h.e1.serviceSessionsError = kNetworkError;
          h.e1.serviceSessions = <ServiceSessionSummary>[const ServiceSessionSummary(id: 's9', technicianName: 'Usta Ali')];
        },
      );
      await flush(tester);
      expect(find.text('Oturumlar yüklenemedi.'), findsOneWidget);
      expect(find.text('Şu an açık servis oturumu yok.'), findsNothing, reason: 'hata "oturum yok" sanılmaz');

      h.e1.serviceSessionsError = null;
      await tester.tap(byKeyName('btn_sessions_retry'));
      await flush(tester);
      expect(find.text('Usta Ali'), findsOneWidget);
    });
  });

  group('Cihaz adresi kartı', () {
    Widget card() => scaffolded(const DeviceHostCard());

    testWidgets('yerel olmayan (internet) adres reddedilir; hata alanın altında görünür ve önceki adres korunur',
        (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      await tester.runAsync(() => h.state.setHost('192.168.1.20'));
      await tester.enterText(byKeyName('field_host'), 'example.com');
      await tester.tap(byKeyName('btn_save_host'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);

      expect(find.text('Geçersiz cihaz adresi.'), findsOneWidget);
      expect(h.state.host, '192.168.1.20', reason: 'geçersiz adres önceki adresi bozmaz');
      expect(find.textContaining('Cihaza bağlanıldı'), findsNothing);
    });

    testWidgets('bulut modunda geçerli adres yalnızca kaydedilir; "bağlanıldı" denmez', (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      await tester.enterText(byKeyName('field_host'), '192.168.1.55');
      await tester.tap(byKeyName('btn_save_host'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);

      expect(h.state.host, '192.168.1.55');
      expect(find.text('Adres kaydedildi. Yerel ağ moduna geçtiğinizde kullanılacak.'), findsOneWidget);
      expect(find.textContaining('bağlanıldı'), findsNothing);
    });

    testWidgets('yerel modda cihaz yanıt verirse "Cihaza bağlanıldı" gösterilir', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{
            'device': 'AHBU-S3-TEST01',
            'name': 'Pano',
            'provisioned': true,
            'relays': <dynamic>[],
            'shutters': <dynamic>[],
            'dis': <dynamic>[],
          }));
      await pumpPage(tester, h.state, card(), size: tall);

      await tester.enterText(byKeyName('field_host'), '192.168.1.20');
      await tester.tap(byKeyName('btn_save_host'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await flush(tester);
      expect(find.text('Cihaza bağlanıldı (192.168.1.20).'), findsOneWidget);
    });

    testWidgets('yerel modda cihaza ulaşılamazsa başarı DEĞİL uyarı gösterilir', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => throw http.ClientException('erişilemiyor'));
      await pumpPage(tester, h.state, card(), size: tall);

      await tester.enterText(byKeyName('field_host'), '192.168.1.20');
      await tester.tap(byKeyName('btn_save_host'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await flush(tester);
      expect(find.textContaining('Adres kaydedildi ancak cihaza ulaşılamadı'), findsOneWidget);
      expect(find.textContaining('Cihaza bağlanıldı'), findsNothing);
    });

    testWidgets('boş adres doğrulama mesajı verir ve istek göndermez', (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      await tester.enterText(byKeyName('field_host'), '   ');
      await tester.tap(byKeyName('btn_save_host'));
      await flush(tester);
      expect(find.text('Cihaz adresini girin (örn. 192.168.1.20).'), findsOneWidget);
      expect(h.state.host, isEmpty);
    });

    testWidgets('hızlı adres çipleri alanı doldurur: kurtarma ağı ve cihazın bildirdiği son adres', (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      h.mqtt.emitStateJson(stateJson(ip: '192.168.1.77'));
      await flush(tester);

      await tester.tap(byKeyName('chip_host_ap'));
      await flush(tester);
      expect(tester.widget<TextField>(byKeyName('field_host')).controller!.text, '192.168.4.1');

      await tester.tap(byKeyName('chip_host_last'));
      await flush(tester);
      expect(tester.widget<TextField>(byKeyName('field_host')).controller!.text, '192.168.1.77');
      expect(find.textContaining('192.168.1.197'), findsNothing, reason: 'sabit demo adresi yok');
    });

    testWidgets('cihaz anahtarı: kısa anahtar reddedilir; geçerli anahtar kaydedilir ve alan temizlenir', (tester) async {
      final h = await pumpReady(tester, card(), size: tall);
      await tester.enterText(byKeyName('field_local_key'), 'kisa');
      await tester.tap(byKeyName('btn_save_local_key'));
      await flush(tester);
      expect(find.text('Cihaz anahtarı 8 ile 32 karakter arasında olmalıdır.'), findsOneWidget);

      await tester.enterText(byKeyName('field_local_key'), 'gecerli-anahtar-1');
      await tester.tap(byKeyName('btn_save_local_key'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await flush(tester);
      expect(h.state.hasLocalKey, isTrue);
      expect(find.text('Cihaz anahtarı kaydedildi.'), findsOneWidget);
      expect(tester.widget<TextField>(byKeyName('field_local_key')).controller!.text, isEmpty);
    });

    testWidgets('anahtar alanı gizlidir (obscure) ve değer ekranda görünmez', (tester) async {
      await pumpReady(tester, card(), size: tall);
      expect(tester.widget<TextField>(byKeyName('field_local_key')).obscureText, isTrue);
    });
  });

  group('Biyometrik kart', () {
    Widget card() => scaffolded(const BiometricCard());

    testWidgets('destek yoksa anahtar pasif ve açıklama gösterilir', (tester) async {
      await pumpReady(tester, card());
      expect(find.text('Cihazınızda biyometrik donanım bulunamadı'), findsOneWidget);
      expect(tester.widget<Switch>(byKeyName('switch_biometric')).onChanged, isNull);
    });

    testWidgets('açmak kimlik doğrulaması ister; doğrulanamazsa ayar değişmez ve söylenir', (tester) async {
      final h = await pumpReady(tester, card(), biometricSupported: true);
      h.biometric.authResult = false;
      await tester.tap(byKeyName('switch_biometric'));
      await flush(tester);

      expect(h.biometric.authenticateCalls, 1);
      expect(h.state.isBiometricEnabled, isFalse);
      expect(find.text('Kimlik doğrulanamadı. Biyometrik giriş açılmadı.'), findsOneWidget);
    });

    testWidgets('açıkken kapatmak da kimlik doğrulaması ister; doğrulanamazsa açık kalır', (tester) async {
      final h = await pumpReady(tester, card(), biometricSupported: true);
      await tester.tap(byKeyName('switch_biometric'));
      await flush(tester);
      expect(h.state.isBiometricEnabled, isTrue);
      expect(h.biometric.authenticateCalls, 1);

      h.biometric.authResult = false;
      await tester.tap(byKeyName('switch_biometric'));
      await flush(tester);
      expect(h.biometric.authenticateCalls, 2, reason: 'kapatmak da doğrulama ister');
      expect(h.state.isBiometricEnabled, isTrue);
      expect(find.text('Kimlik doğrulanamadı. Biyometrik giriş açık kalıyor.'), findsOneWidget);

      h.biometric.authResult = true;
      await tester.tap(byKeyName('switch_biometric'));
      await flush(tester);
      expect(h.state.isBiometricEnabled, isFalse);
    });
  });

  group('Tema ve hesap kartları', () {
    testWidgets('tema seçimi duruma yazılır ve seçili düğme işaretlenir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ThemeSelectorCard()));
      expect(find.text('Karanlık Mod (Varsayılan)'), findsOneWidget);

      await tester.tap(byKeyName('btn_theme_light'));
      await flush(tester);
      expect(h.state.themeMode, ThemeMode.light);
      expect(find.text('Aydınlık Mod'), findsOneWidget);

      await tester.tap(byKeyName('btn_theme_system'));
      await flush(tester);
      expect(h.state.themeMode, ThemeMode.system);
      expect(find.text('Sistem Teması'), findsOneWidget);
    });

    testWidgets('hesap kartı rolleri Türkçe gösterir (ham "USER"/"SERVICE_USER" yok)', (tester) async {
      await pumpReady(tester, scaffolded(const AccountCard()), role: 'owner');
      expect(find.text('Ayşe Yılmaz'), findsOneWidget);
      expect(find.text('Ev Kullanıcısı'), findsOneWidget);
      expect(find.text('Ev Sahibi'), findsOneWidget);
      expect(find.text('USER'), findsNothing);
    });

    testWidgets('oturumu kapatma onay ister; vazgeçilirse oturum sürer, onaylanırsa kapanır', (tester) async {
      final h = await pumpReady(tester, scaffolded(const AccountCard()), size: tall);
      await tester.tap(byKeyName('btn_logout'));
      await tester.pumpAndSettle();
      expect(byKeyName('btn_logout_confirm'), findsOneWidget);
      await tester.tap(byKeyName('btn_logout_cancel'));
      await tester.pumpAndSettle();
      expect(h.state.authStatus, AuthStatus.authenticated);

      await tester.tap(byKeyName('btn_logout'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_logout_confirm'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.state.authStatus, AuthStatus.unauthenticated);
    });
  });
}
