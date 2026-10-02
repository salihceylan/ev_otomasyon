import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/e1_helpers.dart';

/// Karşılama ve cihaz eşleme akışı: karşılama kartı **yalnızca ev sahibine** ve **başarılı boş** cihaz
/// yanıtında çıkar; elle eşleme diyaloğu boş (uydurma değer yok) açılır; karekod girişi yetkiye bağlıdır.
void main() {
  testWidgets('ev sahibi boş dairede karşılama kartını görür ve "Kodu Elle Gir" eşleme diyaloğunu açar', (tester) async {
    await pumpReady(tester, const DashboardPage(), role: 'owner', endpoints: <EndpointModel>[]);

    expect(find.text('Evinize Hoş Geldiniz!'), findsOneWidget);
    expect(find.text('Karekod ile Cihaz Eşle'), findsOneWidget);
    expect(find.text('Kodu Elle Gir (Manuel Eşleme)'), findsOneWidget);

    await tester.ensureVisible(byKeyName('btn_claim_manual'));
    await tester.tap(byKeyName('btn_claim_manual'));
    await tester.pumpAndSettle();

    expect(find.byType(ClaimManualDialog), findsOneWidget);
    expect(find.text('Cihaz Eşleştirme'), findsOneWidget);
    final values = tester.widgetList<TextField>(find.byType(TextField)).map((f) => f.controller?.text ?? '').toList();
    expect(values, isNot(contains(startsWith('AHBU-'))), reason: 'elle girişte UID alanı uydurma değerle dolu açılmaz');
  });

  testWidgets('cihaz listesi hata verdiyse ev sahibine bile karşılama kartı gösterilmez', (tester) async {
    await pumpReady(
      tester,
      const DashboardPage(),
      role: 'owner',
      configure: (h) => h.e1.fetchEndpointsError = kServerError,
    );
    expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
    expect(byKeyName('error_card'), findsOneWidget);
  });

  testWidgets('aile üyesi ve misafir boş dairede cihaz eşleme önerisi görmez', (tester) async {
    await pumpReady(tester, const DashboardPage(), role: 'resident', endpoints: <EndpointModel>[]);
    expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
    expect(byKeyName('card_empty_home'), findsOneWidget);
  });

  testWidgets('cihazı olan dairede karşılama kartı görünmez', (tester) async {
    await pumpReady(tester, const DashboardPage(), role: 'owner');
    expect(find.text('Evinize Hoş Geldiniz!'), findsNothing);
    expect(byKeyName('card_relay_1'), findsOneWidget);
  });

  testWidgets('üst çubuktaki karekod girişi oturum açmış ev sahibine görünür',
      (tester) async {
    await pumpReady(tester, const DashboardPage(), role: 'owner');
    expect(byKeyName('nav_qr'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsWidgets);
  });

  testWidgets('servis PIN oturumunda karekod girişi yoktur (oturum cihaz eşleyemez ve eve katılamaz)', (tester) async {
    await pumpReady(tester, const DashboardPage(), role: 'service_session', globalRole: 'service_session');
    expect(byKeyName('nav_qr'), findsNothing);
  });
}
