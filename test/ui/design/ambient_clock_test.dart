import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `AmbientClock`: dinleyici yoksa DURUR, tek Ticker, ≈24 Hz bildirim, slot bütçesi 8, arka planda durur,
/// `fixed` hiç çalışmaz, dispose temizler (bekleyen animasyon bırakmaz).
void main() {
  Future<void> run(WidgetTester tester, int frames, [int ms = 16]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(Duration(milliseconds: ms));
    }
  }

  testWidgets('dinleyici YOKKEN Ticker çalışmaz ve kare istenmez', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    expect(clock.isTicking, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(clock.isTicking, isFalse);
    expect(clock.time, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('ilk dinleyiciyle başlar, son dinleyici çıkınca durur (bekleyen animasyon kalmaz)', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    var n = 0;
    void a() => n++;
    void b() {}
    clock.addListener(a);
    expect(clock.isTicking, isTrue);
    clock.addListener(b);
    await run(tester, 30);
    expect(n, greaterThan(0));
    expect(clock.time, greaterThan(0));

    clock.removeListener(a);
    expect(clock.isTicking, isTrue, reason: 'hâlâ bir dinleyici var');
    clock.removeListener(b);
    expect(clock.isTicking, isFalse);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0, reason: 'Ticker bırakılmış olmalı');
  });

  testWidgets('bildirim hızı ≈24 Hz bandında (60 Hz karede 20-25 Hz): saniyede 18-26 bildirim', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    var n = 0;
    void l() => n++;
    clock.addListener(l);
    await tester.pump(); // ilk kare
    n = 0;
    await run(tester, 60, 16); // ≈ 0.96 sn
    clock.removeListener(l);
    expect(n, inInclusiveRange(17, 26), reason: 'ara kareler bildirilmez (her karede 60 Hz DEĞİL)');
  });

  testWidgets('zaman monoton artar ve durup yeniden başlayınca KALDIĞI YERDEN devam eder', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    void l() {}
    clock.addListener(l);
    await run(tester, 30);
    final t1 = clock.time;
    expect(t1, greaterThan(0.2));
    clock.removeListener(l);
    expect(clock.isTicking, isFalse);
    clock.addListener(l);
    await run(tester, 10);
    expect(clock.time, greaterThanOrEqualTo(t1));
    clock.removeListener(l);
  });

  testWidgets('slot bütçesi 8: dokuzuncu istek reddedilir, bırakınca yeniden verilir; aynı sahip idempotent', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    final owners = List.generate(9, (_) => Object());
    for (var i = 0; i < 8; i++) {
      expect(clock.tryAcquireSlot(owners[i]), isTrue, reason: 'slot $i');
    }
    expect(AmbientClock.defaultMaxSlots, 8);
    expect(clock.activeSlots, 8);
    expect(clock.tryAcquireSlot(owners[8]), isFalse, reason: '9. nefes alan parıltı statik kalır');
    expect(clock.tryAcquireSlot(owners[0]), isTrue, reason: 'aynı sahip tekrar isteyince yer tutmaz');
    expect(clock.activeSlots, 8);
    clock.releaseSlot(owners[3]);
    expect(clock.activeSlots, 7);
    expect(clock.tryAcquireSlot(owners[8]), isTrue);
    clock.releaseSlot(Object()); // tutmayan sahip: no-op
    expect(clock.activeSlots, 8);
  });

  testWidgets('arka plana geçince durur, öne dönünce dinleyici varsa devam eder', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    var n = 0;
    void l() => n++;
    clock.addListener(l);
    await run(tester, 20);
    expect(clock.isTicking, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(clock.isTicking, isFalse, reason: 'arka planda Ticker durmalı');
    final frozen = n;
    await run(tester, 20);
    expect(n, frozen, reason: 'arka planda bildirim yok');
    expect(tester.binding.transientCallbackCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(clock.isTicking, isTrue);
    await run(tester, 20);
    expect(n, greaterThan(frozen));
    clock.removeListener(l);
    expect(clock.isTicking, isFalse);
  });

  testWidgets('inactive (kısa kesinti) durdurmaz; hidden/detached durdurur', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    void l() {}
    clock.addListener(l);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(clock.isTicking, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(clock.isTicking, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(clock.isTicking, isTrue);
    clock.removeListener(l);
  });

  testWidgets('AmbientClock.fixed: asla çalışmaz, zaman sabit, dinleyici eklemek Ticker başlatmaz', (tester) async {
    final clock = AmbientClock.fixed(2.5);
    addTearDown(clock.dispose);
    var n = 0;
    void l() => n++;
    clock.addListener(l);
    expect(clock.isFixed, isTrue);
    expect(clock.isTicking, isFalse);
    await run(tester, 30);
    expect(clock.time, 2.5);
    expect(n, 0);
    expect(tester.binding.transientCallbackCount, 0);
    clock.removeListener(l);
    // Slot bütçesi sabit saatte de geçerlidir (golden'da 8'den fazla nefes alan orb statik kalır).
    for (var i = 0; i < 8; i++) {
      expect(clock.tryAcquireSlot(Object()), isTrue);
    }
    expect(clock.tryAcquireSlot(Object()), isFalse);
  });

  testWidgets('dispose çalışan saati durdurur (bekleyen animasyon bırakmaz)', (tester) async {
    final clock = AmbientClock();
    void l() {}
    clock.addListener(l);
    await run(tester, 5);
    expect(clock.isTicking, isTrue);
    clock.removeListener(l);
    clock.dispose();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('widget ağacıyla: painter repaint dinleyicisi ağaçtan çıkınca saat durur', (tester) async {
    final clock = AmbientClock();
    addTearDown(clock.dispose);
    await tester.pumpWidget(designHost(CustomPaint(painter: _ClockPainter(clock), size: const Size(10, 10))));
    expect(clock.isTicking, isTrue);
    await run(tester, 5);
    await tester.pumpWidget(designHost(const SizedBox()));
    expect(clock.isTicking, isFalse, reason: 'dinleyici ağaçla birlikte gitti');
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });
}

class _ClockPainter extends CustomPainter {
  _ClockPainter(AmbientClock clock) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
