import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis paneli çek-yenile: hata **sessizce yutulmaz** (kullanıcıya anlaşılır bir mesaj gösterilir), panel bozulmaz.

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> pullToRefresh(WidgetTester tester) async {
  await tester.fling(find.byKey(const Key('service_panel')), const Offset(0, 600), 1000);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 300)); // gösterge açılır, onRefresh çağrılır, yanıt işlenir
  }
}

void main() {
  group('servis paneli çek-yenile', () {
    Future<ServiceHarness> openPanel(WidgetTester tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 1200),
      );
      await settle(tester);
      expect(exists('btn_new_setup'), isTrue);
      return env;
    }

    testWidgets('yenileme başarısız olursa (sunucuya ulaşılamıyor) hata yutulmaz: "Yenilenemedi" mesajı gösterilir; panel bozulmaz', (tester) async {
      final env = await openPanel(tester);
      env.cloud.fetchHomesErrorOnce = ApiException.network();

      await pullToRefresh(tester);

      expect(env.cloud.calls, contains('fetchHomes'), reason: 'çek-yenile gerçekten sunucuyu sorguladı');
      expect(exists('snack_refresh_failed'), isTrue, reason: 'hata yutulmaz, kullanıcıya bildirilir');
      expect(find.textContaining('Yenilenemedi'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing, reason: 'ham istisna metni gösterilmez');
      expect(exists('btn_new_setup'), isTrue, reason: 'panel bozulmaz');
    });

    testWidgets('yenileme başarılıysa hata mesajı çıkmaz', (tester) async {
      final env = await openPanel(tester);

      await pullToRefresh(tester);

      expect(env.cloud.calls, contains('fetchHomes'));
      expect(exists('snack_refresh_failed'), isFalse);
    });
  });
}
