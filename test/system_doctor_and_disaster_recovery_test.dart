import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/system_doctor_dialog.dart';
import 'package:ev_otomasyon/ui/pages/replace_board_dialog.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ADIM 16: Sistem Doktoru & Buluttan Tek Tıkla Pano Değişimi Tests', () {
    testWidgets('SystemDoctorDialog renders healthy 3 diagnostic layers without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      final mockHealthyData = {
        'diagnosis_level': 'ok',
        'diagnosis_title': 'SİSTEM SAĞLIKLI',
        'diagnosis_summary': 'Tüm sistemler normal ve aktif çalışıyor.',
        'cloud': {
          'status': 'OK',
          'label': 'Bulut Sunucu & MQTTS',
          'latency_ms': 24,
        },
        'home_network': {
          'status': 'OK',
          'label': 'Ev Modemi & İnternet',
          'device_ip': '192.168.1.197',
        },
        'hardware_power': {
          'status': 'OK',
          'label': 'Pano Gücü & Donanım',
        },
      };

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: SystemDoctorDialog(initialData: mockHealthyData),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlık ve genel durum
      expect(find.text('Sistem Doktoru'), findsOneWidget);
      expect(find.text('Self-Diagnostic & Otomatik Teşhis'), findsOneWidget);
      expect(find.text('SİSTEM SAĞLIKLI'), findsOneWidget);
      expect(find.text('Tüm sistemler normal ve aktif çalışıyor.'), findsOneWidget);

      // 3 Katman kontrolü
      expect(find.text('1. Bulut Sunucu & MQTTS'), findsOneWidget);
      expect(find.text('2. Ev Modemi & İnternet'), findsOneWidget);
      expect(find.text('3. Pano Gücü & Donanım'), findsOneWidget);

      // Butonlar
      expect(find.text('Testi Yeniden Çalıştır'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('SystemDoctorDialog displays power cut warning and wifi recovery button on failure', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      final mockPowerCutData = {
        'diagnosis_level': 'error',
        'diagnosis_title': 'PANO GÜCÜ / SİGORTA KESİK',
        'diagnosis_summary': 'Panonun bağlı olduğu elektrik sigortası veya adaptörünü kontrol edin.',
        'action_recommendation': 'Sigortayı veya adaptörü kontrol edin.',
        'cloud': {
          'status': 'OK',
          'latency_ms': 18,
        },
        'home_network': {
          'status': 'OFFLINE',
          'last_seen_sec': 1500,
        },
        'hardware_power': {
          'status': 'CUT',
        },
      };

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: SystemDoctorDialog(initialData: mockPowerCutData),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('PANO GÜCÜ / SİGORTA KESİK'), findsOneWidget);
      expect(find.text('Panonun bağlı olduğu elektrik sigortası veya adaptörünü kontrol edin.'), findsOneWidget);
      expect(find.text('Modem/Şifre Değiştiyse: Kurtarma Modu'), findsOneWidget);
    });

    testWidgets('ReplaceBoardDialog renders disaster recovery guidance and validates serial number', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: ReplaceBoardDialog(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlık ve açıklama
      expect(find.text('Pano Değişimi & Kurtarma'), findsOneWidget);
      expect(find.text('Disaster Recovery (5 Saniyede Aktarım)'), findsOneWidget);

      // Yeni pano giriş alanı ve buton
      expect(find.text('Yeni Pano Seri No (UUID)'), findsOneWidget);
      expect(find.text('Yeni Panonun 6 Haneli Kurulum PIN\'i'), findsOneWidget);
      expect(find.text('Eski Pano Ayarlarını Yeni Karta Aktar'), findsOneWidget);

      // Boş seri no ile butona basıldığında uyarı vermelidir
      final submitBtn = find.text('Eski Pano Ayarlarını Yeni Karta Aktar');
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      expect(find.text('Lütfen yeni panonun UUID kodunu girin.'), findsOneWidget);

      // Yeni seri no ve PIN gir
      final textFields = find.byType(TextField);
      expect(textFields, findsNWidgets(3));

      await tester.enterText(textFields.at(0), 'AHBU-S3-A1B2C3D4');
      await tester.enterText(textFields.at(1), '123456');
      await tester.enterText(textFields.at(2), 'Yıldırım hasarı nedeniyle pano değişimi');
      await tester.pumpAndSettle();

      expect(find.text('AHBU-S3-A1B2C3D4'), findsOneWidget);
      expect(find.text('123456'), findsOneWidget);
    });

    testWidgets('DeviceSettingsPage renders System Doctor and Disaster Recovery cards without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: DeviceSettingsPage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Sistem Doktoru kartı kontrolü
      expect(find.text('Sistem Doktoru (Teşhis & Analiz)'), findsOneWidget);
      expect(find.text('Sistem Doktorunu Çalıştır'), findsOneWidget);

      // Pano Değişimi kartı kontrolü
      expect(find.text('Felaket Kurtarma & Pano Değişimi'), findsOneWidget);
      expect(find.text('Pano Değişimi Sihirbazını Aç'), findsOneWidget);
    });
  });
}

