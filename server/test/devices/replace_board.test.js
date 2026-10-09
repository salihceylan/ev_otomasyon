'use strict';

// B6 / B11: replaceBoard - PIN sayaci, durum reddi, old_device_uuid, UNIQUE cakismasi, kimlik yenileme, transaction

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp, fakePin } = require('./_world');

const OLD = 'AHBU-S3-0001';
const NEW = 'AHBU-S3-0002';
const NEW_PIN = '135790';

async function setup({ emqx = false } = {}) {
  setTestEnv();
  if (emqx) {
    process.env.EMQX_API_URL = 'http://emqx.test.invalid:18083';
    process.env.EMQX_API_KEY = 'test-key';
    process.env.EMQX_API_SECRET = 'test-secret';
  }
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;

  const owner = h.addUser({ email: 'sahip@example.test' });
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const home = h.addHome({ name: 'Daire 3', owner });
  h.addMember(home, tech, 'service_user');

  const oldInv = h.addInventory({ uuid: OLD, pin: '999999', status: 'CLAIMED' });
  const oldDev = h.addDevice({ home, uuid: OLD, mac: oldInv.mac_address, claimedBy: owner, online: true });
  const eps = h.addEndpoints(home, oldDev, 8);
  eps[0].name = 'Salon Panjuru (ozel ad)';
  eps[0].shutter_duration_sec = 24;
  eps[1].shutter_duration_sec = 24;
  oldInv.claimed_home_id = home.id;
  oldInv.claimed_by_user_id = owner.id;

  const newInv = h.addInventory({ uuid: NEW, pin: NEW_PIN, status: 'IN_STOCK' });

  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: oldDev.id });
  await svc.credentials.issueUserCredential({ homeId: home.id, userId: owner.id });
  svc.timeline.length = 0;
  world.db.log.length = 0;
  world.db.commits = 0;

  const actorFor = (access, extra = {}) => ({
    userId: owner.id, globalRole: 'user', ip: '198.51.100.4', access, label: 'Ali Usta', ...extra,
  });
  const replace = (overrides = {}, actor = actorFor('owner')) =>
    svc.deviceService.replaceBoard({
      actor,
      homeId: home.id,
      oldDeviceUuid: OLD,
      newDeviceUuid: NEW,
      setupPin: NEW_PIN,
      reason: 'Pano yandi',
      ...overrides,
    });
  return { world, ...svc, owner, tech, home, oldInv, oldDev, eps, newInv, actorFor, replace };
}

// ------------------------------------------------------------------------------------------------
test('yetki matrisi: owner/staff/servis oturumu/super basarili; resident/misafir/bilinmeyen rol 403', async () => {
  for (const access of ['owner', 'service_user', 'service_session', 'super_user']) {
    const ctx = await setup();
    const actor = ctx.actorFor(access, access === 'service_session' ? { userId: null, globalRole: 'service_session', sessionId: 'sess-1' } : {});
    const r = await ctx.replace({}, actor);
    assert.strictEqual(r.new_device_uuid, NEW, access);
  }
  for (const access of ['resident', 'guest', 'hacker', null, undefined]) {
    const ctx = await setup();
    await expectHttp(ctx.replace({}, ctx.actorFor(access)), 403, 'FORBIDDEN');
    assert.strictEqual(ctx.world.db.log.length, 0, `${access}: DB'ye dokunulmamali`);
  }
});

test('basarili pano degisimi: kanallar yeni panoya tasinir, eski REVOKED, yeni CLAIMED (PIN yakilir), tek transaction', async () => {
  const ctx = await setup({ emqx: true });
  const r = await ctx.replace();
  const { state, db } = ctx.world;
  const newDev = state.devices.find((d) => d.device_uuid === NEW);

  assert.strictEqual(r.old_device_uuid, OLD);
  assert.strictEqual(r.new_device_uuid, NEW);
  assert.strictEqual(r.migrated_endpoints_count, 8);
  assert.strictEqual(r.home_id, ctx.home.id);

  // yeni cihaz bu evde; sahip eski cihazin sahibi; yerel anahtar sifreli
  assert.strictEqual(newDev.home_id, ctx.home.id);
  assert.strictEqual(newDev.is_claimed, true);
  assert.strictEqual(newDev.claimed_by, ctx.owner.id);
  assert.strictEqual(newDev.is_commissioned, false);
  assert.strictEqual(newDev.setup_pin, null, 'duz metin PIN yazilmaz');
  assert.strictEqual(ctx.secretBox.decrypt(newDev.local_key_enc).length, 16);

  // eski cihaz devreden cikti
  assert.strictEqual(ctx.oldDev.home_id, null);
  assert.strictEqual(ctx.oldDev.is_claimed, false);
  assert.strictEqual(ctx.oldDev.device_status, 'REPLACED_DAMAGED');
  assert.strictEqual(ctx.oldDev.is_online, false);

  // envanter
  assert.strictEqual(ctx.newInv.status, 'CLAIMED');
  assert.strictEqual(ctx.newInv.pin_hash, 'CLAIMED_BURNED_PIN');
  assert.strictEqual(ctx.newInv.claimed_home_id, ctx.home.id);
  assert.strictEqual(ctx.newInv.claimed_by_user_id, ctx.owner.id);
  assert.strictEqual(ctx.oldInv.status, 'REVOKED');
  assert.strictEqual(ctx.oldInv.claimed_home_id, null);

  // kanallar yeni cihaza tasindi, isimler korunur
  const moved = state.endpoints.filter((e) => e.home_id === ctx.home.id);
  assert.strictEqual(moved.length, 8);
  assert.ok(moved.every((e) => e.device_id === newDev.id));
  assert.strictEqual(moved.find((e) => e.channel_index === 1).name, 'Salon Panjuru (ozel ad)');
  assert.deepStrictEqual(r.shutter_runtimes, [{ shutter: 1, sec: 24 }, { shutter: 2, sec: 20 }]);
  assert.strictEqual(r.runtime_sync, 'pending_device_online');

  // snapshot + gunluk (kim, IP) + denetim
  assert.strictEqual(newDev.config_snapshot.length > 10, true);
  const log = state.device_replacement_logs[0];
  assert.strictEqual(log.replaced_by_user_id, ctx.owner.id);
  assert.strictEqual(log.replaced_by_label, 'Ali Usta');
  assert.strictEqual(log.ip_address, '198.51.100.4');
  assert.strictEqual(log.endpoints_migrated_count, 8);
  assert.strictEqual(log.reason, 'Pano yandi');
  assert.ok(state.device_audit_logs.some((a) => a.event === 'board_replaced' && a.ip_address === '198.51.100.4'));

  // MQTT: eski cihaz kimligi YENILENDI, tek seferlik yeni parola, eski baglanti atildi
  const dev = state.mqtt_credentials.filter((c) => c.kind === 'device');
  assert.strictEqual(dev.length, 1);
  assert.strictEqual(dev[0].device_id, newDev.id);
  assert.strictEqual(r.device_credential.username, `d_${ctx.home.mqtt_username}`);
  assert.strictEqual(r.device_credential.password.length, 24);
  assert.ok(ctx.timeline.includes(`kick:d_${ctx.home.mqtt_username}`));
  // uygulama kimlikleri korunur (aile ayni)
  assert.strictEqual(state.mqtt_credentials.filter((c) => c.kind === 'app').length, 1);

  // tek transaction, havuza dusen sorgu yok, duz metin PIN hicbir yerde yok
  assert.strictEqual(db.commits, 1);
  assert.strictEqual(db.rollbacks, 0);
  assert.deepStrictEqual(db.nonTxQueries(), []);
  assert.ok(!JSON.stringify(state).includes(NEW_PIN));
  assert.ok(!JSON.stringify(state).includes(r.device_credential.password));
});

test('S2 (plan §5d-3): panjur suresi uzlastirma ISARETI yeni cihazin config_snapshot\'inda: runtime_sync=pending + home_id + replaced_at; gunluk kaydi isaret TASIMAZ', async () => {
  const ctx = await setup();
  const r = await ctx.replace();
  const { state } = ctx.world;
  const newDev = state.devices.find((d) => d.device_uuid === NEW);

  const marker = JSON.parse(newDev.config_snapshot);
  assert.strictEqual(marker.runtime_sync, 'pending', 'kopru uzlastiricisi cihaz cevrimici olunca set_runtime uygular');
  assert.strictEqual(marker.home_id, ctx.home.id, 'isaret bu eve baglidir (cihaz baska eve tasinirsa gecersiz)');
  assert.ok(Number.isFinite(Date.parse(marker.replaced_at)), 'replaced_at ISO: isaretin kimligi (yeni degisim isareti yeniden kurar)');
  assert.strictEqual(marker.old_device_uuid, OLD);
  assert.strictEqual(marker.endpoints.length, 8, 'anlik goruntu korunur');

  // yanit sozlesmesi ayni: panjur sureleri + bekliyor
  assert.deepStrictEqual(r.shutter_runtimes, [{ shutter: 1, sec: 24 }, { shutter: 2, sec: 20 }]);
  assert.strictEqual(r.runtime_sync, 'pending_device_online');

  // gunluk tablosundaki anlik goruntu SAF kalir (kalici gecmis; "bekliyor" durumu tasimaz)
  const rawLogSnap = state.device_replacement_logs[0].config_snapshot;
  const logSnap = typeof rawLogSnap === 'string' ? JSON.parse(rawLogSnap) : rawLogSnap;
  assert.strictEqual(logSnap.runtime_sync, undefined);
  assert.strictEqual(logSnap.home_id, undefined);
  assert.strictEqual(logSnap.replaced_at, marker.replaced_at, 'ayni degisim');
});

test('S2: panjursuz kurulumda (uygulanacak sure yok) isaret YAZILMAZ; sureler yanitta bos', async () => {
  const ctx = await setup();
  for (const e of ctx.eps) { e.type = 'light'; e.shutter_pair_index = null; e.shutter_duration_sec = null; }
  const r = await ctx.replace();
  const newDev = ctx.world.state.devices.find((d) => d.device_uuid === NEW);
  const marker = JSON.parse(newDev.config_snapshot);
  assert.strictEqual(marker.runtime_sync, undefined);
  assert.strictEqual(marker.home_id, undefined);
  assert.deepStrictEqual(r.shutter_runtimes, []);
});

test('olmayan mqttBridge.publish / sync_full_config artik yok; komut yayini yapilmaz (yeni pano henuz cevrimdisi)', async () => {
  const ctx = await setup();
  await ctx.replace();
  assert.deepStrictEqual(ctx.bridge.commands, []);
  assert.deepStrictEqual(ctx.bridge.topics, []);
  const src = require('fs').readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/sync_full_config.*publish|mqttBridge\.publish\(/.test(src));
  assert.ok(!/ahbu\/\$\{/.test(src), 'eski konu bicimi (ahbu/.../config/set) olmamali');
});

// ------------------------------------------------------------------------------------------------
test('yanlis PIN: claim ile AYNI atomik sayac; 5 hatada 423 kilit; kilitliyken dogru PIN reddedilir', async () => {
  const ctx = await setup();
  const e = await expectHttp(ctx.replace({ setupPin: '000000' }), 403, 'FORBIDDEN', { remaining_attempts: 4 });
  assert.match(e.message, /Kalan deneme hakkı: 4/);
  assert.strictEqual(ctx.newInv.failed_attempts, 1, 'sayac commit edilmeli (rollback ile kaybolmamali)');
  assert.strictEqual(ctx.world.db.rollbacks, 0);
  assert.ok(ctx.world.db.find('UPDATE device_inventory SET failed_attempts')[0].sql.includes('COALESCE(failed_attempts, 0) + 1'));

  for (let i = 2; i <= 4; i++) await expectHttp(ctx.replace({ setupPin: '000000' }), 403, 'FORBIDDEN');
  const locked = await expectHttp(ctx.replace({ setupPin: '000000' }), 423, 'PIN_LOCKED');
  assert.ok(locked.extra.retry_after > 800);
  await expectHttp(ctx.replace({ setupPin: NEW_PIN }), 423, 'PIN_LOCKED');
  assert.strictEqual(ctx.newInv.failed_attempts, 5);
  assert.strictEqual(ctx.newInv.status, 'IN_STOCK');

  ctx.world.clock.advance(15 * 60 * 1000 + 1000);
  const ok = await ctx.replace();
  assert.strictEqual(ok.new_device_uuid, NEW);
  assert.strictEqual(ctx.newInv.failed_attempts, 0);
});

test('PIN sayaci eszamanli denemelerde de atomik (8 eszamanli yanlis -> tam 5)', async () => {
  const ctx = await setup();
  const results = await Promise.allSettled(Array.from({ length: 8 }, () => ctx.replace({ setupPin: '000000' })));
  assert.ok(results.every((r) => r.status === 'rejected'));
  assert.strictEqual(ctx.newInv.failed_attempts, 5);
});

test('yeni pano durumu: SUSPENDED/REVOKED 403, CLAIMED 409, envanterde yok 404 (sayaca dokunmadan)', async () => {
  for (const [status, httpStatus] of [['SUSPENDED', 403], ['REVOKED', 403], ['CLAIMED', 409]]) {
    const ctx = await setup();
    ctx.newInv.status = status;
    await expectHttp(ctx.replace({ setupPin: '000000' }), httpStatus, null);
    assert.strictEqual(ctx.newInv.failed_attempts, 0, status);
    assert.strictEqual(ctx.oldDev.home_id, ctx.home.id, 'degisim yapilmamali');
  }
  const ctx = await setup();
  await expectHttp(ctx.replace({ newDeviceUuid: 'AHBU-YOK-9' }), 404, 'NOT_FOUND');
});

// ------------------------------------------------------------------------------------------------
test('old_device_uuid: cok cihazli evde ZORUNLU (sessiz "ilk pano" yok); tek cihazda gerekmez; olmayan 404', async () => {
  // tek cihaz: old_device_uuid yoksa o cihaz
  let ctx = await setup();
  const r = await ctx.replace({ oldDeviceUuid: undefined });
  assert.strictEqual(r.old_device_uuid, OLD);

  // iki cihaz: belirsiz -> 400
  ctx = await setup();
  const second = ctx.world.helpers.addDevice({ home: ctx.home, uuid: 'AHBU-S3-0003', mac: 'E8:F6:0A:00:00:33', claimedBy: ctx.owner });
  await expectHttp(ctx.replace({ oldDeviceUuid: undefined }), 400, 'VALIDATION');
  assert.strictEqual(ctx.newInv.status, 'IN_STOCK');
  // belirtince hedef cihaz degisir, digeri DOKUNULMAZ
  const ok = await ctx.replace({ oldDeviceUuid: 'AHBU-S3-0003' });
  assert.strictEqual(ok.old_device_uuid, 'AHBU-S3-0003');
  assert.strictEqual(second.home_id, null);
  assert.strictEqual(ctx.oldDev.home_id, ctx.home.id, 'belirtilmeyen cihaz yerinde kalmali');

  // dairede cihaz yok
  ctx = await setup();
  ctx.oldDev.home_id = null;
  await expectHttp(ctx.replace({ oldDeviceUuid: undefined }), 404, 'NOT_FOUND');

  // baska evin cihazi old_device_uuid olarak verilemez
  ctx = await setup();
  const otherHome = ctx.world.helpers.addHome({ name: 'Baska ev' });
  ctx.world.helpers.addDevice({ home: otherHome, uuid: 'AHBU-S3-0004', mac: 'E8:F6:0A:00:00:44' });
  await expectHttp(ctx.replace({ oldDeviceUuid: 'AHBU-S3-0004' }), 404, 'NOT_FOUND');
});

test('eski cihaz sorgusunda LIMIT 1 yedegi ve sessiz "ilk ev" fallback\'i YOK', async () => {
  const ctx = await setup();
  await ctx.replace({ oldDeviceUuid: undefined });
  for (const sql of ctx.world.db.sqls()) {
    assert.ok(!/FROM devices WHERE home_id = \$1 LIMIT 1/.test(sql), sql);
    assert.ok(!/FROM home_users WHERE user_id = \$1 ORDER BY created_at ASC LIMIT 1/.test(sql), sql);
  }
  const src = require('fs').readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/UUID_REGEX\.test\(String\(homeId\)\)/.test(src));
});

test('home_id dogrulamasi: UUID degilse 400, bilinmeyen ev 404 (baska eve dusmez)', async () => {
  const ctx = await setup();
  await expectHttp(ctx.replace({ homeId: 'bozuk' }), 400, 'VALIDATION');
  await expectHttp(ctx.replace({ homeId: undefined }), 400, 'VALIDATION');
  await expectHttp(ctx.replace({ homeId: '0' }), 400, 'VALIDATION');
  await expectHttp(ctx.replace({ homeId: '00000000-0000-4000-8000-000000000000' }), 404, 'NOT_FOUND');
  assert.strictEqual(ctx.oldDev.home_id, ctx.home.id);
});

test('girdi dogrulama: gecersiz uuid / PIN / eski=yeni (DB\'ye dokunmadan 400)', async () => {
  const ctx = await setup();
  for (const o of [
    { newDeviceUuid: 'xyz' }, { newDeviceUuid: undefined }, { oldDeviceUuid: 'bozuk' }, { oldDeviceUuid: NEW },
    { setupPin: '12345' }, { setupPin: 'abcdef' }, { setupPin: undefined }, { reason: 'x'.repeat(501) },
  ]) {
    await expectHttp(ctx.replace(o), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.world.db.log.length, 0);
});

// ------------------------------------------------------------------------------------------------
test('UNIQUE(device_id, channel_index) cakismasi cozulur: yeni cihazin eski/yetim kanal satirlari once silinir', async () => {
  const ctx = await setup();
  // yeni cihazin bir onceki (yarim kalmis) denemeden kalan kanal satirlari var
  const staleHome = ctx.world.helpers.addHome({ name: 'Eski deneme' });
  const staleDev = ctx.world.helpers.addDevice({ home: null, uuid: NEW, mac: ctx.newInv.mac_address });
  ctx.world.helpers.addEndpoints(staleHome, staleDev, 8);

  const r = await ctx.replace();
  assert.strictEqual(r.migrated_endpoints_count, 8);
  const rows = ctx.world.state.endpoints;
  assert.strictEqual(rows.filter((e) => e.device_id === staleDev.id).length, 8);
  assert.ok(rows.every((e) => e.home_id === ctx.home.id), 'yetim satirlar silindi, tasinanlar kaldi');
  const channels = rows.map((e) => e.channel_index).sort((a, b) => a - b);
  assert.deepStrictEqual(channels, [1, 2, 3, 4, 5, 6, 7, 8]);
});

test('yeni cihaz baska daireye bagliysa CALINMAZ (409); MAC cakismasi: yetim arsivlenir / aktif 409', async () => {
  let ctx = await setup();
  const other = ctx.world.helpers.addHome({ name: 'Baska' });
  ctx.world.helpers.addDevice({ home: other, uuid: NEW, mac: ctx.newInv.mac_address });
  await expectHttp(ctx.replace(), 409, 'CONFLICT');
  assert.strictEqual(ctx.oldDev.home_id, ctx.home.id);

  ctx = await setup();
  const orphan = ctx.world.helpers.addDevice({ home: null, uuid: 'AHBU-ESKI-5', mac: ctx.newInv.mac_address });
  await ctx.replace();
  assert.ok(orphan.mac_address.includes('-DUP-'));

  ctx = await setup();
  ctx.world.helpers.addDevice({ home: ctx.world.helpers.addHome({ name: 'X' }), uuid: 'AHBU-ESKI-6', mac: ctx.newInv.mac_address });
  await expectHttp(ctx.replace(), 409, 'CONFLICT');
});

test('hata durumunda her sey geri alinir (kimlik uretimi basarisiz): kanallar eski cihazda, PIN yakilmaz', async () => {
  const ctx = await setup();
  delete process.env.MQTT_PUBLIC_HOST;
  await assert.rejects(ctx.replace(), (e) => e.status === 500);
  assert.strictEqual(ctx.world.db.rollbacks, 1);
  assert.strictEqual(ctx.oldDev.home_id, ctx.home.id);
  assert.strictEqual(ctx.oldInv.status, 'CLAIMED');
  assert.strictEqual(ctx.newInv.status, 'IN_STOCK');
  assert.strictEqual(ctx.newInv.pin_hash, fakePin.hashPin(NEW_PIN));
  assert.ok(ctx.world.state.endpoints.every((e) => e.device_id === ctx.oldDev.id));
  assert.strictEqual(ctx.world.state.devices.filter((d) => d.device_uuid === NEW).length, 0);
  assert.strictEqual(ctx.world.state.device_replacement_logs.length, 0);
  assert.deepStrictEqual(ctx.timeline, []);
});

test('servis oturumu (PIN) ile degisim: kullanici kimligi yok, teknisyen etiketi ve oturum kimligi gunluge yazilir', async () => {
  const ctx = await setup();
  const actor = ctx.actorFor('service_session', {
    userId: null, globalRole: 'service_session', sessionId: 'a1b2c3d4-0000-4000-8000-000000000001', label: 'Veli Usta',
  });
  await ctx.replace({}, actor);
  const log = ctx.world.state.device_replacement_logs[0];
  assert.strictEqual(log.replaced_by_user_id, null);
  assert.strictEqual(log.replaced_by_label, 'Veli Usta');
  assert.strictEqual(log.service_session_id, 'a1b2c3d4-0000-4000-8000-000000000001');
  // yeni cihazin sahibi teknisyen DEGIL, evin sahibi
  assert.strictEqual(ctx.world.state.devices.find((d) => d.device_uuid === NEW).claimed_by, ctx.owner.id);
});

test('eski cihazin sahibi yoksa evin owner\'i yeni cihazin sahibi olur', async () => {
  const ctx = await setup();
  ctx.oldDev.claimed_by = null;
  await ctx.replace();
  assert.strictEqual(ctx.world.state.devices.find((d) => d.device_uuid === NEW).claimed_by, ctx.owner.id);
  assert.strictEqual(ctx.newInv.claimed_by_user_id, ctx.owner.id);
});

test('kick basarisizsa uyari doner ama degisim basarilidir', async () => {
  const ctx = await setup({ emqx: true });
  ctx.fetchFn.failAll = true;
  const r = await ctx.replace();
  assert.strictEqual(r.new_device_uuid, NEW);
  assert.ok(r.warnings && r.warnings.some((w) => /bağlantısı atılamadı/.test(w)));
});

test('kick istisna firlatirsa (ag/EMQX) degisim yine tamamlanir: uyari doner', async () => {
  const ctx = await setup();
  ctx.credentials.kickUsernames = async () => {
    throw new Error('beklenmeyen kick hatasi');
  };
  const r = await ctx.replace();
  assert.strictEqual(r.new_device_uuid, NEW);
  assert.ok(r.warnings.some((w) => /Eski pano bağlantısı atılamadı/.test(w)), JSON.stringify(r.warnings));
  assert.strictEqual(ctx.newInv.status, 'CLAIMED', 'islem commit edildi');
});

// ---- kullanim-4 / guvenlik-1 / atolye-8: pano degisiminde kurallar, acik alarmlar, daire baglantisi ----
test('kullanim-4: zamanli kurallar ayni tx te yeni cihaza tasinir; baska evin kuralina dokunulmaz; denetimde rules_migrated', async () => {
  const ctx = await setup();
  const { state } = ctx.world;
  const r1 = { id: 'r-1', home_id: ctx.home.id, device_id: ctx.oldDev.id, updated_at: null };
  const r2 = { id: 'r-2', home_id: ctx.home.id, device_id: null, updated_at: null }; // ev geneli kural
  const r3 = { id: 'r-3', home_id: 'baska-ev', device_id: ctx.oldDev.id, updated_at: null };
  state.scheduled_rules.push(r1, r2, r3);
  await ctx.replace();
  const newDev = state.devices.find((d) => d.device_uuid === NEW);
  assert.strictEqual(r1.device_id, newDev.id, 'kural yeni panoyu gosterir');
  assert.ok(r1.updated_at);
  assert.strictEqual(r2.device_id, null, 'cihazsiz kural aynen');
  assert.strictEqual(r3.device_id, ctx.oldDev.id, 'baska ev etkilenmez');
  const audit = state.device_audit_logs.find((a) => a.event === 'board_replaced');
  assert.strictEqual(audit.details.rules_migrated, 1);
  const migrateSql = ctx.world.db.find('UPDATE scheduled_rules SET device_id = $1');
  assert.strictEqual(migrateSql.length, 1);
  assert.ok(migrateSql[0].tx !== null, 'ayni transaction');
});

// tarama-sunucu-cihaz-site-1 (sozlesme C4): guvenlik yapilandirmasi yeni panoya AKTARILMAZ; yanit bunu acikca soyler.
const SAFETY_RESTORE_WARNING =
  'Eski panonun güvenlik ayarları (sensörler, vanalar, bölgeler) yeni panoya aktarılmadı. Servis bu ayarları yeniden yazana kadar su/gaz koruması ÇALIŞMAZ. Yetkili servisi çağırın.';
const REPLACE_MESSAGE = 'Pano değişimi tamamlandı. Kanal adları, kurallar ve panjur süreleri yeni panoya taşındı.';

test('C4: eski panonun guvenlik yapilandirmasinda sensor/eylemci varsa safety_restore required + uyari; denetim kaydinda', async () => {
  for (const body of [
    { sensors: [{ id: 'd3', kind: 'water', zone: 1 }], actuators: [] },
    { sensors: [], actuators: [{ id: 'a1', relay: 5, kind: 'valve' }] },
  ]) {
    const ctx = await setup();
    ctx.world.state.device_configs = [{ device_id: ctx.oldDev.id, module: 'safety', rev: 3, crc: '0000000a', body }];
    // Karar 18: guvenlik yapilandirmali evde degisimi yetkili servis yapar (servis oturumu)
    const r = await ctx.replace({}, ctx.actorFor('service_session', { userId: null, globalRole: 'service_session', isServiceSession: true }));
    assert.strictEqual(r.safety_restore, 'required', JSON.stringify(body));
    assert.ok(Array.isArray(r.warnings) && r.warnings.includes(SAFETY_RESTORE_WARNING), JSON.stringify(r.warnings));
    assert.strictEqual(r.message, REPLACE_MESSAGE);
    const audit = ctx.world.state.device_audit_logs.find((a) => a.event === 'board_replaced');
    assert.strictEqual(audit.details.safety_restore, 'required');
  }
});

test('karar 18: guvenlik yapilandirmali (sensor / vana) evde ev sahibinin pano degisimi 403 REPLACE_REQUIRES_SERVICE; hicbir sey degismez', async () => {
  for (const body of [
    { sensors: [{ id: 'd3', kind: 'water', zone: 1 }], actuators: [] },
    { sensors: [], actuators: [{ id: 'a1', relay: 5, kind: 'valve' }] },
  ]) {
    const ctx = await setup();
    ctx.world.state.device_configs = [{ device_id: ctx.oldDev.id, module: 'safety', rev: 3, crc: '0000000a', body }];
    const before = JSON.stringify(ctx.world.state.device_inventory);
    await assert.rejects(ctx.replace(), (e) => {
      assert.strictEqual(e.status || e.statusCode, 403);
      assert.strictEqual(e.code, 'REPLACE_REQUIRES_SERVICE');
      assert.strictEqual(e.message, 'Güvenlik ayarları olan evde pano değişimini yetkili servis yapmalıdır.');
      return true;
    });
    assert.strictEqual(JSON.stringify(ctx.world.state.device_inventory), before, 'envanter (PIN sayaci dahil) degismez');
  }
  // Bos guvenlik govdesi (yalniz bolge adi): ev sahibi degistirebilir (safety_restore not_required ile ayni kural)
  const plain = await setup();
  plain.world.state.device_configs = [{ device_id: plain.oldDev.id, module: 'safety', rev: 1, crc: '00000001', body: { sensors: [], actuators: [], zones: [{ id: 1, name: 'Ev' }] } }];
  assert.ok(await plain.replace());
});

test('C4: tasinan uc noktada actuator_type dolu ise required; guvenlik yapilandirmasiz evde not_required ve uyari yok', async () => {
  const withActuator = await setup();
  withActuator.eps[5].actuator_type = 'valve';
  assert.strictEqual((await withActuator.replace()).safety_restore, 'required');

  const plain = await setup();
  // bos guvenlik govdesi ve baska modul sayilmaz
  plain.world.state.device_configs = [
    { device_id: plain.oldDev.id, module: 'safety', rev: 1, crc: '00000001', body: { sensors: [], actuators: [], zones: [{ id: 1, name: 'Ev' }] } },
    { device_id: plain.oldDev.id, module: 'other', rev: 1, crc: '00000001', body: { sensors: [{ id: 'd1' }] } },
  ];
  const r = await plain.replace();
  assert.strictEqual(r.safety_restore, 'not_required');
  assert.ok(!(r.warnings || []).includes(SAFETY_RESTORE_WARNING));
  assert.strictEqual(r.message, REPLACE_MESSAGE);
  assert.strictEqual(plain.world.state.device_audit_logs.find((a) => a.event === 'board_replaced').details.safety_restore, 'not_required');
});

test('guvenlik-1: eski panonun ACIK alarm satirlari lost/detached olur (gaz bastirmasi kalkar); kapali satirlara dokunulmaz', async () => {
  const ctx = await setup();
  const { state } = ctx.world;
  const open = { id: 1, device_id: ctx.oldDev.id, home_id: ctx.home.id, kind: 'gas', status: 'latched', ack_requested_at: new Date(), ack_requested_by: 'x' };
  const silenced = { id: 2, device_id: ctx.oldDev.id, home_id: ctx.home.id, kind: 'water', status: 'silenced' };
  const cleared = { id: 3, device_id: ctx.oldDev.id, home_id: ctx.home.id, kind: 'gas', status: 'cleared', cleared_by: 'device' };
  const otherDev = { id: 4, device_id: 'baska-cihaz', home_id: ctx.home.id, kind: 'gas', status: 'latched' };
  state.alarms.push(open, silenced, cleared, otherDev);
  await ctx.replace();
  for (const a of [open, silenced]) {
    assert.strictEqual(a.status, 'lost', `alarm ${a.id}`);
    assert.strictEqual(a.cleared_by, 'detached');
    assert.ok(a.cleared_at);
    assert.strictEqual(a.ack_requested_at, null);
    assert.strictEqual(a.ack_requested_by, null);
  }
  assert.strictEqual(cleared.status, 'cleared');
  assert.strictEqual(cleared.cleared_by, 'device');
  assert.strictEqual(otherDev.status, 'latched', 'baska cihazin alarmi korunur');
});

test('atolye-8 (inceleme): yeni kart BASKA bir daireye bagliysa super olmayan 409 DEVICE_LINKED_TO_FLAT, hicbir sey degismez', async () => {
  for (const access of ['owner', 'service_user', 'service_session']) {
    const ctx = await setup();
    const { state } = ctx.world;
    const flatA = { id: 'flat-a', device_uuid: OLD, status: 'installed', template_id: null };
    const flatB = { id: 'flat-b', device_uuid: NEW, status: 'written', template_id: 'tpl-b' };
    state.site_flats.push(flatA, flatB);
    const actor = ctx.actorFor(access, access === 'service_session' ? { userId: null, globalRole: 'service_session', sessionId: 'sess-1' } : {});
    const e = await expectHttp(ctx.replace({}, actor), 409, 'DEVICE_LINKED_TO_FLAT');
    assert.strictEqual(e.message, 'Kart bir daireye bağlı; önce daireden ayırın.', access);
    assert.strictEqual(flatA.device_uuid, OLD, `${access}: degistirilen daire aynen`);
    assert.strictEqual(flatB.device_uuid, NEW, `${access}: diger dairenin karti aynen`);
    assert.strictEqual(flatB.status, 'written');
    assert.strictEqual(ctx.newInv.status, 'IN_STOCK', `${access}: yeni kart sahiplenilmedi`);
    assert.strictEqual(ctx.oldDev.home_id, ctx.home.id, `${access}: eski pano evde kalir`);
    assert.ok(!state.devices.some((d) => d.device_uuid === NEW), `${access}: yeni cihaz kaydi olusmadi`);
    assert.ok(!ctx.world.db.sqls().some((s) => s.startsWith('UPDATE site_flats')), `${access}: daire yazimi yok`);
  }
});

test('atolye-8 (inceleme): super_user gecersiz kilarsa diger daire KARTSIZ ve planned olur (kartsiz written/installed/handed_over kalmaz) + uyari', async () => {
  for (const otherStatus of ['written', 'installed', 'handed_over', 'planned']) {
    const ctx = await setup();
    const { state } = ctx.world;
    const flatA = { id: 'flat-a', device_uuid: OLD, status: 'installed', template_id: null };
    const flatB = { id: 'flat-b', device_uuid: NEW, status: otherStatus, template_id: 'tpl-b' };
    state.site_flats.push(flatA, flatB);
    const r = await ctx.replace({}, ctx.actorFor('super_user', { globalRole: 'super_user' }));
    assert.strictEqual(flatA.device_uuid, NEW, 'dairenin karti yeni pano');
    assert.strictEqual(flatA.status, 'installed', 'installed karta bagli kalir');
    assert.strictEqual(flatB.device_uuid, null, `${otherStatus}: diger dairenin bagi kalkti`);
    assert.strictEqual(flatB.status, 'planned', `${otherStatus}: diger daire planned`);
    assert.ok((r.warnings || []).some((w) => w.includes('başka bir daireye bağlıydı')), JSON.stringify(r.warnings));
  }
});

test('atolye-7 (inceleme): degistirilen dairede written, yeni kartin BU dairenin sablonuyla basarili yazimi yoksa planned; varsa korunur', async () => {
  // yazim yok -> planned
  let ctx = await setup();
  const flatA = { id: 'flat-a', device_uuid: OLD, status: 'written', template_id: 'tpl-a' };
  ctx.world.state.site_flats.push(flatA);
  await ctx.replace();
  assert.strictEqual(flatA.device_uuid, NEW);
  assert.strictEqual(flatA.status, 'planned');

  // baska sablonla basarili / ayni sablonla hatali yazim -> yine planned
  ctx = await setup();
  const flatB = { id: 'flat-b', device_uuid: OLD, status: 'written', template_id: 'tpl-a' };
  ctx.world.state.site_flats.push(flatB);
  ctx.world.state.template_writes.push(
    { id: 1, device_uuid: NEW, template_id: 'tpl-x', version: 1, result: 'ok', created_at: new Date() },
    { id: 2, device_uuid: NEW, template_id: 'tpl-a', version: 1, result: 'error', created_at: new Date() }
  );
  await ctx.replace();
  assert.strictEqual(flatB.status, 'planned');

  // sablonsuz written daire -> planned
  ctx = await setup();
  const flatN = { id: 'flat-n', device_uuid: OLD, status: 'written', template_id: null };
  ctx.world.state.site_flats.push(flatN);
  await ctx.replace();
  assert.strictEqual(flatN.status, 'planned');

  // yeni karta bu dairenin sablonu basariyla yazilmis -> written korunur
  ctx = await setup();
  const flatC = { id: 'flat-c', device_uuid: OLD, status: 'written', template_id: 'tpl-a' };
  ctx.world.state.site_flats.push(flatC);
  ctx.world.state.template_writes.push({ id: 3, device_uuid: NEW, template_id: 'tpl-a', version: 2, result: 'ok', created_at: new Date() });
  await ctx.replace();
  assert.strictEqual(flatC.device_uuid, NEW);
  assert.strictEqual(flatC.status, 'written');

  // handed_over karta bagli kalir; bag kaldirilmadiysa uyari yok
  ctx = await setup();
  const flatD = { id: 'flat-d', device_uuid: OLD, status: 'handed_over', template_id: 'tpl-a' };
  ctx.world.state.site_flats.push(flatD);
  const r = await ctx.replace();
  assert.strictEqual(flatD.device_uuid, NEW);
  assert.strictEqual(flatD.status, 'handed_over');
  assert.ok(!(r.warnings || []).some((w) => w.includes('başka bir daireye')), 'uyari yalniz bag kaldirildiysa');

  // migration 035 yoksa daire islemi atlanir
  ctx = await setup();
  ctx.world.state.schema035 = false;
  await ctx.replace();
  assert.ok(!ctx.world.db.sqls().some((s) => s.startsWith('UPDATE site_flats') || s.includes('FROM site_flats')));
});
