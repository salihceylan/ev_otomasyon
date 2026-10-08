import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../pages/device_settings_page.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/critical_alarm_card.dart';
import '../widgets/quick_scenario_bar.dart';
import 'dashboard_states.dart';
import 'endpoint_sections.dart';
import 'home_hero.dart';
import 'peace_banner.dart';
import 'status_pills.dart';
import 'welcome_cards.dart';

/// Daire panosunun hangi durumda olduğu. Yükleme / hata / boş ayrımı burada yapılır:
/// "Henüz kayıtlı daireniz yok" yalnızca **başarılı boş** ev yanıtında, karşılama/cihaz eşleme
/// kartı yalnızca **başarılı boş** uç nokta yanıtında ve yalnızca ev sahibine gösterilir.
enum ApartmentPhase {
  /// Misafir süresi doldu (tüm ev yetkileri kapalı).
  guestExpired,

  /// Ev listesi yükleniyor (henüz yanıt yok, aktif ev yok).
  loadingHomes,

  /// Ev listesi alınamadı (hata) ve gösterilecek önbellek yok.
  homesFailed,

  /// Ev listesi başarıyla alındı ve boş: dairesi olmayan kullanıcı.
  homeless,

  /// Daireler var ama aktif daire seçili değil (ör. erişim kaybı sonrası).
  pickHome,

  /// Aktif dairenin cihazları yükleniyor.
  loadingDevices,

  /// Aktif dairenin cihazları alınamadı.
  devicesFailed,

  /// Cihazlar yüklendi (bulut).
  content,

  /// Doğrudan (LAN) mod.
  direct,
}

/// Durumdan [ApartmentPhase] türetir (saf fonksiyon; birim testlidir).
ApartmentPhase apartmentPhaseOf(AutomationState s) {
  if (s.mode == AppMode.direct) return ApartmentPhase.direct;

  final home = s.activeHome;
  if (s.capabilities.isGuestExpired ||
      (home != null && home.isGuestExpiredAt(s.clock.now()))) {
    return ApartmentPhase.guestExpired;
  }
  if (home == null) {
    if (s.homes.isNotEmpty) return ApartmentPhase.pickHome;
    if (s.homesLoaded) return ApartmentPhase.homeless;
    if (s.homesError != null) return ApartmentPhase.homesFailed;
    return ApartmentPhase.loadingHomes;
  }
  if (s.endpointsLoaded) return ApartmentPhase.content;
  if (s.endpointsError != null) return ApartmentPhase.devicesFailed;
  return ApartmentPhase.loadingDevices;
}

/// Geniş ekranda pano içeriğinin en büyük genişliği (dp).
const double kDashboardMaxWidth = 1200;

/// Daire sakini / ev sahibi / misafir / servis oturumu panosu (konsol olmayan roller).
class ApartmentDashboard extends StatelessWidget {
  const ApartmentDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final phase = context.select<AutomationState, ApartmentPhase>(apartmentPhaseOf);
    final state = context.read<AutomationState>();

    return RefreshIndicator(
      onRefresh: () => state.refresh(),
      child: SingleChildScrollView(
        key: const Key('view_apartment'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          MediaQuery.sizeOf(context).width >= 900 ? 24 : 16,
          12,
          MediaQuery.sizeOf(context).width >= 900 ? 24 : 16,
          30,
        ),
        // Geniş ekran (tablet/masaüstü): içerik en çok [kDashboardMaxWidth] genişliğinde, ortalı.
        child: Align(
          key: const Key('view_apartment_content'),
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kDashboardMaxWidth),
            child: _PhaseBody(phase: phase),
          ),
        ),
      ),
    );
  }
}

class _PhaseBody extends StatelessWidget {
  const _PhaseBody({required this.phase});

  final ApartmentPhase phase;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final Widget body;
    switch (phase) {
      case ApartmentPhase.guestExpired:
        body = const GuestExpiredView();
      case ApartmentPhase.loadingHomes:
        body = TimedLoadingView(
          message: 'Daireleriniz yükleniyor…',
          onRetry: () => unawaited(state.fetchHomes()),
        );
      case ApartmentPhase.homesFailed:
        body = const _HomesFailedView();
      case ApartmentPhase.homeless:
        body = const HomelessWelcome();
      case ApartmentPhase.pickHome:
        body = const _PickHomeView();
      case ApartmentPhase.loadingDevices:
        body = Column(
          children: [
            const OfflineBanner(),
            TimedLoadingView(
              message: 'Cihazlarınız yükleniyor…',
              onRetry: () => unawaited(state.refresh()),
            ),
          ],
        );
      case ApartmentPhase.devicesFailed:
        body = const _DevicesFailedView();
      case ApartmentPhase.content:
        return const _CloudContent();
      case ApartmentPhase.direct:
        return const _DirectContent();
    }
    // Tek sütunlu durum ekranları (yükleme / hata / boş / karşılama / erişim bitti / daire seç) geniş ekranda 1200 dp'lik
    // çubuğa dönüşmez: ortalı ve [kDashboardStateMaxWidth] ile sınırlı.
    return _StateColumn(child: body);
  }
}

/// Tek sütunlu durum ekranı kabı: üstte ortalı, en çok [kDashboardStateMaxWidth] genişliğinde.
class _StateColumn extends StatelessWidget {
  const _StateColumn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kDashboardStateMaxWidth),
        child: child,
      ),
    );
  }
}

class _HomesFailedView extends StatelessWidget {
  const _HomesFailedView();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final message = context.select<AutomationState, String?>((s) => s.homesError);
    return ErrorRetryCard(
      title: 'Daireler yüklenemedi',
      message: message ?? 'Lütfen bağlantınızı kontrol edip tekrar deneyin.',
      onRetry: () => unawaited(state.fetchHomes()),
    );
  }
}

class _PickHomeView extends StatelessWidget {
  const _PickHomeView();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('view_pick_home'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const OfflineBanner(),
        Text(
          'Bir daire seçin',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppTheme.getTextPrimary(context),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Kontrol etmek istediğiniz daireyi seçin.',
          style: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(context)),
        ),
        const SizedBox(height: 14),
        const HomePickerList(),
      ],
    );
  }
}

class _DevicesFailedView extends StatelessWidget {
  const _DevicesFailedView();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final vm = context.select<AutomationState, ({String? message, bool canSwitch})>(
      (s) => (message: s.endpointsError, canSwitch: s.capabilities.canSwitchMode),
    );
    return Column(
      children: [
        const OfflineBanner(),
        ErrorRetryCard(
          title: 'Cihazlar yüklenemedi',
          message: vm.message ?? 'Lütfen tekrar deneyin.',
          onRetry: () => unawaited(state.refresh()),
          actions: [
            if (vm.canSwitch)
              OutlinedButton.icon(
                key: const Key('btn_go_local'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => unawaited(state.setMode(AppMode.direct)),
                icon: const Icon(Icons.lan_outlined, size: 18),
                label: const Text('Yerel moda geç'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Bulut modu içeriği (cihazlar yüklendi).
class _CloudContent extends StatefulWidget {
  const _CloudContent();

  @override
  State<_CloudContent> createState() => _CloudContentState();
}

class _CloudContentState extends State<_CloudContent> {
  String? _room;

  @override
  Widget build(BuildContext context) {
    final rooms = context.select<AutomationState, RoomOptions>(roomOptionsOf).items;
    final vm = context.select<AutomationState, ({bool empty, bool isOwner, bool canGroup, bool offline})>(
      (s) => (
        empty: s.cloudEndpoints.isEmpty,
        isOwner: s.capabilities.isOwner,
        canGroup: s.capabilities.canUseGroupCommands,
        offline: s.devicePresence == DevicePresence.offline,
      ),
    );

    // Seçili oda artık yoksa filtre kendiliğinden kalkar.
    final effective = rooms.any((r) => r.key == _room) ? _room : null;
    final roomText = effective == null ? null : rooms.firstWhere((r) => r.key == effective).label;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const OfflineBanner(),
        // Kritik güvenlik uyarıları (alarm / vana arızası / güvenli kip / su kesik) panonun EN ÜSTÜNDE (§5.3.3).
        const SafetyAlertsPanel(),
        if (!vm.empty) ...[
          const StaggeredEntrance(index: 0, child: HomeHero()),
          const SizedBox(height: 12),
          const StaggeredEntrance(index: 1, child: DashboardStatusBar()),
          const SizedBox(height: 16),
        ],
        // Hiç cihaz yokken durum şeridi YOK: "Tüm Işıklar Kapalı / Sistem Hazır" kurulumu tamamlamamış kullanıcıya
        // sistemin hazır olduğunu söylerdi ve ilk-çalıştırma eylemini (karekod eşleme) aşağı iterdi.
        if (vm.empty) ...[
          if (vm.isOwner)
            const WelcomeClaimCard()
          else
            const InfoCard(
              cardKey: Key('card_empty_home'),
              icon: Icons.devices_other_outlined,
              title: 'Bu dairede henüz cihaz yok',
              message: 'Kontrol edilebilir bir cihaz tanımlı değil. Ev sahibi cihazı eşledikten sonra burada görünür.',
            ),
        ] else ...[
          const PeaceBanner(),
          if (vm.canGroup) ...[
            const StaggeredEntrance(index: 2, child: QuickScenarioBar()),
            const SizedBox(height: 20),
          ],
          RoomFilterChips(
            selected: effective,
            onSelected: (key) => setState(() => _room = key),
          ),
          if (rooms.length >= 2) const SizedBox(height: 16),
          DeviceSections(roomKeyFilter: effective, roomLabelText: roomText),
        ],
        if (vm.offline) ...[
          const SizedBox(height: 20),
          const StaggeredEntrance(index: 0, offset: 8, child: DeviceOfflineNotice()),
        ],
      ],
    );
    // Cihazsız durum tek sütunlu bir durum ekranıdır: geniş ekranda ortalı ve sınırlı genişlikte.
    return vm.empty ? _StateColumn(child: column) : column;
  }
}

/// Doğrudan (LAN) mod içeriği.
class _DirectContent extends StatelessWidget {
  const _DirectContent();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final vm = context.select<AutomationState, ({bool hasStatus, ConnectionStateEnum conn, String? error, String host, bool canWifi, bool canSwitch, bool canGroup, bool blocked})>(
      (s) => (
        blocked: s.directBlockedUntil != null && s.clock.now().isBefore(s.directBlockedUntil!),
        hasStatus: s.status != null,
        conn: s.connState,
        error: s.directError,
        host: s.host,
        canWifi: s.capabilities.canOpenWifiRecovery,
        // Buluta dönüş giriş yapmış kullanıcıya HER ZAMAN açık (kullanim-1): rolü düşen / misafir kalan kullanıcı doğrudan
        // kipte mahsur kalmasın (`setMode(cloud)` yetki kapısızdır).
        canSwitch: s.capabilities.canSwitchMode || s.isAuthenticated,
        canGroup: s.capabilities.canUseGroupCommands,
      ),
    );
    Widget goCloud() => OutlinedButton.icon(
          key: const Key('btn_go_cloud'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => unawaited(state.setMode(AppMode.cloud)),
          icon: const Icon(Icons.cloud_outlined, size: 18),
          label: const Text('Bulut moduna geç'),
        );

    final Widget body;
    if (vm.hasStatus) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PeaceBanner(),
          if (vm.canGroup) ...[
            const QuickScenarioBar(),
            const SizedBox(height: 20),
          ],
          const DeviceSections(),
          if (vm.conn == ConnectionStateEnum.offline) ...[
            const SizedBox(height: 20),
            const StaggeredEntrance(index: 0, offset: 8, child: DeviceOfflineNotice()),
          ],
        ],
      );
    } else if (vm.conn == ConnectionStateEnum.connecting) {
      body = TimedLoadingView(
        message: 'Cihaza bağlanılıyor…',
        onRetry: () => unawaited(state.refresh()),
      );
    } else if (vm.conn == ConnectionStateEnum.connected) {
      // Cihaza ulaşıldı ama kontrol edilemiyor (anahtar gerekli / cihaz kurulmamış / geçici kilit). Uyarı = amber.
      // Anahtar eksik/geçersizken yeniden denemek işe yaramaz: birincil eylem "Ayarları aç", "Yeniden dene" ikincil.
      // Geçici kilitte ise yeniden deneme anlamlıdır (süre dolunca): birincil kalır.
      void openSettings() {
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage()),
          ),
        );
      }

      body = ErrorRetryCard(
        title: 'Cihaz kontrol edilemiyor',
        message: vm.blocked
            ? (vm.error ?? 'Çok fazla hatalı deneme yapıldı. Cihaz kısa süre sonra yeniden denenecek.')
            : (vm.error ?? 'Cihaz anahtarı gerekli. Ayarlardan cihaz anahtarını girin.'),
        icon: vm.blocked ? Icons.lock_clock_outlined : Icons.vpn_key_outlined,
        family: AppFamilies.amber,
        primaryRetry: vm.blocked,
        onRetry: () => unawaited(state.refresh()),
        actions: [
          if (vm.blocked)
            OutlinedButton.icon(
              key: const Key('btn_open_settings'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: openSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Ayarları aç'),
            )
          else
            FilledButton.icon(
              key: const Key('btn_open_settings'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: openSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Ayarları aç'),
            ),
          if (vm.canSwitch) goCloud(),
        ],
      );
    } else {
      body = ErrorRetryCard(
        title: 'Cihaza ulaşılamıyor',
        family: AppFamilies.amber,
        message: vm.host.isEmpty
            ? 'Cihaz adresi ayarlanmadı. Ayarlardan cihazın yerel IP adresini girin.'
            : 'Cihaza bağlanılamıyor (${vm.host}). Yerel Wi-Fi ağına bağlı olduğunuzdan emin olun.',
        onRetry: () => unawaited(state.refresh()),
        actions: [
          OutlinedButton.icon(
            key: const Key('btn_open_settings'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage()),
            ),
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('Adresi düzenle'),
          ),
          if (vm.canWifi)
            OutlinedButton.icon(
              key: const Key('btn_wifi_recovery'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => WifiRecoveryDialog.show(context),
              icon: const Icon(Icons.wifi_find, size: 18),
              label: const Text('Wi-Fi Kurtarma Modu'),
            ),
          if (vm.canSwitch) goCloud(),
        ],
      );
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (vm.hasStatus) ...[
          // Aynı kritik alarm kartı LAN kipinde de (K5: internetsiz alarm görünür).
          const SafetyAlertsPanel(),
          const StaggeredEntrance(index: 0, child: HomeHero()),
          const SizedBox(height: 12),
        ],
        // Durum verisi yokken (erişilemiyor / anahtar gerekli / kilitli) şeritte yalnız sistem durumu hapı kalır
        // (ışık/panjur sayaçları [DashboardStatusBar] içinde gizlenir).
        const StaggeredEntrance(index: 1, child: DashboardStatusBar()),
        const SizedBox(height: 16),
        body,
      ],
    );
    // Durum verisi olmayan kipler (hata / yükleme) tek sütunlu durum ekranıdır: geniş ekranda ortalı ve sınırlı.
    return vm.hasStatus ? column : _StateColumn(child: column);
  }
}
