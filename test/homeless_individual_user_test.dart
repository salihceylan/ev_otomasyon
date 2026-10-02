import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Dairesi olmayan bireysel kullanıcı: yalnızca "eve katıl" yolları; eve katıldıktan sonra normal
/// pano açılır. "Daire yok" yalnızca **başarılı boş** ev yanıtında söylenir (hata/yükleme "daire yok"
/// değildir).
void main() {
  Future<StateHarness> pumpHomeless(WidgetTester tester, {Object? homesError}) async {
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'test@ahbu.test', fullName: 'Test Kullanıcı', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    h.cloud.fetchHomesError = homesError;
    h.cloud.homes = <HomeModel>[];
    addTearDown(h.dispose);
    await tester.runAsync(() => h.state.fetchHomes());
    await pumpPage(tester, h.state, const DashboardPage());
    return h;
  }

  testWidgets('daire yoksa yalnızca katılma yolları görünür; mod, ayar, aile ve doktor girdileri gizlidir', (tester) async {
    await pumpHomeless(tester);

    expect(find.text('Kod ile Bir Eve Katıl'), findsOneWidget);
    expect(find.text('Karekod Tara (Katıl / Cihaz Eşle)'), findsOneWidget);
    expect(find.text('Henüz kayıtlı bir daireniz yok'), findsOneWidget);
    expect(find.text('Hoş Geldiniz, Test!'), findsOneWidget);

    // Daire kontrolü gerektiren AppBar girdileri yok; profil ve karekod var.
    for (final key in ['nav_mode', 'nav_settings', 'nav_family', 'nav_doctor', 'nav_service']) {
      expect(byKeyName(key), findsNothing, reason: key);
    }
    expect(byKeyName('nav_profile'), findsOneWidget);
    expect(byKeyName('nav_qr'), findsOneWidget);
    expect(byKeyName('card_relay_1'), findsNothing);
    expect(byKeyName('card_scenario_leaving'), findsNothing);
  });

  testWidgets('"Kod ile Bir Eve Katıl" katılma diyaloğunu açar', (tester) async {
    await pumpHomeless(tester);
    await tester.tap(byKeyName('btn_join_code'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinHomeDialog), findsOneWidget);
  });

  testWidgets('ev listesi alınamadıysa "daire yok" DENMEZ: hata kartı çıkar', (tester) async {
    await pumpHomeless(tester, homesError: kNetworkError);
    expect(find.text('Henüz kayıtlı bir daireniz yok'), findsNothing);
    expect(find.text('Kod ile Bir Eve Katıl'), findsNothing);
    expect(byKeyName('error_card'), findsOneWidget);
    expect(find.text('Daireler yüklenemedi'), findsOneWidget);
  });

  testWidgets('daire edinilince (yenileme sonrası) normal pano açılır ve katılma ekranı kalkar', (tester) async {
    final h = await pumpHomeless(tester);
    expect(byKeyName('view_homeless'), findsOneWidget);

    h.cloud.homes = <HomeModel>[testHome()];
    h.cloud.endpoints[kHomeA] = testEndpoints();
    await tester.runAsync(() => h.state.fetchHomes());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(byKeyName('view_homeless'), findsNothing);
    expect(find.text('Henüz kayıtlı bir daireniz yok'), findsNothing);
    expect(byKeyName('card_relay_1'), findsOneWidget);
    expect(byKeyName('nav_settings'), findsOneWidget);
  });

  testWidgets('dairesi olan kullanıcıda katılma ekranı hiç görünmez', (tester) async {
    await pumpReady(tester, const DashboardPage(), role: 'owner');
    expect(find.text('Kod ile Bir Eve Katıl'), findsNothing);
    expect(find.text('Henüz kayıtlı bir daireniz yok'), findsNothing);
  });

  testWidgets('dar ekranda ve yazı ölçeği 1.5\'te (açık tema) taşma yok', (tester) async {
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Çok Uzun İsimli Bir Kullanıcı Adı', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    addTearDown(h.dispose);
    await tester.runAsync(() => h.state.fetchHomes());
    await pumpPage(
      tester,
      h.state,
      const DashboardPage(),
      size: const Size(320, 720),
      textScale: 1.5,
      themeMode: ThemeMode.light,
    );
    expect(tester.takeException(), isNull);
  });
}
