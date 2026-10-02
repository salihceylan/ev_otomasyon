import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Paylaşılan yardımcılar (E1 ve F de kullanır): yazarak onay, onaylı çıkış + yığın temizleme,
/// kullanıcı dostu hata gösterimi.
void main() {
  group('ConfirmDestructiveDialog (yazarak onay)', () {
    Future<Opened<bool>> open(WidgetTester tester, {String phrase = 'SİL'}) {
      final env = e2Env(role: null);
      return openFromHost<bool>(
        tester,
        env.state,
        (context) => ConfirmDestructiveDialog.show(
          context,
          title: 'Silinsin mi?',
          message: 'Bu işlem geri alınamaz.',
          confirmPhrase: phrase,
          confirmLabel: 'Sil',
        ),
      );
    }

    testWidgets('onay düğmesi, ifade doğru yazılana kadar pasiftir', (tester) async {
      await open(tester);

      ElevatedButton confirm() => tester.widget<ElevatedButton>(find.byKey(const Key('btn_confirm_destructive')));
      expect(confirm().onPressed, isNull);

      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'SI');
      await tester.pump();
      expect(confirm().onPressed, isNull, reason: 'kısmi ifade yetmez');

      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'SİL');
      await tester.pump();
      expect(confirm().onPressed, isNotNull);
    });

    testWidgets('Türkçe i/İ ve küçük harf farkı gözetilmez: "sil" yazmak da onaylar', (tester) async {
      final opened = await open(tester);
      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'sil');
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
      await settle(tester);

      expect(opened.done, isTrue);
      expect(opened.result, isTrue);
      expect(find.byType(ConfirmDestructiveDialog), findsNothing);
    });

    testWidgets('vazgeç ve dışarı dokunma `false` döndürür', (tester) async {
      var opened = await open(tester);
      await tester.tap(find.byKey(const Key('btn_cancel_destructive')));
      await settle(tester);
      expect(opened.result, isFalse);

      opened = await open(tester);
      await tester.tapAt(const Offset(4, 4)); // diyalog dışı bariyer
      await settle(tester);
      expect(opened.done, isTrue);
      expect(opened.result, isFalse);
    });

    testWidgets('UID\'nin son 4 hanesi gibi özel ifade istenebilir', (tester) async {
      final opened = await open(tester, phrase: 'A1B2');
      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'a1b2');
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
      await settle(tester);
      expect(opened.result, isTrue);
    });

    testWidgets('klavyeden "bitti" ile de yalnızca doğru ifadede onaylanır', (tester) async {
      final opened = await open(tester);
      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'yanlış');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(opened.done, isFalse, reason: 'yanlış ifade ile onaylanmaz');
      expect(find.byType(ConfirmDestructiveDialog), findsOneWidget);
    });
  });

  group('confirmAndLogout (onay + çıkış + yığın temizleme)', () {
    /// Giriş yapılmış durum + üzerinde itilmiş bir sayfa olan uygulama.
    Future<E2Env> pumpWithPushedPage(WidgetTester tester) async {
      final env = e2Env(role: null, authenticated: false);
      await env.state.login(kUserEmail, kStrongPassword);
      await settle(tester, frames: 1);
      expect(env.state.authStatus, AuthStatus.authenticated);

      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('push_page'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (pageContext) => Scaffold(
                      appBar: AppBar(title: const Text('İkinci sayfa')),
                      body: Center(
                        child: ElevatedButton(
                          key: const Key('do_logout'),
                          onPressed: () => confirmAndLogout(pageContext, env.state),
                          child: const Text('Çık'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('push_page')));
      await settle(tester);
      expect(find.text('İkinci sayfa'), findsOneWidget);
      return env;
    }

    testWidgets('vazgeçilirse oturum ve sayfa yığını korunur', (tester) async {
      final env = await pumpWithPushedPage(tester);
      await tester.tap(find.byKey(const Key('do_logout')));
      await settle(tester);
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_logout_cancel')));
      await settle(tester);

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(find.text('İkinci sayfa'), findsOneWidget);
      expect(env.cloud.revokedRefreshTokens, isEmpty);
    });

    testWidgets('onaylanırsa çıkış yapılır, yerel veri silinir ve navigator ilk rotaya döner', (tester) async {
      final env = await pumpWithPushedPage(tester);
      await tester.tap(find.byKey(const Key('do_logout')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('btn_logout_confirm')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(env.state.currentUser, isNull);
      expect(await env.h.storage.getAuthToken(), isNull, reason: 'güvenli depo temizlendi');
      expect(find.text('İkinci sayfa'), findsNothing, reason: 'itilen sayfa kapandı');
      expect(find.byKey(const Key('push_page')), findsOneWidget, reason: 'ilk rota gösteriliyor');
      expect(env.cloud.revokedRefreshTokens, hasLength(1), reason: 'sunucuda refresh iptali (en iyi çaba)');
    });

    testWidgets('onaylanan çıkışta Google hesabı da bırakılır (sonraki girişte hesap seçilebilsin); vazgeçilirse bırakılmaz', (tester) async {
      const channel = MethodChannel('plugins.flutter.io/google_sign_in');
      final googleCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        googleCalls.add(call.method);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final env = await pumpWithPushedPage(tester);

      await tester.tap(find.byKey(const Key('do_logout')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('btn_logout_cancel')));
      await settle(tester);
      expect(googleCalls, isNot(contains('signOut')), reason: 'vazgeçilen çıkışta Google oturumuna dokunulmaz');

      await tester.tap(find.byKey(const Key('do_logout')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('btn_logout_confirm')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(googleCalls, contains('signOut'));
    });

    testWidgets('Google eklentisi kullanılamazsa (hata) çıkış yine de tamamlanır', (tester) async {
      const channel = MethodChannel('plugins.flutter.io/google_sign_in');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'sign_in_failed', message: 'eklenti hatası');
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final env = await pumpWithPushedPage(tester);

      await tester.tap(find.byKey(const Key('do_logout')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('btn_logout_confirm')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(tester.takeException(), isNull);
    });

    testWidgets('açık diyalog ve itilmiş sayfa birlikte kapatılır (yığın tümüyle temizlenir)', (tester) async {
      final env = await pumpWithPushedPage(tester);
      final pageContext = tester.element(find.byKey(const Key('do_logout')));
      // Sayfanın üstünde zaten bir diyalog açık.
      showDialog<void>(
        context: pageContext,
        builder: (_) => const AlertDialog(title: Text('Açık diyalog')),
      );
      await settle(tester);
      expect(find.text('Açık diyalog'), findsOneWidget);

      // Çıkış, açık diyaloğun üstünden de başlatılabilir.
      final result = confirmAndLogout(pageContext, env.state);
      await settle(tester);
      await tester.tap(find.byKey(const Key('btn_logout_confirm')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(await result, isTrue);
      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(find.text('Açık diyalog'), findsNothing);
      expect(find.text('İkinci sayfa'), findsNothing);
      expect(Navigator.of(tester.element(find.byKey(const Key('push_page')))).canPop(), isFalse);
    });
  });

  group('showFriendlyError', () {
    testWidgets('ApiException mesajını gösterir; ham istisna metnini ASLA göstermez', (tester) async {
      final env = e2Env(role: null);
      late BuildContext captured;
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox());
        }),
      );

      showFriendlyError(captured, apiError(409, 'Bu cihaz zaten kayıtlı.', code: 'CONFLICT'));
      await settle(tester);
      expect(find.text('Bu cihaz zaten kayıtlı.'), findsOneWidget);

      showFriendlyError(captured, Exception('SQL: constraint users_email_key violated'));
      await settle(tester);
      expect(find.textContaining('constraint'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.text('İşlem tamamlanamadı. Lütfen tekrar deneyin.'), findsOneWidget);

      showFriendlyError(captured, StateError('x'), fallback: 'Özel yedek mesaj.');
      await settle(tester);
      expect(find.text('Özel yedek mesaj.'), findsOneWidget);
    });

    testWidgets('bağlam kapandıktan sonra çağrılırsa hata fırlatmaz', (tester) async {
      final env = e2Env(role: null);
      late BuildContext captured;
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox());
        }),
      );
      await tester.pumpWidget(const SizedBox()); // ağaç kaldırıldı
      expect(() => showFriendlyError(captured, apiError(500, 'x')), returnsNormally);
    });
  });
}
