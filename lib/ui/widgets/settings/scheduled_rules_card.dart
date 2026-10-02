import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../pages/scheduled_rules_page.dart';
import '../../theme/app_theme.dart';

/// "Zamanlı Otomasyon Kuralları" özet kartı. Kural sayısı **ayarlar açılırken yüklenir**:
/// yükleme sürerken "yükleniyor…", hata olursa "yüklenemedi", yalnızca başarılı boş yanıtta
/// "henüz kural yok" gösterilir (yanlış "kural yok" yok). Yalnızca bulut modunda ve
/// `canManageRules` yetkisiyle sayfada gösterilir.
///
/// Anahtar: `Key('card_rules')`, `Key('text_rules_status')`.
class ScheduledRulesCard extends StatefulWidget {
  const ScheduledRulesCard({super.key});

  @override
  State<ScheduledRulesCard> createState() => _ScheduledRulesCardState();
}

class _ScheduledRulesCardState extends State<ScheduledRulesCard> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final state = context.read<AutomationState>();
    if (mounted) setState(() => _loaded = false);
    await state.fetchScheduledRules();
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({int total, int active, bool loading, String? error})>(
      (s) => (
        total: s.scheduledRules.length,
        active: s.scheduledRules.where((r) => r.enabled).length,
        loading: s.scheduledRulesLoading,
        error: s.scheduledRulesError,
      ),
    );

    final cyan = Colors.cyanAccent;
    final readable = AppTheme.readableAccent(context, cyan);
    final loading = !_loaded || vm.loading && vm.total == 0;
    final failed = !loading && vm.error != null && vm.total == 0;

    final String status;
    if (loading) {
      status = 'Kurallar yükleniyor…';
    } else if (failed) {
      status = 'Kurallar yüklenemedi. Dokunup tekrar deneyin.';
    } else if (vm.total == 0) {
      status = 'Henüz kural tanımlanmamış';
    } else {
      status = '${vm.active} aktif / ${vm.total} kural';
    }

    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: 'Zamanlı otomasyon kuralları. $status',
      onTap: () => _open(context),
      child: InkWell(
        key: const Key('card_rules'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(context),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.cardDecoration(
            context,
            accent: vm.active > 0 ? cyan : null,
            radius: 16,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.schedule, color: readable, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Zamanlı Otomasyon Kuralları',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.getTextPrimary(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (loading) ...[
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            status,
                            key: const Key('text_rules_status'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: failed
                                  ? AppTheme.warningText(context)
                                  : (vm.active > 0 ? readable : AppTheme.getTextMuted(context)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Işıklar ve panjurlar için otomatik açma/kapama saatleri belirleyin',
                      style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppTheme.getTextMuted(context)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ScheduledRulesPage()),
    );
    if (mounted) unawaited(_load());
  }
}
