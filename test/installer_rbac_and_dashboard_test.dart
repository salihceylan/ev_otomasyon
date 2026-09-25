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

  group('Teknisyen Rolünün Kaldırılması ve Servis Sorumlusuna Devri Testleri', () {
    final legacyInstallerUser = UserModel.fromJson({
      'id': '33333333-3333-3333-3333-333333333333',
      'email': 'eski_teknisyen@gudeteknoloji.com.tr',
      'full_name': 'Murat Usta',
      'role': 'installer',
    });

    final serviceUser = UserModel.fromJson({
      'id': '22222222-2222-2222-2222-222222222222',
      'email': 'servis@gudeteknoloji.com.tr',
      'full_name': 'Ahmet Sorumlu',
      'role': 'service_user',
    });

    test('Installer role is eliminated and legacy installer flags evaluate to false', () {
      expect(legacyInstallerUser.isInstaller, isFalse);
      expect(legacyInstallerUser.isServiceUser, isFalse);
      expect(legacyInstallerUser.isSuperUser, isFalse);
      expect(legacyInstallerUser.isServiceManagerOrSuper, isFalse);

      final state = AutomationState();
      state.setCurrentUserForTesting(legacyInstallerUser);
      expect(state.isInstaller, isFalse);
      expect(state.isServiceManagerOrSuper, isFalse);
    });

    test('Service user correctly inherits all field and service mode flags', () {
      expect(serviceUser.isInstaller, isFalse);
      expect(serviceUser.isServiceUser, isTrue);
      expect(serviceUser.isSuperUser, isFalse);
      expect(serviceUser.isServiceManagerOrSuper, isTrue);

      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);
      expect(state.isInstaller, isFalse);
      expect(state.isServiceMode, isTrue);
      expect(state.isServiceManagerOrSuper, isTrue);
    });

    testWidgets('DashboardPage renders Yetkili Servis Konsolu with all 8 field tools', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);

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
      expect(find.text('Yetkili Servis Konsolu'), findsOneWidget);
      expect(find.text('Saha Operasyon & Montaj Yönetimi'), findsOneWidget);
      expect(find.byTooltip('Sandviç Menü'), findsOneWidget);

      // 2. Servis Sorumlusu Başlık Kartı
      expect(find.text('Ahmet Sorumlu'), findsOneWidget);
      expect(find.text('YETKİLİ SERVİS'), findsOneWidget);
      expect(find.text('servis@gudeteknoloji.com.tr'), findsOneWidget);

      // 3. Altyapı ve Canlı Durum Bileşenleri
      expect(find.text('API Sunucusu'), findsOneWidget);
      expect(find.text('Veritabanı'), findsOneWidget);
      expect(find.text('MQTT Köprüsü'), findsOneWidget);

      // 4. Sayaçlar
      expect(find.text('Cihaz Envanteri'), findsOneWidget);
      expect(find.text('Devreye Alınan'), findsOneWidget);

      // 5. Birleştirilmiş 8 Saha Görevi & Servis Araçları
      expect(find.text('🛠️ Saha Servis & Devreye Alma Görevleri'), findsOneWidget);
      expect(find.text('Devreye Alma (Commissioning)'), findsOneWidget);
      expect(find.text('Karekod ile Pano Eşle (Claim)'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet & Hasar)'), findsOneWidget);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsOneWidget);
      expect(find.text('Sistem Doktoru (Teşhis)'), findsOneWidget);
      expect(find.text('Cihaz Envanteri & Seri No'), findsOneWidget);
      expect(find.text('Acil Servis Sıfırlaması & Devir'), findsOneWidget);
      expect(find.text('Yetkili Servis Ağı (Salt Okunur)'), findsOneWidget);

      // 6. Eski Teknisyen Konsolu veya Daire Sakini Elemanları KESİNLİKLE OLMAMALI
      expect(find.text('Saha Teknisyeni Konsolu'), findsNothing);
      expect(find.text('Saha Teknisyen Yönetimi'), findsNothing);
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
      expect(find.text('Salon'), findsNothing);
    });

    testWidgets('SuperUserDrawer equips service_user with all field tools without installer artifacts', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);

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
      expect(find.text('Ahmet Sorumlu'), findsOneWidget);
      expect(find.text('servis@gudeteknoloji.com.tr'), findsOneWidget);
      expect(find.text('YETKİLİ SERVİS KONSOLU'), findsOneWidget);

      // Servis Sorumlusu Doğrudan Tüm Saha Araçlarına Sahiptir
      expect(find.text('Yetkili Servis Konsolu'), findsOneWidget);
      expect(find.text('Cihaz Envanteri'), findsOneWidget);
      expect(find.text('Servis Yönetim Konsolu'), findsOneWidget);
      expect(find.text('Devreye Alma & Donanım Testi'), findsOneWidget);
      expect(find.text('Karekod ile Pano Eşle'), findsOneWidget);
      expect(find.text('Sistem Doktoru'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet Modu)'), findsOneWidget);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsOneWidget);

      // Teknisyen başlığı veya menüsü kesinlikle olmamalıdır
      expect(find.text('SAHA TEKNİSYENİ KONSOLU'), findsNothing);
      expect(find.text('Teknisyen Konsolu'), findsNothing);
      expect(find.text('Saha Teknisyenleri'), findsNothing);
    });

    testWidgets('ServiceManagementPage has only 2 tabs and no installers tab', (tester) async {
      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceManagementPage(autoLoad: false, initialTabIndex: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tab 0 Servis Sorumluları
      expect(find.text('Servis Sorumluları'), findsOneWidget);
      expect(find.text('Görevler & Araçlar'), findsOneWidget);
      expect(find.text('Teknisyenler'), findsNothing);

      // Tab 1 Görevler & Araçlar
      await tester.tap(find.text('Görevler & Araçlar'));
      await tester.pumpAndSettle();

      expect(find.text('Tanımlı Servis Görevleri & Eylemleri'), findsOneWidget);
      expect(find.text('1. Cihaz Envanteri & Fabrika Kaydı'), findsOneWidget);
      expect(find.text('2. Devreye Alma (Commissioning) Onayı'), findsOneWidget);
    });
  });
}
