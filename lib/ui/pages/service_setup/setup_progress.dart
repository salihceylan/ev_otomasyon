import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/ambient_breath.dart';
import '../../widgets/orb/orb.dart';
import 'service_setup_controller.dart';

/// Sihirbazın üst ilerleme şeridi: [total] adet küçük orb + aralarında bağlantı çizgisi.
///
/// * Tamamlanan adımlar (ve tamamlanmış etkin adım) **emerald orb ✓**, etkin adım **sky orb** (ambient saatten
///   nefes alır; yalnız tek orb slot tutar), sorunlu adım rose "!" , bekleyenler **soluk cam** küre (numara).
/// * **Gerçek durum:** [phases] verilirse (sihirbaz her adımın `phaseOf` durumunu verir) şerit adımın GERÇEK tamamlanmasını
///   gösterir: etkin adımdan ÖNCEKİ tüm adımlar eskiden körlemesine yeşil ✓ idi; oysa "Eksik adımlar: 6, 7, 8, 9." yazan
///   teslim ekranında 1-9 yeşil ✓ görünüp aynı ekranda iki çelişen ilerleme anlatısı çıkıyordu. Şimdi: tamamlanan -> emerald ✓,
///   tamamlanmamış önceki adım -> amber "!" (eksik), atlanan (bu oturumda gerekmeyen) adım -> soluk ✓, sorunlu adım -> rose "!".
///   [phases] verilmezse eski kural (öncekiler ✓) geçerlidir.
/// * Adım değişince orb renkleri ve bağlantı çizgileri `base` sürede yumuşakça geçer (şerit sayfa düzeyinde
///   durur, adım içerikleri değişirken yeniden kurulmaz; `MotionMode.off`: anında).
/// * Yalnız görseldir: ekran okuyucuya "Adım n / m" özeti verilir; adımın kendi başlığı iskelette okunur.
class SetupStepStrip extends StatelessWidget {
  const SetupStepStrip({
    super.key,
    required this.step,
    required this.total,
    this.phase = StepPhase.pending,
    this.phases,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 8),
  });

  /// Etkin adım (1 tabanlı).
  final int step;
  final int total;

  /// Etkin adımın durumu (tamamlandı -> emerald, sorun -> rose).
  final StepPhase phase;

  /// Her adımın gerçek durumu (indeks 0 = 1. adım); `null` ise önceki adımlar tamamlanmış varsayılır (eski kural).
  final List<StepPhase>? phases;
  final EdgeInsetsGeometry padding;

  /// Orb yuvası genişliği ve çizgi kalınlığı.
  static const double slot = 24;
  static const double railHeight = 4;

  @override
  Widget build(BuildContext context) {
    final duration = MotionScope.durationOf(context, AppMotion.base);
    // Bekleyen (gelecek) bölüm: pasif iz belirteci (≥ 3:1); eskiden `muted@0.35` ≈ 1.8-2.0:1 idi ve 3 dp'lik iz orblar arasında kayboluyordu.
    final track = AppTheme.getInactiveTrack(context);
    final fraction = total <= 1 ? 1.0 : ((_fillStep - 1) / (total - 1)).clamp(0.0, 1.0);
    // Eksik adımlar renk/simgeyle (amber "!") anlatılır; ekran okuyucu için de söylenir.
    final missing = <int>[for (var i = 1; i <= total; i++) if (_kindFor(i) == _OrbKind.missing) i];
    return Semantics(
      label: 'İlerleme: adım $step / $total${missing.isEmpty ? '' : '. Eksik adımlar: ${missing.join(', ')}'}',
      excludeSemantics: true,
      child: Padding(
        key: const Key('setup_step_strip'),
        padding: padding,
        child: SizedBox(
          height: slot + 2,
          // Sürekli ilerleme çizgisi: tüm genişlikte soluk iz + etkin orba kadar dolan zümrüt gradyan; orblar üstte
          // eşit aralıkla durur (eskiden orbler arası 9 ayrı ≈ 3.5 dp'lik "nokta" bağlantı vardı: çizgi okunmuyordu).
          child: LayoutBuilder(
            builder: (context, constraints) {
              final railWidth = (constraints.maxWidth - slot).clamp(0.0, double.infinity);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: slot / 2,
                    right: slot / 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        color: track,
                      ),
                      child: const SizedBox(height: railHeight),
                    ),
                  ),
                  Positioned(
                    left: slot / 2,
                    child: AnimatedContainer(
                      duration: duration,
                      curve: AppMotion.standard,
                      width: railWidth * fraction,
                      height: railHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        gradient: LinearGradient(colors: [AppFamilies.emerald.light, AppFamilies.emerald.base]),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var i = 1; i <= total; i++) _StripOrb(key: Key('setup_strip_orb_$i'), index: i, kind: _kindFor(i)),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Zümrüt dolgunun ulaştığı orb (1 tabanlı): etkin adım, ama gerçek durum verildiyse BAŞTAN beri kesintisiz tamamlanan
  /// adımların hemen ötesindeki ilk adımla sınırlı (eksik adımlar varsa dolgu onların üstünden "tamamlanmış gibi" geçmez).
  int get _fillStep {
    final real = phases;
    if (real == null) return step;
    var leading = 0;
    for (var i = 0; i < real.length && i < total; i++) {
      final p = real[i];
      if (p != StepPhase.done && p != StepPhase.skipped) break;
      leading++;
    }
    return leading + 1 < step ? leading + 1 : step;
  }

  _OrbKind _kindFor(int i) {
    if (i == step) {
      switch (phase) {
        case StepPhase.done:
          return _OrbKind.done;
        case StepPhase.failed:
          return _OrbKind.failed;
        case StepPhase.pending:
        case StepPhase.working:
        case StepPhase.skipped:
          return _OrbKind.active;
      }
    }
    final real = phases;
    if (real == null || i > real.length) return i < step ? _OrbKind.done : _OrbKind.pending;
    switch (real[i - 1]) {
      case StepPhase.done:
        return _OrbKind.done;
      case StepPhase.skipped:
        return _OrbKind.skipped;
      case StepPhase.failed:
        return _OrbKind.failed;
      case StepPhase.pending:
      case StepPhase.working:
        // Etkin adımdan ÖNCE olup tamamlanmamış: "eksik" (amber "!"); sonrakiler henüz gelinmemiş (numara).
        return i < step ? _OrbKind.missing : _OrbKind.pending;
    }
  }
}

/// Şerit orb türleri: [pending] numaralı soluk küre, [active] etkin adım, [done] tamamlandı (✓), [failed] sorunlu ("!"),
/// [missing] önceki ama tamamlanmamış adım (amber "!"), [skipped] bu oturumda gerekmeyen adım (soluk ✓).
enum _OrbKind { pending, active, done, failed, missing, skipped }

class _OrbColorsTween extends Tween<OrbColors> {
  _OrbColorsTween({super.end});

  @override
  OrbColors lerp(double t) => OrbColors.lerp(begin!, end!, t);
}

class _StripOrb extends StatefulWidget {
  const _StripOrb({super.key, required this.index, required this.kind});

  final int index;
  final _OrbKind kind;

  @override
  State<_StripOrb> createState() => _StripOrbState();
}

class _StripOrbState extends State<_StripOrb> with AmbientBreathMixin<_StripOrb> {
  @override
  bool get wantsBreath => widget.kind == _OrbKind.active;

  OrbColors _colors(Brightness brightness) {
    switch (widget.kind) {
      case _OrbKind.pending:
        // Bekleyen adım: `disabled` takımı (kenarı ≥ 3:1: cam küre koyuda gövde/zemin 1.7:1'de kalıyordu, orb sınırı okunmuyordu).
        return OrbColors.disabled(brightness);
      case _OrbKind.skipped:
        return OrbColors.glass(brightness);
      case _OrbKind.active:
        return OrbColors.family(AppFamilies.sky);
      case _OrbKind.done:
        return OrbColors.family(AppFamilies.emerald);
      case _OrbKind.failed:
        return OrbColors.family(AppFamilies.rose);
      case _OrbKind.missing:
        return OrbColors.family(AppFamilies.amber);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final brightness = dark ? Brightness.dark : Brightness.light;
    final kind = widget.kind;
    final active = kind == _OrbKind.active || kind == _OrbKind.failed;
    final marked = kind == _OrbKind.done || kind == _OrbKind.missing;
    // Yuva 24 dp: etkin 24, tamamlanan/eksik 22, bekleyen/atlanan 20 (orbler arası çizgi ≈ 9-10 dp görünür kalır).
    final diameter = active ? 24.0 : (marked ? 22.0 : 20.0);
    final target = _colors(brightness);
    final clock = breathClock;
    return SizedBox.square(
      dimension: SetupStepStrip.slot,
      child: Center(
        child: TweenAnimationBuilder<OrbColors>(
          tween: _OrbColorsTween(end: target),
          duration: MotionScope.durationOf(context, AppMotion.base),
          curve: AppMotion.standard,
          builder: (context, colors, _) {
            return RepaintBoundary(
              child: SizedBox.square(
                dimension: diameter,
                child: CustomPaint(
                  painter: OrbPainter(
                    colors: colors,
                    dark: dark,
                    glowLevel: active ? 0.7 : (marked ? 0.25 : 0.0),
                    clock: kind == _OrbKind.active ? clock : null,
                  ),
                  child: Center(child: _glyph(colors)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _glyph(OrbColors colors) {
    switch (widget.kind) {
      case _OrbKind.done:
      case _OrbKind.skipped:
        return Icon(Icons.check_rounded, size: 15, color: colors.icon);
      case _OrbKind.failed:
      case _OrbKind.missing:
        return Icon(Icons.priority_high_rounded, size: 15, color: colors.icon);
      case _OrbKind.active:
      case _OrbKind.pending:
        return Padding(
          padding: const EdgeInsets.all(2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${widget.index}',
              style: TextStyle(fontSize: AppTouch.minFontSize, height: 1.0, fontWeight: FontWeight.w800, color: colors.icon),
            ),
          ),
        );
    }
  }
}
