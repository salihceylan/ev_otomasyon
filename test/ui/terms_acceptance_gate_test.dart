import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/legal/terms_acceptance_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Giriş sonrası Kullanıcı Sözleşmesi onay kapısı (CONTRACTS: `user.legal.needs_acceptance`):
///
/// * YALNIZ bulutta oturum açmış ve sunucunun onay istediği kullanıcıya tam ekran `TermsAcceptancePage` gösterilir;
///   personel, servis PIN oturumu ve yerel ağ (LAN) kipinde hiç gösterilmez. Zorunlu parola değişimi önce gelir.
/// * "Kabul Ediyorum" -> `POST /legal/accept` -> `GET /auth/me` -> pano. `409` -> güncel metin yüklenip yeniden sorulur;
///   ağ hatası -> yeniden denenebilir; "Çıkış Yap" her zaman çıkış yoludur (çıkmaz yok).
void main() {
  UserModel pendingUser({String role = 'user', int current = 1, bool mustChangePassword = false}) => UserModel(
        id: kUserId,
        email: kUserEmail,
        fullName: 'Ayşe Yılmaz',
        role: role,
        mustChangePassword: mustChangePassword,
        legal: pendingTerms(current: current),
      );

  UserModel acceptedUser({int version = 1}) => UserModel(
        id: kUserId,
        email: kUserEmail,
        fullName: 'Ayşe Yılmaz',
        legal: UserLegalStatus(termsAcceptedVersion: version, termsCurrentVersion: version, termsStatus: 'final'),
      );

  /// Oturum açmış, onay bekleyen kullanıcı + kesinleşmiş sözleşme (sürüm 1) ile kapıyı kurar.
  Future<E2Env> pumpGate(
    WidgetTester tester, {
    UserModel? user,
    AppMode mode = AppMode.cloud,
    Size size = const Size(412, 915),
    void Function(E2Env env)? configure,
  }) async {
    final env = e2Env();
    env.cloud
      ..legalDocuments = testLegalDocuments(termsStatus: 'final')
      ..meUser = acceptedUser()
      ..beginSession(accessToken: 'access-1', refreshToken: 'refresh-1');
    env.state
      ..setCurrentUserForTesting(user ?? pendingUser())
      ..setModeForTesting(mode);
    configure?.call(env);
    await pumpApp(tester, state: env.state, size: size, child: const AuthGate());
    await settle(tester, frames: 6);
    return env;
  }

  Finder gatePage() => find.byType(TermsAcceptancePage);

  group('gateViewFor: sözleşme onay kapısı', () {
    test('bulutta onay bekleyen kullanıcı -> termsAcceptance; onay yoksa -> dashboard', () {
      final env = e2Env();
      env.state.setCurrentUserForTesting(pendingUser());
      expect(gateViewFor(env.state), AuthGateView.termsAcceptance);

      env.state.setCurrentUserForTesting(acceptedUser());
      expect(gateViewFor(env.state), AuthGateView.dashboard);
    });

    test('zorunlu parola değişimi ÖNCE gelir', () {
      final env = e2Env();
      env.state.setCurrentUserForTesting(pendingUser(mustChangePassword: true));
      expect(gateViewFor(env.state), AuthGateView.forcedPasswordChange);
    });

    test('LAN kipi, personel ve servis PIN oturumunda kapı YOK', () {
      final env = e2Env();
      env.state
        ..setCurrentUserForTesting(pendingUser())
        ..setModeForTesting(AppMode.direct);
      expect(gateViewFor(env.state), AuthGateView.dashboard);

      env.state.setModeForTesting(AppMode.cloud);
      for (final role in <String>['super_user', 'service_user', 'service_session']) {
        env.state.setCurrentUserForTesting(pendingUser(role: role));
        expect(gateViewFor(env.state), AuthGateView.dashboard, reason: role);
      }
    });
  });

  group('AuthGate + TermsAcceptancePage', () {
    testWidgets('onay bekleyen kullanıcıya tam ekran sözleşme gösterilir; pano açılmaz; geri tuşu kapıyı atlatmaz', (tester) async {
      final env = await pumpGate(tester);

      expect(gatePage(), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
      expect(find.text('Kullanıcı Sözleşmesi'), findsOneWidget, reason: 'sayfa başlığı');
      expect(textOf(tester, 'legal_meta'), 'Sürüm 1 · Yürürlük: 08.10.2026');
      expect(find.text('Kabul Ediyorum'), findsOneWidget);
      expect(find.text('Çıkış Yap'), findsOneWidget);
      expect(env.cloud.legalDocumentCalls, <String>['terms']);
      final popScope = tester.widget<PopScope>(
        find.descendant(of: gatePage(), matching: find.byWidgetPredicate((w) => w is PopScope)).first,
      );
      expect(popScope.canPop, isFalse);
    });

    testWidgets('"Kabul Ediyorum": POST /legal/accept -> GET /auth/me -> pano', (tester) async {
      final env = await pumpGate(tester);

      await tapKey(tester, 'btn_terms_accept');
      await settle(tester, frames: 6);

      expect(env.cloud.legalLog, <String>['legal:get:terms', 'legal:accept:terms:1', 'me']);
      expect(env.state.needsTermsAcceptance, isFalse);
      expect(gatePage(), findsNothing);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('409: güncel metin yeniden yüklenir ve yeniden sorulur; ikinci onay yeni sürümle gider', (tester) async {
      final env = await pumpGate(tester);
      // Sayfa açıkken sunucuda 2. sürüm yayımlandı.
      env.cloud
        ..legalDocuments = testLegalDocuments(termsVersion: 2, termsStatus: 'final')
        ..meUser = acceptedUser(version: 2);

      await tapKey(tester, 'btn_terms_accept');

      expect(gatePage(), findsOneWidget, reason: 'onaylanmadı: kapı sürer');
      expect(textOf(tester, 'terms_notice'), contains('Kullanıcı Sözleşmesi güncellendi'));
      expect(textOf(tester, 'legal_meta'), 'Sürüm 2 · Yürürlük: 08.10.2026', reason: 'güncel metin yüklendi');
      expect(find.text('Kullanıcı Sözleşmesi metninin 2. sürümü.'), findsOneWidget);

      await tapKey(tester, 'btn_terms_accept');
      await settle(tester, frames: 6);

      expect(env.cloud.legalAccepts.map((a) => a.version), <int>[1, 2]);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('ağ hatası: Türkçe hata, düğmeler etkin kalır; yeniden deneme başarılı olur', (tester) async {
      final env = await pumpGate(tester, configure: (env) => env.cloud.legalAcceptError = ApiException.network());

      await tapKey(tester, 'btn_terms_accept');

      expect(gatePage(), findsOneWidget);
      expect(textOf(tester, 'terms_error'), contains('Sunucuya ulaşılamadı'));
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_terms_accept'))).onPressed, isNotNull);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_terms_logout'))).onPressed, isNotNull);

      env.cloud.legalAcceptError = null;
      await tapKey(tester, 'btn_terms_accept');
      await settle(tester, frames: 6);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('metin yüklenemezse: hata + "Tekrar Dene"; onay pasif; "Çıkış Yap" etkin; yeniden deneme metni getirir', (tester) async {
      final env = await pumpGate(tester, configure: (env) => env.cloud.legalError = ApiException.network());

      expect(find.byKey(const Key('legal_error')), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_terms_accept'))).onPressed, isNull,
          reason: 'görülmeyen metin onaylanamaz');
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_terms_logout'))).onPressed, isNotNull, reason: 'çıkmaz yok');

      env.cloud.legalError = null;
      await tapKey(tester, 'btn_legal_retry');

      expect(textOf(tester, 'legal_meta'), 'Sürüm 1 · Yürürlük: 08.10.2026');
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_terms_accept'))).onPressed, isNotNull);
    });

    testWidgets('metin sunucuda yoksa (404): kullanıcı /auth/me ile yenilenir; sunucu artık onay istemiyorsa kapı kalkar',
        (tester) async {
      // Saklı "onay gerekir" durumu eski (ör. sözleşme yayından kaldırıldı): "Tekrar Dene" tek başına kapıyı açamazdı.
      final env = await pumpGate(tester, configure: (env) {
        env.cloud
          ..legalDocuments = <LegalDocument>[testLegalDocument('privacy')]
          ..meUser = UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz');
      });

      expect(env.cloud.legalLog, <String>['legal:get:terms', 'me']);
      expect(env.state.needsTermsAcceptance, isFalse);
      expect(gatePage(), findsNothing);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('metin sunucuda yok (404) ve sunucu hâlâ onay istiyor: kapı sürer, hata + "Tekrar Dene" + "Çıkış Yap"',
        (tester) async {
      final env = await pumpGate(tester, configure: (env) {
        env.cloud
          ..legalDocuments = <LegalDocument>[testLegalDocument('privacy')]
          ..meUser = pendingUser();
      });

      expect(env.cloud.legalLog, <String>['legal:get:terms', 'me']);
      expect(gatePage(), findsOneWidget);
      expect(find.byKey(const Key('legal_error')), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_terms_logout'))).onPressed, isNotNull, reason: 'çıkmaz yok');

      // Ağ hatasında /auth/me boşuna denenmez (yeniden deneme düğmesi yeter).
      env.cloud.legalError = ApiException.network();
      await tapKey(tester, 'btn_legal_retry');
      expect(env.cloud.legalLog, <String>['legal:get:terms', 'me', 'legal:get:terms']);
    });

    testWidgets('"Çıkış Yap" onay sorar ve oturumu kapatır (giriş ekranı)', (tester) async {
      final env = await pumpGate(tester);

      await tapKey(tester, 'btn_terms_logout');
      expect(find.byKey(const Key('btn_logout_confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_logout_confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(gatePage(), findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(env.cloud.legalAccepts, isEmpty, reason: 'onay gönderilmedi');
    });

    testWidgets('bulut girişinden sonra (onay bekleyen hesap) kapı gelir; onay sonrası pano açılır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud
        ..legalDocuments = testLegalDocuments(termsStatus: 'final')
        ..loginUser = UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz', legal: pendingTerms())
        ..meUser = acceptedUser()
        ..homes = <HomeModel>[testHome()];
      await pumpApp(tester, state: env.state, size: const Size(412, 915), child: const AuthGate());
      await settle(tester);

      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', kStrongPassword);
      await tapKey(tester, 'btn_login');
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(gatePage(), findsOneWidget);

      await tapKey(tester, 'btn_terms_accept');
      await settle(tester, frames: 8);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('servis PIN oturumu, personel ve LAN kipinde kapı GÖSTERİLMEZ', (tester) async {
      for (final setup in <({String role, AppMode mode})>[
        (role: 'service_session', mode: AppMode.cloud),
        (role: 'super_user', mode: AppMode.cloud),
        (role: 'service_user', mode: AppMode.cloud),
        (role: 'user', mode: AppMode.direct),
      ]) {
        await tester.pumpWidget(const SizedBox());
        final env = await pumpGate(tester, user: pendingUser(role: setup.role), mode: setup.mode);
        expect(gatePage(), findsNothing, reason: '${setup.role} / ${setup.mode.name}');
        expect(env.cloud.legalDocumentCalls, isEmpty, reason: '${setup.role} / ${setup.mode.name}');
      }
    });

    testWidgets('zorunlu parola değişimi önce; parola değişince sözleşme kapısı gelir', (tester) async {
      final env = await pumpGate(
        tester,
        user: pendingUser(mustChangePassword: true),
        configure: (env) => env.cloud.registeredUser = pendingUser(),
      );
      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(gatePage(), findsNothing);

      await typeInto(tester, 'field_current_password', 'gecici-parola-1');
      await typeInto(tester, 'field_new_password', kStrongPassword);
      await typeInto(tester, 'field_confirm_password', kStrongPassword);
      await tapKey(tester, 'btn_change_password');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester, frames: 8);

      expect(env.state.mustChangePassword, isFalse);
      expect(gatePage(), findsOneWidget);
    });

    testWidgets('erişilebilirlik: dokunma hedefleri yeterli ve etiketli (metin yüklü / yüklenemedi)', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await pumpGate(tester);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await tester.pumpWidget(const SizedBox());
        await pumpGate(tester, configure: (e) => e.cloud.legalError = ApiException.network());
        expect(find.byKey(const Key('legal_error')), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        handle.dispose();
      }
    });

    for (final theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      testWidgets('dar ekran (320 dp) ve yazı ölçeği 2.0: taşma yok; düğmeler görünür (${theme.name})', (tester) async {
        final env = e2Env();
        env.cloud.legalDocuments = testLegalDocuments(termsStatus: 'final');
        env.state.setCurrentUserForTesting(pendingUser());
        await pumpApp(
          tester,
          state: env.state,
          size: const Size(320, 640),
          themeMode: theme,
          child: MediaQuery.withClampedTextScaling(minScaleFactor: 2.0, maxScaleFactor: 2.0, child: const AuthGate()),
        );
        await settle(tester, frames: 6);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('btn_terms_accept')).hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('btn_terms_logout')).hitTestable(), findsOneWidget);
      });
    }
  });
}
