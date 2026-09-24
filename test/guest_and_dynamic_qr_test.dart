import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ADIM 12: Aile İçi Katılım & Dinamik QR / Misafir Yönetimi Tests', () {
    testWidgets('InviteFamilyDialog displays Family and Guest tabs and renders duration options', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: InviteFamilyDialog(
                initialInviteCode: 'AHBU-TEST12',
                initialHomeName: 'Gude Akıllı Villa',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Sekmeler görünmeli
      expect(find.text('Aile Bireyi'), findsOneWidget);
      expect(find.text('Süreli Misafir'), findsOneWidget);
      expect(find.text('AİLE KATILIM KODU'), findsOneWidget);
      expect(find.text('AHBU-TEST12'), findsOneWidget);

      // Süreli Misafir sekmesine tıkla
      await tester.tap(find.text('Süreli Misafir'));
      await tester.pumpAndSettle();

      // Misafir süre seçenekleri ve alanları görünmeli
      expect(find.text('Erişim Süresi Belirleyin:'), findsOneWidget);
      expect(find.text('2 Saat'), findsOneWidget);
      expect(find.text('4 Saat'), findsOneWidget);
      expect(find.text('8 Saat (Mesai)'), findsOneWidget);
      expect(find.text('24 Saat (1 Gün)'), findsOneWidget);
      expect(find.text('Misafir / Görevli Adı (İsteğe Bağlı)'), findsOneWidget);
    });

    testWidgets('FamilyMembersPage renders member list and invite button without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: FamilyMembersPage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlık ve butonlar görünmeli
      expect(find.text('Aile & Misafir Yönetimi'), findsOneWidget);
      expect(find.text('Yeni Birey / Misafir Davet Et (QR Üret)'), findsOneWidget);
      expect(find.text('Kayıtlı Kişiler & Yetkiler'), findsOneWidget);
    });

    test('AutomationState handles isGuest role accurately', () {
      final state = AutomationState();
      expect(state.isGuest, isFalse);
    });
  });
}

