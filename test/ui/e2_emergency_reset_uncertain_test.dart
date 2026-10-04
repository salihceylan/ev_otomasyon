import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// PF-45 (ve PF-50 devir/acil sıfırlama kolu): `TransferOwnershipDialog` acil sıfırlama sekmesi.
///
/// Sorun: `emergencyResetDevice` zaman aşımsızdı ve ağ kesintisinde "tekrar deneyin" diyordu; işlem sunucuda
/// TAMAMLANMIŞ olabilir, kör tekrar yeni PIN üretir ve devredilen sahibi bozabilir. Düzeltme, servis
/// panelindeki `EmergencyResetCard` sözleşmesiyle aynıdır: 40 sn sınır + `UncertainOutcomeCard.isUncertain`
/// -> "belirsiz" kartı + envanterde "Durumu Kontrol Et"; belirsizken `btn_reset_submit` PASİF.
/// Mevcut anahtarlar/metinler (`reset_error`, `btn_reset_submit`) korunur
/// (`test/transfer_and_emergency_reset_test.dart`).
///
/// Zaman SAHTE saatle ilerletilir (`env.clock.advance`).
void main() {
  const uid = 'AHBU-S3-A1B2C3';
  const otherUid = 'AHBU-S3-FFEEDD';
  const reason = 'Kiracı tahliye edildi, sözleşme ibraz edildi';

  /// `e2Env` ile aynı kurulum; yalnızca sahte bulut verilebilir (kapı/envanter kancaları için).
  ({E2Env env, _Cloud cloud}) rig({String? role, String globalRole = 'super_user'}) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = _Cloud(clock: clock);
    final h = StateHarness(clock: clock, cloud: cloud);
    h.state
      ..setCurrentUserForTesting(
        UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz', phone: kUserPhone, role: globalRole),
      )
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    if (role != null) {
      final active = testHome(role: role);
      h.state.setHomesForTesting(<HomeModel>[active], activeHome: active);
    }
    addTearDown(h.dispose);
    return (env: E2Env(h, cloud), cloud: cloud);
  }

  Future<Opened<void>> open(WidgetTester tester, E2Env env) => openFromHost<void>(
        tester,
        env.state,
        (context) => TransferOwnershipDialog.show(context),
      );

  Future<void> fillAndSubmit(WidgetTester tester, {String targetUid = uid}) async {
    await typeInto(tester, 'field_reset_uid', targetUid);
    await typeInto(tester, 'field_reset_reason', reason);
    await tapKey(tester, 'btn_reset_submit');
  }

  Future<void> confirmTyped(WidgetTester tester, String phrase) async {
    expect(find.byKey(const Key('field_confirm_phrase')), findsOneWidget, reason: 'yazarak onay diyaloğu açık olmalı');
    await tester.enterText(find.byKey(const Key('field_confirm_phrase')), phrase);
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
    await settle(tester);
  }

  bool shown(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;
  String noticeText(WidgetTester tester, String key) => tester.widget<DialogBusyNotice>(find.byKey(Key(key))).text;
  bool submitEnabled(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byKey(const Key('btn_reset_submit'))).onPressed != null;
  bool closeEnabled(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('btn_close'))).onPressed != null;

  group('acil sıfırlama: sonucu belirsiz kesinti (PF-45)', () {
    testWidgets(
      'ağ kesintisi (ApiException.network): "belirsiz" kartı çıkar, "tekrar deneyin" DENMEZ, gönder düğmesi PASİF, '
      'kör tekrar sunucuya gitmez',
      (tester) async {
        final r = rig();
        r.cloud.emergencyError = ApiException.network();
        await open(tester, r.env);

        await fillAndSubmit(tester);
        await confirmTyped(tester, uid);

        expect(r.env.cloud.emergencyArgs, hasLength(1), reason: 'istek bir kez gitti');
        expect(shown('reset_uncertain'), isTrue, reason: 'sonuç belirsiz kartı');
        expect(shown('btn_reset_check'), isTrue, reason: '"Durumu Kontrol Et"');
        expect(shown('reset_error'), isFalse, reason: 'belirsiz sonuç düz hata olarak gösterilmez');
        expect(find.byKey(const Key('emergency_result')), findsNothing);
        expect(find.textContaining('Sıfırlamanın sonucu belirsiz'), findsOneWidget);
        expect(find.textContaining('körlemesine yinelemek'), findsOneWidget);
        expect(submitEnabled(tester), isFalse, reason: 'belirsizken kör tekrar yok');

        // Pasif düğmeye dokunmak hiçbir şey yapmaz.
        await tester.tap(find.byKey(const Key('btn_reset_submit')), warnIfMissed: false);
        await settle(tester);
        expect(find.byKey(const Key('field_confirm_phrase')), findsNothing, reason: 'onay diyaloğu yeniden açılmadı');
        expect(r.env.cloud.emergencyArgs, hasLength(1), reason: 'ikinci istek GİTMEDİ');
        expect(closeEnabled(tester), isTrue, reason: 'işlem bitti: diyalog kapatılabilir');
      },
    );

    testWidgets('"Durumu Kontrol Et": envanterde cihaz STOKTA ise sıfırlamanın tamamlandığı bildirilir', (tester) async {
      final r = rig();
      r.cloud.emergencyError = ApiException.network();
      r.cloud.inventoryItems = <Map<String, dynamic>>[
        <String, dynamic>{'device_uuid': uid, 'status': 'IN_STOCK'},
      ];
      await open(tester, r.env);
      await fillAndSubmit(tester);
      await confirmTyped(tester, uid);

      await tapKey(tester, 'btn_reset_check');

      expect(r.cloud.inventorySearches, <String>[uid], reason: 'durum cihaz kimliğiyle sorgulanır');
      expect(find.textContaining('şu an STOKTA'), findsOneWidget);
      expect(find.textContaining('sıfırlama sunucuda tamamlanmış görünüyor'), findsOneWidget);
      expect(submitEnabled(tester), isFalse, reason: 'kontrol sonrası da kör tekrar yok');
    });

    testWidgets('"Durumu Kontrol Et": cihaz hâlâ bir daireye bağlıysa daire adı gösterilir (emin olmadan yinelenmez)', (tester) async {
      final r = rig();
      r.cloud.emergencyError = ApiException.network();
      r.cloud.inventoryItems = <Map<String, dynamic>>[
        <String, dynamic>{'device_uuid': uid, 'status': 'CLAIMED', 'claimed_home_name': 'Villa Merkez'},
      ];
      await open(tester, r.env);
      await fillAndSubmit(tester);
      await confirmTyped(tester, uid);

      await tapKey(tester, 'btn_reset_check');

      expect(find.textContaining('bir daireye bağlı ("Villa Merkez")'), findsOneWidget);
      expect(find.textContaining('Emin olmadan yinelemeyin'), findsOneWidget);
    });

    testWidgets('"Durumu Kontrol Et": envanter okunamazsa nedeni gösterilir ve tekrar kontrol edilebilir', (tester) async {
      final r = rig();
      r.cloud.emergencyError = ApiException.network();
      r.cloud.inventoryError = ApiException.network();
      await open(tester, r.env);
      await fillAndSubmit(tester);
      await confirmTyped(tester, uid);

      await tapKey(tester, 'btn_reset_check');
      expect(find.textContaining('Durum kontrol edilemedi'), findsOneWidget);

      r.cloud.inventoryError = null;
      r.cloud.inventoryItems = <Map<String, dynamic>>[
        <String, dynamic>{'device_uuid': uid, 'status': 'IN_STOCK'},
      ];
      await tapKey(tester, 'btn_reset_check');
      expect(find.textContaining('şu an STOKTA'), findsOneWidget);
      expect(r.cloud.inventorySearches, hasLength(2));
    });

    testWidgets('başka bir cihaz kimliği yazılınca önceki cihazın belirsizlik kilidi kalkar', (tester) async {
      final r = rig();
      r.cloud.emergencyError = ApiException.network();
      await open(tester, r.env);
      await fillAndSubmit(tester);
      await confirmTyped(tester, uid);
      expect(shown('reset_uncertain'), isTrue);
      expect(submitEnabled(tester), isFalse);

      await typeInto(tester, 'field_reset_uid', otherUid);

      expect(shown('reset_uncertain'), isFalse, reason: 'başka cihaz: önceki cihazın uyarısı kalkar');
      expect(submitEnabled(tester), isTrue);
    });

    testWidgets('sunucunun AÇIK hata yanıtı (403) belirsiz sayılmaz: reset_error gösterilir ve yeniden denenebilir', (tester) async {
      final r = rig();
      r.cloud.emergencyError = apiError(403, 'Bu cihazı yalnızca süper kullanıcı sıfırlayabilir.', code: 'FORBIDDEN');
      await open(tester, r.env);
      await fillAndSubmit(tester);
      await confirmTyped(tester, uid);

      expect(textOf(tester, 'reset_error'), 'Bu cihazı yalnızca süper kullanıcı sıfırlayabilir.');
      expect(shown('reset_uncertain'), isFalse);
      expect(submitEnabled(tester), isTrue, reason: 'işlem yapılmadığı biliniyor: yeniden denenebilir');
    });

    testWidgets(
      'yanıt hiç gelmezse: işlem sürerken ilerleme gösterilir ve diyalog kapatılamaz; 40 sn sonra "belirsiz" kartı çıkar '
      've geç dönen yanıt yok sayılır',
      (tester) async {
        final r = rig();
        final gate = r.cloud.emergencyGate = Completer<EmergencyResetResult>();
        await open(tester, r.env);
        await fillAndSubmit(tester);
        await confirmTyped(tester, uid);

        expect(shown('reset_busy_notice'), isTrue, reason: 'belirgin ilerleme');
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(closeEnabled(tester), isFalse, reason: 'sıfırlama sürerken kapatılamaz');
        expect(submitEnabled(tester), isFalse);

        r.env.clock.advance(const Duration(seconds: 30));
        await settle(tester);
        expect(shown('reset_busy_notice'), isTrue);
        expect(shown('reset_uncertain'), isFalse, reason: '30 sn: hâlâ bekleniyor');
        expect(closeEnabled(tester), isFalse, reason: '25 sn sonra bile yeni PIN kaybolmasın diye kapatılamaz');
        expect(noticeText(tester, 'reset_busy_notice'), contains('40'));

        r.env.clock.advance(const Duration(seconds: 11));
        await settle(tester);
        expect(shown('reset_uncertain'), isTrue, reason: '40 sn doldu: sonuç belirsiz');
        expect(shown('reset_busy_notice'), isFalse);
        expect(shown('reset_error'), isFalse);
        expect(submitEnabled(tester), isFalse, reason: 'belirsiz: kör tekrar yok');
        expect(closeEnabled(tester), isTrue, reason: 'zaman aşımından sonra kapatılabilir');

        // Geç dönen yanıt ekranı bozmaz (belirsiz kart kalır, işlenmemiş hata yok).
        gate.complete(const EmergencyResetResult(action: 'UNCLAIMED', deviceUuid: uid, setupPin: '482916'));
        await settle(tester);
        expect(shown('reset_uncertain'), isTrue);
        expect(find.byKey(const Key('emergency_result')), findsNothing);
        expect(find.textContaining('482916'), findsNothing, reason: 'geç dönen PIN gösterilmez/loglanmaz');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('başarılı sıfırlama etkilenmez: sonuç ekranı ve tek seferlik PIN gösterilir, belirsiz kart yok', (tester) async {
      final r = rig();
      r.cloud.emergencyResetToReturn = const EmergencyResetResult(action: 'UNCLAIMED', deviceUuid: uid, setupPin: '482916');
      await open(tester, r.env);
      await fillAndSubmit(tester);
      await confirmTyped(tester, uid);

      expect(find.byKey(const Key('emergency_result')), findsOneWidget);
      expect(textOf(tester, 'reset_setup_pin'), '482916');
      expect(shown('reset_uncertain'), isFalse);
      expect(shown('reset_busy_notice'), isFalse);
    });
  });

  group('dar ekran ve büyük yazı ölçeği: yeni durumlar taşmadan çizilir (erişilebilirlik)', () {
    const configs = <(Size, double)>[
      (Size(360, 640), 2.0),
      (Size(320, 568), 1.5),
      (Size(320, 568), 2.0),
    ];
    const longHome = 'Çok Uzun İsimli Bir Aile Evi Ve Çok Uzun Bir Daire Adı Daha';

    for (final (size, scale) in configs) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}, yazı ölçeği $scale: ilerleme, belirsiz kart ve kontrol sonucu', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final r = rig();
        r.cloud.emergencyGate = Completer<EmergencyResetResult>();
        r.cloud.inventoryItems = <Map<String, dynamic>>[
          <String, dynamic>{'device_uuid': uid, 'status': 'CLAIMED', 'claimed_home_name': longHome},
        ];
        await openFromHost<void>(tester, r.env.state, size: size, (context) => TransferOwnershipDialog.show(context));
        expect(tester.takeException(), isNull, reason: 'açılış');

        await fillAndSubmit(tester);
        await confirmTyped(tester, uid);
        expect(shown('reset_busy_notice'), isTrue);
        expect(tester.takeException(), isNull, reason: 'ilerleme bildirimi');

        r.env.clock.advance(const Duration(seconds: 41));
        await settle(tester);
        expect(shown('reset_uncertain'), isTrue);
        expect(tester.takeException(), isNull, reason: 'belirsiz sonuç kartı');

        await tapKey(tester, 'btn_reset_check');
        expect(find.textContaining('bir daireye bağlı'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'kontrol sonucu');
      });
    }
  });

  group('devir sekmesi: uzun işlemde ilerleme ve 25 sn sonra "Kapat" (PF-50)', () {
    Future<void> startTransfer(WidgetTester tester) async {
      await typeInto(tester, 'field_transfer_target', 'malik@ornek.test');
      await tapKey(tester, 'btn_initiate_transfer');
      await confirmTyped(tester, 'DEVRET');
    }

    testWidgets(
      'devir başlatma sürerken belirgin ilerleme gösterilir; 25 sn sonra kapatılabilir; geç dönen yanıt kapalı diyaloğu bozmaz',
      (tester) async {
        final r = rig(role: 'owner', globalRole: 'user');
        final gate = r.cloud.initiateGate = Completer<void>();
        await open(tester, r.env);

        await startTransfer(tester);

        expect(shown('transfer_busy_notice'), isTrue, reason: 'belirgin ilerleme');
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(closeEnabled(tester), isFalse, reason: '25 sn dolmadan kapatılamaz');

        r.env.clock.advance(const Duration(seconds: 24));
        await settle(tester);
        expect(closeEnabled(tester), isFalse);

        r.env.clock.advance(const Duration(seconds: 2));
        await settle(tester);
        expect(closeEnabled(tester), isTrue, reason: '25 sn sonra "Kapat" açılır');
        expect(noticeText(tester, 'transfer_busy_notice'), contains('gecikiyor'));

        await tapKey(tester, 'btn_close');
        expect(find.byType(TransferOwnershipDialog), findsNothing);

        gate.complete(); // geç yanıt: kapalı diyalog güncellenmez, hata fırlatılmaz
        await settle(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('işlem 25 sn içinde biterse ilerleme kalkar ve kapatma kilidi açılır', (tester) async {
      final r = rig(role: 'owner', globalRole: 'user');
      final gate = r.cloud.initiateGate = Completer<void>();
      await open(tester, r.env);
      await startTransfer(tester);
      expect(shown('transfer_busy_notice'), isTrue);

      r.env.clock.advance(const Duration(seconds: 5));
      gate.complete();
      await settle(tester);

      expect(shown('transfer_busy_notice'), isFalse);
      expect(find.byKey(const Key('transfer_active')), findsOneWidget);
      expect(closeEnabled(tester), isTrue);

      r.env.clock.advance(const Duration(seconds: 60)); // bitmiş işlemin zamanlayıcısı kalmadı
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Acil sıfırlama / devir başlatma yavaş-takılı olabilen ve envanteri sorgulanabilen sahte bulut.
class _Cloud extends E2Cloud {
  _Cloud({super.clock});

  /// Atanırsa acil sıfırlama bu kapı tamamlanana kadar DÖNMEZ (yanıt kayboldu / sunucu yavaş).
  Completer<EmergencyResetResult>? emergencyGate;

  /// Atanırsa devir başlatma bu kapı açılana kadar DÖNMEZ.
  Completer<void>? initiateGate;

  List<Map<String, dynamic>> inventoryItems = <Map<String, dynamic>>[];
  Object? inventoryError;
  final List<String> inventorySearches = <String>[];

  @override
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) {
    final gate = emergencyGate;
    if (gate == null) {
      return super.emergencyResetDevice(
        deviceUuid: deviceUuid,
        confirmUid: confirmUid,
        reason: reason,
        newOwnerIdentifier: newOwnerIdentifier,
      );
    }
    calls.add('emergencyResetDevice');
    emergencyArgs.add(<String, Object?>{
      'uid': deviceUuid,
      'confirm': confirmUid,
      'reasonLength': reason.length,
      'newOwner': newOwnerIdentifier,
    });
    return gate.future;
  }

  @override
  Future<TransferInfo> initiateTransfer(String homeId, {required String targetIdentifier}) async {
    final gate = initiateGate;
    if (gate != null) await gate.future;
    return super.initiateTransfer(homeId, targetIdentifier: targetIdentifier);
  }

  @override
  Future<Map<String, dynamic>> fetchDeviceInventory({
    String? status,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    calls.add('fetchDeviceInventory');
    inventorySearches.add(search ?? '');
    final error = inventoryError;
    if (error != null) throw error;
    return <String, dynamic>{'items': inventoryItems};
  }
}
