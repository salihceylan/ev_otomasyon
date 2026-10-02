import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/widgets/super_user_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Yetkili servis / süper kullanıcı: konsol ve çekmece **rol izolasyonu**. Girdiler `Capabilities`'ten
/// türetilir; servis personeli süper kullanıcı araçlarını, süper kullanıcı saha araçlarını görmez.
void main() {
  Future<void> openDrawer(WidgetTester tester) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
  }

  /// Yalnızca çekmeceyi içeren iskelet (konsoldaki yükleme göstergeleri `pumpAndSettle`'ı engellemesin).
  Widget drawerHost() => const Scaffold(drawer: SuperUserDrawer(), body: SizedBox());

  Future<StateHarness> pumpDrawer(WidgetTester tester, {required String globalRole, String? name, String? email}) async {
    final h = await pumpReady(tester, drawerHost(), role: 'owner', globalRole: globalRole);
    if (name != null || email != null) {
      h.state.setCurrentUserForTesting(
        UserModel(id: 'u1', email: email ?? '', fullName: name ?? '', role: globalRole),
      );
      await tester.pump();
    }
    await openDrawer(tester);
    return h;
  }

  group('Yetkili servis konsolu', () {
    testWidgets('servis personeli saha konsolunu görür; daire kontrolleri ve karşılama kartı görünmez', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'service_user', globalRole: 'service_user');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Yetkili Servis Konsolu'), findsOneWidget);
      expect(find.text('YETKİLİ SERVİS'), findsOneWidget);
      expect(find.text('Ayşe Yılmaz'), findsWidgets);
      expect(byKeyName('view_service_console'), findsOneWidget);
      expect(byKeyName('card_action_commissioning'), findsOneWidget);
      expect(byKeyName('card_action_replace_board'), findsOneWidget);
      expect(byKeyName('card_action_wifi_recovery'), findsOneWidget);
      expect(byKeyName('card_action_emergency_reset'), findsOneWidget);

      // Daire sakini ekranı ve süper kullanıcı araçları KESİNLİKLE görünmez.
      expect(byKeyName('view_apartment'), findsNothing);
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
      expect(byKeyName('card_relay_1'), findsNothing);
      expect(byKeyName('card_action_inventory'), findsNothing);
      expect(byKeyName('card_action_service_managers'), findsNothing);
      expect(find.text('Tüm Paneli Aç'), findsNothing);
    });

    testWidgets('süper kullanıcı yönetici konsolunu görür; saha (servis modu) görevleri görünmez', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Süper Yönetici Konsolu'), findsOneWidget);
      expect(byKeyName('card_action_inventory'), findsOneWidget);
      expect(byKeyName('card_action_service_managers'), findsOneWidget);
      expect(byKeyName('card_action_commissioning'), findsNothing);
      expect(byKeyName('view_apartment'), findsNothing);
    });
  });

  group('Çekmece (SuperUserDrawer) girdileri rolden değil Capabilities\'ten gelir', () {
    testWidgets('servis personeli: servis modu, aboneler, pano değişimi, Wi-Fi kurtarma ve acil sıfırlama', (tester) async {
      await pumpDrawer(tester, globalRole: 'service_user');

      expect(find.text('YETKİLİ SERVİS KONSOLU'), findsOneWidget);
      expect(find.text('Servis Konsolu'), findsOneWidget);
      for (final key in [
        'nav_drawer_commissioning',
        'nav_drawer_subscribers',
        'nav_drawer_replace_board',
        'nav_drawer_wifi_recovery',
        'nav_drawer_emergency_reset',
        'nav_drawer_theme',
        'nav_drawer_logout',
      ]) {
        expect(byKeyName(key), findsOneWidget, reason: key);
      }
      // Süper kullanıcı menüleri servis personelinde OLMAZ.
      for (final key in ['nav_drawer_inventory', 'nav_drawer_service_managers', 'nav_drawer_doctor']) {
        expect(byKeyName(key), findsNothing, reason: key);
      }
    });

    testWidgets('süper kullanıcı: envanter, servis sorumluları, aboneler ve sistem doktoru; saha araçları yok', (tester) async {
      await pumpDrawer(tester, globalRole: 'super_user');

      expect(find.text('SÜPER YÖNETİCİ KONSOLU'), findsOneWidget);
      for (final key in [
        'nav_drawer_inventory',
        'nav_drawer_service_managers',
        'nav_drawer_subscribers',
        'nav_drawer_doctor',
        'nav_drawer_emergency_reset',
      ]) {
        expect(byKeyName(key), findsOneWidget, reason: key);
      }
      for (final key in ['nav_drawer_commissioning', 'nav_drawer_replace_board', 'nav_drawer_wifi_recovery']) {
        expect(byKeyName(key), findsNothing, reason: key);
      }
    });

    testWidgets('adı/e-postası olmayan kullanıcıda sabit yedek e-posta gösterilmez', (tester) async {
      await pumpDrawer(tester, globalRole: 'service_user', name: '', email: '');
      expect(find.textContaining('servis@gudeteknoloji'), findsNothing);
      expect(find.text('Yetkili Servis Sorumlusu'), findsOneWidget);
    });

    testWidgets('gerçek ad ve e-posta başlıkta gösterilir', (tester) async {
      await pumpDrawer(tester, globalRole: 'service_user', name: 'Murat Sorumlu', email: 'murat@servis.test');
      expect(find.text('Murat Sorumlu'), findsOneWidget);
      expect(find.text('murat@servis.test'), findsOneWidget);
    });

    testWidgets('tema satırı temayı değiştirir', (tester) async {
      final h = await pumpDrawer(tester, globalRole: 'service_user');
      expect(h.state.themeMode, ThemeMode.dark);
      await tester.tap(byKeyName('nav_drawer_theme'));
      await tester.pump();
      expect(h.state.themeMode, ThemeMode.light);
    });

    testWidgets('çıkış onay ister; vazgeçilirse oturum sürer, onaylanırsa kapanır', (tester) async {
      final h = await pumpDrawer(tester, globalRole: 'service_user');
      await tester.tap(byKeyName('nav_drawer_logout'));
      await tester.pumpAndSettle();
      expect(byKeyName('btn_logout_confirm'), findsOneWidget);

      await tester.tap(byKeyName('btn_logout_cancel'));
      await tester.pumpAndSettle();
      expect(h.state.authStatus, AuthStatus.authenticated);

      await tester.tap(byKeyName('nav_drawer_logout'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_logout_confirm'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.state.authStatus, AuthStatus.unauthenticated);
    });

    testWidgets('çekmece dar ekranda ve yazı ölçeği 1.5\'te taşmaz (açık tema)', (tester) async {
      await pumpReady(
        tester,
        drawerHost(),
        globalRole: 'service_user',
        size: const Size(320, 640),
        textScale: 1.5,
        themeMode: ThemeMode.light,
      );
      await openDrawer(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
