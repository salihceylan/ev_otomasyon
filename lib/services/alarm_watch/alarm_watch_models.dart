import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/capabilities.dart';
import '../../models/cloud_models.dart';

// =============================================================================
// Arka planda alarm bildirimi (Android, Firebase'siz): ortak modeller.
//
// Ön plan uygulaması (ayar kartı) ile arka plan servisi (ayrı FlutterEngine/isolate) aynı küçük ayar kaydını paylaşır:
// açık mı, kimin için açıldı (kullanıcı kimliği), hangi evler izlenecek. Kayıt sır içermez (belirteç/kimlik YOK);
// belirteçler yalnız güvenli depodadır.
// =============================================================================

/// İzlenen ev (kimlik + gösterim adı).
@immutable
class WatchedHome {
  const WatchedHome({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name};

  static WatchedHome? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty) return null;
    return WatchedHome(id: id, name: name is String ? name : '');
  }

  @override
  bool operator ==(Object other) => other is WatchedHome && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'WatchedHome($id)';
}

/// Arka plan alarm bildirimi alabilecek evler: yalnız **ev rolü sahip ya da sakin** olan evler (misafir ✖, ev rolü
/// `service_user` ✖; sunucunun güvenlik push'u kuralıyla aynı: owner + resident).
///
/// Ev rolü belirleyicidir (guvenlik-12): kendi evinin sahibi olan servis sorumlusu / süper kullanıcı da izler; başkasının
/// evindeki servis üyeliği izlenmez. Servis PIN oturumu ve tanınmayan küresel rol hiçbir evi izlemez.
List<WatchedHome> eligibleWatchHomes({required String? globalRole, required List<HomeModel> homes}) {
  final global = GlobalRole.parse(globalRole);
  if (global == GlobalRole.serviceSession || global == GlobalRole.unknown) return const <WatchedHome>[];
  final out = <WatchedHome>[];
  for (final h in homes) {
    final role = HomeRole.parse(h.role);
    if (role != HomeRole.owner && role != HomeRole.resident) continue;
    if (h.id.isEmpty) continue;
    out.add(WatchedHome(id: h.id, name: h.name.trim()));
  }
  return List<WatchedHome>.unmodifiable(out);
}

/// Paylaşılan ayar kaydı.
@immutable
class AlarmWatchSettings {
  const AlarmWatchSettings({this.enabled = false, this.userId, this.homes = const <WatchedHome>[]});

  static const AlarmWatchSettings off = AlarmWatchSettings();

  final bool enabled;

  /// Özelliği açan kullanıcı. Başka kullanıcı girerse ya da çıkış yapılırsa servis durur.
  final String? userId;

  /// Son bilinen uygun evler (servis açılışta internet yoksa bununla başlar; sonra sunucudan tazeler).
  final List<WatchedHome> homes;

  AlarmWatchSettings copyWith({bool? enabled, String? userId, List<WatchedHome>? homes}) => AlarmWatchSettings(
        enabled: enabled ?? this.enabled,
        userId: userId ?? this.userId,
        homes: homes ?? this.homes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'enabled': enabled,
        if (userId != null) 'user': userId,
        'homes': <Map<String, dynamic>>[for (final h in homes) h.toJson()],
      };

  static AlarmWatchSettings fromJson(Object? raw) {
    if (raw is! Map) return off;
    final user = raw['user'];
    final homes = <WatchedHome>[];
    final list = raw['homes'];
    if (list is List) {
      for (final item in list) {
        final h = WatchedHome.fromJson(item);
        if (h != null) homes.add(h);
      }
    }
    return AlarmWatchSettings(
      enabled: raw['enabled'] == true,
      userId: user is String && user.isNotEmpty ? user : null,
      homes: List<WatchedHome>.unmodifiable(homes),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlarmWatchSettings && other.enabled == enabled && other.userId == userId && listEquals(other.homes, homes);

  @override
  int get hashCode => Object.hash(enabled, userId, Object.hashAll(homes));
}

/// İki isolate'in paylaştığı küçük anahtar-değer deposu (önbelleksiz: diğer isolate'in yazdığı hemen görünür).
abstract class AlarmWatchStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// `SharedPreferencesAsync`: bellek önbelleği YOK (klasik `SharedPreferences` isolate başına önbellek tutar ve diğer
/// isolate'in yazdığını görmezdi).
class PrefsAlarmWatchStore implements AlarmWatchStore {
  PrefsAlarmWatchStore([SharedPreferencesAsync? prefs]) : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// Bellek içi depo (testler).
class MemoryAlarmWatchStore implements AlarmWatchStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> remove(String key) async => data.remove(key);
}

/// Ayar kaydının okunması / yazılması.
class AlarmWatchSettingsRepository {
  AlarmWatchSettingsRepository(this._store);

  static const String key = 'alarm_watch_settings';

  final AlarmWatchStore _store;

  Future<AlarmWatchSettings> load() async {
    try {
      final raw = await _store.read(key);
      if (raw == null || raw.isEmpty) return AlarmWatchSettings.off;
      return AlarmWatchSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return AlarmWatchSettings.off;
    }
  }

  Future<void> save(AlarmWatchSettings settings) => _store.write(key, jsonEncode(settings.toJson()));

  Future<void> clear() => _store.remove(key);
}

/// Bildirilmiş alarmların tekilleştirme kaydı (kalıcı): aynı alarm yeniden bağlanınca / servis yeniden başlayınca
/// ikinci kez çaldırılmaz. En çok [maxEntries] kayıt, [maxAge]'den eskiler atılır.
class AlarmDedupeStore {
  AlarmDedupeStore(
    this._store, {
    DateTime Function()? now,
    this.maxEntries = 200,
    this.maxAge = const Duration(days: 7),
  }) : _now = now ?? DateTime.now;

  static const String key = 'alarm_watch_seen';

  final AlarmWatchStore _store;
  final DateTime Function() _now;
  final int maxEntries;
  final Duration maxAge;

  Map<String, int>? _cache;

  Future<Map<String, int>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String, int>{};
    try {
      final raw = await _store.read(key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final k = e.key;
            final v = e.value;
            if (k is String && v is int) out[k] = v;
          }
        }
      }
    } catch (_) {
      // Bozuk kayıt: boş başlanır (en kötü ihtimalle bir alarm ikinci kez bildirilir).
    }
    return _cache = out;
  }

  Future<void> _save(Map<String, int> map) async {
    try {
      await _store.write(key, jsonEncode(map));
    } catch (_) {}
  }

  /// [dedupeKey] daha önce görülmediyse kaydeder ve `true` döner.
  Future<bool> markIfNew(String dedupeKey) async {
    final map = await _load();
    final now = _now().millisecondsSinceEpoch;
    map.removeWhere((_, at) => now - at > maxAge.inMilliseconds);
    if (map.containsKey(dedupeKey)) return false;
    map[dedupeKey] = now;
    if (map.length > maxEntries) {
      final sorted = map.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
      for (final e in sorted.take(map.length - maxEntries)) {
        map.remove(e.key);
      }
    }
    await _save(map);
    return true;
  }

  /// Kaydı siler (ör. kimliksiz alarm kalktı: aynı bölge yeniden alarm verirse yine bildirilsin).
  Future<void> forget(String dedupeKey) async {
    final map = await _load();
    if (map.remove(dedupeKey) != null) await _save(map);
  }

  /// Var olan kayıtların zamanını tazeler (guvenlik-9: hâlâ etkin alarm). Kayıt EKLEMEZ. Gereksiz yazım olmasın diye
  /// yalnız [minInterval]'den eski kayıtlar güncellenir.
  Future<void> touch(Iterable<String> keys, {Duration minInterval = const Duration(hours: 1)}) async {
    final map = await _load();
    final now = _now().millisecondsSinceEpoch;
    var changed = false;
    for (final key in keys) {
      final at = map[key];
      if (at == null || now - at < minInterval.inMilliseconds) continue;
      map[key] = now;
      changed = true;
    }
    if (changed) await _save(map);
  }

  /// Önekle başlayan kayıtları siler.
  Future<void> forgetPrefix(String prefix) async {
    final map = await _load();
    final before = map.length;
    map.removeWhere((k, _) => k.startsWith(prefix));
    if (map.length != before) await _save(map);
  }
}

/// Saf üstel geri çekilme: 5, 10, 20, 40 sn ... en çok [max]; ±%20 oynama ([random] enjekte edilebilir).
class AlarmBackoff {
  AlarmBackoff({
    this.base = const Duration(seconds: 5),
    this.max = const Duration(minutes: 5),
    double Function()? random,
  }) : _random = random ?? Random().nextDouble;

  final Duration base;
  final Duration max;
  final double Function() _random;
  int _attempt = 0;

  int get attempt => _attempt;

  /// Sıradaki bekleme (sayaç artar).
  Duration next() {
    final factor = 1 << min(_attempt, 16);
    _attempt++;
    final raw = base.inMilliseconds * factor;
    final capped = min(raw, max.inMilliseconds);
    final jitter = 0.8 + _random() * 0.4;
    return Duration(milliseconds: (capped * jitter).round());
  }

  /// Başarıda sıfırlanır.
  void reset() => _attempt = 0;
}
