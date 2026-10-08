import 'dart:convert';
import 'dart:io';

import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/ui/pages/legal/legal_document_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Gerçek yasal metinler (`server/legal/*.md`; sunucunun yayımladığı Kullanıcı Sözleşmesi ve KVKK aydınlatma metni)
/// uygulamada çizilir: metnin TAMAMI dar ekranda (320 dp) ve büyük yazıda (2.0) taşmadan okunur; başlık, "Sürüm N ·
/// Yürürlük: GG.AA.YYYY" satırı, taslakta TASLAK şeridi ve herkese açık adres görünür.
///
/// Metin sunucunun blok modeline ([LegalBlock]) burada YALNIZ bu test için basit bir satır ayrıştırıcıyla çevrilir
/// (belgelerde her paragraf ve madde tek satırdır). Asıl ayrıştırıcı sunucudadır; blok biçimi ve belgelerin sözleşmeye
/// uygunluğu `server/test/legal/legal_real_documents.test.js`'te sınanır.
void main() {
  for (final kind in LegalDocumentKind.values) {
    final document = _readServerDocument(kind.slug);

    test('${kind.slug}.md okunur: sözleşmedeki kimlik / başlık / onay kuralı ve gövde', () {
      expect(document.id, kind.id);
      expect(document.slug, kind.slug);
      expect(document.title, kind.title, reason: 'uygulamanın yedek başlığı sunucu başlığıyla aynı');
      expect(document.info.requiresAcceptance, kind == LegalDocumentKind.terms, reason: 'KVKK metni onaya bağlanmaz');
      expect(document.version, greaterThan(0));
      expect(document.bodyBlocks.where((b) => b.type == LegalBlockType.h2), isNotEmpty);
      expect(document.bodyBlocks.where((b) => b.type == LegalBlockType.p), isNotEmpty);
    });

    for (final theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      testWidgets('${kind.slug}: metnin tamamı dar ekran + yazı ölçeği 2.0 ile taşmadan çizilir (${theme.name})', (tester) async {
        final env = e2Env(authenticated: false);
        env.cloud.legalDocuments = <LegalDocument>[document];
        await pumpApp(
          tester,
          state: env.state,
          size: const Size(320, 640),
          themeMode: theme,
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: 2.0,
            maxScaleFactor: 2.0,
            child: LegalDocumentPage(kind: kind),
          ),
        );
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(env.cloud.legalDocumentCalls, <String>[kind.id]);
        expect(textOf(tester, 'legal_title'), kind.title);
        expect(textOf(tester, 'legal_meta'), 'Sürüm ${document.version} · Yürürlük: ${formatLegalDate(document.info.effectiveDate)}');
        expect(find.byKey(const Key('legal_draft_banner')), document.isDraft ? findsOneWidget : findsNothing);
        final blocks = document.bodyBlocks;
        expect(find.byKey(Key('legal_block_${blocks.length - 1}')), findsOneWidget, reason: 'son blok da çizilir');
        expect(find.byKey(Key('legal_block_${blocks.length}')), findsNothing);
        expect(find.textContaining('**'), findsNothing, reason: 'kalın işaretleri görünmez');
        expect(
          tester.widget<SelectableText>(find.byKey(const Key('legal_public_url'))).data,
          'https://fake.invalid/yasal/${kind.slug}',
        );

        // Sonuna kadar kaydırılabilir (uzun metin kesilmez); en alttaki adres görünür olur, taşma yok.
        await tester.ensureVisible(find.byKey(const Key('legal_public_url')));
        await tester.pump();
        expect(find.byKey(const Key('legal_public_url')).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

/// `server/legal/<slug>.md` -> [LegalDocument] (YALNIZ test: tek satırlık paragraf / madde varsayımı).
LegalDocument _readServerDocument(String slug) {
  final lines = const LineSplitter().convert(File('server/legal/$slug.md').readAsStringSync());
  if (lines.isEmpty || lines.first.trim() != '---') throw FormatException('ön bilgi yok: $slug');
  final end = lines.indexWhere((l) => l.trim() == '---', 1);
  if (end < 0) throw FormatException('ön bilgi kapanmıyor: $slug');
  final meta = <String, String>{
    for (final line in lines.sublist(1, end))
      if (line.contains(':')) line.substring(0, line.indexOf(':')).trim(): line.substring(line.indexOf(':') + 1).trim(),
  };
  final heading = RegExp(r'^(#{1,3})\s+(\S.*)$');
  final bullet = RegExp(r'^-\s+(\S.*)$');
  final ordered = RegExp(r'^(\d{1,9})\.\s+(\S.*)$');
  final blocks = <LegalBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(LegalBlock(type: LegalBlockType.p, text: paragraph.join(' ')));
    paragraph.clear();
  }

  for (final raw in lines.sublist(end + 1)) {
    final line = raw.trim();
    final h = heading.firstMatch(line);
    final li = bullet.firstMatch(line);
    final oli = paragraph.isEmpty ? ordered.firstMatch(line) : null;
    if (line.isEmpty) {
      flush();
    } else if (h != null) {
      flush();
      blocks.add(LegalBlock(type: LegalBlockType.parse('h${h[1]!.length}'), text: h[2]!));
    } else if (li != null) {
      flush();
      blocks.add(LegalBlock(type: LegalBlockType.li, text: li[1]!));
    } else if (oli != null) {
      blocks.add(LegalBlock(type: LegalBlockType.oli, text: oli[2]!, n: int.parse(oli[1]!)));
    } else {
      paragraph.add(line);
    }
  }
  flush();
  return LegalDocument(
    info: LegalDocumentInfo.fromJson(<String, dynamic>{...meta, 'url': '/yasal/${meta['slug']}'}),
    blocks: blocks,
  );
}
