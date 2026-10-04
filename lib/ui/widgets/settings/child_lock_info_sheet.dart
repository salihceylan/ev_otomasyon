import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../common/app_dialogs.dart';
import '../../dashboard/child_lock_status.dart';
import '../../theme/app_theme.dart';
import '../../theme/feature_accent.dart';
import '../../theme/tokens.dart';
import '../orb/orb.dart';

/// Çocuk kilidi bilgi sayfasını açar: neyi kilitler / kilitlemez, elektrik kesintisinde ne olur,
/// kapsamı ve kimin değiştirebileceği. Hem ayar kartından hem pano rozetinden açılır.
Future<void> showChildLockInfoSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: AppTheme.getSurfaceColor(context),
    builder: (_) => const ChildLockInfoSheet(),
  );
}

/// Çocuk kilidi bilgi sayfası içeriği. Anahtarlar: `Key('child_lock_info_sheet')`,
/// `Key('btn_child_lock_info_close')`.
class ChildLockInfoSheet extends StatelessWidget {
  const ChildLockInfoSheet({super.key});

  static const List<({IconData icon, String title, String text})> sections = [
    (
      icon: Icons.lock_outline,
      title: 'Neyi kilitler?',
      text:
          'Evdeki duvar anahtarlarına ve butonlarına basılsa bile lambalar ve panjurlar çalışmaz. '
          'Böylece çocuklar anahtarlarla oynayamaz.',
    ),
    (
      icon: Icons.phone_iphone_rounded,
      title: 'Neyi kilitlemez?',
      text:
          'Telefon uygulaması, zamanlı kurallar ve ev halkının diğer telefonları lambaları ve '
          'panjurları kontrol etmeye devam eder.',
    ),
    (
      icon: Icons.power_outlined,
      title: 'Elektrik kesintisinde',
      text:
          'Kilit pano hafızasında saklanır: elektrik kesilip gelse de sürer. Elektrik geldiğinde '
          'lambalar kapalı başlar ve kilit kaldırılana kadar duvar anahtarıyla açılamaz.',
    ),
    (
      icon: Icons.home_work_outlined,
      title: 'Kapsamı',
      text: 'Kilit evdeki tüm panoları ve tüm duvar anahtarlarını kapsar; tek tek seçilemez.',
    ),
    (
      icon: Icons.verified_user_outlined,
      title: 'Kim değiştirebilir?',
      text:
          'Ev sahibi, aile üyeleri ve yetkili servis. Misafirler durumu görebilir ama '
          'değiştiremez. Kilidi kaldırmak için kimlik doğrulaması ya da basılı tutma gerekir.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ChildLockVm>(childLockVmOf);
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);

    return SingleChildScrollView(
      key: const Key('child_lock_info_sheet'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              OrbIconBadge(icon: Icons.child_care_rounded, family: AppFeature.childLock.accentFamily, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Çocuk Kilidi',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Şu anki durum: ${childLockStatusLabel(vm)}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.infoText(context)),
          ),
          const SizedBox(height: 16),
          for (final section in sections) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppFamilies.sky.base.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.r12),
                  ),
                  child: Icon(section.icon, size: 20, color: AppTheme.infoText(context)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.title,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: primary),
                      ),
                      const SizedBox(height: 2),
                      Text(section.text, style: TextStyle(fontSize: 13, height: 1.4, color: muted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('btn_child_lock_info_close'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Anladım'),
            ),
          ),
        ],
      ),
    );
  }
}
