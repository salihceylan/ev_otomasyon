import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/tone_button_surface.dart';

/// Birincil yüzen eylem düğmesi (FAB): **gradyan, cila ve renkli parıltı** taşır; düz `#2563EB` Material FAB'ın yerine geçer.
///
/// `FloatingActionButton` `ButtonStyle.backgroundBuilder` desteklemediğinden tema ile gradyan verilemez
/// ([AppTheme] FAB teması düz yedek olarak kalır). Burada GERÇEK bir [FloatingActionButton] (anlam, odak, ipucu, `Scaffold`
/// yerleşimi/animasyonu aynen) **şeffaf ve yükseltmesiz** çizilir; altına düğmelerle AYNI ortak yüzey ([ToneButtonSurface])
/// konur: aile tonu gradyanı ([ButtonTone]; varsayılan sky → koyu cyan), üst cila (sheen), 1 px parlak kenar ve renkli
/// glow gölgesi. Basınçta yüzey 0.97'ye küçülür ve glow sönümlenir (ANINDA; tween yok), klavye odağında 2 px halka çizilir,
/// pasifken ([onPressed] `null`) opak nötr cam görünür. Mürekkep (metin/simge) gradyanın her ucunda ≥ 4.5:1'dir.
///
/// İki varyant:
/// * **genişletilmiş** ([label] verilir): simge + etiket, hap (örn. `Hesap Ekle`; yükseklik 56 dp, yazı ölçeğiyle genişler);
/// * **yuvarlak** ([label] yok): 56 dp daire, yalnız simge; anlam etiketi için [tooltip] ZORUNLUDUR.
///
/// [Key] doğrudan bu bileşendedir (`find.byKey(Key('btn_add_account'))` tek widget bulur ve dokunuş FAB'a ulaşır).
/// Hero varsayılan KAPALIDIR ([heroTag] `null`): yüzey FAB'ın dışında olduğundan Hero uçuşu gradyansız saydam bir FAB taşırdı;
/// aynı rotada birden çok FAB varsa farklı [heroTag] verin.
///
/// ```dart
/// Scaffold(
///   floatingActionButton: AccentFab(
///     key: const Key('btn_add_account'),
///     onPressed: _create,
///     icon: Icons.person_add_alt_1_rounded,
///     label: 'Hesap Ekle',
///   ),
/// )
/// ```
class AccentFab extends StatefulWidget {
  const AccentFab({
    super.key,
    required this.onPressed,
    required this.icon,
    this.label,
    this.tooltip,
    this.family,
    this.heroTag,
  }) : assert(label != null || tooltip != null, 'yuvarlak FAB (label yok) için tooltip (anlam etiketi) verilmeli');

  /// `null` ⇒ pasif (opak nötr cam; dokunuş yok).
  final VoidCallback? onPressed;
  final IconData icon;

  /// Etiket: verilirse GENİŞLETİLMİŞ varyant (simge + etiket), verilmezse yuvarlak.
  final String? label;

  /// İşaretçi ipucu ve (yuvarlak varyantta) anlam etiketi.
  final String? tooltip;

  /// Renk ailesi (`null` ⇒ tema birincil gradyanı: sky → koyu cyan).
  final AccentFamily? family;

  /// Hero etiketi (`null` ⇒ Hero yok; bkz. sınıf belgesi).
  final Object? heroTag;

  /// FAB yüksekliği / yuvarlak çapı (Material 3: 56 dp; dokunma hedefi ≥ 48 dp).
  static const double size = 56;

  /// Genişletilmiş varyantın yatay dolgusu (tema `extendedPadding` ile aynı).
  static const double extendedPadding = 22;

  @override
  State<AccentFab> createState() => _AccentFabState();
}

class _AccentFabState extends State<AccentFab> {
  bool _pressed = false;
  bool _focused = false;
  int? _pointer;
  Offset _origin = Offset.zero;

  bool get _enabled => widget.onPressed != null;

  @override
  void didUpdateWidget(AccentFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _pressed) {
      _pointer = null;
      _pressed = false;
    }
  }

  // Basılı görünüm parmak değdiği AN (ham işaretçi olayı; `onTapDown`un 100 ms gecikmesi beklenmez). `Listener` hareket
  // yarışına katılmaz: dokunuşu FAB'ın kendi `InkWell`ı işler, gecikme/kuyruk oluşmaz.
  void _down(PointerDownEvent event) {
    if (!_enabled || _pointer != null) return;
    _pointer = event.pointer;
    _origin = event.position;
    setState(() => _pressed = true);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer == _pointer && (event.position - _origin).distance > kTouchSlop) _release();
  }

  void _up(PointerEvent event) {
    if (event.pointer == _pointer) _release();
  }

  void _release() {
    _pointer = null;
    if (mounted && _pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final family = widget.family;
    final tone = family == null ? PrimaryButtonSurface.primaryTone : ButtonTone.fromFamily(family);
    final enabled = _enabled;
    // Pasif: opak cam yüzey + `muted` mürekkep (yüzeyde ≥ 4.5:1); etkin: gradyan ucu ne olursa olsun AA mürekkep.
    final ink = enabled ? tone.ink : AppTheme.getTextMuted(context);
    final states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (_pressed) WidgetState.pressed,
      if (_focused && enabled) WidgetState.focused,
    };
    const shape = StadiumBorder();
    final splash = ink.withValues(alpha: 0.20);
    final overlay = ink.withValues(alpha: 0.12);
    final label = widget.label;

    // Şeffaf, yükseltmesiz FAB: yüzeyin gradyanı/gölgesi altta görünür; Material yalnız mürekkep (ripple), odak ve anlamı verir.
    final Widget fab = label == null
        ? FloatingActionButton(
            onPressed: widget.onPressed,
            tooltip: widget.tooltip,
            heroTag: widget.heroTag,
            backgroundColor: Colors.transparent,
            foregroundColor: ink,
            splashColor: splash,
            focusColor: overlay,
            hoverColor: overlay,
            elevation: 0,
            focusElevation: 0,
            hoverElevation: 0,
            highlightElevation: 0,
            disabledElevation: 0,
            shape: shape,
            child: Icon(widget.icon),
          )
        : FloatingActionButton.extended(
            onPressed: widget.onPressed,
            tooltip: widget.tooltip,
            heroTag: widget.heroTag,
            backgroundColor: Colors.transparent,
            foregroundColor: ink,
            splashColor: splash,
            focusColor: overlay,
            hoverColor: overlay,
            elevation: 0,
            focusElevation: 0,
            hoverElevation: 0,
            highlightElevation: 0,
            disabledElevation: 0,
            shape: shape,
            extendedPadding: const EdgeInsets.symmetric(horizontal: AccentFab.extendedPadding),
            icon: Icon(widget.icon),
            label: Text(label),
          );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
      },
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: RepaintBoundary(
          child: ToneButtonSurface(
            tone: tone,
            states: states,
            dark: dark,
            shape: shape,
            child: fab,
          ),
        ),
      ),
    );
  }
}
