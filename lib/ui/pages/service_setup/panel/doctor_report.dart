import 'package:flutter/foundation.dart';

import '../../../../models/json_utils.dart';

/// Bir tanı katmanının seviyesi. **Eksik veri `unknown`dur**: sunucu bir alanı göndermediyse
/// "çalışıyor" ya da "20 ms" gibi bir değer uydurulmaz.
enum DoctorLevel { ok, warning, error, unknown, notApplicable }

/// Sistem doktoru yanıtındaki tek pano satırı.
@immutable
class DoctorDevice {
  const DoctorDevice({
    required this.deviceUuid,
    this.name,
    this.online,
    this.level,
    this.secondsSinceSeen,
    this.firmware,
  });

  final String deviceUuid;
  final String? name;
  final bool? online;

  /// `ok | warning | error` (sunucu seviyesi); yoksa `null`.
  final String? level;
  final int? secondsSinceSeen;
  final String? firmware;

  static DoctorDevice? tryParse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final uid = asNonEmptyString(map['device_uuid']);
    if (uid == null) return null;
    return DoctorDevice(
      deviceUuid: uid,
      name: asNonEmptyString(map['name']),
      online: asBool(map['online']),
      level: asNonEmptyString(map['level'])?.toLowerCase(),
      secondsSinceSeen: asInt(map['seconds_since_last_seen']),
      firmware: asNonEmptyString(map['firmware_version']),
    );
  }
}

/// `GET /devices/system-diagnostic/:homeId` yanıtının tipli, **eksik veriye dayanıklı** özeti.
///
/// Yanıt alanları: `cloud{status OK|DEGRADED, latency_ms, db_connected, mqtt_bridge_connected}`,
/// `home_network{status OK|WARNING|OFFLINE|UNCLAIMED, device_ip, seconds_since_last_seen}`,
/// `hardware_power{status OK|SUSPECTED_OFFLINE_OR_POWER_OUTAGE|UNCLAIMED, is_online}`, `devices[]`,
/// `diagnosis_level|title|summary`, `action_recommendation`.
@immutable
class DoctorReport {
  const DoctorReport({
    this.cloudStatus,
    this.latencyMs,
    this.dbConnected,
    this.bridgeConnected,
    this.networkStatus,
    this.deviceIp,
    this.secondsSinceSeen,
    this.powerStatus,
    this.powerOnline,
    this.devices = const <DoctorDevice>[],
    this.endpointCount,
    this.level,
    this.title,
    this.summary,
    this.action,
  });

  final String? cloudStatus;
  final int? latencyMs;
  final bool? dbConnected;
  final bool? bridgeConnected;

  final String? networkStatus;
  final String? deviceIp;
  final int? secondsSinceSeen;

  final String? powerStatus;
  final bool? powerOnline;

  final List<DoctorDevice> devices;
  final int? endpointCount;

  /// `ok | warning | error` (sunucu genel seviyesi); yoksa `null`.
  final String? level;
  final String? title;
  final String? summary;
  final String? action;

  factory DoctorReport.parse(Map<String, dynamic> json) {
    final cloud = asMap(json['cloud']);
    final network = asMap(json['home_network']);
    final power = asMap(json['hardware_power']);
    final level = asNonEmptyString(json['diagnosis_level'])?.toLowerCase();
    return DoctorReport(
      cloudStatus: asNonEmptyString(cloud?['status'])?.toUpperCase(),
      latencyMs: asInt(cloud?['latency_ms']),
      dbConnected: asBool(cloud?['db_connected']),
      bridgeConnected: asBool(cloud?['mqtt_bridge_connected']),
      networkStatus: asNonEmptyString(network?['status'])?.toUpperCase(),
      deviceIp: asNonEmptyString(network?['device_ip']),
      secondsSinceSeen: asInt(network?['seconds_since_last_seen']),
      powerStatus: asNonEmptyString(power?['status'])?.toUpperCase(),
      powerOnline: asBool(power?['is_online']),
      devices: <DoctorDevice>[
        for (final item in asList(json['devices']) ?? const <dynamic>[]) ?DoctorDevice.tryParse(item),
      ],
      endpointCount: asInt(json['endpoint_count']),
      level: const <String>{'ok', 'warning', 'error'}.contains(level) ? level : null,
      title: asNonEmptyString(json['diagnosis_title']),
      summary: asNonEmptyString(json['diagnosis_summary']),
      action: asNonEmptyString(json['action_recommendation']),
    );
  }

  /// Bulut katmanı seviyesi.
  DoctorLevel get cloudLevel {
    switch (cloudStatus) {
      case null:
        return DoctorLevel.unknown;
      case 'OK':
        return DoctorLevel.ok;
      case 'DEGRADED':
        return DoctorLevel.warning;
      default:
        return DoctorLevel.error;
    }
  }

  /// Ev ağı katmanı seviyesi.
  DoctorLevel get networkLevel {
    switch (networkStatus) {
      case null:
      case 'UNKNOWN':
        return DoctorLevel.unknown;
      case 'OK':
        return DoctorLevel.ok;
      case 'WARNING':
        return DoctorLevel.warning;
      case 'UNCLAIMED':
        return DoctorLevel.notApplicable;
      default:
        return DoctorLevel.error;
    }
  }

  /// Pano gücü katmanı seviyesi.
  DoctorLevel get powerLevel {
    switch (powerStatus) {
      case null:
      case 'UNKNOWN':
        return DoctorLevel.unknown;
      case 'OK':
        return DoctorLevel.ok;
      case 'UNCLAIMED':
        return DoctorLevel.notApplicable;
      default:
        return DoctorLevel.error;
    }
  }

  /// Wi-Fi kurtarma önerilir: ev ağı kapalı / bilinmiyor / hatalı (ya da bilgi hiç gelmedi).
  bool get suggestsWifiRecovery {
    final level = networkLevel;
    return level == DoctorLevel.error || level == DoctorLevel.unknown;
  }

  /// Sunucu hiçbir tanı alanı göndermedi.
  bool get isEmpty =>
      cloudStatus == null && networkStatus == null && powerStatus == null && devices.isEmpty && title == null && summary == null;

  /// "3 dk önce" gibi görülme metni; veri yoksa `null`.
  static String? seenText(int? seconds) {
    if (seconds == null) return null;
    if (seconds < 60) return '$seconds sn önce';
    if (seconds < 3600) return '${seconds ~/ 60} dk önce';
    if (seconds < 86400) return '${seconds ~/ 3600} sa önce';
    return '${seconds ~/ 86400} gün önce';
  }
}
