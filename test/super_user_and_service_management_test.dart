import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/widgets/super_user_drawer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ADIM 19: Süper Yönetici & Servis Yönetim Sistemi Testleri', () {
    test('UserModel role helpers and JSON parsing works correctly', () {
      final superUser = UserModel.fromJson({
        'id': '1ab81ee3-5e3e-4b4f-ad0b-5b765d540575',
        'email': 'salihceylan@gmail.com',
        'full_name': 'Salih Ceylan',
        'role': 'super_user',
        'phone': '+905551234567',
        'admin_notes': 'Sistem Kurucusu',
      });

      expect(superUser.isSuperUser, isTrue);
      expect(superUser.isServiceUser, isFalse);
      expect(superUser.isServiceManagerOrSuper, isTrue);
      expect(superUser.effectiveId, equals('1ab81ee3-5e3e-4b4f-ad0b-5b765d540575'));
      expect(superUser.adminNotes, equals('Sistem Kurucusu'));

      final serviceUser = UserModel.fromJson({
        'id': '22222222-2222-2222-2222-222222222222',
        'email': 'servis@gudeteknoloji.com.tr',
        'full_name': 'Servis Müdürü',
        'role': 'service_user',
      });

      expect(serviceUser.isSuperUser, isFalse);
      expect(serviceUser.isServiceUser, isTrue);
      expect(serviceUser.isServiceManagerOrSuper, isTrue);
    });

    test('AutomationState reports isSuperUser and isServiceManagerOrSuper correctly', () {
      final state = AutomationState();
      expect(state.isSuperUser, isFalse);
      expect(state.isServiceManagerOrSuper, isFalse);
    });

    testWidgets('ServiceManagementPage renders tabs and tools for service_user without overflow', (tester) async {
      final state = AutomationState();
      final serviceUser = UserModel.fromJson({
        'id': '2bb81ee3-5e3e-4b4f-ad0b-5b765d540576',
        'email': 'servis@gudeteknoloji.com.tr',
        'full_name': 'Servis Sorumlusu',
        'role': 'service_user',
      });
      state.setCurrentUserForTesting(serviceUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceManagementPage(autoLoad: false),
          ),
        ),
      );

      // Servis sorumlusunda sekme çubuğu ve saha araçları görünmeli
      expect(find.text('Servis & Saha Konsolu'), findsOneWidget);
      expect(find.text('Sorumlular'), findsOneWidget);
      expect(find.text('Görevler & Araçlar'), findsOneWidget);

      // Görevler sekmesine geçiş
      await tester.tap(find.text('Görevler & Araçlar'));
      await tester.pumpAndSettle();

      expect(find.text('Tanımlı Servis Görevleri & Eylemleri'), findsOneWidget);
      expect(find.text('1. Cihaz Envanteri & Fabrika Kaydı'), findsOneWidget);
      expect(find.text('2. Devreye Alma (Commissioning) Onayı'), findsOneWidget);

      // Aşağı kaydır
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(find.text('3. Acil Servis Sıfırlaması & Daire Devri'), findsOneWidget);
    });

    testWidgets('ServiceManagementPage hides Görevler & Araçlar tab for super_user and shows direct Sorumlular list', (tester) async {
      final state = AutomationState();
      final superUser = UserModel.fromJson({
        'id': '1ab81ee3-5e3e-4b4f-ad0b-5b765d540575',
        'email': 'salihceylan@gmail.com',
        'full_name': 'Salih Ceylan',
        'role': 'super_user',
      });
      state.setCurrentUserForTesting(superUser);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceManagementPage(autoLoad: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Süper kullanıcıda başlık Servis Sorumluları Yönetimi olmalı
      expect(find.text('Servis Sorumluları Yönetimi'), findsOneWidget);
      // Görevler & Araçlar sekmesi Süper Kullanıcıda KESİNLİKLE OLMAMALIDIR
      expect(find.text('Görevler & Araçlar'), findsNothing);
      // Doğrudan Sorumlu Ekle butonu görünmeli
      expect(find.text('Sorumlu Ekle'), findsOneWidget);
    });

    testWidgets('SuperUserDrawer renders menu items without overflow', (tester) async {
      final state = AutomationState();
      final user = UserModel.fromJson({
        'id': '1ab81ee3-5e3e-4b4f-ad0b-5b765d540575',
        'email': 'salihceylan@gmail.com',
        'full_name': 'Salih Ceylan',
        'role': 'super_user',
      });
      state.setCurrentUserForTesting(user);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const Scaffold(
              drawer: SuperUserDrawer(),
              body: Center(child: Text('Body')),
            ),
          ),
        ),
      );

      // Open drawer
      final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      expect(find.text('Salih Ceylan'), findsOneWidget);
      expect(find.text('salihceylan@gmail.com'), findsOneWidget);
      expect(find.text('SÜPER YÖNETİCİ KONSOLU'), findsOneWidget);
      expect(find.text('Yönetici Konsolu'), findsOneWidget);
      expect(find.text('Cihaz Envanteri'), findsOneWidget);
      expect(find.text('Servis Sorumluları'), findsOneWidget);
      expect(find.text('Sistem Doktoru'), findsOneWidget);

      // Saha montaj & servis araçları Süper Kullanıcıda KESİNLİKLE GÖRÜNMEMELİDİR
      expect(find.text('Görevler & Araçlar'), findsNothing);
      expect(find.text('Servis Modu & Kalibrasyon'), findsNothing);
      expect(find.text('Karekod ile Pano Eşle'), findsNothing);
      expect(find.text('Pano Değişimi (Afet Modu)'), findsNothing);
      expect(find.text('Wi-Fi Yapılandırma & Kurtarma'), findsNothing);

      // Scroll ListView to view exit button
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(find.text('Güvenli Çıkış Yap'), findsOneWidget);
    });

    testWidgets('DashboardPage renders Super User Console when isSuperUser is true', (tester) async {
      final state = AutomationState();
      final user = UserModel.fromJson({
        'id': '1ab81ee3-5e3e-4b4f-ad0b-5b765d540575',
        'email': 'salihceylan@gmail.com',
        'full_name': 'Salih Ceylan',
        'role': 'super_user',
      });
      state.setCurrentUserForTesting(user);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const DashboardPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Süper Yönetici Konsolu başlığı ve Sandviç Menü ikonu
      expect(find.text('Süper Yönetici Konsolu'), findsOneWidget);
      expect(find.text('AHBU Altyapı & Servis Denetimi'), findsOneWidget);
      expect(find.byTooltip('Sandviç Menü'), findsOneWidget);

      // Altyapı bileşenleri
      expect(find.text('API Sunucusu'), findsOneWidget);
      expect(find.text('Veritabanı'), findsOneWidget);
      expect(find.text('MQTT Köprüsü'), findsOneWidget);

      // Daire kontrolleri GÖRÜNMEMELİ
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
      expect(find.text('Karekod ile Cihaz Eşle'), findsNothing);
      expect(find.text('Salon'), findsNothing);
      expect(find.text('Mutfak'), findsNothing);
    });

    testWidgets('DashboardPage renders Yetkili Servis Konsolu when user is service_user', (tester) async {
      final state = AutomationState();
      final user = UserModel.fromJson({
        'id': '22222222-2222-2222-2222-222222222222',
        'email': 'servis@gudeteknoloji.com.tr',
        'full_name': 'Ahmet Yılmaz',
        'role': 'service_user',
      });
      state.setCurrentUserForTesting(user);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const DashboardPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Yetkili Servis Konsolu başlığı ve Sandviç Menü
      expect(find.text('Yetkili Servis Konsolu'), findsOneWidget);
      expect(find.text('Saha Operasyon & Montaj Yönetimi'), findsOneWidget);
      expect(find.byTooltip('Sandviç Menü'), findsOneWidget);

      // Servis Sorumlusu Kartı & Görevleri
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);
      expect(find.text('YETKİLİ SERVİS'), findsOneWidget);
      expect(find.text('🛠️ Saha Servis & Devreye Alma Görevleri'), findsOneWidget);

      // Görev Listesi
      expect(find.text('Cihaz Envanteri & Seri No'), findsOneWidget);
      expect(find.text('Devreye Alma (Commissioning)'), findsOneWidget);
      expect(find.text('Pano Değişimi (Afet & Hasar)'), findsOneWidget);

      // Daire sakini kontrolleri görünmemeli
      expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
      expect(find.text('Salon'), findsNothing);
    });

    testWidgets('ServiceManagementPage hides Sorumlu Ekle button for service_user on Tab 0', (tester) async {
      final state = AutomationState();
      final user = UserModel.fromJson({
        'id': '22222222-2222-2222-2222-222222222222',
        'email': 'servis@gudeteknoloji.com.tr',
        'full_name': 'Ahmet Yılmaz',
        'role': 'service_user',
      });
      state.setCurrentUserForTesting(user);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceManagementPage(autoLoad: false, initialTabIndex: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sorumlular tabında "Sorumlu Ekle" butonu GÖRÜNMEMELİ
      expect(find.text('Sorumlu Ekle'), findsNothing);

      // Bilgilendirme uyarısı görünmeli
      expect(
        find.text('Servis sorumlusu ve yönetici hesapları yalnızca Süper Yönetici tarafından tanımlanabilir ve yönetilebilir.'),
        findsOneWidget,
      );

      // Görevler & Araçlar tabına geçince FAB olmamalı
      await tester.tap(find.text('Görevler & Araçlar'));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('ServiceManagementPage shows Sorumlu Ekle button for super_user on Tab 0', (tester) async {
      final state = AutomationState();
      final user = UserModel.fromJson({
        'id': '1ab81ee3-5e3e-4b4f-ad0b-5b765d540575',
        'email': 'salihceylan@gmail.com',
        'full_name': 'Salih Ceylan',
        'role': 'super_user',
      });
      state.setCurrentUserForTesting(user);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceManagementPage(autoLoad: false, initialTabIndex: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Süper yönetici "Sorumlu Ekle" butonunu görebilmeli
      expect(find.text('Sorumlu Ekle'), findsOneWidget);
    });
  });
}
