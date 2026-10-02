import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Servis sorumlusu: karekodla cihazı tanıma (2. adım), müşteri + onay kodu (3. adım) ve daireye bağlama
/// (4. adım) - arayüzde, hata yollarıyla (yanlış PIN/kod, kilit, hız sınırı, kısmi başarı) ve rol matrisiyle.

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> toStep2(WidgetTester tester, ServiceHarness env, {Future<String?> Function(BuildContext, {required String title, required String hint})? scanner}) async {
  await openWizard(tester, env, scanner: scanner);
  await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
  await goNext(tester, env);
  expect(exists('setup_step_2'), isTrue);
}

Future<void> scanAccepted(WidgetTester tester, ServiceHarness env) async {
  await tapKey(tester, 'btn_scan_label');
  await pumpUntil(tester, env, () => exists('step2_accepted_card'));
}

Future<void> toStep3(WidgetTester tester, ServiceHarness env) async {
  await toStep2(tester, env);
  await scanAccepted(tester, env);
  await goNext(tester, env);
  expect(exists('setup_step_3'), isTrue);
}

Future<void> sendCode(WidgetTester tester, ServiceHarness env, {String customer = kCustomerEmail}) async {
  await typeKey(tester, 'field_customer', customer);
  await tapKey(tester, 'btn_send_otp');
  await pumpUntil(tester, env, () => exists('field_otp'));
}

Future<void> toStep4(WidgetTester tester, ServiceHarness env, {String otp = kCustomerOtp}) async {
  await toStep3(tester, env);
  await sendCode(tester, env);
  await typeKey(tester, 'field_otp', otp);
  await goNext(tester, env);
  expect(exists('setup_step_4'), isTrue);
}

Future<void> claimNow(WidgetTester tester, ServiceHarness env) async {
  await tapKey(tester, 'btn_claim');
  await tester.pump(const Duration(milliseconds: 300));
  await tapKey(tester, 'btn_claim_confirm');
}

void main() {
  group('2. adım: cihazı tanıma', () {
    testWidgets('etiket okutulunca cihaz tanınır, PIN maskelenir ve stoktaki cihaz kuruluma uygun görünür', (tester) async {
      final env = await serviceHarness(inventoryListed: true, flush: () async {});
      addTearDown(env.dispose);
      await toStep2(tester, env);
      expect(buttonEnabled(tester, 'setup_continue'), isFalse, reason: 'cihaz tanıtılmadan devam edilemez');

      await scanAccepted(tester, env);
      await pumpUntil(tester, env, () => find.textContaining('stokta görünüyor').evaluate().isNotEmpty);
      expect(find.textContaining(kDeviceUid), findsWidgets);
      expect(find.textContaining(kSetupPin), findsNothing, reason: 'PIN hiçbir yerde açık yazılmaz');
      expect(find.textContaining('••••••'), findsOneWidget);
    });

    testWidgets('başka siteye ait ya da bozuk karekod reddedilir ve ne yapılacağı yazılır', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep2(tester, env, scanner: fakeScanner('https://kotu-site.example/claim?uid=$kDeviceUid&pin=$kSetupPin'));

      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => exists('setup_retry') || find.text('Neden?').evaluate().isNotEmpty);
      expect(exists('step2_accepted_card'), isFalse);
      expect(find.text('Ne yapmalıyım?'), findsOneWidget);
      expect(buttonEnabled(tester, 'setup_continue'), isFalse);
    });

    testWidgets('karekod okunamıyorsa elle yazılan seri no ve PIN doğrulanır, geçerliyse alanlar temizlenir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep2(tester, env);

      await tapKey(tester, 'btn_toggle_manual');
      await typeKey(tester, 'field_uid', 'bozuk');
      await typeKey(tester, 'field_pin', '12');
      await tapKey(tester, 'btn_submit_manual');
      await tester.pump(const Duration(milliseconds: 100));
      expect(exists('step2_accepted_card'), isFalse);
      expect(find.text('Ne yapmalıyım?'), findsOneWidget);

      await typeKey(tester, 'field_uid', kDeviceUid.toLowerCase());
      await typeKey(tester, 'field_pin', kSetupPin);
      await tapKey(tester, 'btn_submit_manual');
      await pumpUntil(tester, env, () => exists('step2_accepted_card'));
      expect(find.textContaining(kSetupPin), findsNothing);
    });

    testWidgets('süper yönetici: cihaz zaten devredeyse (CLAIMED) ilerleyemez ve nedeni görür', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.inventory = <InventoryDeviceModel>[inventoryDevice(status: 'CLAIMED', claimedHome: 'Başka Daire')];
      await toStep2(tester, env);

      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => find.text('Ne yapmalıyım?').evaluate().isNotEmpty || buttonEnabled(tester, 'setup_continue'));
      expect(buttonEnabled(tester, 'setup_continue'), isFalse, reason: 'devredeki cihaz yeniden bağlanamaz');
      expect(find.text('Ne yapmalıyım?'), findsOneWidget);
    });

    testWidgets('Başka Cihaz Seç tanınan cihazı unutturur', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep2(tester, env);
      await scanAccepted(tester, env);
      await tapKey(tester, 'btn_reset_label');
      await tester.pump();
      expect(exists('step2_accepted_card'), isFalse);
      expect(exists('btn_scan_label'), isTrue);
    });
  });

  group('3. adım: müşteri ve onay kodu', () {
    testWidgets('boş ve geçersiz müşteri bilgisi hata verir; sunucudan kod istenmez', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep3(tester, env);

      await tapKey(tester, 'btn_send_otp');
      await tester.pump();
      expect(env.cloud.otpRequests, 0);
      await typeKey(tester, 'field_customer', 'bu bir e-posta değil');
      await tapKey(tester, 'btn_send_otp');
      await tester.pump();
      expect(env.cloud.otpRequests, 0);
      expect(exists('otp_sent_card'), isFalse);
    });

    testWidgets('teknisyen kendi e-postasını ya da telefonunu yazarsa engellenir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep3(tester, env);

      await typeKey(tester, 'field_customer', 'SERVIS@Ornek.Test');
      await tapKey(tester, 'btn_send_otp');
      await tester.pump();
      expect(find.textContaining('Kendi hesabınız adına'), findsWidgets);
      await typeKey(tester, 'field_customer', '0555 111 22 33');
      await tapKey(tester, 'btn_send_otp');
      await tester.pump();
      expect(find.textContaining('Kendi hesabınız adına'), findsWidgets);
      expect(env.cloud.otpRequests, 0);
    });

    testWidgets('kod gönderilince kod alanı ve geçerlilik süresi görünür; devam kod yazılana kadar kapalıdır', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep3(tester, env);
      await sendCode(tester, env);

      expect(env.cloud.otpRequests, 1);
      expect(exists('otp_sent_card'), isTrue);
      expect(find.textContaining('Kodun geçerlilik süresi'), findsOneWidget);
      expect(buttonEnabled(tester, 'setup_continue'), isFalse);
      await typeKey(tester, 'field_otp', '12');
      expect(buttonEnabled(tester, 'setup_continue'), isFalse, reason: '6 hane tamamlanmadan devam edilemez');
      await typeKey(tester, 'field_otp', kCustomerOtp);
      await pumpUntil(tester, env, () => continueEnabled(tester));
    });

    testWidgets('Yeniden gönder düğmesi sunucunun verdiği süre dolana kadar kapalıdır', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep3(tester, env);
      await sendCode(tester, env);

      expect(buttonEnabled(tester, 'btn_send_otp'), isFalse);
      expect(find.textContaining('Yeniden gönder:'), findsOneWidget);
      env.clock.advance(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
      await pumpUntil(tester, env, () => buttonEnabled(tester, 'btn_send_otp'));
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => env.cloud.otpRequests == 2);
    });

    testWidgets('kod isteği hız sınırına takılırsa neden ve bekleme süresi açıklanır, kod alanı açılmaz', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.cloud.otpError = const ApiException(
        statusCode: 429,
        code: 'RATE_LIMITED',
        message: 'Çok fazla istek gönderildi. Lütfen biraz bekleyin.',
        retryAfter: Duration(minutes: 5),
      );
      await toStep3(tester, env);
      await typeKey(tester, 'field_customer', kCustomerEmail);
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => find.text('Ne yapmalıyım?').evaluate().isNotEmpty);
      expect(exists('field_otp'), isFalse);
      expect(find.textContaining('5 dakika'), findsWidgets);
    });

    testWidgets('Müşteriyi değiştir kodu temizler ve yeni müşteriye yeniden kod gönderilebilir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep3(tester, env);
      await sendCode(tester, env);
      await typeKey(tester, 'field_otp', kCustomerOtp);

      await tapKey(tester, 'btn_change_customer');
      await tester.pump();
      expect(exists('field_otp'), isFalse);
      expect(buttonEnabled(tester, 'setup_continue'), isFalse);
      await typeKey(tester, 'field_customer', 'baska@ornek.test');
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => env.cloud.otpRequests == 2);
    });
  });

  group('4. adım: daireye bağlama (claim)', () {
    testWidgets('özet doğrudur; onay penceresinden vazgeçilirse sunucuya istek atılmaz', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep4(tester, env);

      expect(find.descendant(of: find.byKey(const Key('claim_summary_card')), matching: find.textContaining(kDeviceUid)), findsOneWidget);
      await tapKey(tester, 'btn_claim');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Cihaz daireye bağlansın mı?'), findsOneWidget);
      await tapKey(tester, 'btn_claim_cancel');
      await tester.pump(const Duration(milliseconds: 300));
      expect(env.cloud.claimCalls, 0);
    });

    testWidgets('yanlış kurulum PIN\'i: kalan deneme hakkı yazılır, 2. adıma dönüş önerilir, devam kapalı kalır', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.cloud.expectedPin = '111111'; // etiketteki PIN sunucudakiyle uyuşmuyor
      await toStep4(tester, env);

      await claimNow(tester, env);
      await pumpUntil(tester, env, () => exists('setup_fix_step'), reason: 'hata kutusu/adıma dönüş çıkmadı');
      expect(env.cloud.claimCalls, 1);
      expect(find.textContaining('Kalan deneme hakkı'), findsWidgets);
      expect(find.text('2. adıma dön'), findsOneWidget);
      expect(buttonEnabled(tester, 'setup_continue'), isFalse);
      expect(exists('claim_result_card'), isFalse);

      await tapKey(tester, 'setup_fix_step');
      await tester.pump(const Duration(milliseconds: 400));
      expect(exists('setup_step_2'), isTrue);
      expect(exists('step2_accepted_card'), isFalse, reason: 'yanlış PIN bellekten silinir; yeniden okutulmalı');
    });

    testWidgets('yanlış müşteri kodu: 3. adıma dönüş önerilir ve girilen kod temizlenir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep4(tester, env, otp: '000000');

      await claimNow(tester, env);
      await pumpUntil(tester, env, () => exists('setup_fix_step'));
      expect(find.text('3. adıma dön'), findsOneWidget);
      await tapKey(tester, 'setup_fix_step');
      await tester.pump(const Duration(milliseconds: 400));
      expect(exists('setup_step_3'), isTrue);
    });

    testWidgets('PIN kilitlendiyse (423) bekleme süresi gösterilir ve yeniden deneme önerilmez', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep4(tester, env);
      env.cloud.claimErrorOnce = const ApiException(
        statusCode: 423,
        code: 'PIN_LOCKED',
        message: 'Çok fazla hatalı deneme. Lütfen biraz bekleyin.',
        retryAfter: Duration(minutes: 15),
      );

      await claimNow(tester, env);
      await pumpUntil(tester, env, () => find.text('Ne yapmalıyım?').evaluate().isNotEmpty);
      expect(find.textContaining('15 dakika'), findsWidgets);
      expect(exists('claim_result_card'), isFalse);
    });

    testWidgets('başarıda sonuç kartı ve kısmi başarı uyarıları gösterilir; claim edilen daire aktif daire olmaz', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.cloud.claimWarnings = const <String>['Yerel anahtar panoya iletilemedi; yerinde yazılmalı.'];
      await toStep4(tester, env);

      await typeKey(tester, 'field_home_name', 'Daire 5');
      await claimNow(tester, env);
      await pumpUntil(tester, env, () => exists('claim_result_card'));
      expect(exists('claim_warnings_card'), isTrue);
      expect(find.text('Yerel anahtar panoya iletilemedi; yerinde yazılmalı.'), findsOneWidget);
      expect(env.state.activeHome, isNull, reason: 'sihirbaz aktif evi değiştirmez');
      await pumpUntil(tester, env, () => continueEnabled(tester));
    });

    testWidgets('claim sonrası PIN ve müşteri kodu hiçbir kalıcı kayıtta yer almaz', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await toStep4(tester, env);
      await claimNow(tester, env);
      await pumpUntil(tester, env, () => exists('claim_result_card'));
      await goNext(tester, env);

      final prefs = await dumpPrefs();
      for (final secret in <String>[kSetupPin, kCustomerOtp, kCredentialPassword, kLocalKey]) {
        expect(prefs, isNot(contains(secret)));
      }
    });
  });

  group('rol matrisi', () {
    testWidgets('geçici servis oturumunda müşteri ve claim adımları atlanır: dairedeki pano seçilir ve 5. adıma geçilir', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await toStep2(tester, env);

      expect(find.textContaining('claim) yapılmaz'), findsOneWidget);
      await pumpUntil(tester, env, () => exists('card_device_$kDeviceUid'), reason: 'dairedeki pano listelenmedi');
      await pumpUntil(tester, env, () => continueEnabled(tester), reason: 'tek pano otomatik seçilir');
      await goNext(tester, env);
      expect(exists('setup_step_5'), isTrue, reason: '3. ve 4. adım atlanır');
      expect(env.cloud.claimCalls, 0);
      expect(env.cloud.otpRequests, 0);
    });

    testWidgets('geçici servis oturumunda dairede birden çok pano varsa seçmeden devam edilemez ve seçilen pano hedef olur', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.devicesByHome[kClaimedHome] = const <DeviceInfo>[
        DeviceInfo(deviceUuid: kDeviceUid, name: 'Salon', online: true),
        DeviceInfo(deviceUuid: 'AHBU-S3-B2B2B2', name: 'Mutfak', online: false),
      ];
      await toStep2(tester, env);
      await pumpUntil(tester, env, () => exists('card_device_AHBU-S3-B2B2B2'));
      expect(buttonEnabled(tester, 'setup_continue'), isFalse, reason: 'pano seçilmeden devam edilemez');

      await tapKey(tester, 'card_device_AHBU-S3-B2B2B2');
      await pumpUntil(tester, env, () => continueEnabled(tester));
      await goNext(tester, env);
      expect(exists('setup_step_5'), isTrue);
      expect(find.textContaining('AHBU-B2B2B2'), findsWidgets, reason: 'kurulum ağı adı seçilen panoya göredir');
    });

    testWidgets('servis personeli ve süper yönetici müşteriye bağlama akışını görür', (tester) async {
      for (final role in ['staff', 'super']) {
        final env = await serviceHarness(role: role, flush: () async {});
        addTearDown(env.dispose);
        await toStep2(tester, env);
        expect(exists('btn_scan_label'), isTrue, reason: role);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
