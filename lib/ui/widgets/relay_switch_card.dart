import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../dashboard/command_retry.dart';
import '../dashboard/connection_status.dart';
import '../dashboard/module_badge.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart';
import 'orb/orb.dart';
import 'surface_card.dart';

/// Röle kartının canlı görünüm verisi (`context.select` daraltması; golden/test için de kullanılır).
typedef RelayVm = ({
  bool isOn,
  String name,
  bool pending,
  bool offline,
  bool canControl,
  bool locked,
});

/// Aydınlatma / priz / darbe (tetik) rölesi kartı v2 (Neon Glass).
///
/// * Sol: güç [OrbToggle] (`Key('switch_relay_<kanal>')`): KAPALI = koyu cam orb; AÇIK = amber orb + kartın
///   arkasında radyal "bloom" (statik gradyan, blur yok). Darbe rölesi: sol orb, bolt [OrbButton]
///   (`Key('btn_relay_impulse_<kanal>')`) + altında "Tetikle" (TEK orb: eskiden sağda ikinci, aynı görünümlü
///   etkileşimsiz rozet vardı ve hangisinin düğme olduğu anlaşılmıyordu).
/// * Kartın tamamı dokunuşla aç/kapat (`Key('card_relay_<kanal>')`, [SurfaceCard] `onTap`: parmak değdiği AN kart
///   hafifçe küçülür; eskiden InkWell mürekkebi opak kartın arkasında kalıp hiç görünmüyordu); orb'a dokunuş
///   orb'un kendi `onTap`'ine gider (iç içe dokunmada en içteki kazanır).
/// * Kartın kendisi durumdan **canlı** değerini seçer (`context.select`): ana sayfa her bildirimde
///   yeniden çizilmez; yalnızca değişen kart çizilir.
/// * Komutlar `state.setRelay` (idempotent, 1 tabanlı kanal) ile gider; hata olursa kabuktaki tek abone
///   mesajı gösterir ve "Tekrar dene" sunar (iyimser UI/CommandPipeline aynen).
/// * Bekleyen komut (orb çevresinde dönen yay), çevrimdışı ("son bilinen") ve çocuk kilidi görseli vardır.
/// * Dokunma hedefleri ≥ 48 dp; tüm kart tek bir erişilebilirlik düğümüdür (`toggled`).
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
    final vm = context.select<AutomationState, RelayVm>((s) {
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

    return RelayCardView(
      relay: relay,
      vm: vm,
      onSet: (on) => _set(context, on),
      onImpulse: () => _impulse(context),
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

/// Röle kartının saf (durumsuz) görünümü: [RelaySwitchCard] canlı veriyi bağlar, golden/testler doğrudan kurar.
class RelayCardView extends StatelessWidget {
  const RelayCardView({super.key, required this.relay, required this.vm, this.onSet, this.onImpulse});

  final RelayItem relay;
  final RelayVm vm;
  final ValueChanged<bool>? onSet;
  final VoidCallback? onImpulse;

  @override
  Widget build(BuildContext context) {
    final isImpulse = relay.isImpulse;
    final isOn = vm.isOn && !isImpulse;
    // Çevrimdışıyken "açık" bilgisi son bilinen değerdir: canlı gibi vurgulanmaz (soluk renkli ama
    // OKUNAKLI; kartın tamamı saydamlaştırılmaz, kontrast korunur).
    final live = isOn && !vm.offline;
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);

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
    final dark = AppTheme.isDark(context);

    // Sol orb: lamba/priz = güç anahtarı; darbe çıkışı = "Tetikle" düğmesi (tek orb; etiketi altında).
    final Widget lead = isImpulse
        ? _ImpulseAction(
            relayId: relay.id,
            enabled: vm.canControl,
            pending: vm.pending,
            onTap: () => onImpulse?.call(),
          )
        : OrbToggle(
            key: Key('switch_relay_${relay.id}'),
            value: isOn,
            onChanged: vm.canControl ? (value) => onSet?.call(value) : null,
            icon: Icons.lightbulb_outline_rounded,
            activeIcon: Icons.lightbulb_rounded,
            family: AppFamilies.amber,
            semanticLabel: vm.name,
            size: OrbSize.md,
            pending: vm.pending,
            glowWhenOn: !vm.offline,
            // Çevrimdışı/son bilinen: AÇIK orb aile renginin soluk tonu (parıltısız); dokunuş aynen çalışır.
            dimmed: vm.offline,
            // Dokunuş haptiği `_set` içinde verilir.
            haptic: PressHaptic.none,
          );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Ad KESİLMEZ: 3 (büyük yazıda 4) satıra sarılır (kilit rozetli uzun adlar 1.5 ölçekte 2 satırda kesiliyordu).
        Text(
          vm.name,
          style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w700, color: primary),
          maxLines: cardNameMaxLines(context),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpace.s8,
          runSpacing: 4,
          children: [
            if (vm.pending)
              Text(
                'Uygulanıyor…',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.infoText(context)),
              )
            else if (live)
              // AÇIK (canlı): OPAK amber tonlu hap ([AppPill]; zemin = kart gradyanı + amber .14). Orb'un sıcak halesi ve
              // kartın bloom'u metnin arkasındaki zemini aydınlatır: düz amber metin yerel zeminde koyu temada 1.9-3.9:1
              // kalıyordu (sözcüğün orb'a yakın ucunda en kötüsü). Opak hap zemini halenin ALTINDA kalmaz; kontrast hap
              // yüzeyine göre belirlenir (≥ 4.5:1, iki temada) ve "hangi lambalar açık" taramada daha net seçilir.
              AppPill(label: stateText, family: AppFamilies.amber, maxLines: 1)
            else
              Text(
                stateText,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: muted),
              ),
            if (vm.offline)
              Text(
                'Çevrimdışı • son bilinen',
                style: TextStyle(fontSize: 12, color: AppTheme.dangerText(context)),
              ),
            // Ek modül kanalı rozeti durum satırında (başlık satırında değil): büyük yazıda ve dar kartta ad ile
            // yarışmaz; kartlar arası ortak rozet bileşeni.
            if (relay.isExt) ModuleBadge(text: 'CH ${relay.id - 8}'),
          ],
        ),
      ],
    );

    final Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        lead,
        const SizedBox(width: AppSpace.s12),
        Expanded(child: info),
        if (vm.locked) ...[
          const SizedBox(width: AppSpace.s12),
          const LockBadge(),
        ],
      ],
    );

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
                onImpulse?.call();
              } else {
                onSet?.call(!isOn);
              }
            }
          : null,
      child: SurfaceCard(
        key: Key('card_relay_${relay.id}'),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.s16, vertical: AppSpace.s12),
        accent: live ? AppFamilies.amber.base : null,
        active: live,
        onTap: canTap ? () => onSet?.call(!isOn) : null,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Radyal bloom: açık lambanın kartın arkasında yaydığı ışık (statik gradyan; yalnız alfa akar).
            Positioned(
              left: -AppSpace.s16,
              top: -AppSpace.s12,
              right: -AppSpace.s16,
              bottom: -AppSpace.s12,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: live ? 1.0 : 0.0),
                    duration: MotionScope.durationOf(context, AppMotion.slow),
                    curve: AppMotion.standard,
                    builder: (context, t, _) => t <= 0.001
                        ? const SizedBox.expand()
                        : CustomPaint(
                            painter: _BloomPainter(
                              amount: t,
                              radius: AppRadius.card,
                              dark: dark,
                            ),
                          ),
                  ),
                ),
              ),
            ),
            content,
          ],
        ),
      ),
    );
  }
}

/// Darbe rölesi eylemi: bolt orb + "Tetikle" başlığı (başlığa dokunmak da tetikler).
class _ImpulseAction extends StatelessWidget {
  const _ImpulseAction({
    required this.relayId,
    required this.enabled,
    required this.pending,
    required this.onTap,
  });

  final int relayId;
  final bool enabled;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OrbButton(
            key: Key('btn_relay_impulse_$relayId'),
            icon: Icons.bolt_rounded,
            family: AppFamilies.sky,
            semanticLabel: 'Tetikle',
            size: OrbSize.md,
            pending: pending,
            haptic: PressHaptic.none,
            onTap: enabled ? onTap : null,
          ),
          // Etiket rengi panjur orb etiketleriyle aynı (ana metin); eskiden mavi idi. Sütun orb genişliğindedir
          // (`FittedBox.scaleDown`): büyük yazıda ('Tetikle' 1.5x ≈ 56 dp > orb 52 dp) sol sütun genişleyip metin sütununu
          // lamba/panjur kartlarından 5 dp sağa kaydırmasın.
          ExcludeSemantics(
            child: SizedBox(
              width: OrbSize.md.footprint,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Tetikle',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: enabled ? AppTheme.getTextPrimary(context) : AppTheme.getTextMuted(context),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Açık lamba parıltısı: sol taraftaki orb merkezli, kart yuvarlak köşelerine kırpılı iki katman:
/// (1) geniş, yumuşak amber ışık yayılımı, (2) orb'u saran SIKI sıcak hale (ışık kaynağı hissi).
///
/// Koyu temada amber lacivert kartın üstüne normal alfa karışımıyla binince "donuk kahve" olurdu (turuncu ile mavi
/// tamamlayıcıdır, düşük alfada nötrleşir): koyuda tüm alfalar orb'larla AYNI kuralla [OrbPainter.warmGlowGain] (sıcak
/// tonlar için 1.4) ile çarpılır; ışık rengi parlaklığı yüksek `amber.glow` / `amber.light`'tır. Açık temada (şeftali
/// yıkaması) çarpan yoktur. Statik gradyan: blur / `saveLayer` yok.
class _BloomPainter extends CustomPainter {
  const _BloomPainter({required this.amount, required this.radius, required this.dark});

  final double amount;
  final double radius;
  final bool dark;

  /// Orb yarıçapı ([OrbSize.md] / 2), orb merkezinin kart içi x konumu (dolgu + yarıçap) ve sıkı halenin yarıçapı.
  ///
  /// Sıkı hale orb kenarından en çok ~%60 taşar ve metin sütunundan ÖNCE söner: durum metni ('AÇIK') orb merkezinden
  /// 38 dp (yarıçap + 12 dp boşluk) ötede başlar. Eskiden yarıçap 2.5x idi (65 dp): hale metnin altına giriyor, koyu temada
  /// 'AÇIK' sözcüğünün yerel zemini #987B42'ye çıkıp kontrast 1.9-3.9:1'e düşüyordu.
  static const double orbRadius = 26;
  static const double orbCenterX = AppSpace.s16 + orbRadius;
  static const double tightRadius = orbRadius * 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final center = Offset(orbCenterX, size.height / 2);
    // Koyu temada sıcak ton kazancı (orb parıltısıyla aynı belirteç); alfa 0.92'yi aşmaz.
    final gain = dark ? OrbPainter.warmGlowGain(AppFamilies.amber.glow) : 1.0;
    double alpha(double base) => (base * gain * amount).clamp(0.0, 0.92);

    // (1) Geniş yayılım.
    final wideColor = dark ? AppFamilies.amber.glow : AppFamilies.amber.base;
    final wideAlpha = alpha(dark ? 0.27 : 0.22);
    final wideRadius = size.width * 0.62;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            wideColor.withValues(alpha: wideAlpha),
            wideColor.withValues(alpha: wideAlpha * 0.38),
            wideColor.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.42, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: wideRadius)),
    );

    // (2) Orb çevresinde sıkı hale.
    final tightColor = dark ? AppFamilies.amber.light : AppFamilies.amber.base;
    final tightAlpha = alpha(dark ? 0.30 : 0.20);
    canvas.drawCircle(
      center,
      tightRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            tightColor.withValues(alpha: tightAlpha),
            tightColor.withValues(alpha: tightAlpha * 0.42),
            tightColor.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: tightRadius)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BloomPainter old) => old.amount != amount || old.radius != radius || old.dark != dark;
}
