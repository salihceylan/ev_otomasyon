import 'cloud_models.dart' show shutterBaseName;
import 'install_template_models.dart';
import 'json_utils.dart';
import 'safety_models.dart';

export 'install_template_models.dart' show TemplateRef;
export 'safety_models.dart';

/// Röle (cihaz durum JSON'unda `relays[]`). **Numaralar 1 tabanlıdır** (CONTRACTS §0).
class RelayItem {
  const RelayItem({
    required this.id,
    required this.name,
    required this.type,
    required this.state,
    this.runtimeSec = 0,
    this.typeKnown = true,
    this.actuator,
  });

  /// 1 tabanlı röle numarası.
  final int id;
  final String name;

  /// 0: Lamba/Priz, 1: Panjur Yukarı, 2: Panjur Aşağı, 3: Darbe/Tetik.
  final int type;
  final bool state;
  final int runtimeSec;

  /// Cihaz `type` alanını bildirdi mi (bildirmediyse 0 varsayıldı).
  final bool typeKnown;

  /// `state v:3` röle satırındaki `act` (K1): bu röle bir güvenlik eylemcisini (vana, siren, fan, genel) sürer.
  /// `type` aynı kalır (eski istemci uyumu); eylemci rölesi lamba kartı DEĞİLDİR. `null` = eylemci değil.
  final ActuatorKind? actuator;

  bool get isActuator => actuator != null;

  bool get isLight => type == 0;
  bool get isShutterUp => type == 1;
  bool get isShutterDown => type == 2;
  bool get isImpulse => type == 3;
  bool get isShutterRelay => isShutterUp || isShutterDown;

  /// Ana kart (1..8) dışındaki röle (RS485 genişleme modülü).
  bool get isExt => id > 8;

  /// `type`: sayı (0..3) veya MQTT v2 metni (`light`, `shutter_up`, `shutter_down`, `impulse` ...).
  static int? _parseType(Object? raw, int id) {
    final number = asInt(raw);
    if (number != null && raw is! String) return (number >= 0 && number <= 3) ? number : null;
    final text = asNonEmptyString(raw)?.toLowerCase();
    if (text == null) return null;
    final asNumber = int.tryParse(text);
    if (asNumber != null) return (asNumber >= 0 && asNumber <= 3) ? asNumber : null;
    switch (text) {
      case 'light':
      case 'lamp':
      case 'plug':
      case 'socket':
      case 'relay':
        return 0;
      case 'shutter_up':
      case 'shutter-up':
      case 'up':
        return 1;
      case 'shutter_down':
      case 'shutter-down':
      case 'down':
        return 2;
      case 'shutter':
        return id.isOdd ? 1 : 2; // yön belirtilmemişse çiftin tek/çift rölesine göre
      case 'impulse':
      case 'pulse':
      case 'trigger':
        return 3;
    }
    return null;
  }

  factory RelayItem.fromJson(Map<String, dynamic> json) {
    final id = asInt(json['id']);
    if (id == null || id < 1 || id > 64) throw const FormatException('Geçersiz röle numarası');
    final type = _parseType(json['type'], id);
    return RelayItem(
      id: id,
      name: asNonEmptyString(json['name']) ?? 'Röle $id',
      type: type ?? 0,
      typeKnown: type != null,
      state: asBool(json['state']) ?? false,
      runtimeSec: clampInt(asInt(json['runtime_sec']) ?? 0, 0, 300),
      actuator: ActuatorKind.tryParse(json['act']),
    );
  }

  RelayItem copyWith({bool? state}) => RelayItem(
        id: id,
        name: name,
        type: type,
        state: state ?? this.state,
        runtimeSec: runtimeSec,
        typeKnown: typeKnown,
        actuator: actuator,
      );
}

/// Panjur. **`pair` 1 tabanlıdır**; `pair N` = röle `2N-1` (YUKARI) ve `2N` (AŞAĞI).
class ShutterItem {
  const ShutterItem({
    required this.pair,
    required this.name,
    this.isMoving = false,
    this.direction = 0,
    this.pos = 0,
    this.target,
    this.runtimeSec = 20,
  });

  /// 1 tabanlı panjur numarası.
  final int pair;
  final String name;
  final bool isMoving;

  /// 0: Durdu, 1: Yukarı, 2: Aşağı.
  final int direction;

  /// 0..100 (0 = tam kapalı, 100 = tam açık).
  final int pos;

  /// Hedef konum (0..100); hedef yoksa `null` (cihaz `255` bildirir).
  final int? target;

  /// Motor süresi (1..300 sn).
  final int runtimeSec;

  /// RS485 genişleme modülündeki panjur (ana kartın 4 panjur çiftinden sonrası).
  bool get isExt => pair > 4;

  /// YUKARI / AŞAĞI röle numaraları.
  int get upRelay => 2 * pair - 1;
  int get downRelay => 2 * pair;

  factory ShutterItem.fromJson(
    Map<String, dynamic> json, {
    required int pair,
    required String name,
    int runtimeSec = 20,
  }) {
    final rawDir = asInt(json['dir'] ?? json['direction']) ?? 0;
    // Aralık dışı yön (bozuk yük) "aşağı"ya kırpılmaz: bilinmeyen = durdu.
    final dir = (rawDir >= 0 && rawDir <= 2) ? rawDir : 0;
    final moving = asBool(json['moving'] ?? json['is_moving']) ?? (dir != 0);
    final targetRaw = asInt(json['target'] ?? json['target_position']);
    return ShutterItem(
      pair: pair,
      name: name,
      isMoving: moving,
      direction: dir,
      pos: clampInt(asInt(json['pos'] ?? json['current_position'] ?? json['percent']) ?? 0, 0, 100),
      target: (targetRaw != null && targetRaw >= 0 && targetRaw <= 100) ? targetRaw : null,
      runtimeSec: runtimeSec,
    );
  }

  ShutterItem copyWith({bool? isMoving, int? direction, int? pos, int? target, bool clearTarget = false}) =>
      ShutterItem(
        pair: pair,
        name: name,
        isMoving: isMoving ?? this.isMoving,
        direction: direction ?? this.direction,
        pos: pos ?? this.pos,
        target: clearTarget ? null : (target ?? this.target),
        runtimeSec: runtimeSec,
      );
}

/// Dijital giriş (duvar butonu).
class DIItem {
  const DIItem({
    required this.id,
    required this.name,
    required this.state,
    this.targetRelay = 0,
    this.mode = 0,
  });

  /// 1 tabanlı giriş numarası.
  final int id;
  final String name;
  final bool state;
  final int targetRelay;
  final int mode;

  bool get isExt => id > 8;

  factory DIItem.fromJson(Map<String, dynamic> json) {
    final id = asInt(json['id']);
    if (id == null || id < 1 || id > 64) throw const FormatException('Geçersiz giriş numarası');
    return DIItem(
      id: id,
      name: asNonEmptyString(json['name']) ?? 'Giriş $id',
      state: asBool(json['state']) ?? false,
      targetRelay: asInt(json['target_relay']) ?? 0,
      mode: asInt(json['mode']) ?? 0,
    );
  }
}

/// Panonun Wi-Fi bağlanma denemesi durumu (`GET /api/status` -> `wifi_connect_state`).
/// **Başarı yalnızca [success]**: `POST /api/wifi/connect` `200 connecting` yanıtı bağlandı demek değildir.
enum WifiConnectState {
  idle('idle'),
  connecting('connecting'),
  success('success'),
  failed('failed'),

  /// Cihaz alanı bildirmedi / tanınmayan değer.
  unknown('unknown');

  const WifiConnectState(this.wire);

  final String wire;

  static WifiConnectState parse(Object? raw) {
    switch (asNonEmptyString(raw)?.toLowerCase()) {
      case 'idle':
        return WifiConnectState.idle;
      case 'connecting':
        return WifiConnectState.connecting;
      case 'success':
        return WifiConnectState.success;
      case 'failed':
        return WifiConnectState.failed;
    }
    return WifiConnectState.unknown;
  }

  /// Deneme sonuçlandı mı (başarı veya hata).
  bool get isFinal => this == success || this == failed;
}

/// `GET /api/wifi/scan` -> `networks[]` öğesi: `{ ssid, rssi, enc }` (`enc` = şifreli ağ mı).
class WifiNetwork {
  const WifiNetwork({required this.ssid, required this.rssi, required this.secured});

  /// Ağ adı (geçersiz UTF-8 baytları `�` olarak çözülür; 1..32 bayt).
  final String ssid;

  /// Sinyal gücü (dBm; büyük = güçlü).
  final int rssi;

  /// Şifreli (WPA/WEP...) ağ; `false` = açık ağ.
  final bool secured;

  /// SSID'si olmayan (gizli) ağlar listelenmez: `FormatException`.
  factory WifiNetwork.fromJson(Map<String, dynamic> json) {
    final ssid = asString(json['ssid']);
    if (ssid == null || ssid.isEmpty) throw const FormatException('Gizli/boş ağ adı');
    return WifiNetwork(
      ssid: ssid,
      rssi: asInt(json['rssi']) ?? -100,
      secured: asBool(json['enc'] ?? json['secured'] ?? json['encrypted']) ?? true,
    );
  }
}

/// Cihazın tam anlık durumu: LAN `GET /api/status` yanıtı **ve** MQTT `ev/{t}/state` yükü
/// (CONTRACTS §2.4) aynı modele çözülür.
///
/// LAN `status` notları (CONTRACTS §3b): **anahtarsız** istek yalnızca kısıtlı özet döndürür
/// (`device, name, fw, provisioned, wifi_connected`; [restricted] = `true`); `uid` alanı yoktur,
/// cihaz kimliği `device` alanındadır; `relays[].runtime_sec` yoktur (`/api/config`'te).
class DeviceStatus {
  const DeviceStatus({
    this.deviceName = 'Akıllı Ev Pano',
    this.ip = '',
    this.wifiRssi = 0,
    this.uptimeSec = 0,
    this.wifiConnected = false,
    this.wifiStaSsid = '',
    this.wifiStaIp = '',
    this.wifiStaRssi = 0,
    this.wifiLastReason = 0,
    this.relays = const [],
    this.dis = const [],
    this.shutters = const [],
    this.childLock = false,
    this.childLockKnown = true,
    this.uid,
    this.firmware,
    this.seq,
    this.lastId,
    this.provisioned,
    this.restricted = false,
    this.wifiConnectState = WifiConnectState.unknown,
    this.wifiConnectReason = 0,
    this.wifiApActive,
    this.wifiApSsid = '',
    this.wifiApIp = '',
    this.timeSynced,
    this.mqttConfigured,
    this.mqttConnected,
    this.totalRelays,
    this.totalDis,
    this.extModuleEnabled,
    this.extModuleResponding,
    this.stateVersion,
    this.safety = SafetyState.unsupported,
    this.lastRej,
    this.template,
    this.ethConnected,
    this.ethIp = '',
    this.netIf,
    this.lkFp,
  });

  final String deviceName;
  final String ip;
  final int wifiRssi;
  final int uptimeSec;
  final bool wifiConnected;
  final String wifiStaSsid;
  final String wifiStaIp;
  final int wifiStaRssi;

  /// Panonun son Wi-Fi kopma nedeni (ESP-IDF wifi_err_reason_t). 0 = hata yok.
  final int wifiLastReason;
  final List<RelayItem> relays;
  final List<DIItem> dis;

  /// **Gerçek** panjurlar (yapılandırılmamış "hayalet" çiftler süzülmüştür).
  final List<ShutterItem> shutters;
  final bool childLock;

  /// Yük `child_lock` alanını taşıdı mı (taşımadıysa [childLock] varsayılan `false`tur ve
  /// gerçek durum sayılmamalıdır).
  final bool childLockKnown;

  /// Cihaz kimliği (`uid`, MQTT state'te var).
  final String? uid;

  /// Yazılım sürümü (`fw`).
  final String? firmware;

  /// Cihazın artan durum sayacı (`seq`).
  final int? seq;

  /// Son uygulanan komutun kimliği (`last_id`): komut onayı için.
  final String? lastId;

  /// Kısıtlı (anahtarsız) `GET /api/status` özeti: cihaz sağlandı mı.
  final bool? provisioned;

  /// Yanıt kısıtlı özettir (anahtar gönderilmedi): röle/panjur/giriş listesi **yoktur**; cihaz
  /// kontrol edilemez. Arayüz "anahtar gerekli" göstermelidir (boş cihaz sanılmamalı).
  final bool restricted;

  /// Son Wi-Fi bağlanma denemesinin durumu ve (başarısızsa) `wifi_err_reason_t` nedeni (0 = bilinmiyor/zaman aşımı).
  final WifiConnectState wifiConnectState;
  final int wifiConnectReason;

  /// Kurulum/kurtarma AP'si açık mı ve kimliği.
  final bool? wifiApActive;
  final String wifiApSsid;
  final String wifiApIp;

  /// Panoda saat senkronlandı mı (TLS için gerekir).
  final bool? timeSynced;

  /// Bulut (MQTT) kimliği yazıldı mı / bulut bağlantısı kuruldu mu (kurulum doğrulaması).
  final bool? mqttConfigured;
  final bool? mqttConnected;

  /// Yapılandırılan toplam röle / dijital giriş sayısı.
  final int? totalRelays;
  final int? totalDis;

  /// RS485 genişleme modülü etkin mi / yanıt veriyor mu.
  final bool? extModuleEnabled;
  final bool? extModuleResponding;

  /// `state.v` (MQTT; LAN yanıtında yok). Sözleşme: tüketiciler `v >= 2` denetler, `v == 2` değil [O8].
  final int? stateVersion;

  /// Güvenlik modülü durumu (`v:3`: `caps`, `sensors`, `actuators`, `safety`). Eski panoda [SafetyState.unsupported].
  final SafetyState safety;

  /// Son reddedilen komut (`last_rej`). Komut hattı bunu görünce bekleyen komutu BEKLEMEDEN geri alır.
  final SafetyRejection? lastRej;

  /// Panoda yüklü kurulum şablonu (`tpl: {id, ver}`, firmware v1.3.0+; yoksa `null`).
  final TemplateRef? template;

  /// Ethernet (W5500) bağlı mı ve IP'si (firmware v1.3.0+; eski panoda `null` / boş).
  final bool? ethConnected;
  final String ethIp;

  /// Etkin ağ arayüzü: `wifi` | `eth` | `none` (firmware v1.3.0+; eski panoda `null`).
  final String? netIf;

  /// Yerel anahtar parmak izi (`lk_fp`; firmware 1.3.1, provizyonlu tam durumda; CONTRACTS sözleşme 1). Yalnız 8 küçük
  /// hex ise okunur; uygulama HMAC hesaplamaz, sunucunun `local_key_fp`'siyle karşılaştırır (servis_kurulum-1).
  final String? lkFp;

  /// Pano kablolu Ethernet ile ağa bağlı (firmware v1.3.0+; eski panoda her zaman `false`).
  bool get onEthernet => ethConnected == true || netIf == 'eth';

  /// Pano ev ağında: Wi-Fi **ya da** Ethernet. Ethernet bilgisi olmayan (eski) panoda [wifiConnected] ile aynıdır.
  bool get onHomeNetwork => wifiConnected || onEthernet;

  RelayItem? relayById(int id) {
    for (final r in relays) {
      if (r.id == id) return r;
    }
    return null;
  }

  ShutterItem? shutterByPair(int pair) {
    for (final s in shutters) {
      if (s.pair == pair) return s;
    }
    return null;
  }

  /// Panjur çiftine ait röle numaraları (lamba kartı olarak gösterilmez).
  Set<int> get shutterRelayIds => <int>{
        for (final s in shutters) ...[s.upRelay, s.downRelay],
      };

  /// Aydınlatma / priz / darbe röleleri (panjur röleleri ve güvenlik eylemcisi röleleri hariç: vana lamba kartına
  /// düşmez, "tüm lambalar" sayaçları onu saymaz [Y3]).
  List<RelayItem> get controllableRelays {
    final skip = shutterRelayIds;
    return relays
        .where((r) => (r.isLight || r.isImpulse) && !r.isActuator && !skip.contains(r.id))
        .toList(growable: false);
  }

  /// [filterPhantomShutters]: LAN `status` yanıtında bellenim her röle çifti için panjur kaydı
  /// üretebilir ("hayalet panjur"); `true` iken bunlar süzülür. MQTT `state` yükünde bellenim
  /// yalnızca gerçek panjurları bildirir (CONTRACTS §2.4): orada `false` kullanılır ve cihaz
  /// bildirimine olduğu gibi güvenilir.
  factory DeviceStatus.fromJson(Map<String, dynamic> json, {bool filterPhantomShutters = true}) {
    final relays = parseList(json['relays'], RelayItem.fromJson, label: 'Relay');
    final dis = parseList(json['dis'], DIItem.fromJson, label: 'DI');
    final shutters = _parseShutters(json['shutters'], relays, filterPhantoms: filterPhantomShutters);

    final seq = asInt(json['seq']);
    // LAN status'ta cihaz kimliği `device` alanındadır (`uid` yok); MQTT state'te `uid` vardır.
    final deviceField = asNonEmptyString(json['device']);
    final deviceIsUid = deviceField != null && _uidShape.hasMatch(deviceField.toUpperCase());
    final restricted = !json.containsKey('relays') &&
        !json.containsKey('shutters') &&
        !json.containsKey('dis') &&
        json.containsKey('provisioned');
    return DeviceStatus(
      deviceName: asNonEmptyString(json['device_name'] ?? json['name']) ??
          (deviceIsUid ? null : deviceField) ??
          'Akıllı Ev Pano',
      ip: asString(json['ip']) ?? '',
      wifiRssi: asInt(json['wifi_rssi']) ?? 0,
      uptimeSec: asInt(json['uptime_sec'] ?? json['uptime']) ?? 0,
      wifiConnected: asBool(json['wifi_connected']) ?? false,
      wifiStaSsid: asString(json['wifi_sta_ssid']) ?? '',
      wifiStaIp: asString(json['wifi_sta_ip']) ?? '',
      wifiStaRssi: asInt(json['wifi_sta_rssi']) ?? 0,
      wifiLastReason: asInt(json['wifi_last_reason']) ?? 0,
      relays: relays,
      dis: dis,
      shutters: shutters,
      childLock: asBool(json['child_lock']) ?? false,
      childLockKnown: asBool(json['child_lock']) != null,
      uid: asNonEmptyString(json['uid']) ?? (deviceIsUid ? deviceField.toUpperCase() : null),
      firmware: asNonEmptyString(json['fw'] ?? json['firmware']),
      seq: seq,
      lastId: asNonEmptyString(json['last_id']),
      provisioned: asBool(json['provisioned']),
      restricted: restricted,
      wifiConnectState: WifiConnectState.parse(json['wifi_connect_state']),
      wifiConnectReason: asInt(json['wifi_connect_reason']) ?? 0,
      wifiApActive: asBool(json['wifi_ap_active']),
      wifiApSsid: asString(json['wifi_ap_ssid']) ?? '',
      wifiApIp: asString(json['wifi_ap_ip']) ?? '',
      timeSynced: asBool(json['time_synced']),
      mqttConfigured: asBool(json['mqtt_configured']),
      mqttConnected: asBool(json['mqtt_connected']),
      totalRelays: asInt(json['total_relays']),
      totalDis: asInt(json['total_dis']),
      extModuleEnabled: asBool(json['ext_module_enabled']),
      extModuleResponding: asBool(json['ext_module_responding']),
      stateVersion: asInt(json['v']),
      safety: SafetyState.fromStateJson(
        json,
        uid: asNonEmptyString(json['uid'])?.toUpperCase() ?? (deviceIsUid ? deviceField.toUpperCase() : null),
      ),
      lastRej: SafetyRejection.fromJson(json['last_rej']),
      template: TemplateRef.tryParse(json['tpl']),
      ethConnected: asBool(json['eth_connected']),
      ethIp: asString(json['eth_ip']) ?? '',
      netIf: asNonEmptyString(json['net_if']),
      lkFp: _parseLkFp(json['lk_fp']),
    );
  }

  static final RegExp _uidShape = RegExp(r'^AHBU-[A-Z0-9-]{3,32}$');
  static final RegExp _lkFpShape = RegExp(r'^[0-9a-f]{8}$');

  static String? _parseLkFp(Object? raw) {
    final s = asNonEmptyString(raw);
    return s != null && _lkFpShape.hasMatch(s) ? s : null;
  }

  /// `shutters[]` -> gerçek panjurlar.
  ///
  /// * `pair` **1 tabanlı** kabul edilir (CONTRACTS). Dizide `pair == 0` görülürse eski (0 tabanlı)
  ///   bellenim kabul edilip tümü +1 kaydırılır; `pair` yoksa sıra numarası kullanılır.
  /// * **Hayalet panjur filtresi:** her röle çifti için bellenim bir panjur kaydı üretebilir.
  ///   Çiftin iki rölesi de durum listesinde varsa ve ikisi de **bilinen, panjur olmayan** bir
  ///   tipteyse (lamba/darbe) çift gerçek panjur değildir ve atılır. Tip bilgisi yoksa veya
  ///   röle listede değilse panjur korunur (gerçek bir panjuru gizlemek, hayaletten kötüdür).
  static List<ShutterItem> _parseShutters(Object? raw, List<RelayItem> relays, {bool filterPhantoms = true}) {
    final items = (asList(raw) ?? const <dynamic>[]).map(asMap).whereType<Map<String, dynamic>>().toList();
    final zeroBased = items.any((m) => asInt(m['pair']) == 0);
    final seen = <int>{};
    final out = <ShutterItem>[];
    for (var i = 0; i < items.length; i++) {
      final m = items[i];
      var pair = asInt(m['pair']);
      if (pair == null) {
        pair = i + 1;
      } else if (zeroBased) {
        pair += 1;
      }
      if (pair < 1 || pair > 32 || !seen.add(pair)) continue;
      // Cihaz çiftin gerçek panjur olmadığını AÇIKÇA bildirirse (LAN: `is_shutter:false`) atılır.
      if (asBool(m['is_shutter']) == false) continue;
      if (filterPhantoms && _isPhantomPair(pair, relays)) continue;

      RelayItem? up;
      for (final r in relays) {
        if (r.id == 2 * pair - 1) up = r;
      }
      final name = up == null ? 'Panjur $pair' : shutterBaseName(up.name, fallback: 'Panjur $pair');
      final reported = asInt(m['runtime_sec']);
      final fromRelay = (up != null && up.runtimeSec > 0) ? up.runtimeSec : null;
      final runtime = clampInt(
        (reported != null && reported > 0) ? reported : (fromRelay ?? 20),
        1,
        300,
      );
      out.add(ShutterItem.fromJson(m, pair: pair, name: name, runtimeSec: runtime));
    }
    return out;
  }

  static bool _isPhantomPair(int pair, List<RelayItem> relays) {
    RelayItem? up;
    RelayItem? down;
    for (final r in relays) {
      if (r.id == 2 * pair - 1) up = r;
      if (r.id == 2 * pair) down = r;
    }
    if (up == null || down == null) return false;
    if (!up.typeKnown || !down.typeKnown) return false;
    return !up.isShutterRelay && !down.isShutterRelay;
  }

  /// Arayüzü etkileyen alanlar aynı mı? (Yalnızca zamanla değişen `uptime`/RSSI hariç tutulur;
  /// doğrudan modda her yoklamada gereksiz yeniden çizimi önlemek için kullanılır.)
  bool sameAs(DeviceStatus other) {
    if (deviceName != other.deviceName ||
        ip != other.ip ||
        wifiConnected != other.wifiConnected ||
        wifiStaSsid != other.wifiStaSsid ||
        wifiStaIp != other.wifiStaIp ||
        wifiLastReason != other.wifiLastReason ||
        childLock != other.childLock ||
        childLockKnown != other.childLockKnown ||
        uid != other.uid ||
        firmware != other.firmware ||
        lastId != other.lastId ||
        provisioned != other.provisioned ||
        restricted != other.restricted ||
        wifiConnectState != other.wifiConnectState ||
        wifiConnectReason != other.wifiConnectReason ||
        wifiApActive != other.wifiApActive ||
        timeSynced != other.timeSynced ||
        mqttConfigured != other.mqttConfigured ||
        mqttConnected != other.mqttConnected ||
        stateVersion != other.stateVersion ||
        lastRej != other.lastRej ||
        template != other.template ||
        ethConnected != other.ethConnected ||
        ethIp != other.ethIp ||
        netIf != other.netIf ||
        safety != other.safety ||
        relays.length != other.relays.length ||
        dis.length != other.dis.length ||
        shutters.length != other.shutters.length) {
      return false;
    }
    for (var i = 0; i < relays.length; i++) {
      final a = relays[i];
      final b = other.relays[i];
      if (a.id != b.id || a.name != b.name || a.type != b.type || a.state != b.state || a.actuator != b.actuator) {
        return false;
      }
    }
    for (var i = 0; i < dis.length; i++) {
      final a = dis[i];
      final b = other.dis[i];
      if (a.id != b.id || a.state != b.state || a.name != b.name) return false;
    }
    for (var i = 0; i < shutters.length; i++) {
      final a = shutters[i];
      final b = other.shutters[i];
      if (a.pair != b.pair ||
          a.name != b.name ||
          a.pos != b.pos ||
          a.isMoving != b.isMoving ||
          a.direction != b.direction ||
          a.target != b.target) {
        return false;
      }
    }
    return true;
  }

  DeviceStatus copyWith({
    List<RelayItem>? relays,
    List<ShutterItem>? shutters,
    List<DIItem>? dis,
    bool? childLock,
    bool? wifiConnected,
  }) {
    return DeviceStatus(
      deviceName: deviceName,
      ip: ip,
      wifiRssi: wifiRssi,
      uptimeSec: uptimeSec,
      wifiConnected: wifiConnected ?? this.wifiConnected,
      wifiStaSsid: wifiStaSsid,
      wifiStaIp: wifiStaIp,
      wifiStaRssi: wifiStaRssi,
      wifiLastReason: wifiLastReason,
      relays: relays ?? this.relays,
      dis: dis ?? this.dis,
      shutters: shutters ?? this.shutters,
      childLock: childLock ?? this.childLock,
      childLockKnown: childLock != null ? true : childLockKnown,
      uid: uid,
      firmware: firmware,
      seq: seq,
      lastId: lastId,
      provisioned: provisioned,
      restricted: restricted,
      wifiConnectState: wifiConnectState,
      wifiConnectReason: wifiConnectReason,
      wifiApActive: wifiApActive,
      wifiApSsid: wifiApSsid,
      wifiApIp: wifiApIp,
      timeSynced: timeSynced,
      mqttConfigured: mqttConfigured,
      mqttConnected: mqttConnected,
      totalRelays: totalRelays,
      totalDis: totalDis,
      extModuleEnabled: extModuleEnabled,
      extModuleResponding: extModuleResponding,
      stateVersion: stateVersion,
      safety: safety,
      lastRej: lastRej,
      lkFp: lkFp,
      template: template,
      ethConnected: ethConnected,
      ethIp: ethIp,
      netIf: netIf,
    );
  }
}
