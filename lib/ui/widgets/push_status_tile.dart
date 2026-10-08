import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/alarm_watch/alarm_watch_controller.dart';
import '../../services/peace_notice_controller.dart';
import '../../services/push/push_coordinator.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Gece huzur bildirimi kartına konan, bu telefonun push (bildirim) kaydının durumu.
///
/// Ayar kartına TEK satırla yerleştirilir: `const PushStatusTile()`. Durum ve eylem
/// [PeaceNoticeController]'dan gelir (üstte bir sağlayıcı olmalı; yoksa hiçbir şey çizilmez).
///
/// Push gönderim katmanı yapılandırılmadığında ([PushState.unsupported]; Firebase/APNs kullanılmayan bu sürümde
/// hep böyledir) ve oturum gece hatırlatması için uygunsa ([PeaceNoticeController.isEligible]: owner/resident)
/// tek bir DÜRÜST bilgi satırı çizilir: bildirim telefona gönderilmez, hatırlatma uygulama açılınca görünür
/// (ayar kartının "bildirim alırsınız" açıklaması yanlış beklenti doğurmasın; RR3-02). Uygun olmayan oturumda
/// ([PushState.unsupported]) ve [PushState.idle] iken hiçbir şey çizilmez.
///
/// Durum bir simge + metinle verilir (renge bağımlı değildir) ve değişince ekran okuyucuya duyurulur
/// (canlı bölge). Metin renkleri AA kontrastlıdır (yeşil yalnızca simgede). Kayıt KALICI reddedildiyse
/// ([PeaceNoticeController.pushRegistrationBlocked]) metin bunu dürüstçe söyler ve elle "Yeniden dene" sunar;
/// geçici hatada otomatik yeniden denenir. Anahtarlar: `Key('tile_push_status')`, `Key('text_push_status')`,
/// `Key('btn_push_enable')`, `Key('btn_push_retry')`.
class PushStatusTile extends StatefulWidget {
  const PushStatusTile({super.key});

  @override
  State<PushStatusTile> createState() => _PushStatusTileState();
}

class _PushStatusTileState extends State<PushStatusTile> {
  /// İstek sürerken düğme devre dışı (sistem penceresi açıkken / kayıt denenirken çift dokunuş olmasın).
  bool _requesting = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sağlayıcı yoksa (ör. kartı yalnızca AutomationState ile çizen testler) hiçbir şey çizilmez: nullable arama.
    final view = context
        .select<
          PeaceNoticeController?,
          ({PushState state, bool denied, bool blocked, bool eligible})?
        >(
          (c) => c == null
              ? null
              : (
                  state: c.pushState,
                  denied: c.pushPermissionDenied,
                  blocked: c.pushRegistrationBlocked,
                  eligible: c.isEligible,
                ),
        );
    final controller = context.read<PeaceNoticeController?>();
    if (view == null || controller == null) return const SizedBox.shrink();
    // Android: alarmlar için arka plan bildirimi seçeneği var (gece hatırlatması yine uygulama açılınca görünür).
    final alarmWatch = context.select<AlarmWatchController?, bool>((c) => c?.supported ?? false);

    final _TileSpec? spec = switch (view.state) {
      // Push gönderim katmanı yapılandırılmadı: uygun kullanıcıya bildirimin telefona gönderilmediği söylenir.
      PushState.unsupported when view.eligible => _TileSpec(
        icon: Icons.info_outline,
        text: alarmWatch ? kPushTileAndroidText : kPushTileUnsupportedText,
        tone: _Tone.muted,
      ),
      PushState.unsupported || PushState.idle => null,
      PushState.registered => _TileSpec(
        icon: Icons.check_circle_outline,
        text: 'Bu telefona bildirim gönderilecek.',
        tone: _Tone.success,
      ),
      PushState.registering => _TileSpec(
        icon: Icons.sync,
        text: 'Bildirimler etkinleştiriliyor…',
        tone: _Tone.muted,
      ),
      PushState.needsPermission when !view.denied => _TileSpec(
        icon: Icons.notifications_off_outlined,
        text: 'Gece hatırlatmasını almak için bildirimleri açın.',
        tone: _Tone.warning,
        action: 'Bildirimleri aç',
        actionKey: const Key('btn_push_enable'),
        onAction: controller.requestPermission,
      ),
      PushState.needsPermission => _TileSpec(
        icon: Icons.notifications_off_outlined,
        text: 'Bildirim izni kapalı. Hatırlatmayı almak için telefon ayarlarından bu uygulamanın bildirimlerini açın.',
        tone: _Tone.warning,
      ),
      PushState.failed when view.blocked => _TileSpec(
        icon: Icons.error_outline,
        text: 'Bildirim kaydı bu cihazda kabul edilmedi. Çıkış yapıp yeniden giriş yapmayı deneyin.',
        tone: _Tone.warning,
        action: 'Yeniden dene',
        actionKey: const Key('btn_push_retry'),
        onAction: controller.retryPushRegistration,
      ),
      PushState.failed => _TileSpec(
        icon: Icons.error_outline,
        text: 'Bildirim kaydı şu an yapılamadı. Otomatik olarak yeniden denenecek.',
        tone: _Tone.warning,
      ),
    };
    if (spec == null) return const SizedBox.shrink();

    // Metin AA kontrastlı olmalı: açık temada yeşil metin (3.55:1) yetmez; yeşil yalnızca simgede kalır.
    final iconColor = switch (spec.tone) {
      _Tone.success => AppTheme.successText(context),
      _Tone.warning => AppTheme.warningText(context),
      _Tone.muted => AppTheme.getTextMuted(context),
    };
    final textColor = switch (spec.tone) {
      _Tone.success => Theme.of(context).colorScheme.onSurface,
      _Tone.warning => AppTheme.warningText(context),
      _Tone.muted => AppTheme.getTextMuted(context),
    };

    // Ton rengine göre hafif tınılı panel (uyarı = amber bloom, başarı = zümrüt); renk tek ipucu değildir.
    final tint = switch (spec.tone) {
      _Tone.success => AppFamilies.emerald.base,
      _Tone.warning => AppFamilies.amber.base,
      _Tone.muted => AppFamilies.slate.base,
    };

    return Padding(
      key: const Key('tile_push_status'),
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.r12),
          border: Border.all(color: tint.withValues(alpha: 0.30)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                container: true,
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(spec.icon, size: 18, color: iconColor),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        spec.text,
                        key: const Key('text_push_status'),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (spec.action != null && spec.onAction != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: spec.actionKey,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                      foregroundColor: AppTheme.infoText(context),
                    ),
                    onPressed: _requesting
                        ? null
                        : () => unawaited(_run(spec.onAction!)),
                    child: Text(spec.action!),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Push gönderim katmanı yokken (bu sürüm) gösterilen dürüst metin.
const String kPushTileUnsupportedText =
    'Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür.';

/// Android'de: gece hatırlatması yine uygulama açılınca görünür; alarmlar için arka plan bildirimi açılabilir.
const String kPushTileAndroidText =
    'Gece hatırlatması telefona gönderilmez; uygulamayı açtığınızda görünür. Alarmların uygulama kapalıyken de '
    'gelmesi için Güvenlik bölümündeki "Arka planda alarm bildirimi"ni açın.';

enum _Tone { success, warning, muted }

class _TileSpec {
  const _TileSpec({
    required this.icon,
    required this.text,
    required this.tone,
    this.action,
    this.actionKey,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final _Tone tone;
  final String? action;
  final Key? actionKey;
  final Future<void> Function()? onAction;
}
