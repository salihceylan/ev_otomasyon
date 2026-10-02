import 'dart:convert';

import 'package:ev_otomasyon/ui/pages/service_setup/logic/relay_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// İlerleme kaydı (cihaz bazlı devam etme): kayıt içeriği, sahiplik kapsamı, gizli değer yokluğu, devam
/// ettirme ve silme davranışları.

SetupProgressRecord record({
  String owner = 'user:staff-1',
  String uid = kDeviceUid,
  DateTime? updated,
  int step = 5,
  Map<String, dynamic> data = const <String, dynamic>{},
}) {
  final now = updated ?? DateTime.utc(2026, 10, 1, 12);
  return SetupProgressRecord(
    ownerKey: owner,
    deviceUuid: uid,
    homeId: kClaimedHome,
    homeName: 'Daire 5',
    ip: kLanIp,
    currentStep: step,
    createdAt: now.subtract(const Duration(hours: 1)),
    updatedAt: now,
    data: data,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SetupStore', () {
    test('kaydedilen ilerleme owner kapsamında listelenir; en son güncellenen önce gelir', () async {
      final store = SetupStore();
      await store.save(record(uid: 'AHBU-S3-AAA111', updated: DateTime.utc(2026, 10, 1, 10)));
      await store.save(record(uid: 'AHBU-S3-BBB222', updated: DateTime.utc(2026, 10, 1, 12)));
      await store.save(record(owner: 'user:baska', uid: 'AHBU-S3-CCC333'));

      final mine = await store.list('user:staff-1');
      expect(mine.map((r) => r.deviceUuid), <String>['AHBU-S3-BBB222', 'AHBU-S3-AAA111']);
      expect(await store.list('user:baska'), hasLength(1));
      expect(await store.list('user:yok'), isEmpty);
    });

    test('load yalnızca doğru sahibe ve doğru cihaza ait kaydı verir; delete yalnızca o kaydı siler', () async {
      final store = SetupStore();
      await store.save(record());
      await store.save(record(uid: 'AHBU-S3-BBB222'));
      expect(await store.load('user:staff-1', kDeviceUid), isNotNull);
      expect(await store.load('user:baska', kDeviceUid), isNull);
      expect(await store.load('user:staff-1', 'AHBU-S3-YOK000'), isNull);

      await store.delete('user:staff-1', kDeviceUid);
      expect(await store.load('user:staff-1', kDeviceUid), isNull);
      expect(await store.load('user:staff-1', 'AHBU-S3-BBB222'), isNotNull);
    });

    test('aynı cihaz yeniden kaydedilince tek kayıt kalır (güncellenir)', () async {
      final store = SetupStore();
      await store.save(record(step: 5));
      await store.save(record(step: 8));
      final list = await store.list('user:staff-1');
      expect(list, hasLength(1));
      expect(list.single.currentStep, 8);
    });

    test('en fazla ${SetupStore.maxRecords} kayıt tutulur; en eskiler silinir', () async {
      final store = SetupStore();
      for (var i = 0; i < SetupStore.maxRecords + 5; i++) {
        await store.save(record(uid: 'AHBU-S3-${i.toString().padLeft(6, '0')}', updated: DateTime.utc(2026, 10, 1, 12, i)));
      }
      final list = await store.list('user:staff-1');
      expect(list, hasLength(SetupStore.maxRecords));
      expect(list.any((r) => r.deviceUuid == 'AHBU-S3-000000'), isFalse, reason: 'en eski silindi');
      expect(list.any((r) => r.deviceUuid == 'AHBU-S3-${(SetupStore.maxRecords + 4).toString().padLeft(6, '0')}'), isTrue);
    });

    test('bozuk kayıt listeden atılır ve temizlenir; diğer kayıtlar etkilenmez', () async {
      final store = SetupStore();
      await store.save(record());
      final prefs = await SharedPreferences.getInstance();
      final badKey = SetupStore.keyFor('user:staff-1', 'AHBU-S3-BOZUK1');
      await prefs.setString(badKey, '{bozuk json');
      await prefs.setStringList(SetupStore.indexKey, <String>[SetupStore.keyFor('user:staff-1', kDeviceUid), badKey]);

      final list = await store.list('user:staff-1');
      expect(list.map((r) => r.deviceUuid), <String>[kDeviceUid]);
      expect(prefs.getString(badKey), isNull, reason: 'bozuk kayıt silindi');
    });

    test('depolama hatasında istisna fırlatılmaz: kayıt başarısız işaretlenir, liste boş döner', () async {
      final store = SetupStore(prefs: () async => throw StateError('depolama yok'));
      await store.save(record());
      expect(store.lastWriteFailed, isTrue);
      expect(await store.list('user:staff-1'), isEmpty);
      expect(await store.load('user:staff-1', kDeviceUid), isNull);
      await store.delete('user:staff-1', kDeviceUid);
    });
  });

  group('SetupProgressRecord.tryParse', () {
    test('gidiş-dönüş: JSON yazılıp okununca tüm alanlar korunur', () {
      final original = record(step: 7, data: <String, dynamic>{
        '7': <String, dynamic>{
          'relays': <String, String>{'5': 'ok'},
        },
      }).copyWith(completed: <int>{2, 3, 4, 5, 6}, skipped: <int>{3, 4}, customerHint: 'm***@o***.test');
      final parsed = SetupProgressRecord.tryParse(jsonDecode(jsonEncode(original.toJson())))!;
      expect(parsed.ownerKey, original.ownerKey);
      expect(parsed.deviceUuid, kDeviceUid);
      expect(parsed.homeId, kClaimedHome);
      expect(parsed.currentStep, 7);
      expect(parsed.completed, <int>{2, 3, 4, 5, 6});
      expect(parsed.skipped, <int>{3, 4});
      expect(parsed.customerHint, 'm***@o***.test');
      expect(parsed.data['7'], isNotNull);
      expect(parsed.updatedAt, original.updatedAt);
    });

    test('eksik zorunlu alan, geçersiz tür ve tarih içeren kayıt null döner', () {
      expect(SetupProgressRecord.tryParse(null), isNull);
      expect(SetupProgressRecord.tryParse('metin'), isNull);
      expect(SetupProgressRecord.tryParse(<String, dynamic>{}), isNull);
      final json = record().toJson();
      for (final key in <String>['owner', 'device_uuid', 'home_id', 'created_at', 'updated_at']) {
        final broken = Map<String, dynamic>.of(json)..remove(key);
        expect(SetupProgressRecord.tryParse(broken), isNull, reason: key);
      }
      expect(SetupProgressRecord.tryParse(<String, dynamic>{...json, 'created_at': 'dün'}), isNull);
    });

    test('adım numarası 1-10 aralığına sığdırılır; geçersiz adım listeleri süzülür', () {
      final json = record().toJson();
      expect(SetupProgressRecord.tryParse(<String, dynamic>{...json, 'step': 99})!.currentStep, 10);
      expect(SetupProgressRecord.tryParse(<String, dynamic>{...json, 'step': -3})!.currentStep, 1);
      final parsed = SetupProgressRecord.tryParse(<String, dynamic>{
        ...json,
        'completed': <dynamic>[2, 'x', 99, 0, 5],
        'skipped': 'liste değil',
      })!;
      expect(parsed.completed, <int>{2, 5});
      expect(parsed.skipped, isEmpty);
    });
  });

  group('denetleyici ilerlemeyi kaydeder ve kaldığı yerden sürer', () {
    test('claim sonrası kayıt: hedef, adım, maskeli müşteri bilgisi var; PIN, kod, anahtar, kimlik, Wi-Fi şifresi yok', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await completeClaim(env);
      await pumpEventQueue();

      final saved = (await env.store.list(env.access.ownerKey)).single;
      expect(saved.ownerKey, 'user:staff-1');
      expect(saved.deviceUuid, kDeviceUid);
      expect(saved.homeId, kClaimedHome);
      expect(saved.homeName, 'Daire 5');
      expect(saved.currentStep, SetupSteps.wifi);
      expect(saved.customerHint, 'm***@o***.test');
      expect(saved.completed, containsAll(<int>[2, 3, 4]));
      final raw = await dumpPrefs();
      for (final secret in <String>[kSetupPin, kCustomerOtp, kCredentialPassword, kLocalKey, kHomeWifiPass, kApPass, kCustomerEmail]) {
        expect(raw, isNot(contains(secret)));
        expect(env.dumpSecureStore(), isNot(contains(secret)), reason: 'güvenli depoda da yok');
      }
      expect(c.target!.localKey, kLocalKey, reason: 'anahtar yalnızca bellekte');
    });

    test('kayıttan devam: hedef (ev/cihaz/IP) ve adım geri gelir; anahtar ve kimlik gelmez', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final first = await completeClaim(env);
      await completeWifi(env, first);
      await pumpEventQueue();
      final saved = (await env.store.list(env.access.ownerKey)).single;
      expect(saved.currentStep, SetupSteps.cloud);
      first.dispose();

      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      expect(resumed.currentStep, SetupSteps.cloud);
      expect(resumed.target!.homeId, kClaimedHome);
      expect(resumed.target!.deviceUuid, kDeviceUid);
      expect(resumed.target!.ip, kLanIp);
      expect(resumed.target!.localKey, isNull);
      expect(resumed.ctx.pendingCredential, isNull);
      expect(resumed.claim.isComplete, isTrue);
      expect(resumed.wifi.isComplete, isTrue, reason: 'bağlantı doğrulaması kayıtlı');
      expect(resumed.customer.hint, 'm***@o***.test');
    });

    test('Wi-Fi bağlantısı kanıtlanınca ilerleme hemen kaydedilir; telefon kurulum ağındayken uygulama kapanıp açılsa da 5. adım tamamlı ve adres ev ağındaki IP olur',
        () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final first = await completeClaim(env);
      env.phoneOnSetupNetwork();
      await drive(env, first.wifi.checkDevice());
      expect((await connectHomeWifi(env, first)).isSuccess, isTrue);
      await pumpEventQueue();

      // "Devam"a basılmadan, telefon hâlâ kurulum ağındayken uygulama kapandı.
      final saved = (await env.store.list(env.access.ownerKey)).single;
      expect(saved.currentStep, SetupSteps.wifi);
      expect(saved.ip, kLanIp, reason: 'pano ev ağındaki adresi (wifi_sta_ip) kayda yazıldı');
      expect(saved.data['5'], <String, dynamic>{'connected': true, 'lost': false});
      first.dispose();

      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      expect(resumed.currentStep, SetupSteps.wifi);
      expect(resumed.wifi.isComplete, isTrue, reason: 'bağlantı kanıtı kayıtlı: Wi-Fi tekrar yapılmaz');
      expect(resumed.target!.ip, kLanIp);
      expect(resumed.target!.localKey, isNull, reason: 'anahtar kayda girmez; 6. adımda sunucudan alınır');
      env.phoneOnHomeNetwork();
      resumed.start();
      await pumpEventQueue();
      expect(resumed.canContinue, isTrue);
      resumed.continueNext();
      expect(resumed.currentStep, SetupSteps.cloud);
      expect(await drive(env, resumed.cloud.connectAndWait()), isTrue);
      expect(resumed.target!.localKey, kLocalKey, reason: 'anahtar 6. adımda (ev ağında) sunucudan alındı');
    });

    test('devam edilen kurulumda bulut adımı, kimlik bellekte yokken sunucudan yenisini üretir', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final first = await completeClaim(env);
      await completeWifi(env, first);
      await pumpEventQueue();
      final saved = (await env.store.list(env.access.ownerKey)).single;
      first.dispose();

      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      resumed.start();
      await pumpEventQueue();
      // Telefon yeniden başlatıldı: pano ev ağında ve ulaşılabilir.
      expect(await drive(env, resumed.cloud.connectAndWait()), isTrue);
      expect(env.cloud.calls, contains('reissueDeviceMqttCredential:$kDeviceUid'));
      expect(env.device.receivedMqttPass, isNotNull);
    });

    test('röle doğrulamaları kayda yazılır ve devam edilince korunur', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await reachStep(env, SetupSteps.relays);
      await waitUntil(env, () => c.relays.loaded && !c.isBusy);
      expect(await drive(env, c.relays.command(5, true)), isTrue);
      c.relays.confirmLit(5, true);
      expect(await drive(env, c.relays.command(5, false)), isTrue);
      c.relays.setUnused(6, true);
      await pumpEventQueue();
      final saved = (await env.store.list(env.access.ownerKey)).single;
      expect(saved.data['7'], <String, dynamic>{
        'relays': <String, dynamic>{'5': 'ok', '6': 'unused'},
      });
      c.dispose();

      final resumed = env.newController(resume: saved);
      addTearDown(resumed.dispose);
      resumed.start();
      await waitUntil(env, () => resumed.relays.loaded);
      expect(resumed.relays.byId(5)!.verdict, RelayVerdict.ok);
      expect(resumed.relays.byId(6)!.verdict, RelayVerdict.unused);
      expect(resumed.relays.byId(7)!.verdict, RelayVerdict.untested);
    });

    test('denetleyici atılırken ilerleme yazılır (sayfadan çıkınca kaybolmaz)', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await completeClaim(env);
      c.dispose();
      await pumpEventQueue();
      expect(await env.store.list(env.access.ownerKey), hasLength(1));
    });

    test('kuruluma başlanmadan (cihaz seçilmeden) kayıt oluşmaz', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await startedController(env);
      c.dispose();
      await pumpEventQueue();
      expect(await env.store.list(env.access.ownerKey), isEmpty);
    });

    test('teslim tamamlanınca kayıt silinir; kurulumu bırakmak da kaydı siler', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await reachStep(env, SetupSteps.handover);
      await pumpEventQueue();
      expect(await env.store.list(env.access.ownerKey), hasLength(1));
      c.handover.setOwnerApproved(true);
      expect(await drive(env, c.handover.submit()), isTrue);
      await pumpEventQueue();
      expect(await env.store.list(env.access.ownerKey), isEmpty, reason: 'tamamlanan kurulum "devam eden" listede kalmaz');

      final env2 = await serviceHarness();
      addTearDown(env2.dispose);
      final c2 = await completeClaim(env2);
      await pumpEventQueue();
      await c2.discardProgress();
      expect(await env2.store.list(env2.access.ownerKey), isEmpty);
    });

    test('başka teknisyenin kaydı bu teknisyenin listesinde görünmez', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      await completeClaim(env);
      await pumpEventQueue();
      expect(await env.store.list('user:baska-usta'), isEmpty);
      expect(await env.store.list(env.access.ownerKey), hasLength(1));
    });
  });

  group('ServiceSetupAccess', () {
    test('kalıcı personel user:<id>, geçici oturum session:<evId> anahtarı kullanır ve claim yetkisi yalnızca personelde vardır', () async {
      final staff = await serviceHarness();
      addTearDown(staff.dispose);
      expect(staff.access.ownerKey, 'user:staff-1');
      expect(staff.access.mode, SetupMode.staff);
      expect(staff.access.canClaim, isTrue);
      expect(staff.access.sessionExpiresAt, isNull);

      final pin = await serviceHarness(role: 'pin');
      addTearDown(pin.dispose);
      expect(pin.access.ownerKey, 'session:$kClaimedHome');
      expect(pin.access.mode, SetupMode.pinSession);
      expect(pin.access.canClaim, isFalse);
      expect(pin.access.sessionHomeId, kClaimedHome);
      expect(pin.access.sessionExpiresAt, isNotNull);

      final superEnv = await serviceHarness(role: 'super');
      addTearDown(superEnv.dispose);
      expect(superEnv.access.ownerKey, 'user:super-1');
      expect(superEnv.access.isSuperUser, isTrue);
      expect(superEnv.access.canClaim, isTrue);
    });

    test('servis yetkisi olmayan kullanıcı ve oturumsuz durum için erişim null döner', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      await env.state.logout();
      expect(ServiceSetupAccess.fromState(env.state), isNull);
    });
  });
}
