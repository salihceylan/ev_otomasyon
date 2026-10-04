import 'package:flutter/material.dart';

import '../../motion/pressable.dart';
import '../../theme/tokens.dart';
import 'orb_core.dart';

/// Yuvarlak, parlatılmış, dışbükey "orb" eylem düğmesi (panjur Aç/Durdur/Kapat, senaryo, "Tetikle" …).
///
/// Sözleşme:
/// * **Dokunma alanı ≥ 48 dp** (düzende `size.footprint`: `sm` 44 dp çizilir, 48 dp yer kaplar).
/// * **`onTap` ASLA gecikmez**: parmak kalkınca eşzamanlı çağrılır; **pressed ölçeği (0.92) parmak değdiği
///   AN uygulanır**; bırakınca yaylanma (yalnız `MotionMode.full`). Hiçbir animasyon girdiyi bloklamaz;
///   çift dokunuş koruması `CommandPipeline`'dadır (orb `pending` iken de dokunuşu kabul eder).
/// * `onTap == null` ⇒ **devre dışı** (gri küre, parıltı yok, dokunuş yok, `Semantics.enabled = false`).
/// * Anlamsal: `button`, `enabled`, [semanticLabel]. Orb yalnız görsel katmandır (alt ağaç anlamdan hariç).
/// * Haptik: [haptic] (`light` varsayılan; durdur/yıkıcı için `medium`).
///
/// ```dart
/// OrbButton(
///   key: Key('btn_shutter_up_$pair'),
///   icon: Icons.keyboard_arrow_up_rounded,
///   family: AppFamilies.emerald,
///   semanticLabel: 'Aç',
///   active: isOpening,
///   pending: pendingUp,
///   onTap: () => state.shutterUp(pair),
/// )
/// ```
class OrbButton extends StatelessWidget {
  const OrbButton({
    super.key,
    this.icon,
    this.iconBuilder,
    required this.family,
    required this.semanticLabel,
    this.onTap,
    this.size = OrbSize.lg,
    this.active = false,
    this.pending = false,
    this.status = OrbStatus.none,
    this.haptic = PressHaptic.light,
    this.breathPhase = 0.0,
    this.glow = true,
    this.dimmed = false,
  }) : assert(icon != null || iconBuilder != null, 'icon veya iconBuilder verilmeli');

  final IconData? icon;
  final Widget Function(BuildContext context, Color color, double size)? iconBuilder;
  final AccentFamily family;

  /// Ekran okuyucu etiketi (zorunlu). Görünür metin orb'un altında ayrıca yazılıyorsa aynı metni verin.
  final String semanticLabel;

  /// `null` ⇒ devre dışı.
  final VoidCallback? onTap;
  final OrbSize size;

  /// Hareketli/etkin: parıltı güçlenir ve nefes alır (slot bütçesi dahilinde, yalnız `MotionMode.full`).
  final bool active;

  /// Komut bekliyor: orb çevresinde dönen yay.
  final bool pending;

  /// Tek seferlik sonuç (başarı halkası / hata sarsıntısı). Sahibi gösterdikten sonra `none`'a çevirir.
  final OrbStatus status;
  final PressHaptic haptic;
  final double breathPhase;
  final bool glow;

  /// Etkin ama SOLUK orb (çevrimdışı/son bilinen durum): aile renginin soluk tonu, parıltı/nefes yok; `onTap` aynen çalışır.
  /// Bkz. [OrbCore.dimmed]. Varsayılan `false`.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        enabled: enabled,
        pressedScale: 0.92,
        releaseOvershoot: 1.04,
        haptic: haptic,
        builder: (context, pressed) => SizedBox.square(
          dimension: size.footprint,
          child: Center(
            child: OrbCore(
              size: size,
              family: family,
              icon: icon,
              iconBuilder: iconBuilder,
              active: active,
              pending: pending,
              status: status,
              enabled: enabled,
              pressed: pressed,
              breathPhase: breathPhase,
              glow: glow,
              dimmed: dimmed,
            ),
          ),
        ),
      ),
    );
  }
}
