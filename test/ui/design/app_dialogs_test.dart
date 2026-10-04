import 'package:ev_otomasyon/ui/common/app_dialogs.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `showAppDialog` / `showAppSheet` (hareket v3 §2.2, §3): `showDialog`/`showModalBottomSheet` ile aynı anlam
/// (bariyer, dönüş değeri, tema yakalama), yalnız geçiş farklı. off kipinde tek karede tam görünür; full kipte
/// 320 ms solma + 0.96→1.0 ölçek; ConfirmDialogEntrance rota içinde ikinci kez canlanmaz.
void main() {
  /// [open] düğmeye basınca çağrılır; dönen değer [results]'a yazılır.
  Widget host(Future<Object?> Function(BuildContext) open, List<Object?> results, {MotionMode? mode}) {
    return designHost(
      Builder(
        builder: (context) => ElevatedButton(
          key: const Key('btn_open'),
          onPressed: () async => results.add(await open(context)),
          child: const Text('aç'),
        ),
      ),
      mode: mode,
    );
  }

  Future<Object?> openAlert(BuildContext context, {bool barrierDismissible = true}) => showAppDialog<Object?>(
        context,
        barrierDismissible: barrierDismissible,
        builder: (ctx) => AlertDialog(
          title: const Text('başlık'),
          actions: [
            TextButton(key: const Key('btn_ok'), onPressed: () => Navigator.of(ctx).pop(42), child: const Text('tamam')),
          ],
        ),
      );

  /// Diyaloğu/alt sayfayı taşıyan rotanın geçiş animasyonu (düğme mürekkep sıçraması `hasRunningAnimations`'ı
  /// etkilediği için rota durumuna bakılır).
  AnimationStatus routeStatus(WidgetTester tester, Finder finder) =>
      ModalRoute.of(tester.element(finder.first))!.animation!.status;

  double scaleAbove(WidgetTester tester, Finder finder) {
    var scale = 1.0;
    tester.element(finder.first).visitAncestorElements((a) {
      final w = a.widget;
      if (w is ScaleTransition) scale *= w.scale.value;
      return true;
    });
    return scale;
  }

  testWidgets('off: tek pump ile AlertDialog tam görünür, animasyon yok, pumpAndSettle biter', (tester) async {
    final results = <Object?>[];
    await tester.pumpWidget(host(openAlert, results, mode: MotionMode.off));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(effectiveOpacity(tester, find.text('başlık')), 1.0);
    expect(scaleAbove(tester, find.text('başlık')), 1.0);
    expect(routeStatus(tester, find.text('başlık')), AnimationStatus.completed);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_ok')));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing, reason: 'kapanış da anında');
    expect(results, [42]);
  });

  testWidgets('kapsam yok (testlerin varsayılanı) da off gibi davranır', (tester) async {
    final results = <Object?>[];
    await tester.pumpWidget(host(openAlert, results));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pump();
    expect(effectiveOpacity(tester, find.text('başlık')), 1.0);
    expect(routeStatus(tester, find.text('başlık')), AnimationStatus.completed);
  });

  testWidgets('full: ara karede tek diyalog, solma+ölçek sürüyor; 320 ms sonunda tam görünür', (tester) async {
    final results = <Object?>[];
    await tester.pumpWidget(host(openAlert, results, mode: MotionMode.full));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('başlık'), findsOneWidget);
    final midOpacity = effectiveOpacity(tester, find.text('başlık'));
    expect(midOpacity, greaterThan(0.0));
    expect(midOpacity, lessThan(1.0));
    final midScale = scaleAbove(tester, find.text('başlık'));
    expect(midScale, greaterThanOrEqualTo(0.96));
    expect(midScale, lessThan(1.0));
    await tester.pump(const Duration(milliseconds: 240)); // toplam 320 ms
    expect(effectiveOpacity(tester, find.text('başlık')), closeTo(1.0, 1e-9));
    expect(scaleAbove(tester, find.text('başlık')), closeTo(1.0, 1e-9));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_ok')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(results, [42]);
  });

  testWidgets('disableAnimations full kipi ezer: anında', (tester) async {
    await tester.pumpWidget(designHost(
      Builder(
        builder: (context) => ElevatedButton(
          key: const Key('btn_open'),
          onPressed: () => openAlert(context),
          child: const Text('aç'),
        ),
      ),
      mode: MotionMode.full,
      disableAnimations: true,
    ));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pump();
    expect(effectiveOpacity(tester, find.text('başlık')), 1.0);
    expect(routeStatus(tester, find.text('başlık')), AnimationStatus.completed);
  });

  testWidgets('barrierDismissible: true bariyerle kapanır ve null döner', (tester) async {
    final results = <Object?>[];
    await tester.pumpWidget(host(openAlert, results, mode: MotionMode.full));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(results, [null]);
  });

  testWidgets('barrierDismissible: false bariyerle kapanmaz', (tester) async {
    final results = <Object?>[];
    await tester.pumpWidget(host((c) => openAlert(c, barrierDismissible: false), results));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('tema yakalama: çağıranın Theme ezmesi diyalogda görünür (showDialog gibi)', (tester) async {
    const marker = Color(0xFF123456);
    Color? seen;
    await tester.pumpWidget(designHost(
      Builder(
        builder: (outer) => Theme(
          data: Theme.of(outer).copyWith(primaryColor: marker),
          child: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('btn_open'),
              onPressed: () => showAppDialog<void>(
                context,
                builder: (ctx) {
                  seen = Theme.of(ctx).primaryColor;
                  return const AlertDialog(title: Text('başlık'));
                },
              ),
              child: const Text('aç'),
            ),
          ),
        ),
      ),
      mode: MotionMode.off,
    ));
    await tester.tap(find.byKey(const Key('btn_open')));
    await tester.pumpAndSettle();
    expect(seen, marker);
  });

  group('ConfirmDialogEntrance: çift geçiş yok', () {
    double entranceOpacity(WidgetTester tester) => tester
        .widget<FadeTransition>(
            find.descendant(of: find.byType(ConfirmDialogEntrance), matching: find.byType(FadeTransition)).first)
        .opacity
        .value;

    Widget entranceHost(Future<void> Function(BuildContext, WidgetBuilder) open) => designHost(
          Builder(
            builder: (context) => ElevatedButton(
              key: const Key('btn_open'),
              onPressed: () => open(
                context,
                (_) => const ConfirmDialogEntrance(child: AlertDialog(title: Text('başlık'))),
              ),
              child: const Text('aç'),
            ),
          ),
          mode: MotionMode.full,
        );

    testWidgets('AppDialogRoute içinde kendi giriş animasyonunu yapmaz', (tester) async {
      await tester.pumpWidget(entranceHost((c, b) => showAppDialog<void>(c, builder: b)));
      await tester.tap(find.byKey(const Key('btn_open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(entranceOpacity(tester), 1.0, reason: 'rota geçişi tek animasyondur');
      await tester.pumpAndSettle();
    });

    testWidgets('eski showDialog ile açılınca bugünkü gibi canlanır', (tester) async {
      await tester.pumpWidget(entranceHost((c, b) => showDialog<void>(context: c, builder: b)));
      await tester.tap(find.byKey(const Key('btn_open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(entranceOpacity(tester), lessThan(1.0));
      await tester.pumpAndSettle();
      expect(entranceOpacity(tester), 1.0);
    });
  });

  group('showAppSheet', () {
    Future<Object?> openSheet(BuildContext context) => showAppSheet<Object?>(
          context,
          isScrollControlled: true,
          showDragHandle: true,
          useSafeArea: true,
          builder: (ctx) => TextButton(
            key: const Key('btn_sheet_ok'),
            onPressed: () => Navigator.of(ctx).pop('evet'),
            child: const Text('sayfa'),
          ),
        );

    testWidgets('off: tek pump ile görünür, animasyon yok; dönüş değeri aynen', (tester) async {
      final results = <Object?>[];
      await tester.pumpWidget(host(openSheet, results, mode: MotionMode.off));
      await tester.tap(find.byKey(const Key('btn_open')));
      await tester.pump();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(routeStatus(tester, find.text('sayfa')), AnimationStatus.completed);
      await tester.tap(find.byKey(const Key('btn_sheet_ok')));
      await tester.pump();
      expect(find.byType(BottomSheet), findsNothing);
      expect(results, ['evet']);
    });

    testWidgets('full: kayarak gelir, 320 ms sonunda yerinde; pumpAndSettle biter', (tester) async {
      final results = <Object?>[];
      await tester.pumpWidget(host(openSheet, results, mode: MotionMode.full));
      await tester.tap(find.byKey(const Key('btn_open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(routeStatus(tester, find.text('sayfa')), AnimationStatus.forward);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 230));
      expect(routeStatus(tester, find.text('sayfa')), AnimationStatus.completed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_sheet_ok')));
      await tester.pumpAndSettle();
      expect(results, ['evet']);
    });
  });
}
