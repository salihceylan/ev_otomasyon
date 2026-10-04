import 'package:ev_otomasyon/ui/common/arc_spinner.dart';
import 'package:ev_otomasyon/ui/common/wifi_signal_bars.dart';
import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_value_row.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_progress.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_widgets.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/steps/step_10_handover.dart';
import 'package:ev_otomasyon/ui/motion/pulse_ring.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WP-V6 sihirbaz bileşenleri (orb ilerleme şeridi, durum rozeti, hata kutusu, gizli değer satırı, sinyal çubukları,
/// orb eylem düğmesi, yay göstergesi) için birim/widget testleri. Hareket kipi açıkça verilir: kapsamsız = `off`.
Widget _host(
  Widget child, {
  bool full = false,
  double scale = 1.0,
  Brightness brightness = Brightness.dark,
  double width = 360,
}) {
  Widget app = MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: c!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
  if (full) {
    app = MotionScope(mode: MotionMode.full, clock: AmbientClock.fixed(0.65), child: app);
  }
  return app;
}

void main() {
  group('SetupStepStrip (10 adımlı orb şeridi)', () {
    testWidgets('önceki adımlar ✓, etkin ve bekleyen adımlar numara gösterir; semantik özet tek', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const SetupStepStrip(step: 4, total: 10)));
      expect(find.byKey(const Key('setup_step_strip')), findsOneWidget);
      for (var i = 1; i <= 10; i++) {
        expect(find.byKey(Key('setup_strip_orb_$i')), findsOneWidget, reason: 'orb $i');
      }
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(3), reason: '1-3. adımlar tamamlandı');
      expect(find.text('4'), findsOneWidget, reason: 'etkin adım numarası');
      expect(find.text('10'), findsOneWidget, reason: 'bekleyen adım numarası');
      expect(find.text('2'), findsNothing, reason: 'tamamlanan adımda numara yerine ✓ var');
      expect(find.bySemanticsLabel('İlerleme: adım 4 / 10'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('etkin adım tamamlandıysa ✓, sorunluysa "!" gösterir', (tester) async {
      await tester.pumpWidget(_host(const SetupStepStrip(step: 3, total: 10, phase: StepPhase.done)));
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));
      expect(find.byIcon(Icons.priority_high_rounded), findsNothing);

      await tester.pumpWidget(_host(const SetupStepStrip(step: 3, total: 10, phase: StepPhase.failed)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);
    });

    testWidgets(
      'GERÇEK durum (phases): etkin adımdan önceki tüm adımlar körlemesine yeşil ✓ DEĞİL; eksik adım amber "!", ✓ yalnız tamamlananlarda',
      (tester) async {
        // e10_missing durumu: 10. adımdayız, 1-5 tamam, 6-9 eksik ("Eksik adımlar: 6, 7, 8, 9.").
        final handle = tester.ensureSemantics();
        final phases = <StepPhase>[for (var i = 1; i <= 10; i++) i <= 5 ? StepPhase.done : StepPhase.pending];
        await tester.pumpWidget(_host(SetupStepStrip(step: 10, total: 10, phases: phases)));
        expect(find.byIcon(Icons.check_rounded), findsNWidgets(5), reason: 'yalnız 1-5 gerçekten tamam');
        expect(find.byIcon(Icons.priority_high_rounded), findsNWidgets(4), reason: '6-9 eksik');
        expect(find.text('10'), findsOneWidget, reason: 'etkin adım numarası');
        expect(find.bySemanticsLabel('İlerleme: adım 10 / 10. Eksik adımlar: 6, 7, 8, 9'), findsOneWidget);

        // Zümrüt dolgu ilk eksik adımın (6) orbunda biter; 10. adıma kadar "tamamlanmış gibi" uzanmaz.
        final strip = tester.getSize(find.byKey(const Key('setup_step_strip')));
        final railWidth = strip.width - 32 - SetupStepStrip.slot;
        final fill = tester.getSize(
          find.descendant(of: find.byKey(const Key('setup_step_strip')), matching: find.byType(AnimatedContainer)),
        );
        expect(fill.width, closeTo(railWidth * 5 / 9, 0.6));
        handle.dispose();
      },
    );

    testWidgets('phases: atlanan adım soluk ✓, sorunlu önceki adım "!", sonraki tamamlanmış adım ✓; eksik yoksa etikete eklenmez', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // PIN oturumu: 3 ve 4 atlanır. 6. adımdayız; 1,2,5 tamam; 3,4 atlandı; 7. adım (daha önce yapılmış) tamam; 8 sorunlu.
      final phases = <StepPhase>[
        StepPhase.done,
        StepPhase.done,
        StepPhase.skipped,
        StepPhase.skipped,
        StepPhase.done,
        StepPhase.pending, // etkin
        StepPhase.done,
        StepPhase.failed,
        StepPhase.pending,
        StepPhase.pending,
      ];
      await tester.pumpWidget(_host(SetupStepStrip(step: 6, total: 10, phases: phases)));
      expect(
        find.byIcon(Icons.check_rounded),
        findsNWidgets(6),
        reason: '1, 2, 5 ve 7 (tamam) + 3, 4 (atlandı: soluk ✓)',
      );
      expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget, reason: 'yalnız 8 (sorunlu)');
      expect(find.text('6'), findsOneWidget, reason: 'etkin adım numarası');
      expect(find.bySemanticsLabel('İlerleme: adım 6 / 10'), findsOneWidget, reason: 'eksik önceki adım yok: etiket sade');
      handle.dispose();
    });

    testWidgets('hareket açıkken adım değişimi yumuşak geçer ve biter (ambient saat sabit: pumpAndSettle takılmaz)', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const SetupStepStrip(step: 2, total: 10), full: true));
      await tester.pumpWidget(_host(const SetupStepStrip(step: 3, total: 10), full: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    });

    testWidgets('320 dp ve 2.0x yazıda taşmaz (orb sabit boyutlu, numara FittedBox içinde)', (tester) async {
      await tester.pumpWidget(_host(const SetupStepStrip(step: 10, total: 10), scale: 2.0, width: 320));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        _host(const SetupStepStrip(step: 7, total: 10), scale: 2.0, width: 320, brightness: Brightness.light),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SetupStatusBadge', () {
    testWidgets('her durumda doğru metin + işaret: bekliyor nokta, çalışıyor yay, diğerleri mini orb', (tester) async {
      final handle = tester.ensureSemantics();
      for (final phase in StepPhase.values) {
        await tester.pumpWidget(_host(SetupStatusBadge(phase: phase)));
        expect(find.text(SetupStatusBadge.textFor(phase)), findsOneWidget, reason: '$phase');
        expect(find.bySemanticsLabel('Adım durumu: ${SetupStatusBadge.textFor(phase)}'), findsOneWidget);
        expect(find.byType(ArcSpinner), phase == StepPhase.working ? findsOneWidget : findsNothing);
        expect(find.byType(GlowDot), phase == StepPhase.pending ? findsOneWidget : findsNothing);
        expect(
          find.byType(SetupMiniOrb),
          (phase == StepPhase.done || phase == StepPhase.failed || phase == StepPhase.skipped)
              ? findsOneWidget
              : findsNothing,
          reason: '$phase',
        );
      }
      handle.dispose();
    });

    testWidgets('üst adım rozeti ile kart içi durum hapı AYNI yükseklikte (eskiden 28 dp / 24 dp: aynı ekranda iki rozet boyu)', (
      tester,
    ) async {
      // Hap yüksekliği = etiket + dikey dolgu: gösterge yuvası (14 dp) etiketin satır yüksekliğini aşmaz.
      for (final phase in <StepPhase>[StepPhase.pending, StepPhase.working, StepPhase.done, StepPhase.failed]) {
        await tester.pumpWidget(
          _host(
            Wrap(
              spacing: 8,
              children: [
                SetupStatusBadge(phase: phase, label: 'Rozet'),
                const SetupVerdictChip(label: 'Hap', color: Colors.blue),
              ],
            ),
          ),
        );
        final badge = tester.getSize(find.byType(SetupStatusBadge)).height;
        final chip = tester.getSize(find.byType(SetupVerdictChip)).height;
        expect(badge, closeTo(chip, 1.0), reason: '$phase: rozet $badge dp, hap $chip dp');
      }
    });

    testWidgets('özel durum metni (statusText) varsayılanın yerine geçer; uzun metin 360 dp / 2.0x taşmaz', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SetupStatusBadge(phase: StepPhase.done, label: 'Pano sunucuda çevrimiçi ve doğrulandı'),
          scale: 2.0,
          width: 200,
        ),
      );
      expect(find.text('Pano sunucuda çevrimiçi ve doğrulandı'), findsOneWidget);
      expect(find.text('Tamamlandı'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('SetupProblemBox', () {
    testWidgets('her hata türü anlamlı simge orb + Neden/Ne yapmalıyım + eylemler ile taşmadan çizilir', (
      tester,
    ) async {
      for (final kind in SetupProblemKind.values) {
        var retried = 0;
        int? fixed;
        await tester.pumpWidget(
          _host(
            SetupProblemBox(
              problem: SetupProblem(
                kind: kind,
                title: 'Başlık $kind',
                why: 'Neden metni',
                todo: 'Yapılacak metni',
                fixStep: 2,
                retryAfter: const Duration(seconds: 30),
              ),
              onRetry: () => retried++,
              onFixStep: (s) => fixed = s,
            ),
            scale: 1.5,
          ),
        );
        await tester.pump();
        expect(find.text('Başlık $kind'), findsOneWidget);
        expect(find.text('Neden?'), findsOneWidget);
        expect(find.text('Ne yapmalıyım?'), findsOneWidget);
        expect(find.byIcon(SetupProblemBox.iconForKind(kind)), findsOneWidget, reason: 'simge $kind');
        expect(find.byType(SetupResultOrb), findsOneWidget);
        await tester.tap(find.byKey(const Key('setup_retry')));
        await tester.tap(find.byKey(const Key('setup_fix_step')));
        expect(retried, 1);
        expect(fixed, 2);
        expect(tester.takeException(), isNull, reason: '$kind');
      }
    });

    testWidgets(
      'retrySecondary: "Tekrar dene" çerçeveli (OutlinedButton) olur, varsayılan gradyanlı (ElevatedButton); anahtar ve eylem aynı',
      (tester) async {
        var retried = 0;
        final problem = SetupProblems.fromError(StateError('x'), step: 7);
        await tester.pumpWidget(_host(SetupProblemBox(problem: problem, onRetry: () => retried++, onFixStep: (_) {})));
        await tester.pump();
        expect(tester.widget(find.byKey(const Key('setup_retry'))), isA<ElevatedButton>(), reason: 'varsayılan: gradyan birincil');

        await tester.pumpWidget(
          _host(SetupProblemBox(problem: problem, onRetry: () => retried++, onFixStep: (_) {}, retrySecondary: true)),
        );
        await tester.pump();
        expect(tester.widget(find.byKey(const Key('setup_retry'))), isA<OutlinedButton>(), reason: 'ikincil: çerçeveli');
        await tester.tap(find.byKey(const Key('setup_retry')));
        expect(retried, 1, reason: 'ikincil düğme de yeniden dener');
      },
    );

    testWidgets('oturum süresi doldu amber (hata sarsıntısı yok), diğerleri rose hata orb\'u', (tester) async {
      await tester.pumpWidget(_host(SetupProblemBox(problem: SetupProblems.expired())));
      await tester.pump();
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).family, AppFamilies.amber);
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).status, OrbStatus.none);

      await tester.pumpWidget(_host(SetupProblemBox(problem: SetupProblems.fromError(StateError('x'), step: 1))));
      await tester.pump();
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).family, AppFamilies.rose);
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).status, OrbStatus.error);
    });
  });

  group('SetupResultOrb / SetupResultHeader', () {
    testWidgets('durum ilk çerçeveden sonra uygulanır (tek seferlik halka/sarsıntı yalnız none -> sonuç geçişinde)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const SetupResultOrb(icon: Icons.check_rounded, family: AppFamilies.emerald, status: OrbStatus.success)),
      );
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).status, OrbStatus.none);
      await tester.pump();
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).status, OrbStatus.success);
    });

    testWidgets('başlık metni tek Text olarak çizilir ve dar/büyük yazıda taşmaz', (tester) async {
      await tester.pumpWidget(
        _host(
          const SetupResultHeader(text: 'Pano sunucuda zaten çevrimiçi: çalışan panonun bulut kimliği DEĞİŞTİRİLMEDİ.'),
          scale: 2.0,
          width: 320,
        ),
      );
      await tester.pump();
      expect(find.textContaining('DEĞİŞTİRİLMEDİ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('SecretValueRow', () {
    testWidgets('kopyala: onCopy çağrılır, düğme ✓ olur; hareket kapalıyken halka çizilmez', (tester) async {
      var copied = 0;
      await tester.pumpWidget(
        _host(
          SecretValueRow(label: 'Kurulum PIN', shown: '705 318', copyKey: const Key('copy'), onCopy: () => copied++),
        ),
      );
      expect(find.text('705 318'), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy')));
      await tester.pump();
      expect(copied, 1);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsNothing);
    });

    testWidgets('hareket açıkken 45 sn silme halkası boşalır ve süre bitince düğme eski haline döner', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          SecretValueRow(label: 'Kurulum PIN', shown: '705 318', copyKey: const Key('copy'), onCopy: () {}),
          full: true,
        ),
      );
      await tester.tap(find.byKey(const Key('copy')));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('Panoya kopyalandı; 45 saniye sonra silinir')), findsOneWidget);
      await tester.pump(const Duration(seconds: 20));
      expect(find.byIcon(Icons.check_rounded), findsOneWidget, reason: 'halka süresi dolmadı');
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget, reason: 'süre bitti: kopyala simgesi geri gelir');
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      handle.dispose();
    });

    testWidgets('showWipeRing: false -> ✓ geri bildirimi var, halka yok', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          SecretValueRow(
            label: 'Kurulum PIN',
            shown: '705 318',
            copyKey: const Key('copy'),
            onCopy: () {},
            showWipeRing: false,
          ),
          full: true,
        ),
      );
      await tester.tap(find.byKey(const Key('copy')));
      await tester.pump();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Panoya kopyalandı')), findsNothing);
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('uzun anahtar 320 dp ve 2.0x yazıda satıra sarar, taşmaz; kopyala hedefi >= 48 dp', (tester) async {
      await tester.pumpWidget(
        _host(
          SecretValueRow(
            label: 'Yerel anahtar (panoya iletilemedi)',
            shown: 'yeni-yerel-anahtar-9988-ABCDEF0123456789',
            copyKey: const Key('copy'),
            onCopy: () {},
          ),
          scale: 2.0,
          width: 320,
        ),
      );
      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byKey(const Key('copy')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('WifiSignalBars', () {
    test('RSSI -> çubuk sayısı ve etiket', () {
      expect(WifiSignalBars.levelFor(-30), 4);
      expect(WifiSignalBars.levelFor(-55), 4);
      expect(WifiSignalBars.levelFor(-56), 3);
      expect(WifiSignalBars.levelFor(-65), 3);
      expect(WifiSignalBars.levelFor(-66), 2);
      expect(WifiSignalBars.levelFor(-75), 2);
      expect(WifiSignalBars.levelFor(-76), 1);
      expect(WifiSignalBars.levelFor(-95), 1);
      expect(WifiSignalBars.labelFor(-48), 'iyi');
      expect(WifiSignalBars.labelFor(-70), 'orta');
      expect(WifiSignalBars.labelFor(-88), 'zayıf');
    });

    testWidgets('anlamsal etiket "Sinyal iyi/orta/zayıf"; dolum animasyonu biter (ambient yok)', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const WifiSignalBars(rssi: -48), full: true));
      expect(find.bySemanticsLabel('Sinyal iyi'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_host(const WifiSignalBars(rssi: -88)));
      expect(find.bySemanticsLabel('Sinyal zayıf'), findsOneWidget);
      handle.dispose();
    });
  });

  group('SetupOrbAction', () {
    testWidgets('orb dokunulabilir (>= 48 dp), başlık görsel etiket; onTap null ise etkisiz', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          SetupOrbAction(
            orbKey: const Key('orb'),
            icon: Icons.arrow_upward_rounded,
            family: AppFamilies.emerald,
            label: 'Yukarı',
            onTap: () => taps++,
          ),
        ),
      );
      expect(find.text('Yukarı'), findsOneWidget);
      final size = tester.getSize(find.byKey(const Key('orb')));
      expect(size.width, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('orb')));
      await tester.pump();
      expect(taps, 1);

      await tester.pumpWidget(
        _host(
          const SetupOrbAction(
            orbKey: Key('orb'),
            icon: Icons.arrow_upward_rounded,
            family: AppFamilies.emerald,
            label: 'Yukarı',
            onTap: null,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('orb')), warnIfMissed: false);
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('HandoverCelebration (teslim başarısı)', () {
    testWidgets('hareket açıkken tek seferlik (<= 900 ms) biter; konfeti/döngü yok; ✓ orb emerald', (tester) async {
      await tester.pumpWidget(_host(const Center(child: HandoverCelebration()), full: true));
      expect(find.byKey(const Key('handover_celebration')), findsOneWidget);
      expect(find.byType(PulseRing), findsWidgets);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.pump();
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).family, AppFamilies.emerald);
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).status, OrbStatus.success);
      await tester.pump(const Duration(milliseconds: 900));
      // Sonlu animasyonlar bitti: ambient saat sabit olduğundan kare istenmez.
      expect(tester.hasRunningAnimations, isFalse, reason: 'kutlama 900 ms içinde biter');
      expect(tester.takeException(), isNull);
    });

    testWidgets('hareket kapalıyken halka çizilmez ve animasyon kurulmaz; 320 dp / 2.0x taşmaz', (tester) async {
      await tester.pumpWidget(_host(const Center(child: HandoverCelebration()), scale: 2.0, width: 320));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('ArcSpinner', () {
    testWidgets('hareket kapalıyken statik yay: pumpAndSettle takılmaz; çocuk (geri sayım) ortada', (tester) async {
      await tester.pumpWidget(_host(const ArcSpinner(size: 56, color: Colors.blue, child: Text('33'))));
      await tester.pumpAndSettle();
      expect(find.text('33'), findsOneWidget);
      expect(find.byType(ProgressArc), findsOneWidget);
    });
  });
}
