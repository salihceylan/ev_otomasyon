import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'services/automation_state.dart';
import 'ui/app_shell.dart';
import 'ui/motion/motion_scope.dart';
import 'ui/pages/auth/auth_gate.dart';

/// Yakalanmamış hata bildirimi: yalnızca hata TÜRÜ yazdırılır (ileti/yığın sır içerebilir).
/// Üretimde bir çökme raporlama servisi bağlanacaksa buraya atanır.
void Function(Object error, StackTrace? stack)? appErrorReporter;

void _report(Object error, StackTrace? stack) {
  if (kDebugMode) debugPrint('[Yakalanmamış hata] ${error.runtimeType}');
  appErrorReporter?.call(error, stack);
}

/// Uygulamanın widget ağacını kurar. `main()` bunu kullanır; `integration_test` / QA ise sahte
/// ya da gerçek yerel arka uca bağlı bir [state] vererek aynı ağacı başlatabilir:
///
/// ```dart
/// await tester.pumpWidget(await buildApp(state: AutomationState(cloudApi: fakeApi)));
/// ```
///
/// [state] verilirse sahipliği çağırandadır (kapatma ona aittir); verilmezse ağaç kendi durumunu
/// oluşturur ve kapatır.
Future<Widget> buildApp({AutomationState? state}) async {
  WidgetsFlutterBinding.ensureInitialized();
  return MultiProvider(
    providers: [
      if (state != null)
        ChangeNotifierProvider<AutomationState>.value(value: state)
      else
        ChangeNotifierProvider<AutomationState>(create: (_) => AutomationState()),
    ],
    child: const EvOtomasyonApp(),
  );
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _report(details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _report(error, stack);
      return true;
    };
    // Tam hareket YALNIZ burada açılır (şartname §4.1): `EvOtomasyonApp`'i doğrudan pompalayan testler kapsam
    // görmez ve `MotionMode.off` (süre 0, döngü yok) ile çalışır; sistem "animasyonları kaldır" de kapatır.
    runApp(MotionScope(mode: MotionMode.full, child: await buildApp()));
  }, _report);
}

/// Kök uygulama: kabuğu ([AppShell]) bağlar. Komut hataları, oturum olayları ve tema
/// `lib/ui/app_shell.dart` içindedir; bu dosya yalnızca başlatma ve hata raporlamayı yönetir.
class EvOtomasyonApp extends StatelessWidget {
  const EvOtomasyonApp({super.key});

  @override
  Widget build(BuildContext context) => const AppShell(home: AuthGate());
}
