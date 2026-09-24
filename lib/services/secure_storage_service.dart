// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Güvenli Depolama Servisi (Faz 7.1)
// ==============================================================================

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/cloud_models.dart';

class SecureStorageService {
  static const _tokenKey = 'ahbu_auth_token';
  static const _userKey = 'ahbu_current_user';
  static const _savedModeKey = 'ahbu_app_mode';

  final FlutterSecureStorage _storage;

  SecureStorageService()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(resetOnError: true),
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        );

  static const _refreshTokenKey = 'ahbu_refresh_token';

  /// JWT Access Token Kaydetme
  Future<void> saveAuthToken(String token) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
    } catch (_) {}
  }

  /// JWT Access Token Okuma
  Future<String?> getAuthToken() async {
    try {
      return await _storage.read(key: _tokenKey);
    } catch (_) {
      return null;
    }
  }

  /// JWT Access Token Silme
  Future<void> deleteAuthToken() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
  }

  /// JWT Refresh Token Kaydetme (1 Yıllık Kalıcı Oturum)
  Future<void> saveRefreshToken(String token) async {
    try {
      await _storage.write(key: _refreshTokenKey, value: token);
    } catch (_) {}
  }

  /// JWT Refresh Token Okuma
  Future<String?> getRefreshToken() async {
    try {
      return await _storage.read(key: _refreshTokenKey);
    } catch (_) {
      return null;
    }
  }

  /// JWT Refresh Token Silme
  Future<void> deleteRefreshToken() async {
    try {
      await _storage.delete(key: _refreshTokenKey);
    } catch (_) {}
  }

  /// Kullanıcı Profilini Şifreli Saklama
  Future<void> saveUser(UserModel user) async {
    try {
      final jsonStr = jsonEncode(user.toJson());
      await _storage.write(key: _userKey, value: jsonStr);
    } catch (_) {}
  }

  /// Saklanan Kullanıcı Profilini Okuma
  Future<UserModel?> getUser() async {
    try {
      final jsonStr = await _storage.read(key: _userKey);
      if (jsonStr == null || jsonStr.isEmpty) return null;
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return UserModel.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Kullanıcı Bilgisini Silme
  Future<void> deleteUser() async {
    try {
      await _storage.delete(key: _userKey);
    } catch (_) {}
  }

  /// Çalışma Modu (Direct / Cloud)
  Future<void> saveAppMode(String mode) async {
    try {
      await _storage.write(key: _savedModeKey, value: mode);
    } catch (_) {}
  }

  Future<String?> getAppMode() async {
    try {
      return await _storage.read(key: _savedModeKey);
    } catch (_) {
      return null;
    }
  }

  static const _biometricEnabledKey = 'ahbu_biometric_enabled';
  static const _biometricPromptShownKey = 'ahbu_biometric_prompt_shown';

  /// ADIM 19: Biyometrik Giriş Tercihini Kaydetme
  Future<void> saveBiometricEnabled(bool enabled) async {
    try {
      await _storage.write(key: _biometricEnabledKey, value: enabled ? 'true' : 'false');
    } catch (_) {}
  }

  /// ADIM 19: Biyometrik Giriş Etkin mi?
  Future<bool> isBiometricEnabled() async {
    try {
      final val = await _storage.read(key: _biometricEnabledKey);
      return val == 'true';
    } catch (_) {
      return false;
    }
  }

  /// ADIM 19: Biyometrik Giriş Diyaloğu Gösterildi mi?
  Future<void> saveBiometricPromptShown(bool shown) async {
    try {
      await _storage.write(key: _biometricPromptShownKey, value: shown ? 'true' : 'false');
    } catch (_) {}
  }

  Future<bool> isBiometricPromptShown() async {
    try {
      final val = await _storage.read(key: _biometricPromptShownKey);
      return val == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Tüm Oturum Bilgilerini Sıfırlama (Logout)
  Future<void> clearAll() async {
    try {
      await _storage.deleteAll();
    } catch (_) {}
  }
}
