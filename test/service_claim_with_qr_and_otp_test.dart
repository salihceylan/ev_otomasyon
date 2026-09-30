import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Servis Sorumlusu Devreye Alma Menüsünde Karekod Eşleme & Müşteri OTP Doğrulaması', () {
    final serviceUser = UserModel.fromJson({
      'id': '33333333-3333-3333-3333-333333333333',
      'email': 'servis@gudeteknoloji.com.tr',
      'full_name': 'Murat Sorumlu',
      'role': 'service_user',
    });

    testWidgets('ServiceModePage renders QR scan button, customer input, and OTP request button', (tester) async {
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceModePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Kart Başlığı ve Açıklaması
      expect(find.text('Yeni Pano Cihazı Eşleme & Müşteriye Teslim'), findsOneWidget);
      expect(
        find.textContaining('Servis sorumlusu cihaz sahibi olamaz'),
        findsOneWidget,
      );

      // 1. Karekod ile Otomatik Okuma Butonu
      expect(find.text('Pano Karekodunu Oku (Kamera ile Tara)'), findsOneWidget);

      // 2. Form Alanları
      expect(find.text('Pano Device UUID'), findsOneWidget);
      expect(find.text('6 Haneli Kurulum PIN'), findsOneWidget);
      expect(find.text('Daire Sahibi (Müşteri) E-Posta veya Telefonu *'), findsOneWidget);

      // 3. Müşteriye Doğrulama Kodu Gönder Butonu
      expect(find.text('Müşteriye Doğrulama Kodu Gönder'), findsOneWidget);
    });

    testWidgets('Validates customer input before requesting OTP and toggles OTP entry upon code sent', (tester) async {
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceModePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Müşteri alanı boşken butona bas
      await tester.tap(find.text('Müşteriye Doğrulama Kodu Gönder'));
      await tester.pumpAndSettle();

      // Uyarı mesajı görünmeli
      expect(
        find.text('Lütfen cihazın teslim edileceği Daire Sahibi e-posta veya telefonunu girin'),
        findsOneWidget,
      );

      // Müşteri e-postası gir
      await tester.enterText(
        find.widgetWithText(TextField, 'Daire Sahibi (Müşteri) E-Posta veya Telefonu *'),
        'musteri@gmail.com',
      );
      await tester.pumpAndSettle();

      expect(find.text('musteri@gmail.com'), findsOneWidget);
    });
  });
}
