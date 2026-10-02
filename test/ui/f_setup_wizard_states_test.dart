import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// Kurulum sihirbazının arayüz durumları: oturum bitişi, çıkış onayı, ilerlemeyi bırakma, sunucu hatası ve
/// küçük ekran / büyük yazı yerleşimi.

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

/// Sihirbazı bir başlatıcıdan, mevcut cihaz kipinde açar (kayıt oluşur, çıkış onayı sorulur).
Future<void> openExisting(WidgetTester tester, ServiceHarness env, {int startStep = SetupSteps.wifi}) async {
  tester.view.physicalSize = const Size(900, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpLauncherWithRoute(
    tester,
    env,
    (_) => ServiceSetupWizardPage(
      existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5'),
      startStep: startStep,
      store: env.store,
      deviceApiFactory: env.deviceFactory,
      scanner: fakeScanner(null),
    ),
  );
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 20);
}

/// Başlatıcı sayfa + sihirbaz rotası (geri dönüş kontrolü için).
Future<void> pumpLauncherWithRoute(
  WidgetTester tester,
  ServiceHarness env,
  Widget Function(BuildContext context) page,
) async {
  await pumpLauncher(tester, env, (context) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: page));
  });
}

void main() {
  group('oturum süresi', () {
    testWidgets('geçici oturum bitince "Oturum süresi doldu" ekranı çıkar, ilerlemenin kayıtlı olduğu söylenir ve giriş ekranına dönülür',
        (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env);
      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      await goNext(tester, env);
      await pumpUntil(tester, env, () => continueEnabled(tester), reason: 'tek pano otomatik seçilmedi');
      await goNext(tester, env);
      expect(exists('setup_step_5'), isTrue);

      env.clock.advance(const Duration(hours: 2, seconds: 5));
      await settle(tester, frames: 30);
      expect(find.text('Oturum süresi doldu'), findsWidgets);
      expect(exists('session_expired_saved'), isTrue);
      expect(exists('setup_step_5'), isFalse, reason: 'süre dolunca eylem düğmeleri kalkar');
      expect(await env.store.list(env.access.ownerKey), hasLength(1), reason: 'ilerleme korunur');

      await tapKey(tester, 'btn_back_to_login');
      await settle(tester, frames: 20);
      expect(env.state.isAuthenticated, isFalse);
      expect(exists('launcher'), isTrue, reason: 'ilk sayfaya dönülür');
    });

    testWidgets('oturum bitiş uyarısı 5 dakikadan az kalınca şeritte görünür (geri sayım)', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env);
      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      env.clock.advance(const Duration(hours: 1, minutes: 56));
      await settle(tester, frames: 10);
      final text = tester.widget<Text>(find.byKey(const Key('service_session_text'))).data!;
      expect(text, contains('Kalan 04:'));
    });
  });

  group('çıkış ve bırakma', () {
    testWidgets('geri tuşu ilerleme varken onay ister; vazgeçilirse sihirbazda kalınır, onaylanırsa ilerleme saklı çıkılır', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openExisting(tester, env);
      expect(exists('setup_step_5'), isTrue);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      await navigator.maybePop();
      await settle(tester);
      expect(find.text('Sihirbazdan çıkılsın mı?'), findsOneWidget);
      expect(find.textContaining('İlerlemeniz bu telefonda kaydedildi'), findsOneWidget);
      await tapKey(tester, 'btn_exit_cancel');
      await settle(tester);
      expect(exists('setup_step_5'), isTrue);

      await navigator.maybePop();
      await settle(tester);
      await tapKey(tester, 'btn_exit_confirm');
      await settle(tester, frames: 20);
      expect(exists('launcher'), isTrue);
      expect(await env.store.list(env.access.ownerKey), hasLength(1), reason: 'çıkış ilerlemeyi silmez');
    });

    testWidgets('menüden kurulumu bırakmak yazarak onay ister ve kaydı siler', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openExisting(tester, env);
      await tapKey(tester, 'btn_setup_menu');
      await settle(tester);
      await tester.tap(find.text('Kurulumu bırak (ilerlemeyi sil)'));
      await settle(tester);
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await typeKey(tester, 'field_confirm_phrase', 'SİL');
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester, frames: 20);
      expect(await env.store.list(env.access.ownerKey), isEmpty);
      expect(exists('launcher'), isTrue);
    });
  });

  group('hata durumları', () {
    testWidgets('ilk adımda sunucuya ulaşılamazsa neden/çözüm ve Tekrar dene görünür; düzelince devam açılır', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.cloud.fetchHomesErrorOnce = ApiException.network();
      await openWizard(tester, env);
      await pumpUntil(tester, env, () => exists('setup_retry'), reason: 'hata kutusu çıkmadı');
      expect(find.text('Neden?'), findsOneWidget);
      expect(find.text('Ne yapmalıyım?'), findsOneWidget);
      expect(continueEnabled(tester), isFalse);

      await tapKey(tester, 'setup_retry');
      await pumpUntil(tester, env, () => continueEnabled(tester));
      expect(exists('setup_retry'), isFalse);
    });
  });

  group('yerleşim', () {
    testWidgets('360x800 ekranda ve 1.5x yazıda 1-4. adımlar taşma olmadan çalışır', (tester) async {
      final env = await serviceHarness(inventoryListed: true, flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env, size: const Size(360, 800), textScale: 1.5);
      expect(tester.takeException(), isNull);
      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      expect(tester.takeException(), isNull);
      await goNext(tester, env);

      expect(exists('setup_step_2'), isTrue);
      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => exists('step2_accepted_card'));
      expect(tester.takeException(), isNull);
      await goNext(tester, env);

      expect(exists('setup_step_3'), isTrue);
      await typeKey(tester, 'field_customer', kCustomerEmail);
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => exists('field_otp'));
      await typeKey(tester, 'field_otp', kCustomerOtp);
      expect(tester.takeException(), isNull);
      await goNext(tester, env);

      expect(exists('setup_step_4'), isTrue);
      expect(tester.takeException(), isNull);
      // "Devam" düğmesi büyük yazıda bile görünür ve dokunulabilir olmalı (başparmak bölgesi).
      expect(find.byKey(const Key('setup_continue')), findsOneWidget);
    });
  });
}
