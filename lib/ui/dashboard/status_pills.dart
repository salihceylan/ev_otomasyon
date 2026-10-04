import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../motion/motion.dart';
import '../pages/device_settings_page.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_pill.dart';
import '../widgets/orb/orb.dart';
import '../widgets/settings/child_lock_info_sheet.dart';
import 'child_lock_status.dart';
import 'connection_status.dart';

/// Pano durum hapı v2 (Neon Glass): ortak rozet yüzeyi ([AppPillShell]: kart gradyanı + vurgu tonu `.14` + kenar `.40`), solda
/// durum göstergesi:
/// * [busy]: dönen yay ([ProgressArc]),
/// * [dot]: canlı nokta ([GlowDot]; [dotPulses] > 0 ise "bağlanıyor" nabzı, sonra sabit),
/// * aksi halde: simge (renk TEK ipucu olmasın diye çevrimdışı/uyarı durumları simge + metindir).
///
/// Etkin hap vurgu renginde; **pasif hap `getTextMuted(context)`** renginde ve tonsuz (nötr cam; açık temada da okunur).
/// [count] verilirse ([countFormat] ile) sayı yumuşakça akar ([AnimatedCount]; ağaçta tek `Text`).
///
/// **Boyut tek:** her hap görsel olarak aynı yükseklikte ([kHeight]) çizilir; dokunulabilir hap ([onTap]) görseli
/// şişirmez, 48 dp dokunma hedefini hapın çevresindeki saydam payla ([kTouchTarget]) verir (aynı satırdaki
/// dokunulmaz haplarla metin ortaları hizalı kalır). [color] hapın parlak aile rengidir (nokta/kenar); metin ve
/// simge [AppTheme.readableAccent] ile AA okunur tona çevrilir.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.isActive,
    this.onTap,
    this.busy = false,
    this.semanticsLabel,
    this.dot = false,
    this.dotPulses = 0,
    this.count,
    this.countFormat,
  });

  /// Hapın görsel yüksekliği (en az).
  static const double kHeight = 36;

  /// Dokunulabilir hapın toplam dokunma hedefi yüksekliği.
  static const double kTouchTarget = AppTouch.minTarget;

  final IconData icon;
  final String label;

  /// Etkin durumdaki vurgu rengi.
  final Color color;
  final bool isActive;
  final VoidCallback? onTap;

  /// Küçük bir ilerleme göstergesi çizer (ör. "uygulanıyor…").
  final bool busy;
  final String? semanticsLabel;

  /// Simge yerine canlı nokta çizer.
  final bool dot;

  /// Nokta için "bağlanıyor" nabız sayısı (0 = nabız yok).
  final int dotPulses;

  /// Verilirse metin `countFormat(count)` olarak sayıdan türetilir ve sayı değişince akar ([label] yalnız anlam içindir).
  final int? count;
  final String Function(int)? countFormat;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final fg = isActive ? AppTheme.readableAccent(context, color) : AppTheme.getTextMuted(context);
    final textStyle = TextStyle(fontSize: AppText.badge, fontWeight: FontWeight.w700, color: fg);
    // Simge diski ve glif yazı ölçeğiyle (en çok 1.3x) büyür: büyük yazıda simge metne oranla küçük kalmaz.
    final scale = (MediaQuery.textScalerOf(context).scale(10) / 10).clamp(1.0, 1.3);
    final disc = 26.0 * scale;

    final Widget leading;
    if (busy) {
      leading = SizedBox(
        width: disc,
        height: disc,
        child: Center(child: ProgressArc(diameter: 16, color: fg, strokeWidth: 2)),
      );
    } else if (dot) {
      leading = SizedBox(
        width: disc,
        height: disc,
        child: Center(
          child: GlowDot(
            key: ValueKey<int>(dotPulses),
            color: isActive ? color : AppTheme.getTextMuted(context),
            size: 8,
            pulses: dotPulses,
          ),
        ),
      );
    } else {
      // Pasif hapta glif ana metin renginde (soluk gri değil): panjur/ampul simgesi 1.0 ölçekte de seçilir.
      final glyph = isActive ? fg : AppTheme.getTextPrimary(context).withValues(alpha: 0.78);
      leading = Container(
        width: disc,
        height: disc,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (isActive ? color : fg).withValues(alpha: dark ? 0.22 : 0.16),
        ),
        child: Icon(icon, size: 16 * scale, color: glyph),
      );
    }

    final labelWidget = count != null && countFormat != null
        ? AnimatedCount(value: count!, format: countFormat!, style: textStyle, maxLines: 2, overflow: TextOverflow.ellipsis)
        : Text(label, style: textStyle, maxLines: 2, overflow: TextOverflow.ellipsis);

    // Ortak rozet yüzeyi: durum hapı büyük (36 dp, 26 dp'lik gösterge diski) ama dil aynı (ton + kenar + stadium).
    Widget pill = AppPillShell(
      color: color,
      active: isActive,
      animate: false,
      minHeight: kHeight,
      padding: const EdgeInsetsDirectional.fromSTEB(5, 4, 14, 4),
      gap: 8,
      leading: leading,
      child: labelWidget,
    );

    if (onTap != null) {
      // Görsel yükseklik sabit kalır; 48 dp hedef saydam dikey payla (hap + 2 x 6 dp) sağlanır.
      pill = Padding(
        padding: const EdgeInsets.symmetric(vertical: (kTouchTarget - kHeight) / 2),
        child: pill,
      );
    }

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: semanticsLabel ?? label,
      button: onTap != null,
      liveRegion: true,
      onTap: onTap,
      child: onTap == null
          ? pill
          : Pressable(onTap: onTap, pressedScale: 0.96, child: pill),
    );
  }
}

/// Çocuk kilidi rozeti: kilitliyken, uygulanırken ya da panolar farklı durumdayken görünür;
/// **dokunulabilir** (bilgi sayfasını açar). Kilit kapalı/bilinmiyorken görünmez (yanlış
/// "kilitli/kapalı" iddiası yapılmaz). Anahtar: `Key('chip_child_lock')`.
class ChildLockChip extends StatelessWidget {
  const ChildLockChip({super.key});

  /// Rozet bu durumda görünür mü? (kilitliyken, uygulanırken ya da panolar farklı durumdayken). Üst durum şeridi
  /// ([DashboardStatusBar]) bunu `select` ile okur ve rozeti **yalnız görünürken** `Wrap`'e ekler: görünmez bir rozet
  /// (`SizedBox.shrink`) bile `Wrap` içinde yuva + `spacing` (8 dp) tüketir ve hap araları eşitsiz çıkardı.
  static bool visibleFor(ChildLockVm vm) =>
      vm.pending || vm.status == ChildLockStatus.locked || vm.status == ChildLockStatus.mixed;

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ChildLockVm>(childLockVmOf);
    final mixed = vm.status == ChildLockStatus.mixed;
    if (!visibleFor(vm)) return const SizedBox.shrink();

    final label = vm.pending
        ? 'Çocuk kilidi uygulanıyor…'
        : mixed
            ? 'Çocuk kilidi: panolar farklı'
            : (vm.stale ? 'Çocuk kilidi: son bilinen' : 'Çocuk Kilidi Aktif');

    return StatusPill(
      key: const Key('chip_child_lock'),
      icon: Icons.lock_outline,
      label: label,
      color: AppFamilies.amber.base,
      isActive: true,
      busy: vm.pending,
      semanticsLabel: '$label. ${childLockStatusLabel(vm)}. Ayrıntı için dokunun.',
      onTap: () => showChildLockInfoSheet(context),
    );
  }
}

/// Üst durum şeridi: açık ışık sayısı, hareketli panjur sayısı, çocuk kilidi ve sistem durumu
/// ("Sistem Hazır" yalnızca broker bağlı **ve** cihaz çevrimiçiyken). Anahtar: `Key('status_bar')`.
///
/// Sayaç hapları (ışık / panjur) yalnızca **sayılacak durum verisi varken** çizilir: cihaz erişilemez / anahtar
/// gerekli / geçici kilitli iken, pano **kesin** çevrimdışıyken ([deviceKnownOffline]; sayılar son bilinen değerdir)
/// ya da hiç cihaz yokken "Tüm Işıklar Kapalı" demek bilinmeyen durumu kesin bilgi gibi sunardı (açık lamba
/// olabilir). Sistem durumu hapı ve çocuk kilidi rozeti her zaman anlamlıdır.
class DashboardStatusBar extends StatelessWidget {
  const DashboardStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({int lights, int moving, bool hasData, bool childLock, ConnectionBadge badge})>(
      (s) => (
        lights: s.openLightsCount,
        moving: s.shutterItems.where((item) => item.isMoving).length,
        // Doğrudan modda cihaz durumu (`status`) yoksa, bulutta uç nokta listesi boşsa sayılacak veri yoktur. Pano kesin
        // çevrimdışıyken eldeki sayılar son bilinen değerdir: aynı "veri yok" gösterimi (yalnız sistem hapı) kullanılır.
        hasData: !deviceKnownOffline(s) && (s.mode == AppMode.direct ? s.status != null : s.cloudEndpoints.isNotEmpty),
        // Çocuk kilidi rozeti görünür mü: görünmezken şeritte HİÇ yuva ayrılmaz (aşağıda koşullu eleman).
        childLock: ChildLockChip.visibleFor(childLockVmOf(s)),
        badge: connectionBadgeOf(s),
      ),
    );

    final state = context.read<AutomationState>();
    final level = vm.badge.level;
    // Renk TEK ipucu değil: hazır/kesik/bağlanıyor durumlarında nokta + metin, çevrimdışı/anahtar/kilit
    // durumlarında simge + metin.
    final useDot = level == ConnectionLevel.ready ||
        level == ConnectionLevel.degraded ||
        level == ConnectionLevel.connecting;
    VoidCallback? systemAction;
    switch (level) {
      case ConnectionLevel.needsKey:
        // Anahtar ayarlardan girilir (`setLocalKey` orada çağrılır).
        systemAction = () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage()),
            );
      case ConnectionLevel.locked:
      case ConnectionLevel.offline:
      case ConnectionLevel.degraded:
        systemAction = () => unawaited(state.refresh());
      case ConnectionLevel.ready:
      case ConnectionLevel.connecting:
        systemAction = null;
    }

    // Satırdaki hapların metin ortaları hizalı: dokunulabilir hap 48 dp hedef için saydam pay taşır.
    return Wrap(
      key: const Key('status_bar'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (vm.hasData)
          StatusPill(
            icon: Icons.lightbulb,
            label: vm.lights > 0 ? '${vm.lights} Işık Açık' : 'Tüm Işıklar Kapalı',
            color: AppFamilies.amber.base,
            isActive: vm.lights > 0,
            count: vm.lights > 0 ? vm.lights : null,
            countFormat: (v) => '$v Işık Açık',
          ),
        if (vm.hasData)
          StatusPill(
            icon: Icons.blinds,
            label: vm.moving > 0 ? '${vm.moving} Panjur Hareketli' : 'Panjurlar Sabit',
            color: AppFamilies.sky.base,
            isActive: vm.moving > 0,
            count: vm.moving > 0 ? vm.moving : null,
            countFormat: (v) => '$v Panjur Hareketli',
          ),
        if (vm.childLock) const ChildLockChip(),
        StatusPill(
          key: const Key('pill_system'),
          icon: vm.badge.icon,
          label: vm.badge.label,
          // Parlak aile rengi (nokta/kenar); metin için hap kendi içinde okunur tona çevirir.
          color: vm.badge.family.base,
          isActive: vm.badge.isReady || level != ConnectionLevel.connecting,
          dot: useDot,
          dotPulses: level == ConnectionLevel.connecting ? 3 : 0,
          onTap: systemAction,
          semanticsLabel: systemAction == null ? null : '${vm.badge.label}. Ayrıntı için dokunun.',
        ),
      ],
    );
  }
}
