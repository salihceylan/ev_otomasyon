import 'package:flutter/material.dart';

import 'tokens.dart';

// =============================================================================
// WP-V8 TONE: düğmelerin ORTAK gradyan yüzeyi.
//
// Tema düğmesi (ElevatedButton/FilledButton) `ButtonStyle.backgroundBuilder` ile gradyan hap çizer. Ekranlardaki
// yerel `styleFrom(backgroundColor: X)` rengi bu builder'ın ARKASINDA kalıp gradyanla örtülürdü (kırmızı/yeşil/amber/mor
// anlamsal düğmeler mavi gradyana dönerdi). Çözüm: builder'ın `context`'i `_ButtonStyleState`'in bağlamıdır
// (`button_style_button.dart`: `resolvedBackgroundBuilder(context, statesController.value, result)`), yani
// `context.widget` düğmenin kendisidir ve `style` YEREL stildir. [ToneButtonSurface.forStyle] bu yerel stilden rengi,
// şekli ve metin rengini okur; renk yoksa varsayılan (sky → cyan) kalır.
//
// Bu dosya TEK gradyan yüzey gerçeklemesidir: tema ([PrimaryButtonSurface]), `accentButtonStyle` ve
// `destructiveButtonStyle` hepsi [ToneButtonSurface]'i kullanır; kopya gradyan kodu yoktur.
// =============================================================================

/// Bir düğme renginin "tonu": gradyanın iki ucu, gölge rengi ve üzerindeki mürekkep (metin/simge) rengi.
///
/// Kurallar (WCAG AA, test ile ölçülür):
///  * [ink], gradyanın HER ucunda (en açık uç dahil) en az 4.5:1 kontrast verir.
///  * Açık aileler (amber, cyan: ana ton parlaklığı ≥ 0.45) **koyu mürekkep** ([darkInk]) + açıktan ana tona gradyan;
///    diğerleri **beyaz mürekkep** + ana tondan derin tona "zengin" gradyan (ana ton gerekirse AA'ya kadar koyulaşır).
///  * Gradyan soldan sağa akar: [start] en açık uçtur, [end] en koyu uçtur.
@immutable
class ButtonTone {
  const ButtonTone({
    required this.name,
    required this.start,
    required this.end,
    required this.glow,
    required this.ink,
  });

  /// Aileler için ton (önbellekli). Beyaz mürekkepli "zengin" ya da koyu mürekkepli "parlak" biçim, ailenin ana
  /// tonunun parlaklığına göre seçilir.
  factory ButtonTone.fromFamily(AccentFamily family) => _byFamily[family] ??= _compute(family, glow: family.base);

  /// Yerel bir düğme rengi için ton (önbellekli). Renk önce **ailesine oturtulur** ([familyFor]: tam ton eşleşmesi
  /// ya da en yakın ton/doygunluk), böylece aynı anlam (yeşil onay, kırmızı yıkıcı …) hangi API ile verilirse
  /// verilsin AYNI görünür. Hiçbir aileye yakın değilse renkten türetilen özel bir aile kullanılır. Gölge rengi
  /// verilen renktir. Alfa yok sayılır (yalnız opak renkler için çağırın).
  factory ButtonTone.fromColor(Color color) {
    final opaque = color.withValues(alpha: 1.0);
    return _byColor[opaque.toARGB32()] ??= _compute(familyFor(opaque) ?? _derive(opaque), glow: opaque);
  }

  /// Koyu mürekkep: açık tonlu (amber/cyan) gradyanlarda metin/simge rengi.
  static const Color darkInk = Color(0xFF1A1205);

  /// Hedef kontrast: AA eşiği (4.5) + küçük güvenlik payı (yuvarlama ve üst parlaklık katmanı için).
  static const double inkTarget = 4.6;

  /// Ana ton parlaklığı bu değerin üstündeyse koyu mürekkepli "parlak" biçim kullanılır (amber ≈ 0.52, cyan ≈ 0.53;
  /// emerald ≈ 0.36 ve diğerleri beyaz mürekkepli kalır).
  static const double brightLuminance = 0.45;

  /// Oturtmada en çok kabul edilen ton farkı (derece) ve nötr (gri/slate) doygunluk sınırı (HSV).
  static const double maxHueDistance = 30;
  static const double neutralSaturation = 0.25;

  /// Hata ayıklama/test adı: aile adı ('emerald' ...) ya da 'custom' / 'primary'.
  final String name;

  /// Gradyanın sol (en açık) ve sağ (en koyu) ucu; ikisi de opak.
  final Color start;
  final Color end;

  /// Gölge rengi (opak; yüzey alfa uygular). Yerel renkten türeyen tonlarda verilen renktir.
  final Color glow;

  /// Metin ve simge mürekkebi (beyaz ya da [darkInk]).
  final Color ink;

  /// Soldan sağa gradyan (tema düğmesinin eski yönü korunur).
  LinearGradient get gradient => LinearGradient(colors: [start, end]);

  /// En açık uç: beyaz mürekkebin en zor zemini.
  Color get lightest => start.computeLuminance() >= end.computeLuminance() ? start : end;

  /// En koyu uç: koyu mürekkebin en zor zemini.
  Color get darkest => start.computeLuminance() >= end.computeLuminance() ? end : start;

  /// [ink]'in gradyanın iki ucundaki en düşük kontrastı.
  double get inkContrast => wcagContrast(ink, lightest) < wcagContrast(ink, darkest)
      ? wcagContrast(ink, lightest)
      : wcagContrast(ink, darkest);

  @override
  String toString() => 'ButtonTone($name, $start -> $end, ink: $ink)';

  // --- aileye oturtma ----------------------------------------------------------------------------

  /// [color]'ın ait olduğu aile: önce herhangi bir aile tonuyla TAM eşleşme, sonra nötr (gri/slate) denetimi, sonra
  /// en yakın ton ([maxHueDistance] içinde). Yoksa `null` (renkten aile türetilir).
  static AccentFamily? familyFor(Color color) {
    for (final f in AppFamilies.all) {
      if (color == f.base || color == f.light || color == f.deep || color == f.glow) return f;
    }
    final hsv = HSVColor.fromColor(color);
    if (hsv.saturation < neutralSaturation) return AppFamilies.slate;
    AccentFamily? best;
    var bestDistance = maxHueDistance;
    for (final f in _chromatic) {
      final distance = _hueDistance(hsv.hue, HSLColor.fromColor(f.base).hue);
      if (distance <= bestDistance) {
        best = f;
        bestDistance = distance;
      }
    }
    return best;
  }

  static final List<AccentFamily> _chromatic = <AccentFamily>[
    for (final f in AppFamilies.all)
      if (f != AppFamilies.slate) f,
  ];

  static double _hueDistance(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  /// Hiçbir aileye yakın olmayan renk için aile: ana ton verilen renk; açık/derin tonlar HSL açıklığından.
  static AccentFamily _derive(Color base) {
    final hsl = HSLColor.fromColor(base);
    Color shift(double delta) => hsl.withLightness((hsl.lightness + delta).clamp(0.04, 0.96)).toColor();
    return AccentFamily(name: 'custom', light: shift(0.22), base: base, deep: shift(-0.16), glow: shift(0.08));
  }

  // --- ton hesabı ---------------------------------------------------------------------------------

  static final Map<AccentFamily, ButtonTone> _byFamily = <AccentFamily, ButtonTone>{};
  static final Map<int, ButtonTone> _byColor = <int, ButtonTone>{};

  static ButtonTone _compute(AccentFamily f, {required Color glow}) {
    return f.base.computeLuminance() >= brightLuminance ? _bright(f, glow) : _rich(f, glow);
  }

  /// Beyaz mürekkep: sağ uç = derin ton (gerekirse AA'ya kadar koyulaşır); sol uç = derin → ana ton arasında AA'yı
  /// koruyan en açık nokta (en çok 0.45).
  static ButtonTone _rich(AccentFamily f, Color glow) {
    bool ok(Color c) => wcagContrast(Colors.white, c) >= inkTarget;
    final deep = ok(f.deep) ? f.deep : _shade(f.deep, ok, lighter: false);
    var t = 0.0;
    for (var i = 0; i <= 9; i++) {
      final candidate = 0.45 - i * 0.05;
      if (ok(Color.lerp(deep, f.base, candidate)!)) {
        t = candidate;
        break;
      }
    }
    final start = Color.lerp(deep, f.base, t)!;
    // AA sol ucu sınırladıysa (t < 0.45; örn. emerald) gradyan düzleşmesin diye sağ uç da orantılı derinleşir.
    // AA'yı zaten sağlayan aileler (sky, rose, violet, slate) için bu terim 0'dır: uç = ailenin derin tonu.
    final end = Color.lerp(deep, Colors.black, (0.45 - t) * 0.5)!;
    return ButtonTone(name: f.name, start: start, end: end, glow: glow, ink: Colors.white);
  }

  /// Koyu mürekkep: sol uç = açık ton, sağ uç = ana ton (koyu mürekkep için gerekirse AA'ya kadar açılır).
  static ButtonTone _bright(AccentFamily f, Color glow) {
    bool ok(Color c) => wcagContrast(darkInk, c) >= inkTarget;
    final end = ok(f.base) ? f.base : _shade(f.base, ok, lighter: true);
    final start = f.light.computeLuminance() > end.computeLuminance() ? f.light : _shade(end, (c) => false, lighter: true, steps: 5);
    return ButtonTone(name: f.name, start: start, end: end, glow: glow, ink: darkInk);
  }

  /// [color]'ın açıklığını [ok] sağlanana kadar (HSL, ton/doygunluk korunur) adım adım değiştirir.
  static Color _shade(Color color, bool Function(Color) ok, {required bool lighter, int steps = 60}) {
    final hsl = HSLColor.fromColor(color);
    var result = color;
    var lightness = hsl.lightness;
    for (var i = 0; i < steps && !ok(result); i++) {
      lightness = (lightness + (lighter ? 0.02 : -0.02)).clamp(0.0, 1.0);
      result = hsl.withLightness(lightness).toColor();
    }
    return result;
  }
}

/// Düğme gradyan yüzeyi (`ButtonStyle.backgroundBuilder` çıktısı): [tone] gradyanlı hap (ya da yerel [shape]),
/// üst cila (sheen), 1 px parlak kenar ve renkli gölge. Basınçta (`pressed`) ölçek 0.97 ve gölge sönümü ANINDA
/// (tween yok). Devre dışıyken düz nötr cam yüzey, gölgesiz ve **OPAK** ([disabledFillDark]/[disabledFillLight]: kart/sayfa
/// zeminine harmanlanmış cam rengi; devre izleri etiketin altından geçmez); [disabledFill] (yerel pasif renk) verilmişse
/// nötr dolgu çizilmez (renk Material katmanında görünür), yalnız kenar çizilir.
///
/// [textInk]/[iconInk] verilirse metin ve simge rengi bunlarla ezilir (`DefaultTextStyle`/`IconTheme` birleştirme):
/// tema düğmesinde `ButtonStyle.iconColor` (beyaz) yerel `foregroundColor`'ın önüne geçtiği için simge ancak böyle
/// doğru renk alır.
///
/// [coversMaterialFill]: düğmenin YEREL `backgroundColor`'ı Material katmanında düz dolgu olarak kalır (tema bunu
/// değiştiremez); basınçta yüzey 0.97 küçülünce kenarında bu düz renk halka olarak görünürdü. Bayrak açıkken basılı
/// durumda yüzeyin altına tam boyutlu, koyulaştırılmış gradyan "kuyu" çizilir: halka yüzeyin tonunda kalır.
class ToneButtonSurface extends StatelessWidget {
  const ToneButtonSurface({
    super.key,
    required this.tone,
    required this.states,
    required this.dark,
    required this.child,
    this.shape,
    this.disabledFill,
    this.textInk,
    this.iconInk,
    this.coversMaterialFill = false,
  });

  /// Düğmenin YEREL stilinden yüzeyi çözer: `backgroundColor` (opak ve [fallbackColor]'dan farklıysa) ton belirler,
  /// `shape` yarıçapı belirler, `foregroundColor`/`iconColor` verilmişse onlara saygı gösterilir; verilmemişse ton
  /// mürekkebi uygulanır. Yerel renk yoksa ([fallbackColor] dahil) [fallbackTone] KALIR (mürekkebe dokunulmaz).
  factory ToneButtonSurface.forStyle({
    Key? key,
    required ButtonStyle? style,
    required Set<WidgetState> states,
    required bool dark,
    required ButtonTone fallbackTone,
    Color? fallbackColor,
    required Widget? child,
  }) {
    final disabled = states.contains(WidgetState.disabled);
    final bg = style?.backgroundColor?.resolve(states);
    final fg = style?.foregroundColor?.resolve(states);
    final iconFg = style?.iconColor?.resolve(states) ?? fg;
    final shape = style?.shape?.resolve(states);

    var tone = fallbackTone;
    var explicitTone = false;
    if (!disabled && bg != null && bg.a >= 1.0 && bg != fallbackColor) {
      tone = ButtonTone.fromColor(bg);
      explicitTone = true;
    }
    final Color? textInk;
    final Color? iconInk;
    if (disabled) {
      textInk = fg;
      iconInk = iconFg;
    } else {
      textInk = fg ?? (explicitTone ? tone.ink : null);
      iconInk = iconFg ?? (explicitTone ? tone.ink : null);
    }
    return ToneButtonSurface(
      key: key,
      tone: tone,
      states: states,
      dark: dark,
      shape: shape,
      disabledFill: disabled ? bg : null,
      textInk: textInk,
      iconInk: iconInk,
      coversMaterialFill: !disabled && bg != null && bg.a > 0,
      child: child,
    );
  }

  final ButtonTone tone;
  final Set<WidgetState> states;
  final bool dark;
  final Widget? child;

  /// Yerel düğme şekli (`null` = hap). Yuvarlatılmış dikdörtgen/stadium `BoxDecoration`, diğerleri `ShapeDecoration`.
  final OutlinedBorder? shape;

  /// Yerel pasif dolgu (varsa nötr dolgu çizilmez).
  final Color? disabledFill;

  /// Metin / simge rengi geçersiz kılma (`null` = dokunma).
  final Color? textInk;
  final Color? iconInk;

  /// Yerel renk Material katmanında dolgu olarak duruyor mu (basılı kuyu çizilsin mi)?
  final bool coversMaterialFill;

  /// Pasif düğmenin OPAK cam dolgusu. Eskiden yarı saydamdı (koyu `white@0.08`, açık `#0B1016@0.06`): sayfa gövdesinde (opak
  /// alt çubuğun dışında) duran pasif düğmenin içinden devre izleri ve çip pinleri etiketin ALTINDAN geçiyordu. Şimdi aynı
  /// cam tonu kart/sayfa zeminine harmanlanmış OPAK renktir: koyu `white@0.05` üstü `#1E293B` (kart), açık `#0B1016@0.06`
  /// üstü `#F1F5F9` (sayfa). (`app_theme.dart` içe aktarılamaz: döngü; renkler `AppTheme.cardDark`/`bgLight` ile aynıdır.)
  /// Temanın opak `muted` pasif etiketi bu dolguda ≥ 4.5:1'dir (koyu ≈ 4.9, açık ≈ 5.6; testle pinli).
  static final Color disabledFillDark = Color.alphaBlend(const Color(0x0DFFFFFF), const Color(0xFF1E293B));
  static final Color disabledFillLight = Color.alphaBlend(const Color(0x0F0B1016), const Color(0xFFF1F5F9));

  /// Pasif cam dolgusu ([dark]: koyu tema).
  static Color disabledFillOf(bool dark) => dark ? disabledFillDark : disabledFillLight;

  /// Basınç ölçeği: parmak değdiği karede anında.
  static const double pressedScale = 0.97;

  /// Material yükseltme gölgesi (dış renkli gölge): dinlenirken [restElevation], basılıyken [pressedElevation], pasifken 0.
  /// Gölge rengi düğme stilinin `shadowColor`ıdır (tema: sky; [toneButtonStyle]: ton parıltı rengi).
  static const double restElevation = 8;
  static const double pressedElevation = 3;

  /// `ButtonStyle.elevation` çözücüsü: pasif 0, basılı [pressedElevation], aksi halde [restElevation].
  static double elevationFor(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) return 0;
    return states.contains(WidgetState.pressed) ? pressedElevation : restElevation;
  }

  static const BorderRadius _pill = BorderRadius.all(Radius.circular(AppRadius.pill));

  /// `BoxDecoration` (hap / yuvarlatılmış dikdörtgen) ya da `ShapeDecoration` (diğer şekiller).
  static Decoration _decoration(
    OutlinedBorder? shape, {
    Color? color,
    Gradient? gradient,
    List<BoxShadow>? shadows,
    BorderSide? side,
  }) {
    if (shape == null || shape is StadiumBorder || shape is RoundedRectangleBorder) {
      return BoxDecoration(
        color: color,
        gradient: gradient,
        borderRadius: shape is RoundedRectangleBorder ? shape.borderRadius : _pill,
        boxShadow: shadows,
        border: side == null ? null : Border.fromBorderSide(side),
      );
    }
    return ShapeDecoration(
      color: color,
      gradient: gradient,
      shadows: shadows,
      shape: shape.copyWith(side: side ?? BorderSide.none),
    );
  }

  Widget? _inked() {
    var result = child;
    if (result == null) return null;
    if (textInk != null) result = DefaultTextStyle.merge(style: TextStyle(color: textInk), child: result);
    if (iconInk != null) result = IconTheme.merge(data: IconThemeData(color: iconInk), child: result);
    return result;
  }

  /// Basılı "kuyu" rengi: gradyan ucunun koyulaştırılmışı.
  static Color _dim(Color c) => Color.lerp(c, Colors.black, 0.32)!;

  @override
  Widget build(BuildContext context) {
    final content = _inked();
    if (states.contains(WidgetState.disabled)) {
      return DecoratedBox(
        key: const ValueKey<String>('tone_glass'),
        decoration: _decoration(
          shape,
          color: disabledFill == null ? disabledFillOf(dark) : null,
          side: BorderSide(color: dark ? const Color(0x1AFFFFFF) : const Color(0x140B1016)),
        ),
        child: content,
      );
    }
    final pressed = states.contains(WidgetState.pressed);
    // Opak gradyan Material'in mürekkep/odak katmanını (ince, altta) örter: klavye odağı görünür kalsın diye odakta
    // kenar 2 px ve mürekkep renginde (yüzeyde ≥ 4.5:1) çizilir.
    final focused = states.contains(WidgetState.focused);
    Widget result = Transform.scale(
      scale: pressed ? pressedScale : 1.0,
      child: DecoratedBox(
        key: const ValueKey<String>('tone_base'),
        decoration: _decoration(
          shape,
          gradient: tone.gradient,
          shadows: [
            BoxShadow(
              color: tone.glow.withValues(alpha: pressed ? 0.20 : (dark ? 0.38 : 0.32)),
              blurRadius: pressed ? 10 : 18,
              offset: Offset(0, pressed ? 3 : 7),
            ),
          ],
        ),
        child: DecoratedBox(
          key: const ValueKey<String>('tone_sheen'),
          decoration: _decoration(
            shape,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white.withValues(alpha: pressed ? 0.08 : 0.22), Colors.white.withValues(alpha: 0)],
              stops: const [0.0, 0.58],
            ),
            side: focused
                ? BorderSide(color: tone.ink.withValues(alpha: 0.95), width: 2)
                : BorderSide(color: Colors.white.withValues(alpha: 0.24)),
          ),
          child: content,
        ),
      ),
    );
    if (pressed && coversMaterialFill) {
      result = DecoratedBox(
        key: const ValueKey<String>('tone_well'),
        decoration: _decoration(shape, gradient: LinearGradient(colors: [_dim(tone.start), _dim(tone.end)])),
        child: result,
      );
    }
    return result;
  }
}

/// Aile renkli birincil düğme stili (`ElevatedButton` türü KALIR): tema gradyanı yerine [family] tonunun gradyanı,
/// aynı hap şekli ve ortak yüzey ([ToneButtonSurface]). `accentButtonStyle` ve `destructiveButtonStyle` bunun
/// ince sarmalayıcılarıdır. Tema (`AppTheme`) olmadan da aynı görünür: yüzey stilin kendi `backgroundBuilder`ıdır.
ButtonStyle toneButtonStyle(AccentFamily family, {Size? minimumSize}) {
  final tone = ButtonTone.fromFamily(family);
  return ElevatedButton.styleFrom(
    minimumSize: minimumSize,
    foregroundColor: tone.ink,
    // Dış renkli gölge (Material yükseltme gölgesi; yüzeyin BoxShadow'u `Clip.antiAlias` ile kırpılır): ton parıltı rengi.
    shadowColor: tone.glow,
    animationDuration: Duration.zero,
    backgroundBuilder: (context, states, child) {
      final disabled = states.contains(WidgetState.disabled);
      return ToneButtonSurface(
        tone: tone,
        states: states,
        dark: Theme.of(context).brightness == Brightness.dark,
        // Metin rengi `foregroundColor`'dan gelir; simge ise tema `iconColor`ı (beyaz) yüzünden ayrıca ezilmelidir.
        iconInk: disabled ? null : tone.ink,
        child: child,
      );
    },
  ).copyWith(elevation: WidgetStateProperty.resolveWith(ToneButtonSurface.elevationFor));
}
