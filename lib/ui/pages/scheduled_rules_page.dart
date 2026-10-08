import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/scheduled_rule_model.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../dashboard/dashboard_states.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../widgets/settings/accent_button.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/rules/rule_dialog.dart';
import '../widgets/rules/rule_logic.dart';
import '../widgets/orb/orb.dart';
import '../widgets/surface_card.dart';

typedef _RulesVm = ({String signature, bool loading, String? error, bool canManage, bool cloud, String timezone});

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
      .map((r) =>
          '${r.id}|${r.enabled}|${r.action}|${r.hour}:${r.minute}|${r.daysOfWeek.join()}|${r.label}|${r.creatorActive}')
      .join(';');

  void _snack(String message, {SnackBarAction? action, bool warning = false}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // Uyarı: ham amber ZEMİN (beyaz metinle ≈2.1:1, eylem rengi de okunmazdı) yerine tema'nın koyu iletisi +
          // amber uyarı simgesi.
          content: warning
              ? Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: AppFamilies.amber.light, size: 20),
                    const SizedBox(width: 10),
                    Flexible(child: Text(message)),
                  ],
                )
              : Text(message),
          behavior: SnackBarBehavior.floating,
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
    // Ortak onay kabuğu (rose orb başlık + hap eylemler; "Sil" artık çıplak metin düğmesi değil, yıkıcı gradyan hap).
    // Anahtarlar/metinler aynen (testlerle pinli).
    final confirmed = await showSimpleConfirm(
      context,
      title: 'Kural silinsin mi?',
      message: '$name → ${rule.actionLabel} (${rule.timeString}) kuralı silinecek.',
      confirmLabel: 'Sil',
      cancelLabel: 'İptal',
      destructive: true,
      icon: Icons.delete_outline_rounded,
      dialogKey: const Key('dialog_delete_rule'),
      cancelKey: const Key('btn_cancel_delete_rule'),
      confirmKey: const Key('btn_confirm_delete_rule'),
    );
    if (!confirmed || !mounted) return;
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
    final String bodyState;
    if (!vm.cloud) {
      bodyState = 'cloud_only';
      body = const InfoCard(
        cardKey: Key('view_rules_cloud_only'),
        icon: Icons.cloud_off_outlined,
        title: 'Bulut modu gerekir',
        message: 'Zamanlı kurallar sunucuda çalışır. Kuralları yönetmek için bulut moduna geçin.',
      );
    } else if ((!_loadedOnce || vm.loading) && rules.isEmpty && vm.error == null) {
      bodyState = 'loading';
      body = TimedLoadingView(message: 'Kurallar yükleniyor…', onRetry: () => unawaited(_load()));
    } else if (vm.error != null && rules.isEmpty) {
      bodyState = 'error';
      body = ErrorRetryCard(title: 'Kurallar yüklenemedi', message: vm.error!, onRetry: () => unawaited(_load()));
    } else if (rules.isEmpty) {
      bodyState = 'empty';
      body = _EmptyRules(canManage: vm.canManage, onAdd: () => unawaited(_openDialog()));
    } else {
      bodyState = 'content';
      body = Column(
        children: [
          if (vm.error != null)
            StaggeredEntrance(
              key: const ValueKey<String>('enter_rules_stale'),
              index: 0,
              offset: 8,
              child: _StaleBanner(message: vm.error!, onRetry: () => unawaited(_load())),
            ),
          for (final (i, rule) in rules.indexed)
            StaggeredEntrance(
              key: ValueKey<String>('enter_rule_${rule.id}'),
              index: i,
              child: Padding(
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
            ),
          // Kapalı / çalışmayan kural varken (kullanim-5): kuranın erişimi biterse kural çalışmaz; düzenleyip kaydeden üstlenir.
          if (rules.any((r) => !r.enabled || !r.creatorActive))
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Kuralı oluşturan kişinin erişimi sona erdiyse kural çalışmaz; kaydederseniz sizin adınıza çalışır.',
                key: const Key('hint_rule_creator'),
                style: TextStyle(fontSize: 12, height: 1.35, color: AppTheme.getTextMuted(context)),
              ),
            ),
        ],
      );
    }

    return Scaffold(
      // Ortak Neon Glass üst çubuk: geri diski + özellik orb'u + başlık + cam disk eylemler (çıplak ⊕/↻ yok). İpucu
      // işaretçi kullanıcıları içindir; anlamsal etiketi düğmenin kendisi verir (çift okuma olmasın).
      appBar: NeonAppBar(
        title: 'Zamanlı Kurallar',
        feature: AppFeature.rules,
        icon: Icons.schedule_rounded,
        actions: [
          if (vm.canManage && vm.cloud)
            NeonBarAction(
              key: const Key('btn_add_rule'),
              icon: Icons.add_rounded,
              tooltip: 'Yeni Kural Ekle',
              onTap: () => unawaited(_openDialog()),
            ),
          NeonBarAction(
            key: const Key('nav_refresh'),
            icon: Icons.refresh_rounded,
            tooltip: 'Yenile',
            onTap: () => unawaited(_load()),
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
            StateSwitcher(stateKey: bodyState, child: body),
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
    return SurfaceCard(
      key: const Key('banner_rules_stale'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      accent: AppFamilies.amber.base,
      radius: AppRadius.r16,
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
          // Boş durum orb'u DEVRE DIŞI (mat gri) değil, özellik renginde (kurallar = cyan) ve yumuşak parıltılıdır: gri orb
          // "kullanılamaz" anlamı taşıyıp hemen altındaki "İlk Kuralı Ekle" çağrısını zayıflatıyordu. Sakin kalsın diye
          // `active: false` (nabız/halka yok).
          OrbIconBadge(
            icon: Icons.schedule_rounded,
            family: AppFeature.rules.accentFamily,
            size: OrbSize.xl,
            glow: true,
          ),
          const SizedBox(height: 16),
          Text(
            'Henüz zamanlı kural yok',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.getTextMuted(context)),
          ),
          const SizedBox(height: 8),
          Text(
            canManage ? 'Sağ üstteki + düğmesiyle kural ekleyebilirsiniz.' : 'Ev sahibi henüz kural tanımlamamış.',
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
              style: accentButtonStyle(null),
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
    // Eylemin Neon Glass ailesi (aç=amber, kapat=slate, panjur aç=emerald, panjur kapat=sky): orb, çip ve kart
    // vurgusu aynı aileden türer (ham Material aksanları yok).
    final family = rule.family;
    final title = (rule.label != null && rule.label!.isNotEmpty) ? rule.label! : name;
    final typeName = rule.channelType == 'shutter' ? 'Panjur' : 'Röle';
    final muted = AppTheme.getTextMuted(context);

    final leading = OrbIconBadge(icon: rule.actionIcon, family: family, enabled: rule.enabled, active: rule.enabled);

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.getTextPrimary(context)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text('$typeName ${rule.channel} • ${rule.actionLabel}', style: TextStyle(fontSize: 12, color: muted)),
      ],
    );

    final detail = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const SizedBox(height: 8),
        _DayChips(days: rule.daysOfWeek, family: family, enabled: rule.enabled),
        if (!rule.creatorActive) ...[
          const SizedBox(height: 8),
          Row(
            key: Key('note_rule_creator_${rule.id}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.warningText(context)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Çalışmıyor: kuralı kuranın erişimi bitti. Düzenleyip kaydederek kuralı üstlenin.',
                  style: TextStyle(fontSize: 12, height: 1.35, fontWeight: FontWeight.w600, color: AppTheme.warningText(context)),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    // Anahtarın kendi etiketi olur (ekran okuyucu "<kural> kuralı, açık/kapalı" der). Başparmak/iz rengi TEMADAN
    // gelir (ham eylem renginde başparmak zümrüt izde ≈1.1–1.7:1 kontrast veriyordu).
    final toggle = MergeSemantics(
      child: Semantics(
        label: '$title kuralı, ${rule.timeString}',
        child: Switch(
          key: Key('switch_rule_${rule.id}'),
          value: rule.enabled,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onChanged: canManage ? onToggle : null,
        ),
      ),
    );

    final menu = canManage ? _RuleMenuButton(ruleId: rule.id, title: title, onEdit: onEdit, onDelete: onDelete) : null;

    return SurfaceCard(
      key: Key('card_rule_${rule.id}'),
      accent: rule.enabled ? family.base : null,
      active: rule.enabled,
      // Yatay 16: diğer ayar kartlarıyla aynı iç boşluk (orb sütunu hizalı).
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Çok dar ekran / büyük yazı: anahtar ve menü alt satıra iner (metin sütunu daralmaz). Normal telefonda
          // (360 dp, 1.0–1.15 ölçek) tek başlık satırı: orb | başlık | anahtar | ⋮ ; zaman ve gün çipleri altta
          // tam genişlikte (başlık sütunuyla aynı sol hizada).
          final compact = constraints.maxWidth < 280 || MediaQuery.textScalerOf(context).scale(10) > 11.5;
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [titleBlock, const SizedBox(height: 4), detail],
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [toggle, ?menu]),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(child: titleBlock),
                  toggle,
                  ?menu,
                ],
              ),
              Padding(
                padding: EdgeInsetsDirectional.only(start: OrbSize.sm.diameter + 12, top: 4),
                child: detail,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Kural işlemleri menüsü (Düzenle / Sil): cam disk düğme + açılır menü. Düz Material `IconButton`+`PopupMenuButton`
/// yerine pano üst çubuğuyla aynı [GlassIconButton] dili; menü öğeleri `Key('btn_rule_edit_<kimlik>')` /
/// `Key('btn_rule_delete_<kimlik>')` taşır.
class _RuleMenuButton extends StatelessWidget {
  const _RuleMenuButton({required this.ruleId, required this.title, required this.onEdit, required this.onDelete});

  final String ruleId;
  final String title;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  Future<void> _open(BuildContext buttonContext) async {
    final button = buttonContext.findRenderObject();
    final overlay = Overlay.maybeOf(buttonContext)?.context.findRenderObject();
    if (button is! RenderBox || overlay is! RenderBox || !button.attached) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final value = await showMenu<String>(
      context: buttonContext,
      position: position,
      items: [
        PopupMenuItem<String>(
          key: Key('btn_rule_edit_$ruleId'),
          value: 'edit',
          height: 48,
          child: const Row(children: [Icon(Icons.edit, size: 18), SizedBox(width: 8), Text('Düzenle')]),
        ),
        PopupMenuItem<String>(
          key: Key('btn_rule_delete_$ruleId'),
          value: 'delete',
          height: 48,
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: AppTheme.dangerText(buttonContext)),
              const SizedBox(width: 8),
              Text('Sil', style: TextStyle(color: AppTheme.dangerText(buttonContext))),
            ],
          ),
        ),
      ],
    );
    if (value == 'edit') onEdit();
    if (value == 'delete') onDelete();
  }

  @override
  Widget build(BuildContext context) {
    // Tooltip işaretçi kullanıcıları içindir; anlamsal etiketi düğmenin kendisi verir (çift okuma olmasın).
    return Tooltip(
      message: '$title kuralı işlemleri',
      excludeFromSemantics: true,
      child: Builder(
        builder: (buttonContext) => GlassIconButton(
          key: Key('menu_rule_$ruleId'),
          icon: Icons.more_vert_rounded,
          semanticLabel: '$title kuralı işlemleri',
          size: 40,
          haptic: PressHaptic.selection,
          onTap: () => unawaited(_open(buttonContext)),
        ),
      ),
    );
  }
}

/// Haftanın 7 günü (Pzt..Paz) küçük çipler: seçili günler kural renginde (aile) dolu. Görsel özettir; metin
/// özeti ([ScheduledRule.daysShortString]) ve anlamsal etiket ayrıdır.
///
/// Mürekkep rengi tahmini parlaklıkla DEĞİL **WCAG kontrastıyla** seçilir (beyaz / koyu mürekkepten yüksek olan:
/// turuncu üstünde beyaz 2.8:1'di). Devre dışı kuralın seçili günleri bulanık "çamur" dolgu yerine nötr zemin +
/// aile renkli kenar + okunur aile tonunda harf (≥ 4.5:1) ile çizilir. Çip yazı ölçeğiyle büyür (sabit 24 dp'de
/// büyük yazı taşardı).
class _DayChips extends StatelessWidget {
  const _DayChips({required this.days, required this.family, required this.enabled});

  final List<int> days;
  final AccentFamily family;
  final bool enabled;

  static const List<(int, String)> _order = [(1, 'P'), (2, 'S'), (3, 'Ç'), (4, 'P'), (5, 'C'), (6, 'C'), (0, 'P')];
  static const Color _darkInk = Color(0xFF0B1120);

  @override
  Widget build(BuildContext context) {
    final inset = AppTheme.getInsetColor(context);
    final dark = AppTheme.isDark(context);
    final muted = AppTheme.getTextMuted(context);
    final readable = AppTheme.readableAccent(context, family.base);
    final activeFill = family.base;
    final activeInk = wcagContrast(Colors.white, activeFill) >= wcagContrast(_darkInk, activeFill)
        ? Colors.white
        : _darkInk;
    final edge = dark ? family.base.withValues(alpha: 0.75) : family.deep;
    // Çip yazı ölçeğiyle ölçülenir ama en çok 30 dp: yedi çip 244 dp'lik sütuna TEK satırda sığar (büyük yazıda iki
    // satıra inip kartı şişirmesin; anahtar/menü ilk ekranda kalsın).
    final scaled = MediaQuery.textScalerOf(context).scale(12);
    final size = (scaled * 1.25).clamp(24.0, 30.0);

    return ExcludeSemantics(
      child: Wrap(
        spacing: 3,
        runSpacing: 4,
        children: [
          for (final (day, letter) in _order)
            Builder(
              builder: (context) {
                final on = days.contains(day);
                final Color fill;
                final Color ink;
                final Border? border;
                if (on && enabled) {
                  fill = activeFill;
                  ink = activeInk;
                  border = null;
                } else if (on) {
                  fill = inset;
                  ink = readable;
                  border = Border.all(color: edge, width: 1.5);
                } else {
                  fill = inset;
                  ink = muted;
                  // Seçili olmayan gün halkası haftanın hangi günlerinin DIŞARIDA kaldığını anlatır: ≥ 3:1 (alan
                  // çerçevesiyle aynı dil; dekoratif kart kenarı açıkta 1.4:1'di).
                  border = Border.all(color: AppTheme.getFieldBorder(context));
                }
                return Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: border),
                  child: Text(
                    letter,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ink, height: 1),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
