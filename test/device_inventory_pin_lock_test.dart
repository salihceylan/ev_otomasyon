import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// bireysel-7: kurulum PIN'i kilitli kartta süper yönetici kilidi onaylı kaldırabilir
/// (`POST /admin/inventory/:uuid/clear-pin-lock`; sunucu sözleşme 13). servis_kurulum-9: süper yönetici için `claimed_home_id`.
void main() {
  const uid = 'AHBU-S3-A1B2C3';

  InventoryDeviceModel locked({DateTime? until}) => InventoryDeviceModel(
        id: 'inv-1',
        serialNo: 1,
        deviceUuid: uid,
        macAddress: 'E8:F6:0A:11:22:31',
        model: 'ESP32-S3-POE-ETH-8DI-8RO',
        batchNo: 'BATCH-2026-01',
        status: 'IN_STOCK',
        failedAttempts: 5,
        lockedUntil: until,
        createdAt: DateTime.utc(2026, 9, 24, 10),
        qrClaimUrl: 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$uid',
      );

  Future<ServiceHarness> open(WidgetTester tester, String role, InventoryDeviceModel device) async {
    final env = await serviceHarness(role: role, flush: () async {});
    env.cloud.inventory = <InventoryDeviceModel>[device];
    await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(900, 3000));
    await settle(tester);
    return env;
  }

  bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

  test('InventoryDeviceModel: claimed_home_id ve PIN kilidi okunur', () {
    final d = InventoryDeviceModel.fromJson(<String, dynamic>{
      'device_uuid': uid,
      'status': 'CLAIMED',
      'claimed_home_id': 'home-9',
      'claimed_home_name': 'Daire 9',
      'failed_attempts': 5,
      'locked_until': '2026-10-01T12:30:00.000Z',
    });
    expect(d.claimedHomeId, 'home-9');
    expect(d.isPinLocked(DateTime.utc(2026, 10, 1, 12)), isTrue);
    expect(d.isPinLocked(DateTime.utc(2026, 10, 1, 13)), isFalse);
    expect(InventoryDeviceModel.fromJson(<String, dynamic>{'device_uuid': uid}).claimedHomeId, isNull);
  });

  testWidgets('süper: kilitli kartta not ve onaylı "PIN Kilidini Kaldır" -> sunucu çağrısı, liste yenilenir', (tester) async {
    final env = await open(tester, 'super', locked(until: DateTime.utc(2026, 10, 1, 12, 30)));
    addTearDown(env.dispose);
    expect(exists('note_pin_locked_$uid'), isTrue);
    expect(exists('btn_clear_pin_lock_$uid'), isTrue);

    await tester.ensureVisible(find.byKey(const Key('btn_clear_pin_lock_$uid')));
    await tester.tap(find.byKey(const Key('btn_clear_pin_lock_$uid')));
    await settle(tester);
    expect(env.cloud.pinLocksCleared, isEmpty, reason: 'onay beklenir');
    await tester.tap(find.byKey(const Key('btn_simple_confirm')));
    await settle(tester);
    expect(env.cloud.pinLocksCleared, <String>[uid]);
    expect(find.textContaining('PIN kilidi kaldırıldı'), findsOneWidget);
  });

  testWidgets('servis personeli kilidi göremez ama kaldıramaz (yalnız süper)', (tester) async {
    final env = await open(tester, 'staff', locked(until: DateTime.utc(2026, 10, 1, 12, 30)));
    addTearDown(env.dispose);
    expect(exists('note_pin_locked_$uid'), isTrue);
    expect(exists('btn_clear_pin_lock_$uid'), isFalse);
  });

  testWidgets('kilit süresi geçmiş kartta düğme yok', (tester) async {
    final env = await open(tester, 'super', locked(until: DateTime.utc(2026, 9, 30, 12)));
    addTearDown(env.dispose);
    expect(exists('btn_clear_pin_lock_$uid'), isFalse);
    expect(exists('note_pin_locked_$uid'), isFalse);
  });
}
