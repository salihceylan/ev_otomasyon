import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../widgets/settings/child_lock_info_sheet.dart';
import 'child_lock_status.dart';
import 'connection_status.dart';

/// Pano durum hapı. Etkin hap vurgu renginde; **pasif hap `getTextMuted(context)`** renginde
/// (açık temada da okunur). [onTap] verilirse hap dokunulabilirdir (≥ 48 dp).
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
  });

  final IconData icon;
  final String label;

  /// Etkin durumdaki vurgu rengi.
  final Color color;
  final bool isActive;
  final VoidCallback? onTap;

  /// Küçük bir ilerleme göstergesi çizer (ör. "uygulanıyor…").
  final bool busy;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final fg = isActive ? AppTheme.readableAccent(context, color) : AppTheme.getTextMuted(context);

    final pill = Container(
      constraints: BoxConstraints(minHeight: onTap != null ? 48 : 34),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive
            ? color.withValues(alpha: AppTheme.isDark(context) ? 0.12 : 0.10)
            : AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isActive ? color.withValues(alpha: 0.4) : AppTheme.getCardBorder(context),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            )
          else
            Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: semanticsLabel ?? label,
      button: onTap != null,
      liveRegion: true,
      onTap: onTap,
      child: onTap == null
          ? pill
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: onTap,
                child: pill,
              ),
            ),
    );
  }
}

/// Çocuk kilidi rozeti: kilitliyken, uygulanırken ya da panolar farklı durumdayken görünür;
/// **dokunulabilir** (bilgi sayfasını açar). Kilit kapalı/bilinmiyorken görünmez (yanlış
/// "kilitli/kapalı" iddiası yapılmaz). Anahtar: `Key('chip_child_lock')`.
class ChildLockChip extends StatelessWidget {
  const ChildLockChip({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ChildLockVm>(childLockVmOf);
    final locked = vm.status == ChildLockStatus.locked;
    final mixed = vm.status == ChildLockStatus.mixed;
    if (!vm.pending && !locked && !mixed) return const SizedBox.shrink();

    final label = vm.pending
        ? 'Çocuk kilidi uygulanıyor…'
        : mixed
            ? 'Çocuk kilidi: panolar farklı'
            : (vm.stale ? 'Çocuk kilidi: son bilinen' : 'Çocuk Kilidi Aktif');

    return StatusPill(
      key: const Key('chip_child_lock'),
      icon: Icons.lock_outline,
      label: label,
      color: Colors.amber,
      isActive: true,
      busy: vm.pending,
      semanticsLabel: '$label. ${childLockStatusLabel(vm)}. Ayrıntı için dokunun.',
      onTap: () => showChildLockInfoSheet(context),
    );
  }
}

/// Üst durum şeridi: açık ışık sayısı, hareketli panjur sayısı, çocuk kilidi ve sistem durumu
/// ("Sistem Hazır" yalnızca broker bağlı **ve** cihaz çevrimiçiyken). Anahtar: `Key('status_bar')`.
class DashboardStatusBar extends StatelessWidget {
  const DashboardStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({int lights, int moving, ConnectionBadge badge})>(
      (s) => (
        lights: s.openLightsCount,
        moving: s.shutterItems.where((item) => item.isMoving).length,
        badge: connectionBadgeOf(s),
      ),
    );

    return Wrap(
      key: const Key('status_bar'),
      spacing: 8,
      runSpacing: 8,
      children: [
        StatusPill(
          icon: Icons.lightbulb,
          label: vm.lights > 0 ? '${vm.lights} Işık Açık' : 'Tüm Işıklar Kapalı',
          color: AppTheme.accentAmber,
          isActive: vm.lights > 0,
        ),
        StatusPill(
          icon: Icons.blinds,
          label: vm.moving > 0 ? '${vm.moving} Panjur Hareketli' : 'Panjurlar Sabit',
          color: AppTheme.primaryBlue,
          isActive: vm.moving > 0,
        ),
        const ChildLockChip(),
        StatusPill(
          key: const Key('pill_system'),
          icon: vm.badge.icon,
          label: vm.badge.label,
          color: vm.badge.color(context),
          isActive: vm.badge.isReady || vm.badge.level != ConnectionLevel.connecting,
        ),
      ],
    );
  }
}
