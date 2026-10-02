import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../dashboard/command_retry.dart';
import '../dashboard/connection_status.dart';
import '../theme/app_theme.dart';

typedef _ShutterVm = ({
  int pos,
  bool moving,
  int direction,
  int? target,
  String name,
  bool isExt,
  bool pending,
  bool offline,
  bool canControl,
  bool locked,
});

/// Panjur kartı. **`shutter.pair` 1 tabanlıdır** (`pair N` = röle `2N-1` YUKARI, `2N` AŞAĞI).
///
/// Kart durumdan kendi canlı değerlerini seçer (`context.select`): konum, hareket, bekleyen komut
/// ("uygulanıyor…"), çevrimdışı ("son bilinen") ve çocuk kilidi. Komutlar `state.cmdShutter`
/// ile gider; hata olursa kabuktaki tek abone mesajı gösterir ve "Tekrar dene" sunar.
/// Dokunma hedefleri ≥ 48 dp'dir; yazı ölçeği 1.5'te taşma olmaz (`Wrap`/`FittedBox`).
///
/// Anahtarlar: `Key('card_shutter_<pair>')`, `Key('btn_shutter_up_<pair>')`,
/// `Key('btn_shutter_stop_<pair>')`, `Key('btn_shutter_down_<pair>')`, `Key('slider_shutter_<pair>')`.
class ShutterCard extends StatefulWidget {
  const ShutterCard({super.key, required this.shutter});

  final ShutterItem shutter;

  @override
  State<ShutterCard> createState() => _ShutterCardState();
}

class _ShutterCardState extends State<ShutterCard> {
  double? _dragValue;

  int get _pair => widget.shutter.pair;

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _ShutterVm>((s) {
      var live = widget.shutter;
      for (final item in s.shutterItems) {
        if (item.pair == _pair) {
          live = item;
          break;
        }
      }
      return (
        pos: live.pos,
        moving: live.isMoving,
        direction: live.direction,
        target: live.target,
        name: live.name,
        isExt: live.isExt,
        pending: s.commandPipeline.isPending('shutter:$_pair'),
        offline: deviceKnownOffline(s),
        canControl: s.capabilities.canControlDevices,
        locked: s.childLockStatus == ChildLockStatus.locked,
      );
    });

    final sliderValue = (_dragValue ?? vm.pos.toDouble()).clamp(0.0, 100.0);
    // Çevrimdışıyken konum son bilinen değerdir: canlı gibi vurgulanmaz (kart saydamlaştırılmaz;
    // metinler okunaklı kalır).
    final muted = AppTheme.getTextMuted(context);
    final opening = vm.moving && vm.direction == 1;
    final closing = vm.moving && vm.direction == 2;

    String statusText = 'Durdu';
    Color statusColor = AppTheme.getTextMuted(context);
    if (vm.pending) {
      statusText = 'Uygulanıyor…';
      statusColor = AppTheme.infoText(context);
    } else if (opening) {
      statusText = 'Açılıyor…';
      statusColor = AppTheme.successText(context);
    } else if (closing) {
      statusText = 'Kapanıyor…';
      statusColor = AppTheme.warningText(context);
    }

    final semanticsLabel = [
      '${vm.name} panjur',
      'yüzde ${vm.pos} açık',
      statusText.replaceAll('…', ''),
      if (vm.offline) 'cihaz çevrimdışı, son bilinen durum',
      if (vm.locked) 'çocuk kilidi açık, duvar anahtarı devre dışı',
    ].join(', ');

    return Container(
      key: Key('card_shutter_$_pair'),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.cardDecoration(
        context,
        accent: vm.moving && !vm.offline ? statusColor : null,
        emphasized: vm.moving && !vm.offline,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            container: true,
            excludeSemantics: true,
            label: semanticsLabel,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  vm.pos == 0 ? Icons.blinds_closed : Icons.blinds,
                  size: 22,
                  color: vm.offline ? muted : AppTheme.infoText(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    vm.name,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.getTextPrimary(context),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (vm.locked) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.lock_outline, size: 16, color: AppTheme.warningText(context)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Chip(
                text: '%${sliderValue.round()}',
                color: vm.offline ? muted : AppTheme.infoText(context),
                filled: true,
              ),
              if (vm.pending)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: statusColor),
                ),
              Text(
                statusText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
              if (vm.moving && vm.target != null)
                Text(
                  'Hedef %${vm.target}',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.getTextMuted(context)),
                ),
              if (vm.isExt)
                _Chip(
                  text: 'RS485',
                  color: AppTheme.readableAccent(context, AppTheme.accentPurple),
                ),
              if (vm.offline)
                Text(
                  'Çevrimdışı • son bilinen',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.dangerText(context)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: vm.offline ? muted : AppTheme.primaryBlue,
              inactiveTrackColor: AppTheme.getCardBorder(context),
              thumbColor: vm.offline ? muted : AppTheme.primaryBlue,
              overlayColor: AppTheme.primaryBlue.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            ),
            child: Semantics(
              label: '${vm.name} panjur konumu',
              child: Slider(
                key: Key('slider_shutter_$_pair'),
                value: sliderValue,
                min: 0,
                max: 100,
                semanticFormatterCallback: (value) => 'yüzde ${value.round()}',
                onChanged: vm.canControl ? (value) => setState(() => _dragValue = value) : null,
                onChangeEnd: vm.canControl ? (value) => _setPosition(value.round()) : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Kapalı',
                  style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
                ),
                Text(
                  'Açık',
                  style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  buttonKey: Key('btn_shutter_up_$_pair'),
                  icon: Icons.arrow_upward,
                  label: 'Aç',
                  semanticsLabel: '${vm.name} panjuru aç',
                  active: opening,
                  color: AppTheme.accentGreen,
                  enabled: vm.canControl,
                  onTap: () => _command('up'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _ActionButton(
                  buttonKey: Key('btn_shutter_stop_$_pair'),
                  icon: Icons.stop,
                  label: 'Durdur',
                  semanticsLabel: '${vm.name} panjuru durdur',
                  active: false,
                  color: AppTheme.getTextMuted(context),
                  enabled: vm.canControl,
                  onTap: () => _command('stop'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _ActionButton(
                  buttonKey: Key('btn_shutter_down_$_pair'),
                  icon: Icons.arrow_downward,
                  label: 'Kapat',
                  semanticsLabel: '${vm.name} panjuru kapat',
                  active: closing,
                  color: AppTheme.primaryBlueLight,
                  enabled: vm.canControl,
                  onTap: () => _command('down'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _setPosition(int percent) {
    HapticFeedback.selectionClick();
    setState(() => _dragValue = null);
    final state = context.read<AutomationState>();
    unawaited(runCommand(context, 'shutter:$_pair', () => state.cmdShutter(_pair, 'pos', percent: percent)));
  }

  void _command(String action) {
    HapticFeedback.selectionClick();
    final state = context.read<AutomationState>();
    unawaited(runCommand(context, 'shutter:$_pair', () => state.cmdShutter(_pair, action)));
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color, this.filled = false});

  final String text;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.14 : 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        // Metin, vurgu rengiyle boyalı rozet zemininde de AA kontrastlı olsun.
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: AppTheme.readableAccent(context, color),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.active,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final String semanticsLabel;
  final bool active;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppTheme.readableAccent(context, color) : AppTheme.getTextPrimary(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Material(
        color: active ? color.withValues(alpha: 0.2) : AppTheme.getInsetColor(context),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: buttonKey,
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? color : AppTheme.getCardBorder(context),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: enabled ? fg : AppTheme.getTextMuted(context)),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: enabled ? fg : AppTheme.getTextMuted(context),
                    ),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
