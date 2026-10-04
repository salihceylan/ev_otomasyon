import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// PF-44 (WP-STATE, S5): tek seferlik sırlı sonuçlar (acil sıfırlama PIN'i / yerel anahtar, pano değişimi cihaz kimliği,
/// claim cihaz kimliği) başarı SONRASI ağ yenilemesi bitene kadar beklemez: yenileme en iyi çaba ve en çok 3 sn
/// sınırlıdır (Clock tabanlı), sonuç hemen döner. Aksi halde 401/yavaş ağda arayüz tavanı (40/30 sn) aşılır,
/// "sonuç belirsiz" kartı çıkar ve sır KAYBOLUR (sunucu sırrı bir daha vermez).
void main() {
  Future<void> settle() => pumpEventQueue();

  const emergencyArgs = (deviceUuid: 'AHBU-S3-ABC123', confirmUid: 'AHBU-S3-ABC123');

  Future<EmergencyResetResult> reset(StateHarness h) => h.state.emergencyResetDevice(
        deviceUuid: emergencyArgs.deviceUuid,
        confirmUid: emergencyArgs.confirmUid,
        reason: 'Saha denemesi: pano arızalı, yeniden devreye alınacak.',
      );

  group('acil sıfırlama', () {
    test('ev listesi yenilemesi kapıda TAKILI: sonuç (tek seferlik PIN) 5 sn içinde döner', () async {
      final h = await readyHarness(role: 'service_user', globalRole: 'service_user');
      addTearDown(h.dispose);
      h.cloud
        ..emergencyResetToReturn = const EmergencyResetResult(action: 'UNCLAIMED', deviceUuid: 'AHBU-S3-ABC123', setupPin: '482913')
        ..fetchHomesGate = Completer<void>();

      EmergencyResetResult? result;
      unawaited(reset(h).then((r) => result = r));
      await h.clock.elapse(const Duration(seconds: 5));

      expect(result, isNotNull, reason: 'eskiden: fetchHomes bitene kadar dönmezdi (kara delikli ağda sır kaybolurdu)');
      expect(result!.setupPin, '482913');
      expect(result!.isUnclaimed, isTrue);

      h.cloud.fetchHomesGate!.complete(); // arka plandaki yenileme sonradan sorunsuz biter
      await settle();
    });

    test('yenileme 3 sn içinde BİTERSE beklenir: sonuç döndüğünde ev listesi güncel', () async {
      final h = await readyHarness(role: 'service_user', globalRole: 'service_user');
      addTearDown(h.dispose);
      final fetchesBefore = h.cloud.count('fetchHomes');

      final result = await reset(h);

      expect(result.action, 'UNCLAIMED');
      expect(h.cloud.count('fetchHomes'), fetchesBefore + 1, reason: 'hızlı ağda yenileme sonuçtan önce tamamlanır');
      expect(h.state.homesLoaded, isTrue);
      expect(h.state.homesLoading, isFalse);
    });

    test('yenileme HATA verirse (ağ) sonuç yine döner', () async {
      final h = await readyHarness(role: 'service_user', globalRole: 'service_user');
      addTearDown(h.dispose);
      h.cloud.fetchHomesError = ApiException.network();

      final result = await reset(h);

      expect(result.setupPin, '000000');
    });

    test('doğrulama hataları (yetki / gerekçe / uid teyidi) AĞA gitmeden fırlatılır (davranış korunur)', () async {
      final h = await readyHarness(role: 'service_user', globalRole: 'service_user');
      addTearDown(h.dispose);

      await expectLater(
        h.state.emergencyResetDevice(deviceUuid: 'AHBU-S3-ABC123', confirmUid: 'AHBU-S3-ABC123', reason: 'kısa'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      await expectLater(
        h.state.emergencyResetDevice(deviceUuid: 'AHBU-S3-ABC123', confirmUid: 'AHBU-S3-ZZZ999', reason: 'x' * 20),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      expect(h.cloud.count('emergencyResetDevice'), 0);
    });
  });

  group('pano değişimi', () {
    test('REST yenilemesi (uç noktalar) kapıda TAKILI: sonuç (cihaz kimliği) 5 sn içinde döner', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      h.cloud
        ..replaceBoardToReturn = const ReplaceBoardResult(
          newDeviceUuid: 'AHBU-S3-NEW001',
          homeId: kHomeA,
          deviceCredential: DeviceMqttCredential(
            host: 'broker.fake.invalid',
            port: 8884,
            username: 'd_h_test',
            password: 'fake-device-secret-not-real',
            topicId: 'h_test',
          ),
        )
        ..fetchEndpointsGate = Completer<void>();

      ReplaceBoardResult? result;
      unawaited(h.state.replaceBoard(newDeviceUuid: 'AHBU-S3-NEW001', setupPin: '123456').then((r) => result = r));
      await h.clock.elapse(const Duration(seconds: 5));

      expect(result, isNotNull);
      expect(result!.deviceCredential?.username, 'd_h_test');
      expect(result!.newDeviceUuid, 'AHBU-S3-NEW001');

      h.cloud.fetchEndpointsGate!.complete();
      await settle();
      expect(h.state.endpointsLoaded, isTrue);
    });

    test('hızlı ağda yenileme sonuçtan önce biter (uç noktalar tazelenmiş)', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      final before = h.cloud.count('fetchEndpoints');

      await h.state.replaceBoard(newDeviceUuid: 'AHBU-S3-NEW001', setupPin: '123456');

      expect(h.cloud.count('fetchEndpoints'), before + 1);
    });
  });

  group('cihaz sahiplenme (claim)', () {
    test('ev listesi yenilemesi kapıda TAKILI: sonuç 5 sn içinde döner', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      h.cloud.fetchHomesGate = Completer<void>();

      ClaimResult? result;
      unawaited(h.state.claimDevice('AHBU-S3-NEW001', '123456', homeName: 'Yeni Ev').then((r) => result = r));
      await h.clock.elapse(const Duration(seconds: 5));

      expect(result, isNotNull);
      expect(result!.homeId, kHomeA);
      h.cloud.fetchHomesGate!.complete();
      await settle();
    });

    test('müşteri akışı (hızlı ağ): sahiplenilen ev listede bulunur ve AKTİF ev olur (davranış korunur)', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yeni Ev', topic: 'h_b')]
        ..endpoints[kHomeB] = testEndpoints(homeId: kHomeB)
        ..claimResultToReturn = const ClaimResult(homeId: kHomeB, homeName: 'Yeni Ev', deviceUuid: 'AHBU-S3-NEW001');

      final result = await h.state.claimDevice('AHBU-S3-NEW001', '123456', homeName: 'Yeni Ev');
      await settle();

      expect(result.homeId, kHomeB);
      expect(h.state.activeHome?.id, kHomeB);
      expect(h.state.homes.map((e) => e.id), containsAll(<String>[kHomeA, kHomeB]));
    });

    test('müşteri akışı (YAVAŞ ağ): sonuç hemen döner; ev seçimi arka planda sonradan tamamlanır', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yeni Ev', topic: 'h_b')]
        ..endpoints[kHomeB] = testEndpoints(homeId: kHomeB)
        ..claimResultToReturn = const ClaimResult(homeId: kHomeB, homeName: 'Yeni Ev', deviceUuid: 'AHBU-S3-NEW001')
        ..fetchHomesGate = Completer<void>();

      ClaimResult? result;
      unawaited(h.state.claimDevice('AHBU-S3-NEW001', '123456').then((r) => result = r));
      await h.clock.elapse(const Duration(seconds: 5));
      expect(result?.homeId, kHomeB, reason: 'sonuç 3 sn sınırında döndü');
      expect(h.state.activeHome?.id, kHomeA, reason: 'ev listesi henüz gelmedi');

      h.cloud.fetchHomesGate!.complete();
      await settle();
      expect(h.state.activeHome?.id, kHomeB, reason: 'liste gelince sahiplenilen ev seçildi (arka plan sürdü)');
    });

    test('servis personeli akışı: müşterinin evi aktif ev YAPILMAZ', () async {
      final h = await readyHarness(role: 'service_user', globalRole: 'service_user');
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome(role: 'service_user'), testHome(id: kHomeB, name: 'Müşteri', role: 'service_user', topic: 'h_b')]
        ..claimResultToReturn = const ClaimResult(homeId: kHomeB, homeName: 'Müşteri', deviceUuid: 'AHBU-S3-NEW001');

      await h.state.claimDevice('AHBU-S3-NEW001', '123456', targetOwner: 'musteri@example.test');
      await settle();

      expect(h.state.activeHome?.id, kHomeA);
      expect(h.state.homeById(kHomeB), isNotNull, reason: 'ev listesi yine de yenilenir');
    });
  });
}
