import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/biometric_auth_service.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import '../ui/e2_support.dart' show settle;

/// Biyometrik etkinleştirme / kilit açma akışının GERÇEK eklenti davranışına karşı sağlamlığı.
///
/// İki model kullanılır:
///
/// * [PluginLikeLocalAuth] + GERÇEK [BiometricAuthService] ([Rig]): eklenti `LocalAuthentication`
///   sınırında modellenir. Sarmalayıcının hata yutması da, servis katmanında yapılacak bir düzeltme de
///   (ör. tek-uçuş) bu testlerle sınanır. Çocuk kilidi onayı servisi DOĞRUDAN çağırdığı için
///   (child_lock_card.dart:328) yarış testleri bu modelle yazılmıştır: `authenticate`'i ezen bir
///   `FakeBiometric` türevi servis katmanını devre dışı bırakırdı.
/// * [ExclusiveFakeBiometric] (`FakeBiometric` türevi): servis sınırında "bir çağrı beklerken gelen ikinci
///   çağrı hemen false döner" modeli; yalnızca durum katmanının kendi yarışı (çift "yeniden dene") için.
/// * [ThrowingBiometric] (`FakeBiometric` türevi): gerçek sarmalayıcı hiç fırlatmadığından istisna
///   güvenliği için.
///
/// Modelin dayandığı kaynak (local_auth 2.3.0 / local_auth_android 1.0.56):
/// * `LocalAuthPlugin.authenticate`: `authInProgress` iken `ERROR_ALREADY_IN_PROGRESS` döner
///   (LocalAuthPlugin.java:114-117); Dart tarafı bunu `PlatformException('auth_in_progress')` yapar
///   (local_auth_android.dart:56-60); sarmalayıcı istisnayı `false` yapar ve nedeni `lastFailure`'da saklar
///   (biometric_auth_service.dart `_authenticate`).
/// * `stickyAuth: true`: uygulama arka plana gidince istem iptal edilir ama sonuç GÖNDERİLMEZ; dönüşte
///   yeniden gösterilir (AuthenticationHelper.java:152-157, 188-195). Yani `authenticate` arka plan
///   süresince bekler: modelde istem `paused`/`resumed` boyunca "ekranda" kalır.
/// * `getEnrolledBiometrics` Android'de yalnızca `weak` / `strong` döndürür (LocalAuthPlugin.java:84-95).
///
/// `[B1]`..`[B3]` servis katmanındaki tek-uçuş düzeltmesiyle YEŞİLDİR; `[B4]`..`[B7]` durum katmanı
/// (`AutomationState`: `_unlockWithBiometrics` istisna/arka plan bayrağı, `toggleBiometric`) düzeltmeleriyle
/// YEŞİLDİR (WP-BIO: B6 + `toggleBiometric` epoch denetimi dev'de PF-30 ile zaten vardı).
/// "SORUN DEĞİL" ve bölüm 0 testleri yeşildir; düzeltmeden sonra da yeşil kalmalıdır.
void main() {
  group('0. Eklenti modeli ve sarmalayıcı (belgeleyici)', () {
    test('model: bekleyen doğrulama varken ikinci platform çağrısı auth_in_progress ile reddedilir', () async {
      final plugin = PluginLikeLocalAuth();

      final first = plugin.authenticate(localizedReason: 'ilk');
      await expectLater(
        plugin.authenticate(localizedReason: 'ikinci'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'auth_in_progress')),
      );
      expect(plugin.promptsShown, 1, reason: 'ikinci çağrı istem göstermez');
      expect(plugin.rejectedInProgress, 1);

      plugin.completePrompt(true);
      expect(await first, isTrue);
      final third = plugin.authenticate(localizedReason: 'üçüncü');
      expect(plugin.promptsShown, 2, reason: 'ilk doğrulama bitince yenisi başlatılabilir');
      plugin.completePrompt(false);
      expect(await third, isFalse);
    });

    test('sarmalayıcı her eklenti hata kodunda false döner ve istem göstermez (neden lastFailure alanında; bkz. biometric_auth_service_test)', () async {
      const codes = <String>[
        'NotAvailable',
        'NotEnrolled',
        'LockedOut',
        'PermanentlyLockedOut',
        'auth_in_progress',
        'no_activity',
        'no_fragment_activity',
      ];
      for (final code in codes) {
        final plugin = PluginLikeLocalAuth()..immediateError = code;
        final service = BiometricAuthService(auth: plugin);
        expect(await service.authenticate(reason: 'deneme'), isFalse, reason: code);
        expect(plugin.promptsShown, 0, reason: '$code: sistem istemi gösterilmedi');
      }
    });

    test('desteklenmeyen cihazda sarmalayıcı eklentiye authenticate göndermeden false döner', () async {
      // Donanım var ama ekran kilidi / kayıtlı biyometri yok: isDeviceSupported=false (LocalAuthPlugin.java:76-78).
      final plugin = PluginLikeLocalAuth()..deviceSupported = false;
      final service = BiometricAuthService(auth: plugin);

      expect(await service.isBiometricSupported(), isFalse);
      expect(await service.authenticate(reason: 'deneme'), isFalse);
      expect(plugin.platformAuthenticateCalls, 0);
    });

    test('Android etiketi: "Parmak İzi" yalnızca GÜÇLÜ biyometri kayıtlıysa çıkar; kayıt yoksa "Biyometrik Giriş"', () async {
      final plugin = PluginLikeLocalAuth();
      final service = BiometricAuthService(auth: plugin);

      plugin.enrolled = <BiometricType>[BiometricType.weak, BiometricType.strong];
      expect(await service.getBiometricLabel(), 'Parmak İzi');
      plugin.enrolled = <BiometricType>[BiometricType.weak];
      expect(await service.getBiometricLabel(), 'Biyometrik Giriş');
      plugin.enrolled = <BiometricType>[];
      expect(await service.getBiometricLabel(), 'Biyometrik Giriş');
      expect(await service.isBiometricSupported(), isTrue,
          reason: 'kayıtlı parmak izi olmasa da ekran kilidi (PIN) varsa "destekleniyor" sayılır');
    });
  });

  group('1. Eşzamanlılık (eklenti aynı anda tek doğrulamaya izin verir)', () {
    test(
        '[B1] kilit ekranında çift "yeniden dene" (FakeBiometric türevi model): ilk istem beklerken başarısız GÖRÜNMEZ ve '
        'yaşam döngüsü kapısı kapalı kalır', () async {
      final biometric = ExclusiveFakeBiometric();
      final h = lockedHarness(biometric, await storedSession());
      await pumpEventQueue();
      biometric.completePrompt(false); // açılıştaki istem iptal edildi: kilit ekranı "yeniden dene" gösterir
      await h.state.ready;
      await pumpEventQueue();
      expect(h.state.biometricFailed, isTrue, reason: 'hazırlık');

      // auth_gate.dart:322 -> onPressed: () => unawaited(state.retryBiometricAuth()); aynı karede iki dokunuş.
      final first = h.state.retryBiometricAuth();
      final second = h.state.retryBiometricAuth();
      await pumpEventQueue();

      expect(biometric.promptVisible, isTrue, reason: 'hazırlık: ilk çağrının istemi bekliyor');
      expect(
        <String>[
          if (biometric.rejectedInProgress != 0)
            'servise yarışan ${biometric.rejectedInProgress} authenticate çağrısı daha yapıldı (hemen false döndü)',
          if (h.state.biometricFailed) 'ilk istem beklerken biometricFailed=true (kilit ekranı "tamamlanamadı" gösterir)',
          if (!h.state.biometricChecking)
            'ilk istem beklerken biometricChecking=false (yaşam döngüsü kapısı açıldı)',
          if (h.state.authStatus != AuthStatus.checking) 'authStatus=${h.state.authStatus}',
        ],
        isEmpty,
        reason: 'sistem istemi açıkken ikinci "yeniden dene" durumu bozmamalı',
      );

      biometric.completePrompt(true);
      expect(await first, isTrue);
      expect(await second, isTrue, reason: 'ikinci çağrı da istemin sonucunu alır');
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.biometricFailed, isFalse);
      expect(h.state.biometricChecking, isFalse);
    });

    test(
        '[B1] kilit ekranında çift "yeniden dene" (eklenti modeli + gerçek sarmalayıcı): ilk istem beklerken başarısız '
        'GÖRÜNMEZ ve yaşam döngüsü kapısı kapalı kalır', () async {
      final rig = await coldStartLockedRig();
      rig.plugin.completePrompt(false);
      await rig.state.ready;
      await pumpEventQueue();
      expect(rig.state.biometricFailed, isTrue, reason: 'hazırlık');
      rig.plugin.resetCounters();

      final first = rig.state.retryBiometricAuth();
      final second = rig.state.retryBiometricAuth();
      await pumpEventQueue();

      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: ilk çağrının sistem istemi ekranda');
      expect(
        <String>[
          if (rig.plugin.rejectedInProgress != 0)
            'eklenti ${rig.plugin.rejectedInProgress} çağrıyı auth_in_progress ile reddetti',
          if (rig.state.biometricFailed) 'ilk istem beklerken biometricFailed=true (kilit ekranı "tamamlanamadı" gösterir)',
          if (!rig.state.biometricChecking)
            'ilk istem beklerken biometricChecking=false (yaşam döngüsü kapısı açıldı)',
          if (rig.state.authStatus != AuthStatus.checking) 'authStatus=${rig.state.authStatus}',
        ],
        isEmpty,
        reason: 'sistem istemi açıkken ikinci "yeniden dene" durumu bozmamalı',
      );

      rig.plugin.completePrompt(true);
      expect(await first, isTrue);
      expect(await second, isTrue, reason: 'ikinci çağrı da istemin sonucunu alır');
    });

    test(
        'SORUN DEĞİL (gerileme bekçisi): çift "yeniden dene" başarıyla bitince oturum TAM BİR KEZ başlar '
        '(_startSession / _resumeSession çiftlenmez)', () async {
      final rig = await coldStartLockedRig();
      rig.plugin.completePrompt(false);
      await rig.state.ready;
      await pumpEventQueue();
      rig.plugin.resetCounters();

      final first = rig.state.retryBiometricAuth();
      final second = rig.state.retryBiometricAuth();
      await pumpEventQueue();
      await approveAllPrompts(rig);
      await first;
      await second;
      await pumpEventQueue();

      expect(rig.state.authStatus, AuthStatus.authenticated);
      expect(rig.state.biometricFailed, isFalse);
      expect(rig.state.biometricChecking, isFalse);
      expect(rig.plugin.promptsShown, 1, reason: 'kullanıcı tek istem görür');
      expect(rig.cloud.count('fetchHomes'), 1, reason: 'ev listesi bir kez alınır');
      expect(rig.mqtt.startCount, 1, reason: 'canlı bağlantı bir kez başlar');
      expect(rig.state.activeHome?.id, kHomeA);
    });

    testWidgets('[B1] kilit ekranı: aynı karede çift dokunuş, sistem istemi açıkken "doğrulama tamamlanamadı" göstermez',
        (tester) async {
      final rig = await coldStartLockedRig(flush: tester.pump);
      rig.plugin.completePrompt(false);
      await rig.state.ready;
      await pumpApp(tester, state: rig.state, child: const AuthGate());
      await settle(tester);
      expect(find.byKey(const Key('btn_biometric_retry')), findsOneWidget, reason: 'hazırlık: kilit ekranı');
      rig.plugin.resetCounters();

      await tester.tap(find.byKey(const Key('btn_biometric_retry')));
      await tester.tap(find.byKey(const Key('btn_biometric_retry')), warnIfMissed: false);
      await settle(tester);

      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: sistem istemi ekranda');
      expect(
        <String>[
          if (rig.plugin.rejectedInProgress != 0)
            'eklenti ${rig.plugin.rejectedInProgress} çağrıyı auth_in_progress ile reddetti',
          if (find.byKey(const Key('biometric_locked')).evaluate().isNotEmpty)
            'sistem istemi açıkken kilit ekranı "doğrulama tamamlanamadı" + yeniden dene gösteriyor',
          if (find.byKey(const Key('splash_checking')).evaluate().isEmpty) '"doğrulanıyor" durumu gösterilmiyor',
        ],
        isEmpty,
      );

      rig.plugin.completePrompt(true);
      await settle(tester, frames: 8);
      expect(rig.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.byKey(const Key('biometric_locked')), findsNothing);
    });

    test('SORUN DEĞİL: kilit açma istemi beklerken toggleBiometric kilit açmayı bozmaz; durum tutarlı kalır', () async {
      final rig = await signedInRig();
      backgroundFor(rig, const Duration(seconds: 45));
      await pumpEventQueue();
      expect(rig.state.authStatus, AuthStatus.checking, reason: 'hazırlık: yeniden kilit');
      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: kilit açma istemi ekranda');

      final toggle = rig.state.toggleBiometric(false);
      await pumpEventQueue();

      expect(rig.state.authStatus, AuthStatus.checking, reason: 'kilit, toggle ile atlatılamaz');
      expect(rig.state.biometricChecking, isTrue);
      expect(rig.state.biometricFailed, isFalse);
      expect(rig.state.isBiometricEnabled, isTrue, reason: 'doğrulanmadan tercih değişmez');

      await approveAllPrompts(rig);
      final toggled = await toggle;
      await pumpEventQueue();

      expect(rig.state.authStatus, AuthStatus.authenticated);
      expect(rig.state.biometricFailed, isFalse);
      expect(rig.state.biometricChecking, isFalse);
      expect(rig.state.isBiometricEnabled, !toggled, reason: 'tercih yalnızca toggle doğrulandıysa değişir');
    });

    test(
        '[B2] biyometrik girişi KAPATMA doğrulaması beklerken arka plandan >= 30 sn sonra dönüş: yarışan ikinci doğrulama '
        'başlatılmaz, kilit ekranı başarısız göstermez; istem başarıyla bitince uygulama KİLİTLİ KALMAZ', () async {
      final rig = await signedInRig();
      final toggle = rig.state.toggleBiometric(false); // BiometricCard._toggle(false) (appearance_cards.dart:160)
      await pumpEventQueue();
      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: kapatma doğrulaması istemi ekranda');

      // Kullanıcı Ana Ekran'a basar / ekran kapanır; stickyAuth istemi askıda tutar; >= 30 sn sonra döner.
      backgroundFor(rig, const Duration(seconds: 45));
      await pumpEventQueue();

      final whilePending = <String>[
        if (rig.plugin.rejectedInProgress != 0)
          'yeniden kilit, süren doğrulamayla yarışan ikinci bir doğrulama başlattı (auth_in_progress x${rig.plugin.rejectedInProgress})',
        if (rig.state.biometricFailed) 'istem hâlâ ekrandayken biometricFailed=true',
      ];

      rig.plugin.completePrompt(true); // kullanıcı (yeniden gösterilen) istemi başarıyla tamamlar
      final toggled = await toggle;
      await pumpEventQueue();

      expect(
        <String>[
          ...whilePending,
          if (!toggled) 'kapatma doğrulaması false döndü',
          if (rig.state.isBiometricEnabled) 'biyometrik giriş kapanmadı',
          if (rig.state.authStatus != AuthStatus.authenticated)
            'başarılı doğrulamadan sonra authStatus=${rig.state.authStatus} (uygulama kilitli kaldı)',
          if (rig.state.biometricFailed) 'başarılı doğrulamadan sonra biometricFailed=true',
          if (rig.plugin.promptsShown != 1) 'kullanıcıya ${rig.plugin.promptsShown} istem gösterildi (beklenen 1)',
          if (!rig.mqtt.isConnected) 'canlı bağlantı yeniden kurulmadı',
        ],
        isEmpty,
        reason: 'kullanıcı kimliğini az önce doğruladı: uygulama açık ve tutarlı olmalı',
      );
    });

    test(
        '[B2] çocuk kilidi doğrulaması beklerken arka plandan >= 30 sn sonra dönüş: yarışan ikinci doğrulama başlatılmaz; '
        'istem başarıyla bitince uygulama KİLİTLİ KALMAZ', () async {
      final rig = await signedInRig();
      // ChildLockDisableSheet._verify (child_lock_card.dart:328): servis DOĞRUDAN çağrılır.
      final verify = rig.state.biometricService.authenticate(
        reason: 'Çocuk kilidini kaldırmak için kimliğinizi doğrulayın',
      );
      await pumpEventQueue();
      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: çocuk kilidi doğrulama istemi ekranda');

      backgroundFor(rig, const Duration(seconds: 45));
      await pumpEventQueue();

      final whilePending = <String>[
        if (rig.plugin.rejectedInProgress != 0)
          'yeniden kilit, süren doğrulamayla yarışan ikinci bir doğrulama başlattı (auth_in_progress x${rig.plugin.rejectedInProgress})',
        if (rig.state.biometricFailed) 'istem hâlâ ekrandayken biometricFailed=true',
      ];

      rig.plugin.completePrompt(true);
      final verified = await verify;
      await pumpEventQueue();

      expect(
        <String>[
          ...whilePending,
          if (!verified) 'çocuk kilidi doğrulaması false döndü',
          if (rig.state.authStatus != AuthStatus.authenticated)
            'başarılı doğrulamadan sonra authStatus=${rig.state.authStatus} (uygulama kilitli kaldı)',
          if (rig.state.biometricFailed) 'başarılı doğrulamadan sonra biometricFailed=true',
          if (rig.plugin.promptsShown != 1) 'kullanıcıya ${rig.plugin.promptsShown} istem gösterildi (beklenen 1)',
        ],
        isEmpty,
        reason: 'kullanıcı kimliğini az önce doğruladı: uygulama açık ve tutarlı olmalı',
      );
    });

    testWidgets(
        '[B2] kapı: kapatma doğrulaması sürerken yeniden kilit, istem açıkken "doğrulama tamamlanamadı" göstermez; '
        'başarıdan sonra pano açılır', (tester) async {
      final rig = await signedInRig(flush: tester.pump);
      await pumpApp(tester, state: rig.state, child: const AuthGate());
      await settle(tester, frames: 6);
      expect(find.byType(DashboardPage), findsOneWidget, reason: 'hazırlık: pano açık');

      final toggle = rig.state.toggleBiometric(false);
      await tester.pump();
      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık');

      backgroundFor(rig, const Duration(seconds: 45));
      await settle(tester, frames: 8);

      final lockedWhilePrompt = find.byKey(const Key('biometric_locked')).evaluate().isNotEmpty;

      rig.plugin.completePrompt(true);
      await toggle;
      await settle(tester, frames: 8);

      expect(
        <String>[
          if (lockedWhilePrompt) 'sistem istemi açıkken kilit ekranı "doğrulama tamamlanamadı" gösterdi',
          if (find.byKey(const Key('biometric_locked')).evaluate().isNotEmpty)
            'başarılı doğrulamadan sonra kilit ekranı hâlâ "doğrulama tamamlanamadı" gösteriyor',
          if (find.byType(DashboardPage).evaluate().isEmpty) 'başarılı doğrulamadan sonra pano açılmadı',
        ],
        isEmpty,
      );
    });

    test(
        '[B3] istem diyaloğu ile Ayarlar kartı aynı anda etkinleştirirse: ikinci çağrı istem beklerken başarısız DÖNMEZ; '
        'ikisi de istemin sonucunu alır', () async {
      final rig = await signedInRig(biometricEnabled: false);
      expect(rig.state.shouldPromptBiometrics, isTrue, reason: 'hazırlık: ilk giriş istemi bekliyor');

      // BiometricPromptDialog._enable (biometric_prompt_dialog.dart:68) ve BiometricCard._toggle(true)
      // (appearance_cards.dart:158) aynı durum yöntemini çağırır.
      bool? cardEarlyResult;
      final fromDialog = rig.state.enableBiometricWithVerification();
      final fromCard = rig.state.enableBiometricWithVerification();
      unawaited(fromCard.then((value) => cardEarlyResult = value));
      await pumpEventQueue();
      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: ilk çağrının istemi ekranda');

      final whilePending = <String>[
        if (rig.plugin.rejectedInProgress != 0)
          'eklenti ${rig.plugin.rejectedInProgress} çağrıyı auth_in_progress ile reddetti',
        if (cardEarlyResult != null)
          'ikinci çağrı, istem hâlâ ekrandayken $cardEarlyResult ile sonuçlandı (kart "Kimlik doğrulanamadı" gösterir)',
      ];

      rig.plugin.completePrompt(true);
      final dialogResult = await fromDialog;
      final cardResult = await fromCard;
      await pumpEventQueue();

      expect(
        <String>[
          ...whilePending,
          if (!dialogResult) 'diyalog çağrısı false döndü',
          if (!cardResult) 'kart çağrısı false döndü (özellik açıldığı halde)',
          if (!rig.state.isBiometricEnabled) 'biyometrik giriş açılmadı',
          if (rig.state.shouldPromptBiometrics) 'istem "gösterildi" olarak işaretlenmedi',
          if (rig.plugin.promptsShown != 1) 'kullanıcıya ${rig.plugin.promptsShown} istem gösterildi (beklenen 1)',
        ],
        isEmpty,
      );
    });

    test('[B6] kilit açma istemi beklerken oturum sona ererse: istemin sonradan BAŞARIYLA bitmesi oturumu açık göstermez',
        () async {
      final rig = await signedInRig();
      backgroundFor(rig, const Duration(seconds: 45));
      await pumpEventQueue();
      expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: yeniden kilit istemi ekranda');

      // Sunucu refresh token'ı reddetti / servis oturumu süresi doldu (EvCloudApiService.onSessionExpired).
      rig.cloud.onSessionExpired!(SessionEndReason.refreshRejected);
      await pumpEventQueue();
      expect(rig.state.authStatus, AuthStatus.unauthenticated, reason: 'hazırlık: oturum kapandı');
      expect(rig.state.currentUser, isNull, reason: 'hazırlık');

      rig.plugin.completePrompt(true);
      await pumpEventQueue();

      expect(rig.state.authStatus, AuthStatus.unauthenticated,
          reason: 'kullanıcısız/belirteçsiz oturum "authenticated" sayılmamalı (currentUser=${rig.state.currentUser})');
    });
  });

  group('3. Yaşam döngüsü kapısı (toggle / çocuk kilidi doğrulaması _biometricChecking kurmaz)', () {
    test('SORUN DEĞİL: etkinleştirme doğrulaması sırasında kısa (< 30 sn) paused -> resumed: yeniden kilit yok, oturum sürer',
        () async {
      final rig = await signedInRig(biometricEnabled: false);
      final enabling = rig.state.enableBiometricWithVerification();
      await pumpEventQueue();

      // Android <= 9: cihaz kimlik bilgisi ayrı bir activity ile sorulur (uygulama durur ve geri döner).
      backgroundFor(rig, const Duration(seconds: 10));
      await pumpEventQueue();

      expect(rig.state.authStatus, AuthStatus.authenticated, reason: 'yeniden kilit yok');
      expect(rig.plugin.rejectedInProgress, 0, reason: 'yarışan doğrulama başlatılmadı');
      expect(rig.plugin.promptVisible, isTrue, reason: 'etkinleştirme istemi sürüyor');

      rig.plugin.completePrompt(true);
      expect(await enabling, isTrue);
      await pumpEventQueue();
      expect(rig.state.isBiometricEnabled, isTrue);
      expect(rig.state.authStatus, AuthStatus.authenticated);
      expect(rig.plugin.promptsShown, 1);
      expect(rig.mqtt.isConnected, isTrue, reason: 'ön plana dönüşte canlı bağlantı yeniden kurulur');
    });

    test(
        'SORUN DEĞİL: etkinleştirme doğrulaması sırasında >= 30 sn paused -> resumed (sonuç resumed\'dan SONRA): '
        'özellik henüz kapalı olduğundan yeniden kilit yok', () async {
      final rig = await signedInRig(biometricEnabled: false);
      final enabling = rig.state.enableBiometricWithVerification();
      await pumpEventQueue();

      backgroundFor(rig, const Duration(seconds: 45));
      await pumpEventQueue();

      expect(rig.state.authStatus, AuthStatus.authenticated);
      expect(rig.plugin.rejectedInProgress, 0);

      rig.plugin.completePrompt(true);
      expect(await enabling, isTrue);
      await pumpEventQueue();
      expect(rig.state.isBiometricEnabled, isTrue);
      expect(rig.state.authStatus, AuthStatus.authenticated, reason: 'etkinleştirmeden sonra yeniden kilit yok');
      expect(rig.plugin.promptsShown, 1, reason: 'çift istem yok');
    });

    test(
        '[B4] etkinleştirme doğrulaması sırasında >= 30 sn arka plan ve sonuç resumed\'dan ÖNCE gelirse: etkinleştirmenin '
        'hemen ardından yeniden kilit / ikinci istem OLMAZ', () async {
      final rig = await signedInRig(biometricEnabled: false);
      final enabling = rig.state.enableBiometricWithVerification();
      await pumpEventQueue();

      // Flutter "resumed"ı yalnızca activity resumed VE pencere odaklıyken gönderir (LifecycleChannel.java:84-90);
      // eklenti sonucu ise onActivityResult / istem kapanışında gönderir: sonuç, resumed'dan önce gelebilir.
      rig.state.handleLifecycleState(AppLifecycleState.paused);
      rig.clock.advance(const Duration(seconds: 45));
      rig.plugin.completePrompt(true);
      expect(await enabling, isTrue);
      await pumpEventQueue();
      rig.state.handleLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(
        <String>[
          if (rig.state.authStatus != AuthStatus.authenticated)
            'etkinleştirmeden hemen sonra yeniden kilit: authStatus=${rig.state.authStatus}',
          if (rig.plugin.promptsShown != 1)
            'kullanıcıya ${rig.plugin.promptsShown} istem gösterildi (çift istem; son neden: "${rig.plugin.reasons.last}")',
        ],
        isEmpty,
        reason: 'kullanıcı kimliğini arka plan süresinden SONRA doğruladı: hemen yeniden sorulmamalı',
      );
      expect(rig.state.isBiometricEnabled, isTrue);
    });

    test(
        '[B5] açılışta "paused" kilit açma başlamadan önce işlenir ve "resumed" istem sırasında yutulursa: kilit açıldıktan '
        'sonra uygulama "arka planda" takılı kalmaz', () async {
      final rig = Rig(autoInit: true, storage: await storedSession());
      // Soğuk açılışın ilk await'leri sürerken (tercihler, güvenli depo) activity durdu: _biometricChecking henüz false.
      rig.state.handleLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(rig.state.biometricChecking, isTrue, reason: 'hazırlık: kilit açma doğrulaması bekliyor');

      // Kullanıcı döndü: istem gösterilir; "resumed" _biometricChecking yüzünden yutulur.
      rig.state.handleLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      rig.plugin.completePrompt(true);
      await rig.state.ready;
      await pumpEventQueue();
      expect(rig.state.authStatus, AuthStatus.authenticated, reason: 'hazırlık: kilit açıldı');

      final violations = <String>[
        if (rig.state.isInBackground) 'kilit açıldı ama isInBackground=true (uygulama ön planda)',
        if (rig.mqtt.startCount != 1) 'canlı bağlantı (MQTT) başlamadı: startCount=${rig.mqtt.startCount}',
      ];

      // Bir süre kullanımdan sonra 5 sn'lik kısa bir arka plan gezisi yeniden kilit İSTEMEZ.
      rig.clock.advance(const Duration(minutes: 2));
      backgroundFor(rig, const Duration(seconds: 5));
      await pumpEventQueue();
      if (rig.state.authStatus != AuthStatus.authenticated) {
        violations.add('5 sn\'lik arka plan gezisi yeniden kilitledi (bayat _backgroundedAt): authStatus=${rig.state.authStatus}');
      }

      expect(violations, isEmpty);
    });
  });

  group('4. İstisna güvenliği (enjekte edilen servis fırlatırsa)', () {
    test(
        '[B7] açılışta authenticate istisna fırlatırsa: kilitli kalır, biometricChecking sıfırlanır ve kilit ekranı çıkış '
        'yolu sunar (biometricFailed)', () async {
      final biometric = ThrowingBiometric();
      final h = lockedHarness(biometric, await storedSession());
      await h.state.ready;
      await pumpEventQueue();

      expect(biometric.authenticateCalls, 1, reason: 'hazırlık: açılışta doğrulama denendi');
      expect(h.state.authStatus, AuthStatus.checking, reason: 'istisna kilidi AÇMAZ');
      expect(h.cloud.calls, isEmpty, reason: 'kilitliyken ağa çıkılmaz');
      expect(
        <String>[
          if (h.state.biometricChecking)
            'biometricChecking=true kaldı (yaşam döngüsü olayları yutulur; açılış ekranındaki çıkış yolu gizlenir)',
          if (!h.state.biometricFailed) 'biometricFailed=false (kilit ekranı yeniden dene / şifre ile giriş sunmaz)',
        ],
        isEmpty,
      );
    });

    test('[B7] retryBiometricAuth istisna fırlatmaz: false döner; sonraki deneme kilidi açar', () async {
      final biometric = ThrowingBiometric()
        ..throwOnAuthenticate = false
        ..authResult = false;
      final h = lockedHarness(biometric, await storedSession());
      await h.state.ready;
      await pumpEventQueue();
      expect(h.state.biometricFailed, isTrue, reason: 'hazırlık: kilit ekranı yeniden dene gösteriyor');

      biometric.throwOnAuthenticate = true;
      Object? thrown;
      bool? result;
      try {
        result = await h.state.retryBiometricAuth();
      } catch (e) {
        thrown = e;
      }
      await pumpEventQueue();

      expect(
        <String>[
          if (thrown != null) 'retryBiometricAuth istisna fırlattı: $thrown',
          if (result == true) 'istisna kilidi açtı',
          if (h.state.biometricChecking) 'biometricChecking=true kaldı',
          if (!h.state.biometricFailed) 'biometricFailed=false (yeniden deneme düğmesi kayboldu)',
          if (h.state.authStatus != AuthStatus.checking) 'authStatus=${h.state.authStatus}',
        ],
        isEmpty,
      );

      biometric
        ..throwOnAuthenticate = false
        ..authResult = true;
      expect(await h.state.retryBiometricAuth(), isTrue);
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.authenticated);
    });

    test('[B7] yeniden kilitte authenticate istisna fırlatırsa: işlenmemiş hata olmaz ve yaşam döngüsü olayları yutulmaz',
        () async {
      final biometric = ThrowingBiometric()..throwOnAuthenticate = false;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness(biometric: biometric);
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      await h.state.login('ev@example.test', 'parola-1234');
      expect(await h.state.enableBiometricWithVerification(), isTrue, reason: 'hazırlık');
      await pumpEventQueue();

      biometric.throwOnAuthenticate = true;
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        h.state.handleLifecycleState(AppLifecycleState.paused);
        h.clock.advance(const Duration(seconds: 45));
        h.state.handleLifecycleState(AppLifecycleState.resumed); // -> unawaited(_unlockWithBiometrics())
        await pumpEventQueue();
      }, (error, stack) => uncaught.add(error));

      expect(h.state.authStatus, AuthStatus.checking, reason: 'istisna kilidi AÇMAZ');
      final violations = <String>[
        if (uncaught.isNotEmpty) 'işlenmemiş hata: ${uncaught.first}',
        if (h.state.biometricChecking) 'biometricChecking=true kaldı',
        if (!h.state.biometricFailed) 'biometricFailed=false (kilit ekranı yeniden dene sunmaz)',
      ];

      // Kapı kapalı kalırsa sonraki arka plan geçişi yutulur.
      h.state.handleLifecycleState(AppLifecycleState.paused);
      if (!h.state.isInBackground) violations.add('sonraki "paused" yutuldu (isInBackground=false)');

      expect(violations, isEmpty);
    });

    testWidgets('[B7] açılış ekranı: authenticate istisnasında sonsuz bekleme yerine bir çıkış yolu sunulur', (tester) async {
      final biometric = ThrowingBiometric();
      final h = lockedHarness(biometric, await storedSession());
      await h.state.ready;

      await pumpApp(tester, state: h.state, child: const AuthGate());
      await settle(tester);
      h.clock.advance(const Duration(seconds: 16)); // "yavaş açılış" eşiği (15 sn) de geçsin
      await tester.pump();

      expect(find.byType(DashboardPage), findsNothing, reason: 'istisna kilidi AÇMAZ');
      final exits = <String>[
        for (final key in const <String>['btn_biometric_retry', 'btn_biometric_fallback', 'btn_splash_fallback'])
          if (find.byKey(Key(key)).evaluate().isNotEmpty) key,
      ];
      expect(exits, isNotEmpty,
          reason: 'kullanıcı "doğrulanıyor" ekranında kilitli: ne yeniden dene ne de şifre ile giriş sunuluyor');
    });
  });
}

// =============================================================================
// Eklenti / servis modelleri
// =============================================================================

/// `local_auth` eklentisinin uygulama açısından gözlenen davranışını modelleyen sahte
/// (`LocalAuthentication` sınırı). Aynı anda TEK doğrulama: bir istem ekrandayken gelen ikinci
/// `authenticate` çağrısı `PlatformException('auth_in_progress')` ile hemen reddedilir.
class PluginLikeLocalAuth extends LocalAuthentication {
  /// Biyometrik donanım var mı (`deviceSupportsBiometrics`).
  bool hardware = true;

  /// Cihaz güvenli mi (ekran kilidi) ya da biyometri kayıtlı mı (`isDeviceSupported`).
  bool deviceSupported = true;

  /// Kayıtlı biyometri sınıfları (Android: yalnızca `weak` / `strong`).
  List<BiometricType> enrolled = <BiometricType>[BiometricType.weak, BiometricType.strong];

  /// Atanırsa `authenticate` istem göstermeden bu kodla `PlatformException` fırlatır.
  String? immediateError;

  /// Platforma ulaşan `authenticate` çağrıları (reddedilenler dahil).
  int platformAuthenticateCalls = 0;

  /// Kullanıcıya gösterilen sistem istemi sayısı.
  int promptsShown = 0;

  /// `auth_in_progress` ile reddedilen (yarışan) çağrı sayısı.
  int rejectedInProgress = 0;

  /// Gösterilen istemlerin gerekçe metinleri.
  final List<String> reasons = <String>[];

  Completer<bool>? _prompt;

  /// Ekranda (ya da stickyAuth ile askıda) sistem istemi var mı: eklentideki `authInProgress`.
  bool get promptVisible => _prompt != null;

  void resetCounters() {
    platformAuthenticateCalls = 0;
    promptsShown = 0;
    rejectedInProgress = 0;
    reasons.clear();
  }

  /// Kullanıcı ekrandaki istemi sonuçlandırır (`true` = doğrulandı, `false` = iptal/başarısız).
  void completePrompt(bool ok) {
    final prompt = _prompt;
    if (prompt == null) throw StateError('Ekranda sistem istemi yok.');
    _prompt = null;
    prompt.complete(ok);
  }

  @override
  Future<bool> get canCheckBiometrics async => hardware;

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => List<BiometricType>.of(enrolled);

  @override
  Future<bool> stopAuthentication() async {
    final prompt = _prompt;
    _prompt = null;
    prompt?.complete(false);
    return true;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const <Object>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    platformAuthenticateCalls++;
    if (_prompt != null) {
      rejectedInProgress++;
      throw PlatformException(code: 'auth_in_progress', message: 'Authentication in progress');
    }
    final error = immediateError;
    if (error != null) throw PlatformException(code: error, message: 'model: $error');
    promptsShown++;
    reasons.add(localizedReason);
    final prompt = Completer<bool>();
    _prompt = prompt;
    return prompt.future;
  }
}

/// `FakeBiometric` türevi, servis sınırında "aynı anda tek doğrulama" modeli: bir çağrı beklerken gelen
/// ikinci çağrı (eklentide `auth_in_progress`, sarmalayıcıda `false`) HEMEN `false` döner.
class ExclusiveFakeBiometric extends FakeBiometric {
  ExclusiveFakeBiometric() : super(supported: true);

  Completer<bool>? _active;

  /// Bir doğrulama beklerken gelen ve hemen `false` dönen çağrı sayısı.
  int rejectedInProgress = 0;

  bool get promptVisible => _active != null;

  void completePrompt(bool ok) {
    final active = _active;
    if (active == null) throw StateError('Bekleyen doğrulama yok.');
    _active = null;
    active.complete(ok);
  }

  @override
  Future<bool> authenticate({String reason = '', bool biometricOnly = false}) async {
    authenticateCalls++;
    reasons.add(reason);
    if (_active != null) {
      rejectedInProgress++;
      return false;
    }
    final active = Completer<bool>();
    _active = active;
    return active.future;
  }
}

/// `authenticate` çağrısında istisna fırlatabilen biyometrik sahte (gerçek sarmalayıcı fırlatmaz;
/// enjekte edilen bir servis fırlatabilir).
class ThrowingBiometric extends FakeBiometric {
  ThrowingBiometric() : super(supported: true);

  bool throwOnAuthenticate = true;

  @override
  Future<bool> authenticate({String reason = '', bool biometricOnly = false}) async {
    authenticateCalls++;
    reasons.add(reason);
    if (throwOnAuthenticate) throw StateError('enjekte edilen biyometrik servis hatası');
    return authResult;
  }
}

// =============================================================================
// Test donanımı
// =============================================================================

/// `AutomationState` + GERÇEK `BiometricAuthService` (eklenti modeli üzerinde) + diğer sahteler.
class Rig {
  Rig._(this.clock, this.cloud, this.mqtt, this.storage, this.plugin, this.state);

  factory Rig({bool autoInit = false, FakeStorage? storage}) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = FakeCloudApi(clock: clock)
      ..homes = <HomeModel>[testHome()]
      ..endpoints[kHomeA] = testEndpoints()
      ..devicesByHome[kHomeA] = <DeviceInfo>[
        const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
      ];
    final mqtt = FakeMqtt();
    final store = storage ?? FakeStorage();
    final plugin = PluginLikeLocalAuth();
    final state = AutomationState(
      cloudApi: cloud,
      mqttService: mqtt,
      secureStorage: store,
      biometricService: BiometricAuthService(auth: plugin),
      directApi: AutomationApiService(baseUrl: '', client: MockApi().client),
      clock: clock,
      autoInit: autoInit,
      observeAppLifecycle: false,
    );
    addTearDown(state.dispose);
    return Rig._(clock, cloud, mqtt, store, plugin, state);
  }

  final FakeClock clock;
  final FakeCloudApi cloud;
  final FakeMqtt mqtt;
  final FakeStorage storage;
  final PluginLikeLocalAuth plugin;
  final AutomationState state;
}

/// Kayıtlı oturum + açık biyometrik tercih içeren güvenli depo (soğuk açılış).
Future<FakeStorage> storedSession() async {
  final storage = FakeStorage();
  await storage.saveAuthToken('kayitli-erisim');
  await storage.saveRefreshToken('kayitli-yenileme');
  await storage.saveUser(const UserModel(id: 'user-1', email: 'ev@example.test', fullName: 'Test Kullanıcı'));
  await storage.saveBiometricEnabled(true);
  return storage;
}

/// Soğuk açılış: kayıtlı oturum + biyometrik kilit; açılıştaki kilit açma istemi ekranda bekliyor.
/// Widget testlerinde [flush] olarak `tester.pump` verin (sahte zamanlı bölgede `pumpEventQueue` ilerlemez).
Future<Rig> coldStartLockedRig({Future<void> Function() flush = pumpEventQueue}) async {
  final rig = Rig(autoInit: true, storage: await storedSession());
  await flush();
  expect(rig.plugin.promptVisible, isTrue, reason: 'hazırlık: açılışta kilit açma istemi gösterilir');
  expect(rig.state.authStatus, AuthStatus.checking, reason: 'hazırlık');
  return rig;
}

/// Gerçek giriş yolundan (login -> ev seçimi -> MQTT) geçmiş oturum; [biometricEnabled] ise biyometrik
/// giriş gerçek etkinleştirme yolundan açılmıştır. Sayaçlar sıfırlanmış döner.
Future<Rig> signedInRig({bool biometricEnabled = true, Future<void> Function() flush = pumpEventQueue}) async {
  final rig = Rig();
  expect(await rig.state.login('ev@example.test', 'parola-1234'), isTrue, reason: 'hazırlık: giriş');
  await flush();
  expect(rig.state.authStatus, AuthStatus.authenticated, reason: 'hazırlık');
  expect(rig.state.isBiometricSupported, isTrue, reason: 'hazırlık');
  expect(rig.state.biometricLabel, 'Parmak İzi', reason: 'hazırlık');
  expect(rig.mqtt.isConnected, isTrue, reason: 'hazırlık: canlı bağlantı kurulu');
  if (biometricEnabled) {
    final enabling = rig.state.enableBiometricWithVerification();
    await flush();
    rig.plugin.completePrompt(true);
    expect(await enabling, isTrue, reason: 'hazırlık: biyometrik giriş açıldı');
    await flush();
  }
  rig.plugin.resetCounters();
  return rig;
}

/// Uygulama arka plana gider ve [away] sonra ön plana döner (yeniden kilit eşiği 30 sn).
void backgroundFor(Rig rig, Duration away) {
  rig.state.handleLifecycleState(AppLifecycleState.paused);
  rig.clock.advance(away);
  rig.state.handleLifecycleState(AppLifecycleState.resumed);
}

/// Ekrandaki (ve varsa ardından açılan) bütün sistem istemlerini onaylar.
Future<void> approveAllPrompts(Rig rig) async {
  for (var i = 0; i < 5 && rig.plugin.promptVisible; i++) {
    rig.plugin.completePrompt(true);
    await pumpEventQueue();
  }
}

/// Kayıtlı oturum + biyometrik kilit ile otomatik başlatılan klasik donanım (sahte biyometrik ile).
StateHarness lockedHarness(FakeBiometric biometric, FakeStorage storage) {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final cloud = FakeCloudApi()
    ..homes = <HomeModel>[testHome()]
    ..endpoints[kHomeA] = testEndpoints();
  final h = StateHarness(autoInit: true, storage: storage, cloud: cloud, biometric: biometric);
  addTearDown(h.dispose);
  return h;
}
