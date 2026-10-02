import 'package:ev_otomasyon/utils/qr_claim_parser.dart';
import 'package:ev_otomasyon/utils/qr_router.dart';
import 'package:ev_otomasyon/utils/wifi_qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const host = 'evotomasyon.gudeteknoloji.com.tr';

  group('QrClaimParser (sıkı)', () {
    final valid = <String, QrClaimData>{
      'https://$host/claim?uid=AHBU-S3-ABC123&pin=123456':
          const QrClaimData(uid: 'AHBU-S3-ABC123', pin: '123456'),
      '  https://$host/claim?pin=000123&uid=ahbu-s3-abc123  ':
          const QrClaimData(uid: 'AHBU-S3-ABC123', pin: '000123'), // kırp + büyük harf, baştaki sıfır korunur
      'https://EVOTOMASYON.gudeteknoloji.com.tr/claim?uid=AHBU-X-1A2&pin=654321':
          const QrClaimData(uid: 'AHBU-X-1A2', pin: '654321'),
      'https://$host:443/claim?device_uuid=AHBU-DEV-99&setup_pin=654321':
          const QrClaimData(uid: 'AHBU-DEV-99', pin: '654321'),
      'https://$host/claim?uid=AHBU-S3-ABC123&pin=123456#parca':
          const QrClaimData(uid: 'AHBU-S3-ABC123', pin: '123456'),
      '{"uid": "AHBU-JSON-BOARD", "pin": "987654"}':
          const QrClaimData(uid: 'AHBU-JSON-BOARD', pin: '987654'),
      '{"device_uuid":"ahbu-json-2","setup_pin":"012345","ekstra":1}':
          const QrClaimData(uid: 'AHBU-JSON-2', pin: '012345'),
    };
    valid.forEach((input, expected) {
      test('geçerli: ${input.length > 60 ? '${input.substring(0, 60)}…' : input}', () {
        expect(QrClaimParser.parse(input), expected);
      });
    });

    final invalid = <String, QrClaimError>{
      // şema / ana makine / yol
      'http://$host/claim?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.notHttps,
      'ftp://$host/claim?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.notHttps,
      'https://evil.example/claim?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.hostNotAllowed,
      'https://$host.evil.example/claim?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.hostNotAllowed,
      'https://user@$host/claim?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.hostNotAllowed,
      'https://$host:8443/claim?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.hostNotAllowed,
      'https://$host/other?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.badPath,
      'https://$host/claim/?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.badPath,
      'https://$host/?uid=AHBU-S3-ABC123&pin=123456': QrClaimError.badPath,
      // UID
      'https://$host/claim?uid=XYZ-S3-ABC123&pin=123456': QrClaimError.badUid,
      'https://$host/claim?uid=AHBU-A&pin=123456': QrClaimError.badUid,
      'https://$host/claim?uid=AHBU-S3-ABC_123&pin=123456': QrClaimError.badUid,
      'https://$host/claim?uid=AHBU-INVITE-ABC&pin=123456': QrClaimError.badUid, // ayrılmış önek
      'https://$host/claim?uid=AHBU-TR-123456&pin=123456': QrClaimError.badUid,
      'https://$host/claim?pin=123456': QrClaimError.badUid,
      // PIN
      'https://$host/claim?uid=AHBU-S3-ABC123': QrClaimError.missingPin,
      'https://$host/claim?uid=AHBU-S3-ABC123&pin=12345': QrClaimError.badPin,
      'https://$host/claim?uid=AHBU-S3-ABC123&pin=1234567': QrClaimError.badPin,
      'https://$host/claim?uid=AHBU-S3-ABC123&pin=12a456': QrClaimError.badPin,
      // tekrar eden / çakışan parametre
      'https://$host/claim?uid=AHBU-S3-ABC123&uid=AHBU-S3-ZZZ999&pin=123456': QrClaimError.badUid,
      'https://$host/claim?uid=AHBU-S3-ABC123&pin=123456&pin=654321': QrClaimError.missingPin,
      'https://$host/claim?uid=AHBU-S3-ABC123&device_uuid=AHBU-S3-ZZZ999&pin=123456': QrClaimError.badUid,
      // JSON: yalnızca String
      '{"uid": "AHBU-S3-ABC123", "pin": 123456}': QrClaimError.badPin,
      '{"uid": 12345, "pin": "123456"}': QrClaimError.badUid,
      '{"uid": ["AHBU-S3-ABC123"], "pin": "123456"}': QrClaimError.badUid,
      '{"uid": null, "pin": "123456"}': QrClaimError.badUid,
      '{"uid": "AHBU-S3-ABC123"}': QrClaimError.badPin,
      '{"uid": "AHBU-S3-ABC123", "pin": "12"}': QrClaimError.badPin,
      '{bozuk json': QrClaimError.malformed,
      '[1,2,3]': QrClaimError.malformed, // ne URL ne JSON nesnesi
      // ham/serbest metin ASLA UID olmaz
      'AHBU-PLAIN-01:112233': QrClaimError.notHttps, // şema gibi ayrıştırılır, https değil
      'AHBU-PLAIN-02/445566': QrClaimError.malformed,
      'AHBU-S3-ABC123': QrClaimError.malformed,
      'sadece-bir-metin': QrClaimError.malformed,
    };
    invalid.forEach((input, error) {
      test('reddedilir ($error): ${input.length > 55 ? '${input.substring(0, 55)}…' : input}', () {
        final result = QrClaimParser.parseDetailed(input);
        expect(result.data, isNull);
        expect(result.error, error);
        expect(QrClaimParser.parse(input), isNull);
      });
    });

    test('boş, null, çok uzun ve kontrol karakterli girdiler', () {
      expect(QrClaimParser.parse(null), isNull);
      expect(QrClaimParser.parseDetailed('').error, QrClaimError.empty);
      expect(QrClaimParser.parseDetailed('   ').error, QrClaimError.empty);
      final long = 'https://$host/claim?uid=AHBU-${'A' * 600}&pin=123456';
      expect(QrClaimParser.parseDetailed(long).error, QrClaimError.tooLong);
      expect(
        QrClaimParser.parseDetailed('https://$host/claim?uid=AHBU-S3-ABC123&pin=123456\u0000x').error,
        QrClaimError.malformed,
      );
    });

    test('izin listesi özelleştirilebilir (yalnızca açıkça verilince)', () {
      const url = 'https://10.0.2.2/claim?uid=AHBU-S3-ABC123&pin=123456';
      expect(QrClaimParser.parse(url), isNull);
      expect(QrClaimParser.parse(url, allowedHosts: <String>{'10.0.2.2'})?.uid, 'AHBU-S3-ABC123');
    });

    test('toString PIN içermez', () {
      expect(const QrClaimData(uid: 'AHBU-S3-ABC123', pin: '123456').toString(), isNot(contains('123456')));
      expect(const QrClaim(uid: 'AHBU-S3-ABC123', pin: '123456').toString(), isNot(contains('123456')));
    });

    test('normalizeUid / isValidPin yardımcıları', () {
      expect(QrClaimParser.normalizeUid(' ahbu-s3-abc123 '), 'AHBU-S3-ABC123');
      expect(QrClaimParser.normalizeUid('AHBU-INVITE'), isNull);
      expect(QrClaimParser.normalizeUid('AHBU-TR-123456'), isNull);
      expect(QrClaimParser.normalizeUid('AHBU-A'), isNull);
      expect(QrClaimParser.normalizeUid(null), isNull);
      expect(QrClaimParser.isValidPin(' 123456 '), isTrue);
      expect(QrClaimParser.isValidPin('12345'), isFalse);
      expect(QrClaimParser.isValidPin('12345a'), isFalse);
      expect(QrClaimParser.isValidPin(null), isFalse);
    });
  });

  group('QrRouter', () {
    test('claim URL -> QrClaim', () {
      final p = QrRouter.route('https://$host/claim?uid=AHBU-S3-ABC123&pin=123456');
      expect(p, isA<QrClaim>());
      expect((p as QrClaim).uid, 'AHBU-S3-ABC123');
      expect(p.pin, '123456');
    });

    test('claim JSON -> QrClaim', () {
      expect(QrRouter.route('{"uid":"AHBU-S3-ABC123","pin":"123456"}'), isA<QrClaim>());
    });

    test('AHBU-INVITE: -> QrInvite (kod büyük harfe çevrilir)', () {
      final p = QrRouter.route('AHBU-INVITE:ahbu-g-482910');
      expect(p, isA<QrInvite>());
      expect((p as QrInvite).code, 'AHBU-G-482910');
      expect(QrRouter.route('ahbu-invite:ABCDEFGHJK'), isA<QrInvite>());
    });

    test('AHBU-TRANSFER: ve çıplak AHBU-TR- -> QrTransfer', () {
      final a = QrRouter.route('AHBU-TRANSFER:AHBU-TR-482910');
      final b = QrRouter.route('AHBU-TR-482910');
      final c = QrRouter.route('ahbu-tr-482910');
      expect(a, isA<QrTransfer>());
      expect((a as QrTransfer).code, 'AHBU-TR-482910');
      expect((b as QrTransfer).code, 'AHBU-TR-482910');
      expect((c as QrTransfer).code, 'AHBU-TR-482910');
    });

    test('davet / devir önekleri cihaz kimliği ile karışmaz', () {
      // Önceden: "AHBU-" ile başlayıp ':' içermeyen her şey davet sayılıyordu (cihaz UID'si dahil).
      expect(QrRouter.route('AHBU-S3-ABC123'), isA<QrUnknown>());
      expect(QrRouter.route('AHBU-S3-ABC123:123456'), isA<QrUnknown>());
      expect(QrRouter.route('AHBU-INVITE:123456'), isA<QrInvite>()); // devre dışı UID olamaz
      expect(QrRouter.route('AHBU-INVITE:%%%'), isA<QrUnknown>());
      expect(QrRouter.route('AHBU-TRANSFER:'), isA<QrUnknown>());
    });

    test('çıplak davet kodu yalnızca elle giriş modunda', () {
      expect(QrRouter.route('AHBU-482910'), isA<QrUnknown>());
      const manual = QrRouter(allowBareInviteCodes: true);
      expect(manual.parse('ahbu-482910'), isA<QrInvite>());
      expect(manual.parse('AHBU-G-482910'), isA<QrInvite>());
      expect(manual.parse('AHBU-S3-ABC123'), isA<QrUnknown>()); // cihaz UID'si davet olmaz
      expect(manual.parse('rastgele'), isA<QrUnknown>());
    });

    test('Wi-Fi karekodu -> QrWifi; WEP/EAP/bozuk -> QrUnknown(+neden)', () {
      final ok = QrRouter.route('WIFI:T:WPA;S:Ev Agi;P:sifre12345;;');
      expect(ok, isA<QrWifi>());
      expect((ok as QrWifi).credentials.ssid, 'Ev Agi');

      final wep = QrRouter.route('WIFI:T:WEP;S:Eski;P:12345;;');
      expect(wep, isA<QrUnknown>());
      expect((wep as QrUnknown).message, contains('WEP'));
      final eap = QrRouter.route('WIFI:T:WPA2-EAP;S:Kurum;E:PEAP;;');
      expect((eap as QrUnknown).message, contains('EAP'));
    });

    test('tanınmayan / boş / uzun / kontrol karakterli içerik', () {
      expect((QrRouter.route(null) as QrUnknown).reason, QrUnknownReason.empty);
      expect((QrRouter.route('  ') as QrUnknown).reason, QrUnknownReason.empty);
      expect((QrRouter.route('x' * 600) as QrUnknown).reason, QrUnknownReason.tooLong);
      expect((QrRouter.route('AHBU-INVITE:ABC\u0007DEF') as QrUnknown).reason, QrUnknownReason.malformed);
      expect((QrRouter.route('merhaba dünya') as QrUnknown).reason, QrUnknownReason.unrecognized);
      expect((QrRouter.route('javascript:alert(1)') as QrUnknown).reason, QrUnknownReason.unrecognized);
      expect(QrRouter.route('http://$host/claim?uid=AHBU-S3-ABC123&pin=123456'), isA<QrUnknown>());
      expect(QrRouter.route('https://evil.example/claim?uid=AHBU-S3-ABC123&pin=123456'), isA<QrUnknown>());
    });

    test('ham metin hiçbir zaman QrClaim üretmez (rastgele girdi taraması)', () {
      const samples = <String>[
        'AHBU-S3-ABC123',
        'AHBU-S3-ABC123/123456',
        'uid=AHBU-S3-ABC123&pin=123456',
        'claim?uid=AHBU-S3-ABC123&pin=123456',
        '//$host/claim?uid=AHBU-S3-ABC123&pin=123456',
        'AHBU-S3-ABC123 123456',
        '123456',
      ];
      for (final s in samples) {
        expect(QrRouter.route(s), isNot(isA<QrClaim>()), reason: s);
      }
    });

    test('sealed sınıf: tüm türler switch ile kapsanır', () {
      String describe(QrPayload p) => switch (p) {
            QrClaim() => 'claim',
            QrInvite() => 'invite',
            QrTransfer() => 'transfer',
            QrWifi() => 'wifi',
            QrUnknown() => 'unknown',
          };
      expect(describe(QrRouter.route('AHBU-TR-482910')), 'transfer');
      expect(describe(QrRouter.route('nope')), 'unknown');
    });
  });

  group('WifiQrParser', () {
    WifiQrParseResult parse(String raw) => WifiQrParser.parseDetailed(raw);

    test('standart WPA karekodu', () {
      final c = parse('WIFI:T:WPA;S:Ev_Agi;P:sifre123;H:false;;').credentials!;
      expect(c.ssid, 'Ev_Agi');
      expect(c.password, 'sifre123');
      expect(c.security, 'WPA');
      expect(c.hidden, isFalse);
      expect(c.isOpen, isFalse);
    });

    test('alan sırası serbest, anahtarlar büyük/küçük harf duyarsız, gizli ağ', () {
      final c = parse('wifi:H:true;P:parola1234;S:Gizli;t:wpa2;;').credentials!;
      expect(c.ssid, 'Gizli');
      expect(c.hidden, isTrue);
      expect(c.security, 'WPA');
    });

    test('kaçışlı ayırıcılar: \\\\ \\; \\, \\: \\"', () {
      final c = parse(r'WIFI:T:WPA;S:Ev\;Agi\:2\,4\\G;P:a\"b\;c\\d12345;;').credentials!;
      expect(c.ssid, r'Ev;Agi:2,4\G');
      expect(c.password, r'a"b;c\d12345');
    });

    test('çift tırnaklı değer: tırnaklar atılır, içteki kaçışlı tırnak korunur', () {
      expect(parse('WIFI:T:WPA;S:"12345678";P:"parola 1234";;').credentials!.ssid, '12345678');
      expect(parse('WIFI:T:WPA;S:"12345678";P:"parola 1234";;').credentials!.password, 'parola 1234');
      // Tırnak ŞÂRT değil: kaçışlı tırnaklar değerin parçasıdır.
      expect(parse(r'WIFI:T:WPA;S:\"Ag\";P:parola1234;;').credentials!.ssid, '"Ag"');
      // Kaçışsız kapanış tırnağı yok: tırnaklı sayılmaz.
      expect(parse(r'WIFI:T:WPA;S:"Ag\";P:parola1234;;').credentials!.ssid, '"Ag"');
    });

    test('açık ağ: nopass veya T yok + parola yok; parola yok sayılır', () {
      final a = parse('WIFI:T:nopass;S:Misafir;;').credentials!;
      final b = parse('WIFI:S:Misafir;;').credentials!;
      final c = parse('WIFI:T:nopass;S:Misafir;P:ihmal;;').credentials!;
      for (final x in <WifiQrCredentials>[a, b, c]) {
        expect(x.isOpen, isTrue);
        expect(x.password, '');
        expect(x.security, 'nopass');
      }
    });

    test('T yok + parola var -> WPA varsayılır', () {
      final c = parse('WIFI:S:Ag;P:parola1234;;').credentials!;
      expect(c.security, 'WPA');
      expect(c.isOpen, isFalse);
    });

    test('WPA3/SAE kabul edilir', () {
      expect(parse('WIFI:T:SAE;S:Ag;P:parola1234;;').isOk, isTrue);
      expect(parse('WIFI:T:WPA3;S:Ag;P:parola1234;;').isOk, isTrue);
    });

    final errors = <String, WifiQrError>{
      'WIFI:T:WEP;S:Ag;P:12345;;': WifiQrError.wepUnsupported,
      'WIFI:T:WPA2-EAP;S:Kurum;;': WifiQrError.eapUnsupported,
      'WIFI:T:WPA;S:Kurum;E:PEAP;P:parola1234;;': WifiQrError.eapUnsupported,
      'WIFI:T:WPA;S:Kurum;A:anon;P:parola1234;;': WifiQrError.eapUnsupported,
      'WIFI:T:XYZ;S:Ag;P:parola1234;;': WifiQrError.unknownSecurity,
      'WIFI:T:WPA;P:parola1234;;': WifiQrError.missingSsid,
      'WIFI:T:WPA;S:;P:parola1234;;': WifiQrError.missingSsid,
      'WIFI:T:WPA;S:Ag;P:kisa;;': WifiQrError.passwordLength, // < 8
      'WIFI:T:WPA;S:Ag;P:;;': WifiQrError.passwordLength, // WPA + boş parola açık ağ sayılmaz
      'WIFI:T:WPA;S:Ag;P:1234567;;': WifiQrError.passwordLength,
      'WIFI:T:WPA;S:Ag;P:\u0001parola1234;;': WifiQrError.controlCharacters,
      'WIFI:T:WPA;S:A\u0000g;P:parola1234;;': WifiQrError.controlCharacters,
      r'WIFI:T:WPA;S:Ag;P:parola1234\': WifiQrError.malformed, // yarım kaçış
      'METIN': WifiQrError.notWifi,
    };
    errors.forEach((input, error) {
      test('reddedilir ($error)', () {
        final r = parse(input);
        expect(r.credentials, isNull);
        expect(r.error, error);
        expect(WifiQrParser.parse(input), isNull);
        expect(error.message, isNotEmpty);
      });
    });

    test('SSID sınırı 32 BAYT (UTF-8), karakter değil', () {
      expect(parse('WIFI:T:WPA;S:${'a' * 32};P:parola1234;;').isOk, isTrue);
      expect(parse('WIFI:T:WPA;S:${'a' * 33};P:parola1234;;').error, WifiQrError.ssidTooLong);
      // 17 x "ğ" = 34 bayt (karakter sayısı 17 < 32 olsa da reddedilmeli)
      expect(parse('WIFI:T:WPA;S:${'ğ' * 17};P:parola1234;;').error, WifiQrError.ssidTooLong);
      expect(parse('WIFI:T:WPA;S:${'ğ' * 16};P:parola1234;;').isOk, isTrue);
    });

    test('parola sınırı 8..63 bayt', () {
      expect(parse('WIFI:T:WPA;S:Ag;P:${'p' * 8};;').isOk, isTrue);
      expect(parse('WIFI:T:WPA;S:Ag;P:${'p' * 63};;').isOk, isTrue);
      expect(parse('WIFI:T:WPA;S:Ag;P:${'p' * 64};;').error, WifiQrError.passwordLength);
    });

    test('çok uzun karekod reddedilir', () {
      expect(parse('WIFI:T:WPA;S:Ag;P:${'p' * 600};;').error, WifiQrError.tooLong);
    });

    test('null / boş', () {
      expect(WifiQrParser.parse(null), isNull);
      expect(WifiQrParser.parse(''), isNull);
    });
  });
}
