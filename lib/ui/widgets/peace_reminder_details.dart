import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/api_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

/// Gece huzur bildirimi kartına konan "son hatırlatma" ve cihaz durumu özeti.
///
/// Ayar kartına TEK satırla yerleştirilir: `const PeaceReminderDetails()`. Veriyi
/// [AutomationState.peaceNotificationData]'dan (sunucu v2 alanları: `last_notice`, `devices_online`,
/// `devices_total`, `stale`) okur; gösterilecek bir şey yoksa hiçbir şey çizmez (v1 sunucu, veri yok).
///
/// * "Son hatırlatma: Dün 23:30 - açık 2 lamba, 1 panjur (kapatılmadı)" (kapatıldıysa "(kapatıldı)").
/// * "Cihazlar: 1/2 çevrimiçi".
/// * `stale == true` ise: "Cihaz çevrimdışı; açık lamba bilgisi güncel değil." uyarısı (simge + metin).
///
/// Anahtarlar: `Key('peace_reminder_details')`, `Key('text_peace_last_notice')`,
/// `Key('text_peace_devices')`, `Key('text_peace_stale')`.
class PeaceReminderDetails extends StatelessWidget {
  /// [now] yalnızca testler içindir ("Bugün/Dün" hesabı için saat).
  const PeaceReminderDetails({super.key, this.now});

  final DateTime Function()? now;

  /// Kısa Türkçe gün + saat: `Bugün 23:30`, `Dün 23:30`, `12.03 23:30` (başka yıl: `12.03.2025 23:30`).
  /// [moment] yerel saate çevrilir.
  static String formatMoment(DateTime moment, DateTime reference) {
    final local = moment.toLocal();
    final today = DateTime(reference.year, reference.month, reference.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    if (diff == 0) return 'Bugün $time';
    if (diff == 1) return 'Dün $time';
    final date = local.year == reference.year
        ? '${two(local.day)}.${two(local.month)}'
        : '${two(local.day)}.${two(local.month)}.${local.year}';
    return '$date $time';
  }

  /// Son hatırlatma satırı; gösterilecek bilgi yoksa `null`.
  static String? lastNoticeText(PeaceLastNotice? last, DateTime reference) {
    if (last == null) return null;
    final lights = last.openLightsCount;
    final shutters = last.openShuttersCount;
    final created = last.createdAt;
    final parts = <String>[
      if (lights != null) '$lights lamba',
      if (shutters != null) '$shutters panjur',
    ];
    if (created == null && parts.isEmpty) return null;

    final when = created == null ? '' : ' ${formatMoment(created, reference)}';
    final what = parts.isEmpty
        ? ''
        : '${created == null ? '' : ' -'} açık ${parts.join(', ')}';
    final state = last.isResolved ? 'kapatıldı' : 'kapatılmadı';
    return 'Son hatırlatma:$when$what ($state)';
  }

  @override
  Widget build(BuildContext context) {
    // Harita yalnızca yeni yanıt gelince değişir; tipli görünüm burada üretilir (peaceSettings ile aynı).
    final data = context.select<AutomationState, Map<String, dynamic>?>(
      (s) => s.peaceNotificationData,
    );
    if (data == null) return const SizedBox.shrink();

    final settings = PeaceNotificationSettings.fromJson(data);
    final reference = (now ?? DateTime.now)();
    final lastText = lastNoticeText(settings.lastNotice, reference);
    final online = settings.devicesOnline;
    final total = settings.devicesTotal;
    final devicesText = (online != null && total != null)
        ? 'Cihazlar: $online/$total çevrimiçi'
        : null;
    final stale = settings.stale == true;
    if (lastText == null && devicesText == null && !stale) {
      return const SizedBox.shrink();
    }

    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    final warning = AppTheme.warningText(context);

    return Padding(
      key: const Key('peace_reminder_details'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lastText != null)
            _Line(
              icon: Icons.history,
              iconColor: muted,
              child: Text(
                lastText,
                key: const Key('text_peace_last_notice'),
                style: TextStyle(fontSize: 13, height: 1.35, color: primary),
              ),
            ),
          if (devicesText != null)
            _Line(
              icon: Icons.developer_board,
              iconColor: muted,
              child: Text(
                devicesText,
                key: const Key('text_peace_devices'),
                style: TextStyle(fontSize: 13, height: 1.35, color: muted),
              ),
            ),
          if (stale)
            _Line(
              icon: Icons.cloud_off_outlined,
              iconColor: warning,
              child: Text(
                'Cihaz çevrimdışı; açık lamba bilgisi güncel değil.',
                key: const Key('text_peace_stale'),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: warning,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Simge + metin satırı (durum renge bağımlı değildir); satır tek bir ekran okuyucu öğesidir.
class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.iconColor,
    required this.child,
  });

  final IconData icon;
  final Color iconColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 16, color: iconColor),
            ),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
