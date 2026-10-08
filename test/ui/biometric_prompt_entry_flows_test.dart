// ignore_for_file: avoid_print

import 'dart:async';

import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/app_shell.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/service_pin_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/social_sign_in.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// GİRİŞ AKIŞLARI x "biyometrik giriş kullanılsın mı?" istemi ([BiometricPromptDialog]).
///
/// İstem, `DashboardPage.initState` içindeki kare-sonu geri çağrısında açılır. Pano ise giriş çağrısı
/// (`register` / `verifyPhoneOtp` / `loginWithMagicLink` / `resetPassword`) DÖNMEDEN önce, yani
/// `AutomationState._handleAuthSuccess` içindeki `notifyListeners()` anında kurulur; giriş çağrısı ancak
/// ardından gelen `await fetchHomes()` (ev listesi + ilk ev + yenileme) bitince döner. Giriş çağrısı döndükten
/// sonra kendi rotasını kapatan akışlar (`popUntil(isFirst)` / `pop()`) bu yüzden gerçek ağda İSTEMİ kapatır
/// ya da yanlış rotayı kapatır.
///
/// Her akış iki sırayla sınanır:
/// * **anında yanıt**: sahte API aynı mikro görev zincirinde yanıtlar; giriş çağrısı ilk kareden ÖNCE döner
///   ve akışın `pop`'u istemden önce çalışır (kusur gizlenir);
/// * **gecikmeli ev listesi**: `fetchHomes` bir `Completer` ile bekletilir (gerçek ağ sırası: önce pano +
///   istem açılır, giriş çağrısı SONRA döner ve akış rotasını kapatır).
///
/// Testler İSTENEN davranışı doğrular ve görsel ayrıntıya değil `Key`'lere, widget türlerine ve durum
/// alanlarına dayanır: akış bitince istem tam bir kez ve en üstte görünür; akışın kendi rotası ağaçta
/// kalmaz; kullanıcı karar verene kadar `shouldPromptBiometrics` true kalır ve depoya "istem gösterildi"
/// yazılmaz; "Etkinleştir" biyometrik girişi açar.
///
/// Yazıldığı andaki (düzeltme öncesi) durum: KONTROL grubu ve bütün "anında yanıt" testleri geçer;
/// "gecikmeli ev listesi" sırasında kayıt, telefon OTP, sihirli bağlantı (iki yol), şifre sıfırlama (bağlantı
/// ve kod), "Etkinleştir'e bastıktan sonra giriş çağrısı döner" ve "pano açıkken yapılan giriş" testleri
/// KIRMIZIDIR. `[tanı]` satırları ara durumu ve istemi kapatan çağrı zincirini yazdırır.
/// Tanı çıktısı (çağrı zincirleri, rota durumu) yalnız yerel ayıklamada açılır; CI günlüğünü kirletmez.
const bool _taniAcik = false;

void _tani(Object? mesaj) {
  if (_taniAcik) print(mesaj);
}

void main() {
  setUpAll(() {
    // Testte ağdan yazı tipi indirilmez (AppShell temaları).
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // Gerçek olmayan, biçimi geçerli (base64url, >= 16) sahte belirteç.
  const token = 'test-magic-token-0001-abcdef';

  // ---------------------------------------------------------------------------
  // KONTROL: giriş çağrısından sonra hiçbir rota kapatmayan yollar
  // ---------------------------------------------------------------------------

  group('KONTROL (rota kapatmayan yollar)', () {
    for (final order in _Order.values) {
      _flowTest('[${order.label}] e-posta + şifre: istem açık kalır ve "Etkinleştir" biyometrik girişi açar', (tester) async {
        final rig = await _pumpRealApp(tester, order);

        await _submitLogin(tester);
        await _finishFlow(tester, rig, flow: 'e-posta+şifre', flowRoute: find.byType(LoginPage));

        expect(rig.env.cloud.loginArgs, hasLength(1), reason: 'hazırlık: giriş isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'e-posta+şifre', flowRoute: find.byType(LoginPage));
        await _enableFromPrompt(tester, rig);
      });

      _flowTest('[${order.label}] Google ile giriş: istem açık kalır ve "Etkinleştir" biyometrik girişi açar', (tester) async {
        // `AuthGate`, `LoginPage`'e jeton sağlayıcısı veremediği için kapının yerine aynı kararı
        // (`gateViewFor`) veren eşdeğer bir kapı kullanılır; giriş ve pano sayfaları gerçektir.
        final rig = await _pumpRealApp(tester, order, home: const _SocialGate());

        await tapKey(tester, 'btn_google_sign_in', settleAfter: false);
        await _finishFlow(tester, rig, flow: 'Google', flowRoute: find.byType(LoginPage));

        expect(rig.env.cloud.googleTokens, hasLength(1), reason: 'hazırlık: Google giriş isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'Google', flowRoute: find.byType(LoginPage));
        await _enableFromPrompt(tester, rig);
      });
    }

    _flowTest('[gecikmeli ev listesi] Apple ile giriş (iOS): istem açık kalır ve "Etkinleştir" biyometrik girişi açar', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final rig = await _pumpRealApp(tester, _Order.delayed, home: const _SocialGate());

        await tapKey(tester, 'btn_apple_sign_in', settleAfter: false);
        await _finishFlow(tester, rig, flow: 'Apple', flowRoute: find.byType(LoginPage));

        expect(rig.env.cloud.appleArgs, hasLength(1), reason: 'hazırlık: Apple giriş isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'Apple', flowRoute: find.byType(LoginPage));
        await _enableFromPrompt(tester, rig);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    _flowTest('[gecikmeli ev listesi] e-posta + şifre, doğrulama başarısız: istem AÇIK kalır, geri bildirim görünür, yeniden denenebilir', (tester) async {
      final rig = await _pumpRealApp(
        tester,
        _Order.delayed,
        biometric: FakeBiometric(supported: true, authResult: false, label: 'Parmak İzi'),
      );

      await _submitLogin(tester);
      await _finishFlow(tester, rig, flow: 'e-posta+şifre (başarısız doğrulama)', flowRoute: find.byType(LoginPage));
      await _expectPromptAwaitingDecision(tester, rig, flow: 'e-posta+şifre', flowRoute: find.byType(LoginPage));

      await tapKey(tester, 'btn_biometric_enable');

      expect(rig.biometric.authenticateCalls, 1);
      expect(find.byType(BiometricPromptDialog), findsOneWidget, reason: 'başarısız doğrulamada istem mesajsız kapanmaz');
      expect(find.byKey(const Key('biometric_feedback')), findsOneWidget);
      expect(rig.state.isBiometricEnabled, isFalse);
      expect(rig.state.shouldPromptBiometrics, isTrue, reason: 'karar verilmedi');
      expect(await rig.storage.isBiometricPromptShown(), isFalse);

      rig.biometric.authResult = true;
      await _enableFromPrompt(tester, rig, expectedAuthenticateCalls: 2);
    });

    _flowTest('zorunlu parola değişimi: istem, parola değişip pano açılınca gösterilir', (tester) async {
      final rig = await _pumpRealApp(
        tester,
        _Order.instant,
        configure: (env) => env.cloud.loginUser =
            const UserModel(id: kUserId, email: kUserEmail, fullName: 'Müşteri', mustChangePassword: true),
      );

      await _submitLogin(tester, password: 'gecici-parola-9');
      await settle(tester, frames: 8);
      expect(find.byType(ChangePasswordPage), findsOneWidget, reason: 'hazırlık: zorunlu parola ekranı');
      expect(find.byType(BiometricPromptDialog), findsNothing, reason: 'pano açılmadan istem gösterilmez');
      expect(rig.state.shouldPromptBiometrics, isTrue);

      await typeInto(tester, 'field_current_password', 'gecici-parola-9');
      await typeInto(tester, 'field_new_password', 'yepyeni-parola-123');
      await typeInto(tester, 'field_confirm_password', 'yepyeni-parola-123');
      await tapKey(tester, 'btn_change_password', settleAfter: false);
      await settle(tester, frames: 10);

      expect(rig.env.cloud.calls, contains('changePassword'), reason: 'hazırlık: parola değişti');
      await _expectPromptAwaitingDecision(tester, rig, flow: 'zorunlu parola değişimi', flowRoute: find.byType(ChangePasswordPage));
      await _enableFromPrompt(tester, rig);
    });

    _flowTest('servis PIN\'i (ServicePinDialog): istem hiç açılmaz, PIN diyaloğu kapanır ve pano görünür', (tester) async {
      final rig = await _pumpRealApp(tester, _Order.instant);

      await tapKey(tester, 'btn_service_pin');
      expect(find.byType(ServicePinDialog), findsOneWidget, reason: 'hazırlık: servis PIN diyaloğu açıldı');
      await typeInto(tester, 'field_service_pin', '123456');
      await tapKey(tester, 'btn_service_login', settleAfter: false);
      await settle(tester, frames: 10);

      expect(rig.env.cloud.calls, contains('serviceLogin'), reason: 'hazırlık: servis girişi yapıldı');
      expect(rig.state.isServiceSession, isTrue);
      expect(rig.state.shouldPromptBiometrics, isFalse, reason: 'servis oturumunda biyometrik istem istenmez');
      expect(find.byType(BiometricPromptDialog), findsNothing);
      expect(find.byType(ServicePinDialog), findsNothing, reason: 'PIN diyaloğu kendi rotasını kapattı');
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(rig.biometric.authenticateCalls, 0);
      expect(await rig.storage.isBiometricPromptShown(), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Giriş çağrısı döndükten sonra kendi rotasını kapatan akışlar
  // ---------------------------------------------------------------------------

  for (final order in _Order.values) {
    group('akış kendi rotasını kapatır [${order.label}]', () {
      _flowTest('kayıt (RegisterPage): akış bitince istem en üstte kalır, kayıt sayfası kapanır', (tester) async {
        final rig = await _pumpRealApp(tester, order);

        await _openRegisterAndSubmit(tester);
        await _finishFlow(tester, rig, flow: 'kayıt', flowRoute: find.byType(RegisterPage));

        expect(rig.env.cloud.calls, contains('register'), reason: 'hazırlık: kayıt isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'kayıt', flowRoute: find.byType(RegisterPage));
        await _enableFromPrompt(tester, rig);
      });

      _flowTest('telefon OTP (PhoneOtpDialog): akış bitince istem en üstte kalır, OTP diyaloğu kapanır', (tester) async {
        // SMS ile giriş düğmesi yalnız sunucu yeteneği bildirirse görünür (UYELIK-04).
        final rig = await _pumpRealApp(
          tester,
          order,
          configure: (env) => env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true),
        );

        await tapKey(tester, 'btn_phone_otp');
        expect(find.byType(PhoneOtpDialog), findsOneWidget, reason: 'hazırlık: OTP diyaloğu açıldı');
        await typeInto(tester, 'field_phone', '0555 111 22 33');
        await tapKey(tester, 'btn_otp_send');
        await typeInto(tester, 'field_code', '123456');
        await tapKey(tester, 'btn_otp_verify', settleAfter: false);
        await _finishFlow(tester, rig, flow: 'telefon OTP', flowRoute: find.byType(PhoneOtpDialog));

        expect(rig.env.cloud.calls, contains('verifyPhoneOtp'), reason: 'hazırlık: OTP doğrulama isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'telefon OTP', flowRoute: find.byType(PhoneOtpDialog));
        await _enableFromPrompt(tester, rig);
      });

      _flowTest('sihirli bağlantı, elle yapıştırma (MagicLinkPage): akış bitince istem en üstte kalır, bağlantı sayfası kapanır', (tester) async {
        final rig = await _pumpRealApp(tester, order);

        await tapKey(tester, 'btn_magic_link');
        await typeInto(tester, 'field_magic_link', 'https://${AppConfig.productionHost}/magic-login#token=$token');
        await tapKey(tester, 'btn_magic_link_continue', settleAfter: false);
        await _finishFlow(tester, rig, flow: 'sihirli bağlantı (yapıştırma)', flowRoute: find.byType(MagicLinkPage));

        expect(rig.env.cloud.magicTokens, <String>[token], reason: 'hazırlık: belirteç bir kez kullanıldı');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'sihirli bağlantı (yapıştırma)', flowRoute: find.byType(MagicLinkPage));
        await _enableFromPrompt(tester, rig);
      });

      _flowTest('sihirli bağlantı, derin bağlantı (MagicLinkPage): akış bitince istem en üstte kalır, bağlantı sayfası kapanır', (tester) async {
        final rig = await _pumpRealApp(tester, order);

        unawaited(rig.navKey.currentState!.pushNamed('/magic-login#token=$token'));
        await _finishFlow(tester, rig, flow: 'sihirli bağlantı (derin)', flowRoute: find.byType(MagicLinkPage));

        expect(rig.env.cloud.magicTokens, <String>[token], reason: 'hazırlık: belirteç bir kez kullanıldı');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'sihirli bağlantı (derin)', flowRoute: find.byType(MagicLinkPage));
        await _enableFromPrompt(tester, rig);
      });

      _flowTest('şifre sıfırlama bağlantısı (MagicLinkPage, sunucu oturum verir): akış bitince istem en üstte kalır, sayfa kapanır', (tester) async {
        final rig = await _pumpRealApp(tester, order, configure: (env) => env.cloud.resetReturnsSession = true);

        unawaited(rig.navKey.currentState!.pushNamed('/reset-password#token=$token'));
        await _settlePage(tester);
        expect(find.byKey(const Key('magic_reset_view')), findsOneWidget, reason: 'hazırlık: yeni şifre formu açıldı');
        await typeInto(tester, 'field_new_password', kStrongPassword);
        await typeInto(tester, 'field_confirm_password', kStrongPassword);
        await tapKey(tester, 'btn_magic_reset_submit', settleAfter: false);
        await _finishFlow(tester, rig, flow: 'şifre sıfırlama (bağlantı)', flowRoute: find.byType(MagicLinkPage));

        expect(rig.env.cloud.calls, contains('resetPassword'), reason: 'hazırlık: sıfırlama isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'şifre sıfırlama (bağlantı)', flowRoute: find.byType(MagicLinkPage));
        await _enableFromPrompt(tester, rig);
      });

      _flowTest('şifre sıfırlama kodu (ForgotPasswordDialog, sunucu oturum verir): akış bitince istem en üstte kalır, diyalog kapanır', (tester) async {
        final rig = await _pumpRealApp(tester, order, configure: (env) => env.cloud.resetReturnsSession = true);

        await tapKey(tester, 'btn_forgot_password');
        expect(find.byType(ForgotPasswordDialog), findsOneWidget, reason: 'hazırlık: şifre yenileme diyaloğu açıldı');
        await typeInto(tester, 'field_identifier', kUserEmail);
        await tapKey(tester, 'btn_send_code');
        await typeInto(tester, 'field_code', '123456');
        await typeInto(tester, 'field_new_password', kStrongPassword);
        await typeInto(tester, 'field_confirm_password', kStrongPassword);
        await tapKey(tester, 'btn_reset_password', settleAfter: false);
        await _finishFlow(tester, rig, flow: 'şifre sıfırlama (kod)', flowRoute: find.byType(ForgotPasswordDialog));

        expect(rig.env.cloud.calls, contains('resetPassword'), reason: 'hazırlık: sıfırlama isteği gitti');
        await _expectPromptAwaitingDecision(tester, rig, flow: 'şifre sıfırlama (kod)', flowRoute: find.byType(ForgotPasswordDialog));
        await _enableFromPrompt(tester, rig);
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Belirtinin güncel koddaki karşılığı: kullanıcı "Etkinleştir"e bastıktan sonra akış istemi kapatır
  // ---------------------------------------------------------------------------

  group('kullanıcı "Etkinleştir"e bastıktan sonra giriş çağrısı döner [gecikmeli ev listesi]', () {
    _flowTest('kayıt: doğrulama sürerken istem kapanmaz; doğrulama iptal olursa geri bildirim görünür (mesajsız kapanma yok)', (tester) async {
      final rig = await _pumpRealApp(tester, _Order.delayed);
      final gate = rig.env.cloud.fetchHomesGate!;

      await _openRegisterAndSubmit(tester);
      await settle(tester, frames: 8);
      _expectLoginCallStillWaitingForHomes(rig);

      // Sistem doğrulama ekranı açık kalır (kullanıcı henüz parmağını okutmadı / iptal etmedi).
      rig.biometric.pending = Completer<bool>();
      final tappedBeforeLoginReturned = find.byKey(const Key('btn_biometric_enable')).evaluate().isNotEmpty;
      if (tappedBeforeLoginReturned) {
        await tapKey(tester, 'btn_biometric_enable', settleAfter: false);
        await tester.pump();
        expect(rig.biometric.authenticateCalls, 1, reason: 'hazırlık: doğrulama başladı');
      }
      _tani('[tanı][kayıt + doğrulama sürüyor] giriş çağrısı DÖNMEDEN önce "Etkinleştir"e basıldı=$tappedBeforeLoginReturned '
          '${await _observe(tester, rig, find.byType(RegisterPage))}');

      gate.complete(); // giriş çağrısı döner; kayıt sayfası kendi kapanışını yapar
      await settle(tester, frames: 10);
      _tani('[tanı][kayıt + doğrulama sürüyor] giriş çağrısı döndükten sonra (doğrulama hâlâ sürüyor): '
          '${await _observe(tester, rig, find.byType(RegisterPage))}');
      final clearedBy = rig.promptClearedBy;
      if (clearedBy != null) {
        _tani('[tanı][kayıt + doğrulama sürüyor] doğrulama sürerken "istem gerekli" bayrağını düşüren çağrı zinciri:\n'
            '      ${_appFrames(clearedBy)}');
      }
      if (!tappedBeforeLoginReturned) {
        // İstem akış bitene kadar ertelendiyse kullanıcı şimdi basar.
        await tapKey(tester, 'btn_biometric_enable', settleAfter: false);
        await tester.pump();
        expect(rig.biometric.authenticateCalls, 1, reason: 'hazırlık: doğrulama başladı');
      }

      rig.biometric.pending!.complete(false); // kullanıcı sistem ekranını iptal etti / doğrulama başarısız
      await settle(tester);

      final seen = await _observe(tester, rig, find.byType(RegisterPage));
      _tani('[tanı][kayıt + doğrulama sürüyor] doğrulama iptal edildikten sonra: $seen '
          'geriBildirim=${find.byKey(const Key('biometric_feedback')).evaluate().isNotEmpty}');
      final problems = <String>[
        if (seen.prompts != 1) 'istem kullanıcıya sonuç gösterilmeden kapandı (BiometricPromptDialog sayısı ${seen.prompts})',
        if (find.byKey(const Key('biometric_feedback')).evaluate().isEmpty) 'başarısız/iptal doğrulamada geri bildirim görünmüyor',
        if (seen.flowRoutePresent) 'kayıt sayfası hâlâ ağaçta',
        if (!seen.shouldPrompt) 'kullanıcı karar vermeden shouldPromptBiometrics=false oldu',
        if (seen.promptShownStored) 'kullanıcı karar vermeden depoya "istem gösterildi" yazıldı',
        if (rig.state.isBiometricEnabled) 'doğrulama başarısızken biyometrik giriş açıldı',
      ];
      expect(problems, isEmpty, reason: 'giriş çağrısının dönmesi, doğrulaması süren istemi kapatmamalı');

      // Yeniden deneme: bu kez doğrulama başarılı.
      rig.biometric.pending = null;
      await _enableFromPrompt(tester, rig, expectedAuthenticateCalls: 2);
    });

    _flowTest('kayıt: giriş çağrısının döndüğü anda basılan "Etkinleştir" yutulmaz (doğrulama başlar, biyometrik giriş açılır)', (tester) async {
      final rig = await _pumpRealApp(tester, _Order.delayed);
      final gate = rig.env.cloud.fetchHomesGate!;

      await _openRegisterAndSubmit(tester);
      await settle(tester, frames: 8);
      _expectLoginCallStillWaitingForHomes(rig);

      gate.complete(); // giriş çağrısı döner; kayıt sayfası kendi kapanışını yapar
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60)); // (varsa) kapanış animasyonunun ortası
      final enable = find.byKey(const Key('btn_biometric_enable'));
      final buttonInTreeAtTap = enable.evaluate().isNotEmpty;
      final seenAtTap = await _observe(tester, rig, find.byType(RegisterPage));
      if (buttonInTreeAtTap) await tester.tap(enable, warnIfMissed: false);
      await settle(tester, frames: 10);
      _tani('[tanı][kayıt + kapanış anında dokunuş] dokunuş anında: düğme ağaçta=$buttonInTreeAtTap $seenAtTap');
      _tani('[tanı][kayıt + kapanış anında dokunuş] dokunuştan sonra: authenticate çağrısı=${rig.biometric.authenticateCalls} '
          '${await _observe(tester, rig, find.byType(RegisterPage))}');
      if (rig.biometric.authenticateCalls == 0 && enable.evaluate().isNotEmpty) {
        // İstem akış bittikten sonra açıldıysa kullanıcı şimdi basar.
        await tester.tap(enable);
        await settle(tester);
      }

      final problems = <String>[
        if (rig.biometric.authenticateCalls != 1)
          '"Etkinleştir" dokunuşu hiçbir şey yapmadı (authenticate çağrısı: ${rig.biometric.authenticateCalls}, beklenen: 1)',
        if (!rig.state.isBiometricEnabled) 'biyometrik giriş açılmadı',
        if (find.byType(BiometricPromptDialog).evaluate().isNotEmpty) 'başarılı doğrulamadan sonra istem hâlâ açık',
        if (find.byType(RegisterPage).evaluate().isNotEmpty) 'kayıt sayfası hâlâ ağaçta',
        if (!await rig.storage.isBiometricEnabled()) 'biyometrik tercih depoya yazılmadı',
      ];
      expect(problems, isEmpty, reason: 'kullanıcı "Etkinleştir" dediğinde doğrulama başlamalı; istem mesajsız kapanmamalı');
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Pano zaten açıkken yapılan giriş (DashboardPage yeniden kurulmaz)
  //
  // Ayrı ve daha düşük öncelikli bir kusur: istem yalnızca `DashboardPage.initState`'te açıldığı için, pano
  // ağaçtayken açılan yeni oturumda `shouldPromptBiometrics` true olsa da istem hiç gösterilmez.
  // ---------------------------------------------------------------------------

  group('pano açıkken yapılan giriş', () {
    _flowTest('hesap değişimi (sihirli bağlantı onayı): yeni oturum için istem gösterilir', (tester) async {
      // Açık oturum: kUserId; bağlantının hesabı: kOtherUserId (hesap gerçekten değişsin).
      final rig = await _pumpRealApp(
        tester,
        _Order.instant,
        authenticated: true,
        configure: (env) => env.cloud.registeredUser =
            const UserModel(id: kOtherUserId, email: 'diger@ornek.test', fullName: 'Diğer Hesap'),
      );
      expect(rig.state.currentUser?.id, kUserId, reason: 'hazırlık: ilk hesap açık');
      expect(find.byType(BiometricPromptDialog), findsNothing, reason: 'hazırlık: açık oturumda istem yok');
      final dashboardBefore = tester.state(find.byType(DashboardPage));

      unawaited(rig.navKey.currentState!.pushNamed('/magic-login#token=$token'));
      await _settlePage(tester);
      expect(find.byKey(const Key('magic_login_confirm_notice')), findsOneWidget, reason: 'hazırlık: hesap değişimi onayı istenir');
      expect(rig.env.cloud.magicTokens, isEmpty, reason: 'hazırlık: onaysız istek yok');
      await tapKey(tester, 'btn_magic_login_confirm', settleAfter: false);
      await _finishFlow(tester, rig, flow: 'hesap değişimi', flowRoute: find.byType(MagicLinkPage));

      expect(rig.env.cloud.magicTokens, <String>[token], reason: 'hazırlık: bağlantıyla giriş yapıldı');
      expect(rig.state.currentUser?.id, kOtherUserId, reason: 'hazırlık: oturum bağlantının hesabına geçti');
      _tani('[tanı][hesap değişimi] pano State nesnesi aynı kaldı (initState yeniden çalışmadı)='
          '${identical(dashboardBefore, tester.state(find.byType(DashboardPage)))}');
      await _expectPromptAwaitingDecision(tester, rig, flow: 'hesap değişimi', flowRoute: find.byType(MagicLinkPage));
      await _enableFromPrompt(tester, rig);
    });
  });
}

// =============================================================================
// Düzenek
// =============================================================================

enum _Order {
  /// Sahte API aynı mikro görev zincirinde yanıtlar: giriş çağrısı ilk kareden ÖNCE döner.
  instant('anında yanıt'),

  /// `fetchHomes` bekletilir: pano ve istem, giriş çağrısı dönmeden ÖNCE açılır (gerçek ağ sırası).
  delayed('gecikmeli ev listesi');

  const _Order(this.label);

  final String label;
}

class _Rig {
  _Rig(this.env, this.navKey, this.order);

  final E2Env env;
  final GlobalKey<NavigatorState> navKey;
  final _Order order;

  AutomationState get state => env.state;
  FakeBiometric get biometric => env.h.biometric;
  FakeStorage get storage => env.h.storage;

  /// `shouldPromptBiometrics` ilk kez true -> false olduğu andaki çağrı yığını (tanı: istemi kim kapattı).
  StackTrace? promptClearedBy;

  /// Navigator yığınının en üstündeki rota (hiçbir şeyi kapatmadan okunur).
  Route<dynamic>? get topRoute {
    Route<dynamic>? top;
    navKey.currentState!.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }
}

/// `AuthGate` ile aynı kararı ([gateViewFor]) veren, ama `LoginPage`'e sahte Google/Apple jeton sağlayıcısı
/// verebilen kapı (gerçek `AuthGate` sağlayıcı enjekte edemez). Giriş ve pano sayfaları gerçektir.
class _SocialGate extends StatelessWidget {
  const _SocialGate();

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, AuthGateView>(gateViewFor);
    if (view == AuthGateView.dashboard) return const DashboardPage(key: ValueKey('dashboard_screen'));
    return LoginPage(
      key: const ValueKey('login_screen'),
      googleIdTokenProvider: () async => 'sahte-google-kimlik-jetonu',
      appleProvider: () async => const AppleSignInResult(identityToken: 'sahte-apple-kimlik-jetonu', rawNonce: 'sahte-nonce'),
    );
  }
}

/// Kırmızı (başarısız) bir test, ağacını bir sonraki teste bırakmasın: ağaç bu testin içinde kaldırılır ve
/// kabuğun kapanışta kurduğu kısa zamanlayıcı (push durdurma sınırı, 3 sn) tüketilir.
void _flowTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    }
  });
}

/// Gerçek uygulama ağacı: `AppShell` (MaterialApp + derin bağlantı üreteci) + `AuthGate`; servisler sahte.
/// Biyometrik destekleniyor (varsayılan: doğrulama başarılı), "istem gösterildi" kaydı yok.
/// [authenticated] `false` ise oturum yoktur (giriş ekranı); `true` ise ev sahibi oturumu ve pano açıktır.
Future<_Rig> _pumpRealApp(
  WidgetTester tester,
  _Order order, {
  FakeBiometric? biometric,
  bool authenticated = false,
  Widget home = const AuthGate(),
  void Function(E2Env env)? configure,
}) async {
  final env = e2Env(
    authenticated: authenticated,
    biometric: biometric ?? FakeBiometric(supported: true, authResult: true, label: 'Parmak İzi'),
  );
  env.cloud.homes = [testHome()];
  env.cloud.endpoints[kHomeA] = testEndpoints();
  if (order == _Order.delayed) env.cloud.fetchHomesGate = Completer<void>();
  configure?.call(env);

  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: AppShell(navigatorKey: navKey, home: home),
    ),
  );
  await settle(tester);
  expect(find.byType(authenticated ? DashboardPage : LoginPage), findsOneWidget, reason: 'hazırlık: başlangıç ekranı');
  expect(await env.h.storage.isBiometricPromptShown(), isFalse, reason: 'hazırlık: istem daha önce gösterilmedi');

  final rig = _Rig(env, navKey, order);
  // Tanı: "istem gerekli" bayrağını ilk kez düşüren çağrı zinciri yakalanır (dinleyici eşzamanlı çağrılır).
  var prompting = env.state.shouldPromptBiometrics;
  void watch() {
    final now = env.state.shouldPromptBiometrics;
    if (prompting && !now) rig.promptClearedBy ??= StackTrace.current;
    prompting = now;
  }

  env.state.addListener(watch);
  addTearDown(() => env.state.removeListener(watch));
  return rig;
}

/// Çağrı yığınından yalnızca uygulama ve Navigator kapanış çerçeveleri (tanı çıktısı için).
String _appFrames(StackTrace trace) => trace
    .toString()
    .split('\n')
    .where((line) => line.contains('package:ev_otomasyon/') || line.contains('NavigatorState.pop'))
    .map((line) => line.replaceFirst(RegExp(r'^#\d+\s+'), '').trim())
    .take(8)
    .join('\n      <- ');

/// Sayfa geçişi (Android varsayılanı 450 ms) bitene kadar kareleri işler.
Future<void> _settlePage(WidgetTester tester) => settle(tester, frames: 8);

Future<void> _submitLogin(WidgetTester tester, {String password = kStrongPassword}) async {
  await typeInto(tester, 'field_email', kUserEmail);
  await typeInto(tester, 'field_password', password);
  await tapKey(tester, 'btn_login', settleAfter: false);
}

Future<void> _openRegisterAndSubmit(WidgetTester tester) async {
  await tapKey(tester, 'btn_register', settleAfter: false);
  await _settlePage(tester); // geçiş bitince giriş sayfası sahne dışı kalır (aynı anahtarlı alanlar karışmaz)
  expect(find.byType(RegisterPage), findsOneWidget, reason: 'hazırlık: kayıt sayfası açıldı');
  await typeInto(tester, 'field_full_name', 'Ayşe Yılmaz');
  await typeInto(tester, 'field_email', kUserEmail);
  await typeInto(tester, 'field_password', kStrongPassword);
  await typeInto(tester, 'field_password_confirm', kStrongPassword);
  await tapKey(tester, 'chk_accept_terms'); // zorunlu Kullanıcı Sözleşmesi onayı
  await tapKey(tester, 'btn_register_submit', settleAfter: false);
}

/// O anki gözlem (tanı çıktısı ve son durum denetimi için).
class _Seen {
  _Seen({
    required this.prompts,
    required this.promptOnTop,
    required this.flowRoutePresent,
    required this.shouldPrompt,
    required this.promptShownStored,
    required this.top,
  });

  /// Ağaçtaki `BiometricPromptDialog` sayısı.
  final int prompts;

  /// İstemin rotası Navigator yığınının en üstünde mi.
  final bool promptOnTop;

  /// Akışın kendi rotası (kayıt sayfası / OTP diyaloğu / bağlantı sayfası ...) hâlâ ağaçta mı.
  final bool flowRoutePresent;
  final bool shouldPrompt;

  /// Depoda "istem gösterildi" kaydı var mı.
  final bool promptShownStored;
  final String top;

  @override
  String toString() => 'istem=$prompts enUstte=$promptOnTop akisRotasi=$flowRoutePresent '
      'shouldPrompt=$shouldPrompt depoPromptShown=$promptShownStored ustRota=$top';
}

Future<_Seen> _observe(WidgetTester tester, _Rig rig, Finder flowRoute) async {
  final promptElements = find.byType(BiometricPromptDialog).evaluate().toList();
  final onTop = promptElements.length == 1 && (ModalRoute.of(promptElements.single)?.isCurrent ?? false);
  return _Seen(
    prompts: promptElements.length,
    promptOnTop: onTop,
    flowRoutePresent: flowRoute.evaluate().isNotEmpty,
    shouldPrompt: rig.state.shouldPromptBiometrics,
    promptShownStored: await rig.storage.isBiometricPromptShown(),
    top: rig.topRoute.runtimeType.toString(),
  );
}

/// Düzenek ön koşulu (gecikmeli sıra): giriş yanıtı alındı, ev listesi isteği yolda ve henüz yanıtlanmadı;
/// yani giriş çağrısı (`register` / `verifyPhoneOtp` / ...) hâlâ `fetchHomes`'ta bekliyor.
void _expectLoginCallStillWaitingForHomes(_Rig rig) {
  expect(rig.env.cloud.fetchHomesGate!.isCompleted, isFalse, reason: 'hazırlık: ev listesi yanıtı bekletiliyor');
  expect(rig.env.cloud.count('fetchHomes'), greaterThan(0), reason: 'hazırlık: giriş yanıtı alındı, ev listesi isteği yolda');
  expect(rig.state.homesLoaded, isFalse, reason: 'hazırlık: giriş çağrısı henüz dönmedi (fetchHomes bekliyor)');
}

/// Giriş isteği gönderildikten sonra akışı sonuna kadar yürütür.
///
/// * anında yanıt: kareler işlenir (giriş çağrısı ilk kareden önce dönmüştür).
/// * gecikmeli ev listesi: önce kareler işlenir (pano + istem açılır; giriş çağrısı `fetchHomes`'ta bekler),
///   ara durum tanı için yazdırılır, sonra ev listesi yanıtı serbest bırakılır ve akışın kendi kapanışı çalışır.
Future<void> _finishFlow(WidgetTester tester, _Rig rig, {required String flow, required Finder flowRoute}) async {
  await settle(tester, frames: 8);
  final tag = '[tanı][$flow][${rig.order.label}]';
  if (rig.order == _Order.delayed) {
    _expectLoginCallStillWaitingForHomes(rig);
    _tani('$tag giriş çağrısı DÖNMEDEN önce: ${await _observe(tester, rig, flowRoute)}');
    rig.env.cloud.fetchHomesGate!.complete();
  }
  await settle(tester, frames: 10);
  _tani('$tag akış bittikten sonra: ${await _observe(tester, rig, flowRoute)}');
  final clearedBy = rig.promptClearedBy;
  if (clearedBy != null) {
    _tani('$tag kullanıcı karar vermeden "istem gerekli" bayrağını düşüren çağrı zinciri:\n      ${_appFrames(clearedBy)}');
  }
}

/// İSTENEN son durum: istem tam bir kez ve en üstte; akışın kendi rotası kapanmış; kullanıcı henüz karar
/// vermediği için `shouldPromptBiometrics` true ve depoda "istem gösterildi" kaydı yok.
Future<void> _expectPromptAwaitingDecision(
  WidgetTester tester,
  _Rig rig, {
  required String flow,
  required Finder flowRoute,
}) async {
  final seen = await _observe(tester, rig, flowRoute);
  final problems = <String>[
    if (seen.prompts != 1) 'BiometricPromptDialog sayısı ${seen.prompts} (beklenen: tam 1)',
    if (seen.prompts == 1 && !seen.promptOnTop) 'istem en üstteki rota değil (üstteki: ${seen.top})',
    if (seen.flowRoutePresent) 'akışın kendi rotası hâlâ ağaçta (üstteki rota: ${seen.top})',
    if (!seen.shouldPrompt) 'kullanıcı karar vermeden shouldPromptBiometrics=false oldu',
    if (seen.promptShownStored) 'kullanıcı karar vermeden depoya "istem gösterildi" yazıldı',
    if (rig.state.isBiometricEnabled) 'kullanıcı onaylamadan biyometrik giriş açıldı',
  ];
  expect(problems, isEmpty, reason: '$flow akışı bittikten sonra biyometrik istem kullanıcının kararını beklemeli');
  expect(rig.biometric.authenticateCalls, 0, reason: 'kullanıcı dokunmadan doğrulama başlatılmaz');
  expect(tester.takeException(), isNull);
}

/// "Evet, Etkinleştir": doğrulama (sahte: başarılı) yapılır, biyometrik giriş açılır ve istem kapanır.
Future<void> _enableFromPrompt(WidgetTester tester, _Rig rig, {int expectedAuthenticateCalls = 1}) async {
  await tapKey(tester, 'btn_biometric_enable');
  await settle(tester);

  expect(rig.biometric.authenticateCalls, expectedAuthenticateCalls, reason: 'dokunuş başına tek doğrulama isteği');
  expect(rig.state.isBiometricEnabled, isTrue, reason: 'biyometrik giriş açıldı');
  expect(rig.state.shouldPromptBiometrics, isFalse, reason: 'karar verildi');
  expect(find.byType(BiometricPromptDialog), findsNothing, reason: 'istem kapandı');
  expect(await rig.storage.isBiometricEnabled(), isTrue, reason: 'tercih kalıcı yazıldı');
  expect(find.byType(DashboardPage), findsOneWidget, reason: 'kullanıcı panoda');
  expect(tester.takeException(), isNull);
}
