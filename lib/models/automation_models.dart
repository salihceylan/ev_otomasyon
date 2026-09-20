class RelayItem {
  final int id;
  final String name;
  final int type; // 0: Lamba, 1: Panjur Yukari, 2: Panjur Asagi, 3: Darbe/Tetik
  final bool state;
  final int runtimeSec;

  RelayItem({
    required this.id,
    required this.name,
    required this.type,
    required this.state,
    this.runtimeSec = 0,
  });

  bool get isLight => type == 0;
  bool get isShutterUp => type == 1;
  bool get isShutterDown => type == 2;
  bool get isImpulse => type == 3;
  bool get isExt => id > 8;

  factory RelayItem.fromJson(Map<String, dynamic> json) {
    return RelayItem(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 1,
      name: json['name'] ?? 'Röle',
      type: json['type'] is int ? json['type'] : int.tryParse(json['type'].toString()) ?? 0,
      state: json['state'] == true || json['state'] == 1,
      runtimeSec: json['runtime_sec'] is int ? json['runtime_sec'] : int.tryParse(json['runtime_sec']?.toString() ?? '0') ?? 0,
    );
  }
}

class ShutterItem {
  final int pairIndex;
  final String name;
  final bool isMoving;
  final int direction; // 0: Durdu, 1: Yukari, 2: Asagi
  final int runtimeSec;

  ShutterItem({
    required this.pairIndex,
    required this.name,
    required this.isMoving,
    required this.direction,
    this.runtimeSec = 20,
  });

  bool get isExt => pairIndex >= 4;

  factory ShutterItem.fromJson(int pairIndex, Map<String, dynamic> json, String calculatedName) {
    return ShutterItem(
      pairIndex: pairIndex,
      name: calculatedName,
      isMoving: json['is_moving'] == true,
      direction: json['dir'] is int ? json['dir'] : int.tryParse(json['dir'].toString()) ?? 0,
    );
  }
}

class DIItem {
  final int id;
  final String name;
  final bool state;
  final int targetRelay;
  final int mode;

  DIItem({
    required this.id,
    required this.name,
    required this.state,
    this.targetRelay = 0,
    this.mode = 0,
  });

  bool get isExt => id > 8;

  factory DIItem.fromJson(Map<String, dynamic> json) {
    return DIItem(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 1,
      name: json['name'] ?? 'Giriş',
      state: json['state'] == true || json['state'] == 1,
      targetRelay: json['target_relay'] is int ? json['target_relay'] : int.tryParse(json['target_relay']?.toString() ?? '0') ?? 0,
      mode: json['mode'] is int ? json['mode'] : int.tryParse(json['mode']?.toString() ?? '0') ?? 0,
    );
  }
}

class DeviceStatus {
  final String deviceName;
  final String ip;
  final int wifiRssi;
  final int uptimeSec;
  final bool wifiConnected;
  final String wifiStaSsid;
  final String wifiStaIp;
  final int wifiStaRssi;
  final List<RelayItem> relays;
  final List<DIItem> dis;
  final List<ShutterItem> shutters;

  DeviceStatus({
    required this.deviceName,
    required this.ip,
    required this.wifiRssi,
    required this.uptimeSec,
    required this.wifiConnected,
    required this.wifiStaSsid,
    required this.wifiStaIp,
    required this.wifiStaRssi,
    required this.relays,
    required this.dis,
    required this.shutters,
  });

  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    final rawRelays = (json['relays'] as List<dynamic>?) ?? [];
    final parsedRelays = rawRelays.map((r) => RelayItem.fromJson(r as Map<String, dynamic>)).toList();

    final rawDis = (json['dis'] as List<dynamic>?) ?? [];
    final parsedDis = rawDis.map((d) => DIItem.fromJson(d as Map<String, dynamic>)).toList();

    final rawShutters = (json['shutters'] as List<dynamic>?) ?? [];
    final List<ShutterItem> parsedShutters = [];

    for (int p = 0; p < rawShutters.length; p++) {
      final r1 = p * 2;
      String sName = 'Panjur ${p + 1}';
      if (r1 < parsedRelays.length) {
        sName = parsedRelays[r1].name.replaceAll(RegExp(r'\s*\((?:Yukari|Asagi)\)', caseSensitive: false), '').trim();
        if (sName.isEmpty) sName = 'Panjur ${p + 1}';
      }
      parsedShutters.add(ShutterItem.fromJson(p, rawShutters[p] as Map<String, dynamic>, sName));
    }

    return DeviceStatus(
      deviceName: json['device_name'] ?? 'Akıllı Ev Pano',
      ip: json['ip'] ?? '192.168.4.1',
      wifiRssi: json['wifi_rssi'] ?? 0,
      uptimeSec: json['uptime_sec'] ?? 0,
      wifiConnected: json['wifi_connected'] == true,
      wifiStaSsid: json['wifi_sta_ssid'] ?? '',
      wifiStaIp: json['wifi_sta_ip'] ?? '',
      wifiStaRssi: json['wifi_sta_rssi'] ?? 0,
      relays: parsedRelays,
      dis: parsedDis,
      shutters: parsedShutters,
    );
  }
}
