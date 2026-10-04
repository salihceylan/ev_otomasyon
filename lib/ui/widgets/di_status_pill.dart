import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../dashboard/module_badge.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart';
import 'orb/glow_dot.dart';

/// Dijital giriş (duvar butonu) durum hapı.
///
/// Çocuk kilidi açıkken duvar anahtarlarına basış yok sayılır: hap bunu kilit simgesiyle gösterir
/// (misafirler ölü anahtarlara şaşırmasın). Anahtar: `Key('card_di_<kimlik>')`.
///
/// Biçim, panodaki durum hapıyla ([StatusPill]) AYNI cam dilidir: opak gradyan gövde (kart tabanı + etkinse
/// yeşil ton) + rim, 36 dp yükseklik, >= 12 sp yazı. Gövde OPAKTIR: arkadaki devre izi hapın içinden görünmez
/// (eskiden etkin dolgu yarı saydamdı). Ad tek satırdır (uzun ad / ek modül / çift haneli kimlikte hap büyümez,
/// ad kesilir; tam ad anlam etiketindedir).
class DIStatusPill extends StatelessWidget {
  const DIStatusPill({super.key, required this.di});

  final DIItem di;

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AutomationState, bool>(
      (s) => s.childLockStatus == ChildLockStatus.locked,
    );
    // Duvar butonunun canlı durumu (kart yalnızca kendi girişi değişince yeniden çizilir).
    final live = context.select<AutomationState, bool?>((s) {
      for (final item in s.status?.dis ?? const <DIItem>[]) {
        if (item.id == di.id) return item.state;
      }
      return null;
    });
    final active = live ?? di.state;
    final name = 'Giriş ${di.id}${di.isExt ? " (ek modül)" : ""}';
    final stateText = active ? 'Aktif' : 'Pasif';
    final accent = AppFamilies.emerald.base;
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: [
        name,
        stateText.toLowerCase(),
        if (locked) 'çocuk kilidi açık, duvar anahtarı devre dışı',
      ].join(', '),
      child: Container(
        key: Key('card_di_${di.id}'),
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // Ortak rozet dili ([AppPillTokens]): ton .14 + kenar .40 (etkin), nötr cam (pasif); gövde OPAK.
            colors: [
              active ? Color.alphaBlend(accent.withValues(alpha: AppPillTokens.tint), tokens.cardTop) : tokens.cardTop,
              active ? Color.alphaBlend(accent.withValues(alpha: AppPillTokens.tint), tokens.cardBottom) : tokens.cardBottom,
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: active ? AppTheme.successText(context).withValues(alpha: AppPillTokens.rim) : tokens.rimSolid,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Canlı LED: etkinken yumuşak halo (yalnız anlık durum; metin yanında ayrıca yazılıdır).
            GlowDot(
              color: active ? accent : AppTheme.getTextMuted(context).withValues(alpha: 0.6),
              size: 9,
              breathing: active,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: AppText.badge,
                  fontWeight: FontWeight.w700,
                  color: active ? AppTheme.successText(context) : AppTheme.getTextPrimary(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              stateText,
              maxLines: 1,
              style: TextStyle(
                fontSize: AppText.badge,
                fontWeight: FontWeight.w600,
                color: active ? AppTheme.successText(context) : AppTheme.getTextMuted(context),
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 8),
              const LockBadge(size: 24),
            ],
          ],
        ),
      ),
    );
  }
}
