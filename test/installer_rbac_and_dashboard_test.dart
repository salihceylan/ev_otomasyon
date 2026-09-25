import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/widgets/super_user_drawer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Saha Teknisyeni (Installer) Rol ve Ekran İzolasyon Testleri', () {
    final installerUser = UserModel.fromJson({
      'id': '33333333-3333-3333-3333-333333333333',
      'email': 'teknisyen@gudeteknoloji.com.tr',
      'full_name': 'Murat Usta',
      'role': 'installer',
    });

    test('UserModel and AutomationState correctly report installer role flags', () {
      expect(installerUser.isInstaller, isTrue);
      expect(installerUser.isServiceUser, isFalse);
      expect(installerUser.isSuperUser, isFalse);
      expect(installerUser.isServiceManagerOrSuper, isFalse);

      final state = AutomationState();
      state.setCurrentUserForTesting(installerUser);
      expect(state.isInstaller, isTrue);
      expect(state.isServiceMode, isTrue);
      expect(state.isServiceManagerOrSuper, isFalse);
    });

    testWidgets('DashboardPage renders Saha Teknisyeni Konsolu for installer role', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setCurrentUserForTesting(installerUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const DashboardPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. AppBar Kontrolleri
      expect(find.text('Saha Teknisyeni Konsolu'), findsOneWidget);
      expect(find.text('AHBU Montaj & Servis Altyapısı'), findsOneWidget);
      expect(find.byTooltip('Sandviç Menü'), findsOneWidget);

      // 2. Saha Teknisyeni Başlık Kartı
      expect(find.text('Murat Usta'), findsOneWidget);
      expect(find.text('SAHA TEKNİSYENİ'), findsOneWidget);
      expect(find.text('teknisyen@gudeteknoloji.com.tr'), findsOneWidget);

      // 3. Altyapı ve Canlı Durum Bileşenleri
      expect(find.text('API Sunucusu'), findsOneWidget);
      expect(find.text('Veritabanı'), findsOneWidget);
      expect(find.text('MQTT Köprüsü'), findsOneWidget);

      // 4. Sayaçlar
      expect(find.text('Aktif Daire Pano'), findsOneWidget);
      expect(find.text('Cihaz Envanteri'), findsOneWidget);

      // 5. Saha Görevleri & Araçları
      expect(find.text('🛠️ Saha Servis & Devreye Alma Görevleri'), findsOneWidget);
      expect(find.text('Devreye Alma (Commissioning)'), findsOneWidget);
      expect(find.text('Karekod ile Pano Eşle (Claim)'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet & Hasar)'), findsOneWidget);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsOneWidget);
      expect(find.text('Sistem Doktoru (Teşhis)'), findsOneWidget);
      expect(find.text('Cihaz Envanteri & Seri No'), findsOneWidget);
      expect(find.text('Acil Servis Sıfırlaması'), findsOneWidget);

      // 6. Güvenlik Uyarısı
      expect(find.text('Yetkili Servis & Montaj Güvenliği Uyarısı'), findsOneWidget);

      // 7. Daire Sakini Kontrolleri KESİNLİKLE GÖRÜNMEMELİDİR
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
      expect(find.text('Karekod ile Cihaz Eşle'), findsNothing);
      expect(find.text('Salon'), findsNothing);
      expect(find.text('Mutfak'), findsNothing);
      expect(find.text('Evden Çıkıyorum'), findsNothing);
      expect(find.text('Sinema Modu'), findsNothing);
    });

    testWidgets('SuperUserDrawer hides manager sections and shows installer tools for installer', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setCurrentUserForTesting(installerUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const Scaffold(
              drawer: SuperUserDrawer(),
              body: Center(child: Text('Dashboard')),
            ),
          ),
        ),
      );

      final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Drawer Header
      expect(find.text('Murat Usta'), findsOneWidget);
      expect(find.text('teknisyen@gudeteknoloji.com.tr'), findsOneWidget);
      expect(find.text('SAHA TEKNİSYENİ KONSOLU'), findsOneWidget);

      // Teknisyen Elemanları Görünmeli
      expect(find.text('Teknisyen Konsolu'), findsOneWidget);
      expect(find.text('Cihaz Envanteri'), findsOneWidget);
      expect(find.text('Servis Modu & Kalibrasyon'), findsOneWidget);
      expect(find.text('Karekod ile Pano Eşle'), findsOneWidget);
      expect(find.text('Sistem Doktoru'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet Modu)'), findsOneWidget);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsOneWidget);

      // YÖNETİCİ MENÜLERİ KESİNLİKLE GİZLİ OLMALIDIR
      expect(find.text('Servis Sorumluları'), findsNothing);
      expect(find.text('Saha Teknisyenleri'), findsNothing);
    });

    testWidgets('ServiceManagementPage locks managers & installers tabs and hides FAB for installer', (tester) async {
      final state = AutomationState();
      state.setCurrentUserForTesting(installerUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceManagementPage(autoLoad: false, initialTabIndex: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tab 0 Sorumlular: Kısıtlama Uyarısı görünmeli, Sorumlu Ekle FAB olmamalı
      expect(find.text('Yetkili Servis Sorumluları Yönetimi'), findsOneWidget);
      expect(find.text('Sorumlu Ekle'), findsNothing);

      // Tab 1 Teknisyenler: Kısıtlama Uyarısı görünmeli, Teknisyen Ekle FAB olmamalı
      await tester.tap(find.text('Teknisyenler'));
      await tester.pumpAndSettle();

      expect(find.text('Saha Teknisyenleri Yönetimi'), findsOneWidget);
      expect(find.text('Teknisyen Ekle'), findsNothing);

      // Tab 2 Görevler & Araçlar: Açılmalı ve teknisyen tüm servis araçlarını kullanabilmeli
      await tester.tap(find.text('Görevler & Araçlar'));
      await tester.pumpAndSettle();

      expect(find.text('Tanımlı Servis Görevleri & Eylemleri'), findsOneWidget);
      expect(find.text('1. Cihaz Envanteri & Fabrika Kaydı'), findsOneWidget);
      expect(find.text('2. Devreye Alma (Commissioning) Onayı'), findsOneWidget);
    });
  });
}
