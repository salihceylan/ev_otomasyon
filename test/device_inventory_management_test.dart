import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Cihaz envanteri sayfası: rol matrisi, kısıtlı durum geçişleri, yazarak onay, görünür hatalar,
/// sayfalama/arama, panonun 45 sn sonra silinmesi ve etiket yeniden üretimi (davranış testleri).

const String kUidStock = 'AHBU-S3-A1B2C3';
const String kUidClaimed = 'AHBU-S3-D4E5F6';
const String kUidSuspended = 'AHBU-S3-778899';

List<InventoryDeviceModel> threeDevices() => <InventoryDeviceModel>[
      inventoryDevice(uid: kUidStock, status: 'IN_STOCK', serial: 1),
      inventoryDevice(uid: kUidClaimed, status: 'CLAIMED', serial: 2, claimedHome: 'Daire 5 - Nilüfer'),
      inventoryDevice(uid: kUidSuspended, status: 'SUSPENDED', serial: 3),
    ];

Future<ServiceHarness> envFor(String role, {List<InventoryDeviceModel>? devices}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.inventory = devices ?? threeDevices();
  return env;
}

Future<void> openInventory(
  WidgetTester tester,
  ServiceHarness env, {
  int pageSize = 50,
  double textScale = 1.0,
}) async {
  await pumpPage(
    tester,
    env,
    DeviceInventoryPage(pageSize: pageSize),
    textScale: textScale,
    size: const Size(900, 3000),
  );
  await settle(tester);
}

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> typeConfirmPhrase(WidgetTester tester, String phrase) async {
  await typeKey(tester, 'field_confirm_phrase', phrase);
}

void main() {
  setUp(SecretClipboard.reset);

  group('rol matrisi', () {
    testWidgets('süper yönetici stoktaki cihazda askıya al, etiket üret ve sil; askıdakinde stoğa al ve sil; devredekinde yalnızca açıklama görür',
        (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      // Stokta: tüm yönetim eylemleri
      expect(exists('btn_suspend_$kUidStock'), isTrue);
      expect(exists('btn_reissue_label_$kUidStock'), isTrue);
      expect(exists('btn_delete_$kUidStock'), isTrue);
      expect(exists('btn_restore_$kUidStock'), isFalse, reason: 'stoktaki cihaz zaten stokta');

      // Devrede: askıya alma / silme / etiket yenileme YOK, nedeni açıklanır.
      expect(exists('btn_suspend_$kUidClaimed'), isFalse);
      expect(exists('btn_delete_$kUidClaimed'), isFalse);
      expect(exists('btn_reissue_label_$kUidClaimed'), isFalse);
      expect(exists('note_claimed_$kUidClaimed'), isTrue);

      // Askıda: stoğa alma, silme, etiket yenileme var; yeniden askıya alma yok.
      expect(exists('btn_restore_$kUidSuspended'), isTrue);
      expect(exists('btn_suspend_$kUidSuspended'), isFalse);
      expect(exists('btn_delete_$kUidSuspended'), isTrue);
      expect(exists('btn_reissue_label_$kUidSuspended'), isFalse, reason: 'sunucu yalnızca IN_STOCK cihazın etiketini yeniler');
    });

    testWidgets('iptal edilmiş cihaz yalnızca stoğa alınır ya da (yazarak onayla) silinir; askıya alma ve etiket üretimi yoktur', (tester) async {
      final env = await envFor('super', devices: <InventoryDeviceModel>[inventoryDevice(uid: kUidStock, status: 'REVOKED')]);
      addTearDown(env.dispose);
      await openInventory(tester, env);
      expect(exists('btn_restore_$kUidStock'), isTrue);
      expect(exists('btn_delete_$kUidStock'), isTrue);
      expect(exists('btn_suspend_$kUidStock'), isFalse);
      expect(exists('btn_reissue_label_$kUidStock'), isFalse, reason: 'etiket yalnızca stoktaki cihaz için üretilir');
    });

    testWidgets('servis personeli envanteri ve karekodu görür ama hiçbir yönetim düğmesi çıkmaz', (tester) async {
      final env = await envFor('staff');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);
      expect(exists('btn_qr_$kUidStock'), isTrue);
      for (final prefix in ['btn_suspend_', 'btn_restore_', 'btn_delete_', 'btn_reissue_label_']) {
        for (final uid in [kUidStock, kUidClaimed, kUidSuspended]) {
          expect(exists('$prefix$uid'), isFalse, reason: '$prefix$uid personelde görünmemeli');
        }
      }
    });

    testWidgets('geçici servis oturumu envanteri açamaz ve sunucuya istek atılmaz', (tester) async {
      final env = await envFor('pin');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      expect(find.textContaining('yalnızca süper yönetici ve servis personeli'), findsOneWidget);
      expect(env.cloud.calls.where((c) => c.startsWith('fetchDeviceInventory')), isEmpty);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsNothing);
    });
  });

  group('durum geçişleri', () {
    testWidgets('askıya alma onay ister: vazgeçince istek atılmaz, onaylayınca cihaz askıya alınır', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_suspend_$kUidStock');
      expect(find.text('Cihaz askıya alınsın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_status_cancel');
      await settle(tester);
      expect(env.cloud.inventoryStatusUpdates, isEmpty);

      await tapKey(tester, 'btn_suspend_$kUidStock');
      await tapKey(tester, 'btn_status_confirm');
      await settle(tester);
      expect(env.cloud.inventoryStatusUpdates, <String>['$kUidStock:SUSPENDED']);
      expect(exists('btn_restore_$kUidStock'), isTrue, reason: 'artık askıda; stoğa alma sunulur');
      expect(exists('btn_suspend_$kUidStock'), isFalse);
    });

    testWidgets('askıdaki cihaz stoğa alınır', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_restore_$kUidSuspended');
      await tapKey(tester, 'btn_status_confirm');
      await settle(tester);
      expect(env.cloud.inventoryStatusUpdates, <String>['$kUidSuspended:IN_STOCK']);
      expect(exists('btn_suspend_$kUidSuspended'), isTrue);
    });

    testWidgets('iptal edilmiş cihazı stoğa almak basit onayla değil, cihaz kimliği YAZILARAK onaylanır', (tester) async {
      final env = await envFor('super', devices: <InventoryDeviceModel>[inventoryDevice(uid: kUidStock, status: 'REVOKED')]);
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_restore_$kUidStock');
      expect(find.text('İptal edilmiş cihaz stoğa alınsın mı?'), findsOneWidget);
      expect(find.textContaining('İPTAL EDİLMİŞTİ'), findsOneWidget, reason: 'neden uyarılır');
      expect(exists('btn_status_confirm'), isFalse, reason: 'basit "Stoğa Al" onayı yok');
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await typeConfirmPhrase(tester, 'AHBU-S3-YANLIS');
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);

      // Vazgeçmek hiçbir istek atmaz.
      await tapKey(tester, 'btn_cancel_destructive');
      await settle(tester);
      expect(env.cloud.inventoryStatusUpdates, isEmpty);

      await tapKey(tester, 'btn_restore_$kUidStock');
      await typeConfirmPhrase(tester, kUidStock);
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isTrue);
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester);
      expect(env.cloud.inventoryStatusUpdates, <String>['$kUidStock:IN_STOCK']);
      expect(exists('btn_suspend_$kUidStock'), isTrue, reason: 'artık stokta');
    });

    testWidgets('askıdaki cihazın stoğa alınması basit onayla kalır (yazarak onay yalnızca iptal edilmiş cihaz için)', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);
      await tapKey(tester, 'btn_restore_$kUidSuspended');
      expect(exists('btn_status_confirm'), isTrue);
      expect(exists('field_confirm_phrase'), isFalse);
    });

    testWidgets('durum değiştirme sunucuda reddedilirse hata görünür ve durum değişmiş gibi gösterilmez', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      env.cloud.inventoryMutationError = const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Cihaz şu anda işlemde.');
      await openInventory(tester, env);

      await tapKey(tester, 'btn_suspend_$kUidStock');
      await tapKey(tester, 'btn_status_confirm');
      await settle(tester);
      expect(find.text('Cihaz şu anda işlemde.'), findsOneWidget);
      expect(exists('btn_suspend_$kUidStock'), isTrue, reason: 'başarısız işlem kartı değiştirmemeli');
    });
  });

  group('silme', () {
    testWidgets('silme cihaz kimliği yazılmadan etkinleşmez; doğru yazılınca cihaz envanterden kalkar', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_delete_$kUidStock');
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await typeConfirmPhrase(tester, 'AHBU-S3-YANLIS');
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse, reason: 'yanlış kimlik onaylamaz');
      await typeConfirmPhrase(tester, kUidStock.toLowerCase());
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isTrue, reason: 'büyük/küçük harf farkı önemsizdir');
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester);

      expect(env.cloud.inventoryDeleted, <String>[kUidStock]);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsNothing);
    });

    testWidgets('silme vazgeçilirse hiçbir istek atılmaz', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_delete_$kUidSuspended');
      await tapKey(tester, 'btn_cancel_destructive');
      await settle(tester);
      expect(env.cloud.inventoryDeleted, isEmpty);
      expect(find.byKey(const Key('card_inventory_$kUidSuspended')), findsOneWidget);
    });

    testWidgets('sunucu silmeyi reddederse hata gösterilir ve cihaz listede kalır', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      env.cloud.inventoryMutationError = const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Cihaz bir daireye bağlı.');
      await openInventory(tester, env);

      await tapKey(tester, 'btn_delete_$kUidStock');
      await typeConfirmPhrase(tester, kUidStock);
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester);
      expect(find.text('Cihaz bir daireye bağlı.'), findsOneWidget);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);
    });
  });

  group('yükleme hataları ve yenileme', () {
    testWidgets('sunucu hiç yanıt vermezse sonsuz dönmez: 25 sn sonra zaman aşımı hatası ve Tekrar Dene çıkar', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      env.cloud.inventoryGate = Completer<void>();
      await openInventory(tester, env);
      expect(exists('inventory_loading'), isTrue);

      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(exists('inventory_loading'), isFalse);
      expect(exists('inventory_error'), isTrue);
      expect(find.textContaining('zaman aşımına uğradı'), findsOneWidget);

      env.cloud.inventoryGate!.complete();
      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(exists('inventory_error'), isFalse);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);
    });

    testWidgets('ilk yüklemede hata olursa boş liste yerine hata ve Tekrar Dene gösterilir; tekrar denenince liste gelir',
        (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      env.cloud.inventoryErrorOnce = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu şu anda yanıt veremiyor.');
      await openInventory(tester, env);

      expect(exists('inventory_error'), isTrue);
      expect(find.text('Sunucu şu anda yanıt veremiyor.'), findsOneWidget);
      expect(exists('inventory_empty'), isFalse, reason: 'hata, "envanter boş" gibi gösterilmemeli');

      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(exists('inventory_error'), isFalse);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);
    });

    testWidgets('yenileme başarısız olursa eski liste "güncellenemedi" uyarısıyla gösterilir, düzelince uyarı kalkar',
        (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);

      env.cloud.inventoryError = const ApiException(statusCode: 0, code: 'NETWORK', message: 'Sunucuya ulaşılamadı.');
      await tapKey(tester, 'btn_refresh');
      await settle(tester);
      expect(exists('inventory_stale'), isTrue, reason: 'bayat veri sessizce gösterilmemeli');
      expect(find.textContaining('Sunucuya ulaşılamadı.'), findsOneWidget);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);

      env.cloud.inventoryError = null;
      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(exists('inventory_stale'), isFalse);
    });

    testWidgets('sunucu boş envanter döndürürse yönlendirici boş durum gösterilir', (tester) async {
      final env = await envFor('super', devices: <InventoryDeviceModel>[]);
      addTearDown(env.dispose);
      await openInventory(tester, env);
      expect(exists('inventory_empty'), isTrue);
      expect(find.textContaining('Karekod Üret & Etiket Bas'), findsOneWidget);
    });
  });

  group('arama ve sayfalama', () {
    testWidgets('arama 300 ms sessiz kalınca tek istek atar', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);
      final before = env.cloud.calls.where((c) => c.startsWith('fetchDeviceInventory')).length;

      await tester.enterText(find.byKey(const Key('field_search')), 'D4');
      await tester.pump();
      await tester.enterText(find.byKey(const Key('field_search')), 'D4E5');
      await tester.pump();
      env.clock.advance(const Duration(milliseconds: 250));
      await settle(tester, frames: 3);
      expect(env.cloud.calls.where((c) => c.startsWith('fetchDeviceInventory')).length, before,
          reason: '300 ms dolmadan istek atılmamalı');

      env.clock.advance(const Duration(milliseconds: 100));
      await settle(tester);
      final searches = env.cloud.calls.where((c) => c.startsWith('fetchDeviceInventory:D4E5')).toList();
      expect(searches, hasLength(1));
      expect(find.byKey(const Key('card_inventory_$kUidClaimed')), findsOneWidget);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsNothing);
    });

    testWidgets('liste sayfalıdır: Daha fazla yükle sonraki sayfayı mevcut listenin sonuna ekler', (tester) async {
      final env = await envFor('super', devices: <InventoryDeviceModel>[
        for (var i = 1; i <= 5; i++) inventoryDevice(uid: 'AHBU-S3-0000$i', serial: i),
      ]);
      addTearDown(env.dispose);
      await openInventory(tester, env, pageSize: 2);

      expect(find.byKey(const Key('card_inventory_AHBU-S3-00001')), findsOneWidget);
      expect(find.byKey(const Key('card_inventory_AHBU-S3-00003')), findsNothing);
      await tapKey(tester, 'btn_load_more');
      await settle(tester);
      expect(find.byKey(const Key('card_inventory_AHBU-S3-00001')), findsOneWidget, reason: 'önceki sayfa korunur');
      expect(env.cloud.calls, contains('fetchDeviceInventory::2'));
    });

    testWidgets('durum süzgeci sunucuya durum parametresiyle sorar', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await openInventory(tester, env);

      await tapKey(tester, 'chip_filter_SUSPENDED');
      await settle(tester);
      expect(find.byKey(const Key('card_inventory_$kUidSuspended')), findsOneWidget);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsNothing);
    });
  });

  group('karekod ve pano', () {
    testWidgets('karekod penceresi PIN içermeyen bağlantıyı gösterir ve kopyalanan bağlantı 45 sn sonra panodan silinir',
        (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      final clip = ClipboardSpy()..install(tester);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_qr_$kUidStock');
      await settle(tester);
      expect(find.textContaining('PIN içermez'), findsOneWidget);
      await tapKey(tester, 'btn_copy_qr_link');
      await settle(tester);
      expect(clip.text, contains(kUidStock));

      env.clock.advance(const Duration(seconds: 44));
      await settle(tester, frames: 3);
      expect(clip.text, isNotEmpty, reason: '45 sn dolmadan silinmemeli');
      env.clock.advance(const Duration(seconds: 2));
      await settle(tester);
      expect(clip.text, isEmpty, reason: 'karekod bağlantısı 45 sn sonra panodan silinmeli');
    });

    testWidgets('UUID satırına dokunmak değeri kopyalar ve yine 45 sn sonra siler', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      final clip = ClipboardSpy()..install(tester);
      await openInventory(tester, env);

      await tester.tap(find.text(kUidStock).first);
      await settle(tester);
      expect(clip.text, kUidStock);
      env.clock.advance(const Duration(seconds: 46));
      await settle(tester);
      expect(clip.text, isEmpty);
    });
  });

  group('etiket yeniden üretimi', () {
    testWidgets('kimlik yazılarak onaylanır; yeni PIN ve anahtar bir kez gösterilir, pencere kapanınca pano temizlenir',
        (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      final clip = ClipboardSpy()..install(tester);
      await openInventory(tester, env);

      await tapKey(tester, 'btn_reissue_label_$kUidStock');
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await typeConfirmPhrase(tester, kUidStock);
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester);

      expect(env.cloud.reissued, <String>[kUidStock]);
      expect(find.byKey(const Key('reissue_warning')), findsOneWidget);
      expect(find.text('705 318'), findsOneWidget, reason: 'PIN okunaklı gruplanır');
      expect(find.text(kReissuedKey), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing,
          reason: 'gizli değerler seçilebilir metin değildir: panoya tek giriş yolu, silinen "Kopyala" düğmesidir');

      await tapKey(tester, 'btn_copy_reissue_pin');
      await settle(tester);
      expect(clip.text, kReissuedPin);

      await tapKey(tester, 'btn_reissue_close');
      await settle(tester);
      expect(clip.text, isEmpty, reason: 'diyalog kapanınca gizli değer panodan silinir');
      expect(find.text('705 318'), findsNothing);
      expect(find.text(kReissuedKey), findsNothing);
    });

    testWidgets('istek sürerken sayfadan çıkılamaz (tek seferlik PIN/anahtar kaybolmasın); yanıt gelince değerler gösterilir', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      ClipboardSpy().install(tester);
      env.cloud.reissueGate = Completer<void>();
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: env.state,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('launcher'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeviceInventoryPage())),
                    child: const Text('aç'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'launcher');
      await settle(tester, frames: 20);
      expect(find.byType(DeviceInventoryPage), findsOneWidget);

      await tapKey(tester, 'btn_reissue_label_$kUidStock');
      await typeConfirmPhrase(tester, kUidStock);
      await tapKey(tester, 'btn_confirm_destructive');
      await tester.pump();
      expect(env.cloud.calls, contains('reissueInventoryLabel:$kUidStock'), reason: 'istek gönderildi ve yanıt bekleniyor');

      // Geri dönmeye çalışmak (sistem geri tuşu / uygulama çubuğu geri oku) engellenir.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      await navigator.maybePop();
      await tester.pump();
      expect(find.byType(DeviceInventoryPage), findsOneWidget, reason: 'yanıt gelmeden sayfa kapanmaz');
      expect(find.textContaining('yalnızca bir kez gösterilir: işlem bitene kadar sayfadan çıkılamaz'), findsOneWidget);

      env.cloud.reissueGate!.complete();
      await settle(tester, frames: 20);
      expect(find.text('705 318'), findsOneWidget, reason: 'tek seferlik PIN yine de gösterildi');
      expect(find.text(kReissuedKey), findsOneWidget);

      await tapKey(tester, 'btn_reissue_close');
      await settle(tester, frames: 20);
      await navigator.maybePop();
      await settle(tester, frames: 20);
      expect(find.byType(DeviceInventoryPage), findsNothing, reason: 'istek bitince sayfadan çıkılabilir');
    });

    testWidgets('sunucu etiketi yenilemezse hata görünür ve hiçbir gizli bilgi gösterilmez', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      env.cloud.reissueError = const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Cihaz şu anda kurulumda.');
      await openInventory(tester, env);

      await tapKey(tester, 'btn_reissue_label_$kUidStock');
      await typeConfirmPhrase(tester, kUidStock);
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester);
      expect(find.text('Cihaz şu anda kurulumda.'), findsOneWidget);
      expect(find.byKey(const Key('reissue_warning')), findsNothing);
    });
  });

  group('günlük ve erişilebilirlik', () {
    testWidgets('hiçbir akışta debugPrint ile cihaz bilgisi yazılmaz', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await withDebugLog((log) async {
        await openInventory(tester, env);
        await tapKey(tester, 'btn_suspend_$kUidStock');
        await tapKey(tester, 'btn_status_confirm');
        await settle(tester);
        await tapKey(tester, 'btn_qr_$kUidSuspended');
        await settle(tester);
        expect(log.all, isNot(contains(kUidStock)));
        expect(log.all, isNot(contains(kUidSuspended)));
        expect(log.lines.where((l) => l.contains('AHBU')), isEmpty);
      });
    });

    testWidgets('büyük yazı boyutunda ve dar ekranda taşma olmadan çalışır', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(360, 800), textScale: 1.5);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);
    });

    testWidgets('autoLoad kapalıyken durumdaki envanter gösterilir ve sunucuya istek atılmaz', (tester) async {
      final env = await envFor('super');
      addTearDown(env.dispose);
      env.state.setInventoryDevicesForTesting(<InventoryDeviceModel>[inventoryDevice(uid: kUidStock)]);
      await pumpPage(tester, env, const DeviceInventoryPage(autoLoad: false));
      await settle(tester);
      expect(find.byKey(const Key('card_inventory_$kUidStock')), findsOneWidget);
      expect(env.cloud.calls.where((c) => c.startsWith('fetchDeviceInventory')), isEmpty);
    });
  });
}
