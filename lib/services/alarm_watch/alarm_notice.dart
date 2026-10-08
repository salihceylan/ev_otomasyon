import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/automation_models.dart';
import '../../ui/widgets/safety_labels.dart' show safetyKindInstruction, safetyKindTitle, valveFaultText;
import '../push/peace_notice.dart';
import '../push/safety_notice.dart';

// =============================================================================
// Pano `state` geçişi -> telefon bildirimi eşlemesi (saf; arka plan servisi kullanır).
//
// Uygulama MQTT kimliği yalnız `ev/{t}/state` ve `ev/{t}/status` konularına abone olabilir (sunucu ACL'si; `ev/{t}/event`
// YOK, CONTRACTS §2.2/§2.6). Bu yüzden alarmlar ardışık `state` görüntülerinden türetilir: bölge kilidi (su/gaz/duman),
// vana arızası, güvenli kip ve hırsız alarmı (`safety.arm.st = alarm`). Metinler uygulama içi alarm kartıyla aynıdır.
// =============================================================================

/// Bildirimin türü (dokununca yönlendirme ve kanal aynı: "Güvenlik alarmları").
enum AlarmNoticeType { alarm, valveFault, safeMode, intrusion }

/// Gösterilecek bildirim.
@immutable
class AlarmNotice {
  const AlarmNotice({
    required this.type,
    required this.dedupeKey,
    required this.notificationId,
    required this.title,
    required this.body,
    required this.homeId,
    this.deviceUid,
    this.zone,
    this.kind = 'generic',
  });

  final AlarmNoticeType type;

  /// Aynı alarmın ikinci kez bildirilmemesi için anahtar (alarm kimliği `aid` dahil).
  final String dedupeKey;

  /// Sistem bildirim kimliği (aynı bölgenin bildirimi güncellenir / alarm kalkınca silinir).
  final int notificationId;
  final String title;
  final String body;
  final String homeId;
  final String? deviceUid;
  final int? zone;
  final String kind;

  /// Bildirime dokununca uygulamaya dönen yük (kişisel veri: yalnız kimlikler; ev adı yok).
  String get payload => jsonEncode(<String, dynamic>{
        'v': 1,
        't': type.name,
        'h': homeId,
        if (deviceUid != null) 'u': deviceUid,
        if (zone != null) 'z': zone,
        'k': kind,
      });

  @override
  String toString() => 'AlarmNotice(${type.name}, zone=$zone, kind=$kind)';
}

/// Bildirimi kaldırma (alarm kalktı / arıza düzeldi / güvenli kipten çıkıldı).
@immutable
class AlarmNoticeCancel {
  const AlarmNoticeCancel({required this.notificationId, this.forgetKey, this.forgetPrefix});

  final int notificationId;

  /// Kimliksiz (aid'siz) kaydın tekilleştirme anahtarı: kalkınca silinir, yeniden alarm olursa yine bildirilir.
  final String? forgetKey;
  final String? forgetPrefix;
}

/// Eşleme sonucu.
@immutable
class AlarmNoticePlan {
  const AlarmNoticePlan({this.show = const <AlarmNotice>[], this.cancel = const <AlarmNoticeCancel>[]});

  final List<AlarmNotice> show;
  final List<AlarmNoticeCancel> cancel;

  bool get isEmpty => show.isEmpty && cancel.isEmpty;
}

/// Kararlı (süreçten bağımsız) 31 bitlik FNV-1a özeti: servis yeniden başlasa da aynı bölgenin bildirim kimliği aynı
/// kalır (önceki süreçte gösterilen bildirim silinebilsin). 1000'in altı ön plan servisine ayrılır.
int stableNotificationId(String text) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(text)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return 1000 + (hash & 0x3FFFFFFF);
}

String _homeLabel(String homeName) => homeName.trim().isEmpty ? 'Eviniz' : homeName.trim();

/// [before] (`null` = ilk görüntü) -> [after] geçişinin bildirimleri. [sensorName] sensör kimliğinin adını verir
/// (yapılandırma kopyasından; bilinmiyorsa `null`).
AlarmNoticePlan planAlarmNotices({
  required String homeId,
  required String homeName,
  required SafetyState? before,
  required SafetyState after,
  String? Function(String sensorId)? sensorName,
}) {
  if (!after.supported) return const AlarmNoticePlan();
  final uid = after.deviceUid ?? '-';
  final home = _homeLabel(homeName);
  final show = <AlarmNotice>[];
  final cancel = <AlarmNoticeCancel>[];

  String sourceLabel(List<String> sources, int? zone) {
    for (final id in sources) {
      final name = sensorName?.call(id);
      if (name != null && name.trim().isNotEmpty && name.trim() != id) return name.trim();
    }
    return zone == null ? 'sensör' : 'Bölge $zone';
  }

  int zoneId(String prefix, int zone) => stableNotificationId('$prefix|$homeId|$uid|$zone');

  for (final event in SafetyEvent.between(before, after)) {
    final zone = event.zone;
    switch (event.type) {
      case SafetyEventType.alarmRaised:
        if (zone == null) continue;
        final alarm = after.alarmForZone(zone);
        final kind = alarm?.kind ?? event.kind ?? 'unknown';
        final title = '${safetyKindTitle(kind)}: ${sourceLabel(alarm?.sources ?? const <String>[], zone)} — $home';
        show.add(AlarmNotice(
          type: AlarmNoticeType.alarm,
          dedupeKey: 'z|$homeId|$uid|$zone|${event.aid ?? '-'}',
          notificationId: zoneId('z', zone),
          title: title,
          body: safetyKindInstruction(kind) ?? 'Alarmı görmek ve vanayı yönetmek için dokunun.',
          homeId: homeId,
          deviceUid: after.deviceUid,
          zone: zone,
          kind: kind,
        ));
      case SafetyEventType.valveFault:
        if (zone == null) continue;
        final kind = after.alarmForZone(zone)?.kind ?? event.kind ?? 'unknown';
        show.add(AlarmNotice(
          type: AlarmNoticeType.valveFault,
          dedupeKey: 'f|$homeId|$uid|$zone|${event.aid ?? '-'}',
          notificationId: zoneId('f', zone),
          title: 'Vana kapanmadı (arıza) — $home',
          body: valveFaultText(kind),
          homeId: homeId,
          deviceUid: after.deviceUid,
          zone: zone,
          kind: kind,
        ));
      case SafetyEventType.valveFaultCleared:
        if (zone == null) continue;
        cancel.add(AlarmNoticeCancel(notificationId: zoneId('f', zone), forgetPrefix: 'f|$homeId|$uid|$zone|-'));
      case SafetyEventType.safeModeEntered:
        show.add(AlarmNotice(
          type: AlarmNoticeType.safeMode,
          dedupeKey: 's|$homeId|$uid',
          notificationId: stableNotificationId('s|$homeId|$uid'),
          title: 'Pano güvenli kipe girdi — $home',
          body: 'Pano güvenli kipte; vanalar açılamaz. Kurulumcunuza başvurun.',
          homeId: homeId,
          deviceUid: after.deviceUid,
        ));
      case SafetyEventType.safeModeExited:
        cancel.add(AlarmNoticeCancel(notificationId: stableNotificationId('s|$homeId|$uid'), forgetKey: 's|$homeId|$uid'));
      case SafetyEventType.alarmCleared: // aşağıda bölge durumundan (firmware normal bölgeyi listeye yazmaz)
      case SafetyEventType.alarmSilenced:
      case SafetyEventType.sensorFault:
      case SafetyEventType.sensorFaultCleared:
      case SafetyEventType.commandRejected:
        break;
    }
  }

  // Alarm kalktı: firmware normal bölgeyi `safety.zones[]`'a YAZMAZ (yokluk = normal; CONTRACTS §2.6), bu yüzden kalkış
  // olay listesinden değil bölge durumundan anlaşılır.
  if (before != null && before.supported) {
    for (var zone = 1; zone <= 4; zone++) {
      if (!before.zoneStatus(zone).isAlarm || after.zoneStatus(zone).isAlarm) continue;
      cancel
        ..add(AlarmNoticeCancel(notificationId: zoneId('z', zone), forgetPrefix: 'z|$homeId|$uid|$zone|-'))
        ..add(AlarmNoticeCancel(notificationId: zoneId('f', zone), forgetPrefix: 'f|$homeId|$uid|$zone|-'));
    }
  }

  // Güvenli kip yoksa (ilk görüntü dahil) kaydı unut: servis kapalıyken çıkılmış olabilir, yeniden girişte bildirilsin.
  if (before == null) {
    if (!after.safeMode) {
      cancel.add(AlarmNoticeCancel(notificationId: stableNotificationId('s|$homeId|$uid'), forgetKey: 's|$homeId|$uid'));
    }
    // Kimliksiz (aid'siz) bölge alarmı servis kapalıyken kalkmış olabilir: normal bölgelerin kaydı unutulur.
    for (var zone = 1; zone <= 4; zone++) {
      if (after.zoneStatus(zone).isAlarm) continue;
      cancel.add(AlarmNoticeCancel(notificationId: zoneId('z', zone), forgetPrefix: 'z|$homeId|$uid|$zone|-'));
    }
  }

  // Hırsız alarmı (`safety.arm`; olay konusu uygulamaya kapalı olduğu için state'ten).
  final arm = after.arm;
  final wasArm = (before?.supported ?? false) ? before!.arm : null;
  final intrusionId = stableNotificationId('i|$homeId|$uid');
  if (arm != null && arm.isAlarm) {
    final changed = wasArm == null || !wasArm.isAlarm || (arm.aid != null && arm.aid != wasArm.aid);
    if (changed) {
      show.add(AlarmNotice(
        type: AlarmNoticeType.intrusion,
        dedupeKey: 'i|$homeId|$uid|${arm.aid ?? '-'}',
        notificationId: intrusionId,
        title: 'Hırsız alarmı: ${sourceLabel(arm.srcs, null)} — $home',
        body: 'Evinizde izinsiz giriş algılandı. Ayrıntılar için dokunun.',
        homeId: homeId,
        deviceUid: after.deviceUid,
        kind: 'intrusion',
      ));
    }
  } else if (wasArm != null && wasArm.isAlarm) {
    cancel.add(AlarmNoticeCancel(notificationId: intrusionId, forgetPrefix: 'i|$homeId|$uid|-'));
  }

  return AlarmNoticePlan(
    show: List<AlarmNotice>.unmodifiable(show),
    cancel: List<AlarmNoticeCancel>.unmodifiable(cancel),
  );
}

/// Bildirime dokunuşun yükünü uygulamanın mevcut alarm yönlendirmesine ([SafetyPushNotice], "opened") çevirir.
/// Bozuk/yabancı yük `null`.
SafetyPushNotice? alarmPayloadToNotice(String? payload, {DateTime? now}) {
  if (payload == null || payload.isEmpty || payload.length > 1024) return null;
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != 1) return null;
    final home = map['h'];
    if (home is! String || home.isEmpty) return null;
    final uid = map['u'];
    final zone = map['z'];
    final kind = map['k'];
    final type = map['t'];
    final deviceUuid = uid is String && uid.isNotEmpty ? uid.toUpperCase() : null;
    final received = now ?? DateTime.now();
    if (type == AlarmNoticeType.safeMode.name) {
      // Güvenli kip: etkin alarm kartı varsa ona, yoksa panoya ("alarm_lost" yönlendirmesiyle aynı karar).
      return SafetyPushNotice(
        type: SafetyPushType.info,
        homeId: home,
        deviceId: deviceUuid ?? home,
        deviceUuid: deviceUuid,
        kind: 'generic',
        reason: 'alarm_lost',
        source: PeaceNoticeSource.opened,
        receivedAt: received,
      );
    }
    if (type != AlarmNoticeType.alarm.name &&
        type != AlarmNoticeType.valveFault.name &&
        type != AlarmNoticeType.intrusion.name) {
      return null;
    }
    final k = kind is String && SafetyPushNotice.knownKinds.contains(kind) ? kind : 'generic';
    return SafetyPushNotice(
      type: SafetyPushType.alarm,
      homeId: home,
      deviceId: deviceUuid ?? home,
      deviceUuid: deviceUuid,
      zone: zone is int ? zone : null,
      kind: type == AlarmNoticeType.intrusion.name ? 'intrusion' : k,
      status: type == AlarmNoticeType.valveFault.name ? 'fault' : 'latched',
      source: PeaceNoticeSource.opened,
      receivedAt: received,
    );
  } catch (_) {
    return null;
  }
}
