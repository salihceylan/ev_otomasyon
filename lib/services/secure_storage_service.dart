// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Güvenli Depolama Servisi
// ==============================================================================
//
// Erişim/yenileme belirteçleri, kullanıcı profili, yerel (LAN) cihaz anahtarları ve servis
// oturumu yalnızca burada (Android Keystore / iOS Keychain) saklanır. SharedPreferences'a
// belirteç yedeği YAZILMAZ.
//
// Hata politikası: depolama (platform) hataları sessizce yutulmaz; [SecureStorageException]
// olarak çağırana yüzeye çıkar. "Kayıt yok" ise `null` döner. Böylece "okunamadı" ile
// "oturum yok" birbirine karışmaz (ör. biyometrik kilit bayrağı okunamazsa kilit açık sayılır).

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/api_models.dart';
import '../models/cloud_models.dart';
import '../models/json_utils.dart';

/// Güvenli depolama platform hatası (içerik/anahtar mesaja yazılmaz).
class SecureStorageException implements Exception {
  const SecureStorageException(this.operation, [this.cause]);

  /// `read` | `write` | `delete` | `deleteAll`.
  final String operation;
  final Object? cause;

  String get message =>
      'Güvenli depolama kullanılamıyor ($operation). Uygulamayı yeniden başlatmayı deneyin.';

  @override
  String toString() => message;
}

/// Basit anahtar-değer deposu soyutlaması (test için bellek içi sürümü enjekte edilir).
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
}

/// Gerçek uygulama deposu: `flutter_secure_storage`.
///
/// iOS: `first_unlock_this_device` — cihaz ilk kilit açılışından sonra erişilir ve **başka bir
/// cihaza yedekle taşınmaz**. Android: şifreli depolama; çözme hatasında depolama sıfırlanır.
class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

class SecureStorageService {
  SecureStorageService({SecureKeyValueStore? store}) : _store = store ?? FlutterSecureKeyValueStore();

  final SecureKeyValueStore _store;

  static const _tokenKey = 'ahbu_auth_token';
  static const _refreshTokenKey = 'ahbu_refresh_token';
  static const _userKey = 'ahbu_current_user';
  static const _biometricEnabledKey = 'ahbu_biometric_enabled';
  static const _biometricPromptShownKey = 'ahbu_biometric_prompt_shown';
  static const _localKeyPrefix = 'ahbu_local_key_';
  static const _homesCacheKey = 'ahbu_homes_cache';
  static const _serviceSessionKey = 'ahbu_service_session';

  // --- Düşük seviyeli sarmalayıcılar (hataları yüzeye çıkarır) -----------------------------

  Future<String?> _read(String key) async {
    try {
      return await _store.read(key);
    } catch (e) {
      throw SecureStorageException('read', e);
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (e) {
      throw SecureStorageException('write', e);
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _store.delete(key);
    } catch (e) {
      throw SecureStorageException('delete', e);
    }
  }

  // --- JWT -----------------------------------------------------------------------------------

  /// JWT erişim belirteci (15 dk).
  Future<void> saveAuthToken(String token) => _write(_tokenKey, token);
  Future<String?> getAuthToken() => _read(_tokenKey);
  Future<void> deleteAuthToken() => _delete(_tokenKey);

  /// Opak yenileme belirteci (30 gün; her kullanımda döner).
  Future<void> saveRefreshToken(String token) => _write(_refreshTokenKey, token);
  Future<String?> getRefreshToken() => _read(_refreshTokenKey);
  Future<void> deleteRefreshToken() => _delete(_refreshTokenKey);

  // --- Kullanıcı -----------------------------------------------------------------------------

  /// Kullanıcı profili (belirteç içermez).
  Future<void> saveUser(UserModel user) => _write(_userKey, jsonEncode(user.toJson()));

  /// Bozuk/okunamayan JSON `null` döndürür (ve bozuk kayıt silinir); platform hatası fırlatılır.
  Future<UserModel?> getUser() async {
    final raw = await _read(_userKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = asMap(jsonDecode(raw));
      if (map == null) throw const FormatException('kullanıcı kaydı');
      return UserModel.fromJson(map);
    } catch (_) {
      try {
        await _delete(_userKey);
      } catch (_) {}
      return null;
    }
  }

  Future<void> deleteUser() => _delete(_userKey);

  // --- Biyometrik tercihler ------------------------------------------------------------------

  Future<void> saveBiometricEnabled(bool enabled) =>
      _write(_biometricEnabledKey, enabled ? 'true' : 'false');

  /// Okunamazsa **hata fırlatılır** (çağıran kilidi açık varsayar; fail-closed).
  Future<bool> isBiometricEnabled() async => (await _read(_biometricEnabledKey)) == 'true';

  Future<void> saveBiometricPromptShown(bool shown) =>
      _write(_biometricPromptShownKey, shown ? 'true' : 'false');

  Future<bool> isBiometricPromptShown() async =>
      (await _read(_biometricPromptShownKey)) == 'true';

  // --- Yerel (LAN) cihaz anahtarı ------------------------------------------------------------

  static String _localKeyName(String deviceUuid) =>
      '$_localKeyPrefix${deviceUuid.trim().toUpperCase()}';

  /// `GET /homes/:id/devices/:uuid/local-key` ile alınan `X-Device-Key` değeri.
  Future<void> saveLocalKey(String deviceUuid, String key) =>
      _write(_localKeyName(deviceUuid), key);

  Future<String?> getLocalKey(String deviceUuid) => _read(_localKeyName(deviceUuid));

  Future<void> deleteLocalKey(String deviceUuid) => _delete(_localKeyName(deviceUuid));

  // --- Ev listesi önbelleği (çevrimdışı açılış) ---------------------------------------------

  /// Ev listesini kullanıcıya bağlı olarak saklar (başka kullanıcıya gösterilmez).
  Future<void> saveHomesCache(String userId, List<HomeModel> homes) => _write(
        _homesCacheKey,
        jsonEncode(<String, dynamic>{
          'user_id': userId,
          'homes': homes.map((h) => h.toJson()).toList(),
        }),
      );

  /// Yalnızca [userId] için kaydedilmiş liste döner; başka kullanıcınınki yok sayılır.
  Future<List<HomeModel>> loadHomesCache(String userId) async {
    final raw = await _read(_homesCacheKey);
    if (raw == null || raw.isEmpty) return <HomeModel>[];
    try {
      final map = asMap(jsonDecode(raw));
      if (map == null || map['user_id'] != userId) return <HomeModel>[];
      return parseList(map['homes'], HomeModel.fromJson, label: 'HomeCache');
    } catch (_) {
      return <HomeModel>[];
    }
  }

  Future<void> deleteHomesCache() => _delete(_homesCacheKey);

  // --- Servis PIN oturumu --------------------------------------------------------------------

  /// 2 saatlik servis oturumunun meta verisi (token ayrıca `saveAuthToken` ile saklanır).
  Future<void> saveServiceSession(ServiceSessionInfo info) =>
      _write(_serviceSessionKey, jsonEncode(info.toJson()));

  Future<ServiceSessionInfo?> getServiceSession() async {
    final raw = await _read(_serviceSessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = asMap(jsonDecode(raw));
      if (map == null) return null;
      return ServiceSessionInfo.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteServiceSession() => _delete(_serviceSessionKey);

  // --- Toplu silme ---------------------------------------------------------------------------

  /// Tüm oturum bilgilerini sıfırlar (çıkış / oturum sonu).
  Future<void> clearAll() async {
    try {
      await _store.deleteAll();
    } catch (e) {
      throw SecureStorageException('deleteAll', e);
    }
  }
}
