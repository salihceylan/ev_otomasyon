import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'orb_core.dart';

/// Etkileşimsiz küçük orb: kart başlıkları, senaryo kutucukları, liste önü simgeleri.
///
/// Dokunuşu yakalamaz ve odak almaz; anlamsal ağaçta yok sayılır ([semanticLabel] verilmedikçe: simge tek
/// başına bir anlam taşıyorsa etiket verin). `active`/`pending`/`status` orb ile aynıdır.
///
/// ```dart
/// OrbIconBadge(icon: Icons.nightlight_round, family: AppFamilies.violet, size: OrbSize.sm, pending: running)
/// ```
class OrbIconBadge extends StatelessWidget {
  const OrbIconBadge({
    super.key,
    this.icon,
    this.iconBuilder,
    required this.family,
    this.size = OrbSize.sm,
    this.active = false,
    this.pending = false,
    this.status = OrbStatus.none,
    this.enabled = true,
    this.glow,
    this.dimmed = false,
    this.semanticLabel,
  }) : assert(icon != null || iconBuilder != null, 'icon veya iconBuilder verilmeli');

  /// Simge. [iconBuilder] verilirse yok sayılır; ikisinden biri zorunludur.
  final IconData? icon;

  /// Özel simge: `(context, renk, boyut)` (marka işareti, harf, dolu üçgen — bkz. `OrbIcons`). Renk orb gövdesine göre seçilmiş
  /// simge rengidir (≥ 3:1). Verilmezse [icon] kullanılır (varsayılan davranış aynı).
  final Widget Function(BuildContext context, Color color, double size)? iconBuilder;
  final AccentFamily family;
  final OrbSize size;
  final bool active;
  final bool pending;
  final OrbStatus status;
  final bool enabled;

  /// Soluk dış parıltı. `null` (varsayılan) = **temaya göre**: koyu temada AÇIK (idle seviyesi, `AppGlass.orbGlowIdle`;
  /// eskiden koyu temada hiç halo yoktu ve açık temada renkli statik gölge vardı: iki tema farklı derinlikteydi),
  /// açık temada kapalı (orb zaten renkli statik gölge taşır). `true`/`false` verilirse aynen uygulanır; yoğun listelerde
  /// sade görünüm için `glow: false`. `active` rozet her durumda parlar.
  final bool? glow;

  /// SOLUK rozet: aile renginin soluk tonu, parıltı yok (bkz. [OrbCore.dimmed]). `enabled: false` gri devre dışı görünümdür;
  /// `dimmed` aileyi korur ama solgun gösterir (ör. desteklenmeyen özellik, çevrimdışı kart). Varsayılan `false`.
  final bool dimmed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final withGlow = glow ?? AppTheme.isDark(context);
    final orb = SizedBox.square(
      dimension: size.diameter,
      child: OrbCore(
        size: size,
        family: family,
        icon: icon,
        iconBuilder: iconBuilder,
        active: active,
        pending: pending,
        status: status,
        enabled: enabled,
        dimmed: dimmed,
        glow: withGlow || active,
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: orb);
    return Semantics(label: semanticLabel, image: true, excludeSemantics: true, child: orb);
  }
}
