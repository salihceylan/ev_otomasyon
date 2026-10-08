import 'package:flutter/material.dart';

import '../../pages/legal/legal_texts_page.dart';
import '../../theme/tokens.dart';
import 'settings_card.dart';

/// "Yasal Metinler" kartı: Kullanıcı Sözleşmesi, Gizlilik Politikası ve KVKK Aydınlatma Metni, Açık Kaynak Lisansları.
/// HER ROLDE gösterilir (girişsiz yerel kip dahil): yasal metinler oturum ya da yetki gerektirmez.
/// Anahtar: `Key('card_legal')` (girişler: [LegalLinksList]).
class LegalTextsCard extends StatelessWidget {
  const LegalTextsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('card_legal'),
      child: SettingsCard(
        icon: Icons.gavel_rounded,
        title: 'Yasal Metinler',
        accent: AppFamilies.slate.base,
        children: const [
          CardCaption(kLegalTextsCaption),
          SizedBox(height: 6),
          LegalLinksList(),
        ],
      ),
    );
  }
}
