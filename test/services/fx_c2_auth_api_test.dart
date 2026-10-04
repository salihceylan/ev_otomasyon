import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/dashboard/labels.dart' show firstNameOf;
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// UYELIK-04 (D22): `GET /auth/capabilities` (kimliksiz) -> `{sms_otp, google, apple}`; eski sunucuda 404.
/// Uygulama bunu giriş ekranı açılışında BİR kez (bellekte, uygulama oturumu başına) alır; hata/404 = yetenek yok.
///
/// UYELIK-03 (D21): `DELETE /auth/account` yanıtındaki `released_homes` (üyesiz + panosuz tek sahipli daireler).
///
/// UYELIK-07 (D24): kullanıcı nesnesinde `email:null` güvenle karşılanır; eski sunucunun yer tutucu e-postaları
/// (`@ahbu.local`, `@users.noreply.invalid`, `@deleted.invalid`) istemcide de "e-posta yok" sayılır.
void main() {
  late MockApi api;
  late FakeClock clock;
  late EvCloudApiService service;

  setUp(() {
    api = MockApi();
    clock = FakeClock();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock);
  });

  tearDown(() => service.dispose());

  group('UYELIK-04 (D22): GET /auth/capabilities', () {
    test('kimliksiz GET; sms_otp / google / apple çözülür (oturum açıkken bile Authorization gönderilmez)', () async {
      service
        ..setAuthToken('access-1')
        ..setRefreshToken('refresh-1');
      api.on('GET', '/api/v1/auth/capabilities', (r) => okResponse(<String, dynamic>{'sms_otp': true, 'google': true, 'apple': false}));

      final caps = await service.fetchAuthCapabilities();

      expect(caps.smsOtp, isTrue);
      expect(caps.google, isTrue);
      expect(caps.apple, isFalse);
      final request = api.where('GET', '/api/v1/auth/capabilities').single;
      expect(request.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    });

    test('eksik / tanınmayan değerler false (fail-closed)', () async {
      api.on('GET', '/api/v1/auth/capabilities', (r) => okResponse(<String, dynamic>{'sms_otp': 'belki', 'google': null}));

      final caps = await service.fetchAuthCapabilities();

      expect(caps.smsOtp, isFalse);
      expect(caps.google, isFalse);
      expect(caps.apple, isFalse);
    });

    test('eski sunucu (uç yok): 404 ApiException; 401 oturum sonu tetiklemez', () async {
      final expired = <SessionEndReason>[];
      service
        ..onSessionExpired = expired.add
        ..setAuthToken('access-1')
        ..setRefreshToken('refresh-1');

      await expectLater(service.fetchAuthCapabilities(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)));

      api.on('GET', '/api/v1/auth/capabilities', (r) => errorResponse(401, 'Yetkisiz.', code: 'UNAUTHORIZED'));
      await expectLater(service.fetchAuthCapabilities(), throwsA(isA<ApiException>()));
      expect(expired, isEmpty, reason: 'kimliksiz uç');
      expect(api.count('POST', '/api/v1/auth/refresh'), 0);
    });
  });

  group('UYELIK-04 (D22): AutomationState.loadAuthCapabilities (bellekte, oturum başına)', () {
    test('başarılı yanıt BİR kez alınır ve bellekte tutulur', () async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud.authCapabilities = const AuthCapabilities(smsOtp: true, google: true, apple: true);
      expect(h.state.authCapabilities, isNull, reason: 'henüz alınmadı');

      final first = await h.state.loadAuthCapabilities();
      final second = await h.state.loadAuthCapabilities();

      expect(first.smsOtp, isTrue);
      expect(second.smsOtp, isTrue);
      expect(h.state.authCapabilities?.smsOtp, isTrue);
      expect(h.cloud.authCapabilitiesCalls, 1);
    });

    test('404 (eski sunucu) ve ağ hatası: SMS yok (fail-closed); önbelleğe alınmaz, sonraki açılış yeniden sorar', () async {
      final h = StateHarness();
      addTearDown(h.dispose);

      final old = await h.state.loadAuthCapabilities(); // sahte HTTP: 404
      expect(old.smsOtp, isFalse);
      expect(h.state.authCapabilities, isNull);

      h.cloud.authCapabilitiesError = ApiException.network();
      final offline = await h.state.loadAuthCapabilities();
      expect(offline.smsOtp, isFalse);
      expect(h.state.authCapabilities, isNull);

      h.cloud.authCapabilitiesError = null;
      h.cloud.authCapabilities = const AuthCapabilities(smsOtp: true);
      final fresh = await h.state.loadAuthCapabilities();
      expect(fresh.smsOtp, isTrue);
      expect(h.cloud.authCapabilitiesCalls, 3);
    });

    test('eşzamanlı çağrılar tek istekte birleşir', () async {
      final cloud = _GatedCapabilitiesCloud();
      final h = StateHarness(cloud: cloud);
      addTearDown(h.dispose);

      final a = h.state.loadAuthCapabilities();
      final b = h.state.loadAuthCapabilities();
      cloud.gate.complete();

      expect((await a).smsOtp, isTrue);
      expect((await b).smsOtp, isTrue);
      expect(cloud.authCapabilitiesCalls, 1);
    });
  });

  group('UYELIK-03 (D21): DELETE /auth/account -> released_homes', () {
    void signedIn() => service
      ..setAuthToken('access-1')
      ..setRefreshToken('refresh-1');

    test('data.released_homes okunur', () async {
      signedIn();
      api.on('DELETE', '/api/v1/auth/account', (r) => okResponse(<String, dynamic>{'released_homes': 2}, message: 'Hesap silindi.'));

      final result = await service.deleteAccount(password: 'dogru-parola-1234');

      expect(result.releasedHomes, 2);
    });

    test('üst düzeyde released_homes da okunur; alan yoksa / bozuksa (eski sunucu) 0', () async {
      signedIn();
      api.on('DELETE', '/api/v1/auth/account', (r) => jsonResponse(<String, dynamic>{'success': true, 'released_homes': 1}));
      expect((await service.deleteAccount(confirm: 'SİL')).releasedHomes, 1);

      api.on('DELETE', '/api/v1/auth/account', (r) => okResponse(null, message: 'Hesap silindi.'));
      expect((await service.deleteAccount(confirm: 'SİL')).releasedHomes, 0);

      api.on('DELETE', '/api/v1/auth/account', (r) => okResponse(<String, dynamic>{'released_homes': -3}));
      expect((await service.deleteAccount(confirm: 'SİL')).releasedHomes, 0);
    });

    test('409 SOLE_OWNER aynen fırlatılır (hiçbir şey silinmedi)', () async {
      signedIn();
      api.on(
        'DELETE',
        '/api/v1/auth/account',
        (r) => errorResponse(409, 'Tek sahibisiniz.', code: 'SOLE_OWNER', extra: <String, dynamic>{
          'homes': <Map<String, dynamic>>[
            <String, dynamic>{'id': kHomeA, 'name': 'Ev A', 'other_member_count': 1, 'device_count': 0},
          ],
        }),
      );

      await expectLater(
        service.deleteAccount(password: 'dogru-parola-1234'),
        throwsA(isA<ApiException>().having((e) => e.isSoleOwner, 'isSoleOwner', isTrue)),
      );
    });
  });

  group('UYELIK-07 (D24): e-posta null / yer tutucu', () {
    test('UserModel.fromJson: email null ya da yok -> boş metin', () {
      expect(UserModel.fromJson(const <String, dynamic>{'id': 'u1', 'email': null}).email, '');
      expect(UserModel.fromJson(const <String, dynamic>{'id': 'u1'}).email, '');
    });

    test('UserModel.fromJson: yer tutucu e-postalar "e-posta yok" sayılır (büyük/küçük harf ve boşluk duyarsız)', () {
      for (final placeholder in const <String>[
        'phone_905551234567@ahbu.local',
        'apple.0123456789abcdef01234567@users.noreply.invalid',
        'deleted+99999999-9999-4999-8999-999999999999@deleted.invalid',
        '  PHONE_905551234567@AHBU.LOCAL ',
      ]) {
        expect(UserModel.isPlaceholderEmail(placeholder), isTrue, reason: placeholder);
        expect(UserModel.fromJson(<String, dynamic>{'id': 'u1', 'email': placeholder}).email, '', reason: placeholder);
      }
    });

    test('gerçek ve benzer görünen e-postalar korunur', () {
      for (final real in const <String>['ayse@ornek.com.tr', 'destek@ahbu.com', 'x@ahbu.local.example.com', 'y@noreply.invalid.com.tr']) {
        expect(UserModel.isPlaceholderEmail(real), isFalse, reason: real);
        expect(UserModel.fromJson(<String, dynamic>{'id': 'u1', 'email': real}).email, real);
      }
    });

    test('e-postayı kullanan yerler bozulmaz: karşılama adı teknik adresten türetilmez (ad boş -> "Kullanıcı")', () {
      final user = UserModel.fromJson(const <String, dynamic>{'id': 'u1', 'email': 'phone_905551234567@ahbu.local', 'full_name': ''});
      expect(firstNameOf(user.fullName, email: user.email), 'Kullanıcı');
      final real = UserModel.fromJson(const <String, dynamic>{'id': 'u1', 'email': 'ayse@ornek.com', 'full_name': ''});
      expect(firstNameOf(real.fullName, email: real.email), 'ayse', reason: 'gerçek e-postada mevcut davranış');
    });

    test('eski sürümün sakladığı yer tutucu, geri yüklemede (toJson -> fromJson) temizlenir', () {
      const stored = UserModel(id: 'u1', email: 'phone_905551234567@ahbu.local', fullName: 'Ali', phone: '+905551234567');
      final restored = UserModel.fromJson(stored.toJson());
      expect(restored.email, '');
      expect(restored.phone, '+905551234567');
    });

    test('HomeMember.fromJson aynı kuralla: yer tutucu ya da null e-posta boş (üye listesi telefona düşer)', () {
      final member = HomeMember.fromJson(const <String, dynamic>{
        'user_id': 'u2',
        'full_name': 'Veli',
        'email': 'phone_905551112233@ahbu.local',
        'phone': '+905551112233',
        'role': 'resident',
      });
      expect(member.email, '');
      expect(member.phone, '+905551112233');
      expect(HomeMember.fromJson(const <String, dynamic>{'user_id': 'u3', 'email': null}).email, '');
      expect(HomeMember.fromJson(const <String, dynamic>{'user_id': 'u4', 'email': 'veli@ornek.com'}).email, 'veli@ornek.com');
    });
  });
}

/// Yetenek isteği bir kapı açılana kadar bekler (eşzamanlı çağrıların birleşmesini sınamak için).
class _GatedCapabilitiesCloud extends FakeCloudApi {
  final Completer<void> gate = Completer<void>();

  @override
  Future<AuthCapabilities> fetchAuthCapabilities() async {
    authCapabilitiesCalls++;
    await gate.future;
    return const AuthCapabilities(smsOtp: true);
  }
}
