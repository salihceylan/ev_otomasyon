@Tags(['visual'])
library;

// WP-V3 AUTH/SHELL görsel galerisi: açılış, giriş, kayıt, şifre sıfırlama diyaloğu, OTP diyaloğu, zorunlu parola,
// biyometrik kilit, yıkıcı onay diyaloğu. Koyu + açık tema, yazı ölçeği 1.0 ve 1.5, 360 dp telefon.
//
// WP-F4 (eleştirmen bulguları): hata/bekleme/yükleme/bildirim durumları (giriş hata iletisi, 429 geri sayım, düğme
// yükleme hâli, oturum bildirimi, alan hataları, kod adımları, biyometrik geri bildirim, devre dışı onay düğmesi,
// açılış "yavaş başlatma" bildirimi) ve tablet genişliği eklendi. Sayfa PNG'leri içerik yüksekliğine göre
// kırpılır (üst/alt boş bant yok). Kayıt ekranı gerçek akıştaki gibi `Navigator.push` ile açılır (geri oku görünür).
//
// WP-FX-B (2. tur eleştirmen bulguları): şifre yenileme 2. adım hatalı kod (kırmızı kod alanı + tek "Kalan deneme"
// iletisi alanın altında), servis PIN diyaloğu ve "E-postadaki bağlantım var" diyaloğu eklendi (galeri boşlukları);
// kayıt / zorunlu parola üst çubukları NeonAppBar (cam geri diski; zorunlu kipte geri YOK, "Çıkış" cam disk eylemi).
//
//   flutter test --tags visual --update-goldens test/visual/auth     -> test/visual/auth/goldens/*.png üretir
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/auth         -> kayıtlı PNG'lerle karşılaştırır
//
// MotionScope(full) + AmbientClock.fixed: giriş koreografileri bitirilir, ambient katmanlar (veri nabzı, orb
// nefesi) belirli bir andan dondurulur (deterministik).

import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/service_pin_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/support.dart';
import '../../ui/e2_support.dart';
import '../support/golden_support.dart';

/// 360 dp telefon (DPR 2). Yükseklik ekran ailesine göre.
const Size _phone = Size(360, 740);

/// Giriş isteğini bir kapı açılana kadar bekleten sahte bulut (düğme "yükleniyor" hâlini yakalamak için).
class _GatedCloud extends E2Cloud {
  _GatedCloud({super.clock});

  final Completer<void> loginGate = Completer<void>();

  @override
  Future<Map<String, dynamic>> login(String identifier, String password) async {
    await loginGate.future;
    return super.login(identifier, password);
  }
}

/// [e2Env] ile aynı kurulum (oturumsuz), ama giriş isteği kapıda bekler.
E2Env _gatedLoginEnv() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final clock = FakeClock();
  final cloud = _GatedCloud(clock: clock);
  final h = StateHarness(clock: clock, cloud: cloud);
  h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
  addTearDown(h.dispose);
  return E2Env(h, cloud);
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required AutomationState state,
  required GlobalKey boundaryKey,
  required Brightness brightness,
  required double textScale,
  required Widget home,
  Size size = _phone,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(size.width * 2, size.height * 2);
  addTearDown(tester.view.reset);
  final shadowsWere = debugDisableShadows;
  debugDisableShadows = false;
  addTearDown(() => debugDisableShadows = shadowsWere);

  final clock = AmbientClock.fixed(0.65);
  addTearDown(clock.dispose);
  await tester.pumpWidget(
    MotionScope(
      mode: MotionMode.full,
      clock: clock,
      child: ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(Brightness.light),
          darkTheme: goldenTheme(Brightness.dark),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          // Gerçek uygulama gibi: CircuitBackground tüm ekranların arkasında (app_shell builder'ı).
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(key: boundaryKey, child: CircuitBackground(child: child!)),
          ),
          home: home,
        ),
      ),
    ),
  );
  // Görüntüler (arka plan JPEG'leri + logo) gerçek async ile çözülür.
  final ctx = tester.element(find.byType(MaterialApp));
  await tester.runAsync(() async {
    for (final asset in const ['assets/images/ai_circuit_bg.jpg', 'assets/images/ai_circuit_bg_light.jpg', 'assets/images/round_app_logo.png']) {
      await precacheImage(AssetImage(asset), ctx);
    }
  });
  await tester.pump();
}

/// Giriş koreografilerini bitirir (sonsuz animasyonlu gösterge olabilir: pumpAndSettle YOK).
Future<void> _advance(WidgetTester tester, {int ms = 1000}) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Sayfa yüksekliğini İÇERİĞE göre kırpar: kaydırılabilir alanın gerçek içerik uzunluğu ölçülür (önce küçük bir
/// yükseklikte kurulup `maxScrollExtent` okunur), PNG üst/alt boş bant içermez. [extra]: ek boşluk (dp).
Future<void> _fitHeight(WidgetTester tester, {required double width, double extra = 0}) async {
  tester.view.physicalSize = Size(width * 2, 360 * 2);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  final content = position.maxScrollExtent + position.viewportDimension;
  final chrome = tester.getSize(find.byType(Scaffold).first).height - position.viewportDimension;
  final height = (content + chrome + extra).ceilToDouble();
  tester.view.physicalSize = Size(width * 2, height * 2);
  await tester.pump();
  await _advance(tester, ms: 200);
}

/// Diyaloğu/sayfayı bir ana sayfadan açar.
Future<void> _openDialog(WidgetTester tester, Future<Object?> Function(BuildContext context) show) async {
  unawaited(show(tester.element(find.byType(Scaffold).first)));
  await tester.pump();
  await _advance(tester, ms: 600);
}

/// Sayfayı bir ana sayfanın ÜSTÜNE iter (gerçek akış: AppBar'da geri oku görünür).
Future<void> _pushPage(WidgetTester tester, Widget page) async {
  unawaited(Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => page)));
  await tester.pump();
  await _advance(tester, ms: 900);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Auth/Shell galeri', () {
    setUpAll(loadGoldenFonts);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';
        final ratio = scale > 1 ? 1.0 : 2.0;
        final base1 = scale == 1.0; // yalnız 1.0 ölçekte çekilen ek durumlar

        Future<void> shoot(WidgetTester tester, GlobalKey key, String name) async {
          await expectGolden(tester, key, '${name}_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        }

        testWidgets('açılış / splash ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          env.state.setAuthStatusForTesting(AuthStatus.checking);
          final key = GlobalKey();
          await _pumpScreen(tester, state: env.state, boundaryKey: key, brightness: brightness, textScale: scale, home: const AuthGate());
          // 700 ms: giriş koreografileri bitti (<= 480 ms) ve stok gösterge yayı en uzun anında (başlık/kuyruk döngüsü
          // 1333 ms; 1200 ms'de yay ~8 derece kalıyor ve PNG'de kopuk bir "-" görünüyordu: harness artefaktı).
          await _advance(tester, ms: 700);
          await shoot(tester, key, 'splash');
        });

        if (base1) {
          testWidgets('açılış / yavaş başlatma bildirimi + yedek düğme ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.state.setAuthStatusForTesting(AuthStatus.checking);
            final key = GlobalKey();
            await _pumpScreen(tester, state: env.state, boundaryKey: key, brightness: brightness, textScale: scale, home: const AuthGate());
            await _advance(tester, ms: 300);
            env.clock.advance(const Duration(seconds: 16));
            await tester.pump();
            await _advance(tester, ms: 400); // toplam ~700 ms: gösterge yayı uzun (bkz. splash)
            expect(find.byKey(const Key('splash_slow_notice')), findsOneWidget);
            await shoot(tester, key, 'splash_slow');
          });
        }

        testWidgets('biyometrik kilit ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          env.state.setBiometricForTesting(
            isSupported: true,
            isEnabled: true,
            failed: true,
            label: 'Parmak İzi',
            authStatus: AuthStatus.checking,
          );
          final key = GlobalKey();
          await _pumpScreen(tester, state: env.state, boundaryKey: key, brightness: brightness, textScale: scale, home: const AuthGate());
          await _advance(tester, ms: 1200);
          await shoot(tester, key, 'biometric_lock');
        });

        testWidgets('giriş ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          // Tüm giriş yöntemleri görünsün: SMS satırı yalnız sunucu yeteneği bildirirse çizilir (UYELIK-04).
          env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true, google: true, apple: true);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const LoginPage(),
            size: Size(_phone.width, 1200),
          );
          await _advance(tester, ms: 1200);
          await _fitHeight(tester, width: _phone.width);
          await shoot(tester, key, 'login');
        });

        // Hata iletisi: hatalı kimlik bilgisi -> InlineMessage.error (eskiden test sahte bulutu girişi başarılı
        // sayıyordu: PNG'de hata hiç görünmüyordu).
        testWidgets('giriş / hata iletisi ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          env.cloud.loginError = apiError(401, 'Geçersiz e-posta / telefon veya şifre.', code: 'INVALID_CREDENTIALS');
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const LoginPage(),
            size: Size(_phone.width, 1400),
          );
          await _advance(tester, ms: 900);
          await tester.enterText(find.byKey(const Key('field_email')), 'ayse@ornek.com');
          await tester.enterText(find.byKey(const Key('field_password')), 'yanlis-sifre');
          await tester.tap(find.byKey(const Key('btn_login')));
          await _advance(tester, ms: 800);
          expect(find.byKey(const Key('login_error')), findsOneWidget);
          await _fitHeight(tester, width: _phone.width);
          await shoot(tester, key, 'login_error');
        });

        if (base1) {
          // 429: "Tekrar dene (0:45)" + geri sayım kadranı + hata iletisi.
          testWidgets('giriş / hız sınırı geri sayımı ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.cloud.loginError = apiError(
              429,
              'Çok fazla giriş denemesi yapıldı. Güvenliğiniz için lütfen biraz bekleyip yeniden deneyin.',
              code: 'RATE_LIMITED',
              retryAfter: const Duration(seconds: 45),
            );
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const LoginPage(),
              size: Size(_phone.width, 1400),
            );
            await _advance(tester, ms: 900);
            await tester.enterText(find.byKey(const Key('field_email')), 'ayse@ornek.com');
            await tester.enterText(find.byKey(const Key('field_password')), 'yanlis-sifre');
            await tester.tap(find.byKey(const Key('btn_login')));
            await _advance(tester, ms: 800);
            expect(find.textContaining('Tekrar dene (0:45)'), findsOneWidget);
            await _fitHeight(tester, width: _phone.width);
            await shoot(tester, key, 'login_cooldown');
          });

          // Düğme "yükleniyor": marka yayı + pasif cam düğme; diğer girişler de pasif.
          testWidgets('giriş / yükleniyor ($tag)', (tester) async {
            final env = _gatedLoginEnv();
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const LoginPage(),
              size: Size(_phone.width, 1400),
            );
            await _advance(tester, ms: 900);
            await tester.enterText(find.byKey(const Key('field_email')), 'ayse@ornek.com');
            await tester.enterText(find.byKey(const Key('field_password')), 'dogru-parola-1234');
            await tester.tap(find.byKey(const Key('btn_login')));
            await _advance(tester, ms: 400);
            await _fitHeight(tester, width: _phone.width);
            await shoot(tester, key, 'login_loading');
            // Kapıyı aç: bekleyen istek test sonunda askıda kalmasın.
            (env.cloud as _GatedCloud).loginGate.complete();
            await tester.pump();
          });

          // Oturum süresi doldu bildirimi (login_session_notice): uyarı iletisi + "Tamam".
          testWidgets('giriş / oturum bildirimi ($tag)', (tester) async {
            final env = e2Env(); // oturum açık
            env.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const LoginPage(),
              size: Size(_phone.width, 1400),
            );
            await _advance(tester, ms: 900);
            expect(find.byKey(const Key('login_session_notice')), findsOneWidget);
            await _fitHeight(tester, width: _phone.width);
            await shoot(tester, key, 'login_notice');
          });

          // Geniş ekran: içerik 440 dp'de ortalanır.
          testWidgets('giriş / tablet genişliği ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const LoginPage(),
              size: const Size(840, 1300),
            );
            await _advance(tester, ms: 1200);
            await _fitHeight(tester, width: 840);
            await shoot(tester, key, 'login_tablet');
          });
        }

        testWidgets('kayıt ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
            size: Size(_phone.width, 1400),
          );
          await _pushPage(tester, const RegisterPage());
          await _fitHeight(tester, width: _phone.width);
          await shoot(tester, key, 'register');
        });

        // Boş gönderim: tüm alan hataları (yardımcı metinlerin yerini alır) görünür.
        testWidgets('kayıt / doğrulama hataları ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
            size: Size(_phone.width, 1400),
          );
          await _pushPage(tester, const RegisterPage());
          // Onaysız "Kayıt Ol" pasiftir: doğrulama hatalarını göstermek için zorunlu sözleşme kutusu işaretlenir.
          await tester.tap(find.byKey(const Key('chk_accept_terms')));
          await _advance(tester, ms: 200);
          await tester.tap(find.byKey(const Key('btn_register_submit')));
          await _advance(tester, ms: 500);
          await _fitHeight(tester, width: _phone.width);
          await shoot(tester, key, 'register_errors');
        });

        if (base1) {
          // Sunucu hatası: dolu form + InlineMessage.error (409: hesap zaten var).
          testWidgets('kayıt / sunucu hatası ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.cloud.registerError = apiError(
              409,
              'Bu e-posta adresiyle zaten bir hesap var. Giriş yapmayı veya şifrenizi sıfırlamayı deneyin.',
              code: 'CONFLICT',
            );
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
              size: Size(_phone.width, 1500),
            );
            await _pushPage(tester, const RegisterPage());
            await tester.enterText(find.byKey(const Key('field_full_name')), 'Ayşe Yılmaz');
            await tester.enterText(find.byKey(const Key('field_email')), 'ayse@ornek.test');
            await tester.enterText(find.byKey(const Key('field_phone')), '0555 123 45 67');
            await tester.enterText(find.byKey(const Key('field_password')), 'dogru-parola-1234');
            await tester.enterText(find.byKey(const Key('field_password_confirm')), 'dogru-parola-1234');
            await tester.tap(find.byKey(const Key('chk_accept_terms'))); // zorunlu Kullanıcı Sözleşmesi onayı
            await _advance(tester, ms: 200);
            await tester.tap(find.byKey(const Key('btn_register_submit')));
            await _advance(tester, ms: 600);
            expect(find.byKey(const Key('register_error')), findsOneWidget);
            await _fitHeight(tester, width: _phone.width);
            await shoot(tester, key, 'register_server_error');
          });

          // Şifre yenileme: 429 -> hata iletisi + "Bekleyin (0:30)" PASİF düğme (geri sayım).
          testWidgets('şifre sıfırlama diyaloğu / hız sınırı ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.cloud.forgotError = apiError(
              429,
              'Çok fazla istek yapıldı. Lütfen biraz bekleyip tekrar deneyin.',
              code: 'RATE_LIMITED',
              resendAfter: const Duration(seconds: 30),
            );
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
              size: Size(_phone.width, 800),
            );
            await _openDialog(tester, (c) => ForgotPasswordDialog.show(c));
            await tester.enterText(find.byKey(const Key('field_identifier')), 'ayse@ornek.test');
            await tester.tap(find.byKey(const Key('btn_send_code')));
            await _advance(tester, ms: 600);
            expect(find.text('Bekleyin (0:30)'), findsOneWidget);
            await shoot(tester, key, 'forgot_cooldown');
          });
        }

        testWidgets('şifre sıfırlama diyaloğu ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
          );
          await _openDialog(tester, (c) => ForgotPasswordDialog.show(c));
          await shoot(tester, key, 'forgot_dialog');
        });

        // 2. adım: kod + yeni şifre + güvenlik uyarısı + geçerlilik sayacı + yeniden gönderme.
        testWidgets('şifre sıfırlama diyaloğu / 2. adım ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
            size: Size(_phone.width, scale > 1 ? 900 : 860),
          );
          await _openDialog(tester, (c) => ForgotPasswordDialog.show(c));
          await tester.enterText(find.byKey(const Key('field_identifier')), 'ayse@ornek.test');
          await tester.tap(find.byKey(const Key('btn_send_code')));
          await _advance(tester, ms: 700);
          expect(find.byKey(const Key('field_code')), findsOneWidget);
          await shoot(tester, key, 'forgot_step2');
        });

        if (base1) {
          // 2. adım, hatalı kurtarma kodu: kod alanı KIRMIZI çerçeve + ileti kod alanının hemen altında (tek "Kalan deneme"
          // bilgisi; alan altında ikinci amber satır yok).
          testWidgets('şifre sıfırlama diyaloğu / hatalı kod ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.cloud.resetError = apiError(400, 'Kod hatalı.', code: 'VALIDATION', remaining: 2);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
              size: const Size(360, 940),
            );
            await _openDialog(tester, (c) => ForgotPasswordDialog.show(c));
            await tester.enterText(find.byKey(const Key('field_identifier')), 'ayse@ornek.test');
            await tester.tap(find.byKey(const Key('btn_send_code')));
            await _advance(tester, ms: 700);
            await tester.enterText(find.byKey(const Key('field_code')), '123456');
            await tester.enterText(find.byKey(const Key('field_new_password')), 'yepyeni-parola-1');
            await tester.enterText(find.byKey(const Key('field_confirm_password')), 'yepyeni-parola-1');
            await tester.tap(find.byKey(const Key('btn_reset_password')));
            await _advance(tester, ms: 700);
            expect(find.byKey(const Key('forgot_error')), findsOneWidget);
            await shoot(tester, key, 'forgot_step2_error');
          });

          // Eskiden galeride yoktu: auth akışından erişilen servis PIN ve "E-postadaki bağlantım var" diyalogları.
          testWidgets('servis PIN diyaloğu ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
            );
            await _openDialog(tester, (c) => ServicePinDialog.show(c));
            await shoot(tester, key, 'service_pin_dialog');
          });

          testWidgets('sihirli bağlantı diyaloğu ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
            );
            await _openDialog(tester, (c) => MagicLinkDialog.show(c));
            await shoot(tester, key, 'magic_link_dialog');
          });
        }

        if (base1) {
          testWidgets('OTP diyaloğu / telefon adımı ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
            );
            await _openDialog(tester, (c) => PhoneOtpDialog.show(c));
            await shoot(tester, key, 'otp_dialog_phone');
          });
        }

        testWidgets('OTP diyaloğu / kod adımı ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
            size: Size(_phone.width, scale > 1 ? 900 : 740),
          );
          await _openDialog(tester, (c) => PhoneOtpDialog.show(c));
          await tester.enterText(find.byKey(const Key('field_phone')), '0555 123 45 67');
          await tester.tap(find.byKey(const Key('btn_otp_send')));
          await _advance(tester, ms: 700);
          await shoot(tester, key, 'otp_dialog');
        });

        if (base1) {
          // Girilmiş 6 haneli kod + hatalı kod iletisi + kalan deneme hakkı.
          testWidgets('OTP diyaloğu / hatalı kod ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.cloud.otpVerifyError = apiError(401, 'Doğrulama kodu hatalı.', code: 'INVALID_CODE', remaining: 2);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
              size: Size(_phone.width, 800),
            );
            await _openDialog(tester, (c) => PhoneOtpDialog.show(c));
            await tester.enterText(find.byKey(const Key('field_phone')), '0555 123 45 67');
            await tester.tap(find.byKey(const Key('btn_otp_send')));
            await _advance(tester, ms: 700);
            await tester.enterText(find.byKey(const Key('field_code')), '123456');
            await tester.tap(find.byKey(const Key('btn_otp_verify')));
            await _advance(tester, ms: 700);
            expect(find.byKey(const Key('otp_error')), findsOneWidget);
            await shoot(tester, key, 'otp_dialog_error');
          });
        }

        testWidgets('zorunlu parola değişimi ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const ChangePasswordPage(forced: true),
            size: Size(_phone.width, 1400),
          );
          await _advance(tester, ms: 900);
          await _fitHeight(tester, width: _phone.width);
          await shoot(tester, key, 'forced_password');
        });

        if (base1) {
          testWidgets('zorunlu parola değişimi / doğrulama hataları ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const ChangePasswordPage(forced: true),
              size: Size(_phone.width, 1400),
            );
            await _advance(tester, ms: 900);
            await tester.enterText(find.byKey(const Key('field_current_password')), 'gecici-parola-9');
            await tester.enterText(find.byKey(const Key('field_new_password')), 'kisa');
            await tester.enterText(find.byKey(const Key('field_confirm_password')), 'baska');
            await tester.tap(find.byKey(const Key('btn_change_password')));
            await _advance(tester, ms: 500);
            await _fitHeight(tester, width: _phone.width);
            await shoot(tester, key, 'forced_password_errors');
          });
        }

        // Sihirli bağlantı ile şifre sıfırlama sayfası: orb + cam plaka (açıklama + 2 alan + düğme).
        testWidgets('sihirli bağlantı / yeni şifre ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const MagicLinkPage(link: MagicLink(kind: MagicLinkKind.resetPassword, token: 'ornek-belirtec')),
            size: Size(_phone.width, 1200),
          );
          await _advance(tester, ms: 900);
          await _fitHeight(tester, width: _phone.width);
          await shoot(tester, key, 'magic_link_reset');
        });

        if (base1) {
          // Açılış/biyometrik kilit sürerken bağlantıyla giriş bekler: marka yayı + açıklama + "Vazgeç".
          testWidgets('sihirli bağlantı / oturum durumu bekleniyor ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            env.state.setAuthStatusForTesting(AuthStatus.checking);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const MagicLinkPage(link: MagicLink(kind: MagicLinkKind.magicLogin, token: 'ornek-belirtec')),
              size: Size(_phone.width, 900),
            );
            await _advance(tester, ms: 700);
            expect(find.byKey(const Key('magic_login_waiting')), findsOneWidget);
            await _fitHeight(tester, width: _phone.width);
            await shoot(tester, key, 'magic_link_waiting');
          });
        }

        testWidgets('biyometrik istem diyaloğu ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
          );
          await _openDialog(tester, (c) => BiometricPromptDialog.show(c, label: 'Parmak İzi'));
          await shoot(tester, key, 'biometric_prompt');
        });

        if (base1) {
          // Doğrulama başarısız: InlineMessage.warning geri bildirimi + "Tekrar Dene".
          testWidgets('biyometrik istem / doğrulama başarısız ($tag)', (tester) async {
            final env = e2Env(biometric: FakeBiometric(supported: true, authResult: false, label: 'Parmak İzi'));
            env.state.setBiometricForTesting(isSupported: true);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
              size: Size(_phone.width, 800),
            );
            await _openDialog(tester, (c) => BiometricPromptDialog.show(c, label: 'Parmak İzi'));
            await tester.tap(find.byKey(const Key('btn_biometric_enable')));
            await _advance(tester, ms: 600);
            expect(find.byKey(const Key('biometric_feedback')), findsOneWidget);
            await shoot(tester, key, 'biometric_prompt_feedback');
          });
        }

        testWidgets('yıkıcı onay diyaloğu ($tag)', (tester) async {
          final env = e2Env(authenticated: false);
          final key = GlobalKey();
          await _pumpScreen(
            tester,
            state: env.state,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            home: const Scaffold(body: SizedBox.expand()),
          );
          await _openDialog(
            tester,
            (c) => ConfirmDestructiveDialog.show(
              c,
              title: 'Daire Silinsin mi?',
              message: 'Bu dairenin tüm sakin kayıtları ve cihaz eşleşmeleri kalıcı olarak silinir. Bu işlem geri alınamaz.',
              confirmLabel: 'Evet, Sil',
            ),
          );
          await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'sil');
          await _advance(tester, ms: 300);
          await shoot(tester, key, 'confirm_destructive');
        });

        if (base1) {
          // İfade henüz yazılmadı: birincil düğme PASİF (nötr cam), onay simgesi yok.
          testWidgets('yıkıcı onay diyaloğu / ifade yazılmadan ($tag)', (tester) async {
            final env = e2Env(authenticated: false);
            final key = GlobalKey();
            await _pumpScreen(
              tester,
              state: env.state,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              home: const Scaffold(body: SizedBox.expand()),
            );
            await _openDialog(
              tester,
              (c) => ConfirmDestructiveDialog.show(
                c,
                title: 'Daire Silinsin mi?',
                message: 'Bu dairenin tüm sakin kayıtları ve cihaz eşleşmeleri kalıcı olarak silinir. Bu işlem geri alınamaz.',
                confirmLabel: 'Evet, Sil',
              ),
            );
            await shoot(tester, key, 'confirm_destructive_idle');
          });
        }
      }
    }
  }, skip: visualSkipReason);
}
