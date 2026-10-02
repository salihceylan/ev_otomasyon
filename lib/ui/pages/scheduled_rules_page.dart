import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/scheduled_rule_model.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../dashboard/dashboard_states.dart';
import '../theme/app_theme.dart';
import '../widgets/rules/rule_dialog.dart';
import '../widgets/rules/rule_logic.dart';

typedef _RulesVm = ({
  String signature,
  bool loading,
  String? error,
  bool canManage,
  bool cloud,
  String timezone,
});

/// Zamanlı Otomasyon Kuralları sayfası.
///
/// * Kural **yüklenemedi** ile **kural yok** ayrıdır (`scheduledRulesError`): hata durumunda
///   "Yüklenemedi, tekrar dene" gösterilir; yalnızca başarılı boş yanıtta "Henüz kural yok".
/// * Ekleme/düzenleme/silme `canManageRules` yetkisine bağlıdır (kapı `Capabilities`'ten).
/// * Evin saat dilimi (`home.timezone`) gösterilir; kurallar o dilimde çalışır.
/// * Kayıt sonrası liste yeniden yüklenemezse başarı iddia edilmez.
/// * Hatalar `friendlyError` ile gösterilir.
///
/// Anahtarlar: `Key('btn_add_rule')`, `Key('nav_refresh')`, `Key('card_rule_<kimlik>')`,
/// `Key('switch_rule_<kimlik>')`, `Key('menu_rule_<kimlik>')`, `Key('btn_rule_edit_<kimlik>')`,
/// `Key('btn_rule_delete_<kimlik>')`, `Key('text_rules_timezone')`, `Key('view_rules_empty')`,
/// `Key('banner_rules_stale')`.
class ScheduledRulesPage extends StatefulWidget {
  const ScheduledRulesPage({super.key});

  @override
  State<ScheduledRulesPage> createState() => _ScheduledRulesPageState();
}

class _ScheduledRulesPageState extends State<ScheduledRulesPage> {
  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final state = context.read<AutomationState>();
    await state.fetchScheduledRules();
    if (mounted) setState(() => _loadedOnce = true);
  }

  static String _signature(List<ScheduledRule> rules) => rules
      .map((r) => '${r.id}|${r.enabled}|${r.action}|${r.hour}:${r.minute}|${r.daysOfWeek.join()}|${r.label}')
      .join(';');

  void _snack(String message, {SnackBarAction? action, bool warning = false}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: warning ? AppTheme.accentAmber : null,
          action: action,
          duration: Duration(seconds: action == null ? 3 : 8),
        ),
      );
  }

  Future<void> _openDialog({ScheduledRule? existing}) async {
    final outcome = await showRuleDialog(context, existing: existing);
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case RuleSaveOutcome.saved:
        _snack(existing == null ? 'Kural eklendi' : 'Kural güncellendi');
      case RuleSaveOutcome.savedButListStale:
        _snack(
          'Kural kaydedildi ancak liste yenilenemedi. Güncel durumu görmek için yenileyin.',
          warning: true,
          action: SnackBarAction(label: 'Yenile', onPressed: () => unawaited(_load())),
        );
    }
  }

  Future<void> _toggle(ScheduledRule rule, bool enabled) async {
    final state = context.read<AutomationState>();
    try {
      await state.updateScheduledRule(rule.id, <String, dynamic>{'enabled': enabled});
    } catch (e) {
      if (mounted) showFriendlyError(context, e, fallback: 'Kural güncellenemedi. Lütfen tekrar deneyin.');
      return;
    }
    if (state.scheduledRulesError != null) {
      _snack(
        'Değişiklik gönderildi ancak liste yenilenemedi. Güncel durumu görmek için yenileyin.',
        warning: true,
        action: SnackBarAction(label: 'Yenile', onPressed: () => unawaited(_load())),
      );
    }
  }

  Future<void> _confirmDelete(ScheduledRule rule, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('dialog_delete_rule'),
        title: const Text('Kural silinsin mi?'),
        content: Text('$name → ${rule.actionLabel} (${rule.timeString}) kuralı silinecek.'),
        actions: [
          TextButton(
            key: const Key('btn_cancel_delete_rule'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('İptal'),
          ),
          TextButton(
            key: const Key('btn_confirm_delete_rule'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.dangerText(ctx)),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final state = context.read<AutomationState>();
    try {
      await state.deleteScheduledRule(rule.id);
      _snack('Kural silindi');
    } catch (e) {
      if (mounted) showFriendlyError(context, e, fallback: 'Kural silinemedi. Lütfen tekrar deneyin.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _RulesVm>(
      (s) => (
        signature: _signature(s.scheduledRules),
        loading: s.scheduledRulesLoading,
        error: s.scheduledRulesError,
        canManage: s.capabilities.canManageRules,
        cloud: s.mode == AppMode.cloud,
        timezone: s.activeHome?.timezone ?? '',
      ),
    );
    final state = context.read<AutomationState>();
    final rules = state.scheduledRules;
    final options = ruleChannelOptions(state.cloudEndpoints);

    Widget body;
    if (!vm.cloud) {
      body = const InfoCard(
        cardKey: Key('view_rules_cloud_only'),
        icon: Icons.cloud_off_outlined,
        title: 'Bulut modu gerekir',
        message: 'Zamanlı kurallar sunucuda çalışır. Kuralları yönetmek için bulut moduna geçin.',
      );
    } else if ((!_loadedOnce || vm.loading) && rules.isEmpty && vm.error == null) {
      body = TimedLoadingView(
        message: 'Kurallar yükleniyor…',
        onRetry: () => unawaited(_load()),
      );
    } else if (vm.error != null && rules.isEmpty) {
      body = ErrorRetryCard(
        title: 'Kurallar yüklenemedi',
        message: vm.error!,
        onRetry: () => unawaited(_load()),
      );
    } else if (rules.isEmpty) {
      body = _EmptyRules(canManage: vm.canManage, onAdd: () => unawaited(_openDialog()));
    } else {
      body = Column(
        children: [
          if (vm.error != null) _StaleBanner(message: vm.error!, onRetry: () => unawaited(_load())),
          for (final rule in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RuleCard(
                rule: rule,
                name: ruleChannelName(rule, options),
                canManage: vm.canManage,
                onToggle: (value) => unawaited(_toggle(rule, value)),
                onEdit: () => unawaited(_openDialog(existing: rule)),
                onDelete: () => unawaited(_confirmDelete(rule, ruleChannelName(rule, options))),
              ),
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_logo.png',
                width: 28,
                height: 28,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.schedule, size: 24),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Zamanlı Kurallar',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (vm.canManage && vm.cloud)
            IconButton(
              key: const Key('btn_add_rule'),
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Yeni Kural Ekle',
              onPressed: () => unawaited(_openDialog()),
            ),
          IconButton(
            key: const Key('nav_refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Yenile',
            onPressed: () => unawaited(_load()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryBlue,
        child: ListView(
          key: const Key('view_rules'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (vm.cloud) _TimezoneNote(timezone: vm.timezone),
            body,
          ],
        ),
      ),
    );
  }
}

class _TimezoneNote extends StatelessWidget {
  const _TimezoneNote({required this.timezone});

  final String timezone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.public, size: 16, color: AppTheme.getTextMuted(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Kurallar evinizin saat dilimine göre çalışır: ${homeTimezoneLabel(timezone)}',
              key: const Key('text_rules_timezone'),
              style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final warn = AppTheme.warningText(context);
    return Container(
      key: const Key('banner_rules_stale'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentAmber, radius: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Liste güncellenemedi; son bilinen kurallar gösteriliyor. $message',
              style: TextStyle(fontSize: 12, color: warn),
            ),
          ),
          TextButton(
            key: const Key('btn_retry'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            child: const Text('Tekrar dene'),
          ),
        ],
      ),
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules({required this.canManage, required this.onAdd});

  final bool canManage;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('view_rules_empty'),
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 64, color: AppTheme.getTextMuted(context).withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            'Henüz zamanlı kural yok',
            style: TextStyle(fontSize: 16, color: AppTheme.getTextMuted(context)),
          ),
          const SizedBox(height: 8),
          Text(
            canManage
                ? 'Sağ üstteki + düğmesiyle kural ekleyebilirsiniz.'
                : 'Ev sahibi henüz kural tanımlamamış.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(context)),
          ),
          if (canManage) ...[
            const SizedBox(height: 20),
            ElevatedButton.icon(
              key: const Key('btn_add_first_rule'),
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('İlk Kuralı Ekle'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(48, 48),
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.name,
    required this.canManage,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final ScheduledRule rule;

  /// Kanalın okunur adı (uç noktadan; yoksa "Röle N").
  final String name;
  final bool canManage;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final color = rule.actionColor;
    final readable = AppTheme.readableAccent(context, color);
    final title = (rule.label != null && rule.label!.isNotEmpty) ? rule.label! : name;
    final typeName = rule.channelType == 'shutter' ? 'Panjur' : 'Röle';
    final muted = AppTheme.getTextMuted(context);

    final leading = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: rule.enabled ? color.withValues(alpha: 0.15) : AppTheme.getInsetColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        rule.actionIcon,
        color: rule.enabled ? readable : muted,
        size: 22,
      ),
    );

    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: AppTheme.getTextPrimary(context),
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          '$typeName ${rule.channel} • ${rule.actionLabel}',
          style: TextStyle(fontSize: 11.5, color: muted),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.access_time, size: 13, color: muted),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    rule.timeString,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: rule.enabled ? AppTheme.infoText(context) : muted,
                    ),
                  ),
                ),
              ],
            ),
            Text(rule.daysShortString, style: TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      ],
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Anahtarın kendi etiketi olur (ekran okuyucu "<kural> kuralı, açık/kapalı" der).
        MergeSemantics(
          child: Semantics(
            label: '$title kuralı, ${rule.timeString}',
            child: Switch(
              key: Key('switch_rule_${rule.id}'),
              value: rule.enabled,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              activeThumbColor: color,
              onChanged: canManage ? onToggle : null,
            ),
          ),
        ),
        if (canManage)
          PopupMenuButton<String>(
            key: Key('menu_rule_${rule.id}'),
            tooltip: '$title kuralı işlemleri',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) {
              if (value == 'edit') onEdit();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                key: Key('btn_rule_edit_${rule.id}'),
                value: 'edit',
                height: 48,
                child: const Row(
                  children: [Icon(Icons.edit, size: 18), SizedBox(width: 8), Text('Düzenle')],
                ),
              ),
              PopupMenuItem<String>(
                key: Key('btn_rule_delete_${rule.id}'),
                value: 'delete',
                height: 48,
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18, color: AppTheme.dangerText(context)),
                    const SizedBox(width: 8),
                    Text('Sil', style: TextStyle(color: AppTheme.dangerText(context))),
                  ],
                ),
              ),
            ],
          ),
      ],
    );

    return Container(
      key: Key('card_rule_${rule.id}'),
      decoration: AppTheme.cardDecoration(context, accent: rule.enabled ? color : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Dar ekran / büyük yazı: anahtar ve menü alt satıra iner (metin sütunu daralmaz).
            final compact = constraints.maxWidth < 330 || MediaQuery.textScalerOf(context).scale(10) > 12;
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [leading, const SizedBox(width: 12), Expanded(child: texts)],
                  ),
                  Align(alignment: AlignmentDirectional.centerEnd, child: actions),
                ],
              );
            }
            return Row(
              children: [leading, const SizedBox(width: 12), Expanded(child: texts), actions],
            );
          },
        ),
      ),
    );
  }
}
