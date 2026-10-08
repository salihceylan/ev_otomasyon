import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_notice.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_watch_engine.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_watch_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// Arka plan alarm izleyicisinin çekirdeği: rol kapısı, ev başına MQTT, state -> bildirim, kalıcı tekilleştirme,
/// ev listesi alınamazken kayıtlı liste, oturum bitişi ve ayarın kapanması.
const String _uid = 'AHBU-S3-TEST01';

class _Notifier implements AlarmNotifier {
  final List<AlarmNotice> shown = <AlarmNotice>[];
  final List<int> cancelled = <int>[];
  final List<String> statuses = <String>[];
  final List<String> stops = <String>[];

  @override
  Future<void> show(AlarmNotice notice) async => shown.add(notice);

  @override
  Future<void> cancel(int notificationId) async => cancelled.add(notificationId);

  @override
  Future<void> status(String text) async => statuses.add(text);

  @override
  Future<void> stopped(String text) async => stops.add(text);
}

Map<String, dynamic> _stateJson({String st = 'normal', String aid = 'aa11-1'}) => <String, dynamic>{
      'v': 3,
      'uid': _uid,
      'relays': <Object?>[],
      'caps': <String>['safety', 'actuator', 'event', 'cfg'],
      'sensors': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd3', 'src': 'di', 'kind': 'water', 'zone': 1, 'active': st != 'normal', 'ok': true},
      ],
      'safety': <String, dynamic>{
        'policy': 'on',
        'mode': 'normal',
        'zones': <Map<String, dynamic>>[
          if (st != 'normal')
            <String, dynamic>{'id': 1, 'st': st, 'kind': 'water', 'aid': aid, 'since_up': 5, 'srcs': <String>['d3']},
        ],
      },
    };

void main() {
  late FakeCloudApi cloud;
  late MemoryAlarmWatchStore store;
  late _Notifier notifier;
  late List<FakeMqtt> mqtts;
  late List<String> stopReasons;
  UserModel? user;

  const owner = HomeModel(id: 'h-owner', name: 'Evim', role: 'owner');
  const resident = HomeModel(id: 'h-res', name: 'Annemin Evi', role: 'resident');
  const guest = HomeModel(id: 'h-guest', name: 'Komşu', role: 'guest');
  const staff = HomeModel(id: 'h-staff', name: 'Müşteri', role: 'service_user');

  AlarmWatchEngine engine({FakeClock? clock}) => AlarmWatchEngine(
        cloud: cloud,
        settings: AlarmWatchSettingsRepository(store),
        dedupe: AlarmDedupeStore(store),
        notifier: notifier,
        mqttFactory: () {
          final m = FakeMqtt();
          mqtts.add(m);
          return m;
        },
        readUser: () async => user,
        onStopRequested: stopReasons.add,
        clock: clock ?? FakeClock(),
        backoff: AlarmBackoff(random: () => 0.5),
      );

  Future<void> enable({String userId = 'u1', List<WatchedHome> homes = const <WatchedHome>[]}) =>
      AlarmWatchSettingsRepository(store).save(AlarmWatchSettings(enabled: true, userId: userId, homes: homes));

  setUp(() {
    cloud = FakeCloudApi()
      ..setAuthToken('access')
      ..setRefreshToken('refresh')
      ..homes = <HomeModel>[owner, resident, guest, staff]
      ..safetyConfigs[_uid] = <String, dynamic>{
        'sensors': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'd3', 'name': 'Mutfak Su'},
        ],
      };
    store = MemoryAlarmWatchStore();
    notifier = _Notifier();
    mqtts = <FakeMqtt>[];
    stopReasons = <String>[];
    user = const UserModel(id: 'u1', email: 'ev@ornek.test', fullName: 'Ev Sahibi', role: 'user');
  });

  tearDown(() => cloud.dispose());

  test('ayar kapalıysa başlamaz ve servis durdurulur', () async {
    final e = engine();
    expect(await e.start(), isFalse);
    expect(stopReasons, <String>['disabled']);
    expect(cloud.calls, isNot(contains('fetchHomes')));
  });

  test('başka kullanıcı / kullanıcı yok / oturum yok: durur', () async {
    await enable(userId: 'baskasi');
    expect(await engine().start(), isFalse);
    expect(stopReasons.last, 'user');

    await enable();
    user = null;
    expect(await engine().start(), isFalse);
    expect(stopReasons.last, 'user');

    user = const UserModel(id: 'u1', email: 'e', fullName: 'f', role: 'user');
    cloud.clearSession();
    expect(await engine().start(), isFalse);
    expect(stopReasons.last, 'session');
  });

  test('rol kapısı: yalnız owner/resident evleri izlenir (misafir ve servis evleri ✖); liste kaydedilir', () async {
    await enable();
    final e = engine();
    expect(await e.start(), isTrue);
    expect(e.watchedHomeIds, unorderedEquals(<String>['h-owner', 'h-res']));
    expect(cloud.calls, containsAll(<String>['mqttCredentials:h-owner', 'mqttCredentials:h-res']));
    expect(cloud.calls, isNot(contains('mqttCredentials:h-guest')));
    final saved = await AlarmWatchSettingsRepository(store).load();
    expect(saved.homes.map((h) => h.id), <String>['h-owner', 'h-res']);
    expect(notifier.statuses.last, 'Alarm takibi açık • 2 ev');
    await e.stop();
  });

  test('servis personeli hesabı: yalnız müşteri evleri (ev rolü service_user) -> uygun ev yok -> durur', () async {
    await enable();
    user = const UserModel(id: 'u1', email: 'e', fullName: 'Servis', role: 'service_user');
    cloud.homes = <HomeModel>[guest, staff];
    expect(await engine().start(), isFalse);
    expect(stopReasons, <String>['no_homes']);
  });

  test('guvenlik-12: kendi evinin sahibi olan servis personeli kendi evini izler; müşteri evini izlemez', () async {
    await enable();
    user = const UserModel(id: 'u1', email: 'e', fullName: 'Servis', role: 'service_user');
    final e = engine();
    expect(await e.start(), isTrue);
    expect(e.watchedHomeIds, <String>['h-owner', 'h-res']);
    await e.stop();
  });

  test('alarm: sensör adıyla bir kez bildirilir; yeni alarm kimliği yeniden; kalkınca silinir', () async {
    await enable();
    cloud.homes = <HomeModel>[owner];
    final e = engine();
    await e.start();
    final m = mqtts.single;
    m.emitStateJson(_stateJson());
    await pumpEventQueue();
    expect(notifier.shown, isEmpty);

    m.emitStateJson(_stateJson(st: 'latched'));
    await pumpEventQueue();
    expect(notifier.shown.single.title, 'Su baskını: Mutfak Su — Evim');
    expect(cloud.calls, contains('safetyConfig:$_uid'));

    m.emitStateJson(_stateJson(st: 'latched'));
    await pumpEventQueue();
    expect(notifier.shown, hasLength(1), reason: 'özdeş durum');

    m.emitStateJson(_stateJson());
    await pumpEventQueue();
    expect(notifier.cancelled, contains(stableNotificationId('z|h-owner|$_uid|1')));

    m.emitStateJson(_stateJson(st: 'latched', aid: 'bb22-1'));
    await pumpEventQueue();
    expect(notifier.shown, hasLength(2), reason: 'yeni alarm');
    await e.stop();
  });

  test('guvenlik-9: her state etkin alarmın kaydını tazeler; 7 günü aşan eski kilit yeniden başlangıçta yeni sayılmaz',
      () async {
    await enable();
    cloud.homes = <HomeModel>[owner];
    var now = DateTime(2026, 10, 9, 12);
    final dedupe = AlarmDedupeStore(store, now: () => now);
    AlarmWatchEngine make() => AlarmWatchEngine(
          cloud: cloud,
          settings: AlarmWatchSettingsRepository(store),
          dedupe: dedupe,
          notifier: notifier,
          mqttFactory: () {
            final m = FakeMqtt();
            mqtts.add(m);
            return m;
          },
          readUser: () async => user,
          onStopRequested: stopReasons.add,
          clock: FakeClock(),
          backoff: AlarmBackoff(random: () => 0.5),
        );
    final first = make();
    await first.start();
    mqtts.last.emitStateJson(_stateJson(st: 'latched'));
    await pumpEventQueue();
    expect(notifier.shown, hasLength(1));
    now = now.add(const Duration(days: 5)); // kilit sürüyor: özdeş kalp atışı kaydı tazeler
    mqtts.last.emitStateJson(_stateJson(st: 'latched'));
    await pumpEventQueue();
    await first.stop();

    now = now.add(const Duration(days: 4)); // ilk bildirimden 9 gün sonra servis yeniden başlar
    final second = make();
    await second.start();
    mqtts.last.emitStateJson(_stateJson(st: 'latched'), retained: true);
    await pumpEventQueue();
    expect(notifier.shown, hasLength(1), reason: 'aynı (sürmekte olan) alarm ikinci kez çalmaz');
    await second.stop();
  });

  test('servis yeniden başlayınca (retained ilk görüntü) aynı alarm ikinci kez çalmaz', () async {
    await enable();
    cloud.homes = <HomeModel>[owner];
    final first = engine();
    await first.start();
    mqtts.last.emitStateJson(_stateJson(st: 'latched'), retained: true);
    await pumpEventQueue();
    expect(notifier.shown, hasLength(1));
    await first.stop();

    final second = engine();
    await second.start();
    mqtts.last.emitStateJson(_stateJson(st: 'latched'), retained: true);
    await pumpEventQueue();
    expect(notifier.shown, hasLength(1), reason: 'kalıcı tekilleştirme');
    await second.stop();
  });

  test('sensör adları alınamazsa bölge adıyla bildirilir', () async {
    await enable();
    cloud
      ..homes = <HomeModel>[owner]
      ..safetyConfigs.clear();
    final e = engine();
    await e.start();
    mqtts.single.emitStateJson(_stateJson(st: 'latched'));
    await pumpEventQueue();
    expect(notifier.shown.single.title, 'Su baskını: Bölge 1 — Evim');
    await e.stop();
  });

  test('ev listesi alınamazsa (internet yok) kayıtlı listeyle başlar; geri çekilme dolunca yeniden dener', () async {
    final clock = FakeClock();
    await enable(homes: const <WatchedHome>[WatchedHome(id: 'h-owner', name: 'Evim')]);
    cloud.fetchHomesError = ApiException.network();
    final e = engine(clock: clock);
    expect(await e.start(), isTrue);
    expect(e.watchedHomeIds, <String>['h-owner']);

    cloud
      ..fetchHomesError = null
      ..homes = <HomeModel>[owner, resident];
    await e.refresh();
    expect(e.watchedHomeIds, <String>['h-owner'], reason: 'geri çekilme süresi dolmadı');
    clock.advance(const Duration(seconds: 6));
    await e.refresh();
    expect(e.watchedHomeIds, unorderedEquals(<String>['h-owner', 'h-res']));
    await e.stop();
  });

  test('uyelik-5: tüm evler MQTT\'ye bağlıyken ev listesi 15 dk yerine 60 dk\'da bir tazelenir', () async {
    final clock = FakeClock();
    await enable();
    final e = engine(clock: clock);
    expect(await e.start(), isTrue);
    await pumpEventQueue();
    final fetches = cloud.count('fetchHomes');

    clock.advance(const Duration(minutes: 15));
    await e.refresh();
    clock.advance(const Duration(minutes: 15));
    await e.refresh();
    expect(cloud.count('fetchHomes'), fetches, reason: 'bağlıyken 60 dk dolmadan istenmez');

    clock.advance(const Duration(minutes: 31));
    await e.refresh();
    expect(cloud.count('fetchHomes'), fetches + 1);

    // Bağlantı koptuysa (bir ev bağlı değil) 15 dk kuralı geçerli.
    await mqtts.first.stop();
    clock.advance(const Duration(minutes: 15));
    await e.refresh();
    expect(cloud.count('fetchHomes'), fetches + 2);
    await e.stop();
  });

  test('ayar sonradan kapatılırsa periyodik denetimde durur', () async {
    await enable();
    final e = engine();
    await e.start();
    await AlarmWatchSettingsRepository(store).save(AlarmWatchSettings.off);
    await e.refresh();
    expect(stopReasons, <String>['disabled']);
    expect(e.isRunning, isFalse);
  });

  test('oturum biterse bilgi bildirimi gösterilir ve servis durur', () async {
    await enable();
    final e = engine();
    await e.start();
    cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
    await pumpEventQueue();
    expect(notifier.stops.single, contains('yeniden giriş'));
    expect(stopReasons, <String>['session']);
  });
}
