import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../models/cloud_models.dart';
import '../../services/automation_state.dart';
import '../common/app_dialogs.dart';
import '../common/qr_flow.dart';
import '../pages/claim/claim_manual_dialog.dart';
import '../pages/system_doctor_dialog.dart';
import '../pages/wifi_recovery_dialog.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/orb.dart';
import '../widgets/surface_card.dart';
import 'labels.dart';
import 'status_pills.dart';

/// Tek sütunlu pano durum ekranlarının (yükleme / hata / boş / karşılama / erişim bitti) geniş ekranda en büyük
/// genişliği (dp). İçerik ızgarası [kDashboardMaxWidth] kadar geniş olabilir; ama tek kartlık durumlar 1200 dp'lik
/// çubuğa dönüşmez, ortalanır.
const double kDashboardStateMaxWidth = 600;

/// Durum kartlarındaki birincil eylem (CTA) düğmelerinin en büyük genişliği (dp): geniş ekranda düğme çubuk olmaz.
const double kDashboardCtaMaxWidth = 420;

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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Spinner yok: iskelet kartlar (paylaşılan süpürme; 12 sn sonra durur) + durum metni.
          const DashboardSkeleton(),
          const SizedBox(height: 20),
          Semantics(
            liveRegion: true,
            child: Text(
              widget.message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.getTextMuted(context),
              ),
            ),
          ),
          if (_timedOut) ...[
            const SizedBox(height: 12),
            Text(
              'Bu işlem beklenenden uzun sürüyor.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.warningText(context),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: OutlinedButton.icon(
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
            ),
          ],
        ],
      ),
    );
  }
}

/// Pano yükleme iskeleti: durum hapları + 3 kart (gerçek yerleşimle aynı ritim; `ExcludeSemantics`).
///
/// Hap iskeletleri gerçek hapların boyundadır (sabit genişlik; geniş ekranda gerilmez, içerik gelince yerleşim
/// sıçramaz) ve opak cam tabanlıdır (arkadaki devre izi iskeletin içinden görünmez).
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SkeletonPill(width: 132),
              _SkeletonPill(width: 148),
              _SkeletonPill(width: 112),
            ],
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            StaggeredEntrance(
              index: i,
              child: const SkeletonCard(lines: 3, leadingSize: 56),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hap biçimli iskelet: opak cam taban (kart gradyanı + rim) üstünde süpürme. Yükseklik gerçek hapla ([StatusPill.kHeight]
/// ya da büyük yazıda simge diski + dolgu) AYNI hesaplanır: yazı ölçeği büyüdükçe içerik gelince yerleşim ziplamaz.
class _SkeletonPill extends StatelessWidget {
  const _SkeletonPill({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);
    final scale = (MediaQuery.textScalerOf(context).scale(10) / 10).clamp(1.0, 1.3);
    final height = math.max(StatusPill.kHeight, 26 * scale + 8);
    return Container(
      width: width,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.cardTop, tokens.cardBottom],
        ),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: tokens.rimSolid),
      ),
      child: Skeleton(height: height - 2, radius: (height - 2) / 2),
    );
  }
}

/// Orb içinde daha dolgun görünen karşılığı (yoksa aynı simge).
IconData _solid(IconData icon) {
  if (icon == Icons.cloud_off_outlined) return Icons.cloud_off_rounded;
  if (icon == Icons.vpn_key_outlined) return Icons.vpn_key_rounded;
  // 'Cihaz geçici kilitli' kartı: ince çizgili kilit-saat yerine dolu karşılığı (diğer durum orb'larıyla aynı ağırlık).
  if (icon == Icons.lock_clock_outlined) return Icons.lock_clock;
  return icon;
}

/// Durum kartı eylem satırı: dar genişlikte (< [stackBelow] dp) düğmeler alt alta TAM genişlikte (hizalı,
/// 48 dp+), geniş genişlikte ortalanmış [Wrap]. [maxWidth] verilirse grup o genişliği aşmaz ve ortalanır
/// (geniş ekranda CTA çubuğa dönüşmez).
class StateActions extends StatelessWidget {
  const StateActions({super.key, required this.children, this.stackBelow = 400, this.maxWidth});

  final List<Widget> children;

  /// Bu genişliğin altında düğmeler alt alta dizilir (`double.infinity` = her zaman alt alta).
  final double stackBelow;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < stackBelow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpace.s8),
                    children[i],
                  ],
                ],
              );
            }
            return Wrap(
              spacing: AppSpace.s8,
              runSpacing: AppSpace.s8,
              alignment: WrapAlignment.center,
              children: children,
            );
          },
        ),
      ),
    );
  }
}

/// Pano durum kartlarının (hata / dairesiz karşılama / cihaz eşleme / erişim bitti / bilgi) ORTAK iskeleti:
/// orb + başlık (20/700) + iletinin (14) + eylemlerin aynı ritmi (boşluk 16/8/24; dolgu 24). Genişlikte
/// ayrıca [kDashboardStateMaxWidth] ile sınırlamak çağıranın işidir (pano gövdesi yapar).
///
/// [extra], başlıkla ileti arasına konan ek öğedir (ör. "daireniz yok" bilgi hapı).
class StateCard extends StatelessWidget {
  const StateCard({
    super.key,
    required this.orb,
    required this.title,
    this.message,
    this.extra,
    this.actions = const <Widget>[],
    this.actionsStackBelow = 400,
    this.actionsMaxWidth,
    this.accent,
    this.active = false,
    this.padding = const EdgeInsets.all(AppSpace.s24),
  });

  final Widget orb;
  final String title;
  final String? message;
  final Widget? extra;
  final List<Widget> actions;

  /// Eylem satırı alt alta dizilme eşiği ve en büyük genişliği ([StateActions]).
  final double actionsStackBelow;
  final double? actionsMaxWidth;
  final Color? accent;
  final bool active;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SurfaceCard(
        accent: accent,
        active: active,
        padding: padding,
        child: Column(
          children: [
            orb,
            const SizedBox(height: AppSpace.s16),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppTheme.getTextPrimary(context),
              ),
            ),
            if (extra != null) ...[const SizedBox(height: AppSpace.s8), extra!],
            if (message != null) ...[
              const SizedBox(height: AppSpace.s8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppText.body,
                  height: 1.4,
                  color: AppTheme.getTextMuted(context),
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AppSpace.s24),
              StateActions(stackBelow: actionsStackBelow, maxWidth: actionsMaxWidth, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

/// Hata + "Yeniden dene" kartı. Anahtarlar: `Key('error_card')`, `Key('btn_retry')`.
///
/// Renk dili: kalıcı hata (yükleme başarısız) = [AppFamilies.rose] (varsayılan); geçici/uyarı durumları (çevrimdışı,
/// kilitli, anahtar gerekli) çağıran [family] olarak [AppFamilies.amber] verir.
///
/// Eylem hiyerarşisi: varsayılan olarak "Yeniden dene" birincil (dolgu) ve [actions] ikincildir. Yeniden denemenin
/// işe yaramayacağı durumlarda (ör. geçersiz cihaz anahtarı) [primaryRetry] `false` verilir: "Yeniden dene" çerçeveli
/// ikincil olur ve [actions] ÖNE gelir (çağıran ilk eylemi birincil `FilledButton` yapar).
class ErrorRetryCard extends StatelessWidget {
  const ErrorRetryCard({
    super.key,
    required this.title,
    required this.message,
    required this.onRetry,
    this.actions = const <Widget>[],
    this.icon = Icons.cloud_off_outlined,
    this.family = AppFamilies.rose,
    this.primaryRetry = true,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  /// Ek eylemler (ör. "Yerel moda geç").
  final List<Widget> actions;
  final IconData icon;
  final AccentFamily family;
  final bool primaryRetry;

  @override
  Widget build(BuildContext context) {
    final Widget retry = primaryRetry
        ? FilledButton.icon(
            key: const Key('btn_retry'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Yeniden dene'),
          )
        : OutlinedButton.icon(
            key: const Key('btn_retry'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Yeniden dene'),
          );
    return StateCard(
      key: const Key('error_card'),
      accent: family.base,
      orb: OrbIconBadge(
        icon: _solid(icon),
        family: family,
        size: OrbSize.lg,
        active: true,
      ),
      title: title,
      message: message,
      actions: primaryRetry ? [retry, ...actions] : [...actions, retry],
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
    final vm = context
        .select<AutomationState, ({String? message, bool canSwitch})>((s) {
          String? message;
          if (s.homesFromCache) {
            message = 'Çevrimdışısınız. Kayıtlı daireler gösteriliyor; durum güncel olmayabilir.';
          } else if (s.homesError != null) {
            message = s.homesError;
          } else if (s.endpointsError != null && s.endpointsLoaded) {
            message =
                'Cihazlar güncellenemedi. Son bilinen durum gösteriliyor.';
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
      decoration: AppTheme.cardDecoration(
        context,
        accent: AppFamilies.amber.base,
        radius: AppRadius.r16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.wifi_off_outlined, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(fontSize: 13, color: color, height: 1.3),
                ),
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
    final vm = context
        .select<
          AutomationState,
          ({bool direct, String host, Capabilities caps, String? neverSeenUid})
        >(
          (s) => (
            direct: s.mode == AppMode.direct,
            host: s.host,
            caps: s.capabilities,
            neverSeenUid: _neverSeenUid(s),
          ),
        );
    final state = context.read<AutomationState>();
    final warn = AppTheme.warningText(context);
    // Panoların hiçbiri buluta hiç bağlanmadı (bireysel-12): "çevrimdışı / son bilinen durum" değil, kurulum eksik.
    final neverSeen = !vm.direct && vm.neverSeenUid != null;

    return Container(
      key: const Key('notice_device_offline'),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration(
        context,
        accent: AppFamilies.amber.base,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_off_outlined, color: warn),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  vm.direct ? 'Cihaza ulaşılamıyor' : (neverSeen ? 'Pano henüz bağlanmadı' : 'Pano çevrimdışı'),
                  style: TextStyle(fontWeight: FontWeight.bold, color: warn),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            vm.direct
                ? 'Cihaza bağlanılamıyor${vm.host.isEmpty ? '' : ' (${vm.host})'}. Yerel Wi-Fi ağına bağlı olduğunuzdan emin olun.'
                : (neverSeen
                      ? 'Pano buluta henüz hiç bağlanmadı. Panonun elektriği açık ve ev ağına (Ethernet ya da Wi-Fi) bağlı '
                            'olmalı; Wi-Fi ile bağlanacaksa ev ağını "Pano Wi-Fi Kurulumu" ile yükleyin. Pano internete '
                            'çıktıktan sonra bağlantı birkaç dakika sürebilir.'
                      : 'Pano şu an buluta bağlı görünmüyor. Gösterilen durum son bilinen durumdur; '
                            'pano elektrik ve internet bağlantısını kontrol edin.'),
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.getTextMuted(context),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('btn_notice_retry'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                onPressed: () => unawaited(state.refresh()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yeniden dene'),
              ),
              if (vm.caps.canChangeChildLock)
                OutlinedButton.icon(
                  key: const Key('btn_system_doctor'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => SystemDoctorDialog.show(context),
                  icon: const Icon(Icons.health_and_safety, size: 18),
                  label: const Text('Sistem Doktoru'),
                ),
              if (vm.caps.canOpenWifiRecovery)
                OutlinedButton.icon(
                  key: const Key('btn_wifi_recovery'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => WifiRecoveryDialog.show(context, deviceUuid: neverSeen ? vm.neverSeenUid : null),
                  icon: const Icon(Icons.wifi_find, size: 18),
                  label: Text(neverSeen ? 'Pano Wi-Fi Kurulumu' : 'Wi-Fi Kurtarma Modu'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Evin pano listesi boş değilse ve hiçbiri buluta hiç bağlanmadıysa (son görülme yok, çevrimiçi değil) ilk panonun
  /// kimliği; aksi halde `null`.
  static String? _neverSeenUid(AutomationState s) {
    final devices = s.devices;
    if (devices.isEmpty) return null;
    for (final d in devices) {
      if (d.lastSeenAt != null || d.online) return null;
    }
    return devices.first.deviceUuid;
  }
}

/// Daire seçici satırındaki mini orb'un görsel çapı (dp): 44 dp'lik orb ölçeklenir (başlık orb'ları, profil satırlarıyla aynı kalıp).
const double _kPickerOrb = 36;

/// Daire listesi (seçici). Süresi dolmuş misafir daireleri pasif gösterilir.
/// Anahtarlar: `Key('card_home_<kimlik>')`.
class HomePickerList extends StatelessWidget {
  const HomePickerList({super.key, this.onSelected});

  /// Bir daire seçildikten sonra çağrılır (ör. alt sayfayı kapatmak için).
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final homes = context.select<AutomationState, List<HomeModel>>(
      (s) => s.homes,
    );
    final activeId = context.select<AutomationState, String?>(
      (s) => s.activeHome?.id,
    );
    final state = context.read<AutomationState>();
    final now = state.serverNow; // misafir penceresi sunucu saatine göre (cekirdek-1)

    return Column(
      children: [
        for (final home in homes)
          Builder(
            builder: (context) {
              final expired = home.isGuestExpiredAt(now);
              final active = home.id == activeId;
              final roleText = homeRoleLabel(home.homeRole);
              final selectable = !(expired || active);
              // Kart yüzeyi SurfaceCard: basma geri bildirimi (Pressable ölçeği) kartın üstünde görünür; eskiden
              // InkWell mürekkebi opak kartın ARKASINDA kalıp hiç görünmüyordu. Köşe yarıçapı kartla aynı (20).
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Semantics(
                  container: true,
                  excludeSemantics: true,
                  button: true,
                  enabled: selectable,
                  selected: active,
                  label: [
                    home.name,
                    expired ? '$roleText, süresi doldu' : roleText,
                    if (active) 'seçili',
                  ].join(', '),
                  onTap: selectable
                      ? () {
                          unawaited(state.selectHome(home));
                          onSelected?.call();
                        }
                      : null,
                  child: SurfaceCard(
                    key: Key('card_home_${home.id}'),
                    accent: active ? AppFamilies.sky.base : null,
                    active: active,
                    onTap: selectable
                        ? () {
                            unawaited(state.selectHome(home));
                            onSelected?.call();
                          }
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 36),
                      child: Row(
                        children: [
                          // Panonun geri kalanıyla AYNI dil: parlak mini orb (eskiden çıplak Material simgesi). Süresi dolmuş
                          // daire amber (erişim/kilit; üst çubuk rozeti ve durum kartıyla aynı aile), diğerleri sky (ev).
                          SizedBox.square(
                            dimension: _kPickerOrb,
                            child: FittedBox(
                              child: OrbIconBadge(
                                icon: expired ? Icons.timer_off_rounded : Icons.home_rounded,
                                family: expired ? AppFamilies.amber : AppFamilies.sky,
                                size: OrbSize.sm,
                                active: active,
                                glow: false,
                              ),
                            ),
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
                                  expired
                                      ? '$roleText • Süresi doldu'
                                      : roleText,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: expired
                                        ? AppTheme.warningText(context)
                                        : AppTheme.getTextMuted(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (active)
                            Icon(
                              Icons.check_circle,
                              color: AppTheme.successText(context),
                            )
                          else if (!expired)
                            Icon(
                              Icons.chevron_right,
                              color: AppTheme.getTextMuted(context),
                            ),
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
  return showAppSheet<void>(
    context,
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
/// yenileme, (varsa) başka daireye geçiş ve (bireysel-2) kendi panosunu eşleme: sahiplenme ev kapsamlı değildir,
/// süresi dolan misafir de kendi panosunu karekodla / elle eşleyebilir. Anahtarlar: `Key('view_guest_expired')`,
/// `Key('btn_refresh_homes')`, `Key('btn_guest_scan_qr')`, `Key('btn_guest_claim_manual')`.
class GuestExpiredView extends StatelessWidget {
  const GuestExpiredView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final vm = context
        .select<
          AutomationState,
          ({String name, DateTime? until, bool hasOther, bool canClaim})
        >((s) {
          final now = s.serverNow;
          return (
            name: s.activeHome?.name ?? 'Bu daire',
            until: s.activeHome?.guestValidUntil,
            hasOther: s.homes.any(
              (h) => h.id != s.activeHome?.id && !h.isGuestExpiredAt(now),
            ),
            canClaim: s.capabilities.canClaimDevice,
          );
        });

    // Erişim süresi dolmuş misafir: AMBER (erişim/kilit). Üst çubuk rozeti ('Erişim süresi doldu', ConnectionLevel.locked) ve
    // daire seçicideki 'Süresi doldu' satırı da amber: aynı durum eskiden iki renkle anlatılıyordu (rozet amber, kart rose;
    // rose yalnız tehlike/hata içindir). Orb boyutu hata/kilit kartlarıyla aynı (lg; xl yalnız karşılama hero'larında).
    return StateCard(
      key: const Key('view_guest_expired'),
      accent: AppFamilies.amber.base,
      orb: const OrbIconBadge(
        icon: Icons.timer_off_rounded,
        family: AppFamilies.amber,
        size: OrbSize.lg,
        active: true,
      ),
      title: 'Erişim süreniz doldu',
      message: '${vm.name} için misafir erişiminiz${vm.until == null ? '' : ' (${formatWhen(vm.until!, now: state.clock.now())})'} '
          'sona erdi. Cihazları göremez ve kontrol edemezsiniz. Yeniden erişim için ev sahibinden '
          'yeni bir davet isteyin.',
      actions: [
        FilledButton.icon(
          key: const Key('btn_refresh_homes'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
          ),
          onPressed: () => unawaited(state.fetchHomes(autoSelect: false)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Daire listesini yenile'),
        ),
        if (vm.hasOther)
          OutlinedButton.icon(
            key: const Key('btn_switch_home'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => showHomeSwitcherSheet(context),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Başka daireye geç'),
          ),
        if (vm.canClaim) ...[
          OutlinedButton.icon(
            key: const Key('btn_guest_scan_qr'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => scanAndRouteQr(context),
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Karekod ile Cihaz Eşle'),
          ),
          TextButton.icon(
            key: const Key('btn_guest_claim_manual'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => ClaimManualDialog.show(context),
            icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
            label: const Text('Cihaz Kodunu Elle Gir'),
          ),
        ],
      ],
    );
  }
}

/// Kısa bilgi kartı (ör. dairede henüz cihaz yok). Diğer durum kartlarıyla AYNI iskelet ([StateCard]).
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.cardKey,
  });

  final IconData icon;
  final String title;
  final String message;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    return StateCard(
      key: cardKey,
      orb: OrbIconBadge(
        icon: icon,
        family: AppFamilies.slate,
        size: OrbSize.lg,
      ),
      title: title,
      message: message,
    );
  }
}
