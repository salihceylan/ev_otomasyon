import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/peace_notice_controller.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/services/push/push_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/fakes.dart' as push_fakes;
import '../support/support.dart';

/// `PeaceNoticeController`: gerçek [AutomationState] + sahte bulut API'si; push tarafı için sahte
/// koordinatör ([_FakePush]) ve (entegrasyon testlerinde) gerçek koordinatör + sahte ağ geçidi.

// -----------------------------------------------------------------------------
// Sahteler
// -----------------------------------------------------------------------------

/// Bellek içi "izin istemi soruldu mu" deposu.
class _MemoryPromptStore implements PromptStore {
  bool prompted = false;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;

  @override
  Future<bool> wasPrompted() async {
    if (failRead) throw StateError('okunamadı');
    return prompted;
  }

  @override
  Future<void> markPrompted() async {
    writes++;
    if (failWrite) throw StateError('yazılamadı');
    prompted = true;
  }
}

/// Sahte koordinatör: çağrıları kaydeder; durum/bildirim olayları testten üretilir.
class _FakePush implements PushCoordinator {
  final List<String> calls = <String>[];
  final StreamController<PushState> _states = StreamController<PushState>.broadcast();
  final StreamController<PeaceNotice> _notices = StreamController<PeaceNotice>.broadcast();

  PushState _state = PushState.idle;

  /// `start` çağrılınca bu duruma geçilir (örn. izin yok -> needsPermission).
  PushState startState = PushState.registered;
  bool denied = false;

  /// `requestPermissionAndRegister` sonunda yazılacak değerler.
  bool deniedAfterRequest = false;
  PushState stateAfterRequest = PushState.registered;

  Completer<void>? stopGate;
  bool throwOnEverything = false;

  /// Kalıcı red bilgisi ([PushCoordinator.registrationBlocked]); `retryRegistration` onu kaldırır.
  bool blocked = false;

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
  Future<void> start({bool promptForPermission = false}) async {
    calls.add('start:$promptForPermission');
    if (throwOnEverything) throw StateError('start');
    if (_state != startState) emitState(startState);
  }

  @override
  Future<void> requestPermissionAndRegister() async {
    calls.add('request');
    if (throwOnEverything) throw StateError('request');
    denied = deniedAfterRequest;
    if (_state != stateAfterRequest) emitState(stateAfterRequest);
  }

  @override
  Future<void> refresh() async {
    calls.add('refresh');
    if (throwOnEverything) throw StateError('refresh');
  }

  @override
  Future<void> retryRegistration() async {
    calls.add('retry');
    if (throwOnEverything) throw StateError('retry');
    blocked = false;
  }

  /// Çağrı günlüğü: `stop:<unregister>:<invalidateLocalToken>` (varsayılan: unregister değeri).
  @override
  Future<void> stop({bool unregister = true, bool? invalidateLocalToken}) async {
    calls.add('stop:$unregister:${invalidateLocalToken ?? unregister}');
    final gate = stopGate;
    if (gate != null) await gate.future;
    if (throwOnEverything) throw StateError('stop');
    if (_state != PushState.unsupported) emitState(PushState.idle);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `closeAllForNotice` (afiş) ve `closeAllOpenLights` (eski pano düğmesi) çağrılarını kaydeden/yönlendiren
/// sahte bulut API'si. Eski yöntem panjur indirmez: kayıtta `includeShutters: false` olarak görünür.
class _CloudApi extends FakeCloudApi {
  _CloudApi({super.clock});

  final List<({String homeId, int? noticeId, bool includeShutters})> closeCalls =
      <({String homeId, int? noticeId, bool includeShutters})>[];

  /// Hangi yöntemle çağrıldığı: `legacy` (closeAllOpenLights) ya da `notice` (closeAllForNotice).
  final List<String> closeVia = <String>[];
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
  Future<Map<String, dynamic>> closeAllOpenLights(String homeId) {
    closeVia.add('legacy');
    return _close(homeId, null, false);
  }

  @override
  Future<Map<String, dynamic>> closeAllForNotice(String homeId, {int? noticeId, bool includeShutters = true}) {
    closeVia.add('notice');
    return _close(homeId, noticeId, includeShutters);
  }

  Future<Map<String, dynamic>> _close(String homeId, int? noticeId, bool includeShutters) async {
    calls.add('closeAll:$homeId');
    closeCalls.add((homeId: homeId, noticeId: noticeId, includeShutters: includeShutters));
    await closeGate?.future;
    final error = closeError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(closeResult);
  }
}

/// Silme anındaki oturum belirtecini de kaydeden sahte push API'si.
class _SpyTokenApi extends push_fakes.FakeApi {
  _SpyTokenApi(this._cloud);

  final FakeCloudApi _cloud;
  final List<String?> authTokenAtUnregister = <String?>[];

  @override
  Future<void> unregisterPushToken(String token) {
    authTokenAtUnregister.add(_cloud.authToken);
    return super.unregisterPushToken(token);
  }
}

// -----------------------------------------------------------------------------
// Düzen
// -----------------------------------------------------------------------------

class _Rig {
  _Rig._(this.clock, this.cloud, this.h, this.store);

  final FakeClock clock;
  final _CloudApi cloud;
  final StateHarness h;
  final _MemoryPromptStore store;

  late PeaceNoticeController c;
  late _FakePush push;
  int notifications = 0;

  AutomationState get state => h.state;

  /// [viaLogin]: gerçek `login()` yolu (oturum belirteci gerçekten kurulur); aksi halde test kancalarıyla.
  /// [attach]: `false` ise denetleyici kurulmaz (testin kendisi kurar).
  static Future<_Rig> create({
    String role = 'owner',
    String globalRole = 'user',
    List<HomeModel>? homes,
    bool authenticated = true,
    bool viaLogin = false,
    bool attach = true,
    PushState startState = PushState.registered,
    _MemoryPromptStore? store,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = _CloudApi(clock: clock);
    final h = StateHarness(clock: clock, cloud: cloud);
    cloud.homes = homes ?? <HomeModel>[testHome(role: role)];
    for (final home in cloud.homes) {
      cloud.endpoints[home.id] = testEndpoints(homeId: home.id);
      cloud.devicesByHome[home.id] = <DeviceInfo>[
        const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
      ];
    }
    final rig = _Rig._(clock, cloud, h, store ?? _MemoryPromptStore());
    if (viaLogin) {
      await h.state.login('a@b.c', 'parola-1234');
    } else {
      h.state.setCurrentUserForTesting(UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: globalRole));
      if (authenticated) h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      if (globalRole == 'service_session') {
        final sessionHome = cloud.homes.first;
        h.state.setHomesForTesting(<HomeModel>[sessionHome]);
        await h.state.selectHome(sessionHome);
      } else {
        await h.state.fetchHomes();
      }
    }
    await pumpEventQueue();
    if (attach) {
      rig.push = _FakePush()..startState = startState;
      rig.attach(rig.push);
      await pumpEventQueue();
    }
    return rig;
  }

  void attach(PushCoordinator coordinator) {
    c = PeaceNoticeController(state: h.state, push: coordinator, promptStore: store, now: clock.now);
    c.addListener(() => notifications++);
  }

  PeaceNotice notice({
    String home = kHomeA,
    int? id = 41,
    PeaceNoticeSource source = PeaceNoticeSource.foreground,
    int lights = 2,
    int shutters = 1,
  }) => PeaceNotice(
    homeId: home,
    noticeId: id,
    openLights: lights,
    openShutters: shutters,
    source: source,
    receivedAt: clock.now(),
    title: 'Ev',
    body: 'Salonda $lights lamba, $shutters panjur açık.',
  );

  /// Ayar yanıtı (sunucu v2 şekli): canlı veri, çözülmemiş gece kaydı. Varsayılan: tüm cihazlar (1/1)
  /// çevrimiçi; `devices_*` alanları `null` verilirse yanıttan çıkarılır.
  Map<String, dynamic> settings({
    int lights = 2,
    int shutters = 0,
    bool stale = false,
    int noticeId = 41,
    String status = 'sent',
    String? resolvedAt,
    String? home,
    int? devicesTotal = 1,
    int? devicesOnline = 1,
  }) => <String, dynamic>{
    'home_id': home ?? kHomeA,
    'enabled': true,
    'time': '23:30',
    'stale': stale,
    'open_lights_count': lights,
    'open_shutters_count': shutters,
    'devices_total': ?devicesTotal,
    'devices_online': ?devicesOnline,
    'summary_text': 'Salonda $lights lamba açık.',
    'last_notice': <String, dynamic>{
      'id': noticeId,
      'status': status,
      'created_at': clock.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
      'resolved_at': resolvedAt,
    },
  };

  Future<void> pump() => pumpEventQueue();

  void dispose() {
    c.dispose();
    h.dispose();
  }
}

HomeModel _home(String id, String role, {String name = 'Ev'}) => testHome(id: id, role: role, name: name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  group('uygunluk', () {
    test('owner: push izin penceresi AÇILMADAN başlatılır', () async {
      final r = await _Rig.create();
      expect(r.c.isEligible, isTrue);
      expect(r.push.calls, <String>['start:false']);
      r.dispose();
    });

    test('resident uygun; yalnızca misafir olan kullanıcı uygun değil (push hiç başlamaz)', () async {
      final resident = await _Rig.create(role: 'resident');
      expect(resident.c.isEligible, isTrue);
      expect(resident.push.calls, <String>['start:false']);
      resident.dispose();

      final guest = await _Rig.create(role: 'guest');
      expect(guest.c.isEligible, isFalse);
      expect(guest.push.calls, isEmpty);
      guest.dispose();
    });

    test('karışık evler: biri owner ise uygun', () async {
      final r = await _Rig.create(homes: <HomeModel>[_home(kHomeA, 'guest'), _home(kHomeB, 'owner')]);
      expect(r.c.isEligible, isTrue);
      expect(r.push.calls, <String>['start:false']);
      r.dispose();
    });

    test('servis oturumu uygun değil', () async {
      final r = await _Rig.create(globalRole: 'service_session', role: 'service_session');
      expect(r.state.isServiceSession, isTrue);
      expect(r.c.isEligible, isFalse);
      expect(r.push.calls, isEmpty);
      r.dispose();
    });

    test('oturum açılmamış kullanıcı uygun değil; giriş yapılınca başlar', () async {
      final r = await _Rig.create(authenticated: false, viaLogin: false);
      expect(r.c.isEligible, isFalse);
      expect(r.push.calls, isEmpty);
      r.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await r.pump();
      expect(r.c.isEligible, isTrue);
      expect(r.push.calls, <String>['start:false']);
      r.dispose();
    });

    test('yalnızca DEĞİŞİMDE harekete geçer: çok sayıda bildirim tek başlatma', () async {
      final r = await _Rig.create();
      for (var i = 0; i < 5; i++) {
        r.state.setThemeModeForTesting(i.isEven ? ThemeMode.light : ThemeMode.dark);
      }
      await r.pump();
      expect(r.push.calls, <String>['start:false']);
      r.dispose();
    });

    test('doğrudan moda geçince durdurulur (silmeden), buluta dönünce yeniden başlar', () async {
      final r = await _Rig.create();
      r.state.setModeForTesting(AppMode.direct);
      await r.pump();
      expect(r.c.isEligible, isFalse);
      expect(r.push.calls, <String>['start:false', 'stop:false:false']);
      r.state.setModeForTesting(AppMode.cloud);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'stop:false:false', 'start:false']);
      r.dispose();
    });

    test('rol kaybı (owner -> misafir): durdurulur, afiş temizlenir', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending, isNotNull);

      r.state.setHomesForTesting(<HomeModel>[_home(kHomeA, 'guest')]);
      await r.pump();
      expect(r.c.isEligible, isFalse);
      expect(r.c.pending, isNull);
      expect(r.push.calls.last, 'stop:false:false', reason: 'rol kaybı geçici olabilir: yerel belirteç silinmez');
      r.dispose();
    });

    test('hiçbir kosulda istisna sızmaz: koordinatör her çağrıda fırlatsa bile', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final r = await _Rig.create(attach: false);
      final push = _FakePush()..throwOnEverything = true;
      runZonedGuarded(() {
        r.attach(push);
      }, (e, s) => fail('yakalanmamış istisna: $e'));
      await r.pump();
      r.c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await r.c.requestPermission();
      await r.c.dismissSoftPrompt();
      await r.h.state.logout(); // kanca fırlatır; çıkış engellenmez
      expect(r.state.isAuthenticated, isFalse);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('çıkış ve oturum bitişi', () {
    test('logout: kanca push.stop() (silmeli) çağırır; sonra uygunluk kaybı silmesiz durdurur', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending, isNotNull);

      await r.state.logout();
      await r.pump();

      expect(r.push.calls, <String>['start:false', 'stop:true:true', 'stop:false:false']);
      expect(r.c.pending, isNull);
      expect(r.c.isEligible, isFalse);
      r.dispose();
    });

    test('kanca takılan push.stop() ile çıkışın yerel temizliğini en çok ~1 sn geciktirir', () async {
      final r = await _Rig.create();
      r.push.stopGate = Completer<void>(); // asla bitmez
      final watch = Stopwatch()..start();
      await r.state.logout();
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(2500));
      expect(r.state.isAuthenticated, isFalse);
      r.dispose();
    });

    test('oturum bitti olayı: silmeden durdurur, afiş ve kapatılanlar sıfırlanır', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      r.c.dismiss();
      r.push.emitNotice(r.notice(id: 42));
      await r.pump();
      expect(r.c.pending, isNotNull);

      r.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await r.pump();

      expect(r.state.isAuthenticated, isFalse);
      expect(r.c.pending, isNull);
      expect(r.push.calls, <String>['start:false', 'stop:false:true'], reason: 'silmesiz ama yerel belirteç geçersiz');
      expect(r.push.calls, isNot(contains('stop:true:true')));

      // Yeni oturumda aynı (daha önce kapatılmış) bildirim yeniden gösterilebilir.
      await r.state.login('a@b.c', 'parola-1234');
      await r.pump();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('yumuşak istem ve izin', () {
    test('izin yok: yumuşak istem görünür; sistem izin penceresi KENDİLİĞİNDEN açılmaz', () async {
      final r = await _Rig.create(startState: PushState.needsPermission);
      expect(r.c.pushState, PushState.needsPermission);
      expect(r.c.softPromptVisible, isTrue);
      expect(r.push.calls, <String>['start:false']);
      expect(r.store.writes, 0);
      r.dispose();
    });

    test('requestPermission: bayrak kalıcılaşır, istem kapanır, kayıt istenir', () async {
      final r = await _Rig.create(startState: PushState.needsPermission);
      await r.c.requestPermission();
      expect(r.store.prompted, isTrue);
      expect(r.c.softPromptVisible, isFalse);
      expect(r.push.calls, contains('request'));
      expect(r.c.pushState, PushState.registered);
      r.dispose();
    });

    test('izin reddedilirse pushPermissionDenied güncellenir ve dinleyiciler uyarılır', () async {
      final r = await _Rig.create(startState: PushState.needsPermission);
      r.push
        ..deniedAfterRequest = true
        ..stateAfterRequest = PushState.needsPermission; // durum değişmez: olay üretilmez
      final before = r.notifications;
      await r.c.requestPermission();
      expect(r.c.pushPermissionDenied, isTrue);
      expect(r.notifications, greaterThan(before));
      expect(r.c.softPromptVisible, isFalse);
      r.dispose();
    });

    test('dismissSoftPrompt: bir daha sorulmaz (yeni oturum/denetleyici dahil)', () async {
      final store = _MemoryPromptStore();
      final r = await _Rig.create(startState: PushState.needsPermission, store: store);
      expect(r.c.softPromptVisible, isTrue);
      await r.c.dismissSoftPrompt();
      expect(r.c.softPromptVisible, isFalse);
      expect(store.prompted, isTrue);
      expect(r.push.calls, isNot(contains('request')));

      // Aynı depoyla yeni denetleyici: sorulmuş sayılır.
      final r2 = await _Rig.create(startState: PushState.needsPermission, store: store);
      expect(r2.c.pushState, PushState.needsPermission);
      expect(r2.c.softPromptVisible, isFalse);
      r.dispose();
      r2.dispose();
    });

    test('daha önce sorulduysa yeniden gösterilmez (needsPermission yine de görünür)', () async {
      final store = _MemoryPromptStore()..prompted = true;
      final r = await _Rig.create(startState: PushState.needsPermission, store: store);
      expect(r.c.pushState, PushState.needsPermission);
      expect(r.c.softPromptVisible, isFalse);
      r.dispose();
    });

    test('izin açıkça reddedilmişse yumuşak istem gösterilmez', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final r = await _Rig.create(attach: false);
      r.push = _FakePush()
        ..startState = PushState.needsPermission
        ..denied = true;
      r.attach(r.push);
      await r.pump();
      expect(r.c.pushPermissionDenied, isTrue);
      expect(r.c.softPromptVisible, isFalse);
      r.dispose();
    });

    test('push desteklenmiyor / kayıtlı: yumuşak istem yok; durum değişince istem kapanır', () async {
      final r = await _Rig.create(startState: PushState.needsPermission);
      expect(r.c.softPromptVisible, isTrue);
      r.push.emitState(PushState.registered); // kullanıcı izni ayarlardan açtı
      await r.pump();
      expect(r.c.softPromptVisible, isFalse);

      final unsupported = await _Rig.create(startState: PushState.unsupported);
      expect(unsupported.c.softPromptVisible, isFalse);
      r.dispose();
      unsupported.dispose();
    });

    test('depo okunamazsa/yazılamazsa istisna sızmaz; istem gösterilmez', () async {
      final store = _MemoryPromptStore()..failRead = true;
      final r = await _Rig.create(startState: PushState.needsPermission, store: store);
      expect(r.c.softPromptVisible, isFalse);
      store.failWrite = true;
      await r.c.dismissSoftPrompt();
      await r.c.requestPermission();
      r.dispose();
    });

    test('uygun değilken needsPermission gelirse istem gösterilmez', () async {
      final r = await _Rig.create(role: 'guest', startState: PushState.needsPermission);
      r.push.emitState(PushState.needsPermission);
      await r.pump();
      expect(r.c.softPromptVisible, isFalse);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('gelen bildirim', () {
    test('ön plan, etkin ev: afiş + gerçek durum tazelenir (ayar yanıtı ve silent refresh)', () async {
      final r = await _Rig.create();
      final fetchBefore = r.cloud.count('getPeaceNotification');
      final endpointsBefore = r.cloud.count('fetchEndpoints');

      r.push.emitNotice(r.notice());
      await r.pump();

      expect(r.c.pending?.noticeId, 41);
      expect(r.c.pending?.source, PeaceNoticeSource.foreground);
      expect(r.cloud.count('getPeaceNotification'), greaterThan(fetchBefore));
      expect(r.cloud.count('fetchEndpoints'), greaterThan(endpointsBefore));
      r.dispose();
    });

    test('dokunarak gelen başka ev bildirimi: o eve geçilir', () async {
      final r = await _Rig.create(
        homes: <HomeModel>[
          _home(kHomeA, 'owner', name: 'A'),
          _home(kHomeB, 'owner', name: 'B'),
        ],
      );
      expect(r.state.activeHome?.id, isNot(kHomeB), reason: 'başlangıçta B seçili değil');
      r.push.emitNotice(r.notice(home: kHomeB, source: PeaceNoticeSource.opened));
      await r.pump();
      expect(r.state.activeHome?.id, kHomeB);
      expect(r.c.pending?.homeId, kHomeB);
      r.dispose();
    });

    test('kapalıyken açılış (initial) bildirimi de eve geçer', () async {
      final r = await _Rig.create(homes: <HomeModel>[_home(kHomeA, 'owner'), _home(kHomeB, 'owner')]);
      r.push.emitNotice(r.notice(home: kHomeB, source: PeaceNoticeSource.initial));
      await r.pump();
      expect(r.state.activeHome?.id, kHomeB);
      r.dispose();
    });

    test('ön planda gelen başka ev bildirimi: ev ZORLA değiştirilmez, yalnızca afiş', () async {
      final r = await _Rig.create(homes: <HomeModel>[_home(kHomeA, 'owner'), _home(kHomeB, 'owner')]);
      final active = r.state.activeHome?.id;
      r.push.emitNotice(r.notice(home: kHomeB));
      await r.pump();
      expect(r.state.activeHome?.id, active);
      expect(r.c.pending?.homeId, kHomeB);
      r.dispose();
    });

    test('kimliği doğrulanmamış oturumda gelen bildirim yok sayılır', () async {
      final r = await _Rig.create();
      r.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await r.pump();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('kapatılan bildirim (dedupeKey) bir daha gösterilmez; yenisi gösterilir', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      r.c.dismiss();
      expect(r.c.pending, isNull);

      r.push.emitNotice(r.notice()); // aynı kimlik
      await r.pump();
      expect(r.c.pending, isNull);

      r.push.emitNotice(r.notice(id: 42));
      await r.pump();
      expect(r.c.pending?.noticeId, 42);
      r.dispose();
    });

    test('kimliksiz bildirimler içerik anahtarıyla tekilleştirilir', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: null));
      await r.pump();
      r.c.dismiss();
      r.push.emitNotice(r.notice(id: null));
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('yedek afiş (push gelmediyse)', () {
    test('çözülmemiş gece kaydı + canlı açık sayı: afiş üretilir (kaynak settings, ev adı)', () async {
      final r = await _Rig.create();
      r.cloud.peaceNotification = r.settings();
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNotNull);
      expect(r.c.pending?.source, PeaceNoticeSource.settings);
      expect(r.c.pending?.noticeId, 41);
      expect(r.c.pending?.title, 'Ev A', reason: 'ev adı etkin evden');
      expect(r.c.pending?.openLights, 2);
      r.dispose();
    });

    test('lambalar kapandıktan sonra yalnızca YEDEK afiş kalkar', () async {
      final r = await _Rig.create();
      r.cloud.peaceNotification = r.settings();
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNotNull);

      r.cloud.peaceNotification = r.settings(lights: 0);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('push kaynaklı afişe DOKUNULMAZ (ayar yanıtı afiş üretmese de)', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      r.cloud.peaceNotification = r.settings(lights: 0, stale: true);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.source, PeaceNoticeSource.foreground);
      r.dispose();
    });

    test('başka bir afiş zaten gösteriliyorsa yedek ona dokunmaz', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41, lights: 5));
      await r.pump();
      r.cloud.peaceNotification = r.settings(noticeId: 99);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      expect(r.c.pending?.source, PeaceNoticeSource.foreground);
      r.dispose();
    });

    test('kapatılan yedek afiş aynı oturumda geri gelmez', () async {
      final r = await _Rig.create();
      r.cloud.peaceNotification = r.settings();
      await r.state.fetchPeaceNotification();
      await r.pump();
      r.c.dismiss();
      expect(r.c.pending, isNull);

      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('çözülmüş / bayat (stale) / eski kayıt afiş üretmez', () async {
      final r = await _Rig.create();
      for (final data in <Map<String, dynamic>>[
        r.settings(status: 'resolved', resolvedAt: '2026-10-01T11:30:00Z'),
        r.settings(stale: true),
        r.settings(lights: 0),
      ]) {
        r.cloud.peaceNotification = data;
        await r.state.fetchPeaceNotification();
        await r.pump();
        expect(r.c.pending, isNull, reason: '$data');
      }
      r.dispose();
    });

    test('push ile gelen aynı bildirim, yedekle çift afiş üretmez (aynı dedupeKey)', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      r.c.dismiss();
      r.cloud.peaceNotification = r.settings(noticeId: 41);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('mevcut veriyle kurulan denetleyici yedek afişi hemen üretir', () async {
      final r = await _Rig.create(attach: false);
      r.cloud.peaceNotification = r.settings();
      await r.state.fetchPeaceNotification();
      await r.pump();
      r.push = _FakePush();
      r.attach(r.push);
      await r.pump();
      expect(r.c.pending?.source, PeaceNoticeSource.settings);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('Hepsini kapat', () {
    test('bildirim kimliği sunucuya iletilir; çözüldü -> afiş kalkar, sonuç mesajı, durum tazelenir', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{'closed_count': 2, 'resolved': true, 'notice_id': 41, 'message': ''};
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      final fetchBefore = r.cloud.count('getPeaceNotification');

      await r.c.closeAll();
      await r.pump();

      expect(r.cloud.closeCalls.single.homeId, kHomeA);
      expect(r.cloud.closeCalls.single.noticeId, 41);
      expect(r.cloud.closeCalls.single.includeShutters, isTrue, reason: 'afişteki Hepsini kapat panjurları da indirir');
      expect(r.c.pending, isNull);
      expect(r.c.closing, isFalse);
      expect(r.c.closeMessage, 'Kapatma komutu gönderildi.');
      expect(r.cloud.count('getPeaceNotification'), greaterThan(fetchBefore));

      // Kapatılan bildirim bu oturumda geri gelmez.
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('kapatma sürerken closing true; çift dokunuş tek istek', () async {
      final r = await _Rig.create();
      r.cloud.closeGate = Completer<void>();
      r.push.emitNotice(r.notice());
      await r.pump();

      final first = r.c.closeAll();
      await r.pump();
      expect(r.c.closing, isTrue);
      final second = r.c.closeAll();
      r.cloud.closeGate!.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(r.cloud.closeCalls, hasLength(1));
      expect(r.c.closing, isFalse);
      r.dispose();
    });

    test('nothing_to_do: "kapatıldı" DENMEZ, sunucu mesajı gösterilir, afiş kalkar', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{
        'nothing_to_do': true,
        'resolved': false,
        'closed_count': 0,
        'message': 'Sunucu kayıtlarına göre açık lamba ya da panjur yok; cihaza komut gönderilmedi.',
      };
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.c.closeMessage, contains('cihaza komut gönderilmedi'));
      expect(r.c.closeMessage, isNot(contains('kapatıldı')));
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('nothing_to_do mesajsız gelirse güvenli varsayılan metin', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{'nothing_to_do': true};
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.c.closeMessage, contains('komut gönderilmedi'));
      r.dispose();
    });

    test('skipped_count > 0: afiş AÇIK kalır, KISA istemci iletisi gösterilir (sunucu iletisi değil)', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{
        'closed_count': 1,
        'skipped_count': 2,
        'resolved': false,
        'message': 'Bazı kanallar elle kontrol edilmeli.',
      };
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.c.pending, isNotNull);
      expect(r.c.closeMessage, 'Komut gönderildi; 2 öğe uzaktan kapatılamadı, lütfen elle kontrol edin.');
      expect(r.c.closing, isFalse);
      r.dispose();
    });

    group('skipped_count > 0: kısa, talimatı başa alan ileti (FXU karar noktası)', () {
      // Sunucunun gerçek (166 karakterlik) iletisi: kritik talimat SONDA olduğu için büyük yazıda görsel
      // olarak kısalıyordu; istemci bunu kullanmaz.
      const realServerMessage =
          'Huzur modu: 2 lamba, 1 panjur için kapatma komutu cihaza iletildi. 1 lamba birden fazla panonun '
          'ortak bağlantısı nedeniyle uzaktan kapatılamadı; lütfen elle kontrol edin.';

      Future<_Rig> closeWith(Map<String, dynamic> result) async {
        final r = await _Rig.create();
        r.cloud.closeResult = result;
        r.push.emitNotice(r.notice());
        await r.pump();
        await r.c.closeAll();
        return r;
      }

      test('sunucu iletisi (gerçek, 166 karakter) KULLANILMAZ; ileti kısa ve talimat başta', () async {
        final r = await closeWith(<String, dynamic>{
          'closed_count': 2,
          'closed_shutters': 1,
          'skipped_count': 1,
          'resolved': false,
          'message': realServerMessage,
        });
        final message = r.c.closeMessage!;
        expect(message, 'Komut gönderildi; 1 öğe uzaktan kapatılamadı, lütfen elle kontrol edin.');
        expect(message, isNot(contains('Huzur modu')));
        expect(message.length, lessThanOrEqualTo(80));
        expect(realServerMessage.length, greaterThan(150), reason: 'sınama gerçekten uzun bir iletiyle yapılır');
        expect(r.c.pending, isNotNull, reason: 'afiş açık kalır');
        r.dispose();
      });

      test('hiçbir şey kapatılmadıysa "Komut gönderildi" DENMEZ (closed_count 0)', () async {
        final r = await closeWith(<String, dynamic>{
          'closed_count': 0,
          'skipped_count': 3,
          'resolved': false,
          'message': realServerMessage,
        });
        expect(r.c.closeMessage, '3 öğe uzaktan kapatılamadı; lütfen elle kontrol edin.');
        expect(r.c.pending, isNotNull);
        r.dispose();
      });

      test('kapatılan sayısı bilinmiyorsa (v1 alanı yok) "Komut gönderildi" DENMEZ', () async {
        final r = await closeWith(<String, dynamic>{'skipped_count': 1, 'resolved': false});
        expect(r.c.closeMessage, '1 öğe uzaktan kapatılamadı; lütfen elle kontrol edin.');
        r.dispose();
      });

      test('yalnızca panjur kapatıldıysa da komut gönderilmiştir', () async {
        final r = await closeWith(<String, dynamic>{
          'closed_count': 0,
          'closed_shutters': 2,
          'skipped_count': 1,
          'resolved': false,
        });
        expect(r.c.closeMessage, 'Komut gönderildi; 1 öğe uzaktan kapatılamadı, lütfen elle kontrol edin.');
        r.dispose();
      });

      test('komut cihaza iletilmediyse (delivered false) "Komut gönderildi" DENMEZ', () async {
        final r = await closeWith(<String, dynamic>{
          'closed_count': 2,
          'delivered': false,
          'skipped_count': 1,
          'resolved': false,
        });
        expect(r.c.closeMessage, '1 öğe uzaktan kapatılamadı; lütfen elle kontrol edin.');
        r.dispose();
      });

      test('sunucu iletisi boş olsa da aynı ileti üretilir', () async {
        final r = await closeWith(<String, dynamic>{
          'closed_count': 1,
          'skipped_count': 4,
          'resolved': false,
          'message': '',
        });
        expect(r.c.closeMessage, 'Komut gönderildi; 4 öğe uzaktan kapatılamadı, lütfen elle kontrol edin.');
        r.dispose();
      });

      test('skipped_count 0 iken sunucu iletisi AYNEN gösterilir (kısa ileti yalnızca kısmi sonuçta)', () async {
        final r = await closeWith(<String, dynamic>{
          'closed_count': 2,
          'skipped_count': 0,
          'resolved': true,
          'message': 'Huzur modu: 2 lamba için kapatma komutu cihaza iletildi.',
        });
        expect(r.c.closeMessage, 'Huzur modu: 2 lamba için kapatma komutu cihaza iletildi.');
        expect(r.c.pending, isNull);
        r.dispose();
      });
    });

    test('ApiException: kullanıcıya gösterilebilir mesaj; afiş açık kalır', () async {
      final r = await _Rig.create();
      r.cloud.closeError = const ApiException(
        statusCode: 409,
        code: 'DEVICE_OFFLINE',
        message: 'Cihaz çevrimdışı; komut iletilemedi.',
      );
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.c.closeMessage, 'Cihaz çevrimdışı; komut iletilemedi.');
      expect(r.c.pending, isNotNull);
      expect(r.c.closing, isFalse);
      r.dispose();
    });

    test('beklenmeyen hata (bozuk yanıt dahil) genel mesaja çevrilir, istisna sızmaz', () async {
      final r = await _Rig.create();
      r.cloud.closeError = StateError('iç hata ayrıntısı');
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.c.closeMessage, 'Lambalar kapatılamadı. Lütfen tekrar deneyin.');
      expect(r.c.closeMessage, isNot(contains('iç hata')));
      r.dispose();
    });

    test('afiş yokken bir şey yapmaz', () async {
      final r = await _Rig.create();
      await r.c.closeAll();
      expect(r.cloud.closeCalls, isEmpty);
      expect(r.c.closeMessage, isNull);
      r.dispose();
    });

    test('başka eve ait bildirim: önce o eve geçilir, istek o evin kimliğiyle gider', () async {
      final r = await _Rig.create(homes: <HomeModel>[_home(kHomeA, 'owner'), _home(kHomeB, 'owner')]);
      expect(r.state.activeHome?.id, isNot(kHomeB));
      r.push.emitNotice(r.notice(home: kHomeB, id: 77)); // ön plan: ev değişmez
      await r.pump();
      expect(r.state.activeHome?.id, isNot(kHomeB));

      await r.c.closeAll();
      expect(r.state.activeHome?.id, kHomeB);
      expect(r.cloud.closeCalls.single.homeId, kHomeB);
      expect(r.cloud.closeCalls.single.noticeId, 77);
      r.dispose();
    });

    test('bildirimin evi listeden çıktıysa anlaşılır hata (istek gitmez)', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending, isNotNull);
      // Afiş açıkken ev listesi değişti (A artık listede yok): savunma yolu.
      r.state.setHomesForTesting(<HomeModel>[_home(kHomeB, 'owner')]);
      await r.pump();
      await r.c.closeAll();
      expect(r.cloud.closeCalls, isEmpty);
      expect(r.c.closeMessage, contains('daire'));
      expect(r.c.pending, isNotNull);
      r.dispose();
    });

    test('doğrudan modda yapılmaz (bulut işlemi)', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      r.state.setModeForTesting(AppMode.direct);
      // Uygunluk kaybı afişi zaten temizler; yine de closeAll güvenli olmalı.
      await r.pump();
      await r.c.closeAll();
      expect(r.cloud.closeCalls, isEmpty);
      r.dispose();
    });

    test('closeMessage temizlenebilir; yeni closeAll eski mesajı siler', () async {
      final r = await _Rig.create();
      r.cloud.closeError = const ApiException(statusCode: 409, message: 'Çevrimdışı.');
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.c.closeMessage, 'Çevrimdışı.');
      r.c.clearCloseMessage();
      expect(r.c.closeMessage, isNull);
      r.dispose();
    });

    test('yarış: uçuştaki sonuç, çıkış + yeni oturum sonrasında yeni oturuma YANSIMAZ', () async {
      final r = await _Rig.create(viaLogin: true);
      r.cloud.closeGate = Completer<void>();
      r.push.emitNotice(r.notice());
      await r.pump();
      final inFlight = r.c.closeAll();
      await r.pump();
      expect(r.c.closing, isTrue);

      await r.state.logout();
      await r.pump();
      expect(r.c.closing, isFalse, reason: 'oturum sıfırlanınca durum da sıfırlanır');

      await r.state.login('a@b.c', 'parola-1234'); // yeni oturum
      await r.pump();
      final fetchesBefore = r.cloud.count('getPeaceNotification');
      final endpointsBefore = r.cloud.count('fetchEndpoints');

      r.cloud.closeGate!.complete();
      await inFlight;
      await r.pump();

      expect(r.c.closeMessage, isNull);
      expect(r.c.pending, isNull);
      expect(r.c.closing, isFalse);
      expect(r.cloud.count('getPeaceNotification'), fetchesBefore, reason: 'eski oturum yenileme tetiklemez');
      expect(r.cloud.count('fetchEndpoints'), endpointsBefore);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('yaşam döngüsü ve dispose', () {
    test('öne gelince uygunsa push.refresh(); arka planda / uygun değilken yok', () async {
      final r = await _Rig.create();
      r.c.didChangeAppLifecycleState(AppLifecycleState.paused);
      r.c.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await r.pump();
      expect(r.push.calls, <String>['start:false']);
      r.c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'refresh']);

      final guest = await _Rig.create(role: 'guest');
      guest.c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await guest.pump();
      expect(guest.push.calls, isEmpty);
      r.dispose();
      guest.dispose();
    });

    test('dispose: abonelikler, gözlemci ve çıkış kancası kaldırılır; geç olaylar yok sayılır', () async {
      final r = await _Rig.create();
      final notified = r.notifications;
      r.c.dispose();

      r.push.emitNotice(r.notice());
      r.push.emitState(PushState.needsPermission);
      r.state.setThemeModeForTesting(ThemeMode.light);
      r.c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await r.pump();
      expect(r.notifications, notified);
      expect(r.c.pending, isNull);
      expect(r.push.calls, <String>['start:false'], reason: 'dispose sonrası push çağrısı yok');
      expect(r.push.calls, isNot(contains('dispose')), reason: 'dışarıdan verilen koordinatör kapatılmaz');

      await r.state.logout();
      expect(r.push.calls, isNot(contains('stop:true:true')), reason: 'kanca kaldırıldı');
      r.c.dispose(); // ikinci dispose zararsız
      r.h.dispose();
    });

    test('dispose sonrası closeAll/dismiss/requestPermission zararsız', () async {
      final r = await _Rig.create();
      r.c.dispose();
      await r.c.closeAll();
      r.c.dismiss();
      await r.c.requestPermission();
      await r.c.dismissSoftPrompt();
      r.h.dispose();
    });

    test('dispose sırasında uçuştaki closeAll sonucu bildirim göndermez', () async {
      final r = await _Rig.create();
      r.cloud.closeGate = Completer<void>();
      r.push.emitNotice(r.notice());
      await r.pump();
      final inFlight = r.c.closeAll();
      await r.pump();
      final notified = r.notifications;
      r.c.dispose();
      r.cloud.closeGate!.complete();
      await inFlight;
      await r.pump();
      expect(r.notifications, notified);
      r.h.dispose();
    });

    test('push verilmezse kendi koordinatörü: push katmanı yapılandırılmadı -> unsupported, hiçbir kanala dokunulmaz', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final r = await _Rig.create(attach: false);
      final c = PeaceNoticeController(state: r.state, now: r.clock.now);
      await r.pump();
      expect(c.pushState, PushState.unsupported, reason: 'push katmanı yapılandırılmadı -> UnsupportedPushGateway');
      expect(c.softPromptVisible, isFalse);
      expect(c.pending, isNull);
      // Push'suz sürümle aynı davranış: yedek afiş yine çalışır.
      r.cloud.peaceNotification = r.settings();
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(c.pending?.source, PeaceNoticeSource.settings);
      c.dispose();
      r.h.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('gerçek koordinatör + sahte ağ geçidi (uçtan uca)', () {
    test('giriş: izinli ise kayıt olur; sistem izin penceresi açılmaz', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final gateway = push_fakes.FakeGateway();
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: gateway, api: api, platform: 'android', appVersion: '1.0.0+1');
      r.attach(coordinator);
      await r.pump();

      expect(coordinator.state, PushState.registered);
      expect(api.registerCalls.single.token, 'token-1');
      expect(api.registerCalls.single.platform, 'android');
      expect(gateway.count('requestPermission'), 0);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('çıkış: belirteç oturum belirteci HÂLÂ geçerliyken sunucudan silinir', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: push_fakes.FakeGateway(), api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();
      expect(api.registerCalls, hasLength(1));

      await r.state.logout();
      await r.pump();

      expect(api.unregisterCalls, <String>['token-1']);
      expect(api.authTokenAtUnregister, <String?>['access-1']);
      expect(r.state.isAuthenticated, isFalse);
      expect(coordinator.state, PushState.idle);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('logoutAll başarılı: silme tam bir kez gider (kanca yalnızca logout() içinde çalışır)', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: push_fakes.FakeGateway(), api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();

      await r.state.logoutAll();
      await r.pump();

      expect(api.unregisterCalls, <String>['token-1']);
      expect(r.state.isAuthenticated, isFalse);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('silme isteği takılırsa çıkış ~3 sn içinde tamamlanır', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final api = _SpyTokenApi(r.cloud)..unregisterGate = Completer<void>();
      final coordinator = PushCoordinator(gateway: push_fakes.FakeGateway(), api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();

      final watch = Stopwatch()..start();
      await r.state.logout();
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(6000));
      expect(r.state.isAuthenticated, isFalse);
      api.unregisterGate!.complete();
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('izin yok: yumuşak istem; kullanıcı onaylayınca sistem penceresi açılır ve kayıt olur', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final gateway = push_fakes.FakeGateway()
        ..permission = PushPermission.notDetermined
        ..requestResult = PushPermission.granted;
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: gateway, api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();

      expect(coordinator.state, PushState.needsPermission);
      expect(r.c.softPromptVisible, isTrue);
      expect(gateway.count('requestPermission'), 0, reason: 'kendiliğinden açılmaz');

      await r.c.requestPermission();
      await r.pump();
      expect(gateway.count('requestPermission'), 1);
      expect(coordinator.state, PushState.registered);
      expect(api.registerCalls, hasLength(1));
      expect(r.store.prompted, isTrue);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('izin reddedilince pushPermissionDenied açılır (ayar kartı için)', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final gateway = push_fakes.FakeGateway()
        ..permission = PushPermission.notDetermined
        ..requestResult = PushPermission.denied;
      final coordinator = PushCoordinator(gateway: gateway, api: _SpyTokenApi(r.cloud), platform: 'android');
      r.attach(coordinator);
      await r.pump();
      expect(r.c.softPromptVisible, isTrue);
      expect(r.c.pushPermissionDenied, isFalse);

      await r.c.requestPermission();
      await r.pump();
      expect(r.c.pushPermissionDenied, isTrue);
      expect(r.c.pushState, PushState.needsPermission);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('gateway mesajı: FCM verisi afişe dönüşür (sıkı doğrulamadan geçerek)', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final gateway = push_fakes.FakeGateway();
      final coordinator = PushCoordinator(gateway: gateway, api: _SpyTokenApi(r.cloud), platform: 'android');
      r.attach(coordinator);
      await r.pump();

      gateway.foreground.add(
        PushMessage(
          data: <String, dynamic>{
            'type': 'peace_open_devices',
            'home_id': kHomeA,
            'notice_id': '41',
            'open_lights': '2',
            'open_shutters': '1',
            'action': 'close_all',
            'v': '1',
          },
          title: 'Ev A',
          body: 'Salonda 2 lamba, 1 panjur açık.',
        ),
      );
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      expect(r.c.pending?.openLights, 2);

      // Bozuk mesaj sessizce yok sayılır.
      gateway.foreground.add(const PushMessage(data: <String, dynamic>{'type': 'baska'}));
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // F1 (B1 / R3-01): oturum bitince yerel FCM belirteci geçersiz kılınır.
  group('yerel belirteç geçersiz kılma (sahte koordinatör)', () {
    test('oturum bitti olayı: silmesiz durdurur AMA yerel belirteci geçersiz kılar (tek sefer)', () async {
      final r = await _Rig.create();
      r.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'stop:false:true']);
      r.dispose();
    });

    test('hiç uygun olmamış cihazda (soğuk açılış, süresi dolmuş oturum) olay yine geçersiz kılar', () async {
      final r = await _Rig.create(authenticated: false);
      expect(r.c.isEligible, isFalse);
      expect(r.push.calls, isEmpty);
      r.cloud.onSessionExpired?.call(SessionEndReason.noRefreshToken);
      await r.pump();
      expect(r.push.calls, <String>['stop:false:true']);
      r.dispose();
    });

    test('oturum açık değil durumuna geçiş: yerel belirteç geçersiz kılınır', () async {
      final r = await _Rig.create();
      r.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'stop:false:true']);
      r.dispose();
    });

    test('servis oturumuna geçiş: yerel belirteç geçersiz kılınır', () async {
      final r = await _Rig.create();
      r.state.setCurrentUserForTesting(
        UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: 'service_session'),
      );
      await r.pump();
      expect(r.state.isServiceSession, isTrue);
      expect(r.push.calls, <String>['start:false', 'stop:false:true']);
      r.dispose();
    });

    test('rol kaybı (oturum açık): yerel belirteç SİLİNMEZ (rol değişimi geçici olabilir)', () async {
      final r = await _Rig.create();
      r.state.setHomesForTesting(<HomeModel>[_home(kHomeA, 'guest')]);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'stop:false:false']);
      r.dispose();
    });

    test('doğrudan moda geçiş: yerel belirteç SİLİNMEZ', () async {
      final r = await _Rig.create();
      r.state.setModeForTesting(AppMode.direct);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'stop:false:false']);
      r.dispose();
    });

    test('çıkıştan sonra yeni oturum: ikinci çıkış yine geçersiz kılar', () async {
      final r = await _Rig.create(viaLogin: true);
      await r.state.logout();
      await r.pump();
      await r.state.login('a@b.c', 'parola-1234');
      await r.pump();
      r.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await r.pump();
      expect(r.push.calls, <String>[
        'start:false',
        'stop:true:true',
        'stop:false:false',
        'start:false',
        'stop:false:true',
      ]);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  group('yerel belirteç geçersiz kılma (gerçek koordinatör + sahte ağ geçidi)', () {
    Future<({_Rig rig, push_fakes.FakeGateway gateway, _SpyTokenApi api, PushCoordinator coordinator})> attached({
      bool viaLogin = true,
      String role = 'owner',
    }) async {
      final r = await _Rig.create(viaLogin: viaLogin, role: role, attach: false);
      final gateway = push_fakes.FakeGateway();
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: gateway, api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();
      return (rig: r, gateway: gateway, api: api, coordinator: coordinator);
    }

    Future<void> close(_Rig r, PushCoordinator coordinator) async {
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    }

    test('oturum bitti (refresh reddi / başka cihazdan çık): DELETE gitmez, deleteToken ÇAĞRILIR', () async {
      final t = await attached();
      expect(t.coordinator.state, PushState.registered);

      t.rig.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await t.rig.pump();

      expect(t.rig.state.isAuthenticated, isFalse);
      expect(t.api.unregisterCalls, isEmpty, reason: 'oturum bitti: silme isteği 401 verirdi');
      expect(t.gateway.deleteTokenCalls, 1, reason: 'belirteç yerelde geçersiz: sonraki gönderim UNREGISTERED döner');
      expect(t.coordinator.state, PushState.idle);
      await close(t.rig, t.coordinator);
    });

    test('çıkış: sunucu DELETE (oturum belirteci geçerliyken) + yerel deleteToken; ikincisi tek sefer', () async {
      final t = await attached();
      await t.rig.state.logout();
      await t.rig.pump();
      expect(t.api.unregisterCalls, <String>['token-1']);
      expect(t.api.authTokenAtUnregister, <String?>['access-1']);
      expect(t.gateway.deleteTokenCalls, 1, reason: 'kanca + uygunluk kaybı + oturum olayı tek geçersiz kılma');
      await close(t.rig, t.coordinator);
    });

    test('sunucu DELETE başarısız olsa da çıkışta deleteToken çağrılır', () async {
      final t = await attached();
      t.api.unregisterError = StateError('ağ yok');
      await t.rig.state.logout();
      await t.rig.pump();
      expect(t.api.unregisterCalls, hasLength(1));
      expect(t.gateway.deleteTokenCalls, 1);
      await close(t.rig, t.coordinator);
    });

    test('deleteToken hata verirse çıkış tamamlanır', () async {
      final t = await attached();
      t.gateway.deleteTokenError = StateError('çevrimdışı');
      await t.rig.state.logout();
      expect(t.rig.state.isAuthenticated, isFalse);
      await close(t.rig, t.coordinator);
    });

    test('deleteToken asılı kalırsa çıkışın yerel temizliği en çok ~1 sn gecikir', () async {
      final t = await attached();
      t.gateway.deleteTokenGate = Completer<void>();
      final watch = Stopwatch()..start();
      await t.rig.state.logout();
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(2500));
      expect(t.rig.state.isAuthenticated, isFalse);
      t.gateway.deleteTokenGate!.complete();
      await close(t.rig, t.coordinator);
    });

    test('rol kaybı: deleteToken ÇAĞRILMAZ', () async {
      final t = await attached();
      t.rig.state.setHomesForTesting(<HomeModel>[_home(kHomeA, 'guest')]);
      await t.rig.pump();
      expect(t.rig.c.isEligible, isFalse);
      expect(t.gateway.deleteTokenCalls, 0);
      expect(t.api.unregisterCalls, isEmpty);
      await close(t.rig, t.coordinator);
    });

    test('servis oturumuna geçiş: deleteToken çağrılır', () async {
      final t = await attached();
      t.rig.state.setCurrentUserForTesting(
        UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: 'service_session'),
      );
      await t.rig.pump();
      expect(t.gateway.deleteTokenCalls, 1);
      expect(t.api.unregisterCalls, isEmpty);
      await close(t.rig, t.coordinator);
    });

    test('logoutAll sunucuda başarısız: push KAPANMAZ, hiçbir silme yapılmaz', () async {
      final t = await attached();
      t.rig.cloud.logoutAllError = ApiException.network();
      await expectLater(t.rig.state.logoutAll(), throwsA(isA<ApiException>()));
      await t.rig.pump();
      expect(t.rig.state.isAuthenticated, isTrue);
      expect(t.coordinator.state, PushState.registered);
      expect(t.api.unregisterCalls, isEmpty);
      expect(t.gateway.deleteTokenCalls, 0);
      await close(t.rig, t.coordinator);
    });

    test('logoutAll başarılı: kanca logout() içinde bir kez çalışır; yerel belirteç geçersiz kılınır', () async {
      final t = await attached();
      await t.rig.state.logoutAll();
      await t.rig.pump();
      expect(t.rig.state.isAuthenticated, isFalse);
      expect(t.api.unregisterCalls, hasLength(1));
      expect(t.gateway.deleteTokenCalls, 1);
      await close(t.rig, t.coordinator);
    });

    test('soğuk açılışta süresi dolmuş oturum (hiç push başlamadı): deleteToken yine çağrılır', () async {
      final r = await _Rig.create(authenticated: false, viaLogin: false, attach: false);
      final gateway = push_fakes.FakeGateway();
      final coordinator = PushCoordinator(gateway: gateway, api: _SpyTokenApi(r.cloud), platform: 'android');
      r.attach(coordinator);
      await r.pump();
      r.cloud.onSessionExpired?.call(SessionEndReason.noRefreshToken);
      await r.pump();
      expect(gateway.deleteTokenCalls, 1);
      await close(r, coordinator);
    });
  });

  // ---------------------------------------------------------------------------
  // F1 (B4 / B5): çıkış kancası yalnızca logout()'ta çalışır; logoutAll hatasında push kapanmaz.
  group('logoutAll ve çıkış kancası', () {
    test('logoutAll sunucuda başarısız: kanca ÇALIŞMAZ, push durdurulmaz; öne gelince refresh', () async {
      final r = await _Rig.create(viaLogin: true);
      r.cloud.logoutAllError = ApiException.network();
      await expectLater(r.state.logoutAll(), throwsA(isA<ApiException>()));
      await r.pump();
      expect(r.state.isAuthenticated, isTrue);
      expect(r.push.calls, <String>['start:false']);

      r.c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'refresh']);
      r.dispose();
    });

    test('logoutAll başarılı: kanca tam bir kez (logout içinde) çalışır', () async {
      final r = await _Rig.create(viaLogin: true);
      await r.state.logoutAll();
      await r.pump();
      expect(r.push.calls.where((c) => c.startsWith('stop:true')), <String>['stop:true:true']);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // F1 (B2): iş bitince push kaynaklı afiş de kalkar.
  group('afiş iş bitince kalkar (kaynağa bakılmadan)', () {
    test('Hepsini kapat: komut gitti ama resolved:false (başka sakin çözmüş) -> afiş yine kalkar', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{
        'closed_count': 2,
        'skipped_count': 0,
        'nothing_to_do': false,
        'resolved': false,
        'notice_id': 41,
      };
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      expect(r.c.pending, isNotNull);

      await r.c.closeAll();
      await r.pump();
      expect(r.c.pending, isNull);
      expect(r.c.closeMessage, 'Kapatma komutu gönderildi.');
      r.dispose();
    });

    test('Hepsini kapat: skipped_count > 0 ise afiş AÇIK kalır', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{'closed_count': 1, 'skipped_count': 1, 'resolved': false};
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      await r.c.closeAll();
      expect(r.c.pending, isNotNull);
      r.dispose();
    });

    test('Hepsini kapat: istek hata verirse afiş açık kalır', () async {
      final r = await _Rig.create();
      r.cloud.closeError = StateError('ağ');
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      await r.c.closeAll();
      expect(r.c.pending, isNotNull);
      r.dispose();
    });

    test('taze veri: gece kaydı çözülmüş -> push afişi kalkar', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      expect(r.c.pending, isNotNull);

      r.cloud.peaceNotification = r.settings(status: 'resolved', resolvedAt: r.clock.now().toUtc().toIso8601String());
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('taze veri: canlı sayılar 0 -> push afişi kalkar', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();

      r.cloud.peaceNotification = r.settings(lights: 0, shutters: 0);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('bayat (stale) veri push afişini kaldırmaz', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      r.cloud.peaceNotification = r.settings(lights: 0, shutters: 0, stale: true);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.noticeId, 41);

      r.cloud.peaceNotification = r.settings(stale: true, status: 'resolved');
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('başka bildirimin çözülmüş kaydı (id farklı) ve hâlâ açık lamba: afiş kalır', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      r.cloud.peaceNotification = r.settings(noticeId: 99, status: 'resolved');
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('başka eve ait taze veri (home_id eşleşmez) push afişini kaldırmaz', () async {
      final r = await _Rig.create(homes: <HomeModel>[_home(kHomeA, 'owner'), _home(kHomeB, 'owner')]);
      r.push.emitNotice(r.notice(home: kHomeB, id: 41));
      await r.pump();
      expect(r.state.activeHome?.id, isNot(kHomeB));

      r.cloud.peaceNotification = r.settings(lights: 0, shutters: 0); // etkin ev A için
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.homeId, kHomeB);
      r.dispose();
    });

    test('canlı sayılar > 0 ve kayıt çözülmemiş: push afişi kalır', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      r.cloud.peaceNotification = r.settings(lights: 3);
      await r.state.fetchPeaceNotification();
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      expect(r.c.pending?.source, PeaceNoticeSource.foreground);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // F1 (B3): panjur indirme yalnızca afişteki "Hepsini kapat" için ve AÇIKÇA istenir.
  group('includeShutters', () {
    test('afişteki Hepsini kapat includeShutters: true gönderir (afiş panjurları da sayıyor)', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.cloud.closeCalls.single.includeShutters, isTrue);
      r.dispose();
    });

    test('eski pano düğmesi (AutomationState.closeAllOpenLights) panjur İNDİRMEZ', () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{'closed_count': 2};
      await r.state.closeAllOpenLights();
      await r.pump();
      expect(r.cloud.closeCalls, hasLength(1));
      expect(r.cloud.closeCalls.single.includeShutters, isFalse);
      expect(r.cloud.closeCalls.single.noticeId, isNull);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // F1 (B8 / R3-06): listedeki evlerden biri olmayan bildirim yok sayılır.
  group('bilinmeyen evin bildirimi', () {
    test('ön planda gelen: afiş OLUŞMAZ, ev değiştirilmez, durum tazelenmez', () async {
      final r = await _Rig.create();
      final fetchBefore = r.cloud.count('getPeaceNotification');
      r.push.emitNotice(r.notice(home: 'bilinmeyen-ev'));
      await r.pump();
      expect(r.c.pending, isNull);
      expect(r.cloud.count('getPeaceNotification'), fetchBefore);
      r.dispose();
    });

    test('dokunarak gelen (opened/initial): ev değiştirilmez, afiş oluşmaz', () async {
      final r = await _Rig.create();
      final active = r.state.activeHome?.id;
      for (final source in <PeaceNoticeSource>[PeaceNoticeSource.opened, PeaceNoticeSource.initial]) {
        r.push.emitNotice(r.notice(home: 'bilinmeyen-ev', source: source));
        await r.pump();
        expect(r.c.pending, isNull, reason: source.name);
      }
      expect(r.state.activeHome?.id, active);
      r.dispose();
    });

    test('kullanıcının kendi evlerinden birinin bildirimi gösterilir', () async {
      final r = await _Rig.create(homes: <HomeModel>[_home(kHomeA, 'owner'), _home(kHomeB, 'resident')]);
      r.push.emitNotice(r.notice(home: kHomeB));
      await r.pump();
      expect(r.c.pending?.homeId, kHomeB);
      r.dispose();
    });

    test('eski hesabın bildirimi yeni kullanıcıya sızmaz (ev kimliği yeni listede yok)', () async {
      final r = await _Rig.create(viaLogin: true);
      await r.state.logout();
      r.cloud.homes = <HomeModel>[testHome(id: kHomeB, role: 'owner', name: 'Yeni kullanıcının evi')];
      r.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      r.cloud.devicesByHome[kHomeB] = <DeviceInfo>[
        const DeviceInfo(deviceUuid: 'AHBU-S3-TEST02', name: 'Pano', online: true, firmware: '1.1.0'),
      ];
      await r.state.login('x@y.z', 'parola-1234');
      await r.pump();
      r.push.emitNotice(r.notice(home: kHomeA)); // eski hesabın evi
      await r.pump();
      expect(r.c.pending, isNull);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // F1 (R2-4): kalıcı red bilgisi ve elle yeniden deneme.
  group('push kaydı kalıcı red ve elle yeniden deneme', () {
    test(
      'pushRegistrationBlocked koordinatörün kalıcı red bilgisini yansıtır; retry çağırır ve dinleyicileri uyarır',
      () async {
        final r = await _Rig.create();
        expect(r.c.pushRegistrationBlocked, isFalse);

        r.push
          ..blocked = true
          ..emitState(PushState.failed);
        await r.pump();
        expect(r.c.pushRegistrationBlocked, isTrue);

        final before = r.notifications;
        await r.c.retryPushRegistration();
        expect(r.push.calls, contains('retry'));
        expect(r.c.pushRegistrationBlocked, isFalse);
        expect(r.notifications, greaterThan(before));
        r.dispose();
      },
    );

    test('uygun değilken (rol yok) pushRegistrationBlocked false; retry koordinatöre gitmez', () async {
      final r = await _Rig.create(role: 'guest');
      r.push.blocked = true;
      expect(r.c.pushRegistrationBlocked, isFalse);
      await r.c.retryPushRegistration();
      expect(r.push.calls, isEmpty);
      r.dispose();
    });

    test('retry hata verirse ya da dispose sonrası istisna sızmaz', () async {
      final r = await _Rig.create();
      r.push.throwOnEverything = true;
      await r.c.retryPushRegistration();
      r.c.dispose();
      await r.c.retryPushRegistration();
      r.h.dispose();
    });

    test('gerçek koordinatör: sunucu kalıcı reddeder -> blocked; elle yeniden deneme kaydeder', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final api = _SpyTokenApi(r.cloud)..registerOutcomes.add(const PushRegistrationRejected('400'));
      final coordinator = PushCoordinator(gateway: push_fakes.FakeGateway(), api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();
      expect(r.c.pushState, PushState.failed);
      expect(r.c.pushRegistrationBlocked, isTrue);

      await r.c.retryPushRegistration();
      await r.pump();
      expect(api.registerCalls, hasLength(2));
      expect(r.c.pushState, PushState.registered);
      expect(r.c.pushRegistrationBlocked, isFalse);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('gerçek koordinatör: geçici hata blocked DEĞİLDİR (otomatik yeniden denenir)', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final api = _SpyTokenApi(r.cloud)..registerOutcomes.add(StateError('ağ'));
      final coordinator = PushCoordinator(gateway: push_fakes.FakeGateway(), api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();
      expect(r.c.pushState, PushState.failed);
      expect(r.c.pushRegistrationBlocked, isFalse);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // FXC (RR1-01): AuthStatus.checking BELİRSİZDİR (biyometrik yeniden kilit / soğuk açılış doğrulaması):
  // oturum bitmiş sayılmaz; uygunluk, başlatma, durdurma ve yerel belirteç geçersiz kılma tetiklenmez.
  group('biyometrik yeniden kilit ve soğuk açılış (AuthStatus.checking belirsizdir)', () {
    /// Gerçek yaşam döngüsü: arka plan -> 2 dk -> ön plan; biyometrik açık, kilit ekranı açık (doğrulanmadı).
    Future<void> relock(_Rig r) async {
      r.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      r.state.handleLifecycleState(AppLifecycleState.paused);
      r.clock.advance(const Duration(minutes: 2));
      r.h.biometric.pending = Completer<bool>();
      r.state.handleLifecycleState(AppLifecycleState.resumed);
      await r.pump();
      expect(r.state.authStatus, AuthStatus.checking);
    }

    test('yeniden kilit: oturum bitmiş SAYILMAZ; push durmaz, belirteç geçersiz kılınmaz', () async {
      final r = await _Rig.create();
      expect(r.push.calls, <String>['start:false']);
      await relock(r);
      expect(r.push.calls, <String>['start:false'], reason: 'kilit oturum bitişi değildir: stop çağrılmaz');
      expect(r.c.isEligible, isTrue, reason: 'kilitliyken önceki uygunluk korunur');
      r.dispose();
    });

    test('kilit açılınca: yeniden başlatma/durdurma YOK; gösterilen afiş korunur', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      await relock(r);
      expect(r.c.pending?.noticeId, 41, reason: 'kilit sırasında afiş sıfırlanmaz');

      r.h.biometric.pending!.complete(true);
      await r.pump();
      expect(r.state.authStatus, AuthStatus.authenticated);
      expect(r.push.calls, <String>['start:false'], reason: 'eski uygunlukla aynı: yeniden kayıt baskısı yok');
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('gerçek koordinatör: kilitte deleteToken ve sunucu DELETE yok; açılınca yeniden kayıt yok', () async {
      final r = await _Rig.create(viaLogin: true, attach: false);
      final gateway = push_fakes.FakeGateway();
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: gateway, api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();
      expect(coordinator.state, PushState.registered);
      expect(api.registerCalls, hasLength(1));

      await relock(r);
      await r.pump();
      expect(gateway.deleteTokenCalls, 0, reason: 'kilit: gece bildirimi belirteci silinmemeli');
      expect(api.unregisterCalls, isEmpty);
      expect(coordinator.state, PushState.registered, reason: 'push durmadı');

      r.h.biometric.pending!.complete(true);
      await r.pump();
      expect(r.state.authStatus, AuthStatus.authenticated);
      expect(gateway.deleteTokenCalls, 0);
      expect(api.unregisterCalls, isEmpty);
      expect(api.registerCalls, hasLength(1), reason: 'aynı belirteç/kayıt korunur: gereksiz yeniden kayıt yok');
      expect(coordinator.state, PushState.registered);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test(
      'kilitliyken şifreyle girişe düşme (gerçek çıkış): kanca siler, belirteç tek sefer geçersiz kılınır',
      () async {
        final r = await _Rig.create(viaLogin: true);
        await relock(r);
        await r.state.fallbackToPasswordLogin();
        await r.pump();
        expect(r.state.authStatus, AuthStatus.unauthenticated);
        expect(r.push.calls, <String>['start:false', 'stop:true:true', 'stop:false:false']);
        r.dispose();
      },
    );

    test('kilitliyken oturum bitti olayı: yerel belirteç geçersiz kılınır (tek sefer)', () async {
      final r = await _Rig.create();
      await relock(r);
      r.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await r.pump();
      expect(r.state.authStatus, AuthStatus.unauthenticated);
      expect(r.push.calls, <String>['start:false', 'stop:false:true']);
      r.dispose();
    });

    test('kilitliyken oturum açık değil durumuna geçiş (gerçek bitiş): belirteç geçersiz kılınır', () async {
      final r = await _Rig.create();
      await relock(r);
      r.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await r.pump();
      expect(r.push.calls, <String>['start:false', 'stop:false:true']);
      r.dispose();
    });

    test('soğuk açılış: checking -> authenticated: deleteToken YOK, push başlar', () async {
      final r = await _Rig.create(authenticated: false, attach: false);
      expect(r.state.authStatus, AuthStatus.checking);
      final gateway = push_fakes.FakeGateway();
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: gateway, api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();
      expect(r.c.isEligible, isFalse);
      expect(gateway.deleteTokenCalls, 0);

      r.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await r.pump();
      expect(r.c.isEligible, isTrue);
      expect(gateway.deleteTokenCalls, 0);
      expect(api.unregisterCalls, isEmpty);
      expect(coordinator.state, PushState.registered);
      expect(api.registerCalls, hasLength(1));
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('soğuk açılış: checking -> unauthenticated (olay YOK): deleteToken yok (olay yolu ayrı)', () async {
      final r = await _Rig.create(authenticated: false, attach: false);
      expect(r.state.authStatus, AuthStatus.checking);
      final gateway = push_fakes.FakeGateway();
      final api = _SpyTokenApi(r.cloud);
      final coordinator = PushCoordinator(gateway: gateway, api: api, platform: 'android');
      r.attach(coordinator);
      await r.pump();

      r.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await r.pump();
      expect(gateway.deleteTokenCalls, 0);
      expect(api.unregisterCalls, isEmpty);
      expect(coordinator.state, PushState.idle);
      r.c.dispose();
      await coordinator.dispose();
      r.h.dispose();
    });

    test('soğuk açılışta checking sürerken push başlamaz ve durdurma da çağrılmaz', () async {
      final r = await _Rig.create(authenticated: false);
      expect(r.state.authStatus, AuthStatus.checking);
      expect(r.c.isEligible, isFalse);
      expect(r.push.calls, isEmpty);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // Zorunlu parola değişimi (oturum açık + mustChangePassword): AuthGate bu görünümde pano/oturum verisi göstermez;
  // denetleyici bunu KİLİT sayar (yalnız görünürlük): oturum bitişi değildir, push durmaz/yeniden başlamaz.
  group('zorunlu parola değişimi (kilit sayılır, oturum bitişi değildir)', () {
    UserModel user({required bool mustChange}) =>
        UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: 'user', mustChangePassword: mustChange);

    test('uygun oturumda kilit açılıp kapanır, dinleyiciler uyarılır; afiş ve push korunur', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      expect(r.c.isLocked, isFalse);

      final beforeLock = r.notifications;
      r.state.setCurrentUserForTesting(user(mustChange: true));
      await r.pump();
      expect(r.state.mustChangePassword, isTrue);
      expect(r.c.isLocked, isTrue);
      expect(r.notifications, greaterThan(beforeLock), reason: 'kilit değişimi dinleyicilere bildirilir');
      expect(r.c.pending?.noticeId, 41, reason: 'kilit oturum bitişi değildir: afiş korunur');
      expect(r.c.isEligible, isTrue);
      expect(r.push.calls, <String>['start:false'], reason: 'push durmaz ve yeniden başlamaz');

      final beforeUnlock = r.notifications;
      r.state.setCurrentUserForTesting(user(mustChange: false));
      await r.pump();
      expect(r.c.isLocked, isFalse);
      expect(r.notifications, greaterThan(beforeUnlock), reason: 'parola değişince dinleyiciler yeniden uyarılır');
      expect(r.c.pending?.noticeId, 41);
      expect(r.push.calls, <String>['start:false']);
      r.dispose();
    });

    test('kilitliyken gelen afiş bekler (kaybolmaz); parola değişince gösterilebilir', () async {
      final r = await _Rig.create();
      r.state.setCurrentUserForTesting(user(mustChange: true));
      await r.pump();
      expect(r.c.isLocked, isTrue);

      r.push.emitNotice(r.notice(id: 42));
      await r.pump();
      expect(r.c.pending?.noticeId, 42, reason: 'afiş bellekte tutulur; yalnız gösterimi arayüzde gizlenir');
      expect(r.c.isLocked, isTrue);

      r.state.setCurrentUserForTesting(user(mustChange: false));
      await r.pump();
      expect(r.c.isLocked, isFalse);
      expect(r.c.pending?.noticeId, 42);
      r.dispose();
    });

    test('uygun olmayan oturumda (misafir) kilit yok: zaten afiş olamaz', () async {
      final r = await _Rig.create(role: 'guest');
      expect(r.c.isEligible, isFalse);
      r.state.setCurrentUserForTesting(user(mustChange: true));
      await r.pump();
      expect(r.state.mustChangePassword, isTrue);
      expect(r.c.isLocked, isFalse);
      r.dispose();
    });

    test('uygulama-ekranlar-2: sözleşme onayı bekleyen oturum kilit sayılır; afiş korunur ama "Hepsini kapat" çalışmaz',
        () async {
      final r = await _Rig.create();
      r.cloud.closeResult = <String, dynamic>{'closed_count': 2, 'resolved': true, 'notice_id': 41, 'message': ''};
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      expect(r.c.isLocked, isFalse);

      r.state.setCurrentUserForTesting(const UserModel(
        id: 'user-1',
        email: 'a@b.c',
        fullName: 'Ayşe',
        role: 'user',
        legal: UserLegalStatus(termsCurrentVersion: 2, termsStatus: 'final', needsAcceptance: true),
      ));
      await r.pump();
      expect(r.state.needsTermsAcceptance, isTrue);
      expect(r.c.isLocked, isTrue, reason: 'sözleşme kapısı da oturum verisi göstermeyen bir görünümdür');

      await r.c.closeAll();
      await r.pump();
      expect(r.cloud.closeCalls, isEmpty, reason: 'kapı geçilmeden "Hepsini kapat" çalışmaz');
      expect(r.c.pending?.noticeId, 41, reason: 'afiş korunur');
      r.dispose();
    });

    test('biyometrik kilit ve zorunlu parola art arda: ikisi de bitene kadar kilit sürer', () async {
      final r = await _Rig.create();
      r.state.setCurrentUserForTesting(user(mustChange: true));
      r.state.setAuthStatusForTesting(AuthStatus.checking);
      await r.pump();
      expect(r.c.isLocked, isTrue);

      r.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await r.pump();
      expect(r.c.isLocked, isTrue, reason: 'biyometrik kilit açıldı ama parola değişimi sürüyor');

      r.state.setCurrentUserForTesting(user(mustChange: false));
      await r.pump();
      expect(r.c.isLocked, isFalse);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // FXC (RR1-04): kısmi çevrimdışı evde "sayılar 0" = "hepsi kapalı" DEĞİLDİR.
  group('taze veriyle push afişi kaldırma: çevrimdışı cihaz (RR1-04)', () {
    Future<_Rig> withPushNotice() async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41, lights: 2, shutters: 0));
      await r.pump();
      expect(r.c.pending?.noticeId, 41);
      return r;
    }

    Future<void> fetch(_Rig r, Map<String, dynamic> data) async {
      r.cloud.peaceNotification = data;
      await r.state.fetchPeaceNotification();
      await r.pump();
    }

    test('devices_online < devices_total, sayılar 0: afiş KALIR (bilinmiyor; "hepsi kapalı" denmez)', () async {
      final r = await withPushNotice();
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: 2, devicesOnline: 1));
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('tüm cihazlar çevrimiçi (online == total > 0), sayılar 0: afiş kalkar', () async {
      final r = await withPushNotice();
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: 3, devicesOnline: 3));
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('devices_* alanları yok (eski/eksik yanıt): sayı tabanlı kaldırma YOK', () async {
      final r = await withPushNotice();
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: null, devicesOnline: null));
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('yalnızca biri verilmiş (total ya da online eksik): afiş kalır', () async {
      final r = await withPushNotice();
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: 2, devicesOnline: null));
      expect(r.c.pending?.noticeId, 41);
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: null, devicesOnline: 2));
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('hiç cihaz yok (0/0) ya da tutarsız (online > total): afiş kalır', () async {
      final r = await withPushNotice();
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: 0, devicesOnline: 0));
      expect(r.c.pending?.noticeId, 41);
      await fetch(r, r.settings(lights: 0, shutters: 0, devicesTotal: 2, devicesOnline: 3));
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });

    test('kısmi çevrimdışı olsa da gece kaydı çözüldüyse (last_notice aynı id + resolved): afiş kalkar', () async {
      final r = await withPushNotice();
      await fetch(
        r,
        r.settings(
          lights: 0,
          shutters: 0,
          devicesTotal: 2,
          devicesOnline: 1,
          status: 'resolved',
          resolvedAt: r.clock.now().toUtc().toIso8601String(),
        ),
      );
      expect(r.c.pending, isNull);
      r.dispose();
    });

    test('sayılar > 0 iken tüm cihazlar çevrimiçi olsa da afiş kalır', () async {
      final r = await withPushNotice();
      await fetch(r, r.settings(lights: 1, shutters: 0, devicesTotal: 2, devicesOnline: 2));
      expect(r.c.pending?.noticeId, 41);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // FXC (RR1-08 / RR1-02): afişten "Hepsini kapat" yalnızca afiş panjur sayıyorsa panjur indirir;
  // eski pano düğmesi ayrı (tek konumsal parametreli) yöntemi kullanır.
  group('Hepsini kapat: includeShutters ve yöntem seçimi', () {
    test('afiş 0 panjur diyorsa include_shutters:false gider', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41, lights: 2, shutters: 0));
      await r.pump();
      await r.c.closeAll();
      expect(r.cloud.closeCalls.single.includeShutters, isFalse, reason: 'afiş yalnızca lamba sayıyor');
      expect(r.cloud.closeCalls.single.noticeId, 41);
      r.dispose();
    });

    test('afiş panjur sayıyorsa (> 0) include_shutters:true gider', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice(id: 41, lights: 0, shutters: 3));
      await r.pump();
      await r.c.closeAll();
      expect(r.cloud.closeCalls.single.includeShutters, isTrue);
      r.dispose();
    });

    test('afiş yolu closeAllForNotice, eski pano düğmesi closeAllOpenLights kullanır', () async {
      final r = await _Rig.create();
      r.push.emitNotice(r.notice());
      await r.pump();
      await r.c.closeAll();
      expect(r.cloud.closeVia, <String>['notice']);

      await r.state.closeAllOpenLights();
      await r.pump();
      expect(r.cloud.closeVia, <String>['notice', 'legacy']);
      r.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // FXC (test boşluğu S5): ev listesi henüz boşken gelen bildirim kaybolmaz.
  group('ev listesi boşken gelen bildirim', () {
    test('liste henüz yüklenmemiş (boş): bildirim atılmaz, afiş oluşur', () async {
      final r = await _Rig.create(homes: <HomeModel>[]);
      expect(r.state.homes, isEmpty);
      r.push.emitNotice(r.notice(id: 41));
      await r.pump();
      expect(r.c.pending?.noticeId, 41, reason: 'boş listede "bilinmeyen ev" kuralı uygulanmaz');
      r.dispose();
    });
  });
}
