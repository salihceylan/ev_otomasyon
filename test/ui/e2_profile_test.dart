import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/delete_account_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Profil diyaloğu: avatar harfi (Türkçe/emoji dahil), rol etiketi, yer tutucular, tema seçimi,
/// role göre görünen eylemler ve hesap güvenliği eylemleri (onaylı çıkış, tüm cihazlardan çıkış,
/// hesap silme girişi).
void main() {
  Future<Opened<void>> openProfile(WidgetTester tester, E2Env env) =>
      openFromHost<void>(tester, env.state, (context) => UserProfileDialog.show(context));

  bool present(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

  /// Servis PIN oturumu kurar (ev: tek, rol: servis oturumu).
  E2Env serviceSessionEnv() {
    final env = e2Env(authenticated: false);
    final home = HomeModel(id: kHomeA, name: 'Servis Evi', role: 'service_session');
    env.cloud.restoreServiceSession(
      accessToken: 'servis-oturumu',
      info: ServiceSessionInfo(
        homeId: kHomeA,
        homeName: 'Servis Evi',
        expiresAt: env.clock.now().add(const Duration(hours: 1, minutes: 30)),
        technicianName: 'Teknisyen',
      ),
    );
    env.state
      ..setCurrentUserForTesting(const UserModel(id: '', email: '', fullName: 'Teknisyen', role: 'service_session'))
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setHomesForTesting(<HomeModel>[home], activeHome: home);
    return env;
  }

  group('avatarInitial', () {
    test('ilk harf büyütülür; Türkçe i/ı doğru eşlenir; boş ad "U" olur', () {
      expect(UserProfileDialog.avatarInitial('Ayşe Yılmaz'), 'A');
      expect(UserProfileDialog.avatarInitial('özlem'), 'Ö');
      expect(UserProfileDialog.avatarInitial('ışık'), 'I', reason: 'ı -> I');
      expect(UserProfileDialog.avatarInitial('ilker'), 'İ', reason: 'i -> İ (Türkçe)');
      expect(UserProfileDialog.avatarInitial('  boşluklu ad '), 'B');
      expect(UserProfileDialog.avatarInitial(''), 'U');
      expect(UserProfileDialog.avatarInitial('   '), 'U');
      expect(UserProfileDialog.avatarInitial(null), 'U');
    });

    test('birleşik karakter ve emoji bozulmaz (grafem kümesinin ilk karakteri)', () {
      expect(UserProfileDialog.avatarInitial('😀 Ali'), '😀', reason: 'vekil çiftin yarısı değil, tüm emoji');
      expect(UserProfileDialog.avatarInitial('émile'), 'É', reason: 'e + birleşik vurgu tek karakter');
      expect(UserProfileDialog.avatarInitial('👨‍👩‍👧 Aile'), '👨‍👩‍👧', reason: 'ZWJ dizisi tek grafem');
    });
  });

  group('roleBadge', () {
    test('rol ev bazlı rolden (ve küresel yönetici/servis rolünden) gelir', () {
      expect(UserProfileDialog.roleBadge(e2Env(role: 'owner').state).$1, 'Ev Sahibi');
      expect(UserProfileDialog.roleBadge(e2Env(role: 'resident').state).$1, 'Aile Bireyi');
      expect(UserProfileDialog.roleBadge(e2Env(role: 'guest').state).$1, 'Süreli Misafir');
      expect(UserProfileDialog.roleBadge(e2Env(role: null).state).$1, 'Kullanıcı', reason: 'evi/rolü olmayan hesap');
      expect(UserProfileDialog.roleBadge(e2Env(role: 'owner', globalRole: 'super_user').state).$1, 'Süper Yönetici',
          reason: 'küresel rol ev rolünden önce gelir');
      expect(UserProfileDialog.roleBadge(e2Env(role: 'owner', globalRole: 'service_user').state).$1, 'Servis Sorumlusu');
      expect(UserProfileDialog.roleBadge(serviceSessionEnv().state).$1, 'Servis Oturumu (PIN)');
    });

    test('"member" ev rolü aile bireyi olarak gösterilir', () {
      expect(UserProfileDialog.roleBadge(e2Env(role: 'member').state).$1, 'Aile Bireyi');
    });
  });

  group('görünüm', () {
    testWidgets('ad, e-posta, telefon, rol ve avatar harfi gösterilir', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      expect(textOf(tester, 'profile_name'), 'Ayşe Yılmaz');
      expect(textOf(tester, 'profile_avatar_initial'), 'A');
      expect(textOf(tester, 'profile_role'), 'Ev Sahibi');
      expect(textOf(tester, 'profile_email'), kUserEmail);
      expect(find.text(kUserPhone), findsOneWidget);
      expect(find.text('Ev A'), findsOneWidget, reason: 'aktif ev');
    });

    testWidgets('ad ve e-posta boşsa "Kullanıcı Profili" / "Belirtilmedi" yer tutucuları gösterilir (boş satır yok)', (tester) async {
      final env = e2Env(role: 'owner');
      env.state.setCurrentUserForTesting(const UserModel(id: kUserId, email: '  ', fullName: ''));
      await openProfile(tester, env);

      expect(textOf(tester, 'profile_name'), 'Kullanıcı Profili');
      expect(textOf(tester, 'profile_email'), 'Belirtilmedi');
      expect(textOf(tester, 'profile_avatar_initial'), 'U');
    });

    testWidgets('çok uzun ad taşma yapmaz (tek satır, üç nokta)', (tester) async {
      final env = e2Env(role: 'owner');
      env.state.setCurrentUserForTesting(UserModel(id: kUserId, email: kUserEmail, fullName: 'Çok ${'uzun ' * 40}ad'));
      await openProfile(tester, env);

      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.byKey(const Key('profile_name'))).overflow, TextOverflow.ellipsis);
    });

    testWidgets('servis oturumunda rol ve kalan süre gösterilir', (tester) async {
      final env = serviceSessionEnv();
      await openProfile(tester, env);

      expect(textOf(tester, 'profile_role'), 'Servis Oturumu (PIN)');
      expect(find.text('Oturum Süresi'), findsOneWidget);
      expect(find.text('1 saat 30 dk'), findsOneWidget);
    });
  });

  group('tema seçimi', () {
    bool selected(WidgetTester tester, String key) => tester.widget<ChoiceChip>(find.byKey(Key(key))).selected;

    testWidgets('sistem modunda YALNIZCA "Sistem" seçili görünür; seçim değişince durum ve görünüm güncellenir', (tester) async {
      final env = e2Env(role: 'owner');
      await env.state.setThemeMode(ThemeMode.system);
      await openProfile(tester, env);

      expect(selected(tester, 'theme_system'), isTrue);
      expect(selected(tester, 'theme_light'), isFalse);
      expect(selected(tester, 'theme_dark'), isFalse);

      await tapKey(tester, 'theme_light');
      expect(env.state.themeMode, ThemeMode.light);
      expect(selected(tester, 'theme_light'), isTrue);
      expect(selected(tester, 'theme_system'), isFalse);

      await tapKey(tester, 'theme_dark');
      expect(env.state.themeMode, ThemeMode.dark);
      expect(selected(tester, 'theme_dark'), isTrue);

      await tapKey(tester, 'theme_system');
      expect(env.state.themeMode, ThemeMode.system);
      expect(selected(tester, 'theme_system'), isTrue);
    });
  });

  group('role göre görünen eylemler', () {
    testWidgets('ev sahibi: aile yönetimi, hızlı davet, eve katıl ve tüm hesap eylemleri görünür; servis paneli yoktur', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      for (final key in <String>[
        'btn_open_family',
        'btn_quick_invite',
        'btn_join_home',
        'btn_open_change_password',
        'btn_logout_all',
        'btn_delete_account_entry',
        'btn_logout',
        'btn_profile_close',
      ]) {
        expect(present(key), isTrue, reason: key);
      }
      expect(present('btn_open_service_panel'), isFalse);
    });

    testWidgets('aile bireyi: aile yönetimi/davet yok; eve katıl ve hesap eylemleri var', (tester) async {
      final env = e2Env(role: 'resident');
      await openProfile(tester, env);

      expect(present('btn_open_family'), isFalse);
      expect(present('btn_quick_invite'), isFalse);
      expect(present('btn_join_home'), isTrue);
      expect(present('btn_open_change_password'), isTrue);
      expect(present('btn_delete_account_entry'), isTrue);
    });

    testWidgets('süper yönetici: servis paneli var; "eve katıl" ve "hesabı sil" yok (sunucu yönetici hesabı silmeyi reddeder)', (tester) async {
      final env = e2Env(role: 'owner', globalRole: 'super_user');
      await openProfile(tester, env);

      expect(present('btn_open_service_panel'), isTrue);
      expect(present('btn_join_home'), isFalse);
      expect(present('btn_delete_account_entry'), isFalse);
      expect(present('btn_open_change_password'), isTrue, reason: 'şifre değiştirme yöneticiye de açık');
    });

    testWidgets('servis sorumlusu: servis paneli var; "eve katıl" ve "hesabı sil" yok', (tester) async {
      final env = e2Env(role: 'resident', globalRole: 'service_user');
      await openProfile(tester, env);

      expect(present('btn_open_service_panel'), isTrue);
      expect(present('btn_join_home'), isFalse);
      expect(present('btn_delete_account_entry'), isFalse);
    });

    testWidgets('servis PIN oturumu: hesap eylemleri (şifre, tüm cihazlardan çıkış, hesap silme) ve eve katıl YOKTUR; çıkış vardır', (tester) async {
      final env = serviceSessionEnv();
      await openProfile(tester, env);

      expect(present('btn_open_change_password'), isFalse);
      expect(present('btn_logout_all'), isFalse);
      expect(present('btn_delete_account_entry'), isFalse);
      expect(present('btn_join_home'), isFalse);
      expect(present('btn_logout'), isTrue);
    });
  });

  group('eylemler', () {
    testWidgets('"Şifreyi Değiştir": profil kapanır, gönüllü şifre sayfası açılır', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_open_change_password');
      await tester.pumpAndSettle();

      expect(find.byType(UserProfileDialog), findsNothing);
      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(find.byKey(const Key('forced_notice')), findsNothing, reason: 'zorunlu mod değil');
    });

    testWidgets('"Hesabımı Sil": silme diyaloğu açılır; hiçbir istek kendiliğinden atılmaz', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_delete_account_entry');

      expect(find.byType(DeleteAccountDialog), findsOneWidget);
      expect(env.cloud.deleteAccountArgs, isEmpty);
    });

    testWidgets('"Aile & Misafir Yönetimi", "Hızlı Davet" ve "Eve Katıl" ilgili ekranları açar', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);
      await tapKey(tester, 'btn_open_family');
      await tester.pumpAndSettle();
      expect(find.byType(FamilyMembersPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openProfile(tester, env);
      await tapKey(tester, 'btn_quick_invite');
      expect(find.byType(InviteFamilyDialog), findsOneWidget);
    });

    testWidgets('"Başka Bir Eve Katıl" katılma diyaloğunu açar', (tester) async {
      final env = e2Env(role: 'resident');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_join_home');

      expect(find.byType(JoinHomeDialog), findsOneWidget);
    });

    testWidgets('"Kapat" diyaloğu kapatır', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_profile_close');

      expect(find.byType(UserProfileDialog), findsNothing);
    });
  });

  group('oturumu kapatma', () {
    testWidgets('"Oturumu Kapat" ONAY ister; vazgeçilirse oturum sürer', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_logout');
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_logout_cancel');

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(UserProfileDialog), findsOneWidget);
    });

    testWidgets('onaylanırsa çıkış yapılır ve profil diyaloğu dahil açık her şey kapanır', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_logout');
      await tapKey(tester, 'btn_logout_confirm');
      await tester.pumpAndSettle();

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(find.byType(UserProfileDialog), findsNothing);
    });

    testWidgets('"Tüm Cihazlardan Çıkış" ONAY ister; onaylanınca sunucuda toplu çıkış yapılır ve yerel oturum kapanır', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_logout_all');
      expect(find.text('Tüm Cihazlardan Çıkış'), findsWidgets);
      expect(env.cloud.calls.contains('logoutAll'), isFalse, reason: 'onaydan önce istek yok');
      await tapKey(tester, 'btn_simple_confirm');
      await tester.pumpAndSettle();

      expect(env.cloud.calls.contains('logoutAll'), isTrue);
      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(find.byType(UserProfileDialog), findsNothing);
    });

    testWidgets('"Tüm Cihazlardan Çıkış" vazgeçilirse istek atılmaz ve oturum sürer', (tester) async {
      final env = e2Env(role: 'owner');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_logout_all');
      await tapKey(tester, 'btn_simple_cancel');

      expect(env.cloud.calls.contains('logoutAll'), isFalse);
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('sunucu toplu çıkışı başarısız olursa ÇIKIŞ YAPILMAZ; hata gösterilir ve profil açık kalır', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.logoutAllError = apiError(0, 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.', code: 'NETWORK');
      await openProfile(tester, env);

      await tapKey(tester, 'btn_logout_all');
      await tapKey(tester, 'btn_simple_confirm');

      expect(env.state.authStatus, AuthStatus.authenticated, reason: 'işlem gerçekleşmedi: oturum korunur');
      expect(find.text('Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.'), findsOneWidget);
      expect(find.byType(UserProfileDialog), findsOneWidget);
    });
  });
}
