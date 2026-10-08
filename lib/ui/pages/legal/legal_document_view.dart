import 'package:flutter/material.dart';

import '../../../models/legal_models.dart';
import '../../common/inline_message.dart';
import '../../motion/skeleton.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Taslak (kesinleşmemiş) metin şeridinin metni.
const String kLegalDraftNotice = 'TASLAK: Bu metin henüz kesinleşmedi; yürürlüğe girmeden önce değişebilir.';

/// Yasal metnin tamamı: başlık, "Sürüm N · Yürürlük: GG.AA.YYYY" satırı, taslaksa TASLAK şeridi, gövde blokları ve
/// (verilirse) herkese açık adres. Metin sayfası (`LegalDocumentPage`) ve sözleşme onay kapısı (`TermsAcceptancePage`)
/// AYNI görünümü kullanır.
///
/// Anahtarlar: `Key('legal_title')`, `Key('legal_meta')`, `Key('legal_draft_banner')`, blok metinleri
/// `Key('legal_block_<sıra>')`, `Key('legal_public_url')`.
class LegalDocumentView extends StatelessWidget {
  const LegalDocumentView({super.key, required this.document, this.publicUrl});

  final LegalDocument document;

  /// Herkese açık adres (`<sunucu>/yasal/<slug>`); `null` ise gösterilmez.
  final String? publicUrl;

  @override
  Widget build(BuildContext context) {
    final url = publicUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            document.title,
            key: const Key('legal_title'),
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.3, color: AppTheme.getTextPrimary(context)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          document.metaLine,
          key: const Key('legal_meta'),
          style: TextStyle(fontSize: AppText.caption, fontWeight: FontWeight.w600, color: AppTheme.getTextMuted(context)),
        ),
        if (document.isDraft) ...[
          const SizedBox(height: 12),
          const InlineMessage.warning(kLegalDraftNotice, key: Key('legal_draft_banner')),
        ],
        const SizedBox(height: 6),
        LegalBlocksView(blocks: document.bodyBlocks),
        if (url != null) ...[
          const SizedBox(height: 22),
          LegalPublicAddress(url: url),
        ],
      ],
    );
  }
}

/// Sunucunun blok modelini çizer (markdown paketi yok): `h1`/`h2`/`h3` başlık (ekran okuyucuya başlık olarak bildirilir),
/// `p` paragraf, `li` madde işaretli, `oli` numaralı öğe. Satır içi yalnız `**kalın**` desteklenir ([parseLegalInline]).
/// Metin boyutları kullanıcının yazı ölçeğiyle büyür; satırlar sarılır, kesilmez.
class LegalBlocksView extends StatelessWidget {
  const LegalBlocksView({super.key, required this.blocks});

  final List<LegalBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: _gapBefore(blocks[i], i == 0 ? null : blocks[i - 1])),
            child: _block(context, blocks[i], Key('legal_block_$i'), primary),
          ),
      ],
    );
  }

  /// Blok öncesi boşluk: başlıklar bölüm ayırır; ardışık maddeler sıkı durur.
  static double _gapBefore(LegalBlock block, LegalBlock? previous) {
    final listItem = block.type == LegalBlockType.li || block.type == LegalBlockType.oli;
    final previousListItem = previous != null && (previous.type == LegalBlockType.li || previous.type == LegalBlockType.oli);
    switch (block.type) {
      case LegalBlockType.h1:
      case LegalBlockType.h2:
        return previous == null ? 8 : 20;
      case LegalBlockType.h3:
        return previous == null ? 8 : 14;
      case LegalBlockType.p:
      case LegalBlockType.li:
      case LegalBlockType.oli:
        if (listItem && previousListItem) return 6;
        return 10;
    }
  }

  Widget _block(BuildContext context, LegalBlock block, Key key, Color primary) {
    switch (block.type) {
      case LegalBlockType.h1:
        return _heading(block, key, TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.3, color: primary));
      case LegalBlockType.h2:
        return _heading(block, key, TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.3, color: primary));
      case LegalBlockType.h3:
        return _heading(block, key, TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w700, height: 1.3, color: primary));
      case LegalBlockType.p:
        return _rich(block.text, key, _body(primary));
      case LegalBlockType.li:
        return _item(context, marker: '•', excludeMarker: true, block: block, key: key, primary: primary);
      case LegalBlockType.oli:
        final n = block.n;
        return _item(
          context,
          marker: n == null ? '•' : '$n.',
          excludeMarker: n == null,
          block: block,
          key: key,
          primary: primary,
        );
    }
  }

  static TextStyle _body(Color color) => TextStyle(fontSize: AppText.body, height: 1.5, color: color);

  static Widget _heading(LegalBlock block, Key key, TextStyle style) =>
      Semantics(header: true, container: true, child: _rich(block.text, key, style));

  /// Madde: işaret / numara (sabit genişlikli sütun) + sarılan metin (asılı girinti).
  Widget _item(
    BuildContext context, {
    required String marker,
    required bool excludeMarker,
    required LegalBlock block,
    required Key key,
    required Color primary,
  }) {
    final markerText = Text(marker, style: _body(primary).copyWith(fontWeight: FontWeight.w700));
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Numara metnin ölçeğiyle büyür: genişlik yazı ölçeğine göre (2.0x'te "10." sığar).
          ConstrainedBox(
            constraints: BoxConstraints(minWidth: MediaQuery.textScalerOf(context).scale(26)),
            child: excludeMarker ? ExcludeSemantics(child: markerText) : markerText,
          ),
          const SizedBox(width: 4),
          Expanded(child: _rich(block.text, key, _body(primary))),
        ],
      ),
    );
  }

  /// `**kalın**` parçalı metin. Kök [TextSpan] yalnız çocuk parçaları taşır; taban stil [Text.style]'dadır.
  static Widget _rich(String text, Key key, TextStyle style) => Text.rich(
        TextSpan(
          children: <InlineSpan>[
            for (final part in parseLegalInline(text))
              TextSpan(text: part.text, style: part.bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
          ],
        ),
        key: key,
        style: style,
      );
}

/// Herkese açık adres: açıklama + seçilebilir (kopyalanabilir) adres. Uygulamada tarayıcı açma paketi yoktur; kullanıcı
/// adresi kopyalayıp tarayıcıda açabilir. Adres alanı en az 48 dp yüksektir (dokunma hedefi).
class LegalPublicAddress extends StatelessWidget {
  const LegalPublicAddress({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bu metne tarayıcıdan da ulaşabilirsiniz:',
          style: TextStyle(fontSize: AppText.caption, color: AppTheme.getTextMuted(context)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppTouch.minTarget, minWidth: double.infinity),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SelectableText(
              url,
              key: const Key('legal_public_url'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.infoText(context)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Metin yüklenirken iskelet (spinner yerine): başlık, üst satır ve paragraf satırları. Ekran okuyucuya "yükleniyor"
/// bildirilir.
class LegalLoadingSkeleton extends StatelessWidget {
  const LegalLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Metin yükleniyor',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Skeleton(width: 220, height: 20),
            const SizedBox(height: 10),
            const Skeleton(width: 160, height: 12),
            const SizedBox(height: 22),
            for (var i = 0; i < 6; i++) ...[
              Skeleton(width: i == 5 ? 180 : null, height: 12),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}
