import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';
import 'setup_style.dart';
import 'setup_widgets.dart';

/// Oturumun türü: **geçici servis (PIN) oturumu** ile **kalıcı servis personeli hesabı** ayrımı.
enum ServiceSessionKind { pin, staff, superUser, none }

/// Oturum özeti (arayüz için): kim, hangi türde, geçici ise ne kadar süre kaldı.
class ServiceSessionView {
  const ServiceSessionView({required this.kind, this.name = '', this.homeName = '', this.remaining});

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
  const ServiceSessionBanner({super.key, this.pinOnly = false});

  /// `true` ise yalnız **geçici (PIN) oturumda** görünür: geri sayım taşıyan tek şerit. Kalıcı personel / süper yönetici
  /// şeridi yalnız "kim giriş yaptı" bilgisi verir; sihirbazın sabit üst alanında (şerit + başlık + alt çubuk) 1.5 yazı
  /// ölçeğinde ≈ 80 dp yer yiyip aynı bilgiyi "Teknisyen" kartında tekrarladığı için orada gösterilmez.
  final bool pinOnly;

  @override
  State<ServiceSessionBanner> createState() => _ServiceSessionBannerState();
}

class _ServiceSessionBannerState extends State<ServiceSessionBanner> {
  Timer? _timer;

  /// Kalan süre halkasının tabanı: bu bandın gördüğü ilk kalan süre (oturumun toplam süresi istemcide bilinmez).
  Duration? _initialRemaining;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  /// Saniyelik zamanlayıcı yalnızca **geçici (PIN) oturumda** kurulur: geri sayım yalnız orada vardır; personel/süper
  /// yönetici bandı sabittir ve saniyede bir yeniden kurulmaz. Oturum türü değişirse (bkz. [build]'deki `select`)
  /// zamanlayıcı buna göre kurulur/bırakılır.
  void _syncTimer() {
    final state = context.read<AutomationState>();
    final wantsTicker = ServiceSessionView.fromState(state).isPin;
    if (wantsTicker && _timer == null) {
      _timer = state.clock.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!wantsTicker && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Yalnız oturum türü / ad / daire adı değişince yeniden kurulur (AutomationState'in her bildirimi değil); PIN
    // oturumunda kalan süre saniyelik zamanlayıcıyla tazelenir.
    context.select<AutomationState, (ServiceSessionKind, String, String)>((s) {
      final v = ServiceSessionView.fromState(s);
      return (v.kind, v.name, v.homeName);
    });
    final view = ServiceSessionView.fromState(context.read<AutomationState>());
    switch (view.kind) {
      case ServiceSessionKind.none:
        return const SizedBox.shrink();
      case ServiceSessionKind.pin:
        return _pin(context, view);
      case ServiceSessionKind.staff:
        if (widget.pinOnly) return const SizedBox.shrink();
        return _info(
          context,
          icon: Icons.verified_user_rounded,
          title: 'Servis personeli hesabı',
          detail: view.name.isEmpty ? null : view.name,
        );
      case ServiceSessionKind.superUser:
        if (widget.pinOnly) return const SizedBox.shrink();
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
    // Ad bölünmez boşlukla bağlanır: dar ekranda / büyük yazıda "Servis / Ali" gibi yetim satır oluşmaz.
    final name = detail?.replaceAll(' ', '\u00A0');
    return SurfaceCard(
      key: const Key('service_session_banner'),
      accent: color,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: AppRadius.card,
      child: Row(
        children: [
          SetupMiniOrb(family: SetupColors.family(color), icon: icon, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name == null ? title : '$title • $name',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: SetupColors.readable(context, color),
              ),
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
    final muted = SetupColors.muted(context);
    final initial = _initialRemaining ??= left;
    // Halka uyarı anlarında İŞE YARAMALI: <2 dk'da halka son 2 dakikaya, <10 dk'da son 10 dakikaya göre ölçülür (taban
    // "bandın gördüğü ilk süre" (2 sa) olduğundan 01:30'da yay ≈ %1'e düşüp görünmez oluyordu); aksi halde ilk süreye göre.
    final window = left < const Duration(minutes: 2)
        ? const Duration(minutes: 2)
        : (left < const Duration(minutes: 10) ? const Duration(minutes: 10) : initial);
    final fraction = expired || window <= Duration.zero
        ? 0.0
        : (left.inMilliseconds / window.inMilliseconds).clamp(0.0, 1.0);
    final large = SetupText.isLargeText(context);

    // Kalan süre AYRI bir öğedir (cümlenin sonuna yapışık değil): "Kalan / 2:00:00" gibi yetim satır oluşmaz, süre azalırken
    // (2:00:00 -> 59:59) düzen sıçramaz (tabular rakam). Metin anahtarı `service_session_text` süreyi ("Kalan 2:00:00") ya da
    // bitince "Oturum süresi doldu"yu taşır.
    final countdown = Text(
      expired ? 'Oturum süresi doldu' : 'Kalan ${CountdownText.format(left)}',
      key: const Key('service_session_text'),
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: readable,
      ),
    );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Geçici servis oturumu',
          maxLines: large ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: readable),
        ),
        if (view.homeName.isNotEmpty)
          Text(
            view.homeName,
            maxLines: large ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppTouch.minFontSize, color: muted),
          ),
      ],
    );
    return SurfaceCard(
      key: const Key('service_session_banner'),
      accent: color,
      active: expired || left < const Duration(minutes: 2),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: AppRadius.card,
      child: Semantics(
        liveRegion: expired || left < const Duration(minutes: 2),
        child: Row(
          children: [
            _SessionRing(
              fraction: fraction,
              color: color,
              readable: readable,
              icon: expired ? Icons.timer_off_rounded : Icons.timer_rounded,
            ),
            const SizedBox(width: 10),
            if (expired)
              Expanded(child: countdown)
            else if (large)
              // Büyük yazıda yan yana sığmaz: süre başlığın altında, tam genişlikte.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [heading, const SizedBox(height: 2), countdown],
                ),
              )
            else ...[
              Expanded(child: heading),
              const SizedBox(width: 8),
              countdown,
            ],
          ],
        ),
      ),
    );
  }
}

/// Kalan süre halkası: dolu iz + kalan oranı kadar yay (saniyede bir yeniden çizilir; animasyon/ambient yok), ortada
/// zamanlayıcı simgesi. Yalnız görsel: süre metni yanındadır.
class _SessionRing extends StatelessWidget {
  const _SessionRing({required this.fraction, required this.color, required this.readable, required this.icon});

  final double fraction;
  final Color color;
  final Color readable;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 30,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _SessionRingPainter(fraction: fraction, color: color),
            child: Center(child: Icon(icon, size: 15, color: readable)),
          ),
        ),
      ),
    );
  }
}

class _SessionRingPainter extends CustomPainter {
  const _SessionRingPainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.5;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.35),
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SessionRingPainter old) => old.fraction != fraction || old.color != color;
}

/// Oturum bittiğinde eylemlerin yerine gösterilen açıklayıcı panel.
class SessionExpiredPanel extends StatelessWidget {
  const SessionExpiredPanel({super.key, required this.onBackToLogin, this.progressSaved = false, this.trailing});

  final VoidCallback onBackToLogin;

  /// Kurulum ilerlemesi bu telefonda kayıtlı mı.
  final bool progressSaved;

  /// "Giriş Ekranına Dön" düğmesinin altında gösterilecek ek içerik (ör. girişsiz çalışan Wi-Fi kurulum kartı).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const OrbIconBadge(
                icon: Icons.timer_off_rounded,
                family: AppFamilies.amber,
                size: OrbSize.xl,
                glow: true,
              ),
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
