import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_watch_controller.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_watch_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_watch_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/settings/alarm_watch_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// "Arka planda alarm bildirimi" ayarı: denetleyici (izin, kalıcı ayar, servis, çıkışta kapanma, dokunuş) ve kart
/// (Android / iOS metni, küçük ekran + büyük yazı yerleşimi).
class _FakePlatform implements AlarmWatchPlatform {
  _FakePlatform({this.supported = true});

  final bool supported;
  bool allowed = false;
  bool grantOnRequest = true;
  bool exempt = false;
  bool running = false;
  bool startOk = true;
  int starts = 0;
  int stops = 0;
  int permissionRequests = 0;
  int batteryRequests = 0;
  String? launch;
  final StreamController<String> tapController = StreamController<String>.broadcast();

  @override
  bool get isSupported => supported;

  @override
  Future<bool> notificationsAllowed() async => allowed;

  @override
  Future<bool> requestNotifications() async {
    permissionRequests++;
    allowed = grantOnRequest;
    return allowed;
  }

  @override
  Future<bool> batteryOptimizationIgnored() async => exempt;

  @override
  Future<bool> requestBatteryExemption() async {
    batteryRequests++;
    exempt = true;
    return true;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> start() async {
    starts++;
    running = startOk;
    return startOk;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
  }

  @override
  Stream<String> get taps => tapController.stream;

  @override
  Future<String?> takeLaunchPayload() async {
    final l = launch;
    launch = null;
    return l;
  }
}

const _user = UserModel(id: 'u1', email: 'ev@ornek.test', fullName: 'Ev Sahibi', role: 'user');

void main() {
  late StateHarness h;
  late _FakePlatform platform;
  late MemoryAlarmWatchStore store;

  AlarmWatchController controller() {
    final c = AlarmWatchController(state: h.state, platform: platform, store: store);
    addTearDown(c.dispose);
    return c;
  }

  void signIn({String role = 'owner', UserModel user = _user}) {
    h.state
      ..setCurrentUserForTesting(user)
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setHomesForTesting(<HomeModel>[testHome(role: role, name: 'Evim')]);
  }

  setUp(() {
    h = StateHarness();
    platform = _FakePlatform();
    store = MemoryAlarmWatchStore();
  });

  tearDown(() => h.dispose());

  group('denetleyici', () {
    test('kapalı başlar; açınca izin istenir, ayar (kullanıcı + uygun evler) kaydedilir, servis başlar', () async {
      signIn();
      final c = controller();
      await c.init();
      expect(c.enabled, isFalse);
      expect(c.eligible, isTrue);

      expect(await c.enable(), isTrue);
      expect(platform.permissionRequests, 1);
      expect(platform.starts, 1);
      expect(c.enabled, isTrue);
      expect(c.running, isTrue);
      final saved = await AlarmWatchSettingsRepository(store).load();
      expect(saved.enabled, isTrue);
      expect(saved.userId, 'u1');
      expect(saved.homes.single.id, kHomeA);

      await c.disable();
      expect(platform.stops, 1);
      expect((await AlarmWatchSettingsRepository(store).load()).enabled, isFalse);
    });

    test('uyelik-4: ön plana dönüşte servis kendini durdurmuşsa (ör. şifre değişince oturumu bitti) yeniden başlatılır',
        () async {
      signIn();
      final c = controller();
      await c.init();
      expect(await c.enable(), isTrue);
      expect(platform.starts, 1);
      expect(c.running, isTrue);

      platform.running = false; // arka plan servisi oturum bitince kendini durdurdu
      c.handleResume();
      await pumpEventQueue();
      expect(platform.starts, 2);
      expect(c.running, isTrue);

      // Durum değişimlerinde de (en çok 60 sn'de bir) denetlenir.
      platform.running = false;
      h.state.setThemeModeForTesting(ThemeMode.light); // dinleyicileri uyandırır
      await pumpEventQueue();
      expect(platform.starts, 2, reason: '60 sn dolmadan yeniden sorulmaz');
      await h.clock.elapse(const Duration(seconds: 61));
      h.state.setThemeModeForTesting(ThemeMode.dark);
      await pumpEventQueue();
      expect(platform.starts, 3);
    });

    test('bildirim izni verilmezse açılmaz ve açıklama gösterilir', () async {
      signIn();
      platform.grantOnRequest = false;
      final c = controller();
      await c.init();
      expect(await c.enable(), isFalse);
      expect(c.enabled, isFalse);
      expect(c.message, contains('Bildirim izni'));
      expect(platform.starts, 0);
    });

    test('misafir ve servis hesabı açamaz', () async {
      signIn(role: 'guest');
      final c = controller();
      await c.init();
      expect(c.eligible, isFalse);
      expect(await c.enable(), isFalse);

      // Müşteri evindeki servis üyeliği (ev rolü service_user) izlenmez.
      signIn(role: 'service_user', user: const UserModel(id: 'u2', email: 's', fullName: 'Servis', role: 'service_user'));
      expect(c.eligible, isFalse);
      expect(platform.starts, 0);
      // guvenlik-12: kendi evinin sahibi olan servis personeli açabilir.
      signIn(user: const UserModel(id: 'u2', email: 's', fullName: 'Servis', role: 'service_user'));
      expect(c.eligible, isTrue);
    });

    test('çıkış yapılınca kapanır ve servis durur; başka kullanıcı girince de', () async {
      signIn();
      final c = controller();
      await c.init();
      await c.enable();
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await pumpEventQueue();
      expect(c.enabled, isFalse);
      expect(platform.stops, 1);

      signIn();
      await c.enable();
      signIn(user: const UserModel(id: 'u9', email: 'b', fullName: 'Başkası', role: 'user'));
      await pumpEventQueue();
      expect(c.enabled, isFalse);
      expect(platform.stops, 2);
    });

    test('cekirdek-3: güvenli depo okunamadı (soğuk açılış): ayar ve servis korunur; gerçek çıkışta kapanır', () async {
      await AlarmWatchSettingsRepository(store).save(const AlarmWatchSettings(enabled: true, userId: 'u1'));
      h.dispose();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = FakeStorage();
      storage.memory.failReads = true; // soğuk Keystore okuması başarısız / zaman aşımı
      h = StateHarness(storage: storage, autoInit: true);
      await h.state.ready;
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.storageError, isNotNull);

      final c = controller();
      await c.init();
      await pumpEventQueue();
      expect(platform.stops, 0, reason: 'depo hatası çıkış değildir: arka plan izleme durmaz');
      expect(c.enabled, isTrue);
      expect((await AlarmWatchSettingsRepository(store).load()).enabled, isTrue, reason: 'ayar kalıcı kapanmaz');

      storage.memory.failReads = false;
      signIn();
      await pumpEventQueue();
      await h.state.logout();
      await pumpEventQueue();
      expect(platform.stops, 1, reason: 'gerçek çıkış: servis durur');
      expect(c.enabled, isFalse);
    });

    test('açılışta oturum denetlenirken (checking) ayar kapanmaz; ev listesi değişince kayıt güncellenir', () async {
      await AlarmWatchSettingsRepository(store).save(const AlarmWatchSettings(enabled: true, userId: 'u1'));
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      final c = controller();
      await c.init();
      expect(c.enabled, isTrue);

      signIn();
      await pumpEventQueue();
      expect(c.enabled, isTrue);
      expect(platform.starts, 1, reason: 'ayar açık ve servis çalışmıyordu');
      final saved = await AlarmWatchSettingsRepository(store).load();
      expect(saved.homes.single.id, kHomeA);
    });

    test('bildirime dokunuş (uygulama açıkken ve uygulamayı başlatan) alarm yönlendirmesine gider', () async {
      signIn();
      final payload = jsonEncode(<String, dynamic>{'v': 1, 't': 'alarm', 'h': kHomeA, 'u': 'AHBU-S3-X', 'z': 2, 'k': 'gas'});
      platform.launch = payload;
      final c = controller();
      final received = <SafetyPushNotice>[];
      c.openedNotices.listen(received.add);
      await c.init();
      await pumpEventQueue();
      expect(received.single.zone, 2);
      expect(received.single.kind, 'gas');
      platform.tapController.add(payload);
      platform.tapController.add('bozuk');
      await pumpEventQueue();
      expect(received, hasLength(2));
    });

    test('pil kısıtlaması muafiyeti istenir', () async {
      signIn();
      final c = controller();
      await c.init();
      await c.requestBatteryExemption();
      expect(platform.batteryRequests, 1);
      expect(c.batteryExempt, isTrue);
    });

    test('iOS / desteklenmeyen: hiçbir şey yapmaz', () async {
      platform = _FakePlatform(supported: false);
      signIn();
      final c = controller();
      await c.init();
      expect(c.supported, isFalse);
      expect(await c.enable(), isFalse);
      expect(platform.starts, 0);
    });
  });

  group('kart', () {
    Future<AlarmWatchController> pumpCard(WidgetTester tester, {Size size = const Size(400, 900), double scale = 1.0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = controller();
      await c.init();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ChangeNotifierProvider<AlarmWatchController>.value(
            value: c,
            child: const Scaffold(
              body: SingleChildScrollView(padding: EdgeInsets.all(16), child: AlarmWatchCard()),
            ),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    testWidgets('Android: anahtar açınca açık; izin ve pil satırları; kapatınca kapalı', (tester) async {
      signIn();
      platform.allowed = true;
      final c = await pumpCard(tester);
      expect(find.text('Kapalı'), findsOneWidget);
      expect(find.textContaining('kalıcı bir bildirim simgesi'), findsOneWidget);
      expect(find.textContaining('Xiaomi'), findsOneWidget);

      await tester.tap(find.byKey(const Key('switch_alarm_watch')));
      await tester.pump();
      await tester.pump();
      expect(c.enabled, isTrue);
      expect(find.text('Açık'), findsOneWidget);
      expect(find.byKey(const Key('btn_alarm_watch_battery')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_alarm_watch_battery')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('btn_alarm_watch_battery')), findsNothing);

      await tester.tap(find.byKey(const Key('switch_alarm_watch')));
      await tester.pump();
      await tester.pump();
      expect(c.enabled, isFalse);
    });

    testWidgets('uyelik-4: açık ama servis çalışmıyorsa "Durdu - yeniden başlatılıyor"', (tester) async {
      signIn();
      platform.allowed = true;
      platform.startOk = false;
      final c = await pumpCard(tester);
      await tester.tap(find.byKey(const Key('switch_alarm_watch')));
      await tester.pump();
      await tester.pump();
      expect(c.enabled, isTrue);
      expect(c.running, isFalse);
      expect(find.text('Durdu - yeniden başlatılıyor'), findsOneWidget);
    });

    testWidgets('iOS: "Bu özellik yalnız Android\'de", anahtar yok', (tester) async {
      platform = _FakePlatform(supported: false);
      signIn();
      await pumpCard(tester);
      expect(find.byKey(const Key('text_alarm_watch_unsupported')), findsOneWidget);
      expect(find.textContaining('yalnız Android'), findsOneWidget);
      expect(find.byKey(const Key('switch_alarm_watch')), findsNothing);
    });

    testWidgets('misafir: anahtar devre dışı ve neden yazılı', (tester) async {
      signIn(role: 'guest');
      await pumpCard(tester);
      final sw = tester.widget<Switch>(find.byKey(const Key('switch_alarm_watch')));
      expect(sw.onChanged, isNull);
      expect(find.textContaining('Yalnız ev sahibi'), findsOneWidget);
    });

    for (final size in <Size>[const Size(360, 640), const Size(320, 568)]) {
      testWidgets('yerleşim ${size.width.toInt()}x${size.height.toInt()} yazı 2.0x: kapalı, açık (izin + pil uyarısı) taşmaz',
          (tester) async {
        signIn();
        platform.grantOnRequest = true;
        final c = await pumpCard(tester, size: size, scale: 2.0);
        expect(tester.takeException(), isNull, reason: 'kapalı');
        await c.enable();
        platform.allowed = false; // izin sonradan kapatıldı
        await c.refreshPermissions();
        await tester.pump();
        expect(find.byKey(const Key('btn_alarm_watch_permission')), findsOneWidget);
        expect(find.byKey(const Key('btn_alarm_watch_battery')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'açık + uyarılar');
      });
    }
  });
}
