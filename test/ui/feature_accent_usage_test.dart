import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/service_tool_cards.dart';
import 'package:ev_otomasyon/ui/theme/feature_accent.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/glass_pill.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/super_user_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e1_helpers.dart';

/// Özellik vurgu haritasının ÇAĞRI YERLERİNDE kullanıldığını kilitler (WP-V9 C): çekmece, konsol kutucukları/satırları, servis
/// araç kartları ve ayar eylem kartları AYNI özelliği AYNI aileyle gösterir; her listede iki farklı özellik farklı aile taşır.
void main() {
  /// [key]'li bileşenin içindeki ilk [OrbIconBadge]'in ailesi.
  AccentFamily orbOf(WidgetTester tester, String key) {
    final orb = find.descendant(of: byKeyName(key), matching: find.byType(OrbIconBadge));
    expect(orb, findsWidgets, reason: '$key içinde orb yok');
    return tester.widget<OrbIconBadge>(orb.first).family;
  }

  /// Anahtar -> beklenen özellik; her satırın orb ailesi haritadan gelir ve liste içinde benzersizdir.
  void expectMapped(WidgetTester tester, Map<String, AppFeature> rows, {required String reason}) {
    final seen = <AccentFamily, String>{};
    final byFeature = <AppFeature, AccentFamily>{};
    for (final entry in rows.entries) {
      final family = orbOf(tester, entry.key);
      expect(family, featureFamily(entry.value), reason: '$reason: ${entry.key} -> ${entry.value.name}');
      // Aynı özellik (ör. sayaç + eylem) aynı aile; farklı özellik farklı aile.
      final previous = byFeature[entry.value];
      if (previous != null) {
        expect(previous, family, reason: '$reason: aynı özellik her yerde aynı aile (${entry.value.name})');
      } else {
        byFeature[entry.value] = family;
        final clash = seen[family];
        expect(clash, isNull, reason: '$reason: ${entry.key} ile $clash AYNI aileyi paylaşıyor (${family.name})');
        seen[family] = entry.key;
      }
    }
  }

  Future<void> openDrawer(WidgetTester tester) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
  }

  const drawerHost = Scaffold(drawer: SuperUserDrawer(), body: SizedBox());

  group('çekmece', () {
    testWidgets('süper yönetici: her satır kendi özelliğinin ailesi; liste içinde benzersiz; başlık rozeti konsol kimliği', (tester) async {
      await pumpReady(tester, drawerHost, role: 'owner', globalRole: 'super_user', size: const Size(500, 1100));
      await openDrawer(tester);
      expectMapped(
        tester,
        const {
          'nav_drawer_console': AppFeature.superConsole,
          'nav_drawer_inventory': AppFeature.inventory,
          'nav_drawer_service_managers': AppFeature.management,
          'nav_drawer_subscribers': AppFeature.subscribers,
          'nav_drawer_doctor': AppFeature.doctor,
          'nav_drawer_emergency_reset': AppFeature.emergencyReset,
        },
        reason: 'süper çekmece',
      );
      final pill = tester.widget<GlassPill>(find.descendant(of: byKeyName('nav_drawer'), matching: find.byType(GlassPill)));
      expect(pill.color, AppFeature.superConsole.accentFamily.base, reason: 'başlık rozeti = konsol satırı = konsol başlık kartı');
    });

    testWidgets('yetkili servis: her satır kendi özelliğinin ailesi; liste içinde benzersiz', (tester) async {
      await pumpReady(tester, drawerHost, role: 'owner', globalRole: 'service_user', size: const Size(500, 1100));
      await openDrawer(tester);
      expectMapped(
        tester,
        const {
          'nav_drawer_console': AppFeature.serviceConsole,
          'nav_drawer_subscribers': AppFeature.subscribers,
          'nav_drawer_commissioning': AppFeature.commissioning,
          'nav_drawer_replace_board': AppFeature.boardReplace,
          'nav_drawer_wifi_recovery': AppFeature.wifiRecovery,
          'nav_drawer_emergency_reset': AppFeature.emergencyReset,
        },
        reason: 'servis çekmecesi',
      );
    });
  });

  group('konsollar', () {
    testWidgets('süper konsol: sayaç kutucukları + hızlı işlemler haritadan; aynı özellik sayaçta ve eylemde AYNI aile', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(900, 2000));
      await tester.pump(const Duration(milliseconds: 100));
      expectMapped(
        tester,
        const {
          'card_metric_service_managers': AppFeature.management,
          'card_metric_devices': AppFeature.inventory,
          'card_metric_commissioned': AppFeature.subscribers,
          'card_action_inventory': AppFeature.inventory,
          'card_action_service_managers': AppFeature.management,
          'card_action_subscribers': AppFeature.subscribers,
          'card_action_doctor': AppFeature.doctor,
        },
        reason: 'süper konsol',
      );
      expect(orbOf(tester, 'card_console_header'), AppFeature.superConsole.accentFamily, reason: 'konsol kimliği');
    });

    testWidgets('servis konsolu: sayaçlar + görev satırları haritadan; liste içinde benzersiz', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'service_user', globalRole: 'service_user', size: const Size(900, 2000));
      await tester.pump(const Duration(milliseconds: 100));
      expectMapped(
        tester,
        const {
          'card_metric_devices': AppFeature.inventory,
          'card_metric_commissioned': AppFeature.subscribers,
          'card_action_commissioning': AppFeature.commissioning,
          'card_action_subscribers': AppFeature.subscribers,
          'card_action_replace_board': AppFeature.boardReplace,
          'card_action_wifi_recovery': AppFeature.wifiRecovery,
          'card_action_emergency_reset': AppFeature.emergencyReset,
        },
        reason: 'servis konsolu',
      );
      expect(orbOf(tester, 'card_console_header'), AppFeature.serviceConsole.accentFamily);
    });
  });

  group('servis araç kartları', () {
    testWidgets('beş araç + kurulum kısayolu: haritadan, hepsi FARKLI aile (eskiden aboneler/hesaplar/sihirbaz ortak sky idi)', (tester) async {
      await pumpReady(
        tester,
        const SingleChildScrollView(child: ServiceToolCards(includeSetup: true)),
        role: 'owner',
        globalRole: 'service_user',
        size: const Size(500, 1400),
      );
      expectMapped(
        tester,
        const {
          'card_tool_setup': AppFeature.commissioning,
          'card_tool_subscribers': AppFeature.subscribers,
          'card_tool_inventory': AppFeature.inventory,
          'card_tool_replace': AppFeature.boardReplace,
          'card_tool_doctor': AppFeature.doctor,
        },
        reason: 'yönetim sayfası araçlar sekmesi',
      );
    });

    testWidgets('servis paneli araçları: hesaplar kartı da haritadan ve diğerlerinden farklı', (tester) async {
      await pumpReady(
        tester,
        const SingleChildScrollView(child: ServiceToolCards()),
        role: 'owner',
        globalRole: 'service_user',
        size: const Size(500, 1400),
      );
      expectMapped(
        tester,
        const {
          'card_tool_subscribers': AppFeature.subscribers,
          'card_tool_inventory': AppFeature.inventory,
          'card_tool_replace': AppFeature.boardReplace,
          'card_tool_doctor': AppFeature.doctor,
          'card_tool_management': AppFeature.management,
        },
        reason: 'servis paneli araçları',
      );
    });
  });

  group('ayarlar eylem kartları', () {
    testWidgets("'Cihaz' bölümü: doktor emerald, Wi-Fi amber, pano değişimi violet, cihaz adresi sky, telemetri yoksa atlanır; hepsi farklı", (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: const Size(500, 3000));
      await tester.pump(const Duration(milliseconds: 100));
      expectMapped(
        tester,
        const {
          'card_system_doctor': AppFeature.doctor,
          'card_wifi_recovery': AppFeature.wifiRecovery,
          'card_replace_board': AppFeature.boardReplace,
          'card_host': AppFeature.deviceHost,
        },
        reason: 'ayarlar Cihaz bölümü',
      );
    });

    testWidgets("servis PIN'i amber (eskiden violet: pano değişimiyle karışıyordu); gece huzuru violet; kurallar cyan", (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: const Size(500, 3000));
      await tester.pump(const Duration(milliseconds: 100));
      expect(orbOf(tester, 'card_service_pin'), AppFeature.servicePin.accentFamily);
      expect(orbOf(tester, 'card_service_pin'), isNot(orbOf(tester, 'card_replace_board')), reason: 'aynı sayfada artık ayırt edilir');
      expect(orbOf(tester, 'card_peace'), AppFeature.nightPeace.accentFamily);
      expect(orbOf(tester, 'card_rules'), AppFeature.rules.accentFamily);
    });
  });
}
