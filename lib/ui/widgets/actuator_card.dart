import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../dashboard/command_retry.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart';
import 'critical_alarm_card.dart';
import 'orb/orb.dart';
import 'safety_labels.dart';
import 'settings/accent_button.dart';
import 'surface_card.dart';

// =============================================================================
// Eylemci kartı (WP-A3; tasarım §5.3.3 "Güvenlik ve Eylemciler" bölümü).
//
//  * Vana: konum hapı (simge + metin), "Kapat" (her zaman, misafir dahil; onay diyaloğu) ve kapalıyken "Aç"
//    (yalnız yetkili üye; bölgede alarm / ıslak ya da yanıtsız sensör / güvenli kipte devre dışı + gerekçe).
//    Gaz vanası uygulamadan AÇILMAZ [K-4]: düğme yok, "yalnız yerinde" açıklaması var.
//  * Siren / fan / genel: durum hapı + anahtar. Kapatma (güvenli yön) misafir dahil serbest; açma yalnız yetkili üye
//    (misafirde kapalı cihazın anahtarı hiç çizilmez).
//  * Komut bekliyorsa "Uygulanıyor…" (açma iyimser değildir; kapatma anında görünür).
//
// Anahtarlar: `Key('card_actuator_<id>')`, `Key('btn_actuator_close_<id>')`, `Key('btn_actuator_open_<id>')`,
// `Key('switch_actuator_<id>')`, sensör hapı `Key('pill_sensor_<id>')`.
// =============================================================================

@immutable
class _ActuatorView {
  const _ActuatorView({
    required this.item,
    required this.pending,
    required this.openBlock,
    required this.canClose,
    required this.canControl,
    this.gasVentilation = false,
    this.canAck = false,
  });

  final ActuatorItem? item;
  final bool pending;
  final String? openBlock;
  final bool canClose;
  final bool canControl;

  /// Çalışan fan + bölgesinde etkin gaz alarmı (guvenlik-7).
  final bool gasVentilation;
  final bool canAck;

  @override
  bool operator ==(Object other) =>
      other is _ActuatorView &&
      other.item == item &&
      other.pending == pending &&
      other.openBlock == openBlock &&
      other.canClose == canClose &&
      other.canControl == canControl &&
      other.gasVentilation == gasVentilation &&
      other.canAck == canAck;

  @override
  int get hashCode => Object.hash(item, pending, openBlock, canClose, canControl, gasVentilation, canAck);
}

/// Tek eylemcinin kartı; canlı değerini kendisi seçer (bölüm yalnız kart kümesi değişince yeniden kurulur).
class ActuatorCard extends StatelessWidget {
  const ActuatorCard({super.key, required this.actuatorId, this.deviceUid});

  final String actuatorId;
  final String? deviceUid;

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, _ActuatorView>((s) {
      ActuatorItem? item;
      for (final a in s.actuatorItems) {
        if (a.id == actuatorId && a.deviceUid == deviceUid) item = a;
      }
      return _ActuatorView(
        item: item,
        pending: item != null && s.isActuatorPending(item),
        openBlock: item != null && item.isValve ? s.valveOpenBlockReason(item) : null,
        canClose: s.capabilities.canCloseActuators,
        canControl: s.capabilities.canControlActuators,
        gasVentilation: item != null && s.isGasVentilationRunning(item),
        canAck: s.capabilities.canAckAlarm,
      );
    });
    final item = view.item;
    if (item == null) return const SizedBox.shrink();
    final kind = actuatorKindOf(item);
    final muted = AppTheme.getTextMuted(context);

    final Widget body = item.isValve ? _valveBody(context, item, view) : _switchBody(context, item, view);
    final family = item.isValve ? valvePosFamily(item.pos) : ((item.on ?? false) ? AppFamilies.amber : AppFamilies.slate);

    return SurfaceCard(
      key: Key('card_actuator_${item.id}'),
      accent: item.fault ? AppFamilies.rose.base : family.base,
      active: item.fault,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OrbIconBadge(icon: kind.icon, family: item.fault ? AppFamilies.rose : family, size: OrbSize.sm, active: !item.isValve && (item.on ?? false)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context)),
                    ),
                    Text(
                      '${kind.label} · Röle ${item.relay}',
                      style: TextStyle(fontSize: AppText.caption, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          body,
        ],
      ),
    );
  }

  Widget _valveBody(BuildContext context, ActuatorItem item, _ActuatorView view) {
    final muted = AppTheme.getTextMuted(context);
    final closed = item.isClosedOrClosing;
    final showOpen = view.canControl &&
        !item.isGasValve &&
        item.pos != ValvePos.open &&
        item.pos != ValvePos.cmdOpen &&
        item.pos != ValvePos.opening;
    final buttons = <Widget>[
      if (view.canClose && !closed)
        OutlinedButton.icon(
          key: Key('btn_actuator_close_${item.id}'),
          style: accentOutlinedButtonStyle(context, AppFamilies.rose, minimumSize: const Size(48, 48)),
          onPressed: view.pending ? null : () => unawaited(confirmAndCloseValves(context, <ActuatorItem>[item])),
          icon: Icon(Icons.lock_rounded, size: accentIconSize(context)),
          label: const Text('Kapat'),
        ),
      if (showOpen)
        OutlinedButton.icon(
          key: Key('btn_actuator_open_${item.id}'),
          style: accentOutlinedButtonStyle(context, AppFamilies.amber, minimumSize: const Size(48, 48)),
          onPressed: (view.pending || view.openBlock != null) ? null : () => unawaited(confirmAndOpenValve(context, item)),
          icon: Icon(Icons.lock_open_rounded, size: accentIconSize(context)),
          label: const Text('Aç'),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            AppPill(label: valvePosLabel(item.pos), family: valvePosFamily(item.pos), icon: valvePosIcon(item.pos)),
            if (item.fault) const AppPill(label: 'Arıza', family: AppFamilies.rose, icon: Icons.error_rounded),
            if (view.pending) const AppPill(label: 'Uygulanıyor…', family: AppFamilies.sky, icon: Icons.sync_rounded),
          ],
        ),
        if (item.isGasValve)
          _note(context, Icons.info_outline_rounded, safetyRejectMessage('gas_local_only'))
        else if (showOpen && view.openBlock != null && !view.pending)
          _note(context, Icons.lock_outline_rounded, safetyRejectMessage(view.openBlock)),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 8, children: buttons),
        ] else if (!item.isGasValve && !view.canControl && closed)
          _note(context, Icons.info_outline_rounded, 'Vanayı ev sahibi ya da ev üyeleri açabilir.', color: muted),
      ],
    );
  }

  Widget _switchBody(BuildContext context, ActuatorItem item, _ActuatorView view) {
    final on = item.on ?? false;
    // Gaz alarmı sürerken çalışan havalandırma fanı: anahtar yalnız alarm onay yetkisi olana (guvenlik-7).
    final allowed = view.gasVentilation ? view.canAck : (on ? view.canClose : view.canControl);
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              AppPill(
                label: on ? 'Çalışıyor' : 'Kapalı',
                family: on ? AppFamilies.amber : AppFamilies.slate,
                icon: on ? Icons.power_rounded : Icons.power_off_rounded,
                active: on,
              ),
              if (item.fault) const AppPill(label: 'Arıza', family: AppFamilies.rose, icon: Icons.error_rounded),
              if (view.pending) const AppPill(label: 'Uygulanıyor…', family: AppFamilies.sky, icon: Icons.sync_rounded),
            ],
          ),
        ),
        if (allowed)
          Semantics(
            label: '${item.name} ${on ? 'kapat' : 'aç'}',
            child: Switch(
              key: Key('switch_actuator_${item.id}'),
              value: on,
              onChanged: view.pending
                  ? null
                  : (value) async {
                      final state = context.read<AutomationState>();
                      if (!value && view.gasVentilation) {
                        final ok = await confirmSafetyAction(
                          context,
                          title: 'Gaz alarmı sürüyor; havalandırma durdurulsun mu?',
                          message: 'Fan, gaz birikmesini önlemek için çalışıyor. Ortam havalandırılmadıysa durdurmayın.',
                          confirmLabel: 'Fanı Durdur',
                          icon: Icons.mode_fan_off_outlined,
                          family: AppFamilies.amber,
                        );
                        if (!ok || !context.mounted) return;
                      }
                      unawaited(runCommand(context, actuatorCommandKey(item), () => state.setActuatorOn(item, value)));
                    },
            ),
          ),
      ],
    );
  }

  Widget _note(BuildContext context, IconData icon, String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon, size: 16, color: color ?? AppTheme.getTextMuted(context))),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: AppText.caption, height: 1.35, color: color ?? AppTheme.getTextPrimary(context)),
              ),
            ),
          ],
        ),
      );
}

/// Güvenlik sensörü hapı: "Kuru" / "Islak" / "Bağlantı yok" (simge + metin; DI haplarından farklı olarak bulut kipinde de
/// görünür).
class SensorStatusPill extends StatelessWidget {
  const SensorStatusPill({super.key, required this.sensor});

  final SensorItem sensor;

  @override
  Widget build(BuildContext context) {
    final status = sensorStatusOf(sensor);
    return Semantics(
      label: '${sensorLabel(sensor)}: ${status.label}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${sensorLabel(sensor)} ',
            style: TextStyle(fontSize: AppText.caption, color: AppTheme.getTextMuted(context)),
          ),
          AppPill(label: status.label, family: status.family, icon: status.icon, active: sensor.ok),
        ],
      ),
    );
  }
}
