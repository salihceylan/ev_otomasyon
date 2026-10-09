import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/legal/legal_document_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Kayıt ekranında Kullanıcı Sözleşmesi onayı (CONTRACTS: `POST /auth/register` + `accept_terms_version`):
///
/// * ZORUNLU onay kutusu "Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum." ("Kullanıcı Sözleşmesi" dokunulabilir);
///   işaretlenmeden "Kayıt Ol" pasiftir.
/// * Güncel sözleşme sürümü sayfa açılınca alınır ve kayıtta `accept_terms_version` olarak gönderilir; alınamazsa satır
///   içi hata + yeniden dene, kayıt gönderilemez.
/// * `409 LEGAL_VERSION_MISMATCH`: hesap açılmaz; sürüm yeniden alınır ve onay yeniden istenir.
/// * KVKK aydınlatma satırı BİLGİLENDİRMEDİR: onay kutusu yoktur (aydınlatma rızaya bağlanmaz).
void main() {
  Future<E2Env> openRegister(WidgetTester tester, {void Function(E2Env env)? configure, Size size = const Size(412, 1400)}) async {
    final env = e2Env(authenticated: false);
    configure?.call(env);
    await pumpApp(tester, state: env.state, size: size, child: const RegisterPage());
    await settle(tester);
    return env;
  }

  Future<void> fillValid(WidgetTester tester) async {
    await typeInto(tester, 'field_full_name', 'Ayşe Yılmaz');
    await typeInto(tester, 'field_email', 'yeni@ornek.com.tr');
    await typeInto(tester, 'field_email_confirm', 'yeni@ornek.com.tr');
    await typeInto(tester, 'field_password', kStrongPassword);
    await typeInto(tester, 'field_password_confirm', kStrongPassword);
  }

  Checkbox termsBox(WidgetTester tester) => tester.widget<Checkbox>(find.byKey(const Key('chk_accept_terms')));
  ElevatedButton submit(WidgetTester tester) => tester.widget<ElevatedButton>(find.byKey(const Key('btn_register_submit')));

  testWidgets('zorunlu onay kutusu: işaretlenmeden "Kayıt Ol" pasif, işaretlenince etkin', (tester) async {
    await openRegister(tester);

    expect(find.text("Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum."), findsOneWidget);
    expect(termsBox(tester).value, isFalse);
    expect(submit(tester).onPressed, isNull, reason: 'onay olmadan kayıt gönderilemez');

    await tapKey(tester, 'chk_accept_terms');
    expect(termsBox(tester).value, isTrue);
    expect(submit(tester).onPressed, isNotNull);

    await tapKey(tester, 'chk_accept_terms');
    expect(submit(tester).onPressed, isNull);
  });

  testWidgets('güncel sürüm sayfa açılınca alınır ve kayıtta accept_terms_version olarak gönderilir', (tester) async {
    final env = await openRegister(tester, configure: (env) => env.cloud.legalDocuments = testLegalDocuments(termsVersion: 3));

    expect(env.cloud.legalListCalls, 1);
    await fillValid(tester);
    await tapKey(tester, 'chk_accept_terms');
    await tapKey(tester, 'btn_register_submit');

    expect(env.cloud.registerArgs.single['acceptTermsVersion'], 3);
    expect(env.state.authStatus, AuthStatus.authenticated);
  });

  testWidgets('onay kutusunun etiketi ekran okuyucu için de söylenir; metne dokunmak kutuyu işaretler', (tester) async {
    await openRegister(tester);

    expect(termsBox(tester).semanticLabel, "Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum");
    await tester.tapOnText(find.textRange.ofSubstring('okudum ve kabul ediyorum'));
    await settle(tester);
    expect(termsBox(tester).value, isTrue);
  });

  testWidgets('klavyeden gönderimde (onaysız) kayıt GİTMEZ; nedeni söylenir; onaylanınca uyarı kalkar', (tester) async {
    final env = await openRegister(tester);
    await fillValid(tester); // odak son alanda (Şifre Tekrar)

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(env.cloud.registerArgs, isEmpty);
    expect(textOf(tester, 'register_terms_notice'), "Kayıt olmak için Kullanıcı Sözleşmesi'ni okuyup onaylamanız gerekir.");

    await tapKey(tester, 'chk_accept_terms');
    expect(find.byKey(const Key('register_terms_notice')), findsNothing);
  });

  testWidgets('erişilebilirlik: onay kutusu, bağlantılar ve yeniden dene düğmesi etiketli ve yeterli büyüklükte', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final env = await openRegister(tester, configure: (env) => env.cloud.legalError = ApiException.network());
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

      env.cloud.legalError = null;
      await tapKey(tester, 'btn_register_terms_retry');
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('"Kullanıcı Sözleşmesi" bağlantısı sözleşme metnini açar (kutu işaretlenmez)', (tester) async {
    final env = await openRegister(tester);

    await tester.tapOnText(
      find.textRange.ofSubstring('Kullanıcı Sözleşmesi', descendentOf: find.byKey(const Key('register_terms_text'))),
    );
    await settle(tester);

    expect(find.byType(LegalDocumentPage), findsOneWidget);
    expect(tester.widget<LegalDocumentPage>(find.byType(LegalDocumentPage)).kind, LegalDocumentKind.terms);
    expect(env.cloud.legalDocumentCalls, <String>['terms']);

    await tester.pageBack();
    await settle(tester);
    expect(termsBox(tester).value, isFalse, reason: 'bağlantı onay yerine geçmez');
  });

  testWidgets('KVKK satırı bilgilendirmedir: onay kutusu YOK; bağlantısı aydınlatma metnini açar', (tester) async {
    final env = await openRegister(tester);

    expect(find.byType(Checkbox), findsOneWidget, reason: 'sayfadaki TEK onay kutusu sözleşme onayıdır');
    expect(find.text('Kişisel verileriniz Gizlilik Politikası ve KVKK Aydınlatma Metni kapsamında işlenir.'), findsOneWidget);
    expect(
      find.ancestor(of: find.byKey(const Key('register_privacy_notice')), matching: find.byType(CheckboxListTile)),
      findsNothing,
    );

    await tester.tapOnText(find.textRange.ofSubstring('Gizlilik Politikası ve KVKK Aydınlatma Metni'));
    await settle(tester);

    expect(tester.widget<LegalDocumentPage>(find.byType(LegalDocumentPage)).kind, LegalDocumentKind.privacy);
    expect(env.cloud.legalDocumentCalls, <String>['privacy']);
  });

  testWidgets('sürüm alınamazsa satır içi hata + "Tekrar Dene"; kayıt gönderilemez; yeniden deneme sürümü alır', (tester) async {
    final env = await openRegister(tester, configure: (env) => env.cloud.legalError = ApiException.network());

    expect(find.byKey(const Key('register_terms_error')), findsOneWidget);
    expect(textOf(tester, 'register_terms_error'), contains('Kullanıcı Sözleşmesi yüklenemedi'));
    expect(termsBox(tester).onChanged, isNull, reason: 'sürüm bilinmeden onay verilemez');
    expect(submit(tester).onPressed, isNull);

    env.cloud.legalError = null;
    await tapKey(tester, 'btn_register_terms_retry');

    expect(env.cloud.legalListCalls, 2);
    expect(find.byKey(const Key('register_terms_error')), findsNothing);
    expect(termsBox(tester).onChanged, isNotNull);
  });

  testWidgets('sunucuda sözleşme yoksa (boş liste) aynı hata gösterilir; kayıt gönderilemez', (tester) async {
    final env = await openRegister(tester, configure: (env) => env.cloud.legalDocuments = <LegalDocument>[]);

    expect(find.byKey(const Key('register_terms_error')), findsOneWidget);
    await fillValid(tester);
    expect(submit(tester).onPressed, isNull);
    expect(env.cloud.registerArgs, isEmpty);
  });

  testWidgets('409 LEGAL_VERSION_MISMATCH: hesap açılmaz, onay kalkar, güncel sürüm alınır ve yeniden sorulur', (tester) async {
    final env = await openRegister(tester);
    await fillValid(tester);
    await tapKey(tester, 'chk_accept_terms');

    // Sayfa açıkken sunucuda yeni sürüm yayımlandı.
    env.cloud
      ..legalDocuments = testLegalDocuments(termsVersion: 2)
      ..registerError = legalVersionMismatch(2);
    await tapKey(tester, 'btn_register_submit');

    expect(env.cloud.registerArgs.single['acceptTermsVersion'], 1);
    expect(env.state.authStatus, isNot(AuthStatus.authenticated), reason: 'hesap açılmadı');
    expect(textOf(tester, 'register_terms_notice'), contains('Kullanıcı Sözleşmesi güncellendi'));
    expect(find.byKey(const Key('register_error')), findsNothing, reason: 'genel hata kutusu yerine sözleşme uyarısı');
    expect(termsBox(tester).value, isFalse, reason: 'güncel metin için yeniden onay istenir');
    expect(submit(tester).onPressed, isNull);
    expect(env.cloud.legalListCalls, 2, reason: 'sürüm yeniden alındı');

    env.cloud.registerError = null;
    await tapKey(tester, 'chk_accept_terms');
    await tapKey(tester, 'btn_register_submit');

    expect(env.cloud.registerArgs.last['acceptTermsVersion'], 2);
    expect(env.state.authStatus, AuthStatus.authenticated);
  });

  for (final theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    testWidgets('dar ekran (320 dp) ve yazı ölçeği 2.0: onay satırları taşmaz (${theme.name})', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(
        tester,
        state: env.state,
        size: const Size(320, 2400),
        themeMode: theme,
        child: MediaQuery.withClampedTextScaling(minScaleFactor: 2.0, maxScaleFactor: 2.0, child: const RegisterPage()),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('chk_accept_terms')), findsOneWidget);
      expect(find.byKey(const Key('register_privacy_notice')), findsOneWidget);
    });
  }
}
