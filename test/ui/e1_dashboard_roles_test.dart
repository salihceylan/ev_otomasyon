import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Pano gezinme girdilerinin rol matrisi: görünürlük `Capabilities`'ten gelir (beyaz liste).
void main() {
  const allNav = <String>[
    'nav_menu',
    'nav_qr',
    'nav_settings',
    'nav_family',
    'nav_mode',
    'nav_service',
    'nav_doctor',
    'nav_refresh',
    'nav_profile',
    'nav_login',
  ];

  void expectNav(Set<String> visible) {
    for (final name in allNav) {
      expect(
        byKeyName(name),
        visible.contains(name) ? findsOneWidget : findsNothing,
        reason: '$name ${visible.contains(name) ? 'görünmeli' : 'gizli olmalı'}',
      );
    }
  }

  group('Pano gezinme girdileri rol matrisi', () {
    testWidgets('ev sahibi: davet/aile, ayarlar, mod, doktor ve karekod görünür', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner');
      expectNav({'nav_qr', 'nav_settings', 'nav_family', 'nav_mode', 'nav_doctor', 'nav_refresh', 'nav_profile'});
    });

    testWidgets('aile üyesi: aile yönetimi yok; ayarlar, mod ve doktor var', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'resident');
      expectNav({'nav_qr', 'nav_settings', 'nav_mode', 'nav_doctor', 'nav_refresh', 'nav_profile'});
    });

    testWidgets('geçerli misafir: mod değiştirici, doktor ve aile yönetimi YOK; ayarlar salt-okunur sayfa', (tester) async {
      await pumpReady(tester, const DashboardPage(), home: guestHome());
      expectNav({'nav_qr', 'nav_settings', 'nav_refresh', 'nav_profile'});
    });

    testWidgets('servis PIN oturumu: servis modu var; karekod ve aile yönetimi yok', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'service_session', globalRole: 'service_session');
      expectNav({'nav_settings', 'nav_mode', 'nav_service', 'nav_doctor', 'nav_refresh', 'nav_profile'});
    });

    testWidgets('kalıcı servis personeli: servis konsolu (çekmece, doktor, yenile, profil)', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'service_user', globalRole: 'service_user');
      expect(byKeyName('view_service_console'), findsOneWidget);
      expectNav({'nav_menu', 'nav_doctor', 'nav_refresh', 'nav_profile'});
    });

    testWidgets('süper kullanıcı: yönetici konsolu (çekmece, doktor, yenile, profil)', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user');
      expect(byKeyName('view_super_console'), findsOneWidget);
      expectNav({'nav_menu', 'nav_doctor', 'nav_refresh', 'nav_profile'});
    });

    testWidgets('girişsiz yerel mod: yalnızca ayarlar, mod ve giriş; profil/aile/karekod/doktor yok', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      await pumpPage(tester, h.state, const DashboardPage());
      expectNav({'nav_settings', 'nav_mode', 'nav_refresh', 'nav_login'});
    });

    testWidgets('dar ekranda ikincil girdiler "Diğer" menüsüne girer ve oradan erişilir', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800));
      // Birincil simgeler görünür.
      expect(byKeyName('nav_qr'), findsOneWidget);
      expect(byKeyName('nav_settings'), findsOneWidget);
      expect(byKeyName('nav_family'), findsOneWidget);
      expect(byKeyName('nav_profile'), findsOneWidget);
      // İkincil girdiler menüde.
      expect(byKeyName('nav_mode'), findsNothing);
      expect(byKeyName('nav_overflow'), findsOneWidget);
      await tester.tap(byKeyName('nav_overflow'));
      await tester.pumpAndSettle();
      expect(byKeyName('nav_mode'), findsOneWidget);
      expect(byKeyName('nav_doctor'), findsOneWidget);
      expect(byKeyName('nav_refresh'), findsOneWidget);
    });
  });

  group('Mod değiştirici', () {
    testWidgets('yetkili kullanıcı yerel moda geçebilir ve bilgilendirilir', (tester) async {
      final h = await pumpReady(tester, const DashboardPage(), role: 'owner');
      await tester.tap(byKeyName('nav_mode'));
      // Mod değişimi platform depolamasına (gerçek asenkron) dokunur.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.state.mode.name, 'direct');
      expect(find.text('Yerel ağ moduna geçildi'), findsOneWidget);
    });
  });

  group('Pano içeriği rol matrisi', () {
    testWidgets('misafir toplu komutlara (senaryolar, hepsini kapat) erişemez ama cihazları görür/kontrol eder',
        (tester) async {
      final endpoints = testEndpoints();
      final lit = endpoints.map((e) => e.isLight ? e.copyWith(currentState: true) : e).toList();
      await pumpReady(tester, const DashboardPage(), home: guestHome(), endpoints: lit);
      expect(byKeyName('card_scenario_leaving'), findsNothing);
      expect(byKeyName('banner_peace'), findsNothing);
      expect(byKeyName('card_relay_1'), findsOneWidget);
      expect(byKeyName('card_shutter_2'), findsOneWidget);
    });

    testWidgets('aile üyesi senaryoları ve huzur bandını görür (açık lamba varsa)', (tester) async {
      final lit = testEndpoints().map((e) => e.isLight ? e.copyWith(currentState: true) : e).toList();
      await pumpReady(tester, const DashboardPage(), role: 'resident', endpoints: lit);
      expect(byKeyName('card_scenario_leaving'), findsOneWidget);
      expect(byKeyName('banner_peace'), findsOneWidget);
      expect(find.text('3 lamba açık kaldı.'), findsOneWidget);
    });

    testWidgets('panjur çifti tek panjur kartıdır; panjur röleleri aydınlatma listesinde değildir', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner');
      expect(byKeyName('card_shutter_2'), findsOneWidget);
      expect(byKeyName('card_relay_3'), findsNothing); // panjur YUKARI rölesi
      expect(byKeyName('card_relay_4'), findsNothing); // panjur AŞAĞI rölesi
      expect(byKeyName('card_relay_1'), findsOneWidget);
      expect(byKeyName('card_relay_5'), findsOneWidget);
      expect(byKeyName('card_relay_6'), findsOneWidget);
    });
  });
}
