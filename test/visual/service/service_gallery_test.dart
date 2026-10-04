@Tags(['visual'])
library;

// Servis sayfaları görsel galerisi (WP-V7).
//
//   flutter test --tags visual --update-goldens test/visual/service   -> test/visual/service/goldens/*.png
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/service        -> kayıtlı PNG'lerle karşılaştırır
//
// Gerçek sayfalar/diyaloglar gerçek AutomationState + sahte bulut (ServiceHarness) üzerinde çizilir;
// MotionScope(full) + AmbientClock.fixed ile deterministiktir. Koyu + açık, yazı ölçeği 1.0 + 1.5, 360 dp telefon.

import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:ev_otomasyon/ui/pages/replace_board_dialog.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/admin_account_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/assign_admin_dialog.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/emergency_reset_card.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/subscriber_models.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:ev_otomasyon/ui/pages/service_subscribers_page.dart';
import 'package:ev_otomasyon/ui/pages/system_doctor_dialog.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/support.dart';
import '../../ui/f_support.dart';
import '../../ui/f_widget_support.dart';
import '../support/golden_support.dart';

/// Her çağrı YENİ bir ağaç kurar (`UniqueKey`): galeri harness'inin Navigator'ı GlobalKey'li olduğundan aynı testte ikinci kez
/// `pumpGallery` çağrılınca eski `home` ağacının State'i korunur ve yeni senaryonun verisi (ör. doktor `initialData`) yok sayılırdı
/// (üç doktor PNG'si de "sağlıklı" çıkıyordu).
///
/// [pushed] `true` ise sayfa bir kök sayfanın ÜSTÜNE yığılır ([PushedOverHome]): gerçek akıştaki gibi `NeonAppBar`'da geri
/// diski görünür (kök rotada geri düğmesi çizilmez). Diyalog/kart sahneleri kök rotada kalır.
Widget host(ServiceHarness env, Widget child, {bool pushed = false}) => ChangeNotifierProvider<AutomationState>.value(
  key: UniqueKey(),
  value: env.state,
  child: Builder(
    builder: (context) => Theme(
      data: Theme.of(context).copyWith(scaffoldBackgroundColor: Colors.transparent),
      child: pushed ? PushedOverHome(child: child) : child,
    ),
  ),
);

/// Diyalog sahnesi: gerçek akıştaki gibi MODAL PERDE (`AppGlass.scrim*`) üstünde. Galeri diyalogları `showDialog` ile değil doğrudan
/// sayfa çocuğu olarak çizdiğinden perde PNG'de yoktu: açık temada beyaz diyalog yüzeyi doğrudan açık devre kartı üstünde, koyuda
/// perdesiz parlak zemin; yüzey/perde kontrastı üretimdekini temsil etmiyordu (2. tur eleştirmen bulgusu, harness artefaktı).
Widget modalScene(Widget dialog, Brightness brightness) => Stack(
  fit: StackFit.expand,
  children: [
    ModalBarrier(color: brightness == Brightness.dark ? AppGlass.scrimDark : AppGlass.scrimLight, dismissible: false),
    dialog,
  ],
);

Map<String, dynamic> _acct(
  String id,
  String name, {
  String role = 'user',
  bool active = true,
  String status = 'active',
  String? phone,
  String? notes,
}) => <String, dynamic>{
  'id': id,
  'full_name': name,
  'email': '$id@ornek.test',
  'phone': phone,
  'role': role,
  'is_active': active,
  'account_status': active ? status : 'suspended',
  'admin_notes': notes,
};

Map<String, dynamic> _sub(
  Object homeId,
  String name, {
  List<String> uids = const <String>[],
  int online = 0,
  int commissioned = 0,
  Map<String, dynamic>? owner,
}) => <String, dynamic>{
  'home_id': homeId,
  'home_name': name,
  'home_address': 'Atatürk Cad. No:5',
  'owner': owner,
  'device_count': uids.length,
  'online_count': online,
  'commissioned_count': commissioned,
  'device_uuids': uids,
};

Map<String, dynamic> _report({
  String level = 'ok',
  String cloud = 'OK',
  String network = 'OK',
  String power = 'OK',
  String title = 'Tüm Sistemler Sağlıklı ve Çevrimiçi',
  String summary = 'Bulut, ev modemi ve pano kesintisiz haberleşiyor.',
  String? action,
}) => <String, dynamic>{
  'cloud': <String, dynamic>{'status': cloud, 'latency_ms': 37, 'db_connected': true, 'mqtt_bridge_connected': true},
  'home_network': <String, dynamic>{'status': network, 'device_ip': '192.168.1.42', 'seconds_since_last_seen': 12},
  'hardware_power': <String, dynamic>{'status': power, 'is_online': power == 'OK'},
  'devices': <Map<String, dynamic>>[],
  'endpoint_count': 8,
  'diagnosis_title': title,
  'diagnosis_summary': summary,
  'diagnosis_level': level,
  'action_recommendation': ?action,
};

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Servis sayfaları galerisi', () {
    setUpAll(loadGoldenFonts);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';
        final ratio = scale > 1 ? 1.0 : 2.0;
        double h(double base) => scale > 1 ? base * 1.55 : base;

        // [modal] `true` ⇒ diyalog sahnesi: modal perde üstünde çizilir (bkz. [modalScene]).
        Future<void> gallery(
          WidgetTester tester,
          ServiceHarness env,
          GlobalKey key,
          Widget child,
          double height, {
          bool pushed = false,
          bool modal = false,
        }) => pumpGallery(
          tester,
          boundaryKey: key,
          brightness: brightness,
          textScale: scale,
          size: Size(360, height),
          // Üretimdeki GERÇEK devre kartı zemini: arka planda doğrudan duran metinlerin (AppBar başlığı, bölüm başlıkları)
          // kontrastı üretimle birebir değerlendirilir.
          realBackground: true,
          child: host(env, modal ? modalScene(child, brightness) : child, pushed: pushed),
        );

        testWidgets('servis paneli: personel ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[
            DeviceInfo(deviceUuid: 'AHBU-S3-A1B2C3', name: 'Salon Panosu', online: true, firmware: '1.1.0'),
            DeviceInfo(deviceUuid: 'AHBU-S3-D4E5F6', name: 'Mutfak Panosu', online: false, firmware: '1.0.9'),
          ];
          await activateHome(tester, env, HomeModel(id: kHomeA, name: 'Daire 5 - Nilüfer', role: 'service_user'));
          final now = env.clock.now().toUtc();
          await env.store.save(
            SetupProgressRecordX.sample(env.access.ownerKey, 'AHBU-S3-A1B2C3', 6, now),
          );
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
            h(2500),
            pushed: true,
          );
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'panel_staff_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('servis paneli: PIN oturumu ($tag)', (tester) async {
          final env = await serviceHarness(role: 'pin', flush: () async {});
          addTearDown(env.dispose);
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
            h(1500),
            pushed: true,
          );
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'panel_pin_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('servis paneli: giriş yok (PIN girişi) ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          await env.state.logout();
          await tester.pump();
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
            h(900),
            pushed: true,
          );
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'panel_login_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('cihaz envanteri ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.inventory = <InventoryDeviceModel>[
            inventoryDevice(uid: 'AHBU-S3-A1B2C3', serial: 1),
            inventoryDevice(uid: 'AHBU-S3-D4E5F6', serial: 2, status: 'CLAIMED', claimedHome: 'Daire 5 - Nilüfer'),
            inventoryDevice(uid: 'AHBU-S3-0A0B0C', serial: 3, status: 'SUSPENDED'),
          ];
          final key = GlobalKey();
          await gallery(tester, env, key, const DeviceInventoryPage(), h(1500), pushed: true);
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'inventory_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('cihaz envanteri: yönetici eylemleri ($tag)', (tester) async {
          // Süper yönetici: Askıya Al / Stoğa Al / Etiketi Yeniden Üret / Envanterden Sil düğmeleri (ızgara, aile tonları, AA).
          final env = await serviceHarness(role: 'super', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.inventory = <InventoryDeviceModel>[
            inventoryDevice(uid: 'AHBU-S3-A1B2C3', serial: 1),
            inventoryDevice(uid: 'AHBU-S3-0A0B0C', serial: 3, status: 'SUSPENDED'),
            inventoryDevice(uid: 'AHBU-S3-0D0E0F', serial: 4, status: 'REVOKED'),
            inventoryDevice(uid: 'AHBU-S3-D4E5F6', serial: 2, status: 'CLAIMED', claimedHome: 'Daire 5 - Nilüfer'),
          ];
          final key = GlobalKey();
          await gallery(tester, env, key, const DeviceInventoryPage(), h(2300), pushed: true);
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'inventory_manage_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('cihaz envanteri: yükleniyor ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.inventoryGate = Completer<void>();
          final key = GlobalKey();
          await gallery(tester, env, key, const DeviceInventoryPage(), h(760), pushed: true);
          await tester.pump();
          expect(find.byKey(const Key('inventory_loading')), findsOneWidget);
          await expectGolden(tester, key, 'inventory_loading_$tag.png', pixelRatio: ratio);
          env.cloud.inventoryGate!.complete();
          await settle(tester, frames: 30);
        });

        testWidgets('aboneler ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.subscribers = <Map<String, dynamic>>[
            _sub(
              101,
              'Daire 101',
              uids: const ['AHBU-S3-A1B2C3'],
              online: 1,
              commissioned: 1,
              owner: <String, dynamic>{
                'full_name': 'Ayşe Yılmaz',
                'email': 'ayse@ornek.test',
                'phone': '05550001122',
              },
            ),
            _sub(102, 'Daire 102', uids: const ['AHBU-S3-D4E5F6', 'AHBU-S3-0A0B0C'], online: 1),
            _sub(103, 'Villa 7'),
          ];
          final key = GlobalKey();
          await gallery(tester, env, key, const ServiceSubscribersPage(pageSize: 2), h(1500), pushed: true);
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'subscribers_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('servis yönetimi: hesaplar ($tag)', (tester) async {
          final env = await serviceHarness(role: 'super', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.adminUsers = <Map<String, dynamic>>[
            _acct('super-1', 'Yönetici', role: 'super_user'),
            _acct('staff-1', 'Servis Ali', role: 'service_user'),
            _acct('cust-1', 'Müşteri Mehmet', status: 'pending_invite', phone: '05551112233'),
            _acct('cust-2', 'Müşteri Zeynep', active: false),
          ];
          final key = GlobalKey();
          await gallery(tester, env, key, const ServiceManagementPage(), h(1500), pushed: true);
          await settle(tester, frames: 30);
          await expectGolden(tester, key, 'management_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('pano değişimi: form ve sonuç ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[
            DeviceInfo(deviceUuid: 'AHBU-S3-0A0B0C', name: 'Salon Panosu', online: false, firmware: '1.1.0'),
            DeviceInfo(deviceUuid: 'AHBU-S3-D4E5F6', name: 'Mutfak Panosu', online: true, firmware: '1.1.0'),
          ];
          await activateHome(tester, env, HomeModel(id: kHomeA, name: 'Daire 5 - Nilüfer', role: 'service_user'));
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            Center(child: SingleChildScrollView(child: ReplaceBoardDialog(scanner: fakeScanner(null)))),
            h(980),
            modal: true,
          );
          await settle(tester, frames: 20);
          await tester.tap(find.byKey(const Key('card_oldboard_AHBU-S3-0A0B0C')));
          await tester.pump();
          await _type(tester, 'field_new_uid', kDeviceUid);
          await _type(tester, 'field_new_pin', kSetupPin);
          await settle(tester, frames: 10);
          await expectGolden(tester, key, 'replace_form_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('pano değişimi: sonuç belirsiz ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[
            DeviceInfo(deviceUuid: 'AHBU-S3-0A0B0C', name: 'Salon Panosu', online: false, firmware: '1.1.0'),
          ];
          env.cloud.replaceError = ApiException.network();
          await activateHome(tester, env, HomeModel(id: kHomeA, name: 'Daire 5 - Nilüfer', role: 'service_user'));
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            Center(child: SingleChildScrollView(child: ReplaceBoardDialog(scanner: fakeScanner(null)))),
            h(1180),
            modal: true,
          );
          await settle(tester, frames: 20);
          await _type(tester, 'field_new_uid', kDeviceUid);
          await _type(tester, 'field_new_pin', kSetupPin);
          final submit = find.byKey(const Key('btn_replace_submit'));
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await settle(tester, frames: 10);
          await tester.tap(find.byKey(const Key('btn_replace_confirm')));
          await settle(tester, frames: 20);
          expect(find.byKey(const Key('replace_uncertain')), findsOneWidget);
          await expectGolden(tester, key, 'replace_uncertain_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('pano değişimi: tamamlandı ($tag)', (tester) async {
          final env = await serviceHarness(role: 'staff', flush: () async {});
          addTearDown(env.dispose);
          env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[
            DeviceInfo(deviceUuid: 'AHBU-S3-0A0B0C', name: 'Salon Panosu', online: false, firmware: '1.1.0'),
          ];
          await activateHome(tester, env, HomeModel(id: kHomeA, name: 'Daire 5 - Nilüfer', role: 'service_user'));
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            Center(child: SingleChildScrollView(child: ReplaceBoardDialog(scanner: fakeScanner(null)))),
            h(1000),
            modal: true,
          );
          await settle(tester, frames: 20);
          await _type(tester, 'field_new_uid', kDeviceUid);
          await _type(tester, 'field_new_pin', kSetupPin);
          final submit = find.byKey(const Key('btn_replace_submit'));
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await settle(tester, frames: 10);
          await tester.tap(find.byKey(const Key('btn_replace_confirm')));
          await settle(tester, frames: 25);
          expect(find.byKey(const Key('replace_result_title')), findsOneWidget);
          await expectGolden(tester, key, 'replace_done_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('acil sıfırlama: normal ve sonuç belirsiz ($tag)', (tester) async {
          final env = await serviceHarness(role: 'super', flush: () async {});
          addTearDown(env.dispose);
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: EmergencyResetCard(scanner: fakeScanner(null)),
            ),
            h(1100),
          );
          await settle(tester, frames: 10);
          await expectGolden(tester, key, 'emergency_normal_$tag.png', pixelRatio: ratio);
          env.cloud.emergencyError = ApiException.network();
          await _type(tester, 'field_reset_uid', kDeviceUid);
          await _type(tester, 'field_reset_reason', 'Kiracı tahliye edildi, sözleşme ibraz edildi');
          final submit = find.byKey(const Key('btn_emergency_reset'));
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await settle(tester, frames: 10);
          await tester.enterText(find.byKey(const Key('field_confirm_phrase')), kDeviceUid);
          await tester.pump();
          await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
          await settle(tester, frames: 20);
          expect(find.byKey(const Key('reset_uncertain')), findsOneWidget);
          await expectGolden(tester, key, 'emergency_uncertain_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('acil sıfırlama sonucu: gizli PIN + 45 sn halka ($tag)', (tester) async {
          final env = await serviceHarness(role: 'super', flush: () async {});
          addTearDown(env.dispose);
          // Pano kanalı SAHTE: kopyalama biter bitmez "panoya kopyalandı + 45 sn halka" satırı çıkar (gerçek kanal testte yok).
          ClipboardSpy().install(tester);
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            Center(
              child: SingleChildScrollView(
                child: EmergencyResetResultDialog(
                  result: EmergencyResetResult(
                    action: 'UNCLAIMED',
                    deviceUuid: kDeviceUid,
                    setupPin: kReissuedPin,
                    affectedUsersCount: 3,
                  ),
                ),
              ),
            ),
            h(900),
            modal: true,
          );
          await settle(tester, frames: 10);
          await tester.tap(find.byKey(const Key('btn_copy_reset_pin')));
          await settle(tester, frames: 10);
          await tester.pump(const Duration(milliseconds: 120));
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          expect(find.byKey(const Key('reset_copied')), findsOneWidget, reason: 'kopyalama sonrası geri sayım satırı görünür');
          await expectGolden(tester, key, 'emergency_result_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('sistem doktoru: sağlıklı / uyarı / sorun ($tag)', (tester) async {
          for (final c in <(String, Map<String, dynamic>)>[
            ('ok', _report()),
            (
              'warn',
              _report(
                level: 'warning',
                network: 'WARNING',
                title: 'Ev ağı gecikmeli',
                summary: 'Pano modemle zayıf haberleşiyor.',
                action: 'Modeme yaklaşın ya da Wi-Fi kurtarmayı deneyin.',
              ),
            ),
            (
              'error',
              _report(
                level: 'error',
                network: 'OFFLINE',
                power: 'SUSPECTED_OFFLINE_OR_POWER_OUTAGE',
                title: 'Pano erişilemiyor',
                summary: 'Pano ve ev modemi yanıt vermiyor.',
                action: 'Sigortayı ve modemi kontrol edin.',
              ),
            ),
          ]) {
            final env = await serviceHarness(role: 'staff', flush: () async {});
            addTearDown(env.dispose);
            await activateHome(tester, env, HomeModel(id: kHomeA, name: 'Daire 5 - Nilüfer', role: 'service_user'));
            final key = GlobalKey();
            await gallery(
              tester,
              env,
              key,
              Center(child: SingleChildScrollView(child: SystemDoctorDialog(initialData: c.$2))),
              // Tuval diyalog + perde payı kadar (eskiden 2200 dp: PNG'nin yarısı boş zemindi).
              scale > 1 ? 1600 : 1000,
              modal: true,
            );
            await settle(tester, frames: 20);
            await expectGolden(tester, key, 'doctor_${c.$1}_$tag.png', pixelRatio: ratio);
            expect(tester.takeException(), isNull);
          }
        });

        testWidgets('hesap yönetimi diyalogları ($tag)', (tester) async {
          final env = await serviceHarness(role: 'super', flush: () async {});
          addTearDown(env.dispose);
          final key = GlobalKey();
          await gallery(
            tester,
            env,
            key,
            Center(child: SingleChildScrollView(child: CreateAccountDialog(actorIsSuper: true))),
            h(900),
            modal: true,
          );
          await settle(tester, frames: 10);
          await expectGolden(tester, key, 'account_create_$tag.png', pixelRatio: ratio);

          final subscriber = parseSubscribers(<Map<String, dynamic>>[
            _sub(
              101,
              'Daire 101',
              uids: const ['AHBU-S3-A1B2C3'],
              online: 1,
              commissioned: 1,
              owner: <String, dynamic>{'full_name': 'Ayşe Yılmaz', 'email': 'ayse@ornek.test'},
            ),
          ]).first;
          final key2 = GlobalKey();
          await tester.pumpWidget(const SizedBox.shrink());
          await gallery(
            tester,
            env,
            key2,
            Center(child: SingleChildScrollView(child: AssignAdminDialog(subscriber: subscriber))),
            h(900),
            modal: true,
          );
          await settle(tester, frames: 10);
          await expectGolden(tester, key2, 'account_assign_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }, skip: visualSkipReason);
}

/// Örnek devam eden kurulum kaydı.
class SetupProgressRecordX {
  static SetupProgressRecord sample(String owner, String uid, int step, DateTime now) => SetupProgressRecord(
    ownerKey: owner,
    deviceUuid: uid,
    homeId: kClaimedHome,
    homeName: 'Daire 5 - Nilüfer',
    currentStep: step,
    customerHint: 'm***@o***.test',
    createdAt: now.subtract(const Duration(hours: 2)),
    updatedAt: now.subtract(const Duration(minutes: 5)),
  );
}
