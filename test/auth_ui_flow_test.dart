import 'dart:async';

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/social_sign_in.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Giriş ve kayıt akışları (sahte API ile): doğrulama kuralları, hata gösterimi, bekleme süreleri,
/// çift dokunuş koruması, sosyal giriş kuralları. Metin varlığı değil **davranış** doğrulanır.
/// Platformu geçici olarak değiştirir ve **test gövdesi bitmeden** geri alır (aksi halde test çerçevesi
/// "foundation değişkeni değişti" hatası verir).
Future<void> withPlatform(TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('LoginPage', () {
    testWidgets('boş form gönderilmez: yalnızca "boş mu" hataları gösterilir, API çağrılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await tapKey(tester, 'btn_login');

      expect(find.text('Lütfen e-posta adresinizi girin'), findsOneWidget);
      expect(find.text('Lütfen şifrenizi girin'), findsOneWidget);
      expect(env.cloud.loginArgs, isEmpty);
    });

    testWidgets('geçersiz e-posta reddedilir; kısa şifre giriş formunda reddedilmez (politika kayıtta)', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await typeInto(tester, 'field_email', 'gecersiz-adres');
      await typeInto(tester, 'field_password', '123');
      await tapKey(tester, 'btn_login');

      expect(find.text('Geçerli bir e-posta adresi girin'), findsOneWidget);
      expect(find.text('Şifre en az 10 karakter olmalıdır'), findsNothing);
      expect(find.text('Şifre en az 6 karakter olmalıdır'), findsNothing);
      expect(env.cloud.loginArgs, isEmpty);
    });

    testWidgets('geçerli ama alışılmadık e-posta (artı etiketi, uzun TLD) ve kısa şifreyle giriş yapılır', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await typeInto(tester, 'field_email', '  ayse+ev@alt.ornek.photography ');
      await typeInto(tester, 'field_password', 'kisa');
      await tapKey(tester, 'btn_login');

      expect(env.cloud.loginArgs, hasLength(1));
      expect(env.cloud.loginArgs.single['identifier'], 'ayse+ev@alt.ornek.photography', reason: 'e-posta kırpılır');
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('şifre ASLA kırpılmaz (başında/sonunda boşluk sunucuya aynen gider)', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', ' bosluklu parola ');
      await tapKey(tester, 'btn_login');

      expect(env.cloud.lastLoginPassword, ' bosluklu parola ');
      expect(env.cloud.loginArgs.single['passwordEdgeSpace'], isTrue);
    });

    testWidgets('sunucu hatası kullanıcıya Türkçe gösterilir; ham istisna metni gösterilmez', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.loginError = apiError(401, 'Geçersiz e-posta / telefon veya şifre.', code: 'INVALID_CREDENTIALS');
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', 'yanlis-parola');
      await tapKey(tester, 'btn_login');

      expect(textOf(tester, 'login_error'), 'Geçersiz e-posta / telefon veya şifre.');
      expect(find.textContaining('Exception'), findsNothing);
      expect(env.state.authStatus, isNot(AuthStatus.authenticated));

      env.cloud.loginError = StateError('SELECT * FROM users -- iç ayrıntı');
      await tapKey(tester, 'btn_login');
      expect(find.textContaining('SELECT'), findsNothing);
      expect(textOf(tester, 'login_error'), 'Giriş yapılamadı. Lütfen tekrar deneyin.');
    });

    testWidgets('hız sınırı (429): geri sayım gösterilir, düğme kapanır ve süre dolunca açılır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.loginError = apiError(
        429,
        'Çok fazla hatalı giriş denemesi. Lütfen daha sonra tekrar deneyin.',
        code: 'RATE_LIMITED',
        retryAfter: const Duration(seconds: 30),
      );
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', 'parola-123456');
      await tapKey(tester, 'btn_login');

      expect(find.textContaining('Tekrar dene (0:30)'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_login'))).onPressed, isNull);

      env.cloud.loginError = null;
      env.clock.advance(const Duration(seconds: 31));
      await tester.pump();
      expect(find.text('Giriş Yap'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_login'))).onPressed, isNotNull);
    });

    testWidgets('oturum sona erdiyse açıklayıcı iletiyi gösterir ve "Tamam" ile temizler', (tester) async {
      final env = e2Env();
      env.cloud.onSessionExpired!(SessionEndReason.refreshRejected); // oturum sunucuda bitti
      await pumpApp(tester, state: env.state, child: const LoginPage());
      expect(env.state.sessionNotice, isNotNull);
      expect(find.byKey(const Key('login_session_notice')), findsOneWidget);

      await tapKey(tester, 'btn_dismiss_notice');

      expect(env.state.sessionNotice, isNull);
      expect(find.byKey(const Key('login_session_notice')), findsNothing);
    });

    testWidgets('yerel ağ modu düğmesi doğrudan modu açar', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await tapKey(tester, 'btn_local_mode');

      expect(env.state.mode, AppMode.direct);
    });
  });

  group('Sosyal giriş', () {
    testWidgets("Apple düğmesi yalnızca iOS/macOS'ta görünür", (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());
      expect(find.byKey(const Key('btn_apple_sign_in')), findsNothing, reason: 'Android: Apple yok');
      expect(find.byKey(const Key('btn_google_sign_in')), findsOneWidget);

      for (final platform in <TargetPlatform>[TargetPlatform.iOS, TargetPlatform.macOS]) {
        await withPlatform(platform, () async {
          await tester.pumpWidget(const SizedBox());
          await pumpApp(tester, state: env.state, child: const LoginPage());
          expect(find.byKey(const Key('btn_apple_sign_in')), findsOneWidget, reason: '$platform: Apple var');
        });
      }
      await withPlatform(TargetPlatform.windows, () async {
        await tester.pumpWidget(const SizedBox());
        await pumpApp(tester, state: env.state, child: const LoginPage());
        expect(find.byKey(const Key('btn_apple_sign_in')), findsNothing, reason: 'Windows: Apple yok');
      });
    });

    testWidgets('Apple iptali SESSİZDİR: hata gösterilmez, sunucuya istek gitmez', (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        final env = e2Env(authenticated: false);
        await pumpApp(tester, state: env.state, child: LoginPage(appleProvider: () async => null));

        await tapKey(tester, 'btn_apple_sign_in');

        expect(find.byKey(const Key('login_error')), findsNothing);
        expect(env.cloud.calls.contains('loginWithApple'), isFalse);
        expect(env.state.authStatus, isNot(AuthStatus.authenticated));
      });
    });

    testWidgets('Apple: doğrulanmış kimlik jetonu, ad ve HAM nonce sunucuya iletilir', (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        final env = e2Env(authenticated: false);
        await pumpApp(
          tester,
          state: env.state,
          child: LoginPage(
            appleProvider: () async => const AppleSignInResult(
              identityToken: 'apple-kimlik-jetonu',
              rawNonce: 'ham-nonce-123',
              fullName: 'Ayşe Yılmaz',
            ),
          ),
        );

        await tapKey(tester, 'btn_apple_sign_in');

        expect(env.cloud.appleArgs.single, <String, String?>{'fullName': 'Ayşe Yılmaz', 'nonce': 'ham-nonce-123'});
        expect(env.state.authStatus, AuthStatus.authenticated);
      });
    });

    testWidgets('Apple hatası açık mesajla gösterilir', (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        final env = e2Env(authenticated: false);
        await pumpApp(
          tester,
          state: env.state,
          child: LoginPage(appleProvider: () async => throw const SocialAuthException('Apple kimlik jetonu alınamadı. Lütfen tekrar deneyin.')),
        );

        await tapKey(tester, 'btn_apple_sign_in');

        expect(textOf(tester, 'login_error'), 'Apple kimlik jetonu alınamadı. Lütfen tekrar deneyin.');
      });
    });

    testWidgets('Google: kimlik jetonu YOKSA açık hata gösterilir ve sunucuya hiçbir istek gitmez', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(
        tester,
        state: env.state,
        child: LoginPage(
          googleIdTokenProvider: () async => throw const SocialAuthException(
            'Google kimlik doğrulama jetonu alınamadı. Uygulamanın Google yapılandırması eksik olabilir; e-posta ile giriş yapmayı deneyin.',
          ),
        ),
      );

      await tapKey(tester, 'btn_google_sign_in');

      expect(textOf(tester, 'login_error'), contains('Google kimlik doğrulama jetonu alınamadı'));
      expect(env.cloud.calls.contains('loginWithGoogle'), isFalse, reason: 'istemci jetonsuz e-posta göndermez');
    });

    testWidgets('Google: kullanıcı vazgeçerse sessizdir; jeton varsa YALNIZCA jeton gönderilir', (tester) async {
      final env = e2Env(authenticated: false);
      var token = '';
      await pumpApp(
        tester,
        state: env.state,
        child: LoginPage(googleIdTokenProvider: () async => token.isEmpty ? null : token),
      );

      await tapKey(tester, 'btn_google_sign_in');
      expect(find.byKey(const Key('login_error')), findsNothing, reason: 'iptal sessiz');
      expect(env.cloud.googleTokens, isEmpty);

      token = 'google-kimlik-jetonu';
      await tapKey(tester, 'btn_google_sign_in');
      expect(env.cloud.googleTokens, <String>['google-kimlik-jetonu']);
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('sosyal giriş sürerken ikinci dokunuş ikinci istek başlatmaz', (tester) async {
      final env = e2Env(authenticated: false);
      final gate = Completer<String?>();
      var calls = 0;
      await pumpApp(
        tester,
        state: env.state,
        child: LoginPage(googleIdTokenProvider: () {
          calls++;
          return gate.future;
        }),
      );

      await tester.tap(find.byKey(const Key('btn_google_sign_in')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_google_sign_in')), warnIfMissed: false);
      await tester.pump();

      expect(calls, 1);
      gate.complete(null);
      await settle(tester);
    });
  });

  group('Servis PIN girişi', () {
    testWidgets('PIN yalnızca rakamdır ve 6 haneyle sınırlıdır; eksik PIN gönderilmez', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await tapKey(tester, 'btn_service_pin');

      await typeInto(tester, 'field_service_pin', '12ab34567890');
      expect(tester.widget<TextField>(find.byKey(const Key('field_service_pin'))).controller!.text, '123456');

      await typeInto(tester, 'field_service_pin', '123');
      await tapKey(tester, 'btn_service_login');
      expect(textOf(tester, 'service_pin_error'), 'Lütfen 6 haneli geçerli PIN giriniz');
      expect(env.cloud.calls.contains('serviceLogin'), isFalse);
    });

    testWidgets('PIN kilitliyse (423) geri sayım gösterilir ve düğme süre dolana kadar kapalıdır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.serviceLoginError = apiError(423, 'Çok fazla hatalı deneme.', code: 'PIN_LOCKED', retryAfter: const Duration(seconds: 45));
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await tapKey(tester, 'btn_service_pin');

      await typeInto(tester, 'field_service_pin', '123456');
      await tapKey(tester, 'btn_service_login');

      expect(find.byKey(const Key('service_pin_lock')), findsOneWidget);
      expect(find.textContaining('0:45'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_service_login'))).onPressed, isNull);

      env.clock.advance(const Duration(seconds: 46));
      await tester.pump();
      expect(find.byKey(const Key('service_pin_lock')), findsNothing);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_service_login'))).onPressed, isNotNull);
    });

    testWidgets('doğru PIN servis oturumu açar ve teknisyen adı iletilir', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());
      await tapKey(tester, 'btn_service_pin');

      await typeInto(tester, 'field_service_pin', '123456');
      await typeInto(tester, 'field_service_technician', 'Usta Ahmet');
      await tapKey(tester, 'btn_service_login');
      await settle(tester);

      expect(env.state.isServiceSession, isTrue);
      expect(env.state.serviceSession?.technicianName, 'Usta Ahmet');
      expect(find.byKey(const Key('field_service_pin')), findsNothing, reason: 'diyalog kapandı');
    });
  });

  group('RegisterPage', () {
    Future<void> fillValid(WidgetTester tester, {String phone = '', String password = kStrongPassword}) async {
      await typeInto(tester, 'field_full_name', 'Ayşe Yılmaz');
      await typeInto(tester, 'field_email', 'yeni+kayit@ornek.com.tr');
      await typeInto(tester, 'field_email_confirm', 'yeni+kayit@ornek.com.tr');
      if (phone.isNotEmpty) await typeInto(tester, 'field_phone', phone);
      await typeInto(tester, 'field_password', password);
      await typeInto(tester, 'field_password_confirm', password);
      await tapKey(tester, 'chk_accept_terms'); // zorunlu Kullanıcı Sözleşmesi onayı
    }

    testWidgets('boş alanlar ve politika dışı şifre reddedilir; API çağrılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const RegisterPage());
      await settle(tester); // güncel sözleşme sürümü alındı
      await tapKey(tester, 'chk_accept_terms'); // onaysız düğme zaten pasif: doğrulama hataları için işaretlenir

      await tapKey(tester, 'btn_register_submit');
      expect(find.text('Lütfen adınızı ve soyadınızı girin'), findsOneWidget);
      expect(find.text('Lütfen e-posta adresinizi girin'), findsOneWidget);
      expect(find.text('Lütfen bir şifre belirleyin'), findsOneWidget);

      await typeInto(tester, 'field_full_name', 'Ali Veli');
      await typeInto(tester, 'field_email', 'ali@test.com');
      await typeInto(tester, 'field_password', 'kisa123');
      await typeInto(tester, 'field_password_confirm', 'baska1234');
      await tapKey(tester, 'btn_register_submit');
      expect(find.text('Şifre en az 10 karakter olmalıdır'), findsOneWidget);
      expect(find.text('Şifreler eşleşmiyor'), findsOneWidget);
      expect(env.cloud.registerArgs, isEmpty);
    });

    testWidgets('geçersiz telefon reddedilir; geçerli telefon kanonik +905XXXXXXXXX gönderilir (karar 11)', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const RegisterPage());

      await fillValid(tester, phone: '555 12');
      await tapKey(tester, 'btn_register_submit');
      expect(find.textContaining('10 hane'), findsOneWidget);
      expect(env.cloud.registerArgs, isEmpty);

      await typeInto(tester, 'field_phone', '0555 123-45 67'); // yapıştırılan 0'lı biçim
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_phone'))).controller!.text, '555 123 45 67');
      await tapKey(tester, 'btn_register_submit');
      expect(env.cloud.registerArgs.single['phone'], '+905551234567');
    });

    testWidgets('telefon alanı sabit +90 önekli; yalnız rakam, 3-3-2-2 gruplanır', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const RegisterPage());
      await typeInto(tester, 'field_phone', 'abc0555 xyz');
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_phone'))).controller!.text, '555');
      await typeInto(tester, 'field_phone', '+90 555 1234567');
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_phone'))).controller!.text, '555 123 45 67');
      expect(find.text('+90 '), findsOneWidget);
    });

    testWidgets('e-posta tekrarı eşleşmezse gönderilmez; büyük/küçük harf ve boşluk farkı sorun değil (karar 9)', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const RegisterPage());
      await fillValid(tester);
      await typeInto(tester, 'field_email_confirm', 'yeni+kayit@ornek.com');
      await tapKey(tester, 'btn_register_submit');
      expect(find.text('E-posta adresleri eşleşmiyor'), findsOneWidget);
      expect(env.cloud.registerArgs, isEmpty);

      await typeInto(tester, 'field_email_confirm', '  YENI+kayit@Ornek.com.tr ');
      await tapKey(tester, 'btn_register_submit');
      expect(find.text('E-posta adresleri eşleşmiyor'), findsNothing);
      expect(env.cloud.registerArgs.single['email'], 'yeni+kayit@ornek.com.tr');
    });

    testWidgets('başarılı kayıt: e-posta kırpılır, şifre kırpılmaz, oturum açılır ve sayfa kapanır', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const RegisterPage());

      await fillValid(tester, password: '  boşluklu-parola  ');
      await tapKey(tester, 'btn_register_submit');
      await settle(tester);

      final args = env.cloud.registerArgs.single;
      expect(args['email'], 'yeni+kayit@ornek.com.tr');
      expect(args['passwordEdgeSpace'], isTrue, reason: 'şifre kırpılmadan gitti');
      expect(args['phone'], isNull, reason: 'boş telefon gönderilmez');
      expect(args['acceptTermsVersion'], 1, reason: 'onaylanan sözleşme sürümü kayıtla gider');
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('sunucu hatası dostu mesajla gösterilir (örn. e-posta kayıtlı)', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.registerError = apiError(409, 'Bu e-posta adresi zaten kayıtlı.', code: 'CONFLICT');
      await pumpApp(tester, state: env.state, child: const RegisterPage());

      await fillValid(tester);
      await tapKey(tester, 'btn_register_submit');

      expect(textOf(tester, 'register_error'), 'Bu e-posta adresi zaten kayıtlı.');
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('çift dokunuşta yalnızca BİR kayıt isteği gider', (tester) async {
      final env = e2Env(authenticated: false);
      final gate = Completer<void>();
      env.cloud.registerGate = gate;
      await pumpApp(tester, state: env.state, child: const RegisterPage());
      await fillValid(tester);

      await tester.ensureVisible(find.byKey(const Key('btn_register_submit')));
      await tester.tap(find.byKey(const Key('btn_register_submit')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_register_submit')), warnIfMissed: false);
      await tester.pump();

      expect(env.cloud.registerArgs, hasLength(1));
      gate.complete();
      await settle(tester);
    });
  });
}
