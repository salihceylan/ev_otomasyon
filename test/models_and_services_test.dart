import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/widgets/quick_scenario_bar.dart';
import 'package:ev_otomasyon/ui/widgets/relay_switch_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Röle kartı ve hızlı senaryolar: kartların gerçek durumla (komut hattı, cihaz bildirimi, yetki)
/// bütünleşik **davranışı**. Modellerin ayrıştırması `test/services/*` altındadır.
void main() {
  const lamp = RelayItem(id: 1, name: 'Avize', type: 0, state: false);
  const impulse = RelayItem(id: 5, name: 'Bahçe Kapısı', type: 3, state: false);

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('Röle kartı', () {
    testWidgets('dokunmak 1 tabanlı kanalla açma komutu gönderir; cihaz doğrulayana kadar "Uygulanıyor…"',
        (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      expect(find.text('KAPALI'), findsOneWidget);

      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);

      expect(h.e1.sentCommands.last, containsPair('relay', 1));
      expect(h.e1.sentCommands.last, containsPair('state', true));
      expect(find.text('Uygulanıyor…'), findsOneWidget);

      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}));
      await flush(tester);
      expect(find.text('Uygulanıyor…'), findsNothing);
      expect(find.text('AÇIK'), findsOneWidget);
    });

    testWidgets('açıkken yeniden dokunmak kapatma komutu (state:false) gönderir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);
      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}));
      await flush(tester);

      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('state', false));
    });

    testWidgets('cihaz çevrimdışıysa komut reddedilir, kart eski haline döner ve kendi hata mesajını göstermez',
        (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      h.e1.sendCommandHandler = (home, device, command) async => throw const ApiException(
            statusCode: 409,
            code: 'DEVICE_OFFLINE',
            message: 'Cihaz çevrimdışı.',
          );

      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);

      expect(h.state.commandPipeline.isPending('relay:1'), isFalse);
      expect(find.text('KAPALI'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('onay gelmezse 2,5 sn sonra değer geri alınır (komut hattı zaman aşımı)', (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      final failures = <CommandFailure>[];
      final sub = h.state.commandFailures.listen(failures.add);
      addTearDown(sub.cancel);

      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);
      expect(find.text('Uygulanıyor…'), findsOneWidget);

      h.clock.advance(const Duration(seconds: 3));
      await flush(tester);

      expect(find.text('Uygulanıyor…'), findsNothing);
      expect(find.text('KAPALI'), findsOneWidget);
      expect(failures, hasLength(1));
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    testWidgets('darbe (tetik) rölesi "Tetikle" düğmesi taşır ve açık/kapalı anahtarı göstermez', (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: impulse)));
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Tetikle'), findsOneWidget);

      await tester.tap(find.text('Tetikle'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('relay', 5));
      expect(find.text('AÇIK'), findsNothing, reason: 'darbe çıkışı kalıcı durum göstermez');
    });

    testWidgets('QA anahtarları: açma/kapama anahtarı switch_relay_<kanal>, darbe düğmesi btn_relay_impulse_<kanal> taşır ve işler',
        (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      expect(byKeyName('switch_relay_1'), findsOneWidget);
      await tester.tap(byKeyName('switch_relay_1'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('relay', 1));
      expect(h.e1.sentCommands.last, containsPair('state', true));

      final h2 = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: impulse)));
      expect(byKeyName('btn_relay_impulse_5'), findsOneWidget);
      expect(byKeyName('switch_relay_5'), findsNothing, reason: 'darbe çıkışı açık/kapalı anahtarı göstermez');
      await tester.tap(byKeyName('btn_relay_impulse_5'));
      await flush(tester);
      expect(h2.e1.sentCommands.last, containsPair('relay', 5));
    });

    testWidgets('çevrimdışı cihaz "Çevrimdışı • son bilinen" olarak işaretlenir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      h.mqtt.emitPresence(false);
      await flush(tester);
      expect(find.text('Çevrimdışı • son bilinen'), findsOneWidget);
    });

    testWidgets('anahtar ve kart en az 48 dp dokunma hedefindedir', (tester) async {
      await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      expect(tester.getSize(find.byType(Switch)).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(byKeyName('card_relay_1')).height, greaterThanOrEqualTo(48));
    });

    testWidgets('erişilebilirlik: kart tek düğümdür ve adı + durumu söyler', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReady(tester, scaffolded(const RelaySwitchCard(relay: lamp)));
      expect(find.bySemanticsLabel('Avize, kapalı'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('yazı ölçeği 1.5 ve 320 dp genişlikte (açık tema) taşma yok', (tester) async {
      await pumpReady(
        tester,
        scaffolded(const RelaySwitchCard(relay: RelayItem(id: 9, name: 'Uzun Adlı Mutfak Tezgah Altı Aydınlatma', type: 0, state: true))),
        size: const Size(320, 700),
        textScale: 1.5,
        themeMode: ThemeMode.light,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Hızlı senaryolar', () {
    testWidgets('"Evden Çıkıyorum" ışıkları kapatma ve panjurları indirme komutlarını sırayla gönderir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const QuickScenarioBar()));
      await tester.tap(byKeyName('card_scenario_leaving'));
      await flush(tester);

      final cmds = h.e1.sentCommands.map((c) => c['cmd']).toList();
      expect(cmds, <String>['all_lights_off', 'all_shutters_down']);
      expect(find.text('Evden çıkış: ışıklar ve panjurlar için komut iletildi.'), findsOneWidget);
    });

    testWidgets('ilk komut hata verirse senaryo durur; "iletildi" mesajı gösterilmez', (tester) async {
      final h = await pumpReady(tester, scaffolded(const QuickScenarioBar()));
      h.e1.sendCommandHandler = (home, device, command) async => throw kNetworkError;

      await tester.tap(byKeyName('card_scenario_night'));
      await flush(tester);

      expect(h.e1.sentCommands, hasLength(1), reason: 'ilk hatada kısmi uygulama yerine durur');
      expect(find.textContaining('komut iletildi'), findsNothing);
      expect(find.byType(SnackBar), findsNothing, reason: 'hata mesajı kabuktaki tek aboneden gelir');
    });

    testWidgets('çalışırken çift dokunuş ikinci senaryoyu başlatmaz', (tester) async {
      final h = await pumpReady(tester, scaffolded(const QuickScenarioBar()));
      final gate = Completer<CommandResult>();
      h.e1.sendCommandHandler = (home, device, command) => gate.future;

      await tester.tap(byKeyName('card_scenario_morning'));
      await tester.pump();
      await tester.tap(byKeyName('card_scenario_lights_off'));
      await tester.pump();
      expect(h.e1.sentCommands, hasLength(1));
      expect(tester.widget<InkWell>(byKeyName('card_scenario_lights_off')).onTap, isNull);

      gate.complete(deliveredResult());
      await flush(tester);
      expect(tester.widget<InkWell>(byKeyName('card_scenario_lights_off')).onTap, isNotNull);
    });

    testWidgets('misafir için senaryolar pasiftir (toplu komut yetkisi yok)', (tester) async {
      final h = await pumpReady(tester, scaffolded(const QuickScenarioBar()), home: guestHome());
      expect(h.state.capabilities.canUseGroupCommands, isFalse);
      for (final scenario in kQuickScenarios) {
        expect(tester.widget<InkWell>(byKeyName('card_scenario_${scenario.id}')).onTap, isNull, reason: scenario.id);
      }
      await tester.tap(byKeyName('card_scenario_leaving'), warnIfMissed: false);
      await flush(tester);
      expect(h.e1.sentCommands, isEmpty);
    });

    testWidgets('senaryo kartları dar ekranda ve yazı ölçeği 1.5\'te taşmaz', (tester) async {
      await pumpReady(
        tester,
        scaffolded(const QuickScenarioBar()),
        size: const Size(320, 600),
        textScale: 1.5,
        themeMode: ThemeMode.light,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
