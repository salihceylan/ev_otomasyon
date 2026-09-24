import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sampleDevice1 = InventoryDeviceModel(
    id: 'inv-uuid-001',
    serialNo: 1,
    deviceUuid: 'AHBU-S3-A1B2C3',
    macAddress: 'E8:F6:0A:11:22:33',
    model: 'ESP32-S3-POE-ETH-8DI-8RO',
    batchNo: 'BATCH-2026-01',
    status: 'IN_STOCK',
    createdAt: DateTime(2026, 9, 24, 10, 0),
    qrClaimUrl: 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=AHBU-S3-A1B2C3',
  );

  final sampleDevice2 = InventoryDeviceModel(
    id: 'inv-uuid-002',
    serialNo: 2,
    deviceUuid: 'AHBU-S3-D4E5F6',
    macAddress: 'E8:F6:0A:44:55:66',
    model: 'ESP32-S3-POE-ETH-8DI-8RO',
    batchNo: 'BATCH-2026-01',
    status: 'CLAIMED',
    claimedHomeName: 'Daire 5 - Nilüfer',
    claimedUserEmail: 'ali@example.com',
    claimedAt: DateTime(2026, 9, 24, 15, 30),
    createdAt: DateTime(2026, 9, 24, 11, 0),
    qrClaimUrl: 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=AHBU-S3-D4E5F6',
  );

  final sampleDevice3 = InventoryDeviceModel(
    id: 'inv-uuid-003',
    serialNo: 3,
    deviceUuid: 'AHBU-S3-778899',
    macAddress: 'E8:F6:0A:77:88:99',
    model: 'ESP32-S3-POE-ETH-8DI-8RO',
    batchNo: 'BATCH-2026-01',
    status: 'SUSPENDED',
    createdAt: DateTime(2026, 9, 24, 12, 0),
    qrClaimUrl: 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=AHBU-S3-778899',
  );

  Widget createTestWidget(AutomationState state) {
    return MaterialApp(
      home: ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const DeviceInventoryPage(autoLoad: false),
      ),
    );
  }

  group('Cihaz Envanteri ve Karekod Yönetimi Testleri', () {
    testWidgets('DeviceInventoryPage displays stats header, search bar, and filter chips without overflow',
        (tester) async {
      final state = AutomationState();
      state.setCurrentUserForTesting(
        UserModel(
          id: 1,
          email: 'admin@gude.com',
          role: 'super_user',
          fullName: 'Süper Yönetici',
          phone: '',
        ),
      );
      state.setInventoryDevicesForTesting(
        [sampleDevice1, sampleDevice2, sampleDevice3],
        stats: {'total': 3, 'in_stock': 1, 'claimed': 1, 'suspended': 1},
      );

      await tester.pumpWidget(createTestWidget(state));
      await tester.pumpAndSettle();

      expect(find.text('Cihaz Envanteri'), findsOneWidget);
      expect(find.text('Toplam'), findsOneWidget);
      expect(find.text('Stokta'), findsOneWidget);
      expect(find.text('Devrede'), findsOneWidget);
      expect(find.text('Askıda'), findsOneWidget);
      expect(find.text('Tümü'), findsOneWidget);
      expect(find.text('Stokta Hazır'), findsOneWidget);
      expect(find.text('Devrede / Aktif'), findsOneWidget);
      expect(find.text('Askıya Alınan'), findsOneWidget);
    });

    testWidgets('DeviceInventoryPage lists devices with serial badges, UUID, MAC, and claim info', (tester) async {
      final state = AutomationState();
      state.setCurrentUserForTesting(
        UserModel(
          id: 1,
          email: 'admin@gude.com',
          role: 'super_user',
          fullName: 'Süper Yönetici',
          phone: '',
        ),
      );
      state.setInventoryDevicesForTesting(
        [sampleDevice1, sampleDevice2, sampleDevice3],
        stats: {'total': 3, 'in_stock': 1, 'claimed': 1, 'suspended': 1},
      );

      await tester.pumpWidget(createTestWidget(state));
      await tester.pumpAndSettle();

      expect(find.text('#0001'), findsOneWidget);
      expect(find.text('#0002'), findsOneWidget);
      expect(find.text('AHBU-S3-A1B2C3'), findsOneWidget);
      expect(find.text('AHBU-S3-D4E5F6'), findsOneWidget);
      expect(find.text('STOKTA'), findsOneWidget);
      expect(find.text('DEVREDE'), findsOneWidget);
      expect(find.textContaining('Daire 5 - Nilüfer'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(find.text('#0003'), findsOneWidget);
      expect(find.text('AHBU-S3-778899'), findsOneWidget);
      expect(find.text('ASKIDA'), findsOneWidget);
    });

    testWidgets('Tapping Karekod Gör opens dialog with QrImageView and claim link', (tester) async {
      final state = AutomationState();
      state.setCurrentUserForTesting(
        UserModel(
          id: 1,
          email: 'admin@gude.com',
          role: 'super_user',
          fullName: 'Süper Yönetici',
          phone: '',
        ),
      );
      state.setInventoryDevicesForTesting([sampleDevice1]);

      await tester.pumpWidget(createTestWidget(state));
      await tester.pumpAndSettle();

      final qrBtn = find.text('Karekod Gör').first;
      await tester.tap(qrBtn);
      await tester.pumpAndSettle();

      expect(find.text('Cihaz Karekodu (#0001)'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('Karekod Bağlantısını Kopyala'), findsOneWidget);
    });

    testWidgets('Empty inventory renders informative guide message and retry button', (tester) async {
      final state = AutomationState();
      state.setCurrentUserForTesting(
        UserModel(
          id: 1,
          email: 'admin@gude.com',
          role: 'super_user',
          fullName: 'Süper Yönetici',
          phone: '',
        ),
      );
      state.setInventoryDevicesForTesting([]);

      await tester.pumpWidget(createTestWidget(state));
      await tester.pumpAndSettle();

      expect(find.text('Envanterde Cihaz Bulunmuyor'), findsOneWidget);
      expect(find.textContaining('Karekod Üret & Etiket Bas'), findsOneWidget);
    });
  });
}
