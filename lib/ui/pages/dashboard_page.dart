import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../dashboard/apartment_dashboard.dart';
import '../dashboard/console_dashboards.dart';
import '../dashboard/dashboard_app_bar.dart';
import '../widgets/biometric_prompt_dialog.dart';
import '../widgets/super_user_drawer.dart';

/// Ana pano. Rolüne göre üç görünümden birini gösterir:
///
/// * süper yönetici konsolu ([SuperConsole]),
/// * yetkili servis konsolu ([ServiceConsole]),
/// * daire panosu ([ApartmentDashboard]: ev sahibi, aile üyesi, misafir, servis PIN oturumu,
///   dairesi olmayan kullanıcı ve girişsiz yerel mod).
///
/// Sayfa kökü `AutomationState`'i **izlemez**: yalnızca görünüm türü için `select` kullanılır; alt
/// bileşenler kendi değerlerini seçer. Yetki kapıları `Capabilities`'tendir (kara liste yok).
/// Bu dosya yalnızca iskeleti kurar; ayrıntılar `lib/ui/dashboard/**` altındadır.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AutomationState>();
      if (state.shouldPromptBiometrics) {
        BiometricPromptDialog.show(context, label: state.biometricLabel);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, DashboardView>(dashboardViewOf);
    final isConsole = view != DashboardView.apartment;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isConsole ? const SuperUserDrawer() : null,
      appBar: DashboardAppBar(onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer()),
      body: switch (view) {
        DashboardView.superConsole => const SuperConsole(),
        DashboardView.serviceConsole => const ServiceConsole(),
        DashboardView.apartment => const ApartmentDashboard(),
      },
    );
  }
}
