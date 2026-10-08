import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/common/qr_flow.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Pano karekod girişlerinin (E2'nin paylaşılan `routeScannedCode` akışı) E1 beklentileri:
/// tür ayrımı (claim / davet / devir / Wi-Fi / bilinmeyen) ve **ham metnin cihaz kimliği (UID)
/// alanına yazılmaması**. Davet/devir önizleme ve onay adımları E2 testlerindedir.
void main() {
  String claimUrl({String uid = 'AHBU-S3-ABC123', String pin = '123456'}) =>
      '${AppConfig.productionClaimUrl}?uid=$uid&pin=$pin';

  /// Taranan metni yönlendiren tek düğmeli sayfa.
  Widget page(String raw) => Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('btn_scan_sim'),
              onPressed: () => routeScannedCode(context, raw),
              child: const Text('tara'),
            ),
          ),
        ),
      );

  Future<StateHarness> scan(
    WidgetTester tester,
    String content, {
    String role = 'owner',
    HomeModel? home,
  }) async {
    final h = await pumpReady(tester, page(content), role: role, home: home);
    await tester.tap(byKeyName('btn_scan_sim'));
    await tester.pumpAndSettle();
    return h;
  }

  List<String> textFieldValues(WidgetTester tester) =>
      tester.widgetList<TextField>(find.byType(TextField)).map((f) => f.controller?.text ?? '').toList();

  group('Cihaz etiketi (claim)', () {
    testWidgets('geçerli etiket UID ve PIN ile eşleme diyaloğunu açar', (tester) async {
      await scan(tester, claimUrl(), role: 'resident');
      expect(find.byType(ClaimManualDialog), findsOneWidget);
      expect(textFieldValues(tester), contains('AHBU-S3-ABC123'), reason: 'UID alanı karekoddan dolar');
    });

    testWidgets('çıplak UID (URL olmadan) kabul edilmez; ham metin UID alanına YAZILMAZ', (tester) async {
      await scan(tester, 'AHBU-S3-ABC123');
      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.text('Geçersiz karekod formatı. Lütfen bilgileri kontrol edin.'), findsOneWidget);
    });

    testWidgets('serbest metin ("UID:PIN") reddedilir ve eşleme diyaloğu açılmaz', (tester) async {
      await scan(tester, 'AHBU-S3-ABC123:123456');
      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('bireysel-2: aktif evi misafir olan kullanıcı kendi panosunu eşleyebilir (sahiplenme ev kapsamlı değil)',
        (tester) async {
      await scan(tester, claimUrl(), home: guestHome());
      expect(find.byType(ClaimManualDialog), findsOneWidget);
      expect(textFieldValues(tester), contains('AHBU-S3-ABC123'));
    });

    testWidgets('servis PIN oturumu cihaz eşleyemez', (tester) async {
      await scan(tester, claimUrl(), role: 'service_session');
      expect(find.byType(ClaimManualDialog), findsNothing);
    });
  });

  group('Davet ve devir kodları', () {
    testWidgets('davet kodu eve katılma diyaloğunu açar; onaydan önce sunucuya katılım gitmez', (tester) async {
      final h = await scan(tester, 'AHBU-INVITE:AHBU-ABC1234567');
      expect(find.byType(JoinHomeDialog), findsOneWidget);
      expect(h.e1.calls, isNot(contains('joinHome')));
    });

    testWidgets('devir kodu (önek büyük/küçük harf duyarsız) katılma/devir diyaloğunu açar; devir kabul edilmez',
        (tester) async {
      final h = await scan(tester, 'ahbu-transfer:ahbu-tr-abcdefgh');
      expect(find.byType(JoinHomeDialog), findsOneWidget);
      expect(h.e1.acceptedTransfers, isEmpty, reason: 'devir yalnızca açık onayla');
    });

    testWidgets('çıplak AHBU-TR-… devir kodu da devir olarak yönlendirilir', (tester) async {
      await scan(tester, 'AHBU-TR-ABCDEFGH');
      expect(find.byType(JoinHomeDialog), findsOneWidget);
      expect(find.byType(ClaimManualDialog), findsNothing);
    });
  });

  group('Wi-Fi karekodu ve tanınmayan içerik', () {
    testWidgets('Wi-Fi karekodu eşleme/katılım olarak yorumlanmaz; Wi-Fi Kurulum sihirbazı açılır (bireysel-11)', (tester) async {
      await scan(tester, 'WIFI:T:WPA;S:EvAgi;P:parola12345;;');
      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.byType(JoinHomeDialog), findsNothing);
      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    });

    testWidgets('tanınmayan içerik Türkçe mesaj verir ve ham metni yansıtmaz', (tester) async {
      await scan(tester, 'merhaba-dunya-123');
      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.byType(JoinHomeDialog), findsNothing);
      expect(find.text('Geçersiz karekod formatı. Lütfen bilgileri kontrol edin.'), findsOneWidget);
      expect(find.textContaining('merhaba'), findsNothing);
    });

    testWidgets('boş içerik "Karekod boş." der', (tester) async {
      await scan(tester, '   ');
      expect(find.text('Karekod boş.'), findsOneWidget);
    });
  });
}
