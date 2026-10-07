import 'package:flutter/foundation.dart';

import 'peace_notice.dart';

/// Güvenlik push'unun türü (`data.type`).
enum SafetyPushType {
  /// `safety_alarm`: alarm açıldı / vana arızası (owner + resident).
  alarm,

  /// `safety_info`: alarm doğrulanamadı, politika değişti, bekleyen yapılandırma düştü (owner).
  info,
}

/// Sunucunun güvenlik bildirimi (CONTRACTS §2.5 "Güvenlik push'u"; Faz 2 tasarımı F2.C.3).
///
/// [PeaceNotice] deseninde: FCM `data` güvenilmeyen girdidir; yalnız [tryParse] ile, sıkı doğrulamadan geçerek üretilir.
/// Geçersiz her şey `null` olur ve hiçbir koşulda istisna fırlatılmaz. Değerler FCM'de hep metindir; metin olmayan
/// değer (ör. gerçek `int`) bozuk mesaj işaretidir ve reddedilir.
@immutable
class SafetyPushNotice {
  const SafetyPushNotice({
    required this.type,
    required this.homeId,
    required this.deviceId,
    required this.kind,
    required this.source,
    required this.receivedAt,
    this.deviceUuid,
    this.alarmId,
    this.zone,
    this.status,
    this.reason,
    this.title,
    this.body,
  });

  static const String alarmTypeValue = 'safety_alarm';
  static const String infoTypeValue = 'safety_info';
  static const String supportedVersion = '1';

  /// Tanınan alarm türleri; başka kısa kod `generic` olur (gösterimde "Güvenlik alarmı").
  static const Set<String> knownKinds = <String>{'water', 'gas', 'smoke', 'intrusion'};
  static const Set<String> alarmStatuses = <String>{'latched', 'fault'};
  static const Set<String> infoReasons = <String>{'alarm_lost', 'policy_off', 'policy_on', 'cfg_pending_dropped'};

  static const int _maxIdLength = 64;
  static const int _maxTitleLength = 120;
  static const int _maxBodyLength = 300;
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _uuidPattern = RegExp(r'^[A-Z0-9-]{1,32}$');
  static final RegExp _digitsPattern = RegExp(r'^[0-9]{1,18}$');
  static final RegExp _kindPattern = RegExp(r'^[a-z_]{1,24}$');

  final SafetyPushType type;
  final String homeId;

  /// Sunucunun cihaz kimliği (`devices.id`).
  final String deviceId;

  /// Panonun `uid`'si (`devices.device_uuid`; F2.C.8 ek alan). Kritik alarm kartının anahtarı bununla kurulur. Eski
  /// sunucu yazmaz: `null` (kart bölgeyle aranır).
  final String? deviceUuid;

  /// Sunucudaki alarm kaydı kimliği (rakam metni); bilgi bildiriminde olmayabilir.
  final String? alarmId;

  /// 1..4, yalnız alarm.
  final int? zone;

  /// `water|gas|smoke|intrusion|generic`.
  final String kind;

  /// Alarm: `latched|fault`.
  final String? status;

  /// Bilgi: `alarm_lost|policy_off|policy_on|cfg_pending_dropped`.
  final String? reason;
  final String? title;
  final String? body;
  final PeaceNoticeSource source;
  final DateTime receivedAt;

  bool get isAlarm => type == SafetyPushType.alarm;
  bool get isIntrusion => kind == 'intrusion';

  /// Tekilleştirme anahtarı: alarm `a:<alarm_id>:<status>` (aynı alarmın `fault` push'u ayrı bildirimdir), bilgi
  /// `i:<alarm_id|home_id>:<reason>`. Önekler gece hatırlatmasınınkilerle (`n:`, `h:`) çakışmaz.
  String get dedupeKey => isAlarm ? 'a:$alarmId:$status' : 'i:${alarmId ?? homeId}:$reason';

  /// [data] FCM `data` haritası. Tür `safety_alarm`/`safety_info` değilse `null` (gece hatırlatması ayrıştırıcısına
  /// bırakılır).
  static SafetyPushNotice? tryParse(
    Map<String, dynamic> data, {
    String? title,
    String? body,
    PeaceNoticeSource source = PeaceNoticeSource.foreground,
    DateTime? now,
  }) {
    try {
      final rawType = data['type'];
      final SafetyPushType type;
      if (rawType == alarmTypeValue) {
        type = SafetyPushType.alarm;
      } else if (rawType == infoTypeValue) {
        type = SafetyPushType.info;
      } else {
        return null;
      }
      if (data['v'] != supportedVersion) return null;

      final homeId = _id(data['home_id']);
      final deviceId = _id(data['device_id']);
      if (homeId == null || deviceId == null) return null;

      final rawUuid = data['device_uuid'];
      String? deviceUuid;
      if (rawUuid != null && rawUuid != '') {
        if (rawUuid is! String || !_uuidPattern.hasMatch(rawUuid)) return null;
        deviceUuid = rawUuid;
      }

      final rawAlarmId = data['alarm_id'];
      String? alarmId;
      if (rawAlarmId != null && rawAlarmId != '') {
        if (rawAlarmId is! String || !_digitsPattern.hasMatch(rawAlarmId)) return null;
        alarmId = rawAlarmId;
      }

      final rawKind = data['kind'];
      var kind = 'generic';
      if (rawKind != null && rawKind != '') {
        if (rawKind is! String || !_kindPattern.hasMatch(rawKind)) return null;
        kind = knownKinds.contains(rawKind) ? rawKind : 'generic';
      }

      int? zone;
      String? status;
      String? reason;
      if (type == SafetyPushType.alarm) {
        if (alarmId == null) return null;
        final rawZone = data['zone'];
        if (rawZone is! String || !RegExp(r'^[1-4]$').hasMatch(rawZone)) return null;
        zone = int.parse(rawZone);
        final rawStatus = data['status'];
        if (rawStatus is! String || !alarmStatuses.contains(rawStatus)) return null;
        status = rawStatus;
      } else {
        final rawReason = data['reason'];
        if (rawReason is! String || !infoReasons.contains(rawReason)) return null;
        reason = rawReason;
      }

      return SafetyPushNotice(
        type: type,
        homeId: homeId,
        deviceId: deviceId,
        deviceUuid: deviceUuid,
        alarmId: alarmId,
        zone: zone,
        kind: kind,
        status: status,
        reason: reason,
        title: PeaceNotice.sanitizeText(title, _maxTitleLength),
        body: PeaceNotice.sanitizeText(body, _maxBodyLength),
        source: source,
        receivedAt: now ?? DateTime.now(),
      );
    } catch (_) {
      // Düşmanca/bozuk girdi hiçbir zaman uygulamayı düşürmez.
      return null;
    }
  }

  static String? _id(Object? raw) {
    if (raw is! String || raw.isEmpty || raw.length > _maxIdLength || !_idPattern.hasMatch(raw)) return null;
    return raw;
  }

  /// Aynı bildirimin farklı kaynaktan (ör. `foreground` sonra `opened`) gelen kopyası.
  SafetyPushNotice withSource(PeaceNoticeSource next) => SafetyPushNotice(
        type: type,
        homeId: homeId,
        deviceId: deviceId,
        deviceUuid: deviceUuid,
        alarmId: alarmId,
        zone: zone,
        kind: kind,
        status: status,
        reason: reason,
        title: title,
        body: body,
        source: next,
        receivedAt: receivedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is SafetyPushNotice &&
      other.type == type &&
      other.homeId == homeId &&
      other.deviceId == deviceId &&
      other.deviceUuid == deviceUuid &&
      other.alarmId == alarmId &&
      other.zone == zone &&
      other.kind == kind &&
      other.status == status &&
      other.reason == reason &&
      other.title == title &&
      other.body == body &&
      other.source == source &&
      other.receivedAt == receivedAt;

  @override
  int get hashCode =>
      Object.hash(type, homeId, deviceId, deviceUuid, alarmId, zone, kind, status, reason, title, body, source, receivedAt);

  /// Ev kimliği, başlık ve gövde (kişisel veri) log'a düşmesin diye yazdırılmaz.
  @override
  String toString() =>
      'SafetyPushNotice(${type.name}, alarm: $alarmId, zone: $zone, kind: $kind, ${status ?? reason}, ${source.name})';
}
