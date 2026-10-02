import 'package:ev_otomasyon/ui/pages/service_setup/logic/button_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/relay_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

void main() {
  group('servis kurulum sihirbazı: 10 adım uçtan uca (kalıcı servis personeli)', () {
    late ServiceHarness env;

    setUp(() async {
      env = await serviceHarness();
    });
    tearDown(() => env.dispose());

    test('her adım yalnızca gerçek sunucu/cihaz yanıtıyla geçilir ve rapor gizli değer içermez', () async {
      final c = env.newController();
      addTearDown(c.dispose);

      // 1) Hazırlık: oturum sunucuda doğrulanana kadar devam edilemez.
      expect(c.currentStep, 1);
      expect(c.canContinue, isFalse, reason: 'sunucu henüz doğrulanmadı');
      c.start();
      await pumpEventQueue();
      expect(c.prep.isComplete, isTrue);
      expect(env.cloud.calls, contains('fetchHomes'));
      c.continueNext();
      expect(c.currentStep, 2);

      // 2) Cihazı tanı: etiket QR'ı.
      expect(c.canContinue, isFalse);
      expect(await c.identify.acceptLabel(kLabelQr), isTrue);
      expect(c.identify.uid, kDeviceUid);
      expect(c.canContinue, isTrue);
      c.continueNext();

      // 3) Müşteri: kod gönderilmeden devam edilemez.
      expect(c.customer.validateIdentifier('servis@ornek.test'), contains('Kendi hesabınız'));
      expect(await c.customer.sendCode(kCustomerEmail), isTrue);
      expect(env.cloud.otpRequests, 1);
      expect(c.canContinue, isFalse, reason: 'müşteri kodu henüz yazılmadı');
      c.customer.setCode('12');
      expect(c.canContinue, isFalse);
      c.customer.setCode(kCustomerOtp);
      expect(c.canContinue, isTrue);
      c.continueNext();

      // 4) Claim: sunucu home_id döndürür; bundan sonra tüm adımlar bu eve işlem yapar.
      expect(c.canContinue, isFalse);
      expect(await c.claim.claim(homeName: 'Daire 5'), isTrue);
      expect(c.target!.homeId, kClaimedHome);
      expect(c.target!.deviceUuid, kDeviceUid);
      expect(c.target!.localKey, kLocalKey, reason: 'anahtar internet varken (yalnızca bellekte) hazırlanır');
      expect(env.dumpSecureStore(), isNot(contains(kLocalKey)), reason: 'cihaz anahtarı güvenli depoya YAZILMAZ');
      expect(env.state.activeHome, isNull, reason: 'claim edilen ev aktif ev DEĞİLDİR');
      expect(env.cloud.localKeyHomeIds, contains(kClaimedHome));
      expect(c.identify.hasPin, isFalse, reason: 'PIN claim sonrası bellekten silinir');
      expect(c.customer.hasCode, isFalse, reason: 'müşteri kodu claim sonrası bellekten silinir');
      c.continueNext();
      expect(c.currentStep, SetupSteps.wifi);

      // 5) Wi-Fi (telefon panonun kurulum ağında: internet YOK, cihaz anahtarı YOK): pano kimliği anahtarsız
      // doğrulanır, gönderim sonucu BEKLENİR.
      env.phoneOnSetupNetwork();
      final callsAtSetupNetwork = List<String>.of(env.cloud.calls);
      expect(c.canContinue, isFalse);
      expect(await drive(env, c.wifi.checkDevice()), isTrue);
      expect(c.wifi.deviceReady, isTrue);
      expect(c.canContinue, isFalse, reason: 'ev Wi-Fi henüz gönderilmedi');
      expect((await connectHomeWifi(env, c)).isSuccess, isTrue);
      expect(c.wifi.connected, isTrue);
      expect(c.target!.ip, kLanIp, reason: 'artık pano ev ağındaki IP (wifi_sta_ip) ile kullanılır');
      expect(env.cloud.calls, callsAtSetupNetwork, reason: 'kurulum ağında hiçbir sunucu çağrısı yapılmadı');
      expect(env.device.keyHeaderHosts, isEmpty, reason: 'kurulum ağında cihaz anahtarı gönderilmedi');
      c.continueNext();
      env.phoneOnHomeNetwork(); // telefon ev Wi-Fi'sine döndü: internet geri geldi

      // 6) Bulut (ev ağı, internet var): anahtar doğrulanır, kimlik panoya yazılır, sunucuda çevrimiçi olması beklenir.
      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(env.device.keyHeaderHosts.toSet(), <String>{kLanIp}, reason: 'cihaz anahtarı yalnızca ev ağı adresine gider');
      expect(env.device.receivedMqttPass, kCredentialPassword);
      expect(env.device.receivedMqttServer, 'mqtt.ornek.test');
      expect(env.device.receivedMqttPort, 8884);
      expect(env.cloud.homeIdsUsed.every((id) => id == kClaimedHome), isTrue);
      expect(c.ctx.pendingCredential, isNull, reason: 'kimlik yazılınca bellekten bırakılır');
      c.continueNext();

      // 7) Röleler
      await waitUntil(env, () => c.relays.loaded); // adıma girince röleler otomatik okunur
      expect(c.relays.relays, hasLength(4));
      expect(c.canContinue, isFalse);
      for (final r in List<RelayCheck>.of(c.relays.relays)) {
        expect(await drive(env, c.relays.command(r.id, true)), isTrue);
        expect(env.device.relayState(r.id), isTrue);
        c.relays.confirmLit(r.id, true);
        expect(await drive(env, c.relays.command(r.id, false)), isTrue);
        expect(c.relays.byId(r.id)!.verdict, RelayVerdict.ok);
      }
      expect(c.canContinue, isTrue);
      c.continueNext();

      // 8) Panjurlar: yön + ölçülen süre kaydedilir ve panoda doğrulanır.
      await waitUntil(env, () => c.shutters.loaded);
      expect(c.shutters.shutters.map((s) => s.pair), <int>[1, 2]);
      for (final pair in <int>[1, 2]) {
        expect(await drive(env, c.shutters.move(pair, 'up')), isTrue);
        c.shutters.confirmDirection(pair, wentUp: true);
        expect(await drive(env, c.shutters.move(pair, 'stop')), isTrue);
        expect(await drive(env, c.shutters.prepareMeasure(pair)), isTrue);
        expect(env.device.shutterRuntime(pair), 300);
        expect(await drive(env, c.shutters.driveToBottom(pair)), isTrue);
        expect(await drive(env, c.shutters.bottomReached(pair)), isTrue);
        expect(await drive(env, c.shutters.startMeasure(pair)), isTrue);
        env.clock.advance(Duration(seconds: 20 + pair * 4));
        expect(await drive(env, c.shutters.finishMeasure(pair)), isTrue);
        expect(c.shutters.byPair(pair)!.measuredSeconds, 20 + pair * 4);
        expect(await drive(env, c.shutters.saveRuntime(pair)), isTrue);
        expect(env.device.shutterRuntime(pair), 20 + pair * 4, reason: 'pano süreyi gerçekten uyguladı');
      }
      expect(c.shutters.isComplete, isTrue);
      expect(env.cloud.endpointUpdates.last['sec'], 28);
      expect(env.cloud.endpointUpdates.every((u) => u['home_id'] == kClaimedHome), isTrue);
      c.continueNext();

      // 9) Duvar butonları: her giriş için basış algılanır.
      await waitUntil(env, () => c.buttons.loaded);
      expect(await drive(env, c.buttons.startListening()), isTrue);
      expect(c.canContinue, isFalse);
      for (var id = 1; id <= 4; id++) {
        env.device.setDi(id, true);
        await env.clock.elapse(const Duration(milliseconds: 400));
        env.device.setDi(id, false);
        await env.clock.elapse(const Duration(milliseconds: 400));
        expect(c.buttons.buttons.firstWhere((b) => b.id == id).verdict, ButtonVerdict.detected);
      }
      expect(c.canContinue, isTrue);
      c.continueNext();
      expect(c.buttons.listening, isFalse, reason: 'adımdan çıkınca dinleme durur');

      // 10) Teslim: sunucu tests_passed hesaplar.
      await waitUntil(env, () => !c.handover.busy); // adıma girince güncel durum okunur
      c.handover.setNotes('Montaj tamam');
      c.handover.setReceiver('Ayşe Hanım');
      expect(c.handover.canSubmit, isFalse, reason: 'müşteri teslimi onaylanmadı');
      c.handover.setOwnerApproved(true);
      expect(c.handover.canSubmit, isTrue);
      expect(await drive(env, c.handover.submit()), isTrue);
      expect(c.handover.result!.testsPassed, isTrue);
      expect(c.isFinished, isTrue);
      final checks = env.cloud.commissionChecks.single;
      expect(checks.relays.ok && checks.buttons.ok && checks.shutters.ok && checks.network.ok && checks.cloud.ok, isTrue);
      expect(checks.relays.detail, contains('4 röle doğrulandı'));
      expect(checks.shutters.detail, contains('24 sn'));
      expect(env.cloud.commissionNotes.single, contains('Teslim alan: Ayşe Hanım'));

      // Rapor ve kalıcı kayıt: hiçbir gizli değer yok.
      final report = c.handover.buildReport(roleLabel: 'Servis personeli');
      expect(report, contains(kDeviceUid));
      expect(report, contains('Daire 5'));
      expect(report, contains('BAŞARILI'));
      for (final secret in <String>[kSetupPin, kCustomerOtp, kCredentialPassword, kLocalKey, kHomeWifiPass, kCustomerEmail]) {
        expect(report, isNot(contains(secret)));
        expect(await dumpPrefs(), isNot(contains(secret)));
        expect(env.dumpSecureStore(), isNot(contains(secret)), reason: 'güvenli depoda da gizli değer kalmaz');
      }
    });
  });
}
