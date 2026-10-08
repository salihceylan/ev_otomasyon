import 'dart:async';

import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/legal/legal_document_page.dart';
import 'package:ev_otomasyon/ui/pages/legal/legal_document_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Yasal metin görünümü: sunucunun blok modeli (başlık, paragraf, madde, numaralı madde, satır içi **kalın**) uygulamada
/// çizilir; metin sayfası sürüm / yürürlük satırını, TASLAK şeridini, yükleniyor / hata + yeniden dene hâllerini ve
/// herkese açık adresi (seçilebilir) gösterir.
void main() {
  group('LegalBlocksView', () {
    const blocks = <LegalBlock>[
      LegalBlock(type: LegalBlockType.h2, text: '1. Taraflar'),
      LegalBlock(type: LegalBlockType.p, text: 'Bu metin **önemlidir** ve okunmalıdır.'),
      LegalBlock(type: LegalBlockType.li, text: 'Madde işaretli **kalın** öğe'),
      LegalBlock(type: LegalBlockType.oli, text: 'Üçüncü öğe', n: 3),
      LegalBlock(type: LegalBlockType.h3, text: '1.1 Alt başlık'),
    ];

    Future<void> pumpBlocks(WidgetTester tester) => pumpApp(
          tester,
          child: const Scaffold(body: SingleChildScrollView(child: LegalBlocksView(blocks: blocks))),
        );

    TextSpan spanOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).textSpan! as TextSpan;

    testWidgets('her blok çizilir: başlıklar, paragraf, madde işareti ve numara', (tester) async {
      await pumpBlocks(tester);

      expect(find.text('1. Taraflar'), findsOneWidget);
      expect(find.text('Bu metin önemlidir ve okunmalıdır.'), findsOneWidget, reason: '** işaretleri görünmez');
      expect(find.text('Madde işaretli kalın öğe'), findsOneWidget);
      expect(find.text('•'), findsOneWidget);
      expect(find.text('3.'), findsOneWidget);
      expect(find.text('Üçüncü öğe'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
    });

    testWidgets('**kalın** parça kalın, çevresindeki metin normal yazılır', (tester) async {
      await pumpBlocks(tester);

      final paragraph = spanOf(tester, 'legal_block_1');
      final parts = paragraph.children!.cast<TextSpan>();
      final bold = parts.singleWhere((s) => s.text == 'önemlidir');
      final normal = parts.firstWhere((s) => s.text == 'Bu metin ');
      expect(bold.style?.fontWeight, FontWeight.w700);
      expect(normal.style?.fontWeight, isNot(FontWeight.w700));

      final item = spanOf(tester, 'legal_block_2').children!.cast<TextSpan>();
      expect(item.singleWhere((s) => s.text == 'kalın').style?.fontWeight, FontWeight.w700);
    });

    testWidgets('başlıklar ekran okuyucuya başlık olarak bildirilir', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBlocks(tester);
      expect(tester.getSemantics(find.text('1. Taraflar')), matchesSemantics(isHeader: true, label: '1. Taraflar'));
      handle.dispose();
    });
  });

  group('LegalDocumentPage', () {
    Future<E2Env> openPage(
      WidgetTester tester,
      LegalDocumentKind kind, {
      void Function(E2Env env)? configure,
      Size size = const Size(412, 915),
      double textScale = 1.0,
    }) async {
      final env = e2Env(authenticated: false);
      configure?.call(env);
      await pumpApp(
        tester,
        state: env.state,
        size: size,
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: LegalDocumentPage(kind: kind),
        ),
      );
      return env;
    }

    testWidgets('yüklenirken iskelet; yüklenince başlık, sürüm satırı, TASLAK şeridi, bloklar ve seçilebilir adres', (tester) async {
      final gate = Completer<void>();
      final env = await openPage(tester, LegalDocumentKind.terms, configure: (env) => env.cloud.legalGate = gate);

      expect(find.byKey(const Key('legal_loading')), findsOneWidget);
      expect(find.byKey(const Key('legal_meta')), findsNothing);

      gate.complete();
      await settle(tester);

      expect(env.cloud.legalDocumentCalls, <String>['terms']);
      expect(find.byKey(const Key('legal_loading')), findsNothing);
      expect(textOf(tester, 'legal_title'), 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları');
      expect(textOf(tester, 'legal_meta'), 'Sürüm 1 · Yürürlük: 08.10.2026');
      expect(find.byKey(const Key('legal_draft_banner')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('legal_draft_banner')), matching: find.textContaining('TASLAK')), findsOneWidget);
      expect(find.text('1. Taraflar'), findsOneWidget);
      expect(find.text('Kullanıcı Sözleşmesi metninin 1. sürümü.'), findsOneWidget);
      expect(
        find.text('Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları'),
        findsOneWidget,
        reason: 'gövdenin başlıkla aynı h1 bloğu ikinci kez çizilmez',
      );
      final url = tester.widget<SelectableText>(find.byKey(const Key('legal_public_url')));
      expect(url.data, 'https://fake.invalid/yasal/kullanici-sozlesmesi');
    });

    testWidgets('kesinleşmiş (final) metinde TASLAK şeridi yoktur', (tester) async {
      await openPage(
        tester,
        LegalDocumentKind.terms,
        configure: (env) => env.cloud.legalDocuments = testLegalDocuments(termsVersion: 2, termsStatus: 'final'),
      );
      await settle(tester);

      expect(textOf(tester, 'legal_meta'), 'Sürüm 2 · Yürürlük: 08.10.2026');
      expect(find.byKey(const Key('legal_draft_banner')), findsNothing);
      expect(find.textContaining('TASLAK'), findsNothing);
    });

    testWidgets('çevrimdışı: Türkçe hata + "Tekrar Dene"; adres yine gösterilir; yeniden deneme metni yükler', (tester) async {
      final env = await openPage(
        tester,
        LegalDocumentKind.terms,
        configure: (env) => env.cloud.legalError = ApiException.network(),
      );
      await settle(tester);

      expect(textOf(tester, 'legal_error'), contains('Sunucuya ulaşılamadı'));
      expect(find.byKey(const Key('legal_meta')), findsNothing);
      expect(tester.widget<SelectableText>(find.byKey(const Key('legal_public_url'))).data,
          'https://fake.invalid/yasal/kullanici-sozlesmesi',
          reason: 'internet gelince tarayıcıdan da okunabilir');

      env.cloud.legalError = null;
      await tapKey(tester, 'btn_legal_retry');

      expect(env.cloud.legalDocumentCalls, <String>['terms', 'terms']);
      expect(find.byKey(const Key('legal_error')), findsNothing);
      expect(textOf(tester, 'legal_meta'), 'Sürüm 1 · Yürürlük: 08.10.2026');
    });

    testWidgets('gizlilik metni kendi kimliğiyle istenir; adresi /yasal/gizlilik-politikasi', (tester) async {
      final env = await openPage(tester, LegalDocumentKind.privacy);
      await settle(tester);

      expect(env.cloud.legalDocumentCalls, <String>['privacy']);
      expect(textOf(tester, 'legal_title'), 'Gizlilik Politikası ve KVKK Aydınlatma Metni');
      expect(tester.widget<SelectableText>(find.byKey(const Key('legal_public_url'))).data,
          'https://fake.invalid/yasal/gizlilik-politikasi');
    });

    testWidgets('erişilebilirlik: adres alanı ve "Tekrar Dene" yeterli büyüklükte ve etiketli', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await openPage(tester, LegalDocumentKind.terms);
        await settle(tester);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await tester.pumpWidget(const SizedBox());
        await openPage(tester, LegalDocumentKind.terms, configure: (env) => env.cloud.legalError = ApiException.network());
        await settle(tester);
        expect(find.byKey(const Key('btn_legal_retry')), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        handle.dispose();
      }
    });

    for (final theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      testWidgets('dar ekran (320 dp) ve yazı ölçeği 2.0: taşma yok (${theme.name})', (tester) async {
        final env = e2Env(authenticated: false);
        await pumpApp(
          tester,
          state: env.state,
          size: const Size(320, 640),
          themeMode: theme,
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: 2.0,
            maxScaleFactor: 2.0,
            child: const LegalDocumentPage(kind: LegalDocumentKind.privacy),
          ),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('legal_meta')), findsOneWidget);
      });
    }
  });
}
