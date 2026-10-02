import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Wi-Fi servis akışı (CONTRACTS §3d) **uçtan uca tutarlılık**: Flutter istemcisi
/// ([AutomationApiService]) ile firmware kurallarının JavaScript portu olan QA cihaz simülatörü
/// (`tools/qa_stack/sim`, `ApAccess.h`/`WebPortal.cpp` portu) gerçek HTTP ile konuşur.
///
/// Neden: istemci testleri sahte cihazla (`FakeDevice`, `MockApi`), simülatör testleri kendi
/// istemcisiyle çalışır; kuralın iki yanı birbirinden sapsa iki takım da yeşil kalırdı. Burada
/// gerçek istemci, gerçek (portlanmış) yetki kararıyla karşılaşır.
///
/// Ön koşul: `node` ve `tools/qa_stack/node_modules` (yoksa testler ATLANIR; CI'da bağımlılık kurulmamışsa
/// kırılmaz). Gizli değerler (anahtar, parolalar) her koşuda rastgele üretilir ve yalnızca bellekte /
/// alt sürecin komut satırında bulunur: dosyaya yazılmaz, loglanmaz. Simülatör yalnızca 127.0.0.1'e bağlanır.
String _rand(int n) {
  final r = Random.secure();
  const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  return List<String>.generate(n, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// `null`: koşullar uygun; aksi halde atlama nedeni.
String? _prerequisiteProblem() {
  final qa = Directory('tools/qa_stack');
  if (!File('tools/qa_stack/sim/device_sim.js').existsSync() || !Directory('tools/qa_stack/node_modules').existsSync()) {
    return 'tools/qa_stack (simülatör) veya bağımlılıkları (node_modules) yok';
  }
  if (!qa.existsSync()) return 'tools/qa_stack yok';
  try {
    final r = Process.runSync('node', <String>['--version']);
    if (r.exitCode != 0) return 'node çalıştırılamadı';
  } catch (_) {
    return 'node bulunamadı';
  }
  return null;
}

class _Sim {
  _Sim._(this.port, this._proc);

  final int port;
  final Process _proc;
  String get base => 'http://127.0.0.1:$port';

  static Future<_Sim> start({
    required String uid,
    String? localKey,
    String? apPass,
    String? homeSsid,
    String? homePass,
    String? staIp,
  }) async {
    final port = await _freePort();
    final args = <String>[
      'sim/device_sim.js',
      '--uid', uid,
      '--http-port', '$port',
      if (staIp != null) ...<String>['--sta-ip', staIp],
      if (localKey != null) ...<String>['--local-key', localKey],
      if (apPass != null) ...<String>['--ap-pass', apPass],
      if (homeSsid != null) ...<String>['--home-wifi-ssid', homeSsid],
      if (homePass != null) ...<String>['--home-wifi-pass', homePass],
    ];
    final proc = await Process.start('node', args, workingDirectory: 'tools/qa_stack');
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    final sim = _Sim._(port, proc);
    for (var i = 0; i < 160; i++) {
      try {
        final r = await http.get(Uri.parse('${sim.base}/__sim/state')).timeout(const Duration(seconds: 1));
        if (r.statusCode == 200) return sim;
      } catch (_) {
        // henüz dinlemiyor
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    proc.kill();
    throw StateError('Simülatör açılmadı (UID $uid).');
  }

  Future<Map<String, dynamic>> state() async {
    final r = await http.get(Uri.parse('$base/__sim/state'));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Kurulum ağı (AP) şu an WPA2 olarak yayında mı (provizyonlu cihazda AP penceresi açık).
  Future<void> waitForSecuredAp({int seconds = 20}) async {
    for (var i = 0; i < seconds * 4; i++) {
      final wifi = (await state())['wifi'] as Map<String, dynamic>;
      if (wifi['ap_secured'] == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Kurulum ağı WPA2 olarak açılmadı.');
  }

  /// İstemcinin ağ konumu modeli: `ap` (cihazın SoftAP'sinde) | `lan` (ev ağında).
  Future<void> setClientNet(String mode) async {
    final r = await http.post(
      Uri.parse('$base/__sim/client-net'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'mode': mode}),
    );
    expect(r.statusCode, 200);
  }

  void stop() => _proc.kill();
}

void main() {
  final skipReason = _prerequisiteProblem();
  const homeSsid = 'EvAgiTest';
  final homePass = _rand(12);
  final started = <_Sim>[];

  Future<_Sim> startSim({
    required String uid,
    bool provisioned = true,
    String? staIp,
  }) async {
    final sim = await _Sim.start(
      uid: uid,
      localKey: provisioned ? _rand(16) : null,
      apPass: provisioned ? _rand(12) : null,
      homeSsid: homeSsid,
      homePass: homePass,
      staIp: staIp,
    );
    started.add(sim);
    if (provisioned) await sim.waitForSecuredAp();
    return sim;
  }

  tearDownAll(() {
    for (final sim in started) {
      sim.stop();
    }
  });

  const slow = Timeout(Duration(seconds: 120));

  group('Flutter istemcisi <-> firmware kuralı simülatörü (Wi-Fi servis akışı, CONTRACTS §3d)', () {
    test('anahtarsız kısıtlı özet: kimlik + provizyon durumu okunur', () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0042');
      final api = AutomationApiService(baseUrl: sim.base);
      addTearDown(api.dispose);

      final status = await api.fetchPublicStatus();
      expect(status.uid, 'AHBU-S3-0A0042');
      expect(status.provisioned, isTrue);
    }, timeout: slow);

    test('SoftAP istemcisi anahtarsız: tarama listeler, wifi/status okunur; diğer uçlar (röle) 401', () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0043');
      final api = AutomationApiService(baseUrl: sim.base); // anahtar YOK
      addTearDown(api.dispose);

      final networks = await api.scanWifi(refresh: true);
      expect(networks.map((n) => n.ssid), contains(homeSsid));
      final wifi = await api.fetchWifiStatus();
      expect(wifi.wifiConnectState.name, 'idle');
      expect(wifi.wifiConnected, isFalse);
      await expectLater(
        api.setRelay(1, true),
        throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
    }, timeout: slow);

    test('istemci kurulum ağı dışına (LAN) alınınca anahtarsız wifi uçları 401; anahtarlı yol her yerden çalışır', () async {
      final key = _rand(16);
      final sim = await _Sim.start(uid: 'AHBU-S3-0A0044', localKey: key, apPass: _rand(12), homeSsid: homeSsid, homePass: homePass);
      started.add(sim);
      await sim.waitForSecuredAp();
      final api = AutomationApiService(baseUrl: sim.base);
      final keyed = AutomationApiService(baseUrl: sim.base, localKey: key);
      addTearDown(api.dispose);
      addTearDown(keyed.dispose);

      await sim.setClientNet('lan');
      await expectLater(api.fetchWifiStatus(), throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, '401', isTrue)));
      await expectLater(api.scanWifi(), throwsA(isA<LocalApiException>().having((e) => e.isUnauthorized, '401', isTrue)));
      expect((await keyed.fetchWifiStatus()).wifiConnectState.name, 'idle');

      await sim.setClientNet('ap');
      expect((await api.fetchWifiStatus()).wifiConnectState.name, 'idle');
    }, timeout: slow);

    test('yanlış ev Wi-Fi şifresi: sonuç BEKLENİR; "failed" + şifre mesajı (başarı gösterilmez)', () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0045');
      final api = AutomationApiService(baseUrl: sim.base);
      addTearDown(api.dispose);

      final result = await api.connectWifiAndWait(homeSsid, '${homePass}x', timeout: const Duration(seconds: 40));
      expect(result.outcome, WifiConnectOutcome.failed);
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('şifresi hatalı'));
    }, timeout: slow);

    test('doğru bilgi: connect "bağlandı" DEMEZ (connecting); başarı YALNIZ wifi_connect_state=success ile ve IP gelir', () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0046');
      final api = AutomationApiService(baseUrl: sim.base);
      addTearDown(api.dispose);

      await api.connectWifi(homeSsid, homePass);
      final immediately = await api.fetchWifiStatus();
      expect(immediately.wifiConnectState.name, 'connecting');
      expect(immediately.wifiConnected, isFalse);

      final result = await api.awaitWifiConnection(timeout: const Duration(seconds: 40));
      expect(result.outcome, WifiConnectOutcome.success);
      expect(result.ipAddress, isNotEmpty);
    }, timeout: slow);

    test('kenar durum: modem ağı da 192.168.4.x ise bağlantı başarılı olur ama yetki yolu kapanır -> "belirsiz" (yetki hatası değil)',
        () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0047', staIp: '192.168.4.20');
      final api = AutomationApiService(baseUrl: sim.base);
      addTearDown(api.dispose);

      final result = await api.connectWifiAndWait(homeSsid, homePass, timeout: const Duration(seconds: 40));
      expect(result.outcome, WifiConnectOutcome.lostContact);
      expect(result.isSuccess, isFalse);
    }, timeout: slow);

    test('hız sınırı: anahtarsız connect dakikada 6 (geçersiz gövdeli dahil); 7. istek 429 + retryAfter', () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0048');
      final api = AutomationApiService(baseUrl: sim.base);
      addTearDown(api.dispose);

      // Geçersiz gövdeli istekler de hak tüketir (istemci SSID'yi önce doğruladığı için ham HTTP).
      for (var i = 0; i < 6; i++) {
        final r = await http.post(
          Uri.parse('${sim.base}/api/wifi/connect'),
          headers: <String, String>{'Content-Type': 'application/json'},
          body: '{"ssid":""}',
        );
        expect(r.statusCode, 400, reason: 'istek ${i + 1} sınıra takılmamalı');
      }
      await expectLater(
        api.connectWifi(homeSsid, homePass),
        throwsA(
          isA<LocalApiException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.retryAfter, 'retryAfter', isNotNull)
              .having((e) => e.retryAfter!.inSeconds, 'sn', inInclusiveRange(1, 60)),
        ),
      );
    }, timeout: slow);

    test('provizyonsuz cihaz: wifi uçları 403 unprovisioned; factory/init ile AP WPA2\'ye dönünce anahtarsız erişim açılır', () async {
      final sim = await startSim(uid: 'AHBU-S3-0A0049', provisioned: false);
      final api = AutomationApiService(baseUrl: sim.base);
      addTearDown(api.dispose);

      expect((await api.fetchPublicStatus()).provisioned, isFalse);
      await expectLater(api.scanWifi(), throwsA(isA<LocalApiException>().having((e) => e.isUnprovisioned, 'unprovisioned', isTrue)));
      await expectLater(api.fetchWifiStatus(), throwsA(isA<LocalApiException>().having((e) => e.isUnprovisioned, 'unprovisioned', isTrue)));

      await api.factoryInit(localKey: _rand(16), apPass: _rand(12));
      await sim.waitForSecuredAp();
      api.localKey = null; // servis sihirbazı gibi: anahtar olmadan devam
      expect((await api.fetchWifiStatus()).wifiConnectState.name, 'idle');
    }, timeout: slow);
  }, skip: skipReason);
}
