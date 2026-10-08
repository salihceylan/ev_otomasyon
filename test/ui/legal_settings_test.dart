import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/legal/legal_document_page.dart';
import 'package:ev_otomasyon/ui/pages/legal/legal_texts_page.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';
import 'e2_support.dart';

/// "Yasal Metinler" girişi HER ROLDE ulaşılabilir: ayarlar sayfası (ev sahibi, aile, misafir, servis oturumu, girişsiz
/// yerel kip, evsiz personel) ve profil diyaloğu (konsollar dahil oturum açmış herkes). Liste: Kullanıcı Sözleşmesi,
/// Gizlilik Politikası ve KVKK Aydınlatma Metni (ikisi de metin sayfasını açar; çevrimdışı -> hata + yeniden dene) ve Açık
/// Kaynak Lisansları (Flutter lisans sayfası, uygulamanın görünen adıyla). Giriş ekranının altında iki küçük bağlantı.
void main() {
  const tall = Size(800, 4200);

  void expectLegalEntries() {
    expect(find.byKey(const Key('btn_legal_terms')), findsOneWidget);
    expect(find.byKey(const Key('btn_legal_privacy')), findsOneWidget);
    expect(find.byKey(const Key('btn_legal_licenses')), findsOneWidget);
    expect(find.text('Kullanıcı Sözleşmesi'), findsOneWidget);
    expect(find.text('Gizlilik Politikası ve KVKK Aydınlatma Metni'), findsOneWidget);
    expect(find.text('Açık Kaynak Lisansları'), findsOneWidget);
  }

  group('Ayarlar: "Yasal Metinler" kartı her rolde', () {
    testWidgets('ev sahibi', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: tall);
      expect(byKeyName('card_legal'), findsOneWidget);
      expect(find.text('Yasal Metinler'), findsOneWidget);
      expectLegalEntries();
    });

    testWidgets('aile üyesi ve misafir', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'resident', size: tall);
      expect(byKeyName('card_legal'), findsOneWidget);
      await pumpReady(tester, const DeviceSettingsPage(), home: guestHome(), size: tall);
      expect(byKeyName('card_legal'), findsOneWidget);
    });

    testWidgets('servis PIN oturumu', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'service_session', globalRole: 'service_session', size: tall);
      expect(byKeyName('card_legal'), findsOneWidget);
    });

    testWidgets('girişsiz yerel (LAN) kip', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      await pumpPage(tester, h.state, const DeviceSettingsPage(), size: tall);
      expect(byKeyName('card_legal'), findsOneWidget);
    });

    testWidgets('aktif evi olmayan süper kullanıcı', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'su-1', email: 'su@b.c', fullName: 'Süper', role: 'super_user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await pumpPage(tester, h.state, const DeviceSettingsPage(), size: tall);
      expect(byKeyName('card_legal'), findsOneWidget);
    });
  });

  group('Yasal metin girişleri', () {
    Future<StateHarness> openSettings(WidgetTester tester) async {
      final h = await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: tall);
      await tester.pump(const Duration(milliseconds: 100));
      return h;
    }

    testWidgets('"Kullanıcı Sözleşmesi" ve "Gizlilik..." metin sayfasını açar', (tester) async {
      final h = await openSettings(tester);

      await tapKey(tester, 'btn_legal_terms');
      expect(tester.widget<LegalDocumentPage>(find.byType(LegalDocumentPage)).kind, LegalDocumentKind.terms);
      expect(textOf(tester, 'legal_meta'), 'Sürüm 1 · Yürürlük: 08.10.2026');

      await tester.pageBack();
      await settle(tester, frames: 10); // geri geçişi bitsin (önceki sayfa yeniden dokunulabilir)
      await tapKey(tester, 'btn_legal_privacy');
      expect(tester.widget<LegalDocumentPage>(find.byType(LegalDocumentPage)).kind, LegalDocumentKind.privacy);
      expect(h.cloud.legalDocumentCalls, <String>['terms', 'privacy']);
    });

    testWidgets('çevrimdışı: metin sayfasında hata + "Tekrar Dene"; bağlantı gelince yüklenir', (tester) async {
      final h = await openSettings(tester);
      h.cloud.legalError = ApiException.network();

      await tapKey(tester, 'btn_legal_privacy');
      expect(find.byKey(const Key('legal_error')), findsOneWidget);

      h.cloud.legalError = null;
      await tapKey(tester, 'btn_legal_retry');
      expect(textOf(tester, 'legal_title'), 'Gizlilik Politikası ve KVKK Aydınlatma Metni');
    });

    testWidgets('"Açık Kaynak Lisansları" Flutter lisans sayfasını uygulamanın görünen adıyla açar', (tester) async {
      await openSettings(tester);

      await tapKey(tester, 'btn_legal_licenses');

      final page = tester.widget<LicensePage>(find.byType(LicensePage));
      expect(page.applicationName, AppConfig.appDisplayName);
      expect(AppConfig.appDisplayName, 'AHBU Ev Otomasyonu');
    });
  });

  group('Profil diyaloğu: "Yasal Metinler" (konsollar dahil oturum açmış herkes)', () {
    for (final roles in <(String?, String)>[
      ('owner', 'user'),
      (null, 'user'),
      (null, 'super_user'),
      (null, 'service_user'),
      ('service_session', 'service_session'),
    ]) {
      testWidgets('${roles.$2} (ev rolü: ${roles.$1 ?? 'yok'})', (tester) async {
        final env = e2Env(role: roles.$1, globalRole: roles.$2);
        await openFromHost<void>(tester, env.state, size: const Size(412, 1800), (c) => UserProfileDialog.show(c));

        expect(find.byKey(const Key('btn_open_legal')), findsOneWidget);
        await tapKey(tester, 'btn_open_legal');

        expect(find.byType(LegalTextsPage), findsOneWidget);
        expect(find.byType(UserProfileDialog), findsNothing, reason: 'profil kapanır');
        expectLegalEntries();
      });
    }
  });

  group('Erişilebilirlik', () {
    testWidgets('"Yasal Metinler" sayfası: satırlar ≥ 48 dp ve etiketli; dar ekran + 2.0 yazı ölçeğinde taşma yok', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final env = e2Env();
        await pumpApp(tester, state: env.state, size: const Size(412, 915), child: const LegalTextsPage());
        await settle(tester);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await pumpApp(
          tester,
          state: env.state,
          size: const Size(320, 900),
          child: MediaQuery.withClampedTextScaling(minScaleFactor: 2.0, maxScaleFactor: 2.0, child: const LegalTextsPage()),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    });
  });

  group('Giriş ekranı alt bağlantıları', () {
    testWidgets('"Kullanıcı Sözleşmesi" ve "Gizlilik ve KVKK" metin sayfalarını açar (oturum gerekmez)', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, size: const Size(412, 1400), child: const LoginPage());
      await settle(tester);

      await tapKey(tester, 'btn_login_terms');
      expect(tester.widget<LegalDocumentPage>(find.byType(LegalDocumentPage)).kind, LegalDocumentKind.terms);

      await tester.pageBack();
      await settle(tester, frames: 10); // geri geçişi bitsin (önceki sayfa yeniden dokunulabilir)
      await tapKey(tester, 'btn_login_privacy');
      expect(tester.widget<LegalDocumentPage>(find.byType(LegalDocumentPage)).kind, LegalDocumentKind.privacy);
      expect(env.cloud.legalDocumentCalls, <String>['terms', 'privacy']);
    });
  });
}
