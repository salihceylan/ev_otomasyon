import 'dart:ui' show SemanticsAction;

import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

List<OrbPainter> orbPainters(WidgetTester tester) =>
    tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<OrbPainter>().toList();

void _noop() {}

OrbButton _orb({
  VoidCallback? onTap = _noop,
  OrbSize size = OrbSize.lg,
  bool active = false,
  bool pending = false,
  OrbStatus status = OrbStatus.none,
  PressHaptic haptic = PressHaptic.none,
  Key? key,
  String label = 'Aç',
}) =>
    OrbButton(
      key: key,
      icon: Icons.arrow_upward_rounded,
      family: AppFamilies.emerald,
      semanticLabel: label,
      size: size,
      onTap: onTap,
      active: active,
      pending: pending,
      status: status,
      haptic: haptic,
    );

void main() {
  // -----------------------------------------------------------------------------------------
  // (a) off: pumpAndSettle takılmaz, bekleyen zamanlayıcı/ticker yok
  // -----------------------------------------------------------------------------------------
  group('off kipte (kapsam yok / off / disableAnimations) hiçbir ambient animasyon KURULMAZ', () {
    final hosts = <String, Widget Function(Widget, AmbientClock)>{
      'kapsam yok': (w, c) => designHost(w, clock: c),
      'MotionMode.off': (w, c) => designHost(w, mode: MotionMode.off, clock: c),
      'disableAnimations': (w, c) => designHost(w, mode: MotionMode.full, clock: c, disableAnimations: true),
    };
    for (final h in hosts.entries) {
      testWidgets('${h.key}: etkin+bekleyen orb tüm biçimleri, pumpAndSettle HİÇ takılmaz', (tester) async {
        final clock = AmbientClock();
        addTearDown(clock.dispose);
        await tester.pumpWidget(
          h.value(
            Wrap(
              children: [
                _orb(active: true, pending: true, status: OrbStatus.success),
                OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline, activeIcon: Icons.lightbulb, family: AppFamilies.amber, semanticLabel: 'L', pending: true),
                const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan, active: true, pending: true),
                GlassIconButton(icon: Icons.settings, onTap: () {}, semanticLabel: 'Ayarlar', showBadge: true),
                GlowDot(color: Colors.green, breathing: true, pulses: 3),
                const ProgressArc(diameter: 40, color: Colors.white),
                const Skeleton(width: 60),
              ],
            ),
            clock,
          ),
        );
        await tester.pumpAndSettle(); // takılırsa zaman aşımı hatası verir
        expect(clock.isTicking, isFalse);
        expect(clock.activeSlots, 0);
        expect(AmbientClock.shared.isTicking, isFalse);
        expect(tester.hasRunningAnimations, isFalse);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('off: durum değişimleri (error/success) sarsıntı/halka animasyonu BAŞLATMAZ', (tester) async {
      await tester.pumpWidget(designHost(_orb()));
      await tester.pumpWidget(designHost(_orb(status: OrbStatus.error)));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(designHost(_orb(status: OrbStatus.success)));
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.byType(PulseRing), findsNothing, reason: 'off kipte halka bile kurulmaz');
      await tester.pumpAndSettle();
    });

    testWidgets('off: etkin orb statik parıltı çizer (painter saatsiz), pending yayı statik', (tester) async {
      await tester.pumpWidget(designHost(_orb(active: true, pending: true)));
      final painters = orbPainters(tester);
      expect(painters, hasLength(1));
      expect(painters.single.clock, isNull);
      expect(find.byType(ProgressArc), findsOneWidget, reason: 'durum yine görülür');
    });
  });

  // -----------------------------------------------------------------------------------------
  // (b) full: sonlu animasyonlar biter, ambient yalnız etkin orb + slot bütçesiyle
  // -----------------------------------------------------------------------------------------
  group('full kip', () {
    testWidgets('etkin olmayan orb: hiçbir sürekli animasyon yok, pumpAndSettle biter', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(onTap: () {}), mode: MotionMode.full, clock: clock));
      await tester.pumpAndSettle();
      expect(clock.isTicking, isFalse);
      expect(clock.activeSlots, 0);
    });

    testWidgets('etkin orb bir slot alır ve saati çalıştırır; ağaçtan kalkınca slot bırakılır ve saat durur', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(active: true), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 1);
      expect(clock.isTicking, isTrue);
      expect(orbPainters(tester).single.clock, same(clock));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 0);
      expect(clock.isTicking, isFalse);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('active true → false: slot bırakılır, saat durur, parıltı statikleşir', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(active: true), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isTrue);
      await tester.pumpWidget(designHost(_orb(active: false), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 0);
      expect(clock.isTicking, isFalse);
      expect(orbPainters(tester).single.clock, isNull);
    });

    testWidgets('slot bütçesi 8: 12 etkin orbtan yalnız 8\'i nefes alır, 4\'ü STATİK kalır', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        designHost(
          Wrap(children: [for (var i = 0; i < 12; i++) _orb(key: Key('o$i'), active: true, size: OrbSize.sm)]),
          mode: MotionMode.full,
          clock: clock,
        ),
      );
      expect(clock.activeSlots, 8);
      final painters = orbPainters(tester);
      expect(painters, hasLength(12));
      expect(painters.where((p) => p.clock != null), hasLength(8));
      expect(painters.where((p) => p.clock == null), hasLength(4));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('TickerMode(enabled: false) (arka rota): etkin orb nefes ALMAZ', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(TickerMode(enabled: false, child: _orb(active: true)), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 0);
      expect(clock.isTicking, isFalse);
      await tester.pumpWidget(designHost(TickerMode(enabled: true, child: _orb(active: true)), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 1);
      expect(clock.isTicking, isTrue);
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full, clock: clock));
    });

    testWidgets('uygulama arka plana geçince nefes durur, öne dönünce sürer', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(active: true), mode: MotionMode.full, clock: clock));
      await tester.pump(const Duration(milliseconds: 100));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(clock.isTicking, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(clock.isTicking, isTrue);
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isFalse);
    });

    testWidgets('devre dışı orb (onTap null) etkin olsa da nefes almaz (parıltı yok)', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(active: true, onTap: null), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 0);
      expect(clock.isTicking, isFalse);
    });

    testWidgets('sabit saat: nefes deterministik, saat çalışmaz ama slot bütçesi geçerlidir', (tester) async {
      final clock = AmbientClock.fixed(0.65);
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(active: true), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isFalse);
      expect(orbPainters(tester).single.clock, same(clock));
      expect(OrbPainter.breath(0.65, 0), closeTo(1.0, 1e-9), reason: 't = period/4 → tepe');
      await tester.pumpAndSettle();
    });

    testWidgets('success: halka tek sefer oynar ve pumpAndSettle ile biter (450 ms)', (tester) async {
      await tester.pumpWidget(designHost(_orb(), mode: MotionMode.full));
      await tester.pumpWidget(designHost(_orb(status: OrbStatus.success), mode: MotionMode.full));
      expect(find.byType(PulseRing), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('error: kısa sarsıntı (±3 px) + flaş, 420 ms içinde biter; sarsıntı kenar boşluğunu aşmaz', (tester) async {
      await tester.pumpWidget(designHost(_orb(key: const Key('o')), mode: MotionMode.full));
      final x0 = tester.getCenter(find.byKey(const Key('o'))).dx;
      await tester.pumpWidget(designHost(_orb(key: const Key('o'), status: OrbStatus.error), mode: MotionMode.full));
      var maxShift = 0.0;
      var maxFlash = 0.0;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final shift = tester.getCenter(find.byKey(const Key('o'))).dx - x0;
        maxShift = shift.abs() > maxShift ? shift.abs() : maxShift;
        final flash = orbPainters(tester).single.flash;
        maxFlash = flash > maxFlash ? flash : maxFlash;
      }
      // Orb düzen kutusu sabit kalır (sarsıntı yalnız çizim dönüşümüdür); flaş görünür.
      expect(maxShift, lessThanOrEqualTo(3.0 + 1e-6));
      expect(maxFlash, greaterThan(0.2));
      await tester.pumpAndSettle();
      expect(orbPainters(tester).single.flash, 0);
    });

    testWidgets('pending yayı full kipte saati dinler ve 10 sn güvenlik sınırında DURUR', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(pending: true), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isTrue);
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(clock.isTicking, isTrue);
      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(clock.isTicking, isFalse, reason: 'sahibi unutsa bile sonsuz animasyon bırakılmaz');
      await tester.pumpAndSettle();
    });

    testWidgets('pending kalkınca yay ağaçtan çıkar ve saat durur', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(_orb(pending: true), mode: MotionMode.full, clock: clock));
      expect(find.byType(ProgressArc), findsOneWidget);
      await tester.pumpWidget(designHost(_orb(pending: false), mode: MotionMode.full, clock: clock));
      expect(find.byType(ProgressArc), findsNothing);
      expect(clock.isTicking, isFalse);
    });

    testWidgets('GlowDot: pulses=3 sonlu (≈2.7 sn) ve biter; breathing slot alır', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(GlowDot(color: Colors.amber, pulses: 3), mode: MotionMode.full, clock: clock));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 2300));
      expect(tester.hasRunningAnimations, isFalse, reason: '3 nabızdan sonra sabit');
      await tester.pumpAndSettle();

      await tester.pumpWidget(designHost(GlowDot(color: Colors.green, breathing: true), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 1);
      expect(clock.isTicking, isTrue);
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isFalse);
    });
  });

  // -----------------------------------------------------------------------------------------
  // (c) dokunma hedefi ≥ 48 dp, Semantics, devre dışı
  // -----------------------------------------------------------------------------------------
  group('dokunma hedefi ve anlamsal ağaç', () {
    for (final size in OrbSize.values) {
      testWidgets('OrbButton ${size.name} (${size.diameter.toInt()} dp): dokunma kutusu ≥ 48 dp', (tester) async {
        await tester.pumpWidget(designHost(_orb(size: size, onTap: () {})));
        final s = tester.getSize(find.byType(OrbButton));
        expect(s.width, greaterThanOrEqualTo(48));
        expect(s.height, greaterThanOrEqualTo(48));
        expect(s.width, size.footprint);
      });
    }

    testWidgets('sm (44 dp çizim): kutu 48 dp, orb kenarından 2 dp ötesine dokunuş da orb\'u tetikler', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(_orb(size: OrbSize.sm, onTap: () => taps++, key: const Key('o'))));
      final rect = tester.getRect(find.byKey(const Key('o')));
      expect(rect.size, const Size(48, 48));
      await tester.tapAt(rect.topLeft + const Offset(1, 24)); // görsel orb dışı, hedef içi
      expect(taps, 1);
    });

    testWidgets('OrbButton: button + enabled + label, tap eylemi', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(designHost(_orb(onTap: () {}, label: 'Aç')));
      final node = tester.getSemantics(find.byType(OrbButton));
      expect(node.label, 'Aç');
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isEnabled.toBoolOrNull(), isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('OrbButton devre dışı: enabled=false, tap eylemi YOK, onTap çağrılmaz', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(designHost(_orb(onTap: null)));
      final node = tester.getSemantics(find.byType(OrbButton));
      expect(node.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      handle.dispose();
    });

    testWidgets('OrbButton: ekran okuyucu eylemi onTap\'i çağırır', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(designHost(_orb(onTap: () => taps++)));
      tester.semantics.tap(find.semantics.byLabel('Aç'));
      await tester.pump();
      expect(taps, 1);
      handle.dispose();
    });

    for (final on in [true, false]) {
      testWidgets('OrbToggle value=$on: toggled=$on, button, label', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          designHost(OrbToggle(value: on, onChanged: (_) {}, icon: Icons.lightbulb_outline, family: AppFamilies.amber, semanticLabel: 'Salon Avize')),
        );
        final node = tester.getSemantics(find.byType(OrbToggle));
        expect(node.label, 'Salon Avize');
        expect(node.flagsCollection.isToggled.toBoolOrNull(), on);
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.flagsCollection.isEnabled.toBoolOrNull(), isTrue);
        handle.dispose();
      });
    }

    testWidgets('OrbToggle: dokunma hedefi ≥ 48; devre dışı: onChanged çağrılmaz, enabled=false', (tester) async {
      final handle = tester.ensureSemantics();
      var calls = 0;
      await tester.pumpWidget(
        designHost(
          OrbToggle(
            key: const Key('t'),
            value: false,
            onChanged: null,
            icon: Icons.lightbulb_outline,
            family: AppFamilies.amber,
            semanticLabel: 'L',
            size: OrbSize.sm,
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('t'))).shortestSide, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('t')));
      expect(calls, 0);
      expect(tester.getSemantics(find.byKey(const Key('t'))).flagsCollection.isEnabled.toBoolOrNull(), isFalse);
      handle.dispose();
    });

    testWidgets('GlassIconButton: kutu ≥ 48 (görsel 44), rozet etikete eklenir, devre dışı tap yok', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        designHost(
          GlassIconButton(key: const Key('g'), icon: Icons.notifications_none, onTap: () {}, semanticLabel: 'Bildirimler', showBadge: true, badgeSemantics: '2 yeni'),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('g'))), const Size(48, 48));
      expect(find.byKey(const ValueKey('glass_badge_dot')), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const Key('g'))).label, 'Bildirimler, 2 yeni');

      await tester.pumpWidget(designHost(GlassIconButton(key: const Key('g'), icon: Icons.menu, onTap: null, semanticLabel: 'Menü')));
      expect(find.byKey(const ValueKey('glass_badge_dot')), findsNothing);
      final node = tester.getSemantics(find.byKey(const Key('g')));
      expect(node.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      handle.dispose();
    });

    testWidgets('GlassIconButton büyük boyutta (56) kutu büyür; küçükte (36) 48\'e yükselir', (tester) async {
      await tester.pumpWidget(designHost(GlassIconButton(key: const Key('g'), icon: Icons.menu, onTap: () {}, semanticLabel: 'M', size: 56)));
      expect(tester.getSize(find.byKey(const Key('g'))), const Size(56, 56));
      await tester.pumpWidget(designHost(GlassIconButton(key: const Key('g'), icon: Icons.menu, onTap: () {}, semanticLabel: 'M', size: 36)));
      expect(tester.getSize(find.byKey(const Key('g'))), const Size(48, 48));
    });

    testWidgets('OrbIconBadge etkileşimsizdir: dokunuşu yakalamaz, varsayılan olarak anlamsal ağaçta yok', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        designHost(
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const OrbIconBadge(key: Key('b'), icon: Icons.home, family: AppFamilies.cyan),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('b')));
      expect(taps, 1, reason: 'dokunuş alttaki sahibine geçer');
      expect(find.descendant(of: find.byKey(const Key('b')), matching: find.byType(Pressable)), findsNothing);
      expect(find.semantics.byLabel('Ev'), findsNothing);
      handle.dispose();
    });

    testWidgets('OrbIconBadge semanticLabel verilince etiketli görsel düğüm', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(designHost(const OrbIconBadge(key: Key('b'), icon: Icons.home, family: AppFamilies.cyan, semanticLabel: 'Ev')));
      expect(tester.getSemantics(find.byKey(const Key('b'))).label, 'Ev');
      handle.dispose();
    });

    testWidgets('yazı ölçeği 2.0: orb kutusu değişmez ve taşma yok', (tester) async {
      await tester.pumpWidget(designHost(_orb(onTap: () {}), textScale: 2.0));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(OrbButton)).width, OrbSize.lg.footprint);
    });
  });

  // -----------------------------------------------------------------------------------------
  // (d) gecikmesiz onTap, pressed ölçeği parmak değdiği AN
  // -----------------------------------------------------------------------------------------
  group('gecikmesizlik', () {
    for (final mode in <MotionMode?>[null, MotionMode.full]) {
      testWidgets('OrbButton (${mode ?? "kapsam yok"}): parmak değince AYNI karede 0.92 ölçek; onTap pointer-up ile eşzamanlı', (tester) async {
        var taps = 0;
        await tester.pumpWidget(designHost(_orb(onTap: () => taps++, key: const Key('o')), mode: mode));
        final p = find.descendant(of: find.byKey(const Key('o')), matching: find.byType(Pressable));
        expect(pressableScale(tester, p), 1.0);
        final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('o'))));
        await tester.pump(); // tek sıfır-süreli kare
        expect(pressableScale(tester, p), closeTo(0.92, 1e-9));
        expect(orbPainters(tester).single.pressed, isTrue, reason: 'speküler azalır');
        expect(taps, 0);
        await g.up();
        expect(taps, 1, reason: 'hiçbir kare/zaman geçmeden');
        await tester.pumpAndSettle();
        expect(pressableScale(tester, p), 1.0);
        expect(orbPainters(tester).single.pressed, isFalse);
      });
    }

    testWidgets('OrbToggle: onChanged(!value) pointer-up ile eşzamanlı; owner güncellemesi olmadan değer kendiliğinden değişmez', (tester) async {
      final calls = <bool>[];
      await tester.pumpWidget(
        designHost(OrbToggle(key: const Key('t'), value: false, onChanged: calls.add, icon: Icons.lightbulb_outline, family: AppFamilies.amber, semanticLabel: 'L'), mode: MotionMode.full),
      );
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('t'))));
      await tester.pump();
      final p = find.descendant(of: find.byKey(const Key('t')), matching: find.byType(Pressable));
      expect(pressableScale(tester, p), closeTo(0.92, 1e-9));
      await g.up();
      expect(calls, [true]);
      await tester.pumpAndSettle();
      // Kontrollü bileşen: owner değer vermedi → kapalı kalır.
      expect(orbPainters(tester).single.colors, OrbColors.lerp(OrbColors.glass(Brightness.dark), OrbColors.family(AppFamilies.amber), 0));
    });

    testWidgets('GlassIconButton pressed ölçeği parmak değdiği AN', (tester) async {
      await tester.pumpWidget(designHost(GlassIconButton(key: const Key('g'), icon: Icons.menu, onTap: () {}, semanticLabel: 'M')));
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('g'))));
      await tester.pump();
      expect(pressableScale(tester, find.descendant(of: find.byKey(const Key('g')), matching: find.byType(Pressable))), closeTo(0.92, 1e-9));
      await g.up();
    });

    testWidgets('pending iken de dokunuş kabul edilir (CommandPipeline çift dokunuşu yönetir; orb bloklamaz)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(_orb(onTap: () => taps++, pending: true, key: const Key('o')), mode: MotionMode.full));
      await tester.tap(find.byKey(const Key('o')));
      await tester.tap(find.byKey(const Key('o')));
      expect(taps, 2);
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full));
    });

    testWidgets('haptik: onTap ile birlikte tek çağrı (medium)', (tester) async {
      final calls = recordHaptics(tester);
      var taps = 0;
      await tester.pumpWidget(designHost(_orb(onTap: () => taps++, haptic: PressHaptic.medium, key: const Key('o'))));
      await tester.tap(find.byKey(const Key('o')));
      expect(taps, 1);
      expect(calls, ['HapticFeedbackType.mediumImpact']);
    });
  });

  // -----------------------------------------------------------------------------------------
  // OrbToggle geçişi
  // -----------------------------------------------------------------------------------------
  group('OrbToggle geçişi', () {
    Widget toggle(bool on) => OrbToggle(
          value: on,
          onChanged: (_) {},
          icon: Icons.lightbulb_outline,
          activeIcon: Icons.lightbulb,
          family: AppFamilies.amber,
          semanticLabel: 'L',
        );

    testWidgets('off kip: değer değişince anında aile rengi, ara değer yok, animasyon yok', (tester) async {
      await tester.pumpWidget(designHost(toggle(false)));
      expect(orbPainters(tester).single.colors, OrbColors.glass(Brightness.dark));
      await tester.pumpWidget(designHost(toggle(true)));
      expect(orbPainters(tester).single.colors, OrbColors.family(AppFamilies.amber));
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.byIcon(Icons.lightbulb), findsOneWidget);
      expect(find.byIcon(Icons.lightbulb_outline), findsNothing, reason: 'eski+yeni simge birlikte olmaz');
    });

    testWidgets('full: yaylanmalı geçiş (ara renk), 320 ms\'de aile rengine oturur; açılışta 1.0→1.08→1.0 pop', (tester) async {
      await tester.pumpWidget(designHost(toggle(false), mode: MotionMode.full, clock: AmbientClock.fixed(0)));
      await tester.pumpWidget(designHost(toggle(true), mode: MotionMode.full, clock: AmbientClock.fixed(0)));
      var maxScale = 1.0;
      var sawMid = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final c = orbPainters(tester).single.colors;
        if (c != OrbColors.glass(Brightness.dark) && c != OrbColors.family(AppFamilies.amber)) sawMid = true;
        final scale = tester.widgetList<Transform>(find.descendant(of: find.byType(OrbToggle), matching: find.byType(Transform))).map((t) => t.transform.storage[0]).fold<double>(1.0, (m, v) => v > m ? v : m);
        if (scale > maxScale) maxScale = scale;
      }
      expect(sawMid, isTrue, reason: 'geçiş ara değerlerden geçer');
      expect(maxScale, greaterThan(1.05), reason: 'açılış pop\'u ≈ 1.08');
      expect(maxScale, lessThanOrEqualTo(1.0801));
      await tester.pump(const Duration(milliseconds: 400));
      expect(orbPainters(tester).single.colors, OrbColors.family(AppFamilies.amber));
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full));
    });

    testWidgets('kapanış: pop YOK (ölçek 1.0 üstüne çıkmaz)', (tester) async {
      await tester.pumpWidget(designHost(toggle(true), mode: MotionMode.full, clock: AmbientClock.fixed(0)));
      await tester.pumpWidget(designHost(toggle(false), mode: MotionMode.full, clock: AmbientClock.fixed(0)));
      var maxScale = 0.0;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final t in tester.widgetList<Transform>(find.descendant(of: find.byType(OrbToggle), matching: find.byType(Transform)))) {
          final s = t.transform.storage[0];
          if (s > maxScale) maxScale = s;
        }
      }
      expect(maxScale, lessThanOrEqualTo(1.0 + 1e-9));
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full));
    });

    testWidgets('açık toggle nefes alır (slot), kapalı almaz', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(toggle(true), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 1);
      await tester.pumpWidget(designHost(toggle(false), mode: MotionMode.full, clock: clock));
      expect(clock.activeSlots, 0);
      await tester.pumpAndSettle();
    });
  });

  // -----------------------------------------------------------------------------------------
  // Painter / renk takımı (saf)
  // -----------------------------------------------------------------------------------------
  group('OrbPainter', () {
    OrbPainter painter({double glow = 0.25, bool pressed = false, AmbientClock? clock, double phase = 0, double flash = 0, OrbColors? colors}) => OrbPainter(
          colors: colors ?? OrbColors.family(AppFamilies.sky),
          dark: true,
          glowLevel: glow,
          pressed: pressed,
          clock: clock,
          phase: phase,
          flash: flash,
        );

    test('nefes eğrisi 0..1 aralığında ve periyot 2.6 sn', () {
      for (var t = 0.0; t < 6; t += 0.1) {
        expect(OrbPainter.breath(t, 0), inInclusiveRange(0.0, 1.0));
      }
      expect(OrbPainter.breath(0, 0), closeTo(0.5, 1e-9));
      expect(OrbPainter.breath(OrbPainter.breathPeriodSeconds, 0), closeTo(0.5, 1e-9));
      expect(OrbPainter.breath(0.3, 0.25), isNot(OrbPainter.breath(0.3, 0)), reason: 'faz kayması');
    });

    test('shouldRepaint: her görsel alan değişince true, aynıysa false', () {
      final base = painter();
      expect(base.shouldRepaint(painter()), isFalse);
      expect(base.shouldRepaint(painter(glow: 0.6)), isTrue);
      expect(base.shouldRepaint(painter(pressed: true)), isTrue);
      expect(base.shouldRepaint(painter(flash: 0.4)), isTrue);
      expect(base.shouldRepaint(painter(phase: 0.2)), isTrue);
      expect(base.shouldRepaint(painter(colors: OrbColors.family(AppFamilies.rose))), isTrue);
      final clock = AmbientClock.fixed(1);
      expect(base.shouldRepaint(painter(clock: clock)), isTrue);
    });

    test('saat verilen painter saati dinler (repaint), saatsiz dinlemez', () {
      final clock = AmbientClock.fixed(1);
      var n = 0;
      void l() => n++;
      painter(clock: clock).addListener(l);
      painter().addListener(l); // repaint null → no-op
      expect(n, 0);
    });

    test('OrbColors.lerp: uçlarda aynı nesne değerleri, ortada ara değer; == / hashCode', () {
      final a = OrbColors.glass(Brightness.dark);
      final b = OrbColors.family(AppFamilies.amber);
      expect(OrbColors.lerp(a, b, 0), a);
      expect(OrbColors.lerp(a, b, 1), b);
      final mid = OrbColors.lerp(a, b, 0.5);
      expect(mid, isNot(a));
      expect(mid, isNot(b));
      expect(mid.base, Color.lerp(a.base, b.base, 0.5));
      expect(OrbColors.family(AppFamilies.amber), same(OrbColors.family(AppFamilies.amber)), reason: 'önbellek');
      expect(OrbColors.family(AppFamilies.amber).hashCode, OrbColors.family(AppFamilies.amber).hashCode);
    });
  });
}
