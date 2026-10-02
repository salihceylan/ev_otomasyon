import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

/// Dijital giriş (duvar butonu) durum hapı.
///
/// Çocuk kilidi açıkken duvar anahtarlarına basış yok sayılır: hap bunu kilit simgesiyle gösterir
/// (misafirler ölü anahtarlara şaşırmasın). Anahtar: `Key('card_di_<kimlik>')`.
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
    final accent = AppTheme.accentGreen;

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
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.16) : AppTheme.getInsetColor(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? accent : AppTheme.getCardBorder(context),
            width: 1.1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? accent : AppTheme.getTextMuted(context).withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: active ? AppTheme.successText(context) : AppTheme.getTextPrimary(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              stateText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active ? AppTheme.successText(context) : AppTheme.getTextMuted(context),
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 6),
              Icon(Icons.lock_outline, size: 14, color: AppTheme.warningText(context)),
            ],
          ],
        ),
      ),
    );
  }
}
