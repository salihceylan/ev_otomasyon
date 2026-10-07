import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../dashboard/command_retry.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart';
import 'orb/orb.dart';
import 'safety_labels.dart';
import 'settings/accent_button.dart';
import 'alarm_mode_tile.dart';
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
    this.arms = const <String, ArmState>{},
    this.armPending = const <String>[],
    this.canArm = false,
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

  /// Pano -> hırsız alarmı durumu (F2.B.9); yalnız `alarm`/`entry` kart üretir.
  final Map<String, ArmState> arms;

  /// Kurma/çözme komutu bekleyen panolar.
  final List<String> armPending;
  final bool canArm;

  bool get _hasIntrusionCard => arms.values.any((a) => a.st == ArmStatus.alarm || a.st == ArmStatus.entry);

  bool get isEmpty => alarms.isEmpty && safeModeUids.isEmpty && !actuators.any(_isWaterCut) && !_hasIntrusionCard;

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

  /// Bölgedeki fanlar (gaz alarmında fan satırı; F2.A.6).
  List<ActuatorItem> fansFor(AlarmItem alarm) => <ActuatorItem>[
        for (final a in actuators)
          if (a.kind == ActuatorKind.fan && a.deviceUid == alarm.deviceUid && a.zones.contains(alarm.zone)) a,
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
      other.canArm == canArm &&
      mapEquals(other.arms, arms) &&
      listEquals(other.armPending, armPending) &&
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
        canArm,
        Object.hashAllUnordered(arms.entries.map((e) => Object.hash(e.key, e.value))),
        Object.hashAll(armPending),
      );
}

/// Bildirime dokununca kartı bulup bir kez vurgulamak için kanca (Faz 2 F2.C.6, WP-N3). Kartı sarar; kendi bağlamını
/// [cardKey] ile kaydeder. Vurgu tek seferlik bir çerçeve sönümlemesidir (yanıp sönme yok); süre Hareket v3'ten gelir
/// (`MotionScope.off`'ta 0: tek karede biter).
class SafetyCardHighlight extends StatefulWidget {
  const SafetyCardHighlight({super.key, required this.cardKey, required this.child});

  final String cardKey;
  final Widget child;

  static final Map<String, _SafetyCardHighlightState> _live = <String, _SafetyCardHighlightState>{};
  static final Map<String, int> _counts = <String, int>{};

  /// Kartın bağlamı (ağaçta değilse `null`).
  static BuildContext? contextOf(String cardKey) => _live[cardKey]?.context;

  /// Kartı bir kez vurgular; kart ağaçta değilse `false`.
  static bool highlight(String cardKey) {
    final state = _live[cardKey];
    if (state == null || !state.mounted) return false;
    state._run();
    return true;
  }

  /// Test: kartın kaç kez vurgulandığı.
  @visibleForTesting
  static int highlightCount(String cardKey) => _counts[cardKey] ?? 0;

  @override
  State<SafetyCardHighlight> createState() => _SafetyCardHighlightState();
}

class _SafetyCardHighlightState extends State<SafetyCardHighlight> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this, duration: Duration.zero);

  @override
  void initState() {
    super.initState();
    SafetyCardHighlight._live[widget.cardKey] = this;
  }

  @override
  void didUpdateWidget(SafetyCardHighlight old) {
    super.didUpdateWidget(old);
    if (old.cardKey != widget.cardKey) {
      if (identical(SafetyCardHighlight._live[old.cardKey], this)) SafetyCardHighlight._live.remove(old.cardKey);
      SafetyCardHighlight._live[widget.cardKey] = this;
    }
  }

  @override
  void dispose() {
    if (identical(SafetyCardHighlight._live[widget.cardKey], this)) SafetyCardHighlight._live.remove(widget.cardKey);
    _fade.dispose();
    super.dispose();
  }

  void _run() {
    SafetyCardHighlight._counts[widget.cardKey] = SafetyCardHighlight.highlightCount(widget.cardKey) + 1;
    _fade.duration = MotionScope.durationOf(context, const Duration(milliseconds: 1400));
    unawaited(_fade.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fade,
      child: widget.child,
      builder: (context, child) {
        final active = _fade.isAnimating;
        if (!active) return child!;
        final alpha = (1 - Curves.easeOut.transform(_fade.value)).clamp(0.0, 1.0);
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppFamilies.rose.base.withValues(alpha: alpha), width: 3),
          ),
          child: child,
        );
      },
    );
  }
}

/// Durumdan [SafetyAlertsView] (saf; `context.select` seçicisi).
SafetyAlertsView safetyAlertsOf(AutomationState s) {
  final boards = s.safetyByDevice;
  if (boards.isEmpty) return SafetyAlertsView.empty;
  final arms = <String, ArmState>{
    for (final e in boards.entries)
      if (e.value.arm != null) e.key: e.value.arm!,
  };
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
    arms: arms,
    armPending: <String>[for (final uid in arms.keys) if (s.isArmPending(uid)) uid],
    canArm: caps.canArm,
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
          SafetyCardHighlight(
            cardKey: 'card_critical_alarm_${alarm.deviceUid}_${alarm.zone}',
            child: CriticalAlarmCard(
              key: Key('card_critical_alarm_${alarm.deviceUid}_${alarm.zone}'),
              alarm: alarm,
              view: view,
            ),
          )
        else if (alarm.status == ZoneStatus.test)
          _ZoneTestCard(key: Key('card_safety_test_${alarm.deviceUid}_${alarm.zone}'), alarm: alarm),
      // Hırsız alarmı tehlike kartlarından SONRA (F2.B.9).
      for (final e in view.arms.entries)
        if (e.value.st == ArmStatus.alarm)
          SafetyCardHighlight(
            cardKey: 'card_intrusion_${e.key}',
            child: IntrusionAlarmCard(key: Key('card_intrusion_${e.key}'), uid: e.key, arm: e.value, view: view),
          )
        else if (e.value.st == ArmStatus.entry)
          IntrusionEntryCard(key: Key('card_intrusion_entry_${e.key}'), uid: e.key, view: view),
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
    final instruction = safetyKindInstruction(alarm.kind);
    final fans = alarm.kind == 'gas' ? view.fansFor(alarm) : const <ActuatorItem>[];

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
          if (instruction != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                key: Key('critical_alarm_instruction_${alarm.zone}'),
                container: true,
                child: _InfoLine(
                  icon: alarm.kind == 'gas' ? Icons.air_rounded : Icons.directions_run_rounded,
                  color: AppTheme.dangerText(context),
                  text: instruction,
                  bold: true,
                ),
              ),
            ),
          if (valves.isNotEmpty || fault || fans.isNotEmpty) const SizedBox(height: 10),
          for (final v in valves) ...[
            _InfoLine(
              icon: valvePosIcon(v.pos),
              color: AppTheme.readableAccent(context, valvePosFamily(v.pos).base),
              text: '${v.name}: ${valvePosLabel(v.pos)}',
            ),
            if (v.isGasValve)
              _InfoLine(
                key: Key('note_gas_valve_${v.id}'),
                icon: Icons.lock_outline_rounded,
                color: muted,
                text: kGasValveLocalOnlyNote,
              ),
          ],
          for (final f in fans)
            _InfoLine(
              key: Key('note_gas_fan_${f.id}'),
              icon: f.exproof ? Icons.mode_fan_off_outlined : Icons.block_rounded,
              color: muted,
              text: f.exproof
                  ? (f.on == false ? '${f.name}: Havalandırma fanı kapalı' : '${f.name}: Havalandırma çalışıyor')
                  : '${f.name}: Fan güvenlik gereği çalıştırılmıyor (gaz)',
            ),
          if (fault)
            _InfoLine(
              icon: Icons.error_rounded,
              color: AppTheme.dangerText(context),
              text: valveFaultText(alarm.kind),
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

/// Hırsız alarmı kartı (F2.B.9): başlık, tetikleyen sensör adları, "Alarmı Çöz" (owner/resident; onaylı, iyimser değil).
/// Anahtarlar: `card_intrusion_<uid>`, `btn_disarm_<uid>`.
class IntrusionAlarmCard extends StatelessWidget {
  const IntrusionAlarmCard({super.key, required this.uid, required this.arm, required this.view});

  final String uid;
  final ArmState arm;
  final SafetyAlertsView view;

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    final pending = view.armPending.contains(uid);
    final names = <String>[
      for (final id in arm.srcs)
        () {
          for (final s in view.sensors) {
            if (s.id == id) return sensorLabel(s);
          }
          return sensorIdLabel(id);
        }(),
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
              OrbIconBadge(icon: safetyKindIcon('intrusion'), family: AppFamilies.rose, size: OrbSize.sm, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  header: true,
                  child: Text(
                    safetyKindTitle('intrusion'),
                    style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: primary),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const AppPill(label: 'ALARM', family: AppFamilies.rose, icon: Icons.warning_rounded, maxLines: 1),
            ],
          ),
          if (names.isNotEmpty)
            _InfoLine(icon: Icons.sensors_rounded, color: muted, text: 'Tetikleyen: ${names.join(', ')}'),
          if (!view.canArm)
            _InfoLine(icon: Icons.info_outline_rounded, color: muted, text: 'Alarmı ev sahibi ya da ev üyeleri çözebilir.'),
          if (view.canArm) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton.icon(
                key: Key('btn_disarm_$uid'),
                style: accentButtonStyle(AppFamilies.rose, minimumSize: const Size(48, 48)),
                onPressed: pending ? null : () => unawaited(confirmAndSetArmMode(context, uid, ArmMode.off)),
                icon: Icon(Icons.lock_open_rounded, size: accentIconSize(context)),
                label: Text(pending ? 'Uygulanıyor…' : 'Alarmı Çöz'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Giriş gecikmesi bilgi kartı: "Giriş gecikmesi: 23 sn içinde alarmı çözün." (+ "Alarmı Çöz").
class IntrusionEntryCard extends StatelessWidget {
  const IntrusionEntryCard({super.key, required this.uid, required this.view});

  final String uid;
  final SafetyAlertsView view;

  @override
  Widget build(BuildContext context) {
    final pending = view.armPending.contains(uid);
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
              const OrbIconBadge(icon: Icons.timer_outlined, family: AppFamilies.amber, size: OrbSize.sm, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: ArmCountdownText(
                    uid: uid,
                    builder: (s) => 'Giriş gecikmesi: $s sn içinde alarmı çözün.',
                    style: TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.getTextPrimary(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (view.canArm) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: Key('btn_disarm_$uid'),
                style: accentOutlinedButtonStyle(context, AppFamilies.amber, minimumSize: const Size(48, 48)),
                onPressed: pending ? null : () => unawaited(confirmAndSetArmMode(context, uid, ArmMode.off)),
                icon: Icon(Icons.lock_open_rounded, size: accentIconSize(context)),
                label: Text(pending ? 'Uygulanıyor…' : 'Alarmı Çöz'),
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
  const _InfoLine({super.key, required this.icon, required this.color, required this.text, this.bold = false});

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
