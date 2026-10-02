import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/widgets/settings/child_lock_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Yerleşim: en küçük telefon (320 dp) ve yazı ölçeği 1.5'te, tipik Android telefonda (360 dp) ve
/// yazı ölçeği 2.0'da, açık ve koyu temada, konsol/kurallar/çocuk kilidi sayfaları ve üst çubuk
/// **taşmaz** (taşma `tester.takeException()` ile yakalanır).
void main() {
  /// (ekran boyutu, yazı ölçeği) çiftleri.
  const configs = <({Size phone, double scale})>[
    (phone: Size(320, 640), scale: 1.5),
    (phone: Size(360, 740), scale: 2.0),
  ];

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  ScheduledRule rule(String id, {int channel = 1, String action = 'off', int hour = 22, String? label}) =>
      ScheduledRule(
        id: id,
        homeId: kHomeA,
        channel: channel,
        channelType: 'relay',
        action: action,
        hour: hour,
        minute: 30,
        daysOfWeek: const <int>[0, 1, 2, 3, 4, 5, 6],
        enabled: true,
        label: label,
      );

  for (final cfg in configs) {
    final phone = cfg.phone;
    final scale = cfg.scale;
    for (final theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      final tag = theme == ThemeMode.light ? 'açık tema' : 'koyu tema';

      group('${phone.width.toInt()} dp, yazı ölçeği $scale ($tag)', () {
        for (final role in <String>['super_user', 'service_user']) {
          testWidgets('$role konsolu taşmaz', (tester) async {
            await pumpReady(tester, const DashboardPage(),
                role: 'owner', globalRole: role, size: phone, textScale: scale, themeMode: theme);
            await flush(tester);
            expect(tester.takeException(), isNull);
          });

          testWidgets('$role çekmecesi taşmaz', (tester) async {
            await pumpReady(tester, const DashboardPage(),
                role: 'owner', globalRole: role, size: phone, textScale: scale, themeMode: theme);
            await flush(tester);
            await tester.tap(byKeyName('nav_menu'));
            await tester.pumpAndSettle();
            expect(byKeyName('nav_drawer'), findsOneWidget);
            expect(tester.takeException(), isNull);
          });
        }

        testWidgets('ev sahibinin panosu: üst çubuk, lambalar, panjur ve senaryolar taşmaz', (tester) async {
          await pumpReady(tester, const DashboardPage(),
              role: 'owner', endpoints: litEndpoints(), size: phone, textScale: scale, themeMode: theme);
          await flush(tester);
          expect(tester.takeException(), isNull);
          // Kaydırılan içeriğin tamamı çizilir (taşma yalnızca çizimde görülür).
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
          await flush(tester);
          expect(tester.takeException(), isNull);
        });

        for (final role in <String>['owner', 'guest', 'service_user']) {
          testWidgets('ayarlar sayfası ($role) taşmaz', (tester) async {
            await pumpReady(
              tester,
              const DeviceSettingsPage(),
              role: role == 'guest' ? 'guest' : 'owner',
              globalRole: role == 'service_user' ? 'service_user' : 'user',
              home: role == 'guest' ? guestHome() : null,
              size: Size(phone.width, 8000),
              textScale: scale,
              themeMode: theme,
            );
            await flush(tester);
            expect(tester.takeException(), isNull);
          });
        }

        testWidgets('çevrimdışı pano: kurtarma bildirimi taşmaz', (tester) async {
          await pumpReady(tester, const DashboardPage(),
              role: 'owner', deviceOnline: false, size: phone, textScale: scale, themeMode: theme);
          await flush(tester);
          expect(tester.takeException(), isNull);
        });

        testWidgets('kurallar listesi ve kural ekleme diyaloğu taşmaz', (tester) async {
          await pumpReady(
            tester,
            const ScheduledRulesPage(),
            configure: (h) => h.e1.rules = <ScheduledRule>[
              rule('a', label: 'Gece yarısı bütün lambaları ve panjurları kapat'),
              rule('b', channel: 5, action: 'on', hour: 7),
            ],
            size: phone,
            textScale: scale,
            themeMode: theme,
          );
          await flush(tester);
          expect(tester.takeException(), isNull);

          await tester.tap(byKeyName('btn_add_rule'));
          await tester.pumpAndSettle();
          expect(byKeyName('dialog_rule'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('çakışma uyarılı kural diyaloğu taşmaz', (tester) async {
          await pumpReady(
            tester,
            const ScheduledRulesPage(),
            configure: (h) => h.e1.rules = <ScheduledRule>[rule('a', action: 'off'), rule('b', action: 'on')],
            size: phone,
            textScale: scale,
            themeMode: theme,
          );
          await flush(tester);
          await tester.tap(byKeyName('menu_rule_a'));
          await tester.pumpAndSettle();
          await tester.tap(byKeyName('btn_rule_edit_a'));
          await tester.pumpAndSettle();
          expect(byKeyName('banner_rule_conflict'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('çocuk kilidi bilgi ve kaldırma sayfaları taşmaz', (tester) async {
          final h = await pumpReady(tester, scaffolded(const ChildLockCard()),
              size: phone, textScale: scale, themeMode: theme);
          h.mqtt.emitStateJson(stateJson(childLock: true));
          await flush(tester);

          await tester.tap(byKeyName('btn_child_lock_info'));
          await tester.pumpAndSettle();
          expect(byKeyName('child_lock_info_sheet'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(byKeyName('btn_child_lock_info_close'));
          await tester.tap(byKeyName('btn_child_lock_info_close'));
          await tester.pumpAndSettle();

          await tester.ensureVisible(byKeyName('switch_child_lock'));
          await tester.tap(byKeyName('switch_child_lock'));
          await tester.pumpAndSettle();
          expect(byKeyName('child_lock_disable_sheet'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      });
    }
  }
}
