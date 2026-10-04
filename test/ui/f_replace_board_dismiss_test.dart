import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/replace_board_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart' show FakeClock, StateHarness, kHomeA;
import 'f_support.dart';
import 'f_widget_support.dart';

/// PF-46: pano değişimi diyaloğu işlem sürerken kapatılamaz.
///
/// Değişim geri alınamaz bir işlemdir (eski panoyu devre dışı bırakır; yanıttaki uyarılar ve tek seferlik bulut
/// kimliği yalnızca o yanıtta gelir). İstek sürerken diyalog bariyere dokunma, X düğmesi ya da sistem geri tuşuyla
/// kapanırsa sonuç (`if (!mounted) return;`) kullanıcıya hiç gösterilmeden atılırdı.
///
/// PF-47 (diyalog yarısı): sonuç ekranındaki "Yeni Panoyu Şimdi Bağla" aynı karede iki kez etkinleştirilse de tek
/// sihirbaz rotası itilir.

const String kOldUid = 'AHBU-S3-OLD001';
const String kNewUid = 'AHBU-S3-NEW001';
const String kNewPin = '246810';
const String kNewLabelQr = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kNewUid&pin=$kNewPin';

/// `replaceBoard` yanıtı bir kapı açılana kadar bekletilebilen sahte bulut (istek sürerken kapatma denemeleri için).
///
/// Kapı bu dosyaya özeldir: ortak `ServiceFakeCloud`a (test/ui/f_support.dart) dokunulmaz.
class _GatedCloud extends ServiceFakeCloud {
  _GatedCloud({super.clock});

  Completer<void>? replaceGate;

  /// Kapıdan ÖNCE sayılır: istek gerçekten gönderildi mi.
  int replaceStarted = 0;

  @override
  Future<ReplaceBoardResult> replaceBoard({
    required String homeId,
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    replaceStarted++;
    final gate = replaceGate;
    if (gate != null) await gate.future;
    return super.replaceBoard(
      homeId: homeId,
      oldDeviceUuid: oldDeviceUuid,
      newDeviceUuid: newDeviceUuid,
      setupPin: setupPin,
      reason: reason,
    );
  }
}

/// Servis personeli + aktif daire + tek panolu daire.
Future<({StateHarness h, _GatedCloud cloud})> _env(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final clock = FakeClock();
  final cloud = _GatedCloud(clock: clock);
  final h = StateHarness(clock: clock, cloud: cloud);
  addTearDown(h.dispose);
  cloud.devicesByHome[kHomeA] = const <DeviceInfo>[
    DeviceInfo(deviceUuid: kOldUid, name: 'Salon Panosu', online: false, firmware: '1.1.0'),
  ];
  final home = HomeModel(id: kHomeA, name: 'Daire 5 - Nilüfer', role: 'service_user');
  cloud.homes = <HomeModel>[home];
  h.state
    ..setCurrentUserForTesting(const UserModel(
      id: 'staff-1',
      email: 'servis@ornek.test',
      fullName: 'Servis Ali',
      role: 'service_user',
    ))
    ..setAuthStatusForTesting(AuthStatus.authenticated)
    ..setHomesForTesting(<HomeModel>[home]);
  var done = false;
  unawaited(h.state.selectHome(home).then((_) => done = true));
  for (var i = 0; i < 40 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(h.state.activeHome?.id, kHomeA, reason: 'aktif daire seçilemedi');
  return (h: h, cloud: cloud);
}

/// Rota itmelerini sayar (diyalog + sihirbaz rotaları).
class _PushCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

Future<void> _openReplace(WidgetTester tester, AutomationState state, {NavigatorObserver? observer}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: state,
      child: MaterialApp(
        navigatorObservers: <NavigatorObserver>[?observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('launcher'),
                onPressed: () => ReplaceBoardDialog.show(context, scanner: fakeScanner(kNewLabelQr)),
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('launcher')));
  await settle(tester);
}

/// Etiketi okutur, formu gönderir ve onay penceresini onaylar: istek kapıda bekler.
Future<void> _submitUntilPending(WidgetTester tester) async {
  await tapKey(tester, 'btn_scan_new_board');
  await settle(tester);
  await tapKey(tester, 'btn_replace_submit');
  await settle(tester);
  await tapKey(tester, 'btn_replace_confirm');
  await settle(tester, frames: 4);
}

bool _dialogOpen() => find.byType(ReplaceBoardDialog).evaluate().isNotEmpty;

void main() {
  group('PF-47 (diyalog yarısı): sonuç ekranından sihirbaz tek kez açılır', () {
    testWidgets('"Yeni Panoyu Şimdi Bağla" aynı karede iki kez etkinleştirilse de TEK sihirbaz rotası itilir', (tester) async {
      final env = await _env(tester);
      final counter = _PushCounter();
      await _openReplace(tester, env.h.state, observer: counter);
      await _submitUntilPending(tester);
      await settle(tester, frames: 20);
      expect(find.byKey(const Key('replace_result_title')), findsOneWidget, reason: 'değişim tamamlandı, sonuç görünür');
      final before = counter.pushes;

      // İşaretçi OLMADAN (erişilebilirlik eylemi / klavye tekrarı): işaretçi dokunuşlarını Navigator aynı karede emer.
      final root = find.byKey(const Key('btn_replace_open_wizard'));
      final direct = tester.widgetList(root).whereType<ElevatedButton>();
      final button = direct.isNotEmpty
          ? direct.first
          : tester.widget<ElevatedButton>(find.descendant(of: root, matching: find.byType(ElevatedButton)));
      final onPressed = button.onPressed;
      expect(onPressed, isNotNull);
      onPressed!();
      onPressed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(counter.pushes - before, 1, reason: 'ikinci etkinleştirme ikinci sihirbazı itmemeli (ilkini kapatıp yenisini açmamalı)');
      expect(find.byType(ReplaceBoardDialog), findsNothing, reason: 'diyalog kapandı');
      expect(find.byKey(const Key('nav_setup_title')), findsOneWidget, reason: 'sihirbaz açık');
    });
  });

  group('PF-46: pano değişimi diyaloğu işlem sürerken kapanmaz', () {
    testWidgets('istek sürerken bariyer dokunuşu ve sistem geri tuşu kapatmaz, X pasiftir; yanıt gelince sonuç gösterilir',
        (tester) async {
      final env = await _env(tester);
      env.cloud.replaceGate = Completer<void>();
      await _openReplace(tester, env.h.state);
      await _submitUntilPending(tester);

      expect(env.cloud.replaceStarted, 1, reason: 'istek gönderildi ve yanıt bekleniyor');
      expect(buttonEnabled(tester, 'btn_replace_x'), isFalse, reason: 'işlem sürerken X pasif');

      await tester.tapAt(const Offset(4, 4)); // diyaloğun dışı (bariyer)
      await settle(tester);
      expect(_dialogOpen(), isTrue, reason: 'bariyere dokunmak işlem sürerken pencereyi kapatmamalı');

      await tester.binding.handlePopRoute(); // sistem geri tuşu
      await settle(tester);
      expect(_dialogOpen(), isTrue, reason: 'geri tuşu işlem sürerken pencereyi kapatmamalı');

      env.cloud.replaceGate!.complete();
      await settle(tester, frames: 20);
      expect(_dialogOpen(), isTrue);
      expect(find.byKey(const Key('replace_result_title')), findsOneWidget, reason: 'sonuç kullanıcıya gösterilir');
      expect(env.cloud.replaceRequests, hasLength(1));
      expect(buttonEnabled(tester, 'btn_replace_x'), isTrue, reason: 'işlem bitince X yeniden etkin');

      await tapKey(tester, 'btn_replace_close');
      await settle(tester);
      expect(_dialogOpen(), isFalse, reason: 'sonuç görüldükten sonra Kapat çalışır');
    });

    testWidgets('boştayken de bariyer dokunuşu formu kapatmaz (girilen kimlik/PIN yanlışlıkla kaybolmaz); X kapatır', (tester) async {
      final env = await _env(tester);
      await _openReplace(tester, env.h.state);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);

      await tester.tapAt(const Offset(4, 4));
      await settle(tester);
      expect(_dialogOpen(), isTrue, reason: 'barrierDismissible: false');
      expect(buttonEnabled(tester, 'btn_replace_x'), isTrue);

      await tapKey(tester, 'btn_replace_x');
      await settle(tester);
      expect(_dialogOpen(), isFalse);
      expect(env.cloud.replaceStarted, 0, reason: 'kapatmak işlem başlatmaz');
    });

    testWidgets('sunucu hiç yanıt vermezse kilit kalıcı değildir: 30 sn sonra sonuç belirsiz kartı çıkar ve X yeniden etkin olur',
        (tester) async {
      final env = await _env(tester);
      env.cloud.replaceGate = Completer<void>();
      await _openReplace(tester, env.h.state);
      await _submitUntilPending(tester);
      expect(buttonEnabled(tester, 'btn_replace_x'), isFalse);

      await tester.pump(const Duration(seconds: 31)); // istemci zaman aşımı (30 sn)
      await settle(tester);
      expect(find.byKey(const Key('replace_uncertain')), findsOneWidget, reason: 'zaman aşımı "sonuç belirsiz" sayılır');
      expect(buttonEnabled(tester, 'btn_replace_x'), isTrue, reason: 'işlem bitti sayılır; pencere kapatılabilir');
      expect(buttonEnabled(tester, 'btn_replace_submit'), isFalse, reason: 'durum kontrol edilmeden yinelenemez');

      env.cloud.replaceGate!.complete(); // geç gelen yanıt hata üretmez
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'btn_replace_x');
      await settle(tester);
      expect(_dialogOpen(), isFalse);
    });
  });
}
