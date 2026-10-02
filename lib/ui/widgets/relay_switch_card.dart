import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../dashboard/command_retry.dart';
import '../dashboard/connection_status.dart';
import '../theme/app_theme.dart';

typedef _RelayVm = ({
  bool isOn,
  String name,
  bool pending,
  bool offline,
  bool canControl,
  bool locked,
});

/// Aydınlatma / priz / darbe (tetik) rölesi kartı.
///
/// * Kartın kendisi durumdan **canlı** değerini seçer (`context.select`): ana sayfa her bildirimde
///   yeniden çizilmez; yalnızca değişen kart çizilir.
/// * Komutlar `state.setRelay` (idempotent, 1 tabanlı kanal) ile gider; hata olursa kabuktaki tek
///   abone mesajı gösterir ve "Tekrar dene" sunar.
/// * Bekleyen komut ("uygulanıyor…"), çevrimdışı ("son bilinen") ve çocuk kilidi görseli vardır.
/// * Dokunma hedefleri ≥ 48 dp; tüm kart tek bir erişilebilirlik düğümüdür.
///
/// Anahtarlar: `Key('card_relay_<kanal>')`, `Key('switch_relay_<kanal>')` (aç/kapat),
/// `Key('btn_relay_impulse_<kanal>')` (darbe/tetik rölesi).
class RelaySwitchCard extends StatelessWidget {
  const RelaySwitchCard({super.key, required this.relay});

  final RelayItem relay;

  static RelayItem? _live(AutomationState s, int id) {
    for (final item in s.relayItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _RelayVm>((s) {
      final live = _live(s, relay.id) ?? relay;
      return (
        isOn: live.state,
        name: live.name,
        pending: s.commandPipeline.isPending('relay:${relay.id}') ||
            s.commandPipeline.isPending('impulse:${relay.id}'),
        offline: deviceKnownOffline(s),
        canControl: s.capabilities.canControlDevices,
        locked: s.childLockStatus == ChildLockStatus.locked,
      );
    });

    final isImpulse = relay.isImpulse;
    final isOn = vm.isOn && !isImpulse;
    // Çevrimdışıyken "açık" bilgisi son bilinen değerdir: canlı gibi vurgulanmaz (soluk renkli ama
    // OKUNAKLI; kartın tamamı saydamlaştırılmaz, kontrast korunur).
    final live = isOn && !vm.offline;
    final accent = AppTheme.accentGreen;

    final stateText = isImpulse ? 'Darbe çıkışı' : (isOn ? 'AÇIK' : 'KAPALI');
    final semanticsLabel = [
      vm.name,
      if (isImpulse) 'darbe çıkışı' else if (isOn) 'açık' else 'kapalı',
      if (vm.pending) 'uygulanıyor',
      if (vm.offline) 'cihaz çevrimdışı, son bilinen durum',
      if (vm.locked) 'çocuk kilidi açık, duvar anahtarı devre dışı',
      if (relay.isExt) 'genişleme modülü kanal ${relay.id - 8}',
    ].join(', ');

    final canTap = vm.canControl && !isImpulse;

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: semanticsLabel,
      toggled: isImpulse ? null : isOn,
      button: isImpulse,
      enabled: vm.canControl,
      onTap: vm.canControl
          ? () {
              if (isImpulse) {
                _impulse(context);
              } else {
                _set(context, !isOn);
              }
            }
          : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('card_relay_${relay.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: canTap ? () => _set(context, !isOn) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(14),
            decoration: AppTheme.cardDecoration(
              context,
              accent: live ? accent : null,
              emphasized: live,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isImpulse
                          ? Icons.bolt
                          : (isOn ? Icons.lightbulb : Icons.lightbulb_outline),
                      size: 20,
                      color: live ? AppTheme.warningText(context) : AppTheme.getTextMuted(context),
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
                    if (relay.isExt) ...[
                      const SizedBox(width: 6),
                      _Badge(
                        text: 'CH ${relay.id - 8}',
                        color: AppTheme.readableAccent(context, AppTheme.accentPurple),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          if (vm.pending)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.infoText(context),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Uygulanıyor…',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.infoText(context),
                                  ),
                                ),
                              ],
                            )
                          else
                            Text(
                              stateText,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: live
                                    ? AppTheme.successText(context)
                                    : AppTheme.getTextMuted(context),
                              ),
                            ),
                          if (vm.offline)
                            Text(
                              'Çevrimdışı • son bilinen',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.dangerText(context),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (isImpulse)
                      ElevatedButton(
                        key: Key('btn_relay_impulse_${relay.id}'),
                        onPressed: vm.canControl ? () => _impulse(context) : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.18),
                          foregroundColor: AppTheme.infoText(context),
                          elevation: 0,
                          minimumSize: const Size(96, 48),
                          side: const BorderSide(color: AppTheme.primaryBlue, width: 1),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text(
                          'Tetikle',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      )
                    else
                      Switch(
                        key: Key('switch_relay_${relay.id}'),
                        value: isOn,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        activeThumbColor: AppTheme.accentGreen,
                        activeTrackColor: AppTheme.accentGreen.withValues(alpha: 0.35),
                        inactiveThumbColor: AppTheme.getTextMuted(context),
                        inactiveTrackColor: AppTheme.getInsetColor(context),
                        onChanged: vm.canControl ? (value) => _set(context, value) : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _set(BuildContext context, bool on) {
    HapticFeedback.selectionClick();
    final state = context.read<AutomationState>();
    unawaited(runCommand(context, 'relay:${relay.id}', () => state.setRelay(relay.id, on)));
  }

  void _impulse(BuildContext context) {
    HapticFeedback.selectionClick();
    final state = context.read<AutomationState>();
    unawaited(runCommand(context, 'impulse:${relay.id}', () => state.triggerImpulse(relay.id)));
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
