import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/cloud_models.dart';
import 'automation_state.dart';
import 'push/peace_notice.dart';
import 'push/safety_notice.dart';

// =============================================================================
// Güvenlik bildirimi denetleyicisi (Faz 2 WP-N2; tasarım F2.C.4, F2.C.6, F2.C.7).
//
// Kabuğa bağlanır (gece hatırlatması deseni): [AutomationState]'in yalnız PUBLIC arayüzünü kullanır (homes, activeHome,
// selectHome, refresh, isAuthenticated, capabilities, safety durumu). Yönlendirmenin kendisini (yığını köke indirme,
// kaydırma, vurgu, geçmiş sayfası) arayüz köprüsü yapar: bu sınıf yalnız KARAR verir ([target]) ve ön plan afişini
// ([banner]) tutar. Hiçbir yöntem istisna fırlatmaz; bildirim içeriği loglanmaz.
// =============================================================================

/// Bildirime dokunulunca gidilecek yer.
enum SafetyNoticeTargetKind {
  /// Panodaki kart ([SafetyNoticeTarget.cardKey]) kaydırılıp bir kez vurgulanır.
  card,

  /// Alarm geçmişi sayfası (kart yok: alarm bu arada kapanmış); [SafetyNoticeTarget.note] alt bilgisiyle.
  history,

  /// Cihaz ayarları sayfası (politika / bekleyen yapılandırma bildirimi); yoksa pano.
  deviceSettings,

  /// Yalnız pano (kök).
  dashboard,
}

/// Arayüz köprüsünün uygulayacağı yönlendirme kararı.
@immutable
class SafetyNoticeTarget {
  const SafetyNoticeTarget({required this.kind, required this.notice, this.cardKey, this.note, this.title});

  final SafetyNoticeTargetKind kind;
  final SafetyPushNotice notice;

  /// `card_critical_alarm_UID_BOLGE` ya da `card_intrusion_UID` biçimli kart anahtarı.
  final String? cardKey;

  /// Geçmiş sayfasının alt bilgisi ("Bu alarm kapanmış.").
  final String? note;

  /// Ekran okuyucu duyurusu için kart başlığı ("Alarm kartı açıldı: BAŞLIK").
  final String? title;

  @override
  String toString() => 'SafetyNoticeTarget(${kind.name}, $cardKey)';
}

/// Uygulama açıkken gelen alarm bildiriminin afişi (F2.C.7).
@immutable
class SafetyNoticeBanner {
  const SafetyNoticeBanner({required this.notice, required this.text, required this.otherHome});

  final SafetyPushNotice notice;

  /// "Gaz kaçağı alarmı – dokunun" ya da "Diğer evinizde alarm: EV ADI".
  final String text;
  final bool otherHome;
}

/// Push başlığıyla aynı adlar (sunucu F2.A.5 / F2.B.7).
String safetyNoticeKindTitle(String kind) {
  switch (kind) {
    case 'water':
      return 'Su baskını alarmı';
    case 'gas':
      return 'Gaz kaçağı alarmı';
    case 'smoke':
      return 'Duman alarmı';
    case 'intrusion':
      return 'Hırsız alarmı';
  }
  return 'Güvenlik alarmı';
}

/// Kritik alarm kartının anahtarı (`critical_alarm_card.dart` ile aynı biçim).
String criticalAlarmCardKey(String? uid, int zone) => 'card_critical_alarm_${uid}_$zone';

/// Hırsız alarmı kartının anahtarı (F2.B.9).
String intrusionAlarmCardKey(String? uid) => 'card_intrusion_$uid';

class SafetyNoticeController extends ChangeNotifier {
  SafetyNoticeController({
    required this.state,
    required Stream<SafetyPushNotice> notices,
    DateTime Function()? now,
    this.refreshTimeout = const Duration(seconds: 5),
    this.holdMaxAge = const Duration(minutes: 30),
  }) : _now = now ?? DateTime.now {
    _authenticated = state.isAuthenticated;
    _noticeSub = notices.listen(_onNotice, onError: (Object _) {});
    state.addListener(_onStateChanged);
  }

  final AutomationState state;
  final DateTime Function() _now;

  /// Yönlendirmeden önce `refresh` için en uzun bekleme (F2.C.6 madde 4).
  final Duration refreshTimeout;

  /// Oturum yokken bekletilen dokunuşun geçerlilik süresi (F2.C.6 madde 1).
  final Duration holdMaxAge;

  StreamSubscription<SafetyPushNotice>? _noticeSub;
  bool _disposed = false;
  bool _authenticated = false;

  /// Oturum/ev nesli: oturum değişince artar; uçuştaki yönlendirme eskiyse çekilir.
  int _generation = 0;

  SafetyPushNotice? _held;
  SafetyNoticeTarget? _target;
  SafetyNoticeBanner? _banner;

  /// Arayüz köprüsünün uygulayacağı (henüz alınmamış) yönlendirme.
  SafetyNoticeTarget? get target => _target;

  /// Ön plan afişi (uygulama açıkken gelen alarm); yoksa `null`.
  SafetyNoticeBanner? get banner => _banner;

  /// Yönlendirmeyi bir kez alır (köprü uygular).
  SafetyNoticeTarget? takeTarget() {
    final t = _target;
    _target = null;
    return t;
  }

  void dismissBanner() {
    if (_banner == null) return;
    _banner = null;
    _notify();
  }

  /// Afişe dokunuldu: aynı bildirim yönlendirmeye gider (F2.C.7 -> C.6).
  Future<void> openBanner() async {
    final b = _banner;
    if (b == null) return;
    _banner = null;
    _notify();
    await open(b.notice.withSource(PeaceNoticeSource.opened));
  }

  void _onNotice(SafetyPushNotice notice) {
    if (_disposed) return;
    if (notice.source == PeaceNoticeSource.foreground) {
      _showBanner(notice);
      return;
    }
    unawaited(open(notice));
  }

  void _showBanner(SafetyPushNotice notice) {
    // Yalnız alarm afiş üretir; bilgi bildirimi uygulama açıkken sessizdir (durum zaten görünür).
    if (!notice.isAlarm || !state.isAuthenticated) return;
    HomeModel? home;
    for (final h in state.homes) {
      if (h.id == notice.homeId) home = h;
    }
    if (home == null) return;
    final other = state.activeHome?.id != notice.homeId;
    final name = home.name.trim().isEmpty ? 'ev' : home.name.trim();
    _banner = SafetyNoticeBanner(
      notice: notice,
      text: other ? 'Diğer evinizde alarm: $name' : '${safetyNoticeKindTitle(notice.kind)} – dokunun',
      otherHome: other,
    );
    _notify();
  }

  /// Bildirime dokunuş (`opened` / `initial`): F2.C.6 adımları. Asla fırlatmaz.
  Future<void> open(SafetyPushNotice notice) async {
    if (_disposed) return;
    if (!state.isAuthenticated) {
      _held = notice; // oturum açılınca bir kez işlenir
      return;
    }
    final generation = ++_generation;
    try {
      HomeModel? home;
      for (final h in state.homes) {
        if (h.id == notice.homeId) home = h;
      }
      if (home == null) return; // çıkış yapmış / rolü düşmüş telefon
      if (state.activeHome?.id != home.id) {
        await state.selectHome(home);
        if (!_current(generation)) return;
      }
      try {
        await state.refresh(silent: true).timeout(refreshTimeout);
      } catch (_) {
        // Yenileme yetişmedi: eldeki durumla karar verilir.
      }
      if (!_current(generation) || state.activeHome?.id != home.id) return;
      // Doğrudan (LAN) kipte adresteki pano bildirimin evine (ve panosuna) ait değilse kart da geçmiş de doğru değildir:
      // yalnız pano (kullanim-3).
      if (state.mode == AppMode.direct &&
          !state.lanBoardBelongsTo(home.id, deviceUid: notice.isAlarm ? notice.deviceUuid : null)) {
        _target = SafetyNoticeTarget(kind: SafetyNoticeTargetKind.dashboard, notice: notice);
        _notify();
        return;
      }
      // Canlı durum (MQTT) tazelenmeden "Bu alarm kapanmış" denmez (kullanim-2): arka plandan dönüşte / başka eve
      // geçişte güvenlik haritası bayat ya da boş olabilir.
      final fresh = await state.awaitFreshSafety(homeId: home.id, timeout: refreshTimeout);
      if (!_current(generation) || state.activeHome?.id != home.id) return;
      var target = _resolve(notice);
      if (target.kind == SafetyNoticeTargetKind.history && !fresh) {
        final open = await _alarmStillOpen(notice);
        if (!_current(generation) || state.activeHome?.id != home.id) return;
        // Hâlâ açık ya da denetlenemedi: pano (kart canlı durum gelince görünür). Kapandığı doğrulandıysa geçmiş.
        if (open != false) target = SafetyNoticeTarget(kind: SafetyNoticeTargetKind.dashboard, notice: notice);
      }
      _target = target;
      _notify();
    } catch (_) {
      // Yönlendirme en iyi çabadır; hata arayüzü bozmaz.
    }
  }

  /// Bildirimin alarmı sunucuda hâlâ açık mı (aynı pano / bölge / tür): `true`/`false`; denetlenemediyse `null`.
  Future<bool?> _alarmStillOpen(SafetyPushNotice notice) async {
    try {
      final records = await state.fetchOpenAlarms().timeout(refreshTimeout);
      final uid = notice.deviceUuid?.toUpperCase();
      for (final r in records) {
        if (!r.isOpen) continue;
        if (notice.isIntrusion ? r.kind != 'intrusion' : r.kind == 'intrusion') continue;
        if (!notice.isIntrusion && notice.zone != null && r.zone != notice.zone) continue;
        if (uid != null && r.deviceUuid != null && r.deviceUuid != uid) continue;
        if (!notice.isIntrusion && notice.kind != 'generic' && r.kind != 'unknown' && r.kind != notice.kind) continue;
        return true;
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation && state.isAuthenticated;

  SafetyNoticeTarget _resolve(SafetyPushNotice notice) {
    final uid = notice.deviceUuid?.toUpperCase();
    if (notice.isAlarm) {
      if (notice.isIntrusion) {
        for (final entry in state.safetyByDevice.entries) {
          if (uid != null && entry.key != uid) continue;
          if (entry.value.intrusionAlarmActive) {
            return SafetyNoticeTarget(
              kind: SafetyNoticeTargetKind.card,
              notice: notice,
              cardKey: intrusionAlarmCardKey(entry.key),
              title: safetyNoticeKindTitle(notice.kind),
            );
          }
        }
      } else {
        for (final a in state.alarmItems) {
          if (!a.isActive || a.zone != notice.zone) continue;
          if (uid != null && a.deviceUid?.toUpperCase() != uid) continue;
          return SafetyNoticeTarget(
            kind: SafetyNoticeTargetKind.card,
            notice: notice,
            cardKey: criticalAlarmCardKey(a.deviceUid, a.zone),
            title: notice.title ?? safetyNoticeKindTitle(notice.kind),
          );
        }
      }
      // Kart yok: alarm bu arada kapanmış. Geçmiş yalnız alarm işlemi yetkisi olanlara (misafir yalnız pano).
      if (state.capabilities.canAckAlarm) {
        return SafetyNoticeTarget(kind: SafetyNoticeTargetKind.history, notice: notice, note: 'Bu alarm kapanmış.');
      }
      return SafetyNoticeTarget(kind: SafetyNoticeTargetKind.dashboard, notice: notice);
    }
    switch (notice.reason) {
      case 'alarm_lost':
        for (final a in state.alarmItems) {
          if (!a.isActive) continue;
          if (uid != null && a.deviceUid?.toUpperCase() != uid) continue;
          return SafetyNoticeTarget(
            kind: SafetyNoticeTargetKind.card,
            notice: notice,
            cardKey: criticalAlarmCardKey(a.deviceUid, a.zone),
            title: safetyNoticeKindTitle(a.kind),
          );
        }
        return SafetyNoticeTarget(kind: SafetyNoticeTargetKind.dashboard, notice: notice);
      default:
        return SafetyNoticeTarget(kind: SafetyNoticeTargetKind.deviceSettings, notice: notice);
    }
  }

  void _onStateChanged() {
    if (_disposed) return;
    final auth = state.isAuthenticated;
    if (auth == _authenticated) return;
    _authenticated = auth;
    _generation++; // oturum değişti: uçuştaki yönlendirme çekilir
    if (!auth) {
      _target = null;
      _banner = null;
      _notify();
      return;
    }
    final held = _held;
    _held = null;
    if (held != null && _now().difference(held.receivedAt) < holdMaxAge) unawaited(open(held));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _noticeSub?.cancel();
    state.removeListener(_onStateChanged);
    super.dispose();
  }
}
