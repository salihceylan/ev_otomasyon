import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// 6. adım ile pano bootstrap'ı (CONTRACTS §3f) yarışı: claim'deki tek seferlik kimlik bellekte beklerken pano internete
/// çıkıp kimliğini kendisi alırsa sunucu eski kimliği siler. Pano sunucuda yeni görülmüş çevrimiçi ise bekleyen kimlik
/// YAZILMAZ (yazılsaydı pano silinmiş kimlikle yeniden bağlanıp düşerdi); "Kimliği Yeniden Yaz" yine zorla yazar.
void main() {
  late ServiceHarness env;
  late ServiceSetupController c;

  setUp(() async {
    env = await serviceHarness();
    c = await completeClaim(env);
    await completeWifi(env, c);
    expect(c.ctx.pendingCredential, isNotNull);
  });

  tearDown(() => env.dispose());

  test('pano çevrimiçi (yeni görülmüş) + bekleyen kimlik: panoya yazılmaz, bırakılır, adım tamamlanır', () async {
    env.cloud
      ..deviceOnline = true
      ..deviceLastSeen = env.clock.now().toUtc().subtract(const Duration(seconds: 20));
    expect(await drive(env, c.cloud.connectAndWait()), isTrue);
    expect(env.device.mqttConfigCount, 0, reason: 'POST /api/mqtt/config gönderilmedi');
    expect(c.ctx.pendingCredential, isNull, reason: 'silinmiş kimlik bellekte tutulmaz');
    expect(c.cloud.alreadyOnline, isTrue);
    expect(c.cloud.isComplete, isTrue);
    expect(c.canContinue, isTrue);
  });

  test('pano çevrimdışı + bekleyen kimlik: eskisi gibi yazılır', () async {
    expect(await drive(env, c.cloud.connectAndWait()), isTrue);
    expect(env.device.mqttConfigCount, 1);
    expect(env.device.receivedMqttPass, kCredentialPassword);
  });

  test('sunucu "çevrimiçi" diyor ama son görülme eski (bayat bayrak): bekleyen kimlik yazılır', () async {
    env.cloud
      ..deviceOnline = true
      ..deviceLastSeen = env.clock.now().toUtc().subtract(const Duration(minutes: 10));
    await drive(env, c.cloud.connectAndWait());
    expect(env.device.mqttConfigCount, 1);
    expect(env.device.receivedMqttPass, kCredentialPassword);
  });

  test('"Kimliği Yeniden Yaz" pano çevrimiçiyken de sunucudan yenisini üretip yazar', () async {
    env.cloud
      ..deviceOnline = true
      ..deviceLastSeen = env.clock.now().toUtc().subtract(const Duration(seconds: 20));
    expect(await drive(env, c.cloud.connectAndWait()), isTrue);
    expect(env.device.mqttConfigCount, 0);
    expect(await drive(env, c.cloud.rewriteCredential()), isTrue);
    expect(env.device.mqttConfigCount, 1);
    expect(env.cloud.calls.where((x) => x.startsWith('reissueDeviceMqttCredential')), hasLength(1));
  });
}
