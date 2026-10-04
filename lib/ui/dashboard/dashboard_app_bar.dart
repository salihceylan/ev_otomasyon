import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../common/qr_flow.dart';
import '../motion/motion.dart';
import '../pages/device_settings_page.dart';
import '../pages/family/family_members_page.dart';
import '../pages/service_mode_page.dart';
import '../pages/system_doctor_dialog.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/orb.dart';
import '../widgets/settings/settings_card.dart' show familyForAccent;
import '../widgets/user_profile_dialog.dart';
import 'connection_status.dart';
import 'dashboard_states.dart';
import 'labels.dart';

/// Panonun hangi görünümü gösterdiği (rol/konsol ayrımı).
enum DashboardView { superConsole, serviceConsole, apartment }

DashboardView dashboardViewOf(AutomationState s) {
  if (s.isSuperUser) return DashboardView.superConsole;
  if (s.isServiceUser) return DashboardView.serviceConsole;
  return DashboardView.apartment;
}

typedef _BarVm = ({
  DashboardView view,
  Capabilities caps,
  AppMode mode,
  String title,
  ConnectionBadge badge,
  String initial,
  AccentFamily roleFamily,
  bool hasUser,
  bool multiHome,
  bool showSettings,
});

_BarVm _barVmOf(AutomationState s) {
  final view = dashboardViewOf(s);
  final caps = s.capabilities;
  String title;
  switch (view) {
    case DashboardView.superConsole:
      title = 'Süper Yönetici Konsolu';
    case DashboardView.serviceConsole:
      title = 'Yetkili Servis Konsolu';
    case DashboardView.apartment:
      title = s.mode == AppMode.cloud ? (s.activeHome?.name ?? 'Evim') : (s.status?.deviceName ?? 'AHBU Akıllı Ev');
  }
  return (
    view: view,
    caps: caps,
    mode: s.mode,
    title: title,
    badge: connectionBadgeOf(s),
    initial: initialOf(s.currentUser?.fullName),
    // Avatar rengi ROL ailesi: profil diyaloğunun avatarıyla AYNI kaynak (süper = violet, servis = cyan, ev sahibi = sky ...);
    // eskiden çubuktaki avatar her rolde sky idi ve tıklayınca açılan diyaloğun avatarı başka renkteydi.
    roleFamily: familyForAccent(UserProfileDialog.roleBadge(s).$2),
    hasUser: s.currentUser != null,
    multiHome: s.homes.length > 1,
    showSettings: s.mode == AppMode.direct || caps.hasHomeAccess || caps.canEditDeviceHost,
  );
}

/// Tüm eylemlerin görünür olduğu geniş çubuk eşiği (dp). Altında yalnızca birincil simgeler görünür.
const double _kWideBar = 640;

/// Dar telefon eşiği (dp): bunun altında "aile" girdisi de ⋮ menüsüne iner (çubukta en çok 2 birincil disk + ⋮ +
/// avatar kalır): 360 dp'de başlığa ≈ 135 dp kalır (5 disk iken ≈ 76 dp: ev adı 'E…' ve boş hap kapsülü).
const double _kPhoneBar = 400;

/// Cam disklerin GÖRSEL kenarı sayfa içerik oluğuna (16 dp) oturur: sol (konsol menü diski) ve sağ (avatar/giriş).
const double _kBarEdge = 16;

/// Marka halkası + boşluk (34 + 10) ve halkanın çizilmesi için başlık bölgesinin en az genişliği.
const double _kLogoSlot = 44;
const double _kLogoMinRegion = 200;

/// Dar kipte (alt satır yok) başlığın sarılabileceği en çok satır: 64 dp'lik çubuğa 2 x 16 sp (1.3x ölçekte ≈ 50 dp) sığar.
const int _kCompactTitleLines = 2;

/// Bağlantı hapındaki durum noktasının yatay yuvası (dp): 8 dp'lik nokta + "bağlanıyor" nabız halkasının (en çok ≈ 10.4 dp
/// yarıçap) hap kenarına ve ilk harfe değmeyeceği pay. Üst çubuğun "hap sığar mı" ölçümü de bunu kullanır.
const double _kDotSlot = 16;

/// Ev değiştirici oku: metinle ok arası boşluk ve okun yatayda tuttuğu toplam yer (boşluk + [_SwitcherChevron.size]).
const double _kSwitcherGap = 4;
const double _kSwitcherSlot = _kSwitcherGap + _SwitcherChevron.size;

class _NavItem {
  const _NavItem({
    required this.name,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.family = AppFamilies.cyan,
    this.primary = false,
  });

  /// `Key('nav_<name>')`.
  final String name;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Simge rengi ailesi: çubuktaki tüm simgeler marka camgöbeği (cyan); yalnızca durum simgesi (yerel/bulut modu)
  /// kendi anlamını taşır. Ham Material renkleri (cyanAccent ...) kullanılmaz.
  final AccentFamily family;

  /// Dar ekranlarda da simge olarak görünür; diğerleri "Diğer" menüsüne girer.
  final bool primary;
}

/// Pano üst çubuğu (Neon Glass): eylemler cam disk ([GlassIconButton]), başlık altında bağlantı hapı
/// ([GlassPill]: [GlowDot] / simge + metin), profil düğmesi avatar orb'u. Gezinme girdileri **`Capabilities`'ten**
/// türetilir:
///
/// | Anahtar | Koşul |
/// |---|---|
/// | `nav_menu` | süper / servis konsolu (çekmece) |
/// | `nav_home_switcher` | birden çok dairesi olan kullanıcı |
/// | `nav_qr` | oturum açmış, servis PIN oturumu değil (katıl / eşle) |
/// | `nav_settings` | aktif eve erişim (misafir dahil, salt-okunur sayfa) |
/// | `nav_family` | `canInvite` / `canManageMembers` (ev sahibi) |
/// | `nav_mode` | `canSwitchMode` (misafir ✖) |
/// | `nav_service` | servis PIN oturumu (`isServiceSession`) |
/// | `nav_doctor` | `canChangeChildLock` (tanılama misafire kapalı) / konsollarda `canOpenServiceManagement` |
/// | `nav_refresh`, `nav_profile`, `nav_login` | herkes / oturum açık / girişsiz yerel mod |
///
/// Dar ekranda (< 640 dp) yalnızca birincil simgeler görünür, kalanlar `nav_overflow` menüsündedir; telefonda
/// (< 400 dp) `nav_family` de menüye iner. Başlık bloğu kendi genişliğine göre uyum sağlar ([_Title]): yer yoksa
/// marka halkası düşer, bağlantı hapı kabuğu çizilmez (yalnız durum noktası/simgesi + ekran okuyucu etiketi),
/// başlık iki satıra sarılır; hiçbir metin boş kapsülde ya da kesik bırakılmaz.
class DashboardAppBar extends StatelessWidget implements PreferredSizeWidget {
  const DashboardAppBar({super.key, this.onOpenDrawer});

  /// Konsol görünümlerinde çekmeceyi açar.
  final VoidCallback? onOpenDrawer;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, _BarVm>(_barVmOf);
    final state = context.read<AutomationState>();
    final caps = vm.caps;
    final isConsole = vm.view != DashboardView.apartment;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _kWideBar;
    final phone = width < _kPhoneBar;

    final items = <_NavItem>[];
    if (isConsole) {
      if (caps.canOpenServiceManagement) {
        items.add(
          _NavItem(
            name: 'doctor',
            icon: Icons.health_and_safety_rounded,
            tooltip: 'Sistem Doktoru (Teşhis)',
            primary: true,
            onPressed: () => SystemDoctorDialog.show(context),
          ),
        );
      }
      items.add(
        _NavItem(
          name: 'refresh',
          icon: Icons.refresh_rounded,
          tooltip: 'Yenile',
          primary: true,
          onPressed: () => unawaited(state.refresh()),
        ),
      );
    } else {
      if (caps.isAuthenticated && !caps.isServiceSession) {
        items.add(
          _NavItem(
            name: 'qr',
            icon: Icons.qr_code_scanner, // test sözleşmesi: welcome_and_claim_flow_test bu simgeyi arar
            tooltip: 'Karekod Tara (Cihaz / Eve Katıl)',
            primary: true,
            onPressed: () => unawaited(scanAndRouteQr(context)),
          ),
        );
      }
      if (vm.showSettings) {
        items.add(
          _NavItem(
            name: 'settings',
            icon: Icons.settings_rounded,
            tooltip: 'Cihaz Ayarları',
            primary: true,
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage())),
          ),
        );
      }
      if (caps.canInvite || caps.canManageMembers) {
        items.add(
          _NavItem(
            name: 'family',
            icon: Icons.group_rounded,
            tooltip: 'Aile & Misafir Yönetimi',
            // Telefonda ⋮ menüsünde: çubuk 5 diskle başlığı eziyordu (ev adı 'E…').
            primary: !phone,
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FamilyMembersPage())),
          ),
        );
      }
      if (caps.canSwitchMode) {
        final cloud = vm.mode == AppMode.cloud;
        items.add(
          _NavItem(
            name: 'mode',
            icon: cloud ? Icons.cloud_rounded : Icons.wifi_rounded,
            tooltip: cloud ? 'Bulut Modu (yerel moda geç)' : 'Yerel Ağ Modu (buluta geç)',
            // Durum simgesi: yerel ağ modu amber (bulut modu marka cyan'ı).
            family: cloud ? AppFamilies.cyan : AppFamilies.amber,
            onPressed: () => unawaited(_toggleMode(context, state, cloud)),
          ),
        );
      }
      if (caps.isServiceSession) {
        items.add(
          _NavItem(
            name: 'service',
            icon: Icons.engineering_rounded,
            tooltip: 'Servis Modu (devreye alma)',
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ServiceModePage())),
          ),
        );
      }
      if (caps.canChangeChildLock && caps.hasHomeAccess) {
        items.add(
          _NavItem(
            name: 'doctor',
            icon: Icons.health_and_safety_rounded,
            tooltip: 'Sistem Doktoru (Teşhis)',
            onPressed: () => SystemDoctorDialog.show(context),
          ),
        );
      }
      items.add(
        _NavItem(name: 'refresh', icon: Icons.refresh_rounded, tooltip: 'Yenile', onPressed: () => unawaited(state.refresh())),
      );
    }

    final visible = wide ? items : items.where((i) => i.primary).toList();
    final overflow = wide ? const <_NavItem>[] : items.where((i) => !i.primary).toList();
    final accent = AppTheme.readableAccent(context, AppFamilies.cyan.base);

    return AppBar(
      toolbarHeight: 64,
      // Cam disklerin ve avatar orb'unun gölgesi araç çubuğunun alt kenarında KESİLMESİN: disk 44 dp, çubukta alt boşluk 10 dp;
      // gölge (blur 12 + y 5) ≈ 17 dp taşar. `AppBar` araç çubuğunu varsayılan `Clip.hardEdge` ile kırpıp açık temada alt kenarda
      // düz bir soluk bant bırakıyordu (r2_dashboard). Başlık bloğu yükseklik sınırlıdır ([_Title]: taşma yok).
      clipBehavior: Clip.none,
      automaticallyImplyLeading: false,
      // Başlığın sol boşluğunu `_Title` kendisi verir (apartman: 16 dp, konsol: menü diskinden 8 dp): AppBar
      // `titleSpacing`'i HER İKİ yandan düşer ve dar telefonda başlığa 16 dp'yi boşuna harcatırdı.
      titleSpacing: 0,
      // Konsol menü diski: GÖRSEL sol kenarı 16 dp (48 dp dokunma kutusu 14 dp'den başlar, disk 2 dp içeride).
      leadingWidth: isConsole ? 14 + 48 : null,
      leading: isConsole
          ? Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: _kBarEdge - 2),
                child: Tooltip(
                  message: 'Menü',
                  excludeFromSemantics: true,
                  child: GlassIconButton(
                    key: const Key('nav_menu'),
                    icon: Icons.menu_rounded,
                    iconColor: accent,
                    semanticLabel: 'Menü',
                    onTap: onOpenDrawer,
                  ),
                ),
              ),
            )
          : null,
      title: _Title(vm: vm, isConsole: isConsole),
      actions: [
        for (final item in visible) _NavButton(item: item),
        if (overflow.isNotEmpty)
          PopupMenuButton<String>(
            key: const Key('nav_overflow'),
            tooltip: 'Diğer işlemler',
            padding: EdgeInsets.zero,
            // Menü ⋮ diskinin ALTINDA açılır (varsayılan `over` menüyü tetikleyicinin ve ev adının üstüne bindirip örtüyordu).
            position: PopupMenuPosition.under,
            offset: const Offset(0, 8),
            child: const _OverflowDisk(),
            onSelected: (name) {
              for (final item in overflow) {
                if (item.name == name) item.onPressed();
              }
            },
            itemBuilder: (_) => [
              for (final item in overflow)
                PopupMenuItem<String>(
                  key: Key('nav_${item.name}'),
                  value: item.name,
                  height: 48,
                  child: Row(
                    children: [
                      // Panonun geri kalanıyla aynı dil: özellik renginde parlak mini orb (eskiden çıplak Material simgesi).
                      ExcludeSemantics(
                        child: SizedBox.square(
                          dimension: 32,
                          child: FittedBox(
                            child: OrbIconBadge(icon: item.icon, family: item.family, size: OrbSize.sm, glow: false),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(child: Text(item.tooltip)),
                    ],
                  ),
                ),
            ],
          ),
        if (vm.hasUser)
          _BarSlot(
            child: Tooltip(
              message: 'Kullanıcı Profili & Oturum',
              excludeFromSemantics: true,
              child: _ProfileButton(
                key: const Key('nav_profile'),
                initial: vm.initial,
                family: vm.roleFamily,
                onTap: () => UserProfileDialog.show(context),
              ),
            ),
          )
        else
          _BarSlot(
            child: Tooltip(
              message: 'Giriş yap (buluta geç)',
              excludeFromSemantics: true,
              child: GlassIconButton(
                key: const Key('nav_login'),
                icon: Icons.login_rounded,
                iconColor: accent,
                semanticLabel: 'Giriş yap (buluta geç)',
                onTap: () => unawaited(state.setMode(AppMode.cloud)),
              ),
            ),
          ),
        // Avatar (40 dp orb, 48 dp kutuda 4 dp içeride) + 1 dp yuva dolgusu ile görsel sağ kenar ≈ 16 dp.
        const SizedBox(width: _kBarEdge - 5),
      ],
    );
  }

  Future<void> _toggleMode(BuildContext context, AutomationState state, bool cloud) async {
    final ok = await state.setMode(cloud ? AppMode.direct : AppMode.cloud);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok ? (cloud ? 'Yerel ağ moduna geçildi' : 'Bulut moduna geçildi') : 'Bu hesapla mod değiştirilemez.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

/// Üst çubuk eylem aralığı (cam diskler arası 2 dp boşluk).
class _BarSlot extends StatelessWidget {
  const _BarSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 1),
    child: Center(child: child),
  );
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item});

  final _NavItem item;

  @override
  Widget build(BuildContext context) {
    return _BarSlot(
      child: Tooltip(
        message: item.tooltip,
        excludeFromSemantics: true,
        child: GlassIconButton(
          key: Key('nav_${item.name}'),
          icon: item.icon,
          iconColor: AppTheme.readableAccent(context, item.family.base),
          semanticLabel: item.tooltip,
          onTap: item.onPressed,
        ),
      ),
    );
  }
}

/// "Diğer" menüsünün cam diski (dokunmayı [PopupMenuButton] alır; yalnız görsel).
class _OverflowDisk extends StatelessWidget {
  const _OverflowDisk();

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    return SizedBox.square(
      dimension: 48,
      child: Center(
        child: SizedBox.square(
          dimension: 44,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: dark ? const Color(0x59000000) : SurfaceTokens.of(Brightness.light).shadow,
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: CustomPaint(
                painter: GlassDiskPainter(dark: dark),
                child: Center(
                  child: Icon(
                    Icons.more_vert_rounded,
                    size: 22,
                    color: AppTheme.readableAccent(context, AppFamilies.cyan.base),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ev değiştirici oku: 20 dp cam çip (marka camgöbeği tonlu OPAK dolgu + ince kenar) içinde açılır ok. Başlığın hemen
/// yanında durur; etkileşimsizdir (dokunuşu üstteki [InkWell] alır) ve anlamdan hariçtir (anlamı üst düğümün ipucu taşır).
class _SwitcherChevron extends StatelessWidget {
  const _SwitcherChevron();

  /// Çipin çapı (dp).
  static const double size = 20;

  @override
  Widget build(BuildContext context) {
    final ink = AppTheme.readableAccent(context, AppFamilies.cyan.base);
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.alphaBlend(AppFamilies.cyan.base.withValues(alpha: 0.20), tokens.cardTop),
          border: Border.all(color: ink.withValues(alpha: 0.55)),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Icon(Icons.expand_more_rounded, size: 16, color: ink),
        ),
      ),
    );
  }
}

/// Profil düğmesi: avatar orb'u (harf); basınca ölçek geri bildirimi, ≥ 48 dp hedef.
class _ProfileButton extends StatelessWidget {
  const _ProfileButton({super.key, required this.initial, required this.family, required this.onTap});

  final String initial;

  /// Avatar orb'unun rengi: rol ailesi (profil diyaloğundaki avatarla aynı).
  final AccentFamily family;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Kullanıcı Profili & Oturum',
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressedScale: 0.92,
        releaseOvershoot: 1.04,
        haptic: PressHaptic.light,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: AvatarOrb(letter: initial, family: family, size: 40),
          ),
        ),
      ),
    );
  }
}

/// Metnin (tek satır) genişliği: geçerli yazı ölçeği ve yazı stiliyle ([_Title] içinde ölçek 1.3'e kenetlidir).
double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Metin [maxWidth] genişliğinde en çok [lines] satıra KESİLMEDEN sığar mı?
bool _fitsInLines(BuildContext context, String text, TextStyle style, double maxWidth, int lines) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: lines,
  )..layout(maxWidth: maxWidth);
  final fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

/// Üst çubuk başlık bloğu: [marka halkası] + başlık + alt satır (bağlantı hapı / konsol sloganı).
///
/// **Kendi genişliğine göre uyum sağlar** (cihaz genişliğine değil; 64 dp'lik çubuk sabit kalır):
/// * marka halkası, başlık bölgesi [_kLogoMinRegion]'dan darsa çizilmez;
/// * alt satır (bağlantı hapı ya da konsol sloganı) yalnız **tamamı sığıyorsa** çizilir; sığmıyorsa hap KABUĞU hiç
///   çizilmez: apartmanda başlığın başında yalnız durum göstergesi kalır ([GlowDot] ya da çevrimdışı/anahtar/kilit
///   simgesi; renk tek ipucu değil, ekran okuyucu etiketi tam durum metnidir), konsolda slogan düşer;
/// * dar kipte başlık [_kCompactTitleLines] satıra sarılır; konsol başlığı iki satıra sığmıyorsa kısa biçime
///   ('Süper Yönetici' / 'Yetkili Servis') geçer.
class _Title extends StatelessWidget {
  const _Title({required this.vm, required this.isConsole});

  final _BarVm vm;
  final bool isConsole;

  @override
  Widget build(BuildContext context) {
    // Üst çubuk 64 dp sabit: başlık bloğu en çok 1.3x büyür (daha büyük yazı ölçeğinde taşma yerine sabit kalır).
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: isConsole ? 8 : _kBarEdge),
        child: LayoutBuilder(builder: (context, constraints) => _build(context, constraints.maxWidth)),
      ),
    );
  }

  Widget _build(BuildContext context, double region) {
    final isSuper = vm.view == DashboardView.superConsole;
    final ringColor = isConsole && !isSuper ? AppFamilies.cyan.base : const Color(0xFF38BDF8);
    final level = vm.badge.level;
    final badge = vm.badge;

    // Durum göstergesi rengi: parlak aile tonu (açık temada da canlı nokta); metin okunabilir ton (GlassPill türetir).
    final Color statusColor = switch (level) {
      ConnectionLevel.ready => AppFamilies.emerald.base,
      ConnectionLevel.degraded || ConnectionLevel.needsKey || ConnectionLevel.locked => AppFamilies.amber.base,
      ConnectionLevel.offline => AppFamilies.rose.base,
      ConnectionLevel.connecting => AppTheme.getTextMuted(context),
    };
    final statusText = AppTheme.readableAccent(context, statusColor);
    // Renk TEK ipucu değil: hazır/kesik/bağlanıyor = nokta + metin; çevrimdışı/anahtar/kilit = simge + metin.
    final useDot =
        level == ConnectionLevel.ready || level == ConnectionLevel.degraded || level == ConnectionLevel.connecting;
    final connecting = level == ConnectionLevel.connecting;
    final subtitle = '${badge.label} • ${badge.detail}';
    final tagline = vm.view == DashboardView.superConsole ? 'AHBU Altyapı & Servis Denetimi' : 'Saha Operasyon & Montaj Yönetimi';

    final base = DefaultTextStyle.of(context).style;
    final titleStyle = base.merge(
      TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
    );
    final pillTextStyle = base.merge(const TextStyle(fontSize: 12, fontWeight: FontWeight.w700));
    final taglineStyle = base.merge(
      TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppTheme.readableAccent(context, AppFamilies.cyan.base),
      ),
    );

    final hasSwitcher = !isConsole && vm.multiHome;
    final showLogo = region >= _kLogoMinRegion;
    final textRegion = math.max(0.0, region - (showLogo ? _kLogoSlot : 0) - (hasSwitcher ? _kSwitcherSlot : 0));

    // Alt satır sığıyor mu? (Ölçüm: gerçek yazı tipi/ölçekle; sığmıyorsa kabuk çizilmez, kesik metin bırakılmaz.)
    final leadingWidth = useDot ? _kDotSlot : 13.0;
    final showPill = !isConsole &&
        _textWidth(context, subtitle, pillTextStyle) + GlassPill.chromeWidth(leadingWidth: leadingWidth) + 2 <= textRegion;
    final showTagline = isConsole && _textWidth(context, tagline, taglineStyle) <= textRegion;
    final hasSecondLine = showPill || showTagline;

    // Başlık: alt satır varken tek satır (üç nokta); yoksa iki satıra sarılır (kesilmez).
    var title = vm.title;
    if (isConsole && !hasSecondLine && !_fitsInLines(context, title, titleStyle, textRegion, _kCompactTitleLines)) {
      title = isSuper ? 'Süper Yönetici' : 'Yetkili Servis';
    }
    final titleLines = hasSecondLine ? 1 : _kCompactTitleLines;
    final titleText = Text(
      title,
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
      maxLines: titleLines,
      softWrap: titleLines > 1,
      overflow: TextOverflow.ellipsis,
    );

    Widget statusGlyph(double dot, double icon) => useDot
        ? GlowDot(key: ValueKey<int>(connecting ? 3 : 0), color: statusColor, size: dot, pulses: connecting ? 3 : 0)
        : Icon(badge.icon, size: icon, color: statusText);

    final Widget head;
    if (hasSecondLine || isConsole) {
      head = titleText;
    } else {
      // Hap kabuğu yok: yalnız durum göstergesi (nokta/simge). Ekran okuyucu bloğu TEK düğümde okur: "ev adı, durum
      // metni" (görsel sıra gösterge → ad olsa da okuma sırası ad → durum). `text_connection` anahtarı alt satır
      // metninin (hap/slogan) yerine bu düğümde durur (her an en çok BİR tane).
      head = Semantics(
        key: const Key('text_connection'),
        label: '${vm.title}, $subtitle',
        excludeSemantics: true,
        child: Row(
          // İçeriğe büzülür: ev değiştirici oku başlığın hemen yanında durur (satır genişliği kadar uzamaz).
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 14, height: 14, child: Center(child: statusGlyph(8, 14))),
            const SizedBox(width: 6),
            Flexible(child: titleText),
          ],
        ),
      );
    }

    final Widget? secondLine = showPill
        ? GlassPill(
            color: statusColor,
            label: subtitle,
            textKey: const Key('text_connection'),
            compact: true,
            maxLines: 1,
            textColor: statusText,
            // Nokta için [_kDotSlot] dp'lik yuva: "bağlanıyor" nabız halkası (≈ 10 dp yarıçap) hap kenarına/ilk harfe
            // taşmasın; simge 13 dp'dir (yuva gerekmez).
            leading: useDot
                ? SizedBox(width: _kDotSlot, child: Center(child: statusGlyph(8, 13)))
                : statusGlyph(8, 13),
          )
        : showTagline
            ? Text(
                tagline,
                key: const Key('text_connection'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: taglineStyle.color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null;

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [head, if (secondLine != null) ...[const SizedBox(height: 2), secondLine]],
    );

    return Row(
      children: [
        if (showLogo) ...[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ringColor.withValues(alpha: 0.9), width: 1.2),
              boxShadow: [BoxShadow(color: ringColor.withValues(alpha: 0.35), blurRadius: 10)],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/round_app_logo.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(Icons.home_work_rounded, size: 20, color: ringColor),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: hasSwitcher
              // Ev değiştirici: TÜM başlık bloğu (ad + durum + ok) tek dokunulabilir/anlamlı düğümdür. Ok, başlığın
              // Expanded sağ ucuna değil METNİN hemen yanına oturur (`Flexible(text)` + ok, satır içeriğe büzülür): eskiden
              // başlıktan 100+ dp uzakta, cam disklere bitişik duruyor ve ad yerine disklere ait gibi okunuyordu.
              ? Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: InkWell(
                    key: const Key('nav_home_switcher'),
                    borderRadius: BorderRadius.circular(AppRadius.r8),
                    onTap: () => showHomeSwitcherSheet(context),
                    // Dokunma hedefi >= 48 dp: dar kipte (alt satır yok) blok tek satırdır (≈ 24 dp) ve hedef küçülürdü.
                    child: Semantics(
                      hint: 'Daireyi değiştirmek için dokunun',
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: text),
                            const SizedBox(width: _kSwitcherGap),
                            const _SwitcherChevron(),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : text,
        ),
      ],
    );
  }
}
