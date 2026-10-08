import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Sahiplenme diyaloğu düzeltmeleri (2026-10-08): uyelik-1 (bekleyen müşteri hesabı), bireysel-1 / -11 (bulut notu,
/// Wi-Fi kurulumuna yol), bireysel-3 (yanıtı kaybolan claim / ALREADY_YOURS), bireysel-7 (art arda PIN kilidi),
/// bireysel-13 (hazırlanmamış pano uyarısı).
void main() {
  const uid = 'AHBU-S3-1A2B3C';
  const pin = '482916';

  Future<Opened<bool>> open(WidgetTester tester, E2Env env) => openFromHost<bool>(
        tester,
        env.state,
        (context) => ClaimManualDialog.show(context, initialUid: uid, initialPin: pin),
      );

  testWidgets('uyelik-1: mevcut (etkinleştirilmemiş) müşteri hesabı başarı ekranında söylenir', (tester) async {
    final env = e2Env();
    env.cloud.claimResultToReturn = const ClaimResult(
      homeId: kHomeA,
      homeName: 'Daire 5',
      deviceUuid: uid,
      customerAccount: CustomerAccountInfo(created: false, status: 'pending_invite', inviteSent: true),
    );
    final opened = await open(tester, env);
    await tapKey(tester, 'btn_claim_submit');
    expect(find.byKey(const Key('claim_success')), findsOneWidget, reason: 'kapanmadan bilgi gösterilir');
    expect(find.text('Müşteri hesabı henüz etkinleştirilmedi; davet yeniden gönderildi.'), findsOneWidget);
    expect(opened.done, isFalse);
  });

  testWidgets('bireysel-1 / bireysel-11: bulut notu sürüm koşullu ve Wi-Fi kurulumunun yerini doğru söyler', (tester) async {
    final env = e2Env();
    env.cloud.claimResultToReturn = const ClaimResult(
      homeId: kHomeA,
      homeName: 'Daire 5',
      deviceUuid: uid,
      warnings: <String>['Uyarı'],
    );
    await open(tester, env);
    await tapKey(tester, 'btn_claim_submit');
    final note = tester.widget<Text>(
      find.descendant(of: find.byKey(const Key('claim_cloud_note')), matching: find.byType(Text)).first,
    );
    expect(note.data, startsWith('Pano yazılımı v1.3.0 ve üstüyse'));
    expect(note.data, contains('Ayarlar > Wi-Fi Şifre Değişimi & Kurtarma (girişsiz: giriş ekranındaki Pano Wi-Fi Kurulumu)'));
  });

  testWidgets('bireysel-11: servis rolü olmayan kullanıcıya başarı bildiriminde "Wi-Fi Kurulumu" eylemi', (tester) async {
    final env = e2Env();
    final opened = await open(tester, env);
    await tapKey(tester, 'btn_claim_submit');
    expect(opened.result, isTrue);
    final action = find.widgetWithText(SnackBarAction, 'Wi-Fi Kurulumu');
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    final dialog = tester.widget<WifiRecoveryDialog>(find.byType(WifiRecoveryDialog));
    expect(dialog.deviceUuid, uid);
  });

  testWidgets('bireysel-3: 409 ALREADY_YOURS başarı sayılır; ev listesi yenilenir ve o ev seçilir', (tester) async {
    final env = e2Env();
    env.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık', topic: 'h_b')];
    env.cloud.claimError = const ApiException(
      statusCode: 409,
      code: 'CONFLICT',
      message: 'Bu cihaz zaten sizin evinizde.',
      details: <String, dynamic>{
        'success': false,
        'code': 'CONFLICT',
        'reason': 'ALREADY_YOURS',
        'data': <String, dynamic>{'home_id': kHomeB, 'home_name': 'Yazlık'},
      },
    );
    final opened = await open(tester, env);
    await tapKey(tester, 'btn_claim_submit');
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened.result, isTrue);
    expect(env.state.activeHome?.id, kHomeB);
    expect(find.textContaining('Cihaz zaten evinizde'), findsOneWidget);
  });

  testWidgets('bireysel-3: ağ hatasında ev listesi yenilenir ve "tamamlanmış olabilir" ipucu', (tester) async {
    final env = e2Env();
    env.cloud.claimError = ApiException.network();
    await open(tester, env);
    final before = env.cloud.count('fetchHomes');
    await tapKey(tester, 'btn_claim_submit');
    expect(find.textContaining('İşlem sunucuda tamamlanmış olabilir; ev listeniz yenileniyor.'), findsOneWidget);
    expect(env.cloud.count('fetchHomes'), greaterThan(before));
  });

  testWidgets('bireysel-7: PIN kilidi art arda ikinci kez gelirse yönlendirme ipucu', (tester) async {
    final env = e2Env();
    env.cloud.claimError = const ApiException(
      statusCode: 423,
      code: 'PIN_LOCKED',
      message: 'Kilitli.',
      retryAfter: Duration(seconds: 2),
    );
    await open(tester, env);
    await tapKey(tester, 'btn_claim_submit');
    const hint = 'Başka bir hesaptan hatalı denemeler olabilir; etiket sizdeyse satıcınıza/yetkili servise başvurun.';
    expect(find.textContaining(hint), findsNothing, reason: 'ilk kilitte yok');
    env.clock.advance(const Duration(seconds: 3));
    await tester.pump();
    await tapKey(tester, 'btn_claim_submit');
    expect(find.textContaining(hint), findsOneWidget);
  });

  testWidgets('bireysel-13: Wi-Fi sihirbazında hazırlanmamış görülen panoda eşlemeden önce uyarı', (tester) async {
    final env = e2Env();
    env.state.noteBoardProvisioned(uid, false);
    await open(tester, env);
    expect(find.byKey(const Key('claim_unprovisioned_warning')), findsOneWidget);
    expect(find.textContaining('ilk hazırlığı (provizyon) görmemiş'), findsOneWidget);
  });
}
