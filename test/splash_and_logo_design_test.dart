import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Açılış ekranı ve kimlik kapısı **davranışı**: duruma göre doğru ekran (açılış / giriş / pano),
/// kimlik çözülünce açılış ekranının hemen bitmesi, biyometrik başarısızlıkta onaylı şifre yolu ve
/// oturum bitince giriş ekranına dönüş.
void main() {
  Future<void> advance(WidgetTester tester, [Duration by = const Duration(milliseconds: 600)]) async {
    await tester.pump();
    await tester.pump(by);
  }

  group('Kimlik kapısı (AuthGate)', () {
    testWidgets('kimlik denetlenirken açılış ekranı (logo + marka + doğrulama mesajı) gösterilir', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));

      expect(find.text('AHBU OTOMASYON'), findsOneWidget);
      expect(find.text('YAPAY ZEKA DESTEKLİ AKILLI YAŞAM'), findsOneWidget);
      expect(find.text('Oturum güvenli şekilde doğrulanıyor...'), findsOneWidget);
      expect(find.byType(ClipOval), findsWidgets, reason: 'dairesel logo');
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(DashboardPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('oturum yoksa giriş ekranı açılır', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));
      await advance(tester);

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
    });

    testWidgets('oturum açıksa pano açılır', (tester) async {
      await pumpReady(tester, const AuthGate(), role: 'owner');
      await advance(tester);
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);
    });

    testWidgets('girişsiz yerel modda doğrudan pano açılır (giriş zorunlu değildir)', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      await pumpPage(tester, h.state, const AuthGate());
      await advance(tester);
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('kimlik çözülür çözülmez açılış ekranı biter ve pano açılır (sabit bekleme yok)', (tester) async {
      final h = await pumpReady(tester, const AuthGate(), role: 'owner');
      // Durum zaten hazır; önce "doğrulanıyor"a çekip açılış ekranının sürdüğünü görüyoruz.
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await advance(tester);
      expect(find.text('AHBU OTOMASYON'), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing, reason: 'doğrulanmayan oturumda pano açılmaz');

      // Çözülünce yalnızca geçiş animasyonu kadar beklenir.
      h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await advance(tester);
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.text('Oturum güvenli şekilde doğrulanıyor...'), findsNothing);
    });

    testWidgets('biyometrik doğrulama başarısızsa "tekrar dene" ve "şifre ile giriş" yolları sunulur', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setBiometricForTesting(
        isSupported: true,
        isEnabled: true,
        failed: true,
        label: 'Parmak İzi',
        authStatus: AuthStatus.checking,
      );
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));

      expect(find.text('Parmak İzi doğrulaması tamamlanamadı.'), findsOneWidget);
      expect(byKeyName('btn_biometric_retry'), findsOneWidget);
      expect(find.text('Parmak İzi ile Aç'), findsOneWidget);
      expect(byKeyName('btn_biometric_fallback'), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing, reason: 'kilitli oturumda pano açılmaz');
    });

    testWidgets('şifre ile giriş yolu oturumu kapatır: önce onay ister, vazgeçilirse hiçbir şey değişmez', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setBiometricForTesting(
        isSupported: true,
        isEnabled: true,
        failed: true,
        label: 'Parmak İzi',
        authStatus: AuthStatus.checking,
      );
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));

      await tester.tap(byKeyName('btn_biometric_fallback'));
      await tester.pumpAndSettle();
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);

      await tester.tap(byKeyName('btn_logout_cancel'));
      await tester.pumpAndSettle();
      expect(h.state.authStatus, AuthStatus.checking, reason: 'vazgeçilince oturum durumu değişmez');
      expect(byKeyName('biometric_locked'), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);

      await tester.tap(byKeyName('btn_biometric_fallback'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_logout_confirm'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await advance(tester);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('oturum süresi dolunca giriş ekranına dönülür ve açıklama gösterilir', (tester) async {
      final h = await pumpReady(tester, const AuthGate(), role: 'owner');
      await advance(tester);
      expect(find.byType(DashboardPage), findsOneWidget);

      h.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await tester.pump();
      await advance(tester, const Duration(seconds: 1));

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
      expect(find.text('Oturumunuz sona erdi. Lütfen tekrar giriş yapın.'), findsOneWidget);
    });
  });

  group('Açılış ekranı yerleşimi', () {
    testWidgets('küçük telefonda ve yazı ölçeği 1.5\'te taşma yok', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(320, 568), textScale: 1.5);
      expect(tester.takeException(), isNull);
    });
  });
}
