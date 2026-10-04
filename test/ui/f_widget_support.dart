import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/steps/step_common.dart';
import 'package:ev_otomasyon/ui/widgets/orb/glass_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'f_support.dart';

/// Servis paneli / sihirbaz **widget** testleri için ortak yardımcılar (WP-F).
///
/// Önemli: bu testlerde `serviceHarness(flush: () async {})` kullanılır ve `tester.runAsync`
/// kullanılmaz (bkz. [serviceHarness]).

/// Saati ilerleterek ([ServiceHarness.clock]) ve kare üreterek [cond] gerçekleşene kadar bekler.
Future<void> pumpUntil(
  WidgetTester tester,
  ServiceHarness env,
  bool Function() cond, {
  int maxIter = 800,
  Duration step = const Duration(milliseconds: 250),
  String? reason,
}) async {
  for (var i = 0; i < maxIter; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (cond()) return;
    env.clock.advance(step);
    await tester.pump();
  }
  fail('Koşul gerçekleşmedi${reason == null ? '' : ': $reason'}');
}

/// Saati ilerletmeden birkaç kare üretir (bekleyen mikro görevler/animasyonlar işlensin).
Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

bool present(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

/// [key] anahtarlı düğme (doğrudan ElevatedButton ya da onu saran widget) etkin mi.
bool buttonEnabled(WidgetTester tester, String key) {
  final root = find.byKey(Key(key));
  final direct = tester.widgetList(root).whereType<ElevatedButton>();
  if (direct.isNotEmpty) return direct.first.onPressed != null;
  final outlined = tester.widgetList(root).whereType<OutlinedButton>();
  if (outlined.isNotEmpty) return outlined.first.onPressed != null;
  final icon = tester.widgetList(root).whereType<IconButton>();
  if (icon.isNotEmpty) return icon.first.onPressed != null;
  // Cam disk düğmesi (kapat X'leri, çöp kutusu ...): `onTap == null` ⇒ pasif.
  final glass = tester.widgetList(root).whereType<GlassIconButton>();
  if (glass.isNotEmpty) return glass.first.onTap != null;
  final text = tester.widgetList(root).whereType<TextButton>();
  if (text.isNotEmpty) return text.first.onPressed != null;
  final inner = tester.widgetList<ElevatedButton>(find.descendant(of: root, matching: find.byType(ElevatedButton)));
  if (inner.isNotEmpty) return inner.first.onPressed != null;
  final innerOutlined = tester.widgetList<OutlinedButton>(find.descendant(of: root, matching: find.byType(OutlinedButton)));
  return innerOutlined.isNotEmpty && innerOutlined.first.onPressed != null;
}

bool continueEnabled(WidgetTester tester) {
  final finder = find.byKey(const Key('setup_continue'));
  if (finder.evaluate().isEmpty) return false;
  return tester.widget<ElevatedButton>(finder).onPressed != null;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget, reason: 'düğme bulunamadı: $key');
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder, warnIfMissed: false);
  await tester.pump();
}

Future<void> typeKey(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget, reason: 'alan bulunamadı: $key');
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, text);
  await tester.pump();
}

/// Bir sayfayı/diyaloğu `AutomationState` sağlayıcısıyla pompalar.
Future<void> pumpPage(
  WidgetTester tester,
  ServiceHarness env,
  Widget page, {
  Size size = const Size(900, 2400),
  double textScale = 1.0,
  ThemeMode themeMode = ThemeMode.dark,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: MaterialApp(
        themeMode: themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: page,
      ),
    ),
  );
  await tester.pump();
}

/// Bir diyaloğu başlatıcı düğmeyle açar (kapanınca başlatıcıya dönülür). Döndürülen işlev diyaloğun
/// kapanışında tamamlanan sonucu verir.
Future<void> pumpLauncher(
  WidgetTester tester,
  ServiceHarness env,
  Future<void> Function(BuildContext context) open, {
  Size size = const Size(900, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('launcher'),
                onPressed: () => open(context),
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Aktif daireyi (gerçek `selectHome` yolu) seçer: sahte bulut `homes` listesine eklenir.
Future<void> activateHome(
  WidgetTester tester,
  ServiceHarness env,
  HomeModel home,
) async {
  env.cloud.homes = <HomeModel>[home];
  env.state.setHomesForTesting(<HomeModel>[home]);
  var done = false;
  env.state.selectHome(home).then((_) => done = true);
  for (var i = 0; i < 40 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(env.state.activeHome?.id, home.id, reason: 'aktif daire seçilemedi');
}

/// Karekod tarayıcısı yerine geçen sahte: [content] her çağrıda döner (`null` = iptal).
Future<String?> Function(BuildContext context, {required String title, required String hint}) fakeScanner(
  String? content,
) =>
    (BuildContext context, {required String title, required String hint}) async => content;

// -----------------------------------------------------------------------------
// Kurulum sihirbazını açma
// -----------------------------------------------------------------------------

const String kWifiQr = 'WIFI:T:WPA;S:$kHomeWifiSsid;P:$kHomeWifiPass;;';

/// Sihirbazı bir başlatıcı sayfadan açar (bitince `pop` ile başlatıcıya dönülür).
Future<void> openWizard(
  WidgetTester tester,
  ServiceHarness env, {
  SetupScanner? scanner,
  Size size = const Size(900, 2800),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final scan = scanner ??
      (BuildContext context, {required String title, required String hint}) async =>
          title.contains('Wi-Fi') ? kWifiQr : kLabelQrForWidget;
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('launcher'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ServiceSetupWizardPage(
                    store: env.store,
                    deviceApiFactory: env.deviceFactory,
                    scanner: scan,
                  ),
                )),
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

const String kLabelQrForWidget = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kDeviceUid&pin=$kSetupPin';

Future<void> goNext(WidgetTester tester, ServiceHarness env, {String? reason}) async {
  await pumpUntil(tester, env, () => continueEnabled(tester), reason: reason ?? 'Devam etkinleşmedi');
  await tapKey(tester, 'setup_continue');
  await tester.pump(const Duration(milliseconds: 400));
}


// -----------------------------------------------------------------------------
// Pano (clipboard) ve günlük (debugPrint) gözlemcileri
// -----------------------------------------------------------------------------

/// Sistem panosunu bellekte taklit eder: `Clipboard.setData/getData` bu nesneye yazar/okur.
class ClipboardSpy {
  String? text;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        text = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        final value = text;
        return value == null ? null : <String, dynamic>{'text': value};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }
}

/// Test boyunca `debugPrint` çıktısını toplar (gizli/kişisel veri yazılmadığını denetlemek için).
///
/// `flutter_test` değişmezleri test **gövdesi biter bitmez** (tearDown'dan önce) denetler; bu yüzden
/// `debugPrint` yalnızca [withDebugLog] içinde değiştirilir ve orada geri yüklenir.
class DebugLog {
  final List<String> lines = <String>[];

  String get all => lines.join('\n');
}

Future<T> withDebugLog<T>(Future<T> Function(DebugLog log) body) async {
  final log = DebugLog();
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) log.lines.add(message);
  };
  try {
    return await body(log);
  } finally {
    debugPrint = previous;
  }
}
