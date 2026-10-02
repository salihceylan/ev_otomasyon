import 'dart:math';

import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/common/cooldown.dart';
import 'package:ev_otomasyon/ui/common/date_format.dart';
import 'package:ev_otomasyon/ui/common/sha256.dart';
import 'package:ev_otomasyon/ui/common/validators.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// Ortak doğrulayıcılar, Türkçe onay ifadesi eşleşmesi, SHA-256 (Apple nonce), tarih biçimleri ve
/// geri sayım yardımcısı.
void main() {
  group('e-posta doğrulayıcı (gevşek ve basit)', () {
    test('geçerli adresleri reddetmez: artı etiketi, alt alan adı, uzun TLD, rakam, tire', () {
      for (final ok in <String>[
        'ayse@ornek.com',
        'ayse.yilmaz+ev@mail.ornek.com.tr',
        'a_b-c@alt.alan.ornek.photography',
        '1234@ornek.io',
        '  bosluklu@ornek.com  ',
        'ÇAĞLAR@ornek.com.tr', // yerel kısım yalnızca yasak karakterleri dışlar
      ]) {
        expect(AuthValidators.isValidEmail(ok), isTrue, reason: ok);
        expect(AuthValidators.emailError(ok), isNull, reason: ok);
      }
    });

    test('geçersiz biçimleri açık mesajla reddeder', () {
      expect(AuthValidators.emailError(''), 'Lütfen e-posta adresinizi girin');
      expect(AuthValidators.emailError(null), 'Lütfen e-posta adresinizi girin');
      for (final bad in <String>['gecersiz', 'a@b', 'a@@b.com', 'a b@c.com', 'a@b.c', '@ornek.com', 'a@ornek.', 'a,b@c.com']) {
        expect(AuthValidators.emailError(bad), 'Geçerli bir e-posta adresi girin', reason: bad);
      }
      expect(AuthValidators.isValidEmail('${'a' * 250}@b.com'), isFalse, reason: '254 karakter sınırı');
    });
  });

  group('parola doğrulayıcıları', () {
    test('giriş formu yalnızca boş mu kontrol eder (kısa/eski parolalar reddedilmez)', () {
      expect(AuthValidators.loginPasswordError(''), 'Lütfen şifrenizi girin');
      expect(AuthValidators.loginPasswordError(null), 'Lütfen şifrenizi girin');
      expect(AuthValidators.loginPasswordError('123'), isNull);
      expect(AuthValidators.loginPasswordError(' '), isNull, reason: 'kırpma yok');
    });

    test('kayıt politikası: en az 10 karakter, 72 bayt sınırı, kırpılmaz, yalnız boşluk olamaz', () {
      expect(AuthValidators.passwordPolicyError(''), 'Lütfen bir şifre belirleyin');
      expect(AuthValidators.passwordPolicyError('kisa1234'), 'Şifre en az 10 karakter olmalıdır');
      expect(AuthValidators.passwordPolicyError('on-karakter'), isNull);
      expect(AuthValidators.passwordPolicyError('  boşluklu parola  '), isNull, reason: 'baş/son boşluk korunur');
      expect(AuthValidators.passwordPolicyError('          '), 'Şifre yalnızca boşluktan oluşamaz');
      expect(AuthValidators.passwordPolicyError('a' * 72), isNull);
      expect(AuthValidators.passwordPolicyError('a' * 73), contains('en fazla 72 bayt'));
      // Türkçe karakterler UTF-8'de 2 bayttır: 40 x 'ş' = 80 bayt.
      expect(AuthValidators.passwordPolicyError('ş' * 40), contains('en fazla 72 bayt'));
    });
  });

  group('telefon', () {
    test('ayırıcılar atılır; 10-15 rakam (+ ile başlayabilir) geçerlidir', () {
      expect(AuthValidators.normalizePhone('0555 123 45 67'), '05551234567');
      expect(AuthValidators.normalizePhone('+90 (555) 123-45-67'), '+905551234567');
      expect(AuthValidators.normalizePhone('555.123.4567'), '5551234567');
      expect(AuthValidators.normalizePhone('12345'), isNull);
      expect(AuthValidators.normalizePhone('0555abc4567'), isNull);
      expect(AuthValidators.normalizePhone(null), isNull);
    });

    test('isteğe bağlı alan boş geçerlidir; zorunlu alan boş değildir', () {
      expect(AuthValidators.phoneError(''), isNull);
      expect(AuthValidators.phoneError('', required: true), 'Lütfen telefon numaranızı girin');
      expect(AuthValidators.phoneError('123'), contains('Geçerli bir telefon'));
      expect(AuthValidators.phoneError('0555 123 45 67'), isNull);
    });

    test('e-posta veya telefon kimliği normalleştirilir', () {
      final mail = AuthValidators.parseIdentifier('  Ayse@Ornek.COM ')!;
      expect(mail.isEmail, isTrue);
      expect(mail.value, 'ayse@ornek.com');
      final phone = AuthValidators.parseIdentifier('0555 123 45 67')!;
      expect(phone.isPhone, isTrue);
      expect(phone.value, '05551234567');
      expect(AuthValidators.parseIdentifier('ne-biri-ne-diger'), isNull);
      expect(AuthValidators.identifierError(''), 'Lütfen e-posta veya telefon numaranızı girin');
      expect(AuthValidators.identifierError('x@'), contains('Geçerli bir e-posta adresi veya telefon'));
    });

    test('altı haneli kod doğrulayıcısı', () {
      expect(AuthValidators.sixDigitCodeError(''), isNotNull);
      expect(AuthValidators.sixDigitCodeError('12345'), 'Kod tam 6 rakam olmalıdır');
      expect(AuthValidators.sixDigitCodeError('12a456'), 'Kod tam 6 rakam olmalıdır');
      expect(AuthValidators.sixDigitCodeError(' 123456 '), isNull);
    });
  });

  group('Wi-Fi doğrulayıcıları', () {
    test('SSID en çok 32 BAYT (UTF-8): çok baytlı karakterler sayılır', () {
      expect(WifiValidators.ssidError(''), isNotNull);
      expect(WifiValidators.ssidError('a' * 32), isNull);
      expect(WifiValidators.ssidError('a' * 33), contains('32 bayt'));
      expect(WifiValidators.ssidError('ş' * 16), isNull, reason: '16 x 2 bayt = 32');
      expect(WifiValidators.ssidError('ş' * 17), contains('32 bayt'));
    });

    test('parola boş (açık ağ) ya da 8-63 bayt; şifreli bilinen ağda boş reddedilir', () {
      expect(WifiValidators.passwordError(''), isNull);
      expect(WifiValidators.passwordError('', networkSecured: true), contains('şifreli'));
      expect(WifiValidators.passwordError('1234567'), contains('8 ile 63'));
      expect(WifiValidators.passwordError('12345678'), isNull);
      expect(WifiValidators.passwordError('a' * 63), isNull);
      expect(WifiValidators.passwordError('a' * 64), contains('8 ile 63'));
    });

    test('baş/son boşluk yalnızca bildirilir, değer değiştirilmez', () {
      expect(WifiValidators.hasEdgeWhitespace(' ev'), isTrue);
      expect(WifiValidators.hasEdgeWhitespace('ev '), isTrue);
      expect(WifiValidators.hasEdgeWhitespace('e v'), isFalse);
      expect(WifiValidators.hasEdgeWhitespace(''), isFalse);
    });
  });

  group('Türkçe onay ifadesi', () {
    test('SİL / sil / SIL / Sil hepsi eşleşir (noktalı-noktasız i katlanır)', () {
      for (final input in <String>['SİL', 'sil', 'SIL', 'Sil', ' sıl ', 'SİL']) {
        expect(confirmPhraseMatches(input, 'SİL'), isTrue, reason: input);
      }
      expect(confirmPhraseMatches('SIL ', 'SİL'), isTrue);
    });

    test('farklı ifade, kısmi ifade ve boş ifade eşleşmez', () {
      expect(confirmPhraseMatches('SİLL', 'SİL'), isFalse);
      expect(confirmPhraseMatches('SI', 'SİL'), isFalse);
      expect(confirmPhraseMatches('', 'SİL'), isFalse);
      expect(confirmPhraseMatches('x', ''), isFalse, reason: 'boş ifade ile "boş = onay" olmaz');
    });

    test('cihaz kimliği büyük/küçük harf duyarsız eşleşir', () {
      expect(confirmPhraseMatches('ahbu-s3-1a2b3c', 'AHBU-S3-1A2B3C'), isTrue);
      expect(confirmPhraseMatches('AHBU-S3-1A2B3D', 'AHBU-S3-1A2B3C'), isFalse);
    });
  });

  group('SHA-256 (Apple nonce özeti)', () {
    test('NIST test vektörleri', () {
      expect(sha256Hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
        sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('64 bayttan uzun girdi (çoklu blok) doğru özetlenir', () {
      // 1000 adet 'a'
      expect(sha256Hex('a' * 1000), '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
    });

    test('ham nonce: istenen uzunlukta, yalnızca [A-Za-z0-9], her seferinde farklı', () {
      final a = generateRawNonce();
      final b = generateRawNonce();
      expect(a.length, 32);
      expect(RegExp(r'^[A-Za-z0-9]{32}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
      expect(generateRawNonce(16, Random(1)).length, 16);
    });
  });

  group('tarih biçimleri', () {
    test('UTC değer yerel saate çevrilerek gösterilir (aynı an, farklı gösterim nesneleri aynı çıktıyı verir)', () {
      final utc = DateTime.utc(2026, 10, 1, 21, 5);
      expect(formatLocalDateTime(utc), formatLocalDateTime(utc.toLocal()));
      final local = utc.toLocal();
      expect(
        formatLocalDateTime(utc),
        '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
      );
      expect(formatLocalTime(utc), formatLocalTime(local));
    });

    test('kalan süre ve geri sayım', () {
      expect(formatRemaining(Duration.zero), 'Süresi doldu');
      expect(formatRemaining(const Duration(seconds: -5)), 'Süresi doldu');
      expect(formatRemaining(const Duration(seconds: 45)), '45 sn');
      expect(formatRemaining(const Duration(minutes: 12)), '12 dk');
      expect(formatRemaining(const Duration(hours: 5, minutes: 20)), '5 saat 20 dk');
      expect(formatRemaining(const Duration(hours: 5)), '5 saat');
      expect(formatRemaining(const Duration(days: 2, hours: 3)), '2 gün 3 saat');
      expect(formatCountdown(125), '2:05');
      expect(formatCountdown(-3), '0:00');
    });
  });

  group('Cooldown (sunucu bekleme süresi geri sayımı)', () {
    test('sahte saatle geri sayar, bitince durur ve bildirir', () async {
      final clock = FakeClock();
      var notifications = 0;
      final cooldown = Cooldown(clock, () => notifications++);

      expect(cooldown.isActive, isFalse);
      cooldown.start(const Duration(seconds: 30));
      expect(cooldown.isActive, isTrue);
      expect(cooldown.remainingSeconds, 30);

      clock.advance(const Duration(seconds: 10));
      expect(cooldown.remainingSeconds, 20);

      clock.advance(const Duration(seconds: 20));
      expect(cooldown.isActive, isFalse);
      expect(notifications, greaterThan(2));
      expect(clock.activeTimerCount, 0, reason: 'bitince zamanlayıcı kalmaz');
      cooldown.dispose();
    });

    test('yeni bekleme öncekinin yerine geçer; dispose sonrası geri çağrı çalışmaz', () {
      final clock = FakeClock();
      var notifications = 0;
      final cooldown = Cooldown(clock, () => notifications++);
      cooldown.start(const Duration(seconds: 60));
      cooldown.start(const Duration(seconds: 5));
      expect(cooldown.remainingSeconds, 5);
      expect(clock.activeTimerCount, 1);

      cooldown.dispose();
      final before = notifications;
      clock.advance(const Duration(seconds: 10));
      expect(notifications, before);
      expect(cooldown.isActive, isFalse);
    });

    test('sıfır/negatif süre beklemeyi başlatmaz', () {
      final clock = FakeClock();
      final cooldown = Cooldown(clock, () {});
      cooldown.start(Duration.zero);
      expect(cooldown.isActive, isFalse);
      cooldown.start(const Duration(seconds: -4));
      expect(cooldown.isActive, isFalse);
      cooldown.dispose();
    });
  });
}
