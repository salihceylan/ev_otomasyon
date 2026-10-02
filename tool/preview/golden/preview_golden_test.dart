// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages, avoid_print
//
// FALLBACK renderer: real PNGs of the real pages through `flutter test` (no browser, no web build).
//
//   node tool/preview/preview.mjs golden [--src working|head] [--screens dashboard,settings,login]
//
// The wrapper runs this file in an isolated snapshot whose pubspec.yaml additionally bundles Inter
// (`assets: - google_fonts/`), because google_fonts otherwise tries to download the font and a
// widget test has no usable network/path_provider. Run by hand only inside such a snapshot.
//
// Environment
//   PREVIEW_GOLDEN_OUT       output directory (default build/preview_shots/golden)
//   PREVIEW_GOLDEN_SCREENS   comma list (default dashboard,settings,login)
//   PREVIEW_GOLDEN_THEMES    comma list (default dark,light)
//   PREVIEW_GOLDEN_SCENARIOS comma list (default default)
//   PREVIEW_GOLDEN_SIZE      logical WxH@dpr (default 390x844@2)
//
// KNOWN LIMITS (why web is the primary method): colour emoji (the UI uses 💡 🪟 ⚡ in labels) render as
// empty boxes because the test engine has no emoji font; blur/shadow rasterisation comes from the
// software Skia of flutter_tester and differs slightly from Impeller on a phone.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../preview_fixture.dart';

List<String> _env(String name, String fallback) =>
    (Platform.environment[name] ?? fallback).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final outDir = Platform.environment['PREVIEW_GOLDEN_OUT'] ?? 'build/preview_shots/golden';
  final screens = _env('PREVIEW_GOLDEN_SCREENS', 'dashboard,settings,login');
  final themes = _env('PREVIEW_GOLDEN_THEMES', 'dark,light');
  final scenarios = _env('PREVIEW_GOLDEN_SCENARIOS', 'default');
  final sizeSpec = RegExp(r'^(\d+)x(\d+)@(\d+(?:\.\d+)?)$').firstMatch(Platform.environment['PREVIEW_GOLDEN_SIZE'] ?? '390x844@2');
  final logicalW = double.parse(sizeSpec?.group(1) ?? '390');
  final logicalH = double.parse(sizeSpec?.group(2) ?? '844');
  final dpr = double.parse(sizeSpec?.group(3) ?? '2');

  for (final scenario in scenarios) {
    for (final screen in screens) {
      for (final theme in themes) {
        final name = '$screen-$theme${scenario == 'default' ? '' : '-$scenario'}-golden';
        testWidgets(name, (tester) async {
          SharedPreferences.setMockInitialValues(<String, Object>{
            'saved_app_mode': 'cloud',
            'saved_theme_mode': theme,
          });
          FlutterSecureStorage.setMockInitialValues(<String, String>{});
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(logicalW * dpr, logicalH * dpr);
          addTearDown(tester.view.reset);

          final cfg = PreviewConfig(<String, String>{'screen': screen, 'theme': theme, 'scenario': scenario});
          final fx = PreviewFixture(cfg);
          final state = PreviewState(fx);
          addTearDown(state.dispose);
          applyPreviewState(state, fx);

          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: ChangeNotifierProvider<AutomationState>.value(value: state, child: PreviewApp(cfg: cfg)),
            ),
          );

          // Fonts, asset images and AutomationState._init() complete in REAL time, not in fake time.
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              try {
                await GoogleFonts.pendingFonts();
              } catch (_) {/* reported by the PNG itself (fallback glyphs) */}
            });
            applyPreviewState(state, fx);
            await tester.pump(const Duration(milliseconds: 120));
          }

          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: dpr);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$outDir/$name.png')..createSync(recursive: true);
            file.writeAsBytesSync(bytes!.buffer.asUint8List());
            print('PREVIEW_GOLDEN wrote ${file.path} (${image.width}x${image.height})');
          });
        });
      }
    }
  }
}
