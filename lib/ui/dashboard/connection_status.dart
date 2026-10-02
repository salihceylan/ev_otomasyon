import 'package:flutter/material.dart';

import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

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

  Color color(BuildContext context) {
    switch (level) {
      case ConnectionLevel.ready:
        return AppTheme.successText(context);
      case ConnectionLevel.degraded:
      case ConnectionLevel.needsKey:
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
        if (s.directError != null) {
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
    return const ConnectionBadge(
      level: ConnectionLevel.offline,
      label: 'Pano çevrimdışı',
      detail: 'Bulut • pano çevrimdışı',
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
