import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

const String kHome = '11111111-1111-4111-8111-111111111111';

/// Kimlik / hesap / servis oturumu yönetimi / cihaz kimliği uçları (CONTRACTS §1.1b, §1.3, §1.5).
void main() {
  late MockApi api;
  late FakeClock clock;
  late EvCloudApiService service;
  late List<SessionEndReason> expired;

  setUp(() {
    api = MockApi();
    clock = FakeClock();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock);
    expired = <SessionEndReason>[];
    service.onSessionExpired = expired.add;
  });

  tearDown(() => service.dispose());

  /// Yer tutucu (gerçek olmayan) oturum belirteçleriyle giriş yapılmış durum.
  void signedIn() => service
    ..setAuthToken('access-old')
    ..setRefreshToken('refresh-old');

  group('hata gövdesi alanları', () {
    test('429: retry_after + resend_after + Retry-After başlığı', () async {
      api.on(
        'POST',
        '/api/v1/auth/otp/send',
        (r) => errorResponse(
          429,
          'Yeni kod istemek için 42 saniye bekleyin.',
          code: 'RATE_LIMITED',
          headers: <String, String>{'Retry-After': '42'},
          extra: <String, dynamic>{'retry_after': 42, 'resend_after': 42},
        ),
      );
      try {
        await service.sendPhoneOtp('+905551112233');
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.isRateLimited, isTrue);
        expect(e.retryAfter, const Duration(seconds: 42));
        expect(e.resendAfter, const Duration(seconds: 42));
        expect(e.message, contains('42'));
      }
    });

    test('kod doğrulama hatası: remaining_attempts', () async {
      api.on(
        'POST',
        '/api/v1/auth/otp/verify',
        (r) => errorResponse(401, 'Hatalı doğrulama kodu.', code: 'INVALID_CREDENTIALS', extra: <String, dynamic>{'remaining_attempts': 3}),
      );
      try {
        await service.verifyPhoneOtp('+905551112233', '000000');
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.isInvalidCredentials, isTrue);
        expect(e.remainingAttempts, 3);
        expect(e.resendAfter, isNull);
      }
      expect(expired, isEmpty, reason: 'kimliksiz uçta 401 oturum sonu değildir');
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });

    test('remaining_attempts: 0 geçerli; negatif/bozuk yok sayılır', () async {
      for (final entry in <Object, int?>{0: 0, -1: null, 'x': null, 2.0: 2}.entries) {
        api.on(
          'POST',
          '/api/v1/auth/reset-password',
          (r) => errorResponse(400, 'Hatalı kod.', code: 'VALIDATION', extra: <String, dynamic>{'remaining_attempts': entry.key}),
        );
        try {
          await service.resetPassword(identifier: 'a@b.c', code: '123456', newPassword: 'yeni-parola-12');
          fail('hata bekleniyordu');
        } on ApiException catch (e) {
          expect(e.remainingAttempts, entry.value, reason: '${entry.key}');
        }
      }
    });

    test('503 DELIVERY_FAILED / SERVICE_UNAVAILABLE mesajı gösterilir; diğer 5xx genel mesaja düşer', () async {
      api.on('POST', '/api/v1/auth/forgot-password',
          (r) => errorResponse(503, 'Şifre sıfırlama e-postası gönderilemedi. Lütfen daha sonra tekrar deneyin.', code: 'DELIVERY_FAILED'));
      try {
        await service.forgotPassword('a@b.c');
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.isDeliveryFailed, isTrue);
        expect(e.message, contains('e-postası gönderilemedi'));
      }

      api.on('POST', '/api/v1/auth/forgot-password',
          (r) => errorResponse(503, 'Google girişi yapılandırılmamış.', code: 'SERVICE_UNAVAILABLE'));
      try {
        await service.forgotPassword('a@b.c');
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.isServiceUnavailable, isTrue);
        expect(e.message, contains('yapılandırılmamış'));
      }

      for (final status in <int>[500, 502, 503]) {
        api.on('POST', '/api/v1/auth/forgot-password',
            (r) => errorResponse(status, 'ERROR: relation "users" does not exist at /srv/app/db.js:10', code: 'INTERNAL'));
        try {
          await service.forgotPassword('a@b.c');
          fail('hata bekleniyordu');
        } on ApiException catch (e) {
          expect(e.message, isNot(contains('relation')), reason: 'iç ayrıntı sızmamalı ($status)');
          expect(e.message, isNot(contains('/srv')));
        }
      }
    });

    test('çok uzun sunucu mesajı 300 karaktere kırpılır', () async {
      api.on('POST', '/api/v1/auth/login', (r) => errorResponse(400, 'x' * 1000, code: 'VALIDATION'));
      try {
        await service.login('a@b.c', 'p');
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.message.length, 300);
      }
    });

    test('yeni hata kodları için yardımcılar ve varsayılan mesajlar', () {
      ApiException make(String code, int status) => ApiException(statusCode: status, code: code, message: 'm');
      expect(make('INVALID_CREDENTIALS', 401).isInvalidCredentials, isTrue);
      expect(make('ACCOUNT_DISABLED', 403).isAccountDisabled, isTrue);
      expect(make('ACCOUNT_PENDING', 403).isAccountPending, isTrue);
      expect(make('REAUTH_REQUIRED', 403).isReauthRequired, isTrue);
      expect(make('GONE', 410).isGone, isTrue);
      expect(const ApiException(statusCode: 410, message: 'm').isGone, isTrue);
      expect(make('DELIVERY_FAILED', 503).isDeliveryFailed, isTrue);
      expect(make('SERVICE_UNAVAILABLE', 503).isServiceUnavailable, isTrue);
      expect(make('VALIDATION', 400).isValidation, isTrue);
      expect(ApiException.defaultMessageFor(410), contains('süresi'));
      expect(ApiException.defaultMessageFor(405), isNotEmpty);
      expect(ApiException.defaultMessageFor(413), contains('büyük'));
    });
  });

  group('kod isteme: CodeChallenge', () {
    test('OTP gönder: expires_in + resend_after; gövde yalnızca telefon', () async {
      api.on(
        'POST',
        '/api/v1/auth/otp/send',
        (r) => okResponse(<String, dynamic>{'message': 'Doğrulama kodu gönderildi.', 'expires_in': 300, 'resend_after': 60}),
      );
      final challenge = await service.sendPhoneOtp(' +905551112233 ');
      expect(api.requests.single.json, <String, dynamic>{'phone': '+905551112233'});
      expect(challenge.expiresIn, const Duration(seconds: 300));
      expect(challenge.resendAfter, const Duration(seconds: 60));
      expect(challenge.message, 'Doğrulama kodu gönderildi.');
    });

    test('şifre sıfırlama isteği: aynı yanıt biçimi; süre alanları yoksa varsayılan 60 sn', () async {
      api.on('POST', '/api/v1/auth/forgot-password', (r) => okResponse(<String, dynamic>{'message': 'Gönderildi.'}));
      final challenge = await service.forgotPassword(' a@b.c ');
      expect(api.requests.single.json, <String, dynamic>{'identifier': 'a@b.c'});
      expect(challenge.resendAfter, CodeChallenge.defaultResendAfter);
      expect(challenge.expiresIn, isNull);
    });

    test('debug_code / debug_token yalnızca release dışı derlemede dolar ve toString\'e yazılmaz', () {
      final json = <String, dynamic>{'message': 'm', 'debug_code': '123456', 'debug_token': 'tok-0123456789abcdef'};
      final dev = CodeChallenge.fromJson(json, releaseMode: false);
      expect(dev.debugCode, '123456');
      expect(dev.debugToken, 'tok-0123456789abcdef');
      expect(dev.toString(), isNot(contains('123456')));
      expect(dev.toString(), isNot(contains('tok-0123456789abcdef')));

      final release = CodeChallenge.fromJson(json, releaseMode: true);
      expect(release.debugCode, isNull);
      expect(release.debugToken, isNull);
    });

    test('bozuk süre alanları güvenli varsayılana düşer', () {
      final challenge = CodeChallenge.fromJson(<String, dynamic>{'expires_in': -5, 'resend_after': 'x'});
      expect(challenge.expiresIn, isNull);
      expect(challenge.resendAfter, CodeChallenge.defaultResendAfter);
    });
  });

  group('parola sıfırlama / sihirli bağlantı / sosyal giriş', () {
    test('bağlantı belirteci ile sıfırlama: identifier GÖNDERİLMEZ; yanıt oturum taşırsa oturum başlar', () async {
      api.on(
        'POST',
        '/api/v1/auth/reset-password',
        (r) => okResponse(<String, dynamic>{'access_token': 'acc-1', 'refresh_token': 'ref-1', 'user': <String, dynamic>{'id': 'u'}}),
      );
      final generation = service.sessionGeneration;
      await service.resetPassword(token: ' opaque-token-0123456789 ', newPassword: '  yeni parola  ');
      final body = api.requests.single.json!;
      expect(body.containsKey('identifier'), isFalse);
      expect(body['token'], 'opaque-token-0123456789');
      expect(body['new_password'], '  yeni parola  ', reason: 'parola kırpılmaz');
      expect(service.authToken, 'acc-1');
      expect(service.currentRefreshToken, 'ref-1');
      expect(service.sessionGeneration, greaterThan(generation));
    });

    test('kodla sıfırlama: identifier ve code zorunlu; eksikse ağa gitmeden doğrulama hatası', () async {
      await expectLater(
        service.resetPassword(newPassword: 'yeni-parola-12'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      await expectLater(
        service.resetPassword(code: '123456', newPassword: 'yeni-parola-12'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      expect(api.requests, isEmpty);

      api.on('POST', '/api/v1/auth/reset-password', (r) => okResponse(<String, dynamic>{'message': 'ok'}));
      await service.resetPassword(identifier: ' a@b.c ', code: ' 123456 ', newPassword: 'yeni-parola-12');
      expect(api.requests.single.json, <String, dynamic>{
        'identifier': 'a@b.c',
        'code': '123456',
        'new_password': 'yeni-parola-12',
      });
      expect(service.authToken, isNull, reason: 'yanıtta belirteç yoksa oturum başlamaz');
    });

    test('sihirli bağlantı girişi: POST + {token}; GET kullanılmaz', () async {
      api.on(
        'POST',
        '/api/v1/auth/magic-login',
        (r) => okResponse(<String, dynamic>{'access_token': 'acc-m', 'refresh_token': 'ref-m', 'user': <String, dynamic>{'id': 'u'}}),
      );
      await service.magicLogin(' opaque-token-0123456789 ');
      expect(api.requests.single.method, 'POST');
      expect(api.requests.single.json, <String, dynamic>{'token': 'opaque-token-0123456789'});
      expect(service.authToken, 'acc-m');
      expect(api.requests.single.url.query, isEmpty, reason: 'belirteç URL\'ye yazılmaz');
    });

    test('sihirli bağlantı: süresi dolmuş / kullanılmış (400/410) hata fırlatır, oturum açılmaz', () async {
      api.on('POST', '/api/v1/auth/magic-login', (r) => errorResponse(400, 'Geçersiz veya süresi dolmuş bağlantı.', code: 'VALIDATION'));
      await expectLater(service.magicLogin('opaque-token-0123456789'), throwsA(isA<ApiException>()));
      api.on('POST', '/api/v1/auth/magic-login', (r) => errorResponse(410, 'Bağlantı kullanılmış.', code: 'GONE'));
      await expectLater(service.magicLogin('opaque-token-0123456789'), throwsA(isA<ApiException>().having((e) => e.isGone, 'gone', isTrue)));
      expect(service.authToken, isNull);
    });

    test('Apple: nonce yalnızca verildiğinde gider', () async {
      api.on('POST', '/api/v1/auth/apple', (r) => okResponse(<String, dynamic>{'access_token': 'a'}));
      await service.loginWithApple(identityToken: 'apple-jwt', nonce: 'ham-nonce-123');
      expect(api.requests.last.json, <String, dynamic>{'identity_token': 'apple-jwt', 'nonce': 'ham-nonce-123'});
      await service.loginWithApple(identityToken: 'apple-jwt');
      expect(api.requests.last.json, <String, dynamic>{'identity_token': 'apple-jwt'});
      await service.loginWithApple(identityToken: 'apple-jwt', nonce: '');
      expect(api.requests.last.json!.containsKey('nonce'), isFalse);
    });

    test('giriş yanıtındaki must_change_password kullanıcı haritasında korunur', () async {
      api.on(
        'POST',
        '/api/v1/auth/login',
        (r) => okResponse(<String, dynamic>{
          'access_token': 'acc',
          'refresh_token': 'ref',
          'user': <String, dynamic>{'id': 'u', 'email': 'a@b.c', 'full_name': 'Ayşe', 'role': 'user', 'must_change_password': true},
        }),
      );
      final payload = await service.login('a@b.c', 'gecici-parola');
      final user = UserModel.fromJson(payload['user'] as Map<String, dynamic>);
      expect(user.mustChangePassword, isTrue);
    });
  });

  group('changePassword', () {
    test('istek: eski belirteçle imzalı, parolalar KIRPILMAZ; yanıttaki yeni belirteçler oturum olur', () async {
      signedIn();
      api.on(
        'POST',
        '/api/v1/auth/change-password',
        (r) => okResponse(<String, dynamic>{
          'access_token': 'access-new',
          'refresh_token': 'refresh-new',
          'user': <String, dynamic>{'id': 'u', 'must_change_password': false},
          'homes': <dynamic>[],
        }),
      );
      final generation = service.sessionGeneration;
      final payload = await service.changePassword(currentPassword: ' eski parola ', newPassword: ' yeni parola 12 ');

      final request = api.requests.single;
      expect(request.headers['Authorization'], 'Bearer access-old');
      expect(request.json, <String, dynamic>{'current_password': ' eski parola ', 'new_password': ' yeni parola 12 '});
      expect(service.authToken, 'access-new');
      expect(service.currentRefreshToken, 'refresh-new');
      expect(service.sessionGeneration, greaterThan(generation), reason: 'eski oturumdan kalan işlemler geçersiz olur');
      expect((payload['user'] as Map)['id'], 'u');
    });

    test('yanlış mevcut parola: 400 INVALID_CREDENTIALS; refresh denenmez, oturum KORUNUR', () async {
      signedIn();
      api.on('POST', '/api/v1/auth/change-password',
          (r) => errorResponse(400, 'Mevcut şifre hatalı.', code: 'INVALID_CREDENTIALS'));
      await expectLater(
        service.changePassword(currentPassword: 'yanlis', newPassword: 'yeni-parola-12'),
        throwsA(isA<ApiException>().having((e) => e.isInvalidCredentials, 'invalid', isTrue)),
      );
      expect(service.authToken, 'access-old');
      expect(service.currentRefreshToken, 'refresh-old');
      expect(expired, isEmpty);
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });

    test('access token süresi dolmuşsa tek-uçuş refresh ile yeniden denenir (401 TOKEN_EXPIRED)', () async {
      signedIn();
      api.on('POST', '/api/v1/auth/refresh', (r) => okResponse(<String, dynamic>{'access_token': 'access-refreshed', 'refresh_token': 'refresh-refreshed'}));
      var first = true;
      api.on('POST', '/api/v1/auth/change-password', (r) {
        if (first) {
          first = false;
          return errorResponse(401, 'Süre doldu', code: 'TOKEN_EXPIRED');
        }
        expect(r.headers['Authorization'], 'Bearer access-refreshed');
        return okResponse(<String, dynamic>{'access_token': 'access-new', 'refresh_token': 'refresh-new', 'user': <String, dynamic>{'id': 'u'}});
      });
      await service.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34');
      expect(api.count('POST', '/api/v1/auth/refresh'), 1);
      expect(service.authToken, 'access-new');
    });

    test('istek sürerken çıkış olursa dönen belirteçler UYGULANMAZ (çıkış yapılmış istemciye belirteç yazılmaz)', () async {
      signedIn();
      final gate = Completer<void>();
      api.on('POST', '/api/v1/auth/change-password', (r) async {
        await gate.future;
        return okResponse(<String, dynamic>{'access_token': 'access-new', 'refresh_token': 'refresh-new', 'user': <String, dynamic>{'id': 'u'}});
      });
      final pending = service.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34');
      await pumpEventQueue();
      service.clearSession(); // kullanıcı çıkış yaptı
      gate.complete();
      await pending;
      expect(service.hasSession, isFalse);
      expect(service.authToken, isNull);
      expect(service.currentRefreshToken, isNull);
    });

    test('istek sürerken başka kullanıcı girişi olursa yeni oturumun belirteçleri EZİLMEZ', () async {
      signedIn();
      final gate = Completer<void>();
      api.on('POST', '/api/v1/auth/change-password', (r) async {
        await gate.future;
        return okResponse(<String, dynamic>{'access_token': 'access-old-user-new', 'refresh_token': 'refresh-old-user-new'});
      });
      final pending = service.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34');
      await pumpEventQueue();
      service.beginSession(accessToken: 'access-other-user', refreshToken: 'refresh-other-user');
      gate.complete();
      await pending;
      expect(service.authToken, 'access-other-user');
      expect(service.currentRefreshToken, 'refresh-other-user');
    });

    test('boş parola alanları ve servis oturumu ağa gitmeden reddedilir', () async {
      signedIn();
      await expectLater(service.changePassword(currentPassword: '', newPassword: 'x'), throwsA(isA<ApiException>().having((e) => e.isValidation, 'v', isTrue)));
      await expectLater(service.changePassword(currentPassword: 'x', newPassword: ''), throwsA(isA<ApiException>().having((e) => e.isValidation, 'v', isTrue)));
      expect(api.requests, isEmpty);

      service.restoreServiceSession(
        accessToken: 'service-access',
        info: ServiceSessionInfo(homeId: kHome, homeName: 'Ev', expiresAt: clock.now().add(const Duration(hours: 1))),
      );
      await expectLater(
        service.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
      expect(api.requests, isEmpty);
    });

    test('ağ hatası: oturum korunur, ağ hatası olarak fırlatılır', () async {
      signedIn();
      api.on('POST', '/api/v1/auth/change-password', (r) => throw http.ClientException('bağlantı koptu'));
      await expectLater(
        service.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34'),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', isTrue)),
      );
      expect(service.authToken, 'access-old');
      expect(service.currentRefreshToken, 'refresh-old');
      expect(expired, isEmpty);
    });
  });

  group('uyelik-12: servis (PIN) oturumundan çıkış sunucuya bildirilir', () {
    test('revokeServiceSession: gövdesiz POST /auth/logout + Authorization: Bearer <servis JWT>', () async {
      api.on('POST', '/api/v1/auth/logout', (r) => okResponse(null));
      expect(await service.revokeServiceSession('svc-jwt-1'), isTrue);
      final req = api.where('POST', '/api/v1/auth/logout').single;
      final auth = req.headers.entries.firstWhere((e) => e.key.toLowerCase() == 'authorization').value;
      expect(auth, 'Bearer svc-jwt-1');
      expect(req.json?.containsKey('refresh_token') ?? false, isFalse);
    });

    test('ağ hatası fırlatmaz (false)', () async {
      api.on('POST', '/api/v1/auth/logout', (r) => throw http.ClientException('bağlantı yok'));
      expect(await service.revokeServiceSession('svc-jwt-1'), isFalse);
    });

    test('logout(): servis oturumunda Bearer ile; normal oturumda refresh_token yolu aynen', () async {
      api.on('POST', '/api/v1/auth/logout', (r) => okResponse(null));
      service.restoreServiceSession(
        accessToken: 'svc-jwt-2',
        info: ServiceSessionInfo(homeId: kHome, homeName: 'Servis', expiresAt: clock.now().add(const Duration(hours: 1))),
      );
      await service.logout();
      var req = api.where('POST', '/api/v1/auth/logout').last;
      expect(req.headers.entries.firstWhere((e) => e.key.toLowerCase() == 'authorization').value, 'Bearer svc-jwt-2');
      expect(service.hasSession, isFalse);

      signedIn();
      await service.logout();
      req = api.where('POST', '/api/v1/auth/logout').last;
      expect(req.json?['refresh_token'], 'refresh-old');
    });
  });

  group('logoutAll', () {
    test('başarı: tüm cihazlar iptal edilir ve yerel oturum silinir', () async {
      signedIn();
      api.on('POST', '/api/v1/auth/logout-all', (r) => okResponse(null));
      final generation = service.sessionGeneration;
      await service.logoutAll();
      expect(api.requests.single.headers['Authorization'], 'Bearer access-old');
      expect(service.hasSession, isFalse);
      expect(service.sessionGeneration, greaterThan(generation));
    });

    test('istek sürerken başka kullanıcı girişi olursa o oturum silinmez', () async {
      signedIn();
      final gate = Completer<void>();
      api.on('POST', '/api/v1/auth/logout-all', (r) async {
        await gate.future;
        return okResponse(null);
      });
      final pending = service.logoutAll();
      await pumpEventQueue();
      service.beginSession(accessToken: 'access-other-user', refreshToken: 'refresh-other-user');
      gate.complete();
      await pending;
      expect(service.authToken, 'access-other-user');
    });

    test('hata (5xx): fırlatılır ve yerel oturum KORUNUR', () async {
      signedIn();
      api.on('POST', '/api/v1/auth/logout-all', (r) => errorResponse(500, 'iç hata', code: 'INTERNAL'));
      await expectLater(service.logoutAll(), throwsA(isA<ApiException>().having((e) => e.isServerError, 'server', isTrue)));
      expect(service.authToken, 'access-old');
      expect(service.currentRefreshToken, 'refresh-old');
    });

    test('servis oturumunda yasak (ağa gitmez)', () async {
      service.restoreServiceSession(
        accessToken: 'service-access',
        info: ServiceSessionInfo(homeId: kHome, homeName: 'Ev', expiresAt: clock.now().add(const Duration(hours: 1))),
      );
      await expectLater(service.logoutAll(), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      expect(api.requests, isEmpty);
      expect(service.hasSession, isTrue);
    });
  });

  group('ev sahibi: servis erişimi yönetimi', () {
    test('PIN geçmişi: PIN değeri YOK, durumlar çözülür; bozuk kayıt listeyi düşürmez', () async {
      api.on(
        'GET',
        '/api/v1/homes/$kHome/service-tokens',
        (r) => okResponse(<dynamic>[
          <String, dynamic>{'id': 't1', 'status': 'active', 'is_used': false, 'expires_at': '2026-10-01T14:00:00.000Z', 'created_by_name': 'Ev Sahibi'},
          <String, dynamic>{'id': 't2', 'status': 'used', 'is_used': true, 'used_at': '2026-10-01T10:00:00.000Z', 'expires_at': '2026-10-01T12:00:00.000Z'},
          <String, dynamic>{'id': 't3', 'is_used': false, 'revoked_at': '2026-10-01T09:00:00.000Z'},
          <String, dynamic>{'status': 'active'}, // kimliksiz: atlanır
          'bozuk',
        ]),
      );
      final tokens = await service.listServiceTokens(kHome);
      expect(tokens.map((t) => t.id), <String>['t1', 't2', 't3']);
      expect(tokens.map((t) => t.status), <String>['active', 'used', 'revoked'], reason: 'durum yoksa alanlardan türetilir');
      expect(tokens.first.isActive, isTrue);
      expect(tokens.first.createdByName, 'Ev Sahibi');
      expect(tokens[1].usedAt, isNotNull);
    });

    test('açık servis oturumları ve erişimi kapatma', () async {
      api.on(
        'GET',
        '/api/v1/homes/$kHome/service-sessions',
        (r) => okResponse(<dynamic>[
          <String, dynamic>{'id': 's1', 'technician_name': 'Usta', 'created_at': '2026-10-01T10:00:00.000Z', 'expires_at': '2026-10-01T12:00:00.000Z'},
        ]),
      );
      api.on('POST', '/api/v1/homes/$kHome/service-access/revoke',
          (r) => okResponse(<String, dynamic>{'revoked_pins': 1, 'revoked_sessions': 2}));
      final sessions = await service.listServiceSessions(kHome);
      expect(sessions.single.technicianName, 'Usta');
      expect(sessions.single.expiresAt, DateTime.utc(2026, 10, 1, 12));
      final revoked = await service.revokeServiceAccess(kHome);
      expect(revoked.revokedPins, 1);
      expect(revoked.revokedSessions, 2);
    });

    test('PIN üretimi: PIN yalnızca bu yanıtta; süre sunucudan', () async {
      api.on(
        'POST',
        '/api/v1/homes/$kHome/service-token',
        (r) => okResponse(<String, dynamic>{'id': 't9', 'service_pin': '987654', 'expires_at': '2026-10-01T14:00:00.000Z', 'expires_in': 7200}, status: 201),
      );
      final token = await service.createServiceToken(kHome);
      expect(token.pin, '987654');
      expect(token.expiresAt, DateTime.utc(2026, 10, 1, 14));
    });

    test('servis girişi: 2 saat süre izlenir; token yalnızca kendi evi için (refresh yok)', () async {
      api.on(
        'POST',
        '/api/v1/auth/service-login',
        (r) => okResponse(<String, dynamic>{
          'access_token': 'service-access',
          'expires_in': 7200,
          'scope': 'home_service',
          'role': 'service_session',
          'home': <String, dynamic>{'id': kHome, 'name': 'Servis Evi'},
        }),
      );
      final info = await service.serviceLogin(' 123456 ', technicianName: ' Usta ');
      expect(api.requests.single.json, <String, dynamic>{'service_pin': '123456', 'technician_name': 'Usta'});
      expect(info.homeId, kHome);
      expect(info.remaining(clock.now()), const Duration(hours: 2));
      expect(service.isServiceSession, isTrue);
      expect(service.currentRefreshToken, isNull);
    });
  });

  group('cihaz bulut kimliği (tek seferlik)', () {
    final credentialJson = <String, dynamic>{
      'host': 'broker.example.test',
      'port': 8884,
      'username': 'd_h_abc123',
      'password': 'sifre-yer-tutucu-xyz',
      'client_id': 'ESP32S3_AABBCCDDEEFF',
      'topic_id': 'h_abc123',
    };

    test('reissueDeviceMqttCredential: yol UUID büyük harfle; yanıt çözülür; toString parolayı gizler', () async {
      api.on('POST', '/api/v1/homes/$kHome/devices/AHBU-S3-ABC123/mqtt-credential', (r) => okResponse(credentialJson));
      final credential = await service.reissueDeviceMqttCredential(kHome, 'ahbu-s3-abc123');
      expect(credential.host, 'broker.example.test');
      expect(credential.port, 8884);
      expect(credential.username, 'd_h_abc123');
      expect(credential.topicId, 'h_abc123');
      expect(credential.clientId, 'ESP32S3_AABBCCDDEEFF');
      expect(credential.toString(), isNot(contains('sifre-yer-tutucu-xyz')));
      expect(credential.toLanConfigBody(), <String, dynamic>{
        'server': 'broker.example.test',
        'port': 8884,
        'user': 'd_h_abc123',
        'pass': 'sifre-yer-tutucu-xyz',
      });
    });

    test('eksik / bozuk kimlik: BAD_RESPONSE ApiException (parola eksikse sessizce geçilmez)', () async {
      for (final broken in <Map<String, dynamic>>[
        <String, dynamic>{...credentialJson}..remove('password'),
        <String, dynamic>{...credentialJson, 'password': ''},
        <String, dynamic>{...credentialJson, 'port': 0},
        <String, dynamic>{...credentialJson}..remove('topic_id'),
      ]) {
        api.on('POST', RegExp(r'/api/v1/homes/.+/devices/.+/mqtt-credential'), (r) => okResponse(broken));
        await expectLater(
          service.reissueDeviceMqttCredential(kHome, 'AHBU-S3-ABC123'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')),
        );
      }
    });

    test('claim yanıtı: device_credential, customer_account, teknisyen süresi, uyarılar; ham haritada PAROLA YOK', () async {
      api.on(
        'POST',
        '/api/v1/devices/claim',
        (r) => okResponse(<String, dynamic>{
          'home_id': kHome,
          'home_name': 'Yeni Ev',
          'device_uuid': 'AHBU-S3-ABC123',
          'device_credential': credentialJson,
          'customer_account': <String, dynamic>{'created': true, 'status': 'pending_invite', 'invite_sent': false},
          'technician_access_expires_at': '2026-10-01T20:00:00.000Z',
          'warnings': <dynamic>['Davet gönderilemedi.', '', 5],
        }),
      );
      final claim = await service.claimDevice(deviceUuid: 'ahbu-s3-abc123', setupPin: '123456');
      expect(claim.homeId, kHome);
      expect(claim.deviceCredential?.username, 'd_h_abc123');
      expect(claim.customerAccount?.created, isTrue);
      expect(claim.customerAccount?.status, 'pending_invite');
      expect(claim.customerAccount?.inviteSent, isFalse);
      expect(claim.technicianAccessExpiresAt, DateTime.utc(2026, 10, 1, 20));
      expect(claim.warnings, <String>['Davet gönderilemedi.', '5']);
      expect(claim.raw.containsKey('device_credential'), isFalse);
      expect(claim.raw.toString(), isNot(contains('sifre-yer-tutucu-xyz')));
    });

    test('claim yanıtı kimlik taşımıyorsa deviceCredential null (eski sunucu uyumu)', () async {
      api.on('POST', '/api/v1/devices/claim',
          (r) => okResponse(<String, dynamic>{'home_id': kHome, 'home_name': 'Ev', 'device_uuid': 'AHBU-S3-ABC123'}));
      final claim = await service.claimDevice(deviceUuid: 'AHBU-S3-ABC123', setupPin: '123456');
      expect(claim.deviceCredential, isNull);
      expect(claim.customerAccount, isNull);
      expect(claim.warnings, isEmpty);
    });
  });

  group('bildirim (push) jetonu', () {
    final token = 'fcm-token-${'x' * 40}';

    test('register: PUT /me/push-tokens; platform küçük harf; app_version isteğe bağlı', () async {
      signedIn();
      api.on('PUT', '/api/v1/me/push-tokens', (r) => okResponse(<String, dynamic>{'registered': true}));
      await service.registerPushToken(token: ' $token ', platform: 'ANDROID', appVersion: ' 1.2.3 ');
      expect(api.requests.single.json, <String, dynamic>{'token': token, 'platform': 'android', 'app_version': '1.2.3'});
      expect(api.requests.single.headers['Authorization'], 'Bearer access-old');

      await service.registerPushToken(token: token, platform: 'ios');
      expect(api.requests.last.json, <String, dynamic>{'token': token, 'platform': 'ios'});
    });

    test('doğrulama ağa gitmeden: kısa/boşluklu/uzun jeton, geçersiz platform, uzun sürüm', () async {
      signedIn();
      for (final bad in <String>['kisa', 'x' * 19, 'x' * 513, 'bosluk iceren ${'y' * 30}', 'türkçe-${'z' * 30}']) {
        await expectLater(service.registerPushToken(token: bad, platform: 'android'), throwsA(isA<ApiException>().having((e) => e.isValidation, 'v', isTrue)), reason: bad);
      }
      await expectLater(service.registerPushToken(token: token, platform: 'web'), throwsA(isA<ApiException>()));
      await expectLater(service.registerPushToken(token: token, platform: 'android', appVersion: 'v' * 33), throwsA(isA<ApiException>()));
      expect(api.requests, isEmpty);
    });

    test('unregister: DELETE govdeli (jeton gövdede); idempotent çağrı', () async {
      signedIn();
      api.on('DELETE', '/api/v1/me/push-tokens', (r) => okResponse(<String, dynamic>{'registered': false}));
      await service.unregisterPushToken(token);
      expect(api.requests.single.method, 'DELETE');
      expect(api.requests.single.json, <String, dynamic>{'token': token});
      await expectLater(service.unregisterPushToken('kisa'), throwsA(isA<ApiException>()));
    });

    test('servis oturumu (kullanıcı satırı yok): ağa gitmeden yasak; sunucu 403 verse de aynı sonuç', () async {
      service.restoreServiceSession(
        accessToken: 'service-access',
        info: ServiceSessionInfo(homeId: kHome, homeName: 'Ev', expiresAt: clock.now().add(const Duration(hours: 1))),
      );
      api.on('PUT', '/api/v1/me/push-tokens', (r) => errorResponse(403, 'Yetkiniz yok', code: 'FORBIDDEN'));
      await expectLater(service.registerPushToken(token: token, platform: 'android'), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      await expectLater(service.unregisterPushToken(token), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      expect(api.requests, isEmpty);
    });
  });

  group('yönetici kullanıcı uçları', () {
    test('createAdminUser: parola verilmezse gövdede YOK; boş telefon/not gönderilmez', () async {
      signedIn();
      api.on('POST', '/api/v1/admin/users', (r) => okResponse(<String, dynamic>{'id': 'u2', 'invite_sent': true}, status: 201));
      final result = await service.createAdminUser(
        fullName: ' Ayşe Y ',
        email: ' a@b.c ',
        role: 'user',
        phone: '  ',
        adminNotes: '',
      );
      expect(api.requests.single.json, <String, dynamic>{'full_name': 'Ayşe Y', 'email': 'a@b.c', 'role': 'user'});
      expect(result['invite_sent'], isTrue);
    });

    test('createAdminUser: süper kullanıcı parola verebilir (kırpılmadan)', () async {
      signedIn();
      api.on('POST', '/api/v1/admin/users', (r) => okResponse(<String, dynamic>{'id': 'u3'}, status: 201));
      await service.createAdminUser(fullName: 'Ali', email: 'ali@b.c', password: ' gecici parola 12 ', role: 'service_user', phone: '+905551112233', adminNotes: 'not');
      expect(api.requests.single.json!['password'], ' gecici parola 12 ');
      expect(api.requests.single.json!['phone'], '+905551112233');
      expect(api.requests.single.json!['admin_notes'], 'not');
    });

    test('servis personeli parola veremez: sunucu 403 FORBIDDEN döner ve oturum düşmez', () async {
      signedIn();
      api.on('POST', '/api/v1/admin/users', (r) => errorResponse(403, 'Servis sorumluları kullanıcı parolası belirleyemez.', code: 'FORBIDDEN'));
      await expectLater(
        service.createAdminUser(fullName: 'Ali', email: 'ali@b.c', password: 'x' * 12, role: 'user'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
      expect(service.authToken, 'access-old');
      expect(api.count('POST', '/api/v1/auth/refresh'), 0, reason: '403 hiçbir zaman refresh tetiklemez');
    });

    test('updateAdminUser: başka süper kullanıcı parolası için current_password; REAUTH_REQUIRED eşlenir', () async {
      signedIn();
      api.on('PATCH', '/api/v1/admin/users/u9', (r) => okResponse(<String, dynamic>{'id': 'u9'}));
      await service.updateAdminUser('u9', password: 'yeni-parola-12', currentPassword: 'kendi-parolam-1');
      expect(api.requests.single.json, <String, dynamic>{'password': 'yeni-parola-12', 'current_password': 'kendi-parolam-1'});

      api.on('PATCH', '/api/v1/admin/users/u9', (r) => errorResponse(403, 'Mevcut parolanızı girin.', code: 'REAUTH_REQUIRED'));
      await expectLater(
        service.updateAdminUser('u9', password: 'yeni-parola-12'),
        throwsA(isA<ApiException>().having((e) => e.isReauthRequired, 'reauth', isTrue)),
      );
    });

    test('sendAdminUserReset: POST /admin/users/:id/send-reset; sonuç alanları', () async {
      signedIn();
      api.on('POST', '/api/v1/admin/users/u9/send-reset',
          (r) => okResponse(<String, dynamic>{'sent': true, 'purpose': 'account_setup', 'expires_at': '2026-10-02T12:00:00.000Z'}));
      final result = await service.sendAdminUserReset('u9');
      expect(result['sent'], isTrue);
      expect(result['purpose'], 'account_setup');

      api.on('POST', '/api/v1/admin/users/u9/send-reset', (r) => errorResponse(503, 'E-posta gönderilemedi.', code: 'DELIVERY_FAILED'));
      await expectLater(service.sendAdminUserReset('u9'), throwsA(isA<ApiException>().having((e) => e.isDeliveryFailed, 'delivery', isTrue)));
    });
  });
}
