import 'package:flutter/material.dart';

/// Haftanın günleri (0=Pazar, 1=Pazartesi, ... 6=Cumartesi)
const _dayNames = ['Paz', 'Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt'];
const _dayNamesFull = ['Pazar', 'Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi'];

class ScheduledRule {
  final int id;
  final int homeId;
  final int? deviceId;
  final int channel;
  final String channelType; // 'relay' veya 'shutter'
  final String action;      // 'on', 'off', 'open', 'close'
  final int hour;
  final int minute;
  final List<int> daysOfWeek; // 0-6
  final String? label;
  final bool enabled;
  final String? createdByName;

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
  });

  factory ScheduledRule.fromJson(Map<String, dynamic> json) {
    List<int> parseDays(dynamic raw) {
      if (raw == null) return [0, 1, 2, 3, 4, 5, 6];
      if (raw is List) return raw.map((e) => (e as num).toInt()).toList();
      return [0, 1, 2, 3, 4, 5, 6];
    }

    return ScheduledRule(
      id: json['id'] as int,
      homeId: json['home_id'] as int,
      deviceId: json['device_id'] as int?,
      channel: json['channel'] as int,
      channelType: (json['channel_type'] as String?) ?? 'relay',
      action: json['action'] as String,
      hour: json['hour'] as int,
      minute: json['minute'] as int,
      daysOfWeek: parseDays(json['days_of_week']),
      label: json['label'] as String?,
      enabled: (json['enabled'] as bool?) ?? true,
      createdByName: json['created_by_name'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
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
      case 'on': return Icons.lightbulb;
      case 'off': return Icons.lightbulb_outline;
      case 'open': return Icons.expand;
      case 'close': return Icons.compress;
      default: return Icons.timer;
    }
  }

  /// Eylem rengi
  Color get actionColor {
    switch (action) {
      case 'on': return Colors.amber;
      case 'off': return Colors.blueGrey;
      case 'open': return Colors.greenAccent;
      case 'close': return Colors.deepOrangeAccent;
      default: return Colors.cyanAccent;
    }
  }

  /// Eylem metni
  String get actionLabel {
    switch (action) {
      case 'on': return 'Aç';
      case 'off': return 'Kapat';
      case 'open': return 'Aç';
      case 'close': return 'Kapat';
      default: return action;
    }
  }

  /// Kanal etiketi
  String get channelLabel {
    final typeName = channelType == 'shutter' ? 'Panjur' : 'Röle';
    return label ?? '$typeName ${channel + 1}';
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
    );
  }
}

