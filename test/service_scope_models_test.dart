import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/admin_account.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/subscriber_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';

/// Servis sorumlusu kapsamı (migration 045, tasarım 2026-10-12): istemci model ayrıştırması (yeni alanlar isteğe bağlı;
/// eski sunucu yanıtı bozmaz), yetenek matrisi ve kök-yalnız aktarım uçları.
void main() {
  const homeId = '11111111-1111-4111-8111-111111111111';
  const serviceId = '22222222-2222-4222-8222-222222222222';
  const uid = 'AHBU-S3-A1B2C3';

  group('HomeModel.service (GET /homes -> service: {name, phone})', () {
    test('ad + telefon okunur ve toJson ile geri yazılır', () {
      final home = HomeModel.fromJson(<String, dynamic>{
        'id': homeId,
        'name': 'Daire 5',
        'role': 'owner',
        'service': <String, dynamic>{'name': 'Ahmet Servis', 'phone': '0555 111 22 33'},
      });
      expect(home.service, isNotNull);
      expect(home.service!.name, 'Ahmet Servis');
      expect(home.service!.phone, '0555 111 22 33');
      final again = HomeModel.fromJson(home.toJson());
      expect(again.service, home.service, reason: 'önbellek turu servis bilgisini korur');
      expect(home.copyWith(role: 'resident').service, home.service, reason: 'copyWith servisi düşürmez');
    });

    test('service: null (kök kapsamı), eksik alan (eski sunucu) ve bozuk değer ev listesini bozmaz', () {
      HomeModel parse(Map<String, dynamic> extra) =>
          HomeModel.fromJson(<String, dynamic>{'id': homeId, 'name': 'Daire', 'role': 'owner', ...extra});
      expect(parse(<String, dynamic>{'service': null}).service, isNull);
      expect(parse(<String, dynamic>{}).service, isNull, reason: 'eski sunucu alanı hiç vermez');
      expect(parse(<String, dynamic>{'service': 'Ahmet'}).service, isNull, reason: 'metin dışı değer yok sayılır');
      expect(parse(<String, dynamic>{'service': <String, dynamic>{'phone': '0555'}}).service, isNull, reason: 'adsız kayıt yok sayılır');
      expect(parse(<String, dynamic>{'service': <String, dynamic>{'name': 'Servis', 'phone': null}}).service!.phone, isNull);
      expect(parse(<String, dynamic>{}).toJson().containsKey('service'), isFalse, reason: 'servis yoksa önbelleğe yazılmaz');
    });
  });

  group('ClaimResult: servis süresizdir (technician_access_unlimited)', () {
    Map<String, dynamic> body(Map<String, dynamic> extra) =>
        <String, dynamic>{'home_id': homeId, 'home_name': 'Daire 5', 'device_uuid': uid, ...extra};

    test('yeni sunucu: unlimited true, süre bitişi YOK, service_owner_id okunur', () {
      final r = ClaimResult.fromJson(body(<String, dynamic>{'technician_access_unlimited': true, 'service_owner_id': serviceId}));
      expect(r.technicianAccessUnlimited, isTrue);
      expect(r.technicianAccessExpiresAt, isNull);
      expect(r.serviceOwnerId, serviceId);
    });

    test('eski sunucu: süre bitişi okunur, unlimited false', () {
      final r = ClaimResult.fromJson(body(<String, dynamic>{'technician_access_expires_at': '2026-10-01T20:00:00.000Z'}));
      expect(r.technicianAccessExpiresAt, DateTime.utc(2026, 10, 1, 20));
      expect(r.technicianAccessUnlimited, isFalse);
      expect(r.serviceOwnerId, isNull);
    });

    test('ikisi de yoksa (müşteri kendi sahiplendi) erişim bilgisi boştur', () {
      final r = ClaimResult.fromJson(body(<String, dynamic>{}));
      expect(r.technicianAccessUnlimited, isFalse);
      expect(r.technicianAccessExpiresAt, isNull);
    });
  });

  group('InventoryDeviceModel: servis sahibi alanları isteğe bağlı', () {
    Map<String, dynamic> row(Map<String, dynamic> extra) =>
        <String, dynamic>{'device_uuid': uid, 'mac_address': 'AA:BB', 'status': 'IN_STOCK', ...extra};

    test('servis stoğu: service_owner_id + e-posta', () {
      final d = InventoryDeviceModel.fromJson(
        row(<String, dynamic>{'service_owner_id': serviceId, 'service_owner_email': 'ahmet@servis.test'}),
      );
      expect(d.serviceOwnerId, serviceId);
      expect(d.serviceOwnerEmail, 'ahmet@servis.test');
      expect(d.hasServiceOwner, isTrue);
      expect(d.isRootStock, isFalse);
      expect(d.serviceOwnerReported, isTrue);
    });

    test('kök stoğu: sunucu service_owner_id: null bildirir', () {
      final d = InventoryDeviceModel.fromJson(row(<String, dynamic>{'service_owner_id': null, 'service_owner_email': null}));
      expect(d.hasServiceOwner, isFalse);
      expect(d.isRootStock, isTrue);
    });

    test('eski sunucu alanı hiç vermez: "kök stoğu" DENMEZ (yanlış bilgi yok)', () {
      final d = InventoryDeviceModel.fromJson(row(<String, dynamic>{}));
      expect(d.serviceOwnerReported, isFalse);
      expect(d.isRootStock, isFalse);
      expect(d.hasServiceOwner, isFalse);
    });

    test('copyWith servis alanlarını korur', () {
      final d = InventoryDeviceModel.fromJson(
        row(<String, dynamic>{'service_owner_id': serviceId, 'service_owner_email': 'a@b.test'}),
      );
      final next = d.copyWith(status: 'SUSPENDED');
      expect(next.serviceOwnerId, serviceId);
      expect(next.serviceOwnerEmail, 'a@b.test');
      expect(next.serviceOwnerReported, isTrue);
    });
  });

  group('Subscriber: servis alanları isteğe bağlı', () {
    test('service_owner_id + service_owner_name okunur', () {
      final s = Subscriber.tryParse(<String, dynamic>{
        'home_id': homeId,
        'home_name': 'Daire 5',
        'service_owner_id': serviceId,
        'service_owner_name': 'Ahmet Servis',
      })!;
      expect(s.serviceOwnerId, serviceId);
      expect(s.serviceOwnerName, 'Ahmet Servis');
      expect(s.isRootScope, isFalse);
    });

    test('service_owner_id: null -> kök kapsamı; alan yoksa (eski sunucu) kök sayılmaz', () {
      final root = Subscriber.tryParse(<String, dynamic>{
        'home_id': homeId,
        'home_name': 'Daire 5',
        'service_owner_id': null,
        'service_owner_name': null,
      })!;
      expect(root.isRootScope, isTrue);
      final old = Subscriber.tryParse(<String, dynamic>{'home_id': homeId, 'home_name': 'Daire 5'})!;
      expect(old.serviceOwnerReported, isFalse);
      expect(old.isRootScope, isFalse);
    });
  });

  group('AdminAccount.createdByUserId ve EmergencyResetResult.serviceOwnerId', () {
    test('created_by_user_id okunur; yoksa null', () {
      final a = AdminAccount.tryParse(<String, dynamic>{
        'id': 'u1',
        'full_name': 'Müşteri',
        'email': 'm@x.test',
        'role': 'user',
        'created_by_user_id': serviceId,
      })!;
      expect(a.createdByUserId, serviceId);
      expect(a.copyWith(isActive: false).createdByUserId, serviceId);
      final b = AdminAccount.tryParse(<String, dynamic>{'id': 'u2', 'full_name': 'M', 'email': 'm@x.test', 'role': 'user'})!;
      expect(b.createdByUserId, isNull);
    });

    test('acil sıfırlama yanıtında service_owner_id okunur', () {
      final r = EmergencyResetResult.fromJson(<String, dynamic>{
        'action': 'REASSIGNED',
        'device_uuid': uid,
        'service_owner_id': serviceId,
      });
      expect(r.serviceOwnerId, serviceId);
      expect(EmergencyResetResult.fromJson(<String, dynamic>{'action': 'UNCLAIMED'}).serviceOwnerId, isNull);
    });
  });

  group('ServiceOwnerTransferResult', () {
    test('sunucu yanıtı okunur', () {
      final r = ServiceOwnerTransferResult.fromJson(<String, dynamic>{
        'home_id': homeId,
        'service_owner_id': serviceId,
        'previous_service_owner_id': null,
        'changed': true,
        'cards_moved': 2,
        'message': 'Daire yeni servis sorumlusunun kapsamına aktarıldı.',
      });
      expect(r.serviceOwnerId, serviceId);
      expect(r.previousServiceOwnerId, isNull);
      expect(r.changed, isTrue);
      expect(r.cardsMoved, 2);
      expect(r.toRoot, isFalse);
      expect(r.message, contains('aktarıldı'));
    });

    test('hedef null = köke alındı; eksik alanlar güvenli varsayılan', () {
      final r = ServiceOwnerTransferResult.fromJson(<String, dynamic>{'service_owner_id': null, 'changed': false});
      expect(r.toRoot, isTrue);
      expect(r.changed, isFalse);
      expect(r.cardsMoved, 0);
      expect(r.message, isEmpty);
    });
  });

  group('yetenekler: servis kendi kapsamında süper, kök-yalnız öğeler servise kapalı', () {
    final now = DateTime.utc(2026, 10, 12, 12);
    Capabilities caps(String global, [String? home]) => Capabilities(globalRole: global, homeRole: home, now: now);

    test('servis sorumlusu: envanter yönetimi AÇIK; iptal, aktarım ve servis hesapları KAPALI', () {
      final c = caps('service_user', 'service_user');
      expect(c.canViewInventory, isTrue);
      expect(c.canManageInventory, isTrue, reason: 'askıya al, etiket, PIN kilidi, silme (kendi stoğu)');
      expect(c.canRevokeInventory, isFalse, reason: 'iptal (REVOKED) yalnız kök');
      expect(c.canTransferServiceScope, isFalse, reason: 'aktarım yalnız kök');
      expect(c.canManageAdminAccounts, isFalse, reason: 'servis hesabı açma / rol değiştirme / özet yalnız kök');
      expect(c.canOpenServiceManagement, isTrue, reason: 'kendi müşterileri');
      expect(c.canEmergencyReset, isTrue);
    });

    test('servis sorumlusu kendi evinde üye ve misafir yönetir; ev sahibine özel devir ve servis PIN ✖', () {
      final c = caps('service_user', 'service_user');
      expect(c.canInvite, isTrue);
      expect(c.canManageMembers, isTrue);
      expect(c.canTransferOwnership, isFalse);
      expect(c.canGenerateServicePin, isFalse);
      expect(c.canArm, isFalse, reason: 'hırsız alarmı kurma servis rollerinde yok (değişmez karar)');
    });

    test('servis ev bağlamı olmadan (üyelik yok) ev yetkisi almaz; envanter yetkisi küreseldir', () {
      final c = Capabilities(globalRole: 'service_user', hasActiveHome: true, now: now);
      expect(c.hasHomeAccess, isFalse);
      expect(c.canInvite, isFalse);
      expect(c.canManageInventory, isTrue);
    });

    test('süper yönetici: aktarım, iptal ve servis hesapları AÇIK', () {
      final c = caps('super_user');
      expect(c.canTransferServiceScope, isTrue);
      expect(c.canRevokeInventory, isTrue);
      expect(c.canManageAdminAccounts, isTrue);
      expect(c.canManageInventory, isTrue);
    });

    test('ev sahibi, sakin, servis PIN oturumu ve oturumsuz: aktarım / iptal / envanter yönetimi ✖', () {
      for (final c in <Capabilities>[
        caps('user', 'owner'),
        caps('user', 'resident'),
        caps('service_session', 'service_session'),
        const Capabilities.none(),
        const Capabilities.localKeyHolder(),
      ]) {
        expect(c.canTransferServiceScope, isFalse, reason: c.toString());
        expect(c.canRevokeInventory, isFalse, reason: c.toString());
        expect(c.canManageInventory, isFalse, reason: c.toString());
      }
    });
  });

  group('aktarım uçları (yalnız kök): PATCH /admin/homes|inventory|sites/:id/service-owner', () {
    late MockApi api;
    late FakeClock clock;
    late EvCloudApiService service;

    setUp(() {
      api = MockApi();
      clock = FakeClock();
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: clock)..setAuthToken('jwt');
    });

    tearDown(() => service.dispose());

    test('daire: gövde service_user_id (uuid) -> kapsam yeni servise; sonuç ayrıştırılır', () async {
      api.on(
        'PATCH',
        '/api/v1/admin/homes/$homeId/service-owner',
        (r) => okResponse(<String, dynamic>{
          'home_id': homeId,
          'service_owner_id': serviceId,
          'previous_service_owner_id': null,
          'changed': true,
          'cards_moved': 1,
          'message': 'Daire yeni servis sorumlusunun kapsamına aktarıldı.',
        }),
      );
      final r = await service.transferHomeServiceOwner(homeId, serviceUserId: serviceId);
      expect(api.requests.single.json, <String, dynamic>{'service_user_id': serviceId});
      expect(r.serviceOwnerId, serviceId);
      expect(r.cardsMoved, 1);
    });

    test('daire: serviceUserId null -> gövdede açıkça service_user_id: null (köke al); alan atlanmaz', () async {
      api.on(
        'PATCH',
        '/api/v1/admin/homes/$homeId/service-owner',
        (r) => okResponse(<String, dynamic>{'home_id': homeId, 'service_owner_id': null, 'changed': true}),
      );
      final r = await service.transferHomeServiceOwner(homeId);
      final body = api.requests.single.json!;
      expect(body.containsKey('service_user_id'), isTrue, reason: 'sunucu alanı ZORUNLU sayar (undefined -> 400)');
      expect(body['service_user_id'], isNull);
      expect(r.toRoot, isTrue);
    });

    test('kart: UUID büyük harfe çevrilir; kurulu kart 409 CONFLICT iletisi aynen yansır', () async {
      api.on(
        'PATCH',
        '/api/v1/admin/inventory/$uid/service-owner',
        (r) => errorResponse(409, 'Kurulu kartın sahibi evinin servisidir; kartı değil daireyi aktarın.', code: 'CONFLICT'),
      );
      await expectLater(
        service.transferInventoryServiceOwner(uid.toLowerCase(), serviceUserId: serviceId),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.message, 'message', contains('daireyi aktarın')),
        ),
      );
      expect(api.requests.single.path, '/api/v1/admin/inventory/$uid/service-owner');
    });

    test('site: uç yolu ve gövde', () async {
      const siteId = '33333333-3333-4333-8333-333333333333';
      api.on(
        'PATCH',
        '/api/v1/admin/sites/$siteId/service-owner',
        (r) => okResponse(<String, dynamic>{'site_id': siteId, 'service_owner_id': serviceId, 'changed': false}),
      );
      final r = await service.transferSiteServiceOwner(siteId, serviceUserId: serviceId);
      expect(r.changed, isFalse);
      expect(api.requests.single.json, <String, dynamic>{'service_user_id': serviceId});
    });

    test('servis sorumlusu 403 alır: ileti olduğu gibi yükselir', () async {
      api.on(
        'PATCH',
        '/api/v1/admin/homes/$homeId/service-owner',
        (r) => errorResponse(403, 'Bu işlem yalnızca kök yöneticiye aittir.', code: 'FORBIDDEN'),
      );
      await expectLater(
        service.transferHomeServiceOwner(homeId, serviceUserId: serviceId),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
    });
  });
}
