import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/app_shell.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:ev_otomasyon/ui/pages/replace_board_dialog.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_subscribers_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_clipboard.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:ev_otomasyon/ui/pages/system_doctor_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../support/support.dart' show kHomeA, kHomeB;
import 'f_support.dart';
import 'f_widget_support.dart';

/// WP-SVC-PAGES (Dalga 5a): servis sayfaları akıcılık sözleşmeleri.
///
/// * PF-47: servis panelindeki girişlere aynı karede iki dokunuş tek sihirbaz rotası açar.
/// * PF-49: hesap listesi `ListView.builder` ile kurulur (yalnızca görünen kartlar oluşturulur).
/// * PF-06: sayfa/diyalog kökleri tüm durumu izlemez; ilgisiz bildirimler onları yeniden kurmaz.
/// * PF-15 (c): opak sayfalarda ikinci (iç içe) `CircuitBackground` yoktur.
/// * PF-50: etiket yeniden üretimi sürerken ilerleme göstergesi vardır.
/// * PF-25: kayıt tarihi biçimi değişmedi (sıcak yolda `DateFormat` kurulmaz).
///
/// Ölçüm değil kanıt: yeniden kurulma sayaçları ([debugOnRebuildDirtyWidget]), rota sayısı, ağaçtaki katman sayısı
/// ve yapısal denetimler. Saniye/kare süresi iddiası yoktur.

// =============================================================================
// Yardımcılar
// =============================================================================

/// `debugOnRebuildDirtyWidget` ile [match]'e uyan widget'ların öğelerinin yeniden kurulma sayısını sayar.
///
/// Yerel sayaçtır (ortak test altyapısına bağlı değil). İlk kurulum da sayılır: kurulum/yükleme tamamlandıktan
/// SONRA oluşturun ya da [reset] çağırın. `builtOnce` bayrağına güvenilmez (yalnızca `debugPrintRebuildDirtyWidgets`
/// açıkken set edilir).
class _RebuildProbe {
  _RebuildProbe(this.match) {
    _previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      if (match(element.widget)) count++;
      _previous?.call(element, builtOnce);
    };
  }

  final bool Function(Widget widget) match;
  RebuildDirtyWidgetCallback? _previous;
  int count = 0;

  void reset() => count = 0;

  /// Önceki kancayı geri yükler.
  void stop() => debugOnRebuildDirtyWidget = _previous;
}

/// Sayfaların görünümünü etkilemeyen bildirimler: pano çevrimiçi/çevrimdışı geçişleri ve durum yenilemeleri
/// (rol, oturum, aktif daire ve yetkiler değişmez).
Future<void> _irrelevantNotifications(WidgetTester tester, AutomationState state) async {
  for (var i = 0; i < 4; i++) {
    state.setPresenceForTesting(i.isEven ? DevicePresence.online : DevicePresence.offline);
    await tester.pump();
  }
  state.setStatusForTesting(null);
  await tester.pump();
}

/// Yetkisiz (düz müşteri) kullanıcı: servis yetkilerinin hepsi kapanır.
const UserModel _plainUser = UserModel(id: 'cust-1', email: 'musteri@ornek.test', fullName: 'Müşteri', role: 'user');

bool _present(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

/// Düğmeyi işaretçi OLMADAN, kare üretmeden iki kez etkinleştirir: erişilebilirlik eylemi (TalkBack/anahtar erişimi)
/// ya da klavye Enter/Boşluk tekrarı gibi yollar. İşaretçi dokunuşlarını Navigator aynı karede zaten emer
/// (`Navigator._cancelActivePointers`); bu yollar emilmez, korumayı sayfa/diyalog bayrağı sağlar.
void _doubleActivate(WidgetTester tester, String key) {
  final root = find.byKey(Key(key));
  expect(root, findsOneWidget, reason: 'düğme bulunamadı: $key');
  final direct = tester.widgetList(root).whereType<ButtonStyleButton>();
  final button = direct.isNotEmpty
      ? direct.first
      : tester.widget<ButtonStyleButton>(find.descendant(of: root, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
  final onPressed = button.onPressed;
  expect(onPressed, isNotNull, reason: '$key etkin olmalı');
  onPressed!();
  onPressed();
}

/// Rota itmelerini sayar.
class _PushCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

Map<String, dynamic> _acct(String id, String name, {String role = 'user'}) => <String, dynamic>{
      'id': id,
      'full_name': name,
      'email': '$id@ornek.test',
      'phone': null,
      'role': role,
      'is_active': true,
      'account_status': 'active',
      'admin_notes': null,
    };

HomeModel _staffHome({String id = kHomeA, String name = 'Daire 5 - Nilüfer', String role = 'service_user'}) =>
    HomeModel(id: id, name: name, role: role);

void main() {
  setUpAll(() {
    // AppShell testlerinde ağdan yazı tipi indirilmez.
    GoogleFonts.config.allowRuntimeFetching = false;
  });
  setUp(SecretClipboard.reset);

  // ===========================================================================
  // PF-47
  // ===========================================================================
  group('PF-47: servis paneli girişlerinde çift dokunuş tek sihirbaz açar', () {
    Future<ServiceHarness> openPanel(WidgetTester tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 2400),
      );
      await settle(tester);
      return env;
    }

    // Çevrimdışı (üstü kapalı) rotalar da sayılır: ikinci rota alttakini "offstage" yapar.
    int wizards() => find.byType(ServiceSetupWizardPage, skipOffstage: false).evaluate().length;

    Future<void> finishTransition(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('"Yeni Kurulum Başlat" aynı karede iki kez etkinleştirilse de TEK sihirbaz rotası açılır; dönünce yeniden açılabilir',
        (tester) async {
      await openPanel(tester);

      _doubleActivate(tester, 'btn_new_setup');
      await finishTransition(tester);
      expect(wizards(), 1, reason: 'ikinci etkinleştirme ikinci sihirbaz denetleyicisi/rotası açmamalı');
      await settle(tester, frames: 10);
      expect(_present('setup_step_1'), isTrue);

      // Rota kapanınca bayrak bırakılır: panel kalıcı kilitlenmez.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await finishTransition(tester);
      expect(wizards(), 0);
      expect(_present('btn_new_setup'), isTrue);

      _doubleActivate(tester, 'btn_new_setup');
      await finishTransition(tester);
      expect(wizards(), 1, reason: 'dönüşten sonra yeniden açılabilir (ve yine tek rota)');
    });

    testWidgets('devam eden kurulumun "Devam Et" düğmesi aynı karede iki kez etkinleştirilse de TEK sihirbaz açılır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      final now = env.clock.now().toUtc();
      await env.store.save(SetupProgressRecord(
        ownerKey: env.access.ownerKey,
        deviceUuid: kDeviceUid,
        homeId: kClaimedHome,
        homeName: 'Daire 5 - Nilüfer',
        currentStep: 6,
        customerHint: 'm***@o***.test',
        createdAt: now.subtract(const Duration(hours: 2)),
        updatedAt: now.subtract(const Duration(minutes: 5)),
      ));
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 2400),
      );
      await settle(tester);

      _doubleActivate(tester, 'btn_resume_$kDeviceUid');
      await finishTransition(tester);
      expect(wizards(), 1);
      await settle(tester, frames: 20);
      expect(_present('setup_step_6'), isTrue, reason: 'kayıtlı adımdan açılır');
    });

    testWidgets('sistem doktorunda "Wi-Fi kurtarma" aynı karede iki kez etkinleştirilse de TEK kurtarma penceresi açılır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await activateHome(tester, env, _staffHome());
      final counter = _PushCounter();
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: env.state,
          child: MaterialApp(
            navigatorObservers: <NavigatorObserver>[counter],
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('launcher'),
                    onPressed: () => SystemDoctorDialog.show(
                      context,
                      initialData: <String, dynamic>{
                        'home_network': <String, dynamic>{'status': 'OFFLINE', 'seconds_since_last_seen': 1800},
                        'diagnosis_level': 'error',
                      },
                    ),
                    child: const Text('aç'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('launcher')));
      await settle(tester);
      expect(_present('btn_doctor_recovery'), isTrue, reason: 'ev ağı kapalı: Wi-Fi kurtarma önerilir');
      final before = counter.pushes;

      _doubleActivate(tester, 'btn_doctor_recovery');
      await finishTransition(tester);

      expect(counter.pushes - before, 1, reason: 'ikinci etkinleştirme açılan kurtarma penceresini kapatıp yenisini açmamalı');
      expect(find.byType(SystemDoctorDialog), findsNothing);
      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    });
  });

  // ===========================================================================
  // PF-49
  // ===========================================================================
  group('PF-49: hesap listesi tembel kurulur', () {
    testWidgets('1000 hesapta liste ListView.builder ile kurulur: yalnızca görünen kartlar ağaçtadır, son karta kaydırılır',
        (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.adminUsers = <Map<String, dynamic>>[
        _acct('super-1', 'Yönetici', role: 'super_user'),
        for (var i = 1; i <= 999; i++) _acct('u$i', 'Müşteri $i'),
      ];
      await pumpPage(tester, env, const ServiceManagementPage(pageSize: 1000), size: const Size(900, 1600));
      await settle(tester);

      final list = tester.widget<ListView>(find.byKey(const Key('accounts_list')));
      expect(
        list.childrenDelegate,
        isA<SliverChildBuilderDelegate>(),
        reason: 'eager `ListView(children: ...)` her kurulumda n kart widget\'ı ve n freezeBlock hesabı üretir',
      );
      expect(
        (list.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount,
        greaterThanOrEqualTo(1000),
        reason: 'tüm hesaplar listede: başlık/filtre öğeleri + 1000 kart',
      );

      int built() => find.byWidgetPredicate((w) {
            final k = w.key;
            return k is ValueKey<String> && k.value.startsWith('card_account_');
          }).evaluate().length;
      expect(built(), inInclusiveRange(1, 29), reason: 'yalnızca görünen kartlar ağaçta');

      // Son karta ulaşılır (tembel liste doğru çalışır).
      final scrollable = find.descendant(of: find.byKey(const Key('accounts_list')), matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      for (var i = 0; i < 8; i++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      expect(find.byKey(const Key('card_account_u999')), findsOneWidget);
      expect(built(), inInclusiveRange(1, 29), reason: 'sonda da yalnızca görünen kartlar');
    });

    testWidgets('listenin sonundaki (tembel kurulan) kartın eylemleri doğru hesaba gider', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.adminUsers = <Map<String, dynamic>>[
        _acct('super-1', 'Yönetici', role: 'super_user'),
        for (var i = 1; i <= 299; i++) _acct('u$i', 'Müşteri $i'),
      ];
      await pumpPage(tester, env, const ServiceManagementPage(pageSize: 300), size: const Size(900, 1600));
      await settle(tester);

      final scrollable = find.descendant(of: find.byKey(const Key('accounts_list')), matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      for (var i = 0; i < 8; i++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      expect(find.byKey(const Key('card_account_u299')), findsOneWidget);

      await tapKey(tester, 'btn_freeze_u299');
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester);
      expect(env.cloud.adminUpdates, hasLength(1));
      expect(env.cloud.adminUpdates.single['id'], 'u299', reason: 'eylem, kartın ait olduğu hesaba gider');
      expect(env.cloud.adminUpdates.single['is_active'], false);
      expect(find.descendant(of: find.byKey(const Key('status_u299')), matching: find.text('Donduruldu')), findsOneWidget);
    });
  });

  // ===========================================================================
  // PF-06
  // ===========================================================================
  group('PF-06: ilgisiz bildirimler sayfa/diyalog köklerini yeniden kurmaz', () {
    testWidgets('ServiceModePage', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 2400),
      );
      await settle(tester, frames: 20);
      expect(_present('btn_new_setup'), isTrue);

      final probe = _RebuildProbe((w) => w is ServiceModePage);
      addTearDown(probe.stop);
      await _irrelevantNotifications(tester, env.state);
      expect(probe.count, 0, reason: 'çevrimiçi/çevrimdışı ve durum bildirimleri sayfa kökünü kurmamalı');

      // İlgili değişiklik yine yansır: yetkisiz hesaba geçince panel yerine "yetkisiz" kartı çıkar.
      env.state.setCurrentUserForTesting(_plainUser);
      await tester.pump();
      expect(probe.count, greaterThan(0));
      expect(_present('service_denied'), isTrue);
      expect(_present('btn_new_setup'), isFalse);
    });

    testWidgets('ServiceManagementPage', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(tester, env, const ServiceManagementPage(autoLoad: false), size: const Size(900, 2400));
      await settle(tester);
      expect(_present('accounts_empty'), isTrue);

      final probe = _RebuildProbe((w) => w is ServiceManagementPage);
      addTearDown(probe.stop);
      await _irrelevantNotifications(tester, env.state);
      expect(probe.count, 0, reason: 'ilgisiz bildirimler sayfa kökünü kurmamalı');

      env.state.setCurrentUserForTesting(_plainUser);
      await tester.pump();
      expect(probe.count, greaterThan(0));
      expect(_present('management_denied'), isTrue, reason: 'yetki kalkınca sayfa yetkisiz görünümüne geçer');
    });

    testWidgets('DeviceInventoryPage', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.state.setInventoryDevicesForTesting(<InventoryDeviceModel>[inventoryDevice()]);
      await pumpPage(tester, env, const DeviceInventoryPage(autoLoad: false), size: const Size(900, 3000));
      await settle(tester);
      expect(_present('btn_suspend_$kDeviceUid'), isTrue, reason: 'süper yönetici yönetim düğmelerini görür');

      final probe = _RebuildProbe((w) => w is DeviceInventoryPage);
      addTearDown(probe.stop);
      await _irrelevantNotifications(tester, env.state);
      expect(probe.count, 0, reason: 'yalnızca canManageInventory için tüm sayfa kurulmaz (select<bool>)');

      // Yetki düşünce (servis personeli) yönetim düğmeleri kalkar: select yine tepki verir.
      env.state.setCurrentUserForTesting(const UserModel(
        id: 'staff-1',
        email: 'servis@ornek.test',
        fullName: 'Servis Ali',
        role: 'service_user',
      ));
      await tester.pump();
      expect(probe.count, greaterThan(0));
      expect(_present('btn_suspend_$kDeviceUid'), isFalse);
      expect(_present('btn_qr_$kDeviceUid'), isTrue, reason: 'karekod herkese açık kalır');
    });

    testWidgets('ReplaceBoardDialog', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[
        DeviceInfo(deviceUuid: 'AHBU-S3-OLD001', name: 'Salon Panosu', online: false, firmware: '1.1.0'),
      ];
      await activateHome(tester, env, _staffHome());
      await pumpLauncher(tester, env, (ctx) => ReplaceBoardDialog.show(ctx));
      await tester.tap(find.byKey(const Key('launcher')));
      await settle(tester);
      expect(_present('replace_target_home'), isTrue);

      final probe = _RebuildProbe((w) => w is ReplaceBoardDialog);
      addTearDown(probe.stop);
      await _irrelevantNotifications(tester, env.state);
      expect(probe.count, 0, reason: 'form açıkken gelen ilgisiz bildirimler pencereyi kurmamalı');

      // Aktif daire değişince (yanlış daire riski) uyarı yine çıkar.
      env.state.setHomesForTesting(<HomeModel>[_staffHome(id: kHomeB, name: 'Başka Daire')]);
      await tester.pump();
      expect(probe.count, greaterThan(0));
      expect(_present('replace_home_changed'), isTrue);
    });

    testWidgets('SystemDoctorDialog', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await activateHome(tester, env, _staffHome());
      await pumpLauncher(tester, env, (ctx) => SystemDoctorDialog.show(ctx, initialData: const <String, dynamic>{}));
      await tester.tap(find.byKey(const Key('launcher')));
      await settle(tester);
      expect(find.text('Daire: Daire 5 - Nilüfer'), findsOneWidget);

      final probe = _RebuildProbe((w) => w is SystemDoctorDialog);
      addTearDown(probe.stop);
      await _irrelevantNotifications(tester, env.state);
      expect(probe.count, 0, reason: 'tanı penceresi ilgisiz bildirimlerle kurulmamalı');

      env.state.setHomesForTesting(<HomeModel>[_staffHome(name: 'Yeni Ad')]);
      await tester.pump();
      expect(probe.count, greaterThan(0));
      expect(find.text('Daire: Yeni Ad'), findsOneWidget, reason: 'daire adı değişince başlık güncellenir');
    });
  });

  // ===========================================================================
  // PF-15 (c)
  // ===========================================================================
  group('PF-15 (c): opak sayfalarda ikinci CircuitBackground yok', () {
    final pages = <String, Widget Function()>{
      'cihaz envanteri': () => const DeviceInventoryPage(),
      'servis yönetimi': () => const ServiceManagementPage(),
      // Servis paneli ve aboneler de opak `Scaffold` rengiyle küresel katmanı örtüyordu (sayfa değişince zemin "devre kartlı"dan
      // "düz lacivert"e atlıyordu).
      'servis paneli': () => const ServiceModePage(),
      'aboneler': () => const ServiceSubscribersPage(),
    };
    for (final entry in pages.entries) {
      testWidgets('${entry.key}: AppShell içinde tam bir CircuitBackground (küresel katman) vardır; Scaffold saydamdır', (tester) async {
        final env = await serviceHarness(role: 'super', flush: () async {});
        addTearDown(env.dispose);
        tester.view.physicalSize = const Size(900, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ChangeNotifierProvider<AutomationState>.value(
            value: env.state,
            child: AppShell(
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      key: const Key('launcher'),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => entry.value())),
                      child: const Text('aç'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(CircuitBackground), findsOneWidget, reason: 'AppShell küresel arka planı');

        await tester.tap(find.byKey(const Key('launcher')));
        await settle(tester, frames: 20);
        final pageFinder = find.byWidgetPredicate((w) => w.runtimeType == entry.value().runtimeType);
        expect(pageFinder, findsOneWidget, reason: 'sayfa açıldı');
        expect(
          find.byType(CircuitBackground),
          findsOneWidget,
          reason: 'opak Scaffold içinde ikinci CircuitBackground, küresel katmanı örtüp tam ekran katmanları ikiye katlar',
        );

        final scaffoldFinder = find.descendant(of: pageFinder, matching: find.byType(Scaffold)).first;
        final scaffold = tester.widget<Scaffold>(scaffoldFinder);
        final effective = scaffold.backgroundColor ?? Theme.of(tester.element(scaffoldFinder)).scaffoldBackgroundColor;
        expect(effective.a, 0.0, reason: 'Scaffold saydam: küresel devre arka planı görünür kalır');
      });
    }
  });

  // ===========================================================================
  // PF-50 / PF-25 (envanter)
  // ===========================================================================
  group('envanter sayfası', () {
    testWidgets('PF-50: etiket yeniden üretimi sürerken ilerleme göstergesi çıkar; sonuç penceresi açıkken sayfa arkasında dönmez',
        (tester) async {
      final env = await serviceHarness(role: 'super', inventoryListed: true, flush: () async {});
      addTearDown(env.dispose);
      ClipboardSpy().install(tester);
      env.cloud.reissueGate = Completer<void>();
      await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(900, 3000));
      await settle(tester);
      expect(_present('inventory_reissue_progress'), isFalse, reason: 'işlem yokken gösterge yok');

      await tapKey(tester, 'btn_reissue_label_$kDeviceUid');
      await typeKey(tester, 'field_confirm_phrase', kDeviceUid);
      await tapKey(tester, 'btn_confirm_destructive');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(env.cloud.calls, contains('reissueInventoryLabel:$kDeviceUid'), reason: 'istek gönderildi ve yanıt bekleniyor');
      expect(_present('inventory_reissue_progress'), isTrue, reason: 'uzun, kapatılamayan kilit için ilerleme göstergesi');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      env.cloud.reissueGate!.complete();
      await settle(tester, frames: 20);
      expect(find.text('705 318'), findsOneWidget, reason: 'tek seferlik PIN gösterildi');
      expect(
        _present('inventory_reissue_progress'),
        isFalse,
        reason: 'yanıt geldi: gösterge kalkar (sonuç penceresinin arkasında sonsuz animasyon dönmez)',
      );

      await tapKey(tester, 'btn_reissue_close');
      await settle(tester, frames: 20);
      expect(_present('inventory_reissue_progress'), isFalse);
    });

    testWidgets('PF-25: kayıt tarihi gg.aa.yyyy ss:dd biçiminde yerel saatle gösterilir (biçim değişmedi)', (tester) async {
      final env = await serviceHarness(role: 'super', inventoryListed: true, flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(900, 3000));
      await settle(tester);

      final expected = DateFormat('dd.MM.yyyy HH:mm').format(inventoryDevice().createdAt.toLocal());
      expect(find.text(expected), findsOneWidget, reason: 'biçim intl DateFormat(dd.MM.yyyy HH:mm) ile aynı kalır');
    });
  });
}
