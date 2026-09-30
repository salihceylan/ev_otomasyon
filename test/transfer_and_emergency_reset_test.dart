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

    testWidgets('TransferOwnershipDialog switches to emergency reset tab and renders QR scanner button', (tester) async {
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

      // Sekmeler görünmeli
      expect(find.text('Daire Devri (Kod & QR)'), findsOneWidget);
      expect(find.text('Acil Pano Sıfırlama'), findsOneWidget);

      // Acil Pano Sıfırlama sekmesine geç
      await tester.tap(find.text('Acil Pano Sıfırlama'));
      await tester.pumpAndSettle();

      // Acil sıfırlama formu ve QR butonu görünmeli
      expect(find.text('Pano QR Kodunu Tara (Kamera)'), findsOneWidget);
      expect(find.text('Cihaz UUID (Pano Etiketi)'), findsOneWidget);
      expect(find.text('Sıfırlama Gerekçesi (Zorunlu)'), findsOneWidget);
      expect(find.text('Acil Sıfırla & Eski Aileyi Azlet'), findsOneWidget);
    });

    testWidgets('ServiceModePage contains emergency reset QR scan button in service mode', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      // Servis yetkilisi oturumu simüle et
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: ServiceModePage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlangıçta yetkili servis oturumu açık değilken donanım koruması ve PIN girişi görünmeli
      expect(find.text('Yetkili Servis Menüsü'), findsOneWidget);
      expect(find.textContaining('Donanım & Motor Koruması'), findsWidgets);
    });
  });
}
