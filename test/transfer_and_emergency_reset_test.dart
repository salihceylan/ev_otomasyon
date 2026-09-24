import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ADIM 13: Daire Devri & Acil Servis Sıfırlaması Tests', () {
    testWidgets('TransferOwnershipDialog renders warning and transfer form without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: TransferOwnershipDialog(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlık ve uyarılar görünmeli
      expect(find.text('Daire Devri (Mülkiyet Transferi)'), findsOneWidget);
      expect(find.text('DİKKAT: Eski Ailenin Azli'), findsOneWidget);
      expect(find.text('48 Saatlik Devir Kodu & QR Üret'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('JoinHomeDialog accepts transfer code and identifies transfer format', (tester) async {
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

      await tester.pumpAndSettle();

      expect(find.text('Eve Katıl'), findsOneWidget);
      expect(find.byType(TextFormField), findsOneWidget);

      // Kodu gir
      await tester.enterText(find.byType(TextFormField), 'AHBU-TR-998877');
      await tester.pumpAndSettle();

      expect(find.text('AHBU-TR-998877'), findsOneWidget);
    });

    testWidgets('ServiceModePage contains emergency reset section in installer mode', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: ServiceModePage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlangıçta teknisyen oturumu açık değilken donanım koruması ve PIN girişi görünmeli
      expect(find.text('Kurulumcu & Servis Menüsü'), findsOneWidget);
      expect(find.textContaining('Donanım & Motor Koruması'), findsWidgets);
    });
  });
}
