@Tags(['visual'])
library;

// WP-V8 TONE düğme galerisi: tema düğmesinin yerel stili okuması + ortak ton yüzeyi.
//
//   flutter test --tags visual --update-goldens test/visual/tone     -> test/visual/tone/goldens/*.png
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/tone         -> kayıtlı PNG ile karşılaştırır
//
// 360 dp telefon genişliği, koyu + açık tema, yazı ölçeği 1.0 (2x PNG) ve 1.5 (1x PNG). Her satır üç durumdur:
// normal · basılı (parmak değdiği an, gerçek dokunuşla) · devre dışı. Sayfalar içeriğin yüksekliğine kırpılır.
//
//  * families : accentButtonStyle(aile) — tüm aileler + yıkıcı + renksiz varsayılan
//  * local    : ekranlardaki yerel `styleFrom(backgroundColor: X)` (çağrı yeri renkleri) — tema yüzeyi okur
//  * variants : simgeli düğme, yerel şekil/yarıçap, pasif yerel renk, FilledButton, uzun etiket

import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_style.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/settings/accent_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_support.dart';

/// Bir satır: üstte etiket, altında normal · basılı · pasif düğmeler.
class _StateRow extends StatelessWidget {
  const _StateRow({required this.id, required this.label, required this.builder});

  final String id;
  final String label;

  /// `(onPressed, key, text)` ile düğmeyi kurar.
  final Widget Function(VoidCallback? onPressed, Key? key, String text) builder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.getTextMuted(context)),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              builder(() {}, ValueKey('normal_$id'), 'Normal'),
              builder(() {}, ValueKey('pressed_$id'), 'Basılı'),
              builder(null, ValueKey('disabled_$id'), 'Pasif'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              title,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context)),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

Widget _elevated(ButtonStyle? style, VoidCallback? onPressed, Key? key, String text) =>
    ElevatedButton(key: key, onPressed: onPressed, style: style, child: Text(text));

Widget _elevatedIcon(ButtonStyle? style, VoidCallback? onPressed, Key? key, String text, IconData icon) =>
    ElevatedButton.icon(key: key, onPressed: onPressed, style: style, icon: Icon(icon, size: 20), label: Text(text));

Widget _familiesSheet() => _Sheet(
      title: 'accentButtonStyle(aile) — ortak ton yüzeyi',
      children: [
        _StateRow(id: 'default', label: 'renk yok: tema varsayılanı (sky -> cyan)', builder: (p, k, t) => _elevated(null, p, k, t)),
        for (final f in [
          AppFamilies.sky,
          AppFamilies.cyan,
          AppFamilies.emerald,
          AppFamilies.amber,
          AppFamilies.rose,
          AppFamilies.violet,
          AppFamilies.slate,
        ])
          _StateRow(
            id: f.name,
            // (Kısa etiket: 'AppFamilies.emerald' gibi boşluksuz uzun sözcük 1.5 ölçekte harf düzeyinde bölünüyordu: harness artefaktı.)
            label: 'accentButtonStyle(${f.name})',
            builder: (p, k, t) => _elevated(accentButtonStyle(f), p, k, t),
          ),
        _StateRow(id: 'destructive', label: 'destructiveButtonStyle()', builder: (p, k, t) => _elevated(destructiveButtonStyle(), p, k, t)),
      ],
    );

/// Çağrı yerlerindeki yerel renkler (lib/ui/** taraması).
final List<(String, String, Color)> _localColors = <(String, String, Color)>[
  ('primary', 'primaryBlue (welcome_cards, peace_notice, wifi_provision …): varsayılanla AYNI', AppTheme.primaryBlue),
  ('cyan', 'accentCyan (device_inventory: Cihaz Ekle)', AppTheme.accentCyan),
  ('green', 'accentGreen (wifi_recovery, inventory Stoğa Al, setup ok)', AppTheme.accentGreen),
  ('amber', 'accentAmber (inventory Askıya Al, setup warn)', AppTheme.accentAmber),
  ('red', 'accentRed (setup error, acil sıfırlama)', AppTheme.accentRed),
  ('purple', 'SetupColors.purple (replace_board: Panoyu Değiştir)', SetupColors.purple),
  ('lime', 'özel renk: 0xFF84CC16 (aileye yakın değil -> türetilir)', const Color(0xFF84CC16)),
  ('gray', 'gri: 0xFF6B7280 (nötr -> slate)', const Color(0xFF6B7280)),
];

Widget _localSheet() => _Sheet(
      title: 'yerel styleFrom(backgroundColor: X) — tema yüzeyi yerel rengi okur',
      children: [
        for (final c in _localColors)
          _StateRow(
            id: 'local_${c.$1}',
            label: c.$2,
            builder: (p, k, t) => _elevated(ElevatedButton.styleFrom(backgroundColor: c.$3), p, k, t),
          ),
      ],
    );

Widget _variantsSheet() => _Sheet(
      title: 'simge · şekil · pasif yerel renk · FilledButton · uzun etiket',
      children: [
        _StateRow(
          id: 'icon_amber',
          label: '.icon + amber (yerel renk, mürekkep otomatik koyu, simge de koyu)',
          builder: (p, k, t) => _elevatedIcon(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber), p, k, t, Icons.lightbulb_rounded),
        ),
        _StateRow(
          id: 'icon_red',
          label: '.icon + accentRed (beyaz mürekkep)',
          builder: (p, k, t) => _elevatedIcon(ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed), p, k, t, Icons.delete_outline_rounded),
        ),
        _StateRow(
          id: 'icon_fg',
          label: '.icon + yeşil + yerel foregroundColor (siyah): ona saygı',
          builder: (p, k, t) => _elevatedIcon(
            ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen, foregroundColor: Colors.black),
            p,
            k,
            t,
            Icons.check_rounded,
          ),
        ),
        _StateRow(
          id: 'warn_fg',
          label: 'UYARI: amber + yerel beyaz foregroundColor (SetupProblemBox kalıbı): saygı gösterilir, AA DEĞİL',
          builder: (p, k, t) => _elevated(
            ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber, foregroundColor: Colors.white),
            p,
            k,
            t,
          ),
        ),
        _StateRow(
          id: 'shape12',
          label: 'yerel RoundedRectangleBorder(12) + violet',
          builder: (p, k, t) => _elevated(
            ElevatedButton.styleFrom(backgroundColor: SetupColors.purple, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            p,
            k,
            t,
          ),
        ),
        _StateRow(
          id: 'shape8_icon',
          label: '.icon + RoundedRectangleBorder(8) + cyan (Clip.none)',
          builder: (p, k, t) => _elevatedIcon(
            ElevatedButton.styleFrom(
              minimumSize: const Size(48, 44),
              backgroundColor: AppTheme.accentCyan,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            p,
            k,
            t,
            Icons.person_add_alt_1,
          ),
        ),
        _StateRow(
          id: 'shape_default12',
          label: 'renksiz + RoundedRectangleBorder(14) (welcome_cards kalıbı)',
          builder: (p, k, t) => _elevated(ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), p, k, t),
        ),
        _StateRow(
          id: 'setup_primary',
          label: 'pasifte yerel disabledBackgroundColor (SetupPrimaryButton kalıbı)',
          builder: (p, k, t) => _elevated(
            ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppTheme.accentGreen.withValues(alpha: 0.35),
              disabledForegroundColor: Colors.white70,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            p,
            k,
            t,
          ),
        ),
        _StateRow(
          id: 'filled',
          label: 'FilledButton: tema artık aynı gradyan/cam dilinde',
          builder: (p, k, t) => FilledButton(key: k, onPressed: p, child: Text(t)),
        ),
        _StateRow(
          id: 'filled_icon',
          label: 'FilledButton.icon + yerel yeşil',
          builder: (p, k, t) => FilledButton.icon(
            key: k,
            onPressed: p,
            style: FilledButton.styleFrom(backgroundColor: AppTheme.accentGreen),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t),
          ),
        ),
        _FocusRow(),
        _LongLabelRow(),
      ],
    );

/// Klavye odağı: `statesController` ile `focused` durumu zorlanır (aynı karede birden çok düğme odaklı görünebilsin).
class _FocusRow extends StatefulWidget {
  @override
  State<_FocusRow> createState() => _FocusRowState();
}

class _FocusRowState extends State<_FocusRow> {
  final List<WidgetStatesController> _controllers = <WidgetStatesController>[
    WidgetStatesController(<WidgetState>{WidgetState.focused}),
    WidgetStatesController(<WidgetState>{WidgetState.focused}),
    WidgetStatesController(<WidgetState>{WidgetState.focused}),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'klavye odağı: mürekkep renginde 2 px halka (varsayılan · amber · rose)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.getTextMuted(context)),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(onPressed: () {}, statesController: _controllers[0], child: const Text('Odak')),
              ElevatedButton(
                onPressed: () {},
                statesController: _controllers[1],
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber),
                child: const Text('Odak'),
              ),
              ElevatedButton(
                onPressed: () {},
                statesController: _controllers[2],
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed),
                child: const Text('Odak'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LongLabelRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'tam genişlik + uzun etiket (taşma yok; iki satıra sarar)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.getTextMuted(context)),
          ),
        ),
        ElevatedButton.icon(
          onPressed: () {},
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentAmber),
          icon: const Icon(Icons.refresh_rounded, size: 20),
          label: const Text('Daire listesini yenile ve cihazları yeniden eşle', maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () {},
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed),
          child: const Text('Hesabı kalıcı olarak sil', maxLines: 2, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WP-V8 TONE düğme galerisi', () {
    setUpAll(loadGoldenFonts);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';
        final ratio = scale > 1 ? 1.0 : 2.0;

        /// Sayfayı kurar, içerik yüksekliğine kırpar, her `pressed_*` düğmesine ayrı parmakla basar ve PNG üretir.
        Future<void> shoot(WidgetTester tester, String name, Widget sheet) async {
          final boundary = GlobalKey();
          final content = GlobalKey();
          await pumpGallery(
            tester,
            boundaryKey: boundary,
            brightness: brightness,
            textScale: scale,
            size: const Size(360, 4000),
            child: Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: KeyedSubtree(key: content, child: sheet),
              ),
            ),
          );
          final height = tester.getSize(find.byKey(content)).height.ceilToDouble() + 8;
          tester.view.physicalSize = Size(360 * 2, height * 2);
          await tester.pump();
          final gestures = <TestGesture>[];
          var pointer = 1;
          final pressed = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('pressed_'));
          for (final key in tester.widgetList(pressed).map((w) => w.key!).toList()) {
            gestures.add(await tester.startGesture(tester.getCenter(find.byKey(key)), pointer: pointer++));
          }
          await tester.pump();
          await expectGolden(tester, boundary, '${name}_$tag.png', pixelRatio: ratio);
          for (final g in gestures) {
            await g.up();
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        testWidgets('aile stilleri ($tag)', (tester) => shoot(tester, 'families', _familiesSheet()));
        testWidgets('yerel renk ($tag)', (tester) => shoot(tester, 'local', _localSheet()));
        testWidgets('varyantlar ($tag)', (tester) => shoot(tester, 'variants', _variantsSheet()));
      }
    }
  }, skip: visualSkipReason);
}
