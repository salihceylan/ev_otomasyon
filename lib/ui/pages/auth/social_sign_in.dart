import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../common/sha256.dart';

/// Sosyal girişte kullanıcıya gösterilebilir hata (ham platform istisnası gösterilmez).
class SocialAuthException implements Exception {
  const SocialAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Apple girişinin sonucu: yalnızca **doğrulanmış kimlik jetonu** + ilk girişte Apple'ın verdiği ad.
class AppleSignInResult {
  const AppleSignInResult({required this.identityToken, required this.rawNonce, this.fullName});

  final String identityToken;

  /// Apple isteğine SHA-256 özetiyle verilen **ham** nonce (sunucu jetondaki özetle eşleştirir).
  final String rawNonce;
  final String? fullName;

  @override
  String toString() => 'AppleSignInResult(token: ******)';
}

/// Google / Apple platform girişleri. İstemci **asla** jetonsuz e-posta göndermez: kimlik jetonu yoksa
/// açık bir hata verilir (sunucu yalnızca doğrulanmış jetonla oturum açar).
abstract final class SocialSignIn {
  /// Google web/sunucu istemci kimliği (`--dart-define=GOOGLE_SERVER_CLIENT_ID=...`). Android'de
  /// kimlik jetonu (`idToken`) almak için gereklidir; sunucudaki `GOOGLE_CLIENT_IDS` ile aynı olmalıdır.
  static const String googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Apple girişi yalnızca iOS ve macOS'ta sunulur.
  static bool get appleSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Kullanıcı vazgeçtiyse `null`; jeton alınamazsa [SocialAuthException].
  static Future<String?> googleIdToken() async {
    try {
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: googleServerClientId.isEmpty ? null : googleServerClientId,
      );
      final account = await googleSignIn.signIn();
      if (account == null) return null; // iptal
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const SocialAuthException(
          'Google kimlik doğrulama jetonu alınamadı. Uygulamanın Google yapılandırması eksik olabilir; '
          'e-posta ile giriş yapmayı deneyin.',
        );
      }
      return idToken;
    } on SocialAuthException {
      rethrow;
    } catch (_) {
      throw const SocialAuthException(
        'Google ile giriş bu cihazda tamamlanamadı. Daha sonra tekrar deneyin veya e-posta ile giriş yapın.',
      );
    }
  }

  /// Çıkışta Google'ın önbellekteki hesabını bırakır: aksi halde bir sonraki "Google ile giriş" hesap
  /// seçtirmeden aynı hesapla açılır (hesap değiştirilemez). En iyi çaba: eklenti yoksa (masaüstü/web)
  /// ya da başarısızsa sessizce geçilir; oturum kapatmayı asla engellemez.
  static Future<void> signOutGoogle() async {
    if (kIsWeb) return;
    try {
      await GoogleSignIn().signOut();
    } catch (_) {
      // Eklenti kullanılamıyor: yoksay.
    }
  }

  /// Kullanıcı vazgeçtiyse (**sessiz**) `null`; diğer hatalarda [SocialAuthException].
  static Future<AppleSignInResult?> apple() async {
    final rawNonce = generateRawNonce();
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: sha256Hex(rawNonce),
      );
      final token = credential.identityToken;
      if (token == null || token.isEmpty) {
        throw const SocialAuthException('Apple kimlik jetonu alınamadı. Lütfen tekrar deneyin.');
      }
      final name = [credential.givenName, credential.familyName]
          .where((n) => n != null && n.trim().isNotEmpty)
          .map((n) => n!.trim())
          .join(' ');
      return AppleSignInResult(
        identityToken: token,
        rawNonce: rawNonce,
        fullName: name.isEmpty ? null : name,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null; // iptal: sessiz
      throw const SocialAuthException('Apple ile giriş tamamlanamadı. Lütfen tekrar deneyin.');
    } on SocialAuthException {
      rethrow;
    } catch (_) {
      throw const SocialAuthException('Apple ile giriş bu cihazda kullanılamıyor.');
    }
  }
}
