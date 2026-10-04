import 'dart:math' as math;

import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tasarım belirteçleri `gorsel-tasarim-v2.md` §2 ile birebir (yanlışlıkla değişirse kırılır).
void main() {
  group('§2.1 renk aileleri', () {
    const spec = <String, List<int>>{
      // ad: [base, light, deep]
      'amber': [0xFFFFB020, 0xFFFFD36B, 0xFFE07A00],
      'emerald': [0xFF10B981, 0xFF6EE7B7, 0xFF047857],
      'sky': [0xFF3B82F6, 0xFF93C5FD, 0xFF1D4ED8],
      'rose': [0xFFF43F5E, 0xFFFDA4AF, 0xFFBE123C],
      'violet': [0xFFA855F7, 0xFFD8B4FE, 0xFF7E22CE],
      'cyan': [0xFF22D3EE, 0xFFA5F3FC, 0xFF0E7490],
      'slate': [0xFF64748B, 0xFFCBD5E1, 0xFF334155],
    };

    test('yedi aile ve tablo değerleri', () {
      expect(AppFamilies.all.map((f) => f.name), spec.keys);
      for (final f in AppFamilies.all) {
        final v = spec[f.name]!;
        expect(f.base.toARGB32(), v[0], reason: '${f.name} base');
        expect(f.light.toARGB32(), v[1], reason: '${f.name} light');
        expect(f.deep.toARGB32(), v[2], reason: '${f.name} deep');
      }
    });

    test('her ailede light > base > deep açıklık sırası ve glow base ile light arasında', () {
      for (final f in AppFamilies.all) {
        expect(f.light.computeLuminance(), greaterThan(f.base.computeLuminance()), reason: f.name);
        expect(f.base.computeLuminance(), greaterThan(f.deep.computeLuminance()), reason: f.name);
        expect(f.glow.computeLuminance(), inInclusiveRange(f.base.computeLuminance(), f.light.computeLuminance()), reason: f.name);
        expect(f.glow.a, 1.0, reason: 'glow opak (alfa çizimde)');
      }
    });
  });

  group('§2.2 yüzeyler', () {
    test('koyu', () {
      const t = SurfaceTokens.dark;
      expect(t.cardTop, const Color(0xFF1B2740));
      expect(t.cardBottom, const Color(0xFF141E33));
      expect(t.raised, const Color(0xFF223253));
      expect(t.rimStart.a, closeTo(0.18, 0.01));
      expect(t.rimEnd.a, closeTo(0.02, 0.01));
      expect(t.shadow.a, closeTo(0.40, 0.01));
      expect((t.shadowBlur, t.shadowOffset), (22.0, const Offset(0, 10)));
      expect(t.shadowBlur, lessThanOrEqualTo(24), reason: 'statik gölgede blur ≤ 24');
    });

    test('açık', () {
      const t = SurfaceTokens.light;
      expect(t.cardTop, const Color(0xFFFFFFFF));
      expect(t.cardBottom, const Color(0xFFF6F8FC));
      expect(t.shadow.a, closeTo(0.14, 0.01));
      expect((t.shadowBlur, t.shadowOffset), (18.0, const Offset(0, 8)));
      expect(t.orbShadowAlpha, 0.30);
      expect((t.orbShadowBlur, t.orbShadowOffset), (14.0, const Offset(0, 6)));
    });

    test('of(brightness)', () {
      expect(SurfaceTokens.of(Brightness.dark), same(SurfaceTokens.dark));
      expect(SurfaceTokens.of(Brightness.light), same(SurfaceTokens.light));
    });

    test('vurgulu kart sabitleri: accent@0.55, 1.4 px, parıltı @0.14', () {
      expect(AppGlass.accentRimAlpha, 0.55);
      expect(AppGlass.accentRimWidth, 1.4);
      expect(AppGlass.accentGlowAlpha, 0.14);
    });
  });

  group('§2.3 şekil / boşluk / boyut', () {
    test('yarıçap ve boşluk ızgarası', () {
      expect([AppRadius.r8, AppRadius.r12, AppRadius.r16, AppRadius.card, AppRadius.sheet, AppRadius.pill], [8, 12, 16, 20, 28, 999]);
      expect([AppSpace.s4, AppSpace.s8, AppSpace.s12, AppSpace.s16, AppSpace.s20, AppSpace.s24, AppSpace.s32], [4, 8, 12, 16, 20, 24, 32]);
    });

    test('orb boyutları ve dokunma alanı ≥ 48', () {
      expect(OrbSize.values.map((s) => s.diameter), [76, 64, 52, 44]);
      expect(OrbSize.xl.diameter, 76);
      for (final s in OrbSize.values) {
        expect(s.footprint, greaterThanOrEqualTo(AppTouch.minTarget));
        expect(s.iconSize, closeTo(s.diameter * 0.44, 1e-9));
      }
      expect(OrbSize.sm.footprint, 48);
      expect(OrbSize.lg.footprint, 64);
      expect(AppTouch.minTarget, 48);
      expect(AppTouch.minFontSize, 12);
    });
  });

  group('§2.4 hareket', () {
    test('süreler', () {
      expect(AppMotion.instant.inMilliseconds, 90);
      expect(AppMotion.fast.inMilliseconds, 140);
      expect(AppMotion.base.inMilliseconds, 220);
      expect(AppMotion.slow.inMilliseconds, 320);
      expect(AppMotion.hero.inMilliseconds, 480);
      expect(AppMotion.pageTransition.inMilliseconds, lessThanOrEqualTo(280));
      expect(AppMotion.staggerStep.inMilliseconds, inInclusiveRange(40, 45));
      expect(AppMotion.staggerMaxItems, 8);
      expect(AppMotion.standard, Curves.easeOutCubic);
      expect(AppMotion.linear, Curves.linear);
    });

    test('SpringCurve: uçlar tam, ≈%3.8 aşım, sonda oturur, damping küçüldükçe aşım artar', () {
      const spring = SpringCurve(damping: 0.72);
      expect(spring.transform(0), 0);
      expect(spring.transform(1), 1);
      var peak = 0.0;
      var peakAt = 0.0;
      for (var i = 0; i <= 1000; i++) {
        final t = i / 1000;
        final y = spring.transform(t);
        if (y > peak) {
          peak = y;
          peakAt = t;
        }
      }
      expect(peak, inInclusiveRange(1.02, 1.06), reason: '1.0 → 1.04 → 1.0');
      expect(peakAt, inInclusiveRange(0.5, 0.9));
      for (final t in [0.95, 0.98, 0.999]) {
        expect((spring.transform(t) - 1).abs(), lessThan(0.02), reason: 't=$t');
      }
      final bouncy = SpringCurve(damping: 0.4);
      var bouncyPeak = 0.0;
      for (var i = 0; i <= 1000; i++) {
        bouncyPeak = math.max(bouncyPeak, bouncy.transform(i / 1000));
      }
      expect(bouncyPeak, greaterThan(peak));
      expect(AppMotion.spring, isA<SpringCurve>());
    });

    test('SpringCurve ilk yükselişte monoton (negatif başlangıç yok)', () {
      const spring = SpringCurve();
      var prev = 0.0;
      for (var i = 1; i <= 300; i++) {
        final y = spring.transform(i / 1000);
        expect(y, greaterThanOrEqualTo(prev - 1e-12));
        prev = y;
      }
    });
  });

  test('wcagContrast: siyah/beyaz 21:1, aynı renk 1:1, simetrik', () {
    expect(wcagContrast(Colors.black, Colors.white), closeTo(21.0, 1e-6));
    expect(wcagContrast(Colors.red, Colors.red), 1.0);
    expect(wcagContrast(Colors.red, Colors.blue), wcagContrast(Colors.blue, Colors.red));
  });

  test('PressHaptic seçenekleri', () {
    expect(PressHaptic.values, [PressHaptic.none, PressHaptic.selection, PressHaptic.light, PressHaptic.medium, PressHaptic.heavy]);
  });
}
