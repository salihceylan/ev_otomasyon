import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// PF-42 (akıcılık/kilitlenmeme, dalga 5a): claim yanıtı **kaybolursa** (istek sunucuda tamamlandı, telefon yanıtı
/// alamadı) kör "Tekrar dene" kurulumu çıkmaza sokuyordu: sunucu idempotent değildir ve PIN/OTP tek kullanımlıktır,
/// ikinci POST `409` verir; hedef atanmadığı için ilerleme kaydı da yazılmaz.
///
/// Sonucu belirsiz kesintide (`UncertainOutcomeCard.isUncertain`) sonraki claim/tekrar deneme ÖNCE cihazın hesaba
/// açık bir dairede olup olmadığını sunucudan doğrular; bulursa POST göndermeden hedefi atar.

/// Claim adımına (4) gelmiş denetleyici.
Future<ServiceSetupController> atClaimStep(ServiceHarness env) async {
  final c = await startedController(env);
  c.continueNext();
  expect(await c.identify.acceptLabel(kLabelQr), isTrue);
  c.continueNext();
  expect(await c.customer.sendCode(kCustomerEmail), isTrue);
  c.customer.setCode(kCustomerOtp);
  c.continueNext();
  expect(c.currentStep, SetupSteps.claim);
  return c;
}

void main() {
  group('PF-42: yanıtı kaybolan claim', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await atClaimStep(env);
    });
    tearDown(() => env.dispose());

    test('tekrar dene, ikinci POST göndermeden cihazı sunucudan bulur ve hedefi atar (claim tek kez gönderilir)', () async {
      env.cloud.claimLosesResponseOnce = true;
      expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);
      expect(c.claim.problem!.kind, SetupProblemKind.network);
      expect(c.claim.canRetry, isTrue);
      expect(env.cloud.claimCalls, 1);
      expect(env.cloud.claimApplied, isTrue, reason: 'sunucu claim\'i tamamladı, yanıt kayboldu');
      expect(c.target, isNull, reason: 'yanıt kayboldu: ev kimliği henüz bilinmiyor');
      expect(c.identify.hasPin, isTrue, reason: 'gizli girdiler korunur (tekrar denenebilsin)');
      expect(c.customer.hasCode, isTrue);

      await c.claim.retry();

      expect(env.cloud.claimCalls, 1, reason: 'sunucu idempotent değil: ikinci claim POST\'u gönderilmemeli');
      expect(c.claim.isComplete, isTrue);
      expect(c.claim.problem, isNull);
      expect(c.target!.homeId, kClaimedHome);
      expect(c.target!.deviceUuid, kDeviceUid);
      expect(c.target!.homeName, 'Daire 5');
      expect(c.canContinue, isTrue);
    });

    test('özet: tek seferlik bulut kimliği yok (6. adımda yeniden üretilir), yanıt kaybolduğu uyarısı gösterilir, gizli girdiler silinir', () async {
      env.cloud.claimLosesResponseOnce = true;
      await c.claim.claim(homeName: 'Daire 5');
      await c.claim.retry();

      final s = c.claim.summary!;
      expect(s.homeId, kClaimedHome);
      expect(s.credentialReceived, isFalse);
      expect(c.ctx.pendingCredential, isNull);
      expect(s.hasWarnings, isTrue, reason: 'müşteri hesabı / davet e-postası bilgisi yanıtla birlikte kayboldu: kullanıcıya söylenir');
      expect(s.warnings.single, contains('Daire 5'));
      expect(s.warnings.single, contains('yanıtı alınamadı'));
      expect(c.identify.hasPin, isFalse, reason: 'claim tamamlandı: gizli girdiler bellekten silinir');
      expect(c.customer.hasCode, isFalse);
      expect(s.localKeyReady, isTrue, reason: 'cihaz anahtarı yine en iyi çabayla (yalnızca bellekte) hazırlanır');
      expect(c.target!.localKey, kLocalKey);
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)));
    });

    test('kurulum devam eder: 5. ve 6. adımlar yeni kimliği sunucudan üretip panoya yazar (bellekte tek seferlik kimlik yok)', () async {
      env.cloud.claimLosesResponseOnce = true;
      await c.claim.claim(homeName: 'Daire 5');
      await c.claim.retry();
      c.continueNext();
      expect(c.currentStep, SetupSteps.wifi);

      await completeWifi(env, c);
      await completeCloud(env, c);
      expect(env.cloud.calls, contains('reissueDeviceMqttCredential:$kDeviceUid'));
      expect(env.device.mqttConfigCount, 1);
      expect(env.cloud.claimCalls, 1);
    });

    test('"Daireye Bağla"ya yeniden basmak da (tekrar dene yerine) önce doğrular ve ikinci POST göndermez', () async {
      env.cloud.claimLosesResponseOnce = true;
      expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);
      expect(await c.claim.claim(homeName: 'Daire 5'), isTrue);
      expect(env.cloud.claimCalls, 1);
      expect(c.target!.homeId, kClaimedHome);
    });

    test('ağ hatası mesajı isteğin sunucuya ulaşıp ulaşmadığının bilinmediğini ve tekrar denemenin önce doğruladığını söyler', () async {
      env.cloud.claimLosesResponseOnce = true;
      await c.claim.claim();
      final p = c.claim.problem!;
      expect(p.title, 'Sunucuya ulaşılamadı', reason: 'mevcut başlık değişmez');
      expect(p.why, contains('Telefonunuzun internet bağlantısı yok'), reason: 'mevcut açıklama korunur');
      expect(p.why, contains('bilinmiyor'));
      expect(p.todo, contains('"Tekrar dene"ye basın'), reason: 'mevcut yönerge korunur');
      expect(p.todo, contains('kontrol edilir'));
      expect(p.retryable, isTrue);
    });

    test('zaman aşımı da belirsiz sonuçtur: tekrar dene önce doğrular', () async {
      env.cloud.claimLosesResponseOnce = true;
      env.cloud.claimErrorOnce = ApiException.network(cause: TimeoutException('claim zaman aşımı'));
      // claimErrorOnce istek sunucuya ulaşmadan düşer; yine de zaman aşımı "belirsiz" sayılır.
      expect(await c.claim.claim(), isFalse);
      expect(c.claim.problem!.kind, SetupProblemKind.timeout);
      expect(env.cloud.claimApplied, isFalse);

      expect(await c.claim.claim(homeName: 'Daire 7'), isFalse, reason: 'bu kez istek uygulandı ama yanıtı kayboldu');
      expect(env.cloud.claimApplied, isTrue);
      expect(env.cloud.claimCalls, 2);

      await c.claim.retry();
      expect(env.cloud.claimCalls, 2, reason: 'doğrulama bulduğu için üçüncü POST yok');
      expect(c.claim.isComplete, isTrue);
      expect(c.target!.homeName, 'Daire 7');
    });
  });

  group('PF-42: istek sunucuya hiç ulaşmadıysa mevcut davranış korunur', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await atClaimStep(env);
    });
    tearDown(() => env.dispose());

    test('claim uygulanmadıysa tekrar dene doğrulamada cihazı bulamaz ve normal claim yapar (tek kimlik, uyarı yok)', () async {
      env.cloud.claimErrorOnce = ApiException.network(); // istek sunucuya ulaşmadı
      expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);
      expect(env.cloud.claimCalls, 1);

      await c.claim.retry();

      expect(env.cloud.claimCalls, 2, reason: 'cihaz hiçbir daireye bağlı değildi: normal claim yapıldı');
      expect(c.claim.isComplete, isTrue);
      expect(c.claim.summary!.credentialReceived, isTrue);
      expect(c.claim.summary!.hasWarnings, isFalse);
      expect(c.ctx.pendingCredential, isNotNull);
      expect(c.target!.homeId, kClaimedHome);
    });

    test('doğrulama da ağ hatasıyla düşerse yeni claim gönderilmez, tekrar denenebilir ve sonra bulunur', () async {
      env.cloud.claimLosesResponseOnce = true;
      await c.claim.claim(homeName: 'Daire 5');
      env.cloud.fetchHomesErrorOnce = ApiException.network();

      await c.claim.retry();
      expect(c.claim.isComplete, isFalse);
      expect(c.claim.problem!.kind, SetupProblemKind.network);
      expect(c.claim.canRetry, isTrue);
      expect(env.cloud.claimCalls, 1, reason: 'durum doğrulanamadıysa körlemesine ikinci claim gönderilmez');

      await c.claim.retry();
      expect(c.claim.isComplete, isTrue);
      expect(env.cloud.claimCalls, 1);
    });

    test('cihaz hiçbir daire listesinde bulunamaz ve sunucu 409 verirse açıklayıcı yeni mesaj çıkar (mevcut 409 metni değişmez)', () async {
      env.cloud.claimLosesResponseOnce = true;
      await c.claim.claim(homeName: 'Daire 5');
      env.cloud.homes = <HomeModel>[]; // bu hesap evi listeleyemiyor (ör. süper yönetici: üyelik yok)

      await c.claim.retry();

      expect(env.cloud.claimCalls, 2, reason: 'doğrulama bulamadı: normal claim denendi, sunucu reddetti');
      final p = c.claim.problem!;
      expect(p.kind, SetupProblemKind.conflict);
      expect(p.title, 'Cihaz önceki denemede daireye bağlanmış olabilir');
      expect(p.retryable, isFalse);
      expect(p.why, contains('Önceki'));
      expect(p.todo, contains('Mevcut cihazlarım'));
      expect(c.claim.isComplete, isFalse);
      expect(c.target, isNull);
    });

    test('belirsiz hata yaşanmadan gelen 409 eskisi gibi 2. adıma yönlendirir', () async {
      env.cloud.claimErrorOnce = const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Zaten sahiplenilmiş.');
      expect(await c.claim.claim(), isFalse);
      final p = c.claim.problem!;
      expect(p.title, 'Cihaz eşlenemedi');
      expect(p.fixStep, SetupSteps.identify);
      expect(p.retryable, isFalse);
    });
  });

  group('PF-42: arayüz', () {
    testWidgets('yanıtı kaybolan claim: hata kutusu belirsizliği söyler, "Tekrar dene" daireyi bulur ve uyarıyı gösterir', (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openWizard(tester, env);
      await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
      await goNext(tester, env);
      await tapKey(tester, 'btn_scan_label');
      await pumpUntil(tester, env, () => present('step2_accepted_card'));
      await goNext(tester, env);
      await typeKey(tester, 'field_customer', kCustomerEmail);
      await tapKey(tester, 'btn_send_otp');
      await pumpUntil(tester, env, () => present('field_otp'));
      await typeKey(tester, 'field_otp', kCustomerOtp);
      await goNext(tester, env);
      expect(present('setup_step_4'), isTrue);

      env.cloud.claimLosesResponseOnce = true;
      await typeKey(tester, 'field_home_name', 'Daire 5');
      await tapKey(tester, 'btn_claim');
      await tester.pump(const Duration(milliseconds: 300));
      await tapKey(tester, 'btn_claim_confirm');
      await pumpUntil(tester, env, () => present('setup_retry'), reason: 'ağ hatası kutusu çıkmadı');
      expect(find.textContaining('bilinmiyor'), findsOneWidget, reason: 'isteğin ulaşıp ulaşmadığının bilinmediği söylenir');
      expect(present('claim_result_card'), isFalse);
      expect(continueEnabled(tester), isFalse);

      await tapKey(tester, 'setup_retry');
      await pumpUntil(tester, env, () => present('claim_result_card'), reason: 'cihaz sunucudan bulunamadı');
      expect(env.cloud.claimCalls, 1, reason: 'ikinci claim isteği gönderilmedi');
      expect(present('claim_warnings_card'), isTrue);
      expect(find.textContaining('Önceki isteğin yanıtı alınamadı'), findsOneWidget);
      expect(find.textContaining('Bulut kimliği bu yanıtta gelmedi'), findsOneWidget);
      expect(continueEnabled(tester), isTrue);
      expect(present('setup_retry'), isFalse);
    });
  });

  group('PF-42: süper yönetici', () {
    test('evi listeleyebiliyorsa (sunucu verirse) yanıtı kaybolan claim yine bulunur; anahtar sunucudan istenmez', () async {
      final env = await serviceHarness(role: 'super', inventoryListed: true);
      addTearDown(env.dispose);
      final c = await atClaimStep(env);
      env.cloud.claimLosesResponseOnce = true;
      expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);

      await c.claim.retry();

      expect(c.claim.isComplete, isTrue);
      expect(env.cloud.claimCalls, 1);
      expect(c.target!.homeId, kClaimedHome);
      expect(c.claim.summary!.localKeyReady, isFalse, reason: 'süper yöneticiye sunucu cihaz anahtarı vermez');
      expect(env.cloud.calls.where((x) => x.startsWith('localKey')), isEmpty);
    });
  });
}
