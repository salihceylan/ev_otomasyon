import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:ev_otomasyon/services/safety_notice_controller.dart';
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

  test('etkin ev farklı -> o eve geçilir, sonra hedef çözülür', () async {
    await setUpRig(homes: <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık', topic: 'h_b')]);
    h.cloud.endpoints[kHomeB] = safetyUiEndpoints();
    expect(h.state.activeHome?.id, kHomeA);
    final target = await deliver(notice(home: kHomeB));
    expect(h.state.activeHome?.id, kHomeB);
    expect(target, isNotNull);
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
