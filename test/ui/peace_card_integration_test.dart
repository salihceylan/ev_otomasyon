import 'package:ev_otomasyon/services/peace_notice_controller.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/ui/widgets/peace_reminder_details.dart';
import 'package:ev_otomasyon/ui/widgets/push_status_tile.dart';
import 'package:ev_otomasyon/ui/widgets/settings/peace_notification_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/support.dart' show StateHarness;
import 'e1_helpers.dart';
import 'peace_ui_rig.dart';

/// Gece huzur bildirimi KARTI: `PeaceReminderDetails` ve `PushStatusTile` kartın gövdesinde.
/// Kart, `PeaceNoticeController` sağlayıcısı OLMADAN da (mevcut kart testleri) çökmemelidir.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const detailsKey = Key('peace_reminder_details');
  const tileKey = Key('tile_push_status');
  const tileText = Key('text_push_status');

  void v2Data(StateHarness h) {
    h.e1.peaceNotification
      ..['devices_online'] = 1
      ..['devices_total'] = 2;
  }

  testWidgets(
    'sağlayıcı YOKKEN kart çökmez; cihaz özeti görünür, push durumu çizilmez',
    (tester) async {
      await pumpReady(
        tester,
        scaffolded(const PeaceNotificationCard()),
        configure: v2Data,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('card_peace')), findsOneWidget);
      expect(find.byType(PeaceReminderDetails), findsOneWidget);
      expect(find.byKey(detailsKey), findsOneWidget);
      expect(find.text('Cihazlar: 1/2 çevrimiçi'), findsOneWidget);
      expect(find.byType(PushStatusTile), findsOneWidget);
      expect(find.byKey(tileKey), findsNothing);
      // Kartın kendi içeriği bozulmadı.
      expect(find.text('Açık • saat 23:30'), findsOneWidget);
    },
  );

  testWidgets('PushStatusTile sağlayıcısız tek başına SizedBox.shrink çizer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PushStatusTile())),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(tileKey), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('sağlayıcı VARKEN kart push durumunu gösterir', (tester) async {
    final rig = PeaceUiRig.create(startState: PushState.registered);
    addTearDown(rig.dispose);
    await pumpReady(
      tester,
      ChangeNotifierProvider<PeaceNoticeController>.value(
        value: rig.controller,
        child: scaffolded(const PeaceNotificationCard()),
      ),
      configure: v2Data,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.byKey(tileKey), findsOneWidget);
    expect(find.byKey(tileText), findsOneWidget);
    expect(find.text('Bu telefona bildirim gönderilecek.'), findsOneWidget);
    expect(find.text('Cihazlar: 1/2 çevrimiçi'), findsOneWidget);
  });

  testWidgets(
    'push kapalıyken (unsupported) kart, bildirimin telefona gönderilmediğini dürüstçe söyler',
    (tester) async {
      final rig = PeaceUiRig.create(startState: PushState.unsupported);
      addTearDown(rig.dispose);
      await pumpReady(
        tester,
        ChangeNotifierProvider<PeaceNoticeController>.value(
          value: rig.controller,
          child: scaffolded(const PeaceNotificationCard()),
        ),
        configure: v2Data,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(rig.controller.isEligible, isTrue);
      expect(rig.controller.pushState, PushState.unsupported);
      expect(find.byKey(tileKey), findsOneWidget);
      expect(
        find.text(
          'Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür.',
        ),
        findsOneWidget,
      );
      expect(find.text('Bu telefona bildirim gönderilecek.'), findsNothing);
      expect(find.text('Cihazlar: 1/2 çevrimiçi'), findsOneWidget);
    },
  );
}
