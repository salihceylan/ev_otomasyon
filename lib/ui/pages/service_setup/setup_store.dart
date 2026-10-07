import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/json_utils.dart';

/// Bir cihazın kurulum ilerlemesi (yarıda bırakıp devam etmek için).
///
/// **Gizli değer içermez**: cihaz anahtarı, kurulum PIN'i, müşteri kodu (OTP), bulut kimliği,
/// Wi-Fi şifresi ve QR içeriği bu kayda ASLA yazılmaz. Müşteri iletişimi yalnızca maskeli
/// ([customerHint]) tutulur.
@immutable
class SetupProgressRecord {
  const SetupProgressRecord({
    required this.ownerKey,
    required this.deviceUuid,
    required this.homeId,
    required this.createdAt,
    required this.updatedAt,
    this.homeName = '',
    this.ip = '',
    this.currentStep = 5,
    this.completed = const <int>{},
    this.skipped = const <int>{},
    this.customerHint = '',
    this.data = const <String, dynamic>{},
  });

  /// Kaydın sahibi (`user:<id>` / `session:<evId>`).
  final String ownerKey;
  final String deviceUuid;
  final String homeId;
  final String homeName;
  final String ip;
  final int currentStep;
  final Set<int> completed;

  /// Gerçekten yapılmayıp atlanan adımlar (PIN oturumunda 3-4, mevcut cihazda 2-4).
  final Set<int> skipped;

  /// Maskeli müşteri bilgisi ("m***@g***.com", "***1234"); yalnızca gösterim için.
  final String customerHint;

  /// Adım bazlı gizli olmayan veriler (röle/panjur/buton sonuçları, notlar ...). Anahtar: adım no.
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get storageKey => SetupStore.keyFor(ownerKey, deviceUuid);

  SetupProgressRecord copyWith({
    String? homeName,
    String? ip,
    int? currentStep,
    Set<int>? completed,
    Set<int>? skipped,
    String? customerHint,
    Map<String, dynamic>? data,
    DateTime? updatedAt,
  }) =>
      SetupProgressRecord(
        ownerKey: ownerKey,
        deviceUuid: deviceUuid,
        homeId: homeId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        homeName: homeName ?? this.homeName,
        ip: ip ?? this.ip,
        currentStep: currentStep ?? this.currentStep,
        completed: completed ?? this.completed,
        skipped: skipped ?? this.skipped,
        customerHint: customerHint ?? this.customerHint,
        data: data ?? this.data,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        // v:2 (WP-A4): Adım 7 verisine güvenlik ataması (`assign`, `inputs`) eklendi; v:1 kayıtları aynı ayrıştırıcıyla
        // okunur (eksik alanlar varsayılan: lamba, duvar butonu).
        'v': 2,
        'owner': ownerKey,
        'device_uuid': deviceUuid,
        'home_id': homeId,
        'home_name': homeName,
        'ip': ip,
        'step': currentStep,
        'completed': completed.toList()..sort(),
        'skipped': skipped.toList()..sort(),
        'customer_hint': customerHint,
        'data': data,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  /// Bozuk kayıtta `null`.
  static SetupProgressRecord? tryParse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final owner = asNonEmptyString(map['owner']);
    final uid = asNonEmptyString(map['device_uuid']);
    final home = asNonEmptyString(map['home_id']);
    final created = asDate(map['created_at']);
    final updated = asDate(map['updated_at']);
    if (owner == null || uid == null || home == null || created == null || updated == null) return null;
    Set<int> ints(Object? value) => <int>{
          for (final item in asList(value) ?? const <dynamic>[])
            if (asInt(item) != null && asInt(item)! >= 1 && asInt(item)! <= 10) asInt(item)!,
        };
    return SetupProgressRecord(
      ownerKey: owner,
      deviceUuid: uid,
      homeId: home,
      homeName: asString(map['home_name']) ?? '',
      ip: asString(map['ip']) ?? '',
      currentStep: clampInt(asInt(map['step']) ?? 5, 1, 10),
      completed: ints(map['completed']),
      skipped: ints(map['skipped']),
      customerHint: asString(map['customer_hint']) ?? '',
      data: asMap(map['data']) ?? const <String, dynamic>{},
      createdAt: created,
      updatedAt: updated,
    );
  }
}

/// Kurulum ilerlemesini cihaz bazlı `SharedPreferences`'ta saklar.
///
/// Depolama hataları sihirbazı durdurmaz (kayıt yazılamazsa kurulum yine sürer; kullanıcıya
/// "kaydedilemedi" bilgisi [lastWriteFailed] ile verilir).
class SetupStore {
  SetupStore({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static const String indexKey = 'ahbu_setup_index_v1';
  static const String _recordPrefix = 'ahbu_setup_v1';

  /// En çok bu kadar kayıt tutulur (eskiler silinir).
  static const int maxRecords = 20;

  /// Son yazma başarısız oldu mu.
  bool lastWriteFailed = false;

  static String keyFor(String ownerKey, String deviceUuid) => '$_recordPrefix:$ownerKey:$deviceUuid';

  Future<List<String>> _index(SharedPreferences prefs) async =>
      List<String>.of(prefs.getStringList(indexKey) ?? const <String>[]);

  /// [ownerKey]'e ait kayıtlar, en son güncellenen önce.
  Future<List<SetupProgressRecord>> list(String ownerKey) async {
    try {
      final prefs = await _prefs();
      final result = <SetupProgressRecord>[];
      final keys = await _index(prefs);
      final prefix = '$_recordPrefix:$ownerKey:';
      var changed = false;
      for (final key in List<String>.of(keys)) {
        if (!key.startsWith(prefix)) continue;
        final record = _decode(prefs.getString(key));
        if (record == null || record.ownerKey != ownerKey) {
          keys.remove(key);
          await prefs.remove(key);
          changed = true;
          continue;
        }
        result.add(record);
      }
      if (changed) await prefs.setStringList(indexKey, keys);
      result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return result;
    } catch (_) {
      return const <SetupProgressRecord>[];
    }
  }

  Future<SetupProgressRecord?> load(String ownerKey, String deviceUuid) async {
    try {
      final prefs = await _prefs();
      final record = _decode(prefs.getString(keyFor(ownerKey, deviceUuid)));
      if (record == null || record.ownerKey != ownerKey || record.deviceUuid != deviceUuid) return null;
      return record;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(SetupProgressRecord record) async {
    try {
      final prefs = await _prefs();
      final key = record.storageKey;
      await prefs.setString(key, jsonEncode(record.toJson()));
      final keys = await _index(prefs);
      keys.remove(key);
      keys.add(key);
      // Sınır aşılırsa en eski kayıtlar silinir.
      while (keys.length > maxRecords) {
        final oldest = keys.removeAt(0);
        await prefs.remove(oldest);
      }
      await prefs.setStringList(indexKey, keys);
      lastWriteFailed = false;
    } catch (_) {
      lastWriteFailed = true;
    }
  }

  Future<void> delete(String ownerKey, String deviceUuid) async {
    try {
      final prefs = await _prefs();
      final key = keyFor(ownerKey, deviceUuid);
      await prefs.remove(key);
      final keys = await _index(prefs);
      if (keys.remove(key)) await prefs.setStringList(indexKey, keys);
    } catch (_) {}
  }

  SetupProgressRecord? _decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return SetupProgressRecord.tryParse(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }
}
