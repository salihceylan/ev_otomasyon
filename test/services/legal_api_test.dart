import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';

/// Yasal metin uçlarının istemcisi (CONTRACTS: `GET /api/v1/legal`, `GET /api/v1/legal/:id`, `POST /api/v1/legal/accept`,
/// `POST /auth/register` + `accept_terms_version`, `GET /auth/me`): yol, kimlik başlığı, zarf çözümü ve hata eşlemesi
/// (`409 LEGAL_VERSION_MISMATCH` + `data.current_version`).
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

  Map<String, dynamic> info(String id, String slug, String title, {int version = 1, String status = 'draft', bool requires = false}) =>
      <String, dynamic>{
        'id': id,
        'slug': slug,
        'title': title,
        'version': version,
        'effective_date': '2026-10-08',
        'status': status,
        'requires_acceptance': requires,
        'url': '/yasal/$slug',
      };

  Map<String, dynamic> termsInfo({int version = 1, String status = 'draft'}) => info(
        'terms',
        'kullanici-sozlesmesi',
        'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları',
        version: version,
        status: status,
        requires: true,
      );

  Map<String, dynamic> privacyInfo() =>
      info('privacy', 'gizlilik-politikasi', 'Gizlilik Politikası ve KVKK Aydınlatma Metni');

  http.Response http409({int current = 2}) => errorResponse(
        409,
        'Kullanıcı Sözleşmesi güncellendi.',
        code: 'LEGAL_VERSION_MISMATCH',
        extra: <String, dynamic>{
          'data': <String, dynamic>{'current_version': current},
        },
      );

  bool hasAuthHeader(RecordedRequest r) => r.headers.keys.any((k) => k.toLowerCase() == 'authorization');

  group('GET /legal (liste)', () {
    test('kimliksiz GET; data.documents sırası korunur ve çözülür', () async {
      service.setAuthToken('access-1');
      api.on('GET', '/api/v1/legal', (r) => okResponse(<String, dynamic>{
            'documents': <dynamic>[termsInfo(), privacyInfo()],
          }));

      final docs = await service.fetchLegalDocuments();

      expect(docs.map((d) => d.id), <String>['terms', 'privacy']);
      expect(docs.first.version, 1);
      expect(docs.first.requiresAcceptance, isTrue);
      expect(docs.last.requiresAcceptance, isFalse);
      expect(docs.first.isDraft, isTrue);
      expect(hasAuthHeader(api.where('GET', '/api/v1/legal').single), isFalse, reason: 'herkese açık uç');
    });

    test('boş liste (yasal dizin yok) boş döner; bozuk kayıt listeyi düşürmez', () async {
      api.on('GET', '/api/v1/legal', (r) => okResponse(<String, dynamic>{'documents': <dynamic>[]}));
      expect(await service.fetchLegalDocuments(), isEmpty);

      api.on('GET', '/api/v1/legal', (r) => okResponse(<String, dynamic>{
            'documents': <dynamic>[
              <String, dynamic>{'id': 'terms'},
              privacyInfo(),
            ],
          }));
      expect((await service.fetchLegalDocuments()).map((d) => d.id), <String>['privacy']);
    });

    test('ağ / sunucu hatası ApiException olarak iletilir (oturum sonu tetiklemez)', () async {
      final expired = <SessionEndReason>[];
      service.onSessionExpired = expired.add;
      api.on('GET', '/api/v1/legal', (r) => errorResponse(503, 'iç ayrıntı', code: 'INTERNAL'));

      await expectLater(service.fetchLegalDocuments(), throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 503)));
      expect(expired, isEmpty);
    });
  });

  group('GET /legal/:id (tek metin)', () {
    test('kimlik yola kodlanır; bloklar çözülür', () async {
      api.on('GET', '/api/v1/legal/terms', (r) => okResponse(<String, dynamic>{
            ...termsInfo(status: 'final'),
            'blocks': <dynamic>[
              <String, dynamic>{'type': 'h2', 'text': '1. Taraflar'},
              <String, dynamic>{'type': 'p', 'text': 'Metin **kalın**.'},
              <String, dynamic>{'type': 'oli', 'text': 'Bir', 'n': 1},
            ],
          }));

      final doc = await service.fetchLegalDocument('terms');

      expect(doc.id, 'terms');
      expect(doc.isDraft, isFalse);
      expect(doc.blocks.map((b) => b.type), <LegalBlockType>[LegalBlockType.h2, LegalBlockType.p, LegalBlockType.oli]);
      expect(doc.blocks.last.n, 1);
      expect(hasAuthHeader(api.where('GET', '/api/v1/legal/terms').single), isFalse);
    });

    test('bilinmeyen metin 404 NOT_FOUND; üst bilgisi bozuk yanıt 502 BAD_RESPONSE', () async {
      await expectLater(
        service.fetchLegalDocument('yok'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404).having((e) => e.code, 'code', 'NOT_FOUND')),
      );

      api.on('GET', '/api/v1/legal/terms', (r) => okResponse(<String, dynamic>{'title': 'Başlık'}));
      await expectLater(
        service.fetchLegalDocument('terms'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')),
      );
    });
  });

  group('POST /legal/accept', () {
    test('kimlik doğrulamalı POST; gövde {document, version}; yanıt çözülür', () async {
      service
        ..setAuthToken('access-1')
        ..setRefreshToken('refresh-1');
      api.on('POST', '/api/v1/legal/accept', (r) => okResponse(<String, dynamic>{
            'document': 'terms',
            'version': 2,
            'accepted_at': '2026-10-08T09:00:00Z',
          }));

      final result = await service.acceptLegalDocument(document: 'terms', version: 2);

      expect(result.document, 'terms');
      expect(result.version, 2);
      expect(result.acceptedAt, DateTime.utc(2026, 10, 8, 9));
      final request = api.where('POST', '/api/v1/legal/accept').single;
      expect(request.json, <String, dynamic>{'document': 'terms', 'version': 2});
      expect(request.headers['Authorization'] ?? request.headers['authorization'], 'Bearer access-1');
    });

    test('409 LEGAL_VERSION_MISMATCH: kod, güncel sürüm (data.current_version) ve Türkçe uygulama metni', () async {
      service.setAuthToken('access-1');
      api.on('POST', '/api/v1/legal/accept', (r) => http409(current: 3));

      try {
        await service.acceptLegalDocument(document: 'terms', version: 2);
        fail('409 beklenirdi');
      } on ApiException catch (e) {
        expect(e.statusCode, 409);
        expect(e.isLegalVersionMismatch, isTrue);
        expect(e.isConflict, isFalse, reason: 'genel CONFLICT değil');
        expect(e.currentLegalVersion, 3);
        expect(e.message, ApiException.clientMessages['LEGAL_VERSION_MISMATCH']);
        expect(e.message, contains('Kullanıcı Sözleşmesi güncellendi'));
      }
    });

    test('servis PIN oturumunda yerel olarak reddedilir (403); ağa çıkılmaz', () async {
      service.restoreServiceSession(
        accessToken: 'service-access',
        info: ServiceSessionInfo(homeId: 'h1', homeName: 'Ev', expiresAt: clock.now().add(const Duration(hours: 2)), technicianName: ''),
      );

      await expectLater(
        service.acceptLegalDocument(document: 'terms', version: 1),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
      expect(api.count('POST', '/api/v1/legal/accept'), 0);
    });

    test('geçersiz sürüm yerel doğrulama hatasıdır', () async {
      service.setAuthToken('access-1');
      await expectLater(service.acceptLegalDocument(document: 'terms', version: 0), throwsA(isA<ApiException>()));
      expect(api.requests, isEmpty);
    });
  });

  group('POST /auth/register + accept_terms_version', () {
    Map<String, dynamic> session() => <String, dynamic>{
          'access_token': 'access-new',
          'refresh_token': 'refresh-new',
          'user': <String, dynamic>{'id': 'u-1', 'email': 'a@b.c', 'full_name': 'Ayşe', 'role': 'user'},
        };

    test('sürüm verilirse gövdede accept_terms_version gider', () async {
      api.on('POST', '/api/v1/auth/register', (r) => okResponse(session(), status: 201));

      await service.register(fullName: 'Ayşe', email: 'a@b.c', password: 'parola-123456', acceptTermsVersion: 2);

      expect(api.where('POST', '/api/v1/auth/register').single.json!['accept_terms_version'], 2);
      expect(service.authToken, 'access-new');
    });

    test('sürüm verilmezse alan HİÇ gönderilmez', () async {
      api.on('POST', '/api/v1/auth/register', (r) => okResponse(session(), status: 201));

      await service.register(fullName: 'Ayşe', email: 'a@b.c', password: 'parola-123456');

      expect(api.where('POST', '/api/v1/auth/register').single.json!.containsKey('accept_terms_version'), isFalse);
    });

    test('409 LEGAL_VERSION_MISMATCH: hata iletilir ve oturum AÇILMAZ', () async {
      api.on('POST', '/api/v1/auth/register', (r) => http409(current: 2));

      await expectLater(
        service.register(fullName: 'Ayşe', email: 'a@b.c', password: 'parola-123456', acceptTermsVersion: 1),
        throwsA(isA<ApiException>().having((e) => e.isLegalVersionMismatch, 'isLegalVersionMismatch', isTrue)),
      );
      expect(service.hasSession, isFalse);
    });
  });

  group('GET /auth/me', () {
    test('kimlik doğrulamalı GET; data (user + homes) döner', () async {
      service.setAuthToken('access-1');
      api.on('GET', '/api/v1/auth/me', (r) => okResponse(<String, dynamic>{
            'user': <String, dynamic>{
              'id': 'u-1',
              'legal': <String, dynamic>{'needs_acceptance': false, 'terms_accepted_version': 2},
            },
            'homes': <dynamic>[],
          }));

      final me = await service.fetchMe();

      expect((me['user'] as Map)['id'], 'u-1');
      expect(api.where('GET', '/api/v1/auth/me').single.headers['Authorization'], 'Bearer access-1');
    });
  });

  group('ApiException.currentLegalVersion', () {
    test('data.current_version ya da üst düzey current_version okunur; yoksa null', () {
      const nested = ApiException(
        statusCode: 409,
        code: 'LEGAL_VERSION_MISMATCH',
        message: 'x',
        details: <String, dynamic>{
          'data': <String, dynamic>{'current_version': 4},
        },
      );
      const flat = ApiException(statusCode: 409, code: 'LEGAL_VERSION_MISMATCH', message: 'x', details: <String, dynamic>{'current_version': '5'});
      const none = ApiException(statusCode: 409, code: 'LEGAL_VERSION_MISMATCH', message: 'x');
      expect(nested.currentLegalVersion, 4);
      expect(flat.currentLegalVersion, 5);
      expect(none.currentLegalVersion, isNull);
    });
  });
}
