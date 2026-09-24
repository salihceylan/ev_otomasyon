import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/automation_state.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/circuit_background.dart';
import 'ui/pages/auth/auth_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AutomationState()),
      ],
      child: const EvOtomasyonApp(),
    ),
  );
}

class EvOtomasyonApp extends StatelessWidget {
  const EvOtomasyonApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();

    return MaterialApp(
      title: 'AHBU Ev Otomasyonu',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: state.themeMode,
      builder: (context, child) {
        return CircuitBackground(
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AuthGate(
        minSplashDuration: Duration(milliseconds: 2600),
      ),
    );
  }
}
