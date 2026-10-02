import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/utils/magic_link_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sihirli bağlantı (`…#token=<opak>`) çözücü: CONTRACTS §1.1b.
void main() {
  const host = 'evotomasyon.gudeteknoloji.com.tr';
  // Sunucu `crypto.randomBytes(32).toString('base64url')` üretir (43 karakter, [A-Za-z0-9_-]).
  const token = 'A1b2C3d4E5f6G7h8I9j0K_l-M2n3O4p5Q6r7S8t9U0v';

  MagicLinkParseResult parse(String url, {Set<String>? hosts}) =>
      MagicLinkParser.parseDetailed(url, allowedHosts: hosts);

  group('geçerli bağlantılar', () {
    test('/reset-password#token= -> resetPassword', () {
      final result = parse('https://$host/reset-password#token=$token');
      expect(result.isOk, isTrue);
      expect(result.link!.kind, MagicLinkKind.resetPassword);
      expect(result.link!.token, token);
      expect(result.error, isNull);
    });

    test('/magic-login ve /auth/magic-login -> magicLogin', () {
      expect(parse('https://$host/magic-login#token=$token').link!.kind, MagicLinkKind.magicLogin);
      expect(parse('https://$host/auth/magic-login#token=$token').link!.kind, MagicLinkKind.magicLogin);
    });

    test('küçük/büyük harf ana makine, sondaki /, açık 443 portu, ek parça parametreleri', () {
      expect(parse('https://${host.toUpperCase()}/reset-password#token=$token').isOk, isTrue);
      expect(parse('https://$host/reset-password/#token=$token').isOk, isTrue);
      expect(parse('https://$host:443/reset-password#token=$token').isOk, isTrue);
      expect(parse('https://$host/reset-password#utm=x&token=$token&lang=tr').link!.token, token);
      expect(parse('  https://$host/reset-password#token=$token  \n').isOk, isTrue, reason: 'baş/son boşluk kırpılır');
    });

    test('yüzde kodlu base64url karakterleri çözülür', () {
      final encoded = token.replaceAll('-', '%2D').replaceAll('_', '%5F');
      expect(parse('https://$host/reset-password#token=$encoded').link!.token, token);
    });

    test('izinli ana makine kümesi parametreyle genişletilebilir', () {
      expect(parse('https://qa.example.test/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
      expect(parse('https://qa.example.test/reset-password#token=$token', hosts: <String>{'qa.example.test'}).isOk, isTrue);
    });

    test('hata ayıklama derlemesinde yapılandırılan API ana makinesi de izinlidir; release\'te yok sayılır', () {
      final previous = AppConfig.current;
      addTearDown(() => AppConfig.current = previous);
      AppConfig.current = AppConfig.forTest(apiBaseUrl: 'http://qa-host.example.test:5000/api');
      expect(parse('https://qa-host.example.test/reset-password#token=$token').isOk, isTrue);

      AppConfig.current = AppConfig.defaults;
      expect(parse('https://qa-host.example.test/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
    });
  });

  group('reddedilen bağlantılar', () {
    test('boş / çok uzun / kontrol karakteri', () {
      expect(parse('').error, MagicLinkError.empty);
      expect(parse('   ').error, MagicLinkError.empty);
      expect(MagicLinkParser.parseDetailed(null).error, MagicLinkError.empty);
      expect(parse('https://$host/reset-password#token=${'a' * 1100}').error, MagicLinkError.tooLong);
      expect(parse('https://$host/reset-password#token=$token\nEk').error, MagicLinkError.malformed);
      expect(parse('https://$host/reset-password#token=$token\u0000').error, MagicLinkError.malformed);
    });

    test('şema ve ana makine: yalnızca https + izinli ana makine, kullanıcı bilgisi / özel port yok', () {
      expect(parse('http://$host/reset-password#token=$token').error, MagicLinkError.notHttps);
      expect(parse('ftp://$host/reset-password#token=$token').error, MagicLinkError.notHttps);
      expect(parse('$host/reset-password#token=$token').error, MagicLinkError.malformed);
      expect(parse('https://evil.example/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
      expect(parse('https://$host.evil.example/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
      expect(parse('https://evil.example@$host/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
      expect(parse('https://attacker:pw@$host/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
      expect(parse('https://$host:8443/reset-password#token=$token').error, MagicLinkError.hostNotAllowed);
    });

    test('yol: yalnızca bilinen üç yol', () {
      for (final path in <String>['/claim', '/reset-passwords', '/reset-password/extra', '/', '', '/magic', '/auth/reset-password']) {
        expect(parse('https://$host$path#token=$token').error, MagicLinkError.badPath, reason: path);
      }
    });

    test('belirteç sorgu dizgisinde (?token=) REDDEDİLİR (sunucu/proxy loglarına düşer)', () {
      expect(parse('https://$host/reset-password?token=$token').error, MagicLinkError.tokenInQuery);
      expect(parse('https://$host/magic-login?token=$token#token=$token').error, MagicLinkError.tokenInQuery,
          reason: 'parçada da olsa sorguda taşıyan bağlantı geçersiz');
      expect(parse('https://$host/reset-password?lang=tr#token=$token').isOk, isTrue,
          reason: 'belirteç taşımayan sorgu parametresi zararsız');
    });

    test('parça yok / belirteç yok', () {
      expect(parse('https://$host/reset-password').error, MagicLinkError.missingToken);
      expect(parse('https://$host/reset-password#').error, MagicLinkError.missingToken);
      expect(parse('https://$host/reset-password#foo=bar').error, MagicLinkError.missingToken);
    });

    test('belirteç biçimi: base64url, 16–512 karakter, tek parametre', () {
      for (final bad in <String>[
        'kisa',
        'a' * 15,
        'a' * 513,
        'abc def ghi jkl mno pqr',
        '<script>alert(1)</script>',
        'abc+def/ghi=jkl_mno-pqr012',
        'türkçe-karakter-içeren-belirteç',
        '',
      ]) {
        final result = parse('https://$host/reset-password#token=$bad');
        expect(result.isOk, isFalse, reason: bad);
        expect(result.error, anyOf(MagicLinkError.badToken, MagicLinkError.malformed), reason: bad);
      }
      expect(parse('https://$host/reset-password#token=$token&token=$token').error, MagicLinkError.badToken);
      expect(parse('https://$host/reset-password#token=%ZZ').error, anyOf(MagicLinkError.badToken, MagicLinkError.malformed));
    });

    test('hata mesajları belirteci içermez; MagicLink.toString belirteci gizler', () {
      final result = parse('https://evil.example/reset-password#token=$token');
      expect(result.error!.message, isNot(contains(token)));
      final link = parse('https://$host/reset-password#token=$token').link!;
      expect(link.toString(), isNot(contains(token)));
      expect(link.toString(), contains('******'));
    });

    test('parse(): geçersizde null, geçerlide bağlantı', () {
      expect(MagicLinkParser.parse('rastgele metin'), isNull);
      expect(MagicLinkParser.parse('https://$host/reset-password#token=$token')?.token, token);
    });

    test('her hata kodunun kullanıcıya gösterilebilir Türkçe mesajı var', () {
      for (final error in MagicLinkError.values) {
        expect(error.message, isNotEmpty);
      }
    });
  });
}
