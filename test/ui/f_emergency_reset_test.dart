import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/emergency_reset_card.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_clipboard.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart' show kHomeA;
import 'f_support.dart';
import 'f_widget_support.dart';

/// Acil servis sıfırlaması kartı: önceden doldurulmuş değer yok, doğrulama, yazarak onay, sonuç (uyarılar,
/// kısmi başarı, tek seferlik gizli değerler) ve yetki davranışları.

const String kResetUid = 'AHBU-S3-A1B2C3';
const String kResetReason = 'Kiracı tahliye edildi, tapu teyit edildi.';
const String kResetLabelQr = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kResetUid&pin=$kSetupPin';

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> openCard(
  WidgetTester tester,
  ServiceHarness env, {
  String? scan = kResetLabelQr,
  Size size = const Size(900, 2400),
}) async {
  await pumpPage(
    tester,
    env,
    Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: EmergencyResetCard(scanner: fakeScanner(scan))))),
    size: size,
  );
  await settle(tester);
}

String fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField))).controller!.text;

Future<void> fillValid(WidgetTester tester, {String uid = kResetUid, String reason = kResetReason, String owner = ''}) async {
  await typeKey(tester, 'field_reset_uid', uid);
  await typeKey(tester, 'field_reset_reason', reason);
  if (owner.isNotEmpty) await typeKey(tester, 'field_reset_owner', owner);
}

Future<void> confirmWithUid(WidgetTester tester, {String uid = kResetUid}) async {
  await tapKey(tester, 'btn_emergency_reset');
  await settle(tester);
  await typeKey(tester, 'field_confirm_phrase', uid);
  await tapKey(tester, 'btn_confirm_destructive');
  await settle(tester);
}

void main() {
  setUp(SecretClipboard.reset);

  group('form', () {
    testWidgets('cihaz kimliği, gerekçe ve yeni sahip alanları boş açılır (önceden doldurulmuş demo değer yok)', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      expect(fieldText(tester, 'field_reset_uid'), isEmpty);
      expect(fieldText(tester, 'field_reset_reason'), isEmpty);
      expect(fieldText(tester, 'field_reset_owner'), isEmpty);
      expect(find.textContaining('123456'), findsNothing);
      expect(find.textContaining('AHBU-S3-PANEL-001'), findsNothing);
    });

    testWidgets('etiket okutulunca yalnızca cihaz kimliği alana yazılır; etiketteki PIN hiçbir yerde görünmez', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await tapKey(tester, 'btn_reset_scan');
      await settle(tester);
      expect(fieldText(tester, 'field_reset_uid'), kResetUid);
      expect(find.textContaining(kSetupPin), findsNothing);
      expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(kSetupPin)), findsNothing);
    });

    testWidgets('tanınmayan karekod alan hatası verir ve kimlik alanını değiştirmez', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env, scan: 'rastgele metin');
      await tapKey(tester, 'btn_reset_scan');
      await settle(tester);
      expect(find.textContaining('Karekod tanınamadı'), findsOneWidget);
      expect(fieldText(tester, 'field_reset_uid'), isEmpty);
    });

    testWidgets('geçersiz kimlik, kısa gerekçe ve geçersiz yeni sahip alan hatası verir; hiçbir istek atılmaz', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);

      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      expect(find.textContaining('AHBU- ile başlamalıdır'), findsOneWidget);
      expect(find.textContaining('en az ${EmergencyResetCard.minReasonLength} karakter'), findsWidgets);

      await typeKey(tester, 'field_reset_uid', kResetUid);
      await typeKey(tester, 'field_reset_reason', '12345678901234'); // 14 karakter
      await typeKey(tester, 'field_reset_owner', 'bu bir eposta degil');
      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      expect(find.textContaining('(şu an 14)'), findsOneWidget);
      expect(find.textContaining('Geçerli bir e-posta adresi ya da telefon'), findsOneWidget);
      expect(exists('field_confirm_phrase'), isFalse);
      expect(env.cloud.emergencyResets, isEmpty);
    });

    testWidgets('gerekçedeki baş/son boşluk sayılmaz: 15 karakterlik anlamlı metin gerekir', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await fillValid(tester, reason: '     kısa gerekçe     ');
      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      expect(exists('field_confirm_phrase'), isFalse);
      expect(env.cloud.emergencyResets, isEmpty);
    });

    testWidgets('kendi hesabını yeni sahip olarak yazmak engellenir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await fillValid(tester, owner: 'SERVIS@ornek.test');
      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      expect(find.textContaining('Kendi hesabınızı yeni sahip'), findsOneWidget);
      expect(env.cloud.emergencyResets, isEmpty);
    });
  });

  group('yazarak onay', () {
    testWidgets('onay penceresi cihaz kimliği yazılana kadar pasiftir; vazgeçilirse sunucuya istek atılmaz', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await fillValid(tester);

      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      expect(find.text('Acil sıfırlama onayı'), findsOneWidget);
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await typeKey(tester, 'field_confirm_phrase', 'AHBU-S3-YANLIS');
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await tapKey(tester, 'btn_cancel_destructive');
      await settle(tester);
      expect(env.cloud.emergencyResets, isEmpty);
      expect(fieldText(tester, 'field_reset_uid'), kResetUid, reason: 'vazgeçilince form korunur');
    });

    testWidgets('onaylanınca istek, gerekçe, onay kimliği ve normalleştirilmiş yeni sahiple gider', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await fillValid(tester, uid: kResetUid.toLowerCase(), owner: ' Yeni.Sahip@Ornek.TEST ');
      await confirmWithUid(tester);

      final req = env.cloud.emergencyResets.single;
      expect(req['device'], kResetUid);
      expect(req['confirm'], kResetUid);
      expect(req['reason'], kResetReason);
      expect(req['new_owner'], 'yeni.sahip@ornek.test');
      // Form temizlenir (gerekçe/kimlik bir sonraki işleme sızmaz).
      expect(fieldText(tester, 'field_reset_uid'), isEmpty);
      expect(fieldText(tester, 'field_reset_reason'), isEmpty);
    });
  });

  group('sonuç', () {
    testWidgets('cihaz stoğa alındı: yeni kurulum PIN\'i bir kez gösterilir, kopyalanır, 45 sn sonra silinir ve kapanınca temizlenir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      final clip = ClipboardSpy()..install(tester);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: kResetUid,
        setupPin: kReissuedPin,
        affectedUsersCount: 3,
        message: 'Cihaz stoğa alındı.',
      );
      await openCard(tester, env);
      await fillValid(tester);
      await confirmWithUid(tester);

      expect(find.text('Sıfırlama tamamlandı'), findsOneWidget);
      expect(find.text('Cihaz stoğa alındı; eski daire bağlantısı kaldırıldı.'), findsOneWidget);
      expect(find.text('Eski daireden 3 kullanıcının erişimi kaldırıldı.'), findsOneWidget);
      expect(exists('reset_secret_warning'), isTrue);
      expect(find.text('705 318'), findsOneWidget);

      await tapKey(tester, 'btn_copy_reset_pin');
      await settle(tester);
      expect(clip.text, kReissuedPin);
      env.clock.advance(const Duration(seconds: 46));
      await settle(tester);
      expect(clip.text, isEmpty, reason: '45 sn sonra panodan silinir');

      await tapKey(tester, 'btn_copy_reset_pin');
      await settle(tester);
      expect(clip.text, kReissuedPin);
      await tapKey(tester, 'btn_reset_close');
      await settle(tester);
      expect(clip.text, isEmpty, reason: 'diyalog kapanınca hemen silinir');
      expect(find.text('705 318'), findsNothing, reason: 'gizli değer kapatınca ekranda kalmaz');
    });

    testWidgets('kısmi başarı: uyarılar ve yerel anahtarın panoya iletilemediği bilgisi gösterilir; anahtar bir kez yazılır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: kResetUid,
        setupPin: kReissuedPin,
        localKey: kReissuedKey,
        localKeyPublish: 'skipped_offline',
        childLockReset: 'failed',
        warnings: <String>['Pano çevrimdışıydı; kimlik iptali kuyruğa alındı.'],
        partial: true,
      );
      await openCard(tester, env);
      await fillValid(tester);
      await confirmWithUid(tester);

      expect(find.text('Sıfırlama kısmen tamamlandı'), findsOneWidget);
      expect(exists('reset_partial'), isTrue);
      expect(find.text('Pano çevrimdışıydı; kimlik iptali kuyruğa alındı.'), findsOneWidget);
      expect(find.textContaining('Yerel anahtar panoya iletilemedi: pano çevrimdışıydı.'), findsOneWidget);
      expect(find.textContaining('Çocuk kilidi sıfırlaması panoya iletilemedi (hata).'), findsOneWidget);
      expect(find.text(kReissuedKey), findsOneWidget);
      expect(find.textContaining('yerinde yazılmalıdır'), findsOneWidget);
    });

    testWidgets('yeni sahibe devredildi: sahip adı ve etkilenen kullanıcı sayısı yazılır; "Panoyu şimdi bağla" sihirbazı açar', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyResetToReturn = EmergencyResetResult(
        action: 'REASSIGNED',
        deviceUuid: kResetUid,
        homeId: kHomeA,
        affectedUsersCount: 2,
        newOwner: ResetNewOwner.fromJson(const <String, dynamic>{'id': 'u-9', 'full_name': 'Ali Veli'}),
        deviceCredential: const DeviceMqttCredential(
          host: 'mqtt.ornek.test',
          port: 8884,
          username: 'd_h_yeni',
          password: kCredentialPassword,
          topicId: 'h_yeni',
        ),
      );
      await openCard(tester, env);
      await fillValid(tester, owner: 'ali@ornek.test');
      await confirmWithUid(tester);

      expect(find.text('Cihaz Ali Veli adlı yeni sahibe devredildi.'), findsOneWidget);
      expect(find.text('Eski daireden 2 kullanıcının erişimi kaldırıldı.'), findsOneWidget);
      expect(exists('reset_next_step'), isTrue);
      expect(find.textContaining(kCredentialPassword), findsNothing, reason: 'bulut kimliği ekranda gösterilmez');

      await tapKey(tester, 'btn_reset_open_wizard');
      await settle(tester, frames: 20);
      expect(exists('nav_setup_title'), isTrue, reason: 'sihirbaz mevcut cihaz kipinde açıldı');
      final page = tester.widget<ServiceSetupWizardPage>(find.byType(ServiceSetupWizardPage));
      expect(page.initialCredential?.password, kCredentialPassword,
          reason: 'yanıttaki tek seferlik bulut kimliği sihirbaza (yalnızca bellek) aktarılır: 6. adım yeniden üretmez');
      expect(page.startStep, 5);
    });

    testWidgets('sunucu reddederse hata görünür, form korunur ve tekrar denenebilir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyError = const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Cihaz bulunamadı.');
      await openCard(tester, env);
      await fillValid(tester);
      await confirmWithUid(tester);

      expect(exists('reset_error'), isTrue);
      expect(find.text('Cihaz bulunamadı.'), findsOneWidget);
      expect(fieldText(tester, 'field_reset_uid'), kResetUid);
      expect(fieldText(tester, 'field_reset_reason'), kResetReason);

      env.cloud.emergencyError = null;
      await confirmWithUid(tester);
      expect(env.cloud.emergencyResets, hasLength(1));
      expect(find.text('Sıfırlama tamamlandı'), findsOneWidget);
    });

    testWidgets('gönderim sürerken düğme pasiftir ve çift dokunuş tek istek atar', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyGate = Completer<void>();
      await openCard(tester, env);
      await fillValid(tester);
      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      await typeKey(tester, 'field_confirm_phrase', kResetUid);
      await tapKey(tester, 'btn_confirm_destructive');
      await tester.pump();

      expect(buttonEnabled(tester, 'btn_emergency_reset'), isFalse, reason: 'istek sürerken yeniden gönderilemez');
      await tester.tap(find.byKey(const Key('btn_emergency_reset')), warnIfMissed: false);
      await tester.pump();
      env.cloud.emergencyGate!.complete();
      await settle(tester);
      expect(env.cloud.emergencyResets, hasLength(1));
    });
  });

  group('sonucu belirsiz kesinti (yıkıcı işlem körlemesine tekrarlanmaz)', () {
    Future<ServiceHarness> uncertain(WidgetTester tester, Object error) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyError = error;
      await openCard(tester, env);
      await fillValid(tester);
      await confirmWithUid(tester);
      return env;
    }

    testWidgets('ağ kesintisinde "sonuç belirsiz" denir; hata kutusu/"tekrar dene" yok ve sıfırla düğmesi kilitlenir', (tester) async {
      final env = await uncertain(tester, ApiException.network());

      expect(exists('reset_uncertain'), isTrue);
      expect(find.text('Sıfırlamanın sonucu belirsiz'), findsOneWidget);
      expect(find.textContaining('TAMAMLANMIŞ olabilir'), findsOneWidget);
      expect(exists('reset_error'), isFalse, reason: 'normal hata değil, belirsiz sonuç');
      expect(find.textContaining('tekrar deneyin'), findsNothing, reason: 'körlemesine tekrar önerilmez');
      expect(buttonEnabled(tester, 'btn_emergency_reset'), isFalse, reason: 'durum kontrol edilmeden yinelenemez');
      expect(env.cloud.calls.where((c) => c.startsWith('emergencyResetDevice')), hasLength(1));

      await tester.tap(find.byKey(const Key('btn_emergency_reset')), warnIfMissed: false);
      await settle(tester);
      expect(exists('field_confirm_phrase'), isFalse, reason: 'kilitliyken onay penceresi açılmaz');
      expect(env.cloud.calls.where((c) => c.startsWith('emergencyResetDevice')), hasLength(1));
    });

    testWidgets('istemci zaman aşımı da belirsiz sayılır; Durumu Kontrol Et envanterdeki gerçek durumu söyler (stokta)', (tester) async {
      final env = await uncertain(tester, TimeoutException('yanıt gelmedi'));
      expect(exists('reset_uncertain'), isTrue);

      env.cloud.inventory = <InventoryDeviceModel>[inventoryDevice(uid: kResetUid, status: 'IN_STOCK')];
      await tapKey(tester, 'btn_reset_check');
      await settle(tester, frames: 20);
      expect(find.textContaining('Cihaz şu an STOKTA'), findsOneWidget);
      expect(find.textContaining('sıfırlama sunucuda tamamlanmış görünüyor'), findsOneWidget);
      expect(env.cloud.calls.where((c) => c.startsWith('fetchDeviceInventory')), isNotEmpty);
      expect(buttonEnabled(tester, 'btn_emergency_reset'), isFalse, reason: 'kontrolden sonra da bilinçli olarak kimlik değişmeden yinelenmez');
    });

    testWidgets('cihaz hâlâ bir daireye bağlıysa daire adı yazılır ve emin olmadan yinelenmemesi söylenir', (tester) async {
      final env = await uncertain(tester, ApiException.network());
      env.cloud.inventory = <InventoryDeviceModel>[inventoryDevice(uid: kResetUid, status: 'CLAIMED', claimedHome: 'Daire 5')];
      await tapKey(tester, 'btn_reset_check');
      await settle(tester, frames: 20);
      expect(find.textContaining('bir daireye bağlı ("Daire 5")'), findsOneWidget);
      expect(find.textContaining('Emin olmadan yinelemeyin'), findsOneWidget);
    });

    testWidgets('stoğunda olmayan cihazda (servis personeli) durum görülemediği açıkça söylenir', (tester) async {
      final env = await uncertain(tester, ApiException.network());
      env.cloud.inventory = <InventoryDeviceModel>[];
      await tapKey(tester, 'btn_reset_check');
      await settle(tester, frames: 20);
      expect(find.textContaining('durumu görüntülenemiyor'), findsOneWidget);
    });

    testWidgets('durum kontrolü de başarısız olursa ham istisna değil açıklama gösterilir', (tester) async {
      final env = await uncertain(tester, ApiException.network());
      env.cloud.inventoryError = ApiException.network();
      await tapKey(tester, 'btn_reset_check');
      await settle(tester, frames: 20);
      expect(find.textContaining('Durum kontrol edilemedi'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(exists('reset_uncertain'), isTrue);
    });

    testWidgets('başka bir cihaz kimliği yazılınca kilit ve uyarı kalkar', (tester) async {
      await uncertain(tester, ApiException.network());
      await typeKey(tester, 'field_reset_uid', 'AHBU-S3-FFFFFF');
      await settle(tester);
      expect(exists('reset_uncertain'), isFalse);
      expect(buttonEnabled(tester, 'btn_emergency_reset'), isTrue);
    });

    testWidgets('dar ekranda ve büyük yazıda "sonuç belirsiz" kartı ve kontrol sonucu taşma olmadan çizilir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyError = ApiException.network();
      await pumpPage(
        tester,
        env,
        Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: EmergencyResetCard(scanner: fakeScanner(null))))),
        size: const Size(360, 800),
        textScale: 1.5,
      );
      await settle(tester);
      await fillValid(tester);
      await confirmWithUid(tester);
      env.cloud.inventory = <InventoryDeviceModel>[
        inventoryDevice(uid: kResetUid, status: 'CLAIMED', claimedHome: 'Çok uzun bir daire adı: Mavi Vadi Sitesi A Blok Kat 12 Daire 47'),
      ];
      await tapKey(tester, 'btn_reset_check');
      await settle(tester, frames: 20);
      expect(exists('reset_uncertain'), isTrue);
      expect(find.textContaining('bir daireye bağlı'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'RenderFlex taşması yok');
    });

    testWidgets('sunucunun açık hata yanıtı (500) belirsiz sayılmaz: normal hata görünür ve tekrar denenebilir', (tester) async {
      await uncertain(tester, const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu hatası.'));
      expect(exists('reset_uncertain'), isFalse);
      expect(exists('reset_error'), isTrue);
      expect(buttonEnabled(tester, 'btn_emergency_reset'), isTrue);
    });
  });

  group('yetki', () {
    testWidgets('geçici servis oturumu acil sıfırlama yapamaz: yetki hatası görünür ve istek atılmaz', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await fillValid(tester);
      await tapKey(tester, 'btn_emergency_reset');
      await settle(tester);
      expect(find.text('Acil sıfırlama için yetkiniz yok.'), findsOneWidget);
      expect(exists('field_confirm_phrase'), isFalse);
      expect(env.cloud.emergencyResets, isEmpty);
    });

    testWidgets('süper yönetici de acil sıfırlama yapabilir', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);
      await fillValid(tester);
      await confirmWithUid(tester);
      expect(env.cloud.emergencyResets, hasLength(1));
    });

    testWidgets('dar ekranda ve büyük yazıda taşma olmadan çalışır', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: kResetUid,
        setupPin: kReissuedPin,
        warnings: <String>['Çok uzun bir uyarı metni ' 'x' 'y' 'z' ' bu satır birkaç satıra yayılacak kadar uzundur ve taşmamalıdır.'],
        partial: true,
      );
      await pumpPage(
        tester,
        env,
        Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: EmergencyResetCard(scanner: fakeScanner(null))))),
        size: const Size(360, 800),
        textScale: 1.5,
      );
      await settle(tester);
      await fillValid(tester);
      await confirmWithUid(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Sıfırlama kısmen tamamlandı'), findsOneWidget);
    });
  });
}
