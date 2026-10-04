import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../motion/motion_scope.dart';
import '../motion/pressable.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'orb/glow_dot.dart';

/// Rozet / çip sabitleri (WP-V9; TEK kaynak). Uygulamadaki tüm rozet ve çipler bu değerlerle çizilir.
abstract final class AppPillTokens {
  /// Hap dolgusu: vurgu renginin kart yüzeyi üstündeki alfası ("tint .14").
  static const double tint = 0.14;

  /// Hap kenarı: okunur vurgu tonunun alfası ("rim .40").
  static const double rim = 0.40;

  /// SEÇİLİ çip: dolgu/kenar alfası ve kenar kalınlığı. Dolgu, [AppTheme.readableAccent]'ın varsaydığı %20'yi AŞMAZ: seçili
  /// çipin metni (okunur ton) her ailede ve iki temada kendi zemininde AA (4.5:1) kalır.
  static const double selectedTint = 0.20;
  static const double selectedRim = 0.70;
  static const double selectedRimWidth = 1.4;

  /// Yatay dolgu: solda gösterge (nokta/simge) varsa [padStart], yoksa [padEnd]; sağda [padEnd]. Gösterge ile metin arası [gap].
  static const double padStart = 8;
  static const double padEnd = 12;
  static const double gap = 6;

  /// Dikey dolgu (normal / sıkışık: üst çubuğun 64 dp'sine sığar).
  static const double vertical = 4;
  static const double compactVertical = 2;

  /// Kenar kalınlığı (hap).
  static const double border = 1;
}

/// Rozet/çip yüzeyi: stadium, kart gradyanı üstüne vurgu tonu ([AppPillTokens.tint]) + okunur tonun kenarı
/// ([AppPillTokens.rim]). [AppPill], [AppChip], `GlassPill`, `StatusPill`, `ServicePillShell` ve `StatusBadge` hepsi bunu
/// çizer (eskiden beş ayrı elle yazılmış varyanttı: dolgu, kenar, yarıçap ve boyut tutarsızdı).
///
/// * [color] vurgu rengi (aile `base`i ya da ham renk): dolgu tonu ve [ink] varsayılanı bundan türer.
/// * [ink] kenar (ve çağıranın metni) için okunur ton: varsayılan `AppTheme.readableAccent(context, color)` (AA).
/// * [active] `false` ⇒ nötr cam (renk tonu yok, kenar `rimSolid` ya da [neutralRim]): pasif durum hapı / seçili olmayan çip.
/// * [neutralRim] nötr hâlin kenarı. Varsayılan `rimSolid` (kartta ≈ 1.2–1.3:1) bilgi amaçlı pasif hap için yeterlidir; ETKİLEŞİMLİ
///   çipin seçilmemiş hâli ise bir bileşen SINIRIDIR (WCAG 1.4.11 ≥ 3:1): [AppChip] burada alan çerçevesini
///   ([AppTheme.getFieldBorder]) verir.
/// * [selected] ⇒ seçili çip dolgusu/kenarı ([AppPillTokens.selectedTint]/[AppPillTokens.selectedRim]).
/// * [animate] ⇒ renk/dolgu geçişi yumuşak (`MotionMode.off`'ta anında); durum hapları için.
/// * Dolgu OPAKTIR (kart gradyanı + ton): hap doğrudan devre kartı zemininde (üst çubuk, durum şeridi) durunca da
///   arkadaki iz çizgileri metnin altından geçmez.
class AppPillShell extends StatelessWidget {
  const AppPillShell({
    super.key,
    required this.color,
    required this.child,
    this.leading,
    this.ink,
    this.active = true,
    this.neutralRim,
    this.selected = false,
    this.compact = false,
    this.animate = false,
    this.minHeight,
    this.padding,
    this.gap = AppPillTokens.gap,
  });

  final Color color;
  final Widget child;

  /// Metnin önündeki gösterge ([GlowDot], simge, mini orb ...).
  final Widget? leading;
  final Color? ink;
  final bool active;

  /// [active] `false` iken kenar rengi (`null` ⇒ `SurfaceTokens.rimSolid`). Bkz. sınıf belgesi.
  final Color? neutralRim;
  final bool selected;
  final bool compact;
  final bool animate;

  /// Görsel en az yükseklik (ör. durum hapı 36 dp).
  final double? minHeight;

  /// Varsayılan dolgu yerine özel iç boşluk (durum hapı, çip).
  final EdgeInsetsGeometry? padding;

  /// [leading] ile [child] arası boşluk.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);
    final Color top;
    final Color bottom;
    final Color rim;
    final double rimWidth;
    if (!active) {
      top = tokens.cardTop;
      bottom = tokens.cardBottom;
      rim = neutralRim ?? tokens.rimSolid;
      rimWidth = AppPillTokens.border;
    } else {
      final readable = ink ?? AppTheme.readableAccent(context, color);
      final tint = selected ? AppPillTokens.selectedTint : AppPillTokens.tint;
      top = Color.alphaBlend(color.withValues(alpha: tint), tokens.cardTop);
      bottom = Color.alphaBlend(color.withValues(alpha: tint), tokens.cardBottom);
      rim = readable.withValues(alpha: selected ? AppPillTokens.selectedRim : AppPillTokens.rim);
      rimWidth = selected ? AppPillTokens.selectedRimWidth : AppPillTokens.border;
    }
    final vertical = compact ? AppPillTokens.compactVertical : AppPillTokens.vertical;
    final resolvedPadding = padding ??
        EdgeInsetsDirectional.fromSTEB(
          leading == null ? AppPillTokens.padEnd : AppPillTokens.padStart,
          vertical,
          AppPillTokens.padEnd,
          vertical,
        );
    final constraints = minHeight == null ? null : BoxConstraints(minHeight: minHeight!);
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]),
      border: Border.all(color: rim, width: rimWidth),
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading!, SizedBox(width: gap)],
        Flexible(child: child),
      ],
    );
    return RepaintBoundary(
      child: animate
          ? AnimatedContainer(
              duration: MotionScope.durationOf(context, AppMotion.base),
              curve: AppMotion.standard,
              constraints: constraints,
              padding: resolvedPadding,
              decoration: decoration,
              child: content,
            )
          : Container(constraints: constraints, padding: resolvedPadding, decoration: decoration, child: content),
    );
  }
}

/// TEK rozet: stadium, vurgu tonu ([AppPillTokens.tint]) + kenar ([AppPillTokens.rim]), en az 12 sp / w700 etiket, isteğe
/// bağlı [GlowDot] ([dot]) / simge ([icon]) / özel [leading], etiket rengi vurgunun **okunabilir tonu**
/// ([AppTheme.readableAccent]; açık temada koyulaşır, AA ≥ 4.5:1).
///
/// Durum rozeti, rol rozeti, modül rozeti ('CH 3', 'RS485'), sayaç kutucuğu rozeti ve servis durum hapı bu bileşenden
/// çizilir (`GlassPill`, `StatusBadge`, `ModuleBadge`, `ServiceStatusPill` ince sarmalayıcılardır).
///
/// * [maxLines] > 1 ⇒ etiket satıra SARILIR (büyük yazıda 'SÜPER YÖNETİCİ KONS…' gibi metin kaybı yok) ama SÖZCÜK ORTASINDAN
///   KIRILMAZ: en uzun sözcük yere sığmıyorsa etiket küçülür ([WordSafeLabel]; 'ENVANTER' → 'ENVANTE'+'R' yok, rozet yüksekliği
///   komşularla eşit); 1 ⇒ tek satır + üç nokta (üst çubuk: yer yoksa hap hiç çizilmez, bkz. `dashboard_app_bar.dart`).
/// * [compact] ⇒ dikey dolgu 2 dp (üst çubuğun 64 dp'lik yüksekliğine sığar).
/// * [active] `false` ⇒ nötr (tonsuz) hap, etiket soluk.
/// * Anlamsal düğüm EKLEMEZ: görünen metin anlamı taşır (renk TEK ipucu değildir: nokta/simge + METİN).
///
/// ```dart
/// AppPill(label: 'Evde', family: AppFamilies.emerald, dot: true)
/// AppPill.tinted(label: 'RS485', color: someColor, maxLines: 1)
/// ```
class AppPill extends StatelessWidget {
  /// Aile rengiyle rozet.
  const AppPill({
    super.key,
    required this.label,
    required AccentFamily this.family,
    this.icon,
    this.dot = false,
    this.leading,
    this.maxLines = 2,
    this.compact = false,
    this.textKey,
    this.letterSpacing,
    this.textColor,
    this.active = true,
    this.animate = false,
  }) : tint = null;

  /// Ham renkle rozet (yalnız elinde aile olmayan sarmalayıcılar için: `GlassPill`, servis renkleri).
  const AppPill.tinted({
    super.key,
    required this.label,
    required Color color,
    this.icon,
    this.dot = false,
    this.leading,
    this.maxLines = 2,
    this.compact = false,
    this.textKey,
    this.letterSpacing,
    this.textColor,
    this.active = true,
    this.animate = false,
  })  : tint = color,
        family = null;

  final String label;
  final AccentFamily? family;
  final Color? tint;

  /// Etiketin önündeki 14 dp simge (renk tek ipucu olmasın diye). [leading] verilirse yok sayılır.
  final IconData? icon;

  /// Etiketin önünde canlı nokta ([GlowDot], 8 dp). [leading]/[icon] verilirse yok sayılır.
  final bool dot;

  /// Özel gösterge (ör. durum noktası, mini orb). Öncelikli.
  final Widget? leading;
  final int maxLines;
  final bool compact;

  /// Etiket `Text`'inin anahtarı (testler/erişim için).
  final Key? textKey;
  final double? letterSpacing;

  /// Etiket rengi (varsayılan: vurgunun okunabilir tonu).
  final Color? textColor;

  /// `false` ⇒ nötr (tonsuz) hap, etiket soluk.
  final bool active;

  /// Renk/dolgu geçişi yumuşak (durum değişen haplar).
  final bool animate;

  /// Etiket dışında kalan sabit yatay genişlik: dolgular + kenar (+ [leadingWidth] ve boşluk). Üst çubuk, hapın SIĞIP
  /// SIĞMAYACAĞINI etiket genişliğine bunu ekleyerek önceden ölçer ([GlassPill.chromeWidth] buna eşittir).
  static double chromeWidth({double leadingWidth = 0}) =>
      AppPillTokens.padEnd +
      (leadingWidth > 0 ? AppPillTokens.padStart + leadingWidth + AppPillTokens.gap : AppPillTokens.padEnd) +
      2 * AppPillTokens.border;

  @override
  Widget build(BuildContext context) {
    final color = family?.base ?? tint!;
    final ink = active ? (textColor ?? AppTheme.readableAccent(context, color)) : (textColor ?? AppTheme.getTextMuted(context));
    final Widget? lead = leading ??
        (icon != null
            ? ExcludeSemantics(child: Icon(icon, size: 14, color: ink))
            : (dot ? GlowDot(color: active ? color : AppTheme.getTextMuted(context), size: 8) : null));
    final text = Text(
      label,
      key: textKey,
      maxLines: maxLines,
      softWrap: maxLines > 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: AppText.badge,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: letterSpacing,
        color: ink,
      ),
    );
    return AppPillShell(
      color: color,
      ink: ink,
      active: active,
      compact: compact,
      animate: animate,
      leading: lead,
      // Sarılan etiket (maxLines > 1) SÖZCÜK ORTASINDAN kırılmaz: en uzun sözcük yere sığmıyorsa etiket küçülür.
      child: maxLines > 1 ? WordSafeLabel(minScale: minLabelScale(context), child: text) : text,
    );
  }

  /// [WordSafeLabel]'in en küçük ölçeği: etkin yazı boyutu (12 sp × kullanıcının yazı ölçeği) 12 sp tabanının
  /// ([AppTouch.minFontSize]) altına İNMEYECEK kadar. Yazı ölçeği 1.0'da etiket hiç küçülmez (1.0); 1.5'te en çok 1/1.5.
  /// Küçülme yalnız kullanıcının büyüttüğü yazı payından yenir: rozet 12 sp kuralını görsel olarak da bozmaz.
  static double minLabelScale(BuildContext context) {
    final effective = MediaQuery.textScalerOf(context).scale(AppText.badge);
    return effective <= 0 ? 1.0 : (AppTouch.minFontSize / effective).clamp(0.0, 1.0);
  }
}

/// Rozet etiketini **sözcük ortasından KIRMAZ**. Sarılan (`maxLines > 1`) bir `Text` yere sığmayan TEK sözcüğü harf düzeyinde
/// böler ('ENVANTER' → 'ENVANTE' + 'R'; rozet iki satırlı kapsüle dönüp komşu rozetle yüksekliği bozuyordu). Burada:
///
/// * en uzun sözcük (alt bileşenin `minIntrinsicWidth`i) mevcut genişliğe SIĞIYORSA düzen aynen kalır (sözcük sınırında sarma);
/// * sığmıyorsa alt bileşen o sözcüğün genişliğinde (sözcük sınırında sarılarak) yerleştirilir ve TÜMÜ mevcut genişliğe
///   küçültülür (`FittedBox.scaleDown` gibi), ama [minScale]'in altına inmez (rozetin 12 sp tabanı; bkz. [AppPill.minLabelScale]);
/// * kutunun YÜKSEKLİĞİ küçülmez (metin dikey ortalanır): aynı şeritteki rozetlerin yüksekliği eşit kalır.
///
/// `LayoutBuilder` KULLANMAZ (rozetler `IntrinsicHeight` satırlarında durur; `LayoutBuilder` iç boyut hesabını desteklemez):
/// tüm iç boyut/kuru yerleşim/taban çizgisi/isabet/boyama dönüşümü bu işlevde gerçeklenir.
class WordSafeLabel extends SingleChildRenderObjectWidget {
  const WordSafeLabel({super.key, this.minScale = 1.0, required Widget super.child}) : assert(minScale >= 0 && minScale <= 1);

  /// Etiketin küçülebileceği en düşük oran (1.0 ⇒ hiç küçülme).
  final double minScale;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderWordSafeLabel(minScale: minScale);

  @override
  void updateRenderObject(BuildContext context, RenderWordSafeLabel renderObject) => renderObject.minScale = minScale;
}

/// [WordSafeLabel]'in yerleşim nesnesi.
class RenderWordSafeLabel extends RenderBox with RenderObjectWithChildMixin<RenderBox> {
  RenderWordSafeLabel({required this._minScale});

  double _minScale;
  set minScale(double value) {
    if (value == _minScale) return;
    _minScale = value;
    markNeedsLayout();
  }

  /// Son yerleşimde uygulanan ölçek ve dikey ortalama payı.
  double _scale = 1.0;
  double _dy = 0.0;
  final LayerHandle<TransformLayer> _transformLayer = LayerHandle<TransformLayer>();

  /// Alt bileşen kısıtı ve ölçek: en uzun sözcük SIĞIYORSA `(constraints, 1)`; sığmıyorsa sözcük genişliğinde kısıt ve
  /// `genişlik / sözcük` ölçeği ([_minScale]'e kadar). Karşılaştırma paylı DEĞİLDİR: sözcük mevcut genişlikten yarım piksel
  /// bile uzunsa paragraf onu harf düzeyinde böler (tam bu sınırda 'ENVANTE' + 'R' kırılması görüldü).
  (BoxConstraints, double) _plan(BoxConstraints constraints, RenderBox child) {
    final maxWidth = constraints.maxWidth;
    if (!maxWidth.isFinite) return (constraints, 1.0);
    final longest = child.getMinIntrinsicWidth(double.infinity);
    if (longest + _epsilon <= maxWidth) return (constraints, 1.0);
    final scale = math.max(maxWidth / longest, _minScale);
    // +_epsilon: ölçeklenen sözcüğün kendi genişliğinde (kayan nokta gürültüsüyle) yeniden bölünmesini önler.
    return (BoxConstraints(maxWidth: maxWidth / scale + _epsilon), scale);
  }

  /// Kayan nokta/ölçüm gürültüsü payı (dp): sözcük bundan daha az boşlukla sığıyorsa sığmıyor sayılır (ölçek ≈ 1).
  static const double _epsilon = 0.05;

  Matrix4? get _paintTransform {
    if (_scale == 1.0 && _dy == 0.0) return null;
    return Matrix4.translationValues(0.0, _dy, 0.0)..multiply(Matrix4.diagonal3Values(_scale, _scale, 1.0));
  }

  @override
  double computeMinIntrinsicWidth(double height) => child?.getMinIntrinsicWidth(height) ?? 0.0;

  @override
  double computeMaxIntrinsicWidth(double height) => child?.getMaxIntrinsicWidth(height) ?? 0.0;

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  double _intrinsicHeight(double width) {
    final child = this.child;
    if (child == null) return 0.0;
    if (!width.isFinite) return child.getMaxIntrinsicHeight(width);
    final longest = child.getMinIntrinsicWidth(double.infinity);
    if (longest + _epsilon <= width) return child.getMaxIntrinsicHeight(width);
    final scale = math.max(width / longest, _minScale);
    return child.getMaxIntrinsicHeight(width / scale + _epsilon);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final (childConstraints, scale) = _plan(constraints, child);
    final childSize = child.getDryLayout(childConstraints);
    return constraints.constrain(Size(childSize.width * scale, childSize.height));
  }

  @override
  double? computeDryBaseline(covariant BoxConstraints constraints, TextBaseline baseline) {
    final child = this.child;
    if (child == null) return null;
    final (childConstraints, scale) = _plan(constraints, child);
    final distance = child.getDryBaseline(childConstraints, baseline);
    if (distance == null) return null;
    final height = child.getDryLayout(childConstraints).height;
    return (scale == 1.0 ? 0.0 : (height - height * scale) / 2) + distance * scale;
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _scale = 1.0;
      _dy = 0.0;
      return;
    }
    final (childConstraints, scale) = _plan(constraints, child);
    child.layout(childConstraints, parentUsesSize: true);
    _scale = scale;
    // Yükseklik küçülmez: ölçeklenmiş metin aynı yükseklikte dikey ortalanır (şeritteki rozetler eşit yükseklikte kalır).
    size = constraints.constrain(Size(child.size.width * scale, child.size.height));
    _dy = scale == 1.0 ? 0.0 : (size.height - child.size.height * scale) / 2;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final distance = child?.getDistanceToActualBaseline(baseline);
    return distance == null ? null : _dy + distance * _scale;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: _paintTransform,
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) => child.hitTest(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final t = _paintTransform;
    if (t != null) transform.multiply(t);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final transform = _paintTransform;
    if (transform == null) {
      _transformLayer.layer = null;
      context.paintChild(child, offset);
      return;
    }
    _transformLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      transform,
      (PaintingContext inner, Offset innerOffset) => inner.paintChild(child, innerOffset),
      oldLayer: _transformLayer.layer,
    );
  }

  @override
  void dispose() {
    _transformLayer.layer = null;
    super.dispose();
  }
}

/// TEK çip (filtre / seçim): [AppPill] ile AYNI stadium dili, etkileşimli. Seçili durum yalnız renkle anlatılmaz:
/// aile tonlu dolgu + kalın kenar + **onay işareti** ve AA okunur etiket ([AppPillTokens.selectedTint]); seçili değil ⇒ nötr cam
/// ve **alan çerçevesi kenarı** ([AppTheme.getFieldBorder]: kart/diyalog/sayfa yüzeyinde ≥ 3:1).
///
/// * Seçili OLMAYAN çip etkileşimli bir kontroldür: kenarı bileşen sınırıdır (WCAG 1.4.11 ≥ 3:1). Eskiden `rimSolid` (kartta
///   ≈ 1.2–1.3:1) idi ve beyaz diyalogda beyaz çip yalnız metinden ibaret kalıyordu. Seçili hâl ve tonlu dolgu AYNI; pasif
///   çipte (`onTap == null`) kenar yumuşak kalır (pasif bileşenler muaf).
/// * Görsel çip ≈ 36 dp, **dokunma hedefi ≥ 48 dp** (çip dikey ortalı, saydam pay); `Wrap`/`Row` içinde içerik genişliğindedir.
/// * Basınca ölçek geri bildirimi ([Pressable], `onTap` gecikmesiz); anlam: `button` + `selected` + `enabled` + etiket.
/// * [onTap] `null` ⇒ pasif (soluk, dokunuş yok).
/// * Yazı en az 12 sp ([AppText.caption] 12.5): seçili w800, değil w600.
///
/// ```dart
/// AppChip(key: Key('chip_filter_ALL'), label: 'Tümü', selected: filter == 'ALL', onTap: () => setFilter('ALL'))
/// ```
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.family = AppFamilies.cyan,
    this.icon,
    this.semanticLabel,
  });

  final String label;
  final bool selected;

  /// `null` ⇒ pasif.
  final VoidCallback? onTap;

  /// Seçili durumun rengi (varsayılan marka camgöbeği).
  final AccentFamily family;

  /// Seçili DEĞİLKEN etiketin önündeki simge (seçiliyken onay işareti gelir).
  final IconData? icon;

  /// Anlam etiketi (varsayılan: [label]).
  final String? semanticLabel;

  /// Görsel çip yüksekliğinin tabanı: 9 + 9 dolgu + 12.5 sp etiket ≈ 36 dp; hedef [AppTouch.minTarget].
  static const double _vertical = 9;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final ink = AppTheme.readableAccent(context, family.base);
    final muted = AppTheme.getTextMuted(context);
    final Color fg = !enabled ? muted.withValues(alpha: 0.6) : (selected ? ink : AppTheme.getTextPrimary(context));
    final Widget? lead = selected
        ? ExcludeSemantics(child: Icon(Icons.check_rounded, size: 16, color: enabled ? ink : fg))
        : (icon != null ? ExcludeSemantics(child: Icon(icon, size: 16, color: fg)) : null);
    final shell = AppPillShell(
      color: family.base,
      ink: ink,
      active: selected && enabled,
      // Seçili olmayan ETKİN çip: alan çerçevesi (≥ 3:1). Pasif çip (onTap null) yumuşak `rimSolid` kalır.
      neutralRim: !selected && enabled ? AppTheme.getFieldBorder(context) : null,
      selected: selected && enabled,
      animate: true,
      leading: lead,
      padding: EdgeInsetsDirectional.fromSTEB(lead == null ? 16 : 10, _vertical, 16, _vertical),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppText.caption,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          height: 1.2,
          color: fg,
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      excludeSemantics: true,
      label: semanticLabel ?? label,
      onTap: onTap,
      child: Pressable(
        onTap: onTap,
        enabled: enabled,
        pressedScale: 0.95,
        haptic: PressHaptic.selection,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
          child: Align(widthFactor: 1.0, child: shell),
        ),
      ),
    );
  }
}
