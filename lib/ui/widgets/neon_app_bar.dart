import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import 'orb/glass_icon_button.dart';
import 'orb/orb_icon_badge.dart';

/// İkincil sayfaların ORTAK "Neon Glass" üst çubuğu (WP-V9): düz Material `AppBar` yerine cam diskler + özellik orb'u.
///
/// `Scaffold.appBar` için bir [PreferredSizeWidget]'tır; `build` GERÇEK bir [AppBar] döndürür (alt sınıf değil:
/// `find.byType(AppBar)` bulur, `Scaffold` ve ekran okuyucu `AppBar` anlamını aynen görür).
///
/// Düzen (yükseklik 64 dp, kaydırınca renk/yüzey tonu YOK — şeffaf):
/// * **geri düğmesi:** sayfa geri gidilebilir bir rotadaysa ([automaticallyImplyLeading]) [GlassIconButton] (cam disk,
///   `Key('nav_back')`, ipucu/anlam etiketi `MaterialLocalizations.backButtonTooltip` — eski `BackButton` ile aynı;
///   `WidgetTester.pageBack` bulur). Görsel sol kenar 16 dp içerik oluğuna oturur;
/// * **özellik orb'u:** [icon] verilirse [OrbIconBadge] (~32 dp) — rengi [feature] (ya da [family]) ailesinden, yani
///   çekmece/konsol/araç kartıyla AYNI ([featureFamily]);
/// * **başlık** ([title], `AppText.title` 18 sp / w700, metin AYNEN) + isteğe bağlı **alt başlık** ([subtitle], 12.5 sp, soluk).
///   Sığmayan başlık/alt başlık en çok 2 satıra SARILIR (kesilmez); blok [maxTextScale]'e kadar büyür (çubuk 64 dp sabit:
///   pano üst çubuğuyla aynı sınır) ve yine de 64 dp'ye sığmazsa tek parça KÜÇÜLÜR (`FittedBox.scaleDown`): yazı ölçeği
///   1.5/2.0 ve 360 dp'de ne kesilir ne taşar;
/// * **eylemler:** [actions] (genelde [NeonBarAction]: cam disk + ipucu; Key ve anlam etiketi çağıranda kalır);
/// * [bottom] (ör. `TabBar`) desteklenir.
///
/// ```dart
/// Scaffold(
///   appBar: NeonAppBar(
///     title: 'Cihaz Envanteri',
///     subtitle: 'Karekodlar, Seri No & Donanım Takibi',
///     feature: AppFeature.inventory,
///     icon: Icons.inventory_2_rounded,
///     actions: [NeonBarAction(key: Key('btn_refresh'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: reload)],
///   ),
/// )
/// ```
///
/// Pano/konsol üst çubuğu ([DashboardAppBar]) ayrıdır ve bu bileşeni KULLANMAZ.
class NeonAppBar extends StatelessWidget implements PreferredSizeWidget {
  const NeonAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.feature,
    this.icon,
    this.family,
    this.titleKey,
    this.actions = const <Widget>[],
    this.bottom,
    this.automaticallyImplyLeading = true,
  });

  /// Başlık metni (olduğu gibi gösterilir).
  final String title;

  /// Başlığın altındaki soluk satır (ör. "Karekodlar, Seri No & Donanım Takibi").
  final String? subtitle;

  /// Orb rengini veren özellik ([featureFamily]). [family] verilirse o öncelikli; ikisi de yoksa marka camgöbeği.
  final AppFeature? feature;

  /// Orb simgesi; `null` ise orb çizilmez.
  final IconData? icon;

  /// Orb ailesini doğrudan verir (özelliği olmayan sayfalar için).
  final AccentFamily? family;

  /// Başlık `Text`'inin anahtarı (testler okur).
  final Key? titleKey;

  /// Sağdaki eylemler (genelde [NeonBarAction]).
  final List<Widget> actions;

  /// Çubuğun altına eklenen bileşen (ör. `TabBar`); yükseklik [preferredSize]'a eklenir.
  final PreferredSizeWidget? bottom;

  /// `true` (varsayılan) ve rota geri gidilebiliyorsa geri düğmesi çizilir.
  final bool automaticallyImplyLeading;

  /// Çubuk yüksekliği (dp); [bottom] bunun ALTINA eklenir.
  static const double toolbarHeight = 64;

  /// Özellik orb'unun görsel çapı (dp).
  static const double orbDiameter = 32;

  /// Başlık bloğunun en çok büyüyeceği yazı ölçeği: çubuk 64 dp sabittir ([DashboardAppBar] başlığıyla aynı sınır; daha
  /// büyük ölçekte metin taşmak yerine bu ölçekte kalır, sığmazsa küçülür).
  static const double maxTextScale = 1.3;

  /// Cam disklerin GÖRSEL kenarının sayfa içerik oluğuna (16 dp) uzaklığı.
  static const double edge = 16;

  /// Geri düğmesi 48 dp'lik kutusunun başlangıç boşluğu: 44 dp'lik disk kutunun içinde 2 dp içeride, görsel kenar 16 dp.
  static const double _backStart = edge - 2;
  static const double _leadingWidth = _backStart + AppTouch.minTarget;

  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final showBack = automaticallyImplyLeading && (ModalRoute.of(context)?.canPop ?? false);
    final orbFamily = family ?? feature?.accentFamily ?? AppFamilies.cyan;
    final hasActions = actions.isNotEmpty;

    // Başlık bloğu: en çok [maxTextScale] büyür; genişlik sınırlı (sığmayan metin sarılır), yükseklik 64 dp ile sınırlı
    // (AppBar başlık kutusu yüksekliği sınırsız verir: sınırı burada koyarız); yine de sığmazsa FittedBox tek parça küçültür.
    final titleBlock = MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxTextScale,
      child: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: toolbarHeight),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    key: titleKey,
                    maxLines: 2,
                    softWrap: true,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: AppText.title, fontWeight: FontWeight.w700),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.getTextMuted(context),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return AppBar(
      toolbarHeight: toolbarHeight,
      automaticallyImplyLeading: false,
      leading: showBack ? const _NeonBackButton() : null,
      leadingWidth: showBack ? _leadingWidth : null,
      // Kenar boşluklarını başlık bloğu kendisi verir (AppBar `titleSpacing`'i iki yandan düşerdi).
      titleSpacing: 0,
      centerTitle: false,
      // Şeffaf Neon Glass çubuk: kaydırınca çıkan M3 "scrolled-under" tonu (açıkta lavanta bant) ve yüzey tonu yok.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      // Cam disklerin (geri/eylemler) ve orb'un gölgesi çubuğun alt kenarında KESİLMESİN: disk 44 dp, çubukta alt boşluk
      // 10 dp; gölge (blur 12 + y 5) ≈ 17 dp taşar. `AppBar` araç çubuğunu varsayılan `Clip.hardEdge` ile kırpıp açık temada
      // alt kenarda düz bir soluk bant bırakıyordu (r2_service #13). Başlık bloğu zaten yükseklik sınırlıdır (taşma yok).
      clipBehavior: Clip.none,
      title: Padding(
        padding: EdgeInsetsDirectional.only(start: showBack ? 6 : edge, end: hasActions ? AppSpace.s8 : edge),
        child: Row(
          children: [
            if (icon != null) ...[
              // 44 dp'lik orb ölçekle ~32 dp'ye indirilir: büyük orb'larla AYNI gövde/parıltı (özel boya yok).
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: orbDiameter,
                  child: FittedBox(
                    child: OrbIconBadge(icon: icon!, family: orbFamily, size: OrbSize.sm),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(child: titleBlock),
          ],
        ),
      ),
      actions: hasActions ? <Widget>[...actions, const SizedBox(width: edge - 2)] : null,
      bottom: bottom,
    );
  }
}

/// Geri düğmesi: cam disk ([GlassIconButton]) + işaretçi ipucu. `Navigator.maybePop` (PopScope/`canPop` kapıları çalışır;
/// eski `BackButton` ile aynı davranış).
class _NeonBackButton extends StatelessWidget {
  const _NeonBackButton();

  @override
  Widget build(BuildContext context) {
    final tooltip = MaterialLocalizations.of(context).backButtonTooltip;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: NeonAppBar._backStart),
        child: Tooltip(
          message: tooltip,
          excludeFromSemantics: true,
          child: GlassIconButton(
            key: const Key('nav_back'),
            icon: Icons.arrow_back_rounded,
            semanticLabel: tooltip,
            onTap: () => unawaited(Navigator.of(context).maybePop()),
          ),
        ),
      ),
    );
  }
}

/// [NeonAppBar] eylemi: cam disk ([GlassIconButton], 44 görsel / 48 hedef) + işaretçi ipucu ([tooltip], anlamdan hariç: anlam
/// etiketini düğmenin kendisi verir, ekran okuyucu çift okumaz). `onTap == null` ⇒ pasif (soluk disk/simge).
///
/// Anahtar (`key`) bu bileşene verilir (testler `find.byKey(...)` ile dokunur; merkez diskin merkezidir).
class NeonBarAction extends StatelessWidget {
  const NeonBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.showBadge = false,
    this.badgeSemantics,
    this.iconColor,
  });

  final IconData icon;

  /// İşaretçi ipucu ve anlam etiketi.
  final String tooltip;

  /// `null` ⇒ pasif.
  final VoidCallback? onTap;
  final bool showBadge;
  final String? badgeSemantics;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: GlassIconButton(
        icon: icon,
        semanticLabel: tooltip,
        onTap: onTap,
        showBadge: showBadge,
        badgeSemantics: badgeSemantics,
        iconColor: iconColor,
      ),
    );
  }
}
