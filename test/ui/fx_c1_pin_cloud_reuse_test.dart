import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// SERVIS-02 (D14): 6. adım (Bulut Bağlantısı) sunucuda zaten çevrimiçi olan panonun bulut kimliğini **kipten bağımsız**
/// yeniden üretmez (CONTRACTS §3d): bellekte bekleyen (tek seferlik) kimlik yoksa ve pano sunucuya göre çevrimiçiyse
/// "Pano sunucuda zaten çevrimiçi: ... DEĞİŞTİRİLMEDİ" denir; yalnız açık "Kimliği Yeniden Yaz" zorlar.
///
/// Eskiden koruma yalnız "mevcut cihaz" (2. adım atlanmış) kipindeydi: geçici servis (PIN) oturumunda "Yeni Kurulum"
/// ev sahibinin çalışan panosu için `POST .../mqtt-credential` çağırıyor, sunucu eski kimliği silip panoyu buluttan
/// düşürüyordu.
void main() {
  /// Ev sahibinin çalışan panosu: sunucuda çevrimiçi, ev Wi-Fi ağında ve bulut kimliği yazılı.
  void boardAlreadyOnline(ServiceHarness env) {
    env.cloud.deviceOnline = true;
    env.cloud.deviceLastSeen = env.clock.now().toUtc();
    env.device
      ..wifiConnected = true
      ..staIp = kLanIp
      ..mqttConfigured = true
      ..mqttConnected = true;
  }

  Iterable<String> reissues(ServiceHarness env) =>
      env.cloud.calls.where((c) => c.startsWith('reissueDeviceMqttCredential'));

  testWidgets(
      'PIN oturumu + "Yeni Kurulum": sunucuda çevrimiçi panoda 6. adım kimliği yeniden ÜRETMEZ, panoya yazmaz ve '
      '"DEĞİŞTİRİLMEDİ" der', (tester) async {
    final env = await serviceHarness(role: 'pin', flush: () async {});
    addTearDown(env.dispose);
    boardAlreadyOnline(env);

    await openWizard(tester, env);
    await pumpUntil(tester, env, () => env.cloud.calls.contains('fetchHomes'));
    await goNext(tester, env); // 1 -> 2: dairedeki tek pano otomatik seçilir
    await goNext(tester, env, reason: 'tek pano otomatik seçilmedi'); // 2 -> 5 (3 ve 4 bu oturumda yok)
    expect(present('setup_step_5'), isTrue);

    // 5. adım: pano zaten ev ağında; ev ağındaki adresinden doğrulanır.
    if (!present('wifi_lan_card')) await tapKey(tester, 'btn_toggle_lan');
    await typeKey(tester, 'field_lan_ip', kLanIp);
    await tapKey(tester, 'btn_confirm_lan');
    await pumpUntil(tester, env, () => present('wifi_connected_card'), reason: 'pano ev ağında doğrulanmadı');
    await goNext(tester, env); // 5 -> 6
    expect(present('setup_step_6'), isTrue);

    await tapKey(tester, 'btn_cloud_connect');
    // Ya adım biter ya da (eski davranış) sunucudan yeni kimlik istenir: hangisi önce olursa.
    await pumpUntil(tester, env, () => present('cloud_online_card') || reissues(env).isNotEmpty,
        reason: 'bulut adımı tamamlanmadı');

    expect(reissues(env), isEmpty, reason: 'çalışan panonun kimliğini yeniden üretmek onu buluttan düşürür');
    expect(present('cloud_online_card'), isTrue);
    expect(find.textContaining('DEĞİŞTİRİLMEDİ'), findsOneWidget);
    expect(env.device.mqttConfigCount, 0, reason: 'panoya yeni kimlik yazılmadı');
    expect(continueEnabled(tester), isTrue);
  });

  group('kip fark etmeksizin (denetleyici)', () {
    test('PIN oturumu: bekleyen kimlik yok + pano çevrimiçi -> alreadyOnline; "Kimliği Yeniden Yaz" yine zorlar', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      boardAlreadyOnline(env);
      final c = await startedController(env);
      c.continueNext();
      await waitUntil(env, () => c.identify.isComplete && !c.isBusy);
      c.continueNext();
      expect(c.currentStep, SetupSteps.wifi);
      expect(c.isExistingDevice, isFalse, reason: 'PIN oturumunda 2. adım atlanmaz (mevcut cihaz kipi değil)');
      expect(await drive(env, c.wifi.confirmLanIp(kLanIp)), isTrue);
      c.continueNext();
      expect(c.currentStep, SetupSteps.cloud);
      expect(c.ctx.pendingCredential, isNull);

      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(c.cloud.alreadyOnline, isTrue);
      expect(reissues(env), isEmpty);
      expect(env.device.mqttConfigCount, 0);

      // Açık "Kimliği Yeniden Yaz" seçeneği kimliği yeniden üretir ve yazar (tek zorlama yolu).
      env.clock.advance(const Duration(seconds: 30));
      expect(await drive(env, c.cloud.rewriteCredential()), isTrue);
      expect(c.cloud.alreadyOnline, isFalse);
      expect(reissues(env), hasLength(1));
      expect(env.device.mqttConfigCount, 1);
    });

    test('personel kurulumu kayıttan devam (bellekte kimlik yok) + pano çevrimiçi -> kimlik yeniden üretilmez', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final first = await completeClaim(env);
      await completeWifi(env, first);
      await pumpEventQueue();
      final saved = (await env.store.list(env.access.ownerKey)).single;
      first.dispose();

      // Uygulama kapanmadan önce kimlik panoya yazılmış ve pano buluta bağlanmıştı (6. adım işaretlenemeden kapandı).
      boardAlreadyOnline(env);
      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      resumed.start();
      await pumpEventQueue();
      expect(resumed.currentStep, SetupSteps.cloud);
      expect(resumed.isExistingDevice, isFalse);
      expect(resumed.ctx.pendingCredential, isNull, reason: 'tek seferlik kimlik kayda yazılmaz');

      expect(await drive(env, resumed.cloud.connectAndWait()), isTrue);
      expect(resumed.cloud.alreadyOnline, isTrue);
      expect(reissues(env), isEmpty);
    });

    test('bekleyen (tek seferlik) kimlik VARSA pano çevrimiçi görünse bile kimlik yazılır (bayat "çevrimiçi" bilgisi)', () async {
      final env = await serviceHarness(role: 'pin');
      addTearDown(env.dispose);
      boardAlreadyOnline(env);
      final c = await startedController(env);
      c.continueNext();
      await waitUntil(env, () => c.identify.isComplete && !c.isBusy);
      c.continueNext();
      expect(await drive(env, c.wifi.confirmLanIp(kLanIp)), isTrue);
      c.continueNext();
      c.ctx.pendingCredential = env.cloud.claimCredential;
      env.device.onMqttConfigured = (server, port, user, pass) {
        env.cloud.deviceOnline = true;
        env.cloud.deviceLastSeen = env.clock.now().toUtc().add(const Duration(seconds: 5));
        env.device.mqttConnected = true;
      };

      expect(await drive(env, c.cloud.connectAndWait()), isTrue);
      expect(c.cloud.alreadyOnline, isFalse);
      expect(env.device.mqttConfigCount, 1, reason: 'bellekteki kimlik panoya yazıldı');
      expect(reissues(env), isEmpty, reason: 'bellekte kimlik vardı: sunucudan yeniden üretilmedi');
    });
  });
}
