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
/// Sayfa kökü yeniden kurulmak için `AutomationState`'i **izlemez**: yalnızca görünüm türü için `select`
/// kullanılır; alt bileşenler kendi değerlerini seçer. (Biyometrik istemin zamanlaması için durumu dinler ve
/// rotanın en üstte olup olmadığına `ModalRoute` ile bağlıdır; bu, sayfayı yeniden kurmaz.)
/// Yetki kapıları `Capabilities`'tendir (kara liste yok).
/// Bu dosya yalnızca iskeleti kurar; ayrıntılar `lib/ui/dashboard/**` altındadır.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  AutomationState? _state;
  bool _routeIsCurrent = true;
  bool _promptScheduled = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AutomationState>()..addListener(_maybePromptBiometrics);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Üstteki sayfa/diyalog kapanınca (pano rotası yeniden en üstte) istem yeniden değerlendirilir.
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _maybePromptBiometrics();
  }

  @override
  void dispose() {
    _state?.removeListener(_maybePromptBiometrics);
    super.dispose();
  }

  /// İlk giriş sonrası biyometrik istem. **Yalnızca pano rotası en üstteyken** açılır: giriş akışının
  /// kendi sayfası/diyaloğu (kayıt, telefon kodu, sihirli bağlantı) hâlâ yığındayken açılırsa akış
  /// biterken kapattığı rota istem olur ve kullanıcı karar vermeden "daha sonra" sayılır.
  void _maybePromptBiometrics() {
    final state = _state;
    if (state == null || _promptScheduled || !_routeIsCurrent || !state.shouldPromptBiometrics) return;
    _promptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // Kare sonunda canlı değer okunur: aynı karede başka bir geri çağrı rota itmiş olabilir.
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? true) && state.shouldPromptBiometrics) {
          await BiometricPromptDialog.show(context, label: state.biometricLabel);
        }
      } finally {
        _promptScheduled = false;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
