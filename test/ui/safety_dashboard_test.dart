import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/pages/alarm_history_page.dart';
import 'package:ev_otomasyon/ui/widgets/critical_alarm_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';
import 'e1_helpers.dart';

/// WP-A3: kritik alarm kartı, eylemci kartları, tek dokunuş eylemleri (onay diyaloğu), alarm geçmişi (tasarım §5.3.3).
void main() {
  const dashboard = Scaffold(body: ApartmentDashboard());
  const tall = Size(800, 3200);
  const cardKey = 'card_critical_alarm_${kSafetyUid}_1';

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<StateHarness> ready(WidgetTester tester, {String role = 'owner', Map<String, dynamic>? state}) async {
    final h = await pumpReady(
      tester,
      dashboard,
      role: role,
      home: role == 'guest' ? guestHome(hours: 5) : null,
      endpoints: safetyUiEndpoints(),
      size: tall,
    );
    if (state != null) {
      h.mqtt.emitStateJson(state);
      await flush(tester);
    }
    return h;
  }

  Future<void> confirmDialog(WidgetTester tester, {bool accept = true}) async {
    await tester.pump();
    expect(byKeyName(accept ? 'btn_safety_confirm' : 'btn_safety_cancel'), findsOneWidget, reason: 'onay diyaloğu açılmalı');
    await tester.tap(byKeyName(accept ? 'btn_safety_confirm' : 'btn_safety_cancel'));
    await tester.pump();
    await tester.pump();
  }

  Finder inCard(String key, Finder matching) => find.descendant(of: byKeyName(key), matching: matching);

  group('kritik alarm kartı', () {
    testWidgets('alarm yokken ya da eski (v:2) panoda kart ve güvenlik bölümü yok; lamba kartları aynı', (tester) async {
      final h = await ready(tester);
      h.mqtt.emitStateJson(stateJson(relays: const <int, bool>{1: true}));
      await flush(tester);
      expect(byKeyName('panel_safety_alerts'), findsOneWidget);
      expect(find.byKey(const Key(cardKey)), findsNothing);
      expect(byKeyName('section_safety'), findsNothing, reason: 'v:2: güvenlik bölümü gizli');

      h.mqtt.emitStateJson(safetyStateJson());
      await flush(tester);
      expect(find.byKey(const Key(cardKey)), findsNothing, reason: 'bölge normal');
      expect(byKeyName('section_safety'), findsOneWidget);
    });

    testWidgets('kilitli alarm: pano ÜSTÜNDE (hero\'dan önce), başlık + metinli durum (renk tek ipucu değil)', (tester) async {
      await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true, valvePos: 'closed', valveFb: true));
      final card = find.byKey(const Key(cardKey));
      expect(card, findsOneWidget);
      expect(inCard(cardKey, find.textContaining('Su baskını')), findsWidgets);
      expect(inCard(cardKey, find.text('ALARM')), findsOneWidget, reason: 'durum metinle de yazılır');
      expect(inCard(cardKey, find.byIcon(Icons.warning_rounded)), findsWidgets, reason: 'durum simgeyle de verilir');
      expect(inCard(cardKey, find.textContaining('Ana Su Vanası: Kapalı (doğrulandı)')), findsOneWidget);
      expect(
        tester.getTopLeft(card).dy,
        lessThan(tester.getTopLeft(byKeyName('home_hero')).dy),
        reason: 'kritik alarm panonun en üstünde',
      );
      // Ekran okuyucu: başlık canlı bölgedir.
      final semantics = tester.getSemantics(inCard(cardKey, find.byKey(const Key('critical_alarm_title_1'))));
      expect(semantics.flagsCollection.isLiveRegion, isTrue);
    });

    testWidgets('geri bildirimsiz kapatma ve VALVE_FAULT metinleri', (tester) async {
      final h = await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true, valvePos: 'cmd_closed'));
      expect(inCard(cardKey, find.textContaining('Kapatıldı (geri bildirim yok)')), findsOneWidget);

      h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'fault', sensorActive: true, valvePos: 'closing', valveFb: false));
      await flush(tester);
      expect(inCard(cardKey, find.text('VANA ARIZASI')), findsOneWidget);
      expect(inCard(cardKey, find.textContaining('Vana kapanmadı! Ana vanayı elle kapatın')), findsOneWidget);
    });

    testWidgets('ıslakken "Sesi Sustur": onay diyaloğu (vazgeç -> komut yok; onay -> alarm_ack)', (tester) async {
      final h = await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true, valvePos: 'closed'));
      h.cloud.alarmRecords = const <AlarmRecord>[
        AlarmRecord(id: '41', zone: 1, aid: '9f3a11c0-3', kind: 'water', status: 'latched', deviceUuid: kSafetyUid),
      ];
      final ack = byKeyName('btn_alarm_ack_1');
      expect(inCard(cardKey, find.text('Sesi Sustur')), findsOneWidget);

      await tester.tap(ack);
      await confirmDialog(tester, accept: false);
      expect(h.cloud.ackCalls, isEmpty, reason: 'vazgeçildi');

      await tester.tap(ack);
      await confirmDialog(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.cloud.ackCalls.single.alarmId, '41');
      expect(inCard(cardKey, find.text('Uygulanıyor…')), findsOneWidget, reason: 'onay iyimser değil: bekleniyor göstergesi');

      // Pano susturdu (hâlâ ıslak): düğme kalkar, açıklama kalır.
      h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true, valvePos: 'closed', silenced: true));
      await flush(tester);
      expect(inCard(cardKey, find.text('SUSTURULDU')), findsOneWidget);
      expect(ack, findsNothing);
      expect(inCard(cardKey, find.textContaining('kuruyunca')), findsOneWidget);
    });

    testWidgets('kuruyken "Alarmı Onayla"', (tester) async {
      await ready(tester, state: safetyStateJson(zoneSt: 'latched', silenced: true, valvePos: 'closed'));
      expect(inCard(cardKey, find.text('Alarmı Onayla')), findsOneWidget);
    });

    testWidgets('"Vanayı Kapat": yalnız açık/belirsiz vanada; onaydan sonra anında "kapatıldı" (iyimser)', (tester) async {
      final h = await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true));
      final close = byKeyName('btn_alarm_close_valve_1');
      expect(close, findsOneWidget);
      await tester.tap(close);
      await confirmDialog(tester);
      expect(h.cloud.actuatorCalls.single.actuatorId, 'a1');
      expect(h.cloud.actuatorCalls.single.to, 'closed');
      expect(inCard(cardKey, find.textContaining('Kapatıldı (geri bildirim yok)')), findsOneWidget);
      expect(close, findsNothing, reason: 'vana kapatıldı: düğme kalkar');
    });

    testWidgets('misafir: onay düğmesi YOK (açıklama var), vanayı kapatabilir', (tester) async {
      await ready(tester, role: 'guest', state: safetyStateJson(zoneSt: 'latched', sensorActive: true));
      expect(byKeyName('btn_alarm_ack_1'), findsNothing);
      expect(inCard(cardKey, find.textContaining('ev sahibi')), findsOneWidget);
      expect(byKeyName('btn_alarm_close_valve_1'), findsOneWidget);
    });

    testWidgets('güvenli kip uyarısı', (tester) async {
      await ready(tester, state: safetyStateJson(mode: 'safe', valvePos: 'closed'));
      expect(byKeyName('card_safety_safe_mode'), findsOneWidget);
      expect(find.textContaining('güvenli kipte'), findsWidgets);
    });

    testWidgets('kilit kalkınca "Su kesik" + Vanayı Aç (onaylı, iyimser değil); misafirde açma gizli', (tester) async {
      final h = await ready(tester, state: safetyStateJson(valvePos: 'closed', valveFb: true));
      expect(find.byKey(const Key(cardKey)), findsNothing);
      expect(byKeyName('card_water_cut_a1'), findsOneWidget);
      expect(inCard('card_water_cut_a1', find.textContaining('Su kesik')), findsOneWidget);
      expect(byKeyName('card_water_cut_a3'), findsNothing, reason: 'gaz vanası su kesik kartı üretmez');

      await tester.tap(byKeyName('btn_water_open_a1'));
      await confirmDialog(tester);
      expect(h.cloud.actuatorCalls.single.to, 'open');
      expect(inCard('card_water_cut_a1', find.text('Açılıyor…')), findsOneWidget, reason: 'açma iyimser değil');
    });

    testWidgets('sensör ıslak/bağlantı yokken "Vanayı Aç" devre dışı ve gerekçe yazılı', (tester) async {
      final h = await ready(tester, state: safetyStateJson(valvePos: 'closed', bridgeOk: false));
      final open = tester.widget<ButtonStyleButton>(byKeyName('btn_water_open_a1'));
      expect(open.onPressed, isNull);
      expect(inCard('card_water_cut_a1', find.textContaining('yanıt vermiyor')), findsOneWidget);
      await tester.tap(byKeyName('btn_water_open_a1'), warnIfMissed: false);
      await tester.pump();
      expect(h.cloud.actuatorCalls, isEmpty);
    });

    testWidgets('misafir: "Su kesik" kartında açma düğmesi yok', (tester) async {
      await ready(tester, role: 'guest', state: safetyStateJson(valvePos: 'closed'));
      expect(byKeyName('card_water_cut_a1'), findsOneWidget);
      expect(byKeyName('btn_water_open_a1'), findsNothing);
    });

    testWidgets('LAN (doğrudan) kipte de aynı kart görünür (K5)', (tester) async {
      final h = await ready(tester);
      h.state
        ..setModeForTesting(AppMode.direct)
        ..setStatusForTesting(DeviceStatus.fromJson(safetyStateJson(zoneSt: 'latched', sensorActive: true)));
      await flush(tester);
      expect(find.byKey(const Key(cardKey)), findsOneWidget);
      expect(byKeyName('section_safety'), findsOneWidget);
    });

    testWidgets('Hareket v3: MotionScope.off -> tek karede tam görünür, süren animasyon yok', (tester) async {
      await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true));
      expect(tester.hasRunningAnimations, isFalse);
      final opacities = tester.widgetList<FadeTransition>(
        find.ancestor(of: find.byKey(const Key(cardKey)), matching: find.byType(FadeTransition)),
      );
      for (final fade in opacities) {
        expect(fade.opacity.value, 1.0);
      }
    });

    testWidgets('Hareket v3: tam kipte yalnız tek seferlik giriş (sonsuz döngü yok)', (tester) async {
      final h = (await tester.runAsync(() => e1Ready(endpoints: safetyUiEndpoints())))!;
      addTearDown(h.dispose);
      // Yalnız uyarı paneli (panonun kendi ambient saati/hero animasyonları bu testin konusu değil).
      await pumpPage(
        tester,
        h.state,
        // Sabit ambient saat: etkin orb'un ortam nabzı (tasarımın bilinçli ambient katmanı) donar; geriye yalnız giriş kalır.
        MotionScope(
          mode: MotionMode.full,
          clock: AmbientClock.fixed(0.4),
          child: const Scaffold(body: SingleChildScrollView(child: SafetyAlertsPanel())),
        ),
        size: tall,
      );
      h.mqtt.emitStateJson(safetyStateJson(zoneSt: 'latched', sensorActive: true));
      await flush(tester);
      await tester.pumpAndSettle(); // sonsuz animasyon olsaydı zaman aşımına uğrardı
      expect(find.byKey(const Key(cardKey)), findsOneWidget);
    });
  });

  group('Güvenlik ve Eylemciler bölümü', () {
    testWidgets('panjurlardan önce; vana, siren, gaz vanası kartları ve sensör hapları', (tester) async {
      await ready(tester, state: safetyStateJson(bridgeOk: false, sensorActive: true));
      expect(byKeyName('section_safety'), findsOneWidget);
      expect(
        tester.getTopLeft(byKeyName('section_safety')).dy,
        lessThan(tester.getTopLeft(find.text('Panjurlar')).dy),
      );
      for (final id in <String>['a1', 'a2', 'a3']) {
        expect(byKeyName('card_actuator_$id'), findsOneWidget);
      }
      expect(inCard('card_actuator_a1', find.text('Ana Su Vanası')), findsOneWidget);
      expect(inCard('card_actuator_a3', find.textContaining('yalnız yerinde')), findsOneWidget);
      expect(byKeyName('btn_actuator_open_a3'), findsNothing, reason: 'gaz vanası uygulamadan açılmaz');
      expect(inCard('pill_sensor_d3', find.text('Islak')), findsOneWidget);
      expect(inCard('pill_sensor_b1', find.text('Bağlantı yok')), findsOneWidget);
      // Eylemci lamba kartına düşmez.
      expect(byKeyName('card_relay_7'), findsNothing);
    });

    testWidgets('vana kartı: Kapat onaylı; kapalıyken Aç; siren anahtarı', (tester) async {
      final h = await ready(tester, state: safetyStateJson(sirenOn: true));
      await tester.ensureVisible(byKeyName('btn_actuator_close_a1'));
      await tester.tap(byKeyName('btn_actuator_close_a1'));
      await confirmDialog(tester);
      expect(h.cloud.actuatorCalls.last.to, 'closed');

      h.mqtt.emitStateJson(safetyStateJson(valvePos: 'closed', valveFb: true, sirenOn: true));
      await flush(tester);
      expect(byKeyName('btn_actuator_open_a1'), findsOneWidget);
      expect(inCard('card_actuator_a1', find.text('Kapalı (doğrulandı)')), findsOneWidget);

      // Siren açık: anahtarla kapatılır (güvenli yön, diyalogsuz).
      await tester.ensureVisible(byKeyName('switch_actuator_a2'));
      await tester.tap(byKeyName('switch_actuator_a2'));
      await tester.pump();
      expect(h.cloud.actuatorCalls.last.actuatorId, 'a2');
      expect(h.cloud.actuatorCalls.last.to, 'off');
    });

    testWidgets('misafir: vana açma ve siren açma gizli; kapatma serbest', (tester) async {
      await ready(tester, role: 'guest', state: safetyStateJson(valvePos: 'closed'));
      expect(byKeyName('btn_actuator_open_a1'), findsNothing);
      expect(byKeyName('switch_actuator_a2'), findsNothing, reason: 'siren kapalı ve misafir açamaz');
      expect(byKeyName('btn_alarm_history'), findsNothing, reason: 'misafir alarm geçmişini görmez');
    });

    testWidgets('oda filtresi: eylemci kendi odasında görünür, başka odada gizlenir', (tester) async {
      await ready(tester, state: safetyStateJson());
      await tester.tap(byKeyName('chip_room_mutfak'));
      await tester.pump();
      expect(byKeyName('card_actuator_a1'), findsOneWidget);
      await tester.tap(byKeyName('chip_room_all'));
      await tester.pump();
      await tester.tap(byKeyName('chip_room_salon'));
      await tester.pump();
      expect(byKeyName('card_actuator_a1'), findsNothing);
    });
  });

  group('alarm geçmişi', () {
    testWidgets('bulut: sunucu kayıtları (açık + kapanmış), durum metinli', (tester) async {
      final h = await ready(tester, state: safetyStateJson());
      h.cloud.alarmRecords = <AlarmRecord>[
        AlarmRecord(id: '41', zone: 1, aid: '9f3a11c0-3', kind: 'water', status: 'cleared', raisedAt: kTestNow.subtract(const Duration(hours: 3))),
        AlarmRecord(id: '42', zone: 2, aid: '9f3a11c0-4', kind: 'gas', status: 'latched', raisedAt: kTestNow.subtract(const Duration(minutes: 5))),
      ];
      await tester.ensureVisible(byKeyName('btn_alarm_history'));
      await tester.tap(byKeyName('btn_alarm_history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKeyName('page_alarm_history'), findsOneWidget);
      expect(h.cloud.calls, contains('alarms:$kHomeA'));
      expect(inCard('row_alarm_41', find.textContaining('Su baskını')), findsOneWidget);
      expect(inCard('row_alarm_41', find.text('Kapandı')), findsOneWidget);
      expect(inCard('row_alarm_42', find.textContaining('Gaz kaçağı')), findsOneWidget);
      expect(inCard('row_alarm_42', find.text('Sürüyor')), findsOneWidget);
    });

    testWidgets('boş liste ve hata + yeniden dene', (tester) async {
      final h = (await tester.runAsync(() => e1Ready(endpoints: safetyUiEndpoints())))!;
      addTearDown(h.dispose);
      h.cloud.alarmsError = kNetworkError;
      await pumpPage(tester, h.state, const AlarmHistoryPage());
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKeyName('alarm_history_error'), findsOneWidget);
      h.cloud.alarmsError = null;
      await tester.tap(find.descendant(of: byKeyName('alarm_history_error'), matching: byKeyName('btn_retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKeyName('alarm_history_empty'), findsOneWidget);
    });

    testWidgets('LAN: panonun son olayları (/api/events)', (tester) async {
      final h = (await tester.runAsync(() => e1Ready(endpoints: safetyUiEndpoints())))!;
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/events', (r) => jsonResponse(<String, dynamic>{
            'events': <Map<String, dynamic>>[
              <String, dynamic>{'eid': '9f3a11c0-3', 'type': 'alarm_raised', 'zone': 1, 'kind': 'water', 'at_up': 3000},
              <String, dynamic>{'eid': '9f3a11c0-4', 'type': 'alarm_cleared', 'zone': 1, 'kind': 'water', 'at': 1791273600},
            ],
          }));
      h.state
        ..setModeForTesting(AppMode.direct)
        ..setSelectedDeviceForTesting(uuid: kSafetyUid, ip: '192.168.1.30');
      h.direct.localKey = 'test-local-key-1234';
      await pumpPage(tester, h.state, const AlarmHistoryPage());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(inCard('row_event_9f3a11c0-3', find.textContaining('Su baskını')), findsOneWidget);
      expect(inCard('row_event_9f3a11c0-4', find.textContaining('Alarm kalktı')), findsOneWidget);
    });
  });
}
