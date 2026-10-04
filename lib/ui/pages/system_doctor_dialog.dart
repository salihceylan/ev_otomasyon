import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../models/json_utils.dart';
import '../common/app_dialogs.dart';
import '../motion/skeleton.dart';
import '../theme/tokens.dart';
import '../widgets/orb/glass_icon_button.dart';
import '../widgets/orb/orb_core.dart';
import '../widgets/orb/orb_icon_badge.dart';
import '../widgets/settings/accent_button.dart';
import 'service_setup/panel/service_glass.dart';
import 'service_setup/panel/doctor_report.dart';
import 'service_setup/setup_style.dart';
import 'service_setup/setup_widgets.dart';
import 'wifi_recovery_dialog.dart';
import '../theme/feature_accent.dart';

/// Sistem doktoru: bulut / ev ağı / pano gücü için 3 katmanlı tanı.
///
/// * Sunucunun göndermediği alan **"Veri yok"** olarak gösterilir; "çalışıyor" ya da "20 ms" gibi bir
///   değer uydurulmaz.
/// * Hata türü ayırt edilir: zaman aşımı / ağ yok / oturum süresi (401) / yetki / sunucu hatası.
/// * Ev ağı kapalı, bilinmiyor ya da hatalıysa **Wi-Fi kurtarma** düğmesi çıkar.
/// * Süper yönetici bir daire seçmediyse neden çalışmadığı açıkça yazılır.
class SystemDoctorDialog extends StatefulWidget {
  const SystemDoctorDialog({super.key, this.initialData});

  /// Dışarıdan hazır tanı yanıtı (verilirse ilk açılışta istek atılmaz).
  final Map<String, dynamic>? initialData;

  static Future<void> show(BuildContext context, {Map<String, dynamic>? initialData}) {
    final state = context.read<AutomationState>();
    return showAppDialog<void>(
      context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: SystemDoctorDialog(initialData: initialData),
      ),
    );
  }

  @override
  State<SystemDoctorDialog> createState() => _SystemDoctorDialogState();
}

/// Tanı isteğinin hata türü.
enum DoctorFailure { timeout, offline, unauthorized, forbidden, notFound, server, unknown }

class _Failure {
  const _Failure(this.kind, this.title, this.hint);

  final DoctorFailure kind;
  final String title;
  final String hint;
}

class _SystemDoctorDialogState extends State<SystemDoctorDialog> {
  static const Duration _requestTimeout = Duration(seconds: 30);

  bool _loading = false;
  _Failure? _failure;
  DoctorReport? _report;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialData;
    if (initial != null) {
      _report = DoctorReport.parse(initial);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_run());
      });
    }
  }

  _Failure _classify(Object error) {
    if (error is TimeoutException) {
      return const _Failure(
        DoctorFailure.timeout,
        'Sunucu zamanında yanıt vermedi',
        'İşlem zaman aşımına uğradı. İnternet bağlantınızı kontrol edip testi yeniden çalıştırın.',
      );
    }
    if (error is ApiException) {
      if (error.isNetwork) {
        if (error.cause is TimeoutException) {
          return const _Failure(
            DoctorFailure.timeout,
            'Sunucu zamanında yanıt vermedi',
            'Bağlantı yavaş ya da sunucu meşgul. Biraz bekleyip testi yeniden çalıştırın.',
          );
        }
        return const _Failure(
          DoctorFailure.offline,
          'İnternet bağlantısı yok',
          'Telefonunuz sunucuya ulaşamıyor. Wi-Fi veya mobil veriyi kontrol edin.',
        );
      }
      if (error.isUnauthorized) {
        return const _Failure(
          DoctorFailure.unauthorized,
          'Oturumunuz sona erdi',
          'Güvenliğiniz için oturum kapandı. Yeniden giriş yapıp testi tekrar çalıştırın.',
        );
      }
      if (error.isForbidden) {
        return const _Failure(
          DoctorFailure.forbidden,
          'Bu daire için yetkiniz yok',
          'Sistem doktorunu yalnızca yetkili olduğunuz dairede çalıştırabilirsiniz.',
        );
      }
      if (error.isNotFound) {
        return const _Failure(
          DoctorFailure.notFound,
          'Daire bulunamadı',
          'Daire silinmiş ya da erişiminiz kaldırılmış olabilir. Ev listesini yenileyin.',
        );
      }
      if (error.isServerError) {
        return const _Failure(
          DoctorFailure.server,
          'Sunucu şu anda yanıt veremiyor',
          'Sorun sunucuda; birkaç dakika sonra tekrar deneyin. Sürerse yöneticiye bildirin.',
        );
      }
      return _Failure(DoctorFailure.unknown, 'Tanı çalıştırılamadı', error.message);
    }
    return const _Failure(
      DoctorFailure.unknown,
      'Tanı çalıştırılamadı',
      'Beklenmeyen bir sorun oluştu. Testi yeniden çalıştırın.',
    );
  }

  Future<void> _run() async {
    final state = context.read<AutomationState>();
    if (state.activeHome == null) {
      setState(() {
        _loading = false;
        _failure = null;
        _report = null;
      });
      return;
    }
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final data = await state.fetchSystemDiagnostic().timeout(_requestTimeout);
      if (!mounted || seq != _seq) return;
      setState(() {
        _report = DoctorReport.parse(asMap(data) ?? const <String, dynamic>{});
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _failure = _classify(e);
        _loading = false;
      });
    }
  }

  /// Kurtarma sihirbazı bir kez açıldı (PF-47): aynı karede gelen ikinci etkinleştirme (erişilebilirlik eylemi,
  /// klavye Enter tekrarı) `pop()` ile az önce açılan kurtarma penceresini kapatıp yenisini açardı.
  bool _recoveryOpened = false;

  void _openRecovery() {
    if (_recoveryOpened) return;
    _recoveryOpened = true;
    final navigator = Navigator.of(context);
    navigator.pop();
    unawaited(WifiRecoveryDialog.show(navigator.context));
  }

  @override
  void dispose() {
    _seq++; // uçuştaki yanıt artık yok sayılır
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Tüm durumu izlemek yerine yalnızca gösterilen değerler seçilir (PF-06): tanı açıkken gelen ilgisiz bildirimler
    // (canlı durum, çevrimiçi/çevrimdışı geçişleri) pencereyi yeniden kurmaz.
    final view = context.select<AutomationState, ({bool hasHome, String homeName, bool isSuper, bool canRecover})>((s) {
      final caps = s.capabilities;
      return (
        hasHome: s.activeHome != null,
        homeName: s.activeHome?.name ?? '',
        isSuper: caps.isSuperUser,
        canRecover: caps.canOpenWifiRecovery,
      );
    });
    final noHome = !view.hasHome && _report == null;
    // Başlık orb'u rapor SEVİYESİNE bağlıdır (eskiden her durumda yeşil kalkan: uyarı/sorun teşhisinde "sağlıklı" sinyali
    // veriyordu): ok zümrüt, uyarı amber, sorun gül; yükleniyor/bilinmiyor doktor ailesi.
    final level = _loading ? null : _report?.level;
    final AccentFamily headFamily;
    final IconData headIcon;
    switch (level) {
      case 'ok':
        headFamily = AppFamilies.emerald;
        headIcon = Icons.health_and_safety_rounded;
      case 'warning':
        headFamily = AppFamilies.amber;
        headIcon = Icons.warning_amber_rounded;
      case 'error':
        headFamily = AppFamilies.rose;
        headIcon = Icons.error_outline_rounded;
      default:
        headFamily = AppFeature.doctor.accentFamily;
        headIcon = Icons.health_and_safety_rounded;
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      // Kenarı yalnız içteki [ServiceCard] çizer: `dialogTheme` şekli cyan kenarlıklı idi ve kartın kenarıyla köşelerde çift
      // kontur oluşturuyordu. Yarıçap [AppRadius.dialog] (24; şartname "diyalog 24": tema dialogTheme, AuthDialogShell ve
      // ConfirmDestructiveDialog ile AYNI — eskiden 28 dp [AppRadius.sheet]'ti).
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.dialog))),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ServiceCard(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          radius: AppRadius.dialog,
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  OrbIconBadge(
                    icon: headIcon,
                    family: headFamily,
                    pending: _loading,
                    status: !_loading && _report?.level == 'ok' ? OrbStatus.success : OrbStatus.none,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sistem Doktoru',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                        ),
                        Text(
                          view.hasHome ? 'Daire: ${view.homeName}' : 'Daire seçili değil',
                          key: const Key('doctor_home_name'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: AppText.badge, color: SetupColors.muted(context)),
                        ),
                      ],
                    ),
                  ),
                  GlassIconButton(
                    key: const Key('btn_doctor_close'),
                    icon: Icons.close_rounded,
                    semanticLabel: 'Kapat',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Divider(color: SetupColors.border(context), height: 24),
              if (noHome)
                _NoHome(isSuper: view.isSuper)
              else if (_loading)
                const _Loading()
              else if (_failure != null)
                _FailureView(failure: _failure!, onRetry: _run)
              else if (_report != null)
                _ReportView(
                  report: _report!,
                  canRecover: view.canRecover,
                  onRecovery: _openRecovery,
                  onRerun: _run,
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _NoHome extends StatelessWidget {
  const _NoHome({required this.isSuper});

  final bool isSuper;

  @override
  Widget build(BuildContext context) {
    return ServiceCard(
      key: const Key('doctor_no_home'),
      accent: SetupColors.warn,
      margin: EdgeInsets.zero,
      child: SetupInfoRow(
        icon: Icons.home_outlined,
        color: SetupColors.warn,
        bold: true,
        text: isSuper
            ? 'Süper yönetici hesabı belirli bir daireye bağlı değildir; sistem doktoru bir daire için çalışır. '
                'Önce Aboneler listesinden ya da ev listesinden bir daire seçin, sonra yeniden açın.'
            : 'Sistem doktoru bir daire için çalışır. Önce bir daire seçin, sonra yeniden açın.',
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        key: const Key('doctor_loading'),
        children: [
          for (var i = 0; i < 3; i++)
            const Padding(padding: EdgeInsets.only(bottom: 10), child: SkeletonCard(lines: 1)),
          const SizedBox(height: 6),
          Text(
            'Sistem katmanları denetleniyor...\n(bulut, ev ağı, pano gücü)',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
        ],
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.failure, required this.onRetry});

  final _Failure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final retryable = failure.kind != DoctorFailure.unauthorized && failure.kind != DoctorFailure.forbidden;
    return Column(
      key: Key('doctor_error_${failure.kind.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServiceCard(
          key: const Key('doctor_error'),
          accent: SetupColors.error,
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ServiceCardHeader(icon: Icons.error_outline_rounded, family: AppFamilies.rose, title: failure.title),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  failure.hint,
                  style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
        ),
        if (retryable) ...[
          const SizedBox(height: 14),
          SetupPrimaryButton(
            key: const Key('btn_doctor_retry'),
            label: 'Tekrar Dene',
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
          ),
        ],
      ],
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({
    required this.report,
    required this.canRecover,
    required this.onRecovery,
    required this.onRerun,
  });

  final DoctorReport report;
  final bool canRecover;
  final VoidCallback onRecovery;
  final VoidCallback onRerun;

  static const String _noData = 'Veri yok';

  String _cloudSubtitle() {
    final parts = <String>[];
    switch (report.cloudLevel) {
      case DoctorLevel.ok:
        parts.add('Çalışıyor');
      case DoctorLevel.warning:
        parts.add('Kısmen çalışıyor');
      case DoctorLevel.error:
        parts.add('Kesinti var');
      case DoctorLevel.unknown:
      case DoctorLevel.notApplicable:
        return _noData;
    }
    parts.add(report.latencyMs == null ? 'Gecikme: $_noData' : 'Gecikme: ${report.latencyMs} ms');
    final db = report.dbConnected;
    if (db != null) parts.add(db ? 'Veritabanı bağlı' : 'Veritabanı bağlı değil');
    final bridge = report.bridgeConnected;
    if (bridge != null) parts.add(bridge ? 'Mesaj köprüsü bağlı' : 'Mesaj köprüsü bağlı değil');
    return parts.join(' • ');
  }

  String _networkSubtitle() {
    switch (report.networkLevel) {
      case DoctorLevel.unknown:
        return _noData;
      case DoctorLevel.notApplicable:
        return 'Daireye henüz pano bağlanmamış';
      case DoctorLevel.ok:
      case DoctorLevel.warning:
      case DoctorLevel.error:
        final label = report.networkLevel == DoctorLevel.ok
            ? 'Çevrimiçi'
            : (report.networkLevel == DoctorLevel.warning ? 'Sinyal gecikmeli' : 'İnternet / modem bağlantısı yok');
        final ip = report.deviceIp;
        final seen = DoctorReport.seenText(report.secondsSinceSeen);
        return <String>[label, ?ip, 'Son görülme: ${seen ?? _noData}'].join(' • ');
    }
  }

  String _powerSubtitle() {
    switch (report.powerLevel) {
      case DoctorLevel.unknown:
        return _noData;
      case DoctorLevel.notApplicable:
        return 'Daireye henüz pano bağlanmamış';
      case DoctorLevel.ok:
        return 'Besleme normal';
      case DoctorLevel.warning:
      case DoctorLevel.error:
        return 'Pano gücü veya sigorta kesik olabilir';
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = report;
    final text = SetupColors.text(context);
    final muted = SetupColors.muted(context);
    final Color summaryColor;
    final IconData summaryIcon;
    switch (r.level) {
      case 'ok':
        summaryColor = SetupColors.ok;
        summaryIcon = Icons.check_rounded;
      case 'warning':
        summaryColor = SetupColors.warn;
        summaryIcon = Icons.warning_amber_rounded;
      case 'error':
        summaryColor = SetupColors.error;
        summaryIcon = Icons.priority_high_rounded;
      default:
        summaryColor = SetupColors.info;
        summaryIcon = Icons.question_mark_rounded;
    }
    return Column(
      key: const Key('doctor_report'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TierRow(
          cardKey: 'doctor_tier_cloud',
          icon: Icons.cloud_done_outlined,
          title: '1. Bulut sunucu ve güvenli bağlantı',
          subtitle: _cloudSubtitle(),
          level: r.cloudLevel,
        ),
        _TierRow(
          cardKey: 'doctor_tier_network',
          icon: Icons.wifi_outlined,
          title: '2. Ev modemi ve internet',
          subtitle: _networkSubtitle(),
          level: r.networkLevel,
        ),
        _TierRow(
          cardKey: 'doctor_tier_power',
          icon: Icons.electric_bolt_outlined,
          title: '3. Pano gücü ve donanım',
          subtitle: _powerSubtitle(),
          level: r.powerLevel,
        ),
        if (r.devices.length > 1)
          ServiceCard(
            key: const Key('doctor_devices'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Dairedeki panolar', style: TextStyle(fontWeight: FontWeight.w800, color: text)),
                const SizedBox(height: 6),
                for (final d in r.devices)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${d.name ?? d.deviceUuid}: '
                      '${d.online == null ? _noData : (d.online! ? 'çevrimiçi' : 'çevrimdışı')} • Son görülme: '
                      '${DoctorReport.seenText(d.secondsSinceSeen) ?? _noData}',
                      style: TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ),
              ],
            ),
          ),
        ServiceCard(
          key: const Key('doctor_summary'),
          accent: summaryColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  OrbIconBadge(
                    icon: summaryIcon,
                    family: serviceFamilyOf(summaryColor),
                    status: r.level == 'ok' ? OrbStatus.success : OrbStatus.none,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      r.title ?? 'Teşhis özeti: $_noData',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: SetupColors.readable(context, summaryColor),
                      ),
                    ),
                  ),
                ],
              ),
              if (r.summary != null) ...[
                const SizedBox(height: 6),
                Text(r.summary!, style: TextStyle(fontSize: 13, height: 1.35, color: text)),
              ],
              if (r.action != null) ...[
                const SizedBox(height: 10),
                Text('Ne yapmalıyım?', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: muted)),
                const SizedBox(height: 2),
                Text(r.action!, style: TextStyle(fontSize: 12.5, height: 1.4, color: text)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (r.suggestsWifiRecovery && canRecover) ...[
          OutlinedButton.icon(
            key: const Key('btn_doctor_recovery'),
            onPressed: onRecovery,
            icon: Icon(Icons.wifi_rounded, size: accentIconSize(context, base: 18)),
            label: const Text(
              'Modem veya şifre değiştiyse: Wi-Fi kurtarma',
              textAlign: TextAlign.center,
              textWidthBasis: TextWidthBasis.longestLine,
            ),
            // Metin + simge + çerçeve AYNI amber ailesinden (AA); sabit 52 dp yükseklik YOK: etiket 3 satıra çıkarsa düğme büyür
            // ve köşe yarıçapı 28 dp ile sınırlıdır (tam stadium 96 dp'lik düğmede "yumurta" oluyordu).
            style: accentOutlinedButtonStyle(context, AppFamilies.amber, minimumSize: const Size.fromHeight(52))
                .copyWith(shape: serviceTallButtonShapeProperty),
          ),
          const SizedBox(height: 8),
        ],
        SetupPrimaryButton(
          key: const Key('btn_doctor_rerun'),
          label: 'Testi Yeniden Çalıştır',
          icon: Icons.refresh_rounded,
          onPressed: onRerun,
        ),
      ],
    );
  }
}

class _TierRow extends StatelessWidget {
  const _TierRow({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.level,
  });

  final String cardKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final DoctorLevel level;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String badge;
    switch (level) {
      case DoctorLevel.ok:
        color = SetupColors.ok;
        badge = 'Sağlıklı';
      case DoctorLevel.warning:
        color = SetupColors.warn;
        badge = 'Uyarı';
      case DoctorLevel.error:
        color = SetupColors.error;
        badge = 'Sorun var';
      case DoctorLevel.unknown:
        color = SetupColors.info;
        badge = 'Veri yok';
      case DoctorLevel.notApplicable:
        color = SetupColors.info;
        badge = 'Pano yok';
    }
    final orb = OrbIconBadge(
      icon: icon,
      family: serviceFamilyOf(color),
      status: level == DoctorLevel.ok ? OrbStatus.success : OrbStatus.none,
      enabled: level != DoctorLevel.notApplicable,
    );
    final pill = ServiceStatusPill(
      label: badge,
      labelKey: Key('${cardKey}_badge'),
      color: color,
      icon: level == DoctorLevel.ok
          ? Icons.check_circle_rounded
          : (level == DoctorLevel.warning
                ? Icons.warning_amber_rounded
                : (level == DoctorLevel.error ? Icons.error_rounded : Icons.remove_circle_outline_rounded)),
    );
    final titleText = Text(
      title,
      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
    );
    final detail = Text(
      subtitle,
      style: TextStyle(fontSize: AppText.badge, height: 1.35, color: SetupColors.muted(context)),
    );
    return ServiceCard(
      key: Key(cardKey),
      margin: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Telefon genişliğinde (kart içi ≈ 256 dp) orb + hap + metin yan yana sığmaz: metin sütunu ≈ 100 dp'ye düşüp sözcükler
          // ("donanı / m") ve IP adresi harf ortasından kırılıyordu. Dar genişlikte / büyük yazıda DİKEY düzen: orb + başlık
          // (hap başlığın altında), ayrıntı TAM genişlikte (IP bölünmez).
          final stacked = SetupText.isLargeText(context) || constraints.maxWidth < 340;
          if (!stacked) {
            return Row(
              children: [
                orb,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [titleText, const SizedBox(height: 2), detail],
                  ),
                ),
                const SizedBox(width: 8),
                pill,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  orb,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [titleText, const SizedBox(height: 6), Wrap(children: [pill])],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              detail,
            ],
          );
        },
      ),
    );
  }
}
