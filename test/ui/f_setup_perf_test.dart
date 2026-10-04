import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/button_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/existing_devices_list.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/service_tool_cards.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/session_banner.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_context.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis kurulum sihirbazı akıcılık testleri (dalga 5a, WP-SETUP): PF-40 (duvar butonu dinlemesi), PF-48
/// (bağımsız LAN/REST isteklerinin eşzamanlı beklenmesi), PF-06 (`watch` -> `select`), PF-47 (çift dokunuş).
///
/// Kanıt: bildirim / yeniden kurulum **sayaçları** ve sanal saat (FakeClock) süreleri. Gerçek kare süresi ya da
/// cihaz ölçümü yoktur; hiçbir performans iddiası ölçüme dayandırılmaz.

/// `debugOnRebuildDirtyWidget` ile çalışma zamanı türü adı [typeNames] içindeki widget'ların yeniden kurulumlarını
/// (ilk kurulum dahil) sayar. Kurulum önceki kancayı korur; [uninstall] geri yükler.
class _RebuildCounter {
  _RebuildCounter(this.typeNames);

  final Set<String> typeNames;
  final Map<String, int> _counts = <String, int>{};
  RebuildDirtyWidgetCallback? _previous;

  void install() {
    _previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      _previous?.call(element, builtOnce);
      final name = element.widget.runtimeType.toString();
      if (typeNames.contains(name)) _counts[name] = (_counts[name] ?? 0) + 1;
    };
  }

  void uninstall() => debugOnRebuildDirtyWidget = _previous;

  void reset() => _counts.clear();

  int of(String typeName) => _counts[typeName] ?? 0;
}

/// Üstündeki sayfaya dokunuşları geçiren şeffaf rota: sayfa artık güncel rota DEĞİLDİR ama dokunulabilir kalır
/// (normal rotalar geçiş sırasında altındaki sayfayı kendiliğinden dokunuşa kapatır, perdeleri dokunuşu emer).
class _PassThroughRoute extends PageRouteBuilder<void> {
  _PassThroughRoute()
      : super(
          opaque: false,
          pageBuilder: (_, _, _) => const IgnorePointer(child: SizedBox.expand()),
        );

  @override
  Widget buildModalBarrier() => const SizedBox.shrink();
}

_RebuildCounter _countRebuilds(Set<String> typeNames) {
  final counter = _RebuildCounter(typeNames)..install();
  addTearDown(counter.uninstall);
  return counter;
}

void main() {
  group('PF-40: duvar butonu dinlemesi yalnız değişimde bildirir (denetleyici)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.buttons);
      await waitUntil(env, () => c.buttons.loaded && !c.isBusy);
      expect(await drive(env, c.buttons.startListening()), isTrue);
    });
    tearDown(() => env.dispose());

    test('giriş durumu sabitken 10 sn dinlemede (~50 yoklama) en çok 1 bildirim gelir', () async {
      var notifications = 0;
      c.addListener(() => notifications++);
      final polls = env.device.api.count('GET', '/api/status');

      await env.clock.elapse(const Duration(seconds: 10));

      expect(env.device.api.count('GET', '/api/status') - polls, greaterThan(40),
          reason: 'yoklama aralığı (200 ms) değişmedi: kısa basışlar kaçmasın');
      expect(notifications, lessThanOrEqualTo(1), reason: 'durum aynıyken sayfa yeniden kurulmamalı');
      expect(c.buttons.listening, isTrue);
    });

    test('basış (yükselen kenar) ve bırakış bildirilir ve algılanır; ardından yine sessiz kalır', () async {
      var notifications = 0;
      c.addListener(() => notifications++);

      env.device.setDi(1, true);
      await env.clock.elapse(const Duration(milliseconds: 400));
      expect(notifications, greaterThan(0), reason: 'basış arayüze bildirildi');
      expect(c.buttons.buttons.firstWhere((b) => b.id == 1).verdict, ButtonVerdict.detected);
      expect(c.buttons.buttons.firstWhere((b) => b.id == 1).pressed, isTrue);
      expect(c.buttons.buttons.firstWhere((b) => b.id == 1).detectedAt, isNotNull);

      final afterPress = notifications;
      env.device.setDi(1, false);
      await env.clock.elapse(const Duration(milliseconds: 400));
      expect(notifications, greaterThan(afterPress), reason: 'bırakış da (basılı göstergesi) bildirildi');
      expect(c.buttons.buttons.firstWhere((b) => b.id == 1).pressed, isFalse);

      final settled = notifications;
      await env.clock.elapse(const Duration(seconds: 6));
      expect(notifications, settled, reason: 'durum yine sabit: bildirim yok');
    });

    test('çocuk kilidi bilgisi değişince bildirilir (uyarı kartı güncellenir)', () async {
      var notifications = 0;
      c.addListener(() => notifications++);
      expect(c.buttons.childLockOn, isFalse);

      env.device.childLock = true;
      await env.clock.elapse(const Duration(milliseconds: 400));

      expect(c.buttons.childLockOn, isTrue);
      expect(notifications, greaterThan(0));
    });

    test('kısa basış (400 ms kenar) kaçırılmaz', () async {
      env.device.setDi(2, true);
      await env.clock.elapse(const Duration(milliseconds: 200));
      env.device.setDi(2, false);
      await env.clock.elapse(const Duration(milliseconds: 200));
      expect(c.buttons.buttons.firstWhere((b) => b.id == 2).verdict, ButtonVerdict.detected);
    });
  });

  group('PF-40: duvar butonu dinlemesi (arayüz)', () {
    testWidgets('9. adım dinlerken sayfa ve kartlar giriş durumu değişmedikçe yeniden kurulmaz; basışta kurulur', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      final counter = _countRebuilds(<String>{'Step9Buttons', '_ButtonCard'});
      await openWizardResumedAt(tester, env, SetupSteps.buttons);
      await pumpUntil(tester, env, () => present('btn_listen_toggle'), reason: 'girişler listelenmedi');
      await tapKey(tester, 'btn_listen_toggle');
      await pumpUntil(tester, env, () => find.text('Dinlemeyi Durdur').evaluate().isNotEmpty);
      await settle(tester);

      counter.reset();
      final polls = env.device.api.count('GET', '/api/status');
      for (var i = 0; i < 40; i++) {
        env.clock.advance(const Duration(milliseconds: 250));
        await tester.pump();
      }
      expect(env.device.api.count('GET', '/api/status') - polls, greaterThan(30), reason: 'dinleme sürdü (yoklama çalıştı)');
      expect(counter.of('_ButtonCard'), 0, reason: '10 sn boyunca giriş kartları yeniden kurulmadı');
      expect(counter.of('Step9Buttons'), 0, reason: 'adım gövdesi de yeniden kurulmadı');

      env.device.setDi(1, true);
      for (var i = 0; i < 4; i++) {
        env.clock.advance(const Duration(milliseconds: 100));
        await tester.pump();
      }
      expect(find.descendant(of: find.byKey(const Key('card_button_1')), matching: find.text('Algılandı')), findsOneWidget);
      expect(counter.of('_ButtonCard'), greaterThan(0), reason: 'basış kartları güncelledi');
    });
  });

  group('PF-48: bağımsız LAN ve REST istekleri eşzamanlı beklenir', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    tearDown(() => env.dispose());

    test('6. adım (bulut bekleme): sunucu 5 sn, LAN zaman aşımı 4 sn sürse de tur ~5 sn sürer (9 sn değil)', () async {
      env = await serviceHarness();
      c = await completeClaim(env);
      await completeWifi(env, c);
      final writeCloudAnswer = env.device.onMqttConfigured;
      env.device.onMqttConfigured = (server, port, user, pass) {
        writeCloudAnswer?.call(server, port, user, pass);
        // Kimlik yazıldı; telefon artık panonun ağında değil (4 sn bağlantı zaman aşımı) ve sunucu yavaş (5 sn).
        env.device.lanReachable = false;
        env.device.unreachableDelay = const Duration(seconds: 4);
        env.cloud.devicesDelay = const Duration(seconds: 5);
      };

      final started = env.clock.now();
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      final took = env.clock.now().difference(started);

      expect(took, greaterThanOrEqualTo(const Duration(seconds: 5)), reason: 'sunucu yanıtı beklendi');
      expect(took, lessThan(const Duration(seconds: 7)), reason: 'sıralı bekleme 9 sn tutardı (4 + 5)');
      expect(c.cloud.lanStatus, isNull, reason: 'LAN tanısı en iyi çabadır: erişilemeyince boş kalır');
      expect(c.cloud.online, isTrue);
    });

    test('10. adım (teslim özeti): sunucu 5 sn, LAN zaman aşımı 4 sn sürse de yenileme ~5 sn sürer (9 sn değil)', () async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.handover);
      env.device.lanReachable = false;
      env.device.unreachableDelay = const Duration(seconds: 4);
      env.cloud.devicesDelay = const Duration(seconds: 5);

      final started = env.clock.now();
      expect(await drive(env, c.handover.refreshSummary()), isTrue);
      final took = env.clock.now().difference(started);

      expect(took, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(took, lessThan(const Duration(seconds: 7)), reason: 'sıralı bekleme 9 sn tutardı (4 + 5)');
      expect(c.handover.cloudOnlineNow, isTrue);
      expect(c.handover.lanStatus, isNull, reason: 'pano ağında değil: yalnız sunucu bilgisiyle devam edilir');
    });

    test('8. adım (panjur listesi): uç noktalar LAN yanıtı beklenmeden istenir; LAN hatası öncelikli kalır', () async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.shutters);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
      env.device.lanReachable = false;
      env.device.unreachableDelay = const Duration(seconds: 4);
      final before = env.cloud.calls.where((x) => x.startsWith('fetchEndpoints:')).length;

      final load = c.shutters.load();
      await env.clock.elapse(const Duration(seconds: 2)); // LAN hâlâ bağlantı zaman aşımında (4 sn)
      expect(env.cloud.calls.where((x) => x.startsWith('fetchEndpoints:')).length, before + 1,
          reason: 'REST isteği LAN zaman aşımını beklemeden başladı');

      expect(await drive(env, load), isFalse);
      expect(c.shutters.problem!.kind, SetupProblemKind.deviceNetwork, reason: 'LAN hatası sıralı koddaki gibi öncelikli');
    });
  });

  group('awaitBoth: iki bağımsız işi birlikte bekler', () {
    test('iki sonuç birlikte döner', () async {
      final (a, b) = await awaitBoth<int, String>(Future<int>.value(1), Future<String>.value('iki'));
      expect(a, 1);
      expect(b, 'iki');
    });

    test('ikisi de hata verirse ilkinin hatası (sıralı koddaki öncelik) fırlar; ikincisininki işlenmemiş kalmaz', () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final first = Completer<int>();
        final second = Completer<int>();
        final both = awaitBoth<int, int>(first.future, second.future);
        second.completeError(StateError('ikinci'));
        await pumpEventQueue();
        first.completeError(ArgumentError('birinci'));
        await expectLater(both, throwsA(isA<ArgumentError>()));
      }, (error, stack) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('yalnız ikincisi hata verirse onun hatası fırlar', () async {
      await expectLater(
        awaitBoth<int, int>(Future<int>.value(1), Future<int>.error(StateError('ikinci'))),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('PF-06: watch -> select (ikincil yüzeyler yalnız kendi verisi değişince kurulur)', () {
    testWidgets('ServiceSessionBanner (personel): AutomationState bildirimleri ve saat ilerlemesi bandı yeniden kurmaz', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      final counter = _countRebuilds(<String>{'ServiceSessionBanner'});
      await pumpPage(tester, env, const Scaffold(body: ServiceSessionBanner()), size: const Size(500, 400));
      expect(present('service_session_banner'), isTrue);

      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.state.setThemeModeForTesting(ThemeMode.dark); // ilgisiz bildirim
        await tester.pump();
      }
      for (var i = 0; i < 5; i++) {
        env.clock.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      expect(counter.of('ServiceSessionBanner'), 0, reason: 'personel bandında geri sayım yok: saniyelik yeniden kurulum gereksiz');
    });

    testWidgets('ServiceSessionBanner (PIN oturumu): geri sayım saniyede bir tazelenmeye devam eder', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(tester, env, const Scaffold(body: ServiceSessionBanner()), size: const Size(500, 400));
      final before = tester.widget<Text>(find.byKey(const Key('service_session_text'))).data!;

      env.clock.advance(const Duration(seconds: 3));
      await tester.pump();
      final after = tester.widget<Text>(find.byKey(const Key('service_session_text'))).data!;

      expect(after, isNot(before), reason: 'kalan süre ilerledi');
      expect(after, contains('Kalan'));
    });

    testWidgets('ExistingDevicesList: ilgisiz bildirimlerde yeniden kurulmaz; daire/pano değişince güncellenir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      final counter = _countRebuilds(<String>{'ExistingDevicesList'});
      await pumpPage(
        tester,
        env,
        Scaffold(body: SingleChildScrollView(child: ExistingDevicesList(onOpen: (_, _) {}))),
        size: const Size(500, 800),
      );
      expect(present('existing_no_home'), isTrue);

      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.state.setThemeModeForTesting(ThemeMode.dark);
        await tester.pump();
      }
      expect(counter.of('ExistingDevicesList'), 0);

      env.state.setHomesForTesting(<HomeModel>[HomeModel(id: kClaimedHome, name: 'Daire 5', role: 'service_user')]);
      env.state.setDevicesForTesting(<DeviceInfo>[const DeviceInfo(deviceUuid: kDeviceUid, name: 'Pano')]);
      await tester.pump();
      expect(find.byKey(const Key('card_existing_$kDeviceUid')), findsOneWidget);
      expect(counter.of('ExistingDevicesList'), greaterThan(0));
    });

    testWidgets('ServiceToolCards: ilgisiz bildirimlerde yeniden kurulmaz; yetki değişince güncellenir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      final counter = _countRebuilds(<String>{'ServiceToolCards'});
      await pumpPage(
        tester,
        env,
        const Scaffold(body: SingleChildScrollView(child: ServiceToolCards())),
        size: const Size(500, 1000),
      );
      expect(find.text('Stoğunuzdaki panolar ve karekodları'), findsOneWidget, reason: 'servis personeli: stok yönetimi yok');

      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.state.setThemeModeForTesting(ThemeMode.dark);
        await tester.pump();
      }
      expect(counter.of('ServiceToolCards'), 0);

      env.state.setCurrentUserForTesting(
        const UserModel(id: 'super-1', email: 'yonetici@ornek.test', fullName: 'Yönetici', role: 'super_user'),
      );
      await tester.pump();
      expect(find.text('Stok, karekod ve etiket yönetimi'), findsOneWidget, reason: 'süper yönetici: stok yönetimi var');
      expect(counter.of('ServiceToolCards'), greaterThan(0));
    });
  });

  group('PF-47: servis aracı kartlarında çift dokunuş', () {
    Future<ServiceHarness> pumpCards(WidgetTester tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        const Scaffold(body: SingleChildScrollView(child: ServiceToolCards(includeSetup: true))),
        size: const Size(500, 1000),
      );
      return env;
    }

    testWidgets('normal dokunuş servis panelini tek kez açar', (tester) async {
      await pumpCards(tester);
      await tester.tap(find.byKey(const Key('card_tool_setup')));
      await tester.tap(find.byKey(const Key('card_tool_setup')), warnIfMissed: false); // aynı karede ikinci dokunuş
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ServiceModePage, skipOffstage: false), findsNWidgets(1));
    });

    testWidgets('kartın rotası güncel değilse (üstte dokunuşları geçiren başka rota var) dokunuş ikinci sayfa açmaz', (tester) async {
      await pumpCards(tester);
      // Kartların üstüne dokunuşları alta geçiren (engelleyici perdesiz) şeffaf bir rota (yarı saydam katman benzeri).
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(_PassThroughRoute()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const Key('card_tool_setup')), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ServiceModePage, skipOffstage: false), findsNothing, reason: 'kart artık güncel rotada değil');

      navigator.pop(); // şeffaf rota kapandı: kart yeniden çalışır
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('card_tool_setup')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ServiceModePage, skipOffstage: false), findsNWidgets(1));
    });
  });
}
