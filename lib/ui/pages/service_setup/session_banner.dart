import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import 'setup_style.dart';
import 'setup_widgets.dart';

/// Oturumun türü: **geçici servis (PIN) oturumu** ile **kalıcı servis personeli hesabı** ayrımı.
enum ServiceSessionKind { pin, staff, superUser, none }

/// Oturum özeti (arayüz için): kim, hangi türde, geçici ise ne kadar süre kaldı.
class ServiceSessionView {
  const ServiceSessionView({
    required this.kind,
    this.name = '',
    this.homeName = '',
    this.remaining,
  });

  final ServiceSessionKind kind;
  final String name;
  final String homeName;

  /// Yalnızca geçici (PIN) oturumda: kalan süre.
  final Duration? remaining;

  bool get isPin => kind == ServiceSessionKind.pin;
  bool get isExpired => isPin && (remaining ?? Duration.zero) <= Duration.zero;

  static ServiceSessionView fromState(AutomationState state) {
    if (!state.isAuthenticated) return const ServiceSessionView(kind: ServiceSessionKind.none);
    final caps = state.capabilities;
    final user = state.currentUser;
    if (caps.isServiceSession || state.isServiceSession) {
      final info = state.serviceSession;
      return ServiceSessionView(
        kind: ServiceSessionKind.pin,
        name: (user?.fullName.isNotEmpty ?? false) ? user!.fullName : (info?.technicianName ?? ''),
        homeName: info?.homeName ?? state.activeHome?.name ?? '',
        remaining: state.serviceSessionRemaining ?? Duration.zero,
      );
    }
    if (caps.isSuperUser || state.isSuperUser) {
      return ServiceSessionView(kind: ServiceSessionKind.superUser, name: user?.fullName ?? '');
    }
    if (caps.isStaff || state.isServiceUser) {
      return ServiceSessionView(kind: ServiceSessionKind.staff, name: user?.fullName ?? '');
    }
    return const ServiceSessionView(kind: ServiceSessionKind.none);
  }
}

/// Oturum şeridi: PIN oturumunda **geri sayım** ("Kalan 01:42:10"; süre azalınca uyarı rengi, bitince
/// "Oturum süresi doldu"), kalıcı personelde hesap bilgisi. Yalnızca bu şerit saniyede bir yeniden çizilir.
class ServiceSessionBanner extends StatefulWidget {
  const ServiceSessionBanner({super.key, this.compact = false});

  /// Dar görünüm (AppBar altı): tek satır.
  final bool compact;

  @override
  State<ServiceSessionBanner> createState() => _ServiceSessionBannerState();
}

class _ServiceSessionBannerState extends State<ServiceSessionBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _timer = state.clock.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final view = ServiceSessionView.fromState(state);
    switch (view.kind) {
      case ServiceSessionKind.none:
        return const SizedBox.shrink();
      case ServiceSessionKind.pin:
        return _pin(context, view);
      case ServiceSessionKind.staff:
        return _info(
          context,
          icon: Icons.verified_user_rounded,
          title: 'Servis personeli hesabı',
          detail: view.name.isEmpty ? null : view.name,
        );
      case ServiceSessionKind.superUser:
        return _info(
          context,
          icon: Icons.shield_rounded,
          title: 'Süper yönetici hesabı',
          detail: view.name.isEmpty ? null : view.name,
        );
    }
  }

  Widget _info(BuildContext context, {required IconData icon, required String title, String? detail}) {
    final color = SetupColors.info;
    return Container(
      key: const Key('service_session_banner'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: SetupColors.readable(context, color)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail == null ? title : '$title • $detail',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: SetupColors.readable(context, color)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pin(BuildContext context, ServiceSessionView view) {
    final left = view.remaining ?? Duration.zero;
    final expired = left <= Duration.zero;
    final Color color;
    if (expired || left < const Duration(minutes: 2)) {
      color = SetupColors.error;
    } else if (left < const Duration(minutes: 10)) {
      color = SetupColors.warn;
    } else {
      color = SetupColors.info;
    }
    final readable = SetupColors.readable(context, color);
    final home = view.homeName.isEmpty ? '' : ' • ${view.homeName}';
    return Container(
      key: const Key('service_session_banner'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Semantics(
        liveRegion: expired || left < const Duration(minutes: 2),
        child: Row(
          children: [
            Icon(expired ? Icons.timer_off_rounded : Icons.timer_rounded, size: 18, color: readable),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                expired
                    ? 'Oturum süresi doldu'
                    : 'Geçici servis oturumu$home • Kalan ${CountdownText.format(left)}',
                key: const Key('service_session_text'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: readable),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Oturum bittiğinde eylemlerin yerine gösterilen açıklayıcı panel.
class SessionExpiredPanel extends StatelessWidget {
  const SessionExpiredPanel({
    super.key,
    required this.onBackToLogin,
    this.progressSaved = false,
    this.trailing,
  });

  final VoidCallback onBackToLogin;

  /// Kurulum ilerlemesi bu telefonda kayıtlı mı.
  final bool progressSaved;

  /// "Giriş Ekranına Dön" düğmesinin altında gösterilecek ek içerik (ör. girişsiz çalışan Wi-Fi kurulum kartı).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final color = SetupColors.warn;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer_off_rounded, size: 64, color: SetupColors.readable(context, color)),
              const SizedBox(height: 16),
              Text(
                'Oturum süresi doldu',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
              ),
              const SizedBox(height: 10),
              Text(
                'Güvenliğiniz için servis oturumu kapandı; yeni işlem yapılamaz.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14.5, height: 1.4, color: SetupColors.muted(context)),
              ),
              if (progressSaved) ...[
                const SizedBox(height: 8),
                Text(
                  'Kurulum ilerlemeniz bu telefonda kayıtlı. Yeniden giriş yaptıktan sonra '
                  '"Devam eden kurulumlar" listesinden kaldığınız yerden sürdürebilirsiniz.',
                  key: const Key('session_expired_saved'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, height: 1.4, color: SetupColors.text(context)),
                ),
              ],
              const SizedBox(height: 24),
              SetupPrimaryButton(
                key: const Key('btn_back_to_login'),
                label: 'Giriş Ekranına Dön',
                icon: Icons.login_rounded,
                onPressed: onBackToLogin,
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
