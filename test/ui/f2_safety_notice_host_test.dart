import 'dart:async';

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/safety_notice.dart';
import 'package:ev_otomasyon/services/safety_notice_controller.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/widgets/critical_alarm_card.dart';
import 'package:ev_otomasyon/ui/widgets/safety_notice_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';
import 'e1_helpers.dart';

/// Faz 2 WP-N3 (tasarım F2.C.6, F2.C.7): bildirime dokununca pano köke iner, alarm kartı görünür olur ve bir kez
/// vurgulanır; kart yoksa geçmiş + "Bu alarm kapanmış."; uygulama açıkken başka sayfada afiş.
void main() {
  const cardKey = 'card_critical_alarm_${kSafetyUid}_1';

  SafetyPushNotice notice(StateHarness h, {PeaceNoticeSource source = PeaceNoticeSource.opened, String kind = 'gas'}) =>
      SafetyPushNotice.tryParse(
        <String, dynamic>{
          'type': 'safety_alarm',
          'v': '1',
          'home_id': kHomeA,
          'device_id': 'dev-1',
          'device_uuid': kSafetyUid,
          'alarm_id': '41',
          'zone': '1',
          'kind': kind,
          'status': 'latched',
        },
        title: 'Gaz kaçağı alarmı',
        source: source,
        now: h.clock.now(),
      )!;

  Future<({StateHarness h, StreamController<SafetyPushNotice> push, GlobalKey<NavigatorState> nav})> rig(
    WidgetTester tester, {
    Size size = const Size(800, 1000),
  }) async {
    final h = (await tester.runAsync(() => e1Ready(endpoints: safetyUiEndpoints())))!;
    addTearDown(h.dispose);
    final push = StreamController<SafetyPushNotice>.broadcast();
    addTearDown(push.close);
    final controller = SafetyNoticeController(state: h.state, notices: push.stream, now: h.clock.now);
    addTearDown(controller.dispose);
    final nav = GlobalKey<NavigatorState>();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(
        value: h.state,
        child: MaterialApp(
          navigatorKey: nav,
          builder: (context, child) => ChangeNotifierProvider<SafetyNoticeController>.value(
            value: controller,
            child: SafetyNoticeHost(navigatorKey: nav, child: child ?? const SizedBox.shrink()),
          ),
          home: const Scaffold(body: ApartmentDashboard()),
        ),
      ),
    );
    await tester.pump();
    return (h: h, push: push, nav: nav);
  }

  Future<void> settleAsync(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 600)); // rota çıkış geçişi
    await tester.pump();
  }

  testWidgets('dokunuş: başka sayfa açıkken köke iner, kart görünür ve bir kez vurgulanır', (tester) async {
    final r = await rig(tester);
    r.h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    await tester.pump();
    unawaited(r.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('başka sayfa')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('başka sayfa'), findsOneWidget);

    r.push.add(notice(r.h));
    await settleAsync(tester);
    expect(find.text('başka sayfa'), findsNothing, reason: 'yığın köke indirildi');
    expect(find.byKey(const Key(cardKey)), findsOneWidget);
    expect(SafetyCardHighlight.highlightCount(cardKey), 1, reason: 'kart bir kez vurgulandı');
    expect(tester.hasRunningAnimations, isFalse, reason: 'MotionScope.off: süre 0, yanıp sönme yok');
  });

  testWidgets('kart yoksa alarm geçmişi + "Bu alarm kapanmış."', (tester) async {
    final r = await rig(tester);
    r.h.mqtt.emitStateJson(safetyStateJson());
    await tester.pump();
    r.push.add(notice(r.h));
    await settleAsync(tester);
    expect(find.byKey(const Key('page_alarm_history')), findsOneWidget);
    expect(find.byKey(const Key('alarm_history_note')), findsOneWidget);
    expect(find.text('Bu alarm kapanmış.'), findsOneWidget);
  });

  testWidgets('ön plan: başka sayfadayken afiş; dokununca karta gider', (tester) async {
    final r = await rig(tester);
    r.h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    await tester.pump();
    unawaited(r.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('başka sayfa')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    r.push.add(notice(r.h, source: PeaceNoticeSource.foreground));
    await settleAsync(tester);
    expect(find.byKey(const Key('banner_safety_notice')), findsOneWidget);
    expect(find.text('Gaz kaçağı alarmı – dokunun'), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn_safety_notice_open')));
    await settleAsync(tester);
    expect(find.text('başka sayfa'), findsNothing);
    expect(find.byKey(const Key('banner_safety_notice')), findsNothing);
    expect(find.byKey(const Key(cardKey)), findsOneWidget);
  });

  testWidgets('ön plan: panoda ve aynı evdeyken afiş yok (kart zaten görünür)', (tester) async {
    final r = await rig(tester);
    r.h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
    await tester.pump();
    r.push.add(notice(r.h, source: PeaceNoticeSource.foreground));
    await settleAsync(tester);
    expect(find.byKey(const Key('banner_safety_notice')), findsNothing);
  });
}
