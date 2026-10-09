import 'dart:async';

import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:ev_otomasyon/services/safety_notice_controller.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';
import '../ui/e1_helpers.dart';

/// Faz 2 WP-N2 (tasarım F2.C.4, F2.C.6, F2.C.7): bildirime dokununca alarm kartına yönlendirme kararı, ön plan afişi.
void main() {
  late StreamController<SafetyPushNotice> notices;
  late StateHarness h;
  late SafetyNoticeController c;

  SafetyPushNotice notice({
    String home = kHomeA,
    String? uuid = kSafetyUid,
    int zone = 1,
    String kind = 'water',
    String type = 'safety_alarm',
    String? reason,
    PeaceNoticeSource source = PeaceNoticeSource.opened,
    String alarmId = '41',
  }) =>
      SafetyPushNotice.tryParse(
        <String, dynamic>{
          'type': type,
          'v': '1',
          'home_id': home,
          'device_id': 'dev-1',
          'device_uuid': ?uuid,
          'alarm_id': alarmId,
          if (type == 'safety_alarm') ...<String, dynamic>{'zone': '$zone', 'kind': kind, 'status': 'latched'},
          if (type == 'safety_info') 'reason': reason ?? 'alarm_lost',
        },
        title: 'Su baskını alarmı',
        source: source,
        now: h.clock.now(),
      )!;

  Future<void> setUpRig({String role = 'owner', List<HomeModel>? homes}) async {
    h = await e1Ready(role: role, endpoints: safetyUiEndpoints());
    if (homes != null) {
      h.cloud.homes = homes;
      await h.state.fetchHomes(autoSelect: false);
    }
    notices = StreamController<SafetyPushNotice>.broadcast();
    c = SafetyNoticeController(state: h.state, notices: notices.stream, now: h.clock.now);
  }

  tearDown(() async {
    c.dispose();
    await notices.close();
    h.dispose();
  });

  Future<SafetyNoticeTarget?> deliver(SafetyPushNotice n) async {
    notices.add(n);
    await pumpEventQueue(times: 40);
    return c.takeTarget();
  }

  test('açılan alarm bildirimi -> pano uid + bölge ile kritik alarm kartı', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    await pumpEventQueue();
    final target = await deliver(notice());
    expect(target, isNotNull);
    expect(target!.kind, SafetyNoticeTargetKind.card);
    expect(target.cardKey, 'card_critical_alarm_${kSafetyUid}_1');
  });

  test('device_uuid yok (eski sunucu) -> aynı bölgedeki ilk kritik kart', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    await pumpEventQueue();
    final target = await deliver(notice(uuid: null));
    expect(target!.cardKey, 'card_critical_alarm_${kSafetyUid}_1');
  });

  test('alarm bu arada kapanmış -> alarm geçmişi + "Bu alarm kapanmış."; misafirde yalnız pano', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson());
    await pumpEventQueue();
    final target = await deliver(notice());
    expect(target!.kind, SafetyNoticeTargetKind.history);
    expect(target.note, 'Bu alarm kapanmış.');
  });

  test('misafir: kart yoksa geçmiş açılmaz, pano', () async {
    await setUpRig(role: 'guest');
    h.mqtt.emitStateJson(safetyStateJson());
    await pumpEventQueue();
    final target = await deliver(notice());
    expect(target!.kind, SafetyNoticeTargetKind.dashboard);
  });

  test('kullanıcının evlerinden biri değil -> yok sayılır', () async {
    await setUpRig();
    final target = await deliver(notice(home: '99999999-9999-4999-8999-999999999999'));
    expect(target, isNull);
  });

  test('etkin ev farklı -> o eve geçilir, sonra hedef çözülür (canlı durum gelmedi, alarm sunucuda açık: pano)', () async {
    await setUpRig(homes: <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık', topic: 'h_b')]);
    h.cloud.endpoints[kHomeB] = safetyUiEndpoints();
    h.cloud.alarmRecords = const <AlarmRecord>[
      AlarmRecord(id: '41', zone: 1, aid: '9f3a11c0-3', kind: 'water', deviceUuid: kSafetyUid),
    ];
    expect(h.state.activeHome?.id, kHomeA);
    notices.add(notice(home: kHomeB));
    await pumpEventQueue(times: 40);
    await h.clock.elapse(const Duration(seconds: 6)); // canlı durum beklenir (en çok refreshTimeout)
    await pumpEventQueue(times: 40);
    final target = c.takeTarget();
    expect(h.state.activeHome?.id, kHomeB);
    expect(target, isNotNull);
    expect(target!.kind, SafetyNoticeTargetKind.dashboard, reason: 'kart MQTT gelince görünür; "kapanmış" denmez');
  });

  group('kullanim-2: canlı durum beklenmeden "Bu alarm kapanmış" denmez', () {
    test('MQTT state\'i olmayan başka eve geçiş: REST denetimi başarısız -> pano (geçmiş DEĞİL)', () async {
      await setUpRig(homes: <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık', topic: 'h_b')]);
      h.cloud.endpoints[kHomeB] = safetyUiEndpoints();
      h.cloud.alarmsError = ApiException.network();
      notices.add(notice(home: kHomeB));
      await pumpEventQueue(times: 40);
      await h.clock.elapse(const Duration(seconds: 6));
      await pumpEventQueue(times: 40);
      final target = c.takeTarget();
      expect(target?.kind, SafetyNoticeTargetKind.dashboard);
      expect(target?.kind, isNot(SafetyNoticeTargetKind.history));
    });

    test('canlı durum yok ama REST kontrolü alarmın kapandığını gösteriyor -> geçmiş + not', () async {
      await setUpRig(homes: <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık', topic: 'h_b')]);
      h.cloud.endpoints[kHomeB] = safetyUiEndpoints();
      h.cloud.alarmRecords = const <AlarmRecord>[];
      notices.add(notice(home: kHomeB));
      await pumpEventQueue(times: 40);
      await h.clock.elapse(const Duration(seconds: 6));
      await pumpEventQueue(times: 40);
      final target = c.takeTarget();
      expect(target?.kind, SafetyNoticeTargetKind.history);
      expect(target?.note, 'Bu alarm kapanmış.');
    });

    test('aynı ev: arka plandan dönüşte bayat harita; ~200 ms sonra alarmı taşıyan canlı state -> kart', () async {
      await setUpRig();
      h.mqtt.emitStateJson(safetyStateJson()); // alarm yok: arka plandan sonra bayat kalacak
      await pumpEventQueue();
      h.state.handleLifecycleState(AppLifecycleState.paused);
      await h.clock.elapse(const Duration(minutes: 5));
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 40);

      notices.add(notice());
      await pumpEventQueue(times: 40);
      expect(c.takeTarget(), isNull, reason: 'taze canlı durum bekleniyor');

      await h.clock.elapse(const Duration(milliseconds: 200));
      h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
      await pumpEventQueue(times: 40);
      final target = c.takeTarget();
      expect(target?.kind, SafetyNoticeTargetKind.card);
      expect(target?.cardKey, 'card_critical_alarm_${kSafetyUid}_1');
    });

    test('awaitFreshSafety: canlı kanal başladıktan sonra state geldiyse hemen true; doğrudan kipte true', () async {
      await setUpRig();
      h.mqtt.emitStateJson(safetyStateJson());
      await pumpEventQueue();
      expect(await h.state.awaitFreshSafety(homeId: kHomeA, timeout: const Duration(seconds: 1)), isTrue);
      final other = h.state.awaitFreshSafety(homeId: kHomeB, timeout: const Duration(seconds: 1));
      expect(await other, isFalse, reason: 'başka ev');
    });
  });

  test('kullanim-3: doğrudan kipte LAN panosu bildirimin evine ait değilse yalnız pano', () async {
    await setUpRig();
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{
          ...safetyStateJson(),
          'uid': 'AHBU-S3-OTHER1',
          'device': 'AHBU-S3-OTHER1',
        }));
    await h.state.setMode(AppMode.direct);
    await h.state.setHost('192.168.1.30');
    await pumpEventQueue(times: 40);
    final target = await deliver(notice());
    expect(target?.kind, SafetyNoticeTargetKind.dashboard);
  });

  test('oturum yokken bekletilir, oturum açılınca bir kez işlenir', () async {
    await setUpRig();
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    final first = await deliver(notice());
    expect(first, isNull, reason: 'oturum yok: bekletilir');
    h.state.setAuthStatusForTesting(AuthStatus.authenticated);
    await pumpEventQueue(times: 40);
    final target = c.takeTarget();
    expect(target?.cardKey, 'card_critical_alarm_${kSafetyUid}_1');
    h.state.setAuthStatusForTesting(AuthStatus.authenticated);
    await pumpEventQueue(times: 40);
    expect(c.takeTarget(), isNull, reason: 'bir kez işlenir');
  });

  test('uygulama-ekranlar-2: sözleşme onayı beklerken dokunuş bekletilir; onaylanınca işlenir', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson());
    await pumpEventQueue();
    const base = UserModel(id: 'user-1', email: 'ayse@example.test', fullName: 'Ayşe Yılmaz', role: 'user');
    h.state.setCurrentUserForTesting(base.copyWith(
      legal: const UserLegalStatus(termsCurrentVersion: 2, termsStatus: 'final', needsAcceptance: true),
    ));
    expect(h.state.needsTermsAcceptance, isTrue);
    expect(await deliver(notice(type: 'safety_info', reason: 'policy_off')), isNull,
        reason: 'kapı (sözleşme onayı) geçilmeden yönlendirme yok');

    h.state.setCurrentUserForTesting(base);
    await pumpEventQueue(times: 40);
    expect(c.takeTarget()?.kind, SafetyNoticeTargetKind.deviceSettings, reason: 'kapı geçilince bekletilen dokunuş işlenir');
  });

  test('uygulama-ekranlar-2: zorunlu parola değişimi sürerken dokunuş bekletilir; parola değişince işlenir', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson());
    await pumpEventQueue();
    const base = UserModel(id: 'user-1', email: 'ayse@example.test', fullName: 'Ayşe Yılmaz', role: 'user');
    h.state.setCurrentUserForTesting(base.copyWith(mustChangePassword: true));
    expect(await deliver(notice(type: 'safety_info', reason: 'policy_off')), isNull);

    h.state.setCurrentUserForTesting(base);
    await pumpEventQueue(times: 40);
    expect(c.takeTarget()?.kind, SafetyNoticeTargetKind.deviceSettings);
  });

  test('uygulama-ekranlar-2: oturumsuz dokunuş, girişten sonra ev listesi gelince işlenir (boş listeyle kaybolmaz)', () async {
    await setUpRig();
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    expect(await deliver(notice(type: 'safety_info', reason: 'policy_off')), isNull, reason: 'oturum yok: bekletilir');

    h.cloud.fetchHomesGate = Completer<void>();
    unawaited(h.state.login('ayse@example.test', 'Parola123!'));
    await pumpEventQueue(times: 40);
    expect(h.state.isAuthenticated, isTrue);
    expect(c.takeTarget(), isNull, reason: 'ev listesi gelmeden karar verilmez');

    h.cloud.fetchHomesGate!.complete();
    await pumpEventQueue(times: 40);
    h.mqtt.emitStateJson(safetyStateJson());
    h.clock.advance(const Duration(seconds: 6));
    await pumpEventQueue(times: 40);
    expect(c.takeTarget()?.kind, SafetyNoticeTargetKind.deviceSettings);
  });

  test('uçuştayken oturum biterse yönlendirme iptal (nesil)', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    notices.add(notice());
    await Future<void>.delayed(Duration.zero);
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    await pumpEventQueue(times: 40);
    expect(c.takeTarget(), isNull);
  });

  test('bilgi: policy_off -> cihaz ayarları; alarm_lost kartsız -> pano', () async {
    await setUpRig();
    h.mqtt.emitStateJson(safetyStateJson());
    await pumpEventQueue();
    final policy = await deliver(notice(type: 'safety_info', reason: 'policy_off'));
    expect(policy!.kind, SafetyNoticeTargetKind.deviceSettings);
    final lost = await deliver(notice(type: 'safety_info', reason: 'alarm_lost', alarmId: '42'));
    expect(lost!.kind, SafetyNoticeTargetKind.dashboard);
  });

  test('ön plan: yönlendirme yok, afiş; başka evdeyse "Diğer evinizde alarm: <ev adı>"', () async {
    await setUpRig(homes: <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık', topic: 'h_b')]);
    final same = await deliver(notice(source: PeaceNoticeSource.foreground, kind: 'gas'));
    expect(same, isNull, reason: 'ön planda otomatik yönlendirme yapılmaz');
    expect(c.banner, isNotNull);
    expect(c.banner!.text, 'Gaz kaçağı alarmı – dokunun');
    expect(c.banner!.otherHome, isFalse);
    c.dismissBanner();
    expect(c.banner, isNull);

    await deliver(notice(source: PeaceNoticeSource.foreground, home: kHomeB, alarmId: '50'));
    expect(c.banner!.text, 'Diğer evinizde alarm: Yazlık');
    expect(c.banner!.otherHome, isTrue);

    // Afişe dokunma: aynı bildirim yönlendirmeye gider.
    unawaited(c.openBanner());
    await pumpEventQueue(times: 40);
    expect(h.state.activeHome?.id, kHomeB);
    expect(c.banner, isNull);
  });

  test('bilgi bildirimi ön planda afiş üretmez', () async {
    await setUpRig();
    await deliver(notice(type: 'safety_info', reason: 'policy_off', source: PeaceNoticeSource.foreground));
    expect(c.banner, isNull);
  });
}
