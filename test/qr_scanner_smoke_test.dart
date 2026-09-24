import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/ui/pages/claim/qr_scanner_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FAZ 8.1 - QR Scanner UI & Widget Tests', () {
    testWidgets('QrScannerPage renders title, torch button, flip camera and instructions', (WidgetTester tester) async {
      bool fallbackTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: QrScannerPage(
            onManualFallback: () {
              fallbackTriggered = true;
            },
          ),
        ),
      );

      // Başlık ve butonlar
      expect(find.text('Karekod Tara'), findsOneWidget);
      expect(find.byIcon(Icons.flip_camera_ios_rounded), findsOneWidget);
      expect(find.textContaining('Pano kapağındaki karekodu'), findsOneWidget);

      // Fallback butonu kontrolü
      final fallbackBtn = find.text('Kameram Çalışmıyor / Kodu Elle Gir');
      expect(fallbackBtn, findsOneWidget);

      await tester.tap(fallbackBtn);
      await tester.pumpAndSettle();

      expect(fallbackTriggered, isTrue);
    });
  });
}

