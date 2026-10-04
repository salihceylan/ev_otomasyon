import 'package:flutter/material.dart';

import '../motion/motion.dart';

// =============================================================================
// Animasyonlu diyalog / alt sayfa yardımcıları (hareket v3 §2.2, §3).
//
//  * [showAppDialog] -> `showDialog` ile BİREBİR aynı anlam (tema yakalama, varsayılan bariyer rengi/etiketi,
//                       SafeArea, kök navigator, dönüş değeri); YALNIZ geçiş farklı: solma + ölçek 0.96→1.0
//                       ([SpringCurve], [AppMotion.slow]); kapanış kısa solma ([AppMotion.fast]).
//  * [showAppSheet]  -> `showModalBottomSheet` ile aynı parametreler; Flutter'ın kayma geçişi korunur, süre
//                       [MotionScope]'a bağlıdır.
//
// `MotionScope.off` (testlerin varsayılanı) ya da `MediaQuery.disableAnimations` -> süre 0: tek karede tam görünür,
// ara durum yok, `pumpAndSettle` biter. Süre, rota oluşturulurken çağıranın context'inden okunur.
// =============================================================================

/// `showDialog` yerine geçer; parametrelerin anlamı ve varsayılanları `showDialog` ile aynıdır.
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool? requestFocus,
}) {
  assert(debugCheckHasMaterialLocalizations(context));

  final NavigatorState navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final CapturedThemes themes = InheritedTheme.capture(from: context, to: navigator.context);
  final enabled = MotionScope.enabledOf(context);

  // `showDialog` de `showRawDialog` üzerinden açar; rota kurucusu dışındaki `builder` yalnız deneysel pencereleme
  // (WindowRegistry) yolunda kullanılır.
  return showRawDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: builder,
    routeBuilder: (BuildContext routeContext, WidgetBuilder _) => AppDialogRoute<T>(
      context: routeContext,
      builder: builder,
      barrierColor:
          barrierColor ?? DialogTheme.of(context).barrierColor ?? Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      themes: themes,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior: traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      requestFocus: requestFocus,
      transitionDuration: enabled ? AppMotion.slow : Duration.zero,
      reverseTransitionDuration: enabled ? AppMotion.fast : Duration.zero,
    ),
  );
}

/// [DialogRoute] ile aynı rota (bariyer, SafeArea, tema, odak); geçişi solma + yaylı ölçek (0.96→1.0) olan sürüm.
/// Kapanışta ölçek sabit kalır, yalnız solar. İçerik [AppDialogScope] ile işaretlenir ki iç giriş animasyonları
/// (ör. `ConfirmDialogEntrance`) ikinci kez canlanmasın.
class AppDialogRoute<T> extends DialogRoute<T> {
  AppDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.requestFocus,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    required this.transitionDuration,
    required this.reverseTransitionDuration,
  });

  @override
  final Duration transitionDuration;

  @override
  final Duration reverseTransitionDuration;

  CurvedAnimation? _fade;
  CurvedAnimation? _scaleCurve;
  Animation<double>? _scale;

  static final Animatable<double> _scaleTween = Tween<double>(begin: 0.96, end: 1.0);

  void _bind(Animation<double> animation) {
    if (_fade?.parent == animation) return;
    _fade?.dispose();
    _scaleCurve?.dispose();
    _fade = CurvedAnimation(parent: animation, curve: AppMotion.standard, reverseCurve: Curves.easeIn);
    // Kapanışta ölçek 1'de kalır (Threshold(0): t > 0 iken 1).
    _scaleCurve = CurvedAnimation(parent: animation, curve: AppMotion.spring, reverseCurve: const Threshold(0));
    _scale = _scaleTween.animate(_scaleCurve!);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    _bind(animation);
    return FadeTransition(
      opacity: _fade!,
      child: ScaleTransition(scale: _scale!, child: AppDialogScope(child: child)),
    );
  }

  @override
  void dispose() {
    _fade?.dispose();
    _scaleCurve?.dispose();
    super.dispose();
  }
}

/// [AppDialogRoute] içeriğini işaretler: altındaki giriş animasyonları rota geçişine bırakılır (çift geçiş yok).
class AppDialogScope extends InheritedWidget {
  const AppDialogScope({super.key, required super.child});

  /// [context] bir [AppDialogRoute] içinde mi? (Bağımlılık kaydetmez.)
  static bool isInside(BuildContext context) => context.getInheritedWidgetOfExactType<AppDialogScope>() != null;

  @override
  bool updateShouldNotify(AppDialogScope oldWidget) => false;
}

/// `showModalBottomSheet` yerine geçer; parametrelerin anlamı ve varsayılanları aynıdır. Flutter'ın kendi kayma
/// geçişi korunur; süre [MotionScope]'a bağlıdır (off -> `AnimationStyle.noAnimation`, full -> [AppMotion.slow]).
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  bool? requestFocus,
}) {
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: backgroundColor,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    requestFocus: requestFocus,
    sheetAnimationStyle:
        MotionScope.enabledOf(context) ? const AnimationStyle(duration: AppMotion.slow) : AnimationStyle.noAnimation,
  );
}
