import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../motion/animated_count.dart';
import '../../../motion/motion_scope.dart';
import '../../../motion/skeleton.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/app_pill.dart';
import '../../../widgets/neon_app_bar.dart';
import '../../../widgets/orb/orb_core.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import '../../../widgets/surface_card.dart';
import '../setup_style.dart';

/// Servis sayfalarının ortak "Neon Glass" yapı taşları (WP-V7).
///
/// [ServiceCard] eski `SetupCard`'ın yerini alır (aynı imza: `accent`, `padding`, `margin`, `child`) ve cam
/// yüzey çizer; sihirbaz adımları `SetupCard`'ı kullanmaya devam eder (bu dosya yalnız servis sayfalarınındır).

/// Rengi bir [AccentFamily]'ye eşler (servis renkleri sabit `SetupColors` olarak gelir).
AccentFamily serviceFamilyOf(Color color) {
  if (color == SetupColors.ok) return AppFamilies.emerald;
  if (color == SetupColors.warn) return AppFamilies.amber;
  if (color == SetupColors.error) return AppFamilies.rose;
  if (color == SetupColors.purple) return AppFamilies.violet;
  if (color == SetupColors.primary || color == SetupColors.primaryLight) return AppFamilies.sky;
  if (color == SetupColors.info) return AppFamilies.cyan;
  return AppFamilies.slate;
}

/// Cam kart: `SurfaceCard` üstünde `SetupCard` imzası. [accent] verilirse kenar o renkte ışır.
class ServiceCard extends StatelessWidget {
  const ServiceCard({
    super.key,
    required this.child,
    this.accent,
    this.active = false,
    this.padding = const EdgeInsets.all(AppSpace.s16),
    this.margin = const EdgeInsets.only(top: 12),
    this.onTap,
    this.radius = AppRadius.card,
  });

  final double radius;
  final Widget child;
  final Color? accent;
  final bool active;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      accent: accent,
      active: active && accent != null,
      padding: padding,
      margin: margin,
      onTap: onTap,
      radius: radius,
      child: child,
    );
  }
}

/// Başlık rozeti + metin (kart başında): orb simge + başlık/alt başlık.
class ServiceCardHeader extends StatelessWidget {
  const ServiceCardHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.family = AppFamilies.sky,
    this.status = OrbStatus.none,
    this.pending = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final AccentFamily family;
  final OrbStatus status;
  final bool pending;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        OrbIconBadge(icon: icon, family: family, status: status, pending: pending),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 12.5, height: 1.3, color: SetupColors.muted(context)),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// Servis/sihirbaz **tek hap** kabuğu: [AppPillShell]'in İNCE sarmalayıcısıdır (WP-V9; adı ve imzası korunur): stadium,
/// vurgu tonu (`.14`) + okunur tonun kenarı (`.40`). Durum rozeti ([ServiceStatusPill]), sihirbaz adım rozeti ve karar hapı AYNI
/// kabuğu kullanır. Renk geçişi yumuşaktır; `MotionMode.off`'ta anında.
class ServicePillShell extends StatelessWidget {
  const ServicePillShell({super.key, required this.color, required this.child, this.leading, this.animate = true});

  final Color color;
  final Widget child;

  /// Metnin önünde durum işareti (nokta, simge, mini orb ...).
  final Widget? leading;
  final bool animate;

  @override
  Widget build(BuildContext context) => AppPillShell(color: color, leading: leading, animate: animate, child: child);
}

/// Durum rozeti: parlayan nokta (ya da simge) + metin (renk + nokta + METİN; renk tek ipucu değildir). [AppPill]'in ince
/// sarmalayıcısıdır (WP-V9).
///
/// Metin en az 12 sp / w700'dür, **başlık harfiyle** yazılır (büyük harf çağıranın tercihidir) ve dar yerde ya da büyük
/// yazıda en çok [maxLines] satıra SARAR (kırpılmaz). Renk metinde [SetupColors.readable] ile AA'dır.
class ServiceStatusPill extends StatelessWidget {
  const ServiceStatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.labelKey,
    this.maxLines = 2,
  });

  final String label;
  final Color color;
  final IconData? icon;

  /// Metne verilen anahtar (testler `Text` okur).
  final Key? labelKey;
  final int maxLines;

  @override
  Widget build(BuildContext context) => AppPill.tinted(
        color: color,
        label: label,
        icon: icon,
        dot: icon == null,
        textKey: labelKey,
        maxLines: maxLines,
        animate: true,
      );
}

/// Sayaç kutucuğu (envanter / aboneler / hesap özeti): cam r16 kutu, simge + büyük tabular sayı (24 sp / 800, sığmazsa
/// küçülür) + en az 12 sp etiket (en çok 2 satır).
///
/// Durumlar (uydurma sıfır YOK): [loading] -> iskelet blok; [value] ve [text] ikisi de yoksa "—"; [value] varsa
/// [AnimatedCount]; [text] yalnız sayı olmayan değer içindir.
class ServiceStatTile extends StatelessWidget {
  const ServiceStatTile({
    super.key,
    required this.label,
    required this.color,
    this.value,
    this.text,
    this.format,
    this.icon,
    this.loading = false,
    this.valueKey,
  });

  final String label;
  final Color color;
  final int? value;
  final String? text;
  final String Function(int value)? format;
  final IconData? icon;
  final bool loading;

  /// Sayıyı çizen [AnimatedCount]'a verilen anahtar (testler tek `Text` okur).
  final Key? valueKey;

  static const double valueSize = 24;

  @override
  Widget build(BuildContext context) {
    final ink = SetupColors.readable(context, color);
    final style = TextStyle(fontSize: valueSize, fontWeight: FontWeight.w800, height: 1.1, color: ink);
    final Widget number;
    if (loading) {
      // Yazı ölçeğine uyan yer tutucu: veri gelince gerçek sayı (aynı boyut/satır yüksekliği) yerine geçer, düzen zıplamaz.
      number = const SkeletonText(width: 44, fontSize: valueSize, lineHeight: 1.1, alignment: Alignment.center);
    } else if (value != null) {
      number = AnimatedCount(key: valueKey, value: value!, format: format, style: style);
    } else {
      number = Text(text ?? '—', key: valueKey, style: style);
    }
    final shownValue = loading ? 'yükleniyor' : (value == null ? (text ?? '—') : (format ?? (int v) => '$v')(value!));
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '$label: $shownValue',
      child: SurfaceCard(
        accent: color,
        radius: AppRadius.r16,
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // Üstten hizalı: etiketi 1 ve 2 satırlık kutucuklar aynı şeritte eşit yüksekliğe gerilince içerik ORTALANIRSA rakamlar
          // farklı yükseklikte dururdu (rakam üst kenarı 7 dp kayık); üstten hizayla tüm rakamlar ortak çizgide durur.
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: ink),
                  const SizedBox(width: 6),
                ],
                Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: number)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppTouch.minFontSize, height: 1.2, color: SetupColors.muted(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// [ServiceStatTile] şeridi: kutucuklar, en uzun etiket sözcüğü harf ortasından kırılmayacak kadar geniş olabildiği sürece
/// yan yana durur; yazı büyüdükçe/ekran daraldıkça sütun sayısı **n'in bölenlerinden** biri olarak düşer (4 -> 2 -> 1; 3 -> 1:
/// "2 + 1" dengesiz dizilim yok). Satır içindeki kutucuklar eşit yükseklikte olur.
class ServiceStatStrip extends StatelessWidget {
  const ServiceStatStrip({super.key, required this.tiles, this.spacing = AppSpace.s8});

  final List<Widget> tiles;
  final double spacing;

  /// Kutucuk başına gereken en az genişlik: yatay dolgu (16) + en uzun sözcük ("Bekleyen" ≈ 56 dp x ölçek).
  static double neededTileWidth(double scale) => 16 + 56 * math.max(1.0, scale);

  @override
  Widget build(BuildContext context) {
    final n = tiles.length;
    if (n == 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = SetupText.scaleOf(context);
        var cols = 1;
        for (var c = n; c >= 1; c--) {
          if (n % c != 0) continue;
          final perTile = (constraints.maxWidth - spacing * (c - 1)) / c;
          if (c == 1 || perTile >= neededTileWidth(scale)) {
            cols = c;
            break;
          }
        }
        final rows = <Widget>[];
        for (var start = 0; start < n; start += cols) {
          final chunk = tiles.sublist(start, math.min(start + cols, n));
          if (rows.isNotEmpty) rows.add(SizedBox(height: spacing));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < chunk.length; i++) ...[
                    if (i > 0) SizedBox(width: spacing),
                    Expanded(child: chunk[i]),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }
}

/// Etiketi / başlığı DENGELİ satırlara böler: metin 2-3 satıra sarıyorsa, aynı satır sayısını koruyan EN DAR genişlik seçilir;
/// böylece "Yeni Wi-Fi Şifresini Panoya / Yükle" gibi son satırda tek sözcük (yetim) kalmaz. Metin DEĞİŞMEZ (aynı [Text]:
/// `find.text` ve ekran okuyucu etkilenmez); tek satıra sığan ya da 3 satırdan çok sarılan metin normal [Text] gibidir
/// (sınırsız satır: etiket ASLA kırpılmaz).
///
/// [centered] ⇒ düğme etiketi (`Flexible` içinde, `Row(mainAxisSize: min)` ile simgeyle birlikte ortalanır; blok içeriği kadar
/// daralır). Değilse ([Expanded] içindeki başlık) dar blok tam genişlikli yuvanın soluna yaslanır. Ölçüm `TextPainter` ile
/// yapılır ve `LayoutBuilder` içerir: `IntrinsicWidth/Height` ve `AlertDialog` (IntrinsicWidth) altında KULLANILMAZ (yalnız
/// kısa düğme etiketi/başlık için; servis sayfaları ve `Dialog` içinde güvenlidir).
class ServiceBalancedLabel extends StatelessWidget {
  const ServiceBalancedLabel(this.text, {super.key, this.style, this.textKey, this.centered = false});

  final String text;
  final TextStyle? style;

  /// İçteki [Text]'e verilen anahtar (testler `Text` okur).
  final Key? textKey;
  final bool centered;

  /// Dengeleme en çok bu kadar satıra sarılan metinler için yapılır (daha uzunsa normal sarma).
  static const int maxBalancedLines = 3;

  /// Aynı satır sayısını koruyan en dar genişlik (sığıyorsa / tek satırsa / [maxLines]'tan çok satırsa [maxWidth]).
  static double balancedWidth({
    required String text,
    required TextStyle style,
    required TextDirection direction,
    required TextScaler scaler,
    required double maxWidth,
    int maxLines = maxBalancedLines,
  }) {
    if (!maxWidth.isFinite || maxWidth <= 0 || !text.contains(' ')) return maxWidth;
    final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: direction, textScaler: scaler);
    try {
      painter.layout(maxWidth: maxWidth);
      final lines = painter.computeLineMetrics().length;
      if (lines <= 1 || lines > maxLines) return maxWidth;
      var lo = 0.0;
      var hi = maxWidth;
      for (var i = 0; i < 10; i++) {
        final mid = (lo + hi) / 2;
        painter.layout(maxWidth: mid);
        if (painter.computeLineMetrics().length <= lines) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      // Yuvarlama + yazı tipi payı (yazı tipi ilk karede yedek aileyle ölçülmüş olabilir): %3 + 1 dp pay satır sayısını korur.
      return math.min(maxWidth, hi * 1.03 + 1);
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = balancedWidth(
          text: text,
          style: effective,
          direction: direction,
          scaler: scaler,
          maxWidth: constraints.maxWidth,
        );
        final label = Text(
          text,
          key: textKey,
          style: style,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          textWidthBasis: centered ? TextWidthBasis.longestLine : TextWidthBasis.parent,
        );
        if (width >= constraints.maxWidth) return label;
        final block = ConstrainedBox(constraints: BoxConstraints(maxWidth: width), child: label);
        return centered ? block : Align(alignment: AlignmentDirectional.centerStart, heightFactor: 1, child: block);
      },
    );
  }
}

/// Çok satırlı etiketli ÇERÇEVELİ düğmeler için şekil: köşe yarıçapı [AppRadius.sheet] (28 dp) ile sınırlıdır. Tam stadium
/// (yükseklik / 2) 3 satırlık bir düğmede (96-122 dp) "yumurta"ya dönüyordu; 28 dp yarıçap tek satırlı (48-56 dp) düğmede yine tam
/// hap görünür (yarı yükseklik 24-28 dp), uzun etiketli düğmede ise yumuşak köşeli dikdörtgen kalır.
/// `accentOutlinedButtonStyle(...).copyWith(shape: serviceTallButtonShapeProperty)` ile verilir.
const WidgetStateProperty<OutlinedBorder?> serviceTallButtonShapeProperty = WidgetStatePropertyAll<OutlinedBorder?>(
  RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.sheet))),
);

/// Kart içi **eylem düğmesi ızgarası**: düğmeler içerik genişliğinde ve farklı genişlikte alt alta/yan yana dizilip sağ kenarı
/// tırtıklı bırakmaz. Sütun başına [minItemWidth]'e sığıyorsa EŞİT genişlikte iki sütun ([columns]); büyük yazıda ya da
/// sığmıyorsa tek sütun tam genişlik. Satır içindeki düğmeler eşit yükseklikte olur; son satırda tek düğme kalırsa tam
/// genişliğe yayılır (yarım genişlikte sola yaslı tek hap + boş yarı kötü duruyordu).
///
/// **Eşik neden 156 dp:** 360 dp telefonda ızgara ≈ 296 dp'dir; iki sütunda sütun ≈ 144 dp, etiket payı ≈ 90 dp kalır ve
/// 'Daveti yeniden gönder' / 'Bağlantıyı yeniden kur' gibi etiketler 3 satıra sarıp (IntrinsicHeight komşu düğmeyi de
/// şişirerek) hapı "yumurtaya" çeviriyordu. Telefonda artık tek sütun (etiket tek satır), ≥ 2 x 156 + 8 dp genişlikte
/// (geniş telefon, tablet) iki sütun: etiket en çok 2 satıra sarar ve hap biçimi korunur.
class ServiceActionGrid extends StatelessWidget {
  const ServiceActionGrid({
    super.key,
    required this.children,
    this.columns = 2,
    this.spacing = AppSpace.s8,
    this.minItemWidth = 156,
  });

  final List<Widget> children;
  final int columns;
  final double spacing;

  /// Bir sütunun en az genişliği (bundan darsa sütun sayısı düşer).
  final double minItemWidth;

  /// Izgara içindeki düğmelerin yatay iç boşluğu: tema varsayılanı (22-24 dp) yarım genişlikte etiketi 2-3 satıra bölerdi
  /// ("Bağlantıyı / yeniden / kur"); 14 dp ile etiket tek/iki satıra sığar. Yükseklik/şekil/renk temadan gelir.
  static const EdgeInsetsGeometry _buttonPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 12);

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final compact = ButtonStyle(padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(_buttonPadding));
    return Theme(
      data: theme.copyWith(
        elevatedButtonTheme: ElevatedButtonThemeData(style: theme.elevatedButtonTheme.style?.merge(compact) ?? compact),
        outlinedButtonTheme: OutlinedButtonThemeData(style: theme.outlinedButtonTheme.style?.merge(compact) ?? compact),
        filledButtonTheme: FilledButtonThemeData(style: theme.filledButtonTheme.style?.merge(compact) ?? compact),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fit = ((constraints.maxWidth + spacing) / (minItemWidth + spacing)).floor();
          // Tek düğme tam genişlik (yarım genişlikte sola yaslı tek hap garip duruyordu ve etiketi bölüyordu).
          final cols = (SetupText.isLargeText(context) || children.length == 1) ? 1 : math.max(1, math.min(columns, fit));
          final rows = <Widget>[];
          for (var start = 0; start < children.length; start += cols) {
            final chunk = children.sublist(start, math.min(start + cols, children.length));
            if (rows.isNotEmpty) rows.add(SizedBox(height: spacing));
            rows.add(
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Son satırda az düğme kalırsa onlar satırı doldurur (boş yarı bırakılmaz).
                    for (var i = 0; i < chunk.length; i++) ...[
                      if (i > 0) SizedBox(width: spacing),
                      Expanded(child: chunk[i]),
                    ],
                  ],
                ),
              ),
            );
          }
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
        },
      ),
    );
  }
}

/// Ortak boş durum: orb (lg) + başlık + açıklama (+ eylem). Düz metin kartı YERİNE servis paneli bölümleri, envanter,
/// aboneler ve hesap listesi aynı kalıbı kullanır (pano boş durumlarıyla aynı dil).
class ServiceEmptyState extends StatelessWidget {
  const ServiceEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.family = AppFamilies.slate,
    this.size = OrbSize.lg,
    this.action,
    this.glow,
  });

  final IconData icon;
  final String title;
  final String? message;
  final AccentFamily family;
  final OrbSize size;
  final Widget? action;

  /// Orb parıltısı: `null` = temaya göre (bkz. `OrbIconBadge.glow`).
  final bool? glow;

  @override
  Widget build(BuildContext context) {
    // Tam genişlik: kart `Column(crossAxisAlignment: start)` içindeyken içeriğe büzülüp komşu kartlardan ≈ 46 dp dar kalıyor ve
    // sayfa bloğunun sağ kenarını tırtıklı bırakıyordu. İçerik yine ortalanır (öğeler gerilmez).
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OrbIconBadge(icon: icon, family: family, size: size, glow: glow),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          if (message != null) ...[
            const SizedBox(height: 4),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 14), action!],
        ],
      ),
    );
  }
}

/// Renkli bilgi kutusu (sahip/uyarı/not): yarıçap [AppRadius.r12], dolgu `renk@0.10-0.16`, kenar metin tonunun `@0.35`'i.
/// Eskiden her ekran kendi kutusunu çiziyordu (r8/r10, alfa 0.08: koyu temada amber "çamurlu" gri-kahveye düşüyordu);
/// dolgu koyuda 0.16'dır, böylece sıcak tonlar da belirgin kalır. Tam genişliktir.
class ServiceTintBox extends StatelessWidget {
  const ServiceTintBox({
    super.key,
    required this.color,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpace.s12, vertical: AppSpace.s12),
  });

  final Color color;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = SetupColors.isDark(context);
    final ink = SetupColors.readable(context, color);
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(AppRadius.r12),
          border: Border.all(color: ink.withValues(alpha: 0.35)),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// `NeonAppBar` "Yenile" eylemi ([NeonBarAction]: cam disk, 48 dp hedef, işaretçi ipucu 'Yenile'). `onPressed == null` ⇒
/// pasif: disk ve simge soluk çizilir (çıplak `IconButton` yükleme sırasında bile tam parlak kalıyordu). Kenar boşluğunu
/// çubuk verir (burada dolgu yok).
class ServiceRefreshAction extends StatelessWidget {
  const ServiceRefreshAction({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) =>
      NeonBarAction(icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: onPressed);
}

/// "Liste güncellenemedi (eski veriler gösteriliyor)" uyarısı: amber kart + uyarı orb'u + ileti, altta sağa hizalı "Tekrar
/// dene". Yenileme/ek sayfa hatasında bayat liste SESSİZ kalmaz; ileti dar yerde tam genişlikte sarılır. [retryKey] testlerin
/// okuduğu `btn_retry` anahtarıdır.
class ServiceStaleBanner extends StatelessWidget {
  const ServiceStaleBanner({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryKey = const Key('btn_retry'),
  });

  final String message;
  final VoidCallback onRetry;
  final Key retryKey;

  @override
  Widget build(BuildContext context) {
    return ServiceCard(
      accent: AppTheme.accentAmber,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(AppSpace.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OrbIconBadge(icon: Icons.warning_amber_rounded, family: AppFamilies.amber),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(fontSize: AppText.caption, height: 1.3, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              key: retryKey,
              style: TextButton.styleFrom(minimumSize: const Size(48, AppTouch.minTarget)),
              onPressed: onRetry,
              child: const Text('Tekrar dene'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Adım göstergesi: [total] nokta, [current] (1 tabanlı) kadarı dolu; geçiş yumuşak.
///
/// Kontrast: bekleyen noktalar [AppTheme.getInactiveTrack] ile (kart üstünde ≥ 3:1; eskiden `muted@0.28` ≈ 1.5-1.7:1'di),
/// dolu noktalar [AppTheme.accentTone] ile (koyuda `light`, açıkta `deep`: amber/cyan gibi açık aileler beyaz kartta kaybolmaz).
/// Adım yalnız noktalarla anlatılmaz: yanında görünür "1/3" metni vardır ([showCount]; renk/boyut tek ipucu değildir).
class ServiceStepDots extends StatelessWidget {
  const ServiceStepDots({
    super.key,
    required this.current,
    required this.total,
    this.family = AppFamilies.sky,
    this.label,
    this.showCount = true,
  });

  final int current;
  final int total;
  final AccentFamily family;

  /// Anlamsal etiket ("Adım 2 / 3").
  final String? label;

  /// Noktaların yanında görünür "n/m" metni (ekran okuyucuya ayrıca okunmaz: anlam [label]'dadır).
  final bool showCount;

  @override
  Widget build(BuildContext context) {
    final d = MotionScope.durationOf(context, AppMotion.base);
    final off = AppTheme.getInactiveTrack(context);
    final on = AppTheme.accentTone(context, family);
    return Semantics(
      label: label ?? 'Adım $current / $total',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= total; i++) ...[
            if (i > 1) const SizedBox(width: 6),
            AnimatedContainer(
              duration: d,
              curve: AppMotion.standard,
              width: i == current ? 26 : 10,
              height: 8,
              decoration: BoxDecoration(
                color: i <= current ? on : off,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ],
          if (showCount) ...[
            const SizedBox(width: 10),
            Text(
              '$current/$total',
              key: const Key('step_dots_count'),
              style: TextStyle(
                fontSize: AppTouch.minFontSize,
                height: 1.2,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: SetupColors.muted(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Liste yüklenirken iskelet kartlar (spinner yerine). Yükleme metni kapsayıcıda verilir.
class ServiceListSkeleton extends StatelessWidget {
  const ServiceListSkeleton({super.key, this.count = 3, this.lines = 2});

  final int count;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Column(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SkeletonCard(lines: lines),
            ),
        ],
      ),
    );
  }
}

/// İlerleme halkası (0..1) + ortada isteğe bağlı çocuk: devam eden kurulum, 45 sn gizli değer süresi.
///
/// İz (boş kısım) [AppTheme.getInactiveTrack]'tır: kart üstünde ≥ 3:1 (eskiden `muted@0.22` ≈ 1.2-1.5:1: halka değil "hayalet yay"
/// gibi okunuyordu). Dolu yayın rengini ([color]) çağıran verir; açık aileler için [AppTheme.accentTone] kullanın.
class ServiceProgressRing extends StatelessWidget {
  const ServiceProgressRing({
    super.key,
    required this.value,
    required this.color,
    this.size = 44,
    this.strokeWidth = 4,
    this.child,
  });

  final double value;
  final Color color;
  final double size;
  final double strokeWidth;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final track = AppTheme.getInactiveTrack(context);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(value.clamp(0.0, 1.0), color, track, strokeWidth),
          child: child == null ? null : Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track, this.stroke);

  final double value;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * value, false, paint..color = color);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track || old.stroke != stroke;
}

/// Kopyalanan gizli değerin panodan silinmesine kalan süreyi gösteren halka (varsayılan 45 sn).
///
/// `full` kipte [duration] boyunca boşalır (Ticker tabanlı; Timer yok); `off` kipte dolu statik halka çizer.
/// Yeniden başlatmak için `ValueKey(kopyalamaSayısı)` verin.
class SecretExpiryRing extends StatefulWidget {
  const SecretExpiryRing({super.key, this.duration = const Duration(seconds: 45), this.size = 36});

  final Duration duration;
  final double size;

  @override
  State<SecretExpiryRing> createState() => _SecretExpiryRingState();
}

class _SecretExpiryRingState extends State<SecretExpiryRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (MotionScope.enabledOf(context)) _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Yay çekirdeği tema duyarlı ton (koyuda açık, açıkta derin): ham amber.base beyaz kartta ≈ 1.8:1'di.
    final color = AppTheme.accentTone(context, AppFamilies.amber);
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => ServiceProgressRing(
          value: _started && MotionScope.enabledOf(context) ? 1 - _c.value : 1,
          color: color,
          size: widget.size,
          strokeWidth: 3.5,
          child: Icon(Icons.timer_outlined, size: widget.size * 0.42, color: SetupColors.readable(context, AppFamilies.amber.base)),
        ),
      ),
    );
  }
}
