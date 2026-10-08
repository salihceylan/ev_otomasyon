import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// servis_kurulum-8: "Testleri yap / Bağlantıyı yeniden kur" aynı panonun yarım kurulum kaydını sessizce ezmez; kayıt
/// varsa sorulur: "Kaldığınız Yerden Devam" / "Baştan Başla (kayıt silinir)" / "Vazgeç".
void main() {
  Future<ServiceHarness> openWithRecord(WidgetTester tester) async {
    final env = await serviceHarness(role: 'pin', flush: () async {});
    addTearDown(env.dispose);
    final now = env.clock.now().toUtc();
    await tester.runAsync(() => env.store.save(SetupProgressRecord(
          ownerKey: env.access.ownerKey,
          deviceUuid: kDeviceUid,
          homeId: kClaimedHome,
          homeName: 'Servis Evi',
          currentStep: 8,
          customerHint: '',
          createdAt: now.subtract(const Duration(hours: 1)),
          updatedAt: now.subtract(const Duration(minutes: 5)),
        )));
    await pumpPage(
      tester,
      env,
      ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
      size: const Size(900, 4200),
    );
    await settle(tester);
    return env;
  }

  Future<void> tapRetest(WidgetTester tester, ServiceHarness env) async {
    await tapKey(tester, 'btn_retest_$kDeviceUid');
    await pumpUntil(tester, env, () => present('btn_half_cancel') || present('setup_step_7'));
  }

  testWidgets('kayıt varken sorulur; Vazgeç kaydı değiştirmez ve sihirbaz açılmaz', (tester) async {
    final env = await openWithRecord(tester);
    await tapRetest(tester, env);
    expect(find.textContaining('Bu panonun yarım kalmış kurulumu var (Adım 8)'), findsOneWidget);
    await tapKey(tester, 'btn_half_cancel');
    await settle(tester);
    expect(find.byType(ServiceSetupWizardPage), findsNothing);
    final rec = await tester.runAsync(() => env.store.load(env.access.ownerKey, kDeviceUid));
    expect(rec?.currentStep, 8);
  });

  testWidgets('Kaldığınız Yerden Devam: sihirbaz kayıttan açılır', (tester) async {
    final env = await openWithRecord(tester);
    await tapRetest(tester, env);
    await tapKey(tester, 'btn_half_resume');
    await settle(tester, frames: 10);
    final page = tester.widget<ServiceSetupWizardPage>(find.byType(ServiceSetupWizardPage));
    expect(page.resume?.currentStep, 8);
    expect(page.existingTarget, isNull);
  });

  testWidgets('Baştan Başla: kayıt silinir, mevcut cihaz kipinde açılır', (tester) async {
    final env = await openWithRecord(tester);
    await tapRetest(tester, env);
    await tapKey(tester, 'btn_half_restart');
    await settle(tester, frames: 10);
    final page = tester.widget<ServiceSetupWizardPage>(find.byType(ServiceSetupWizardPage));
    expect(page.resume, isNull);
    expect(page.existingTarget?.deviceUuid, kDeviceUid);
  });
}
