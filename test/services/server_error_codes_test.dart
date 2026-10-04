import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/utils/friendly_error.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

const String kHome = '11111111-1111-4111-8111-111111111111';

/// Sunucu inceleme düzeltmelerinin (WP-L, CONTRACTS §2.4b) iki yeni yanıtının **istemcide nasıl çözümlendiği**:
///
/// 1. `PUT /homes/:id/scheduled-rules/:ruleId {enabled:true}` → kanal tipi uyumsuzsa `400 VALIDATION` +
///    Türkçe mesaj (ör. "Kanal 5 bir panjura ayrılmış; …").
/// 2. `PUT /homes/:id/endpoints/:id` → eşitleme satırı değiştirmişse `409 CONFLICT` "Kanal tipi değişti; listeyi
///    yenileyin.".
///
/// Gövdeler sunucunun gerçek biçimindedir (`{ success:false, message, code }`, CONTRACTS §1.1); istemci yığını
/// (`EvCloudApiService` + `ApiException`) gerçektir, yalnızca HTTP katmanı sahtedir.
void main() {
  const shutterChannelMessage = 'Kanal 5 bir panjura ayrılmış; röle kuralı yerine panjur kuralı oluşturun';
  const typeChangedMessage = 'Kanal tipi değişti; listeyi yenileyin.';

  late MockApi api;
  late EvCloudApiService service;

  setUp(() {
    api = MockApi();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
  });

  tearDown(() => service.dispose());

  group('ApiException.isConflict', () {
    test('yalnızca code == CONFLICT çakışmadır; öteki 409 kodları, kodsuz 409 ve 400 değildir', () {
      expect(const ApiException(statusCode: 409, code: 'CONFLICT', message: 'x').isConflict, isTrue);
      expect(const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'x').isConflict, isFalse,
          reason: 'cihaz çevrimdışı çakışma değil, ayrı bir durumdur (yenileyip yeniden denemek işe yaramaz)');
      expect(const ApiException(statusCode: 409, code: 'SOLE_OWNER', message: 'x').isConflict, isFalse);
      expect(const ApiException(statusCode: 409, message: 'x').isConflict, isFalse, reason: 'kod yoksa varsayılma yok');
      expect(const ApiException(statusCode: 400, code: 'VALIDATION', message: 'x').isConflict, isFalse);
    });
  });

  group('PUT scheduled-rules {enabled:true} → 400 VALIDATION', () {
    test('sunucunun mesajı ApiException.message olarak AYNEN gelir; friendlyError genel metne çevirmez', () async {
      api.on(
        'PUT',
        RegExp(r'/api/v1/homes/.+/scheduled-rules/.+'),
        (r) => errorResponse(400, shutterChannelMessage, code: 'VALIDATION'),
      );

      Object? caught;
      try {
        await service.updateScheduledRule(kHome, 'rule-1', <String, dynamic>{'enabled': true});
      } catch (e) {
        caught = e;
      }

      expect(api.requests.single.json, <String, dynamic>{'enabled': true}, reason: 'yalnızca anahtar gönderilir');
      expect(caught, isA<ApiException>());
      final error = caught! as ApiException;
      expect(error.statusCode, 400);
      expect(error.code, 'VALIDATION');
      expect(error.isValidation, isTrue);
      expect(error.message, shutterChannelMessage);
      expect(
        friendlyError(error, fallback: 'Kural güncellenemedi. Lütfen tekrar deneyin.'),
        shutterChannelMessage,
        reason: 'kullanıcıya sunucunun açıklayıcı mesajı gösterilir',
      );
    });

    test('genel metin yalnızca ApiException OLMAYAN bilinmeyen hatalarda kullanılır; ham istisna metni sızmaz', () {
      expect(friendlyError(StateError('iç ayrıntı'), fallback: 'Kural güncellenemedi. Lütfen tekrar deneyin.'),
          'Kural güncellenemedi. Lütfen tekrar deneyin.');
    });
  });

  group('PUT endpoints/:id → 409 CONFLICT', () {
    test('code CONFLICT çözülür, isConflict doğrudur, mesaj aynen gelir; istek yeniden denenmez', () async {
      api.on(
        'PUT',
        RegExp(r'/api/v1/homes/.+/endpoints/.+'),
        (r) => errorResponse(409, typeChangedMessage, code: 'CONFLICT'),
      );

      Object? caught;
      try {
        await service.updateEndpoint(homeId: kHome, endpointId: 'e5', shutterDurationSec: 24);
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<ApiException>());
      final error = caught! as ApiException;
      expect(error.statusCode, 409);
      expect(error.code, 'CONFLICT');
      expect(error.isConflict, isTrue);
      expect(error.isDeviceOffline, isFalse);
      expect(error.message, typeChangedMessage);
      expect(api.count('PUT', RegExp(r'/endpoints/')), 1, reason: 'servis katmanı kendiliğinden yeniden denemez');
    });

    test('light↔plug tip değişimi 409 CONFLICT de aynı çözümlemeyi kullanır', () async {
      api.on(
        'PUT',
        RegExp(r'/api/v1/homes/.+/endpoints/.+'),
        (r) => errorResponse(409, typeChangedMessage, code: 'CONFLICT'),
      );
      await expectLater(
        service.updateEndpoint(homeId: kHome, endpointId: 'e6', type: 'light'),
        throwsA(isA<ApiException>().having((e) => e.isConflict, 'isConflict', true)),
      );
      expect(api.requests.single.json, <String, dynamic>{'type': 'light'});
    });

    test('409 DEVICE_OFFLINE çakışma SAYILMAZ (panjur süresi çevrimdışı panoya iletilemedi)', () async {
      api.on(
        'PUT',
        RegExp(r'/api/v1/homes/.+/endpoints/.+'),
        (r) => errorResponse(409, 'Cihaz çevrimdışı; panjur süresi cihaza iletilemedi.', code: 'DEVICE_OFFLINE'),
      );
      await expectLater(
        service.updateEndpoint(homeId: kHome, endpointId: 'e3', shutterDurationSec: 24),
        throwsA(isA<ApiException>()
            .having((e) => e.isConflict, 'isConflict', false)
            .having((e) => e.isDeviceOffline, 'isDeviceOffline', true)),
      );
    });
  });
}
