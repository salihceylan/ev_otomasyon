import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
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

    testWidgets('servis personelinde düğme yok', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.subscribers = <Map<String, dynamic>>[sub()];
      await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3000));
      await settle(tester);
      expect(present('btn_resume_setup_$kClaimedHome'), isFalse);
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
