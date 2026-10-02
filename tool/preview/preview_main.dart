// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages, avoid_print
//
// DEV-ONLY screenshot harness ("preview") for the Ev Otomasyonu Flutter app - WEB entrypoint.
//
// It is NOT part of the shipped app: nothing under lib/ imports it. It renders the REAL pages
// (DashboardPage, DeviceSettingsPage, LoginPage, AuthGate splash ...) inside the REAL theme with a
// fully mocked AutomationState, so screens can be captured without the cloud backend, MQTT broker
// or a device. Build + capture is driven by tool/preview/preview.mjs (see its header).
// Configuration, mock data and the app shell live in preview_fixture.dart (shared with the
// `flutter test` fallback in tool/preview/golden/).
//
//   flutter build web -t tool/preview/preview_main.dart --release
//   http://localhost:PORT/?screen=dashboard&theme=dark&scenario=default
//
// Query parameters
//   screen    dashboard | settings | login | splash | biometric        (default dashboard)
//   theme     dark | light                                              (default dark)
//   scenario  default | locked | quiet | offline | empty | many |
//             peace_off | peace_notime                                  (default default)
//   shell     page | app   page = replicate main.dart's MaterialApp (fast, deterministic);
//                          app  = mount the real EvOtomasyonApp + AuthGate (2.6 s splash, then the
//                                 real navigation; `settings` is pushed on the real Navigator)
//   freeze    1  -> stop all tickers (timeDilation) after the screen settled (endless animations)
//   textscale 1.3 -> MediaQuery text scaler (accessibility / overflow check)
//   insets    30,24 -> simulated top,bottom system insets in logical px (Android status/gesture bar)
//   perf      1  -> after the screen settled, hammer the state with 30 Hz endpoint updates for 3 s
//                   and publish frame timings (window.__previewPerf)
//   legacy    1  -> HEAD-style models (user.role == 'owner'); the build script sets this
//                   automatically via --dart-define=PREVIEW_LEGACY_ROLES=true for `--src head`.
//
// Contract with the capture script (all plain JS globals, set from Dart):
//   window.__previewReady  'screen:theme:scenario'  set when fonts are loaded and no frame is pending
//   window.__previewInfo   JSON {screen, theme, scenario, shell, idle, fontsOk, errors[]}
//   window.__previewPerf   JSON frame-timing summary (only with perf=1)

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' as ui;

import 'package:ev_otomasyon/main.dart' show EvOtomasyonApp;
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_fixture.dart';

VoidCallback? _reassertListener;

// ---------------------------------------------------------------------------------------------
// Error + JS bridge helpers
// ---------------------------------------------------------------------------------------------

final List<String> _errors = <String>[];

void _recordError(Object error, [StackTrace? stack]) {
  if (_errors.length >= 60) return;
  final text = error.toString().split('\n').take(4).join(' | ');
  _errors.add(text.length > 400 ? '${text.substring(0, 400)}...' : text);
}

void _publish(String name, String value) {
  globalContext.setProperty(name.toJS, value.toJS);
}

// ---------------------------------------------------------------------------------------------
// Readiness (fonts + images + no frame pending)
// ---------------------------------------------------------------------------------------------

Future<bool> _waitUntilIdle({Duration quiet = const Duration(milliseconds: 700), Duration timeout = const Duration(seconds: 25)}) async {
  final sw = Stopwatch()..start();
  var quietSince = sw.elapsed;
  while (sw.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final busy = SchedulerBinding.instance.hasScheduledFrame || SchedulerBinding.instance.transientCallbackCount > 0;
    if (busy) {
      quietSince = sw.elapsed;
    } else if (sw.elapsed - quietSince >= quiet) {
      return true;
    }
  }
  return false;
}

Future<void> _signalReady(PreviewConfig cfg, PreviewState state, PreviewFixture fx) async {
  // The very first frame creates the theme (-> google_fonts starts loading Inter).
  await WidgetsBinding.instance.endOfFrame;

  if (cfg.shell == 'app') {
    // AuthGate shows the splash for 2.6 s, then cross-fades (500 ms) to the real screen.
    await Future<void>.delayed(const Duration(milliseconds: 3300));
    if (cfg.screen == 'settings') {
      _pushSettingsOnRealNavigator();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
  }

  var fontsOk = true;
  try {
    await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 30));
  } catch (e) {
    fontsOk = false;
    _recordError('google_fonts: $e');
  }
  // Fonts finishing triggers a re-layout; also lets decoded images land.
  applyPreviewState(state, fx);
  // Endless animations (spinner on `splash`) never go idle: do not burn 25 s waiting for it.
  var idle = await _waitUntilIdle(timeout: const Duration(seconds: 6));
  // Fonts requested by widgets that only built after the first frame (dialogs etc.).
  try {
    await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 15));
  } catch (_) {}
  if (!idle) idle = await _waitUntilIdle(timeout: const Duration(seconds: 2));

  // From here on the fixture is final: stop fighting AutomationState._init().
  if (_reassertListener != null) state.removeListener(_reassertListener!);

  if (cfg.freeze) {
    // Deterministic capture for screens with endless animations: tickers effectively stop.
    timeDilation = 1e9;
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  _publish(
    '__previewInfo',
    jsonEncode(<String, Object?>{
      'screen': cfg.screen,
      'theme': cfg.themeName,
      'scenario': cfg.scenario,
      'shell': cfg.shell,
      'legacyRoles': cfg.legacy,
      'freeze': cfg.freeze,
      'textScale': cfg.textScale,
      'idle': idle,
      'fontsOk': fontsOk,
      'platform': defaultTargetPlatform.name,
      'devicePixelRatio': ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
      'errors': _errors,
    }),
  );
  _publish('__previewReady', cfg.readyKey);

  if (cfg.perf) {
    await _runPerf(state, fx);
  }
}

void _pushSettingsOnRealNavigator() {
  NavigatorState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is NavigatorState) {
      found = element.state as NavigatorState;
      return;
    }
    element.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  found?.push(MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage()));
}

// ---------------------------------------------------------------------------------------------
// Optional frame-timing probe (perf=1)
// ---------------------------------------------------------------------------------------------

Future<void> _runPerf(PreviewState state, PreviewFixture fx) async {
  final build = <int>[];
  final raster = <int>[];
  final total = <int>[];
  void onTimings(List<ui.FrameTiming> timings) {
    for (final t in timings) {
      build.add(t.buildDuration.inMicroseconds);
      raster.add(t.rasterDuration.inMicroseconds);
      total.add(t.totalSpan.inMicroseconds);
    }
  }

  SchedulerBinding.instance.addTimingsCallback(onTimings);
  final sw = Stopwatch()..start();
  var flip = false;
  var ticks = 0;
  final completer = Completer<void>();
  Timer.periodic(const Duration(milliseconds: 33), (timer) {
    // Simulates MQTT `state` bursts: every tick every light flips and every shutter moves.
    flip = !flip;
    final next = <EndpointModel>[
      for (final e in state.cloudEndpoints)
        e.isShutter
            ? e.copyWith(shutterPosition: flip ? 100 : 0)
            : e.copyWith(currentState: e.isLight ? flip : e.currentState),
    ];
    state.setCloudEndpointsForTesting(next);
    ticks++;
    if (sw.elapsed >= const Duration(seconds: 3)) {
      timer.cancel();
      completer.complete();
    }
  });
  await completer.future;
  await Future<void>.delayed(const Duration(milliseconds: 500));
  SchedulerBinding.instance.removeTimingsCallback(onTimings);

  Map<String, Object> stats(List<int> us) {
    if (us.isEmpty) return <String, Object>{'n': 0};
    final sorted = List<int>.from(us)..sort();
    double ms(int v) => (v / 1000 * 100).round() / 100;
    int at(double p) => sorted[((sorted.length - 1) * p).round()];
    return <String, Object>{
      'n': sorted.length,
      'avg_ms': ms((sorted.reduce((a, b) => a + b) / sorted.length).round()),
      'p50_ms': ms(at(0.5)),
      'p90_ms': ms(at(0.9)),
      'p99_ms': ms(at(0.99)),
      'max_ms': ms(sorted.last),
      'over_16ms': sorted.where((v) => v > 16667).length,
      'over_33ms': sorted.where((v) => v > 33333).length,
    };
  }

  _publish(
    '__previewPerf',
    jsonEncode(<String, Object?>{
      'screen': fx.cfg.screen,
      'scenario': fx.cfg.scenario,
      'updates_sent': ticks,
      'frames': total.length,
      'build': stats(build),
      'raster': stats(raster),
      'total': stats(total),
      'note': 'headless software/ANGLE rendering: compare before/after runs, do not read as device numbers',
    }),
  );
}

// ---------------------------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final cfg = PreviewConfig(Uri.base.queryParameters);

  FlutterError.onError = (FlutterErrorDetails details) {
    _recordError(details.exceptionAsString(), details.stack);
    FlutterError.presentError(details);
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _recordError(error, stack);
    return true; // handled: do not crash the zone
  };

  // Deterministic persisted values for AutomationState._init().
  SharedPreferences.setMockInitialValues(<String, Object>{
    'saved_app_mode': 'cloud',
    'saved_theme_mode': cfg.themeName,
  });

  final fx = PreviewFixture(cfg);
  final state = PreviewState(fx);
  applyPreviewState(state, fx);
  // _init() finishes asynchronously and assigns its own values: win every time it notifies.
  // The listener is removed as soon as the screen is published as ready (see _signalReady) so the
  // perf churn / later interactions are not overwritten.
  _reassertListener = () => applyPreviewState(state, fx);
  state.addListener(_reassertListener!);
  Timer(const Duration(seconds: 45), () => state.removeListener(_reassertListener!));

  final Widget root = cfg.shell == 'app'
      ? ChangeNotifierProvider<AutomationState>.value(value: state, child: const EvOtomasyonApp())
      : ChangeNotifierProvider<AutomationState>.value(value: state, child: PreviewApp(cfg: cfg));

  runApp(root);
  unawaited(_signalReady(cfg, state, fx));
}
