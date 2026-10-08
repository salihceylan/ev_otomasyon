import 'dart:convert';

import 'package:flutter/material.dart';

import '../ui/theme/tokens.dart';
import 'json_utils.dart';

/// Haftanın günleri (0=Pazar, 1=Pazartesi, ... 6=Cumartesi)
const _dayNames = ['Paz', 'Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt'];
const _dayNamesFull = ['Pazar', 'Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi'];

/// Zamanlı otomasyon kuralı (CONTRACTS §1.5: `GET/POST/PUT/DELETE /homes/:homeId/scheduled-rules`).
///
/// * Kimlikler **String**'dir (UUID veya sayısal geçiş kimliği; ikisi de metin olarak taşınır).
/// * `channel` **1 tabanlıdır**: `relay` için röle numarası, `shutter` için panjur çifti (`pair`).
/// * `days_of_week`: `0=Pazar … 6=Cumartesi`, benzersiz tamsayılar (yinelenenler/aralık dışı
///   değer içeren kayıt reddedilir; bozuk bir kayıt listeyi düşürmez).
/// * Kurallar evin saat diliminde (`homes.timezone`) değerlendirilir; `hour`/`minute` o dilimdedir.
class ScheduledRule {
  const ScheduledRule({
    required this.id,
    required this.homeId,
    this.deviceId,
    required this.channel,
    required this.channelType,
    required this.action,
    required this.hour,
    required this.minute,
    required this.daysOfWeek,
    this.label,
    required this.enabled,
    this.createdByName,
    this.creatorActive = true,
  });

  final String id;
  final String homeId;
  final String? deviceId;

  /// 1 tabanlı röle numarası veya panjur çifti.
  final int channel;
  final String channelType; // 'relay' veya 'shutter'
  final String action; // 'on', 'off', 'open', 'close'
  final int hour;
  final int minute;
  final List<int> daysOfWeek; // 0-6, benzersiz
  final String? label;
  final bool enabled;
  final String? createdByName;

  /// Kuralı kuran kişinin bu evde kural yetkisi sürüyor mu (`creator_active`; kullanim-5). `false` ise sunucu kuralı
  /// ÇALIŞTIRMAZ; yetkili bir üye düzenleyip kaydederse kuralı üstlenir. Alan yoksa (eski sunucu) `true`.
  final bool creatorActive;

  static const List<String> validActions = ['on', 'off', 'open', 'close'];
  static const List<String> validChannelTypes = ['relay', 'shutter'];
  static const List<int> allDays = [0, 1, 2, 3, 4, 5, 6];

  /// `days_of_week` ham değerini doğrular. `null` -> her gün. Geçersizse `FormatException`.
  static List<int> parseDays(Object? raw) {
    if (raw == null) return List<int>.of(allDays);
    var value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        throw const FormatException('Geçersiz gün listesi');
      }
    }
    if (value is! List) throw const FormatException('Geçersiz gün listesi');
    final out = <int>{};
    for (final item in value) {
      final day = asInt(item);
      if (day == null || day < 0 || day > 6) throw const FormatException('Geçersiz gün');
      out.add(day);
    }
    return out.toList()..sort();
  }

  factory ScheduledRule.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    if (id == null) throw const FormatException('Kural kimliği yok');
    final channel = asInt(json['channel']);
    final hour = asInt(json['hour']);
    final minute = asInt(json['minute']);
    final action = asNonEmptyString(json['action']);
    if (channel == null || channel < 1 || channel > 64) throw const FormatException('Geçersiz kanal');
    if (hour == null || hour < 0 || hour > 23) throw const FormatException('Geçersiz saat');
    if (minute == null || minute < 0 || minute > 59) throw const FormatException('Geçersiz dakika');
    if (action == null) throw const FormatException('Geçersiz eylem');
    final type = (asNonEmptyString(json['channel_type'] ?? json['channelType']) ?? 'relay').toLowerCase();

    return ScheduledRule(
      id: id,
      homeId: asNonEmptyString(json['home_id'] ?? json['homeId']) ?? '',
      deviceId: asNonEmptyString(json['device_id'] ?? json['deviceId']),
      channel: channel,
      channelType: validChannelTypes.contains(type) ? type : 'relay',
      action: action.toLowerCase(),
      hour: hour,
      minute: minute,
      daysOfWeek: parseDays(json['days_of_week'] ?? json['daysOfWeek']),
      label: asNonEmptyString(json['label']),
      enabled: asBool(json['enabled']) ?? true,
      createdByName: asNonEmptyString(json['created_by_name'] ?? json['createdByName']),
      creatorActive: asBool(json['creator_active'] ?? json['creatorActive']) ?? true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'home_id': homeId,
        'device_id': deviceId,
        'channel': channel,
        'channel_type': channelType,
        'action': action,
        'hour': hour,
        'minute': minute,
        'days_of_week': daysOfWeek,
        'label': label,
        'enabled': enabled,
      };

  /// Girdi doğrulaması: geçerliyse `null`, değilse kullanıcıya gösterilebilir mesaj.
  static String? validate({
    required int channel,
    required String channelType,
    required String action,
    required int hour,
    required int minute,
    required List<int> daysOfWeek,
  }) {
    if (channel < 1 || channel > 64) return 'Kanal numarası 1 ile 64 arasında olmalıdır.';
    if (!validChannelTypes.contains(channelType)) return 'Geçersiz kanal tipi.';
    if (!validActions.contains(action)) return 'Geçersiz eylem.';
    if (hour < 0 || hour > 23) return 'Saat 0 ile 23 arasında olmalıdır.';
    if (minute < 0 || minute > 59) return 'Dakika 0 ile 59 arasında olmalıdır.';
    if (daysOfWeek.isEmpty) return 'En az bir gün seçmelisiniz.';
    if (daysOfWeek.any((d) => d < 0 || d > 6)) return 'Geçersiz gün seçimi.';
    if (daysOfWeek.toSet().length != daysOfWeek.length) return 'Günler tekrar edemez.';
    return null;
  }

  /// `POST` gövdesi (snake_case; `channel` 1 tabanlı).
  static Map<String, dynamic> createPayload({
    required int channel,
    required String channelType,
    required String action,
    required int hour,
    required int minute,
    required List<int> daysOfWeek,
    String? label,
    String? deviceId,
    bool enabled = true,
  }) {
    final cleanLabel = label?.trim();
    return <String, dynamic>{
      'channel': channel,
      'channel_type': channelType,
      'action': action,
      'hour': hour,
      'minute': minute,
      'days_of_week': List<int>.of(daysOfWeek)..sort(),
      'device_id': ?deviceId,
      'label': ?((cleanLabel == null || cleanLabel.isEmpty) ? null : cleanLabel),
      'enabled': enabled,
    };
  }

  /// "22:30" formatında saat
  String get timeString =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Kısa gün isimleri: "Pzt Sal Çar"
  String get daysShortString {
    if (daysOfWeek.length == 7) return 'Her gün';
    if (daysOfWeek.isEmpty) return 'Gün seçilmedi';
    final sorted = List<int>.from(daysOfWeek)..sort();
    return sorted.map((d) => _dayNames[d]).join(' ');
  }

  /// Eylem ikonu
  IconData get actionIcon {
    switch (action) {
      case 'on':
        return Icons.lightbulb;
      case 'off':
        return Icons.lightbulb_outline;
      case 'open':
        return Icons.expand;
      case 'close':
        return Icons.compress;
      default:
        return Icons.timer;
    }
  }

  /// Eylemin Neon Glass renk ailesi (şartname §2.1; ham Material aksanları yerine): lamba AÇ = amber, lamba KAPAT =
  /// slate (nötr/pasif), panjur AÇ = emerald, panjur KAPAT = sky, diğer = cyan. Orb, çip ve kart vurgusu aynı
  /// aileden türer; böylece aynı eylem ekranlar arasında aynı renkte görünür (panjur kartıyla uyumlu).
  AccentFamily get family {
    switch (action) {
      case 'on':
        return AppFamilies.amber;
      case 'off':
        return AppFamilies.slate;
      case 'open':
        return AppFamilies.emerald;
      case 'close':
        return AppFamilies.sky;
      default:
        return AppFamilies.cyan;
    }
  }

  /// Eylem rengi (aile ana tonu).
  Color get actionColor => family.base;

  /// Eylem metni
  String get actionLabel {
    switch (action) {
      case 'on':
        return 'Aç';
      case 'off':
        return 'Kapat';
      case 'open':
        return 'Aç';
      case 'close':
        return 'Kapat';
      default:
        return action;
    }
  }

  /// Kanal etiketi (kanal **1 tabanlıdır**; ek bir `+1` uygulanmaz).
  String get channelLabel {
    final typeName = channelType == 'shutter' ? 'Panjur' : 'Röle';
    return label ?? '$typeName $channel';
  }

  /// Haftanın günleri tam isimler
  static List<String> get allDayNamesFull => _dayNamesFull;

  ScheduledRule copyWith({
    bool? enabled,
    String? label,
    int? hour,
    int? minute,
    List<int>? daysOfWeek,
    String? action,
  }) {
    return ScheduledRule(
      id: id,
      homeId: homeId,
      deviceId: deviceId,
      channel: channel,
      channelType: channelType,
      action: action ?? this.action,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      daysOfWeek: daysOfWeek ?? this.daysOfWeek,
      label: label ?? this.label,
      enabled: enabled ?? this.enabled,
      createdByName: createdByName,
      creatorActive: creatorActive,
    );
  }
}
