import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/automation_state.dart';
import 'ui/theme/app_theme.dart';
import 'ui/pages/dashboard_page.dart';

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
    return MaterialApp(
      title: 'AHBU Ev Otomasyonu',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const DashboardPage(),
    );
  }
}
