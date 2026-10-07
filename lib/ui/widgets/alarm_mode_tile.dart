import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../dashboard/command_retry.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart';
import 'orb/orb.dart';
import 'surface_card.dart';

// =============================================================================
// Alarm kipi kutucuğu (Faz 2 WP-I6; tasarım F2.B.9).
//
//  * "Güvenlik ve Eylemciler" bölümünün başında; yalnız panosu hırsız alarmı katmanını bildiren (`state.safety.arm`)
//    evlerde çizilir. Üç seçenek: "Kapalı / Evde / Dışarıda". Kurma da çözme de onay diyaloğuyla ve iyimser DEĞİL
//    (panonun onayına kadar "Uygulanıyor…").
//  * Çıkış gecikmesinde "Çıkış için N sn" geri sayımı (pano `until_up` + `uptime`; yerelde saniyede bir azalır).
//  * Misafir ve servis rolleri ([Capabilities.canArm] yok): seçici çizilmez, yalnız kip metni.
//
// Anahtarlar: `tile_alarm_mode_<uid>`, `chip_arm_<uid>_<off|home|away>`, `arm_pending_<uid>`, `arm_countdown_<uid>`,
// `text_arm_mode_<uid>`; onay diyaloğu `btn_arm_confirm` / `btn_arm_cancel`.
// =============================================================================

/// Kipin kısa adı (seçici).
String armModeLabel(ArmMode mode) {
  switch (mode) {
    case ArmMode.off:
      return 'Kapalı';
    case ArmMode.home:
      return 'Evde';
    case ArmMode.away:
      return 'Dışarıda';
    case ArmMode.unknown:
      return 'Bilinmiyor';
  }
}

/// Kipin durum cümlesi (misafir görünümü, ekran okuyucu).
String armModeSentence(ArmMode mode) {
  switch (mode) {
    case ArmMode.off:
      return 'Alarm kapalı';
    case ArmMode.home:
      return 'Alarm: Evde kurulu';
    case ArmMode.away:
      return 'Alarm: Dışarıda kurulu';
    case ArmMode.unknown:
      return 'Alarm kipi bilinmiyor';
  }
}

/// Kurma / çözme onayı ([showSimpleConfirm]). Onaylanırsa `true`.
Future<bool> confirmArmChange(BuildContext context, ArmMode mode) {
  final disarm = mode == ArmMode.off;
  return showSimpleConfirm(
    context,
    title: disarm ? 'Alarm çözülsün mü?' : 'Alarm "${armModeLabel(mode)}" kipinde kurulsun mu?',
    message: disarm
        ? 'Alarm kapanır; kapı ve pencere açılınca siren çalmaz.'
        : (mode == ArmMode.away
            ? 'Çıkış gecikmesi başlar; süre dolunca açılan kapı, pencere ya da hareket alarmı tetikler.'
            : 'Evde kipinde yalnız çevre (kapı ve pencere) izlenir; hareket sensörleri sayılmaz.'),
    confirmLabel: disarm ? 'Alarmı Çöz' : 'Alarmı Kur',
    icon: disarm ? Icons.lock_open_rounded : Icons.shield_rounded,
    family: disarm ? AppFamilies.amber : AppFamilies.violet,
    cancelKey: const Key('btn_arm_cancel'),
    confirmKey: const Key('btn_arm_confirm'),
  );
}

/// Onay + komut (kabuktaki tek hata abonesi ret metnini gösterir).
Future<void> confirmAndSetArmMode(BuildContext context, String uid, ArmMode mode) async {
  final state = context.read<AutomationState>();
  if (!await confirmArmChange(context, mode) || !context.mounted) return;
  unawaited(runCommand(context, 'arm:$uid', () => state.setArmMode(uid, mode)));
}

@immutable
class _ArmTileVm {
  const _ArmTileVm({required this.boards, required this.pending, required this.canArm});

  final Map<String, ArmState> boards;
  final List<String> pending;
  final bool canArm;

  @override
  bool operator ==(Object other) =>
      other is _ArmTileVm &&
      other.canArm == canArm &&
      mapEquals(other.boards, boards) &&
      listEquals(other.pending, pending);

  @override
  int get hashCode => Object.hash(canArm, Object.hashAllUnordered(boards.entries.map((e) => Object.hash(e.key, e.value))),
      Object.hashAll(pending));
}

_ArmTileVm _vmOf(AutomationState s) {
  final boards = <String, ArmState>{
    for (final e in s.safetyByDevice.entries)
      if (e.value.arm != null) e.key: e.value.arm!,
  };
  return _ArmTileVm(
    boards: boards,
    pending: <String>[for (final uid in boards.keys) if (s.isArmPending(uid)) uid],
    canArm: s.capabilities.canArm,
  );
}

/// Panonun hırsız alarmı katmanı varsa kip seçici; yoksa hiçbir şey çizmez.
class AlarmModeTile extends StatelessWidget {
  const AlarmModeTile({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _ArmTileVm>(_vmOf);
    if (vm.boards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in vm.boards.entries)
          _ArmBoardTile(
            key: Key('tile_alarm_mode_${e.key}'),
            uid: e.key,
            arm: e.value,
            pending: vm.pending.contains(e.key),
            canArm: vm.canArm,
          ),
      ],
    );
  }
}

class _ArmBoardTile extends StatelessWidget {
  const _ArmBoardTile({super.key, required this.uid, required this.arm, required this.pending, required this.canArm});

  final String uid;
  final ArmState arm;
  final bool pending;
  final bool canArm;

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    final armed = arm.mode.isArmed;
    return SurfaceCard(
      accent: (armed ? AppFamilies.violet : AppFamilies.slate).base,
      active: armed,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OrbIconBadge(
                icon: armed ? Icons.shield_rounded : Icons.shield_outlined,
                family: armed ? AppFamilies.violet : AppFamilies.slate,
                size: OrbSize.sm,
                active: armed,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    key: Key('text_arm_mode_$uid'),
                    armModeSentence(arm.mode),
                    style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w800, color: primary),
                  ),
                ),
              ),
              if (!arm.ok)
                const AppPill(label: 'Devre dışı', family: AppFamilies.amber, icon: Icons.gpp_maybe_outlined, maxLines: 1),
            ],
          ),
          if (arm.st == ArmStatus.exit)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ArmCountdownText(
                key: Key('arm_countdown_$uid'),
                uid: uid,
                builder: (s) => 'Çıkış için $s sn',
                style: TextStyle(fontSize: AppText.caption, fontWeight: FontWeight.w700, color: primary),
              ),
            ),
          if (canArm) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in const <ArmMode>[ArmMode.off, ArmMode.home, ArmMode.away])
                  AppChip(
                    key: Key('chip_arm_${uid}_${mode.wire}'),
                    label: armModeLabel(mode),
                    selected: arm.mode == mode,
                    onTap: (pending || arm.mode == mode) ? null : () => unawaited(confirmAndSetArmMode(context, uid, mode)),
                  ),
              ],
            ),
          ],
          if (pending)
            Padding(
              key: Key('arm_pending_$uid'),
              padding: const EdgeInsets.only(top: 8),
              child: Text('Uygulanıyor…', style: TextStyle(fontSize: AppText.caption, color: muted)),
            ),
        ],
      ),
    );
  }
}

/// Pano `until_up`'ından kalan saniyeyi gösterir ve saniyede bir azaltır (yalnız süre varken zamanlayıcı çalışır).
class ArmCountdownText extends StatefulWidget {
  const ArmCountdownText({super.key, required this.uid, required this.builder, this.style});

  final String uid;
  final String Function(int seconds) builder;
  final TextStyle? style;

  @override
  State<ArmCountdownText> createState() => _ArmCountdownTextState();
}

class _ArmCountdownTextState extends State<ArmCountdownText> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = context.read<AutomationState>().armRemainingSec(widget.uid) ?? 0;
    return Text(widget.builder(seconds), style: widget.style);
  }
}
