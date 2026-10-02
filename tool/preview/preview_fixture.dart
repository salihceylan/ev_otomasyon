// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
//
// Platform-neutral half of the DEV-ONLY preview harness: configuration, mock data and the app shell.
//
//   * tool/preview/preview_main.dart            Flutter web entrypoint (screenshots via headless Chrome)
//   * tool/preview/golden/preview_golden_test.dart  `flutter test` renderer (PNG files, no browser)
//
// Nothing under lib/ imports this. Everything that touches lib/ APIs is in this file, so API drift
// (e.g. the HomeModel/EndpointModel id migration int -> UUID String) is fixed in ONE place.
//
// Model data is built through the models' own `fromJson` factories (snake_case wire format), never
// through constructors, so the same fixture compiles against the pre-refactor HEAD models and the
// new contract models.

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Set by the build script (`--src head`) for the pre-refactor models where the owner flag lives in
/// `UserModel.role == 'owner'`. In the new contract the owner flag is `HomeModel.role == 'owner'`
/// and `UserModel.role == 'user'`.
const bool kPreviewLegacyRoles = bool.fromEnvironment('PREVIEW_LEGACY_ROLES');

// ---------------------------------------------------------------------------------------------
// Configuration (web: query string; tests: explicit map)
// ---------------------------------------------------------------------------------------------

class PreviewConfig {
  PreviewConfig(Map<String, String> q)
      : screen = q['screen'] ?? 'dashboard',
        dark = (q['theme'] ?? 'dark') != 'light',
        scenario = q['scenario'] ?? 'default',
        shell = q['shell'] ?? 'page',
        perf = q['perf'] == '1',
        freeze = q['freeze'] == '1',
        textScale = double.tryParse(q['textscale'] ?? '') ?? 1.0,
        insetTop = double.tryParse((q['insets'] ?? '').split(',').first) ?? 0,
        insetBottom = double.tryParse((q['insets'] ?? '').split(',').last) ?? 0,
        legacy = kPreviewLegacyRoles || q['legacy'] == '1';

  final String screen;
  final bool dark;
  final String scenario;
  final String shell;
  final bool perf;

  /// Freeze every Ticker (timeDilation) once the screen settled: screens with endless animations
  /// (spinners, shimmer, animated backgrounds) otherwise never become idle and move while captured.
  final bool freeze;

  /// MediaQuery text scale (accessibility check: 1.3 / 1.5 expose overflow and clipped labels).
  final double textScale;

  /// Simulated system insets in logical px (`insets=top,bottom`, e.g. `30,24` for an Android phone).
  final double insetTop;
  final double insetBottom;
  final bool legacy;

  String get themeName => dark ? 'dark' : 'light';
  String get readyKey => '$screen:$themeName:$scenario';
}

// ---------------------------------------------------------------------------------------------
// Fixture data (wire-format JSON -> real models)
// ---------------------------------------------------------------------------------------------

Map<String, dynamic> _ep(
  int id,
  int channel,
  String name,
  String room,
  String type, {
  bool on = false,
  int pos = 0,
  int duration = 24,
}) =>
    <String, dynamic>{
      'id': id,
      'home_id': 1,
      'device_id': 1,
      'channel': channel,
      'name': name,
      'room': room,
      'endpoint_type': type,
      'current_state': on,
      'shutter_position': pos,
      'shutter_duration_sec': duration,
    };

class PreviewFixture {
  PreviewFixture(this.cfg) {
    final lightsOn = cfg.scenario == 'quiet' ? <int>{} : (cfg.scenario == 'locked' ? {5, 7, 9} : {5, 7});
    List<Map<String, dynamic>> eps;
    if (cfg.scenario == 'empty') {
      eps = <Map<String, dynamic>>[];
    } else if (cfg.scenario == 'many') {
      eps = _manyEndpoints();
    } else {
      eps = <Map<String, dynamic>>[
        _ep(101, 1, 'Salon Panjur', 'Salon', 'shutter', pos: 100),
        _ep(102, 3, 'Yatak Odası Panjur', 'Yatak Odası', 'shutter', pos: 40),
        _ep(105, 5, 'Salon Avize', 'Salon', 'light', on: lightsOn.contains(5)),
        _ep(106, 6, 'Mutfak Tezgah', 'Mutfak', 'light', on: lightsOn.contains(6)),
        _ep(107, 7, 'Antre Spot', 'Antre', 'light', on: lightsOn.contains(7)),
        _ep(108, 8, 'Yatak Odası Başucu', 'Yatak Odası', 'light', on: lightsOn.contains(8)),
        _ep(109, 9, 'Balkon Aplik', 'Balkon', 'light', on: lightsOn.contains(9)),
        _ep(110, 10, 'Bahçe Kapısı', 'Balkon', 'impulse'),
      ];
    }
    endpointJson = eps;
  }

  final PreviewConfig cfg;
  late final List<Map<String, dynamic>> endpointJson;

  static List<Map<String, dynamic>> _manyEndpoints() {
    const rooms = ['Salon', 'Mutfak', 'Yatak Odası', 'Antre', 'Balkon'];
    final out = <Map<String, dynamic>>[];
    var id = 200;
    for (var p = 0; p < 6; p++) {
      out.add(_ep(id++, 1 + p * 2, 'Panjur ${p + 1}', rooms[p % rooms.length], 'shutter', pos: (p * 18) % 101));
    }
    for (var i = 0; i < 30; i++) {
      out.add(_ep(id++, 13 + i, 'Lamba ${i + 1}', rooms[i % rooms.length], 'light', on: i % 3 == 0));
    }
    return out;
  }

  List<EndpointModel> get endpoints => endpointJson.map(EndpointModel.fromJson).toList();

  UserModel get user => UserModel.fromJson(<String, dynamic>{
        'id': 7,
        'email': 'ev.sahibi@example.com',
        'full_name': 'Salih Ceylan',
        'phone': '+90 555 111 22 33',
        // HEAD models carry the owner flag on the user; the new contract carries it on the home.
        'role': cfg.legacy ? 'owner' : 'user',
      });

  HomeModel get home => HomeModel.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Ceylan Evi',
        'role': 'owner',
        'timezone': 'Europe/Istanbul',
        'mqtt_username': 'h_preview0000000000',
        'mqtt_topic_id': 'h_preview0000000000',
      });

  bool get connected => cfg.scenario != 'offline';
  bool get childLock => cfg.scenario == 'locked';

  /// Payload shape of GET /homes/:id/peace-notification as the current UI reads it
  /// (`enabled`, `time`; `notification_time` is the wire name used by PUT).
  /// Scenarios: peace_off = reminder disabled, peace_notime = enabled but no time chosen.
  Map<String, dynamic> get peace {
    switch (cfg.scenario) {
      case 'peace_off':
        return <String, dynamic>{'enabled': false, 'time': '', 'notification_time': ''};
      case 'peace_notime':
        return <String, dynamic>{'enabled': true, 'time': '', 'notification_time': ''};
      default:
        return <String, dynamic>{
          'enabled': true,
          'time': '23:30',
          'notification_time': '23:30',
          'timezone': 'Europe/Istanbul',
        };
    }
  }

  AuthStatus get authStatus {
    switch (cfg.screen) {
      case 'login':
        return AuthStatus.unauthenticated;
      case 'splash':
      case 'biometric':
        return AuthStatus.checking;
      default:
        return AuthStatus.authenticated;
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Mocked state
// ---------------------------------------------------------------------------------------------

/// AutomationState has testing setters for most fields, but NOT for the connection flag, the
/// child-lock flag or the peace-notification payload (they are only set by network code paths).
/// Overriding the public getters keeps the harness network-free without touching lib/.
class PreviewState extends AutomationState {
  PreviewState(this._fx);

  final PreviewFixture _fx;

  @override
  bool get isConnected => _fx.connected;

  @override
  bool get childLock => _fx.childLock;

  @override
  Map<String, dynamic>? get peaceNotificationData => _fx.peace;
}

bool _applying = false;

/// Idempotent: (re-)asserts the desired state. AutomationState's constructor starts an async
/// `_init()` (SharedPreferences / secure storage / biometric probe) that assigns mode, theme and
/// auth status when it completes, so the web entrypoint runs this again on every notification until
/// the screen settled.
void applyPreviewState(PreviewState s, PreviewFixture fx) {
  if (_applying) return;
  _applying = true;
  try {
    s.setModeForTesting(AppMode.cloud);
    s.setThemeModeForTesting(fx.cfg.dark ? ThemeMode.dark : ThemeMode.light);
    s.setCurrentUserForTesting(fx.user);
    s.setHomesForTesting(<HomeModel>[fx.home]);
    s.setCloudEndpointsForTesting(fx.endpoints);
    s.setBiometricForTesting(
      isSupported: true,
      isEnabled: false,
      checking: false,
      failed: fx.cfg.screen == 'biometric',
      label: 'Parmak İzi',
      shouldPrompt: false,
    );
    s.setAuthStatusForTesting(fx.authStatus);
  } finally {
    _applying = false;
  }
}

// ---------------------------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------------------------

/// Mirrors EvOtomasyonApp (lib/main.dart) but lets the harness choose the screen.
/// If main.dart's MaterialApp configuration changes, mirror it here (or use `shell=app` on web).
class PreviewApp extends StatelessWidget {
  const PreviewApp({super.key, required this.cfg});

  final PreviewConfig cfg;

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AutomationState, ThemeMode>((s) => s.themeMode);
    // `settings` is opened from the dashboard in the real app (AppBar shows a back arrow): build the
    // same two-route stack, without a transition animation.
    final stacked = cfg.screen == 'settings';
    return MaterialApp(
      title: 'AHBU Ev Otomasyonu (preview)',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: mode,
      builder: (context, child) {
        var mq = MediaQuery.of(context);
        if (cfg.textScale != 1.0) mq = mq.copyWith(textScaler: TextScaler.linear(cfg.textScale));
        if (cfg.insetTop > 0 || cfg.insetBottom > 0) {
          // Emulates the Android status bar / gesture bar that the browser does not have.
          final pad = EdgeInsets.only(top: cfg.insetTop, bottom: cfg.insetBottom);
          mq = mq.copyWith(padding: pad, viewPadding: pad);
        }
        return MediaQuery(data: mq, child: CircuitBackground(child: child ?? const SizedBox.shrink()));
      },
      initialRoute: stacked ? '/settings' : null,
      home: stacked ? null : previewScreenFor(cfg),
      onGenerateInitialRoutes: stacked
          ? (String name) => <Route<dynamic>>[
                MaterialPageRoute<void>(builder: (_) => const DashboardPage()),
                PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) => const DeviceSettingsPage(),
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                ),
              ]
          : null,
    );
  }
}

Widget previewScreenFor(PreviewConfig cfg) {
  switch (cfg.screen) {
    case 'login':
      return const LoginPage();
    case 'splash':
    case 'biometric':
      return const AuthGate();
    case 'dashboard':
    default:
      return const DashboardPage();
  }
}
