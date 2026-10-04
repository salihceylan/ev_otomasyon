import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/deep_links.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// UYELIK-05 (D23): şifre sıfırlama bağlantısı oturum AÇIKKEN, magic-login'deki ile aynı uyarı/onay olmadan
/// oturumu değiştirmez (sunucu sıfırlama yanıtında bağlantının hesabıyla oturum açar).
///
/// UYELIK-K2 (D26): derin bağlantının şifre sıfırlama kolu da (magic-login kolu gibi) açılış / biyometrik kilit
/// sürerken bekler: form gösterilmez, istek atılmaz; kilit açılınca oturum durumuna göre karar verilir.
void main() {
  // Gerçek olmayan, biçimi geçerli sahte belirteç.
  const token = 'test-magic-token-0001-abcdef';
  const resetLink = MagicLink(kind: MagicLinkKind.resetPassword, token: token);
  const otherUser = UserModel(id: kOtherUserId, email: 'baska@ornek.test', fullName: 'Başka Kişi');

  /// Ana sayfadaki düğmeyle [page]'i iter (geri dönüş ana sayfaya olur).
  Future<void> pushPage(WidgetTester tester, E2Env env, Widget page) async {
    await pumpApp(
      tester,
      state: env.state,
      child: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open_host'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
              child: const Text('Aç'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_host')));
    await settle(tester);
  }

  /// Gerçek derin bağlantı yönlendirmesi (`MaterialApp.onGenerateRoute`, uygulama kabuğundaki ile aynı işlevler).
  Future<GlobalKey<NavigatorState>> pumpRouter(WidgetTester tester, E2Env env) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(
        value: env.state,
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Center(child: Text('Ana ekran'))),
          onGenerateRoute: deepLinkOnGenerateRoute,
          onUnknownRoute: deepLinkOnUnknownRoute,
        ),
      ),
    );
    return navKey;
  }

  Future<void> fillPasswords(WidgetTester tester) async {
    await typeInto(tester, 'field_new_password', kStrongPassword);
    await typeInto(tester, 'field_confirm_password', kStrongPassword);
  }

  void expectNoForm() {
    expect(find.byKey(const Key('field_new_password')), findsNothing, reason: 'form gösterilmez');
    expect(find.byKey(const Key('btn_magic_reset_submit')), findsNothing, reason: 'gönder düğmesi yok');
  }

  group('UYELIK-05 (D23): oturum açıkken onaysız hesap değişmez', () {
    testWidgets('oturum açık: önce magic-login ile aynı uyarı ve onay; form ve istek YOK', (tester) async {
      final env = e2Env(role: 'owner');
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      expect(find.byKey(const Key('magic_reset_confirm_notice')), findsOneWidget);
      expect(textOf(tester, 'magic_reset_confirm_notice'), contains('mevcut oturum kapanır'));
      expect(find.byKey(const Key('btn_magic_reset_confirm')), findsOneWidget);
      expect(find.byKey(const Key('btn_magic_reset_cancel')), findsOneWidget);
      expectNoForm();
      expect(env.cloud.resetArgs, isEmpty);
      expect(env.state.currentUser!.id, kUserId);
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('"Vazgeç": sayfa kapanır; oturum DEĞİŞMEZ ve istek gitmez', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.resetReturnsSession = true;
      env.cloud.registeredUser = otherUser;
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await tapKey(tester, 'btn_magic_reset_cancel');
      await tester.pumpAndSettle();

      expect(find.byType(MagicLinkPage), findsNothing);
      expect(env.cloud.resetArgs, isEmpty);
      expect(env.cloud.calls, isNot(contains('resetPassword')));
      expect(env.state.currentUser!.id, kUserId, reason: 'açık hesap korunur');
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('onaylanınca form açılır; sıfırlama bağlantının hesabını açar ve sayfa kapanır', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.resetReturnsSession = true;
      env.cloud.registeredUser = otherUser;
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await tapKey(tester, 'btn_magic_reset_confirm');
      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(env.cloud.resetArgs, isEmpty, reason: 'onay yalnız formu açar; istek kullanıcı gönderince');

      await fillPasswords(tester);
      await tapKey(tester, 'btn_magic_reset_submit');
      await tester.pumpAndSettle();

      expect(env.cloud.resetArgs, hasLength(1));
      expect(env.state.currentUser!.id, kOtherUserId, reason: 'onaylı hesap değişimi');
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('onay sonrası sunucu oturum VERMEZSE açık oturum sürer ve başarı iletisi gösterilir', (tester) async {
      final env = e2Env(role: 'owner');
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await tapKey(tester, 'btn_magic_reset_confirm');
      await fillPasswords(tester);
      await tapKey(tester, 'btn_magic_reset_submit');

      expect(env.cloud.resetArgs, hasLength(1));
      expect(find.byKey(const Key('magic_reset_done')), findsOneWidget, reason: 'sessizce kapanmaz');
      expect(env.state.currentUser!.id, kUserId);
    });

    testWidgets('oturum yokken mevcut davranış: form doğrudan açılır, onay istenmez', (tester) async {
      final env = e2Env(authenticated: false);
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(find.byKey(const Key('magic_reset_confirm_notice')), findsNothing);
      expect(find.byKey(const Key('magic_reset_waiting')), findsNothing);
    });

    testWidgets('derin bağlantı (/reset-password#token=) oturum açıkken de önce onay ister', (tester) async {
      final env = e2Env(role: 'owner');
      final navKey = await pumpRouter(tester, env);

      unawaited(navKey.currentState!.pushNamed('/reset-password#token=$token'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('magic_reset_confirm_notice')), findsOneWidget);
      expectNoForm();
      expect(env.cloud.resetArgs, isEmpty);
    });
  });

  group('UYELIK-K2 (D26): sıfırlama kolu biyometrik kilit açılana kadar bekler', () {
    testWidgets('açılış/kilit sürerken (checking) form gösterilmez, istek atılmaz; "Vazgeç" sayfayı kapatır', (tester) async {
      final env = e2Env(authenticated: false);
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      expect(find.byKey(const Key('magic_reset_waiting')), findsOneWidget);
      expectNoForm();
      expect(env.cloud.resetArgs, isEmpty);

      await tapKey(tester, 'btn_magic_reset_cancel');
      await tester.pumpAndSettle();
      expect(find.byType(MagicLinkPage), findsNothing);
      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('kilit açılınca: oturum VARSA onay istenir, YOKSA form açılır', (tester) async {
      final env = e2Env(role: 'owner');
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));
      expect(find.byKey(const Key('magic_reset_waiting')), findsOneWidget);

      env.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await settle(tester);
      expect(find.byKey(const Key('magic_reset_confirm_notice')), findsOneWidget);
      expectNoForm();

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await settle(tester);
      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('gerçek kilit: kayıtlı oturum + biyometrik doğrulama başarısız; derin bağlantı formu açmaz, kilit açılınca onay ister', (tester) async {
      final storage = FakeStorage();
      await storage.saveAuthToken('kayitli-erisim');
      await storage.saveRefreshToken('kayitli-yenileme');
      await storage.saveUser(const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz'));
      await storage.saveBiometricEnabled(true);
      final env = e2Env(
        authenticated: false,
        autoInit: true,
        storage: storage,
        biometric: FakeBiometric(supported: true, authResult: false, label: 'Parmak İzi'),
      );
      await env.state.ready;
      expect(env.state.authStatus, AuthStatus.checking, reason: 'hazırlık: oturum kilitli');

      final navKey = await pumpRouter(tester, env);
      unawaited(navKey.currentState!.pushNamed('/reset-password#token=$token'));
      await settle(tester, frames: 8);

      expect(find.byKey(const Key('magic_reset_waiting')), findsOneWidget);
      expectNoForm();
      expect(env.cloud.resetArgs, isEmpty);

      env.h.biometric.authResult = true;
      await env.state.retryBiometricAuth();
      await settle(tester, frames: 8);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byKey(const Key('magic_reset_confirm_notice')), findsOneWidget, reason: 'kilit açıldı, oturum var: onay');
      expectNoForm();
      expect(env.cloud.resetArgs, isEmpty);
    });
  });
}
