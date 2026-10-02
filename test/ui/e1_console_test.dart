import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/dashboard/console_dashboards.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Süper yönetici ve yetkili servis konsolları: sayaçlar gerçekten yüklenir ("—" yüklenmemişse),
/// sabit altyapı satırı ve sabit yedek ad/e-posta yoktur.
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('Sayaç ayrıştırma', () {
    test('sunucunun iç içe özet yanıtı (users/devices/homes) çözülür', () {
      final counts = ConsoleCounts.fromSummary(<String, dynamic>{
        'users': <String, dynamic>{'service_users': 3, 'super_users': 2},
        'devices': <String, dynamic>{'total_devices': 40, 'commissioned_devices': 18},
        'homes': <String, dynamic>{'total_homes': 20},
      });
      expect(counts.serviceManagers, 3);
      expect(counts.superUsers, 2);
      expect(counts.devices, 40);
      expect(counts.commissioned, 18);
      expect(counts.homes, 20);
    });

    test('eski düz anahtarlar yedek olarak okunur; eksik alan "bilinmiyor" (null) kalır, 0 uydurulmaz', () {
      final counts = ConsoleCounts.fromSummary(<String, dynamic>{
        'total_service_managers': 4,
        'total_devices': 9,
      });
      expect(counts.serviceManagers, 4);
      expect(counts.devices, 9);
      expect(counts.commissioned, isNull);
      expect(counts.superUsers, isNull);
    });
  });

  group('Süper yönetici konsolu', () {
    Future<StateHarness> pumpSuper(WidgetTester tester, {void Function(StateHarness h)? configure}) =>
        pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', configure: configure);

    testWidgets('sayaçlar sunucudan gerçekten yüklenir', (tester) async {
      final h = await pumpSuper(tester);
      await flush(tester);

      expect(h.e1.count('getServiceSummary'), 1);
      expect(find.descendant(of: byKeyName('card_metric_service_managers'), matching: find.text('3')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('40')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_commissioned'), matching: find.text('18')), findsOneWidget);
      expect(byKeyName('banner_counters_error'), findsNothing);
    });

    testWidgets('yüklenene kadar yükleniyor göstergesi, yüklenemezse "—" ve yeniden dene; sonra gerçek sayılar', (tester) async {
      final h = await pumpSuper(tester, configure: (h) => h.e1.summaryError = kServerError);
      await flush(tester);

      expect(byKeyName('banner_counters_error'), findsOneWidget);
      expect(find.text(kServerError.message), findsOneWidget);
      for (final key in ['card_metric_service_managers', 'card_metric_devices', 'card_metric_commissioned']) {
        expect(find.descendant(of: byKeyName(key), matching: find.text('—')), findsOneWidget, reason: key);
      }
      expect(find.text('0'), findsNothing, reason: 'yüklenmemiş sayaç 0 gösterilmez');

      h.e1.summaryError = null;
      await tester.tap(byKeyName('btn_retry'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('40')), findsOneWidget);
      expect(byKeyName('banner_counters_error'), findsNothing);
    });

    testWidgets('yükleme sürerken sayaç kartlarında ilerleme gösterilir (sahte "0" yok); yanıt gelince sayılar', (tester) async {
      final gate = Completer<void>();
      final h = await pumpSuper(tester, configure: (h) => h.e1.summaryGate = gate);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await flush(tester);

      expect(
        find.descendant(of: byKeyName('card_metric_devices'), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );
      expect(find.text('0'), findsNothing);

      gate.complete();
      await flush(tester);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('40')), findsOneWidget);
      expect(h.e1.count('getServiceSummary'), 1);
    });

    testWidgets('sabit altyapı satırı (Port 5000 / PostgreSQL 5434 / EMQX) ve sabit yedek ad/e-posta YOKTUR', (tester) async {
      final h = await pumpSuper(tester);
      h.state.setCurrentUserForTesting(const UserModel(id: 'su', email: '', fullName: '', role: 'super_user'));
      await flush(tester);

      expect(find.textContaining('5000'), findsNothing);
      expect(find.textContaining('5434'), findsNothing);
      expect(find.textContaining('PostgreSQL'), findsNothing);
      expect(find.textContaining('EMQX'), findsNothing);
      expect(find.textContaining('salihceylan'), findsNothing);
      expect(find.textContaining('Salih Ceylan'), findsNothing);
      expect(find.text('Süper Yönetici'), findsWidgets, reason: 'adı olmayan kullanıcı için genel başlık');
    });

    testWidgets('gerçek kullanıcı adı ve e-postası başlık kartında gösterilir', (tester) async {
      await pumpSuper(tester);
      expect(
        find.descendant(of: byKeyName('card_console_header'), matching: find.text('Ayşe Yılmaz')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: byKeyName('card_console_header'), matching: find.text('ayse@example.test')),
        findsOneWidget,
      );
    });

    testWidgets('hızlı işlemler yetkilere göre listelenir (envanter, sorumlular, aboneler, doktor)', (tester) async {
      await pumpSuper(tester);
      for (final key in ['card_action_inventory', 'card_action_service_managers', 'card_action_subscribers', 'card_action_doctor']) {
        expect(byKeyName(key), findsOneWidget, reason: key);
      }
      expect(byKeyName('card_action_commissioning'), findsNothing, reason: 'saha araçları süper kullanıcıya ait değil');
    });
  });

  group('Yetkili servis konsolu', () {
    Future<StateHarness> pumpService(WidgetTester tester, {void Function(StateHarness h)? configure}) =>
        pumpReady(tester, const DashboardPage(), role: 'service_user', globalRole: 'service_user', configure: configure);

    testWidgets('sayaçlar kendi kapsamından (stok + aboneler) yüklenir; süper özet ucu çağrılmaz', (tester) async {
      final h = await pumpService(tester);
      await flush(tester);

      expect(h.e1.count('getServiceSummary'), 0, reason: 'servis personeli yönetici özetini çağıramaz');
      expect(h.e1.count('fetchDeviceInventory'), 1);
      expect(h.e1.count('fetchServiceSubscribers'), 1);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('5')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_commissioned'), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('yüklenemezse "—" ve yeniden dene; uydurma "0" yok', (tester) async {
      final h = await pumpService(tester, configure: (h) => h.e1.inventoryError = kServerError);
      await flush(tester);

      expect(byKeyName('banner_counters_error'), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('—')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('0')), findsNothing);

      h.e1.inventoryError = null;
      await tester.tap(byKeyName('btn_retry'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('5')), findsOneWidget);
    });

    testWidgets('saha görevleri: servis modu, aboneler, pano değişimi, Wi-Fi kurtarma ve acil sıfırlama (canEmergencyReset)',
        (tester) async {
      await pumpService(tester);
      for (final key in [
        'card_action_commissioning',
        'card_action_subscribers',
        'card_action_replace_board',
        'card_action_wifi_recovery',
        'card_action_emergency_reset',
      ]) {
        expect(byKeyName(key), findsOneWidget, reason: key);
      }
      expect(byKeyName('card_action_inventory'), findsNothing, reason: 'envanter yönetimi yalnızca süper kullanıcı');
      expect(byKeyName('card_action_service_managers'), findsNothing);
      expect(byKeyName('btn_open_service_management'), findsNothing, reason: '"Tüm Paneli Aç" yalnızca süper konsolda');
      expect(byKeyName('notice_service_safety'), findsOneWidget);
    });

    testWidgets('sabit servis e-postası yedeği ve sabit "8 röle / 8 giriş" metni yoktur', (tester) async {
      final h = await pumpService(tester);
      h.state.setCurrentUserForTesting(const UserModel(id: 'sv', email: '', fullName: '', role: 'service_user'));
      await flush(tester);
      expect(find.textContaining('servis@gudeteknoloji'), findsNothing);
      expect(find.textContaining('8 röle'), findsNothing);
      expect(find.textContaining('8 Röle'), findsNothing);
      expect(find.text('Yetkili Servis Sorumlusu'), findsWidgets);
    });
  });

  group('Pano üst çubuğu: avatar baş harfi', () {
    testWidgets('adı boş kullanıcıda varsayılan harf; emoji ile başlayan ad bozulmaz', (tester) async {
      final h = await pumpReady(tester, const DashboardPage(), role: 'owner');
      h.state.setCurrentUserForTesting(const UserModel(id: 'u1', email: 'x@y.z', fullName: '', role: 'user'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('nav_profile'), matching: find.text('U')), findsOneWidget);

      h.state.setCurrentUserForTesting(const UserModel(id: 'u1', email: 'x@y.z', fullName: '😀 Ahmet', role: 'user'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('nav_profile'), matching: find.text('😀')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
