import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/utils/qr_claim_parser.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FAZ 8.2 - QrClaimParser Unit Tests', () {
    test('parses official URL format with query parameters', () {
      const url = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=AHBU-S3-PANEL-01&pin=123456';
      final result = QrClaimParser.parse(url);

      expect(result, isNotNull);
      expect(result!.uid, 'AHBU-S3-PANEL-01');
      expect(result.pin, '123456');
    });

    test('parses alternative URL query params (device_uuid & setup_pin)', () {
      const url = 'https://api.gudeteknoloji.com.tr/claim?device_uuid=AHBU-DEV-99&setup_pin=654321';
      final result = QrClaimParser.parse(url);

      expect(result, isNotNull);
      expect(result!.uid, 'AHBU-DEV-99');
      expect(result.pin, '654321');
    });

    test('parses JSON format with uid and pin', () {
      const jsonStr = '{"uid": "AHBU-JSON-BOARD", "pin": "987654"}';
      final result = QrClaimParser.parse(jsonStr);

      expect(result, isNotNull);
      expect(result!.uid, 'AHBU-JSON-BOARD');
      expect(result.pin, '987654');
    });

    test('parses plain text format with colon or slash separator', () {
      final resColon = QrClaimParser.parse('AHBU-PLAIN-01:112233');
      expect(resColon, isNotNull);
      expect(resColon!.uid, 'AHBU-PLAIN-01');
      expect(resColon.pin, '112233');

      final resSlash = QrClaimParser.parse('AHBU-PLAIN-02/445566');
      expect(resSlash, isNotNull);
      expect(resSlash!.uid, 'AHBU-PLAIN-02');
      expect(resSlash.pin, '445566');
    });

    test('returns null for corrupted or invalid inputs', () {
      expect(QrClaimParser.parse(null), isNull);
      expect(QrClaimParser.parse(''), isNull);
      expect(QrClaimParser.parse('   '), isNull);
      expect(QrClaimParser.parse('sadece-bir-metin'), isNull);
      expect(QrClaimParser.parse('AHBU-PANEL:12'), isNull); // PIN çok kısa (<4)
      expect(QrClaimParser.parse('{"uid": ""}'), isNull);
    });
  });

  group('FAZ 8.2 - ClaimManualDialog Widget Tests', () {
    testWidgets('renders fields with initial values and validates empty input', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AutomationState()),
            ],
            child: const Scaffold(
              body: ClaimManualDialog(
                initialUid: 'AHBU-INIT-01',
                initialPin: '654321',
              ),
            ),
          ),
        ),
      );

      // Başlangıç değerleri formda olmalıdır
      expect(find.text('AHBU-INIT-01'), findsOneWidget);
      expect(find.text('654321'), findsOneWidget);

      // PIN temizlenip submit edildiğinde hata vermelidir
      await tester.enterText(find.byType(TextFormField).at(1), '');
      final submitBtn = find.widgetWithText(ElevatedButton, 'Eşle & Sahiplen');
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      expect(find.text('Lütfen 6 haneli kurulum PIN kodunu girin'), findsOneWidget);
    });

    testWidgets('validates short PIN input', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AutomationState()),
            ],
            child: const Scaffold(
              body: ClaimManualDialog(
                initialUid: 'AHBU-INIT-01',
                initialPin: '123',
              ),
            ),
          ),
        ),
      );

      final submitBtn = find.widgetWithText(ElevatedButton, 'Eşle & Sahiplen');
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      expect(find.text('PIN kodu tam 6 haneli olmalıdır'), findsOneWidget);
    });
  });
}

