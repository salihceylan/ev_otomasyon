'use strict';

// B5 / B11: emergencyReset - yetki, gerekce+teyit, rastgele PIN, cleanup, MQTT iptali, retained temizligi

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');

const { createWorld, createServices, setTestEnv, expectHttp, fakePin } = require('./_world');

const UUID = 'AHBU-S3-0001';
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';

/**
 * Kurulu bir ev: sahip + sakin + servis personeli uyeligi, cevrimici cihaz, kanallar,
 * yerel anahtar, uygulama/cihaz MQTT kimlikleri.
 */
async function setup({ deviceOnline = true, emqx = false } = {}) {
  setTestEnv();
  if (emqx) enableEmqx();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;

  const root = h.addUser({ email: 'root@example.test', role: 'super_user' });
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const owner = h.addUser({ email: 'sahip@example.test' });
  const resident = h.addUser({ email: 'sakin@example.test' });
  const newbie = h.addUser({ email: 'yeni.sahip@example.test', phone: '+905557778899', full_name: 'Yeni Sahip' });

  const inv = h.addInventory({ uuid: UUID, pin: '246810', status: 'CLAIMED' });
  const home = h.addHome({ name: 'Daire 7', owner });
  h.addMember(home, resident, 'resident');
  h.addMember(home, tech, 'service_user', { installer_expires_at: new Date(world.clock.t + 3600000) });
  const oldKeyEnc = svc.secretBox.encrypt('EskiAnahtar123456');
  const dev = h.addDevice({ home, uuid: UUID, mac: inv.mac_address, claimedBy: owner, online: deviceOnline, local_key_enc: oldKeyEnc });
  h.addEndpoints(home, dev, 8);
  inv.claimed_home_id = home.id;
  inv.claimed_by_user_id = owner.id;
  inv.pin_hash = 'CLAIMED_BURNED_PIN';
  inv.local_key_enc = oldKeyEnc;
  home.child_lock_enabled = true;
  home.peace_notification_enabled = false;

  // MQTT kimlikleri: sahip + sakin uygulama kimlikleri, cihaz kimligi
  await svc.credentials.issueUserCredential({ homeId: home.id, userId: owner.id });
  await svc.credentials.issueUserCredential({ homeId: home.id, userId: resident.id });
  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: dev.id });
  svc.timeline.length = 0;
  svc.fetchFn.calls.length = 0;
  world.db.log.length = 0;
  world.db.commits = 0;

  const act = (u, extra = {}) => ({ userId: u.id, globalRole: u.role, ip: '203.0.113.9', ...extra });
  const reset = (who, overrides = {}) =>
    svc.deviceService.emergencyReset({
      actor: act(who),
      deviceUuid: UUID,
      confirmUid: UUID,
      reason: REASON,
      ...overrides,
    });
  return { world, ...svc, root, tech, owner, resident, newbie, inv, home, dev, oldKeyEnc, act, reset };
}

function enableEmqx() {
  process.env.EMQX_API_URL = 'http://emqx.test.invalid:18083';
  process.env.EMQX_API_KEY = 'test-key';
  process.env.EMQX_API_SECRET = 'test-secret';
}

// ------------------------------------------------------------------------------------------------
// Yetki
// ------------------------------------------------------------------------------------------------

test('yetki: owner/resident/normal kullanici/servis oturumu/aktorsuz reddedilir (DB\'ye dokunmadan)', async () => {
  const ctx = await setup();
  for (const who of [ctx.owner, ctx.resident]) {
    await expectHttp(ctx.reset(who), 403, 'FORBIDDEN');
  }
  await expectHttp(
    ctx.deviceService.emergencyReset({ actor: { userId: null, globalRole: 'service_session' }, deviceUuid: UUID, confirmUid: UUID, reason: REASON }),
    403, 'FORBIDDEN'
  );
  await expectHttp(ctx.deviceService.emergencyReset({ actor: null, deviceUuid: UUID, confirmUid: UUID, reason: REASON }), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.world.db.log.length, 0);
  assert.strictEqual(ctx.inv.status, 'CLAIMED');
});

test('staff YALNIZCA uyesi oldugu evde sifirlayabilir; uyeligi olmayan / suresi dolmus / owner-uyeligi olan reddedilir', async () => {
  // uyelik yok
  let ctx = await setup();
  const stranger = ctx.world.helpers.addUser({ email: 'baska.servis@example.test', role: 'service_user' });
  await expectHttp(ctx.reset(stranger), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.inv.status, 'CLAIMED');

  // suresi dolmus servis uyeligi
  ctx = await setup();
  ctx.world.state.home_users.find((m) => m.user_id === ctx.tech.id).installer_expires_at = new Date(ctx.world.clock.t - 1000);
  await expectHttp(ctx.reset(ctx.tech), 403, 'FORBIDDEN');

  // staff global rolu ama o evde owner (servis degil): servis yetkisiyle islem yapamaz
  ctx = await setup();
  ctx.world.state.home_users.find((m) => m.user_id === ctx.tech.id).role = 'owner';
  await expectHttp(ctx.reset(ctx.tech), 403, 'FORBIDDEN');

  // uyeligi olan staff basarili
  ctx = await setup();
  const r = await ctx.reset(ctx.tech);
  assert.strictEqual(r.action, 'UNCLAIMED');
});

test('super_user uyeliksiz her evde sifirlayabilir', async () => {
  const ctx = await setup();
  const r = await ctx.reset(ctx.root);
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(r.affected_users_count, 3);
});

test('staff, bir daireye bagli olmayan (yetim/stoktaki) cihazi SIFIRLAYAMAZ; super sifirlayabilir', async () => {
  const ctx = await setup();
  ctx.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '111222', status: 'IN_STOCK' });
  const payload = { deviceUuid: 'AHBU-S3-0002', confirmUid: 'AHBU-S3-0002' };
  await expectHttp(ctx.reset(ctx.tech, payload), 403, 'FORBIDDEN');
  const r = await ctx.reset(ctx.root, payload);
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(r.home_id, null);
  assert.match(r.setup_pin, /^\d{6}$/);
  // ev yok: MQTT yan etkisi yok, yerel anahtar yaniti ile elle uygulanmak uzere doner
  assert.strictEqual(ctx.bridge.cleared.length, 0);
  assert.strictEqual(r.local_key_publish, 'skipped');
  assert.strictEqual(r.local_key.length, 16);
});

test('envanterde kaydi olmayan cihaz 404 (yalniz eski devices kaydi sifirlanamaz)', async () => {
  const ctx = await setup();
  ctx.world.helpers.addDevice({ uuid: 'AHBU-LEGACY-1', mac: 'AA:BB:CC:DD:EE:77', home: ctx.home });
  await expectHttp(ctx.reset(ctx.root, { deviceUuid: 'AHBU-LEGACY-1', confirmUid: 'AHBU-LEGACY-1' }), 404, 'NOT_FOUND');
});

// ------------------------------------------------------------------------------------------------
// Girdi dogrulama: gerekce >= 15 + UUID'yi yazarak teyit
// ------------------------------------------------------------------------------------------------

test('gerekce >= 15 karakter ve confirm_uid cihaz UUID\'sine esit olmali (DB\'ye dokunmadan 400)', async () => {
  const ctx = await setup();
  for (const reason of ['kisa', '              ', 'x'.repeat(14), '  ' + 'x'.repeat(10) + '  ', undefined, 42, 'x'.repeat(501)]) {
    await expectHttp(ctx.reset(ctx.tech, { reason }), 400, 'VALIDATION');
  }
  for (const confirmUid of [undefined, '', 'AHBU-S3-0002', 'ahbu', 42]) {
    await expectHttp(ctx.reset(ctx.tech, { confirmUid }), 400, 'VALIDATION');
  }
  await expectHttp(ctx.reset(ctx.tech, { deviceUuid: 'bozuk' }), 400, 'VALIDATION');
  await expectHttp(ctx.reset(ctx.tech, { newOwnerIdentifier: 'gecersiz' }), 400, 'VALIDATION');
  assert.strictEqual(ctx.world.db.log.length, 0);

  // teyit buyuk/kucuk harf duyarsiz (kullanici elle yazar), baslangic/bitis bosluklari kirpilir
  const r = await ctx.reset(ctx.tech, { confirmUid: '  ahbu-s3-0001 ' });
  assert.strictEqual(r.action, 'UNCLAIMED');
});

// ------------------------------------------------------------------------------------------------
// UNCLAIMED (stoga donus)
// ------------------------------------------------------------------------------------------------

test('stoga donus: yeni RASTGELE PIN (yanitta tek sefer), yeni yerel anahtar, uyelikler/kanallar/kimlikler temizlenir', async () => {
  const ctx = await setup({ emqx: true });
  const r = await ctx.reset(ctx.tech);
  const { state, db } = ctx.world;

  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.match(r.setup_pin, /^\d{6}$/);
  assert.notStrictEqual(r.setup_pin, '123456', 'sabit varsayilan PIN YOK');
  assert.strictEqual(r.affected_users_count, 3);
  assert.match(r.message, /yalnızca şimdi/);

  // envanter: stoga donus + yeni PIN OZETI (duz metin yok) + sayaclar sifir
  assert.strictEqual(ctx.inv.status, 'IN_STOCK');
  assert.strictEqual(ctx.inv.pin_hash, fakePin.hashPin(r.setup_pin));
  assert.strictEqual(ctx.inv.claimed_home_id, null);
  assert.strictEqual(ctx.inv.claimed_by_user_id, null);
  assert.strictEqual(ctx.inv.failed_attempts, 0);
  assert.strictEqual(ctx.inv.locked_until, null);

  // cihaz: evden ayrildi, devreye alma sifirlandi, duz metin PIN kolonu kullanilmadi
  assert.strictEqual(ctx.dev.home_id, null);
  assert.strictEqual(ctx.dev.is_claimed, false);
  assert.strictEqual(ctx.dev.claimed_by, null);
  assert.strictEqual(ctx.dev.setup_pin, null);
  assert.strictEqual(ctx.dev.is_commissioned, false);
  assert.ok(!db.sqls().some((s) => /setup_pin\s*=\s*'/.test(s)), 'sabit setup_pin yazimi olmamali');
  assert.ok(!db.log.some((l) => l.sql.includes('UPDATE devices') && (l.params || []).includes('123456')));

  // inceleme: STOGA DONUSTE yeni yerel anahtar (eskisinden FARKLI) HEMEN gecerli: cihaz + envanter; bekleyen / onceki
  // anahtar yok. Eski sahibin bildigi anahtar sonraki musterinin panosunda gecerli KALMAZ (claim envanter anahtarini alir).
  assert.notStrictEqual(ctx.dev.local_key_enc, ctx.oldKeyEnc);
  assert.notStrictEqual(ctx.inv.local_key_enc, ctx.oldKeyEnc, 'envanter anahtari artik eski anahtar degil');
  assert.strictEqual(ctx.inv.local_key_enc, ctx.dev.local_key_enc);
  const newKey = ctx.secretBox.decrypt(ctx.dev.local_key_enc);
  assert.strictEqual(newKey.length, 16);
  assert.notStrictEqual(newKey, 'EskiAnahtar123456');
  assert.ok(!ctx.dev.local_key_pending_enc, 'bekleyen anahtar yok (iletim yolu: ev konusu kalmadi)');
  assert.ok(!ctx.dev.local_key_prev_enc, 'onceki anahtar saklanmaz');
  assert.strictEqual(r.local_key, newKey, 'anahtar yanitta bir kez (pano yenilenirken RESETKEY + FACTORYINIT)');
  assert.strictEqual(r.local_key_publish, 'published');

  // uyelikler silindi; ev kabugu kalir ve ayarlari varsayilana doner
  assert.strictEqual(state.home_users.filter((m) => m.home_id === ctx.home.id).length, 0);
  assert.strictEqual(state.homes.length, 1);
  assert.strictEqual(ctx.home.child_lock_enabled, false);
  assert.strictEqual(ctx.home.peace_notification_enabled, true);

  // kanallar silindi (yeniden sahiplenmede yeniden uretilir)
  assert.strictEqual(state.endpoints.length, 0);

  // MQTT kimlikleri (uygulama + cihaz) DB'den silindi
  assert.strictEqual(state.mqtt_credentials.length, 0);
  assert.strictEqual(state.mqtt_acl.length, 0);

  // ortak cleanup (devir ile ayni fonksiyon) tek transaction'da cagrildi
  assert.strictEqual(ctx.cleanupCalls.length, 1);
  assert.strictEqual(ctx.cleanupCalls[0].homeId, ctx.home.id);
  assert.strictEqual(ctx.cleanupCalls[0].inTx, true);
  assert.deepStrictEqual(ctx.cleanupCalls[0].options, { keepEndpoints: false });

  // denetim: IP + rol + dal + onceki uyeler
  const log = state.emergency_reset_logs[0];
  assert.strictEqual(log.ip_address, '203.0.113.9');
  assert.strictEqual(log.actor_role, 'service_user');
  assert.strictEqual(log.action, 'UNCLAIMED');
  assert.strictEqual(log.reason, REASON);
  assert.strictEqual(log.installer_user_id, ctx.tech.id);
  assert.deepStrictEqual(log.previous_owner_ids.sort(), [ctx.owner.id, ctx.resident.id, ctx.tech.id].sort());
  assert.strictEqual(state.device_audit_logs.find((a) => a.event === 'emergency_reset').ip_address, '203.0.113.9');

  // tek transaction + havuza dusen sorgu yok
  assert.strictEqual(db.commits, 1);
  assert.strictEqual(db.rollbacks, 0);
  assert.deepStrictEqual(db.nonTxQueries(), []);

  // duz metin PIN / yerel anahtar hicbir tabloda yok
  const dump = JSON.stringify(state);
  assert.ok(!dump.includes(r.setup_pin));
  assert.ok(!dump.includes(newKey));
});

test('retained state/status BOS yayinla temizlenir; STOGA DONUSTE yeni (gecerli) anahtar ESKI kimlikle baglanti atilmadan ONCE iletilir; uzlastirici YOK', async () => {
  const ctx = await setup({ deviceOnline: true, emqx: true });
  const rearmed = [];
  ctx.bridge.requestReconcile = (topicId) => rearmed.push(topicId);
  const r = await ctx.reset(ctx.tech);

  assert.deepStrictEqual(ctx.bridge.cleared, [ctx.home.mqtt_username]);
  assert.strictEqual(ctx.bridge.topics.length, 1);
  assert.strictEqual(ctx.bridge.topics[0].topic, `ev/${ctx.home.mqtt_username}/sys`);
  assert.strictEqual(ctx.bridge.topics[0].obj.cmd, 'set_local_key');
  assert.strictEqual(ctx.bridge.topics[0].obj.local_key, r.local_key);
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key, 'iletilen anahtar sunucudaki gecerli anahtar');
  assert.strictEqual(r.local_key_publish, 'published');
  assert.deepStrictEqual(rearmed, [], 'bekleyen anahtar yok: uzlastirici istenmez');

  // sira: sys yayini -> baglanti atma (kick) -> retained temizligi
  const t = ctx.timeline;
  const iSys = t.indexOf('publishSys');
  const iKick = t.findIndex((e) => e.startsWith('kick:'));
  const iClear = t.indexOf('clearRetained');
  assert.ok(iSys >= 0 && iKick > iSys && iClear > iKick, `sira hatali: ${t.join(',')}`);

  // tum eski kullanici adlari atildi: 2 uygulama + 1 cihaz
  const kicked = t.filter((e) => e.startsWith('kick:'));
  assert.strictEqual(kicked.length, 3);
  assert.ok(kicked.includes(`kick:d_${ctx.home.mqtt_username}`));
  assert.ok(kicked.filter((k) => k.startsWith(`kick:a_${ctx.home.mqtt_username}_`)).length === 2);
  assert.strictEqual(r.warnings, undefined);
  assert.strictEqual(r.partial, undefined);
});

test('her sifirlamada FARKLI rastgele PIN uretilir (6 hane, sabit degil)', async () => {
  const pins = new Set();
  for (let i = 0; i < 12; i++) {
    const ctx = await setup();
    const r = await ctx.reset(ctx.root);
    assert.match(r.setup_pin, /^\d{6}$/);
    assert.notStrictEqual(r.setup_pin, '123456');
    pins.add(r.setup_pin);
  }
  assert.ok(pins.size >= 11, `PIN'ler rastgele olmali (benzersiz: ${pins.size}/12)`);
});

test('sifirlanan cihaz yeni PIN ile yeniden sahiplenilebilir; eski (yakilmis) PIN gecmez', async () => {
  const ctx = await setup();
  const r = await ctx.reset(ctx.tech);
  const buyer = ctx.world.helpers.addUser({ email: 'alici@example.test' });
  await expectHttp(
    ctx.deviceService.claimDevice({ actor: ctx.act(buyer), deviceUuid: UUID, setupPin: '246810' }),
    403, 'FORBIDDEN'
  );
  const claimed = await ctx.deviceService.claimDevice({ actor: ctx.act(buyer), deviceUuid: UUID, setupPin: r.setup_pin });
  assert.ok(claimed.home_id);
  assert.notStrictEqual(claimed.home_id, ctx.home.id, 'yeni daire olusur (eski daire kabugu bos kalir)');
  assert.strictEqual(ctx.world.state.endpoints.length, 8);
});

// ------------------------------------------------------------------------------------------------
// REASSIGNED (yeni sahibe devir)
// ------------------------------------------------------------------------------------------------

test('yeni sahibe devir: eski aile cikarilir, yeni sahip owner olur, kanallar yeniden uretilir, cihaz kimligi yenilenir', async () => {
  const ctx = await setup({ emqx: true });
  const oldCredPassHash = ctx.world.state.mqtt_credentials.find((c) => c.kind === 'device').password_hash;

  const r = await ctx.reset(ctx.tech, { newOwnerIdentifier: 'Yeni.Sahip@Example.Test' });
  const { state } = ctx.world;

  assert.strictEqual(r.action, 'REASSIGNED');
  assert.strictEqual(r.new_owner.id, ctx.newbie.id);
  assert.ok(!('setup_pin' in r), 'devirde PIN doner mi? Cihaz CLAIMED kalir, PIN anlamsiz');
  assert.strictEqual(r.home_id, ctx.home.id);

  // uyelik: yeni sahip + servis personeli SURELI (72 saat) servis uyesi (yeni sahip icin kurulumu bitirebilsin)
  const members = state.home_users.filter((m) => m.home_id === ctx.home.id);
  assert.deepStrictEqual(
    members.map((m) => [m.user_id, m.role]).sort(),
    [[ctx.newbie.id, 'owner'], [ctx.tech.id, 'service_user']].sort()
  );
  const staffMember = members.find((m) => m.role === 'service_user');
  const hours = (new Date(staffMember.installer_expires_at) - ctx.world.clock.now()) / 3600000;
  assert.ok(hours > 71 && hours <= 72, `servis uyeligi sureli olmali: ${hours}`);
  assert.ok(!members.some((m) => m.user_id === ctx.owner.id || m.user_id === ctx.resident.id), 'eski aile cikarilmali');

  assert.strictEqual(ctx.inv.status, 'CLAIMED');
  assert.strictEqual(ctx.inv.claimed_by_user_id, ctx.newbie.id);
  assert.strictEqual(ctx.inv.pin_hash, 'CLAIMED_BURNED_PIN');
  assert.strictEqual(ctx.dev.claimed_by, ctx.newbie.id);
  assert.strictEqual(ctx.dev.home_id, ctx.home.id);
  assert.strictEqual(ctx.dev.is_commissioned, false);

  // kanallar temizlenip varsayilanlarla yeniden uretildi (yeni sahip bos ev gormez)
  const eps = state.endpoints.filter((e) => e.home_id === ctx.home.id);
  assert.strictEqual(eps.length, 8);
  assert.ok(eps.every((e) => e.name && e.device_id === ctx.dev.id));

  // MQTT: uygulama kimlikleri silindi; cihaz kimligi YENILENDI (yeni parola, tek seferlik)
  assert.strictEqual(state.mqtt_credentials.filter((c) => c.kind === 'app').length, 0);
  const deviceCreds = state.mqtt_credentials.filter((c) => c.kind === 'device');
  assert.strictEqual(deviceCreds.length, 1);
  assert.notStrictEqual(deviceCreds[0].password_hash, oldCredPassHash);
  assert.strictEqual(r.device_credential.username, `d_${ctx.home.mqtt_username}`);
  assert.strictEqual(r.device_credential.password.length, 24);
  assert.ok(!JSON.stringify(state).includes(r.device_credential.password));

  // ayni kullanici adi (d_{t}) eski baglantiyi atmak icin kick listesindedir
  assert.ok(ctx.timeline.includes(`kick:d_${ctx.home.mqtt_username}`));
  assert.deepStrictEqual(ctx.bridge.cleared, [ctx.home.mqtt_username]);

  const log = state.emergency_reset_logs[0];
  assert.strictEqual(log.action, 'REASSIGNED');
  assert.strictEqual(log.new_owner_identifier, 'yeni.sahip@example.test');
});

test('devir hedefi telefonla: yalniz yer tutucu e-postali (telefon-OTP) hesap; gercek e-postali hesap 400 (uyelik-1)', async () => {
  const ctx = await setup();
  // kayitta telefon dogrulanmaz: telefonla bulunan gercek e-postali hesap baskasinin olabilir
  const e = await expectHttp(ctx.reset(ctx.root, { newOwnerIdentifier: '+90 555 777 88 99' }), 400, 'VALIDATION');
  assert.strictEqual(e.message, 'Bu numara e-postalı bir hesaba kayıtlı; atama için hesabın e-posta adresini girin.');
  const otpUser = ctx.world.helpers.addUser({ email: 'phone_905557770000@ahbu.local', phone: '+905557770000', full_name: 'Sakin' });
  const r = await ctx.reset(ctx.root, { newOwnerIdentifier: '+90 555 777 00 00' });
  assert.strictEqual(r.new_owner.id, otpUser.id);
});

test('servis personeli KENDINI yeni sahip yapamaz (403); bilinmeyen 404; pasif hesap 409; evsiz cihaza sahip atanamaz 409', async () => {
  const ctx = await setup();
  await expectHttp(ctx.reset(ctx.tech, { newOwnerIdentifier: ctx.tech.email }), 403, 'FORBIDDEN');
  await expectHttp(ctx.reset(ctx.tech, { newOwnerIdentifier: 'kayitsiz@example.test' }), 404, 'NOT_FOUND');
  ctx.newbie.is_active = false;
  await expectHttp(ctx.reset(ctx.tech, { newOwnerIdentifier: ctx.newbie.email }), 409, 'CONFLICT');
  // hicbiri kalici degisiklik yapmadi
  assert.strictEqual(ctx.inv.status, 'CLAIMED');
  assert.strictEqual(ctx.world.state.home_users.filter((m) => m.home_id === ctx.home.id).length, 3);

  const c2 = await setup();
  c2.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '111222', status: 'IN_STOCK' });
  await expectHttp(
    c2.reset(c2.root, { deviceUuid: 'AHBU-S3-0002', confirmUid: 'AHBU-S3-0002', newOwnerIdentifier: c2.newbie.email }),
    409, 'CONFLICT'
  );
});

// ------------------------------------------------------------------------------------------------
// Atomiklik / hata yonetimi
// ------------------------------------------------------------------------------------------------

test('transaction ortasinda hata: TUM islem geri alinir ve commit-sonrasi yan etki YAPILMAZ', async () => {
  const ctx = await setup({ emqx: true });
  ctx.deviceService._deps.cleanupHome = async () => {
    throw new Error('cleanup patladi');
  };
  await assert.rejects(ctx.reset(ctx.tech), /cleanup patladi/);

  const { state } = ctx.world;
  assert.strictEqual(ctx.world.db.rollbacks, 1);
  assert.strictEqual(state.home_users.filter((m) => m.home_id === ctx.home.id).length, 3, 'uyelikler geri gelmeli');
  assert.strictEqual(ctx.inv.status, 'CLAIMED');
  assert.strictEqual(ctx.dev.home_id, ctx.home.id);
  assert.strictEqual(ctx.dev.local_key_enc, ctx.oldKeyEnc);
  assert.strictEqual(state.mqtt_credentials.length, 3, 'MQTT kimlikleri geri gelmeli');
  assert.strictEqual(state.emergency_reset_logs.length, 0);
  assert.deepStrictEqual(ctx.bridge.topics, []);
  assert.deepStrictEqual(ctx.bridge.cleared, []);
  assert.deepStrictEqual(ctx.timeline, [], 'rollback sonrasi kick/publish yapilmamali');
});

test('commit sonrasi yan etki hatalari YUTULMAZ: yanitta warnings + partial; yanit YINE 200 (PIN kaybolmasin)', async () => {
  const ctx = await setup({ emqx: true });
  ctx.bridge.failSys = true;
  ctx.bridge.failClear = true;
  ctx.fetchFn.failAll = true;

  const r = await ctx.reset(ctx.tech);
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.match(r.setup_pin, /^\d{6}$/, 'islem commit edildi; PIN yine doner');
  assert.strictEqual(r.partial, true);
  // stoga donus: yayin basarisiz olsa da yeni anahtar sunucuda GECERLI (cihaz + envanter); yanitta bir kez + seri konsol
  // (RESETKEY + FACTORYINIT) yonergesi uyarisi
  assert.strictEqual(r.local_key_publish, 'failed');
  assert.ok(ctx.secretBox.isValidLocalKey(r.local_key));
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key);
  assert.strictEqual(ctx.inv.local_key_enc, ctx.dev.local_key_enc);
  assert.ok(!ctx.dev.local_key_pending_enc, 'bekleyen yok');
  assert.ok(r.warnings.length >= 3, JSON.stringify(r.warnings));
  const w = r.warnings.join(' | ');
  assert.match(w, /RESETKEY/);
  assert.match(w, /bağlantı/i);
  assert.match(w, /Retained/);
  // kimlikler yine de silindi (yeni baglanti engellendi)
  assert.strictEqual(ctx.world.state.mqtt_credentials.length, 0);
});

test('EMQX yonetim API ayari yoksa uyari doner (sessizce gecilmez)', async () => {
  const ctx = await setup(); // EMQX_API_* tanimli degil
  const r = await ctx.reset(ctx.tech);
  assert.ok(r.warnings.some((x) => /EMQX/.test(x)), JSON.stringify(r.warnings));
  assert.strictEqual(r.partial, true);
});

test('STOGA DONUS + pano cevrimdisi: yeni anahtar yine HEMEN gecerli; yayin denenmez (skipped_offline); anahtar yanitta bir kez', async () => {
  const ctx = await setup({ deviceOnline: false, emqx: true });
  const r = await ctx.reset(ctx.tech);
  assert.strictEqual(r.local_key_publish, 'skipped_offline');
  assert.strictEqual(ctx.bridge.topics.length, 0);
  assert.ok(ctx.secretBox.isValidLocalKey(r.local_key));
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key);
  assert.strictEqual(ctx.inv.local_key_enc, ctx.dev.local_key_enc, 'envanter = yeni anahtar');
  assert.ok(!ctx.dev.local_key_pending_enc, 'bekleyen yok');
  // istemci notu local_key_publish'ten uretir; tek gercek uyari cocuk kilidi
  assert.ok(!r.warnings.some((x) => /yerel anahtar/i.test(x)), JSON.stringify(r.warnings));
  assert.ok(r.warnings.includes('Pano çevrimdışı; çocuk kilidi sıfırlama komutu gönderilemedi. Pano yerelde kilitli kalmış olabilir.'), JSON.stringify(r.warnings));
  assert.strictEqual(r.child_lock_reset, 'skipped_offline', 'cocuk kilidi davranisi degismedi');
});

test('eski ailenin kullanici oturumlari GLOBAL iptal edilmez (baska evlerdeki oturumlar korunur); ev erisimi uyelik silinerek kesilir', () => {
  const src = fs.readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/revokeAllUserSessions/.test(src), 'kullanicinin TUM oturumlarini dusuren cagri olmamali');
});

test('eski kod kalintilari yok: 123456 sabit PIN, BEGIN/COMMIT, mqttBridge.publish', () => {
  const src = fs.readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/defaultPinHash/.test(src));
  assert.ok(!/\b[0-9a-f]{64}\b/i.test(src), 'kaynakta sabit 64 onaltilik (SHA-256 benzeri) ozet degeri olmamali');
  assert.ok(!/'123456'/.test(src));
  assert.ok(!/query\(\s*['"`](BEGIN|COMMIT|ROLLBACK)/.test(src));
  assert.ok(!/mqttBridge\.publish\(/.test(src));
});

// ------------------------------------------------------------------------------------------------
// Kenar durumlar: iptal/askiya alinmis cihaz, kick istisnasi, sys yayin yedegi
// ------------------------------------------------------------------------------------------------
test('REVOKED / SUSPENDED cihazi YALNIZCA super sifirlayabilir; staff yonetim kararini geri alamaz (hicbir sey degismez)', async () => {
  for (const status of ['REVOKED', 'SUSPENDED']) {
    const ctx = await setup();
    ctx.inv.status = status;
    const before = {
      members: ctx.world.state.home_users.length,
      endpoints: ctx.world.state.endpoints.length,
      credentials: ctx.world.state.mqtt_credentials.length,
    };

    await expectHttp(ctx.reset(ctx.tech), 403, 'FORBIDDEN');
    assert.strictEqual(ctx.inv.status, status, `${status}: envanter degismemeli`);
    assert.strictEqual(ctx.world.state.home_users.length, before.members);
    assert.strictEqual(ctx.world.state.endpoints.length, before.endpoints);
    assert.strictEqual(ctx.world.state.mqtt_credentials.length, before.credentials);
    assert.strictEqual(ctx.bridge.cleared.length, 0, 'retained temizligi yapilmamali');

    const r = await ctx.reset(ctx.root);
    assert.strictEqual(r.action, 'UNCLAIMED', `${status}: super sifirlayabilir`);
    assert.strictEqual(ctx.inv.status, 'IN_STOCK');
  }
});

test('kick istisna firlatirsa (ag/EMQX) sifirlama yine tamamlanir: uyari + partial, PIN yine doner', async () => {
  const ctx = await setup();
  ctx.credentials.kickUsernames = async () => {
    throw new Error('beklenmeyen kick hatasi');
  };
  const r = await ctx.reset(ctx.tech);
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.match(r.setup_pin, /^\d{6}$/);
  assert.strictEqual(r.partial, true);
  assert.ok(r.warnings.some((w) => /MQTT bağlantıları atılamadı; kimlikler silindi/.test(w)), JSON.stringify(r.warnings));
  assert.strictEqual(ctx.inv.status, 'IN_STOCK', 'islem commit edildi');
});

test('_publishSys: kopru publishSys saglamiyorsa publishToTopic(ev/{t}/sys) yedegi kullanilir', async () => {
  setTestEnv();
  const world = createWorld();
  const base = createServices(world);
  const published = [];
  const legacyBridge = {
    isConnected: () => true,
    publishCommand: async () => ({}),
    publishToTopic: async (topic, obj) => { published.push({ topic, obj }); return {}; },
    clearRetained: async () => {},
  };
  const svc = createServices(world, { mqttBridge: legacyBridge }).deviceService;
  await svc._publishSys('h_0123456789abcdef', { cmd: 'set_local_key', local_key: 'x' });
  assert.deepStrictEqual(published, [{ topic: 'ev/h_0123456789abcdef/sys', obj: { cmd: 'set_local_key', local_key: 'x' } }]);
  assert.strictEqual(base.bridge.topics.length, 0, 'varsayilan kopru kullanilmadi');
});

// ---- inceleme (pano-5 bulgusu): stoga donus anahtari bekleyen BIRAKMAZ ----
test('cok panolu evde STOGA DONUS: set_local_key ev konusundan YAYINLANMAZ (kardes panonun anahtari degisirdi); anahtar gecerli + yanitta', async () => {
  const ctx = await setup({ deviceOnline: true, emqx: true });
  const sibKeyEnc = ctx.secretBox.encrypt('KardesAnahtar1234');
  const sib = ctx.world.helpers.addDevice({
    home: ctx.home, uuid: 'AHBU-S3-0009', mac: 'E8:F6:0A:00:00:09', claimedBy: ctx.owner, online: true, local_key_enc: sibKeyEnc,
  });
  const r = await ctx.reset(ctx.tech);
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(ctx.bridge.topics.filter((t) => t.obj && t.obj.cmd === 'set_local_key').length, 0);
  assert.strictEqual(r.local_key_publish, 'skipped');
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key);
  assert.strictEqual(ctx.inv.local_key_enc, ctx.dev.local_key_enc);
  assert.strictEqual(sib.local_key_enc, sibKeyEnc, 'kardes panonun anahtari degismez');
});

test('stoga donusten sonra yeni musterinin sahiplenmesi YENI anahtari alir (eski sahibin anahtari yeni dairede gecersiz)', async () => {
  const ctx = await setup();
  const r = await ctx.reset(ctx.tech);
  const buyer = ctx.world.helpers.addUser({ email: 'alici2@example.test' });
  await ctx.deviceService.claimDevice({ actor: ctx.act(buyer), deviceUuid: UUID, setupPin: r.setup_pin });
  assert.notStrictEqual(ctx.dev.home_id, ctx.home.id);
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key);
  assert.notStrictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), 'EskiAnahtar123456');
  assert.ok(!ctx.dev.local_key_pending_enc);
});

// ---- guvenlik-1: stoga donuste acik alarmlar kapanir; yeni sahibe devirde (ayni ev + pano) korunur ----
test('guvenlik-1: STOGA DONUS (UNCLAIMED) panonun acik alarmlarini lost/detached yapar; DEVIR (REASSIGNED) dokunmaz', async () => {
  const ctx = await setup();
  const a = { id: 1, device_id: ctx.dev.id, home_id: ctx.home.id, kind: 'gas', status: 'latched', ack_requested_at: new Date(), ack_requested_by: 'u' };
  ctx.world.state.alarms.push(a);
  const r = await ctx.reset(ctx.tech);
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(a.status, 'lost');
  assert.strictEqual(a.cleared_by, 'detached');
  assert.strictEqual(a.ack_requested_at, null);

  const ctx2 = await setup();
  const b = { id: 2, device_id: ctx2.dev.id, home_id: ctx2.home.id, kind: 'gas', status: 'latched' };
  ctx2.world.state.alarms.push(b);
  const r2 = await ctx2.reset(ctx2.root, { newOwnerIdentifier: ctx2.newbie.email });
  assert.strictEqual(r2.action, 'REASSIGNED');
  assert.strictEqual(b.status, 'latched', 'ayni ev ve pano: alarm gecerli kalir');
});
