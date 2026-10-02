import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

const String _home = '11111111-1111-4111-8111-111111111111';

/// Gece hatırlatması sunucu v2 sözleşmesi (WP-H): `close-all` isteği/yanıtı ve ayar yanıtının
/// (`last_notice`, `stale`, `devices_*`) tipli görünümü. v1 sunucu yanıtıyla da çalışmalıdır.
void main() {
  group('CloseAllResult v2', () {
    test('v1 yanıtı: yeni alanlar varsayılan (geriye uyum)', () {
      final result = CloseAllResult.fromJson(<String, dynamic>{
        'closed_count': 3,
        'delivered': true,
        'device_online': true,
        'command_id': 'c-1',
        'message': 'Tamam',
      });
      expect(result.closedCount, 3);
      expect(result.closedShutters, isNull);
      expect(result.skippedCount, 0);
      expect(result.nothingToDo, isFalse);
      expect(result.resolved, isFalse);
      expect(result.noticeId, isNull);
    });

    test('v2 yanıtı: tüm alanlar okunur', () {
      final result = CloseAllResult.fromJson(<String, dynamic>{
        'closed_lights': 2,
        'closed_shutters': 1,
        'closed_count': 2,
        'skipped_count': 1,
        'nothing_to_do': false,
        'delivered': true,
        'device_online': true,
        'command_ids': <String>['a', 'b'],
        'command_id': 'a',
        'notice_id': 41,
        'resolved': true,
        'message': 'Bir öğe elle kontrol edilmeli.',
      });
      expect(result.closedCount, 2);
      expect(result.closedShutters, 1);
      expect(result.skippedCount, 1);
      expect(result.nothingToDo, isFalse);
      expect(result.resolved, isTrue);
      expect(result.noticeId, 41);
      expect(result.commandId, 'a');
    });

    test('nothing_to_do ve rakam metni notice_id', () {
      final result = CloseAllResult.fromJson(<String, dynamic>{
        'nothing_to_do': true,
        'notice_id': '7',
        'resolved': 'true',
        'skipped_count': null,
        'message': 'Cihaza komut gönderilmedi.',
      });
      expect(result.nothingToDo, isTrue);
      expect(result.noticeId, 7);
      expect(result.resolved, isTrue);
      expect(result.skippedCount, 0);
    });

    test('notice_id null: bilinmiyor', () {
      expect(CloseAllResult.fromJson(<String, dynamic>{'notice_id': null}).noticeId, isNull);
    });
  });

  group('PeaceNotificationSettings v2', () {
    Map<String, dynamic> v2() => <String, dynamic>{
      'home_id': _home,
      'enabled': true,
      'time': '23:30',
      'timezone': 'Europe/Istanbul',
      'devices_total': 2,
      'devices_online': 1,
      'stale': false,
      'open_lights_count': 2,
      'open_shutters_count': 1,
      'open_lights': <dynamic>[
        <String, dynamic>{'id': 'a', 'channel_index': 1, 'name': 'Avize', 'room': 'Salon'},
      ],
      'open_shutters': <dynamic>[
        <String, dynamic>{'pair': 1, 'room': 'Salon', 'position': 40},
      ],
      'summary_text': 'Salonda 2 lamba, 1 panjur açık.',
      'last_notice': <String, dynamic>{
        'id': 41,
        'local_date': '2026-10-01',
        'status': 'sent',
        'summary_text': 'Salonda 2 lamba, 1 panjur açık.',
        'open_lights_count': 2,
        'open_shutters_count': 1,
        'created_at': '2026-10-01T20:30:00.000Z',
        'resolved_at': null,
      },
    };

    test('v2 alanları tipli okunur', () {
      final s = PeaceNotificationSettings.fromJson(v2());
      expect(s.stale, isFalse);
      expect(s.devicesTotal, 2);
      expect(s.devicesOnline, 1);
      expect(s.openLightsCount, 2);
      expect(s.openShutters, 1, reason: 'open_shutters listesi -> eleman sayısı');
      final last = s.lastNotice!;
      expect(last.id, 41);
      expect(last.localDate, '2026-10-01');
      expect(last.status, 'sent');
      expect(last.summaryText, 'Salonda 2 lamba, 1 panjur açık.');
      expect(last.openLightsCount, 2);
      expect(last.openShuttersCount, 1);
      expect(last.createdAt, DateTime.utc(2026, 10, 1, 20, 30));
      expect(last.resolvedAt, isNull);
      expect(last.isResolved, isFalse);
    });

    test('open_shutters sayı olarak da gelebilir; yoksa open_shutters_count', () {
      expect(PeaceNotificationSettings.fromJson(<String, dynamic>{'open_shutters': 3}).openShutters, 3);
      expect(PeaceNotificationSettings.fromJson(<String, dynamic>{'open_shutters_count': 2}).openShutters, 2);
      expect(PeaceNotificationSettings.fromJson(<String, dynamic>{}).openShutters, isNull);
    });

    test('çözülmüş last_notice', () {
      final json = v2();
      (json['last_notice'] as Map<String, dynamic>)
        ..['status'] = 'resolved'
        ..['resolved_at'] = '2026-10-01T20:45:00Z';
      final last = PeaceNotificationSettings.fromJson(json).lastNotice!;
      expect(last.isResolved, isTrue);
      expect(last.resolvedAt, DateTime.utc(2026, 10, 1, 20, 45));
    });

    test('stale: true ve last_notice null', () {
      final s = PeaceNotificationSettings.fromJson(<String, dynamic>{'stale': true, 'last_notice': null});
      expect(s.stale, isTrue);
      expect(s.lastNotice, isNull);
    });

    test('v1 yanıtı: v2 alanları boş, mevcut alanlar değişmez', () {
      final s = PeaceNotificationSettings.fromJson(<String, dynamic>{
        'peace_notification_enabled': true,
        'peace_notification_time': '23:30:00',
        'open_lights_count': 1,
        'summary_text': 'Bir lamba açık.',
      });
      expect(s.enabled, isTrue);
      expect(s.time, '23:30');
      expect(s.openLightsCount, 1);
      expect(s.stale, isNull);
      expect(s.devicesTotal, isNull);
      expect(s.devicesOnline, isNull);
      expect(s.lastNotice, isNull);
    });

    test('bozuk last_notice (kimlik yok / yanlış tür) ayarı düşürmez', () {
      for (final bad in <Object?>[
        <String, dynamic>{'status': 'sent'},
        'metin',
        42,
        <dynamic>[],
      ]) {
        final s = PeaceNotificationSettings.fromJson(<String, dynamic>{'enabled': true, 'last_notice': bad});
        expect(s.enabled, isTrue, reason: '$bad');
        expect(s.lastNotice, isNull, reason: '$bad');
      }
    });
  });

  group('EvCloudApiService.closeAllOpenLights gövdesi', () {
    late MockApi api;
    late EvCloudApiService service;

    setUp(() {
      api = MockApi()
        ..on(
          'POST',
          '/api/v1/devices/peace-notification/close-all',
          (r) => okResponse(<String, dynamic>{'closed_count': 0}),
        );
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
      service.setAuthToken('access-1');
    });

    tearDown(() => service.dispose());

    test(
      'eski pano düğmesi yöntemi: include_shutters:false AÇIKÇA gider (v2 sunucu varsayılanı true: panjur inerdi)',
      () async {
        await service.closeAllOpenLights(_home);
        expect(api.requests.single.json, <String, dynamic>{'home_id': _home, 'include_shutters': false});
        expect(api.requests.single.headers['Authorization'], 'Bearer access-1');
      },
    );

    test('yanıt veri haritası olduğu gibi döner (CloseAllResult çözer)', () async {
      api.on(
        'POST',
        '/api/v1/devices/peace-notification/close-all',
        (r) =>
            okResponse(<String, dynamic>{'closed_count': 2, 'closed_shutters': 1, 'resolved': true, 'notice_id': 41}),
      );
      final result = CloseAllResult.fromJson(await service.closeAllOpenLights(_home));
      expect(result.closedCount, 2);
      expect(result.closedShutters, 1);
      expect(result.resolved, isTrue);
      expect(result.noticeId, 41);
    });
  });

  group('EvCloudApiService.closeAllForNotice gövdesi', () {
    late MockApi api;
    late EvCloudApiService service;

    setUp(() {
      api = MockApi()
        ..on(
          'POST',
          '/api/v1/devices/peace-notification/close-all',
          (r) => okResponse(<String, dynamic>{'closed_count': 0}),
        );
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
      service.setAuthToken('access-1');
    });

    tearDown(() => service.dispose());

    test('varsayılan: include_shutters:true AÇIKÇA gider; notice_id yalnızca verilince', () async {
      await service.closeAllForNotice(_home);
      expect(api.requests.last.json, <String, dynamic>{'home_id': _home, 'include_shutters': true});
      expect(api.requests.last.headers['Authorization'], 'Bearer access-1');

      await service.closeAllForNotice(_home, noticeId: 41);
      expect(api.requests.last.json, <String, dynamic>{'home_id': _home, 'notice_id': 41, 'include_shutters': true});
    });

    test('include_shutters HER ZAMAN gider (false dahil)', () async {
      await service.closeAllForNotice(_home, includeShutters: false);
      expect(api.requests.last.json, <String, dynamic>{'home_id': _home, 'include_shutters': false});

      await service.closeAllForNotice(_home, noticeId: 7, includeShutters: false);
      expect(api.requests.last.json, <String, dynamic>{'home_id': _home, 'notice_id': 7, 'include_shutters': false});

      await service.closeAllForNotice(_home, noticeId: 7, includeShutters: true);
      expect(api.requests.last.json, <String, dynamic>{'home_id': _home, 'notice_id': 7, 'include_shutters': true});
    });

    test('yanıt veri haritası olduğu gibi döner (CloseAllResult çözer)', () async {
      api.on(
        'POST',
        '/api/v1/devices/peace-notification/close-all',
        (r) =>
            okResponse(<String, dynamic>{'closed_count': 2, 'closed_shutters': 1, 'resolved': true, 'notice_id': 41}),
      );
      final result = CloseAllResult.fromJson(await service.closeAllForNotice(_home, noticeId: 41));
      expect(result.closedCount, 2);
      expect(result.closedShutters, 1);
      expect(result.resolved, isTrue);
      expect(result.noticeId, 41);
    });
  });

  group('closeAllOpenLights imza uyumluluğu (RR1-02)', () {
    // Canlı ağacın E1 test yardımcısı (test/ui/e1_helpers.dart: E1Cloud) bu imzayla geçersiz kılar. İmza
    // genişlerse (adlandırılmış parametre eklenirse) bu sınıf DERLENMEZ ve dosyadaki tüm testler yüklenemez.
    test('eski tek konumsal parametreli geçersiz kılma geçerli kalır', () async {
      final fake = _LegacySignatureCloud();
      expect(await fake.closeAllOpenLights(_home), <String, dynamic>{'legacy': _home});
      final EvCloudApiService asBase = fake;
      expect(await asBase.closeAllOpenLights(_home), <String, dynamic>{'legacy': _home});
      fake.dispose();
    });
  });
}

/// E1Cloud'un geçersiz kılma biçimi: `closeAllOpenLights(String homeId)` (başka parametre yok).
class _LegacySignatureCloud extends FakeCloudApi {
  @override
  Future<Map<String, dynamic>> closeAllOpenLights(String homeId) async => <String, dynamic>{'legacy': homeId};
}
