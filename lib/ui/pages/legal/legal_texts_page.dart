import 'dart:async';

import 'package:flutter/material.dart';

import '../../../config/app_config.dart';
import '../../../models/legal_models.dart';
import '../../motion/pressable.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/settings/settings_card.dart' show CardCaption;
import '../../widgets/surface_card.dart';
import 'legal_document_page.dart';

/// "Yasal Metinler" açıklaması (ayarlar kartı ve sayfa aynı metni kullanır).
const String kLegalTextsCaption = 'Kullanıcı sözleşmesini, kişisel verilerinizin nasıl işlendiğini anlatan aydınlatma '
    'metnini ve uygulamada kullanılan açık kaynak yazılımların lisanslarını buradan okuyabilirsiniz.';

/// Flutter'ın açık kaynak lisansları sayfası, uygulamanın görünen adıyla ([AppConfig.appDisplayName]).
void showAppLicenses(BuildContext context) =>
    showLicensePage(context: context, applicationName: AppConfig.appDisplayName);

/// "Yasal Metinler" sayfası: profil diyaloğundan (konsollar dahil oturum açmış herkes) açılır; içerik ayarlardaki
/// kartla aynıdır ([LegalLinksList]). Anahtar: `Key('legal_texts_page')`.
class LegalTextsPage extends StatelessWidget {
  const LegalTextsPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const LegalTextsPage()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('legal_texts_page'),
      appBar: const NeonAppBar(title: 'Yasal Metinler', family: AppFamilies.slate, icon: Icons.gavel_rounded),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: const SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CardCaption(kLegalTextsCaption),
                    SizedBox(height: 8),
                    LegalLinksList(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Yasal metin girişleri: Kullanıcı Sözleşmesi, Gizlilik Politikası ve KVKK Aydınlatma Metni (ikisi de metin sayfasını
/// açar; çevrimdışıyken sayfa hata + "Tekrar Dene" gösterir) ve Açık Kaynak Lisansları ([showAppLicenses]).
///
/// Anahtarlar: `Key('btn_legal_terms')`, `Key('btn_legal_privacy')`, `Key('btn_legal_licenses')`.
class LegalLinksList extends StatelessWidget {
  const LegalLinksList({super.key});

  @override
  Widget build(BuildContext context) {
    final divider = Divider(height: 1, thickness: 1, color: SurfaceTokens.of(Theme.of(context).brightness).rimSolid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LegalLinkRow(
          key: const Key('btn_legal_terms'),
          icon: Icons.description_rounded,
          family: AppFamilies.sky,
          label: LegalDocumentKind.terms.label,
          onTap: () => unawaited(LegalDocumentPage.open(context, LegalDocumentKind.terms)),
        ),
        divider,
        _LegalLinkRow(
          key: const Key('btn_legal_privacy'),
          icon: Icons.privacy_tip_rounded,
          family: AppFamilies.emerald,
          label: LegalDocumentKind.privacy.label,
          onTap: () => unawaited(LegalDocumentPage.open(context, LegalDocumentKind.privacy)),
        ),
        divider,
        _LegalLinkRow(
          key: const Key('btn_legal_licenses'),
          icon: Icons.source_rounded,
          family: AppFamilies.slate,
          label: 'Açık Kaynak Lisansları',
          onTap: () => showAppLicenses(context),
        ),
      ],
    );
  }
}

/// Liste satırı: orb rozeti + etiket (satıra sarılır, kesilmez) + ok; dokunma hedefi ≥ 52 dp, tek `button` anlam düğümü
/// (profil diyaloğunun hesap satırlarıyla aynı dil).
class _LegalLinkRow extends StatelessWidget {
  const _LegalLinkRow({
    super.key,
    required this.icon,
    required this.family,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final AccentFamily family;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressedScale: 0.985,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(2, 8, 0, 8),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 32,
                  child: FittedBox(child: OrbIconBadge(icon: icon, family: family, size: OrbSize.sm, glow: false)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w600, color: AppTheme.getTextPrimary(context)),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 20, color: AppTheme.getTextMuted(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
