import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:provider/provider.dart';

import '../../services/safety_notice_controller.dart';
import '../motion/motion.dart';
import '../pages/alarm_history_page.dart';
import '../pages/device_settings_page.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'critical_alarm_card.dart';

// =============================================================================
// Güvenlik bildirimi köprüsü (Faz 2 WP-N3; tasarım F2.C.6, F2.C.7).
//
// `MaterialApp.builder` içinde yaşar, kendisi bir şey çizmez ([child] aynen döner). [SafetyNoticeController]'ın
// kararlarını uygular:
//  * Dokunuş (C.6): gezinti yığını köke indirilir; kart varsa görünür olana kadar kaydırılır (Hareket v3 süresi,
//    `MotionScope.off`'ta 0) ve bir kez vurgulanır ([SafetyCardHighlight]); ekran okuyucuya "Alarm kartı açıldı:
//    <başlık>" duyurulur. Kart yoksa alarm geçmişi ("Bu alarm kapanmış."), bilgi bildiriminde cihaz ayarları.
//  * Ön plan (C.7): başka sayfadayken ya da başka evdeyken [MaterialBanner] afişi ("Gaz kaçağı alarmı – dokunun");
//    panoda ve aynı evdeyse afiş yok (kart zaten görünür). Aynı bildirim 10 dk içinde bir kez.
//
// Anahtarlar: `banner_safety_notice`, `btn_safety_notice_open`, `btn_safety_notice_dismiss`.
// =============================================================================

class SafetyNoticeHost extends StatefulWidget {
  const SafetyNoticeHost({super.key, required this.navigatorKey, required this.child});

  /// Uygulamanın gezgini (köprü `Navigator`'ın üstündedir; yığın bu anahtarla yönetilir).
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<SafetyNoticeHost> createState() => _SafetyNoticeHostState();
}

class _SafetyNoticeHostState extends State<SafetyNoticeHost> {
  /// Kartın ağaçta belirmesini bekleme üst sınırı (kare).
  static const int _maxCardFrames = 30;
  static const Duration _bannerDedupe = Duration(minutes: 10);

  late final SafetyNoticeController _controller;
  ScaffoldFeatureController<MaterialBanner, MaterialBannerClosedReason>? _banner;
  String? _bannerKey;
  final Map<String, DateTime> _bannerShown = <String, DateTime>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller = Provider.of<SafetyNoticeController>(context, listen: false);
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final target = _controller.takeTarget();
    if (target != null) _apply(target);
    _syncBanner();
  }

  // ---------------------------------------------------------------------------
  // Yönlendirme (C.6)
  // ---------------------------------------------------------------------------

  void _apply(SafetyNoticeTarget target) {
    final nav = widget.navigatorKey.currentState;
    if (nav == null) return;
    final generation = ++_generation;
    _hideBanner();
    nav.popUntil((route) => route.isFirst);
    switch (target.kind) {
      case SafetyNoticeTargetKind.card:
        _revealCard(target.cardKey!, target.title, generation, 0);
      case SafetyNoticeTargetKind.history:
        unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => AlarmHistoryPage(note: target.note))));
      case SafetyNoticeTargetKind.deviceSettings:
        unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const DeviceSettingsPage())));
      case SafetyNoticeTargetKind.dashboard:
        break;
    }
  }

  /// Kart (köke inince) ağaca gelene kadar kare kare bekler; sonra kaydırır ve bir kez vurgular.
  void _revealCard(String key, String? title, int generation, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      final cardContext = SafetyCardHighlight.contextOf(key);
      if (cardContext == null || !cardContext.mounted) {
        if (attempt < _maxCardFrames) {
          _revealCard(key, title, generation, attempt + 1);
          WidgetsBinding.instance.scheduleFrame();
        }
        return;
      }
      final duration = MotionScope.durationOf(cardContext, AppMotion.slow);
      unawaited(Scrollable.ensureVisible(cardContext, duration: duration, alignment: 0.1).then((_) {
        if (!mounted || generation != _generation) return;
        SafetyCardHighlight.highlight(key);
        final view = View.maybeOf(context);
        if (view != null) {
          unawaited(SemanticsService.sendAnnouncement(
            view,
            'Alarm kartı açıldı: ${title ?? 'Güvenlik alarmı'}',
            Directionality.maybeOf(context) ?? TextDirection.ltr,
          ));
        }
      }));
    });
  }

  // ---------------------------------------------------------------------------
  // Ön plan afişi (C.7)
  // ---------------------------------------------------------------------------

  void _syncBanner() {
    final banner = _controller.banner;
    if (banner == null) {
      _hideBanner();
      return;
    }
    final key = banner.notice.dedupeKey;
    if (_bannerKey == key && _banner != null) return;
    final nav = widget.navigatorKey.currentState;
    final onDashboard = nav == null || !nav.canPop();
    if (onDashboard && !banner.otherHome) {
      // Kart panoda zaten görünür: afiş gereksiz.
      scheduleMicrotask(_controller.dismissBanner);
      return;
    }
    final now = DateTime.now();
    _bannerShown.removeWhere((_, at) => now.difference(at) >= _bannerDedupe);
    if (_bannerShown.containsKey(key)) {
      scheduleMicrotask(_controller.dismissBanner);
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _hideBanner();
    _bannerShown[key] = now;
    _bannerKey = key;
    try {
      _banner = messenger.showMaterialBanner(_buildBanner(banner));
    } catch (_) {
      // Kayıtlı Scaffold yok (açılış ekranı): afiş atlanır, kart panoda görünür.
      _banner = null;
      _bannerKey = null;
    }
  }

  MaterialBanner _buildBanner(SafetyNoticeBanner banner) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return MaterialBanner(
      key: const Key('banner_safety_notice'),
      backgroundColor: dark ? const Color(0xFF3B0D16) : const Color(0xFFFFE4E8),
      leading: Icon(Icons.warning_rounded, color: AppFamilies.rose.base),
      content: Semantics(
        liveRegion: true,
        child: Text(
          banner.text,
          style: TextStyle(fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context)),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_safety_notice_dismiss'),
          onPressed: () {
            _hideBanner();
            _controller.dismissBanner();
          },
          child: const Text('Kapat'),
        ),
        TextButton(
          key: const Key('btn_safety_notice_open'),
          onPressed: () {
            _hideBanner();
            unawaited(_controller.openBanner());
          },
          child: const Text('Aç'),
        ),
      ],
    );
  }

  void _hideBanner() {
    final handle = _banner;
    _banner = null;
    _bannerKey = null;
    if (handle == null) return;
    try {
      handle.close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
