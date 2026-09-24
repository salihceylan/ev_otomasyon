import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/scheduled_rule_model.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

/// Zamanlı Otomasyon Kuralları Sayfası
/// Daire admini kanallara saat bazlı otomatik açma/kapama kuralları tanımlar.
class ScheduledRulesPage extends StatefulWidget {
  const ScheduledRulesPage({super.key});

  @override
  State<ScheduledRulesPage> createState() => _ScheduledRulesPageState();
}

class _ScheduledRulesPageState extends State<ScheduledRulesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AutomationState>().fetchScheduledRules();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final isAdmin = !state.isMember && !state.isGuest;

    return Scaffold(
      backgroundColor: Colors.transparent,
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
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Zamanlı Kurallar',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Yeni Kural Ekle',
              onPressed: () => _showAddRuleDialog(context, state),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Yenile',
            onPressed: () => state.fetchScheduledRules(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: state.fetchScheduledRules,
        color: AppTheme.primaryBlue,
        child: _buildBody(context, state, isAdmin),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AutomationState state, bool isAdmin) {
    if (state.scheduledRulesLoading && state.scheduledRules.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.scheduledRules.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule, size: 64, color: AppTheme.textMuted.withValues(alpha: 0.4)),
                const SizedBox(height: 16),
                Text(
                  'Henüz zamanlı kural yok',
                  style: TextStyle(fontSize: 16, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 8),
                Text(
                  isAdmin
                      ? 'Sağ üstteki + butonuyla kural ekleyebilirsiniz.'
                      : 'Yönetici henüz kural tanımlamamış.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppTheme.textMuted.withValues(alpha: 0.7)),
                ),
                if (isAdmin) ...[
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: () => _showAddRuleDialog(context, state),
                    icon: const Icon(Icons.add),
                    label: const Text('İlk Kuralı Ekle'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: state.scheduledRules.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) => _buildRuleCard(ctx, state, state.scheduledRules[i], isAdmin),
    );
  }

  Widget _buildRuleCard(BuildContext context, AutomationState state, ScheduledRule rule, bool isAdmin) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: rule.enabled
              ? rule.actionColor.withValues(alpha: 0.4)
              : AppTheme.getCardBorder(context),
        ),
        boxShadow: rule.enabled
            ? [
                BoxShadow(
                  color: rule.actionColor.withValues(alpha: 0.08),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: rule.enabled
                ? rule.actionColor.withValues(alpha: 0.15)
                : AppTheme.getCardBorder(context).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            rule.actionIcon,
            color: rule.enabled ? rule.actionColor : AppTheme.textMuted,
            size: 22,
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                rule.channelLabel,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: AppTheme.getTextPrimary(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: rule.actionColor.withValues(alpha: rule.enabled ? 0.2 : 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                rule.actionLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: rule.enabled ? rule.actionColor : AppTheme.textMuted,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.access_time, size: 13, color: AppTheme.getTextMuted(context)),
              const SizedBox(width: 4),
              Text(
                rule.timeString,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: rule.enabled ? AppTheme.primaryBlueLight : AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  rule.daysShortString,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.getTextMuted(context),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: rule.enabled,
              onChanged: isAdmin
                  ? (val) async {
                      try {
                        await state.updateScheduledRule(rule.id, {'enabled': val});
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
                          );
                        }
                      }
                    }
                  : null,
              activeThumbColor: rule.actionColor,
            ),
            if (isAdmin)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (val) async {
                  if (val == 'edit') {
                    _showEditRuleDialog(context, state, rule);
                  } else if (val == 'delete') {
                    _confirmDelete(context, state, rule);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit, size: 16), SizedBox(width: 8), Text('Düzenle')])),
                  const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8), Text('Sil', style: TextStyle(color: Colors.red))])),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, AutomationState state, ScheduledRule rule) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.getCardColor(context),
        title: const Text('Kural Silinsin mi?'),
        content: Text('${rule.channelLabel} → ${rule.actionLabel} (${rule.timeString}) kuralı silinecek.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await state.deleteScheduledRule(rule.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Kural silindi'), backgroundColor: Colors.green),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Silinemedi: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showAddRuleDialog(BuildContext context, AutomationState state) {
    _showRuleDialog(context, state, null);
  }

  void _showEditRuleDialog(BuildContext context, AutomationState state, ScheduledRule rule) {
    _showRuleDialog(context, state, rule);
  }

  void _showRuleDialog(BuildContext context, AutomationState state, ScheduledRule? existing) {
    showDialog(
      context: context,
      builder: (ctx) => _RuleDialog(state: state, existing: existing),
    );
  }
}

/// Kural Ekleme / Düzenleme Diyalogu
class _RuleDialog extends StatefulWidget {
  final AutomationState state;
  final ScheduledRule? existing;

  const _RuleDialog({required this.state, this.existing});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late int _channel;
  late String _channelType;
  late String _action;
  late TimeOfDay _time;
  late List<int> _daysOfWeek;
  late TextEditingController _labelCtrl;
  bool _saving = false;

  final List<_ChannelOption> _channelOptions = [
    _ChannelOption(channel: 0, type: 'relay', label: 'Röle 1 (Işık/Prizmat)'),
    _ChannelOption(channel: 1, type: 'relay', label: 'Röle 2'),
    _ChannelOption(channel: 2, type: 'relay', label: 'Röle 3'),
    _ChannelOption(channel: 3, type: 'relay', label: 'Röle 4'),
    _ChannelOption(channel: 0, type: 'shutter', label: 'Panjur 1'),
    _ChannelOption(channel: 1, type: 'shutter', label: 'Panjur 2'),
    _ChannelOption(channel: 2, type: 'shutter', label: 'Panjur 3'),
    _ChannelOption(channel: 3, type: 'shutter', label: 'Panjur 4'),
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _channel = e?.channel ?? 0;
    _channelType = e?.channelType ?? 'relay';
    _action = e?.action ?? 'off';
    _time = e != null ? TimeOfDay(hour: e.hour, minute: e.minute) : TimeOfDay.now();
    _daysOfWeek = e?.daysOfWeek.toList() ?? [0, 1, 2, 3, 4, 5, 6];
    _labelCtrl = TextEditingController(text: e?.label ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  String get _currentChannelLabel {
    final opt = _channelOptions.firstWhere(
      (o) => o.channel == _channel && o.type == _channelType,
      orElse: () => _ChannelOption(channel: _channel, type: _channelType, label: '$_channelType $_channel'),
    );
    return opt.label;
  }

  List<String> get _availableActions {
    return _channelType == 'shutter' ? ['open', 'close'] : ['on', 'off'];
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return AlertDialog(
      backgroundColor: AppTheme.getCardColor(context),
      title: Text(isEdit ? 'Kural Düzenle' : 'Yeni Kural Ekle'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Kanal seçimi (sadece yeni kural için değiştirilebilir)
              _SectionLabel('Kanal'),
              if (!isEdit)
                DropdownButtonFormField<String>(
                  initialValue: '${_channelType}_$_channel',
                  dropdownColor: AppTheme.getCardColor(context),
                  decoration: _inputDec(),
                  items: _channelOptions.map((o) => DropdownMenuItem(
                    value: '${o.type}_${o.channel}',
                    child: Text(o.label),
                  )).toList(),
                  onChanged: (val) {
                    if (val == null) return;
                    final parts = val.split('_');
                    setState(() {
                      _channelType = parts[0];
                      _channel = int.parse(parts[1]);
                      // Eylemi sıfırla
                      _action = _channelType == 'shutter' ? 'close' : 'off';
                    });
                  },
                )
              else
                Text(_currentChannelLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryBlueLight)),

              const SizedBox(height: 12),

              // Eylem
              _SectionLabel('Eylem'),
              Row(
                children: _availableActions.map((a) {
                  final label = _actionLabel(a);
                  final color = _actionColor(a);
                  final selected = _action == a;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => setState(() => _action = a),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: selected ? color.withValues(alpha: 0.2) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: selected ? color : AppTheme.getCardBorder(context)),
                          ),
                          child: Center(
                            child: Text(
                              label,
                              style: TextStyle(
                                color: selected ? color : AppTheme.getTextMuted(context),
                                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 12),

              // Saat
              _SectionLabel('Saat'),
              InkWell(
                onTap: () async {
                  final picked = await showTimePicker(context: context, initialTime: _time);
                  if (picked != null) setState(() => _time = picked);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.access_time, color: AppTheme.primaryBlue, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryBlueLight,
                        ),
                      ),
                      const Spacer(),
                      Text('değiştir', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Günler
              _SectionLabel('Günler'),
              Wrap(
                spacing: 6,
                children: List.generate(7, (i) {
                  final selected = _daysOfWeek.contains(i);
                  const dayShort = ['Paz', 'Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt'];
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        if (selected) {
                          if (_daysOfWeek.length > 1) _daysOfWeek.remove(i);
                        } else {
                          _daysOfWeek.add(i);
                          _daysOfWeek.sort();
                        }
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: selected ? AppTheme.primaryBlue.withValues(alpha: 0.25) : Colors.transparent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? AppTheme.primaryBlue : AppTheme.getCardBorder(context),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          dayShort[i],
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: selected ? AppTheme.primaryBlueLight : AppTheme.getTextMuted(context),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 12),

              // İsteğe bağlı etiket
              _SectionLabel('Etiket (opsiyonel)'),
              TextField(
                controller: _labelCtrl,
                decoration: _inputDec(hint: 'ör. Salon Panjuru Gece Kapanışı'),
                maxLength: 80,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
          ),
          onPressed: _saving ? null : () => _save(context),
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(isEdit ? 'Güncelle' : 'Ekle'),
        ),
      ],
    );
  }

  InputDecoration _inputDec({String? hint}) => InputDecoration(
    hintText: hint,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    counterText: '',
    filled: true,
    fillColor: AppTheme.bgDark.withValues(alpha: 0.3),
  );

  String _actionLabel(String a) {
    switch (a) {
      case 'on': return 'Aç';
      case 'off': return 'Kapat';
      case 'open': return 'Aç';
      case 'close': return 'Kapat';
      default: return a;
    }
  }

  Color _actionColor(String a) {
    switch (a) {
      case 'on': return Colors.amber;
      case 'off': return Colors.blueGrey;
      case 'open': return Colors.greenAccent;
      case 'close': return Colors.deepOrangeAccent;
      default: return AppTheme.primaryBlue;
    }
  }

  Future<void> _save(BuildContext context) async {
    setState(() => _saving = true);
    try {
      final labelText = _labelCtrl.text.trim().isEmpty ? null : _labelCtrl.text.trim();

      if (widget.existing == null) {
        await widget.state.createScheduledRule(
          channel: _channel,
          channelType: _channelType,
          action: _action,
          hour: _time.hour,
          minute: _time.minute,
          daysOfWeek: _daysOfWeek,
          label: labelText,
        );
      } else {
        await widget.state.updateScheduledRule(widget.existing!.id, {
          'action': _action,
          'hour': _time.hour,
          'minute': _time.minute,
          'days_of_week': _daysOfWeek,
          'label': labelText,
        });
      }

      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.existing == null ? 'Kural eklendi ✓' : 'Kural güncellendi ✓'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ChannelOption {
  final int channel;
  final String type;
  final String label;
  const _ChannelOption({required this.channel, required this.type, required this.label});
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppTheme.getTextMuted(context),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

