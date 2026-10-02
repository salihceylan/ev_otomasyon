import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../common/confirm_dialogs.dart';
import 'service_setup/device_link.dart';
import 'service_setup/panel/emergency_reset_card.dart';
import 'service_setup/panel/existing_devices_list.dart';
import 'service_setup/panel/service_pin_login_card.dart';
import 'service_setup/panel/service_tool_cards.dart';
import 'service_setup/panel/setup_resume_list.dart';
import 'service_setup/panel/wifi_setup_card.dart';
import 'service_setup/service_setup_wizard_page.dart';
import 'service_setup/service_target.dart';
import 'service_setup/session_banner.dart';
import 'service_setup/setup_store.dart';
import 'service_setup/setup_style.dart';
import 'service_setup/setup_widgets.dart';
import 'service_setup/steps/step_common.dart';

/// Servis paneli: servis sorumlusunun **tek giriş noktası**.
///
/// * "Yeni Kurulum Başlat" -> 10 adımlı kurulum sihirbazı.
/// * "Devam eden kurulumlar" -> bu telefonda yarım kalan kurulumlar (cihaz bazlı).
/// * "Mevcut cihazlarım" -> kurulu panoda bağlantıyı yeniden kurma / testleri yenileme.
/// * "Pano Wi-Fi & Modem Kurulumu" kartı ([WifiSetupCard]): **giriş durumundan bağımsız** (girişsiz, PIN,
///   personel, oturumu bitmiş ekran) görünür ve internet gerektirmeden çalışır (Aşama 16.1).
/// * Yönetim araçları (aboneler, envanter, pano değişimi, sistem doktoru, hesaplar):
///   yalnızca rolün kullanabildiği kartlar görünür.
/// * Acil sıfırlama yalnızca süper yönetici / kalıcı servis personeline ([Capabilities.canEmergencyReset])
///   görünür; geçici PIN oturumunda hiç gösterilmez.
///
/// Testler için [store], [scanner] ve [deviceApiFactory] enjekte edilebilir (sihirbaza iletilir).
class ServiceModePage extends StatefulWidget {
  const ServiceModePage({
    super.key,
    this.store,
    this.scanner = defaultSetupScanner,
    this.deviceApiFactory,
  });

  final SetupStore? store;
  final SetupScanner scanner;
  final DeviceApiFactory? deviceApiFactory;

  @override
  State<ServiceModePage> createState() => _ServiceModePageState();
}

class _ServiceModePageState extends State<ServiceModePage> {
  int _reload = 0;

  Future<void> _openWizard({
    SetupProgressRecord? resume,
    ServiceTarget? existing,
    int? startStep,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          resume: resume,
          existingTarget: existing,
          startStep: startStep,
          store: widget.store,
          deviceApiFactory: widget.deviceApiFactory,
          scanner: widget.scanner,
        ),
      ),
    );
    if (mounted) setState(() => _reload++);
  }

  void _backToLogin() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final access = ServiceSetupAccess.fromState(state);
    return Scaffold(
      backgroundColor: SetupColors.background(context),
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Servis Paneli', key: Key('nav_service_title'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text('Kurulum, test ve yönetim', style: TextStyle(fontSize: 11.5)),
          ],
        ),
      ),
      body: SafeArea(child: _body(context, state, access)),
    );
  }

  Widget _body(BuildContext context, AutomationState state, ServiceSetupAccess? access) {
    if (!state.isAuthenticated && state.sessionNotice != null) {
      // Oturum bitmiş olsa da Wi-Fi kurulum sihirbazı girişsiz çalışır (Aşama 16.1).
      return SessionExpiredPanel(
        onBackToLogin: _backToLogin,
        trailing: WifiSetupCard(margin: const EdgeInsets.only(top: 24), deviceApiFactory: widget.deviceApiFactory),
      );
    }
    if (access == null) {
      return _LoginView(denied: state.isAuthenticated, deviceApiFactory: widget.deviceApiFactory);
    }
    return _Panel(
      state: state,
      access: access,
      reload: _reload,
      store: widget.store,
      scanner: widget.scanner,
      deviceApiFactory: widget.deviceApiFactory,
      onOpenWizard: _openWizard,
    );
  }
}

/// Servis oturumu yok: PIN ile giriş.
class _LoginView extends StatelessWidget {
  const _LoginView({required this.denied, this.deviceApiFactory});

  /// Oturum açık ama servis yetkisi yok.
  final bool denied;
  final DeviceApiFactory? deviceApiFactory;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        key: const Key('service_login_view'),
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (denied)
                const SetupCard(
                  key: Key('service_denied'),
                  accent: SetupColors.warn,
                  margin: EdgeInsets.only(bottom: 12),
                  child: SetupInfoRow(
                    icon: Icons.lock_outline_rounded,
                    color: SetupColors.warn,
                    bold: true,
                    text: 'Bu bölüm yalnızca servis personeli içindir. Servis PIN\'iniz varsa aşağıdan servis '
                        'oturumu açabilirsiniz.',
                  ),
                ),
              const ServicePinLoginCard(),
              const SizedBox(height: 12),
              Text(
                'Kalıcı servis hesabınız varsa uygulamadan çıkış yapıp e-posta ve parolanızla giriş ekranından girin.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.35, color: SetupColors.muted(context)),
              ),
              // Pano Wi-Fi & Modem Kurulumu: giriş yapılmamış olsa da görünür ve çalışır (Aşama 16.1).
              WifiSetupCard(margin: const EdgeInsets.only(top: 20), deviceApiFactory: deviceApiFactory),
            ],
          ),
        ),
      ),
    );
  }
}

/// Servis oturumu açık: kurulum, devam eden işler, araçlar.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.state,
    required this.access,
    required this.reload,
    required this.store,
    required this.scanner,
    required this.onOpenWizard,
    this.deviceApiFactory,
  });

  final AutomationState state;
  final DeviceApiFactory? deviceApiFactory;
  final ServiceSetupAccess access;
  final int reload;
  final SetupStore? store;
  final SetupScanner scanner;
  final Future<void> Function({SetupProgressRecord? resume, ServiceTarget? existing, int? startStep}) onOpenWizard;

  /// Çek-yenile: hata paneli bozmaz ama **sessizce yutulmaz**; kullanıcıya anlaşılır bir mesaj gösterilir.
  ///
  /// `AutomationState.refresh` ağ hatalarında fırlatmaz, hatayı durumda tutar (`homesError` / `endpointsError`);
  /// bu yüzden yenileme sonrası durum da denetlenir. Zaman aşımı ise istisna olarak gelir.
  Future<void> _refresh(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    String? problem;
    try {
      await state.refresh().timeout(const Duration(seconds: 20));
      // Aktif daire yoksa yenileme ev listesini, varsa daire verisini çeker.
      problem = state.activeHome == null ? state.homesError : state.endpointsError;
    } catch (e) {
      problem = friendlyError(e, fallback: 'Bağlantınızı kontrol edip tekrar deneyin.');
    }
    if (problem == null || problem.isEmpty) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('snack_refresh_failed'),
          behavior: SnackBarBehavior.floating,
          content: Text('Yenilenemedi: $problem'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final caps = state.capabilities;
    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: ListView(
        key: const Key('service_panel'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const ServiceSessionBanner(),
          SetupCard(
            accent: SetupColors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Yeni Kurulum',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
                const SizedBox(height: 6),
                Text(
                  access.isPinSession
                      ? 'Bu dairenin panosunu adım adım kurun ve test edin. Her adım gerçek cihaz ve sunucu '
                          'yanıtıyla doğrulanır.'
                      : 'Yeni bir panoyu tanıyın, müşteriye bağlayın ve adım adım kurup test edin. Her adım '
                          'gerçek cihaz ve sunucu yanıtıyla doğrulanır.',
                  style: TextStyle(fontSize: 13.5, height: 1.4, color: SetupColors.muted(context)),
                ),
                if (access.isPinSession)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Geçici servis oturumunda cihazı müşteriye bağlama (claim) yapılamaz; yalnızca bu dairedeki '
                      'panoda çalışabilirsiniz.',
                      key: const Key('pin_session_note'),
                      style: TextStyle(fontSize: 12.5, height: 1.35, color: SetupColors.muted(context)),
                    ),
                  ),
                const SizedBox(height: 12),
                SetupPrimaryButton(
                  key: const Key('btn_new_setup'),
                  label: 'Yeni Kurulum Başlat',
                  icon: Icons.add_circle_outline_rounded,
                  onPressed: () => onOpenWizard(),
                ),
              ],
            ),
          ),
          WifiSetupCard(deviceApiFactory: deviceApiFactory),
          SetupResumeList(
            key: ValueKey<int>(reload),
            access: access,
            store: store,
            onOpen: (record) => onOpenWizard(resume: record),
          ),
          ExistingDevicesList(
            onOpen: (target, step) => onOpenWizard(existing: target, startStep: step),
          ),
          ServiceToolCards(scanner: scanner),
          if (caps.canEmergencyReset) ...[
            const SetupSectionTitle('Acil durum'),
            const SizedBox(height: 8),
            EmergencyResetCard(scanner: scanner),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const Key('btn_service_logout'),
            onPressed: () => unawaited(confirmAndLogout(context, state)),
            icon: const Icon(Icons.logout_rounded, color: SetupColors.error),
            label: Text(access.isPinSession ? 'Servis Oturumunu Kapat' : 'Çıkış Yap'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              foregroundColor: SetupColors.error,
              side: const BorderSide(color: SetupColors.error),
            ),
          ),
        ],
      ),
    );
  }
}
