import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/emergency_reset_card.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart' show kHomeA;
import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis paneli acil sıfırlama kartı (`EmergencyResetCard` + `EmergencyResetResultDialog`):
///
/// * SERVIS-01 (D13): sunucu pano çevrimdışıyken (ya da bulut bağlantısı yokken) yeni yerel anahtarı **bekleyen** olarak
///   işaretler (`local_key_publish: 'pending'`, yanıtta `local_key` YOK) ve pano buluta bağlanınca otomatik iletir; o
///   zamana kadar panonun mevcut anahtarı geçerlidir. Sonuç diyaloğu bunu bilgi notu olarak söyler; uygulanamaz "panoya
///   yerinde yazılmalıdır" yönergesi kalkar. ESKİ sunucu yanıtı (`skipped_offline`/`failed` + `local_key`) gelirse
///   anahtar gösterilebilir ama yönerge gerçek kurtarma yoludur: seri konsolda RESETKEY + FACTORYINIT (fabrika aracı).
/// * SERVIS-07 (D15): kalıcı servis personeli (süper olmayan) yalnız son 72 saatte kurduğu/devraldığı dairelerin
///   panolarını sıfırlayabilir (sunucu kuralı); kart bunu söyler, 403 gelince yönlendirme hata kutusunda görünür.
const String kUid = 'AHBU-S3-A1B2C3';
const String kReason = 'Kiracı tahliye edildi, tapu teyit edildi.';
const String kScopeNote = 'Servis personeli yalnız son 72 saat içinde kurduğu ya da devraldığı dairelerin panolarını '
    'sıfırlayabilir; diğer daireler için süper yöneticiye başvurun.';

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> openCard(WidgetTester tester, ServiceHarness env) async {
  await pumpPage(
    tester,
    env,
    Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: EmergencyResetCard(scanner: fakeScanner(null))))),
    size: const Size(900, 2400),
  );
  await settle(tester);
}

Future<void> resetWith(WidgetTester tester, ServiceHarness env, {String owner = ''}) async {
  await typeKey(tester, 'field_reset_uid', kUid);
  await typeKey(tester, 'field_reset_reason', kReason);
  if (owner.isNotEmpty) await typeKey(tester, 'field_reset_owner', owner);
  await tapKey(tester, 'btn_emergency_reset');
  await settle(tester);
  await typeKey(tester, 'field_confirm_phrase', kUid);
  await tapKey(tester, 'btn_confirm_destructive');
  await settle(tester);
}

const DeviceMqttCredential kCredential = DeviceMqttCredential(
  host: 'mqtt.ornek.test',
  port: 8884,
  username: 'd_h_yeni',
  password: kCredentialPassword,
  topicId: 'h_yeni',
);

void main() {
  setUp(SecretClipboard.reset);

  group('EmergencyResetResult (yanıt modeli): local_key_publish = pending', () {
    test('pending: anahtar bekliyor, yanıtta local_key yok, elle yazılacak anahtar YOK', () {
      final r = EmergencyResetResult.fromJson(const <String, dynamic>{
        'action': 'REASSIGNED',
        'device_uuid': kUid,
        'home_id': kHomeA,
        'local_key_publish': 'pending',
        'child_lock_reset': 'published',
        'new_owner': <String, dynamic>{'id': 'u-9', 'full_name': 'Ali Veli'},
      });
      expect(r.localKeyPublish, 'pending');
      expect(r.localKeyPending, isTrue);
      expect(r.localKey, isNull);
      expect(r.needsManualLocalKey, isFalse);
    });

    test('sözleşmeye aykırı pending + local_key: anahtar elle yazılacak SAYILMAZ (sunucu otomatik iletecek)', () {
      final r = EmergencyResetResult.fromJson(const <String, dynamic>{
        'action': 'UNCLAIMED',
        'device_uuid': kUid,
        'local_key_publish': 'pending',
        'local_key': 'beklenmeyen-anahtar-1',
      });
      expect(r.localKeyPending, isTrue);
      expect(r.needsManualLocalKey, isFalse);
    });

    test('eski sunucu yanıtı (skipped_offline + local_key): bekleyen değil, elle (seri konsol) yazılacak', () {
      final r = EmergencyResetResult.fromJson(const <String, dynamic>{
        'action': 'UNCLAIMED',
        'device_uuid': kUid,
        'local_key_publish': 'skipped_offline',
        'local_key': 'cihaza-yazilacak-anahtar-1',
      });
      expect(r.localKeyPending, isFalse);
      expect(r.needsManualLocalKey, isTrue);
    });
  });

  group('SERVIS-01: sonuç diyaloğu', () {
    testWidgets('pending + devir: bilgi notu (otomatik iletilecek, mevcut anahtar geçerli, "Panoyu şimdi bağla"); '
        'anahtar satırı ve "yerinde yazılmalıdır" yönergesi YOK', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyResetToReturn = EmergencyResetResult(
        action: 'REASSIGNED',
        deviceUuid: kUid,
        homeId: kHomeA,
        newOwner: const ResetNewOwner(id: 'u-9', fullName: 'Ali Veli'),
        deviceCredential: kCredential,
        localKeyPublish: 'pending',
        childLockReset: 'published',
      );
      await openCard(tester, env);
      await resetWith(tester, env, owner: 'ali@ornek.test');

      expect(exists('reset_key_pending'), isTrue);
      final note = find.descendant(of: find.byKey(const Key('reset_key_pending')), matching: find.byType(Text));
      final text = tester.widgetList<Text>(note).map((t) => t.data ?? '').join(' ');
      expect(text, contains('otomatik iletilecek'));
      expect(text, contains('mevcut anahtarı geçerlidir'));
      expect(text, contains('"Panoyu şimdi bağla"'));
      expect(exists('btn_copy_reset_key'), isFalse, reason: 'yanıtta anahtar yok: gösterilecek/kopyalanacak anahtar yok');
      expect(find.textContaining('yerinde'), findsNothing, reason: 'uygulanamaz "yerinde yaz" yönergesi kalktı');
      expect(find.textContaining('iletilemedi'), findsNothing, reason: 'bekleyen anahtar "iletilemedi" uyarısı değildir');
      expect(exists('btn_reset_open_wizard'), isTrue, reason: 'sihirbaz 6. adımda sunucunun verdiği mevcut anahtarla çalışır');
    });

    testWidgets('pending + stoğa alma: bilgi notu var, "Panoyu şimdi bağla" anılmaz (sihirbaz düğmesi yok)', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: kUid,
        setupPin: kReissuedPin,
        localKeyPublish: 'pending',
      );
      await openCard(tester, env);
      await resetWith(tester, env);

      expect(exists('reset_key_pending'), isTrue);
      expect(find.textContaining('otomatik iletilecek'), findsOneWidget);
      expect(find.textContaining('Panoyu şimdi bağla'), findsNothing);
      expect(exists('btn_reset_open_wizard'), isFalse);
      expect(exists('btn_copy_reset_key'), isFalse);
    });

    testWidgets('ESKİ sunucu yanıtı (skipped_offline + local_key): anahtar bir kez gösterilir; yönerge seri konsolda '
        'RESETKEY + FACTORYINIT (fabrika aracı)', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: kUid,
        setupPin: kReissuedPin,
        localKey: kReissuedKey,
        localKeyPublish: 'skipped_offline',
        partial: true,
      );
      await openCard(tester, env);
      await resetWith(tester, env);

      expect(find.text(kReissuedKey), findsOneWidget);
      expect(exists('btn_copy_reset_key'), isTrue);
      expect(exists('reset_key_pending'), isFalse);
      final hint = tester.widget<Text>(find.byKey(const Key('reset_key_manual_hint'))).data!;
      expect(hint, contains('seri konsolda'));
      expect(hint, contains('RESETKEY'));
      expect(hint, contains('FACTORYINIT'));
      expect(hint, contains('fabrika aracı'));
      expect(find.textContaining('yerinde yazılmalıdır'), findsNothing);
    });
  });

  group('SERVIS-07: servis personeli kısıt notu', () {
    testWidgets('kalıcı servis personeli (süper değil): kartta 72 saat kısıt notu görünür', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);

      expect(exists('reset_staff_scope_note'), isTrue);
      expect(find.text(kScopeNote), findsOneWidget);
    });

    testWidgets('süper yönetici: kısıt notu YOK (her cihazı sıfırlayabilir)', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      await openCard(tester, env);

      expect(exists('reset_staff_scope_note'), isFalse);
      expect(find.textContaining('son 72 saat'), findsNothing);
    });

    testWidgets('servis personeline 403: sunucu mesajı + hata kutusunda süper yönetici yönlendirmesi (tek kez görünür)',
        (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyError = const ApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: 'Bu cihazın dairesinde servis yetkiniz yok. Süper yönetici ile iletişime geçin.',
      );
      await openCard(tester, env);
      await resetWith(tester, env);

      expect(exists('reset_error'), isTrue);
      expect(find.text('Bu cihazın dairesinde servis yetkiniz yok. Süper yönetici ile iletişime geçin.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('reset_error')), matching: find.text(kScopeNote)), findsOneWidget,
          reason: 'yönlendirme hatanın yanında');
      expect(find.text(kScopeNote), findsOneWidget, reason: 'aynı not ekranda iki kez yazılmaz');
      expect(buttonEnabled(tester, 'btn_emergency_reset'), isTrue, reason: 'işlem yapılmadığı biliniyor: başka cihaz denenebilir');

      // Sonraki denemede (başka hata) yönlendirme hata kutusundan kalkar, not yerine döner.
      env.cloud.emergencyError = const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Cihaz bulunamadı.');
      await resetWith(tester, env);
      expect(find.text('Cihaz bulunamadı.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('reset_error')), matching: find.text(kScopeNote)), findsNothing);
      expect(exists('reset_staff_scope_note'), isTrue);
    });

    testWidgets('süper yöneticiye 403: kısıt yönlendirmesi EKLENMEZ (yalnız sunucu mesajı)', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyError = const ApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: 'Bu cihaz iptal edilmiş veya askıya alınmış; yalnızca süper yönetici sıfırlayabilir.',
      );
      await openCard(tester, env);
      await resetWith(tester, env);

      expect(exists('reset_error'), isTrue);
      expect(find.textContaining('son 72 saat'), findsNothing);
    });

    testWidgets('dar ekranda ve büyük yazıda kısıt notu ve 403 yönlendirmesi taşma olmadan çizilir', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.emergencyError = const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Yetkiniz yok.');
      await pumpPage(
        tester,
        env,
        Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: EmergencyResetCard(scanner: fakeScanner(null))))),
        size: const Size(360, 800),
        textScale: 1.5,
      );
      await settle(tester);
      expect(exists('reset_staff_scope_note'), isTrue);
      await resetWith(tester, env);
      expect(exists('reset_error'), isTrue);
      expect(tester.takeException(), isNull, reason: 'RenderFlex taşması yok');
    });
  });
}
