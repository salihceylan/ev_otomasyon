import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../common/app_dialogs.dart';
import '../common/confirm_dialogs.dart';
import '../motion/motion.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/settings/accent_button.dart';
import '../widgets/orb/orb_icon_badge.dart';
import 'service_setup/panel/service_glass.dart';
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

/// [ServiceSetupAccess]'in karşılaştırılabilir özeti: sınıf `==` tanımlamadığı için `context.select` onu her
/// bildirimde "değişti" sayardı; alanları kayıt olarak `==` ile karşılaştırılır.
typedef _AccessKey = ({
  SetupMode mode,
  String ownerKey,
  String technicianName,
  bool isSuperUser,
  String? sessionHomeId,
  String? sessionHomeName,
  DateTime? sessionExpiresAt,
});

/// Sayfa kökünün görünümünü belirleyen tüm değerler (`build` yalnızca bunlara bağlıdır).
typedef _ModeView = ({bool authenticated, bool hasNotice, _AccessKey? access});

_ModeView _modeViewOf(AutomationState s) {
  final a = ServiceSetupAccess.fromState(s);
  return (
    authenticated: s.isAuthenticated,
    hasNotice: s.sessionNotice != null,
    access: a == null
        ? null
        : (
            mode: a.mode,
            ownerKey: a.ownerKey,
            technicianName: a.technicianName,
            isSuperUser: a.isSuperUser,
            sessionHomeId: a.sessionHomeId,
            sessionHomeName: a.sessionHomeName,
            sessionExpiresAt: a.sessionExpiresAt,
          ),
  );
}

ServiceSetupAccess _accessFrom(_AccessKey k) => ServiceSetupAccess(
      mode: k.mode,
      ownerKey: k.ownerKey,
      technicianName: k.technicianName,
      isSuperUser: k.isSuperUser,
      sessionHomeId: k.sessionHomeId,
      sessionHomeName: k.sessionHomeName,
      sessionExpiresAt: k.sessionExpiresAt,
    );

class _ServiceModePageState extends State<ServiceModePage> {
  int _reload = 0;

  /// Sihirbaz rotası açılırken/açıkken yeniden giriş engellenir (PF-47): aynı kare içinde gelen ikinci
  /// etkinleştirme (erişilebilirlik eylemi, klavye Enter tekrarı) ikinci bir sihirbaz rotası açmasın. İkinci rota
  /// aynı cihaz kaydıyla ikinci bir denetleyici (çift zamanlayıcı, `SetupStore.save` yarışı, çift komut) demektir.
  /// Rota kapanınca (`finally`) bırakılır.
  bool _opening = false;

  Future<void> _openWizard({
    SetupProgressRecord? resume,
    ServiceTarget? existing,
    int? startStep,
  }) async {
    if (_opening) return;
    _opening = true;
    try {
      // Mevcut cihaz kipi ("Testleri yap / Bağlantıyı yeniden kur") aynı panonun yarım kaydını sessizce ezmesin
      // (servis_kurulum-8): kayıt varsa devam / baştan başla / vazgeç sorulur.
      if (existing != null && resume == null) {
        final access = ServiceSetupAccess.fromState(context.read<AutomationState>());
        if (access != null) {
          final store = widget.store ?? SetupStore();
          final record = await store.load(access.ownerKey, existing.deviceUuid);
          if (!mounted) return;
          if (record != null) {
            final choice = await _askHalfRecord(record);
            if (!mounted || choice == null) return; // Vazgeç: kayıt aynen kalır
            if (choice) {
              resume = record;
              existing = null;
              startStep = null;
            } else {
              await store.delete(access.ownerKey, record.deviceUuid);
              if (!mounted) return;
            }
          }
        }
      }
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
    } finally {
      _opening = false;
    }
    if (mounted) setState(() => _reload++);
  }

  /// Yarım kayıt sorusu: `true` = kaldığı yerden devam, `false` = baştan başla (kayıt silinir), `null` = vazgeç.
  Future<bool?> _askHalfRecord(SetupProgressRecord record) {
    return showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text('Bu panonun yarım kalmış kurulumu var (Adım ${record.currentStep})'),
        content: const Text(
          'Kaldığınız yerden devam edebilir ya da baştan başlayabilirsiniz. Baştan başlarsanız yarım kalan kurulum kaydı '
          'silinir.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_half_cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            key: const Key('btn_half_restart'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Baştan Başla (kayıt silinir)'),
          ),
          ElevatedButton(
            key: const Key('btn_half_resume'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Kaldığınız Yerden Devam'),
          ),
        ],
      ),
    );
  }

  void _backToLogin() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    // Sayfa kökü tüm durumu izlemez (PF-06): yalnızca görünümü belirleyen değerler seçilir; her bildirimde
    // (çevrimiçi/çevrimdışı geçişleri, durum yenilemeleri) sayfa yeniden kurulmaz. Kartlar kendi değerlerini
    // kendileri seçer.
    final view = context.select<AutomationState, _ModeView>(_modeViewOf);
    final state = context.read<AutomationState>();
    final accessKey = view.access;
    final access = accessKey == null ? null : _accessFrom(accessKey);
    // Scaffold arka planı temadan saydam gelir: küresel `CircuitBackground` (AppShell) görünür; opak zemin onu örter ve
    // aynı akışta sayfa değişince zemin "devre kartlı"dan "düz lacivert"e atlardı (PF-15 c).
    return Scaffold(
      appBar: const NeonAppBar(
        title: 'Servis Paneli',
        titleKey: Key('nav_service_title'),
        subtitle: 'Kurulum, test ve yönetim',
        feature: AppFeature.commissioning,
        icon: Icons.engineering_rounded,
      ),
      // Oturum bitti → giriş → panel geçişi: tek durum çocuğu (eski+yeni görünüm birlikte ağaçta olmaz).
      body: SafeArea(
        child: StateSwitcher(
          stateKey: !view.authenticated && view.hasNotice ? 'expired' : (access == null ? 'login' : 'panel'),
          child: SizedBox.expand(child: _body(context, state, view, access)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AutomationState state, _ModeView view, ServiceSetupAccess? access) {
    if (!view.authenticated && view.hasNotice) {
      // Oturum bitmiş olsa da Wi-Fi kurulum sihirbazı girişsiz çalışır (Aşama 16.1).
      return SessionExpiredPanel(
        onBackToLogin: _backToLogin,
        trailing: WifiSetupCard(margin: const EdgeInsets.only(top: 24), deviceApiFactory: widget.deviceApiFactory),
      );
    }
    if (access == null) {
      return _LoginView(denied: view.authenticated, deviceApiFactory: widget.deviceApiFactory);
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
                const ServiceCard(
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
              // Açıklama cam kartın içinde (eskiden kartsız, doğrudan devre kartı zemininde duran 12.5 sp metin açık temada iz
              // çizgileri ve lehim noktalarıyla iç içe geçiyordu). 'e-posta' bölünmez tireyle (U+2011) yazılır: satır sonunda
              // "e-" / "posta" diye ayrılmaz.
              ServiceCard(
                key: const Key('service_login_hint'),
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.s16, vertical: AppSpace.s12),
                child: Text(
                  'Kalıcı servis hesabınız varsa uygulamadan çıkış yapıp e‑posta ve parolanızla giriş ekranından girin.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppText.caption, height: 1.35, color: SetupColors.muted(context)),
                ),
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
    // Yalnızca acil sıfırlama kartının görünürlüğü yetkiye bağlıdır (PF-06): tüm durumu izlemek yerine tek bayrak.
    final canEmergencyReset = context.select<AutomationState, bool>((s) => s.capabilities.canEmergencyReset);
    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: ListView(
        key: const Key('service_panel'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const ServiceSessionBanner(),
          StaggeredEntrance(
            index: 0,
            child: ServiceCard(
            accent: SetupColors.primary,
            active: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const OrbIconBadge(icon: Icons.rocket_launch_rounded, family: AppFamilies.sky),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Yeni Kurulum',
                        style: TextStyle(fontSize: AppText.title, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  access.isPinSession
                      ? 'Bu dairenin panosunu adım adım kurun ve test edin. Her adım gerçek cihaz ve sunucu '
                          'yanıtıyla doğrulanır.'
                      : 'Yeni bir panoyu tanıyın, müşteriye bağlayın ve adım adım kurup test edin. Her adım '
                          'gerçek cihaz ve sunucu yanıtıyla doğrulanır.',
                  style: TextStyle(fontSize: AppText.body, height: 1.4, color: SetupColors.muted(context)),
                ),
                if (access.isPinSession)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Geçici servis oturumunda cihazı müşteriye bağlama (claim) yapılamaz; yalnızca bu dairedeki '
                      'panoda çalışabilirsiniz.',
                      key: const Key('pin_session_note'),
                      style: TextStyle(fontSize: AppText.caption, height: 1.35, color: SetupColors.muted(context)),
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
          ),
          StaggeredEntrance(index: 1, child: WifiSetupCard(deviceApiFactory: deviceApiFactory)),
          StaggeredEntrance(
            index: 2,
            child: SetupResumeList(
              key: ValueKey<int>(reload),
              access: access,
              store: store,
              onOpen: (record) => onOpenWizard(resume: record),
            ),
          ),
          StaggeredEntrance(
            index: 3,
            child: ExistingDevicesList(
              onOpen: (target, step) => onOpenWizard(existing: target, startStep: step),
            ),
          ),
          StaggeredEntrance(index: 4, child: ServiceToolCards(scanner: scanner)),
          if (canEmergencyReset) ...[
            const SetupSectionTitle('Acil durum'),
            const SizedBox(height: 8),
            EmergencyResetCard(scanner: scanner),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const Key('btn_service_logout'),
            onPressed: () => unawaited(confirmAndLogout(context, state)),
            icon: Icon(Icons.logout_rounded, size: accentIconSize(context, base: 20)),
            label: Text(access.isPinSession ? 'Servis Oturumunu Kapat' : 'Çıkış Yap'),
            // Çerçeve + metin + simge AYNI aileden ve AA (ham kırmızı koyu temada ≈ 3.8:1'di); şekil/boyut temadan.
            style: accentOutlinedButtonStyle(context, AppFamilies.rose),
          ),
        ],
      ),
    );
  }
}
