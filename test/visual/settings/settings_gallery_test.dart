@Tags(['visual'])
library;

// Ayarlar / Aile / Claim / Huzur afişi görsel galerisi (WP-V4; WP-F2'de genişletildi).
//
//   flutter test --tags visual --update-goldens test/visual/settings   -> test/visual/settings/goldens/*.png
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/settings        -> kayıtlı PNG'lerle karşılaştırır
//
// Gerçek sayfalar/diyaloglar gerçek AutomationState (sahte bulut/MQTT) üzerinde çizilir; MotionScope(full) +
// AmbientClock.fixed ile deterministiktir. Koyu + açık, yazı ölçeği 1.0 + 1.5, 360 dp telefon genişliği.
//
// WP-F2 (eleştirmen bulguları): ayarlar sayfası 5 kaydırma konumunda; çocuk kilidi galerisi 3 kartı da tam gösterir;
// basılı tutma düğmesi tam genişlik (boşta + basılı); davet diyaloğuna MİSAFİR kodu (13 karakter) ve devir
// onayına "DEVRAL yazıldı" (etkin CTA) karesi; biyometrik kartın üç durumu; boş kurallar / boş üye listesi;
// huzur afişi testi gölge bayrağını galeri gibi kapatır (açık temada sert "hilal" gölge artefaktı yoktu uygulamada);
// uygulama logosu ilk karede önceden ısıtılır; karekod çerçevesi temadan bağımsız olduğundan TEK PNG.
//
// WP-FX-B (2. tur eleştirmen bulguları): ayarlar galerisi parlaklığı durumdaki tema moduna bağlar (açık temada "Açık"
// kutucuğu seçili); huzur afişi harness'i NeonAppBar kullanır; basılı tutma düğmesi iki katmanlı etiket + 64 dp hap;
// boş durum orb'ları özellik renginde; biyometrik kartın "kapalı" durumu soluk orb + yüz/parmak izi simgesi.

import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/services/peace_notice_controller.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/neon_app_bar.dart';
import 'package:ev_otomasyon/ui/widgets/peace_notice_host.dart';
import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:ev_otomasyon/ui/pages/claim/scanner_frame.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/widgets/settings/appearance_cards.dart';
import 'package:ev_otomasyon/ui/widgets/settings/child_lock_card.dart';
import 'package:ev_otomasyon/ui/widgets/settings/hold_to_confirm_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/support.dart';
import '../../ui/e1_helpers.dart';
import '../../ui/peace_ui_rig.dart';
import '../support/golden_support.dart';

/// Davet/önizleme uçlarını da yanıtlayan sahte bulut.
class GoldenCloud extends E1Cloud {
  GoldenCloud({super.clock});

  @override
  Future<InvitationModel> createInvitation(
    String homeId, {
    String role = 'resident',
    int? durationHours,
    DateTime? validFrom,
    DateTime? validUntil,
    String? guestName,
  }) async {
    calls.add('createInvitation');
    final now = kTestNow;
    final guest = role == 'guest';
    return InvitationModel(
      code: guest ? 'AHBU-G-4K7M2Q' : 'AHBU-8F3N5X',
      role: role,
      expiresAt: now.add(const Duration(hours: 24)).subtract(const Duration(hours: 5, minutes: 40)),
      homeName: 'Ev A',
      guestName: guestName,
      guestValidFrom: guest ? now : null,
      guestValidUntil: guest ? now.add(Duration(hours: durationHours ?? 8)).subtract(const Duration(hours: 2)) : null,
    );
  }

  /// Üye listesi yükleme (kapı açılana dek bekler) / hata durumları.
  Completer<void>? membersGate;
  Object? membersError;

  @override
  Future<List<HomeMember>> getHomeMembers(String homeId) async {
    final gate = membersGate;
    if (gate != null) await gate.future;
    final error = membersError;
    if (error != null) throw error;
    return super.getHomeMembers(homeId);
  }

  /// Bekleyen daire devri (devir sayfası "aktif devir" görünümü).
  Map<String, dynamic>? pendingTransfer;

  @override
  Future<Map<String, dynamic>?> getTransferStatus(String homeId) async => pendingTransfer;

  @override
  Future<TransferInfo> initiateTransfer(String homeId, {required String targetIdentifier}) async {
    calls.add('initiateTransfer');
    final expires = kTestNow.add(const Duration(hours: 40));
    pendingTransfer = <String, dynamic>{
      'target_identifier': targetIdentifier,
      'expires_at': expires.toUtc().toIso8601String(),
    };
    return TransferInfo(code: 'AHBU-TR-9F4K2M7Q', expiresAt: expires, targetIdentifier: targetIdentifier);
  }

  @override
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    calls.add('emergencyResetDevice');
    return EmergencyResetResult(
      action: 'UNCLAIMED',
      deviceUuid: deviceUuid,
      affectedUsersCount: 3,
      setupPin: '482916',
      localKey: 'ornek-yerel-anahtar-12345678',
      warnings: const <String>['Yerel anahtar cihaza iletilemedi: cihazı yerinde yeniden anahtarlayın.'],
      partial: true,
    );
  }

  @override
  Future<JoinCodePreview?> previewJoinCode(String code) async {
    return JoinCodePreview(
      isTransfer: code.startsWith('AHBU-TR-'),
      homeName: 'Yazlık Daire 12',
      residentCount: 3,
      role: code.startsWith('AHBU-TR-') ? 'owner' : 'resident',
      expiresAt: kTestNow.add(const Duration(hours: 40)),
    );
  }
}

Future<StateHarness> goldenReady(
  WidgetTester tester, {
  String role = 'owner',
  bool deviceOnline = true,
  void Function(GoldenCloud cloud)? configure,
}) async {
  final h = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = GoldenCloud(clock: clock);
    final h = StateHarness(clock: clock, cloud: cloud);
    h.mqtt.autoConnect = true;
    cloud.homes = <HomeModel>[testHome(role: role)];
    cloud.endpoints[kHomeA] = testEndpoints();
    cloud.devicesByHome[kHomeA] = <DeviceInfo>[
      DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: deviceOnline, firmware: '1.1.0'),
    ];
    configure?.call(cloud);
    h.state
      ..setCurrentUserForTesting(
        UserModel(id: 'user-1', email: 'ayse@example.test', fullName: 'Ayşe Yılmaz', role: 'user'),
      )
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    await h.state.fetchHomes();
    await pumpEventQueue();
    return h;
  }))!;
  addTearDown(h.dispose);
  return h;
}

/// Sayfa zemini şeffaf: gerçek uygulamadaki devre arka planı galeri zemininde görünür.
///
/// [pushed] `true` ise sayfa bir kök sayfanın ÜSTÜNE yığılır ([PushedOverHome]): gerçek akıştaki gibi `NeonAppBar`'da geri
/// diski görünür (kök rotada geri düğmesi çizilmez).
Widget transparentPage(StateHarness h, Widget child, {bool pushed = false}) => ChangeNotifierProvider<AutomationState>.value(
  value: h.state,
  child: Builder(
    builder: (context) => Theme(
      data: Theme.of(context).copyWith(scaffoldBackgroundColor: Colors.transparent),
      child: pushed ? PushedOverHome(child: child) : child,
    ),
  ),
);

/// `pumpGallery` + uygulama logosunu ImageCache'e önceden yükler: aksi halde (soğuk önbellek) bu dosyanın İLK
/// karesinde `Image.asset` çözümlemesi yetişmez ve AppBar'da logo yuvası boş görünürdü.
Future<void> pumpScene(
  WidgetTester tester, {
  required GlobalKey boundaryKey,
  required Brightness brightness,
  required double textScale,
  required Size size,
  required Widget child,
  double clockSeconds = 0.65,
}) async {
  await pumpGallery(
    tester,
    boundaryKey: boundaryKey,
    brightness: brightness,
    textScale: textScale,
    size: size,
    child: child,
    clockSeconds: clockSeconds,
  );
  final context = tester.element(find.byType(GalleryBackdrop));
  await tester.runAsync(() => precacheImage(const AssetImage('assets/images/app_logo.png'), context));
  await tester.pump();
}

ScheduledRule _rule(
  String id,
  int ch,
  String action,
  int hour,
  int minute,
  List<int> days, {
  bool enabled = true,
  String? label,
}) => ScheduledRule(
  id: id,
  homeId: kHomeA,
  channel: ch,
  channelType: action == 'open' || action == 'close' ? 'shutter' : 'relay',
  action: action,
  hour: hour,
  minute: minute,
  daysOfWeek: days,
  enabled: enabled,
  label: label,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ayarlar / Aile / Claim / Huzur galerisi', () {
    setUpAll(loadGoldenFonts);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';
        final ratio = scale > 1 ? 1.0 : 2.0;
        const phone = Size(360, 780);

        testWidgets('ayarlar sayfası 5 konum ($tag)', (tester) async {
          final h = await goldenReady(tester);
          // Galeri parlaklığı durumdaki tema moduna bağlanır: gerçek uygulamada açık temada "Açık" kutucuğu (ve "Aydınlık
          // Mod" metni) seçili olur; eskiden varsayılan koyu mod kalıp açık tema PNG'lerinde "Koyu" seçili görünürdü.
          h.state.setThemeModeForTesting(brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: phone,
            child: transparentPage(h, const DeviceSettingsPage(), pushed: true),
          );
          await tester.pump(const Duration(milliseconds: 700));
          final position = tester
              .state<ScrollableState>(
                find.descendant(of: find.byKey(const Key('view_settings')), matching: find.byType(Scrollable)).first,
              )
              .position;
          // Sayfanın TAMAMI en az bir PNG'de görünsün: 0, 1/4, 1/2, 3/4, son (kareler arası ~%25 bindirme).
          const stops = <(String, double)>[
            ('top', 0),
            ('q1', 0.25),
            ('mid', 0.5),
            ('q3', 0.75),
            ('bottom', 1),
          ];
          for (final (name, fraction) in stops) {
            position.jumpTo(position.maxScrollExtent * fraction);
            await tester.pump(const Duration(milliseconds: 100));
            await expectGolden(tester, key, 'settings_${name}_$tag.png', pixelRatio: ratio);
          }
          expect(tester.takeException(), isNull);
        });

        testWidgets('çocuk kilidi durumları ($tag)', (tester) async {
          final open = await goldenReady(tester);
          final locked = await goldenReady(tester);
          final waiting = await goldenReady(tester);
          locked.mqtt.emitStateJson(stateJson(childLock: true));
          await tester.pump();
          final key = GlobalKey();
          Widget card(StateHarness h) => ChangeNotifierProvider<AutomationState>.value(
            value: h.state,
            child: const Padding(padding: EdgeInsets.only(bottom: 12), child: ChildLockCard()),
          );
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            // Üç kartın tamamı (en alttaki "bekleyen" kartın son satırı ve gölgesi dahil) sığar.
            size: Size(360, scale > 1 ? 1000 : 740),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [card(open), card(locked), card(waiting)]),
            ),
          );
          // Üçüncü kart: kilitleme komutu gönderildi, cihaz doğrulaması bekleniyor (ProgressArc).
          await tester.tap(find.byKey(const Key('switch_child_lock')).at(2));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await expectGolden(tester, key, 'child_lock_states_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('biyometrik kart durumları ($tag)', (tester) async {
          // 1) donanım yok (varsayılan etiket 'Biyometrik Giriş'), 2) destekli + kapalı, 3) destekli + açık.
          final none = await goldenReady(tester);
          final off = await goldenReady(tester);
          final on = await goldenReady(tester);
          off.state.setBiometricForTesting(isSupported: true, isEnabled: false, label: 'Parmak İzi');
          on.state.setBiometricForTesting(isSupported: true, isEnabled: true, label: 'Face ID');
          final key = GlobalKey();
          Widget card(StateHarness h) => ChangeNotifierProvider<AutomationState>.value(
            value: h.state,
            child: const Padding(padding: EdgeInsets.only(bottom: 12), child: BiometricCard()),
          );
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 720 : 470),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [card(none), card(off), card(on)]),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'biometric_states_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('basılı tutarak onay düğmesi ($tag)', (tester) async {
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 330 : 250),
            // Gerçek alt sayfadaki gibi tam genişlik (stretch): üstte boşta, altta basılı tutuluyor (%54).
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HoldToConfirmButton(
                    key: const Key('hold_idle'),
                    label: 'Kilidi kaldırmak için basılı tutun',
                    onConfirmed: () {},
                  ),
                  const SizedBox(height: 16),
                  HoldToConfirmButton(
                    key: const Key('hold_demo'),
                    label: 'Kilidi kaldırmak için basılı tutun',
                    onConfirmed: () {},
                  ),
                ],
              ),
            ),
          );
          final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('hold_demo'))));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 650));
          await expectGolden(tester, key, 'hold_confirm_$tag.png', pixelRatio: ratio);
          await g.up();
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
        });

        testWidgets('zamanlı kurallar ($tag)', (tester) async {
          final h = await goldenReady(
            tester,
            configure: (c) {
              c.rules = <ScheduledRule>[
                _rule('r1', 1, 'off', 23, 30, const [0, 1, 2, 3, 4, 5, 6], label: 'Gece tüm ışıklar kapansın'),
                _rule('r2', 2, 'close', 22, 0, const [1, 2, 3, 4, 5], label: 'Salon panjuru akşam kapanışı'),
                _rule('r3', 1, 'on', 18, 45, const [0, 6], enabled: false),
                _rule('r4', 3, 'open', 7, 30, const [1, 2, 3, 4, 5], label: 'Sabah panjur açılışı'),
              ];
            },
          );
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1300 : 780),
            child: transparentPage(h, const ScheduledRulesPage(), pushed: true),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectGolden(tester, key, 'rules_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('zamanlı kurallar boş durum ($tag)', (tester) async {
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 720 : 560),
            child: transparentPage(h, const ScheduledRulesPage(), pushed: true),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectGolden(tester, key, 'rules_empty_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('aile üyeleri ($tag)', (tester) async {
          final h = await goldenReady(
            tester,
            configure: (c) {
              c.members = <HomeMember>[
                const HomeMember(userId: 'user-1', fullName: 'Ayşe Yılmaz', role: 'owner', email: 'ayse@example.test'),
                const HomeMember(
                  userId: 'u2',
                  fullName: 'Mehmet Yılmaz',
                  role: 'resident',
                  email: 'mehmet@example.test',
                ),
                HomeMember(
                  userId: 'u3',
                  fullName: 'Temizlikçi Fatma',
                  role: 'guest',
                  phone: '0555 000 00 00',
                  validUntil: kTestNow.add(const Duration(hours: 5)),
                ),
                HomeMember(
                  userId: 'u4',
                  fullName: 'Misafir Ali',
                  role: 'guest',
                  email: 'ali@example.test',
                  validUntil: kTestNow.subtract(const Duration(hours: 3)),
                  isExpired: true,
                ),
              ];
            },
          );
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1560 : 940),
            child: transparentPage(h, const FamilyMembersPage(), pushed: true),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectGolden(tester, key, 'family_members_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('aile üyeleri boş durum ($tag)', (tester) async {
          final h = await goldenReady(tester, configure: (c) => c.members = <HomeMember>[]);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 900 : 600),
            child: transparentPage(h, const FamilyMembersPage(), pushed: true),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectGolden(tester, key, 'family_members_empty_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('aile üyeleri yükleniyor ($tag)', (tester) async {
          final gate = Completer<void>();
          final h = await goldenReady(tester, configure: (c) => c.membersGate = gate);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 900 : 600),
            child: transparentPage(h, const FamilyMembersPage(), pushed: true),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectGolden(tester, key, 'family_members_loading_$tag.png', pixelRatio: ratio);
          // Bekleyen istek/zaman aşımı sayacı testi kirletmesin: kapıyı aç, sayfayı kaldır.
          gate.complete();
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        });

        testWidgets('aile üyeleri hata ($tag)', (tester) async {
          final h = await goldenReady(
            tester,
            configure: (c) => c.membersError = const ApiException(
              statusCode: 0,
              message: 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.',
              code: 'NETWORK',
            ),
          );
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 900 : 600),
            child: transparentPage(h, const FamilyMembersPage(), pushed: true),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectGolden(tester, key, 'family_members_error_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('davet diyaloğu ($tag)', (tester) async {
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 900 : 780),
            child: transparentPage(h, const Center(child: InviteFamilyDialog())),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const Key('btn_generate_member_invite')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          // Üretilen sonuç görünür bölgeye kayar (220 ms): animasyon bitsin.
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'invite_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('davet diyaloğu misafir kodu ($tag)', (tester) async {
          // Misafir kodu 'AHBU-G-4K7M2Q' (13 karakter) 1.0'da bile kart genişliğine sınırda: eksiksiz ve tek satır.
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 900 : 780),
            child: transparentPage(h, const Center(child: InviteFamilyDialog())),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const Key('tab_invite_guest')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final generate = find.byKey(const Key('btn_generate_guest_invite'));
          await tester.ensureVisible(generate);
          await tester.pump();
          await tester.tap(generate);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          // Üretilen sonuç görünür bölgeye kayar (220 ms): animasyon bitsin.
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'invite_guest_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('devir onayı ($tag)', (tester) async {
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1100 : 780),
            child: transparentPage(h, const Center(child: JoinHomeDialog(initialCode: 'AHBU-TR-9F4K2M7Q'))),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const Key('btn_join_continue')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await expectGolden(tester, key, 'transfer_confirm_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('devir onayı etkin ($tag)', (tester) async {
          // "DEVRAL" yazıldı: yıkıcı CTA (rose gradyan) etkin.
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1100 : 780),
            child: transparentPage(h, const Center(child: JoinHomeDialog(initialCode: 'AHBU-TR-9F4K2M7Q'))),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const Key('btn_join_continue')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final phrase = find.byKey(const Key('field_join_confirm_phrase'));
          await tester.ensureVisible(phrase);
          await tester.enterText(phrase, 'DEVRAL');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'transfer_confirm_enabled_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        // Daire devri / acil sıfırlama diyaloğu: ev sahibi + servis personeli (iki sekme de görünür).
        Future<void> pumpTransfer(WidgetTester tester, GlobalKey key, StateHarness h, {required double height}) async {
          h.state.setCurrentUserForTesting(
            UserModel(id: 'user-1', email: 'ayse@example.test', fullName: 'Ayşe Yılmaz', role: 'service_user'),
          );
          await pumpScene(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, height),
            child: transparentPage(h, const Center(child: TransferOwnershipDialog())),
          );
          await tester.pump(const Duration(milliseconds: 500));
        }

        testWidgets('daire devri: aktif devir (kod + QR) ($tag)', (tester) async {
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpTransfer(tester, key, h, height: scale > 1 ? 1300 : 900);
          await tester.enterText(find.byKey(const Key('field_transfer_target')), 'yeni@example.test');
          await tester.pump();
          final start = find.byKey(const Key('btn_initiate_transfer'));
          await tester.ensureVisible(start);
          await tester.pump();
          await tester.tap(start);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'DEVRET');
          await tester.pump();
          await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 700));
          await expectGolden(tester, key, 'transfer_active_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('acil sıfırlama formu ve sonucu ($tag)', (tester) async {
          final h = await goldenReady(tester);
          final key = GlobalKey();
          await pumpTransfer(tester, key, h, height: scale > 1 ? 1500 : 1000);
          await tester.tap(find.byKey(const Key('tab_emergency')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'emergency_form_$tag.png', pixelRatio: ratio);

          await tester.enterText(find.byKey(const Key('field_reset_uid')), 'AHBU-S3-1A2B3C');
          await tester.enterText(
            find.byKey(const Key('field_reset_reason')),
            'Kiracı tahliye edildi, sözleşme ibraz edildi.',
          );
          await tester.pump();
          final submit = find.byKey(const Key('btn_reset_submit'));
          await tester.ensureVisible(submit);
          await tester.pump();
          await tester.tap(submit);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'AHBU-S3-1A2B3C');
          await tester.pump();
          await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 700));
          await expectGolden(tester, key, 'emergency_result_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('huzur afişi ($tag)', (tester) async {
          final rig = PeaceUiRig.create();
          addTearDown(rig.dispose);
          final key = GlobalKey();
          tester.view.devicePixelRatio = 2;
          tester.view.physicalSize = Size(phone.width * 2, 520 * 2);
          addTearDown(tester.view.reset);
          final clock = AmbientClock.fixed(0.65);
          addTearDown(clock.dispose);
          // Bu test `pumpGallery` kullanmaz: flutter_test'in düz-blok gölge varsayılanı (açık temada orb'un renkli
          // gölgesi sert bir "hilal" olarak çiziliyordu) kapatılır; değişkenin değişmezlik denetimi için test
          // bitmeden geri alınır.
          final shadowsWereDisabled = debugDisableShadows;
          debugDisableShadows = false;
          try {
            await tester.pumpWidget(
              MotionScope(
                mode: MotionMode.full,
                clock: clock,
                child: ChangeNotifierProvider<AutomationState>.value(
                  value: rig.state,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: goldenTheme(Brightness.light),
                    darkTheme: goldenTheme(Brightness.dark),
                    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                      child: ChangeNotifierProvider<PeaceNoticeController>.value(
                        value: rig.controller,
                        child: PeaceNoticeHost(child: child ?? const SizedBox.shrink()),
                      ),
                    ),
                    home: RepaintBoundary(
                      key: key,
                      child: Scaffold(
                        backgroundColor: brightness == Brightness.dark
                            ? const Color(0xFF0B1120)
                            : const Color(0xFFF1F5F9),
                        // Gerçek uygulamadaki ikincil/pano üst çubuk dili (cam disk + orb): eskiden düz Material `AppBar`
                        // harness iskeleti idi.
                        appBar: const NeonAppBar(title: 'Ev A', icon: Icons.home_rounded, family: AppFamilies.sky),
                        body: const Center(child: Text('Pano')),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            rig.push.emitNotice(rig.notice());
            await tester.pump();
            await tester.pump();
            await tester.pumpAndSettle();
            await expectGolden(tester, key, 'peace_banner_$tag.png', pixelRatio: ratio);
            expect(tester.takeException(), isNull);
          } finally {
            debugDisableShadows = shadowsWereDisabled;
          }
        });
      }
    }

    // Karekod tarayıcı çerçevesi koyu kamera zemininde ve temadan/yazı ölçeğinden bağımsızdır: koyu/açık ve 1.5
    // PNG'leri bayt bayt aynıydı. TEK PNG: solda tarama (çizgi + bant), sağda kabul (✓ orb).
    testWidgets('claim karekod tarayıcı çerçevesi', (tester) async {
      final key = GlobalKey();
      final accepted = ValueNotifier<bool>(false);
      addTearDown(accepted.dispose);
      await pumpScene(
        tester,
        boundaryKey: key,
        brightness: Brightness.dark,
        textScale: 1.0,
        size: const Size(360, 400),
        clockSeconds: 0.9,
        child: ColoredBox(
          color: const Color(0xFF05080F),
          child: SizedBox.expand(
            child: ValueListenableBuilder<bool>(
              valueListenable: accepted,
              builder: (context, done, _) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ScannerFrame(size: 150, accepted: done),
                  ScannerFrame(size: 150, accepted: !done),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await expectGolden(tester, key, 'claim_scanner_dark_1.0.png', pixelRatio: 2);
      expect(tester.takeException(), isNull);
    });
  }, skip: visualSkipReason);
}
