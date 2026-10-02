import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'service_setup_controller.dart';
import 'setup_problem.dart';
import 'setup_style.dart';

/// Adım rozeti ("Bekliyor", "Çalışıyor...", "Tamamlandı", "Sorun var", "Atlandı").
class SetupStatusBadge extends StatelessWidget {
  const SetupStatusBadge({super.key, required this.phase, this.label});

  final StepPhase phase;
  final String? label;

  static String textFor(StepPhase phase) {
    switch (phase) {
      case StepPhase.pending:
        return 'Bekliyor';
      case StepPhase.working:
        return 'Çalışıyor...';
      case StepPhase.done:
        return 'Tamamlandı';
      case StepPhase.failed:
        return 'Sorun var';
      case StepPhase.skipped:
        return 'Atlandı';
    }
  }

  static Color colorFor(StepPhase phase) {
    switch (phase) {
      case StepPhase.pending:
        return SetupColors.info;
      case StepPhase.working:
        return SetupColors.primaryLight;
      case StepPhase.done:
        return SetupColors.ok;
      case StepPhase.failed:
        return SetupColors.error;
      case StepPhase.skipped:
        return SetupColors.warn;
    }
  }

  static IconData iconFor(StepPhase phase) {
    switch (phase) {
      case StepPhase.pending:
        return Icons.hourglass_empty_rounded;
      case StepPhase.working:
        return Icons.sync_rounded;
      case StepPhase.done:
        return Icons.check_circle_rounded;
      case StepPhase.failed:
        return Icons.error_rounded;
      case StepPhase.skipped:
        return Icons.skip_next_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = SetupStatusBadge.colorFor(phase);
    final text = label ?? textFor(phase);
    return Semantics(
      label: 'Adım durumu: $text',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (phase == StepPhase.working)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(iconFor(phase), size: 15, color: SetupColors.readable(context, color)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: SetupColors.readable(context, color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Başarısız adım kutusu: ne oldu / **Neden?** / **Ne yapmalıyım?** + "Tekrar dene" + (varsa) "N. adıma dön".
class SetupProblemBox extends StatelessWidget {
  const SetupProblemBox({
    super.key,
    required this.problem,
    this.onRetry,
    this.onFixStep,
  });

  final SetupProblem problem;
  final VoidCallback? onRetry;
  final void Function(int step)? onFixStep;

  @override
  Widget build(BuildContext context) {
    final color = problem.kind == SetupProblemKind.expired ? SetupColors.warn : SetupColors.error;
    final text = SetupColors.text(context);
    final readable = SetupColors.readable(context, color);
    final fix = problem.fixStep;
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Hata: ${problem.title}',
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, color: readable, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    problem.title,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: readable),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _labeled(context, 'Neden?', problem.why, text),
            const SizedBox(height: 8),
            _labeled(context, 'Ne yapmalıyım?', problem.todo, text),
            if (problem.retryAfter != null) ...[
              const SizedBox(height: 8),
              Text(
                'Beklemeniz gereken süre: yaklaşık ${SetupProblems.waitText(problem.retryAfter)}.',
                style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
              ),
            ],
            if (onRetry != null || (fix != null && onFixStep != null)) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onRetry != null)
                    ElevatedButton.icon(
                      key: const Key('setup_retry'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Tekrar dene'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  if (fix != null && onFixStep != null)
                    OutlinedButton.icon(
                      key: const Key('setup_fix_step'),
                      onPressed: () => onFixStep!(fix),
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: Text('$fix. adıma dön'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _labeled(BuildContext context, String label, String body, Color text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: SetupColors.muted(context))),
        const SizedBox(height: 2),
        Text(body, style: TextStyle(fontSize: 13.5, height: 1.35, color: text)),
      ],
    );
  }
}

/// Kenarlıklı, tema duyarlı genel kart.
class SetupCard extends StatelessWidget {
  const SetupCard({
    super.key,
    required this.child,
    this.accent,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.only(top: 12),
  });

  final Widget child;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final accent = this.accent;
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: accent == null ? SetupColors.card(context) : accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent == null ? SetupColors.border(context) : accent.withValues(alpha: 0.4)),
      ),
      child: child,
    );
  }
}

/// Simge + metin satırı (taşmaz, ölçeklenen yazıda alta sarar).
class SetupInfoRow extends StatelessWidget {
  const SetupInfoRow({
    super.key,
    required this.icon,
    required this.text,
    this.color,
    this.bold = false,
  });

  final IconData icon;
  final String text;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final c = color ?? SetupColors.muted(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: SetupColors.readable(context, c)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: color == null ? SetupColors.text(context) : SetupColors.readable(context, c),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bölüm başlığı.
class SetupSectionTitle extends StatelessWidget {
  const SetupSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 2),
      child: Text(
        text,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
      ),
    );
  }
}

/// Tam genişlik, 52 dp yüksekliğinde birincil eylem düğmesi (başparmak bölgesi).
class SetupPrimaryButton extends StatelessWidget {
  const SetupPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? SetupColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: (color ?? SetupColors.primary).withValues(alpha: 0.35),
          disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            else if (icon != null)
              Icon(icon, size: 20),
            if (busy || icon != null) const SizedBox(width: 10),
            Flexible(child: Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

/// Saniyede bir güncellenen kalan süre metni (yalnızca bu küçük widget yeniden çizilir).
class CountdownText extends StatelessWidget {
  const CountdownText({
    super.key,
    required this.tick,
    required this.remaining,
    this.prefix = '',
    this.style,
    this.doneText,
  });

  final ValueListenable<int> tick;

  /// Güncel kalan süreyi hesaplar (her saniye çağrılır).
  final Duration Function() remaining;
  final String prefix;
  final TextStyle? style;
  final String? doneText;

  static String format(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (context, _, _) {
        final left = remaining();
        final text = (left <= Duration.zero && doneText != null) ? doneText! : '$prefix${format(left)}';
        return Text(text, style: style);
      },
    );
  }
}
