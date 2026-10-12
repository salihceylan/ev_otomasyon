import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/pages/service_subscribers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Servis sorumlusu kapsamı (migration 045): kök için envanter kartında servis sahibi ve "Servisi Değiştir" (kart / daire),
/// servis için kök-yalnız öğelerin gizlenmesi ve aktarım penceresinin akışı (seç -> onayla -> sonuç; hata pencerede kalır).
const String serviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String serviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String serviceFrozen = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String servicePending = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

const String uidOwned = 'AHBU-S3-A1B2C3';
const String uidRoot = 'AHBU-S3-D4E5F6';
const String uidClaimed = 'AHBU-S3-778899';
const String uidOld = 'AHBU-S3-0A0A0A';

Map<String, dynamic> account(
  String id,
  String name, {
  String role = 'service_user',
  bool active = true,
  String status = 'active',
}) =>
    <String, dynamic>{
      'id': id,
      'full_name': name,
      'email': '${name.split(' ').first.toLowerCase()}@servis.test',
      'phone': null,
      'role': role,
      'is_active': active,
      'account_status': status,
    };

List<Map<String, dynamic>> accounts() => <Map<String, dynamic>>[
      account(serviceA, 'Ahmet Servis'),
      account(serviceB, 'Berk Servis'),
      account(serviceFrozen, 'Cemal Donuk', active: false, status: 'suspended'),
      account(servicePending, 'Derya Bekleyen', status: 'pending_invite'),
      account('u-musteri', 'Müşteri Kişi', role: 'user'),
    ];

Map<String, dynamic> sub(
  String homeId,
  String name, {
  bool reported = true,
  String? serviceId,
  String? serviceName,
}) =>
    <String, dynamic>{
      'home_id': homeId,
      'home_name': name,
      'home_address': 'Atatürk Cad. No:5',
      'owner': null,
      'device_count': 1,
      'online_count': 0,
      'commissioned_count': 0,
      'device_uuids': <String>['AHBU-S3-$homeId'],
      if (reported) 'service_owner_id': serviceId,
      if (reported) 'service_owner_name': serviceName,
    };

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data ?? '';

Future<ServiceHarness> inventoryEnv(String role, {List<InventoryDeviceModel>? devices}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.adminUsers = accounts();
  env.cloud.inventory = devices ??
      <InventoryDeviceModel>[
        inventoryDevice(uid: uidOwned, serial: 1, ownerReported: true, serviceOwnerId: serviceA, serviceOwnerEmail: 'ahmet@servis.test'),
        inventoryDevice(uid: uidRoot, serial: 2, ownerReported: true),
        inventoryDevice(
          uid: uidClaimed,
          status: 'CLAIMED',
          serial: 3,
          claimedHome: 'Daire 5',
          claimedHomeId: 'home-5',
          ownerReported: true,
          serviceOwnerId: serviceA,
          serviceOwnerEmail: 'ahmet@servis.test',
        ),
      ];
  return env;
}

Future<void> openInventory(WidgetTester tester, ServiceHarness env) async {
  await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(900, 3200));
  await settle(tester);
}

Future<ServiceHarness> subscribersEnv(String role, List<Map<String, dynamic>> rows) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.adminUsers = accounts();
  env.cloud.subscribers = rows;
  return env;
}

Future<void> openSubscribers(WidgetTester tester, ServiceHarness env) async {
  await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(900, 3200));
  await settle(tester);
}

void main() {
  group('envanter: kök servis sahibini görür ve kartı aktarır', () {
    testWidgets('kök: kartta "Servis: e-posta" / "Servis: Kök stoğu"; stoktaki kartta "Servisi Değiştir", kurulu kartta yalnız açıklama',
        (tester) async {
      final env = await inventoryEnv('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      expect(textOf(tester, 'note_service_owner_$uidOwned'), 'Servis: ahmet@servis.test');
      expect(textOf(tester, 'note_service_owner_$uidRoot'), 'Servis: Kök stoğu');
      expect(textOf(tester, 'note_service_owner_$uidClaimed'), 'Servis: ahmet@servis.test');

      expect(exists('btn_transfer_service_$uidOwned'), isTrue);
      expect(exists('btn_transfer_service_$uidRoot'), isTrue);
      expect(find.widgetWithText(OutlinedButton, 'Servisi Değiştir'), findsNWidgets(2));
      expect(exists('btn_transfer_service_$uidClaimed'), isFalse, reason: 'kurulu kart evinin servisini izler (sunucu 409)');
      expect(exists('note_transfer_claimed_$uidClaimed'), isTrue);
      expect(find.textContaining('Aboneler ekranından daireyi aktarın'), findsOneWidget);
    });

    testWidgets('servis sorumlusu: servis sahibi satırı, aktarım düğmesi ve kurulu-kart açıklaması YOK; yönetim düğmeleri var', (tester) async {
      final env = await inventoryEnv('staff');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      for (final uid in <String>[uidOwned, uidRoot, uidClaimed]) {
        expect(exists('note_service_owner_$uid'), isFalse, reason: uid);
        expect(exists('btn_transfer_service_$uid'), isFalse, reason: uid);
        expect(exists('note_transfer_claimed_$uid'), isFalse, reason: uid);
      }
      expect(find.text('Servisi Değiştir'), findsNothing);
      expect(exists('btn_suspend_$uidOwned'), isTrue);
      expect(exists('btn_reissue_label_$uidOwned'), isTrue);
      expect(exists('btn_delete_$uidOwned'), isTrue);
    });

    testWidgets('eski sunucu (service_owner_id alanı yok): servis satırı ve aktarım düğmesi çizilmez, "Kök stoğu" denmez', (tester) async {
      final env = await inventoryEnv('super', devices: <InventoryDeviceModel>[inventoryDevice(uid: uidOld)]);
      addTearDown(env.dispose);
      await openInventory(tester, env);

      expect(exists('card_inventory_$uidOld'), isTrue);
      expect(exists('note_service_owner_$uidOld'), isFalse);
      expect(exists('btn_transfer_service_$uidOld'), isFalse);
      expect(find.textContaining('Kök stoğu'), findsNothing);
      expect(exists('btn_suspend_$uidOld'), isTrue, reason: 'yönetim düğmeleri eski sunucuda da çalışır');
    });

    testWidgets('kök kartı başka servise aktarır: servis hesapları listelenir (aktif olmayanlar ve müşteriler yok), onay adımı, sonuç iletisi, liste yenilenir',
        (tester) async {
      final env = await inventoryEnv('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_transfer_service_$uidRoot');
      await settle(tester);
      expect(exists('dialog_service_owner'), isTrue);
      expect(find.text('Servisi Değiştir'), findsWidgets);
      expect(find.text('Mevcut servis: Kök (servissiz)'), findsOneWidget);
      expect(env.cloud.calls.where((c) => c.startsWith('listAdminUsers:service_user')), isNotEmpty, reason: 'yalnız servis rolü istenir');

      expect(exists('opt_service_owner_root'), isTrue, reason: '"Kök (servissiz)" seçeneği hedef null');
      expect(exists('opt_service_owner_$serviceA'), isTrue);
      expect(exists('opt_service_owner_$serviceB'), isTrue);
      expect(exists('opt_service_owner_$serviceFrozen'), isFalse, reason: 'donuk hesap hedef olamaz (sunucu 409)');
      expect(exists('opt_service_owner_$servicePending'), isFalse, reason: 'etkinleştirilmemiş hesap hedef olamaz');
      expect(exists('opt_service_owner_u-musteri'), isFalse);
      expect(buttonEnabled(tester, 'btn_service_owner_next'), isFalse, reason: 'seçim yapılmadan devam edilemez');
      // Kök kartın mevcut sahibi: aynı kapsama aktarım anlamsız -> "Devam" kapalı.
      await tapKey(tester, 'opt_service_owner_root');
      expect(buttonEnabled(tester, 'btn_service_owner_next'), isFalse, reason: 'zaten kök stoğunda');

      await tapKey(tester, 'opt_service_owner_$serviceB');
      expect(buttonEnabled(tester, 'btn_service_owner_next'), isTrue);
      await tapKey(tester, 'btn_service_owner_next');
      expect(exists('service_owner_confirm_text'), isTrue);
      expect(find.textContaining('"Kök (servissiz)" kapsamından "Berk Servis" kapsamına aktarılacak'), findsOneWidget);
      expect(env.cloud.serviceTransfers, isEmpty, reason: 'onaylanmadan istek gitmez');

      await tapKey(tester, 'btn_service_owner_confirm');
      await settle(tester);
      expect(env.cloud.serviceTransfers, <String>['inventory:$uidRoot:$serviceB']);
      expect(exists('dialog_service_owner'), isFalse);
      expect(find.text('Kart yeni servis sorumlusunun stoğuna aktarıldı.'), findsOneWidget);
      expect(textOf(tester, 'note_service_owner_$uidRoot'), 'Servis: berk@servis.test', reason: 'liste yenilendi');
    });

    testWidgets('"Kök (servissiz)" seçilirse gövde service_user_id: null (köke al)', (tester) async {
      final env = await inventoryEnv('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_transfer_service_$uidOwned');
      await settle(tester);
      expect(find.text('Mevcut servis: ahmet@servis.test'), findsOneWidget);
      // Mevcut servis seçilemez (aynı kapsam): Devam kapalı.
      await tapKey(tester, 'opt_service_owner_$serviceA');
      expect(buttonEnabled(tester, 'btn_service_owner_next'), isFalse);
      await tapKey(tester, 'opt_service_owner_root');
      await tapKey(tester, 'btn_service_owner_next');
      expect(find.textContaining('servis sorumluları bu kartı yalnızca kurabilir'), findsOneWidget);
      await tapKey(tester, 'btn_service_owner_confirm');
      await settle(tester);
      expect(env.cloud.serviceTransfers, <String>['inventory:$uidOwned:root']);
      expect(find.text('Kart kök stoğuna alındı.'), findsOneWidget);
      expect(textOf(tester, 'note_service_owner_$uidOwned'), 'Servis: Kök stoğu');
    });

    testWidgets('sunucu reddederse ileti pencerede kalır, pencere kapanmaz, hiçbir şey değişmez', (tester) async {
      final env = await inventoryEnv('super');
      addTearDown(env.dispose);
      env.cloud.transferError = const ApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Servis sorumlusu hesabı aktif değil.',
      );
      await openInventory(tester, env);

      await tapKey(tester, 'btn_transfer_service_$uidRoot');
      await settle(tester);
      await tapKey(tester, 'opt_service_owner_$serviceB');
      await tapKey(tester, 'btn_service_owner_next');
      await tapKey(tester, 'btn_service_owner_confirm');
      await settle(tester);

      expect(exists('dialog_service_owner'), isTrue);
      expect(exists('service_owner_error'), isTrue);
      expect(find.text('Servis sorumlusu hesabı aktif değil.'), findsOneWidget);
      expect(env.cloud.serviceTransfers, isEmpty);
      // Geri dönülebilir; vazgeçmek pencereyi hiçbir istek atmadan kapatır.
      await tapKey(tester, 'btn_service_owner_back');
      expect(exists('service_owner_error'), isFalse);
      await tapKey(tester, 'btn_service_owner_cancel');
      await settle(tester);
      expect(exists('dialog_service_owner'), isFalse);
      expect(env.cloud.serviceTransfers, isEmpty);
    });

    testWidgets('servis hesapları yüklenemezse hata ve "Tekrar dene" görünür; kök seçeneği yine de seçilebilir', (tester) async {
      final env = await inventoryEnv('super');
      addTearDown(env.dispose);
      env.cloud.adminListErrorOnce = const ApiException(statusCode: 503, code: 'SERVICE_UNAVAILABLE', message: 'Sunucu şu anda yanıt veremiyor.');
      await openInventory(tester, env);

      await tapKey(tester, 'btn_transfer_service_$uidOwned');
      await settle(tester);
      expect(exists('service_owner_load_error'), isTrue);
      expect(find.text('Sunucu şu anda yanıt veremiyor.'), findsOneWidget);
      expect(exists('opt_service_owner_root'), isTrue);

      await tapKey(tester, 'btn_service_owner_retry');
      await settle(tester);
      expect(exists('service_owner_load_error'), isFalse);
      expect(exists('opt_service_owner_$serviceB'), isTrue);
    });
  });

  group('aboneler: kök dairenin servisini görür ve daireyi aktarır', () {
    List<Map<String, dynamic>> rows() => <Map<String, dynamic>>[
          sub('h1', 'Daire 1', serviceId: serviceA, serviceName: 'Ahmet Servis'),
          sub('h2', 'Daire 2'),
        ];

    testWidgets('kök: her dairede servis satırı ("Servis: ad" / "Servis: Kök (servissiz)") ve "Servisi Değiştir"', (tester) async {
      final env = await subscribersEnv('super', rows());
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      expect(textOf(tester, 'note_service_owner_h1'), 'Servis: Ahmet Servis');
      expect(textOf(tester, 'note_service_owner_h2'), 'Servis: Kök (servissiz)');
      expect(exists('btn_transfer_service_h1'), isTrue);
      expect(exists('btn_transfer_service_h2'), isTrue);
      expect(find.text('Servisi Değiştir'), findsNWidgets(2));
    });

    testWidgets('servis sorumlusu: servis satırı ve "Servisi Değiştir" YOK (kök-yalnız); Home Admin atama sürer', (tester) async {
      final env = await subscribersEnv('staff', rows());
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      expect(exists('card_subscriber_h1'), isTrue);
      expect(exists('note_service_owner_h1'), isFalse);
      expect(exists('btn_transfer_service_h1'), isFalse);
      expect(find.text('Servisi Değiştir'), findsNothing);
      expect(exists('btn_assign_admin_h1'), isTrue);
    });

    testWidgets('eski sunucu (servis alanları yok): satır ve düğme çizilmez', (tester) async {
      final env = await subscribersEnv('super', <Map<String, dynamic>>[sub('h1', 'Daire 1', reported: false)]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      expect(exists('card_subscriber_h1'), isTrue);
      expect(exists('note_service_owner_h1'), isFalse);
      expect(exists('btn_transfer_service_h1'), isFalse);
    });

    testWidgets('kök daireyi başka servise aktarır: taşınan kart sayısı iletide, liste yenilenir', (tester) async {
      final env = await subscribersEnv('super', rows());
      addTearDown(env.dispose);
      env.cloud.transferCardsMoved = 2;
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_transfer_service_h1');
      await settle(tester);
      expect(find.text('Mevcut servis: Ahmet Servis'), findsOneWidget);
      expect(find.text('Daire 1 (#h1)'), findsWidgets);
      await tapKey(tester, 'opt_service_owner_$serviceB');
      await tapKey(tester, 'btn_service_owner_next');
      expect(find.textContaining('Dairedeki kartlar da bu servisin stoğuna geçer.'), findsOneWidget);
      expect(find.textContaining('uygulama bağlantı kimlikleri iptal edilir'), findsOneWidget);
      await tapKey(tester, 'btn_service_owner_confirm');
      await settle(tester);

      expect(env.cloud.serviceTransfers, <String>['home:h1:$serviceB']);
      expect(
        find.text('Daire yeni servis sorumlusunun kapsamına aktarıldı. 2 kart yeni servisin stoğuna geçti.'),
        findsOneWidget,
      );
      expect(textOf(tester, 'note_service_owner_h1'), 'Servis: Berk Servis');
    });

    testWidgets('kök daireyi köke alır; sonuç iletisi ve satır "Kök (servissiz)" olur', (tester) async {
      final env = await subscribersEnv('super', rows());
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_transfer_service_h1');
      await settle(tester);
      await tapKey(tester, 'opt_service_owner_root');
      await tapKey(tester, 'btn_service_owner_next');
      expect(find.textContaining('hiçbir servis sorumlusu bu daireyi yönetemez'), findsOneWidget);
      await tapKey(tester, 'btn_service_owner_confirm');
      await settle(tester);

      expect(env.cloud.serviceTransfers, <String>['home:h1:root']);
      expect(find.text('Daire kök yönetici kapsamına alındı.'), findsOneWidget);
      expect(textOf(tester, 'note_service_owner_h1'), 'Servis: Kök (servissiz)');
    });

    testWidgets('servis sorumlusu durum katmanından da aktaramaz: istek hiç gitmez (savunma)', (tester) async {
      final env = await subscribersEnv('staff', rows());
      addTearDown(env.dispose);
      await expectLater(
        env.state.transferHomeServiceOwner('h1', serviceUserId: serviceB),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
      await expectLater(
        env.state.transferInventoryServiceOwner(uidOwned, serviceUserId: serviceB),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
      expect(env.cloud.calls.where((c) => c.startsWith('transfer')), isEmpty);
    });
  });

  group('müşteri yönetimi: servis yalnız kendi müşterilerini yönetir; servis hesapları kök-yalnız', () {
    testWidgets('servis sorumlusu: kapsam notu, müşteride dondur / bağlantı gönder; servis hesabı satırında kök-yalnız eylem YOK; özet ucu çağrılmaz',
        (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.adminUsers = <Map<String, dynamic>>[account('u-musteri', 'Müşteri Kişi', role: 'user'), account(serviceB, 'Berk Servis')];
      await pumpPage(tester, env, const ServiceManagementPage(), size: const Size(900, 3000));
      await settle(tester);

      expect(find.textContaining('kendi müşterilerinizi (açtığınız ve dairelerinizdeki hesaplar) görür ve yönetirsiniz'), findsOneWidget);
      expect(exists('btn_freeze_u-musteri'), isTrue);
      expect(exists('btn_send_reset_u-musteri'), isTrue);
      for (final id in <String>['u-musteri', serviceB]) {
        expect(exists('btn_change_role_$id'), isFalse, reason: 'rol değiştirme yalnız kök');
        expect(exists('btn_hard_delete_$id'), isFalse, reason: 'kalıcı silme yalnız kök');
      }
      expect(exists('note_readonly_$serviceB'), isTrue, reason: 'servis hesabı servise salt okunur');
      expect(exists('management_summary'), isFalse, reason: 'sistem özeti yalnız kök');
      expect(env.cloud.calls, isNot(contains('getServiceSummary')));
    });
  });

  group('düzen: dar ekran ve büyük yazıda taşma yok', () {
    for (final scale in <double>[1.0, 1.5, 2.0]) {
      testWidgets('envanter kartı + aktarım penceresi (360 dp, yazı ölçeği $scale)', (tester) async {
        final env = await inventoryEnv('super');
        addTearDown(env.dispose);
        await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(360, 2600), textScale: scale);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(textOf(tester, 'note_service_owner_$uidOwned'), 'Servis: ahmet@servis.test');

        await tapKey(tester, 'btn_transfer_service_$uidRoot');
        await settle(tester);
        await tapKey(tester, 'opt_service_owner_$serviceB');
        await tapKey(tester, 'btn_service_owner_next');
        expect(exists('service_owner_confirm_text'), isTrue);
        expect(tester.takeException(), isNull);
      });

      testWidgets('abone kartı servis satırı (360 dp, yazı ölçeği $scale)', (tester) async {
        final env = await subscribersEnv('super', <Map<String, dynamic>>[
          sub('h1', 'Daire 1', serviceId: serviceA, serviceName: 'Ahmet Servis Çok Uzun Bir Şirket Adı Anonim Şirketi'),
        ]);
        addTearDown(env.dispose);
        await pumpPage(tester, env, const ServiceSubscribersPage(), size: const Size(360, 2600), textScale: scale);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(exists('btn_transfer_service_h1'), isTrue);
      });
    }
  });
}
