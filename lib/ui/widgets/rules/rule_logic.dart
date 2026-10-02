import '../../../models/cloud_models.dart';
import '../../../models/endpoint_sync.dart';
import '../../../models/scheduled_rule_model.dart';

/// Zamanlı kural için seçilebilir kanal (evin **gerçek** uç noktalarından). `channel` **1 tabanlıdır**:
/// röle için röle numarası, panjur için panjur çifti (`pair`).
class RuleChannelOption {
  const RuleChannelOption({
    required this.type,
    required this.channel,
    required this.label,
    this.impulse = false,
    this.deviceId,
  });

  /// `relay` | `shutter`.
  final String type;
  final int channel;
  final String label;

  /// Darbe (tetik) rölesi: yalnızca "tetikle" eylemi anlamlıdır.
  final bool impulse;

  /// Kanalın bağlı olduğu cihazın iç kimliği (çok panolu evde kuralın hedefi; bilinmiyorsa `null`).
  final String? deviceId;

  bool get isShutter => type == 'shutter';

  /// Açılır listede değer olarak kullanılan benzersiz kimlik.
  String get id => '${type}_$channel';

  /// Bu kanal için geçerli eylemler.
  List<String> get actions => isShutter
      ? const <String>['open', 'close']
      : (impulse ? const <String>['on'] : const <String>['on', 'off']);

  /// Kanal türüne göre eylemin kullanıcıya gösterilen adı.
  String actionLabel(String action) {
    if (impulse && action == 'on') return 'Tetikle';
    switch (action) {
      case 'on':
      case 'open':
        return 'Aç';
      case 'off':
      case 'close':
        return 'Kapat';
    }
    return action;
  }
}

/// Evin uç noktalarından kanal seçeneklerini üretir:
///
/// * röle seçenekleri **panjur satırlarını içermez** (panjur çifti röleleri "röle" listesinde yoktur),
/// * her panjur çifti tek bir "panjur" seçeneğidir (`channel` = çift numarası, 1 tabanlı),
/// * aynı kanal bir kez listelenir ve kanala göre sıralanır.
List<RuleChannelOption> ruleChannelOptions(List<EndpointModel> endpoints) {
  final relays = <int, RuleChannelOption>{};
  for (final endpoint in endpoints) {
    if (endpoint.isShutter) continue;
    relays.putIfAbsent(
      endpoint.channel,
      () => RuleChannelOption(
        type: 'relay',
        channel: endpoint.channel,
        label: 'Röle ${endpoint.channel} — ${endpoint.name}',
        impulse: endpoint.isImpulse,
        deviceId: endpoint.deviceId,
      ),
    );
  }
  final relayList = relays.values.toList()..sort((a, b) => a.channel.compareTo(b.channel));

  final shutterList = <RuleChannelOption>[
    for (final endpoint in primaryShutterEndpoints(endpoints))
      RuleChannelOption(
        type: 'shutter',
        channel: endpoint.pair,
        label: 'Panjur ${endpoint.pair} — ${shutterBaseName(endpoint.name, fallback: 'Panjur ${endpoint.pair}')}',
        deviceId: endpoint.deviceId,
      ),
  ];
  return <RuleChannelOption>[...relayList, ...shutterList];
}

/// Mevcut bir kuralın kanalının okunur adı (uç nokta bulunamazsa "Röle N"/"Panjur N").
String ruleChannelName(ScheduledRule rule, List<RuleChannelOption> options) {
  for (final option in options) {
    if (option.type == rule.channelType && option.channel == rule.channel) {
      // "Röle 3 — Salon Avize" -> yalnızca ad kısmı, etiket yoksa kısa form.
      final index = option.label.indexOf('—');
      return index < 0 ? option.label : option.label.substring(index + 1).trim();
    }
  }
  return '${rule.channelType == 'shutter' ? 'Panjur' : 'Röle'} ${rule.channel}';
}

/// Çakışma türü.
enum RuleConflictKind {
  /// Aynı kanal, saat ve eylem (en az bir ortak günde): yinelenen kural.
  duplicate,

  /// Aynı kanal ve saatte **ters** eylem (aç ↔ kapat): sonuç belirsiz olur.
  opposite,
}

class RuleConflict {
  const RuleConflict(this.rule, this.kind);

  final ScheduledRule rule;
  final RuleConflictKind kind;
}

/// Aday kuralla çakışan **etkin** kurallar: aynı kanal türü/numarası, aynı saat:dakika ve en az bir
/// ortak gün. [ignoreId] düzenlenen kuralın kendisini dışlar.
List<RuleConflict> findRuleConflicts(
  List<ScheduledRule> existing, {
  required String channelType,
  required int channel,
  required String action,
  required int hour,
  required int minute,
  required List<int> daysOfWeek,
  String? ignoreId,
}) {
  final days = daysOfWeek.toSet();
  final out = <RuleConflict>[];
  for (final rule in existing) {
    if (rule.id == ignoreId || !rule.enabled) continue;
    if (rule.channelType != channelType || rule.channel != channel) continue;
    if (rule.hour != hour || rule.minute != minute) continue;
    if (rule.daysOfWeek.toSet().intersection(days).isEmpty) continue;
    out.add(RuleConflict(
      rule,
      rule.action == action ? RuleConflictKind.duplicate : RuleConflictKind.opposite,
    ));
  }
  return out;
}

/// Ev saat diliminin okunur gösterimi (Türkiye için UTC farkı da yazılır).
String homeTimezoneLabel(String timezone) {
  final tz = timezone.trim().isEmpty ? 'Europe/Istanbul' : timezone.trim();
  if (tz == 'Europe/Istanbul' || tz == 'Asia/Istanbul' || tz == 'Turkey') {
    return 'Türkiye saati ($tz, UTC+3)';
  }
  return tz;
}
