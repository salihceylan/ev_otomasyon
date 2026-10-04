import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// UYELIK-04 (D22): giriş ekranı açılışında sunucu yetenekleri (`GET /auth/capabilities`) alınır; "Telefon ile giriş"
/// düğmesi YALNIZ `sms_otp == true` iken görünür. Uç yok (eski sunucu, 404) / hata -> gizli (fail-closed).
/// Google / Apple düğmelerinin mevcut davranışı DEĞİŞMEZ (yetenek bilgisinden bağımsız).
void main() {
  Future<void> pumpLogin(WidgetTester tester, E2Env env) async {
    await pumpApp(tester, state: env.state, child: const LoginPage(), size: const Size(420, 1600));
    await settle(tester);
  }

  final phoneButton = find.byKey(const Key('btn_phone_otp'));

  testWidgets('sms_otp:false -> "Telefon ile giriş" düğmesi YOK; Google ve e-posta bağlantısı yerinde', (tester) async {
    final env = e2Env(authenticated: false);
    env.cloud.authCapabilities = const AuthCapabilities(smsOtp: false, google: true, apple: true);
    await pumpLogin(tester, env);

    expect(phoneButton, findsNothing);
    expect(find.text('Telefon Numarası ile Şifresiz Giriş (SMS)'), findsNothing);
    expect(find.byKey(const Key('btn_google_sign_in')), findsOneWidget);
    expect(find.byKey(const Key('btn_magic_link')), findsOneWidget);
    expect(env.cloud.authCapabilitiesCalls, 1, reason: 'giriş ekranı açılışında soruldu');
  });

  testWidgets('sms_otp:true -> düğme VAR ve SMS giriş penceresini açar', (tester) async {
    final env = e2Env(authenticated: false);
    env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true);
    await pumpLogin(tester, env);

    expect(phoneButton, findsOneWidget);
    await tapKey(tester, 'btn_phone_otp');
    expect(find.byType(PhoneOtpDialog), findsOneWidget);
  });

  testWidgets('uç yok (eski sunucu, 404) -> düğme gizli (fail-closed)', (tester) async {
    final env = e2Env(authenticated: false); // sahte HTTP: GET /auth/capabilities -> 404
    await pumpLogin(tester, env);

    expect(phoneButton, findsNothing);
    expect(find.byKey(const Key('btn_google_sign_in')), findsOneWidget);
  });

  testWidgets('ağ hatası -> gizli; hata önbelleğe alınmaz: giriş ekranı yeniden açılınca tekrar sorulur', (tester) async {
    final env = e2Env(authenticated: false);
    env.cloud.authCapabilitiesError = ApiException.network();
    await pumpLogin(tester, env);
    expect(phoneButton, findsNothing);

    env.cloud.authCapabilitiesError = null;
    env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true);
    await pumpApp(tester, state: env.state, child: const SizedBox.shrink());
    await pumpLogin(tester, env);

    expect(phoneButton, findsOneWidget);
    expect(env.cloud.authCapabilitiesCalls, 2);
  });

  testWidgets('başarılı yanıt oturum başına BİR kez alınır (bellekte): giriş ekranı yeniden açılınca istek yok', (tester) async {
    final env = e2Env(authenticated: false);
    env.cloud.authCapabilities = const AuthCapabilities(smsOtp: true);
    await pumpLogin(tester, env);
    expect(phoneButton, findsOneWidget);

    await pumpApp(tester, state: env.state, child: const SizedBox.shrink());
    await pumpLogin(tester, env);

    expect(phoneButton, findsOneWidget, reason: 'bellekteki yanıtla ilk karede görünür');
    expect(env.cloud.authCapabilitiesCalls, 1);
  });

  testWidgets('giriş ekranı yanıtı BEKLEMEZ: yanıt gelene kadar düğme gizli, sms_otp:true gelince görünür', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = _GatedCapabilitiesCloud(clock: clock);
    final h = StateHarness(clock: clock, cloud: cloud);
    addTearDown(h.dispose);
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);

    await pumpApp(tester, state: h.state, child: const LoginPage(), size: const Size(420, 1600));
    await settle(tester);
    expect(find.byKey(const Key('btn_login')), findsOneWidget, reason: 'form hemen kullanılabilir');
    expect(phoneButton, findsNothing, reason: 'bilinene kadar gizli');

    cloud.gate.complete();
    await settle(tester);
    expect(phoneButton, findsOneWidget);
  });

  testWidgets('Apple (iOS) ve Google düğmeleri yetenek bilgisinden bağımsız: mevcut davranış', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final env = e2Env(authenticated: false);
      env.cloud.authCapabilities = const AuthCapabilities(smsOtp: false, google: false, apple: false);
      await pumpLogin(tester, env);

      expect(find.byKey(const Key('btn_google_sign_in')), findsOneWidget);
      expect(find.byKey(const Key('btn_apple_sign_in')), findsOneWidget);
      expect(phoneButton, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Yetenek isteği bir kapı açılana kadar bekler (giriş ekranının yanıtı beklemediğini sınamak için).
class _GatedCapabilitiesCloud extends E2Cloud {
  _GatedCapabilitiesCloud({super.clock});

  final Completer<void> gate = Completer<void>();

  @override
  Future<AuthCapabilities> fetchAuthCapabilities() async {
    authCapabilitiesCalls++;
    await gate.future;
    return const AuthCapabilities(smsOtp: true);
  }
}
