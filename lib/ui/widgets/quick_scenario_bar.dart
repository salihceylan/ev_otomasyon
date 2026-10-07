import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../dashboard/command_retry.dart';
import '../dashboard/endpoint_sections.dart';
import '../dashboard/gas_switch_guard.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'orb/orb.dart';
import 'surface_card.dart';

/// Tek tıkla çalışan toplu komut senaryosu.
class QuickScenario {
  const QuickScenario({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.result,
    required this.icon,
    required this.family,
    required this.commands,
  });

  /// Anahtar: `Key('card_scenario_<id>')`.
  final String id;
  final String title;
  final String subtitle;

  /// Tüm komutlar iletildiğinde gösterilen kısa sonuç.
  final String result;
  final IconData icon;

  /// Orb ve kutucuk vurgusu rengi (Neon Glass ailesi).
  final AccentFamily family;

  /// Kutucuk vurgu rengi (ailenin ana tonu).
  Color get color => family.base;

  /// Sırayla gönderilen toplu komutlar (`AutomationState.cmdAll` kanonik adları).
  final List<String> commands;
}

/// Hazır senaryolar (toplu komutlar; misafire kapalıdır — `canUseGroupCommands`).
///
/// Orb/başlık aileleri panonun anlam haritasından türer (şartname §2.1): 'Tüm Lambalar' amber (lamba), 'Günaydın' emerald
/// (panjur AÇ), 'Evden Çıkıyorum' sky (panjur KAPAT + ışıklar), 'İyi Geceler' violet (gece), 'Panjurları Durdur' rose
/// (panjur kartındaki Durdur ■ ile aynı); beş aile benzersizdir. Simgeler dolu/yuvarlak varyantlardır (orb ağırlığı).
const List<QuickScenario> kQuickScenarios = <QuickScenario>[
  QuickScenario(
    id: 'leaving',
    title: 'Evden Çıkıyorum',
    subtitle: 'Işıkları kapat, panjurları indir',
    result: 'Evden çıkış: ışıklar ve panjurlar için komut iletildi.',
    icon: Icons.exit_to_app_rounded,
    family: AppFamilies.sky,
    commands: <String>['all_lights_off', 'all_shutters_down'],
  ),
  QuickScenario(
    id: 'morning',
    title: 'Günaydın',
    subtitle: 'Panjurları aç',
    result: 'Günaydın: panjurları açma komutu iletildi.',
    icon: Icons.wb_sunny_rounded,
    family: AppFamilies.emerald,
    commands: <String>['all_shutters_up'],
  ),
  QuickScenario(
    id: 'night',
    title: 'İyi Geceler',
    subtitle: 'Işıkları söndür, panjurları kapat',
    result: 'İyi geceler: ışıklar ve panjurlar için komut iletildi.',
    icon: Icons.bedtime_rounded,
    family: AppFamilies.violet,
    commands: <String>['all_lights_off', 'all_shutters_down'],
  ),
  QuickScenario(
    id: 'lights_off',
    title: 'Tüm Lambalar',
    subtitle: 'Hepsini söndür',
    result: 'Tüm lambaları kapatma komutu iletildi.',
    icon: Icons.lightbulb_rounded,
    family: AppFamilies.amber,
    commands: <String>['all_lights_off'],
  ),
  QuickScenario(
    id: 'shutters_stop',
    title: 'Panjurları Durdur',
    subtitle: 'Anlık acil durdurma',
    result: 'Panjurları durdurma komutu iletildi.',
    icon: Icons.stop_circle_rounded,
    family: AppFamilies.rose,
    commands: <String>['all_shutters_stop'],
  ),
];

/// Hızlı senaryo çubuğu.
///
/// Senaryo komutları sırayla `AutomationState.cmdAll` ile gönderilir; **ilk hatada durur** (kısmi
/// uygulama yerine açık bir hata). Hata mesajını ve "Tekrar dene"yi kabuktaki tek abone gösterir;
/// bu widget yalnızca **tüm komutlar iletildiğinde** kısa bir sonuç mesajı gösterir. Çalışırken
/// düğmeler pasiftir (çift dokunuş yok).
///
/// Yerleşim: yeterince genişse (>= 5 x en az kutucuk genişliği) kutucuklar satırı eşit paylaşır; değilse yatay
/// kaydırma. Kaydırmada kutucuk genişliği görünüm genişliğinden türetilir: **bir sonraki kutucuk en az ~28 dp
/// görünür** (kaydırılabilirlik ipucu) ve kaydırma görünümü KIRPMAZ: gölgeler tam çizilir, sağdaki kutucuk sayfa
/// kenar boşluğundan ekran kenarına taşar. Kutucuk genişliği büyük yazıda büyür (sözcük ortasından bölünme yok).
class QuickScenarioBar extends StatefulWidget {
  const QuickScenarioBar({super.key});

  /// Kutucuk aralığı ve ölçek 1.0'daki en az / en çok genişlikleri (dp); sonraki kutucuğun görünen payı.
  static const double tileGap = 8;
  static const double tileMinWidth = 136;
  static const double tileMaxWidth = 188;
  static const double peek = 28;

  /// Kaydırma kipinde bir kutucuğun genişliği: iki (geniş görünümde üç) tam kutucuk + [peek] kadar sonraki kutucuk.
  /// [scale] yazı ölçeğidir (1.0 .. 1.6 arası sıkıştırılır).
  static double scrollTileWidth(double viewport, {double scale = 1.0}) {
    final k = scale.clamp(1.0, 1.6);
    final minWidth = tileMinWidth * k;
    final visible = viewport < 480 ? 2 : 3;
    final w = (viewport - (visible - 1) * tileGap - peek) / visible;
    return w.clamp(minWidth, math.max(tileMaxWidth, minWidth));
  }

  /// Kutucuklar satırı eşit paylaşabilir mi (kaydırma gerekmez)?
  static bool fits(double viewport, {double scale = 1.0}) {
    final n = kQuickScenarios.length;
    return viewport >= n * tileMinWidth * scale.clamp(1.0, 1.6) + (n - 1) * tileGap;
  }

  @override
  State<QuickScenarioBar> createState() => _QuickScenarioBarState();
}

class _QuickScenarioBarState extends State<QuickScenarioBar> {
  String? _running;

  /// Başarı geri bildirimi: hangi senaryo + kaçıncı kez (kart ✓ animasyonunu bu sayaçla tetikler).
  String? _doneId;
  int _doneToken = 0;

  Future<void> _run(QuickScenario scenario) async {
    if (_running != null) return;
    final state = context.read<AutomationState>();
    if (!state.capabilities.canUseGroupCommands) return;
    HapticFeedback.mediumImpact();
    if (!await confirmSwitchingDuringGasAlarm(context) || !mounted || _running != null) return; // F2.A.4
    setState(() => _running = scenario.id);
    var allDelivered = true;
    try {
      for (final command in scenario.commands) {
        final ok = await runCommand(context, 'group:$command', () => state.cmdAll(command));
        if (!ok) {
          allDelivered = false;
          break;
        }
      }
    } finally {
      if (mounted) setState(() => _running = null);
    }
    if (!mounted || !allDelivered) return;
    if (scenario.id == 'leaving') await _offerArmAway(state); // F2.B.9: hayır -> bugünkü davranış aynen
    if (!mounted) return;
    setState(() {
      _doneId = scenario.id;
      _doneToken++;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(scenario.result, style: const TextStyle(fontSize: 13)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// "Evden Çıkıyorum" son adımı (F2.B.9): pano hırsız alarmı kipini destekliyor, kullanıcı kurabilir ve alarm dışarıda
  /// kipte değilse "Alarmı dışarıda kip ile kurayım mı?" sorulur. Hayır: hiçbir şey gönderilmez.
  Future<void> _offerArmAway(AutomationState state) async {
    if (!state.capabilities.canArm) return;
    final targets = <String>[
      for (final e in state.safetyByDevice.entries)
        if (e.value.supportsIntrusion && e.value.arm != null && e.value.arm!.mode != ArmMode.away) e.key,
    ];
    if (targets.isEmpty) return;
    final ok = await showSimpleConfirm(
      context,
      title: 'Alarmı dışarıda kip ile kurayım mı?',
      message: 'Çıkış gecikmesi başlar; süre dolunca açılan kapı, pencere ya da hareket alarmı tetikler.',
      confirmLabel: 'Alarmı Kur',
      cancelLabel: 'Hayır',
      icon: Icons.shield_rounded,
      family: AppFamilies.violet,
      cancelKey: const Key('btn_leaving_arm_cancel'),
      confirmKey: const Key('btn_leaving_arm_confirm'),
    );
    if (!ok || !mounted) return;
    for (final uid in targets) {
      await runCommand(context, 'arm:$uid', () => state.setArmMode(uid, ArmMode.away));
      if (!mounted) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canUse = context.select<AutomationState, bool>((s) => s.capabilities.canUseGroupCommands);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Diğer bölüm başlıklarıyla aynı bileşen: mini orb + 15/800 başlık + sağda sayı rozeti.
        SectionHeader(
          icon: Icons.bolt_rounded,
          title: 'Hızlı Senaryolar',
          badge: '${kQuickScenarios.length} Senaryo',
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
            final fill = QuickScenarioBar.fits(constraints.maxWidth, scale: scale);
            final tileWidth = fill ? null : QuickScenarioBar.scrollTileWidth(constraints.maxWidth, scale: scale);
            Widget card(int i) => _ScenarioCard(
                  scenario: kQuickScenarios[i],
                  enabled: canUse && _running == null,
                  running: _running == kQuickScenarios[i].id,
                  successToken: _doneId == kQuickScenarios[i].id ? _doneToken : 0,
                  width: tileWidth,
                  onTap: () => _run(kQuickScenarios[i]),
                );
            final row = IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < kQuickScenarios.length; i++) ...[
                    if (i > 0) const SizedBox(width: QuickScenarioBar.tileGap),
                    if (fill) Expanded(child: card(i)) else card(i),
                  ],
                ],
              ),
            );
            if (fill) return row;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              // Kırpma YOK: kutucuk gölgeleri görünüm sınırında kesilip arkada sert kenarlı "gölge levhası"
              // oluşturmasın; sağdaki kutucuk sayfa kenar boşluğundan taşarak kaydırılabilirliği gösterir.
              clipBehavior: Clip.none,
              child: row,
            );
          },
        ),
      ],
    );
  }
}

class _ScenarioCard extends StatefulWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.enabled,
    required this.running,
    required this.successToken,
    required this.width,
    required this.onTap,
  });

  final QuickScenario scenario;
  final bool enabled;
  final bool running;

  /// Değişince (ve 0 değilse) kısa ✓ morph'u oynar.
  final int successToken;

  /// Kutucuk genişliği; `null` = üst kısıtın genişliği (satırı eşit paylaşma kipi).
  final double? width;
  final VoidCallback onTap;

  @override
  State<_ScenarioCard> createState() => _ScenarioCardState();
}

class _ScenarioCardState extends State<_ScenarioCard> with SingleTickerProviderStateMixin {
  /// ✓ görünür kalma süresi (≤ 900 ms; sonlu denetleyici, Timer yok).
  late final AnimationController _check = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didUpdateWidget(_ScenarioCard old) {
    super.didUpdateWidget(old);
    if (widget.successToken != old.successToken && widget.successToken != 0 && MotionScope.enabledOf(context)) {
      _check.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _check.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scenario = widget.scenario;
    final enabled = widget.enabled;
    final running = widget.running;
    final textColor = AppTheme.readableFamily(context, scenario.family);
    final onTap = enabled ? widget.onTap : null;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _check,
          builder: (context, _) {
            final done = _check.isAnimating;
            return AnimatedSwitcher(
              duration: MotionScope.durationOf(context, AppMotion.fast),
              reverseDuration: Duration.zero,
              child: OrbIconBadge(
                key: ValueKey<bool>(done),
                icon: done ? Icons.check_rounded : scenario.icon,
                family: scenario.family,
                size: OrbSize.sm,
                active: running || done,
                pending: running,
                status: done ? OrbStatus.success : OrbStatus.none,
                enabled: enabled || running || done,
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        // Yazı boyutları şartname tabanının (12 sp) üstünde: başlık 14 (AppText.body), alt başlık 12.5 (AppText.caption).
        Text(
          scenario.title,
          style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700, color: textColor),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          scenario.subtitle,
          style: TextStyle(fontSize: AppText.caption, color: AppTheme.getTextMuted(context)),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      label: '${scenario.title}. ${scenario.subtitle}${running ? ', çalışıyor' : ''}',
      onTap: onTap,
      child: SizedBox(
        width: widget.width,
        child: Pressable(
          onTap: onTap,
          pressedScale: 0.97,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('card_scenario_${scenario.id}'),
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.card),
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              child: SurfaceCard(
                accent: scenario.color,
                active: running,
                padding: const EdgeInsets.all(12),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
