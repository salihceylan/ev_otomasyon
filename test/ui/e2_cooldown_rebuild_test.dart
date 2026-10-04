import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/cooldown.dart';
import 'package:ev_otomasyon/ui/common/deep_links.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// YENİDEN KURULUM sayacı testleri (Dalga 5a, WP-UI-DIALOGS; kanıt = `RebuildCounter`, ölçümsüz performans
/// iddiası yok).
///
///  * PF-23: `Cooldown` her saniye `setState` ile TÜM diyaloğu kuruyordu (iki `Cooldown` = saniyede ~2 kez).
///    `notifyOnTick: false` + `ValueListenable<int> remaining`: yalnız sayaç metinleri güncellenir; düğme
///    kilidi başlangıç/bitişte yeniden kurar.
///  * PF-06: ikincil sayfa/diyalog köklerindeki `context.watch<AutomationState>()` -> `context.select`:
///    ilgisiz bir `notifyListeners` bu köklerin hiçbirini yeniden kurmaz; ilgili değişim kurar.
void main() {
  /// Bu paketin diyalogları için ilgisiz bildirim: dinleyicilere haber verir ama diyaloğun okuduğu hiçbir
  /// değer değişmez.
  void unrelatedNotify(E2Env env) => env.state.setServiceSubscribersForTesting(const <Map<String, dynamic>>[]);

  Future<void> noise(WidgetTester tester, E2Env env, {int times = 3}) async {
    for (var i = 0; i < times; i++) {
      unrelatedNotify(env);
      await tester.pump();
    }
  }

  // ---------------------------------------------------------------------------------------------
  // PF-23: Cooldown
  // ---------------------------------------------------------------------------------------------
  group('Cooldown: remaining + notifyOnTick (PF-23)', () {
    test('varsayılan davranış AYNI: her saniye geri çağrı; remaining her saniye güncellenir', () {
      final clock = FakeClock();
      var notifications = 0;
      final cooldown = Cooldown(clock, () => notifications++);
      final seen = <int>[];
      cooldown.remaining.addListener(() => seen.add(cooldown.remaining.value));

      cooldown.start(const Duration(seconds: 3));
      expect(cooldown.remaining.value, 3);
      clock.advance(const Duration(seconds: 3));

      expect(notifications, 4, reason: 'başlangıç + 3 tik (varsayılan notifyOnTick: true)');
      expect(seen, <int>[3, 2, 1, 0]);
      expect(cooldown.isActive, isFalse);
      cooldown.dispose();
    });

    test('notifyOnTick: false -> geri çağrı yalnız başlangıçta ve bitişte; remaining her saniye güncellenir', () {
      final clock = FakeClock();
      var notifications = 0;
      final cooldown = Cooldown(clock, () => notifications++, notifyOnTick: false);
      final seen = <int>[];
      cooldown.remaining.addListener(() => seen.add(cooldown.remaining.value));

      cooldown.start(const Duration(seconds: 5));
      expect(notifications, 1, reason: 'kilit başladı');
      clock.advance(const Duration(seconds: 4));
      expect(notifications, 1, reason: 'ara tikler diyaloğu kurmaz');
      expect(seen, <int>[5, 4, 3, 2, 1]);
      expect(cooldown.remainingSeconds, 1);

      clock.advance(const Duration(seconds: 1));
      expect(notifications, 2, reason: 'kilit bitti: bir kez bildirilir');
      expect(cooldown.remaining.value, 0);
      expect(cooldown.isActive, isFalse);
      expect(clock.activeTimerCount, 0);
      cooldown.dispose();
    });

    test('cancel: bekleme biter, remaining 0 olur, zamanlayıcı kalmaz ve geri çağrı çalışmaz', () {
      final clock = FakeClock();
      var notifications = 0;
      final cooldown = Cooldown(clock, () => notifications++, notifyOnTick: false);
      cooldown.start(const Duration(seconds: 10));
      expect(cooldown.remaining.value, 10);
      final before = notifications;

      cooldown.cancel();

      expect(cooldown.remaining.value, 0);
      expect(cooldown.isActive, isFalse);
      expect(clock.activeTimerCount, 0);
      clock.advance(const Duration(seconds: 20));
      expect(notifications, before, reason: 'cancel sonrası tik/bitiş bildirimi yok');
      cooldown.dispose();
    });

    test('yeni bekleme öncekinin yerine geçer; sıfır süre remaining\'i 0 yapar; dispose sonrası bildirim yok', () {
      final clock = FakeClock();
      var notifications = 0;
      final cooldown = Cooldown(clock, () => notifications++, notifyOnTick: false);
      cooldown.start(const Duration(seconds: 60));
      cooldown.start(const Duration(seconds: 5));
      expect(cooldown.remaining.value, 5);
      expect(clock.activeTimerCount, 1);

      cooldown.start(Duration.zero);
      expect(cooldown.remaining.value, 0);
      expect(cooldown.isActive, isFalse);

      cooldown.start(const Duration(seconds: 9));
      cooldown.dispose();
      final before = notifications;
      clock.advance(const Duration(seconds: 20));
      expect(notifications, before, reason: 'dispose sonrası geri çağrı çalışmaz');
      expect(clock.activeTimerCount, 0);
    });
  });

  group('geri sayım diyalogları: tikler diyaloğu yeniden kurmaz, yalnız sayaç metinleri güncellenir (PF-23)', () {
    testWidgets('telefon OTP: 5 saniye tiki -> diyalog kökü 0 yeniden kurulum; sayaçlar güncel', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.otpChallenge = const CodeChallenge(
        message: 'Doğrulama kodu gönderildi.',
        expiresIn: Duration(minutes: 5),
        resendAfter: Duration(seconds: 30),
      );
      await openFromHost<void>(tester, env.state, (context) => PhoneOtpDialog.show(context));
      await typeInto(tester, 'field_phone', '0555 123 45 67');
      await tapKey(tester, 'btn_otp_send');
      expect(find.text('Tekrar Kod İste (0:30)'), findsOneWidget);
      expect(textOf(tester, 'otp_expiry'), 'Kod süresi: 5:00');

      final counter = RebuildCounter.install();
      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.clock.advance(const Duration(seconds: 1));
        await tester.pump();
      }

      expect(find.text('Tekrar Kod İste (0:25)'), findsOneWidget, reason: 'geri sayım güncel');
      expect(textOf(tester, 'otp_expiry'), 'Kod süresi: 4:55', reason: 'kod süresi sayacı güncel');
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNull, reason: 'kilit sürüyor');
      expect(counter.of<PhoneOtpDialog>(), 0, reason: counter.describe());
      // WP-F4: OTP diyaloğu `AlertDialog` yerine ortak cam kabuğu (`AuthDialogShell` -> `Dialog`) kullanır; kilit
      // ESKİ sözleşmenin AYNISI (tikler diyalog yüzeyini yeniden kurmaz), kabuk türüne göre güncellendi.
      expect(counter.of<Dialog>(), 0, reason: counter.describe());
    });

    testWidgets('telefon OTP: bekleme bitince düğme kilidi açılır; kod süresi dolunca uyarı verilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.otpChallenge = const CodeChallenge(
        message: 'x',
        expiresIn: Duration(minutes: 1),
        resendAfter: Duration(seconds: 30),
      );
      await openFromHost<void>(tester, env.state, (context) => PhoneOtpDialog.show(context));
      await typeInto(tester, 'field_phone', '0555 123 45 67');
      await tapKey(tester, 'btn_otp_send');

      env.clock.advance(const Duration(seconds: 31));
      await tester.pump();
      expect(find.text('Tekrar Kod İste'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_resend_code'))).onPressed, isNotNull, reason: 'kilit bitişte açıldı');
      expect(textOf(tester, 'otp_expiry'), 'Kod süresi: 0:29');

      env.clock.advance(const Duration(seconds: 30));
      await tester.pump();
      expect(textOf(tester, 'otp_expiry'), 'Kodun süresi doldu');
    });

    testWidgets('şifre sıfırlama: 5 saniye tiki -> diyalog kökü 0 yeniden kurulum; sayaçlar güncel', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotChallenge = const CodeChallenge(
        message: 'Gönderildi.',
        expiresIn: Duration(minutes: 10),
        resendAfter: Duration(seconds: 30),
      );
      await openFromHost<void>(tester, env.state, (context) => ForgotPasswordDialog.show(context));
      await typeInto(tester, 'field_identifier', 'ayse@ornek.test');
      await tapKey(tester, 'btn_send_code');
      expect(find.text('Kodu Tekrar Gönder (0:30)'), findsOneWidget);
      expect(textOf(tester, 'forgot_expiry'), 'Kod geçerlilik süresi: 10:00');

      final counter = RebuildCounter.install();
      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.clock.advance(const Duration(seconds: 1));
        await tester.pump();
      }

      expect(find.text('Kodu Tekrar Gönder (0:25)'), findsOneWidget);
      expect(textOf(tester, 'forgot_expiry'), 'Kod geçerlilik süresi: 9:55');
      expect(counter.of<ForgotPasswordDialog>(), 0, reason: counter.describe());
      expect(counter.of<Dialog>(), 0, reason: counter.describe());
    });

    testWidgets('şifre sıfırlama 1. adım: "Bekleyin (…)" etiketi canlı güncellenir, diyalog kurulmaz; bitince düğme açılır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.forgotError = apiError(429, 'Çok fazla istek.', code: 'RATE_LIMITED', resendAfter: const Duration(seconds: 30));
      await openFromHost<void>(tester, env.state, (context) => ForgotPasswordDialog.show(context));
      await typeInto(tester, 'field_identifier', 'ayse@ornek.test');
      await tapKey(tester, 'btn_send_code');
      expect(find.text('Bekleyin (0:30)'), findsOneWidget);

      final counter = RebuildCounter.install();
      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.clock.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      expect(find.text('Bekleyin (0:25)'), findsOneWidget);
      expect(counter.of<ForgotPasswordDialog>(), 0, reason: counter.describe());

      env.clock.advance(const Duration(seconds: 26));
      await tester.pump();
      expect(find.text('Kod Gönder'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_send_code'))).onPressed, isNotNull);
    });

    testWidgets('cihaz eşleştirme (PIN kilidi 429): 5 saniye tiki -> diyalog kökü 0 yeniden kurulum; etiket ve uyarı güncel', (tester) async {
      final env = e2Env(role: null);
      env.cloud.claimError = apiError(429, 'x', code: 'RATE_LIMITED', retryAfter: const Duration(seconds: 30));
      await openFromHost<bool>(tester, env.state, (context) => ClaimManualDialog.show(context));
      await typeInto(tester, 'field_claim_uid', 'AHBU-S3-A1B2C3');
      await typeInto(tester, 'field_claim_pin', '123456');
      await tapKey(tester, 'btn_claim_submit');
      expect(find.text('Bekleyin (0:30)'), findsOneWidget);
      expect(textOf(tester, 'claim_lock_notice'), contains('30 saniye'));

      final counter = RebuildCounter.install();
      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.clock.advance(const Duration(seconds: 1));
        await tester.pump();
      }

      expect(find.text('Bekleyin (0:25)'), findsOneWidget, reason: 'düğme etiketi güncel');
      expect(textOf(tester, 'claim_lock_notice'), contains('25 saniye'), reason: 'kilit uyarısındaki süre güncel');
      expect(counter.of<ClaimManualDialog>(), 0, reason: counter.describe());
      expect(counter.of<AlertDialog>(), 0, reason: counter.describe());

      env.cloud.claimError = null;
      env.clock.advance(const Duration(seconds: 26));
      await tester.pump();
      expect(find.byKey(const Key('claim_lock_notice')), findsNothing, reason: 'bitişte uyarı kalkar');
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_claim_submit'))).onPressed, isNotNull);
    });

    testWidgets('cihaz eşleştirme (müşteri OTP bekleme): 5 saniye tiki -> diyalog kökü 0 yeniden kurulum', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await openFromHost<bool>(tester, env.state, (context) => ClaimManualDialog.show(context));
      await typeInto(tester, 'field_claim_uid', 'AHBU-S3-A1B2C3');
      await typeInto(tester, 'field_claim_pin', '123456');
      await typeInto(tester, 'field_claim_customer', 'musteri@ornek.test');
      await tapKey(tester, 'btn_claim_send_otp');
      expect(find.text('Yeniden gönder (0:30)'), findsOneWidget);

      final counter = RebuildCounter.install();
      counter.reset();
      for (var i = 0; i < 5; i++) {
        env.clock.advance(const Duration(seconds: 1));
        await tester.pump();
      }

      expect(find.text('Yeniden gönder (0:25)'), findsOneWidget);
      expect(counter.of<ClaimManualDialog>(), 0, reason: counter.describe());

      env.clock.advance(const Duration(seconds: 26));
      await tester.pump();
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_claim_resend_otp'))).onPressed, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------------------------
  // PF-06: context.watch -> context.select
  // ---------------------------------------------------------------------------------------------
  group('ilgisiz bildirim köklerini yeniden kurmaz; ilgili değişim kurar (PF-06)', () {
    testWidgets('profil diyaloğu', (tester) async {
      final env = e2Env(role: 'owner');
      await openFromHost<void>(tester, env.state, (context) => UserProfileDialog.show(context));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<UserProfileDialog>(), 0, reason: counter.describe());

      env.state.setThemeModeForTesting(ThemeMode.light);
      await tester.pump();
      expect(counter.of<UserProfileDialog>(), greaterThan(0), reason: 'tema seçimi görünür: yeniden kurulmalı');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('theme_light'))).selected, isTrue);

      counter.reset();
      env.state.setCurrentUserForTesting(
        const UserModel(id: kUserId, email: kUserEmail, fullName: 'Zeynep Kaya', phone: kUserPhone),
      );
      await tester.pump();
      expect(textOf(tester, 'profile_name'), 'Zeynep Kaya', reason: 'ilgili değişim yansır');
      expect(counter.of<UserProfileDialog>(), greaterThan(0));
    });

    testWidgets('cihaz eşleştirme diyaloğu', (tester) async {
      final env = e2Env(role: 'owner');
      await openFromHost<bool>(tester, env.state, (context) => ClaimManualDialog.show(context));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<ClaimManualDialog>(), 0, reason: counter.describe());
      expect(find.byKey(const Key('claim_forbidden')), findsNothing);

      env.state.setCurrentUserForTesting(null); // yetki kalktı
      await tester.pump();
      expect(find.byKey(const Key('claim_forbidden')), findsOneWidget, reason: 'yetki değişimi yansır');
    });

    testWidgets('aile & misafir yönetimi sayfası', (tester) async {
      final env = e2Env(role: 'owner');
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await settle(tester);
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<FamilyMembersPage>(), 0, reason: counter.describe());

      final renamed = testHome(role: 'owner', name: 'Yeni Daire Adı');
      env.state.setHomesForTesting(<HomeModel>[renamed], activeHome: renamed);
      await tester.pump();
      expect(find.text('Yeni Daire Adı'), findsOneWidget, reason: 'ev adı değişimi yansır');
      expect(counter.of<FamilyMembersPage>(), greaterThan(0));
    });

    testWidgets('davet diyaloğu', (tester) async {
      final env = e2Env(role: 'owner');
      await openFromHost<void>(tester, env.state, (context) => InviteFamilyDialog.show(context));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<InviteFamilyDialog>(), 0, reason: counter.describe());

      final renamed = testHome(role: 'owner', name: 'Yazlık');
      env.state.setHomesForTesting(<HomeModel>[renamed], activeHome: renamed);
      await tester.pump();
      expect(find.text('Yazlık'), findsOneWidget, reason: 'ev adı değişimi yansır');

      env.state.setCurrentUserForTesting(null); // yetki kalktı
      await tester.pump();
      expect(find.byKey(const Key('invite_forbidden')), findsOneWidget, reason: 'yetki değişimi yansır');
    });

    testWidgets('eve katıl diyaloğu', (tester) async {
      final env = e2Env(role: null);
      await openFromHost<bool>(tester, env.state, (context) => JoinHomeDialog.show(context));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<JoinHomeDialog>(), 0, reason: counter.describe());
      expect(find.byKey(const Key('join_forbidden')), findsNothing);

      env.state.setCurrentUserForTesting(const UserModel(id: '', email: '', fullName: 'Teknisyen', role: 'service_session'));
      await tester.pump();
      expect(find.byKey(const Key('join_forbidden')), findsOneWidget, reason: 'servis oturumu değişimi yansır');
    });

    testWidgets('devir / acil sıfırlama diyaloğu', (tester) async {
      final env = e2Env(role: 'owner');
      await openFromHost<void>(tester, env.state, (context) => TransferOwnershipDialog.show(context));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<TransferOwnershipDialog>(), 0, reason: counter.describe());
      expect(find.byKey(const Key('transfer_forbidden')), findsNothing);

      env.state.setCurrentUserForTesting(null); // yetki kalktı
      await tester.pump();
      expect(find.byKey(const Key('transfer_forbidden')), findsOneWidget, reason: 'yetki değişimi yansır');
    });

    testWidgets('şifre değiştirme sayfası (yalnız çıkış için durum gerekir: okuma)', (tester) async {
      final env = e2Env(role: 'owner');
      await pumpApp(tester, state: env.state, child: const ChangePasswordPage(forced: true));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<ChangePasswordPage>(), 0, reason: counter.describe());

      // Zorunlu moddaki çıkış düğmesi hâlâ çalışır (durum build'de değil, dokunuşta okunur).
      await tapKey(tester, 'btn_forced_logout');
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_logout_cancel');
    });

    testWidgets('sihirli bağlantı sayfası (şifre sıfırlama)', (tester) async {
      final env = e2Env(authenticated: false);
      const link = MagicLink(kind: MagicLinkKind.resetPassword, token: 'test-magic-token-0001-abcdef');
      await pumpApp(tester, state: env.state, child: const MagicLinkPage(link: link));
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<MagicLinkPage>(), 0, reason: counter.describe());
    });

    testWidgets('sihirli bağlantı sayfası (giriş): oturum durumu değişince yeniden kurulur', (tester) async {
      final env = e2Env(role: 'owner'); // oturum AÇIK: "bu bağlantıyla giriş yap" onayı bekler
      const link = MagicLink(kind: MagicLinkKind.magicLogin, token: 'test-magic-token-0001-abcdef');
      await pumpApp(tester, state: env.state, child: const MagicLinkPage(link: link));
      await settle(tester);
      expect(find.byKey(const Key('magic_login_confirm_notice')), findsOneWidget);
      final counter = RebuildCounter.install();
      counter.reset();

      await noise(tester, env);
      expect(counter.of<MagicLinkPage>(), 0, reason: counter.describe());

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await tester.pump();
      expect(find.byKey(const Key('magic_login_confirm_notice')), findsNothing, reason: 'oturum kapandı: onay notu kalkar');
    });

    group('derin bağlantı: cihaz etiketi sayfası', () {
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

      testWidgets('oturum yokken ilgisiz bildirim sayfayı kurmaz', (tester) async {
        final env = e2Env(authenticated: false);
        final navKey = await pumpRouter(tester, env);
        unawaited(navKey.currentState!.pushNamed('/claim?uid=AHBU-S3-1A2B3C&pin=482916'));
        await tester.pumpAndSettle();
        expect(textOf(tester, 'deep_link_claim_text'), contains('önce hesabınızla giriş yapın'));
        final counter = RebuildCounter.install();
        counter.reset();

        await noise(tester, env);

        expect(counter.ofName('_ClaimLinkPage'), 0, reason: counter.describe());
      });

      testWidgets('oturum SONRADAN açılıp yetki gelirse eşleştirme penceresi o anda açılır (yan etki korunur)', (tester) async {
        final env = e2Env(authenticated: false);
        final navKey = await pumpRouter(tester, env);
        unawaited(navKey.currentState!.pushNamed('/claim?uid=AHBU-S3-1A2B3C&pin=482916'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('field_claim_uid')), findsNothing);

        env.state
          ..setCurrentUserForTesting(const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz'))
          ..setAuthStatusForTesting(AuthStatus.authenticated);
        await settle(tester);

        expect(fieldText(tester, 'field_claim_uid'), 'AHBU-S3-1A2B3C');
        expect(fieldText(tester, 'field_claim_pin'), '482916');
      });

      testWidgets('açılış/biyometrik kilit metni durum değişince güncellenir', (tester) async {
        final env = e2Env(authenticated: false);
        env.state.setAuthStatusForTesting(AuthStatus.checking);
        final navKey = await pumpRouter(tester, env);
        unawaited(navKey.currentState!.pushNamed('/claim?uid=AHBU-S3-1A2B3C&pin=482916'));
        await tester.pumpAndSettle();
        expect(textOf(tester, 'deep_link_claim_text'), 'Oturum doğrulanıyor...');

        env.state.setBiometricForTesting(failed: true);
        await tester.pump();
        expect(textOf(tester, 'deep_link_claim_text'), contains('Oturum kilitli'));
      });
    });
  });
}
