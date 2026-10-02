import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart' as sup;
import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Servis paneli (rol matrisi), servis oturumu ve devreye alma yetkisi: geçici servis PIN oturumu / kalıcı
/// servis personeli / süper yönetici / yetkisiz kullanıcı için neyin görünüp neyin görünmediği, oturum
/// süresi, giriş akışı ve devam eden kurulumlar (davranış testleri).
///
/// Not: Cihaz ayarları sayfasının donanım koruma uyarısı testi bu dosyadan çıkarıldı; o ekran WP-E1
/// paketinindir (test/ui/e1_settings_test.dart).

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> openPanel(WidgetTester tester, ServiceHarness env, {Size size = const Size(900, 4200), double textScale = 1.0}) async {
  await pumpPage(
    tester,
    env,
    ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
    size: size,
    textScale: textScale,
  );
  await settle(tester);
}

SetupProgressRecord savedRecord(
  ServiceHarness env, {
  String uid = kDeviceUid,
  int step = 6,
  String? owner,
  String home = kClaimedHome,
  String homeName = 'Daire 5 - Nilüfer',
  String customerHint = 'm***@o***.test',
}) {
  final now = env.clock.now().toUtc();
  return SetupProgressRecord(
    ownerKey: owner ?? env.access.ownerKey,
    deviceUuid: uid,
    homeId: home,
    homeName: homeName,
    currentStep: step,
    customerHint: customerHint,
    createdAt: now.subtract(const Duration(hours: 2)),
    updatedAt: now.subtract(const Duration(minutes: 5)),
  );
}

void main() {
  group('servis paneli: rol matrisi', () {
    testWidgets('servis personeli: Yeni Kurulum, devam eden kurulumlar, mevcut cihazlar, araçlar ve acil sıfırlama görür', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);

      expect(exists('btn_new_setup'), isTrue);
      expect(exists('setup_resume_list'), isTrue);
      expect(exists('existing_devices_list'), isTrue);
      expect(exists('card_tool_subscribers'), isTrue);
      expect(exists('card_tool_inventory'), isTrue);
      expect(exists('card_tool_doctor'), isTrue);
      expect(exists('card_tool_management'), isTrue);
      expect(exists('card_emergency_reset'), isTrue, reason: 'kalıcı personel acil sıfırlama yapabilir');
      expect(exists('card_tool_replace'), isFalse, reason: 'pano değişimi aktif daire gerektirir (personelin aktif dairesi yok)');
      expect(find.text('Çıkış Yap'), findsOneWidget);
    });

    testWidgets('süper yönetici de aynı paneli görür ve oturum şeridinde süper yönetici hesabı yazar', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      expect(exists('btn_new_setup'), isTrue);
      expect(exists('card_emergency_reset'), isTrue);
      expect(find.descendant(of: find.byKey(const Key('service_session_banner')), matching: find.textContaining('Süper yönetici hesabı')), findsOneWidget);
    });

    testWidgets('geçici servis oturumu: acil sıfırlama, envanter, aboneler ve hesap yönetimi görünmez; geri sayım gösterilir', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);

      expect(exists('btn_new_setup'), isTrue);
      expect(exists('pin_session_note'), isTrue);
      expect(exists('card_emergency_reset'), isFalse, reason: 'PIN oturumunda acil sıfırlama hiç gösterilmez');
      expect(exists('field_reset_uid'), isFalse);
      expect(exists('card_tool_inventory'), isFalse);
      expect(exists('card_tool_subscribers'), isFalse);
      expect(exists('card_tool_management'), isFalse);
      expect(exists('card_tool_doctor'), isTrue);
      expect(exists('card_tool_replace'), isTrue, reason: 'oturumun dairesinde pano değişimi serbest');
      expect(find.text('Servis Oturumunu Kapat'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('service_session_text'))).data, contains('Kalan 2:00:00'));
    });

    testWidgets('geçici oturumda kalan süre saat ilerledikçe azalır; panelde hiçbir yerde PIN yoktur', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      env.clock.advance(const Duration(minutes: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(find.byKey(const Key('service_session_text'))).data, contains('Kalan 1:30:00'));
      expect(find.textContaining('123456'), findsNothing);
    });

    testWidgets('servis personeli için oturum şeridi kalıcı hesabı gösterir (geri sayım yok)', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      expect(find.descendant(of: find.byKey(const Key('service_session_banner')), matching: find.textContaining('Servis personeli hesabı')), findsOneWidget);
      expect(exists('service_session_text'), isFalse);
    });

    testWidgets('oturum süresi dolunca panel yerine açıklayıcı "Oturum süresi doldu" ekranı çıkar ve işlem yapılamaz', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      expect(exists('btn_new_setup'), isTrue);

      env.clock.advance(const Duration(hours: 2, seconds: 5));
      await settle(tester);
      expect(env.state.isAuthenticated, isFalse);
      expect(find.text('Oturum süresi doldu'), findsOneWidget);
      expect(exists('btn_new_setup'), isFalse);
      expect(exists('btn_back_to_login'), isTrue);
    });

    testWidgets('çıkış onay ister; vazgeçilirse oturum sürer, onaylanırsa kapanır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);

      await tapKey(tester, 'btn_service_logout');
      await settle(tester);
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_logout_cancel');
      await settle(tester);
      expect(env.state.isAuthenticated, isTrue);

      await tapKey(tester, 'btn_service_logout');
      await settle(tester);
      await tapKey(tester, 'btn_logout_confirm');
      await settle(tester);
      expect(env.state.isAuthenticated, isFalse);
    });
  });

  group('servis girişi (PIN)', () {
    Future<sup.StateHarness> unauth(WidgetTester tester) async {
      final h = sup.StateHarness();
      addTearDown(h.dispose);
      await sup.pumpApp(tester, child: const ServiceModePage(), state: h.state, size: const Size(900, 2400));
      await settle(tester);
      return h;
    }

    TextField pinField(WidgetTester tester) =>
        tester.widget<TextField>(find.descendant(of: find.byKey(const Key('field_service_pin')), matching: find.byType(TextField)));

    testWidgets('oturum yokken yalnızca PIN girişi görünür; PIN alanı gizlidir; servis araçları görünmez', (tester) async {
      await unauth(tester);
      expect(exists('card_service_login'), isTrue);
      expect(pinField(tester).obscureText, isTrue);
      expect(exists('btn_new_setup'), isFalse);
      expect(exists('card_emergency_reset'), isFalse);
      expect(exists('service_denied'), isFalse, reason: 'oturumsuz kullanıcıya "yetkisiz" değil giriş formu gösterilir');
    });

    testWidgets('6 haneden kısa PIN gönderilmez', (tester) async {
      final h = await unauth(tester);
      await typeKey(tester, 'field_service_pin', '123');
      await tapKey(tester, 'btn_service_login');
      await settle(tester);
      expect(find.text('PIN tam 6 rakam olmalıdır.'), findsOneWidget);
      expect(h.cloud.calls.where((c) => c == 'serviceLogin'), isEmpty);
    });

    testWidgets('yanlış PIN: kalan deneme hakkı yazılır ve PIN alanı temizlenir', (tester) async {
      final h = await unauth(tester);
      h.cloud.serviceLoginError = const ApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: 'PIN geçersiz.',
        remainingAttempts: 3,
      );
      await typeKey(tester, 'field_service_pin', '654321');
      await tapKey(tester, 'btn_service_login');
      await settle(tester);

      expect(find.textContaining('PIN hatalı ya da süresi dolmuş'), findsOneWidget);
      expect(find.textContaining('Kalan deneme hakkı: 3'), findsOneWidget);
      expect(pinField(tester).controller!.text, isEmpty, reason: 'hata sonrası PIN ekranda bırakılmaz');
      expect(h.state.isAuthenticated, isFalse);
    });

    testWidgets('PIN kilitlendiyse bekleme süresi dakika olarak yazılır', (tester) async {
      final h = await unauth(tester);
      h.cloud.serviceLoginError = const ApiException(
        statusCode: 423,
        code: 'PIN_LOCKED',
        message: 'Kilitlendi.',
        retryAfter: Duration(minutes: 15),
      );
      await typeKey(tester, 'field_service_pin', '654321');
      await tapKey(tester, 'btn_service_login');
      await settle(tester);
      expect(find.textContaining('15 dakika'), findsOneWidget);
    });

    testWidgets('ağ yokken ham istisna değil açıklayıcı mesaj gösterilir', (tester) async {
      final h = await unauth(tester);
      h.cloud.serviceLoginError = ApiException.network();
      await typeKey(tester, 'field_service_pin', '654321');
      await tapKey(tester, 'btn_service_login');
      await settle(tester);
      expect(find.textContaining('Sunucuya ulaşılamadı'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('doğru PIN servis oturumunu açar, panel görünür ve PIN hiçbir yerde kalmaz', (tester) async {
      final h = await unauth(tester);
      h.cloud.homes = <HomeModel>[HomeModel(id: kClaimedHome, name: 'Servis Evi', role: 'service_session')];
      h.cloud.serviceSessionToReturn = ServiceSessionInfo(
        homeId: kClaimedHome,
        homeName: 'Servis Evi',
        expiresAt: h.clock.now().add(const Duration(hours: 2)),
        technicianName: 'Usta',
      );
      await typeKey(tester, 'field_technician_name', 'Usta');
      await typeKey(tester, 'field_service_pin', '654321');
      await tapKey(tester, 'btn_service_login');
      for (var i = 0; i < 40 && !exists('btn_new_setup'); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.state.isServiceSession, isTrue);
      expect(exists('btn_new_setup'), isTrue);
      expect(exists('card_service_login'), isFalse);
      expect(find.textContaining('654321'), findsNothing);
    });

    testWidgets('başka bir hesapla oturum açıkken PIN girişi onay ister; vazgeçilirse oturum korunur', (tester) async {
      final h = sup.StateHarness();
      addTearDown(h.dispose);
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'owner-1', email: 'sahip@ornek.test', fullName: 'Ev Sahibi', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await sup.pumpApp(tester, child: const ServiceModePage(), state: h.state, size: const Size(900, 2400));
      await settle(tester);

      expect(exists('service_denied'), isTrue, reason: 'servis yetkisi olmayan hesap bilgilendirilir');
      expect(exists('btn_new_setup'), isFalse);
      await typeKey(tester, 'field_service_pin', '654321');
      await tapKey(tester, 'btn_service_login');
      await settle(tester);
      expect(find.text('Mevcut oturum kapatılsın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_simple_cancel');
      await settle(tester);
      expect(h.cloud.calls.where((c) => c == 'serviceLogin'), isEmpty, reason: 'vazgeçilince servis girişi denenmez');
      expect(h.state.isAuthenticated, isTrue);
    });
  });

  group('devam eden kurulumlar', () {
    testWidgets('kayıtlı kurulum kartı adım, müşteri ve zaman bilgisini gösterir; kaydı olmayan kullanıcıya boş durum çıkar', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await env.store.save(savedRecord(env, step: 6));
      await openPanel(tester, env);

      final card = find.byKey(const Key('card_setup_$kDeviceUid'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('Adım 6 / 10')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('m***@o***.test')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Daire 5 - Nilüfer')), findsOneWidget);
      expect(exists('resume_empty'), isFalse);
    });

    testWidgets('kayıt yoksa "yarım kalan kurulum yok" denir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      expect(exists('resume_empty'), isTrue);
    });

    testWidgets('başka teknisyenin ya da başka oturumun kaydı listede görünmez', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await env.store.save(savedRecord(env, uid: 'AHBU-S3-DIGER1', owner: 'user:baska-usta'));
      await env.store.save(savedRecord(env, uid: 'AHBU-S3-DIGER2', owner: 'session:$kClaimedHome'));
      await env.store.save(savedRecord(env, uid: 'AHBU-S3-BENIM1'));
      await openPanel(tester, env);
      expect(exists('card_setup_AHBU-S3-BENIM1'), isTrue);
      expect(exists('card_setup_AHBU-S3-DIGER1'), isFalse);
      expect(exists('card_setup_AHBU-S3-DIGER2'), isFalse);
    });

    testWidgets('Devam Et sihirbazı kayıtlı adımdan açar; kurulum sürmeden önce kayıt silinmez', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await env.store.save(savedRecord(env, step: 6));
      await openPanel(tester, env);

      await tapKey(tester, 'btn_resume_$kDeviceUid');
      await settle(tester, frames: 20);
      expect(exists('setup_step_6'), isTrue);
      expect(find.text('Adım 6 / 10'), findsOneWidget);
      expect(await env.store.list(env.access.ownerKey), hasLength(1));
    });

    testWidgets('kayıt silme onay ister; onaylanınca liste boşalır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await env.store.save(savedRecord(env));
      await openPanel(tester, env);

      await tapKey(tester, 'btn_discard_setup_$kDeviceUid');
      await settle(tester);
      await tapKey(tester, 'btn_simple_cancel');
      await settle(tester);
      expect(exists('card_setup_$kDeviceUid'), isTrue);

      await tapKey(tester, 'btn_discard_setup_$kDeviceUid');
      await settle(tester);
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester, frames: 20);
      expect(exists('card_setup_$kDeviceUid'), isFalse);
      expect(await env.store.list(env.access.ownerKey), isEmpty);
    });

    testWidgets('Yeni Kurulum Başlat sihirbazı 1. adımdan açar', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      await tapKey(tester, 'btn_new_setup');
      await settle(tester, frames: 20);
      expect(exists('setup_step_1'), isTrue);
    });
  });

  group('mevcut cihazlarım', () {
    testWidgets('aktif dairenin panoları listelenir; "Testleri yap" sihirbazı mevcut cihaz kipinde 7. adımdan açar', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);

      expect(find.byKey(const Key('existing_home_name')), findsOneWidget);
      expect(find.text('Daire: Servis Evi'), findsOneWidget);
      expect(exists('card_existing_$kDeviceUid'), isTrue);
      expect(exists('btn_reconnect_$kDeviceUid'), isTrue);

      await tapKey(tester, 'btn_retest_$kDeviceUid');
      for (var i = 0; i < 80 && !exists('setup_step_7'); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(exists('setup_step_7'), isTrue, reason: '2-4. adımlar atlanır, oturum doğrulanınca testlere geçilir');
    });

    testWidgets('aktif daire yoksa açıklama gösterilir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openPanel(tester, env);
      expect(exists('existing_no_home'), isTrue);
    });
  });

  group('kurulum sihirbazı yetkisi', () {
    testWidgets('ev sahibi (owner) kurulum sihirbazını açamaz', (tester) async {
      final h = sup.StateHarness();
      addTearDown(h.dispose);
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'owner-1', email: 'sahip@ornek.test', fullName: 'Ev Sahibi', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await sup.pumpApp(tester, child: const ServiceSetupWizardPage(), state: h.state, size: const Size(900, 2400));
      await settle(tester);
      expect(exists('setup_denied'), isTrue);
      expect(exists('setup_step_1'), isFalse);
    });

    testWidgets('başka teknisyene ait kurulum kaydı açılamaz', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceSetupWizardPage(resume: savedRecord(env, owner: 'user:baska-usta'), store: env.store, deviceApiFactory: env.deviceFactory),
      );
      await settle(tester);
      expect(exists('setup_denied'), isTrue);
      expect(find.textContaining('başka bir hesaba'), findsOneWidget);
    });

    testWidgets('geçici servis oturumu başka dairenin kurulum kaydını açamaz', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceSetupWizardPage(
          resume: savedRecord(env, home: sup.kHomeB, owner: env.access.ownerKey),
          store: env.store,
          deviceApiFactory: env.deviceFactory,
        ),
      );
      await settle(tester);
      expect(exists('setup_denied'), isTrue);
      expect(find.textContaining('yalnızca kendi dairesinde'), findsOneWidget);
    });
  });

  group('yerleşim', () {
    testWidgets('dar ekranda ve büyük yazıda panel taşma olmadan çalışır', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await env.store.save(savedRecord(env));
      await openPanel(tester, env, size: const Size(360, 800), textScale: 1.5);
      expect(tester.takeException(), isNull);
      expect(exists('btn_new_setup'), isTrue);
    });
  });
}
