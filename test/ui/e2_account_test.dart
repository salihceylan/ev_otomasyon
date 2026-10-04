import 'dart:async';

import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/deep_links.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/delete_account_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_page.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Hesap yönetimi: e-postadaki sihirli bağlantı (giriş / şifre sıfırlama), hesabı silme (tek sahip
/// dairesi dahil), gönüllü şifre değiştirme ve derin bağlantı yönlendirmesi.
void main() {
  // Gerçek olmayan, biçimi geçerli (base64url, >=16) sahte belirteç.
  const token = 'test-magic-token-0001-abcdef';
  final host = AppConfig.productionHost;
  String link(String path, {String? t}) => 'https://$host$path#token=${t ?? token}';
  const loginLink = MagicLink(kind: MagicLinkKind.magicLogin, token: token);
  const resetLink = MagicLink(kind: MagicLinkKind.resetPassword, token: token);

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

  bool onPressedIsNull(WidgetTester tester, String key) =>
      tester.widget<ElevatedButton>(find.byKey(Key(key))).onPressed == null;

  group('MagicLinkDialog (bağlantıyı elle yapıştırma)', () {
    Future<Opened<void>> openDialog(WidgetTester tester, E2Env env) =>
        openFromHost<void>(tester, env.state, (context) => MagicLinkDialog.show(context));

    testWidgets('geçersiz bağlantılar nedenleriyle reddedilir; diyalog açık kalır, sayfa açılmaz, istek gitmez', (tester) async {
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);

      Future<void> tryLink(String text, String expectedMessage) async {
        await typeInto(tester, 'field_magic_link', text);
        await tapKey(tester, 'btn_magic_link_continue');
        expect(textOf(tester, 'magic_link_error'), expectedMessage, reason: text);
        expect(find.byType(MagicLinkDialog), findsOneWidget);
      }

      await tryLink('', 'Bağlantı boş.');
      await tryLink('http://$host/reset-password#token=$token', 'Bağlantı güvenli (https) bir adres içermiyor.');
      await tryLink('https://baska-sunucu.example/reset-password#token=$token', 'Bu bağlantı tanınan bir sunucuya ait değil.');
      await tryLink('https://$host/reset-password?token=$token', 'Bağlantı geçersiz biçimde.');
      await tryLink('https://$host/baska-yol#token=$token', 'Bu bağlantı bir giriş/şifre sıfırlama bağlantısı değil.');
      await tryLink('https://$host/reset-password', 'Bağlantıda doğrulama kodu yok.');
      await tryLink('https://$host/reset-password#token=kisa', 'Bağlantıdaki doğrulama kodu geçersiz.');

      expect(find.byType(MagicLinkPage), findsNothing);
      expect(env.cloud.calls, isEmpty);
    });

    testWidgets('yazmaya başlayınca hata temizlenir', (tester) async {
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);
      await tapKey(tester, 'btn_magic_link_continue');
      expect(find.byKey(const Key('magic_link_error')), findsOneWidget);

      await typeInto(tester, 'field_magic_link', 'h');

      expect(find.byKey(const Key('magic_link_error')), findsNothing);
    });

    testWidgets('geçerli şifre sıfırlama bağlantısı: diyalog kapanır, yeni şifre sayfası açılır; belirteç ekranda yoktur ve istek atılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);

      await typeInto(tester, 'field_magic_link', '  ${link('/reset-password')}  ');
      await tapKey(tester, 'btn_magic_link_continue');
      await tester.pumpAndSettle();

      expect(find.byType(MagicLinkDialog), findsNothing);
      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(find.textContaining(token), findsNothing, reason: 'belirteç ekranda gösterilmez');
      expect(env.cloud.calls, isEmpty, reason: 'şifre sıfırlama sayfası kendiliğinden istek atmaz');
    });

    testWidgets('geçerli giriş bağlantısı oturumsuzken doğrudan giriş yaptırır ve sayfa kapanır', (tester) async {
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);

      await typeInto(tester, 'field_magic_link', link('/magic-login'));
      await tapKey(tester, 'btn_magic_link_continue');
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, <String>[token]);
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(MagicLinkPage), findsNothing);
      expect(find.byKey(const Key('open_host')), findsOneWidget, reason: 'ilk rotaya dönüldü');
    });

    testWidgets('"Panodan yapıştır" panodaki bağlantıyı kırparak alana yazar; boş pano alanı değiştirmez', (tester) async {
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);
      String? clipboard = '  ${link('/reset-password')} \n';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': clipboard};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tapKey(tester, 'btn_paste_link');
      expect(fieldText(tester, 'field_magic_link'), link('/reset-password'));

      await typeInto(tester, 'field_magic_link', 'elle-yazilan');
      clipboard = '   ';
      await tapKey(tester, 'btn_paste_link');
      expect(fieldText(tester, 'field_magic_link'), 'elle-yazilan');
    });

    testWidgets('"İptal" diyaloğu kapatır', (tester) async {
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);

      await tapKey(tester, 'btn_magic_link_cancel');

      expect(find.byType(MagicLinkDialog), findsNothing);
    });
  });

  group('MagicLinkPage: giriş bağlantısı', () {
    testWidgets('oturum yokken açılır açılmaz giriş yapılır; belirteç yalnızca bir kez gönderilir ve sayfa kapanır', (tester) async {
      final env = e2Env(authenticated: false);

      await pushPage(tester, env, const MagicLinkPage(link: loginLink));
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, <String>[token]);
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(MagicLinkPage), findsNothing);
      expect(find.byKey(const Key('open_host')), findsOneWidget);
    });

    testWidgets('giriş sürerken ilerleme gösterilir, geri dönülemez; tamamlanınca sayfa kapanır', (tester) async {
      final env = e2Env(authenticated: false);
      final gate = Completer<void>();
      env.cloud.magicGate = gate;

      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      expect(find.byKey(const Key('magic_login_progress')), findsOneWidget);
      // Üst çubuk NeonAppBar (cam geri diski `nav_back`): meşgulken `automaticallyImplyLeading` kapanır, disk çizilmez.
      expect(find.byKey(const Key('nav_back')), findsNothing, reason: 'meşgulken geri düğmesi yok');
      expect(find.byType(BackButton), findsNothing);
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await settle(tester);
      expect(find.byType(MagicLinkPage), findsOneWidget, reason: 'geri tuşu meşgulken sayfayı kapatmaz');
      expect(env.cloud.magicTokens, hasLength(1));

      gate.complete();
      await tester.pumpAndSettle();
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('süresi dolmuş/kullanılmış bağlantı (410): açık mesaj; OTOMATİK yeniden deneme yok; "Tekrar Dene" yeni istek yapar', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.magicError = apiError(410, 'Kodun süresi doldu.', code: 'GONE');

      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      expect(
        textOf(tester, 'magic_login_error'),
        'Bu bağlantının süresi dolmuş veya daha önce kullanılmış. Yeni bir bağlantı isteyin.',
      );
      env.clock.advance(const Duration(minutes: 2));
      await tester.pump();
      expect(env.cloud.magicTokens, hasLength(1), reason: 'tek kullanımlık belirteç kendiliğinden yeniden denenmez');
      expect(env.state.authStatus, isNot(AuthStatus.authenticated));

      env.cloud.magicError = null;
      await tapKey(tester, 'btn_magic_login_retry');
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, hasLength(2));
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('beklenmeyen hatada ham istisna metni gösterilmez', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.magicError = StateError('SocketException: kaynak 10.0.0.5');

      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      expect(find.textContaining('SocketException'), findsNothing);
      expect(textOf(tester, 'magic_login_error'), 'Bağlantıyla işlem tamamlanamadı. Lütfen tekrar deneyin.');
    });

    testWidgets('"Giriş Ekranına Dön" ilk rotaya döner', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.magicError = apiError(410, 'x', code: 'GONE');
      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      await tapKey(tester, 'btn_magic_login_back');
      await tester.pumpAndSettle();

      expect(find.byType(MagicLinkPage), findsNothing);
      expect(find.byKey(const Key('open_host')), findsOneWidget);
    });

    testWidgets('oturum açıkken (hesap değişimi) önce onay istenir; onaysız istek gitmez; onaylanınca giriş yapılır', (tester) async {
      final env = e2Env(role: 'owner');

      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      expect(find.byKey(const Key('magic_login_confirm_notice')), findsOneWidget);
      expect(env.cloud.magicTokens, isEmpty, reason: 'onay verilmeden istek yok');
      expect(env.state.authStatus, AuthStatus.authenticated);

      await tapKey(tester, 'btn_magic_login_confirm');
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, <String>[token]);
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('açılış/biyometrik kilit sürerken (oturum durumu bilinmiyor) İSTEK ATILMAZ; kilit açılıp oturum yoksa giriş yapılır', (tester) async {
      final env = e2Env(authenticated: false);
      env.state.setAuthStatusForTesting(AuthStatus.checking);

      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      expect(find.byKey(const Key('magic_login_waiting')), findsOneWidget);
      expect(env.cloud.magicTokens, isEmpty, reason: 'kilit/açılış sürerken kayıtlı oturum sessizce değiştirilmez');

      env.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await tester.pumpAndSettle();

      expect(env.cloud.magicTokens, <String>[token]);
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('kilit açıldığında oturum VARSA otomatik giriş yapılmaz: hesap değişimi onayı istenir', (tester) async {
      final env = e2Env(role: 'owner');
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      await pushPage(tester, env, const MagicLinkPage(link: loginLink));
      expect(find.byKey(const Key('magic_login_waiting')), findsOneWidget);

      env.state.setAuthStatusForTesting(AuthStatus.authenticated);
      await settle(tester);

      expect(find.byKey(const Key('magic_login_confirm_notice')), findsOneWidget);
      expect(env.cloud.magicTokens, isEmpty, reason: 'onaysız hesap değişimi yok');
    });

    testWidgets('kilit sürerken "Vazgeç" sayfayı kapatır ve istek atılmaz', (tester) async {
      final env = e2Env(authenticated: false);
      env.state.setAuthStatusForTesting(AuthStatus.checking);
      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      await tapKey(tester, 'btn_magic_login_cancel');
      await tester.pumpAndSettle();

      expect(find.byType(MagicLinkPage), findsNothing);
      expect(env.cloud.magicTokens, isEmpty);
    });

    testWidgets('oturum açıkken vazgeçilirse oturum korunur ve istek gitmez', (tester) async {
      final env = e2Env(role: 'owner');
      await pushPage(tester, env, const MagicLinkPage(link: loginLink));

      await tapKey(tester, 'btn_magic_login_cancel');
      await tester.pumpAndSettle();

      expect(find.byType(MagicLinkPage), findsNothing);
      expect(env.cloud.magicTokens, isEmpty);
      expect(env.state.authStatus, AuthStatus.authenticated);
    });
  });

  group('MagicLinkPage: şifre sıfırlama bağlantısı', () {
    Future<void> fillPasswords(WidgetTester tester, String password, {String? confirm}) async {
      await typeInto(tester, 'field_new_password', password);
      await typeInto(tester, 'field_confirm_password', confirm ?? password);
    }

    testWidgets('yeni şifre politikası ve eşleşme denetlenir; geçersizse istek gitmez', (tester) async {
      final env = e2Env(authenticated: false);
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await tapKey(tester, 'btn_magic_reset_submit');
      expect(find.text('Lütfen yeni şifrenizi girin'), findsOneWidget);
      expect(find.text('Lütfen şifrenizi tekrar girin'), findsOneWidget);

      await fillPasswords(tester, 'kisa');
      await tapKey(tester, 'btn_magic_reset_submit');
      expect(find.text('Şifre en az 10 karakter olmalıdır'), findsOneWidget);

      await fillPasswords(tester, 'yeterince-uzun-1', confirm: 'yeterince-uzun-2');
      await tapKey(tester, 'btn_magic_reset_submit');
      expect(find.text('Şifreler eşleşmiyor'), findsOneWidget);

      expect(env.cloud.resetArgs, isEmpty);
    });

    testWidgets('başarılı sıfırlama: şifre KIRPILMADAN ve belirteçle gönderilir; başarı görünümü çıkar, "Giriş Ekranına Dön" sayfayı kapatır', (tester) async {
      final env = e2Env(authenticated: false);
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await fillPasswords(tester, '  yeni parola 123  '); // 19 karakter, baş/son boşluk
      await tapKey(tester, 'btn_magic_reset_submit');

      expect(env.cloud.resetArgs.single, <String, Object?>{
        'identifier': null,
        'code': null,
        'hasToken': true,
        'passwordLength': 19,
      });
      expect(find.byKey(const Key('magic_reset_done')), findsOneWidget);
      expect(textOf(tester, 'magic_reset_success'), 'Şifreniz yenilendi. Yeni şifrenizle giriş yapabilirsiniz.');
      expect(env.state.authStatus, isNot(AuthStatus.authenticated), reason: 'sunucu oturum vermedi: giriş yapılmış gibi davranılmaz');

      await tapKey(tester, 'btn_magic_reset_done');
      await tester.pumpAndSettle();
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('sunucu oturum verdiyse (otomatik giriş) başarı sayfası yerine doğrudan çıkılır', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.resetReturnsSession = true;
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await fillPasswords(tester, 'yeterince-uzun-1');
      await tapKey(tester, 'btn_magic_reset_submit');
      await tester.pumpAndSettle();

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(MagicLinkPage), findsNothing);
    });

    testWidgets('süresi dolmuş bağlantı (410) açık mesajla gösterilir; form yeniden kullanılabilir', (tester) async {
      final env = e2Env(authenticated: false);
      env.cloud.resetError = apiError(410, 'Süre doldu.', code: 'GONE');
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await fillPasswords(tester, 'yeterince-uzun-1');
      await tapKey(tester, 'btn_magic_reset_submit');

      expect(
        textOf(tester, 'magic_reset_error'),
        'Bu bağlantının süresi dolmuş veya daha önce kullanılmış. Yeni bir bağlantı isteyin.',
      );
      expect(onPressedIsNull(tester, 'btn_magic_reset_submit'), isFalse, reason: 'düğme yeniden etkin');

      env.cloud.resetError = null;
      await tapKey(tester, 'btn_magic_reset_submit');
      expect(find.byKey(const Key('magic_reset_done')), findsOneWidget);
    });

    testWidgets('çift dokunuşta yalnızca BİR sıfırlama isteği gider; belirteç ekranda gösterilmez', (tester) async {
      final env = e2Env(authenticated: false);
      final gate = Completer<void>();
      env.cloud.resetGate = gate;
      await pushPage(tester, env, const MagicLinkPage(link: resetLink));

      await fillPasswords(tester, 'yeterince-uzun-1');
      await tester.tap(find.byKey(const Key('btn_magic_reset_submit')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_magic_reset_submit')), warnIfMissed: false);
      await tester.pump();

      expect(env.cloud.resetArgs, hasLength(1));
      expect(onPressedIsNull(tester, 'btn_magic_reset_submit'), isTrue);
      expect(find.textContaining(token), findsNothing);

      gate.complete();
      await settle(tester);
      expect(find.byKey(const Key('magic_reset_done')), findsOneWidget);
    });
  });

  group('DeleteAccountDialog', () {
    Future<Opened<void>> openDialog(WidgetTester tester, E2Env env) =>
        openFromHost<void>(tester, env.state, (context) => DeleteAccountDialog.show(context));

    testWidgets('onay ifadesi (SİL) yazılana kadar silme düğmesi pasiftir; Türkçe büyük/küçük harf farkı gözetilmez', (tester) async {
      final env = e2Env(role: 'owner');
      await openDialog(tester, env);
      expect(onPressedIsNull(tester, 'btn_delete_account'), isTrue);

      await typeInto(tester, 'field_delete_confirm', 'SI');
      expect(onPressedIsNull(tester, 'btn_delete_account'), isTrue);

      await typeInto(tester, 'field_delete_confirm', 'sil');
      expect(onPressedIsNull(tester, 'btn_delete_account'), isFalse);
      expect(env.cloud.deleteAccountArgs, isEmpty);
    });

    testWidgets('parolalı hesap: parola KIRPILMADAN gönderilir; hesap silinir, oturum kapanır, diyalog kapanır ve bilgi verilir', (tester) async {
      final env = e2Env(role: 'owner');
      await openDialog(tester, env);

      await typeInto(tester, 'field_delete_password', ' gizli parola '); // 14 karakter
      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');
      await tester.pumpAndSettle();

      expect(env.cloud.deleteAccountArgs.single, <String, Object?>{'hasPassword': true, 'passwordLength': 14, 'confirm': null});
      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(find.byType(DeleteAccountDialog), findsNothing);
      expect(find.text('Hesabınız silindi.'), findsOneWidget);
      expect(env.h.storage.isEmpty, isTrue, reason: 'yerel oturum verisi silindi');
    });

    testWidgets('sosyal giriş / SMS hesabı: parola boşsa onay ifadesi gönderilir', (tester) async {
      final env = e2Env(role: 'owner');
      await openDialog(tester, env);

      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');
      await tester.pumpAndSettle();

      expect(env.cloud.deleteAccountArgs.single, <String, Object?>{'hasPassword': false, 'passwordLength': null, 'confirm': 'SİL'});
      expect(env.state.authStatus, AuthStatus.unauthenticated);
    });

    testWidgets('yanlış parola: hata gösterilir, hesap silinmez, oturum sürer ve yeniden denenebilir', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.deleteAccountError = apiError(401, 'Parola hatalı.', code: 'INVALID_CREDENTIALS');
      await openDialog(tester, env);

      await typeInto(tester, 'field_delete_password', 'yanlis-parola');
      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');

      expect(textOf(tester, 'delete_error'), 'Parola hatalı.');
      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.byType(DeleteAccountDialog), findsOneWidget);
      expect(onPressedIsNull(tester, 'btn_delete_account'), isFalse, reason: 'ifade hâlâ doğru: yeniden denenebilir');

      env.cloud.deleteAccountError = null;
      await tapKey(tester, 'btn_delete_account');
      await tester.pumpAndSettle();
      expect(env.cloud.deleteAccountArgs, hasLength(2));
      expect(env.state.authStatus, AuthStatus.unauthenticated);
    });

    testWidgets('beklenmeyen hatada ham istisna gösterilmez', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.deleteAccountError = StateError('NullPointer at com.ahbu.Account');
      await openDialog(tester, env);

      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');

      expect(find.textContaining('NullPointer'), findsNothing);
      expect(textOf(tester, 'delete_error'), 'Hesap silinemedi. Lütfen tekrar deneyin.');
    });

    testWidgets('silme sürerken çift dokunuş ikinci istek başlatmaz; geri tuşu diyaloğu kapatmaz', (tester) async {
      final env = e2Env(role: 'owner');
      final gate = Completer<void>();
      env.cloud.deleteGate = gate;
      await openDialog(tester, env);
      await typeInto(tester, 'field_delete_confirm', 'SİL');

      await tester.tap(find.byKey(const Key('btn_delete_account')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_delete_account')), warnIfMissed: false);
      await tester.pump();
      expect(env.cloud.deleteAccountArgs, hasLength(1));

      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await settle(tester);
      expect(find.byType(DeleteAccountDialog), findsOneWidget, reason: 'işlem sürerken kapanmaz');

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(DeleteAccountDialog), findsNothing);
    });

    testWidgets('dışarı dokunmak diyaloğu kapatmaz; "Vazgeç" kapatır ve hiçbir istek atılmaz', (tester) async {
      final env = e2Env(role: 'owner');
      await openDialog(tester, env);

      await tester.tapAt(const Offset(4, 4));
      await settle(tester);
      expect(find.byType(DeleteAccountDialog), findsOneWidget);

      await tapKey(tester, 'btn_delete_cancel');
      expect(find.byType(DeleteAccountDialog), findsNothing);
      expect(env.cloud.deleteAccountArgs, isEmpty);
      expect(env.state.authStatus, AuthStatus.authenticated);
    });

    testWidgets('TEK SAHİP olunan daire (409 SOLE_OWNER): hiçbir şey silinmez; daireler listelenir; önce devir yönlendirmesi yapılır', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.deleteAccountError = apiError(
        409,
        'Bazı dairelerin tek sahibisiniz.',
        code: 'SOLE_OWNER',
        details: <String, dynamic>{
          'homes': <Map<String, dynamic>>[
            <String, dynamic>{'id': kHomeA, 'name': 'Ev A', 'other_member_count': 2, 'device_count': 1},
            <String, dynamic>{'id': kHomeB, 'name': 'Yazlık'},
          ],
        },
      );
      await openDialog(tester, env);

      await typeInto(tester, 'field_delete_password', 'dogru-parola-1');
      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');

      expect(find.byKey(const Key('sole_owner_notice')), findsOneWidget);
      expect(find.byKey(const Key('sole_home_$kHomeA')), findsOneWidget);
      expect(find.byKey(const Key('sole_home_$kHomeB')), findsOneWidget);
      expect(find.text('Yazlık'), findsOneWidget);
      expect(textOf(tester, 'sole_home_detail_$kHomeA'), '2 diğer üye · 1 pano', reason: 'sunucu sayıları verdi');
      expect(find.byKey(const Key('sole_home_detail_$kHomeB')), findsNothing, reason: 'sayı yoksa ayrıntı satırı yok');
      expect(env.state.authStatus, AuthStatus.authenticated, reason: 'hiçbir şey silinmedi');
      expect(find.byKey(const Key('btn_delete_account')), findsNothing, reason: 'devir yapılana kadar silme düğmesi yok');

      // Listede olmayan daire için çökme yok, açık mesaj var.
      await tapKey(tester, 'btn_transfer_sole_$kHomeB');
      expect(textOf(tester, 'delete_error'), 'Bu daire listenizde görünmüyor. Daire listesini yenileyip tekrar deneyin.');

      // Aktif daire için devir diyaloğu açılır.
      await tapKey(tester, 'btn_transfer_sole_$kHomeA');
      expect(find.byType(TransferOwnershipDialog), findsOneWidget);
    });

    testWidgets('sunucu daire listesi vermezse kullanıcının kendi sahibi olduğu daireler gösterilir; "Tekrar Dene" formu geri getirir', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.deleteAccountError = apiError(409, 'Tek sahibisiniz.', code: 'SOLE_OWNER');
      await openDialog(tester, env);

      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapKey(tester, 'btn_delete_account');

      expect(find.byKey(const Key('sole_home_$kHomeA')), findsOneWidget);
      await tapKey(tester, 'btn_delete_retry');
      expect(find.byKey(const Key('field_delete_password')), findsOneWidget);
      expect(find.byKey(const Key('sole_owner_notice')), findsNothing);
    });
  });

  group('ChangePasswordPage (gönüllü kullanım)', () {
    Future<void> fill(WidgetTester tester, {String current = 'eski-parola-12', String next = 'yeni-parola-34', String? confirm}) async {
      await typeInto(tester, 'field_current_password', current);
      await typeInto(tester, 'field_new_password', next);
      await typeInto(tester, 'field_confirm_password', confirm ?? next);
    }

    testWidgets('geri dönülebilir; zorunlu uyarı ve zorunlu çıkış düğmesi yoktur', (tester) async {
      final env = e2Env(role: 'owner');
      await pushPage(tester, env, const ChangePasswordPage());

      // Üst çubuk NeonAppBar: geri düğmesi cam disktir (`nav_back`, ipucu "Back": `WidgetTester.pageBack` bulur); eski
      // Material `BackButton` türü artık yoktur (WP-FX-B bilinçli güncelleme).
      expect(find.byKey(const Key('nav_back')), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byKey(const Key('forced_notice')), findsNothing);
      expect(find.byKey(const Key('btn_forced_logout')), findsNothing);
      expect(find.text('Şifre Değiştir'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ChangePasswordPage), findsNothing, reason: 'geri düğmesi sayfayı kapatır');
    });

    testWidgets('boş mevcut şifre, kısa yeni şifre, aynı şifre ve uyuşmayan tekrar reddedilir; istek gitmez', (tester) async {
      final env = e2Env(role: 'owner');
      await pushPage(tester, env, const ChangePasswordPage());

      await tapKey(tester, 'btn_change_password');
      expect(find.text('Lütfen mevcut şifrenizi girin'), findsOneWidget);
      expect(find.text('Lütfen yeni şifrenizi girin'), findsOneWidget);

      await fill(tester, next: 'kisa');
      await tapKey(tester, 'btn_change_password');
      expect(find.text('Şifre en az 10 karakter olmalıdır'), findsOneWidget);

      await fill(tester, current: 'ayni-parola-12', next: 'ayni-parola-12');
      await tapKey(tester, 'btn_change_password');
      expect(find.text('Yeni şifre mevcut şifreyle aynı olamaz'), findsOneWidget);

      await fill(tester, confirm: 'baska-parola-56');
      await tapKey(tester, 'btn_change_password');
      expect(find.text('Şifreler eşleşmiyor'), findsOneWidget);

      expect(env.cloud.changePasswordArgs, isEmpty);
    });

    testWidgets('başarılı değişim: yeni şifre KIRPILMADAN gider, sayfa kapanır ve diğer cihazların kapatıldığı bildirilir', (tester) async {
      final env = e2Env(role: 'owner');
      await pushPage(tester, env, const ChangePasswordPage());

      await fill(tester, next: ' yeni parola 34 '); // baş/son boşluk
      await tapKey(tester, 'btn_change_password');
      await tester.pumpAndSettle();

      expect(env.cloud.changePasswordArgs.single, <String, Object?>{'currentLength': 14, 'newLength': 16, 'newEdgeSpace': true});
      expect(find.byType(ChangePasswordPage), findsNothing);
      expect(find.text('Şifreniz değiştirildi. Diğer cihazlardaki oturumlar kapatıldı.'), findsOneWidget);
      expect(env.state.authStatus, AuthStatus.authenticated, reason: 'bu cihazın oturumu sürer');
    });

    testWidgets('yanlış mevcut şifre alan hatası olarak gösterilir; sayfa açık kalır', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.changePasswordError = apiError(401, 'x', code: 'INVALID_CREDENTIALS');
      await pushPage(tester, env, const ChangePasswordPage());

      await fill(tester);
      await tapKey(tester, 'btn_change_password');

      expect(find.text('Mevcut şifre hatalı.'), findsOneWidget);
      expect(find.byType(ChangePasswordPage), findsOneWidget);
      expect(find.byKey(const Key('change_password_error')), findsNothing);
    });

    testWidgets('ağ hatası dostça gösterilir (ham metin yok); düğme yeniden etkindir ve tekrar denenince başarılı olur', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.changePasswordError = apiError(0, 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.', code: 'NETWORK');
      await pushPage(tester, env, const ChangePasswordPage());

      await fill(tester);
      await tapKey(tester, 'btn_change_password');

      expect(textOf(tester, 'change_password_error'), 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.');
      expect(onPressedIsNull(tester, 'btn_change_password'), isFalse);

      env.cloud.changePasswordError = null;
      await tapKey(tester, 'btn_change_password');
      await tester.pumpAndSettle();
      expect(env.cloud.changePasswordArgs, hasLength(2));
      expect(find.byType(ChangePasswordPage), findsNothing);
    });
  });

  group('parseDeepLink', () {
    test('sıradan rotalar ve boş girdi derin bağlantı sayılmaz (normal yönlendirme sürer)', () {
      expect(parseDeepLink(null), isNull);
      expect(parseDeepLink(''), isNull);
      expect(parseDeepLink('/'), isNull);
      expect(parseDeepLink('/ayarlar'), isNull);
      expect(parseDeepLink('ayarlar'), isNull, reason: 'şemasız ve yolsuz metin');
    });

    test('Android biçimi (yalnızca yol + parça): şifre sıfırlama ve giriş bağlantıları çözülür', () {
      final reset = parseDeepLink('/reset-password#token=$token')!;
      expect(reset.kind, DeepLinkKind.magicLink);
      expect(reset.magicLink!.kind, MagicLinkKind.resetPassword);
      expect(reset.magicLink!.token, token);

      final login = parseDeepLink('/magic-login#token=$token')!;
      expect(login.magicLink!.kind, MagicLinkKind.magicLogin);
      expect(parseDeepLink('/auth/magic-login#token=$token')!.magicLink!.kind, MagicLinkKind.magicLogin);
    });

    test('iOS biçimi (tam URL) ve sondaki eğik çizgi', () {
      expect(parseDeepLink(link('/reset-password'))!.magicLink!.kind, MagicLinkKind.resetPassword);
      expect(parseDeepLink(link('/magic-login/'))!.magicLink!.kind, MagicLinkKind.magicLogin);
    });

    test('belirteç sorguda ya da sunucu yabancıysa geçersizdir ve neden bildirilir', () {
      final inQuery = parseDeepLink('https://$host/reset-password?token=$token')!;
      expect(inQuery.kind, DeepLinkKind.invalid);
      expect(inQuery.message, 'Bağlantı geçersiz biçimde.');

      final foreign = parseDeepLink('https://kotu.example/reset-password#token=$token')!;
      expect(foreign.kind, DeepLinkKind.invalid);
      expect(foreign.message, 'Bu bağlantı tanınan bir sunucuya ait değil.');

      final missing = parseDeepLink('/reset-password')!;
      expect(missing.kind, DeepLinkKind.invalid);
      expect(missing.message, 'Bağlantıda doğrulama kodu yok.');
    });

    test('cihaz etiketi bağlantısı (/claim) UID ve PIN verir; PIN eksikse geçersizdir', () {
      final claim = parseDeepLink('/claim?uid=ahbu-s3-1a2b3c&pin=482916')!;
      expect(claim.kind, DeepLinkKind.claim);
      expect(claim.claimUid, 'AHBU-S3-1A2B3C');
      expect(claim.claimPin, '482916');

      final noPin = parseDeepLink('/claim?uid=AHBU-S3-1A2B3C')!;
      expect(noPin.kind, DeepLinkKind.invalid);
    });

    test('toString belirteci ve PIN\'i içermez', () {
      final link = parseDeepLink('/reset-password#token=$token')!;
      expect(link.toString(), isNot(contains(token)));
      expect(link.magicLink.toString(), isNot(contains(token)));
      final claim = parseDeepLink('/claim?uid=AHBU-S3-1A2B3C&pin=482916')!;
      expect(claim.toString(), isNot(contains('482916')));
    });
  });

  group('derin bağlantı yönlendirmesi (MaterialApp.onGenerateRoute)', () {
    final names = <String?>[];

    Future<GlobalKey<NavigatorState>> pumpRouter(WidgetTester tester, E2Env env) async {
      names.clear();
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: env.state,
          child: MaterialApp(
            navigatorKey: navKey,
            navigatorObservers: <NavigatorObserver>[_NameObserver(names)],
            home: const Scaffold(body: Center(child: Text('Ana ekran'))),
            onGenerateRoute: deepLinkOnGenerateRoute,
            onUnknownRoute: deepLinkOnUnknownRoute,
          ),
        ),
      );
      return navKey;
    }

    testWidgets('sihirli bağlantı ilgili sayfayı açar; rota adı BELİRTEÇ İÇERMEZ', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpRouter(tester, env);

      unawaited(navKey.currentState!.pushNamed('/reset-password#token=$token'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('magic_reset_view')), findsOneWidget);
      expect(names.where((n) => n != null && n.contains(token)), isEmpty, reason: 'rota adı belirteç taşımamalı');
      expect(names, contains('/deep-link'));
      expect(find.textContaining(token), findsNothing);
    });

    testWidgets('geçersiz sihirli bağlantı açık hata sayfası gösterir; "Ana Ekrana Dön" ana ekrana döner', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpRouter(tester, env);

      unawaited(navKey.currentState!.pushNamed('/reset-password?token=$token'));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'deep_link_invalid'), 'Bağlantı geçersiz biçimde.');
      expect(find.textContaining(token), findsNothing);
      expect(env.cloud.calls, isEmpty);

      await tapKey(tester, 'btn_deep_link_back');
      await tester.pumpAndSettle();
      expect(find.text('Ana ekran'), findsOneWidget);
    });

    testWidgets('bilinmeyen rota hata fırlatmaz: "açılamadı" sayfası gösterilir', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpRouter(tester, env);

      unawaited(navKey.currentState!.pushNamed('/bilinmeyen-sayfa'));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'deep_link_invalid'), 'Bu bağlantı açılamadı.');
      expect(tester.takeException(), isNull);
    });

    testWidgets('cihaz etiketi bağlantısı: oturum yoksa önce giriş yönlendirmesi gösterilir ve eşleştirme penceresi AÇILMAZ', (tester) async {
      final env = e2Env(authenticated: false);
      final navKey = await pumpRouter(tester, env);

      unawaited(navKey.currentState!.pushNamed('/claim?uid=AHBU-S3-1A2B3C&pin=482916'));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'deep_link_claim_text'), contains('önce hesabınızla giriş yapın'));
      expect(find.byKey(const Key('field_claim_uid')), findsNothing);
      expect(find.textContaining('482916'), findsNothing, reason: 'PIN ekranda gösterilmez');
    });

    testWidgets('cihaz etiketi bağlantısı: oturum varsa eşleştirme penceresi UID ve PIN ile dolu açılır; vazgeçilince ana ekrana dönülür', (tester) async {
      final env = e2Env(role: null);
      final navKey = await pumpRouter(tester, env);

      unawaited(navKey.currentState!.pushNamed('/claim?uid=AHBU-S3-1A2B3C&pin=482916'));
      await settle(tester);

      expect(fieldText(tester, 'field_claim_uid'), 'AHBU-S3-1A2B3C');
      expect(fieldText(tester, 'field_claim_pin'), '482916');
      expect(names.where((n) => n != null && n.contains('482916')), isEmpty);

      await tapKey(tester, 'btn_claim_cancel');
      await tester.pumpAndSettle();
      expect(find.text('Ana ekran'), findsOneWidget);
    });
  });
}

/// Açılan rota adlarını toplar (belirtecin rota adına sızmadığını doğrulamak için).
class _NameObserver extends NavigatorObserver {
  _NameObserver(this.names);

  final List<String?> names;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}
