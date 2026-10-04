'use strict';

// WP-L D3 - Uc nokta yerlesimi esitlemesinin kapattigi kural, kanal artik uyumsuzken
// {enabled:true} ile DOGRULAMASIZ yeniden acilamaz. Kapatma her zaman serbesttir.
// (Sahte db; gercek PostgreSQL icin scheduled_rules_layout_pg.test.js.)

const test = require('node:test');
const assert = require('node:assert/strict');
const { createService, ValidationError } = require('../../src/services/scheduled_rules_service');
const { makeFakeDb } = require('./_helpers');

const HOME = '11111111-1111-4111-8111-111111111111';
const DEVICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const USER = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

// Esitleme sonrasi ev: 1-2 panjur cifti 1, 3-4 isik, 5-6 panjur cifti 3 (eskiden isikti), 7-8 isik.
const LAYOUT = Object.freeze([
  { channel_index: 1, type: 'shutter' },
  { channel_index: 2, type: 'shutter' },
  { channel_index: 3, type: 'light' },
  { channel_index: 4, type: 'light' },
  { channel_index: 5, type: 'shutter' },
  { channel_index: 6, type: 'shutter' },
  { channel_index: 7, type: 'light' },
  { channel_index: 8, type: 'light' },
]);

const DISABLED_RELAY_5 = Object.freeze({
  id: 5,
  home_id: HOME,
  device_id: null,
  channel: 5,
  channel_type: 'relay',
  action: 'on',
  hour: 7,
  minute: 0,
  days_of_week: [0, 1, 2, 3, 4, 5, 6],
  label: null,
  enabled: false, // esitleme kapatti
  created_by: USER,
});

function makeDb({ existing = DISABLED_RELAY_5, endpoints = LAYOUT, deviceInHome = true } = {}) {
  return makeFakeDb([
    { match: /^SELECT \* FROM scheduled_rules WHERE id = \$1 AND home_id = \$2 FOR UPDATE$/, reply: () => ({ rows: existing ? [{ ...existing }] : [] }) },
    { match: /^SELECT id FROM devices WHERE id = \$1 AND home_id = \$2$/, reply: () => ({ rows: deviceInHome ? [{ id: DEVICE }] : [] }) },
    { match: /FROM endpoints WHERE home_id = \$1/, reply: () => ({ rows: endpoints }) },
    {
      match: /WITH upd AS/,
      reply: (text, p) => ({ rows: [{ ...existing, enabled: true, id: p[p.length - 2], created_by_name: 'Ayse' }] }),
    },
  ]);
}

const updateCall = (db) => db.calls.find((c) => /WITH upd AS/.test(c.text));
const endpointCalls = (db) => db.calls.filter((c) => /FROM endpoints WHERE home_id = \$1/.test(c.text));

test('D3: kapali role kurali, kanali artik panjurken {enabled:true} ile ACILAMAZ (400 VALIDATION, guncelleme yok, geri alinir)', async () => {
  const db = makeDb();
  await assert.rejects(
    () => createService({ db }).updateRule(HOME, 5, { enabled: true }),
    (err) =>
      err instanceof ValidationError &&
      err.status === 400 &&
      err.code === 'VALIDATION' &&
      err.errors[0].field === 'channel' &&
      /Kanal 5 bir panjura ayrılmış/.test(err.errors[0].message)
  );
  assert.equal(updateCall(db), undefined, 'UPDATE calismamali');
  assert.deepEqual(db.txLog, ['BEGIN', 'ROLLBACK']);
  assert.equal(endpointCalls(db).length, 1);
  assert.deepEqual(endpointCalls(db)[0].params, [HOME, null], 'birlesik (kayitli) device_id ile sorgulanir');
});

test('D3: yeniden acarken eski kaydin device_id\'si kullanilir; cihaz artik evde degilse 400', async () => {
  const withDevice = { ...DISABLED_RELAY_5, channel: 3, device_id: DEVICE };
  const ok = makeDb({ existing: withDevice });
  await createService({ db: ok }).updateRule(HOME, 5, { enabled: true });
  assert.deepEqual(endpointCalls(ok)[0].params, [HOME, DEVICE]);
  assert.ok(updateCall(ok));

  const gone = makeDb({ existing: withDevice, deviceInHome: false });
  await assert.rejects(
    () => createService({ db: gone }).updateRule(HOME, 5, { enabled: true }),
    (err) => err instanceof ValidationError && err.errors[0].field === 'device_id'
  );
  assert.equal(updateCall(gone), undefined);
});

test('D3: yeniden acarken tip/eylem uyumu da denetlenir (bozuk kayit acilamaz)', async () => {
  const broken = { ...DISABLED_RELAY_5, channel: 1, channel_type: 'shutter', action: 'on' };
  const db = makeDb({ existing: broken });
  await assert.rejects(
    () => createService({ db }).updateRule(HOME, 5, { enabled: true }),
    (err) => err instanceof ValidationError && err.errors[0].field === 'action'
  );
  assert.equal(updateCall(db), undefined);
});

test('D3: uyumlu kapali kural (panjur cifti 3 / isik kanali) yeniden acilabilir ve son calisma sifirlanir', async () => {
  const shutter = { ...DISABLED_RELAY_5, channel: 3, channel_type: 'shutter', action: 'open' };
  const s = makeDb({ existing: shutter });
  const out = await createService({ db: s }).updateRule(HOME, 5, { enabled: true });
  assert.equal(out.enabled, true);
  assert.match(updateCall(s).text, /enabled = \$1, schedule_changed_at = CURRENT_TIMESTAMP, last_run_at = NULL/);

  const light = makeDb({ existing: { ...DISABLED_RELAY_5, channel: 7 } });
  await createService({ db: light }).updateRule(HOME, 5, { enabled: true });
  assert.ok(updateCall(light));
});

test('D3: yeniden acma + baska alan (etiket/saat) birlikte gelse de dogrulanir', async () => {
  const db = makeDb();
  await assert.rejects(() => createService({ db }).updateRule(HOME, 5, { enabled: true, label: 'Sabah', hour: 8 }), ValidationError);
  assert.equal(updateCall(db), undefined);
});

test('D3: KAPATMA her zaman dogrulamasiz serbest (uc nokta sorgusu bile yok)', async () => {
  const enabledBroken = { ...DISABLED_RELAY_5, enabled: true };
  const db = makeDb({ existing: enabledBroken });
  await createService({ db }).updateRule(HOME, 5, { enabled: false });
  assert.ok(updateCall(db));
  assert.equal(endpointCalls(db).length, 0);

  // Kapali kural kapaliyken etiket/saat duzenlemesi de dogrulamasiz (acilmiyor)
  const db2 = makeDb();
  await createService({ db: db2 }).updateRule(HOME, 5, { label: 'Not', hour: 9 });
  assert.ok(updateCall(db2));
  assert.equal(endpointCalls(db2).length, 0);
});

test('D3: zaten acik kurala {enabled:true} gecis degildir; dogrulama tetiklenmez', async () => {
  const db = makeDb({ existing: { ...DISABLED_RELAY_5, enabled: true } });
  await createService({ db }).updateRule(HOME, 5, { enabled: true });
  assert.ok(updateCall(db));
  assert.equal(endpointCalls(db).length, 0);
});
