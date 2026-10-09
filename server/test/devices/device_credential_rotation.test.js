'use strict';

// Karar 17A / 17B (2026-10-09): erisimi biten kisi evin cihaz MQTT kimligini (d_{t}) kopyaladiysa dinlemeyi / yayini
// surduremesin.
//  17A rotate(homeId, {tx, reason}): tek panolu evde, firmware >= 1.3.0 bildiren panonun cihaz kimligi GECERSIZ kilinir
//      (expires_at = NOW(); EMQX sorgusu ve qa_stack reddeder) + denetim 'device_credential_rotated'; COMMIT sonrasi
//      afterCommit ayni kullanici adinin TUM baglantilarini atar. Pano art arda "not authorized" alinca bootstrap ile
//      YENI kimlik alir (issueDeviceCredential gecersiz satiri siler). Firmware < 1.3.0 / bilinmiyor / cok pano:
//      atlanir + log (+ denetim 'device_credential_rotation_skipped').
//      Uzlastirici: cihaz kimligi dondurmesi bekliyorsa (gecersiz cihaz satiri var) set_local_key YAYINLANMAZ (yeni
//      kimlikle baglanan panoya gider, atilan eski oturuma degil).
//  17B issueDeviceCredential: tek panolu evde client_id = "ESP32S3_" + MAC (firmware MqttManager); cok pano / bozuk
//      MAC: NULL. Uygulama kimligi client_id NULL. EMQX kimlik sorgusu client_id doluysa ${clientid} esitligi ister;
//      qa_stack ayni kurali uygular.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { DeviceCredentialRotation, fwAtLeast, deviceClientId } = require('../../src/services/device_credential_rotation');
const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
const { DeviceReconciler, SQL: RSQL } = require('../../src/services/device_reconciler');

function fakeDb({ devices = [], creds = [] } = {}) {
  const calls = [];
  const audits = [];
  return {
    calls,
    audits,
    creds,
    async query(text, params = []) {
      calls.push({ text, params });
      if (/^UPDATE service_sessions SET device_cred_rotated_at = NOW\(\)/.test(text)) return { rows: [], rowCount: 0 };
      if (/^SELECT id, device_uuid, firmware_version FROM devices WHERE home_id = \$1/.test(text)) {
        return { rows: devices.filter((d) => d.home_id === params[0]) };
      }
      if (/^UPDATE mqtt_credentials SET expires_at = NOW\(\)/.test(text)) {
        const hit = creds.filter((c) => c.home_id === params[0] && c.kind === 'device' && !c.expired);
        hit.forEach((c) => { c.expired = true; });
        return { rows: hit.map((c) => ({ username: c.username })), rowCount: hit.length };
      }
      if (/^INSERT INTO device_audit_logs/.test(text)) {
        audits.push({ event: params[0], device_uuid: params[1], home_id: params[2], details: JSON.parse(params[6]) });
        return { rows: [], rowCount: 1 };
      }
      throw new Error(`beklenmeyen SQL: ${text.slice(0, 80)}`);
    },
  };
}

function setup(opts) {
  const db = fakeDb(opts);
  const logs = [];
  const kicked = [];
  const rot = new DeviceCredentialRotation({
    db,
    logger: { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) },
    credentials: { kickUsernames: async (u) => { kicked.push(...u); return { requested: u.length, kicked: u.length, failed: 0 }; } },
  });
  return { db, logs, kicked, rot };
}

const H = '11111111-1111-4111-8111-111111111111';

test('fwAtLeast: 1.3.0 ve uzeri; v oneki; bilinmeyen / bozuk surum eski sayilir', () => {
  for (const v of ['1.3.0', 'v1.3.0', '1.3.2', '1.10.0', '2.0.0', '1.3.0-rc1']) assert.equal(fwAtLeast(v), true, v);
  for (const v of ['1.2.99', 'v1.0.0', '0.9.9', null, undefined, '', 'abc', '1.3']) assert.equal(fwAtLeast(v), false, String(v));
});

test('deviceClientId: firmware bicimi ESP32S3_<12 hane buyuk harf>; bozuk MAC null', () => {
  assert.equal(deviceClientId('e8:f6:0a:dd:87:54'), 'ESP32S3_E8F60ADD8754');
  assert.equal(deviceClientId('E8-F6-0A-DD-87-54'), 'ESP32S3_E8F60ADD8754');
  assert.equal(deviceClientId('E8:F6:0A:DD:87:54-DUP-1a2b3c4d'), null, 'MAC cakismasi yeniden adlandirmasi');
  assert.equal(deviceClientId(null), null);
});

test('17A rotate: tek pano + fw 1.3.0 -> kimlik gecersiz, denetim, COMMIT sonrasi kick', async () => {
  const c = setup({
    devices: [{ id: 'd1', home_id: H, device_uuid: 'AHBU-S3-0001', firmware_version: '1.3.0' }],
    creds: [{ home_id: H, kind: 'device', username: 'd_h_abc' }],
  });
  const r = await c.rot.rotate(H, { tx: c.db, reason: 'member_removed' });
  assert.deepEqual(r, { rotated: true, usernames: ['d_h_abc'], deviceUuid: 'AHBU-S3-0001', reason: 'member_removed' });
  assert.equal(c.db.creds[0].expired, true);
  assert.deepEqual(c.db.audits.map((a) => [a.event, a.details.reason]), [['device_credential_rotated', 'member_removed']]);
  assert.deepEqual(c.kicked, [], 'kick COMMIT oncesi yapilmaz');
  await c.rot.afterCommit(r);
  assert.deepEqual(c.kicked, ['d_h_abc']);
});

test('17A rotate: eski / bilinmeyen firmware atlanir ve loglanir; kimlik gecerli kalir', async () => {
  for (const fw of ['1.2.9', null, 'v1.0.0']) {
    const c = setup({
      devices: [{ id: 'd1', home_id: H, device_uuid: 'AHBU-S3-0001', firmware_version: fw }],
      creds: [{ home_id: H, kind: 'device', username: 'd_h_abc' }],
    });
    const r = await c.rot.rotate(H, { tx: c.db, reason: 'home_transfer' });
    assert.equal(r.rotated, false);
    assert.equal(r.reason, 'old_firmware');
    assert.equal(c.db.creds[0].expired, undefined, `fw=${fw}: kimlik degismez`);
    assert.ok(!c.db.calls.some((x) => /^UPDATE mqtt_credentials/.test(x.text)));
    assert.deepEqual(c.db.audits.map((a) => a.event), ['device_credential_rotation_skipped']);
    assert.ok(c.logs.some((m) => /atlandi/.test(m) && /old_firmware/.test(m)), c.logs.join('|'));
    await c.rot.afterCommit(r);
    assert.deepEqual(c.kicked, []);
  }
});

test('17A rotate: panosuz ev ve cok panolu ev atlanir; afterCommit firlatmaz', async () => {
  const none = setup({});
  assert.deepEqual(await none.rot.rotate(H, { tx: none.db, reason: 'x' }), { rotated: false, reason: 'no_device' });
  const multi = setup({
    devices: [
      { id: 'd1', home_id: H, device_uuid: 'AHBU-S3-0001', firmware_version: '1.3.1' },
      { id: 'd2', home_id: H, device_uuid: 'AHBU-S3-0002', firmware_version: '1.3.1' },
    ],
    creds: [{ home_id: H, kind: 'device', username: 'd_h_abc' }],
  });
  const r = await multi.rot.rotate(H, { tx: multi.db, reason: 'x' });
  assert.equal(r.reason, 'multi_board');
  assert.equal(multi.db.creds[0].expired, undefined);
  const bad = new DeviceCredentialRotation({ db: multi.db, logger: { warn() {}, error() {}, log() {} }, credentials: { kickUsernames: async () => { throw new Error('ag'); } } });
  await bad.afterCommit({ rotated: true, usernames: ['d_h_abc'] });
  await bad.afterCommit(null);
});

test('17B issueDeviceCredential: tek panoda client_id = ESP32S3_<MAC>; cok panoda NULL; uygulama kimligi NULL', async () => {
  const run = async (macs) => {
    const inserts = [];
    const tx = {
      async query(text, params) {
        if (/pg_advisory_xact_lock/.test(text)) return { rows: [{}] };
        if (/SELECT mqtt_username FROM homes/.test(text)) return { rows: [{ mqtt_username: 'h_0123456789abcdef' }] };
        if (/SELECT mac_address FROM devices WHERE home_id = \$1/.test(text)) return { rows: macs.map((m) => ({ mac_address: m })) };
        if (/DELETE FROM mqtt_credentials/.test(text)) return { rows: [] };
        if (/INSERT INTO mqtt_credentials/.test(text)) { inserts.push(params); return { rows: [{ id: 'c1' }] }; }
        if (/INSERT INTO mqtt_acl/.test(text)) return { rows: [] };
        throw new Error(`beklenmeyen SQL: ${text.slice(0, 60)}`);
      },
    };
    const svc = new MqttCredentialService({ bcrypt: { hash: async () => '$2a$04$x' }, env: { MQTT_PUBLIC_HOST: 'b.test', MQTT_PUBLIC_PORT: '8884' } });
    const dev = await svc.issueDeviceCredential({ homeId: H, deviceId: 'd1', tx });
    const app = await svc.issueUserCredential({ homeId: H, userId: '22222222-2222-4222-8222-222222222222', tx });
    return { inserts, dev, app };
  };
  const one = await run(['e8:f6:0a:dd:87:54']);
  assert.equal(one.inserts[0][4], 'ESP32S3_E8F60ADD8754', 'cihaz kimligi panoya bagli');
  assert.equal(one.inserts[1][4], null, 'uygulama kimligi bagsiz');
  assert.equal(one.dev.client_id, one.dev.username, 'yanit bicimi degismez');
  const two = await run(['e8:f6:0a:dd:87:54', 'e8:f6:0a:dd:87:55']);
  assert.equal(two.inserts[0][4], null, 'cok panolu evde baglama yok');
});

test('17A uzlastirici: cihaz kimligi dondurmesi bekliyorsa set_local_key yayinlanmaz', async () => {
  assert.match(RSQL.localKeyPending, /AS cred_rotation_pending/);
  assert.match(RSQL.localKeyPending, /kind = 'device'/);
  const published = [];
  const rows = [{ home_id: H, device_id: 'd1', device_uuid: 'AHBU-S3-0001', pending_enc: 'x', live: true, device_count: 1, key_fp: null, cred_rotation_pending: true }];
  const r = new DeviceReconciler({
    db: { query: async (text) => (text === RSQL.localKeyPending ? { rows } : { rows: [] }) },
    publishCommand: async () => ({}),
    publishSys: async (t, m) => { published.push(m); return {}; },
    logger: { log() {}, warn() {}, error() {} },
  });
  const home = { homeId: null, devices: new Map(), budgets: new Map(), timer: null, touched: Date.now(), logs: new Map(), disconnectedRetries: 0, echoCheckAfter: 0, awaitingKey: new Map() };
  await r._checkLocalKey('h_0123456789abcdef', home);
  assert.deepEqual(published, []);
  assert.equal(r.counters.skippedCredRotation, 1);
});

test('17B EMQX kimlik sorgusu client_id baglamasini ister; qa_stack ayni kurali uygular', () => {
  const conf = fs.readFileSync(path.join(__dirname, '..', '..', 'emqx_config', 'emqx.conf'), 'utf8');
  assert.match(conf, /FROM mqtt_credentials WHERE username = \$\{username\} AND \(expires_at IS NULL OR expires_at > NOW\(\)\) AND \(client_id IS NULL OR client_id = \$\{clientid\}\)/);
  const broker = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'tools', 'qa_stack', 'lib', 'broker.js'), 'utf8');
  assert.match(broker, /row\.client_id && row\.client_id !== client\.id/);
});

test('migration 043 / 044: sira, ASCII + LF, baslik, lock_timeout, transaction komutu yok; sema yukleyicisi yeni kolonlari goruyor', () => {
  const DIR = path.join(__dirname, '..', '..', 'migrations');
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  const order = ['042_phone_canonical.sql', '043_access_end_hardening.sql', '044_mqtt_client_binding.sql'];
  for (const f of order) assert.ok(files.includes(f), f);
  assert.ok(files.indexOf(order[0]) < files.indexOf(order[1]) && files.indexOf(order[1]) < files.indexOf(order[2]));
  for (const f of order.slice(1)) {
    const sql = fs.readFileSync(path.join(DIR, f), 'utf8');
    const body = sql.replace(/--[^\n]*/g, '');
    assert.equal(/[^\x00-\x7f]/.test(sql), false, `${f} ASCII`);
    assert.equal(sql.includes('\r'), false, `${f} LF`);
    assert.match(sql, new RegExp(`^-- =+\n-- Migration ${f.slice(0, 3)}`, 'm'));
    assert.match(body, /SET LOCAL lock_timeout = '5s';/);
    assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  }
  const { loadSchema } = require('../../scripts/check_schema_contract');
  const schema = loadSchema();
  assert.ok(schema.get('homes').has('ownership_epoch'));
  assert.ok(schema.get('service_sessions').has('device_cred_rotated_at'));
  assert.ok(schema.get('mqtt_credentials').has('client_id'));
});
