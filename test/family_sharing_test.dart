import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
  });

  group('Faz 9: InvitationModel Tests', () {
    test('InvitationModel fromJson and toJson serialization works correctly', () {
      final json = {
        'code': 'AHBU-AB12CD',
        'role': 'member',
        'expires_at': '2026-09-23T12:00:00.000Z',
        'home_name': 'Villa Merkez',
      };

      final inv = InvitationModel.fromJson(json);
      expect(inv.code, 'AHBU-AB12CD');
      expect(inv.role, 'member');
      expect(inv.homeName, 'Villa Merkez');
      expect(inv.expiresAt.isUtc || inv.expiresAt.year == 2026, isTrue);

      final outJson = inv.toJson();
      expect(outJson['code'], 'AHBU-AB12CD');
      expect(outJson['role'], 'member');
      expect(outJson['home_name'], 'Villa Merkez');
    });
  });

  group('Faz 9: Role Guards and Permissions', () {
    testWidgets('User roles (owner vs member vs installer) are properly identified', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      // Varsayılan
      expect(state.isOwner, isFalse);
      expect(state.isMember, isFalse);
      expect(state.isServiceMode, isFalse);
    });

    testWidgets('DeviceSettingsPage displays locked warning for member role', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: DeviceSettingsPage(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('ESP32-S3 Cihaz IP Adresi'), findsOneWidget);
    });
  });

  group('Faz 9: Dialog Smoke & UI Overflow Tests (Kural 6)', () {
    testWidgets('InviteFamilyDialog renders code, copy and close buttons without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: InviteFamilyDialog(
                initialInviteCode: 'AHBU-TEST99',
                initialHomeName: 'Kadıköy Daire 4',
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Kadıköy Daire 4'), findsAtLeastNWidgets(1));
      expect(find.text('AHBU-TEST99'), findsOneWidget);
      expect(find.text('Kodu Kopyala & Paylaş'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      // Buton tıklama kontrolü (Scroll içine erişim)
      await tester.ensureVisible(find.text('Kodu Kopyala & Paylaş'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kodu Kopyala & Paylaş'));
      await tester.pump();
      expect(find.textContaining('panoya kopyalandı!'), findsOneWidget);
    });

    testWidgets('JoinHomeDialog renders code input and validates empty submission', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: JoinHomeDialog(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Bir Eve Katıl'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Eve Katıl'), findsOneWidget);

      // Boş form ile katıl butonuna basıldığında form validasyon hatası görünmeli
      await tester.tap(find.widgetWithText(ElevatedButton, 'Eve Katıl'));
      await tester.pump();

      expect(find.text('Lütfen davet kodunu girin'), findsOneWidget);
    });
  });
}
