import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// İP-4.4: 7. adımdaki "Şablon uygula" kartı — görünürlük (servis oturumunda yok, pano bağlı değilken yok) ve küçük ekran
/// (360x640) + büyük yazı (2.0x) yerleşimi: kartın her aşaması taşmadan çizilir.

Future<void> _open(WidgetTester tester, ServiceHarness env, {Size size = const Size(900, 2400), double scale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await pumpLauncher(tester, env, (context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          existingTarget: const ServiceTarget(
            homeId: kClaimedHome,
            deviceUuid: kDeviceUid,
            homeName: 'Daire 5',
            ip: kLanIp,
          ),
          startStep: SetupSteps.relays,
          store: env.store,
          deviceApiFactory: env.deviceFactory,
          scanner: fakeScanner(null),
        ),
      ),
    );
  }, size: size);
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 25);
  await pumpUntil(tester, env, () => present('setup_step_${SetupSteps.relays}'), reason: '7. adım açılmadı');
}

Future<ServiceHarness> _deployed({String role = 'staff', bool caps = true}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.seedClaimed(online: true);
  env.device
    ..wifiConnected = true
    ..staIp = kLanIp
    ..mqttConfigured = true
    ..mqttConnected = true
    ..templateCaps = caps;
  return env;
}

bool _offstagePresent(String key) => find.byKey(Key(key), skipOffstage: false).evaluate().isNotEmpty;

void main() {
  group('görünürlük', () {
    testWidgets('servis personeli + pano bağlı: kart 7. adımın başında (röle listesinin üstünde)', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      await _open(tester, env);
      await pumpUntil(tester, env, () => present('card_relay_5'));
      expect(_offstagePresent('template_card'), isTrue);
      final cardTop = tester.getTopLeft(find.byKey(const Key('template_card'), skipOffstage: false)).dy;
      final summaryTop = tester.getTopLeft(find.byKey(const Key('relay_summary'), skipOffstage: false)).dy;
      expect(cardTop, lessThan(summaryTop));
      expect(_offstagePresent('btn_template_open'), isTrue);
      expect(_offstagePresent('template_board_current'), isFalse, reason: 'panoda şablon yok');
    });

    testWidgets('servis PIN oturumu: kart hiç çizilmez', (tester) async {
      final env = await _deployed(role: 'pin');
      addTearDown(env.dispose);
      await _open(tester, env);
      await pumpUntil(tester, env, () => present('card_relay_5'));
      expect(_offstagePresent('template_card'), isFalse);
      expect(env.device.api.count('GET', '/api/template'), 0);
    });

    testWidgets('pano bağlı değilken kart yok (önce "Panoya Bağlan")', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      env.device.lanReachable = false;
      await _open(tester, env);
      await pumpUntil(tester, env, () => present('device_connection_panel') || present('setup_retry'));
      expect(_offstagePresent('template_card'), isFalse);
    });

    testWidgets('panodaki şablon kartta ve röle özetinde görünür', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      env.device
        ..tplId = kTplId
        ..tplVer = 3;
      await _open(tester, env);
      await pumpUntil(tester, env, () => present('card_relay_5'));
      expect(_offstagePresent('template_board_current'), isTrue);
      expect(find.textContaining('(v3)', skipOffstage: false), findsWidgets);
      expect(_offstagePresent('relay_template_pill'), isTrue);
    });

    testWidgets('eski firmware: "Şablon Seç" -> güncelleme uyarısı, düğme kalkar', (tester) async {
      final env = await _deployed(caps: false);
      addTearDown(env.dispose);
      await _open(tester, env);
      await pumpUntil(tester, env, () => present('card_relay_5'));
      await tapKey(tester, 'btn_template_open');
      await pumpUntil(tester, env, () => _offstagePresent('template_unsupported'));
      expect(find.textContaining('v1.3.0', skipOffstage: false), findsWidgets);
      expect(_offstagePresent('btn_template_open'), isFalse);
    });
  });

  for (final config in <({Size size, double scale})>[
    (size: const Size(360, 640), scale: 2.0),
    (size: const Size(320, 568), scale: 2.0),
  ]) {
    testWidgets(
        'yerleşim ${config.size.width.toInt()}x${config.size.height.toInt()} yazı ${config.scale}x: site → şablon → '
        'önizleme → ret açıklaması → uygulandı taşmaz', (tester) async {
      final env = await _deployed();
      addTearDown(env.dispose);
      await _open(tester, env, size: config.size, scale: config.scale);
      await pumpUntil(tester, env, () => _offstagePresent('btn_template_open'));
      expect(tester.takeException(), isNull, reason: 'kapalı kart');

      await tapKey(tester, 'btn_template_open');
      await pumpUntil(tester, env, () => _offstagePresent('template_site_$kSiteId'));
      expect(tester.takeException(), isNull, reason: 'site seçimi');

      await tapKey(tester, 'template_site_$kSiteId');
      await pumpUntil(tester, env, () => _offstagePresent('template_item_$kTplId'));
      expect(tester.takeException(), isNull, reason: 'şablon listesi');

      await tapKey(tester, 'template_item_$kTplId');
      await pumpUntil(tester, env, () => _offstagePresent('btn_template_apply'));
      expect(_offstagePresent('template_preview'), isTrue);
      expect(tester.takeException(), isNull, reason: 'önizleme');

      env.device.templateRejectOnce = (403, 'local_loosen_forbidden', null);
      await tapKey(tester, 'btn_template_apply');
      await pumpUntil(tester, env, () => _offstagePresent('template_problem'));
      expect(find.textContaining('atölyede USB ile yazın', skipOffstage: false), findsWidgets);
      expect(tester.takeException(), isNull, reason: 'gevşetme yasağı açıklaması');

      await tapKey(tester, 'btn_template_apply');
      await pumpUntil(tester, env, () => _offstagePresent('template_applied_info'));
      await pumpUntil(tester, env, () => _offstagePresent('card_relay_5'));
      expect(find.textContaining('Şablon Lamba 1', skipOffstage: false), findsWidgets);
      expect(_offstagePresent('relay_template_pill'), isTrue);
      expect(env.cloud.templateWrites.map((w) => w['result']), <String>['error', 'ok']);
      expect(tester.takeException(), isNull, reason: 'uygulandı');
    });
  }
}
