import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../motion/staggered_entrance.dart';
import '../../common/arc_spinner.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/settings/accent_button.dart';
import '../../widgets/surface_card.dart';
import 'panel/service_glass.dart';
import 'service_setup_controller.dart';
import 'setup_problem.dart';
import 'setup_style.dart';

/// Küçük, etkileşimsiz cam küre + simge (durum rozetleri, hata/başarı işaretleri). Statik çizilir (animasyon yok);
/// anlamdan hariçtir: anlam yanındaki metindedir.
class SetupMiniOrb extends StatelessWidget {
  const SetupMiniOrb({super.key, required this.family, this.icon, this.text, this.size = 20})
    : assert(icon != null || text != null);

  final AccentFamily family;
  final IconData? icon;

  /// Simge yerine kısa metin (ör. madde numarası).
  final String? text;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _MiniOrbPainter(OrbColors.family(family)),
            child: Center(
              child: icon != null
                  ? Icon(icon, size: size * 0.66, color: OrbColors.iconFor(family))
                  : Padding(
                      padding: EdgeInsets.all(size * 0.14),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          text!,
                          style: TextStyle(
                            fontSize: size * 0.5,
                            height: 1.0,
                            fontWeight: FontWeight.w800,
                            color: OrbColors.iconFor(family),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniOrbPainter extends CustomPainter {
  _MiniOrbPainter(this.colors);

  final OrbColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    paintOrbBody(canvas, size.center(Offset.zero), size.shortestSide / 2, colors);
  }

  @override
  bool shouldRepaint(_MiniOrbPainter old) => old.colors != colors;
}

/// Sonuç orb'u (başarı ✓ / hata): [status] ilk çerçeveden SONRA uygulanır; böylece başarı halkası ya da hata
/// sarsıntısı sonuç göründüğü anda BİR KEZ oynar (orb animasyonu yalnız `none -> success|error` geçişinde
/// başlar). `MotionMode.off`: hareket yok, yalnız renkli kenar. Zamanlayıcı kullanmaz; anlamdan hariçtir.
class SetupResultOrb extends StatefulWidget {
  const SetupResultOrb({
    super.key,
    required this.icon,
    required this.family,
    required this.status,
    this.size = OrbSize.sm,
    this.glow,
  });

  final IconData icon;
  final AccentFamily family;
  final OrbStatus status;
  final OrbSize size;

  /// Dış parıltı: `null` (varsayılan) = temaya göre (koyuda soluk açık, açıkta kapalı; bkz. `OrbIconBadge.glow`).
  final bool? glow;

  @override
  State<SetupResultOrb> createState() => _SetupResultOrbState();
}

class _SetupResultOrbState extends State<SetupResultOrb> {
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return OrbIconBadge(
      icon: widget.icon,
      family: widget.family,
      size: widget.size,
      glow: widget.glow,
      status: _armed ? widget.status : OrbStatus.none,
    );
  }
}

/// Sonuç başlığı: sonuç orb'u (varsayılan ✓, emerald) + kalın metin. Başarı kartlarının ilk satırıdır
/// ("Cihaz tanındı", "Pano ev Wi-Fi ağına bağlandı" ...). Metin renk + simge + yazıyla verilir.
class SetupResultHeader extends StatelessWidget {
  const SetupResultHeader({
    super.key,
    required this.text,
    this.icon = Icons.check_rounded,
    this.color = SetupColors.ok,
    this.status = OrbStatus.success,
  });

  final String text;
  final IconData icon;
  final Color color;
  final OrbStatus status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SetupResultOrb(icon: icon, family: SetupColors.family(color), status: status),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.3,
                fontWeight: FontWeight.w800,
                color: SetupColors.readable(context, color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cihaz kimliği satırı ([SetupResultHeader]'ın altında, başlık metniyle aynı hizada): kimlik TEK satır mono, sığmazsa küçülür.
/// Kimlik cümlenin içinde kalınca 1.5 yazı ölçeğinde tireden bölünüyordu ("Cihaz: AHBU-S3-" / "A1B2C3").
class SetupUidLine extends StatelessWidget {
  const SetupUidLine(this.uid, {super.key});

  final String uid;

  /// Sonuç orb'u (44) + boşluk (12): başlık metninin sol kenarı.
  static const double _indent = 56;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: _indent, top: 2, bottom: 2),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          uid,
          maxLines: 1,
          softWrap: false,
          style: SetupText.mono(fontSize: 14, fontWeight: FontWeight.w700, color: SetupColors.text(context)),
        ),
      ),
    );
  }
}

/// Adım rozeti ("Bekliyor", "Çalışıyor...", "Tamamlandı", "Sorun var", "Atlandı"): cam hap; solda durum işareti
/// (bekliyor: nokta, çalışıyor: dönen yay, tamamlandı/sorun/atlandı: mini orb). Renk geçişi yumuşaktır.
class SetupStatusBadge extends StatelessWidget {
  const SetupStatusBadge({super.key, required this.phase, this.label});

  final StepPhase phase;
  final String? label;

  static String textFor(StepPhase phase) {
    switch (phase) {
      case StepPhase.pending:
        return 'Bekliyor';
      case StepPhase.working:
        return 'Çalışıyor...';
      case StepPhase.done:
        return 'Tamamlandı';
      case StepPhase.failed:
        return 'Sorun var';
      case StepPhase.skipped:
        return 'Atlandı';
    }
  }

  static Color colorFor(StepPhase phase) {
    switch (phase) {
      case StepPhase.pending:
        return SetupColors.info;
      case StepPhase.working:
        return SetupColors.primaryLight;
      case StepPhase.done:
        return SetupColors.ok;
      case StepPhase.failed:
        return SetupColors.error;
      case StepPhase.skipped:
        return SetupColors.warn;
    }
  }

  static IconData iconFor(StepPhase phase) {
    switch (phase) {
      case StepPhase.pending:
        return Icons.hourglass_empty_rounded;
      case StepPhase.working:
        return Icons.sync_rounded;
      case StepPhase.done:
        return Icons.check_rounded;
      case StepPhase.failed:
        return Icons.priority_high_rounded;
      case StepPhase.skipped:
        return Icons.skip_next_rounded;
    }
  }

  /// Göstergenin yuvası 14 dp: hap yüksekliği = etiket (≈ 14.4) + dikey dolgu, yani kart içi durum hapıyla ([SetupVerdictChip]:
  /// 8 dp nokta) AYNI ≈ 24 dp (eskiden 18 dp'lik yuva üst rozeti 28 dp yapıyordu: aynı ekranda iki rozet yüksekliği).
  static const double _markSize = 14;

  Widget _leading(BuildContext context, Color color) {
    switch (phase) {
      case StepPhase.pending:
        return SizedBox.square(
          dimension: _markSize,
          child: Center(child: GlowDot(color: color, size: 8)),
        );
      case StepPhase.working:
        // Dönen yay metin tonunda (açık temada ham #60A5FA ≈ 2.4:1 idi): AA okunur ton.
        return ArcSpinner(size: _markSize, color: SetupColors.readable(context, color), strokeWidth: 2);
      case StepPhase.done:
      case StepPhase.failed:
      case StepPhase.skipped:
        return SetupMiniOrb(family: SetupColors.family(color), icon: iconFor(phase), size: _markSize);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = SetupStatusBadge.colorFor(phase);
    final text = label ?? textFor(phase);
    return Semantics(
      label: 'Adım durumu: $text',
      excludeSemantics: true,
      // Tek hap kabuğu ([ServicePillShell]): kenar/dolgu/boyut tüm durum rozetleriyle aynı; uzun etiket 2 satıra sarar.
      child: ServicePillShell(
        color: color,
        leading: _leading(context, color),
        child: Text(
          text,
          maxLines: 2,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTouch.minFontSize,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: SetupColors.readable(context, color),
          ),
        ),
      ),
    );
  }
}

/// Başarısız adım kutusu: anlamlı simge orb + ne oldu / **Neden?** / **Ne yapmalıyım?** + "Tekrar dene" +
/// (varsa) "N. adıma dön". Cam kart; hata orb'u girişte bir kez sarsılır.
///
/// **Tek gradyan birincil:** "Tekrar dene" varsayılan olarak gradyanlı birincil düğmedir. Adımın KENDİ birincil eylemi de
/// ekrandaysa ("Panoya Bağlan", "Buluta Bağla ve Bekle", "Dinlemeyi Başlat" ...) ve yeniden deneme aynı işi yapıyorsa
/// ([retrySecondary]) yeniden deneme ÇERÇEVELİ ikincil düğme olur: eskiden hata ekranında 2-3 eş ağırlıklı gradyan hap
/// vardı ve asıl kurtarma eyleminin hangisi olduğu belli değildi.
class SetupProblemBox extends StatelessWidget {
  const SetupProblemBox({super.key, required this.problem, this.onRetry, this.onFixStep, this.retrySecondary = false});

  final SetupProblem problem;
  final VoidCallback? onRetry;
  final void Function(int step)? onFixStep;

  /// `true` ⇒ "Tekrar dene" çerçeveli (ikincil) düğmedir; gradyan birincil ekrandaki başka eylemde kalır.
  final bool retrySecondary;

  /// Hata türüne uygun anlamlı simge (renk tek ipucu değil: simge + başlık metni).
  static IconData iconForKind(SetupProblemKind kind) {
    switch (kind) {
      case SetupProblemKind.network:
        return Icons.wifi_off_rounded;
      case SetupProblemKind.deviceNetwork:
        return Icons.router_rounded;
      case SetupProblemKind.expired:
        return Icons.timer_off_rounded;
      case SetupProblemKind.unauthorized:
      case SetupProblemKind.forbidden:
        return Icons.lock_rounded;
      case SetupProblemKind.validation:
        return Icons.rule_rounded;
      case SetupProblemKind.locked:
        return Icons.lock_clock_rounded;
      case SetupProblemKind.rateLimited:
        return Icons.hourglass_top_rounded;
      case SetupProblemKind.notFound:
        return Icons.search_off_rounded;
      case SetupProblemKind.conflict:
        return Icons.sync_problem_rounded;
      case SetupProblemKind.timeout:
        return Icons.schedule_rounded;
      case SetupProblemKind.wrongDevice:
        return Icons.devices_other_rounded;
      case SetupProblemKind.deviceRejected:
        return Icons.block_rounded;
      case SetupProblemKind.rejected:
        return Icons.gpp_bad_rounded;
      case SetupProblemKind.server:
        return Icons.cloud_off_rounded;
      case SetupProblemKind.unknown:
        return Icons.error_rounded;
    }
  }

  /// BEKLEME türü hatalar (oturum süresi, geçici kilit, hız sınırı, zaman aşımı) sert hata değildir: bekleyince/yeniden
  /// denenince geçer. Amber (uyarı) orb + başlık; gerçek hatalar (ağ yok, reddedildi ...) gül.
  static bool isWaitKind(SetupProblemKind kind) =>
      kind == SetupProblemKind.expired ||
      kind == SetupProblemKind.locked ||
      kind == SetupProblemKind.rateLimited ||
      kind == SetupProblemKind.timeout;

  @override
  Widget build(BuildContext context) {
    final warn = isWaitKind(problem.kind);
    final color = warn ? SetupColors.warn : SetupColors.error;
    final family = warn ? AppFamilies.amber : AppFamilies.rose;
    final text = SetupColors.text(context);
    final readable = SetupColors.readable(context, color);
    final fix = problem.fixStep;
    final hasFix = fix != null && onFixStep != null;
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Hata: ${problem.title}',
      child: StaggeredEntrance(
        index: 0,
        child: SurfaceCard(
          accent: color,
          active: true,
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(AppSpace.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SetupResultOrb(
                    icon: iconForKind(problem.kind),
                    family: family,
                    status: warn ? OrbStatus.none : OrbStatus.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      problem.title,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: readable),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _labeled(context, 'Neden?', problem.why, text),
              const SizedBox(height: 8),
              _labeled(context, 'Ne yapmalıyım?', problem.todo, text),
              if (problem.retryAfter != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Beklemeniz gereken süre: yaklaşık ${SetupProblems.waitText(problem.retryAfter)}.',
                  style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
                ),
              ],
              if (onRetry != null || hasFix) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onRetry != null)
                      retrySecondary
                          // İkincil: çerçeveli (ailenin kendi rengi, AA); asıl kurtarma eylemi ekrandaki gradyan düğmedir.
                          ? OutlinedButton.icon(
                              key: const Key('setup_retry'),
                              onPressed: onRetry,
                              icon: Icon(Icons.refresh_rounded, size: accentIconSize(context, base: 18)),
                              label: const Text('Tekrar dene'),
                              style: accentOutlinedButtonStyle(context, family, minimumSize: const Size(48, 48)),
                            )
                          : ElevatedButton.icon(
                              key: const Key('setup_retry'),
                              onPressed: onRetry,
                              icon: Icon(Icons.refresh_rounded, size: accentIconSize(context, base: 18)),
                              label: const Text('Tekrar dene'),
                              style: accentButtonStyle(family, minimumSize: const Size(48, 48)),
                            ),
                    if (hasFix)
                      // Tek çözüm yolu "adıma dön" ise (yeniden deneme anlamsız) en güçlü eylemdir: dolgulu hap. Yeniden deneme
                      // de varsa ikincil: çerçeveli (aile çerçevesi + AA metin; tema varsayılan çerçevesi açıkta ≈ 2.4:1'di).
                      onRetry == null
                          ? ElevatedButton.icon(
                              key: const Key('setup_fix_step'),
                              onPressed: () => onFixStep!(fix),
                              icon: Icon(Icons.undo_rounded, size: accentIconSize(context, base: 18)),
                              label: Text('$fix. adıma dön'),
                              style: accentButtonStyle(AppFamilies.sky, minimumSize: const Size(48, 48)),
                            )
                          : OutlinedButton.icon(
                              key: const Key('setup_fix_step'),
                              onPressed: () => onFixStep!(fix),
                              icon: Icon(Icons.undo_rounded, size: accentIconSize(context, base: 18)),
                              label: Text('$fix. adıma dön'),
                              style: accentOutlinedButtonStyle(context, AppFamilies.sky, minimumSize: const Size(48, 48)),
                            ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _labeled(BuildContext context, String label, String body, Color text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: SetupColors.muted(context)),
        ),
        const SizedBox(height: 2),
        Text(body, style: TextStyle(fontSize: 13.5, height: 1.35, color: text)),
      ],
    );
  }
}

/// Cam kart (tema duyarlı): [SurfaceCard] üzerinde; [accent] verilirse vurgulu kenar.
class SetupCard extends StatelessWidget {
  const SetupCard({
    super.key,
    required this.child,
    this.accent,
    this.padding = const EdgeInsets.all(AppSpace.s16),
    this.margin = const EdgeInsets.only(top: 12),
  });

  final Widget child;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(accent: accent, padding: padding, margin: margin, child: child);
  }
}

/// Simge + metin satırı (taşmaz, ölçeklenen yazıda alta sarar).
///
/// Simge yazı ölçeğiyle büyür (18 -> en çok 26 dp) ve **ilk satırın dikey ortasına** hizalanır: büyük yazıda sabit 18 dp
/// simge, satır yüksekliğinin yarısına düşüp metnin üstünde kalıyordu.
class SetupInfoRow extends StatelessWidget {
  const SetupInfoRow({super.key, required this.icon, required this.text, this.color, this.bold = false});

  final IconData icon;
  final String text;
  final Color? color;
  final bool bold;

  static const double _fontSize = 13.5;
  static const double _lineHeight = 1.35;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final iconSize = scaler.scale(18).clamp(18.0, 26.0).toDouble();
    final firstLine = scaler.scale(_fontSize) * _lineHeight;
    final iconColor = color == null ? SetupColors.muted(context) : SetupColors.readable(context, color!);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: iconSize,
            height: math.max(firstLine, iconSize),
            child: Center(child: Icon(icon, size: iconSize, color: iconColor)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: _fontSize,
                height: _lineHeight,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: color == null ? SetupColors.text(context) : SetupColors.readable(context, color!),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bölüm başlığı.
class SetupSectionTitle extends StatelessWidget {
  const SetupSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 2),
      child: Text(
        text,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
      ),
    );
  }
}

/// Tam genişlik, 52 dp yüksekliğinde birincil eylem düğmesi (başparmak bölgesi). Tür `ElevatedButton`dır; tema
/// gradyanını uygular, [color] (ok/error ...) verilirse aynı hap biçiminde anlamsal aile gradyanı kullanılır.
class SetupPrimaryButton extends StatelessWidget {
  const SetupPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // Sabit yükseklik YOK: düğmenin kendi en küçük yüksekliği (tema: 52) geçerlidir, büyük yazıda/çok satırlı etikette
    // düğme büyür. Etiket KIRPILMAZ (eskiden maxLines: 2 + üç nokta: "Eski Panonun Ayarlarını Yeni Pan…").
    //
    // Simge + etiket **tek grup** olarak ortalanır (`mainAxisSize.min`, `TextWidthBasis.longestLine`): etiket iki satıra
    // sarınca simge sol kenara yapışıp etiketle bağı kopmaz.
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: accentButtonStyle(SetupColors.buttonFamily(color)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              ArcSpinner(
                size: 20,
                color: SetupColors.isDark(context) ? Colors.white : AppFamilies.sky.deep,
                strokeWidth: 2.4,
              )
            else if (icon != null)
              Icon(icon, size: accentIconSize(context, base: 20)),
            if (busy || icon != null) const SizedBox(width: 10),
            // Dengeli satır sonu ([ServiceBalancedLabel]): etiket 2-3 satıra sarınca son satırda tek sözcük (yetim) kalmaz
            // ("Wi-Fi Kurulum & Kurtarma / Sihirbazı"); metin DEĞİŞMEZ, tek satıra sığan etiket normal Text gibidir.
            Flexible(child: ServiceBalancedLabel(label, centered: true)),
          ],
        ),
      ),
    );
  }
}

/// **İkincil** tam genişlik düğme: aynı ekranda gradyanlı birincil eylem ([SetupPrimaryButton]) varken ikinci/üçüncü akışlar
/// ("Wi-Fi Kurulum & Kurtarma Sihirbazı" ...) çerçeveli hap olur; gradyan hap sayfa başına TEK birincil eylemdir. Çerçeve +
/// metin + simge AYNI aileden ve AA okunur ([accentOutlinedButtonStyle]); simge + etiket tek grup olarak ortalanır, etiket
/// KIRPILMAZ (düğme etiket kadar uzar).
class SetupSecondaryButton extends StatelessWidget {
  const SetupSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.family,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Aile (varsayılan sky).
  final AccentFamily? family;

  /// İşlem sürüyor: simge yerine dönen yay çizilir ve düğme pasif olur ([SetupPrimaryButton.busy] ile aynı davranış).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tone = family ?? AppFamilies.sky;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: busy ? null : onPressed,
        style: accentOutlinedButtonStyle(context, tone),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy) ...[
              ArcSpinner(size: 20, color: SetupColors.readable(context, tone.base), strokeWidth: 2.4),
              const SizedBox(width: 10),
            ] else if (icon != null) ...[
              Icon(icon, size: accentIconSize(context, base: 20)),
              const SizedBox(width: 10),
            ],
            Flexible(child: ServiceBalancedLabel(label, centered: true)),
          ],
        ),
      ),
    );
  }
}

/// İçerik sol kenarına hizalı **satır içi metin eylemi** stili ("Müşteriyi değiştir", "Kullanılmıyor", "Güncel durumu
/// yeniden oku" ...): varsayılan metin düğmesinin 12-16 dp iç boşluğu simgeyi/yazıyı içerik kenarından içeri iterdi
/// (başlık x=16 dp'de, düğme simgesi x≈30 dp'de). Dokunma hedefi 48 dp kalır; yalnız yatay iç boşluk daralır ve içerik
/// sola yaslanır.
ButtonStyle setupInlineActionStyle() => TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(48, AppTouch.minTarget),
      alignment: AlignmentDirectional.centerStart,
    );

/// Onay kutusu satırı: varsayılan mavi Material `Checkbox` YERİNE sihirbazın dilindeki **zümrüt ✓ orb** (işaretliyken) ya da
/// boş halka (işaretsizken). Satırın tamamı dokunma hedefidir (≥ 48 dp), etiket 14 sp kalın; anlam: `checked` + etiket.
class SetupCheckTile extends StatelessWidget {
  const SetupCheckTile({super.key, required this.value, required this.onChanged, required this.label});

  final bool value;

  /// `null` ⇒ pasif.
  final ValueChanged<bool>? onChanged;
  final String label;

  static const double _size = 28;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final muted = SetupColors.muted(context);
    final Widget mark = value
        ? const SetupMiniOrb(key: ValueKey<bool>(true), family: AppFamilies.emerald, icon: Icons.check_rounded, size: _size)
        : SizedBox.square(
            key: const ValueKey<bool>(false),
            dimension: _size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.getFieldBorder(context), width: 2),
              ),
            ),
          );
    return Semantics(
      checked: value,
      enabled: enabled,
      label: label,
      onTap: enabled ? () => onChanged!(!value) : null,
      excludeSemantics: true,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: MotionScope.durationOf(context, AppMotion.fast),
                  child: mark,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: AppText.body,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: enabled ? SetupColors.text(context) : muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// İki seçenekli eylem satırı (ör. "Evet, çalıştı" / "Hayır, çalışmadı"): sığıyorsa yan yana **eşit genişlik ve eşit
/// yükseklikte**; sığmıyorsa (dar ekran, büyük yazı) alt alta **tam genişlikte**. İki düğme içerik genişliğinde ve farklı
/// genişlikte dizilip sağ kenarı tırtıklı bırakmaz; düğme etiketi kırpılmaz.
class SetupChoicePair extends StatelessWidget {
  const SetupChoicePair({super.key, required this.primary, required this.secondary, this.minItemWidth = 150});

  final Widget primary;
  final Widget secondary;

  /// Yan yana dizilmek için her düğmenin en az genişliği.
  final double minItemWidth;

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide = !SetupText.isLargeText(context) && constraints.maxWidth >= minItemWidth * 2 + _gap;
        if (sideBySide) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Expanded(child: primary), const SizedBox(width: _gap), Expanded(child: secondary)],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [primary, const SizedBox(height: _gap), secondary],
        );
      },
    );
  }
}

/// Saniyede bir güncellenen kalan süre metni (yalnızca bu küçük widget yeniden çizilir).
class CountdownText extends StatelessWidget {
  const CountdownText({
    super.key,
    required this.tick,
    required this.remaining,
    this.prefix = '',
    this.style,
    this.doneText,
  });

  final ValueListenable<int> tick;

  /// Güncel kalan süreyi hesaplar (her saniye çağrılır).
  final Duration Function() remaining;
  final String prefix;
  final TextStyle? style;
  final String? doneText;

  static String format(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (context, _, _) {
        final left = remaining();
        final text = (left <= Duration.zero && doneText != null) ? doneText! : '$prefix${format(left)}';
        return Text(text, style: style);
      },
    );
  }
}

/// Kart durum hapı (ör. "Doğrulandı", "Sorun var", "Bekliyor"): cam hap + solda durum noktası. Renk tek ipucu
/// değildir: durum metni her zaman yazılır. Renk geçişi yumuşaktır.
class SetupVerdictChip extends StatelessWidget {
  const SetupVerdictChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Adım rozetiyle ([SetupStatusBadge]) AYNI hap kabuğu ([ServicePillShell]): boyut, ağırlık (w700), kenar ortak.
    return ServicePillShell(
      color: color,
      leading: GlowDot(color: color, size: 8),
      child: Text(
        label,
        maxLines: 2,
        softWrap: true,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTouch.minFontSize,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: SetupColors.readable(context, color),
        ),
      ),
    );
  }
}

/// Altında başlık yazan orb eylem düğmesi (röle/panjur testi): orb dokunma hedefi (`key` orb'a verilir), başlık
/// görsel etikettir (anlam orb'un `semanticLabel`ındadır; başlık anlamdan hariçtir).
class SetupOrbAction extends StatelessWidget {
  const SetupOrbAction({
    super.key,
    required this.orbKey,
    required this.icon,
    required this.family,
    required this.label,
    required this.onTap,
    this.active = false,
    this.pending = false,
    this.size = OrbSize.md,
  });

  final Key orbKey;
  final IconData icon;
  final AccentFamily family;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool pending;
  final OrbSize size;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              OrbButton(
                key: orbKey,
                icon: icon,
                family: family,
                semanticLabel: label,
                size: size,
                active: active,
                onTap: onTap,
              ),
              if (pending)
                Positioned.fill(
                  child: ProgressArc(diameter: size.diameter + 8, color: family.light, strokeWidth: 2.5),
                ),
            ],
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: SetupColors.text(context)),
            ),
          ),
        ],
      ),
    );
  }
}
