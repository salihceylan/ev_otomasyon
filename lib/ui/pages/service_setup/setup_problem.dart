import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../services/api_exception.dart';
import '../../../services/automation_api_service.dart';
import '../../../services/board_network_binding.dart';
import '../../../services/secure_storage_service.dart';

/// Hatanın türü (arayüz davranışını ve testleri yönlendirir).
enum SetupProblemKind {
  network,
  deviceNetwork,
  expired,
  unauthorized,
  forbidden,
  validation,
  locked,
  rateLimited,
  notFound,
  conflict,
  timeout,
  wrongDevice,
  deviceRejected,

  /// Sunucu isteği anlamlı biçimde reddetti (ör. devreye alma onaylanmadı).
  rejected,
  server,
  unknown,
}

/// Başarısız bir adımın **anlaşılır** açıklaması: ne oldu, neden, ne yapmalıyım.
///
/// Kullanıcıya ham istisna / sunucu iç mesajı gösterilmez; [why] yalnızca sunucunun bilerek
/// kullanıcıya açtığı Türkçe mesajdan ya da bu sınıftaki sabit metinlerden gelir.
@immutable
class SetupProblem {
  const SetupProblem({
    required this.kind,
    required this.title,
    required this.why,
    required this.todo,
    this.retryable = true,
    this.fixStep,
    this.retryAfter,
    this.remainingAttempts,
  });

  final SetupProblemKind kind;

  /// Kısa başlık ("Panoya ulaşılamadı").
  final String title;

  /// "Neden?" metni.
  final String why;

  /// "Ne yapmalıyım?" metni.
  final String todo;

  /// "Tekrar dene" anlamlı mı.
  final bool retryable;

  /// Düzeltme için dönülecek adım (ör. yanlış PIN -> 2).
  final int? fixStep;

  /// Beklenmesi gereken süre (hız sınırı / kilit).
  final Duration? retryAfter;

  final int? remainingAttempts;

  @override
  String toString() => 'SetupProblem($kind: $title)';
}

/// Mantık katmanının hazır bir [SetupProblem] ile fırlattığı istisna.
class SetupProblemException implements Exception {
  const SetupProblemException(this.problem);

  final SetupProblem problem;

  @override
  String toString() => problem.title;
}

/// Servis oturumu / hesap oturumu bitti: eylemler durur, ilerleme korunur.
class SetupSessionExpiredException implements Exception {
  const SetupSessionExpiredException();

  @override
  String toString() => 'Oturum süresi doldu';
}

/// Telefon başka bir panoya bağlı (kimlik uyuşmuyor): hiçbir gizli bilgi gönderilmeden durulur.
class WrongDeviceException implements Exception {
  const WrongDeviceException({required this.expectedUid, this.foundUid});

  final String expectedUid;
  final String? foundUid;

  @override
  String toString() => 'Yanlış pano';
}

/// Hataları [SetupProblem]'e çeviren merkez.
class SetupProblems {
  SetupProblems._();

  static SetupProblem expired() => const SetupProblem(
        kind: SetupProblemKind.expired,
        title: 'Oturum süresi doldu',
        why: 'Geçici servis oturumunuzun süresi bitti ya da oturumunuz sunucu tarafından kapatıldı.',
        todo: 'Giriş ekranına dönüp yeniden giriş yapın. Kurulum ilerlemeniz bu telefonda kayıtlıdır; '
            '"Devam eden kurulumlar" listesinden kaldığınız yerden sürdürebilirsiniz.',
        retryable: false,
      );

  static SetupProblem wrongDevice(WrongDeviceException e) {
    final found = e.foundUid;
    return SetupProblem(
      kind: SetupProblemKind.wrongDevice,
      title: 'Başka bir panoya bağlısınız',
      why: found == null
          ? 'Bağlandığınız cihaz kimliğini bildirmedi; kurulumu yaptığınız pano olduğundan emin olunamadı.'
          : 'Telefonunuz ${e.expectedUid} yerine $found panosuyla konuşuyor.',
      todo: 'Telefonunuzun Wi-Fi ayarlarında doğru panonun ağına bağlandığınızı kontrol edin. '
          'Aynı anda birden fazla pano açıksa diğerlerini kapatın. Güvenlik için hiçbir bilgi gönderilmedi.',
    );
  }

  /// [step]: hatanın oluştuğu adım (ipuçları adıma göre değişir).
  static SetupProblem fromError(Object error, {required int step}) {
    if (error is SetupProblemException) return error.problem;
    if (error is SetupSessionExpiredException) return expired();
    if (error is WrongDeviceException) return wrongDevice(error);
    if (error is ApiException) return _fromApi(error, step);
    if (error is LocalApiException) return _fromLocal(error, step);
    if (error is SecureStorageException) {
      return const SetupProblem(
        kind: SetupProblemKind.unknown,
        title: 'Telefon güvenli depoya erişemedi',
        why: 'Cihaz anahtarı telefonun güvenli deposundan okunamadı veya yazılamadı.',
        todo: 'Telefonu yeniden başlatıp tekrar deneyin. Sürerse anahtarı elle girebilirsiniz.',
      );
    }
    if (error is TimeoutException) {
      return const SetupProblem(
        kind: SetupProblemKind.timeout,
        title: 'İşlem zaman aşımına uğradı',
        why: 'Beklenen yanıt zamanında gelmedi.',
        todo: 'Bağlantınızı kontrol edip "Tekrar dene"ye basın.',
      );
    }
    if (error is IOException) {
      return const SetupProblem(
        kind: SetupProblemKind.network,
        title: 'Ağ bağlantısı kurulamadı',
        why: 'Telefonun ağ bağlantısı yok veya kesildi.',
        todo: 'Wi-Fi ya da mobil veri bağlantınızı kontrol edip "Tekrar dene"ye basın.',
      );
    }
    return const SetupProblem(
      kind: SetupProblemKind.unknown,
      title: 'İşlem tamamlanamadı',
      why: 'Beklenmeyen bir sorun oluştu.',
      todo: 'Tekrar deneyin. Sorun sürerse kurulumu bırakıp daha sonra kaldığınız yerden devam edin.',
    );
  }

  static String waitText(Duration? d) {
    if (d == null || d <= Duration.zero) return 'kısa bir süre';
    if (d.inMinutes >= 2) return '${d.inMinutes} dakika';
    if (d.inSeconds >= 60) return '1 dakika';
    return '${d.inSeconds < 1 ? 1 : d.inSeconds} saniye';
  }

  static SetupProblem _fromApi(ApiException e, int step) {
    if (e.isNetwork) {
      final timedOut = e.cause is TimeoutException;
      return SetupProblem(
        kind: timedOut ? SetupProblemKind.timeout : SetupProblemKind.network,
        title: timedOut ? 'Sunucu zamanında yanıt vermedi' : 'Sunucuya ulaşılamadı',
        why: timedOut
            ? 'Sunucu bağlantısı çok yavaş veya kesik.'
            : 'Telefonunuzun internet bağlantısı yok ya da zayıf (veya sunucu geçici olarak kapalı).',
        todo: step == 5
            ? 'Bu işlem internet gerektirir (kurulum ağında internet yoktur): telefonu geçici olarak mobil veriye ya da '
                'ev Wi-Fi\'sine alıp "Tekrar dene"ye basın, sonra kurulum ağına geri dönün.'
            : step == 6
                ? 'Bu adım internet gerektirir: telefonunuzu panonun kurulum ağından çıkarıp müşterinin ev Wi-Fi '
                    'ağına bağlayın (ya da mobil veriyi açın), sonra "Tekrar dene"ye basın.'
                : 'Mobil verinizi veya Wi-Fi bağlantınızı kontrol edip "Tekrar dene"ye basın.',
      );
    }
    if (e.isServiceSessionExpired || e.isUnauthorized) return expired();
    if (e.isPinLocked) {
      final wait = e.retryAfter;
      return SetupProblem(
        kind: SetupProblemKind.locked,
        title: 'Cihaz geçici olarak kilitlendi',
        why: e.message,
        todo: 'Yaklaşık ${waitText(wait)} bekleyin. Beklerken etiketteki PIN\'i doğru okuduğunuzdan emin olun.',
        retryAfter: wait,
        fixStep: step >= 3 ? 2 : null,
      );
    }
    if (e.isRateLimited) {
      final wait = e.retryAfter ?? e.resendAfter;
      return SetupProblem(
        kind: SetupProblemKind.rateLimited,
        title: 'Çok sık deneme yapıldı',
        why: e.message,
        todo: 'Güvenlik için kısa bir bekleme var: ${waitText(wait)} sonra tekrar deneyin.',
        retryAfter: wait,
      );
    }
    if (e.isDeviceOffline) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceNetwork,
        title: 'Cihaz sunucuda çevrimdışı görünüyor',
        why: 'Pano şu anda buluta bağlı değil.',
        todo: 'Panonun elektriğini ve ev internetini kontrol edin; birkaç saniye sonra tekrar deneyin.',
      );
    }
    if (e.isForbidden) {
      return SetupProblem(
        kind: SetupProblemKind.forbidden,
        title: 'Bu işlem yapılamadı',
        why: e.message,
        todo: 'Yetkinizi ve seçili dairenin doğru olduğunu kontrol edin. Servis erişim süreniz dolmuş olabilir; '
            'gerekirse yöneticiyle iletişime geçin.',
        retryable: false,
        remainingAttempts: e.remainingAttempts,
      );
    }
    if (e.isValidation) {
      final left = e.remainingAttempts;
      return SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Bilgiler kabul edilmedi',
        why: e.message,
        todo: left == null
            ? 'Girdiğiniz bilgileri kontrol edip tekrar deneyin.'
            : 'Girdiğiniz bilgiyi kontrol edin. Kalan deneme hakkınız: $left.',
        remainingAttempts: left,
      );
    }
    if (e.isGone) {
      return SetupProblem(
        kind: SetupProblemKind.conflict,
        title: 'Kodun süresi doldu',
        why: e.message,
        todo: 'Yeni bir kod isteyin.',
      );
    }
    if (e.isNotFound) {
      return SetupProblem(
        kind: SetupProblemKind.notFound,
        title: 'Kayıt bulunamadı',
        why: e.message,
        todo: 'Cihazın ve dairenin doğru seçildiğini kontrol edin. Etiket yanlış okunmuş olabilir.',
        retryable: false,
      );
    }
    if (e.statusCode == 409) {
      return SetupProblem(
        kind: SetupProblemKind.conflict,
        title: 'İşlem çakıştı',
        why: e.message,
        todo: 'Cihaz başka bir daireye bağlı veya durumu uygun değil olabilir. Yöneticiye başvurun.',
        retryable: false,
      );
    }
    if (e.isServerError) {
      return const SetupProblem(
        kind: SetupProblemKind.server,
        title: 'Sunucu şu anda yanıt veremiyor',
        why: 'Sunucuda geçici bir sorun var.',
        todo: 'Birkaç dakika sonra "Tekrar dene"ye basın. Sürerse destek hattına bildirin.',
      );
    }
    return SetupProblem(
      kind: SetupProblemKind.unknown,
      title: 'İşlem tamamlanamadı',
      why: e.message,
      todo: 'Tekrar deneyin. Sorun sürerse kurulumu bırakıp daha sonra devam edin.',
    );
  }

  static SetupProblem _fromLocal(LocalApiException e, int step) {
    if (e.isCancelled) {
      return const SetupProblem(
        kind: SetupProblemKind.unknown,
        title: 'İşlem iptal edildi',
        why: 'İşlem kullanıcı tarafından veya sayfa kapanırken durduruldu.',
        todo: 'Devam etmek için işlemi yeniden başlatın.',
      );
    }
    if (e.isNetwork || e.code == 'not_configured') {
      final hint = e.hint; // Android: pano ağına yönlenme kurulamadıysa nedeni (BoardNetworkBinding)
      return SetupProblem(
        kind: SetupProblemKind.deviceNetwork,
        title: 'Panoya ulaşılamadı',
        why: (e.code == 'not_configured'
                ? 'Panonun adresi (IP) bilinmiyor veya geçersiz.'
                : 'Telefonunuz panoyla aynı ağda değil, adres yanlış ya da pano kapalı.') +
            (hint == null ? '' : ' $hint'),
        // Android'de hata kutusunda yalnız yedek cümle kullanılır ("Mobil veri açık kalabilir..." ön bilgisi, başarısız
        // olmuş bir bağlantının hemen yanında "Neden?" satırındaki ipucuyla çelişirdi).
        todo: step == 5
            ? 'Telefonunuzun Wi-Fi ayarlarını açıp panonun kurulum ağına (AHBU-...) bağlı olduğunuzu kontrol edin. '
                '${BoardNetworkBinding.instance.isSupported ? BoardNetworkBinding.mobileDataFallback : 'Mobil veri açıksa geçici olarak kapatın, sonra "Tekrar dene"ye basın.'}'
            : 'Telefonunuzun, panonun bağlı olduğu ev Wi-Fi ağında olduğundan emin olun. '
                'Panonun IP adresini yukarıdaki kutudan kontrol edip "Tekrar dene"ye basın.',
      );
    }
    if (e.isUnauthorized) {
      return const SetupProblem(
        kind: SetupProblemKind.unauthorized,
        title: 'Pano cihaz anahtarını kabul etmedi',
        why: 'Elimizdeki anahtar bu panoda tanımlı değil (pano yeniden anahtarlanmış ya da başka bir anahtarla '
            'kurulmuş olabilir).',
        todo: '"Panoya Bağlan"a yeniden basın: anahtar sunucudan yeniden alınır (aynı anahtar panoya tekrar '
            'gönderilmez). Olmazsa fabrika/servis kaydındaki anahtarı elle girin.',
      );
    }
    if (e.isLocked) {
      final wait = e.retryAfter;
      return SetupProblem(
        kind: SetupProblemKind.locked,
        title: 'Pano geçici olarak kilitlendi',
        why: 'Pano çok sayıda hatalı anahtar denemesi aldı ve güvenlik için bir süre cevap vermiyor.',
        todo: 'Yaklaşık ${waitText(wait)} bekleyip tekrar deneyin.',
        retryAfter: wait,
      );
    }
    if (e.isUnprovisioned) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Pano henüz hazırlanmamış',
        why: 'Pano ilk kurulumu (cihaz anahtarı) yapılmadığı için bu işlemi kabul etmiyor.',
        todo: 'Önce panonun ilk hazırlığını (anahtar tanımlama) tamamlayın.',
      );
    }
    if (e.isAlreadyProvisioned) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Pano zaten hazırlanmış',
        why: 'Panoda cihaz anahtarı daha önce tanımlanmış.',
        todo: 'Hazırlık gerekmiyor: cihaz anahtarını sunucudan alıp devam edin.',
      );
    }
    if (e.isBusy) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Pano şu anda meşgul',
        why: 'Pano başka bir işlemi bitiriyor (ör. bir panjur hareket ediyor).',
        todo: 'Birkaç saniye bekleyip "Tekrar dene"ye basın.',
      );
    }
    if (e.isHostRejected) {
      return const SetupProblem(
        kind: SetupProblemKind.deviceRejected,
        title: 'Pano bu adresi reddetti',
        why: 'Pano yalnızca kendi IP adresiyle erişimi kabul eder.',
        todo: 'Adres olarak isim yerine panonun IP adresini yazın.',
      );
    }
    if (e.code == 'timeout') {
      return const SetupProblem(
        kind: SetupProblemKind.timeout,
        title: 'Pano zamanında yanıt vermedi',
        why: 'Wi-Fi taraması veya pano yanıtı beklenenden uzun sürdü.',
        todo: 'Panoya yakın durup "Tekrar dene"ye basın.',
      );
    }
    return SetupProblem(
      kind: e.isInvalidInput ? SetupProblemKind.validation : SetupProblemKind.deviceRejected,
      title: e.isInvalidInput ? 'Pano girilen bilgiyi kabul etmedi' : 'Pano işlemi tamamlayamadı',
      why: e.message,
      todo: 'Bilgileri kontrol edip tekrar deneyin.',
    );
  }
}
