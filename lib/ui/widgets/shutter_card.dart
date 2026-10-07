import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../dashboard/command_retry.dart';
import '../dashboard/connection_status.dart';
import '../dashboard/gas_switch_guard.dart';
import '../dashboard/module_badge.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'orb/orb.dart';
import 'shutter_visual.dart';
import 'surface_card.dart';

/// Panjur kartının canlı görünüm verisi (`context.select` daraltması; golden/test için de kullanılır).
typedef ShutterVm = ({
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

/// Panjur kartı v2 (Neon Glass). **`shutter.pair` 1 tabanlıdır** (`pair N` = röle `2N-1` YUKARI, `2N` AŞAĞI).
///
/// Sol: [ShutterVisual] (çıta penceresi; hareket sırasında raporlar arasında lineer akar). Orta: yüzde
/// ([AnimatedCount]) + durum metni. Alt: 3 orb (Aç emerald ▲, Durdur rose ■, Kapat sky ▼; hareket yönündeki orb
/// "active") ve altında `Slider` (tür aynı; tema özel iz + orb başparmak; sürükleme penceresini canlı günceller).
///
/// Kart durumdan kendi canlı değerlerini seçer (`context.select`): konum, hareket, bekleyen komut
/// ("uygulanıyor…"), çevrimdışı ("son bilinen") ve çocuk kilidi. Komutlar `state.cmdShutter`
/// ile gider (iyimser UI/CommandPipeline aynen); hata olursa kabuktaki tek abone mesajı gösterir ve
/// "Tekrar dene" sunar. Dokunma hedefleri ≥ 48 dp; yazı ölçeği 1.5/2.0'da taşma olmaz.
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

  /// Son verilen komut (bekleyen orb'u işaretlemek için; yalnızca görsel).
  String? _lastAction;

  int get _pair => widget.shutter.pair;

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ShutterVm>((s) {
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

    return ShutterCardView(
      pair: _pair,
      vm: vm,
      dragValue: _dragValue,
      pendingAction: _lastAction,
      onCommand: _command,
      onDrag: (value) => setState(() => _dragValue = value),
      onDragEnd: _setPosition,
    );
  }

  void _setPosition(int percent) => unawaited(_setPositionGuarded(percent));

  Future<void> _setPositionGuarded(int percent) async {
    HapticFeedback.selectionClick();
    _lastAction = 'pos';
    setState(() => _dragValue = null);
    final state = context.read<AutomationState>();
    if (!await confirmSwitchingDuringGasAlarm(context) || !mounted) return; // F2.A.4
    unawaited(runCommand(context, 'shutter:$_pair', () => state.cmdShutter(_pair, 'pos', percent: percent)));
  }

  void _command(String action) => unawaited(_commandGuarded(action));

  Future<void> _commandGuarded(String action) async {
    HapticFeedback.selectionClick();
    _lastAction = action;
    final state = context.read<AutomationState>();
    if (!await confirmSwitchingDuringGasAlarm(context) || !mounted) return; // F2.A.4
    unawaited(runCommand(context, 'shutter:$_pair', () => state.cmdShutter(_pair, action)));
  }
}

/// Panjur kartının saf (durumsuz) görünümü: [ShutterCard] canlı veriyi bağlar, golden/testler doğrudan kurar.
class ShutterCardView extends StatelessWidget {
  const ShutterCardView({
    super.key,
    required this.pair,
    required this.vm,
    this.dragValue,
    this.pendingAction,
    this.onCommand,
    this.onDrag,
    this.onDragEnd,
  });

  final int pair;
  final ShutterVm vm;

  /// Kaydırıcı sürükleniyorsa anlık değer (pencereyi canlı günceller).
  final double? dragValue;

  /// Bekleyen komut (`up`/`stop`/`down`/`pos`): ilgili orb çevresinde dönen yay.
  final String? pendingAction;
  final void Function(String action)? onCommand;
  final ValueChanged<double>? onDrag;
  final ValueChanged<int>? onDragEnd;

  /// Bu iç genişliğin (kart dolgusu düşülmüş, dp) üstünde kart İKİ PANELİ yan yana dizer: solda ad + pencere + yüzde, sağda
  /// orb eylemleri + kaydırıcı. Izgara kartı mevcut genişliğe yayar ([CardGrid]; eskiden 560 dp'de kesilirdi): tek panjurlu
  /// evde kart tablet/masaüstünde tam genişliğe uzar ve dikey düzen (üç orb 300+ dp arayla, 1100 dp'lik kaydırıcı) seyrelirdi.
  static const double wideBreakpoint = 600;

  /// Kaydırıcı izinin kart içeriğinden içeri payı (dp): temadaki `RoundSliderOverlayShape(overlayRadius: 24)` (başparmak payından
  /// büyük). "Kapalı / Açık" etiketleri bu payla hizalanır.
  static const double _trackInset = 24;

  int get _pair => pair;

  @override
  Widget build(BuildContext context) {
    final dragVal = dragValue;
    final lastAction = pendingAction;
    final sliderValue = (dragVal ?? vm.pos.toDouble()).clamp(0.0, 100.0);
    // Çevrimdışıyken konum son bilinen değerdir: canlı gibi vurgulanmaz (kart saydamlaştırılmaz;
    // metinler okunaklı kalır).
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    final opening = vm.moving && vm.direction == 1;
    final closing = vm.moving && vm.direction == 2;

    String statusText = 'Durdu';
    Color statusColor = muted;
    if (vm.pending) {
      statusText = 'Uygulanıyor…';
      statusColor = AppTheme.infoText(context);
    } else if (opening) {
      statusText = 'Açılıyor…';
      statusColor = AppTheme.readableFamily(context, AppFamilies.emerald);
    } else if (closing) {
      // Rutin kapanma amber "uyarı" gibi okunmasın ve kart kenarı / Kapat orb'u / iz dolgusu (sky) ile çelişmesin:
      // hareket yönü rengi (Açılıyor = emerald, Kapanıyor = sky) metinde de aynıdır.
      statusText = 'Kapanıyor…';
      statusColor = AppTheme.readableFamily(context, AppFamilies.sky);
    }

    final semanticsLabel = [
      '${vm.name} panjur',
      'yüzde ${vm.pos} açık',
      statusText.replaceAll('…', ''),
      if (vm.offline) 'cihaz çevrimdışı, son bilinen durum',
      if (vm.locked) 'çocuk kilidi açık, duvar anahtarı devre dışı',
    ].join(', ');

    // Hareket yönü rengi (Aç = emerald, Kapat/duran = sky).
    final AccentFamily directionFamily = opening ? AppFamilies.emerald : AppFamilies.sky;
    final live = vm.moving && !vm.offline;
    final activePending = vm.pending ? lastAction : null;

    // Kaydırıcı renkleri. Canlı: iz = hareket yönü ailesinin ana tonu, başparmak açık ton (AÇIK temada tema başparmağı ince koyu
    // halka çizer: [OrbSliderThumbShape.outlined]; eskiden pastel başparmak beyaz kartta 1.5-1.8:1 ile kayboluyordu).
    // Çevrimdışı ("son bilinen" konum): pasif durum aktiften SÖNÜK olmalı: iz VE başparmak TEK pasif iz belirteciyle
    // ([AppTheme.getInactiveTrack]: kart ve sayfaya karşı ≥ 3:1 nötr slate, iki temada). Eskiden iz koyu `muted` slate'ti
    // (#4B5B70 ≈ 7:1) ve komşu canlı mavi izden (≈ 3.7:1) daha baskındı.
    final inactive = AppTheme.getInactiveTrack(context);
    final Color trackColor = vm.offline ? inactive : directionFamily.base;
    final Color thumbColor = vm.offline ? inactive : directionFamily.light;

    // Başlık: ad + (kilit / ek modül) rozetleri. Ad KESİLMEZ: 3 (büyük yazıda 4) satıra sarılır.
    final header = Semantics(
      container: true,
      excludeSemantics: true,
      label: semanticsLabel,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              vm.name,
              style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w700, color: primary),
              maxLines: cardNameMaxLines(context),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (vm.locked) ...[
            const SizedBox(width: AppSpace.s8),
            const LockBadge(),
          ],
          if (vm.isExt) ...[
            const SizedBox(width: AppSpace.s8),
            const ModuleBadge(text: 'RS485'),
          ],
        ],
      ),
    );

    // Pencere + yüzde + durum.
    final status = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ShutterVisual(
          position: sliderValue,
          moving: vm.moving,
          dragging: dragVal != null,
          muted: vm.offline,
          accent: (vm.offline || !vm.moving) ? null : directionFamily.light,
        ),
        const SizedBox(width: AppSpace.s16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedCount(
                value: sliderValue.round(),
                format: (v) => '%$v',
                duration: AppMotion.base,
                style: TextStyle(
                  fontSize: AppText.metric,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  color: vm.offline ? muted : primary,
                ),
              ),
              const SizedBox(height: 2),
              Wrap(
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (vm.pending) ProgressArc(diameter: 14, color: statusColor, strokeWidth: 2),
                  Text(
                    statusText,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: statusColor),
                  ),
                  if (vm.moving && vm.target != null)
                    Text('Hedef %${vm.target}', style: TextStyle(fontSize: 12, color: muted)),
                ],
              ),
              if (vm.offline)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Çevrimdışı • son bilinen',
                    style: TextStyle(fontSize: 12, color: AppTheme.dangerText(context)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    // Orb eylemleri (Aç / Durdur / Kapat).
    final actions = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _OrbAction(
            buttonKey: Key('btn_shutter_up_$_pair'),
            iconBuilder: OrbIcons.triangle(up: true),
            label: 'Aç',
            semanticsLabel: '${vm.name} panjuru aç',
            family: AppFamilies.emerald,
            active: opening && !vm.offline,
            dimmed: vm.offline,
            pending: activePending == 'up',
            enabled: vm.canControl,
            onTap: () => onCommand?.call('up'),
          ),
        ),
        Expanded(
          child: _OrbAction(
            buttonKey: Key('btn_shutter_stop_$_pair'),
            icon: Icons.stop_rounded,
            label: 'Durdur',
            semanticsLabel: '${vm.name} panjuru durdur',
            family: AppFamilies.rose,
            active: false,
            dimmed: vm.offline,
            pending: activePending == 'stop',
            enabled: vm.canControl,
            onTap: () => onCommand?.call('stop'),
          ),
        ),
        Expanded(
          child: _OrbAction(
            buttonKey: Key('btn_shutter_down_$_pair'),
            iconBuilder: OrbIcons.triangle(up: false),
            label: 'Kapat',
            semanticsLabel: '${vm.name} panjuru kapat',
            family: AppFamilies.sky,
            active: closing && !vm.offline,
            dimmed: vm.offline,
            pending: activePending == 'down',
            enabled: vm.canControl,
            onTap: () => onCommand?.call('down'),
          ),
        ),
      ],
    );

    // Konum kaydırıcısı + "Kapalı / Açık" uç etiketleri.
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 8,
        activeTrackColor: trackColor,
        // Pasif iz TEMADAN gelir (GlowSliderTrackShape + inactiveRim: kartta ≥ 3:1); yerel geçersiz kılma yok.
        thumbColor: thumbColor,
        overlayColor: directionFamily.base.withValues(alpha: 0.2),
      ),
      child: Semantics(
        label: '${vm.name} panjur konumu',
        child: Slider(
          key: Key('slider_shutter_$_pair'),
          value: sliderValue,
          min: 0,
          max: 100,
          semanticFormatterCallback: (value) => 'yüzde ${value.round()}',
          onChanged: vm.canControl ? (value) => onDrag?.call(value) : null,
          onChangeEnd: vm.canControl ? (value) => onDragEnd?.call(value.round()) : null,
        ),
      ),
    );
    // Etiketler izin uçlarıyla hizalıdır: iz, temadaki 24 dp'lik overlay payıyla içeriden başlar (eskiden etiket satırı 6 dp
    // dolgulu idi ve etiketler iz uçlarının ~17 dp dışına taşıyordu).
    // Dar kartta + büyük yazıda (320 dp x 2.0) iz payı etiketlere yetmeyebilir: etiketler `Flexible` (taşma yok).
    final scaleLabels = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _trackInset),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text('Kapalı', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
          ),
          const SizedBox(width: AppSpace.s8),
          Flexible(
            child: Text('Açık', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
          ),
        ],
      ),
    );

    return SurfaceCard(
      key: Key('card_shutter_$_pair'),
      accent: live ? directionFamily.base : null,
      active: live,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= wideBreakpoint) {
            // Geniş kart: solda ad + pencere/yüzde, sağda orb eylemleri + kaydırıcı (dikey ortalı).
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [header, const SizedBox(height: AppSpace.s12), status],
                  ),
                ),
                const SizedBox(width: AppSpace.s24),
                Expanded(
                  flex: 6,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [actions, const SizedBox(height: AppSpace.s4), slider, scaleLabels],
                  ),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              const SizedBox(height: AppSpace.s12),
              status,
              const SizedBox(height: AppSpace.s12),
              actions,
              const SizedBox(height: AppSpace.s4),
              slider,
              scaleLabels,
            ],
          );
        },
      ),
    );
  }
}

/// Orb eylem düğmesi + altında başlık. `Key` orb'un kendisindedir (`find.byKey` orb'u bulur).
class _OrbAction extends StatelessWidget {
  const _OrbAction({
    required this.buttonKey,
    this.icon,
    this.iconBuilder,
    required this.label,
    required this.semanticsLabel,
    required this.family,
    required this.active,
    this.dimmed = false,
    required this.pending,
    required this.enabled,
    required this.onTap,
  }) : assert(icon != null || iconBuilder != null);

  final Key buttonKey;
  final IconData? icon;
  final Widget Function(BuildContext context, Color color, double size)? iconBuilder;
  final String label;
  final String semanticsLabel;
  final AccentFamily family;
  final bool active;

  /// Çevrimdışı / son bilinen durum: orb aile renginin soluk tonuna döner, parıltı/nefes yok; dokunuş aynen çalışır
  /// (komut çevrimdışıyken de gönderilebilir, bu yüzden gri "devre dışı" görünüm YANILTICI olurdu).
  final bool dimmed;
  final bool pending;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        OrbButton(
          key: buttonKey,
          icon: icon,
          iconBuilder: iconBuilder,
          family: family,
          semanticLabel: semanticsLabel,
          size: OrbSize.lg,
          active: active,
          dimmed: dimmed,
          pending: pending,
          // Dokunuş haptiği kartta (`HapticFeedback.selectionClick`) verilir.
          haptic: PressHaptic.none,
          onTap: enabled ? onTap : null,
        ),
        const SizedBox(height: 2),
        ExcludeSemantics(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: enabled ? AppTheme.getTextPrimary(context) : AppTheme.getTextMuted(context),
            ),
            maxLines: 1,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
