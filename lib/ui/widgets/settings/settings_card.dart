import 'package:flutter/material.dart';

import '../../motion/staggered_entrance.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../orb/orb.dart';
import '../surface_card.dart';

/// [accent] rengine en yakın Neon Glass renk ailesi (orb rozetleri için).
AccentFamily familyForAccent(Color accent) {
  AccentFamily best = AppFamilies.sky;
  var bestDistance = double.infinity;
  for (final family in AppFamilies.all) {
    final c = family.base;
    final dr = c.r - accent.r;
    final dg = c.g - accent.g;
    final db = c.b - accent.b;
    final d = dr * dr + dg * dg + db * db;
    if (d < bestDistance) {
      bestDistance = d;
      best = family;
    }
  }
  return best;
}

/// Ayarlar sayfası kartı: cam yüzey ([SurfaceCard]) + [OrbIconBadge] başlık + içerik. Açık/koyu temaya
/// duyarlıdır; sabit koyu renk kullanmaz.
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.accent,
    required this.children,
    this.trailing,
    this.active = false,
    this.pending = false,
    this.enabled = true,
    this.dimmed = false,
  });

  final IconData icon;
  final String title;

  /// Vurgu rengi (orb rozeti; kart kenarı yalnız [active] iken).
  final Color accent;
  final List<Widget> children;

  /// Başlığın sağındaki isteğe bağlı öğe (ör. bilgi düğmesi).
  final Widget? trailing;

  /// Vurgulu (parıltılı) kart.
  final bool active;

  /// Rozet çevresinde dönen "bekliyor" yayı.
  final bool pending;

  /// `false`: özellik kullanılamıyor (ör. cihazda biyometrik donanım yok). Orb soluk "devre dışı" çizilir ve kart
  /// vurgu rengi/parıltı taşımaz: pasif bir özellik "kullanılabilir" gibi görünmez.
  final bool enabled;

  /// SOLUK rozet ([OrbIconBadge.dimmed]): özellik kullanılabilir ama KAPALI; aile korunur, orb solgun ve parıltısızdır
  /// (örn. biyometrik giriş destekleniyor ama anahtar kapalı: tam doygun zümrüt orb "açık" gibi okunuyordu).
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    // Kategori/özellik rengi orb'da ve içerideki düğmede taşınır; KART KENARI yalnız canlı durumda (active) vurgu rengindedir:
    // sekiz kartın sekiz farklı renkli kenarı "her şey yanıyor" izlenimi veriyor ve canlı durumu (kilitli, kural açık ...) kenar
    // renginden ayırt etmeyi imkânsız kılıyordu (çapraz eleştirmen #7). Pasif özellik de vurgu taşımaz.
    return SurfaceCard(
      accent: (enabled && active) ? accent : null,
      active: active && enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsCardHeader(
            icon: icon,
            title: title,
            family: familyForAccent(accent),
            active: active,
            pending: pending,
            enabled: enabled,
            dimmed: dimmed,
            trailing: trailing,
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// Kart başlığı: orb rozet + başlık + isteğe bağlı sağ öğe.
///
/// Orb kutusu rozetin kendisidir (44 dp): sol kenarı kart içeriğiyle (gövde metni, alt satırlar) AYNI hizadadır.
/// "Bekliyor" yayını orb'un kendisi ([OrbIconBadge.pending]) çizer: yay rengi tema duyarlıdır (koyuda `light`,
/// açıkta `deep`; açık zeminde amber/sarı `light` ≈ 1.3:1 ile görünmez olurdu) ve orb kutusunu şişirmez.
/// Boşta orb soluk dış parıltı taşır (`glow`): ayarların asıl kontrolleri düz kalmaz.
class SettingsCardHeader extends StatelessWidget {
  const SettingsCardHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.family,
    this.active = false,
    this.pending = false,
    this.enabled = true,
    this.dimmed = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final AccentFamily family;
  final bool active;
  final bool pending;

  /// `false`: devre dışı orb (gri küre, parıltı yok).
  final bool enabled;

  /// Soluk orb (aile korunur, parıltı yok); bkz. [SettingsCard.dimmed].
  final bool dimmed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OrbIconBadge(
          icon: icon,
          family: family,
          active: active,
          pending: pending,
          enabled: enabled,
          dimmed: dimmed,
          glow: true,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.getTextPrimary(context),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Ayarlar bölümü: ince parıltılı başlık şeridi + altında kartlar. Kartlar tembel DEĞİL (sayfa eager-build).
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.icon,
    required this.family,
    required this.children,
    this.index = 0,
  });

  final String title;
  final IconData icon;
  final AccentFamily family;
  final List<Widget> children;

  /// Kademeli giriş sırası (en çok 8).
  final int index;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final tint = AppTheme.readableAccent(context, family.base);
    return StaggeredEntrance(
      index: index,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
            child: Semantics(
              header: true,
              child: Row(
                children: [
                  ExcludeSemantics(child: Icon(icon, size: 16, color: tint)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      key: Key('settings_section_$title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: tint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [tint.withValues(alpha: 0.45), tint.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// "Etiket: değer" satırı (telemetri / hesap bilgisi).
///
/// Etiket DOĞAL genişliğinde durur (en çok satırın [labelMaxFraction]'ı kadar; sığmayan uzun etiket o genişlikte sarılır),
/// değer kalan alanı doldurur ve sağa yaslanır. Eskiden sütunlar sabit oranlıydı (etiket 2 / değer 3): "Bu dairedeki
/// rolünüz" yanında ~170 dp boş alan varken iki satıra sarılıp değeri ilk satır hizasında yukarıda bırakıyordu.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  /// Etiketin kaplayabileceği en büyük genişlik oranı (kalanı değerindir).
  static const double labelMaxFraction = 0.55;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * labelMaxFraction),
              child: Text(
                label,
                style: TextStyle(fontSize: 12.5, color: AppTheme.getTextMuted(context)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.getTextPrimary(context),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kısa açıklama metni.
class CardCaption extends StatelessWidget {
  const CardCaption(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.35,
        color: color ?? AppTheme.getTextMuted(context),
      ),
    );
  }
}
