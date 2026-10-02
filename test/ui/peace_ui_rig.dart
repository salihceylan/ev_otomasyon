import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/peace_notice_controller.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/peace_notice_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// Bellek içi "izin istemi soruldu mu" deposu.
class MemoryPromptStore implements PromptStore {
  bool prompted = false;
  int writes = 0;

  @override
  Future<bool> wasPrompted() async => prompted;

  @override
  Future<void> markPrompted() async {
    writes++;
    prompted = true;
  }
}

/// Sahte koordinatör: çağrıları kaydeder; durum/bildirim olayları testten üretilir.
class FakePush implements PushCoordinator {
  final List<String> calls = <String>[];
  final StreamController<PushState> _states =
      StreamController<PushState>.broadcast();
  final StreamController<PeaceNotice> _notices =
      StreamController<PeaceNotice>.broadcast();

  PushState _state = PushState.idle;

  /// `start` çağrılınca bu duruma geçilir (örn. izin yok -> needsPermission).
  PushState startState = PushState.registered;
  bool denied = false;

  /// Sunucu kaydı KALICI reddetti (`registrationBlocked`); `retryRegistration` bunu sıfırlar.
  bool blocked = false;

  /// `retryRegistration` sonunda geçilecek durum (`null`: değişmez).
  PushState? stateAfterRetry;

  /// `requestPermissionAndRegister` sonunda yazılacak değerler.
  bool deniedAfterRequest = false;
  PushState stateAfterRequest = PushState.registered;

  /// Doluysa `requestPermissionAndRegister` bu kapı açılana kadar bekler (sistem penceresi açıkken).
  Completer<void>? requestGate;

  void emitState(PushState next) {
    _state = next;
    _states.add(next);
  }

  void emitNotice(PeaceNotice notice) => _notices.add(notice);

  @override
  PushState get state => _state;

  @override
  Stream<PushState> get states => _states.stream;

  @override
  Stream<PeaceNotice> get notices => _notices.stream;

  @override
  bool get permissionDenied => denied;

  @override
  bool get registrationBlocked => blocked;

  @override
  Future<void> retryRegistration() async {
    calls.add('retry');
    blocked = false;
    final next = stateAfterRetry;
    if (next != null && _state != next) emitState(next);
  }

  @override
  Future<void> start({bool promptForPermission = false}) async {
    calls.add('start:$promptForPermission');
    if (_state != startState) emitState(startState);
  }

  @override
  Future<void> requestPermissionAndRegister() async {
    calls.add('request');
    final gate = requestGate;
    if (gate != null) await gate.future;
    denied = deniedAfterRequest;
    if (_state != stateAfterRequest) emitState(stateAfterRequest);
  }

  @override
  Future<void> refresh() async => calls.add('refresh');

  @override
  Future<void> stop({
    bool unregister = true,
    bool? invalidateLocalToken,
  }) async {
    calls.add('stop:$unregister');
    if (_state != PushState.unsupported) emitState(PushState.idle);
  }

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `closeAllForNotice` (afiş "Hepsini kapat") çağrılarını kaydeden/yönlendiren sahte bulut API'si.
class UiCloudApi extends FakeCloudApi {
  UiCloudApi({super.clock});

  final List<({String homeId, int? noticeId})> closeCalls =
      <({String homeId, int? noticeId})>[];
  Map<String, dynamic> closeResult = <String, dynamic>{
    'closed_lights': 2,
    'closed_shutters': 1,
    'closed_count': 2,
    'skipped_count': 0,
    'nothing_to_do': false,
    'resolved': true,
    'notice_id': 41,
    'message': '',
  };
  Object? closeError;
  Completer<void>? closeGate;

  @override
  Future<Map<String, dynamic>> closeAllForNotice(
    String homeId, {
    int? noticeId,
    bool? includeShutters,
  }) async {
    calls.add('closeAll:$homeId');
    closeCalls.add((homeId: homeId, noticeId: noticeId));
    await closeGate?.future;
    final error = closeError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(closeResult);
  }
}

/// Gerçek [AutomationState] + sahte bulut API'si + gerçek [PeaceNoticeController] (sahte push ile).
///
/// Hepsi SENKRON kurulur (testWidgets sahte zamanında `pumpEventQueue` beklenmez): oturum, ev ve
/// aktif ev `set...ForTesting` ile hazırlanır; denetleyici kurulunca `push.start` mikro görevde koşar
/// (testte `await tester.pump()`).
class PeaceUiRig {
  PeaceUiRig._(
    this.clock,
    this.cloud,
    this.h,
    this.store,
    this.push,
    this.controller,
  );

  final FakeClock clock;
  final UiCloudApi cloud;
  final StateHarness h;
  final MemoryPromptStore store;
  final FakePush push;
  final PeaceNoticeController controller;

  AutomationState get state => h.state;

  static PeaceUiRig create({
    String role = 'owner',
    PushState startState = PushState.registered,
    bool softPromptAlreadyShown = false,
  }) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = UiCloudApi(clock: clock);
    final h = StateHarness(clock: clock, cloud: cloud);
    final home = testHome(role: role);
    cloud.homes = <HomeModel>[home];
    cloud.endpoints[home.id] = testEndpoints(homeId: home.id);
    h.state
      ..setCurrentUserForTesting(
        UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: 'user'),
      )
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setHomesForTesting(<HomeModel>[home], activeHome: home);
    final store = MemoryPromptStore()..prompted = softPromptAlreadyShown;
    final push = FakePush()..startState = startState;
    final controller = PeaceNoticeController(
      state: h.state,
      push: push,
      promptStore: store,
      now: clock.now,
    );
    return PeaceUiRig._(clock, cloud, h, store, push, controller);
  }

  PeaceNotice notice({
    String home = kHomeA,
    int? id = 41,
    PeaceNoticeSource source = PeaceNoticeSource.foreground,
    int lights = 2,
    int shutters = 1,
    String? title = 'Ev A',
    String? body = 'Salonda 2 lamba, 1 panjur açık.',
  }) => PeaceNotice(
    homeId: home,
    noticeId: id,
    openLights: lights,
    openShutters: shutters,
    source: source,
    receivedAt: clock.now(),
    title: title,
    body: body,
  );

  /// Karma yetki: kullanıcı hâlâ owner evinin sahibi (uygun) ama AKTİF ev misafirlik (toplu komut yok).
  void activateGuestHome() {
    final guest = testHome(id: kHomeB, name: 'Misafir ev', role: 'guest');
    h.state.setHomesForTesting(<HomeModel>[
      testHome(),
      guest,
    ], activeHome: guest);
  }

  void dispose() {
    controller.dispose();
    h.dispose();
  }
}

/// Gerçek uygulama kabuğunun yerleşimi: `MaterialApp.builder` içinde (Navigator'ın üstünde)
/// `ChangeNotifierProvider<PeaceNoticeController>` + [PeaceNoticeHost] (köprü: afişi ScaffoldMessenger'a
/// gösterir). [AppShell] derlenmediği için kendi koşum düzeneğimiz. [decorateTheme]: temayı değiştirir
/// (örn. gerçek yazı tipi).
Widget peaceApp({
  required PeaceUiRig rig,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool disableAnimations = false,
  Widget? page,
  ThemeData Function(ThemeData base)? decorateTheme,
}) {
  ThemeData theme(ThemeData base) =>
      decorateTheme == null ? base : decorateTheme(base);
  return ChangeNotifierProvider<AutomationState>.value(
    value: rig.state,
    child: MaterialApp(
      theme: theme(AppTheme.lightTheme),
      darkTheme: theme(AppTheme.darkTheme),
      themeMode: themeMode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: ChangeNotifierProvider<PeaceNoticeController>.value(
            value: rig.controller,
            child: PeaceNoticeHost(child: child ?? const SizedBox.shrink()),
          ),
        );
      },
      home: page ?? const DemoPage(),
    ),
  );
}

/// Sayfa içeriğini taklit eden basit sayfa: AppBar (geri/sol eylem) + gövde düğmesi. Banner sayfayı
/// AŞAĞI itmeli: AppBar eylemleri ve gövde dokunuşları çalışmaya devam eder.
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  static int builds = 0;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  int taps = 0;
  int leadingTaps = 0;

  @override
  Widget build(BuildContext context) {
    DemoPage.builds++;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('page_leading'),
          tooltip: 'Geri',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => leadingTaps++),
        ),
        title: Text('Demo sayfa $leadingTaps'),
      ),
      body: Center(
        child: ElevatedButton(
          key: const Key('page_button'),
          onPressed: () => setState(() => taps++),
          child: Text('Sayfa düğmesi $taps'),
        ),
      ),
    );
  }
}

/// Telefon boyutlu ekran (mantıksal piksel, DPR 1) ve test sonunda sıfırlama.
void usePhone(WidgetTester tester, {Size size = const Size(360, 740)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}
