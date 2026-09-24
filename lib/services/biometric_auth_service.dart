// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Biyometrik Kimlik Doğrulama Servisi (Adım 19)
// ==============================================================================

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class BiometricAuthService {
  final LocalAuthentication _auth;

  BiometricAuthService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  /// Cihazda biyometrik donanım var mı ve kullanılabilir mi?
  Future<bool> isBiometricSupported() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck && isSupported;
    } on PlatformException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Cihazdaki kullanılabilir biyometrik türleri (Face ID, Parmak İzi)
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException catch (_) {
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Biyometrik doğrulama tetikle (Face ID / Parmak İzi)
  Future<bool> authenticate({
    String reason = 'AHBU Ev Otomasyonu için kimliğinizi doğrulayın',
    bool biometricOnly = false,
  }) async {
    try {
      final isSupported = await isBiometricSupported();
      if (!isSupported) return false;

      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: biometricOnly,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Aktif biyometrik türü adı (UI'da Face ID mi Parmak İzi mi göstermek için)
  Future<String> getBiometricLabel() async {
    try {
      final biometrics = await getAvailableBiometrics();
      if (biometrics.contains(BiometricType.face)) {
        return 'Face ID';
      } else if (biometrics.contains(BiometricType.fingerprint) ||
          biometrics.contains(BiometricType.strong)) {
        return 'Parmak İzi';
      }
      return 'Biyometrik Giriş';
    } catch (_) {
      return 'Biyometrik Giriş';
    }
  }
}

