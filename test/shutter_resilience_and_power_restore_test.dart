import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/shutter_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Panjur kartı: **davranış** testleri. Kart 1 tabanlı panjur numarasıyla komut gönderir, bekleyen
/// komutu / çevrimdışı durumu gösterir, geri alınan komutta kendi hata mesajını çıkarmaz ve
/// yazı ölçeği 1.5'te taşmaz.
void main() {
  // `testEndpoints()`: panjur çifti 2 (röle 3 = YUKARI, röle 4 = AŞAĞI), konum %30.
  const shutter = ShutterItem(pair: 2, name: 'Salon Panjur', pos: 30);

  Map<String, dynamic> shutterState({int pos = 30, bool moving = false, int dir = 0, int target = 255}) =>
      <String, dynamic>{'pair': 2, 'pos': pos, 'moving': moving, 'dir': dir, 'target': target};

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('Panjur kartı: komutlar 1 tabanlı panjur numarasıyla gider', () {
    testWidgets('yukarı / durdur / aşağı düğmeleri `shutter: 2` komutunu REST ile gönderir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));

      await tester.tap(byKeyName('btn_shutter_up_2'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('shutter', 2));
      expect(h.e1.sentCommands.last, containsPair('cmd', 'up'));

      await tester.tap(byKeyName('btn_shutter_stop_2'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('cmd', 'stop'));

      await tester.tap(byKeyName('btn_shutter_down_2'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('cmd', 'down'));
      expect(h.e1.sentCommands.every((c) => c['shutter'] == 2), isTrue);
    });

    testWidgets('kaydırıcı bırakılınca hedef konum komutu gider ve iyimser konum görünür', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      expect(find.text('%30'), findsOneWidget);

      await tester.drag(byKeyName('slider_shutter_2'), const Offset(120, 0));
      await flush(tester);

      final command = h.e1.sentCommands.last;
      expect(command['shutter'], 2);
      expect(command['pos'], isA<int>());
      final target = command['pos'] as int;
      expect(target, greaterThan(30));
      expect(h.state.getShutterPosition(2), target, reason: 'bekleyen komutun hedefi görünür');
    });

    testWidgets('cihaz hedefi doğrulayınca "Uygulanıyor…" kalkar ve hareket görünür', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));

      await tester.tap(byKeyName('btn_shutter_up_2'));
      await flush(tester);
      expect(find.text('Uygulanıyor…'), findsOneWidget);

      h.mqtt.emitStateJson(stateJson(shutters: [shutterState(moving: true, dir: 1, target: 100)]));
      await flush(tester);

      expect(find.text('Uygulanıyor…'), findsNothing);
      expect(find.text('Açılıyor…'), findsOneWidget);
      expect(find.text('Hedef %100'), findsOneWidget);
    });

    testWidgets('çocuk kilidi yalnızca duvar anahtarlarını kilitler: uygulamadan panjur komutu yine gider', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      h.mqtt.emitStateJson(stateJson(childLock: true));
      await flush(tester);
      expect(h.state.childLockStatus, ChildLockStatus.locked);

      await tester.tap(byKeyName('btn_shutter_up_2'));
      await flush(tester);
      expect(h.e1.sentCommands.last, containsPair('cmd', 'up'));
    });

    testWidgets('REST komutu reddedilince kart eski haline döner ve ayrı hata snackbar\'ı çıkarmaz', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      h.e1.sendCommandHandler = (home, device, command) async => throw kNetworkError;

      await tester.tap(byKeyName('btn_shutter_down_2'));
      await flush(tester);

      expect(h.state.commandPipeline.isPending('shutter:2'), isFalse, reason: 'hata anında geri alınır');
      expect(find.text('Uygulanıyor…'), findsNothing);
      expect(find.byType(SnackBar), findsNothing, reason: 'hata mesajını kabuktaki tek abone gösterir');
    });
  });

  group('Panjur kartı: durum görselleri', () {
    testWidgets('gerçek konumu ve "Durdu" durumunu gösterir', (tester) async {
      await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      expect(find.text('Salon Panjur'), findsOneWidget, reason: 'yön eki ("Yukarı") ad sonundan atılır');
      expect(find.text('%30'), findsOneWidget);
      expect(find.text('Durdu'), findsOneWidget);
    });

    testWidgets('cihaz çevrimdışıysa "Çevrimdışı • son bilinen" gösterilir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      expect(find.text('Çevrimdışı • son bilinen'), findsNothing);

      h.mqtt.emitPresence(false);
      await flush(tester);
      expect(find.text('Çevrimdışı • son bilinen'), findsOneWidget);
    });

    testWidgets('çocuk kilidi açıkken kart kilit simgesiyle uyarır', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      expect(find.byIcon(Icons.lock_outline), findsNothing);

      h.mqtt.emitStateJson(stateJson(childLock: true));
      await flush(tester);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('erişim süresi dolmuş misafirin kontrolleri pasiftir (yetki Capabilities\'ten)', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const ShutterCard(shutter: shutter)),
        home: guestHome(hours: 2),
      );
      // Süre dolar: yetkiler kapanır.
      h.clock.advance(const Duration(hours: 3));
      await flush(tester);
      expect(h.state.capabilities.canControlDevices, isFalse);
      expect(tester.widget<Slider>(byKeyName('slider_shutter_2')).onChanged, isNull);
      // InkWell -> OrbButton (v2): pasif orb onTap taşımaz.
      expect(tester.widget<OrbButton>(byKeyName('btn_shutter_up_2')).onTap, isNull);
    });
  });

  group('Panjur kartı: erişilebilirlik ve yerleşim', () {
    testWidgets('kart tek bir erişilebilir başlık düğümü sunar; düğmeler etiketlidir', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));

      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Salon Panjur panjur, yüzde 30 açık'))),
        isNotNull,
      );
      expect(find.bySemanticsLabel('Salon Panjur panjuru aç'), findsOneWidget);
      expect(find.bySemanticsLabel('Salon Panjur panjuru durdur'), findsOneWidget);
      expect(find.bySemanticsLabel('Salon Panjur panjuru kapat'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('eylem düğmeleri en az 48 dp yüksekliktedir', (tester) async {
      await pumpReady(tester, scaffolded(const ShutterCard(shutter: shutter)));
      for (final name in ['btn_shutter_up_2', 'btn_shutter_stop_2', 'btn_shutter_down_2']) {
        final size = tester.getSize(byKeyName(name));
        expect(size.height, greaterThanOrEqualTo(48), reason: name);
        expect(size.width, greaterThanOrEqualTo(48), reason: name);
      }
    });

    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('320 dp genişlikte ve yazı ölçeği $scale iken taşma yok (açık tema)', (tester) async {
        await pumpReady(
          tester,
          scaffolded(const ShutterCard(shutter: ShutterItem(pair: 2, name: 'Çok Uzun Bir Odanın Büyük Salon Panjuru', pos: 30))),
          size: const Size(320, 700),
          textScale: scale,
          themeMode: ThemeMode.light,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
