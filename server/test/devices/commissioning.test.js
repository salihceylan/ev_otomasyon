'use strict';

// B9 / B11: devreye alma (commissioning), cihaz listesi, yerel anahtar, cihaz kimligi yeniden uretimi

const test = require('node:test');
const assert = require('node:assert');
const bcrypt = require('bcryptjs');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');

const UUID = 'AHBU-S3-0001';

function setup() {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user', full_name: 'Ali Usta' });
  const home = h.addHome({ name: 'Ev', owner });
  const otherHome = h.addHome({ name: 'Baska' });
  const keyEnc = svc.secretBox.encrypt('YerelAnahtar12345');
  const dev = h.addDevice({ home, uuid: UUID, mac: 'E8:F6:0A:00:00:01', claimedBy: owner, online: true, local_key_enc: keyEnc });
  dev.firmware_version = '1.1.0';
  dev.ip_address = '192.168.1.30';
  dev.last_seen_at = new Date(world.clock.t - 5000);
  const otherDev = h.addDevice({ home: otherHome, uuid: 'AHBU-S3-0002', mac: 'E8:F6:0A:00:00:02', local_key_enc: svc.secretBox.encrypt('BaskaAnahtar12345') });
  const actor = (access, extra = {}) => ({ userId: tech.id, globalRole: 'service_user', ip: '10.0.0.9', access, label: 'Ali Usta', ...extra });
  const checks = (overrides = {}) => ({
    relays: { ok: true, detail: '8/8 role calisti' },
    buttons: { ok: true, detail: 'Buton yok' },
    shutters: { ok: true, detail: 'Sure 24 sn, yon dogru' },
    network: { ok: true, detail: 'Wi-Fi -52 dBm' },
    cloud: { ok: true, detail: 'state alindi' },
    ...overrides,
  });
  const commission = (o = {}, who = actor('service_user')) =>
    svc.deviceService.commissionHome({ actor: who, homeId: home.id, deviceUuid: UUID, checks: checks(), notes: 'Kurulum tamam', ...o });
  return { world, ...svc, owner, tech, home, otherHome, dev, otherDev, keyEnc, actor, checks, commission };
}

// ------------------------------------------------------------------------------------------------
// Devreye alma
// ------------------------------------------------------------------------------------------------

test('5 zorunlu kontrolun HEPSI ok ise tests_passed=true: cihaz onaylanir, kontroller AYRI kayitlanir', async () => {
  const ctx = setup();
  const r = await ctx.commission();
  const { state } = ctx.world;

  assert.strictEqual(r.tests_passed, true);
  assert.strictEqual(r.commissioned, true);
  assert.strictEqual(r.status, 'APPROVED_WORKING');
  assert.strictEqual(r.device_uuid, UUID);
  assert.deepStrictEqual(Object.keys(r.checks).sort(), ['buttons', 'cloud', 'network', 'relays', 'shutters']);
  assert.strictEqual(r.checks.shutters.detail, 'Sure 24 sn, yon dogru');

  assert.strictEqual(ctx.dev.is_commissioned, true);
  assert.strictEqual(ctx.dev.commissioning_status, 'APPROVED_WORKING');
  assert.strictEqual(ctx.dev.commissioned_by, ctx.tech.id);
  assert.strictEqual(ctx.dev.commissioning_notes, 'Kurulum tamam');
  assert.ok(ctx.dev.commissioned_at);

  assert.strictEqual(state.commissioning_logs.length, 1);
  const log = state.commissioning_logs[0];
  assert.strictEqual(log.tests_passed, true);
  assert.strictEqual(log.technician_id, ctx.tech.id);
  assert.strictEqual(log.technician_label, 'Ali Usta');
  assert.strictEqual(log.device_uuid, UUID);
  assert.strictEqual(log.notes, 'Kurulum tamam');

  // kontrol sonuclari ayri satirlar (5 adet)
  assert.strictEqual(state.commissioning_checks.length, 5);
  assert.ok(state.commissioning_checks.every((c) => c.commissioning_log_id === log.id));
  assert.deepStrictEqual(state.commissioning_checks.map((c) => c.check_name).sort(), ['buttons', 'cloud', 'network', 'relays', 'shutters']);
  assert.ok(state.commissioning_checks.every((c) => c.ok === true));
  assert.strictEqual(state.commissioning_checks.find((c) => c.check_name === 'relays').detail, '8/8 role calisti');

  // tek transaction, denetim kaydi
  assert.strictEqual(ctx.world.db.commits, 1);
  assert.deepStrictEqual(ctx.world.db.nonTxQueries(), []);
  assert.ok(state.device_audit_logs.some((a) => a.event === 'commissioning' && a.ip_address === '10.0.0.9'));
});

test('tek kontrol basarisizsa tests_passed=false SUNUCUDA hesaplanir: cihaz ONAYLANMAZ (TESTS_FAILED)', async () => {
  for (const failing of ['relays', 'buttons', 'shutters', 'network', 'cloud']) {
    const ctx = setup();
    const r = await ctx.commission({ checks: ctx.checks({ [failing]: { ok: false, detail: 'basarisiz' } }) });
    assert.strictEqual(r.tests_passed, false, failing);
    assert.strictEqual(r.commissioned, false);
    assert.strictEqual(r.status, 'TESTS_FAILED');
    assert.strictEqual(ctx.dev.is_commissioned, false);
    assert.strictEqual(ctx.dev.commissioning_status, 'TESTS_FAILED');
    assert.strictEqual(ctx.dev.commissioned_by, null);
    assert.strictEqual(ctx.world.state.commissioning_logs[0].tests_passed, false);
    assert.strictEqual(ctx.world.state.commissioning_checks.find((c) => c.check_name === failing).ok, false);
  }
});

test('ISTEMCININ tests_passed / commissioned degeri YOK SAYILIR (sunucu hesaplar)', async () => {
  const ctx = setup();
  const r = await ctx.commission({
    checks: ctx.checks({ cloud: { ok: false, detail: 'bulutta gorunmedi' } }),
    tests_passed: true,
    testsPassed: true,
    commissioned: true,
  });
  assert.strictEqual(r.tests_passed, false);
  assert.strictEqual(ctx.dev.is_commissioned, false);
  assert.strictEqual(ctx.world.state.commissioning_logs[0].tests_passed, false);
});

test('zorunlu 5 kontrol eksiksiz olmali: eksik/bos/yanlis tip kontrol 400 ve HICBIR sey yazilmaz', async () => {
  const ctx = setup();
  const full = ctx.checks();
  const bad = [
    undefined, null, 'ok', [], {},
    { ...full, relays: undefined }, (() => { const c = { ...full }; delete c.cloud; return c; })(),
    { ...full, relays: null }, { ...full, relays: 'ok' }, { ...full, relays: [] },
    { ...full, relays: { detail: 'ok degeri yok' } },
    { ...full, relays: { ok: 'true' } }, { ...full, relays: { ok: 1 } }, { ...full, relays: { ok: null } },
    { ...full, relays: { ok: true, detail: 42 } }, { ...full, relays: { ok: true, detail: 'x'.repeat(501) } },
    { ...full, ekstra: { ok: true } }, { ...full, 'relays\n': { ok: true } },
  ];
  for (const checks of bad) {
    await expectHttp(ctx.commission({ checks }), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.world.state.commissioning_logs.length, 0);
  assert.strictEqual(ctx.world.state.commissioning_checks.length, 0);
  assert.ok(!ctx.dev.is_commissioned, 'cihaz onaylanmamali');
});

test('varsayilan "tumu test edildi" notu YOK: not verilmezse bos (null) kaydedilir', async () => {
  const ctx = setup();
  await ctx.commission({ notes: undefined });
  assert.strictEqual(ctx.world.state.commissioning_logs[0].notes, null);
  assert.strictEqual(ctx.dev.commissioning_notes, null);
  await expectHttp(ctx.commission({ notes: 'x'.repeat(1001) }), 400, 'VALIDATION');
  await expectHttp(ctx.commission({ notes: 12 }), 400, 'VALIDATION');
  const src = require('fs').readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/test edildi ve onaylandi|Basarili test/i.test(src), 'varsayilan onay notu olmamali');
});

test('detail bos birakilabilir (null); metin kirpilir', async () => {
  const ctx = setup();
  const r = await ctx.commission({ checks: ctx.checks({ buttons: { ok: true }, network: { ok: true, detail: '   Wi-Fi iyi  ' } }) });
  assert.strictEqual(r.checks.buttons.detail, null);
  assert.strictEqual(r.checks.network.detail, 'Wi-Fi iyi');
});

test('yetki: owner/resident/misafir devreye alamaz (403); staff/servis oturumu/super alabilir', async () => {
  for (const access of ['owner', 'resident', 'guest', 'hacker', null]) {
    const ctx = setup();
    await expectHttp(ctx.commission({}, ctx.actor(access)), 403, 'FORBIDDEN');
    assert.strictEqual(ctx.world.db.log.length, 0);
  }
  for (const access of ['service_user', 'service_session', 'super_user']) {
    const ctx = setup();
    const who = access === 'service_session'
      ? ctx.actor(access, { userId: null, globalRole: 'service_session', sessionId: 'sess-77', label: 'Veli Usta' })
      : ctx.actor(access);
    const r = await ctx.commission({}, who);
    assert.strictEqual(r.tests_passed, true, access);
    if (access === 'service_session') {
      const log = ctx.world.state.commissioning_logs[0];
      assert.strictEqual(log.technician_id, null, 'servis oturumu kullanici satiri olusturmaz');
      assert.strictEqual(log.technician_label, 'Veli Usta');
      assert.strictEqual(log.service_session_id, 'sess-77');
      assert.strictEqual(ctx.dev.commissioned_by, null);
    }
  }
});

test('cihaz bu evde olmali (IDOR): baska evin cihazi / olmayan cihaz 404; gecersiz UUID 400', async () => {
  const ctx = setup();
  await expectHttp(ctx.commission({ deviceUuid: 'AHBU-S3-0002' }), 404, 'NOT_FOUND');
  await expectHttp(ctx.commission({ deviceUuid: 'AHBU-YOK-1' }), 404, 'NOT_FOUND');
  await expectHttp(ctx.commission({ deviceUuid: 'bozuk' }), 400, 'VALIDATION');
  await expectHttp(ctx.commission({ deviceUuid: undefined }), 400, 'VALIDATION');
  assert.strictEqual(ctx.otherDev.is_commissioned, undefined);
  assert.strictEqual(ctx.world.state.commissioning_logs.length, 0);
});

test('onayli cihazda yeni basarisiz test onayi geri alir (TESTS_FAILED)', async () => {
  const ctx = setup();
  await ctx.commission();
  assert.strictEqual(ctx.dev.is_commissioned, true);
  await ctx.commission({ checks: ctx.checks({ network: { ok: false, detail: 'zayif' } }) });
  assert.strictEqual(ctx.dev.is_commissioned, false);
  assert.strictEqual(ctx.dev.commissioning_status, 'TESTS_FAILED');
  assert.strictEqual(ctx.world.state.commissioning_logs.length, 2);
});

test('devreye alma durumu: tum cihazlar + eski alanlar (ilk cihazdan), teknisyen adi', async () => {
  const ctx = setup();
  const none = ctx.world.helpers.addHome({ name: 'Bos' });
  assert.deepStrictEqual(await ctx.deviceService.getCommissioningStatus({ homeId: none.id }), { is_commissioned: false, status: 'NO_DEVICE', devices: [] });

  let s = await ctx.deviceService.getCommissioningStatus({ homeId: ctx.home.id });
  assert.strictEqual(s.is_commissioned, false);
  assert.strictEqual(s.devices.length, 1);
  assert.strictEqual(s.commissioning_status, 'PENDING_INSTALLATION');

  await ctx.commission();
  s = await ctx.deviceService.getCommissioningStatus({ homeId: ctx.home.id });
  assert.strictEqual(s.is_commissioned, true);
  assert.strictEqual(s.technician_name, 'Ali Usta');
  assert.strictEqual(s.commissioning_notes, 'Kurulum tamam');
  assert.strictEqual(s.devices[0].device_uuid, UUID);

  // ikinci cihaz onaysiz: dairenin geneli onayli degil
  ctx.world.helpers.addDevice({ home: ctx.home, uuid: 'AHBU-S3-0007', mac: 'E8:F6:0A:00:00:07' });
  s = await ctx.deviceService.getCommissioningStatus({ homeId: ctx.home.id });
  assert.strictEqual(s.is_commissioned, false);
  assert.strictEqual(s.devices.length, 2);
});

// ------------------------------------------------------------------------------------------------
// Cihaz listesi
// ------------------------------------------------------------------------------------------------

test('cihaz listesi: sozlesme alanlari { device_uuid, name, online, last_seen_at (ISO), firmware }; yalniz bu evin cihazlari', async () => {
  const ctx = setup();
  ctx.dev.name = 'Zemin Kat Panosu';
  const list = await ctx.deviceService.listDevices({ homeId: ctx.home.id });
  assert.strictEqual(list.length, 1);
  const d = list[0];
  assert.strictEqual(d.device_uuid, UUID);
  assert.strictEqual(d.name, 'Zemin Kat Panosu');
  assert.strictEqual(d.online, true);
  assert.strictEqual(d.firmware, '1.1.0');
  assert.match(d.last_seen_at, /^\d{4}-\d{2}-\d{2}T.*Z$/);
  assert.ok(!('ip_address' in d), 'ag bilgisi varsayilan olarak yok');
  assert.ok(!('mac_address' in d) && !('local_key_enc' in d) && !('setup_pin' in d));

  const withNet = await ctx.deviceService.listDevices({ homeId: ctx.home.id, includeNetwork: true });
  assert.strictEqual(withNet[0].ip_address, '192.168.1.30');

  // ad yoksa model, o da yoksa UUID
  ctx.dev.name = null;
  const noName = await ctx.deviceService.listDevices({ homeId: ctx.home.id });
  assert.strictEqual(noName[0].name, 'ESP32-S3-POE-ETH-8DI-8RO');
});

// ------------------------------------------------------------------------------------------------
// Yerel anahtar
// ------------------------------------------------------------------------------------------------

test('yerel anahtar: owner/resident/staff/servis oturumu alir; misafir ve super HAYIR; her okuma denetim kaydina yazilir', async () => {
  for (const access of ['owner', 'resident', 'service_user', 'service_session']) {
    const ctx = setup();
    const r = await ctx.deviceService.getLocalKey({ actor: ctx.actor(access), homeId: ctx.home.id, deviceUuid: UUID.toLowerCase() });
    // pano-5: + local_key_fp (panonun lk_fp'siyle karsilastirma icin; anahtar degil)
    const { localKeyFingerprint } = require('../../src/utils/local_key_fp');
    assert.deepStrictEqual(r, { local_key: 'YerelAnahtar12345', local_key_fp: localKeyFingerprint('YerelAnahtar12345', UUID) }, access);
    const audit = ctx.world.state.device_audit_logs.find((a) => a.event === 'local_key_read');
    assert.ok(audit, 'okuma denetlenmeli');
    assert.strictEqual(audit.device_uuid, UUID);
    assert.strictEqual(audit.ip_address, '10.0.0.9');
    assert.ok(!JSON.stringify(ctx.world.state.device_audit_logs).includes('YerelAnahtar12345'), 'anahtar denetim kaydina yazilmamali');
  }
  for (const access of ['guest', 'super_user', 'hacker', null]) {
    const ctx = setup();
    await expectHttp(ctx.deviceService.getLocalKey({ actor: ctx.actor(access), homeId: ctx.home.id, deviceUuid: UUID }), 403, 'FORBIDDEN');
    assert.strictEqual(ctx.world.state.device_audit_logs.length, 0);
  }
});

test('yerel anahtar: baska evin cihazi 404 (IDOR); anahtari olmayan cihaz 404; bozuk UUID 400', async () => {
  const ctx = setup();
  await expectHttp(ctx.deviceService.getLocalKey({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: 'AHBU-S3-0002' }), 404, 'NOT_FOUND');
  ctx.dev.local_key_enc = null;
  await expectHttp(ctx.deviceService.getLocalKey({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: UUID }), 404, 'NOT_FOUND');
  await expectHttp(ctx.deviceService.getLocalKey({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: 'bozuk' }), 400, 'VALIDATION');
});

test('yerel anahtar: LOCAL_KEY_SECRET yoksa/bozuksa acik hata; denetim kaydi yazilamazsa anahtar VERILMEZ (fail-closed)', async () => {
  const ctx = setup();
  delete process.env.LOCAL_KEY_SECRET;
  await assert.rejects(ctx.deviceService.getLocalKey({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: UUID }), /LOCAL_KEY_SECRET/);

  const ctx2 = setup();
  ctx2.dev.local_key_enc = 'v1:bozuk:bozuk:bozuk';
  await assert.rejects(ctx2.deviceService.getLocalKey({ actor: ctx2.actor('owner'), homeId: ctx2.home.id, deviceUuid: UUID }), /cozulemedi/);

  const ctx3 = setup();
  const original = ctx3.world.db._exec.bind(ctx3.world.db);
  ctx3.world.db._exec = (tx, text, params) => {
    if (String(text).includes('INSERT INTO device_audit_logs')) return Promise.reject(new Error('audit tablosu yok'));
    return original(tx, text, params);
  };
  await assert.rejects(ctx3.deviceService.getLocalKey({ actor: ctx3.actor('owner'), homeId: ctx3.home.id, deviceUuid: UUID }), /audit tablosu yok/);
});

// ------------------------------------------------------------------------------------------------
// Cihaz kimligi yeniden uretimi
// ------------------------------------------------------------------------------------------------

test('cihaz MQTT kimligi yeniden uretimi: tek seferlik yeni parola, eski parola gecersiz, eski baglanti atilir', async () => {
  const ctx = setup();
  process.env.EMQX_API_URL = 'http://emqx.test.invalid:18083';
  process.env.EMQX_API_KEY = 'k';
  process.env.EMQX_API_SECRET = 's';
  const first = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.timeline.length = 0;

  const r = await ctx.deviceService.reissueDeviceCredential({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: UUID });
  assert.strictEqual(r.username, `d_${ctx.home.mqtt_username}`);
  assert.strictEqual(r.password.length, 24);
  assert.notStrictEqual(r.password, first.password);
  assert.strictEqual(r.topic_id, ctx.home.mqtt_username);
  assert.ok(!('previous_usernames' in r));
  const rows = ctx.world.state.mqtt_credentials.filter((c) => c.kind === 'device');
  assert.strictEqual(rows.length, 1);
  assert.ok(bcrypt.compareSync(r.password, rows[0].password_hash));
  assert.ok(!bcrypt.compareSync(first.password, rows[0].password_hash));
  assert.deepStrictEqual(ctx.timeline, [`kick:d_${ctx.home.mqtt_username}`]);
  assert.ok(ctx.world.state.device_audit_logs.some((a) => a.event === 'device_credential_reissued'));
  assert.ok(!JSON.stringify(ctx.world.state).includes(r.password));
});

test('cihaz kimligi yeniden uretimi: yetki (resident/misafir 403), baska evin cihazi 404, bozuk UUID 400', async () => {
  const ctx = setup();
  for (const access of ['resident', 'guest', 'hacker', null]) {
    await expectHttp(ctx.deviceService.reissueDeviceCredential({ actor: ctx.actor(access), homeId: ctx.home.id, deviceUuid: UUID }), 403, 'FORBIDDEN');
  }
  await expectHttp(ctx.deviceService.reissueDeviceCredential({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: 'AHBU-S3-0002' }), 404, 'NOT_FOUND');
  await expectHttp(ctx.deviceService.reissueDeviceCredential({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: 'x' }), 400, 'VALIDATION');
  assert.strictEqual(ctx.world.state.mqtt_credentials.length, 0);
  for (const access of ['owner', 'service_user', 'service_session', 'super_user']) {
    const c = setup();
    const r = await c.deviceService.reissueDeviceCredential({ actor: c.actor(access), homeId: c.home.id, deviceUuid: UUID });
    assert.ok(r.password, access);
  }
});

test('cihaz kimligi yeniden uretimi: kick istisna firlatirsa yeni kimlik YINE doner + uyari (kimlik kaybolmaz)', async () => {
  const ctx = setup();
  await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.credentials.kickUsernames = async () => {
    throw new Error('beklenmeyen kick hatasi');
  };
  const r = await ctx.deviceService.reissueDeviceCredential({ actor: ctx.actor('owner'), homeId: ctx.home.id, deviceUuid: UUID });
  assert.strictEqual(r.password.length, 24, 'yeni parola tek seferlik doner');
  assert.deepStrictEqual(r.warnings, ['Eski cihaz bağlantısı atılamadı.']);
  const rows = ctx.world.state.mqtt_credentials.filter((c) => c.kind === 'device');
  assert.strictEqual(rows.length, 1);
  assert.ok(bcrypt.compareSync(r.password, rows[0].password_hash));
});

// ---- servis_kurulum-10: basarili devreye alma bagli site dairesini 'handed_over' yapar ----
test('servis_kurulum-10: tests_passed=true -> karta bagli daire handed_over (planned/written/installed); basarisiz test geri cekmez', async () => {
  const ctx = setup();
  const { state } = ctx.world;
  const flat = { id: 'f-1', site_id: 's-1', block: 'A', number: '1', status: 'installed', device_uuid: UUID };
  const other = { id: 'f-2', site_id: 's-1', block: 'A', number: '2', status: 'written', device_uuid: 'AHBU-S3-0002' };
  state.site_flats.push(flat, other);
  await ctx.commission({ checks: ctx.checks({ relays: { ok: false, detail: 'role 3 yok' } }) });
  assert.strictEqual(flat.status, 'installed', 'basarisiz devreye alma daireyi ilerletmez');
  await ctx.commission();
  assert.strictEqual(flat.status, 'handed_over');
  assert.strictEqual(other.status, 'written', 'baska karta bagli daireye dokunulmaz');
  // basarisiz test teslim edilmis daireyi GERI CEKMEZ
  await ctx.commission({ checks: ctx.checks({ cloud: { ok: false, detail: 'yok' } }) });
  assert.strictEqual(flat.status, 'handed_over');
});

test('servis_kurulum-10: migration 035 yoksa daire guncellemesi atlanir (devreye alma yine basarili)', async () => {
  const ctx = setup();
  ctx.world.state.schema035 = false;
  const r = await ctx.commission();
  assert.strictEqual(r.tests_passed, true);
  assert.ok(!ctx.world.db.sqls().some((s) => s.includes("SET status = 'handed_over'")));
});
