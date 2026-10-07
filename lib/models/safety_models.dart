import 'package:flutter/foundation.dart';

import 'json_utils.dart';

// =============================================================================
// Güvenlik modülü (su baskını + vana) durum modeli — tasarım §3.2, §5.3.1
// =============================================================================
//
// Kaynak: panonun `state v:3` yükü (MQTT `ev/{t}/state`) ve LAN `GET /api/status` yanıtı (aynı JSON). `v:3`, `v:2`'nin
// katı üst kümesidir: yeni alanlar yoksa (eski pano) model [SafetyState.unsupported] olur ve güvenlik bölümü gizlenir.
//
// Kurallar:
// * `fromJson`/`fromStateJson` HİÇBİR ZAMAN fırlatmaz (`EndpointModel.fromJson` bilinmeyen türde fırlatır; bu sınıflar
//   o hatayı tekrarlamaz). Bilinmeyen tür `unknown` olur ve satır görünür kalır; kimliksiz/bozuk öğe atlanır.
// * Dizi uzunlukları kesilir: sensör 64, eylemci 16, bölge 4, alarm kaynağı 8.
// * Bütün sınıflar `==`/`hashCode` uygular: özdeş kalp atışı (~30 sn) arayüzü uyandırmaz (PF-04).
// * Sensör/eylemci ADLARI state'te yoktur [B12]: kimlik gösterilir; yapılandırma kopyası gelince [SafetyState.withNames].

/// Bölge durumu (`safety.zones[].st`).
enum ZoneStatus {
  normal,
  latched,

  /// VALVE_FAULT: vana geri bildirimi zaman aşımına uğradı (kilit de sürer).
  fault,
  test,
  unknown;

  static ZoneStatus parse(Object? raw) {
    switch (asNonEmptyString(raw)?.toLowerCase()) {
      case 'normal':
        return ZoneStatus.normal;
      case 'latched':
        return ZoneStatus.latched;
      case 'fault':
        return ZoneStatus.fault;
      case 'test':
        return ZoneStatus.test;
    }
    return ZoneStatus.unknown;
  }

  /// Kilitli alarm (susturulmuş olsa da sürer): `latched` ya da `fault`.
  bool get isAlarm => this == ZoneStatus.latched || this == ZoneStatus.fault;
}

/// Eylemci türü (K1): röleyle sürülen her cihaz.
enum ActuatorKind {
  valve('valve'),
  siren('siren'),
  fan('fan'),
  generic('generic'),
  unknown('unknown');

  const ActuatorKind(this.wire);

  final String wire;

  /// `null`/boş -> `null` (eylemci değil); tanınmayan metin -> [unknown] (yine eylemcidir: lamba kartına düşmez).
  static ActuatorKind? tryParse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    if (text == null) return null;
    for (final kind in ActuatorKind.values) {
      if (kind.wire == text) return kind;
    }
    return ActuatorKind.unknown;
  }
}

/// Vana konumu (`actuators[].pos`). `cmd*`: geri bildirim yok, yalnız komut edilen konum bilinir.
enum ValvePos {
  closed('closed'),
  closing('closing'),
  open('open'),
  opening('opening'),
  cmdClosed('cmd_closed'),
  cmdOpen('cmd_open'),

  /// Konum kaydı yok (7.2b karar 6): emniyet tarafında AÇIK kabul edilir; arayüz "konum bilinmiyor" gösterir.
  unknown('unknown');

  const ValvePos(this.wire);

  final String wire;

  static ValvePos parse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    for (final pos in ValvePos.values) {
      if (pos.wire == text) return pos;
    }
    return ValvePos.unknown;
  }
}

const int _maxSensors = 64;
const int _maxActuators = 16;
const int _maxZones = 4;
const int _maxSources = 8;

/// Sensör türleri; yerel kumanda rolleri (`alarm_ack`, `valve_close`, `gas_reset`) de `sensors[]` listesinde gelir
/// (`active` = ham basılı seviye; CONTRACTS §2.6). Kumanda rolü tehlike sensörü değildir.
const Set<String> _sensorKinds = <String>{
  'water',
  'gas',
  'smoke',
  'door',
  'window',
  'motion',
  'generic',
  'alarm_ack',
  'valve_close',
  'gas_reset',
  'arm_key',
};

/// Yerel kumanda rolleri (sensör listesinde, tehlike sensörü değil). `arm_key` anahtarlı alarm kontağıdır (F2.B.3).
const Set<String> kSafetyControlKinds = <String>{'alarm_ack', 'valve_close', 'gas_reset', 'arm_key'};

/// Hırsız alarmı sensör türleri (F2.B.1).
const Set<String> kIntrusionSensorKinds = <String>{'door', 'window', 'motion'};

/// Sensör bayrakları (`SensorConfig.flags`; CONTRACTS §2.6, F2.B.1).
const int kSensorFlagReact = 0x01;
const int kSensorFlagEntry = 0x08;
const int kSensorFlagAwayOnly = 0x10;

/// Yapılandırma kopyası yokken türün varsayılan bayrakları (F2.B.1: kapı giriş yolu; hareket yalnız dışarıda).
int defaultSensorFlags(String kind) {
  switch (kind) {
    case 'door':
      return kSensorFlagReact | kSensorFlagEntry;
    case 'motion':
      return kSensorFlagReact | kSensorFlagAwayOnly;
  }
  return kSensorFlagReact;
}

/// Alarm kipi (`state.safety.arm.mode`).
enum ArmMode {
  off('off'),
  home('home'),
  away('away'),
  unknown('unknown');

  const ArmMode(this.wire);

  final String wire;

  static ArmMode parse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    for (final m in ArmMode.values) {
      if (m != ArmMode.unknown && m.wire == text) return m;
    }
    return ArmMode.unknown;
  }

  bool get isArmed => this == ArmMode.home || this == ArmMode.away;
}

/// Alarm kipi durumu (`state.safety.arm.st`).
enum ArmStatus {
  idle('idle'),
  exit('exit'),
  entry('entry'),
  alarm('alarm'),
  unknown('unknown');

  const ArmStatus(this.wire);

  final String wire;

  static ArmStatus parse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    for (final s in ArmStatus.values) {
      if (s != ArmStatus.unknown && s.wire == text) return s;
    }
    return ArmStatus.unknown;
  }
}

/// Hırsız alarmı katmanının durumu (`state.safety.arm`; F2.B.7). Yalnız `SF_REACT`'li en az bir kapı/pencere/hareket
/// sensörü varsa pano yazar. Ayrıştırma fırlatmaz; bilinmeyen değer `unknown`.
@immutable
class ArmState {
  const ArmState({
    required this.mode,
    required this.st,
    this.ok = false,
    this.untilUp,
    this.aid,
    this.srcs = const <String>[],
  });

  final ArmMode mode;
  final ArmStatus st;

  /// `false`: güvenli kipte sensör tablosu yok; hırsız katmanı etkisiz.
  final bool ok;

  /// `exit`/`entry` gecikmesinin bittiği pano `uptime` saniyesi (kalan süre `untilUp - uptime`).
  final int? untilUp;

  /// `alarm`: `intrusion_alarm` olayının eid'si.
  final String? aid;

  /// `alarm`: tetikleyen sensör kimlikleri (≤ 8).
  final List<String> srcs;

  bool get isAlarm => st == ArmStatus.alarm;

  static ArmState? fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final aid = asNonEmptyString(map['aid']);
    return ArmState(
      mode: ArmMode.parse(map['mode']),
      st: ArmStatus.parse(map['st']),
      ok: asBool(map['ok']) == true && map['ok'] is bool,
      untilUp: asInt(map['until_up']),
      aid: (aid != null && aid.length <= 14) ? aid : null,
      srcs: List<String>.unmodifiable(<String>[
        for (final s in asList(map['srcs']) ?? const <dynamic>[])
          if (asNonEmptyString(s) != null && asNonEmptyString(s)!.length <= 8) asNonEmptyString(s)!,
      ].take(_maxSources)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ArmState &&
      other.mode == mode &&
      other.st == st &&
      other.ok == ok &&
      other.untilUp == untilUp &&
      other.aid == aid &&
      listEquals(other.srcs, srcs);

  @override
  int get hashCode => Object.hash(mode, st, ok, untilUp, aid, Object.hashAll(srcs));

  @override
  String toString() => 'ArmState(${mode.wire}, ${st.wire}, ok=$ok)';
}

/// Kimlik + kod üst sınırı (`last_rej {id ≤ 24, code ≤ 24}`).
const int _maxRejField = 24;

/// Son reddedilen komut (`state.last_rej`). Reddedilen komut `last_id`'yi değiştirmez; bu alanla ret ANINDA görülür.
@immutable
class SafetyRejection {
  const SafetyRejection({required this.id, required this.code});

  final String id;
  final String code;

  /// Kullanıcıya gösterilecek Türkçe metin.
  String get message => safetyRejectMessage(code);

  /// Kimliksiz, kodsuz ya da sınır dışı kayıt -> `null`.
  static SafetyRejection? fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final id = asNonEmptyString(map['id']);
    final code = asNonEmptyString(map['code'])?.toLowerCase();
    if (id == null || code == null || id.length > _maxRejField || code.length > _maxRejField) return null;
    return SafetyRejection(id: id, code: code);
  }

  @override
  bool operator ==(Object other) => other is SafetyRejection && other.id == id && other.code == code;

  @override
  int get hashCode => Object.hash(id, code);

  @override
  String toString() => 'SafetyRejection($id, $code)';
}

/// Firmware ret kodları (`last_rej.code`, LAN `rej`, LAN hata gövdesi) -> Türkçe metin (§3.2, §5.3.3).
const Map<String, String> _rejectMessages = <String, String>{
  'zone_latched': 'Alarm sürerken vana açılamaz. Önce sensörün kuruduğundan emin olup alarmı onaylayın.',
  'zone_test': 'Bölge testi sürüyor. Test bitince yeniden deneyin.',
  'actuator_relay': 'Bu kanal bir güvenlik cihazına bağlı; lamba gibi açılamaz.',
  'unknown_actuator': 'Bu güvenlik cihazı panoda tanımlı değil. Kurulumu kontrol edin.',
  'bad_state': 'Bu işlem güvenlik cihazının şu anki durumunda yapılamaz.',
  'unsupported': 'Pano yazılımı bu işlemi desteklemiyor. Pano yazılımını güncelleyin.',
  'cfg_conflict': 'Pano ayarları bu arada değişti. Güncel ayarlarla yeniden deneyin.',
  'cfg_invalid': 'Bu ayar bileşimi güvenlik kurallarına uymuyor.',
  'gas_local_only': 'Gaz vanası güvenlik gereği yalnız yerinde, panodaki düğmeyle açılır.',
  'stale_ack': 'Bu arada yeni bir alarm oluştu; lütfen güncel alarmı inceleyip yeniden onaylayın.',
  'safe_mode': 'Pano güvenli kipte; vanalar açılamaz. Kurulumcunuza başvurun.',
  // Hırsız alarmı kurma reddi (F2.B.7): hazır olmayan sensör var.
  'not_ready': 'Alarm kurulamadı: açık kapı ya da pencere var.',
  'bad_cmd': 'Pano komutu anlayamadı (sürüm uyumsuz olabilir).',
  'busy': 'Pano şu anda meşgul. Biraz bekleyip tekrar deneyin.',
  // LAN yanıt kodları (CONTRACTS §2.6 "LAN yanıtları"; karar 7.2b-7)
  'local_loosen_forbidden':
      'Bu değişiklik güvenliği gevşettiği için yerel bağlantıdan yapılamaz. Seri kablo (CLI) ya da bulut (ev sahibi / servis) gerekir.',
  'safety_active': 'Güvenlik modülü etkinken bu işlem yapılamaz.',
  // İstemci tarafı engel gerekçesi (firmware kodu değil): sensör "bağlantı yok" iken kuru sayılmaz [Y-3].
  'sensor_unknown': 'Sensörlerden biri yanıt vermiyor; kuru olduğu doğrulanamadığı için vana açılamaz.',
  'sensor_wet': 'Sensör hâlâ ıslak; vana açılamaz.',
};

/// Ret kodu bir güvenlik/eylemci ret kodu mu (bilinen kodlar).
bool isSafetyRejectCode(String? code) => code != null && _rejectMessages.containsKey(code.toLowerCase());

/// Ret kodunun Türkçe metni; bilinmeyen kod için genel metin.
String safetyRejectMessage(String? code) =>
    _rejectMessages[code?.toLowerCase()] ?? 'Pano komutu reddetti${code == null ? '' : ' ($code)'}.';

/// Güvenlik sensörü (`state.sensors[]`).
@immutable
class SensorItem {
  const SensorItem({
    required this.id,
    this.src = 'di',
    this.kind = 'unknown',
    this.zone = 0,
    this.active = false,
    this.ok = false,
    String? name,
    this.flags,
  }) : name = name ?? id;

  /// `d<1..40>` (DI) ya da `b<1..16>` (köprü yuvası).
  final String id;

  /// `di` | `bridge`.
  final String src;

  /// `water|gas|smoke|door|window|motion|generic` ya da yerel kumanda rolü (`alarm_ack|valve_close|gas_reset`);
  /// tanınmayan -> `unknown`.
  final String kind;
  final int zone;

  /// Onay süzgecinden geçmiş, NC çevrilmiş seviye. [ok] `false` ise anlamsızdır.
  final bool active;

  /// Sensör değeri güvenilir mi. Alan yoksa güvenilmez sayılır (kuru varsayılmaz).
  final bool ok;

  /// Yapılandırma adı; yoksa kimlik.
  final String name;

  /// Yapılandırma bayrakları (`flags`; state'te yoktur, kopyadan gelir). Bilinmiyorsa `null` ([defaultSensorFlags]).
  final int? flags;

  /// Okunur ad: yapılandırma adı; yoksa kimlikten ("d3" -> "Giriş 3", "b1" -> "Kablosuz sensör 1").
  String get displayName {
    if (name != id) return name;
    final n = id.length > 1 ? id.substring(1) : '';
    if (int.tryParse(n) == null) return id;
    if (id.startsWith('d')) return 'Giriş $n';
    if (id.startsWith('b')) return 'Kablosuz sensör $n';
    return id;
  }

  /// Etkin bayraklar (kopya yoksa türün varsayılanı).
  int get effectiveFlags => flags ?? defaultSensorFlags(kind);

  /// Arayüz etiketi: "Islak" / "Kuru" / "Bağlantı yok" ayrımı için.
  bool get isWet => ok && active;
  bool get isDry => ok && !active;

  /// Yerel kumanda rolü (alarm onay / vana kapat / gaz vanası açma düğmesi); tehlike sensörü değildir.
  bool get isControl => kSafetyControlKinds.contains(kind);

  static SensorItem? fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    if (id == null || id.length > 8) return null;
    final kind = asNonEmptyString(json['kind'])?.toLowerCase();
    return SensorItem(
      id: id,
      src: asNonEmptyString(json['src'])?.toLowerCase() == 'bridge' ? 'bridge' : 'di',
      kind: (kind != null && _sensorKinds.contains(kind)) ? kind : 'unknown',
      zone: asInt(json['zone']) ?? 0,
      active: asBool(json['active']) ?? false,
      ok: asBool(json['ok']) ?? false,
    );
  }

  SensorItem withName(String? value) => SensorItem(
        id: id,
        src: src,
        kind: kind,
        zone: zone,
        active: active,
        ok: ok,
        name: (value == null || value.trim().isEmpty) ? id : value.trim(),
        flags: flags,
      );

  SensorItem withFlags(int? value) =>
      SensorItem(id: id, src: src, kind: kind, zone: zone, active: active, ok: ok, name: name, flags: value);

  @override
  bool operator ==(Object other) =>
      other is SensorItem &&
      other.id == id &&
      other.src == src &&
      other.kind == kind &&
      other.zone == zone &&
      other.active == active &&
      other.ok == ok &&
      other.name == name &&
      other.flags == flags;

  @override
  int get hashCode => Object.hash(id, src, kind, zone, active, ok, name, flags);
}

/// Normal olmayan bir bölge (`state.safety.zones[]`): kilitli alarm, vana arızası ya da test.
@immutable
class AlarmItem {
  const AlarmItem({
    required this.zone,
    this.kind = 'unknown',
    required this.status,
    this.aid,
    this.silenced = false,
    this.sinceEpoch,
    this.sinceUptime,
    this.sources = const <String>[],
    this.deviceUid,
  });

  final int zone;
  final String kind;
  final ZoneStatus status;

  /// Alarmı açan olayın eid'si (`<bn>-<n>`); alarm kimliğidir. Onay (`alarm_ack`) bunu taşır [Y-9].
  final String? aid;
  final bool silenced;

  /// Saat güvenilirse (`time_ok`) epoch saniyesi; değilse yalnız [sinceUptime].
  final int? sinceEpoch;
  final int? sinceUptime;

  /// Alarmı tetikleyen ve sonradan katılan sensör kimlikleri (≤ 8).
  final List<String> sources;

  /// Alarmın ait olduğu pano (`state.uid`); çok panolu evde komut hedefi.
  final String? deviceUid;

  /// Kilitli alarm (`latched`/`fault`); test alarm değildir.
  bool get isActive => status.isAlarm;
  bool get isFault => status == ZoneStatus.fault;

  /// `st == 'normal'` ise (alarm değil) ya da bölge numarası geçersizse `null`.
  static AlarmItem? fromZoneJson(Map<String, dynamic> json, {String? deviceUid}) {
    final zone = asInt(json['id'] ?? json['zone']);
    if (zone == null || zone < 1 || zone > _maxZones) return null;
    final status = ZoneStatus.parse(json['st'] ?? json['status']);
    if (status == ZoneStatus.normal) return null;
    final kind = asNonEmptyString(json['kind'])?.toLowerCase();
    final sources = <String>[
      for (final item in asList(json['srcs']) ?? const <dynamic>[])
        if (asNonEmptyString(item) != null) asNonEmptyString(item)!,
    ];
    return AlarmItem(
      zone: zone,
      kind: (kind != null && _sensorKinds.contains(kind)) ? kind : 'unknown',
      status: status,
      aid: asNonEmptyString(json['aid']),
      silenced: asBool(json['silenced']) ?? false,
      sinceEpoch: asInt(json['since']),
      sinceUptime: asInt(json['since_up']),
      sources: List<String>.unmodifiable(sources.take(_maxSources)),
      deviceUid: deviceUid,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlarmItem &&
      other.zone == zone &&
      other.kind == kind &&
      other.status == status &&
      other.aid == aid &&
      other.silenced == silenced &&
      other.sinceEpoch == sinceEpoch &&
      other.sinceUptime == sinceUptime &&
      other.deviceUid == deviceUid &&
      listEquals(other.sources, sources);

  @override
  int get hashCode =>
      Object.hash(zone, kind, status, aid, silenced, sinceEpoch, sinceUptime, deviceUid, Object.hashAll(sources));
}

/// Eylemci (`state.actuators[]`): vana, siren, fan ya da genel cihaz.
@immutable
class ActuatorItem {
  const ActuatorItem({
    required this.id,
    required this.relay,
    required this.kind,
    this.medium,
    this.zones = const <int>[],
    this.pos,
    this.on,
    this.feedback,
    this.fault = false,
    String? name,
    this.deviceUid,
    this.exproof = false,
  }) : name = name ?? id;

  /// `a1`…`a16` (röleden bağımsız, kararlı kimlik).
  final String id;

  /// 1 tabanlı röle numarası.
  final int relay;
  final ActuatorKind kind;

  /// Yalnız vana: `water` | `gas` [K-3]. Bilinmiyorsa `null` (açma izni en tutucu kuralla verilir).
  final String? medium;
  final List<int> zones;

  /// Yalnız vana.
  final ValvePos? pos;

  /// Siren / fan / genel.
  final bool? on;

  /// Geri bildirim kontağının ham "kapalı" yorumu; geri bildirim yoksa `null`.
  final bool? feedback;
  final bool fault;
  final String name;
  final String? deviceUid;

  /// Fan gaz kaçağında çalıştırılabilir (ex-proof / ATEX). State'te yoktur; yapılandırma kopyasından gelir
  /// ([SafetyConfigNames.exproof]). Bilinmiyorsa `false` (tutucu: "gazda çalıştırılmaz").
  final bool exproof;

  bool get isValve => kind == ActuatorKind.valve;
  bool get isGasValve => isValve && medium == 'gas';

  /// Kapalı ya da kapanıyor (geri bildirimli/geri bildirimsiz). `unknown` kapalı DEĞİLDİR.
  bool get isClosedOrClosing => pos == ValvePos.closed || pos == ValvePos.closing || pos == ValvePos.cmdClosed;

  /// Kimliksiz ya da rölesiz (bozuk) öğe -> `null` (atlanır, fırlatmaz).
  static ActuatorItem? fromJson(Map<String, dynamic> json, {String? deviceUid}) {
    final id = asNonEmptyString(json['id']);
    final relay = asInt(json['relay']);
    if (id == null || id.length > 8 || relay == null || relay < 1 || relay > 64) return null;
    final kind = ActuatorKind.tryParse(json['kind']) ?? ActuatorKind.unknown;
    final medium = asNonEmptyString(json['medium'])?.toLowerCase();
    final zones = <int>[
      for (final z in asList(json['zones']) ?? const <dynamic>[])
        if (asInt(z) != null && asInt(z)! >= 1 && asInt(z)! <= _maxZones) asInt(z)!,
    ];
    return ActuatorItem(
      id: id,
      relay: relay,
      kind: kind,
      medium: (medium == 'water' || medium == 'gas') ? medium : null,
      zones: List<int>.unmodifiable(zones),
      pos: kind == ActuatorKind.valve ? ValvePos.parse(json['pos']) : null,
      on: kind == ActuatorKind.valve ? null : asBool(json['on']),
      feedback: asBool(json['fb']),
      fault: asBool(json['fault']) ?? false,
      deviceUid: deviceUid,
    );
  }

  ActuatorItem copyWith({ValvePos? pos, bool? on, String? name, bool? exproof}) => ActuatorItem(
        id: id,
        relay: relay,
        kind: kind,
        medium: medium,
        zones: zones,
        pos: pos ?? this.pos,
        on: on ?? this.on,
        feedback: feedback,
        fault: fault,
        name: name ?? this.name,
        deviceUid: deviceUid,
        exproof: exproof ?? this.exproof,
      );

  @override
  bool operator ==(Object other) =>
      other is ActuatorItem &&
      other.id == id &&
      other.relay == relay &&
      other.kind == kind &&
      other.medium == medium &&
      other.pos == pos &&
      other.on == on &&
      other.feedback == feedback &&
      other.fault == fault &&
      other.name == name &&
      other.deviceUid == deviceUid &&
      other.exproof == exproof &&
      listEquals(other.zones, zones);

  @override
  int get hashCode =>
      Object.hash(id, relay, kind, medium, pos, on, feedback, fault, name, deviceUid, exproof, Object.hashAll(zones));
}

/// Panonun güvenlik durumu (tek pano). `caps` içinde `safety` yoksa [unsupported].
@immutable
class SafetyState {
  const SafetyState({
    required this.supported,
    this.configured = false,
    this.policy = 'unknown',
    this.safeMode = false,
    this.caps = const <String>[],
    this.sensors = const <SensorItem>[],
    this.alarms = const <AlarmItem>[],
    this.actuators = const <ActuatorItem>[],
    this.zones = const <int, ZoneStatus>{},
    this.lastRej,
    this.deviceUid,
    this.cfgRev,
    this.cfgCrc,
    this.arm,
  });

  const SafetyState._unsupported()
      : supported = false,
        configured = false,
        policy = 'unknown',
        safeMode = false,
        caps = const <String>[],
        sensors = const <SensorItem>[],
        alarms = const <AlarmItem>[],
        actuators = const <ActuatorItem>[],
        zones = const <int, ZoneStatus>{},
        lastRej = null,
        deviceUid = null,
        cfgRev = null,
        cfgCrc = null,
        arm = null;

  /// Eski pano yazılımı (`v:2`, `caps` yok) ya da güvenlik yeteneği ilan edilmemiş.
  static const SafetyState unsupported = SafetyState._unsupported();

  /// `caps` içinde `safety` var mı.
  final bool supported;

  /// Modül yapılandırılmış mı (`safety`/`sensors`/`actuators` anahtarlarından biri var).
  final bool configured;

  /// `on` | `off` (bilinmiyorsa `unknown`).
  final String policy;

  /// `safety.mode == 'safe'`: açma komutları reddedilir.
  final bool safeMode;
  final List<String> caps;
  final List<SensorItem> sensors;

  /// Normal olmayan bölgeler (kilitli, arızalı, test).
  final List<AlarmItem> alarms;
  final List<ActuatorItem> actuators;

  /// Bölge -> durum (bildirilen bölgeler). Firmware `safety.zones[]`'a YALNIZ normal olmayan bölgeleri yazar
  /// (yokluğu = normal; CONTRACTS §2.6): durum için [zoneStatus] kullanın.
  final Map<int, ZoneStatus> zones;
  final SafetyRejection? lastRej;
  final String? deviceUid;

  /// Yapılandırma sürümü ve CRC'si (`cfg.safety.{rev,crc}`); değişince ad kopyası (`cfg_dump` /
  /// `GET /api/safety/config`) yenilenir. Yapılandırılmamış panoda `null`.
  final int? cfgRev;
  final String? cfgCrc;

  /// Hırsız alarmı katmanı (`safety.arm`; F2.B.7). Pano yazmadıysa (sensör yok / eski yazılım) `null`.
  final ArmState? arm;

  /// Pano hırsız alarmı kipini destekliyor (`caps` içinde `intrusion`; firmware v1.2.1+).
  bool get supportsIntrusion => caps.contains('intrusion');

  /// Hırsız alarmı sürüyor (`arm.st == alarm`).
  bool get intrusionAlarmActive => arm?.isAlarm ?? false;

  /// [mode] kipinde kurmayı engelleyen sensörler (F2.B.9 ön denetim; firmware hazırlık denetiminin istemci kopyası):
  /// kipte etkin, giriş yolu OLMAYAN ve açık (`active`) ya da `ok=false` kapı/pencere/hareket sensörleri.
  List<SensorItem> armBlockSensors(ArmMode mode) => <SensorItem>[
        for (final s in sensors)
          if (kIntrusionSensorKinds.contains(s.kind) &&
              (s.effectiveFlags & kSensorFlagReact) != 0 &&
              !(mode == ArmMode.home && (s.effectiveFlags & kSensorFlagAwayOnly) != 0) &&
              (s.effectiveFlags & kSensorFlagEntry) == 0 &&
              (!s.ok || s.active))
            s,
      ];

  /// Bölgenin durumu: bildirilmeyen bölge yapılandırılmış panoda `normal`dır (firmware yalnız normal olmayanları
  /// yazar); güvenlik özeti hiç yoksa (yapılandırılmamış / eski pano) [ZoneStatus.unknown].
  ZoneStatus zoneStatus(int zone) => zones[zone] ?? (configured ? ZoneStatus.normal : ZoneStatus.unknown);

  /// Kilitli (latched/fault) en az bir bölge var.
  bool get hasActiveAlarm => alarms.any((a) => a.isActive);

  List<ActuatorItem> get valves => actuators.where((a) => a.isValve).toList(growable: false);

  ActuatorItem? actuatorById(String id) {
    for (final a in actuators) {
      if (a.id == id) return a;
    }
    return null;
  }

  AlarmItem? alarmForZone(int zone) {
    for (final a in alarms) {
      if (a.zone == zone) return a;
    }
    return null;
  }

  /// [state] tam `state`/`status` yükü. [uid] verilmezse `state.uid` okunur (LAN yanıtında `device`). Fırlatmaz.
  factory SafetyState.fromStateJson(Map<String, dynamic> state, {String? uid}) {
    try {
      return _parse(state, uid);
    } catch (_) {
      return SafetyState.unsupported;
    }
  }

  static SafetyState _parse(Map<String, dynamic> state, String? uidHint) {
    final caps = <String>[
      for (final c in asList(state['caps']) ?? const <dynamic>[])
        if (asNonEmptyString(c) != null) asNonEmptyString(c)!.toLowerCase(),
    ];
    if (!caps.contains('safety')) return SafetyState.unsupported;
    final uid = uidHint ?? asNonEmptyString(state['uid'])?.toUpperCase() ?? _uidFromDevice(state['device']);

    final sensors = <SensorItem>[];
    for (final raw in asList(state['sensors']) ?? const <dynamic>[]) {
      if (sensors.length >= _maxSensors) break;
      final map = asMap(raw);
      final item = map == null ? null : SensorItem.fromJson(map);
      if (item != null) sensors.add(item);
    }
    final actuators = <ActuatorItem>[];
    for (final raw in asList(state['actuators']) ?? const <dynamic>[]) {
      if (actuators.length >= _maxActuators) break;
      final map = asMap(raw);
      final item = map == null ? null : ActuatorItem.fromJson(map, deviceUid: uid);
      if (item != null) actuators.add(item);
    }

    final safety = asMap(state['safety']);
    final zones = <int, ZoneStatus>{};
    final alarms = <AlarmItem>[];
    for (final raw in asList(safety?['zones']) ?? const <dynamic>[]) {
      if (zones.length >= _maxZones) break;
      final map = asMap(raw);
      if (map == null) continue;
      final id = asInt(map['id'] ?? map['zone']);
      if (id == null || id < 1 || id > _maxZones || zones.containsKey(id)) continue;
      zones[id] = ZoneStatus.parse(map['st'] ?? map['status']);
      final alarm = AlarmItem.fromZoneJson(map, deviceUid: uid);
      if (alarm != null) alarms.add(alarm);
    }
    final policy = asNonEmptyString(safety?['policy'])?.toLowerCase();
    final cfg = asMap(asMap(state['cfg'])?['safety']);
    final crc = asNonEmptyString(cfg?['crc'])?.toLowerCase();
    return SafetyState(
      supported: true,
      configured: safety != null || state.containsKey('sensors') || state.containsKey('actuators'),
      policy: (policy == 'on' || policy == 'off') ? policy! : 'unknown',
      safeMode: asNonEmptyString(safety?['mode'])?.toLowerCase() == 'safe',
      caps: List<String>.unmodifiable(caps),
      sensors: List<SensorItem>.unmodifiable(sensors),
      alarms: List<AlarmItem>.unmodifiable(alarms),
      actuators: List<ActuatorItem>.unmodifiable(actuators),
      zones: Map<int, ZoneStatus>.unmodifiable(zones),
      lastRej: SafetyRejection.fromJson(state['last_rej']),
      deviceUid: uid,
      cfgRev: asInt(cfg?['rev']),
      cfgCrc: (crc != null && crc.length <= 8) ? crc : null,
      arm: ArmState.fromJson(safety?['arm']),
    );
  }

  static final RegExp _uidShape = RegExp(r'^AHBU-[A-Z0-9-]{3,32}$');

  static String? _uidFromDevice(Object? raw) {
    final text = asNonEmptyString(raw)?.toUpperCase();
    return (text != null && _uidShape.hasMatch(text)) ? text : null;
  }

  /// Yapılandırma kopyasından gelen adlarla (kimlik -> ad) yeni durum; bilinmeyen kimlik adını korur.
  SafetyState withNames({
    Map<String, String> sensors = const {},
    Map<String, String> actuators = const {},
    Set<String> exproof = const <String>{},
    Map<String, int> sensorFlags = const <String, int>{},
  }) {
    if (!supported) return this;
    return SafetyState(
      supported: supported,
      configured: configured,
      policy: policy,
      safeMode: safeMode,
      caps: caps,
      sensors: List<SensorItem>.unmodifiable(
        this.sensors.map((s) {
          final named = sensors.containsKey(s.id) ? s.withName(sensors[s.id]) : s;
          return sensorFlags.containsKey(s.id) ? named.withFlags(sensorFlags[s.id]) : named;
        }),
      ),
      alarms: alarms,
      actuators: List<ActuatorItem>.unmodifiable(
        this.actuators.map((a) {
          final named = actuators.containsKey(a.id) ? a.copyWith(name: actuators[a.id]) : a;
          return exproof.contains(a.id) ? named.copyWith(exproof: true) : named;
        }),
      ),
      zones: zones,
      lastRej: lastRej,
      deviceUid: deviceUid,
      cfgRev: cfgRev,
      cfgCrc: cfgCrc,
      arm: arm,
    );
  }

  /// Vanayı uygulamadan açma izni [Y-3][K-4]: güvenli kip değil; gaz vanası değil; vananın bütün bölgeleri `normal`;
  /// o bölgelerde vananın akışkanına uyan BÜTÜN sensörler `ok && !active` (akışkan bilinmiyorsa bölgedeki bütün
  /// sensörler). Asıl yetki firmware'dedir; bu yalnız arayüz kapısı ve gereksiz komutun önlenmesidir.
  bool canOpenValve(ActuatorItem valve) => openBlockReason(valve) == null;

  /// [canOpenValve] `false` ise gerekçe kodu ([safetyRejectMessage] ile metne çevrilir); izin varsa `null`.
  String? openBlockReason(ActuatorItem valve) {
    if (!supported || !valve.isValve) return 'unsupported';
    if (safeMode) return 'safe_mode';
    if (valve.isGasValve) return 'gas_local_only';
    for (final z in valve.zones) {
      if (zoneStatus(z) != ZoneStatus.normal) return 'zone_latched';
    }
    for (final s in sensors) {
      if (s.isControl || !valve.zones.contains(s.zone)) continue;
      if (valve.medium != null && s.kind != valve.medium) continue;
      if (!s.ok) return 'sensor_unknown';
      if (s.active) return 'sensor_wet';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SafetyState &&
      other.supported == supported &&
      other.configured == configured &&
      other.policy == policy &&
      other.safeMode == safeMode &&
      other.lastRej == lastRej &&
      other.deviceUid == deviceUid &&
      other.cfgRev == cfgRev &&
      other.cfgCrc == cfgCrc &&
      other.arm == arm &&
      listEquals(other.caps, caps) &&
      listEquals(other.sensors, sensors) &&
      listEquals(other.alarms, alarms) &&
      listEquals(other.actuators, actuators) &&
      mapEquals(other.zones, zones);

  @override
  int get hashCode => Object.hash(
        supported,
        configured,
        policy,
        safeMode,
        lastRej,
        deviceUid,
        cfgRev,
        cfgCrc,
        arm,
        Object.hashAll(caps),
        Object.hashAll(sensors),
        Object.hashAll(alarms),
        Object.hashAll(actuators),
        Object.hashAllUnordered(zones.entries.map((e) => Object.hash(e.key, e.value))),
      );
}

// =============================================================================
// Güvenlik olayları (uygulama tarafı türetme)
// =============================================================================
//
// Pano olayları `ev/{t}/event` konusuna yazar; uygulama kimlikleri bu konuya ABONE OLMAZ (tasarım §3.4: ACL değişmez,
// uygulama alarmı state + push ile alır). Arayüzün "kenar" bilgisine (alarm başladı/susturuldu/kalktı, ret) ihtiyacı
// için olaylar ardışık `state` görüntülerinin farkından türetilir. Teslim garantisi YOKTUR (QoS 0 state kaybolabilir,
// ara geçiş görülmeyebilir): kalıcı gerçek her zaman son [SafetyState]'tir; olaylar yalnız bildirim/animasyon içindir.

enum SafetyEventType {
  alarmRaised,
  alarmSilenced,
  alarmCleared,
  valveFault,
  valveFaultCleared,
  sensorFault,
  sensorFaultCleared,
  safeModeEntered,
  safeModeExited,
  commandRejected,
}

/// Ardışık iki [SafetyState] arasındaki bir geçiş.
@immutable
class SafetyEvent {
  const SafetyEvent({
    required this.type,
    this.deviceUid,
    this.zone,
    this.aid,
    this.kind,
    this.sensorId,
    this.rejection,
    this.initial = false,
    this.retained = false,
  });

  final SafetyEventType type;
  final String? deviceUid;
  final int? zone;
  final String? aid;
  final String? kind;
  final String? sensorId;
  final SafetyRejection? rejection;

  /// Panonun bu oturumda İLK görülen durumundan türedi (bağlanış / retained): yeni bir geçiş olmayabilir.
  final bool initial;

  /// Kaynak `state` brokerın saklı (retained) iletisiydi.
  final bool retained;

  /// [before] (`null` = ilk görüntü) -> [after] geçişinin olayları. Güvenlik alanı kaybolduysa (eski yazılım,
  /// silinmiş yapılandırma) hiçbir şey üretilmez: "kalktı" UYDURULMAZ [O11]. İlk görüntüde yalnız etkin durumlar
  /// (alarm, arıza, güvenli kip) bildirilir; eski ret kaydı olay değildir.
  static List<SafetyEvent> between(SafetyState? before, SafetyState after, {bool retained = false}) {
    if (!after.supported) return const <SafetyEvent>[];
    final initial = before == null || !before.supported;
    final prev = initial ? null : before;
    final uid = after.deviceUid;
    final out = <SafetyEvent>[];
    SafetyEvent ev(SafetyEventType type, {int? zone, String? aid, String? kind, String? sensorId, SafetyRejection? rej}) =>
        SafetyEvent(
          type: type,
          deviceUid: uid,
          zone: zone,
          aid: aid,
          kind: kind,
          sensorId: sensorId,
          rejection: rej,
          initial: initial,
          retained: retained,
        );

    if (after.safeMode && !(prev?.safeMode ?? false)) out.add(ev(SafetyEventType.safeModeEntered));
    if (!after.safeMode && (prev?.safeMode ?? false)) out.add(ev(SafetyEventType.safeModeExited));

    for (final entry in after.zones.entries) {
      final zone = entry.key;
      final now = entry.value;
      final was = prev?.zones[zone] ?? ZoneStatus.normal;
      final alarm = after.alarmForZone(zone);
      final oldAlarm = prev?.alarmForZone(zone);
      final newAid = now.isAlarm && was.isAlarm && alarm?.aid != null && oldAlarm?.aid != null && alarm!.aid != oldAlarm!.aid;
      if (now.isAlarm && (!was.isAlarm || newAid)) {
        out.add(ev(SafetyEventType.alarmRaised, zone: zone, aid: alarm?.aid, kind: alarm?.kind));
        if (now == ZoneStatus.fault) out.add(ev(SafetyEventType.valveFault, zone: zone, aid: alarm?.aid, kind: alarm?.kind));
        continue;
      }
      if (now.isAlarm && was.isAlarm) {
        if (was == ZoneStatus.latched && now == ZoneStatus.fault) {
          out.add(ev(SafetyEventType.valveFault, zone: zone, aid: alarm?.aid, kind: alarm?.kind));
        } else if (was == ZoneStatus.fault && now == ZoneStatus.latched) {
          out.add(ev(SafetyEventType.valveFaultCleared, zone: zone, aid: alarm?.aid, kind: alarm?.kind));
        }
        if ((alarm?.silenced ?? false) && !(oldAlarm?.silenced ?? false)) {
          out.add(ev(SafetyEventType.alarmSilenced, zone: zone, aid: alarm?.aid, kind: alarm?.kind));
        }
        continue;
      }
      if (now == ZoneStatus.normal && was.isAlarm) {
        out.add(ev(SafetyEventType.alarmCleared, zone: zone, aid: oldAlarm?.aid, kind: oldAlarm?.kind));
      }
    }

    if (prev != null) {
      for (final sensor in after.sensors) {
        SensorItem? old;
        for (final s in prev.sensors) {
          if (s.id == sensor.id) old = s;
        }
        if (old == null) continue;
        if (old.ok && !sensor.ok) out.add(ev(SafetyEventType.sensorFault, zone: sensor.zone, sensorId: sensor.id, kind: sensor.kind));
        if (!old.ok && sensor.ok) {
          out.add(ev(SafetyEventType.sensorFaultCleared, zone: sensor.zone, sensorId: sensor.id, kind: sensor.kind));
        }
      }
      final rej = after.lastRej;
      if (rej != null && rej != prev.lastRej) out.add(ev(SafetyEventType.commandRejected, rej: rej));
    }
    return out;
  }

  @override
  String toString() => 'SafetyEvent(${type.name}, $deviceUid, zone=$zone, aid=$aid)';
}

/// Sunucudaki alarm kaydı (`GET /homes/:id/alarms`; tablo `alarms`, migration 033). Onay ucu bu kaydın [id]'sini
/// ister; panoya giden `alarm_ack`'in `aid`'si kayıttan gelir [Y-9].
@immutable
class AlarmRecord {
  const AlarmRecord({
    required this.id,
    required this.zone,
    required this.aid,
    this.kind = 'unknown',
    this.status = 'latched',
    this.deviceId,
    this.deviceUuid,
    this.raisedAt,
    this.ackedAt,
    this.clearedAt,
  });

  /// Kayıt kimliği (sunucu `BIGSERIAL`; metin olarak tutulur).
  final String id;
  final int zone;
  final String aid;
  final String kind;

  /// `latched|fault|silenced|cleared|lost`.
  final String status;
  final String? deviceId;
  final String? deviceUuid;
  final DateTime? raisedAt;
  final DateTime? ackedAt;
  final DateTime? clearedAt;

  bool get isOpen => status != 'cleared' && status != 'lost';

  /// Kimliksiz / aid'siz / bölgesiz kayıt -> `FormatException` (`parseList` atlar).
  factory AlarmRecord.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id'] ?? json['alarm_id']);
    final aid = asNonEmptyString(json['aid']);
    final zone = asInt(json['zone']);
    if (id == null || aid == null || zone == null) throw const FormatException('Geçersiz alarm kaydı');
    return AlarmRecord(
      id: id,
      zone: zone,
      aid: aid,
      kind: asNonEmptyString(json['kind'])?.toLowerCase() ?? 'unknown',
      status: asNonEmptyString(json['status'])?.toLowerCase() ?? 'latched',
      deviceId: asNonEmptyString(json['device_id']),
      deviceUuid: asNonEmptyString(json['device_uuid'])?.toUpperCase(),
      raisedAt: asDate(json['raised_at']),
      ackedAt: asDate(json['acked_at']),
      clearedAt: asDate(json['cleared_at']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlarmRecord &&
      other.id == id &&
      other.zone == zone &&
      other.aid == aid &&
      other.kind == kind &&
      other.status == status &&
      other.deviceId == deviceId &&
      other.deviceUuid == deviceUuid &&
      other.raisedAt == raisedAt &&
      other.ackedAt == ackedAt &&
      other.clearedAt == clearedAt;

  @override
  int get hashCode => Object.hash(id, zone, aid, kind, status, deviceId, deviceUuid, raisedAt, ackedAt, clearedAt);
}

/// LAN `GET /api/events` öğesi (EventOutbox'ın son 32 olayı; internetsiz alarm geçmişi, K5, tasarım §3.5).
@immutable
class DeviceEventRecord {
  const DeviceEventRecord({
    required this.eid,
    required this.type,
    this.zone,
    this.kind,
    this.sources = const <String>[],
    this.atEpoch,
    this.atUptime,
    this.ok,
    this.fbMs,
    this.aid,
  });

  /// `<bn>-<n>`.
  final String eid;

  /// Alarm kimliği (`valve_fault`, `valve_fault_cleared`, `alarm_silenced`, `alarm_cleared`; CONTRACTS §2.6).
  /// `alarm_raised`'da alarm kimliği olayın kendi [eid]'sidir ([alarmId]).
  final String? aid;

  /// Olayın ait olduğu alarm: `alarm_raised` için [eid], diğer alarm olaylarında [aid].
  String? get alarmId => type == 'alarm_raised' ? eid : aid;

  /// `alarm_raised`, `valve_fault`, `alarm_silenced`, `alarm_cleared`, `test_result`, `sensor_fault` ...
  final String type;
  final int? zone;
  final String? kind;
  final List<String> sources;
  final int? atEpoch;
  final int? atUptime;

  /// Yalnız `test_result`: test başarılı mı (`ok`) ve geri bildirimle ölçülen kapanma süresi (`fb_ms`; firmware
  /// yalnız geri bildirimli vanada yazar, yoksa `null` = "gözle doğrulayın").
  final bool? ok;
  final int? fbMs;

  factory DeviceEventRecord.fromJson(Map<String, dynamic> json) {
    final eid = asNonEmptyString(json['eid']);
    final type = asNonEmptyString(json['type'])?.toLowerCase();
    if (eid == null || type == null) throw const FormatException('Geçersiz olay');
    return DeviceEventRecord(
      eid: eid,
      type: type,
      zone: asInt(json['zone']),
      kind: asNonEmptyString(json['kind'])?.toLowerCase(),
      sources: List<String>.unmodifiable(<String>[
        for (final s in asList(json['srcs']) ?? const <dynamic>[])
          if (asNonEmptyString(s) != null) asNonEmptyString(s)!,
      ].take(_maxSources)),
      atEpoch: asInt(json['at']),
      atUptime: asInt(json['at_up']),
      ok: asBool(json['ok']),
      fbMs: asInt(json['fb_ms']),
      aid: asNonEmptyString(json['aid'])?.toLowerCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceEventRecord &&
      other.eid == eid &&
      other.type == type &&
      other.zone == zone &&
      other.kind == kind &&
      other.atEpoch == atEpoch &&
      other.atUptime == atUptime &&
      other.ok == ok &&
      other.fbMs == fbMs &&
      other.aid == aid &&
      listEquals(other.sources, sources);

  @override
  int get hashCode => Object.hash(eid, type, zone, kind, atEpoch, atUptime, ok, fbMs, aid, Object.hashAll(sources));
}

/// Alarm geçmişi ekranının verisi: bulutta sunucu kayıtları ([records]), LAN'da panonun son olayları ([events]).
@immutable
class AlarmHistory {
  const AlarmHistory.cloud(this.records)
      : local = false,
        events = const <DeviceEventRecord>[];

  const AlarmHistory.local(this.events)
      : local = true,
        records = const <AlarmRecord>[];

  /// Kaynak panonun yerel olay halkası mı (internetsiz).
  final bool local;
  final List<AlarmRecord> records;
  final List<DeviceEventRecord> events;

  bool get isEmpty => local ? events.isEmpty : records.isEmpty;
}

/// Panonun güvenlik yapılandırma kopyasındaki ADLAR (state'te ad yoktur [B12]). Kaynak: bulutta
/// `GET /homes/:homeId/devices/:deviceId/safety-config` (sunucunun `cfg_dump` kopyası), LAN'da `GET /api/safety/config`.
/// İki yanıt da aynı biçimdedir: `{rev, crc, policy, zones:[{id,name}], lights, sensors:[{id,…,name}],
/// actuators:[{id,…,name}]}` (CONTRACTS §2.6). Ad güvenilmeyen girdidir: kırpılır, kontrol karakterleri atılır.
@immutable
class SafetyConfigNames {
  const SafetyConfigNames({
    this.rev,
    this.crc,
    this.sensors = const <String, String>{},
    this.actuators = const <String, String>{},
    this.zones = const <int, String>{},
    this.exproof = const <String>{},
    this.sensorFlags = const <String, int>{},
  });

  final int? rev;
  final String? crc;

  /// Sensör kimliği (`d3`, `b1`) -> ad.
  final Map<String, String> sensors;

  /// Eylemci kimliği (`a1`) -> ad.
  final Map<String, String> actuators;

  /// Bölge (1..4) -> ad.
  final Map<int, String> zones;

  /// `exproof:true` işaretli eylemci kimlikleri (gaz alarmında çalıştırılabilen fan; F2.A.6 fan satırı).
  final Set<String> exproof;

  /// Sensör kimliği -> `flags` (hırsız alarmı ön denetimi; F2.B.9).
  final Map<String, int> sensorFlags;

  /// Kopya bu durumun yapılandırmasına mı ait (`cfg.safety.rev/crc`).
  bool matches(SafetyState state) => state.cfgRev == rev && (state.cfgCrc == null || crc == null || state.cfgCrc == crc);

  static const int _maxName = 40;

  static String? _name(Object? raw) {
    final text = asNonEmptyString(raw);
    if (text == null) return null;
    final clean = String.fromCharCodes(text.runes.where((r) => r >= 0x20 && r != 0x7f)).trim();
    if (clean.isEmpty) return null;
    return clean.length > _maxName ? clean.substring(0, _maxName) : clean;
  }

  factory SafetyConfigNames.fromJson(Map<String, dynamic> json) {
    Map<String, String> byId(Object? raw, RegExp shape, int max) {
      final out = <String, String>{};
      for (final item in (asList(raw) ?? const <dynamic>[]).take(64)) {
        final map = asMap(item);
        final id = asNonEmptyString(map?['id'])?.toLowerCase();
        final name = _name(map?['name']);
        if (id == null || name == null || !shape.hasMatch(id) || out.length >= max) continue;
        out[id] = name;
      }
      return Map<String, String>.unmodifiable(out);
    }

    final zones = <int, String>{};
    for (final item in (asList(json['zones']) ?? const <dynamic>[]).take(8)) {
      final map = asMap(item);
      final id = asInt(map?['id']);
      final name = _name(map?['name']);
      if (id != null && id >= 1 && id <= _maxZones && name != null) zones[id] = name;
    }
    final crc = asNonEmptyString(json['crc'])?.toLowerCase();
    final exproof = <String>{
      for (final item in (asList(json['actuators']) ?? const <dynamic>[]).take(_maxActuators))
        if (asBool(asMap(item)?['exproof']) == true && asNonEmptyString(asMap(item)?['id']) != null)
          asNonEmptyString(asMap(item)?['id'])!.toLowerCase(),
    };
    final sensorFlags = <String, int>{};
    for (final item in (asList(json['sensors']) ?? const <dynamic>[]).take(_maxSensors)) {
      final map = asMap(item);
      final id = asNonEmptyString(map?['id'])?.toLowerCase();
      final flags = asInt(map?['flags']);
      if (id != null && flags != null && flags >= 0 && flags <= 0xFF) sensorFlags[id] = flags;
    }
    return SafetyConfigNames(
      rev: asInt(json['rev']),
      crc: (crc != null && crc.length <= 8) ? crc : null,
      sensors: byId(json['sensors'], RegExp(r'^[db][0-9]{1,2}$'), _maxSensors),
      actuators: byId(json['actuators'], RegExp(r'^a[0-9]{1,2}$'), _maxActuators),
      zones: Map<int, String>.unmodifiable(zones),
      exproof: Set<String>.unmodifiable(exproof),
      sensorFlags: Map<String, int>.unmodifiable(sensorFlags),
    );
  }
}
