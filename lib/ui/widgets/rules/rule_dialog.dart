import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/scheduled_rule_model.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/app_dialogs.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../orb/orb.dart';
import 'rule_logic.dart';

/// Kural diyaloğunun sonucu: kayıt başarılı; liste de yenilendi mi?
enum RuleSaveOutcome {
  /// Kayıt yapıldı ve kural listesi başarıyla yeniden yüklendi.
  saved,

  /// Kayıt gönderildi ancak liste **yenilenemedi** (başarı iddia edilmez; kullanıcı yenilemeli).
  savedButListStale,
}

/// Kural ekleme / düzenleme diyaloğunu açar. Kayıt diyalog içinde yapılır (hata alanın altında
/// kalır, girdi kaybolmaz); iptalde `null` döner.
Future<RuleSaveOutcome?> showRuleDialog(BuildContext context, {ScheduledRule? existing}) {
  return showAppDialog<RuleSaveOutcome>(
    context,
    builder: (_) => RuleDialog(existing: existing),
  );
}

/// Zamanlı kural ekleme / düzenleme diyaloğu.
///
/// * Kanal seçenekleri evin **gerçek uç noktalarından** gelir (1 tabanlı; panjur çifti röleleri
///   "röle" listesinde yoktur).
/// * Aynı kanal/saat/gün için yinelenen ya da **ters eylemli** kural varsa uyarı gösterilir;
///   kaydetme düğmesi "Yine de Kaydet" olur.
/// * Saat, evin saat diliminde değerlendirilir; diyalog bunu belirtir.
///
/// Anahtarlar: `Key('dialog_rule')`, `Key('field_rule_channel')`, `Key('btn_rule_action_<eylem>')`,
/// `Key('btn_rule_time')`, `Key('btn_rule_day_<n>')`, `Key('field_rule_label')`,
/// `Key('banner_rule_conflict')`, `Key('text_rule_error')`, `Key('btn_save_rule')`,
/// `Key('btn_cancel_rule')`.
class RuleDialog extends StatefulWidget {
  const RuleDialog({super.key, this.existing});

  final ScheduledRule? existing;

  @override
  State<RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<RuleDialog> {
  late final List<RuleChannelOption> _options;
  RuleChannelOption? _option;
  late String _action;
  late TimeOfDay _time;
  late Set<int> _days;
  late final TextEditingController _labelCtrl;
  bool _saving = false;
  String? _error;

  // Hafta Pazartesi'den başlar; gün numaraları sunucu sözleşmesindedir (0=Pazar).
  static const List<int> _dayOrder = <int>[1, 2, 3, 4, 5, 6, 0];
  static const List<String> _dayShort = <String>['Paz', 'Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt'];

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _options = ruleChannelOptions(state.cloudEndpoints);
    final existing = widget.existing;
    if (existing != null) {
      RuleChannelOption? match;
      for (final option in _options) {
        if (option.type == existing.channelType && option.channel == existing.channel) match = option;
      }
      _option = match ??
          RuleChannelOption(
            type: existing.channelType,
            channel: existing.channel,
            label: '${existing.channelType == 'shutter' ? 'Panjur' : 'Röle'} ${existing.channel}',
            deviceId: existing.deviceId,
          );
      _action = existing.action;
      _time = TimeOfDay(hour: existing.hour, minute: existing.minute);
      _days = existing.daysOfWeek.toSet();
    } else {
      _option = _options.isEmpty ? null : _options.first;
      _action = _option == null ? 'off' : (_option!.isShutter ? 'close' : (_option!.impulse ? 'on' : 'off'));
      _time = TimeOfDay.now();
      _days = ScheduledRule.allDays.toSet();
    }
    _labelCtrl = TextEditingController(text: existing?.label ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  void _selectOption(String? id) {
    if (id == null) return;
    final option = _options.firstWhere((o) => o.id == id);
    setState(() {
      _option = option;
      // Eylemi yeni kanala uygun varsayılana sıfırla.
      _action = option.isShutter ? 'close' : (option.impulse ? 'on' : 'off');
      _error = null;
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null && mounted) setState(() => _time = picked);
  }

  List<RuleConflict> _conflicts() {
    final option = _option;
    if (option == null || _days.isEmpty) return const <RuleConflict>[];
    return findRuleConflicts(
      context.read<AutomationState>().scheduledRules,
      channelType: option.type,
      channel: option.channel,
      action: _action,
      hour: _time.hour,
      minute: _time.minute,
      daysOfWeek: _days.toList(),
      ignoreId: widget.existing?.id,
    );
  }

  Future<void> _save() async {
    final option = _option;
    if (option == null || _saving) return;
    final days = _days.toList()..sort();
    final validation = ScheduledRule.validate(
      channel: option.channel,
      channelType: option.type,
      action: _action,
      hour: _time.hour,
      minute: _time.minute,
      daysOfWeek: days,
    );
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    final state = context.read<AutomationState>();
    final label = _labelCtrl.text.trim().isEmpty ? null : _labelCtrl.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        await state.createScheduledRule(
          channel: option.channel,
          channelType: option.type,
          action: _action,
          hour: _time.hour,
          minute: _time.minute,
          daysOfWeek: days,
          label: label,
          deviceId: option.deviceId,
        );
      } else {
        await state.updateScheduledRule(existing.id, <String, dynamic>{
          'action': _action,
          'hour': _time.hour,
          'minute': _time.minute,
          'days_of_week': days,
          'label': label,
        });
      }
      if (!mounted) return;
      // Kayıttan sonra liste yeniden yüklenir: yenileme başarısızsa başarı iddia edilmez.
      Navigator.of(context).pop(
        state.scheduledRulesError == null ? RuleSaveOutcome.saved : RuleSaveOutcome.savedButListStale,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e, fallback: 'Kural kaydedilemedi. Lütfen tekrar deneyin.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final option = _option;
    final conflicts = _conflicts();
    final timezone = homeTimezoneLabel(state.activeHome?.timezone ?? '');
    final muted = AppTheme.getTextMuted(context);

    Widget sectionLabel(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 6, top: 12),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: muted,
            ),
          ),
        );

    return AlertDialog(
      key: const Key('dialog_rule'),
      backgroundColor: AppTheme.getSurfaceColor(context),
      title: Text(_isEdit ? 'Kural Düzenle' : 'Yeni Kural Ekle'),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              sectionLabel('Kanal'),
              if (_isEdit)
                Text(
                  option?.label ?? '',
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.infoText(context)),
                )
              else if (_options.isEmpty)
                Text(
                  'Kontrol edilebilir kanal bulunamadı. Cihazlar yüklenmemiş olabilir; ana ekranda '
                  'yenileyip tekrar deneyin.',
                  key: const Key('text_rule_no_channels'),
                  style: TextStyle(fontSize: 12.5, color: AppTheme.warningText(context)),
                )
              else
                DropdownButtonFormField<String>(
                  key: const Key('field_rule_channel'),
                  initialValue: option?.id,
                  isExpanded: true,
                  dropdownColor: AppTheme.getSurfaceColor(context),
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    for (final o in _options)
                      DropdownMenuItem<String>(
                        value: o.id,
                        child: Text(o.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _selectOption,
                ),
              sectionLabel('Eylem'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final action in option?.actions ?? const <String>['on', 'off'])
                    ChoiceChip(
                      key: Key('btn_rule_action_$action'),
                      label: Text(option?.actionLabel(action) ?? action),
                      selected: _action == action,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (_) => setState(() => _action = action),
                    ),
                ],
              ),
              sectionLabel('Saat'),
              InkWell(
                key: const Key('btn_rule_time'),
                onTap: _pickTime,
                borderRadius: BorderRadius.circular(AppRadius.r16),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppFamilies.sky.base.withValues(alpha: 0.16),
                        AppFamilies.cyan.base.withValues(alpha: 0.06),
                      ],
                    ),
                    border: Border.all(color: AppFamilies.sky.base.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(AppRadius.r16),
                  ),
                  // Dar ekran / büyük yazı: saat küçülür, "değiştir" ipucu sığmazsa kısalır (taşma yok).
                  child: Row(
                    children: [
                      const OrbIconBadge(icon: Icons.schedule_rounded, family: AppFamilies.cyan, active: true),
                      const SizedBox(width: 10),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
                            key: const Key('text_rule_time'),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.infoText(context),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: Text(
                            'değiştir',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Saat, evinizin saat dilimine göre çalışır: $timezone',
                key: const Key('text_rule_timezone'),
                style: TextStyle(fontSize: AppText.badge, color: muted),
              ),
              sectionLabel('Günler'),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final day in _dayOrder)
                    FilterChip(
                      key: Key('btn_rule_day_$day'),
                      label: Text(_dayShort[day]),
                      selected: _days.contains(day),
                      showCheckmark: false,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _days.add(day);
                        } else if (_days.length > 1) {
                          _days.remove(day);
                        }
                      }),
                    ),
                ],
              ),
              sectionLabel('Etiket (opsiyonel)'),
              TextField(
                key: const Key('field_rule_label'),
                controller: _labelCtrl,
                maxLength: 80,
                decoration: const InputDecoration(
                  hintText: 'ör. Salon Panjuru Gece Kapanışı',
                  isDense: true,
                  counterText: '',
                ),
              ),
              if (conflicts.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ConflictBanner(conflicts: conflicts),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('text_rule_error'),
                  style: TextStyle(fontSize: 12.5, color: AppTheme.dangerText(context)),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_cancel_rule'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(
          key: const Key('btn_save_rule'),
          onPressed: (_saving || option == null) ? null : () => unawaited(_save()),
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  conflicts.isNotEmpty ? 'Yine de Kaydet' : (_isEdit ? 'Güncelle' : 'Ekle'),
                ),
        ),
      ],
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.conflicts});

  final List<RuleConflict> conflicts;

  @override
  Widget build(BuildContext context) {
    final warn = AppTheme.warningText(context);
    final opposite = conflicts.any((c) => c.kind == RuleConflictKind.opposite);
    return Container(
      key: const Key('banner_rule_conflict'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.accentAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.r12),
        border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              opposite
                  ? 'Aynı kanal için aynı saatte ters eylemli bir kural var (aç ↔ kapat); sonuç '
                      'belirsiz olabilir.'
                  : 'Aynı kanal, saat ve eylem için bir kural zaten var; bu kural yinelenecek.',
              style: TextStyle(fontSize: 12, color: warn, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
