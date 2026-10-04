// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Biyometrik Kimlik Doğrulama Servisi (Adım 19)
// ==============================================================================
//
// Süre sınırı (PF-02): destek/tür SONDALARI (`canCheckBiometrics`, `isDeviceSupported`,
// `getAvailableBiometrics`) platform kanalına gider ve hiç dönmeyebilir; açılışı ve girişi
// bloklamasın diye [BiometricAuthService.defaultProbeTimeout] (3 sn; kurucuda `probeTimeout` ile
// değiştirilir) içinde dönmezse "desteklenmiyor" (false / []) sayılır. Etkileşimli
// [BiometricAuthService.authenticate] istemine ASLA süre sınırı konmaz: kullanıcı parmağını/yüzünü
// okutana ya da vazgeçene kadar beklemek doğru davranıştır.

import 'package:flutter/services.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import 'clock.dart';

/// Biyometrik doğrulamanın neden başarısız olduğu (kullanıcıya doğru açıklamayı göstermek için).
enum BiometricFailure {
  /// Kullanıcı vazgeçti ya da doğrulama eşleşmedi.
  canceled,

  /// Cihazda kayıtlı parmak izi / yüz yok.
  notEnrolled,

  /// Ekran kilidi ya da biyometrik donanım kullanılamıyor.
  notAvailable,

  /// Çok fazla hatalı deneme: geçici kilit (yaklaşık 30 sn).
  lockedOut,

  /// Kalıcı kilit: cihazın kilidi PIN/desen/şifre ile açılmadan biyometri çalışmaz.
  permanentlyLockedOut,

  /// Başka bir doğrulama istemi zaten açık (eklenti aynı anda tek doğrulamaya izin verir).
  inProgress,

  /// Beklenmeyen platform/eklenti hatası.
  error,
}

/// [failure] için kullanıcıya gösterilecek açıklama. [label]: "Parmak İzi" / "Face ID" / "Biyometrik Giriş".
/// Vazgeçme ve bilinmeyen durumda [fallback] (verilmezse genel açıklama) döner.
String biometricFailureMessage(BiometricFailure? failure, {required String label, String? fallback}) {
  switch (failure) {
    case BiometricFailure.notEnrolled:
      return 'Bu cihazda kayıtlı parmak izi ya da yüz yok. Önce cihazın güvenlik ayarlarından ekleyin.';
    case BiometricFailure.notAvailable:
      return 'Bu cihazda ekran kilidi ayarlı değil ya da biyometrik doğrulama şu anda kullanılamıyor. '
          'Yeniden deneyin; sorun sürerse cihazın güvenlik ayarlarını kontrol edin.';
    case BiometricFailure.lockedOut:
      return 'Çok fazla hatalı deneme yapıldı. Yaklaşık 30 saniye bekleyin.';
    case BiometricFailure.permanentlyLockedOut:
      return 'Çok fazla hatalı deneme yapıldı; biyometrik doğrulama kilitlendi. '
          'Cihazı kilitleyip PIN, desen ya da şifreyle yeniden açın, sonra tekrar deneyin.';
    case BiometricFailure.inProgress:
      return 'Başka bir kimlik doğrulama sürüyor. Bitmesini bekleyip yeniden deneyin.';
    case BiometricFailure.error:
      return '$label doğrulaması başlatılamadı. Yeniden deneyin; sorun sürerse uygulamayı kapatıp yeniden açın.';
    case BiometricFailure.canceled:
    case null:
      return fallback ?? '$label doğrulaması tamamlanamadı.';
  }
}

/// Android sistem istemindeki metinler. Verilmezse eklentinin İngilizce varsayılanları görünür.
/// Üst sınırlar eklentiye aittir: düğmeler 30, başlık/ipucu/durum metinleri 60 karakter; iki açıklama
/// (goToSettingsDescription, deviceCredentialsSetupDescription) sınırsız. `biometricHint: ''` bilinçli:
/// alt başlık gizlenir, açıklama zaten uygulamanın `reason` metnidir. `useErrorDialogs` açıkken "kayıt yok" /
/// "ekran kilidi yok" durumlarını eklenti bu metinlerle kendi penceresinde anlatır ve sonuç `false` gelir.
/// biometricNotRecognized/biometricSuccess eklentinin bu sürümünde Android'de kullanılmaz (sistem kendi metnini gösterir).
const AndroidAuthMessages _androidAuthMessages = AndroidAuthMessages(
  signInTitle: 'Kimlik doğrulama',
  biometricHint: '',
  biometricNotRecognized: 'Tanınmadı. Yeniden deneyin.',
  biometricSuccess: 'Doğrulandı',
  cancelButton: 'Vazgeç',
  biometricRequiredTitle: 'Biyometrik kayıt gerekli',
  goToSettingsButton: 'Ayarlara git',
  goToSettingsDescription: 'Bu cihazda kayıtlı parmak izi ya da yüz yok. Güvenlik ayarlarından ekleyin.',
  deviceCredentialsRequiredTitle: 'Ekran kilidi gerekli',
  deviceCredentialsSetupDescription: 'Güvenlik ayarlarından PIN, desen ya da şifre belirleyin.',
);

class BiometricAuthService {
  final LocalAuthentication _auth;
  final Clock _clock;
  final Duration _probeTimeout;

  /// [clock]: sonda süre sınırı zamanlayıcısının kaynağı (varsayılan gerçek saat; testte `FakeClock`).
  /// [probeTimeout]: tek bir sonda için en uzun bekleme ([defaultProbeTimeout]).
  BiometricAuthService({LocalAuthentication? auth, Clock? clock, Duration? probeTimeout})
      : _auth = auth ?? LocalAuthentication(),
        _clock = clock ?? const SystemClock(),
        _probeTimeout = probeTimeout ?? defaultProbeTimeout;

  /// Destek/tür sondası için en uzun bekleme; aşılırsa cihaz "biyometrik yok" sayılır.
  static const Duration defaultProbeTimeout = Duration(seconds: 3);

  bool _lastSupportProbeTimedOut = false;

  /// Son [isBiometricSupported] sondası süre sınırına takıldı mı? `false` dönen sonda "cihaz desteklemiyor"
  /// ile "platform yanıt vermedi"yi AYIRMAZ; biyometrik kilit AÇIKKEN açılışta sonda zaman aşımına uğrarsa
  /// kilidi atlamak (fail-open) yerine kilidi AÇIK tutmak isteyen çağıran bu bayrağa bakar. Her destek
  /// sondasında güncellenir; [authenticate] ve tür sondaları ([getAvailableBiometrics]) etkilemez.
  bool get lastSupportProbeTimedOut => _lastSupportProbeTimedOut;

  BiometricFailure? _lastFailure;

  /// Son [authenticate] çağrısının başarısızlık nedeni; başarıda `null`.
  BiometricFailure? get lastFailure => _lastFailure;

  /// Cihazda biyometrik donanım var mı ve kullanılabilir mi?
  ///
  /// İki platform çağrısı (`canCheckBiometrics` + `isDeviceSupported`) TOPLAMDA tek sonda süresiyle
  /// ([defaultProbeTimeout]) sınırlıdır; süre dolarsa `false` döner (geç dönen sonuç yutulur) ve
  /// [lastSupportProbeTimedOut] `true` olur.
  Future<bool> isBiometricSupported() async {
    var timedOut = false;
    var supported = false;
    try {
      supported = await _clock.bound<bool>(_probeSupport(), _probeTimeout, () {
        timedOut = true;
        return false;
      });
    } on PlatformException catch (_) {
      supported = false;
    } catch (_) {
      supported = false;
    }
    _lastSupportProbeTimedOut = timedOut;
    return supported;
  }

  Future<bool> _probeSupport() async {
    final canCheck = await _auth.canCheckBiometrics;
    final isSupported = await _auth.isDeviceSupported();
    return canCheck && isSupported;
  }

  /// Cihazdaki kullanılabilir biyometrik türleri (Face ID, Parmak İzi). Sonda süre sınırlıdır;
  /// süre dolarsa boş liste döner.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _clock.bound<List<BiometricType>>(
        _auth.getAvailableBiometrics(),
        _probeTimeout,
        () => <BiometricType>[],
      );
    } on PlatformException catch (_) {
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<bool>? _inFlight;

  /// Biyometrik doğrulama tetikle (Face ID / Parmak İzi). Başarısızlıkta neden [lastFailure]'da kalır.
  ///
  /// Destek sondası süre sınırlıdır ([isBiometricSupported]; dönmezse `false`); asıl doğrulama istemi
  /// (`_auth.authenticate`) kullanıcı etkileşimidir ve SÜRE SINIRI YOKTUR.
  ///
  /// Aynı anda tek doğrulama: eklenti ikinci istemi `auth_in_progress` ile reddeder. Süren bir istem varken
  /// gelen çağrı (ör. kapatma doğrulaması beklerken yeniden kilit) yeni istem açmaz, sürenin sonucunu alır;
  /// katılan çağrının [reason]/[biometricOnly] değerleri yok sayılır (uygulama hep `biometricOnly: false` kullanır).
  Future<bool> authenticate({
    String reason = 'AHBU Ev Otomasyonu için kimliğinizi doğrulayın',
    bool biometricOnly = false,
  }) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final run = _authenticate(reason: reason, biometricOnly: biometricOnly).whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  Future<bool> _authenticate({required String reason, required bool biometricOnly}) async {
    try {
      final isSupported = await isBiometricSupported();
      if (!isSupported) {
        // Süre sınırına takılan sonda "cihaz desteklemiyor" demek değildir (platform yanıt vermedi): kullanıcıya
        // "yeniden deneyin" diyen genel hata nedeni verilir; gerçekten desteklemeyen cihazda "kullanılamıyor".
        _lastFailure = _lastSupportProbeTimedOut ? BiometricFailure.error : BiometricFailure.notAvailable;
        return false;
      }

      final ok = await _auth.authenticate(
        localizedReason: reason,
        authMessages: const <AuthMessages>[_androidAuthMessages],
        options: AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: biometricOnly,
          useErrorDialogs: true,
        ),
      );
      _lastFailure = ok ? null : BiometricFailure.canceled;
      return ok;
    } on PlatformException catch (e) {
      _lastFailure = _failureFor(e.code);
      return false;
    } catch (_) {
      _lastFailure = BiometricFailure.error;
      return false;
    }
  }

  /// Eklentinin `PlatformException` kodunu (Android, iOS, Windows) nedene çevirir.
  static BiometricFailure _failureFor(String code) {
    switch (code) {
      case auth_error.notEnrolled:
        return BiometricFailure.notEnrolled;
      case auth_error.notAvailable:
      case auth_error.passcodeNotSet:
      case auth_error.otherOperatingSystem:
      case 'BiometricNotAvailable':
      case 'NoHardware':
        return BiometricFailure.notAvailable;
      case auth_error.lockedOut:
        return BiometricFailure.lockedOut;
      case auth_error.permanentlyLockedOut:
        return BiometricFailure.permanentlyLockedOut;
      case 'auth_in_progress':
        return BiometricFailure.inProgress;
      case 'UserCancelled':
      case 'UserFallback':
        return BiometricFailure.canceled;
      default:
        return BiometricFailure.error;
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
