import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/identify_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// Kurulum sihirbazı durum makinesi (1-4. adımlar, geçici servis oturumu, mevcut cihaz, oturum süresi):
/// her geçiş koşulu, hata yolları ve gizli değer/yanlış hedef sızıntısı denetimleri.

void main() {
  group('1. adım: hazırlık', () {
    test('devam yalnızca sunucu oturumu gerçekten doğrulanınca açılır', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = env.newController();
      addTearDown(c.dispose);

      expect(c.currentStep, SetupSteps.preparation);
      expect(c.canContinue, isFalse, reason: 'sunucu henüz doğrulanmadı');
      expect(c.phaseOf(1), StepPhase.pending);
      c.start();
      await pumpEventQueue();
      expect(env.cloud.calls, contains('fetchHomes'));
      expect(c.canContinue, isTrue);
      expect(c.phaseOf(1), StepPhase.done);
    });

    test('sunucuya ulaşılamazsa açıklama + tekrar dene gelir; düzelince devam açılır', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.fetchHomesErrorOnce = ApiException.network();
      final c = env.newController();
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();

      expect(c.canContinue, isFalse);
      expect(c.prep.problem!.kind, SetupProblemKind.network);
      expect(c.prep.canRetry, isTrue);
      expect(c.phaseOf(1), StepPhase.failed);
      await c.prep.retry();
      expect(c.prep.isComplete, isTrue);
      expect(c.canContinue, isTrue);
    });

    test('oturum geçersizse (401) "Oturum süresi doldu" olur ve ilerlenemez', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.fetchHomesErrorOnce =
          const ApiException(statusCode: 401, code: 'INVALID_TOKEN', message: 'Oturumunuz sona erdi.');
      final c = env.newController();
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();

      expect(c.prep.problem!.kind, SetupProblemKind.expired);
      expect(c.sessionExpired, isTrue);
      expect(c.canContinue, isFalse);
    });

    test('devam çağrısı koşul sağlanmadan adım atlatmaz', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = env.newController();
      addTearDown(c.dispose);
      c.continueNext();
      expect(c.currentStep, SetupSteps.preparation);
      c.goToStep(7);
      expect(c.currentStep, SetupSteps.preparation, reason: 'tamamlanmamış adımın ötesine atlanamaz');
    });
  });

  group('2. adım: cihazı tanıma', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness(inventoryListed: true);
      c = await startedController(env);
      c.continueNext();
    });
    tearDown(() => env.dispose());

    test('geçerli etiket cihazı tanıtır; envanterde stokta görününce devam açılır', () async {
      expect(c.canContinue, isFalse);
      expect(await c.identify.acceptLabel(kLabelQr), isTrue);
      expect(c.identify.uid, kDeviceUid);
      expect(c.identify.inventory, InventoryCheck.inStock);
      expect(c.canContinue, isTrue);
    });

    test('başka siteye ait, bozuk ve boş karekodlar reddedilir; cihaz tanınmaz', () async {
      for (final raw in <String?>[
        'https://kotu-site.example/claim?uid=$kDeviceUid&pin=$kSetupPin',
        'rastgele metin',
        '',
        null,
        'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=GECERSIZ&pin=$kSetupPin',
        'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kDeviceUid&pin=12',
      ]) {
        expect(await c.identify.acceptLabel(raw), isFalse, reason: '$raw');
        expect(c.identify.uid, isNull);
        expect(c.identify.problem, isNotNull);
        expect(c.canContinue, isFalse);
      }
    });

    test('Wi-Fi karekodu ve davet karekodu "bu bir cihaz etiketi değil" diye açıklanır', () async {
      expect(await c.identify.acceptLabel('WIFI:T:WPA;S:Ag;P:parola-12345;;'), isFalse);
      expect(c.identify.problem!.title, 'Bu bir Wi-Fi karekodu');
      expect(await c.identify.acceptLabel('https://evotomasyon.gudeteknoloji.com.tr/join?token=abc'), isFalse);
      expect(c.identify.problem, isNotNull);
    });

    test('elle giriş: seri no ve PIN biçimi doğrulanır, küçük harf normalleştirilir', () async {
      expect(await c.identify.acceptManual('bozuk', kSetupPin), isFalse);
      expect(c.identify.problem!.title, 'Seri numarası geçersiz');
      expect(await c.identify.acceptManual(kDeviceUid, '12'), isFalse);
      expect(c.identify.problem!.title, 'PIN geçersiz');
      expect(await c.identify.acceptManual(kDeviceUid.toLowerCase(), kSetupPin), isTrue);
      expect(c.identify.uid, kDeviceUid);
    });

    test('askıdaki, iptal edilmiş ve zaten devredeki cihaz kuruluma uygun değildir; PIN bellekte tutulmaz', () async {
      final cases = <({String status, String title})>[
        (status: 'SUSPENDED', title: 'Bu cihaz askıya alınmış'),
        (status: 'REVOKED', title: 'Bu cihaz iptal edilmiş'),
        (status: 'CLAIMED', title: 'Bu cihaz zaten bir daireye bağlı'),
      ];
      for (final k in cases) {
        env.cloud.inventory = <InventoryDeviceModel>[inventoryDevice(status: k.status, claimedHome: 'Başka Daire')];
        expect(await c.identify.acceptLabel(kLabelQr), isFalse, reason: k.status);
        expect(c.identify.inventory, InventoryCheck.blocked);
        expect(c.identify.problem!.title, k.title);
        expect(c.identify.hasPin, isFalse, reason: 'uygun olmayan cihazın PIN\'i bellekte kalmaz');
        expect(c.canContinue, isFalse);
        c.identify.reset();
      }
    });

    test('süper yönetici envanterde olmayan cihazı kabul etmez; servis personeli stok satırını göremezse kabul eder', () async {
      env.cloud.inventory = <InventoryDeviceModel>[];
      // Servis personeli yalnızca kendi stokunu görür: satır yoksa kesin karar sunucuya bırakılır.
      expect(await c.identify.acceptLabel(kLabelQr), isTrue);
      expect(c.identify.inventory, InventoryCheck.notVisible);

      final superEnv = await serviceHarness(role: 'super');
      addTearDown(superEnv.dispose);
      superEnv.cloud.inventory = <InventoryDeviceModel>[];
      final sc = await startedController(superEnv);
      sc.continueNext();
      expect(await sc.identify.acceptLabel(kLabelQr), isFalse);
      expect(sc.identify.problem!.title, 'Bu cihaz envanterde kayıtlı değil');
    });

    test('envanter kontrolü ağ hatası verirse adım tamamlanmış sayılmaz; tekrar dene ile düzelir', () async {
      env.cloud.inventoryError = ApiException.network();
      expect(await c.identify.acceptLabel(kLabelQr), isFalse);
      expect(c.identify.problem!.kind, SetupProblemKind.network);
      expect(c.identify.isComplete, isFalse);
      expect(c.canContinue, isFalse);

      env.cloud.inventoryError = null;
      await c.identify.retry();
      expect(c.identify.inventory, InventoryCheck.inStock);
      expect(c.canContinue, isTrue);
    });

    test('Başka Cihaz Seç (reset) tanınan cihazı ve PIN\'i unutturur', () async {
      expect(await c.identify.acceptLabel(kLabelQr), isTrue);
      c.identify.reset();
      expect(c.identify.uid, isNull);
      expect(c.identify.hasPin, isFalse);
      expect(c.canContinue, isFalse);
    });
  });

  group('3. adım: müşteri ve onay kodu', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await startedController(env);
      c.continueNext();
      await c.identify.acceptLabel(kLabelQr);
      c.continueNext();
    });
    tearDown(() => env.dispose());

    test('müşteri bilgisi doğrulanır: boş, geçersiz, kendi e-postası/telefonu', () {
      expect(c.customer.validateIdentifier(''), contains('yazın'));
      expect(c.customer.validateIdentifier('abc'), contains('Telefon numarası geçersiz'));
      expect(c.customer.validateIdentifier('a@b'), contains('E-posta adresi geçersiz'));
      expect(c.customer.validateIdentifier('SERVIS@ornek.test'), contains('Kendi hesabınız'));
      expect(c.customer.validateIdentifier('0555 111 22 33'), contains('Kendi hesabınız'));
      expect(c.customer.validateIdentifier('musteri@ornek.test'), isNull);
      expect(c.customer.validateIdentifier('+90 555 999 88 77'), isNull);
    });

    test('geçersiz bilgide sunucudan kod istenmez; devam kapalıdır', () async {
      expect(await c.customer.sendCode('bu bir eposta degil'), isFalse);
      expect(await c.customer.sendCode('servis@ornek.test'), isFalse);
      expect(env.cloud.otpRequests, 0);
      expect(c.canContinue, isFalse);
    });

    test('kod gönderilince devam, 6 haneli kod yazılana kadar kapalı kalır; harf/eksik hane kabul edilmez', () async {
      expect(await c.customer.sendCode('Musteri@Ornek.Test'), isTrue);
      expect(c.customer.codeSent, isTrue);
      expect(c.customer.identifier!.value, 'musteri@ornek.test', reason: 'e-posta küçük harfe normalleştirilir');
      expect(c.canContinue, isFalse);
      c.customer.setCode('12345');
      expect(c.canContinue, isFalse);
      c.customer.setCode('abcdef');
      expect(c.canContinue, isFalse);
      c.customer.setCode('135 790');
      expect(c.customer.hasCode, isTrue);
      expect(c.canContinue, isTrue);
    });

    test('yeniden gönderme sunucunun verdiği süre dolana kadar kapalıdır', () async {
      await c.customer.sendCode(kCustomerEmail);
      final now = env.clock.now();
      expect(c.customer.canResend(now), isFalse);
      expect(c.customer.resendRemaining(now), const Duration(seconds: 60));
      expect(c.customer.canResend(now.add(const Duration(seconds: 61))), isTrue);
    });

    test('kodun geçerlilik süresi dolunca adım tamamlanmış sayılmaz', () async {
      await c.customer.sendCode(kCustomerEmail);
      c.customer.setCode(kCustomerOtp);
      expect(c.canContinue, isTrue);
      env.clock.advance(const Duration(seconds: 901));
      expect(c.customer.isCodeExpired(env.clock.now()), isTrue);
      expect(c.customer.isComplete, isFalse);
      expect(c.canContinue, isFalse);
    });

    test('C8 (CUSTOMER_EMAIL_REQUIRED): e-postasız (telefonla giren) müşteri: sunucu iletisi gösterilir, yol tarif edilir',
        () async {
      const message = 'Bu müşteri uygulamaya telefonla giriş yapıyor; hesabında e-posta olmadığı için onay kodu '
          'gönderilemez. Müşteri panoyu kendi uygulamasından etiketteki karekodla sahiplenmeli.';
      env.cloud.otpError = const ApiException(
        statusCode: 400,
        code: 'VALIDATION',
        message: message,
        details: <String, dynamic>{'reason': 'CUSTOMER_EMAIL_REQUIRED'},
      );
      expect(await c.customer.sendCode('05551234567'), isFalse);
      expect(c.customer.problem!.why, message);
      expect(c.customer.problem!.todo, isNot(contains('kontrol edip tekrar deneyin')),
          reason: 'numarayı yeniden yazmak sorunu çözmez');
      expect(c.customer.problem!.todo, contains('servis PIN'));
    });

    test('hız sınırı: bekleme süresi saklanır ve kullanıcıya söylenir', () async {
      env.cloud.otpError = const ApiException(
        statusCode: 429,
        code: 'RATE_LIMITED',
        message: 'Çok fazla istek.',
        retryAfter: Duration(minutes: 10),
      );
      expect(await c.customer.sendCode(kCustomerEmail), isFalse);
      expect(c.customer.problem!.kind, SetupProblemKind.rateLimited);
      expect(c.customer.problem!.retryAfter, const Duration(minutes: 10));
      expect(c.customer.codeSent, isFalse);
    });

    test('cihaz kuruluma uygun değilse (409/404/403) kullanıcı 2. adıma yönlendirilir', () async {
      for (final status in <int>[409, 404, 403]) {
        env.cloud.otpError = ApiException(statusCode: status, code: 'X', message: 'Cihaz uygun değil.');
        expect(await c.customer.sendCode(kCustomerEmail), isFalse, reason: '$status');
        expect(c.customer.problem!.fixStep, SetupSteps.identify, reason: '$status');
        expect(c.customer.problem!.retryable, isFalse);
      }
    });

    test('e-posta servisi çalışmıyorsa (503) açıklama gelir ve tekrar denenebilir', () async {
      env.cloud.otpError = const ApiException(statusCode: 503, code: 'DELIVERY_FAILED', message: 'Gönderilemedi.');
      expect(await c.customer.sendCode(kCustomerEmail), isFalse);
      expect(c.customer.problem!.title, 'Kod e-postası gönderilemedi');
      expect(c.customer.canRetry, isTrue);
      env.cloud.otpError = null;
      await c.customer.retry();
      expect(c.customer.codeSent, isTrue);
    });

    test('2. adımda başka cihaza geçilince eski cihaz için gönderilmiş kod geçerli sayılmaz: yeni kod istenir', () async {
      expect(await c.customer.sendCode(kCustomerEmail), isTrue);
      c.customer.setCode(kCustomerOtp);
      expect(c.canContinue, isTrue);

      c.goToStep(SetupSteps.identify);
      c.identify.reset();
      expect(await c.identify.acceptLabel(kLabelQrOther), isTrue);
      expect(c.identify.uid, kOtherUid);
      expect(c.customer.codeSent, isFalse, reason: 'kod başka cihaz için gönderilmişti');
      expect(c.customer.hasCode, isFalse);
      expect(c.customer.isComplete, isFalse);
      expect(c.isStepComplete(SetupSteps.customer), isFalse);
      expect(c.customer.canResend(env.clock.now()), isTrue, reason: 'sunucu bekleme süresi cihaz+hedef çiftine özeldir');
      c.customer.setCode(kCustomerOtp);
      expect(c.customer.isComplete, isFalse, reason: 'bu cihaz için kod istenmeden yazılan değer geçersizdir');

      expect(await c.customer.sendCode(kCustomerEmail), isTrue);
      c.customer.setCode(kCustomerOtp);
      expect(c.customer.isComplete, isTrue);
      expect(
        env.cloud.calls.where((x) => x.startsWith('requestClaimOtp:')).toList(),
        <String>['requestClaimOtp:$kDeviceUid', 'requestClaimOtp:$kOtherUid'],
      );
    });

    test('claim, başka cihaza ait koda dayanamaz: istek atılmaz ve 3. adıma yönlendirilir', () async {
      expect(await c.customer.sendCode(kCustomerEmail), isTrue);
      c.customer.setCode(kCustomerOtp);
      c.goToStep(SetupSteps.identify);
      c.identify.reset();
      expect(await c.identify.acceptLabel(kLabelQrOther), isTrue);
      expect(await c.claim.claim(), isFalse);
      expect(c.claim.problem!.fixStep, SetupSteps.customer);
      expect(env.cloud.claimCalls, 0, reason: 'sunucu claim\'de reddedecekti; istek hiç atılmaz');
    });

    test('müşteriyi değiştirmek gönderim durumunu, kodu ve maskeli bilgiyi sıfırlar', () async {
      await c.customer.sendCode(kCustomerEmail);
      c.customer.setCode(kCustomerOtp);
      c.customer.resetCustomer();
      expect(c.customer.codeSent, isFalse);
      expect(c.customer.hasCode, isFalse);
      expect(c.customer.hint, isEmpty);
      expect(c.canContinue, isFalse);
    });
  });

  group('4. adım: daireye bağlama (claim)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await startedController(env);
      c.continueNext();
      await c.identify.acceptLabel(kLabelQr);
      c.continueNext();
      await c.customer.sendCode(kCustomerEmail);
      c.customer.setCode(kCustomerOtp);
      c.continueNext();
      expect(c.currentStep, SetupSteps.claim);
    });
    tearDown(() => env.dispose());

    test('yanlış kurulum PIN\'i: PIN silinir, 2. adıma yönlendirilir, kalan hak gösterilir ve claim tamamlanmaz', () async {
      env.cloud.expectedPin = '999999';
      expect(await c.claim.claim(), isFalse);
      final p = c.claim.problem!;
      expect(p.kind, SetupProblemKind.forbidden);
      expect(p.fixStep, SetupSteps.identify);
      expect(p.remainingAttempts, 4);
      expect(p.retryable, isFalse, reason: 'aynı PIN ile tekrar denemek kilitlenmeye götürür');
      expect(c.identify.hasPin, isFalse);
      expect(c.claim.isComplete, isFalse);
      expect(c.target, isNull);
      expect(c.canContinue, isFalse);

      // Düzeltme: 2. adıma dön, etiketi yeniden okut, tekrar ilerle.
      c.goToStep(SetupSteps.identify);
      expect(c.currentStep, SetupSteps.identify);
      env.cloud.expectedPin = kSetupPin;
      expect(await c.identify.acceptLabel(kLabelQr), isTrue);
    });

    test('yanlış müşteri kodu: kod silinir ve 3. adıma yönlendirilir', () async {
      c.customer.setCode('000000');
      expect(await c.claim.claim(), isFalse);
      final p = c.claim.problem!;
      expect(p.fixStep, SetupSteps.customer);
      expect(p.remainingAttempts, 4);
      expect(c.customer.hasCode, isFalse);
      expect(c.identify.hasPin, isTrue, reason: 'PIN doğruydu; yalnızca kod yeniden istenir');
    });

    test('PIN kilidi (423): bekleme süresi söylenir, PIN silinir ve 2. adıma yönlendirilir', () async {
      env.cloud.claimErrorOnce = const ApiException(
        statusCode: 423,
        code: 'PIN_LOCKED',
        message: 'Kilitli.',
        retryAfter: Duration(minutes: 15),
      );
      expect(await c.claim.claim(), isFalse);
      final p = c.claim.problem!;
      expect(p.kind, SetupProblemKind.locked);
      expect(p.retryAfter, const Duration(minutes: 15));
      expect(p.todo, contains('15 dakika'));
      expect(p.fixStep, SetupSteps.identify);
      expect(c.identify.hasPin, isFalse);
    });

    test('cihaz başka daireye bağlıysa (409) 2. adıma yönlendirilir', () async {
      env.cloud.claimErrorOnce = const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Zaten sahiplenilmiş.');
      expect(await c.claim.claim(), isFalse);
      expect(c.claim.problem!.kind, SetupProblemKind.conflict);
      expect(c.claim.problem!.fixStep, SetupSteps.identify);
    });

    test('ağ hatasında gizli girdiler korunur; tekrar dene aynı bilgilerle başarılı olur', () async {
      env.cloud.claimErrorOnce = ApiException.network();
      expect(await c.claim.claim(), isFalse);
      expect(c.claim.problem!.kind, SetupProblemKind.network);
      expect(c.claim.canRetry, isTrue);
      expect(c.identify.hasPin, isTrue);
      expect(c.customer.hasCode, isTrue);

      await c.claim.retry();
      expect(c.claim.isComplete, isTrue);
    });

    test('eşzamanlı iki claim çağrısı tek istek gönderir (çift tıklama koruması)', () async {
      final first = c.claim.claim();
      final second = c.claim.claim();
      expect(await second, isFalse, reason: 'ilki sürerken ikincisi çalıştırılmaz');
      expect(await first, isTrue);
      expect(env.cloud.claimCalls, 1);
    });

    test('başarıda hedef claim edilen eve işaret eder; aktif ev değişmez; gizli girdiler silinir', () async {
      expect(await c.claim.claim(homeName: '  Daire 5  '), isTrue);
      expect(c.target!.homeId, kClaimedHome);
      expect(c.target!.homeName, 'Daire 5');
      expect(c.target!.deviceUuid, kDeviceUid);
      expect(env.state.activeHome, isNull);
      expect(c.identify.hasPin, isFalse);
      expect(c.customer.hasCode, isFalse);
      expect(c.ctx.pendingCredential, isNotNull, reason: 'tek seferlik bulut kimliği 6. adım için bellekte bekler');
      expect(c.canContinue, isTrue);
    });

    test('kısmi başarı uyarıları ve müşteri hesabı bilgisi özetle birlikte tutulur', () async {
      env.cloud.claimWarnings = const <String>['Davet e-postası gönderilemedi.'];
      expect(await c.claim.claim(), isTrue);
      expect(c.claim.summary!.warnings, <String>['Davet e-postası gönderilemedi.']);
      expect(c.claim.summary!.hasWarnings, isTrue);
      expect(c.claim.summary!.customerAccountCreated, isTrue);
      expect(c.claim.summary!.credentialReceived, isTrue);
    });

    test('cihaz anahtarı alınamasa da claim başarılıdır; 5. adım anahtarsızdır, anahtar 6. adımda (ev ağında) alınır', () async {
      env.cloud.localKeyError = ApiException.network();
      expect(await c.claim.claim(), isTrue);
      expect(c.target!.localKey, isNull);
      expect(c.claim.summary!.localKeyReady, isFalse);
      env.cloud.localKeyError = null;
      c.continueNext();

      env.phoneOnSetupNetwork(); // 5. adım: kurulum ağında internet yok
      expect(await drive(env, c.wifi.checkDevice()), isTrue, reason: 'Wi-Fi adımı anahtar gerektirmez');
      expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
      expect(c.target!.localKey, isNull, reason: 'kurulum ağında anahtar aranmadı');
      c.continueNext();

      env.phoneOnHomeNetwork(); // 6. adım: internet geri geldi
      expect(await drive(env, c.conn.connect()), isTrue);
      expect(c.target!.localKey, kLocalKey, reason: 'anahtar 6. adımda sunucudan (kaydedilmeden) alındı');
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)));
    });

    test('claim sonrası anahtar yalnızca bellekte hazırlanır: güvenli depoya yazılmaz ve özet bunu söyler', () async {
      expect(await c.claim.claim(), isTrue);
      expect(c.claim.summary!.localKeyReady, isTrue);
      expect(c.target!.localKey, kLocalKey);
      expect(env.h.storage.keys.where((k) => k.toLowerCase().contains('local')), isEmpty,
          reason: 'teknisyenin telefonunda müşteri panosunun anahtarı kalmaz');
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)));
      expect(env.cloud.localKeyHomeIds, <String>[kClaimedHome], reason: 'anahtar claim edilen evden istendi');
    });

    test('çok uzun daire adı reddedilir ve istek atılmaz', () async {
      expect(await c.claim.claim(homeName: 'x' * 101), isFalse);
      expect(c.claim.problem!.title, 'Daire adı çok uzun');
      expect(env.cloud.claimCalls, 0);
    });

    test('PIN ya da müşteri kodu eksikse istek atılmaz ve doğru adıma yönlendirilir', () async {
      c.customer.clearCode();
      expect(await c.claim.claim(), isFalse);
      expect(c.claim.problem!.fixStep, SetupSteps.customer);
      c.identify.clearPin();
      expect(await c.claim.claim(), isFalse);
      expect(c.claim.problem!.fixStep, SetupSteps.identify);
      expect(env.cloud.claimCalls, 0);
    });
  });

  group('geçici servis (PIN) oturumu', () {
    test('3. ve 4. adım atlanır; ilerleme yalnızca pano seçilince açılır; hedef oturumun dairesidir', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      env.cloud.devicesByHome[kClaimedHome] = const <DeviceInfo>[
        DeviceInfo(deviceUuid: kDeviceUid, name: 'Salon', online: true),
        DeviceInfo(deviceUuid: 'AHBU-S3-B2B2B2', name: 'Mutfak', online: false),
      ];
      final c = await startedController(env);
      expect(c.skippedSteps, <int>{SetupSteps.customer, SetupSteps.claim});
      expect(c.phaseOf(3), StepPhase.skipped);
      expect(c.phaseOf(4), StepPhase.skipped);
      c.continueNext();
      expect(c.currentStep, SetupSteps.identify);
      await waitUntilIdle(env, c);
      expect(c.identify.devicesLoaded, isTrue);
      expect(c.canContinue, isFalse, reason: 'dairede iki pano var: biri seçilmeli');

      expect(c.identify.selectHomeDevice('AHBU-S3-YOK000'), isFalse, reason: 'listede olmayan pano seçilemez');
      expect(c.identify.selectHomeDevice('ahbu-s3-b2b2b2'), isTrue);
      expect(c.target!.homeId, kClaimedHome, reason: 'hedef oturumun dairesi');
      expect(c.target!.deviceUuid, 'AHBU-S3-B2B2B2');
      expect(c.canContinue, isTrue);
      c.continueNext();
      expect(c.currentStep, SetupSteps.wifi, reason: '3. ve 4. adım atlanır');
      c.goBack();
      expect(c.currentStep, SetupSteps.identify, reason: 'geri dönüşte de atlanan adımlara girilmez');
    });

    test('dairede tek pano varsa otomatik seçilir; hiç pano yoksa açıklama gelir', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      final c = await startedController(env);
      c.continueNext();
      await waitUntilIdle(env, c);
      expect(c.identify.selectedDevice, kDeviceUid);
      expect(c.canContinue, isTrue);

      final env2 = await serviceHarness(role: 'pin');
      addTearDown(env2.dispose);
      env2.cloud.devicesError = ApiException.network();
      final c2 = await startedController(env2);
      c2.continueNext();
      await waitUntilIdle(env2, c2);
      expect(c2.identify.problem!.kind, SetupProblemKind.network);
      expect(c2.canContinue, isFalse);
    });

    test('geçici oturumda claim denenirse yetki hatası verilir ve sunucuya istek atılmaz', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      final c = await startedController(env);
      expect(await c.claim.claim(), isFalse);
      expect(env.cloud.claimCalls, 0);
      expect(c.claim.problem, isNotNull);
    });

    test('pano seçildikten sonra 5-10. adımlar oturumun dairesinde çalışır ve teslim gönderilir', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      final c = await startedController(env);
      c.continueNext();
      await waitUntilIdle(env, c);
      c.continueNext();
      expect(c.currentStep, SetupSteps.wifi);
      await completeWifi(env, c);
      await completeCloud(env, c);
      await completeRelays(env, c);
      await completeShutters(env, c);
      await completeButtons(env, c);

      await waitUntil(env, () => !c.handover.busy);
      c.handover.setOwnerApproved(true);
      expect(await drive(env, c.handover.submit()), isTrue);
      expect(env.cloud.commissionChecks, hasLength(1));
      expect(env.cloud.homeIdsUsed.every((id) => id == kClaimedHome), isTrue);
      expect(env.cloud.localKeyHomeIds.every((id) => id == kClaimedHome), isTrue);
    });
  });

  group('mevcut cihazda kurulum (2-4. adımlar atlanır)', () {
    test('oturum doğrulanınca istenen adıma geçilir ve o adımın verisi otomatik okunur', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: kLanIp),
        startStep: SetupSteps.relays,
      );
      addTearDown(c.dispose);
      expect(c.isExistingDevice, isTrue);
      expect(c.skippedSteps, <int>{SetupSteps.identify, SetupSteps.customer, SetupSteps.claim});
      expect(c.currentStep, SetupSteps.preparation);

      c.start();
      await waitUntil(env, () => c.currentStep == SetupSteps.relays && c.relays.loaded);
      expect(c.currentStep, SetupSteps.relays);
      expect(c.relays.relays, isNotEmpty);
      expect(c.target!.homeId, kClaimedHome);
    });

    test('sunucuya ulaşılamıyorsa (internet yok) mevcut cihazda bekleyen başlangıç adımına yine de geçilir (Wi-Fi kurtarma)', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed();
      env.phoneOnSetupNetwork(); // telefon panonun kurulum ağında: internet yok
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5'),
        startStep: SetupSteps.wifi,
      );
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();
      expect(c.prep.isComplete, isFalse);
      expect(c.prep.problem!.kind, SetupProblemKind.network);
      expect(c.currentStep, SetupSteps.wifi, reason: '5. adım sunucu gerektirmez: açılır, uyarı şeridi doğrulanamadığını söyler');
    });

    test('internetsiz başlayıp (kurulum ağı) 6. adıma gelince sunucu doğrulaması sessizce yeniden denenir ve uyarı kalkar', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      env.phoneOnSetupNetwork();
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5'),
        startStep: SetupSteps.wifi,
      );
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();
      expect(c.currentStep, SetupSteps.wifi);
      expect(c.prep.problem, isNotNull);

      env.phoneOnHomeNetwork(); // telefon ev Wi-Fi'sine döndü
      expect(await drive(env, c.wifi.confirmLanIp(kLanIp)), isTrue);
      c.continueNext();
      await pumpEventQueue();
      expect(c.currentStep, SetupSteps.cloud);
      expect(c.prep.isComplete, isTrue, reason: 'internet gerektiren adıma girince sunucu doğrulaması yeniden denendi');
      expect(c.prep.problem, isNull);
    });

    test('oturum geçersizse (401) mevcut cihazda başlangıç adımına geçilmez', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.fetchHomesErrorOnce =
          const ApiException(statusCode: 401, code: 'INVALID_TOKEN', message: 'Oturumunuz sona erdi.');
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5'),
        startStep: SetupSteps.wifi,
      );
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();
      expect(c.sessionExpired, isTrue);
      expect(c.currentStep, SetupSteps.preparation);
    });

    test('ilk oturum doğrulaması başarısız olup 1. adımda elle yeniden denenirse bekleyen başlangıç adımı kaybolmaz', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.cloud.fetchHomesErrorOnce = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'x');
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: kLanIp),
        startStep: SetupSteps.relays,
      );
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();
      expect(c.currentStep, SetupSteps.preparation);
      expect(c.prep.problem, isNotNull);

      expect(await c.prep.verify(), isTrue, reason: 'kullanıcı 1. adımda "Bağlantıyı Doğrula"ya bastı');
      expect(c.currentStep, SetupSteps.relays, reason: 'bekleyen başlangıç adımı (Testleri yap) korunur');
    });

    test('zaten sunucuda çevrimiçi olan çalışan panonun bulut kimliği yeniden üretilmez ve panoya yazılmaz', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: kLanIp),
        startStep: SetupSteps.cloud,
      );
      addTearDown(c.dispose);
      c.start();
      await waitUntil(env, () => c.currentStep == SetupSteps.cloud);

      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(c.cloud.alreadyOnline, isTrue);
      expect(c.canContinue, isTrue);
      expect(env.cloud.calls.where((x) => x.startsWith('reissueDeviceMqttCredential')), isEmpty,
          reason: 'çalışan panonun kimliğini yeniden üretmek onu buluttan düşürebilir');
      expect(env.device.mqttConfigCount, 0);

      // Kullanıcı açıkça "Kimliği Yeniden Yaz" derse yeniden üretilir.
      env.clock.advance(const Duration(seconds: 30));
      expect(await drive(env, c.cloud.rewriteCredential()), isTrue);
      expect(c.cloud.alreadyOnline, isFalse);
      expect(env.cloud.calls, contains('reissueDeviceMqttCredential:$kDeviceUid'));
      expect(env.device.mqttConfigCount, 1);
    });

    test('mevcut cihazda ev ağındaki adresten kimlik + anahtarla bağlanılınca 5. adım (Wi-Fi) de kanıtlanmış sayılır', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      env.cloud.seedClaimed(online: true);
      env.device
        ..wifiConnected = true
        ..staIp = kLanIp
        ..mqttConfigured = true
        ..mqttConnected = true;
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: kLanIp),
        startStep: SetupSteps.relays,
      );
      addTearDown(c.dispose);
      c.start();
      await waitUntil(env, () => c.currentStep == SetupSteps.relays && c.relays.loaded);
      expect(c.wifi.isComplete, isTrue, reason: 'pano ev ağındaki adresinden anahtarla yanıt verdi ve ev Wi-Fi ağına bağlı');
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(c.cloud.alreadyOnline, isTrue);
      expect(c.handover.missingSteps, <int>[SetupSteps.relays, SetupSteps.shutters, SetupSteps.buttons]);
    });

    test('başlangıç adımı Wi-Fi ile bulut arasına sığdırılır (2-4. adımlara girilmez)', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid),
        startStep: 2,
      );
      addTearDown(c.dispose);
      c.start();
      await pumpEventQueue();
      expect(c.currentStep, SetupSteps.wifi);
    });
  });

  group('oturum süresi', () {
    test('geçici oturum bitince eylemler "Oturum süresi doldu" ile durur ve ilerleme korunur', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      final c = await startedController(env);
      c.continueNext();
      await waitUntilIdle(env, c);
      c.continueNext(); // pano seçildi (tek pano) -> 5. adım
      expect(c.sessionRemaining, const Duration(hours: 2));
      expect(c.sessionExpired, isFalse);

      env.clock.advance(const Duration(hours: 1, minutes: 59));
      await pumpEventQueue();
      expect(c.sessionExpired, isFalse);
      expect(c.sessionRemaining, const Duration(minutes: 1));

      env.clock.advance(const Duration(minutes: 2));
      await pumpEventQueue();
      expect(c.sessionExpired, isTrue);
      expect(c.canContinue, isFalse);
      expect(await c.wifi.checkDevice(), isFalse);
      expect(c.wifi.problem!.kind, SetupProblemKind.expired);
      expect(c.wifi.canRetry, isFalse);

      // İlerleme telefonda kayıtlı kalır.
      final saved = await env.store.list(env.access.ownerKey);
      expect(saved, hasLength(1));
      expect(saved.single.deviceUuid, kDeviceUid);
      expect(saved.single.currentStep, SetupSteps.wifi);
    });

    test('kalıcı personel oturumu kapanınca da eylemler durur', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await completeClaim(env);
      await env.state.logout();
      await pumpEventQueue();
      expect(c.sessionExpired, isTrue);
      expect(await c.wifi.checkDevice(), isFalse);
      expect(c.wifi.problem!.kind, SetupProblemKind.expired);
      expect(c.canContinue, isFalse);
    });

    test('oturum sürerken kalan süre null (kalıcı personel) ya da azalan değerdir', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = env.newController();
      addTearDown(c.dispose);
      expect(c.sessionRemaining, isNull);
    });
  });
}

/// Denetleyicide çalışan hiçbir işlem kalmayana kadar saati ilerleterek bekler.
Future<void> waitUntilIdle(ServiceHarness env, ServiceSetupController c) =>
    waitUntil(env, () => !c.isBusy, maxSteps: 200);
