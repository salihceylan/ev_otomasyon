import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/template_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// İP-4.3 / İP-4.4: sihirbazın 7. adımındaki isteğe bağlı "Şablon uygula" akışı (plan K-Ş10) — şablonlu ve şablonsuz
/// kurulum, eski firmware, panonun her ret kodu, bulut yazım kaydı (`via: "lan"`) ve yetki.
void main() {
  late ServiceHarness env;
  late ServiceSetupController c;

  Future<void> atRelays({bool caps = true}) async {
    env = await serviceHarness();
    env.device.templateCaps = caps;
    c = await reachStep(env, SetupSteps.relays);
    await waitUntil(env, () => c.relays.loaded && !c.isBusy);
  }

  Future<void> toPreview({bool global = false}) async {
    expect(await drive(env, c.template.open()), isTrue);
    expect(c.template.stage, TemplateStage.site);
    expect(await drive(env, c.template.chooseSite(global ? null : c.template.sites.single)), isTrue);
    expect(c.template.stage, TemplateStage.template);
    expect(await drive(env, c.template.chooseTemplate(c.template.templates.single)), isTrue);
    expect(c.template.stage, TemplateStage.preview);
  }

  tearDown(() => env.dispose());

  group('şablonlu kurulum', () {
    test('site → şablon → önizleme → LAN uygula: 7-9. adımlar şablon değerleriyle sıfırdan gelir, yazım "lan" kaydedilir',
        () async {
      await atRelays();
      // Şablondan ÖNCE bir röle test edildi: şablon uygulanınca bu ilerleme geçersiz olur.
      final first = c.relays.relays.first.id;
      expect(await drive(env, c.relays.command(first, true)), isTrue);
      c.relays.confirmLit(first, true);
      expect(await drive(env, c.relays.command(first, false)), isTrue);
      expect(c.relays.okCount, 1);
      expect(c.template.available, isTrue);
      expect(c.relays.boardTemplate, isNull);

      await toPreview();
      expect(env.cloud.calls, contains('listInstallTemplates:$kSiteId:false'));
      final preview = c.template.selected!.preview;
      expect(preview.lights, 4);
      expect(preview.shutters, 2);
      expect(preview.inputs, 8);
      expect(preview.sensors, 1);

      expect(await drive(env, c.template.apply()), isTrue);
      expect(c.template.problem, isNull);
      final sent = env.device.templateApplies.single;
      expect(sent['label'], 'Daire 5');
      expect((sent['template'] as Map)['meta'], containsPair('template_id', kTplId));

      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
      expect(c.relays.relays.map((r) => r.name), <String>[for (var i = 1; i <= 4; i++) 'Şablon Lamba $i']);
      expect(c.relays.okCount, 0, reason: 'test ilerlemesi sıfırlandı: yalnız test kalır');
      expect(c.relays.isComplete, isFalse);
      expect(c.relays.boardTemplate, const TemplateRef(id: kTplId, version: 4));
      expect(c.shutters.loaded, isFalse, reason: 'panjurlar adıma girilince panodan (şablon süreleriyle) okunur');
      expect(c.buttons.loaded, isFalse);
      expect(c.template.stage, TemplateStage.closed);
      expect(c.template.applied?.name, 'B Tipi 3+1');
      expect(env.cloud.templateWrites.single, <String, dynamic>{
        'device_uuid': kDeviceUid,
        'template_id': kTplId,
        'version': 4,
        'via': 'lan',
        'result': 'ok',
      });
      expect(c.template.recordFailed, isFalse);

      // Testler şablon değerleriyle sürer: panjur adımı şablonun 25 sn süresini görür.
      await completeRelays(env, c);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
      expect(c.shutters.shutters, hasLength(2));
      expect(env.device.shutterRuntime(1), 25);
      expect(c.shutters.shutters.first.name, contains('Oda 1'));
    });

    test('"Genel" seçilince yalnız genel şablonlar listelenir', () async {
      await atRelays();
      await toPreview(global: true);
      expect(c.template.selected!.id, kGlobalTplId);
      expect(c.template.selected!.summary.isGlobal, isTrue);
    });

    test('bulut kaydı gönderilemezse yazım geçerli kalır, not gösterilir', () async {
      await atRelays();
      env.cloud.templateWriteError = ApiException.network();
      await toPreview();
      expect(await drive(env, c.template.apply()), isTrue);
      expect(c.template.recordFailed, isTrue);
      expect(env.device.tplId, kTplId);
    });

    test('geri / kapat seçimleri bırakır', () async {
      await atRelays();
      await toPreview();
      c.template.back();
      expect(c.template.stage, TemplateStage.template);
      c.template.back();
      expect(c.template.stage, TemplateStage.site);
      c.template.close();
      expect(c.template.stage, TemplateStage.closed);
      expect(c.template.selected, isNull);
    });

    test('etiket 31 baytı aşmaz (UTF-8)', () {
      expect(TemplateLogic.labelFor('  Daire 5 '), 'Daire 5');
      final long = TemplateLogic.labelFor('Güneş Sitesi Çağlayan Blok Daire 120');
      expect(long.length, lessThan(36));
      expect(long.startsWith('Güneş Sitesi'), isTrue);
    });
  });

  group('panonun ret kodları (hiçbir şey değişmez, açıklama gösterilir, ret kaydedilir)', () {
    for (final c0 in <({int status, String code, String? path, String text, bool retry})>[
      (
        status: 403,
        code: 'local_loosen_forbidden',
        path: null,
        text: 'Panodaki güvenlik ayarı bu şablonla gevşer; atölyede USB ile yazın',
        retry: false,
      ),
      (status: 409, code: 'zone_latched', path: null, text: 'alarm', retry: true),
      (status: 409, code: 'armed', path: null, text: 'Alarm kuruluyken', retry: true),
      (status: 409, code: 'busy', path: null, text: 'panjur', retry: true),
      (status: 507, code: 'storage', path: null, text: 'belleğinde yer yok', retry: false),
      (status: 400, code: 'invalid_runtime', path: 'relays[3].runtime_s', text: 'relays[3].runtime_s', retry: false),
    ]) {
      test('${c0.status} ${c0.code}', () async {
        await atRelays();
        final namesBefore = c.relays.relays.map((r) => r.name).toList();
        await toPreview();
        env.device.templateRejectOnce = (c0.status, c0.code, c0.path);
        expect(await drive(env, c.template.apply()), isFalse);
        final problem = c.template.problem!;
        expect('${problem.title} ${problem.why} ${problem.todo}', contains(c0.text));
        expect(problem.retryable, c0.retry);
        expect(c.template.stage, TemplateStage.preview, reason: 'seçim korunur (düzeltip yeniden denenebilir)');
        expect(env.device.tplId, isNull);
        expect(c.relays.relays.map((r) => r.name).toList(), namesBefore, reason: 'röle listesi değişmedi');
        expect(env.cloud.templateWrites.single, containsPair('result', 'error'));
        expect(env.cloud.templateWrites.single, containsPair('error_code', c0.code));
        expect(env.cloud.templateWrites.single, containsPair('via', 'lan'));
        if (c0.retry) {
          expect(await drive(env, c.template.retry().then((_) => c.template.problem == null)), isTrue);
          expect(env.device.tplId, kTplId);
        }
      });
    }

    test('local_loosen_forbidden: kart görünür açıklaması (SetupProblemKind.forbidden)', () async {
      await atRelays();
      await toPreview();
      env.device.templateRejectOnce = (403, 'local_loosen_forbidden', null);
      await drive(env, c.template.apply());
      expect(c.template.problem!.kind, SetupProblemKind.forbidden);
      expect(c.template.problem!.why, contains('USB'));
    });
  });

  group('şablonsuz / desteklenmeyen', () {
    test('eski firmware (GET /api/template 404): "v1.3.0\'a güncelleyin", siteler hiç istenmez', () async {
      await atRelays(caps: false);
      expect(await drive(env, c.template.open()), isTrue);
      expect(c.template.supported, isFalse);
      expect(c.template.stage, TemplateStage.closed);
      expect(TemplateLogic.unsupportedProblem.why, contains('Pano yazılımı şablonu desteklemiyor, v1.3.0\'a güncelleyin'));
      expect(env.cloud.calls, isNot(contains('listInstallSites')));
    });

    test('şablon kullanılmazsa adımlar bugünkü gibi: hiç şablon isteği gitmez', () async {
      env = await serviceHarness();
      env.device.templateCaps = true;
      c = await reachStep(env, SetupSteps.buttons);
      expect(env.device.api.count('GET', '/api/template'), 0);
      expect(env.device.api.count('POST', '/api/template/apply'), 0);
      expect(env.cloud.calls.where((x) => x.contains('Template') || x.contains('Site')), isEmpty);
    });

    test('panoda zaten şablon varsa 7. adım özetinde görünür (durum `tpl`)', () async {
      env = await serviceHarness();
      env.device
        ..templateCaps = true
        ..tplId = kTplId
        ..tplVer = 3;
      c = await reachStep(env, SetupSteps.relays);
      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
      expect(c.relays.boardTemplate, const TemplateRef(id: kTplId, version: 3));
      expect(await drive(env, c.template.open()), isTrue);
      expect(c.template.board?.templateId, kTplId);
      expect(c.template.board?.version, 3);
    });

    test('servis PIN oturumu: kart yok (available=false)', () async {
      env = await serviceHarness(role: 'pin');
      c = env.newController(
        existingTarget: const ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Servis Evi', ip: kLanIp),
        startStep: SetupSteps.relays,
      );
      addTearDown(c.dispose);
      expect(env.access.canUseInstallTemplates, isFalse);
      expect(c.template.available, isFalse);
    });

    test('süper kullanıcı: kart var', () async {
      env = await serviceHarness(role: 'super');
      expect(env.access.canUseInstallTemplates, isTrue);
    });
  });
}
