import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:ev_otomasyon/ui/pages/service_subscribers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// servis_kurulum-9: süper yönetici yanıtı kaybolan claim'i (evin üyesi olmadığı için ev listesinde görmez) envanterdeki
/// `claimed_home_id` ile bulur; bulunamazsa 409 metni süper yöneticiye doğru yolu söyler; Aboneler sayfasında
/// "Kurulumu sürdür".
void main() {
  Future<ServiceSetupController> atClaimStep(ServiceHarness env) async {
    final c = await startedController(env);
    c.continueNext();
    expect(await c.identify.acceptLabel(kLabelQr), isTrue);
    c.continueNext();
    expect(await c.customer.sendCode(kCustomerEmail), isTrue);
    c.customer.setCode(kCustomerOtp);
    c.continueNext();
    expect(c.currentStep, SetupSteps.claim);
    return c;
  }

  InventoryDeviceModel claimedCard({String? homeId}) => InventoryDeviceModel(
        id: 'inv-1',
        serialNo: 1,
        deviceUuid: kDeviceUid,
        macAddress: 'E8:F6:0A:11:22:31',
        model: 'ESP32-S3-POE-ETH-8DI-8RO',
        batchNo: 'BATCH-2026-01',
        status: 'CLAIMED',
        claimedHomeName: 'Daire 5',
        claimedHomeId: homeId,
        createdAt: DateTime.utc(2026, 9, 24, 10),
        qrClaimUrl: 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kDeviceUid',
      );

  test('süper: ev listesinde görünmeyen ev envanterdeki claimed_home_id ile bulunur; ikinci claim gönderilmez', () async {
    final env = await serviceHarness(role: 'super', inventoryListed: true);
    addTearDown(env.dispose);
    final c = await atClaimStep(env);
    env.cloud.claimLosesResponseOnce = true;
    expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);
    env.cloud
      ..homes = <HomeModel>[] // süper bu evin üyesi değil
      ..inventory = <InventoryDeviceModel>[claimedCard(homeId: kClaimedHome)];

    await c.claim.retry();

    expect(c.claim.isComplete, isTrue);
    expect(env.cloud.claimCalls, 1);
    expect(c.target!.homeId, kClaimedHome);
  });

  test('süper: envanter ev kimliği vermezse (eski sunucu) 409 metni Aboneler > Kurulumu sürdür yolunu söyler', () async {
    final env = await serviceHarness(role: 'super', inventoryListed: true);
    addTearDown(env.dispose);
    final c = await atClaimStep(env);
    env.cloud.claimLosesResponseOnce = true;
    expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);
    env.cloud
      ..homes = <HomeModel>[]
      ..inventory = <InventoryDeviceModel>[claimedCard()];

    await c.claim.retry();

    expect(c.claim.isComplete, isFalse);
    expect(c.claim.problem!.todo, contains('Aboneler > Kurulumu sürdür'));
  });

  group('Aboneler: Kurulumu sürdür', () {
    Map<String, dynamic> sub({int commissioned = 0}) => <String, dynamic>{
          'home_id': kClaimedHome,
          'home_name': 'Daire 5',
          'home_address': 'Atatürk Cad. No:5',
          'owner': null,
          'device_count': 1,
          'online_count': 0,
          'commissioned_count': commissioned,
          'device_uuids': <String>[kDeviceUid],
        };

    testWidgets('süper: düğme var; sihirbaz mevcut cihaz kipinde 5. adımdan açılır', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud
        ..subscribers = <Map<String, dynamic>>[sub()]
        ..devicesByHome[kClaimedHome] = <DeviceInfo>[const DeviceInfo(deviceUuid: kDeviceUid)];
      await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3000));
      await settle(tester);

      await tapKey(tester, 'btn_resume_setup_$kClaimedHome');
      await settle(tester, frames: 10);
      final page = tester.widget<ServiceSetupWizardPage>(find.byType(ServiceSetupWizardPage));
      expect(page.existingTarget?.homeId, kClaimedHome);
      expect(page.existingTarget?.deviceUuid, kDeviceUid);
      expect(page.startStep, SetupSteps.wifi);
    });

    testWidgets('uygulama-ekranlar-4: yarım kayıt (Adım 7) varken önce sorulur; Vazgeç kaydı 7. adımda bırakır', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud
        ..subscribers = <Map<String, dynamic>>[sub()]
        ..devicesByHome[kClaimedHome] = <DeviceInfo>[const DeviceInfo(deviceUuid: kDeviceUid)];
      final now = env.clock.now();
      await env.store.save(SetupProgressRecord(
        ownerKey: env.access.ownerKey,
        deviceUuid: kDeviceUid,
        homeId: kClaimedHome,
        homeName: 'Daire 5',
        currentStep: SetupSteps.relays,
        createdAt: now,
        updatedAt: now,
      ));
      await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3000));
      await settle(tester);

      await tapKey(tester, 'btn_resume_setup_$kClaimedHome');
      await settle(tester, frames: 10);
      expect(find.text('Bu panonun yarım kalmış kurulumu var (Adım ${SetupSteps.relays})'), findsOneWidget);
      expect(find.byType(ServiceSetupWizardPage), findsNothing, reason: 'soru yanıtlanmadan sihirbaz açılmaz');

      await tapKey(tester, 'btn_half_cancel');
      await settle(tester, frames: 10);
      expect(find.byType(ServiceSetupWizardPage), findsNothing);
      final kept = await env.store.load(env.access.ownerKey, kDeviceUid);
      expect(kept?.currentStep, SetupSteps.relays, reason: 'Vazgeç: yarım kayıt ezilmez');
    });

    testWidgets('servis sorumlusunda da düğme var; sihirbaz mevcut cihaz kipinde 5. adımdan açılır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud
        ..subscribers = <Map<String, dynamic>>[sub()]
        ..devicesByHome[kClaimedHome] = <DeviceInfo>[const DeviceInfo(deviceUuid: kDeviceUid)];
      await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3000));
      await settle(tester);
      expect(present('btn_resume_setup_$kClaimedHome'), isTrue);

      await tapKey(tester, 'btn_resume_setup_$kClaimedHome');
      await settle(tester, frames: 10);
      final page = tester.widget<ServiceSetupWizardPage>(find.byType(ServiceSetupWizardPage));
      expect(page.existingTarget?.homeId, kClaimedHome);
      expect(page.existingTarget?.deviceUuid, kDeviceUid);
      expect(page.startStep, SetupSteps.wifi);
      expect(env.cloud.calls, contains('devices:$kClaimedHome'));
    });

    testWidgets('müşteri hesabında sayfa yetkisizdir: abone kartı da düğme de yok', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.subscribers = <Map<String, dynamic>>[sub()];
      env.state.setCurrentUserForTesting(
        const UserModel(id: 'cust-1', email: 'musteri@ornek.test', fullName: 'Müşteri', role: 'user'),
      );
      await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3000));
      await settle(tester);
      expect(present('btn_resume_setup_$kClaimedHome'), isFalse);
      expect(present('card_subscriber_$kClaimedHome'), isFalse);
      expect(env.cloud.calls.where((c) => c.startsWith('devices:')), isEmpty);
    });

    group('canResumeSetup (rol matrisi)', () {
      bool allowed(String? globalRole, {String? homeRole}) =>
          ServiceSubscribersPage.canResumeSetup(Capabilities(globalRole: globalRole, homeRole: homeRole));

      test('yalnız süper kullanıcı ve (küresel) servis sorumlusu', () {
        expect(allowed('super_user'), isTrue);
        expect(allowed('service_user'), isTrue);
        expect(allowed('service_user', homeRole: 'service_user'), isTrue);
      });

      test('müşteri, ev sahibi, sakin, misafir, servis PIN oturumu ve oturumsuz: hayır', () {
        expect(allowed('user'), isFalse);
        expect(allowed('user', homeRole: 'owner'), isFalse);
        expect(allowed('user', homeRole: 'resident'), isFalse);
        expect(allowed('user', homeRole: 'guest'), isFalse);
        // Küresel rolü düşürülmüş hesabın eski ev bazlı servis üyeliği yetki vermez.
        expect(allowed('user', homeRole: 'service_user'), isFalse);
        expect(allowed('service_session', homeRole: 'service_session'), isFalse);
        expect(allowed(null), isFalse);
        expect(allowed('garip_rol'), isFalse);
      });
    });

    group('yetkisiz (servis süresi dolmuş / üye değil)', () {
      const noAccess = "Bu dairede servis yetkiniz yok. Müşteriden Servis PIN'i isteyip PIN ile girin.";

      Future<ServiceHarness> openAs(WidgetTester tester, String role, Object error) async {
        final env = await serviceHarness(role: role, flush: () async {});
        addTearDown(env.dispose);
        env.cloud
          ..subscribers = <Map<String, dynamic>>[sub()]
          ..devicesError = error;
        await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3000));
        await settle(tester);
        await tapKey(tester, 'btn_resume_setup_$kClaimedHome');
        await settle(tester, frames: 10);
        return env;
      }

      testWidgets('servis sorumlusu: 403 (süre doldu) sade yönlendirme iletisi, sihirbaz açılmaz', (tester) async {
        await openAs(
          tester,
          'staff',
          const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Servis erişim süreniz dolmuştur.'),
        );
        expect(find.text(noAccess), findsOneWidget);
        expect(find.text('Servis erişim süreniz dolmuştur.'), findsNothing, reason: 'ham sunucu iletisi yerine sade ileti');
        expect(present('snack_resume_no_access'), isTrue);
        expect(find.byType(ServiceSetupWizardPage), findsNothing);
      });

      testWidgets('servis sorumlusu: 403 (üye değil) aynı iletiyi gösterir', (tester) async {
        await openAs(
          tester,
          'staff',
          const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Bu daireye erişim yetkiniz bulunmamaktadır.'),
        );
        expect(find.text(noAccess), findsOneWidget);
      });

      testWidgets('servis sorumlusu: 404 aynı iletiyi gösterir', (tester) async {
        await openAs(tester, 'staff', const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Daire bulunamadı.'));
        expect(find.text(noAccess), findsOneWidget);
      });

      testWidgets('servis sorumlusu: sunucu hatası yetki iletisine çevrilmez', (tester) async {
        await openAs(
          tester,
          'staff',
          const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu şu anda yanıt veremiyor.'),
        );
        expect(find.text('Sunucu şu anda yanıt veremiyor.'), findsOneWidget);
        expect(find.text(noAccess), findsNothing);
      });

      testWidgets('süper kullanıcı: sunucu iletisi olduğu gibi gösterilir (PIN yönlendirmesi yok)', (tester) async {
        await openAs(tester, 'super', const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Daire bulunamadı.'));
        expect(find.text('Daire bulunamadı.'), findsOneWidget);
        expect(find.text(noAccess), findsNothing);
      });
    });

    testWidgets('devreye alınmış dairede (süper) düğme yok', (tester) async {
      final env2 = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env2.dispose);
      env2.cloud.subscribers = <Map<String, dynamic>>[sub(commissioned: 1)];
      await pumpPage(tester, env2, const ServiceSubscribersPage(), size: const Size(900, 3000));
      await settle(tester);
      expect(present('btn_resume_setup_$kClaimedHome'), isFalse);
    });
  });
}
