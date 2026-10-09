import 'package:flutter/foundation.dart';

import '../../../../models/json_utils.dart';

// =============================================================================
// Kurulum sihirbazı: sensör / eylemci ataması ve K4 dimmer sorusu (WP-A4; tasarım §4.4, §4.5, §2.4, §2.5, §7.2b).
//
// SAF modeller: ağ yok, Flutter widget'ı yok. Röle kartı ([ChannelAssignment]) "Bu kanala ne bağlı?" sorusunun ve vana /
// siren / fan / dimmer ayrıntılarının yanıtıdır; giriş kartı ([InputAssignment]) DI ya da köprü (Zigbee/Thread hub)
// kaynağının rolüdür. [validateSafetyPlan] emniyet kurallarını (NC zorunluluğu, akışkan, iki röleli vana çakışması ...)
// denetler, [buildSafetyPatches] panonun mevcut yapılandırmasına göre `POST /api/safety/config` TEK öğelik yamalarını
// kurar (CONTRACTS §2.6; firmware F5 sözleşmesi), [dimmerGuideFor] §4.5 yönerge metnini yer tutucuları doldurarak üretir.
// =============================================================================

/// Kanalın kullanımı. `light` = bugünkü davranış (lamba / priz / darbe; panonun röle tipi değişmez).
enum ChannelUse {
  light('light', 'Lamba / priz'),
  valve('valve', 'Vana'),
  siren('siren', 'Siren'),
  fan('fan', 'Fan'),
  generic('generic', 'Diğer cihaz');

  const ChannelUse(this.wire, this.label);

  final String wire;
  final String label;

  bool get isActuator => this != ChannelUse.light;

  static ChannelUse parse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    for (final u in ChannelUse.values) {
      if (u.wire == text) return u;
    }
    return ChannelUse.light;
  }
}

/// Vananın kapanma kipi (`close_mode`, §2.4): röle enerjiliyken mi kapalı?
enum ValveCloseMode {
  /// "Bilmiyorum": röleyi Aç/Kapat ile deneyip vananın konumunu gözleyin; seçilmeden kaydedilemez.
  unknown('unknown'),

  /// Röle AÇIK = vana kapalı (NO selenoid / motorlu vananın kapama hattı).
  energizeToClose('energize'),

  /// Röle KAPALI = vana kapalı (NC selenoid: elektrik kesilince kapanır, "fail-safe").
  deenergizeToClose('deenergize');

  const ValveCloseMode(this.wire);

  final String wire;

  static ValveCloseMode parse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    for (final m in ValveCloseMode.values) {
      if (m.wire == text) return m;
    }
    return ValveCloseMode.unknown;
  }
}

/// Vana sürüşü (7.2b karar 2): tek röle (sürekli seviye) ya da iki röle (aç + kapat darbesi, panjur benzeri kilitli).
enum ValveDrive {
  single('level'),
  dual('pulse2');

  const ValveDrive(this.wire);

  final String wire;

  static ValveDrive parse(Object? raw) => asNonEmptyString(raw) == 'pulse2' ? ValveDrive.dual : ValveDrive.single;
}

/// Dimmer kaynağı (K4): kablolu RS485 Modbus modülü ya da Zigbee/Thread hub cihazı.
enum DimmerSource {
  modbus('modbus'),
  bridge('bridge');

  const DimmerSource(this.wire);

  final String wire;

  static DimmerSource parse(Object? raw) => asNonEmptyString(raw) == 'bridge' ? DimmerSource.bridge : DimmerSource.modbus;
}

const int kMaxSafetyZones = 4;
const int kMaxActuators = 16;
const int kMaxSensors = 56;
const int kMaxBridgeSlots = 16;
const int kDefaultPulseSec = 15;
const int kDefaultSirenRunSec = 180;

/// Bir röle kanalının ataması.
@immutable
class ChannelAssignment {
  const ChannelAssignment({
    this.use = ChannelUse.light,
    this.closeMode = ValveCloseMode.unknown,
    this.medium,
    this.drive = ValveDrive.single,
    this.openRelay,
    this.pulseSec = kDefaultPulseSec,
    this.fbDi,
    this.zone = 1,
    this.fanExProof = false,
    this.wantsDimming = false,
    this.dimmerSource = DimmerSource.modbus,
  });

  /// Varsayılan: bugünkü lamba davranışı, dimmer yok.
  static const ChannelAssignment none = ChannelAssignment();

  final ChannelUse use;
  final ValveCloseMode closeMode;

  /// Vananın kestiği akışkan: `water` | `gas` (vana için zorunlu) [K-3].
  final String? medium;
  final ValveDrive drive;

  /// İki röleli vanada AÇMA rölesi (bu kanal kapama rölesidir).
  final int? openRelay;

  /// İki röleli vananın darbe süresi (sn).
  final int pulseSec;

  /// Konum geri bildirim girişi (DI no, 1 tabanlı); yoksa `null`.
  final int? fbDi;
  final int zone;

  /// Fan gaz kaçağında çalıştırılabilir (ex-proof / ATEX onayı) [Y-1]. Varsayılan hayır.
  final bool fanExProof;

  /// K4: bu lambanın parlaklığı ayarlanacak mı (varsayılan hayır).
  final bool wantsDimming;
  final DimmerSource dimmerSource;

  bool get isValve => use == ChannelUse.valve;
  bool get isGasValve => isValve && medium == 'gas';
  bool get isDimmable => use == ChannelUse.light && wantsDimming;

  /// Varsayılandan farklı mı (kayda/panoya yazılacak bir şey var mı).
  bool get isDefault => this == none;

  ChannelAssignment copyWith({
    ChannelUse? use,
    ValveCloseMode? closeMode,
    String? medium,
    bool clearMedium = false,
    ValveDrive? drive,
    int? openRelay,
    bool clearOpenRelay = false,
    int? pulseSec,
    int? fbDi,
    bool clearFbDi = false,
    int? zone,
    bool? fanExProof,
    bool? wantsDimming,
    DimmerSource? dimmerSource,
  }) =>
      ChannelAssignment(
        use: use ?? this.use,
        closeMode: closeMode ?? this.closeMode,
        medium: clearMedium ? null : (medium ?? this.medium),
        drive: drive ?? this.drive,
        openRelay: clearOpenRelay ? null : (openRelay ?? this.openRelay),
        pulseSec: pulseSec ?? this.pulseSec,
        fbDi: clearFbDi ? null : (fbDi ?? this.fbDi),
        zone: zone ?? this.zone,
        fanExProof: fanExProof ?? this.fanExProof,
        wantsDimming: wantsDimming ?? this.wantsDimming,
        dimmerSource: dimmerSource ?? this.dimmerSource,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'use': use.wire,
        if (closeMode != ValveCloseMode.unknown) 'close_mode': closeMode.wire,
        'medium': ?medium,
        if (drive != ValveDrive.single) 'drive': drive.wire,
        'open_relay': ?openRelay,
        if (pulseSec != kDefaultPulseSec) 'pulse_s': pulseSec,
        'fb_di': ?fbDi,
        if (zone != 1) 'zone': zone,
        if (fanExProof) 'atex': true,
        if (wantsDimming) 'dim': true,
        if (dimmerSource != DimmerSource.modbus) 'dim_src': dimmerSource.wire,
      };

  /// Bozuk alanlar varsayılana döner (fırlatmaz).
  factory ChannelAssignment.fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return none;
    final medium = asNonEmptyString(map['medium'])?.toLowerCase();
    final zone = asInt(map['zone']) ?? 1;
    final pulse = asInt(map['pulse_s']) ?? kDefaultPulseSec;
    return ChannelAssignment(
      use: ChannelUse.parse(map['use']),
      closeMode: ValveCloseMode.parse(map['close_mode']),
      medium: (medium == 'water' || medium == 'gas') ? medium : null,
      drive: ValveDrive.parse(map['drive']),
      openRelay: asInt(map['open_relay']),
      pulseSec: pulse.clamp(1, 120),
      fbDi: asInt(map['fb_di']),
      zone: zone.clamp(1, kMaxSafetyZones),
      fanExProof: asBool(map['atex']) ?? false,
      wantsDimming: asBool(map['dim']) ?? false,
      dimmerSource: DimmerSource.parse(map['dim_src']),
    );
  }

  /// Panonun yapılandırma kopyasındaki eylemci satırı (`GET /api/safety/config` `actuators[]`: `{id, relay, relay2?,
  /// kind, close_mode: energize|deenergize|pulse, medium, zones, fb_di (0 = yok), run_limit_s, exproof, name}`;
  /// CONTRACTS §2.6) ya da `state.actuators[]` öğesi (`kind`, `medium`, `zones`). Bozuk alan varsayılana döner.
  factory ChannelAssignment.fromBoard(Map<String, dynamic> json) {
    final kind = ChannelUse.parse(json['kind']);
    final zones = asList(json['zones']) ?? const <dynamic>[];
    final zone = zones.isEmpty ? 1 : (asInt(zones.first) ?? 1);
    final medium = asNonEmptyString(json['medium'])?.toLowerCase();
    final pulse = asNonEmptyString(json['close_mode']) == 'pulse' || asNonEmptyString(json['drive']) == 'pulse2';
    final openRelay = asInt(json['open_relay']) ?? asInt(json['relay2']);
    final fbDi = asInt(json['fb_di']);
    return ChannelAssignment(
      use: kind,
      // İki röleli vanada kapanma kipi sorusu anlamsızdır (firmware `pulse`): bilinen bir değerle açılır.
      closeMode: pulse ? ValveCloseMode.energizeToClose : ValveCloseMode.parse(json['close_mode']),
      medium: (medium == 'water' || medium == 'gas') ? medium : null,
      drive: pulse ? ValveDrive.dual : ValveDrive.single,
      openRelay: (openRelay != null && openRelay > 0) ? openRelay : null,
      pulseSec: (asInt(json['pulse_s']) ?? (pulse ? asInt(json['run_limit_s']) : null) ?? kDefaultPulseSec).clamp(1, 120),
      fbDi: (fbDi != null && fbDi > 0) ? fbDi : null,
      zone: zone.clamp(1, kMaxSafetyZones),
      fanExProof: asBool(json['atex']) ?? asBool(json['exproof']) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChannelAssignment &&
      other.use == use &&
      other.closeMode == closeMode &&
      other.medium == medium &&
      other.drive == drive &&
      other.openRelay == openRelay &&
      other.pulseSec == pulseSec &&
      other.fbDi == fbDi &&
      other.zone == zone &&
      other.fanExProof == fanExProof &&
      other.wantsDimming == wantsDimming &&
      other.dimmerSource == dimmerSource;

  @override
  int get hashCode =>
      Object.hash(use, closeMode, medium, drive, openRelay, pulseSec, fbDi, zone, fanExProof, wantsDimming, dimmerSource);
}

/// Giriş (DI ya da köprü) rolü (§4.4 madde 2, §2.5).
enum InputRole {
  button('button', 'Duvar butonu'),
  water('water', 'Su sensörü'),
  gas('gas', 'Gaz dedektörü çıkışı'),
  smoke('smoke', 'Duman dedektörü çıkışı'),
  door('door', 'Kapı kontağı'),
  window('window', 'Pencere kontağı'),
  motion('motion', 'Hareket sensörü'),
  valveFeedback('valve_fb', 'Vana geri bildirimi'),
  alarmAck('alarm_ack', 'Alarm onay düğmesi'),
  valveClose('valve_close', 'Vana kapat düğmesi'),
  gasReset('gas_reset', 'Gaz vanası açma düğmesi'),

  /// Anahtarlı alarm kontağı (F2.B.3): pasif->aktif kenarı `away` kurar, aktif->pasif çözer. Yalnız `caps` `intrusion`
  /// ilan eden panoda seçilebilir.
  armKey('arm_key', 'Alarm anahtarı (anahtarlı kontak)'),
  unused('unused', 'Kullanılmıyor');

  const InputRole(this.wire, this.label);

  final String wire;
  final String label;

  /// Algılayıcı (bölgeye bağlı sensör) mü.
  bool get isSensor => const <InputRole>{water, gas, smoke, door, window, motion}.contains(this);

  /// Yerel güvenlik kumandası (sensör tablosuna `kind` olarak girer, bölgeye bağlıdır) [B15].
  bool get isSafetyControl => this == alarmAck || this == valveClose || this == gasReset || this == armKey;

  /// Hırsız alarmı sensörü (kapı / pencere / hareket; F2.B.1).
  bool get isIntrusionSensor => this == door || this == window || this == motion;

  /// NC (kontak açılınca aktif) bağlantı ZORUNLU: dedektörün enerjisi kesilir ya da kablo koparsa alarm olur [O-2].
  /// Anahtarlı alarm kontağı da NC'dir: kablo kesilince "kurulu" okunur, alarm çözülmez (Faz 2 incelemesi RV-E3; firmware
  /// `arm_key_not_nc`).
  bool get requiresNc => this == gas || this == smoke || this == armKey;

  /// Köprü (kablosuz) kaynağı için anlamlı roller: yalnız algılayıcılar.
  static List<InputRole> get bridgeRoles => const <InputRole>[water, gas, smoke, door, window, motion];

  static InputRole parse(Object? raw) {
    final text = asNonEmptyString(raw)?.toLowerCase();
    for (final r in InputRole.values) {
      if (r.wire == text) return r;
    }
    return InputRole.button;
  }

  /// Panonun bildirdiği sensör türü (`sensors[].kind`) -> rol.
  static InputRole? fromSensorKind(String kind) {
    for (final r in InputRole.values) {
      if (r.isSensor && r.wire == kind) return r;
    }
    return null;
  }
}

/// Bir girişin ataması: kaynak (`di` | `bridge`), numara, rol, kontak tipi ve bölge.
@immutable
class InputAssignment {
  const InputAssignment({
    required this.src,
    required this.index,
    this.role = InputRole.button,
    this.normallyClosed = false,
    this.zone = 1,
    this.entry,
    this.awayOnly,
  });

  /// `di` (panodaki giriş, 1..40) ya da `bridge` (Zigbee/Thread hub yuvası, 1..16) (K2).
  final String src;
  final int index;
  final InputRole role;

  /// NC kontak (kontak AÇILINCA aktif, `active_open=1`). Gaz/duman için her zaman `true`.
  final bool normallyClosed;
  final int zone;

  /// Hırsız alarmı: giriş yolu (`SF_ENTRY`, gecikmeli) ve yalnız dışarıda kipte etkin (`SF_AWAY_ONLY`). `null` =
  /// türün varsayılanı (F2.B.1: kapı giriş yolu; hareket yalnız dışarıda).
  final bool? entry;
  final bool? awayOnly;

  bool get effectiveEntry => entry ?? role == InputRole.door;
  bool get effectiveAwayOnly => awayOnly ?? role == InputRole.motion;

  /// Firmware `flags` (yalnız hırsız sensöründe): `SF_REACT` + giriş yolu (0x08) + yalnız dışarıda (0x10).
  int get intrusionFlags => 0x01 | (effectiveEntry ? 0x08 : 0) | (effectiveAwayOnly ? 0x10 : 0);

  bool get isBridge => src == 'bridge';

  /// Pano sensör kimliği (`d3`, `b1`).
  String get id => '${isBridge ? 'b' : 'd'}$index';

  /// Gaz/duman NC zorunluluğu uygulanmış hali (arayüz NO seçeneğini zaten göstermez; kayıttan gelen bozuk değer için).
  InputAssignment normalized() =>
      role.requiresNc && !normallyClosed ? copyWith(normallyClosed: true) : this;

  InputAssignment copyWith({InputRole? role, bool? normallyClosed, int? zone, bool? entry, bool? awayOnly}) {
    final nextRole = role ?? this.role;
    final sameRole = nextRole == this.role;
    return InputAssignment(
      src: src,
      index: index,
      role: nextRole,
      normallyClosed: nextRole.requiresNc ? true : (normallyClosed ?? this.normallyClosed),
      zone: (zone ?? this.zone).clamp(1, kMaxSafetyZones),
      // Rol değişince hırsız bayrakları yeni türün varsayılanına döner.
      entry: entry ?? (sameRole ? this.entry : null),
      awayOnly: awayOnly ?? (sameRole ? this.awayOnly : null),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'src': src,
        'i': index,
        'role': role.wire,
        if (normallyClosed) 'nc': true,
        if (zone != 1) 'zone': zone,
        'en': ?entry,
        'ao': ?awayOnly,
      };

  /// Panonun sensör satırı: yapılandırma kopyası (`{src, index, kind, zone, active_open}`) ya da `state.sensors[]`
  /// (`{id: "d3", src, kind, zone}`; kontak tipi state'te yoktur). Tanınmayan tür -> `null`.
  static InputAssignment? fromBoard(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    final src = (asNonEmptyString(json['src']) == 'bridge' || (id?.startsWith('b') ?? false)) ? 'bridge' : 'di';
    final index = asInt(json['index']) ?? (id != null && id.length > 1 ? int.tryParse(id.substring(1)) : null);
    final role = InputRole.parse(json['kind']);
    if (index == null || (role == InputRole.button && asNonEmptyString(json['kind']) != 'button')) return null;
    final flags = asInt(json['flags']);
    final intrusionFlags = role.isIntrusionSensor && flags != null;
    return InputAssignment(
      src: src,
      index: index,
      role: role,
      normallyClosed: (asInt(json['active_open']) ?? 0) == 1,
      zone: (asInt(json['zone']) ?? 1).clamp(1, kMaxSafetyZones),
      entry: intrusionFlags ? (flags & 0x08) != 0 : null,
      awayOnly: intrusionFlags ? (flags & 0x10) != 0 : null,
    ).normalized();
  }

  static InputAssignment? fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final src = asNonEmptyString(map['src']) == 'bridge' ? 'bridge' : 'di';
    final index = asInt(map['i']);
    final max = src == 'bridge' ? kMaxBridgeSlots : 40;
    if (index == null || index < 1 || index > max) return null;
    return InputAssignment(
      src: src,
      index: index,
      role: InputRole.parse(map['role']),
      normallyClosed: asBool(map['nc']) ?? false,
      zone: (asInt(map['zone']) ?? 1).clamp(1, kMaxSafetyZones),
      entry: asBool(map['en']),
      awayOnly: asBool(map['ao']),
    ).normalized();
  }

  @override
  bool operator ==(Object other) =>
      other is InputAssignment &&
      other.src == src &&
      other.index == index &&
      other.role == role &&
      other.normallyClosed == normallyClosed &&
      other.zone == zone &&
      other.entry == entry &&
      other.awayOnly == awayOnly;

  @override
  int get hashCode => Object.hash(src, index, role, normallyClosed, zone, entry, awayOnly);
}

/// Doğrulama bulgusu. [blocking] `true` ise kayıt yapılamaz; `false` uyarıdır (kayıt yapılabilir).
@immutable
class SafetyIssue {
  const SafetyIssue(this.target, this.message, {this.blocking = true});

  /// `relay:<n>`, `input:<id>` ya da `plan`.
  final String target;
  final String message;
  final bool blocking;

  @override
  bool operator ==(Object other) =>
      other is SafetyIssue && other.target == target && other.message == message && other.blocking == blocking;

  @override
  int get hashCode => Object.hash(target, message, blocking);

  @override
  String toString() => 'SafetyIssue($target, ${blocking ? 'engel' : 'uyarı'}: $message)';
}

/// İki röleli vanaların açma röleleri (kanal -> sahibi kapama rölesi).
Map<int, int> openRelayOwnersOf(Map<int, ChannelAssignment> channels) => <int, int>{
      for (final e in channels.entries)
        if (e.value.isValve && e.value.drive == ValveDrive.dual && e.value.openRelay != null) e.value.openRelay!: e.key,
    };

/// Plan emniyet kuralları (§2.4 `validate`, §4.4). Sıra: röleler (numara sırasıyla), girişler, genel.
/// [bridgeSupported] `false` (pano `caps` `bridge` bildirmiyor; sözleşme C1): her kablosuz sensör kayıt engelidir.
List<SafetyIssue> validateSafetyPlan(
  Map<int, ChannelAssignment> channels,
  List<InputAssignment> inputs, {
  bool bridgeSupported = true,
}) {
  final issues = <SafetyIssue>[];
  final owners = <int, int>{};
  final relayIds = channels.keys.toList()..sort();
  final inputByDi = <int, InputAssignment>{
    for (final i in inputs)
      if (!i.isBridge) i.index: i,
  };
  var actuatorCount = 0;

  for (final id in relayIds) {
    final a = channels[id]!;
    final target = 'relay:$id';
    if (!a.use.isActuator) continue;
    if (owners.containsKey(id)) continue; // başka vananın açma rölesi (aşağıda o vanada denetlenir)
    actuatorCount++;
    if (a.isValve) {
      if (a.closeMode == ValveCloseMode.unknown) {
        issues.add(SafetyIssue(target, 'Röle $id: vananın rölede enerji varken kapalı olup olmadığını seçin '
            '(bilmiyorsanız röleyi Aç/Kapat ile deneyip vanayı gözleyin).'));
      }
      if (a.medium == null) {
        issues.add(SafetyIssue(target, 'Röle $id: vananın neyi kestiğini seçin (Su ya da Gaz).'));
      }
      if (a.drive == ValveDrive.dual) {
        final open = a.openRelay;
        if (open == null) {
          issues.add(SafetyIssue(target, 'Röle $id: iki röleli vanada açma rölesini seçin.'));
        } else if (open == id || !channels.containsKey(open)) {
          issues.add(SafetyIssue(target, 'Röle $id: açma rölesi bu kanaldan farklı ve panoda tanımlı bir röle olmalı.'));
        } else if (owners.containsKey(open) || channels[open]!.use.isActuator) {
          issues.add(SafetyIssue(target, 'Röle $id: Röle $open başka bir cihaza atanmış; açma rölesi olarak kullanılamaz.'));
        } else {
          owners[open] = id;
        }
      }
      final fb = a.fbDi;
      if (fb != null) {
        final input = inputByDi[fb];
        if (input == null) {
          issues.add(SafetyIssue(target, 'Röle $id: geri bildirim girişi $fb panoda yok.'));
        } else if (input.role != InputRole.valveFeedback) {
          issues.add(SafetyIssue(target, 'Röle $id: Giriş $fb hem geri bildirim hem "${input.role.label}" olamaz.'));
        }
      }
      if (a.isGasValve) {
        issues.add(SafetyIssue(
          target,
          'Röle $id: Gaz vanası yalnız yerinde düğmeyle açılır; her elektrik kesintisinden ve testten sonra kapalı kalır.',
          blocking: false,
        ));
      }
    }
    if ((a.use == ChannelUse.siren || a.use == ChannelUse.fan) && _zoneHasGas(a.zone, channels, inputs)) {
      issues.add(SafetyIssue(
        target,
        'Röle $id: Röle ve ${a.use == ChannelUse.siren ? 'siren' : 'fan'} gaz kaçağı bölgesinin dışında olmalı.',
        blocking: false,
      ));
    }
  }
  if (actuatorCount > kMaxActuators) {
    issues.add(SafetyIssue('plan', 'En çok $kMaxActuators güvenlik cihazı atanabilir.'));
  }

  var sensorCount = 0;
  for (final input in inputs) {
    final target = 'input:${input.id}';
    if (input.role.isSensor || input.role.isSafetyControl) sensorCount++;
    if (input.role.requiresNc && !input.normallyClosed) {
      issues.add(SafetyIssue(target, '${_inputName(input)}: ${input.role.label} NC (normalde kapalı) bağlanmalı.'));
    }
    if (input.role == InputRole.water && !input.normallyClosed) {
      issues.add(SafetyIssue(
        target,
        '${_inputName(input)}: NO bağlantı seçildi. Kablo koparsa pano bunu algılayamaz; NC ya da EOL dirençli bağlantı önerilir.',
        blocking: false,
      ));
    }
    if (input.isBridge && !bridgeSupported) {
      issues.add(SafetyIssue(target, kBridgeUnsupportedMessage));
    }
    if (input.isBridge && !InputRole.bridgeRoles.contains(input.role)) {
      issues.add(SafetyIssue(target, '${_inputName(input)}: kablosuz yuvaya yalnız sensör atanabilir.'));
    }
    if (input.role == InputRole.valveFeedback && !channels.values.any((a) => a.isValve && a.fbDi == input.index)) {
      issues.add(SafetyIssue(target, '${_inputName(input)}: hiçbir vanaya bağlı değil (vana kartında seçin).', blocking: false));
    }
  }
  if (sensorCount > kMaxSensors) {
    issues.add(SafetyIssue('plan', 'En çok $kMaxSensors sensör atanabilir.'));
  }

  // Vanası olan bölgede o akışkanın sensörü yoksa vana yalnız elle kapatılır (uyarı).
  for (final id in relayIds) {
    final a = channels[id]!;
    if (!a.isValve || a.medium == null || owners.containsKey(id)) continue;
    final role = a.medium == 'gas' ? InputRole.gas : InputRole.water;
    if (!inputs.any((i) => i.role == role && i.zone == a.zone)) {
      issues.add(SafetyIssue(
        'relay:$id',
        'Röle $id: Bölge ${a.zone}\'de ${a.medium == 'gas' ? 'gaz dedektörü' : 'su sensörü'} yok; vana yalnız elle kapatılır.',
        blocking: false,
      ));
    }
  }
  if (channels.values.any((a) => a.isGasValve) && !inputs.any((i) => i.role == InputRole.gasReset)) {
    issues.add(const SafetyIssue(
      'plan',
      'Gaz vanası açma düğmesi tanımlı değil: elle kurmalı (manuel reset) gaz vanası kullanın ya da bir girişi '
          '"Gaz vanası açma düğmesi" yapın.',
      blocking: false,
    ));
  }
  return issues;
}

/// Kablosuz sensör sürücüsü olmayan panoda kayıtlı kablosuz sensör satırının uyarısı (sözleşme C1).
const String kBridgeUnsupportedMessage = 'Bu panoda kablosuz sensör desteklenmiyor; kaldırın.';

bool _zoneHasGas(int zone, Map<int, ChannelAssignment> channels, List<InputAssignment> inputs) =>
    inputs.any((i) => i.role == InputRole.gas && i.zone == zone) ||
    channels.values.any((a) => a.isGasValve && a.zone == zone);

String _inputName(InputAssignment i) => i.isBridge ? 'Kablosuz sensör ${i.index}' : 'Giriş ${i.index}';

/// Plan, panoya yazılacak bir şey içeriyor mu (eylemci, güvenlik sensörü/kumandası ya da dimmer).
bool hasSafetyPlan(Map<int, ChannelAssignment> channels, List<InputAssignment> inputs) =>
    channels.values.any((a) => a.use.isActuator || a.isDimmable) ||
    inputs.any((i) => i.role != InputRole.button && i.role != InputRole.unused);

/// Plan GÜVENLİK içeriyor mu (dimmer dışında): eylemci ya da sensör/kumanda.
bool hasSafetyDevices(Map<int, ChannelAssignment> channels, List<InputAssignment> inputs) =>
    channels.values.any((a) => a.use.isActuator) ||
    inputs.any((i) => i.role.isSensor || i.role.isSafetyControl || i.role == InputRole.valveFeedback);

/// Firmware yama öğesi alanları (`GET /api/safety/config` ile aynı; CONTRACTS §2.6). Mevcut öğe güncellenirken bu
/// alanlar korunur (ör. ad, `fb_timeout_s`), plan yalnız kendi bildiklerinin üstüne yazar.
const List<String> _actuatorKeys = <String>[
  'id',
  'relay',
  'relay2',
  'kind',
  'close_mode',
  'medium',
  'zones',
  'fb_di',
  'fb_closed_active',
  'fb_timeout_s',
  'run_limit_s',
  'exproof',
  'name',
];
const List<String> _sensorKeys = <String>['id', 'kind', 'zone', 'active_open', 'flags', 'confirm_ms', 'name'];

/// Planın bir eylemci kanalı için firmware öğesi (kimliksiz). Geri bildirim girişi ayrı sensör değildir; `fb_di`'dir
/// (`0` = yok). İki röleli vana `close_mode: pulse`, `relay2` = AÇ rölesi, `run_limit_s` = darbe süresi.
Map<String, dynamic> safetyActuatorItem(int relay, ChannelAssignment a) {
  final dual = a.isValve && a.drive == ValveDrive.dual;
  return <String, dynamic>{
    'relay': relay,
    'kind': a.use.wire,
    'zones': <int>[a.zone],
    if (a.isValve) ...<String, dynamic>{
      'close_mode': dual ? 'pulse' : a.closeMode.wire,
      'medium': a.medium,
      'relay2': dual ? (a.openRelay ?? 0) : 0,
      'fb_di': a.fbDi ?? 0,
      if (dual) 'run_limit_s': a.pulseSec,
    },
    if (a.use == ChannelUse.siren) 'run_limit_s': kDefaultSirenRunSec,
    if (a.use == ChannelUse.fan) 'exproof': a.fanExProof,
  };
}

/// Planın bir girişi için firmware sensör öğesi (yalnız algılayıcı ve yerel kumanda rolleri).
/// [intrusion]: pano `caps` `intrusion` ilan ediyor (v1.2.1+). Yalnız o zaman hırsız sensörüne `flags` yazılır: v1.2.0
/// `0x07`'den büyük bayrağı `bad_value` ile reddeder (F2.B.7).
Map<String, dynamic> safetySensorItem(InputAssignment i, {bool intrusion = false}) => <String, dynamic>{
      'id': i.id,
      'kind': i.role.wire,
      'zone': i.zone,
      'active_open': i.normallyClosed ? 1 : 0,
      if (intrusion && i.role.isIntrusionSensor) 'flags': i.intrusionFlags,
    };

/// Varsayılan çıkış / giriş gecikmesi (sn; F2.B.1).
const int kDefaultExitDelaySec = 45;
const int kDefaultEntryDelaySec = 30;

List<Map<String, dynamic>> _items(Object? raw) => <Map<String, dynamic>>[
      for (final item in asList(raw) ?? const <dynamic>[])
        if (asMap(item) != null) asMap(item)!,
    ];

bool _sameValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is bool || b is bool) return asBool(a) == asBool(b);
  if (a is num && b is num) return a == b;
  return a == b;
}

/// [want]'taki her alan [cur]'da aynı mı.
bool _covers(Map<String, dynamic> cur, Map<String, dynamic> want) {
  for (final e in want.entries) {
    if (!_sameValue(cur[e.key], e.value)) return false;
  }
  return true;
}

int _actIndex(String? id) => int.tryParse((id ?? '').replaceFirst('a', '')) ?? 0;

/// Planı panoya yazacak TEK öğelik yamalar (`POST /api/safety/config {base_rev?, set|del}`; CONTRACTS §2.6, firmware
/// F5). [current]: panonun güncel yapılandırması (`GET /api/safety/config`). Yalnız DEĞİŞEN öğe yazılır (gereksiz `rev`
/// artışı ve yerel anahtarla "gevşetme" retleri olmaz). Planın bilmediği pano öğelerine dokunulmaz: yalnız planda başka
/// bir role çevrilen kanalın eylemcisi / girişin sensörü silinir; plandan kaldırılan kablosuz (köprü) sensörü de silinir.
///
/// Sıra (her adım panoda `validate`'ten geçmeli): sensör silme (ör. geri bildirime dönen giriş) -> eylemci silme (büyük
/// kimlikten küçüğe; silme sonraki kimlikleri bir kaydırır) -> mevcut eylemci güncelleme (kaydırılmış kimlikle) -> yeni
/// eylemci (kimliksiz = yeni satır) -> sensör ekleme/güncelleme -> ışık (dimmer) seçenekleri. Yamalar sırayla, her biri
/// bir öncekinin `rev`'iyle gönderilir ([AutomationApiService.applySafetyConfigPatches]).
List<Map<String, dynamic>> buildSafetyPatches({
  required Map<String, dynamic> current,
  required Map<int, ChannelAssignment> channels,
  required List<InputAssignment> inputs,
  bool extEnabled = false,
  int? extAddress,
  bool intrusion = false,
  ({int exit, int entry})? intrusionDelays,
}) {
  final patches = <Map<String, dynamic>>[];
  final owners = openRelayOwnersOf(channels);
  final relayIds = channels.keys.toList()..sort();
  final curActs = _items(current['actuators']);
  final curSens = _items(current['sensors']);
  final curLights = _items(current['lights']);

  // 1) Sensör silme: planda algılayıcı/kumanda OLMAYAN role çevrilen girişler.
  final wantSensors = <String, Map<String, dynamic>>{
    for (final i in inputs)
      if (i.role.isSensor || i.role.isSafetyControl) i.id: safetySensorItem(i, intrusion: intrusion),
  };
  final planInputIds = <String>{for (final i in inputs) i.id};
  for (final cur in curSens) {
    final id = asNonEmptyString(cur['id']);
    // Kablosuz (köprü) yuvalarının tümü plana panodan yüklenir: planda olmayan köprü sensörü "Kaldır" ile çıkarılmıştır ve
    // panodan da silinir (fw-tarama-1, sözleşme C1: v1.3.2 köprü sensörlü tabloya silme dışındaki yamaları reddeder).
    final removedBridge = id != null && id.startsWith('b') && !planInputIds.contains(id);
    if (id == null || wantSensors.containsKey(id) || (!planInputIds.contains(id) && !removedBridge)) continue;
    patches.add(<String, dynamic>{
      'del': <String, dynamic>{'sensor': id},
    });
  }

  // 2) Eylemciler: planda istenen kanallar (iki röleli vananın açma rölesi kendi satırı değildir).
  final wanted = <int, Map<String, dynamic>>{
    for (final id in relayIds)
      if (channels[id]!.use.isActuator && !owners.containsKey(id)) id: safetyActuatorItem(id, channels[id]!),
  };
  final deleted = <int>[]; // silinen eylemci indeksleri (1 tabanlı)
  for (final cur in curActs) {
    final relay = asInt(cur['relay']);
    final index = _actIndex(asNonEmptyString(cur['id']));
    if (relay == null || index < 1 || wanted.containsKey(relay) || !channels.containsKey(relay)) continue;
    deleted.add(index);
  }
  deleted.sort((a, b) => b.compareTo(a));
  for (final index in deleted) {
    patches.add(<String, dynamic>{
      'del': <String, dynamic>{'actuator': 'a$index'},
    });
  }
  final adds = <Map<String, dynamic>>[];
  for (final entry in wanted.entries) {
    Map<String, dynamic>? cur;
    for (final c in curActs) {
      if (asInt(c['relay']) == entry.key) cur = c;
    }
    if (cur == null) {
      adds.add(entry.value);
      continue;
    }
    final index = _actIndex(asNonEmptyString(cur['id']));
    if (index < 1 || deleted.contains(index)) {
      adds.add(entry.value);
      continue;
    }
    if (_covers(cur, entry.value)) continue;
    final shifted = index - deleted.where((d) => d < index).length;
    patches.add(<String, dynamic>{
      'set': <String, dynamic>{
        'actuator': <String, dynamic>{
          for (final k in _actuatorKeys)
            if (cur.containsKey(k)) k: cur[k],
          ...entry.value,
          'id': 'a$shifted',
        },
      },
    });
  }
  for (final item in adds) {
    patches.add(<String, dynamic>{
      'set': <String, dynamic>{'actuator': item},
    });
  }

  // 3) Sensör ekleme / güncelleme (ad ve tür değişmediyse onay süresi/bayraklar korunur).
  for (final want in wantSensors.values) {
    Map<String, dynamic>? cur;
    for (final c in curSens) {
      if (asNonEmptyString(c['id']) == want['id']) cur = c;
    }
    if (cur != null && _covers(cur, want)) continue;
    final sameKind = cur != null && cur['kind'] == want['kind'];
    final keep = <String, dynamic>{
      if (cur != null)
        for (final k in _sensorKeys)
          if (cur.containsKey(k) && (sameKind || (k != 'flags' && k != 'confirm_ms'))) k: cur[k],
    };
    patches.add(<String, dynamic>{
      'set': <String, dynamic>{
        'sensor': <String, dynamic>{...keep, ...want},
      },
    });
  }

  // 3b) Hırsız alarmı gecikmeleri (F2.B.7; yalnız `caps` `intrusion`): değiştiyse tek `intrusion` öğesi.
  if (intrusion && intrusionDelays != null) {
    final cur = asMap(current['intrusion']);
    int effective(Object? raw, int fallback) {
      final v = asInt(raw);
      return (v == null || v <= 0) ? fallback : v;
    }

    final want = <String, dynamic>{
      'exit_s': intrusionDelays.exit.clamp(1, 255),
      'entry_s': intrusionDelays.entry.clamp(1, 255),
    };
    final same = effective(cur?['exit_s'], kDefaultExitDelaySec) == want['exit_s'] &&
        effective(cur?['entry_s'], kDefaultEntryDelaySec) == want['entry_s'];
    if (!same) {
      patches.add(<String, dynamic>{
        'set': <String, dynamic>{'intrusion': want},
      });
    }
  }

  // 4) Işık (dimmer) seçenekleri (K4): `src` 1 = Modbus, 2 = köprü; dimmer'dan çıkan kanal sıfırlanır.
  final dimmable = <int>[for (final id in relayIds) if (channels[id]!.isDimmable) id];
  for (final id in relayIds) {
    final k = dimmable.indexOf(id);
    final modbus = k >= 0 && channels[id]!.dimmerSource == DimmerSource.modbus;
    final want = <String, dynamic>{
      'relay': id,
      'dimmable': k >= 0 ? 1 : 0,
      'src': k < 0 ? 0 : (modbus ? 1 : 2),
      'addr': modbus ? suggestedDimmerAddress(extEnabled: extEnabled, extAddress: extAddress) : 0,
      'ch': modbus ? k + 1 : 0,
    };
    Map<String, dynamic>? cur;
    for (final c in curLights) {
      if (asInt(c['relay']) == id) cur = c;
    }
    if (cur == null ? k < 0 : _covers(cur, want)) continue;
    patches.add(<String, dynamic>{
      'set': <String, dynamic>{'light': want},
    });
  }
  return patches;
}

/// Önerilen dimmer modülü adresi (§4.5): ek modül kapalıysa 2; açıksa ek modül adresi + 1 (247'yi aşarsa bir eksiği).
int suggestedDimmerAddress({required bool extEnabled, int? extAddress}) {
  if (!extEnabled) return 2;
  final ext = (extAddress ?? 1).clamp(1, 247);
  return ext + 1 <= 247 ? ext + 1 : ext - 1;
}

/// K4 dimmer yönergesi (§4.5): yer tutucuları doldurulmuş Türkçe metin. Arayüz bölümleri ayrı ayrı çizer.
@immutable
class DimmerGuide {
  const DimmerGuide({
    required this.intro,
    required this.modbusTitle,
    required this.modbusSteps,
    required this.bridgeTitle,
    required this.bridgeSteps,
    required this.fallback,
    required this.address,
  });

  final String intro;
  final String modbusTitle;
  final List<String> modbusSteps;
  final String bridgeTitle;
  final List<String> bridgeSteps;
  final String fallback;

  /// Önerilen Modbus adresi.
  final int address;

  /// Tüm metin (kopyalama / test).
  String get fullText => <String>[
        intro,
        modbusTitle,
        for (var i = 0; i < modbusSteps.length; i++) '${i + 1}. ${modbusSteps[i]}',
        bridgeTitle,
        for (var i = 0; i < bridgeSteps.length; i++) '${i + 1}. ${bridgeSteps[i]}',
        fallback,
      ].join('\n');
}

/// [relay] kanalı için yönerge. [dimmerChannel]: dimmer modülünün çıkış numarası ({k}); [hubDevice]: köprü seçimi
/// ({seçim}; hub kurulmadıysa `null`).
DimmerGuide dimmerGuideFor({
  required int relay,
  required int dimmerChannel,
  required bool extEnabled,
  int? extAddress,
  String? hubDevice,
}) {
  final address = suggestedDimmerAddress(extEnabled: extEnabled, extAddress: extAddress);
  final extText = extEnabled ? '${(extAddress ?? 1).clamp(1, 247)}' : 'ek modül yok';
  return DimmerGuide(
    intro: 'Bu kanal için dimmer gerekiyor. Panodaki röleler lambayı yalnızca açıp kapatabilir; parlaklık ayarlayamaz. '
        'Parlaklık için aşağıdakilerden birini ekleyin:',
    modbusTitle: 'A) RS485 Modbus dimmer modülü (kablolu, internetsiz çalışır)',
    modbusSteps: <String>[
      'Modülü panonun RS485 A/B klemenslerine, ek röle modülüyle aynı hatta paralel bağlayın (A→A, B→B, ortak GND).',
      'Modülün adresini $address yapın. Bu adres ek modülün adresinden ($extText) farklı olmalı.',
      'Lamba hattını Röle $relay yerine dimmer modülünün Çıkış $dimmerChannel ucuna taşıyın. Röle $relay bundan sonra '
          '"Kullanılmıyor" olarak kalır (ya da dimmerin besleme kontaktörü olarak kullanılabilir).',
      'LED lambalar "dim edilebilir" (dimmable) olmalı; değilse titreme olur.',
    ],
    bridgeTitle: 'B) Zigbee/Thread dimmer (kablosuz)',
    bridgeSteps: <String>[
      'Dimmeri lambanın duvar kutusuna ya da armatüre takın ve ev hub\'ına eşleyin.',
      'Hub panoya yerel olarak bağlı olmalı (bulut gerekmez).',
      'Bu kanalı "Hub cihazı: ${hubDevice ?? 'hub kurulunca seçilir'}" ile eşleyin.',
    ],
    fallback: 'Dimmer takılana kadar bu lamba senaryolarda %N parlaklık yerine "aç" olarak çalışır.',
    address: address,
  );
}

/// Bölge testi sonucu (`test_result {ok, fb_ms}`; §4.4 madde 3).
@immutable
class SafetyTestResult {
  const SafetyTestResult({
    required this.zone,
    this.ok,
    this.fbMs,
    this.hasValve = true,
    this.cloud = false,
    this.hasFeedback = false,
  });

  /// Test bulut üzerinden gönderildi: sonuç yalnız yerel bağlantıda okunur (karar F2-10).
  final bool cloud;

  final int zone;

  /// Bölgede vana var mı (yoksa test yalnız siren/fan/cihaz içindir; kapanma süresi sorulmaz).
  final bool hasValve;

  /// Bölgede geri bildirim girişli (`fb_di`) vana var: pano sonucu kesin bildirir (kapandı / `fb_timeout_s` içinde
  /// kapanmadı); gözle doğrulama sonucun yerini tutmaz.
  final bool hasFeedback;

  /// Pano sonucu: `true` kapandı, `false` zaman aşımı, `null` sonuç okunamadı.
  final bool? ok;

  /// Geri bildirimle ölçülen kapanma süresi (ms); geri bildirim yoksa `null`.
  final int? fbMs;

  String get message {
    if (cloud) {
      return 'Bölge $zone: test gönderildi. Geri bildirim sonucu yalnız yerel bağlantıda görünür; '
          '${hasValve ? 'vananın kapandığını' : 'sirenin / cihazın çalıştığını'} gözle doğrulayın.';
    }
    if (unconfirmed) {
      return 'Bölge $zone: vananın geri bildirim sonucu süre içinde alınamadı; kapandığı doğrulanmadı. '
          'Bölge testini yeniden çalıştırın.';
    }
    if (!hasValve) {
      return ok == false
          ? 'Bölge $zone: test tamamlanamadı; cihaz bağlantısını kontrol edin.'
          : 'Bölge $zone: test gönderildi; sirenin / cihazın çalıştığını gözle doğrulayın.';
    }
    if (ok == false) {
      return 'Bölge $zone: vana süre içinde kapanmadı! Vana bağlantısını ve geri bildirim kontağını kontrol edin.';
    }
    final ms = fbMs;
    if (ok == true && ms != null) {
      final sec = (ms / 1000).toStringAsFixed(1).replaceAll('.', ',');
      return 'Bölge $zone: Vana $sec sn\'de kapandı (geri bildirim doğrulandı).';
    }
    return 'Bölge $zone: Geri bildirim yok: vananın kapandığını gözle doğrulayın.';
  }

  /// Geri bildirimli vananın sonucu alınamadı (servis_kurulum-2): test GEÇMİŞ sayılmaz (pano kapanmayan vanayı ancak
  /// `fb_timeout_s` dolunca bildirir; sonuç gelmediyse vana hâlâ takılı olabilir).
  bool get unconfirmed => !cloud && hasFeedback && ok == null;

  /// Test geçmedi: vana süre içinde kapanmadı (`ok == false`) ya da geri bildirimli vananın sonucu alınamadı
  /// ([unconfirmed]). Adımı tamamlatmaz; "Bölge Testini Yeniden Çalıştır" bu bölgeleri dener.
  bool get failed => ok == false || unconfirmed;
}
