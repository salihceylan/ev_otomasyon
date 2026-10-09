import 'dart:convert';

import 'package:ev_otomasyon/ui/pages/service_setup/logic/relay_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// WP-A4: kurulum sihirbazı Adım 7 genişletmesi — sensör/eylemci ataması (DI ya da köprü kaynağı; vana/siren/fan/genel;
/// tek/iki röleli vana; su/gaz), K4 dimmer sorusu ve yönerge metni (tasarım §4.4, §4.5, §2.4, §7.2b).
void main() {
  const valve = ChannelAssignment(
    use: ChannelUse.valve,
    closeMode: ValveCloseMode.deenergizeToClose,
    medium: 'water',
  );
  const waterSensor = InputAssignment(src: 'di', index: 1, role: InputRole.water, normallyClosed: true);

  List<String> blocking(List<SafetyIssue> issues) => <String>[for (final i in issues) if (i.blocking) i.message];
  List<String> warnings(List<SafetyIssue> issues) => <String>[for (final i in issues) if (!i.blocking) i.message];

  group('saf kurallar (validateSafetyPlan)', () {
    test('vana: kapanma kipi ve akışkan seçilmeden kaydedilemez', () {
      final issues = validateSafetyPlan(
        const <int, ChannelAssignment>{5: ChannelAssignment(use: ChannelUse.valve)},
        const <InputAssignment>[],
      );
      expect(blocking(issues), hasLength(2));
      expect(blocking(issues).join(' '), contains('enerji varken'));
      expect(blocking(issues).join(' '), contains('Su ya da Gaz'));
      expect(blocking(validateSafetyPlan(const <int, ChannelAssignment>{5: valve}, const <InputAssignment>[waterSensor])), isEmpty);
    });

    test('iki röleli vana: açma rölesi zorunlu, kendisi olamaz, başka cihaza atanmış olamaz', () {
      final dual = valve.copyWith(drive: ValveDrive.dual);
      expect(blocking(validateSafetyPlan(<int, ChannelAssignment>{5: dual, 6: ChannelAssignment.none}, const [waterSensor])).single,
          contains('açma rölesini seçin'));
      expect(blocking(validateSafetyPlan(<int, ChannelAssignment>{5: dual.copyWith(openRelay: 5)}, const [waterSensor])).single,
          contains('farklı'));
      expect(
        blocking(validateSafetyPlan(
          <int, ChannelAssignment>{5: dual.copyWith(openRelay: 6), 6: const ChannelAssignment(use: ChannelUse.siren)},
          const [waterSensor],
        )).single,
        contains('başka bir cihaza'),
      );
      final ok = <int, ChannelAssignment>{5: dual.copyWith(openRelay: 6), 6: ChannelAssignment.none};
      expect(blocking(validateSafetyPlan(ok, const [waterSensor])), isEmpty);
      expect(openRelayOwnersOf(ok), <int, int>{6: 5});
    });

    test('gaz/duman dedektörü NC zorunlu (seçim NO yapılamaz); su sensörü NO -> uyarı', () {
      const gasNo = InputAssignment(src: 'di', index: 2, role: InputRole.gas);
      expect(gasNo.normalized().normallyClosed, isTrue);
      expect(const InputAssignment(src: 'di', index: 2).copyWith(role: InputRole.smoke, normallyClosed: false).normallyClosed, isTrue);
      expect(blocking(validateSafetyPlan(const {}, const <InputAssignment>[gasNo])).single, contains('NC'));
      const waterNo = InputAssignment(src: 'di', index: 1, role: InputRole.water);
      final issues = validateSafetyPlan(const {}, const <InputAssignment>[waterNo]);
      expect(blocking(issues), isEmpty);
      expect(warnings(issues).single, contains('Kablo koparsa'));
    });

    test('geri bildirim girişi "Vana geri bildirimi" rolünde olmalı; gaz bölgesindeki siren/fan uyarısı; gaz vanası notu', () {
      final fb = valve.copyWith(fbDi: 3);
      expect(
        blocking(validateSafetyPlan(<int, ChannelAssignment>{5: fb}, const <InputAssignment>[waterSensor, InputAssignment(src: 'di', index: 3)])).single,
        contains('hem geri bildirim'),
      );
      expect(
        blocking(validateSafetyPlan(<int, ChannelAssignment>{5: fb},
            const <InputAssignment>[waterSensor, InputAssignment(src: 'di', index: 3, role: InputRole.valveFeedback)])),
        isEmpty,
      );
      final gas = <int, ChannelAssignment>{
        5: valve.copyWith(medium: 'gas'),
        6: const ChannelAssignment(use: ChannelUse.fan),
      };
      final w = warnings(validateSafetyPlan(gas, const <InputAssignment>[InputAssignment(src: 'di', index: 2, role: InputRole.gas, normallyClosed: true)]));
      expect(w.join(' '), contains('gaz kaçağı bölgesinin dışında'));
      expect(w.join(' '), contains('yalnız yerinde'));
      expect(w.join(' '), contains('Gaz vanası açma düğmesi tanımlı değil'));
    });

    test('kablosuz (köprü) yuvaya yalnız sensör atanır', () {
      const bad = InputAssignment(src: 'bridge', index: 1, role: InputRole.alarmAck);
      expect(blocking(validateSafetyPlan(const {}, const <InputAssignment>[bad])).single, contains('yalnız sensör'));
      expect(const InputAssignment(src: 'bridge', index: 2, role: InputRole.water).id, 'b2');
    });

    test('fw-tarama-1 (C1): caps "bridge" bildirmeyen panoda kablosuz sensör kayıt engelidir; destekleyen panoda değil', () {
      const wireless = InputAssignment(src: 'bridge', index: 1, role: InputRole.water, normallyClosed: true);
      const di = InputAssignment(src: 'di', index: 2, role: InputRole.water, normallyClosed: true);
      final unsupported = validateSafetyPlan(const {}, const <InputAssignment>[wireless, di], bridgeSupported: false);
      expect(blocking(unsupported), <String>['Bu panoda kablosuz sensör desteklenmiyor; kaldırın.']);
      expect(unsupported.where((i) => i.blocking).single.target, 'input:b1');
      expect(blocking(validateSafetyPlan(const {}, const <InputAssignment>[wireless, di], bridgeSupported: true)), isEmpty);
      expect(blocking(validateSafetyPlan(const {}, const <InputAssignment>[di], bridgeSupported: false)), isEmpty,
          reason: 'DI sensörleri etkilenmez');
    });
  });

  group('panoya yazılacak yamalar (buildSafetyPatches; firmware F5 tek öğe, CONTRACTS §2.6)', () {
    test('boş panoya: eylemci, sensör ve dimmer satırları firmware alanlarıyla; geri bildirim girişi sensör sayılmaz', () {
      final patches = buildSafetyPatches(
        current: const <String, dynamic>{'rev': 7, 'sensors': <Object?>[], 'actuators': <Object?>[], 'lights': <Object?>[]},
        channels: <int, ChannelAssignment>{
          5: valve.copyWith(fbDi: 3, zone: 2, drive: ValveDrive.dual, openRelay: 6),
          6: ChannelAssignment.none,
          7: const ChannelAssignment(use: ChannelUse.siren, zone: 2),
          8: const ChannelAssignment(wantsDimming: true),
        },
        inputs: const <InputAssignment>[
          InputAssignment(src: 'di', index: 1, role: InputRole.water, normallyClosed: true, zone: 2),
          InputAssignment(src: 'di', index: 3, role: InputRole.valveFeedback),
          InputAssignment(src: 'di', index: 4, role: InputRole.alarmAck),
          InputAssignment(src: 'bridge', index: 1, role: InputRole.water, zone: 2),
          InputAssignment(src: 'di', index: 2),
        ],
      );
      expect(patches, <Map<String, dynamic>>[
        <String, dynamic>{
          'set': <String, dynamic>{
            'actuator': <String, dynamic>{
              'relay': 5,
              'kind': 'valve',
              'zones': <int>[2],
              'close_mode': 'pulse',
              'medium': 'water',
              'relay2': 6,
              'fb_di': 3,
              'run_limit_s': 15,
            },
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'actuator': <String, dynamic>{'relay': 7, 'kind': 'siren', 'zones': <int>[2], 'run_limit_s': 180},
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'sensor': <String, dynamic>{'id': 'd1', 'kind': 'water', 'zone': 2, 'active_open': 1},
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'sensor': <String, dynamic>{'id': 'd4', 'kind': 'alarm_ack', 'zone': 1, 'active_open': 0},
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'sensor': <String, dynamic>{'id': 'b1', 'kind': 'water', 'zone': 2, 'active_open': 0},
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'light': <String, dynamic>{'relay': 8, 'dimmable': 1, 'src': 1, 'addr': 2, 'ch': 1},
          },
        },
      ]);
    });

    test('dolu panoya: değişmeyen öğe yazılmaz; ad korunur; silme büyük kimlikten, güncelleme kaydırılmış kimlikle', () {
      final current = <String, dynamic>{
        'rev': 12,
        'sensors': <Object?>[
          <String, dynamic>{'id': 'd1', 'kind': 'water', 'zone': 1, 'active_open': 1, 'flags': 3, 'confirm_ms': 3000, 'name': 'Evye'},
          <String, dynamic>{'id': 'd2', 'kind': 'door', 'zone': 1, 'active_open': 0, 'flags': 0, 'confirm_ms': 0, 'name': ''},
          <String, dynamic>{'id': 'd9', 'kind': 'generic', 'zone': 1, 'active_open': 0, 'flags': 0, 'confirm_ms': 0, 'name': 'Plan dışı'},
        ],
        'actuators': <Object?>[
          <String, dynamic>{'id': 'a1', 'relay': 3, 'kind': 'siren', 'close_mode': 'energize', 'medium': 'none', 'zones': <int>[1], 'fb_di': 0, 'fb_closed_active': 1, 'fb_timeout_s': 30, 'run_limit_s': 180, 'exproof': false, 'name': 'Siren'},
          <String, dynamic>{'id': 'a2', 'relay': 5, 'kind': 'valve', 'close_mode': 'deenergize', 'medium': 'water', 'zones': <int>[1], 'fb_di': 0, 'fb_closed_active': 1, 'fb_timeout_s': 45, 'run_limit_s': 0, 'exproof': false, 'name': 'Ana vana'},
          <String, dynamic>{'id': 'a3', 'relay': 9, 'kind': 'fan', 'close_mode': 'energize', 'medium': 'none', 'zones': <int>[1], 'fb_di': 0, 'fb_closed_active': 1, 'fb_timeout_s': 30, 'run_limit_s': 0, 'exproof': false, 'name': 'Fan'},
        ],
        'lights': <Object?>[
          <String, dynamic>{'relay': 4, 'dimmable': 1, 'src': 2, 'addr': 0, 'ch': 0},
        ],
      };
      final patches = buildSafetyPatches(
        current: current,
        channels: <int, ChannelAssignment>{
          3: ChannelAssignment.none, // siren lambaya döndü -> a1 silinir
          4: ChannelAssignment.none, // dimmer kaldırıldı -> ışık seçeneği sıfırlanır
          5: valve.copyWith(fbDi: 2), // geri bildirim eklendi -> a2 (kaydırılmış: a1) güncellenir, ad korunur
          9: const ChannelAssignment(use: ChannelUse.fan), // değişmedi -> yazılmaz
        },
        inputs: const <InputAssignment>[
          InputAssignment(src: 'di', index: 1, role: InputRole.water, normallyClosed: true), // değişmedi
          InputAssignment(src: 'di', index: 2, role: InputRole.valveFeedback), // kapı -> geri bildirim: d2 silinir
        ],
      );
      expect(patches, <Map<String, dynamic>>[
        <String, dynamic>{
          'del': <String, dynamic>{'sensor': 'd2'},
        },
        <String, dynamic>{
          'del': <String, dynamic>{'actuator': 'a1'},
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'actuator': <String, dynamic>{
              'id': 'a1',
              'relay': 5,
              'relay2': 0,
              'kind': 'valve',
              'close_mode': 'deenergize',
              'medium': 'water',
              'zones': <int>[1],
              'fb_di': 2,
              'fb_closed_active': 1,
              'fb_timeout_s': 45,
              'run_limit_s': 0,
              'exproof': false,
              'name': 'Ana vana',
            },
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'light': <String, dynamic>{'relay': 4, 'dimmable': 0, 'src': 0, 'addr': 0, 'ch': 0},
          },
        },
      ]);
    });

    test('fw-tarama-1 (C1): plandan kaldırılan kablosuz sensör panodan da silinir; silme diğer yamalardan önce', () {
      // v1.3.2 firmware'i köprü sensörü içeren tabloya silme dışındaki her yamayı sensor_bridge_unsupported ile reddeder:
      // "Kaldır" düğmesiyle plandan çıkan kayıtlı kablosuz sensör silinmezse plan panoya hiç yazılamaz.
      final patches = buildSafetyPatches(
        current: const <String, dynamic>{
          'rev': 4,
          'sensors': <Object?>[
            <String, dynamic>{'id': 'b1', 'kind': 'water', 'zone': 1, 'nc': 0, 'confirm_ms': 2000, 'flags': 0},
          ],
          'actuators': <Object?>[],
          'lights': <Object?>[],
        },
        channels: const <int, ChannelAssignment>{},
        inputs: const <InputAssignment>[
          InputAssignment(src: 'di', index: 1, role: InputRole.water, normallyClosed: true),
        ],
      );
      expect(patches.first, <String, dynamic>{
        'del': <String, dynamic>{'sensor': 'b1'},
      });
      expect(patches.where((p) => p.containsKey('set')).map((p) => (p['set'] as Map)['sensor']?['id']), contains('d1'));
    });

    test('panonun yapılandırma satırı (firmware alanları) atamaya döner: pulse, relay2, fb_di 0 = yok, exproof', () {
      final dual = ChannelAssignment.fromBoard(const <String, dynamic>{
        'id': 'a1', 'relay': 5, 'relay2': 6, 'kind': 'valve', 'close_mode': 'pulse', 'medium': 'water', 'zones': <int>[2],
        'fb_di': 0, 'run_limit_s': 20,
      });
      expect(dual.drive, ValveDrive.dual);
      expect(dual.openRelay, 6);
      expect(dual.pulseSec, 20);
      expect(dual.fbDi, isNull);
      expect(dual.zone, 2);
      expect(dual.closeMode, isNot(ValveCloseMode.unknown));
      final fan = ChannelAssignment.fromBoard(const <String, dynamic>{'relay': 9, 'kind': 'fan', 'exproof': true, 'zones': <int>[1]});
      expect(fan.fanExProof, isTrue);
      final nc = InputAssignment.fromBoard(const <String, dynamic>{'id': 'd3', 'kind': 'gas', 'zone': 1, 'active_open': 1});
      expect(nc!.normallyClosed, isTrue);
      expect(nc.id, 'd3');
    });
  });

  group('K4 dimmer yönergesi (§4.5)', () {
    test('ek modül yokken adres 2; yer tutucular dolu', () {
      final g = dimmerGuideFor(relay: 3, dimmerChannel: 1, extEnabled: false);
      expect(g.address, 2);
      final text = g.fullText;
      expect(text, contains('Bu kanal için dimmer gerekiyor'));
      expect(text, contains('A→A, B→B, ortak GND'));
      expect(text, contains('adresini 2 yapın'));
      expect(text, contains('Röle 3 yerine dimmer modülünün Çıkış 1 ucuna'));
      expect(text, contains('%N parlaklık yerine "aç"'));
      expect(text, isNot(contains('{')), reason: 'doldurulmamış yer tutucu kalmaz');
    });

    test('ek modül açıkken adres = ek modül + 1 (247 sınırı)', () {
      expect(dimmerGuideFor(relay: 5, dimmerChannel: 2, extEnabled: true, extAddress: 5).fullText, contains('adresini 6 yapın. Bu adres ek modülün adresinden (5)'));
      expect(suggestedDimmerAddress(extEnabled: true, extAddress: 247), 246);
      expect(suggestedDimmerAddress(extEnabled: true, extAddress: 1), 2);
    });

    test('bölge testi sonuç metinleri (§4.4 madde 3)', () {
      expect(const SafetyTestResult(zone: 1, ok: true, fbMs: 4200).message, contains("Vana 4,2 sn'de kapandı (geri bildirim doğrulandı)"));
      expect(const SafetyTestResult(zone: 1, ok: true).message, contains('Geri bildirim yok: vananın kapandığını gözle doğrulayın'));
      expect(const SafetyTestResult(zone: 2, ok: false).failed, isTrue);
    });
  });

  group('kayıt biçimi (setup_store v:2)', () {
    test('kayıt sürümü 2; v:1 kaydı okunur', () {
      final now = DateTime.utc(2026, 10, 7, 12);
      final rec = SetupProgressRecord(ownerKey: 'user:1', deviceUuid: kDeviceUid, homeId: 'h', createdAt: now, updatedAt: now);
      expect(rec.toJson()['v'], 2);
      final v1 = <String, dynamic>{...rec.toJson(), 'v': 1, 'data': <String, dynamic>{'7': <String, dynamic>{'relays': <String, String>{'5': 'ok'}}}};
      final parsed = SetupProgressRecord.tryParse(jsonDecode(jsonEncode(v1)));
      expect(parsed, isNotNull);
      expect(parsed!.data['7'], isNotNull);
    });

    test('atamalar gidiş-dönüş; bozuk alanlar varsayılana döner', () {
      final a = valve.copyWith(drive: ValveDrive.dual, openRelay: 6, fbDi: 3, zone: 2);
      expect(ChannelAssignment.fromJson(jsonDecode(jsonEncode(a.toJson()))), a);
      expect(ChannelAssignment.fromJson(<String, dynamic>{'use': 'roket', 'zone': 99}), const ChannelAssignment(zone: 4));
      const i = InputAssignment(src: 'bridge', index: 2, role: InputRole.smoke, normallyClosed: true, zone: 3);
      expect(InputAssignment.fromJson(jsonDecode(jsonEncode(i.toJson()))), i);
      expect(InputAssignment.fromJson(<String, dynamic>{'src': 'bridge', 'i': 99}), isNull);
    });
  });

  group('Adım 7 mantığı (sahte pano)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    Future<void> start({bool safety = true, bool ext = false, bool bridge = false}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      env = await serviceHarness();
      env.device.safetyCaps = safety;
      env.device.bridgeCaps = bridge;
      env.device.extEnabled = ext;
      env.device.extAddress = 4;
      c = await reachStep(env, SetupSteps.relays);
      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
    }

    Future<void> verifyRelays() async {
      for (final r in List<RelayCheck>.of(c.relays.relays)) {
        expect(await drive(env, c.relays.command(r.id, true)), isTrue);
        c.relays.confirmLit(r.id, true);
        expect(await drive(env, c.relays.command(r.id, false)), isTrue);
      }
    }

    tearDown(() => env.dispose());

    test('yükleme: kanallar varsayılan "Lamba", girişler duvar butonu; pano yetenekleri okunur', () async {
      await start(ext: true);
      expect(c.relays.relays.map((r) => r.assign), everyElement(ChannelAssignment.none));
      expect(c.relays.inputs.map((i) => i.id), <String>['d1', 'd2', 'd3', 'd4']);
      expect(c.relays.inputs.map((i) => i.role), everyElement(InputRole.button));
      expect(c.relays.safetySupported, isTrue);
      expect(c.relays.extEnabled, isTrue);
      expect(c.relays.extAddress, 4);
      expect(c.relays.dimmerGuide(5).address, 5, reason: 'ek modül 4 -> 5');
    });

    test('eski pano (güvenlik yok): eylemci ataması kaydedilemez ve adım tamamlanmaz; yalnız dimmer engellemez', () async {
      await start(safety: false);
      await verifyRelays();
      expect(c.relays.isComplete, isTrue);
      c.relays.setAssignment(6, const ChannelAssignment(wantsDimming: true));
      expect(c.relays.isComplete, isTrue, reason: 'dimmer yalnız yönerge: güvenlik yazımı gerektirmez');
      c.relays.setAssignment(5, valve);
      expect(c.relays.needsSafetySave, isTrue);
      expect(c.relays.isComplete, isFalse);
      expect(await drive(env, c.relays.saveSafety()), isFalse);
      expect(c.relays.problem!.title, contains('desteklemiyor'));
      expect(env.device.savedSafetyConfig, isNull);
    });

    test('fw-tarama-1 (C1): caps "bridge" bildirmeyen panoda kablosuz sensör eklenemez', () async {
      await start();
      expect(c.relays.bridgeSupported, isFalse);
      c.relays.addBridgeSensor();
      expect(c.relays.inputs.where((i) => i.isBridge), isEmpty);
      expect(c.relays.safetyDirty, isFalse);
    });

    test('kayıt: eksik bilgi panoya gitmez; tam plan yazılır, bölge testi çalışır, sonuç metni gösterilir', () async {
      await start(bridge: true);
      await verifyRelays();
      c.relays.setAssignment(5, const ChannelAssignment(use: ChannelUse.valve));
      expect(await drive(env, c.relays.saveSafety()), isFalse);
      expect(c.relays.problem!.title, contains('eksik'));
      expect(env.device.savedSafetyConfig, isNull);

      c.relays.setAssignment(5, valve.copyWith(fbDi: 3));
      c.relays.setInput(c.relays.inputs.first.copyWith(role: InputRole.water, normallyClosed: true));
      expect(c.relays.inputs[2].role, InputRole.valveFeedback, reason: 'geri bildirim girişi kendiliğinden işaretlenir');
      c.relays.addBridgeSensor();
      expect(c.relays.inputs.last.id, 'b1');
      expect(c.relays.isComplete, isFalse, reason: 'güvenlik ataması panoya yazılmadan adım bitmez');

      env.device.testResultFbMs = 4200;
      expect(await drive(env, c.relays.saveSafety()), isTrue);
      final saved = env.device.savedSafetyConfig!;
      expect(env.device.safetyPatches.first['base_rev'], 3, reason: 'ilk yama panonun okunan rev\'iyle');
      expect(env.device.safetyPatches.map((p) => p['base_rev']), <int>[for (var i = 0; i < env.device.safetyPatches.length; i++) 3 + i],
          reason: 'her yama bir öncekinin rev\'iyle (zincir)');
      expect((saved['actuators'] as List).single['relay'], 5);
      expect((saved['actuators'] as List).single['fb_di'], 3);
      expect((saved['sensors'] as List).map((s) => s['id']), <String>['d1', 'b1']);
      expect(env.device.alarmTests, <int>[1]);
      expect(c.relays.testResults.single.message, contains("4,2 sn'de kapandı"));
      expect(c.relays.needsSafetySave, isFalse);
      expect(c.relays.isComplete, isTrue);

      // Sonradan değişiklik yeniden yazım ister.
      c.relays.setAssignment(7, const ChannelAssignment(use: ChannelUse.siren));
      expect(c.relays.isComplete, isFalse);
    });

    test('kayıt ve geri yükleme: atamalar ve girişler kalıcı; v:1 kayıt (yalnız röle sonuçları) varsayılanlarla açılır', () async {
      await start();
      c.relays.setAssignment(5, valve.copyWith(zone: 2));
      c.relays.setAssignment(6, const ChannelAssignment(wantsDimming: true, dimmerSource: DimmerSource.bridge));
      c.relays.setInput(c.relays.inputs.first.copyWith(role: InputRole.gas));
      final snap = c.relays.snapshot();
      final again = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;

      final fresh = RelayLogic(c.relays.ctx)..restore(again);
      expect(await drive(env, fresh.load()), isTrue);
      expect(fresh.byId(5)!.assign, valve.copyWith(zone: 2));
      expect(fresh.byId(6)!.assign.dimmerSource, DimmerSource.bridge);
      expect(fresh.inputs.first.role, InputRole.gas);
      expect(fresh.inputs.first.normallyClosed, isTrue);
      expect(fresh.needsSafetySave, isTrue);

      final v1 = RelayLogic(c.relays.ctx)..restore(<String, dynamic>{'relays': <String, String>{'5': 'ok'}});
      expect(await drive(env, v1.load()), isTrue);
      expect(v1.byId(5)!.verdict, RelayVerdict.ok);
      expect(v1.byId(5)!.assign, ChannelAssignment.none);
      expect(v1.inputs.map((i) => i.role), everyElement(InputRole.button));
    });

    test('panoda zaten tanımlı eylemci: listede kalır, türü önceden seçili; bölge testiyle doğrulanır', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      env = await serviceHarness();
      env.device
        ..safetyCaps = true
        ..relayAct[7] = 'valve'
        ..boardActuators.add(<String, dynamic>{
          'id': 'a1',
          'relay': 7,
          'kind': 'valve',
          'medium': 'water',
          'zones': <int>[1],
          'pos': 'open',
        });
      c = await reachStep(env, SetupSteps.relays);
      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
      final r7 = c.relays.byId(7)!;
      expect(r7.boardActuator, isTrue);
      expect(r7.assign.use, ChannelUse.valve);
      expect(r7.assign.medium, 'water');

      expect(await drive(env, c.relays.testActuator(7)), isTrue);
      expect(env.device.alarmTests, <int>[1]);
      expect(c.relays.byId(7)!.awaitingLitAnswer, isTrue);
      c.relays.confirmLit(7, true);
      expect(c.relays.byId(7)!.verdict, RelayVerdict.ok);
    });
  });
}
