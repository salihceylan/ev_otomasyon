import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../models/cloud_models.dart';
import '../../services/automation_state.dart';
import '../pages/system_doctor_dialog.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../theme/app_theme.dart';
import 'labels.dart';

/// Yükleme görünümü: **zaman aşımı + yeniden dene yolu vardır** (sonsuz spinner yok).
/// [timeout] dolunca "beklenenden uzun sürüyor" mesajı ve "Yeniden dene" düğmesi çıkar.
///
/// Anahtarlar: `Key('loading_view')`, `Key('btn_retry')` (yalnızca zaman aşımından sonra).
class TimedLoadingView extends StatefulWidget {
  const TimedLoadingView({
    super.key,
    required this.message,
    required this.onRetry,
    this.timeout = const Duration(seconds: 15),
  });

  final String message;
  final VoidCallback onRetry;
  final Duration timeout;

  @override
  State<TimedLoadingView> createState() => _TimedLoadingViewState();
}

class _TimedLoadingViewState extends State<TimedLoadingView> {
  Timer? _timer;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    final clock = context.read<AutomationState>().clock;
    _timer = clock.timer(widget.timeout, () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('loading_view'),
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            widget.message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: AppTheme.getTextMuted(context)),
          ),
          if (_timedOut) ...[
            const SizedBox(height: 12),
            Text(
              'Bu işlem beklenenden uzun sürüyor.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: AppTheme.warningText(context)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('btn_retry'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                setState(() => _timedOut = false);
                _arm();
                widget.onRetry();
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Yeniden dene'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hata + "Yeniden dene" kartı. Anahtarlar: `Key('error_card')`, `Key('btn_retry')`.
class ErrorRetryCard extends StatelessWidget {
  const ErrorRetryCard({
    super.key,
    required this.title,
    required this.message,
    required this.onRetry,
    this.actions = const <Widget>[],
    this.icon = Icons.cloud_off_outlined,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  /// Ek eylemler (ör. "Yerel moda geç").
  final List<Widget> actions;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.warningText(context);
    return Container(
      key: const Key('error_card'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentAmber, radius: 16),
      child: Column(
        children: [
          Icon(icon, size: 40, color: color),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.getTextPrimary(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.35, color: AppTheme.getTextMuted(context)),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('btn_retry'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yeniden dene'),
              ),
              ...actions,
            ],
          ),
        ],
      ),
    );
  }
}

/// Çevrimdışı / kısmi hata şeridi: kayıtlı (önbellekteki) evler gösteriliyorsa ya da bir yükleme
/// hatası varsa görünür; "Yeniden dene" ve (yetkiliyse) "Yerel moda geç" sunar.
///
/// Anahtarlar: `Key('banner_offline')`, `Key('btn_banner_retry')`, `Key('btn_go_local')`.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({String? message, bool canSwitch})>((s) {
      String? message;
      if (s.homesFromCache) {
        message = 'Çevrimdışısınız. Kayıtlı daireler gösteriliyor; durum güncel olmayabilir.';
      } else if (s.homesError != null) {
        message = s.homesError;
      } else if (s.endpointsError != null && s.endpointsLoaded) {
        message = 'Cihazlar güncellenemedi. Son bilinen durum gösteriliyor.';
      }
      return (message: message, canSwitch: s.capabilities.canSwitchMode);
    });
    final message = vm.message;
    if (message == null) return const SizedBox.shrink();

    final color = AppTheme.warningText(context);
    final state = context.read<AutomationState>();
    return Container(
      key: const Key('banner_offline'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentAmber, radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.wifi_off_outlined, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: TextStyle(fontSize: 12.5, color: color, height: 1.3)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                key: const Key('btn_banner_retry'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () {
                  unawaited(state.fetchHomes(autoSelect: false));
                  unawaited(state.refresh());
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yeniden dene'),
              ),
              if (vm.canSwitch)
                TextButton.icon(
                  key: const Key('btn_go_local'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => unawaited(state.setMode(AppMode.direct)),
                  icon: const Icon(Icons.lan_outlined, size: 18),
                  label: const Text('Yerel moda geç'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Cihaz çevrimdışı bildirimi: Wi-Fi kurtarma yalnızca **doğru koşulda** (cihaz çevrimdışı ve
/// `canOpenWifiRecovery`) önerilir. Anahtarlar: `Key('notice_device_offline')`,
/// `Key('btn_wifi_recovery')`, `Key('btn_system_doctor')`, `Key('btn_notice_retry')`.
class DeviceOfflineNotice extends StatelessWidget {
  const DeviceOfflineNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({bool direct, String host, Capabilities caps})>(
      (s) => (direct: s.mode == AppMode.direct, host: s.host, caps: s.capabilities),
    );
    final state = context.read<AutomationState>();
    final warn = AppTheme.warningText(context);

    return Container(
      key: const Key('notice_device_offline'),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentAmber, radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_off_outlined, color: warn),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  vm.direct ? 'Cihaza ulaşılamıyor' : 'Pano çevrimdışı',
                  style: TextStyle(fontWeight: FontWeight.bold, color: warn),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            vm.direct
                ? 'Cihaza bağlanılamıyor${vm.host.isEmpty ? '' : ' (${vm.host})'}. Yerel Wi-Fi ağına bağlı olduğunuzdan emin olun.'
                : 'Pano şu an buluta bağlı görünmüyor. Gösterilen durum son bilinen durumdur; '
                    'pano elektrik ve internet bağlantısını kontrol edin.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.getTextMuted(context), height: 1.35),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('btn_notice_retry'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => unawaited(state.refresh()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yeniden dene'),
              ),
              if (vm.caps.canChangeChildLock)
                OutlinedButton.icon(
                  key: const Key('btn_system_doctor'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => SystemDoctorDialog.show(context),
                  icon: const Icon(Icons.health_and_safety, size: 18),
                  label: const Text('Sistem Doktoru'),
                ),
              if (vm.caps.canOpenWifiRecovery)
                OutlinedButton.icon(
                  key: const Key('btn_wifi_recovery'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => WifiRecoveryDialog.show(context),
                  icon: const Icon(Icons.wifi_find, size: 18),
                  label: const Text('Wi-Fi Kurtarma Modu'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Daire listesi (seçici). Süresi dolmuş misafir daireleri pasif gösterilir.
/// Anahtarlar: `Key('card_home_<kimlik>')`.
class HomePickerList extends StatelessWidget {
  const HomePickerList({super.key, this.onSelected});

  /// Bir daire seçildikten sonra çağrılır (ör. alt sayfayı kapatmak için).
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final homes = context.select<AutomationState, List<HomeModel>>((s) => s.homes);
    final activeId = context.select<AutomationState, String?>((s) => s.activeHome?.id);
    final state = context.read<AutomationState>();
    final now = state.clock.now();

    return Column(
      children: [
        for (final home in homes)
          Builder(
            builder: (context) {
              final expired = home.isGuestExpiredAt(now);
              final active = home.id == activeId;
              final roleText = homeRoleLabel(home.homeRole);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: Key('card_home_${home.id}'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: expired || active
                        ? null
                        : () {
                            unawaited(state.selectHome(home));
                            onSelected?.call();
                          },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 56),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: AppTheme.cardDecoration(
                        context,
                        accent: active ? AppTheme.primaryBlue : null,
                        emphasized: active,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            expired ? Icons.timer_off_outlined : Icons.home_outlined,
                            color: expired ? AppTheme.dangerText(context) : AppTheme.infoText(context),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  home.name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.getTextPrimary(context),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  expired ? '$roleText • Süresi doldu' : roleText,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: expired
                                        ? AppTheme.dangerText(context)
                                        : AppTheme.getTextMuted(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (active)
                            Icon(Icons.check_circle, color: AppTheme.successText(context))
                          else if (!expired)
                            Icon(Icons.chevron_right, color: AppTheme.getTextMuted(context)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Daire seçici alt sayfası (birden çok dairesi olan kullanıcı için).
Future<void> showHomeSwitcherSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: AppTheme.getSurfaceColor(context),
    builder: (sheetContext) => Padding(
      key: const Key('sheet_home_switcher'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Daire Seç',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppTheme.getTextPrimary(sheetContext),
              ),
            ),
            const SizedBox(height: 12),
            HomePickerList(onSelected: () => Navigator.of(sheetContext).pop()),
          ],
        ),
      ),
    ),
  );
}

/// Misafir erişimi sona ermiş ekranı: kapsamlı bir "Erişim süreniz doldu" açıklaması, ev listesini
/// yenileme ve (varsa) başka daireye geçiş. Anahtarlar: `Key('view_guest_expired')`,
/// `Key('btn_refresh_homes')`.
class GuestExpiredView extends StatelessWidget {
  const GuestExpiredView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final vm = context.select<AutomationState, ({String name, DateTime? until, bool hasOther})>((s) {
      final now = s.clock.now();
      return (
        name: s.activeHome?.name ?? 'Bu daire',
        until: s.activeHome?.guestValidUntil,
        hasOther: s.homes.any((h) => h.id != s.activeHome?.id && !h.isGuestExpiredAt(now)),
      );
    });

    return Container(
      key: const Key('view_guest_expired'),
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: AppTheme.cardDecoration(context, accent: AppTheme.accentRed, radius: 20),
      child: Column(
        children: [
          Icon(Icons.timer_off_outlined, size: 56, color: AppTheme.dangerText(context)),
          const SizedBox(height: 14),
          Text(
            'Erişim süreniz doldu',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppTheme.getTextPrimary(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${vm.name} için misafir erişiminiz${vm.until == null ? '' : ' (${formatWhen(vm.until!, now: state.clock.now())})'} '
            'sona erdi. Cihazları göremez ve kontrol edemezsiniz. Yeniden erişim için ev sahibinden '
            'yeni bir davet isteyin.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, height: 1.4, color: AppTheme.getTextMuted(context)),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('btn_refresh_homes'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => unawaited(state.fetchHomes(autoSelect: false)),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Daire listesini yenile'),
              ),
              if (vm.hasOther)
                OutlinedButton.icon(
                  key: const Key('btn_switch_home'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => showHomeSwitcherSheet(context),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Başka daireye geç'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Kısa bilgi kartı (ör. dairede henüz cihaz yok).
class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.icon, required this.title, required this.message, this.cardKey});

  final IconData icon;
  final String title;
  final String message;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: cardKey,
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: AppTheme.cardDecoration(context, radius: 16),
      child: Column(
        children: [
          Icon(icon, size: 40, color: AppTheme.getTextMuted(context)),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppTheme.getTextPrimary(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.35, color: AppTheme.getTextMuted(context)),
          ),
        ],
      ),
    );
  }
}
