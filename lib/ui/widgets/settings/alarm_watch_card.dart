import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/alarm_watch/alarm_watch_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'settings_card.dart';

/// "Arka planda alarm bildirimi" kartı (Android, Firebase'siz; yalnız ev sahibi ve sakin).
///
/// Açıkken telefonda bir ön plan servisi bulut bağlantısını açık tutar: uygulama kapalıyken de su baskını, gaz, duman,
/// hırsız alarmı ve vana arızası telefona bildirilir. Bedeli dürüstçe yazılır: durum çubuğunda kalıcı bildirim simgesi,
/// biraz pil; bazı markalar (Xiaomi/Huawei/Oppo) arka plan uygulamalarını kapatır → pil kısıtlaması muafiyeti düğmesi.
/// iOS'ta yalnız "Bu özellik yalnız Android'de" yazar.
///
/// Anahtarlar: `Key('card_alarm_watch')`, `Key('switch_alarm_watch')`, `Key('text_alarm_watch_status')`,
/// `Key('btn_alarm_watch_battery')`, `Key('btn_alarm_watch_permission')`, `Key('text_alarm_watch_message')`,
/// `Key('text_alarm_watch_unsupported')`.
class AlarmWatchCard extends StatefulWidget {
  const AlarmWatchCard({super.key});

  @override
  State<AlarmWatchCard> createState() => _AlarmWatchCardState();
}

class _AlarmWatchCardState extends State<AlarmWatchCard> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sistem ayarlarından (izin / pil) dönünce durum yeniden okunur.
    if (state == AppLifecycleState.resumed) {
      unawaited(context.read<AlarmWatchController?>()?.refreshPermissions());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AlarmWatchController?>();
    if (c == null) return const SizedBox.shrink();
    final accent = AppFamilies.rose.base;

    if (!c.supported) {
      return KeyedSubtree(
        key: const Key('card_alarm_watch'),
        child: SettingsCard(
          icon: Icons.notifications_active_rounded,
          title: 'Arka planda alarm bildirimi',
          accent: accent,
          enabled: false,
          children: const [
            CardCaption(
              'Bu özellik yalnız Android\'de. Alarm, uygulamayı açtığınızda uygulama içinde görünür.',
              key: Key('text_alarm_watch_unsupported'),
            ),
          ],
        ),
      );
    }

    final on = c.enabled;
    final status = !c.loaded
        ? 'Durum alınıyor…'
        : on
            ? (c.notificationsAllowed ? 'Açık' : 'Açık • bildirim izni kapalı')
            : 'Kapalı';
    final canToggle = c.loaded && !c.busy && (on || c.eligible);

    return KeyedSubtree(
      key: const Key('card_alarm_watch'),
      child: SettingsCard(
        icon: Icons.notifications_active_rounded,
        title: 'Arka planda alarm bildirimi',
        accent: accent,
        active: on,
        pending: c.busy || !c.loaded,
        children: [
          MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    status,
                    key: const Key('text_alarm_watch_status'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: on ? AppTheme.readableAccent(context, accent) : AppTheme.getTextMuted(context),
                    ),
                  ),
                ),
                Switch(
                  key: const Key('switch_alarm_watch'),
                  value: on,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onChanged: canToggle ? (v) => unawaited(v ? c.enable() : c.disable()) : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          const CardCaption(
            'Uygulama kapalıyken de su baskını, gaz, duman, hırsız alarmı ve vana arızası telefonunuza bildirilir. '
            'Açıkken durum çubuğunda kalıcı bir bildirim simgesi durur ve telefon biraz daha fazla pil kullanır. '
            'Bazı markalar (Xiaomi, Huawei, Oppo vb.) arka plandaki uygulamaları kapatabilir; bildirimin kesilmemesi '
            'için pil kısıtlamasını kaldırın. Telefon yeniden başlayınca kendiliğinden sürer.',
          ),
          if (!c.eligible && !on) ...[
            const SizedBox(height: 6),
            const CardCaption('Yalnız ev sahibi ve ev sakinleri açabilir (misafir ve servis hesapları ✖).'),
          ],
          if (on && !c.notificationsAllowed)
            _ActionRow(
              buttonKey: const Key('btn_alarm_watch_permission'),
              icon: Icons.notifications_off_outlined,
              text: 'Bildirim izni kapalı: alarm telefonda görünmez.',
              action: 'Bildirim izni ver',
              onPressed: c.busy ? null : () => unawaited(c.enable()),
            ),
          if (on && !c.batteryExempt)
            _ActionRow(
              buttonKey: const Key('btn_alarm_watch_battery'),
              icon: Icons.battery_alert_rounded,
              text: 'Pil kısıtlaması açık: telefon servisi kapatabilir.',
              action: 'Pil kısıtlamasını kaldır',
              onPressed: c.busy ? null : () => unawaited(c.requestBatteryExemption()),
            ),
          if (c.message != null) ...[
            const SizedBox(height: 6),
            Text(
              c.message!,
              key: const Key('text_alarm_watch_message'),
              style: TextStyle(fontSize: 12.5, height: 1.35, color: AppTheme.warningText(context)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.buttonKey,
    required this.icon,
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final warn = AppTheme.warningText(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: warn)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 13, height: 1.35, fontWeight: FontWeight.w600, color: warn)),
              ),
            ],
          ),
          TextButton(
            key: buttonKey,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: AppTheme.infoText(context)),
            onPressed: onPressed,
            child: Text(action),
          ),
        ],
      ),
    );
  }
}
