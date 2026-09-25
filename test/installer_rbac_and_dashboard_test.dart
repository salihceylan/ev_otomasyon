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

  group('Yetkili Servis Sorumlusu (Service User) Rol ve Ekran İzolasyon Testleri', () {
    final serviceUser = UserModel.fromJson({
      'id': '33333333-3333-3333-3333-333333333333',
      'email': 'servis@gudeteknoloji.com.tr',
      'full_name': 'Murat Sorumlu',
      'role': 'service_user',
    });

    test('UserModel and AutomationState correctly report service_user role flags', () {
      expect(serviceUser.isInstaller, isFalse);
      expect(serviceUser.isServiceUser, isTrue);
      expect(serviceUser.isSuperUser, isFalse);
      expect(serviceUser.isServiceManagerOrSuper, isTrue);

      final state = AutomationState();
      state.setCurrentUserForTesting(serviceUser);
      expect(state.isInstaller, isFalse);
      expect(state.isServiceUser, isTrue);
      expect(state.isServiceMode, isTrue);
      expect(state.isServiceManagerOrSuper, isTrue);
    });

    testWidgets('DashboardPage renders Yetkili Servis Konsolu for service_user role', (tester) async {
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

      // 2. Saha Servis Sorumlusu Başlık Kartı
      expect(find.text('Murat Sorumlu'), findsOneWidget);
      expect(find.text('YETKİLİ SERVİS'), findsOneWidget);
      expect(find.text('servis@gudeteknoloji.com.tr'), findsOneWidget);

      // 3. Altyapı ve Canlı Durum Bileşenleri
      expect(find.text('API Sunucusu'), findsOneWidget);
      expect(find.text('Veritabanı'), findsOneWidget);
      expect(find.text('MQTT Köprüsü'), findsOneWidget);

      // 4. Sayaçlar
      expect(find.text('Pano Envanteri'), findsOneWidget);
      expect(find.text('Devreye Alınan'), findsOneWidget);

      // 5. Saha Görevleri & Araçları
      expect(find.text('🛠️ Saha Servis & Devreye Alma Görevleri'), findsOneWidget);
      expect(find.text('Devreye Alma (Commissioning)'), findsOneWidget);
      expect(find.text('Karekod ile Pano Eşle (Claim)'), findsOneWidget);
      expect(find.text('Cihaz Envanteri & Seri No'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet & Hasar)'), findsOneWidget);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsOneWidget);
      expect(find.text('Sistem Doktoru (Teşhis)'), findsOneWidget);
      expect(find.text('Acil Sıfırlama & Mülk Devri'), findsOneWidget);

      // 6. Güvenlik Uyarısı
      expect(find.text('Yetkili Servis Güvenlik Uyarısı'), findsOneWidget);

      // 7. Daire Sakini Kontrolleri KESİNLİKLE GÖRÜNMEMELİDİR
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
      expect(find.text('Salon'), findsNothing);
      expect(find.text('Mutfak'), findsNothing);
    });

    testWidgets('SuperUserDrawer shows service console and tools for service_user', (tester) async {
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
      expect(find.text('Murat Sorumlu'), findsOneWidget);
      expect(find.text('servis@gudeteknoloji.com.tr'), findsOneWidget);
      expect(find.text('YETKİLİ SERVİS KONSOLU'), findsOneWidget);

      // Servis Elemanları Görünmeli
      expect(find.text('Servis Konsolu'), findsOneWidget);
      expect(find.text('Cihaz Envanteri'), findsOneWidget);
      expect(find.text('Servis Sorumluları'), findsOneWidget);
      expect(find.text('Görevler & Araçlar'), findsOneWidget);
      expect(find.text('Servis Modu & Kalibrasyon'), findsOneWidget);
      expect(find.text('Karekod ile Pano Eşle'), findsOneWidget);
      expect(find.text('Sistem Doktoru'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet Modu)'), findsOneWidget);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsOneWidget);
    });

    testWidgets('ServiceManagementPage locks managers tab creation and shows tools for service_user', (tester) async {
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

      // Tab 0 Sorumlular: Kısıtlama Uyarısı görünmeli, Sorumlu Ekle FAB olmamalı
      expect(find.text('Süper Yöneticiler & Servis Sorumluları'), findsOneWidget);
      expect(find.text('Sorumlu Ekle'), findsNothing);

      // Tab 1 Görevler & Araçlar: Açılmalı ve tüm servis araçlarını kullanabilmeli
      await tester.tap(find.text('Görevler & Araçlar'));
      await tester.pumpAndSettle();

      expect(find.text('Tanımlı Servis Görevleri & Eylemleri'), findsOneWidget);
      expect(find.text('1. Cihaz Envanteri & Fabrika Kaydı'), findsOneWidget);
      expect(find.text('2. Devreye Alma (Commissioning) Onayı'), findsOneWidget);
    });
  });
}
