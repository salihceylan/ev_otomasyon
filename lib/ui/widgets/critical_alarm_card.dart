import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../dashboard/command_retry.dart';
import '../motion/staggered_entrance.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart';
import 'orb/orb.dart';
import 'safety_labels.dart';
import 'settings/accent_button.dart';
import 'surface_card.dart';

// =============================================================================
// Kritik alarm kartı (WP-A3; tasarım §5.3.3).
//
//  * Panonun EN ÜSTÜNDE durur ([SafetyAlertsPanel]; bulut ve LAN kipinde aynı, K5).
//  * Durum renkle birlikte simge + METİN taşır ("ALARM", "SUSTURULDU", "VANA ARIZASI"): renk tek ipucu değildir.
//  * Tek dokunuş eylemleri ("Sesi Sustur / Alarmı Onayla", "Vanayı Kapat", "Vanayı Aç") bir onay diyaloğuyla
//    ([showSimpleConfirm] -> `showAppDialog`) doğrulanır; komut hatası kabuktaki tek hata abonesinde gösterilir.
//  * Hareket v3: yalnız tek seferlik giriş ([StaggeredEntrance]); yanıp sönme/sonsuz döngü YOK. `MotionScope.off`'ta
//    (testlerin varsayılanı) süre 0: tek karede tam görünür. Başlık ekran okuyucu için canlı bölgedir (`liveRegion`).
//  * Misafir: vanayı kapatabilir; alarmı onaylayamaz ve vanayı AÇAMAZ (düğme hiç çizilmez).
//
// Anahtarlar: `Key('panel_safety_alerts')`, `Key('card_critical_alarm_<uid>_<bölge>')`, `Key('critical_alarm_title_<bölge>')`,
// `Key('btn_alarm_ack_<bölge>')`, `Key('btn_alarm_close_valve_<bölge>')`, `Key('card_water_cut_<eylemci>')`,
// `Key('btn_water_open_<eylemci>')`, `Key('card_safety_safe_mode')`, `Key('card_safety_test_<uid>_<bölge>')`,
// onay diyaloğu `Key('btn_safety_confirm')` / `Key('btn_safety_cancel')`.
// =============================================================================

/// Komut hattı anahtarları (yeniden dene kaydı için; `AutomationState` ile aynı biçim: pano kapsamlı).
String actuatorCommandKey(ActuatorItem a) => a.deviceUid == null ? 'actuator:${a.id}' : 'actuator:${a.id}@${a.deviceUid}';
String alarmAckCommandKey(AlarmItem a) =>
    a.deviceUid == null ? 'alarm:ack:${a.zone}' : 'alarm:ack:${a.zone}@${a.deviceUid}';

/// Güvenlik onay diyaloğu (ortak kabuk, `showAppDialog`). Onaylanırsa `true`.
Future<bool> confirmSafetyAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  IconData icon = Icons.shield_outlined,
  AccentFamily family = AppFamilies.sky,
}) =>
    showSimpleConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      icon: icon,
      family: family,
      cancelKey: const Key('btn_safety_cancel'),
      confirmKey: const Key('btn_safety_confirm'),
    );

/// Vanaları kapatma onayı + komut(lar). Onaylanırsa her açık/belirsiz vana için `closeValve` gönderilir.
Future<void> confirmAndCloseValves(BuildContext context, List<ActuatorItem> valves) async {
  if (valves.isEmpty) return;
  final state = context.read<AutomationState>();
  final names = valves.map((v) => v.name).join(', ');
  final ok = await confirmSafetyAction(
    context,
    title: valves.length == 1 ? 'Vana kapatılsın mı?' : 'Vanalar kapatılsın mı?',
    message: '$names kapatılacak; akış kesilir. Kapatmak her zaman güvenlidir.',
    confirmLabel: 'Vanayı Kapat',
    icon: Icons.water_damage_outlined,
  );
  if (!ok || !context.mounted) return;
  for (final v in valves) {
    unawaited(runCommand(context, actuatorCommandKey(v), () => state.closeValve(v)));
  }
}

/// Vana açma onayı + komut (iyimser DEĞİL: pano onaylayana kadar "Açılıyor…").
Future<void> confirmAndOpenValve(BuildContext context, ActuatorItem valve) async {
  final state = context.read<AutomationState>();
  final ok = await confirmSafetyAction(
    context,
    title: 'Vana açılsın mı?',
    message: '${valve.name} açılacak ve su akışı yeniden başlayacak. Sızıntının giderildiğinden emin olun.',
    confirmLabel: 'Vanayı Aç',
    icon: Icons.water_drop_outlined,
    family: AppFamilies.amber,
  );
  if (!ok || !context.mounted) return;
  unawaited(runCommand(context, actuatorCommandKey(valve), () => state.openValve(valve)));
}

/// Kartların ortak görünüm modeli (değer eşitliği: `context.select` yalnız güvenlik değişince yeniden kurar).
@immutable
class SafetyAlertsView {
  const SafetyAlertsView({
    this.alarms = const <AlarmItem>[],
    this.actuators = const <ActuatorItem>[],
    this.sensors = const <SensorItem>[],
    this.safeModeUids = const <String>[],
    this.pending = const <String>[],
    this.openBlocks = const <String, String?>{},
    this.canAck = false,
    this.canClose = false,
    this.canControl = false,
  });

  static const SafetyAlertsView empty = SafetyAlertsView();

  final List<AlarmItem> alarms;
  final List<ActuatorItem> actuators;
  final List<SensorItem> sensors;
  final List<String> safeModeUids;

  /// Bekleyen komut etiketleri: `a:<uid>:<eylemci>` ve `ack:<uid>:<bölge>`.
  final List<String> pending;

  /// Vana -> açma engeli (`a:<uid>:<eylemci>` anahtarlı; `null` = açılabilir).
  final Map<String, String?> openBlocks;
  final bool canAck;
  final bool canClose;
  final bool canControl;

  bool get isEmpty => alarms.isEmpty && safeModeUids.isEmpty && !actuators.any(_isWaterCut);

  static String tag(ActuatorItem a) => 'a:${a.deviceUid}:${a.id}';
  static String ackTag(AlarmItem a) => 'ack:${a.deviceUid}:${a.zone}';

  bool isPending(ActuatorItem a) => pending.contains(tag(a));
  bool isAckPending(AlarmItem a) => pending.contains(ackTag(a));
  String? openBlock(ActuatorItem a) => openBlocks[tag(a)];

  /// Bir alarmın bölgesindeki, alarm türünün akışkanına uyan vanalar [K-3] (duman: vana yok; tür bilinmiyorsa hepsi).
  List<ActuatorItem> valvesFor(AlarmItem alarm) => <ActuatorItem>[
        for (final a in actuators)
          if (a.isValve && a.deviceUid == alarm.deviceUid && a.zones.contains(alarm.zone) && _mediumMatches(a, alarm.kind)) a,
      ];

  /// Bölgedeki sensörler. Not: [SensorItem] pano kimliği taşımaz; çok panolu evde aynı bölge numarası birleşir
  /// (yalnız ıslaklık metni/düğme etiketi için kullanılır; komut hedefi alarmın panosudur).
  List<SensorItem> sensorsFor(AlarmItem alarm) => <SensorItem>[
        for (final s in sensors)
          if (s.zone == alarm.zone) s,
      ];

  static bool _mediumMatches(ActuatorItem valve, String kind) {
    if (kind == 'smoke') return false;
    if (kind != 'water' && kind != 'gas') return true;
    return valve.medium == null || valve.medium == kind;
  }

  /// Alarmsız bölgede kapalı su vanası: "Su kesik" bilgi kartı.
  bool _isWaterCut(ActuatorItem a) =>
      a.isValve &&
      !a.isGasValve &&
      a.isClosedOrClosing &&
      !alarms.any((al) => al.isActive && al.deviceUid == a.deviceUid && a.zones.contains(al.zone));

  List<ActuatorItem> get waterCutValves => <ActuatorItem>[for (final a in actuators) if (_isWaterCut(a)) a];

  @override
  bool operator ==(Object other) =>
      other is SafetyAlertsView &&
      other.canAck == canAck &&
      other.canClose == canClose &&
      other.canControl == canControl &&
      listEquals(other.alarms, alarms) &&
      listEquals(other.actuators, actuators) &&
      listEquals(other.sensors, sensors) &&
      listEquals(other.safeModeUids, safeModeUids) &&
      listEquals(other.pending, pending) &&
      mapEquals(other.openBlocks, openBlocks);

  @override
  int get hashCode => Object.hash(
        canAck,
        canClose,
        canControl,
        Object.hashAll(alarms),
        Object.hashAll(actuators),
        Object.hashAll(sensors),
        Object.hashAll(safeModeUids),
        Object.hashAll(pending),
        Object.hashAllUnordered(openBlocks.entries.map((e) => Object.hash(e.key, e.value))),
      );
}

/// Durumdan [SafetyAlertsView] (saf; `context.select` seçicisi).
SafetyAlertsView safetyAlertsOf(AutomationState s) {
  final boards = s.safetyByDevice;
  if (boards.isEmpty) return SafetyAlertsView.empty;
  final actuators = s.actuatorItems;
  final alarms = s.alarmItems;
  final caps = s.capabilities;
  return SafetyAlertsView(
    alarms: alarms,
    actuators: actuators,
    sensors: s.sensorItems,
    safeModeUids: <String>[
      for (final e in boards.entries)
        if (e.value.safeMode) e.key,
    ],
    pending: <String>[
      for (final a in actuators)
        if (s.isActuatorPending(a)) SafetyAlertsView.tag(a),
      for (final a in alarms)
        if (s.isAlarmAckPending(a)) SafetyAlertsView.ackTag(a),
    ],
    openBlocks: <String, String?>{
      for (final a in actuators)
        if (a.isValve) SafetyAlertsView.tag(a): s.valveOpenBlockReason(a),
    },
    canAck: caps.canAckAlarm,
    canClose: caps.canCloseActuators,
    canControl: caps.canControlActuators,
  );
}

/// Panonun üstündeki güvenlik uyarıları: güvenli kip, kritik alarm kartları, bölge testi ve "Su kesik" kartları.
/// Güvenlik desteklemeyen (v:2) panoda ya da uyarı yokken hiçbir şey çizmez (yer kaplamaz).
class SafetyAlertsPanel extends StatelessWidget {
  const SafetyAlertsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, SafetyAlertsView>(safetyAlertsOf);
    if (view.isEmpty) return const SizedBox.shrink(key: Key('panel_safety_alerts'));
    final cards = <Widget>[
      if (view.safeModeUids.isNotEmpty) const _SafeModeCard(),
      for (final alarm in view.alarms)
        if (alarm.isActive)
          CriticalAlarmCard(
            key: Key('card_critical_alarm_${alarm.deviceUid}_${alarm.zone}'),
            alarm: alarm,
            view: view,
          )
        else if (alarm.status == ZoneStatus.test)
          _ZoneTestCard(key: Key('card_safety_test_${alarm.deviceUid}_${alarm.zone}'), alarm: alarm),
      for (final valve in view.waterCutValves) WaterCutCard(key: Key('card_water_cut_${valve.id}'), valve: valve, view: view),
    ];
    return Column(
      key: const Key('panel_safety_alerts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) StaggeredEntrance(index: i, offset: 8, child: cards[i]),
      ],
    );
  }
}

/// Kilitli (latched) ya da vana arızalı (fault) bölgenin kartı.
class CriticalAlarmCard extends StatelessWidget {
  const CriticalAlarmCard({super.key, required this.alarm, required this.view});

  final AlarmItem alarm;
  final SafetyAlertsView view;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final sensors = view.sensorsFor(alarm);
    final valves = view.valvesFor(alarm);
    final wet = sensors.any((s) => s.isWet);
    final openValves = <ActuatorItem>[for (final v in valves) if (!v.isClosedOrClosing && !view.isPending(v)) v];
    final ackPending = view.isAckPending(alarm);
    final fault = alarm.isFault;

    // Başlık: "Su baskını: <ilk kaynak sensör>" (ad yoksa kimlikten okunur ad, kaynak yoksa bölge).
    String? sourceName;
    for (final id in alarm.sources) {
      final match = sensors.where((s) => s.id == id);
      sourceName = match.isEmpty ? sensorIdLabel(id) : sensorLabel(match.first);
      break;
    }
    final title = '${safetyKindTitle(alarm.kind)}: ${sourceName ?? 'Bölge ${alarm.zone}'}';
    final since = epochToDate(alarm.sinceEpoch);
    final subtitle = <String>[
      'Bölge ${alarm.zone}',
      if (since != null) elapsedLabel(since, state.clock.now()),
    ].join(' · ');

    final ({String label, IconData icon, AccentFamily family}) status = fault
        ? (label: 'VANA ARIZASI', icon: Icons.error_rounded, family: AppFamilies.rose)
        : alarm.silenced
            ? (label: 'SUSTURULDU', icon: Icons.volume_off_rounded, family: AppFamilies.amber)
            : (label: 'ALARM', icon: Icons.warning_rounded, family: AppFamilies.rose);

    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);

    final buttons = <Widget>[
      if (view.canAck && !(alarm.silenced && wet))
        ElevatedButton.icon(
          key: Key('btn_alarm_ack_${alarm.zone}'),
          style: accentButtonStyle(AppFamilies.rose, minimumSize: const Size(48, 48)),
          onPressed: ackPending ? null : () => unawaited(_ack(context, wet)),
          icon: Icon(wet ? Icons.volume_off_rounded : Icons.check_rounded, size: accentIconSize(context)),
          label: Text(ackPending ? 'Uygulanıyor…' : (wet && !alarm.silenced ? 'Sesi Sustur' : 'Alarmı Onayla')),
        ),
      if (view.canClose && openValves.isNotEmpty)
        OutlinedButton.icon(
          key: Key('btn_alarm_close_valve_${alarm.zone}'),
          style: accentOutlinedButtonStyle(context, AppFamilies.rose, minimumSize: const Size(48, 48)),
          onPressed: () => unawaited(confirmAndCloseValves(context, openValves)),
          icon: Icon(Icons.water_damage_outlined, size: accentIconSize(context)),
          label: const Text('Vanayı Kapat'),
        ),
    ];

    return SurfaceCard(
      accent: AppFamilies.rose.base,
      active: true,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OrbIconBadge(icon: safetyKindIcon(alarm.kind), family: AppFamilies.rose, size: OrbSize.sm, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      key: Key('critical_alarm_title_${alarm.zone}'),
                      liveRegion: true,
                      header: true,
                      child: Text(
                        title,
                        style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: primary),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: AppText.caption, color: muted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AppPill(label: status.label, family: status.family, icon: status.icon, maxLines: 1),
            ],
          ),
          if (valves.isNotEmpty || fault) const SizedBox(height: 10),
          for (final v in valves)
            _InfoLine(
              icon: valvePosIcon(v.pos),
              color: AppTheme.readableAccent(context, valvePosFamily(v.pos).base),
              text: '${v.name}: ${valvePosLabel(v.pos)}',
            ),
          if (fault)
            _InfoLine(
              icon: Icons.error_rounded,
              color: AppTheme.dangerText(context),
              text: 'Vana kapanmadı! Ana vanayı elle kapatın.',
              bold: true,
            ),
          if (alarm.silenced && wet)
            _InfoLine(
              icon: Icons.volume_off_rounded,
              color: muted,
              text: 'Alarm susturuldu. Vana kapalı kalır; sensör kuruyunca alarmı onaylayın.',
            ),
          if (!view.canAck)
            _InfoLine(
              icon: Icons.info_outline_rounded,
              color: muted,
              text: 'Alarmı ev sahibi ya da ev üyeleri onaylayabilir.',
            ),
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: buttons),
          ],
        ],
      ),
    );
  }

  Future<void> _ack(BuildContext context, bool wet) async {
    final state = context.read<AutomationState>();
    final silence = wet && !alarm.silenced;
    final ok = await confirmSafetyAction(
      context,
      title: silence ? 'Alarm susturulsun mu?' : 'Alarm onaylansın mı?',
      message: silence
          ? 'Siren ve pano zili susar. Vana kapalı kalır; sensör kuruyunca alarmı ayrıca onaylamanız gerekir.'
          : 'Onaylayınca alarm kalkar. Vana güvenlik için KAPALI kalır; suyu ayrıca açmanız gerekir.',
      confirmLabel: silence ? 'Sesi Sustur' : 'Alarmı Onayla',
      icon: silence ? Icons.volume_off_rounded : Icons.check_circle_outline_rounded,
      family: AppFamilies.rose,
    );
    if (!ok || !context.mounted) return;
    unawaited(runCommand(context, alarmAckCommandKey(alarm), () => state.ackAlarm(alarm)));
  }
}

/// Alarmsız bölgede kapalı su vanası: "Su kesik" + (yetkiliyse) "Vanayı Aç". Açma engeli varsa düğme devre dışıdır ve
/// gerekçe yazılır (sensör ıslak / yanıt vermiyor / güvenli kip).
class WaterCutCard extends StatelessWidget {
  const WaterCutCard({super.key, required this.valve, required this.view});

  final ActuatorItem valve;
  final SafetyAlertsView view;

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final pending = view.isPending(valve);
    final block = view.openBlock(valve);
    return SurfaceCard(
      accent: AppFamilies.amber.base,
      active: true,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const OrbIconBadge(icon: Icons.water_damage_outlined, family: AppFamilies.amber, size: OrbSize.sm, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Su kesik',
                      style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context)),
                    ),
                    const SizedBox(height: 2),
                    Text('${valve.name}: ${valvePosLabel(valve.pos)}', style: TextStyle(fontSize: AppText.caption, color: muted)),
                  ],
                ),
              ),
            ],
          ),
          if (view.canControl) ...[
            if (block != null && !pending)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _InfoLine(icon: Icons.lock_outline_rounded, color: muted, text: safetyRejectMessage(block)),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: Key('btn_water_open_${valve.id}'),
                style: accentOutlinedButtonStyle(context, AppFamilies.amber, minimumSize: const Size(48, 48)),
                onPressed: (pending || block != null) ? null : () => unawaited(confirmAndOpenValve(context, valve)),
                icon: Icon(Icons.water_drop_outlined, size: accentIconSize(context)),
                label: Text(pending ? 'Açılıyor…' : 'Vanayı Aç'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SafeModeCard extends StatelessWidget {
  const _SafeModeCard();

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      key: const Key('card_safety_safe_mode'),
      accent: AppFamilies.amber.base,
      active: true,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const OrbIconBadge(icon: Icons.gpp_maybe_outlined, family: AppFamilies.amber, size: OrbSize.sm, active: true),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                safetyRejectMessage('safe_mode'),
                style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700, color: AppTheme.getTextPrimary(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoneTestCard extends StatelessWidget {
  const _ZoneTestCard({super.key, required this.alarm});

  final AlarmItem alarm;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      accent: AppFamilies.sky.base,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const OrbIconBadge(icon: Icons.science_outlined, family: AppFamilies.sky, size: OrbSize.sm),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Bölge ${alarm.zone} testi sürüyor: vanalar kapanır, siren kısa süre çalar.',
              style: TextStyle(fontSize: AppText.body, color: AppTheme.getTextPrimary(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Simge + metin satırı (durum renkle tek başına anlatılmaz).
class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.color, required this.text, this.bold = false});

  final IconData icon;
  final Color color;
  final String text;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppText.caption,
                height: 1.35,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                color: bold ? color : AppTheme.getTextPrimary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
