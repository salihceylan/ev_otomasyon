import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/replace_board_dialog.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart' show kHomeA;
import 'f_support.dart';
import 'f_widget_support.dart';

/// bireysel-4 (servis_kurulum-4 birleşik): pano değişimi sonucunda "Yeni Panoyu Şimdi Bağla" yalnız sihirbazı açabilen
/// role (personel / servis PIN oturumu) gösterilir; süper yöneticiye anahtar yolu notu, ev sahibine Wi-Fi yolu.
void main() {
  const oldUid = 'AHBU-S3-OLD001';
  const newUid = 'AHBU-S3-NEW001';
  const newLabel = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$newUid&pin=246810';

  Future<ServiceHarness> env(WidgetTester tester, {required String harnessRole, String? userRole, required String homeRole}) async {
    final e = await serviceHarness(role: harnessRole, flush: () async {});
    if (userRole != null) {
      e.state.setCurrentUserForTesting(UserModel(id: 'u-1', email: 'ayse@ornek.test', fullName: 'Ayşe', role: userRole));
    }
    e.cloud.devicesByHome[kHomeA] = <DeviceInfo>[
      const DeviceInfo(deviceUuid: oldUid, name: 'Salon Panosu', online: false, firmware: '1.3.0'),
    ];
    e.cloud.replaceBoardToReturn = const ReplaceBoardResult(
      newDeviceUuid: newUid,
      oldDeviceUuid: oldUid,
      homeId: kHomeA,
      migratedEndpointsCount: 6,
    );
    await activateHome(tester, e, HomeModel(id: kHomeA, name: 'Daire 5', role: homeRole));
    return e;
  }

  Future<void> replaceToResult(WidgetTester tester, ServiceHarness e) async {
    await pumpLauncher(tester, e, (ctx) => ReplaceBoardDialog.show(ctx, scanner: fakeScanner(newLabel)));
    await tester.tap(find.byKey(const Key('launcher')));
    await settle(tester);
    await tapKey(tester, 'btn_scan_new_board');
    await settle(tester);
    await tapKey(tester, 'btn_replace_submit');
    await settle(tester);
    await tapKey(tester, 'btn_replace_confirm');
    await settle(tester);
    expect(find.byKey(const Key('replace_result_title')), findsOneWidget);
  }

  bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

  testWidgets('ev sahibi: sihirbaz düğmesi yok; Wi-Fi yolu ve bulut notu var; düğme Wi-Fi sihirbazını yeni panoyla açar', (tester) async {
    final e = await env(tester, harnessRole: 'staff', userRole: 'user', homeRole: 'owner');
    addTearDown(e.dispose);
    await replaceToResult(tester, e);

    expect(exists('btn_replace_open_wizard'), isFalse);
    expect(find.textContaining('Kurulum sihirbazı bu adımları sizin için yürütür'), findsNothing);
    expect(find.textContaining('Yeni pano Ethernet ile bağlıysa bir şey yapmanız gerekmez.'), findsOneWidget);
    expect(find.textContaining(claimCloudBootstrapNote), findsOneWidget);

    await tapKey(tester, 'btn_replace_open_wifi');
    await settle(tester);
    expect(find.byType(ReplaceBoardDialog), findsNothing);
    expect(tester.widget<WifiRecoveryDialog>(find.byType(WifiRecoveryDialog)).deviceUuid, newUid);
  });

  const safetyWarning = 'Eski panonun güvenlik ayarları (sensörler, vanalar, bölgeler) yeni panoya aktarılmadı. Servis bu '
      'ayarları yeniden yazana kadar su/gaz koruması ÇALIŞMAZ. Yetkili servisi çağırın.';

  ReplaceBoardResult resultWith(String safetyRestore) => ReplaceBoardResult.fromJson(<String, dynamic>{
        'message': 'Pano değişimi tamamlandı. Kanal adları, kurallar ve panjur süreleri yeni panoya taşındı.',
        'old_device_uuid': oldUid,
        'new_device_uuid': newUid,
        'home_id': kHomeA,
        'migrated_endpoints_count': 6,
        'safety_restore': safetyRestore,
        'warnings': <String>[if (safetyRestore == 'required') safetyWarning],
      });

  testWidgets('C4: güvenlik ayarları aktarılmadıysa vurgulu uyarı; ev sahibine "bir şey yapmanız gerekmez" denmez', (tester) async {
    final e = await env(tester, harnessRole: 'staff', userRole: 'user', homeRole: 'owner');
    addTearDown(e.dispose);
    e.cloud.replaceBoardToReturn = resultWith('required');
    await replaceToResult(tester, e);

    expect(exists('replace_safety_restore_warning'), isTrue);
    expect(find.textContaining('bir şey yapmanız gerekmez'), findsNothing);
    expect(
      find.textContaining('Güvenlik ayarları (su/gaz sensörü, vana) yeni panoya aktarılmadı. Yetkili servisi çağırın.'),
      findsOneWidget,
    );
    expect(find.text(safetyWarning), findsOneWidget, reason: 'sunucu uyarısı listede kalır');
  });

  testWidgets('C4: safety_restore not_required ya da alan yok: bugünkü metin, uyarı kartı yok', (tester) async {
    final e = await env(tester, harnessRole: 'staff', userRole: 'user', homeRole: 'owner');
    addTearDown(e.dispose);
    e.cloud.replaceBoardToReturn = resultWith('not_required');
    await replaceToResult(tester, e);

    expect(exists('replace_safety_restore_warning'), isFalse);
    expect(find.textContaining('Yeni pano Ethernet ile bağlıysa bir şey yapmanız gerekmez.'), findsOneWidget);
  });

  testWidgets('süper yönetici: sihirbaz düğmesi yok, anahtar yolu notu var', (tester) async {
    final e = await env(tester, harnessRole: 'super', homeRole: 'service_user');
    addTearDown(e.dispose);
    await replaceToResult(tester, e);

    expect(exists('btn_replace_open_wizard'), isFalse);
    expect(exists('replace_super_note'), isTrue);
    expect(exists('btn_replace_open_wifi'), isFalse);
  });

  testWidgets('servis personeli: sihirbaz düğmesi var ve sihirbazı açar', (tester) async {
    final e = await env(tester, harnessRole: 'staff', homeRole: 'service_user');
    addTearDown(e.dispose);
    await replaceToResult(tester, e);

    expect(exists('replace_super_note'), isFalse);
    expect(exists('btn_replace_open_wifi'), isFalse);
    await tapKey(tester, 'btn_replace_open_wizard');
    await settle(tester);
    expect(find.byType(ServiceSetupWizardPage), findsOneWidget);
  });

  testWidgets('karar 18: güvenlik modüllü evde sahip -> 403 REPLACE_REQUIRES_SERVICE: sunucu iletisi + servis yolu (çıkmaz yok)', (tester) async {
    final e = await env(tester, harnessRole: 'staff', userRole: 'user', homeRole: 'owner');
    addTearDown(e.dispose);
    e.cloud.replaceError = const ApiException(
      statusCode: 403,
      code: 'REPLACE_REQUIRES_SERVICE',
      message: 'Bu evde güvenlik modülü kurulu; pano değişimini servis personeli yapmalıdır.',
    );
    await pumpLauncher(tester, e, (ctx) => ReplaceBoardDialog.show(ctx, scanner: fakeScanner(newLabel)));
    await tester.tap(find.byKey(const Key('launcher')));
    await settle(tester);
    await tapKey(tester, 'btn_scan_new_board');
    await settle(tester);
    await tapKey(tester, 'btn_replace_submit');
    await settle(tester);
    await tapKey(tester, 'btn_replace_confirm');
    await settle(tester);

    expect(find.byKey(const Key('replace_requires_service')), findsOneWidget);
    expect(find.textContaining('Bu evde güvenlik modülü kurulu; pano değişimini servis personeli yapmalıdır.'), findsOneWidget);
    expect(find.textContaining('Servis PIN'), findsWidgets);
    expect(exists('replace_error'), isFalse);
    expect(exists('btn_replace_submit'), isFalse, reason: 'aynı istek yinelenmez: yol servis personelidir');
  });
}
