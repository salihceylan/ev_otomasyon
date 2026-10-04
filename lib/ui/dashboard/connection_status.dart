import 'package:flutter/material.dart';

import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Bağlantının kullanıcıya gösterilen seviyesi.
enum ConnectionLevel {
  /// Cihaz erişilebilir ve canlı akış var ("Sistem Hazır").
  ready,

  /// Cihaz çevrimiçi ama canlı izleme koptu (komutlar REST ile gider; durum "son bilinen").
  degraded,

  /// Cihaza ulaşılamıyor / çevrimdışı.
  offline,

  /// Bağlantı kuruluyor (henüz bilgi yok).
  connecting,

  /// Yerel modda cihaza ulaşıldı ama anahtar gerekli / cihaz kurulmamış.
  needsKey,

  /// Yerel modda cihaz çok sayıda hatalı denemeyle geçici KİLİTLENDİ (423; süre dolana kadar yoklanmaz).
  locked,
}

/// Bağlantı özeti (rozet ve başlık için). Değer eşitliği vardır: `context.select` ile kullanılır.
@immutable
class ConnectionBadge {
  const ConnectionBadge({required this.level, required this.label, required this.detail});

  final ConnectionLevel level;

  /// Kısa durum etiketi (ör. "Sistem Hazır").
  final String label;

  /// Başlıktaki ikinci satır (ör. "Bulut" / "Yerel Ağ (192.168.1.20)").
  final String detail;

  bool get isReady => level == ConnectionLevel.ready;

  /// Seviyenin renk ailesi: nokta / halka / hap kenarı gibi **şekil** renkleri için (parlak aile rengi).
  /// Metin ve ince simge için okunur ton gereken yerde [color] kullanılır (açık temada AA kontrastlı koyu ton).
  AccentFamily get family {
    switch (level) {
      case ConnectionLevel.ready:
        return AppFamilies.emerald;
      case ConnectionLevel.degraded:
      case ConnectionLevel.needsKey:
      case ConnectionLevel.locked:
        return AppFamilies.amber;
      case ConnectionLevel.offline:
        return AppFamilies.rose;
      case ConnectionLevel.connecting:
        return AppFamilies.slate;
    }
  }

  Color color(BuildContext context) {
    switch (level) {
      case ConnectionLevel.ready:
        return AppTheme.successText(context);
      case ConnectionLevel.degraded:
      case ConnectionLevel.needsKey:
      case ConnectionLevel.locked:
        return AppTheme.warningText(context);
      case ConnectionLevel.offline:
        return AppTheme.dangerText(context);
      case ConnectionLevel.connecting:
        return AppTheme.getTextMuted(context);
    }
  }

  IconData get icon {
    switch (level) {
      case ConnectionLevel.ready:
        return Icons.wifi;
      case ConnectionLevel.degraded:
        return Icons.sync_problem_outlined;
      case ConnectionLevel.offline:
        return Icons.wifi_off;
      case ConnectionLevel.connecting:
        return Icons.sync;
      case ConnectionLevel.needsKey:
        return Icons.vpn_key_outlined;
      case ConnectionLevel.locked:
        return Icons.lock_clock_outlined;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionBadge &&
      other.level == level &&
      other.label == label &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(level, label, detail);
}

/// Durumdan bağlantı rozetini türetir (D §9: cihaz çevrimiçiliği ile broker bağlantısı **ayrıdır**).
ConnectionBadge connectionBadgeOf(AutomationState s) {
  if (s.mode == AppMode.direct) {
    final host = s.host.isEmpty ? 'adres yok' : s.host;
    final detail = 'Yerel Ağ ($host)';
    switch (s.connState) {
      case ConnectionStateEnum.connected:
        final blockedUntil = s.directBlockedUntil;
        if (blockedUntil != null && s.clock.now().isBefore(blockedUntil)) {
          return ConnectionBadge(
            level: ConnectionLevel.locked,
            label: 'Cihaz geçici kilitli',
            detail: detail,
          );
        }
        if (s.directNeedsKey || s.directError != null) {
          return ConnectionBadge(
            level: ConnectionLevel.needsKey,
            label: 'Cihaz anahtarı gerekli',
            detail: detail,
          );
        }
        return ConnectionBadge(level: ConnectionLevel.ready, label: 'Sistem Hazır', detail: detail);
      case ConnectionStateEnum.offline:
        return ConnectionBadge(
          level: ConnectionLevel.offline,
          label: 'Cihaza ulaşılamıyor',
          detail: detail,
        );
      case ConnectionStateEnum.connecting:
        return ConnectionBadge(
          level: ConnectionLevel.connecting,
          label: 'Bağlanıyor…',
          detail: detail,
        );
    }
  }

  // Misafir erişimi sona ermişse cihaz durumu anlamsızdır: gövdede "Erişim süreniz doldu" yazar; "Bağlanıyor…" çelişirdi.
  // (Seviye: `locked` = zaman kilidi simgesi; yeni seviye eklenmez, çünkü seviyeler üzerinde tüketiciler tam eşleştirme yapar.)
  final activeHome = s.activeHome;
  if (s.capabilities.isGuestExpired || (activeHome != null && activeHome.isGuestExpiredAt(s.clock.now()))) {
    return const ConnectionBadge(
      level: ConnectionLevel.locked,
      label: 'Erişim süresi doldu',
      detail: 'Misafir erişimi sona erdi',
    );
  }

  // Aktif daire yoksa (ev listesi hatası / dairesiz kullanıcı / daire seçilmemiş) bağlanılacak uç nokta YOKTUR:
  // ekrandaki kartla ("yüklenemedi" / "daire yok") çelişen "Bağlanıyor…" gösterilmez. Liste henüz gelmediyse
  // (yükleme sürüyor) "Bağlanıyor…" kalır.
  if (s.activeHome == null) {
    if (s.homesFromCache || (s.homesError != null && !s.homesLoaded)) {
      return const ConnectionBadge(
        level: ConnectionLevel.offline,
        label: 'Sunucuya ulaşılamıyor',
        detail: 'Bulut • daire listesi alınamadı',
      );
    }
    if (s.homesLoaded) {
      return ConnectionBadge(
        level: ConnectionLevel.ready,
        label: 'Bulut bağlı',
        detail: s.homes.isEmpty ? 'Daire yok' : 'Daire seçin',
      );
    }
  }

  if (s.deviceOnline) {
    return s.brokerConnected
        ? const ConnectionBadge(
            level: ConnectionLevel.ready,
            label: 'Sistem Hazır',
            detail: 'Bulut',
          )
        : const ConnectionBadge(
            level: ConnectionLevel.degraded,
            label: 'Canlı izleme kesik',
            detail: 'Bulut • son bilinen durum',
          );
  }
  if (s.devicePresence == DevicePresence.offline) {
    // [detail] etiketi TEKRARLAMAZ: üst çubuk hapı "etiket • ayrıntı" birleşimini yazar ("Pano çevrimdışı • Bulut");
    // eskiden ayrıntı "Bulut • pano çevrimdışı" idi ve aynı ifade hapta iki kez geçiyordu.
    return const ConnectionBadge(
      level: ConnectionLevel.offline,
      label: 'Pano çevrimdışı',
      detail: 'Bulut',
    );
  }
  return const ConnectionBadge(
    level: ConnectionLevel.connecting,
    label: 'Bağlanıyor…',
    detail: 'Bulut',
  );
}

/// Cihazın çevrimdışı olduğu **kesin** mi (bilinmiyor/bağlanıyor "çevrimdışı" sayılmaz).
bool deviceKnownOffline(AutomationState s) {
  if (s.mode == AppMode.direct) return s.connState == ConnectionStateEnum.offline;
  return s.devicePresence == DevicePresence.offline;
}
