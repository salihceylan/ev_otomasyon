import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../pages/scheduled_rules_page.dart';
import '../../theme/app_theme.dart';
import '../../theme/feature_accent.dart';
import '../../theme/tokens.dart';
import '../orb/orb.dart';
import '../surface_card.dart';

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

    final readable = AppTheme.readableFamily(context, AppFeature.rules.accentFamily);
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
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => _open(context),
        child: SurfaceCard(
          accent: vm.active > 0 ? AppFeature.rules.accentFamily.base : null,
          active: vm.active > 0,
          child: Row(
            children: [
              // Bekleme yayını orb'un kendisi çizer (tema duyarlı yay rengi; diğer ayar kartlarıyla aynı hiza).
              OrbIconBadge(
                icon: Icons.schedule_rounded,
                family: AppFeature.rules.accentFamily,
                active: vm.active > 0,
                pending: loading,
                glow: true,
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
                    // Sayfa eager-build (serbest yükseklik): büyük yazıda açıklama kelime ortasından KESİLMEZ.
                    Text(
                      'Işıklar ve panjurlar için otomatik açma/kapama saatleri belirleyin',
                      style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppTheme.getTextMuted(context)),
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
