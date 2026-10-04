import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/emergency_reset_card.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart' show kHomeA;
import 'f_support.dart';
import 'f_widget_support.dart';

/// Acil sıfırlama sonuç diyaloğu (`EmergencyResetResultDialog`), GERÇEK sözleşme yanıtlarıyla:
///
/// * M2-F2 / KAÇAN: bekleyen yerel anahtar (`local_key_publish: 'pending'`) hata değil bilgi notudur. Yeni sunucu bu
///   durumda uyarı eklemez ve yalnız bu yüzden `partial` dönmez; ESKİ sunucu ise `warnings` içine bekleyen anahtar
///   uyarısını koyup `partial: true` döner. İki durumda da başlık "kısmen tamamlandı" OLMAZ (başka gerçek uyarı yoksa)
///   ve aynı bilgi iki kez (turuncu uyarı + mavi kart) gösterilmez.
/// * M4-02: süper yönetici hesabına cihaz anahtarı verilmez ve süperin devri personele daire yetkisi vermez: süperde
///   "Panoyu şimdi bağla" düğmesi, "devam edebilirsiniz" cümlesi ve sonraki adım kartı yerine servis PIN yolu yazılır.
const String kUid = 'AHBU-S3-A1B2C3';
const String kReason = 'Kiracı tahliye edildi, tapu teyit edildi.';

/// Sunucunun (eski sürüm) bekleyen anahtar uyarısı (device_service.js LOCAL_KEY_PENDING_WARNING).
const String kServerPendingWarning = 'Yeni yerel anahtar şu an panoya iletilemedi (pano ya da bulut bağlantısı yok). '
    'Pano buluta bağlandığında otomatik iletilecek; o zamana kadar panonun mevcut anahtarı geçerli kalır.';
const String kChildLockWarning = 'Pano çevrimdışı; çocuk kilidi sıfırlanamadı. Pano yerelde kilitli kalmış olabilir.';
const String kSuperNote = 'Süper yönetici hesabına cihaz anahtarı verilmez ve bu devir servis personeline daire '
    "yetkisi vermez. Panoyu bağlamak için yeni sahibin uygulamasından servis PIN'i alınıp servis girişiyle sihirbaz "
    'açılmalı.';

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

String titleText(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('reset_result_title'))).data!;

EmergencyResetResult resultFrom(Map<String, dynamic> extra) => EmergencyResetResult.fromJson(<String, dynamic>{
      'action': 'REASSIGNED',
      'device_uuid': kUid,
      'home_id': kHomeA,
      'new_owner': <String, dynamic>{'id': 'u-9', 'full_name': 'Ali Veli'},
      'local_key_publish': 'pending',
      ...extra,
    });

Future<void> showResult(WidgetTester tester, EmergencyResetResult result, {String role = 'staff'}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  addTearDown(env.dispose);
  env.cloud.emergencyResetToReturn = result;
  await pumpPage(
    tester,
    env,
    Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: EmergencyResetCard(scanner: fakeScanner(null))))),
    size: const Size(900, 2400),
  );
  await settle(tester);
  await typeKey(tester, 'field_reset_uid', kUid);
  await typeKey(tester, 'field_reset_reason', kReason);
  await typeKey(tester, 'field_reset_owner', 'ali@ornek.test');
  await tapKey(tester, 'btn_emergency_reset');
  await settle(tester);
  await typeKey(tester, 'field_confirm_phrase', kUid);
  await tapKey(tester, 'btn_confirm_destructive');
  await settle(tester);
}

void main() {
  setUp(SecretClipboard.reset);

  group('M2-F2: bekleyen anahtar gerçek sözleşme yanıtıyla', () {
    testWidgets('yalnız pending (partial:false, uyarı yok): başlık "tamamlandı", kısmi kartı ve uyarı satırı yok, '
        'not bir kez', (tester) async {
      await showResult(tester, resultFrom(<String, dynamic>{'child_lock_reset': 'published', 'partial': false}));

      expect(titleText(tester), 'Sıfırlama tamamlandı');
      expect(exists('reset_partial'), isFalse);
      expect(exists('reset_warning_0'), isFalse);
      expect(exists('reset_key_pending'), isTrue);
      expect(find.textContaining('otomatik ilet'), findsOneWidget, reason: 'aynı bilgi iki kez gösterilmez');
      expect(find.textContaining('iletilemedi'), findsNothing);
    });

    testWidgets('pending + çocuk kilidi skipped_offline + onun uyarısı + partial:true: başlık kısmen (çocuk kilidi '
        'yüzünden), bekleyen anahtar yalnız mavi kartta', (tester) async {
      await showResult(
        tester,
        resultFrom(<String, dynamic>{
          'child_lock_reset': 'skipped_offline',
          'warnings': <String>[kChildLockWarning],
          'partial': true,
        }),
      );

      expect(titleText(tester), 'Sıfırlama kısmen tamamlandı');
      expect(exists('reset_partial'), isTrue);
      expect(tester.widget<Text>(find.descendant(of: find.byKey(const Key('reset_warning_0')), matching: find.byType(Text))).data,
          kChildLockWarning);
      expect(exists('reset_warning_1'), isFalse);
      expect(exists('reset_key_pending'), isTrue);
      expect(find.textContaining('otomatik ilet'), findsOneWidget, reason: 'bekleyen anahtar yalnız mavi kartta');
    });

    testWidgets('ESKİ sunucu (pending + warnings içinde bekleyen anahtar uyarısı + partial:true): çift gösterim yok, '
        'başlık "tamamlandı"', (tester) async {
      await showResult(
        tester,
        resultFrom(<String, dynamic>{
          'child_lock_reset': 'published',
          'warnings': <String>[kServerPendingWarning],
          'partial': true,
        }),
      );

      expect(titleText(tester), 'Sıfırlama tamamlandı');
      expect(exists('reset_partial'), isFalse);
      expect(exists('reset_warning_0'), isFalse);
      expect(exists('reset_key_pending'), isTrue);
      expect(find.textContaining('otomatik ilet'), findsOneWidget);
      expect(find.textContaining('iletilemedi'), findsNothing);
    });

    testWidgets('ESKİ sunucu (pending uyarısı + çocuk kilidi uyarısı): yalnız çocuk kilidi uyarı satırı kalır', (tester) async {
      await showResult(
        tester,
        resultFrom(<String, dynamic>{
          'child_lock_reset': 'skipped_offline',
          'warnings': <String>[kChildLockWarning, kServerPendingWarning],
          'partial': true,
        }),
      );

      expect(titleText(tester), 'Sıfırlama kısmen tamamlandı');
      expect(exists('reset_warning_0'), isTrue);
      expect(exists('reset_warning_1'), isFalse);
      expect(find.textContaining('otomatik ilet'), findsOneWidget);
    });
  });

  group('M4-02: süper yöneticinin devri', () {
    testWidgets('süper + REASSIGNED + pending: "Panoyu şimdi bağla" düğmesi, devam cümlesi ve sonraki adım kartı YOK; '
        'servis PIN yolu yazılır', (tester) async {
      await showResult(tester, resultFrom(<String, dynamic>{'child_lock_reset': 'published'}), role: 'super');

      expect(exists('btn_reset_open_wizard'), isFalse);
      expect(find.textContaining('Panoyu şimdi bağla'), findsNothing);
      expect(find.textContaining('devam edebilirsiniz'), findsNothing);
      expect(exists('reset_next_step'), isFalse);
      expect(exists('reset_super_note'), isTrue);
      expect(find.text(kSuperNote), findsOneWidget);
      expect(exists('reset_key_pending'), isTrue, reason: 'bekleyen anahtar bilgisi yine verilir');
    });

    testWidgets('servis personeli + REASSIGNED + pending: düğme ve devam cümlesi var, süper notu YOK', (tester) async {
      await showResult(tester, resultFrom(<String, dynamic>{'child_lock_reset': 'published'}));

      expect(exists('btn_reset_open_wizard'), isTrue);
      expect(find.textContaining('devam edebilirsiniz'), findsOneWidget);
      expect(exists('reset_next_step'), isTrue);
      expect(exists('reset_super_note'), isFalse);
    });
  });
}
