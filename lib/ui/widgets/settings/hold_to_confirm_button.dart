import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Basılı tutarak onaylatan düğme (bilinçli eylem). [holdDuration] boyunca basılı tutulursa
/// [onConfirmed] **bir kez** çağrılır; erken bırakılırsa ilerleme sıfırlanır ve hiçbir şey olmaz.
///
/// Ekran okuyucu kullanıcıları için standart "uzun bas" erişilebilirlik eylemi onayı tetikler.
/// Dokunma yüksekliği 56 dp'dir.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.holdDuration = const Duration(milliseconds: 1200),
    this.color = AppTheme.accentAmber,
    this.icon = Icons.lock_open_rounded,
  });

  final String label;
  final VoidCallback onConfirmed;
  final Duration holdDuration;
  final Color color;
  final IconData icon;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener(_onStatus);

  bool _fired = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _confirm();
  }

  void _confirm() {
    if (_fired) return;
    _fired = true;
    HapticFeedback.heavyImpact();
    widget.onConfirmed();
  }

  void _start() {
    if (_fired) return;
    HapticFeedback.selectionClick();
    _controller.forward(from: 0);
  }

  void _cancel() {
    if (_fired) return;
    _controller.animateBack(0, duration: const Duration(milliseconds: 180));
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.readableAccent(context, widget.color);
    return Semantics(
      button: true,
      label: widget.label,
      hint: 'Basılı tutarak onaylayın',
      excludeSemantics: true,
      onLongPress: _confirm,
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _cancel(),
        onPointerCancel: (_) => _cancel(),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final holding = _controller.value > 0 && !_fired;
            return ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                constraints: const BoxConstraints(minHeight: 56),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: widget.color.withValues(alpha: 0.7), width: 1.4),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: _controller.value,
                          child: ColoredBox(
                            color: widget.color.withValues(alpha: 0.32),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(widget.icon, size: 20, color: color),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              holding ? 'Basılı tutun…' : widget.label,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: color,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
