import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../common/confirm_dialogs.dart';
import '../../dashboard/close_all_lights_button.dart';
import '../../theme/app_theme.dart';
import '../peace_reminder_details.dart';
import '../push_status_tile.dart';
import 'settings_card.dart';

enum _Load { loading, ready, failed }

/// Gece huzur bildirimi kartı.
///
/// * Değerler `state.peaceSettings`'ten okunur (sunucunun `peace_notification_enabled/_time`
///   anahtarları çözülür). **Bilinmeyen durum "Aktif" gösterilmez**: "Durum alınıyor…" /
///   "Durum alınamadı" + yeniden dene.
/// * Kaydetme hataları yakalanır ve Türkçe mesajla gösterilir.
/// * Yalnızca bulut modunda ve `canChangeChildLock` yetkisiyle sayfada gösterilir (doğrudan modda gizli).
///
/// Anahtarlar: `Key('card_peace')`, `Key('switch_peace')`, `Key('btn_peace_time')`,
/// `Key('btn_peace_retry')`, `Key('text_peace_status')`.
class PeaceNotificationCard extends StatefulWidget {
  const PeaceNotificationCard({super.key});

  @override
  State<PeaceNotificationCard> createState() => _PeaceNotificationCardState();
}

class _PeaceNotificationCardState extends State<PeaceNotificationCard> {
  _Load _load = _Load.loading;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (context.read<AutomationState>().peaceSettings != null) _load = _Load.ready;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fetch());
    });
  }

  Future<void> _fetch() async {
    final state = context.read<AutomationState>();
    if (state.peaceSettings == null) setState(() => _load = _Load.loading);
    final data = await state.fetchPeaceNotification();
    if (!mounted) return;
    setState(() {
      _load = (data != null || state.peaceSettings != null) ? _Load.ready : _Load.failed;
    });
  }

  Future<void> _update({bool? enabled, String? time}) async {
    final state = context.read<AutomationState>();
    setState(() => _saving = true);
    try {
      await state.updatePeaceNotificationSettings(enabled: enabled, time: time);
    } catch (e) {
      if (mounted) {
        showFriendlyError(context, e, fallback: 'Ayar kaydedilemedi. Lütfen tekrar deneyin.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickTime(String? current) async {
    final now = TimeOfDay.now();
    var initial = now;
    if (current != null) {
      final parts = current.split(':');
      initial = TimeOfDay(
        hour: int.tryParse(parts.first) ?? now.hour,
        minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? now.minute) : now.minute,
      );
    }
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final h = picked.hour.toString().padLeft(2, '0');
    final m = picked.minute.toString().padLeft(2, '0');
    await _update(time: '$h:$m');
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({bool? enabled, String? time, int lights, bool canGroup})>(
      (s) {
        final settings = s.peaceSettings;
        return (
          enabled: settings?.enabled,
          time: settings?.time,
          lights: s.openLightsCount,
          canGroup: s.capabilities.canUseGroupCommands,
        );
      },
    );

    final indigo = Colors.indigoAccent;
    final readable = AppTheme.readableAccent(context, indigo);
    final loading = _load == _Load.loading;
    final failed = _load == _Load.failed;
    final known = !loading && !failed && vm.enabled != null;

    String status;
    if (loading) {
      status = 'Durum alınıyor…';
    } else if (failed) {
      status = 'Durum alınamadı';
    } else if (vm.enabled == null) {
      status = 'Durum bilinmiyor';
    } else if (vm.enabled!) {
      status = vm.time == null ? 'Açık (saat seçilmedi)' : 'Açık • saat ${vm.time}';
    } else {
      status = 'Kapalı';
    }

    return KeyedSubtree(
      key: const Key('card_peace'),
      child: SettingsCard(
        icon: Icons.nightlight_round,
        title: 'Gece Huzur Bildirimi',
        accent: indigo,
        children: [
          MergeSemantics(
            child: Semantics(
              label: 'Gece huzur bildirimi',
              liveRegion: true,
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (loading) ...[
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            status,
                            key: const Key('text_peace_status'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: known && vm.enabled == true
                                  ? readable
                                  : (failed ? AppTheme.warningText(context) : AppTheme.getTextMuted(context)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    key: const Key('switch_peace'),
                    value: vm.enabled ?? false,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    activeThumbColor: indigo,
                    onChanged: (known && !_saving) ? (value) => unawaited(_update(enabled: value)) : null,
                  ),
                ],
              ),
            ),
          ),
          if (failed)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('btn_peace_retry'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => unawaited(_fetch()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yeniden dene'),
              ),
            ),
          const SizedBox(height: 4),
          const CardCaption(
            'Her gece belirlenen saatte açık kalan lamba veya panjur varsa tek bir bildirim alırsınız '
            've tek dokunuşla hepsini kapatabilirsiniz.',
          ),
          const PeaceReminderDetails(),
          const PushStatusTile(),
          if (known && vm.enabled == true) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Bildirim saati',
                    style: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(context)),
                  ),
                ),
                TextButton.icon(
                  key: const Key('btn_peace_time'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _saving ? null : () => unawaited(_pickTime(vm.time)),
                  icon: Icon(
                    Icons.access_time,
                    size: 16,
                    color: vm.time == null ? AppTheme.warningText(context) : readable,
                  ),
                  label: Text(
                    vm.time ?? 'Saat Seç',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: vm.time == null ? AppTheme.warningText(context) : readable,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (vm.canGroup && vm.lights > 0) ...[
            Divider(color: AppTheme.getCardBorder(context), height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lightbulb, color: AppTheme.warningText(context), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Şu an evde ${vm.lights} lamba açık',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.getTextPrimary(context),
                      ),
                    ),
                  ],
                ),
                const CloseAllLightsButton(filled: false, color: Colors.amber),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
