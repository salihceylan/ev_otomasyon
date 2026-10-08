'use strict';

// Faz 1 / IP-1.5 (+ bagimsiz inceleme 7-8): MQTT state `tpl {id, ver}` (firmware v1.3.0+, CONTRACTS §3e) ->
// devices.template_id / template_version / template_reported_at.
//   * Yazim ana state islemine KATILMAZ: COMMIT sonrasi ayri, hata yalitimli UPDATE (buildTemplateUpdate). Migration 035
//     uygulanmadan yeniden baslatilan surumde (42703/42P01) cevrimici durumu bozulmaz; tpl yazimi bir sure atlanir.
//   * Yalniz CANLI state. tpl'li state -> kolonlar yazilir (degisirse). tpl'siz state + fw >= 1.3.0 -> kolonlar NULL
//     (sablon yok); daha eski firmware (alan hic yok) -> dokunulmaz.

const test = require('node:test');
const assert = require('node:assert/strict');

const bridgeModule = require('../../src/mqtt_bridge');
const { validateStatePayload, buildDeviceUpdate, buildTemplateUpdate, fwAtLeast } = bridgeModule.helpers;
const { MqttBridge } = bridgeModule;

const TID = '3f2a9c1e-5b7d-4e8f-9a01-23456789abcd';
const parse = (o) => validateStatePayload({ uid: 'AHBU-S3-0001', ...o }).value;

test('validateStatePayload: gecerli tpl ayristirilir (id kucuk harfe)', () => {
  const r = validateStatePayload({ uid: 'AHBU-S3-0001', tpl: { id: TID.toUpperCase(), ver: 4 } });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.tpl, { id: TID, ver: 4 });
  assert.equal(r.value.skipped, 0);
});

test('validateStatePayload: tpl yok -> null; bozuk -> null + skipped', () => {
  assert.equal(validateStatePayload({ uid: 'AHBU-S3-0001' }).value.tpl, null);
  for (const bad of [{ id: 'x', ver: 1 }, { id: TID, ver: 0 }, { id: TID, ver: 1.5 }, { id: TID }, 'tpl', [TID, 1], null]) {
    const r = validateStatePayload({ uid: 'AHBU-S3-0001', tpl: bad });
    assert.equal(r.ok, true);
    assert.equal(r.value.tpl, null, JSON.stringify(bad));
    assert.equal(r.value.skipped, 1, JSON.stringify(bad));
  }
});

test('buildDeviceUpdate ana state SQL\'ine template_* KATMAZ (035 oncesi yeniden baslatma guvenli)', () => {
  const a = buildDeviceUpdate('dev-1', parse({ fw: '1.3.0', tpl: { id: TID, ver: 4 } }), true);
  const b = buildDeviceUpdate('dev-1', parse({ fw: '1.3.0' }), true);
  assert.doesNotMatch(a.text, /template_/);
  assert.deepEqual(a, b);
});

test('fwAtLeast: surum karsilastirmasi', () => {
  assert.equal(fwAtLeast('1.3.0', 1, 3, 0), true);
  assert.equal(fwAtLeast('1.3.1-rc1', 1, 3, 0), true);
  assert.equal(fwAtLeast('1.10.0', 1, 3, 0), true);
  assert.equal(fwAtLeast('2.0', 1, 3, 0), true);
  assert.equal(fwAtLeast('1.2.9', 1, 3, 0), false);
  assert.equal(fwAtLeast('v1.3.0', 1, 3, 0), false);
  assert.equal(fwAtLeast(null, 1, 3, 0), false);
});

test('buildTemplateUpdate: tpl -> yaz; fw>=1.3.0 tpl yok -> NULL; eski fw / retained -> yok', () => {
  const set = buildTemplateUpdate('dev-1', parse({ fw: '1.3.0', tpl: { id: TID, ver: 4 } }), true);
  assert.match(set.text, /^UPDATE devices SET template_id = \$2, template_version = \$3, template_reported_at = CURRENT_TIMESTAMP WHERE id = \$1 AND/);
  assert.match(set.text, /IS DISTINCT FROM/);
  assert.deepEqual(set.values, ['dev-1', TID, 4]);

  const clear = buildTemplateUpdate('dev-1', parse({ fw: '1.3.0' }), true);
  assert.match(clear.text, /SET template_id = NULL, template_version = NULL/);
  assert.match(clear.text, /template_id IS NOT NULL OR template_version IS NOT NULL/);
  assert.deepEqual(clear.values, ['dev-1']);

  assert.equal(buildTemplateUpdate('dev-1', parse({ fw: '1.2.1' }), true), null);
  assert.equal(buildTemplateUpdate('dev-1', parse({}), true), null);
  assert.equal(buildTemplateUpdate('dev-1', parse({ fw: '1.3.0', tpl: { id: TID, ver: 4 } }), false), null);
});

function fakeDb({ failTpl = null } = {}) {
  const log = [];
  const db = {
    log,
    async query(text, params) {
      log.push({ text, tx: false });
      if (text.startsWith('SELECT h.id AS home_id')) {
        return { rows: [{ home_id: 'home-1', child_lock_requested: null, device_id: 'dev-1', device_uuid: 'AHBU-S3-0001', has_caps: false, safety_state: null }] };
      }
      if (text.includes('template_')) {
        if (failTpl) throw Object.assign(new Error('column "template_id" does not exist'), { code: failTpl });
        return { rowCount: 1, rows: [] };
      }
      return { rowCount: 0, rows: [] };
    },
    async withTransaction(fn) {
      return fn({ query: async (text) => { log.push({ text, tx: true }); return { rowCount: 1, rows: [] }; } });
    },
  };
  return db;
}

const silent = { log() {}, warn() {}, error() {} };

test('_processState: tpl yazimi COMMIT sonrasi ayri sorgu; 42703 -> durum yine yazilir, tpl bir sure atlanir', async () => {
  let now = 1_000_000;
  const db = fakeDb({ failTpl: '42703' });
  const bridge = new MqttBridge({ db, logger: silent, now: () => now });
  const v = parse({ fw: '1.3.0', tpl: { id: TID, ver: 4 } });
  await bridge._processState('h_0123456789abcdef', v, false, null);
  const devUpd = db.log.find((l) => l.text.startsWith('UPDATE devices SET') && l.tx);
  assert.ok(devUpd, 'ana durum islemde yazildi');
  assert.doesNotMatch(devUpd.text, /template_/);
  const tplQ = db.log.filter((l) => l.text.includes('template_'));
  assert.equal(tplQ.length, 1);
  assert.equal(tplQ[0].tx, false, 'islem DISINDA');
  assert.equal(bridge.counters.dbErrors, 0, 'eksik kolon state hatasi sayilmaz');

  await bridge._processState('h_0123456789abcdef', v, false, null);
  assert.equal(db.log.filter((l) => l.text.includes('template_')).length, 1, 'geri cekilme suresince denenmez');
  now += 10 * 60 * 1000;
  await bridge._processState('h_0123456789abcdef', v, false, null);
  assert.equal(db.log.filter((l) => l.text.includes('template_')).length, 2, 'sure dolunca yeniden denenir');
});

test('_processState: fw 1.3.0 tpl yok -> temizleme sorgusu; fw 1.2.1 -> sorgu yok', async () => {
  const db = fakeDb();
  const bridge = new MqttBridge({ db, logger: silent });
  await bridge._processState('h_0123456789abcdef', parse({ fw: '1.3.0' }), false, null);
  assert.equal(db.log.filter((l) => l.text.includes('template_id = NULL')).length, 1);
  const db2 = fakeDb();
  const b2 = new MqttBridge({ db: db2, logger: silent });
  await b2._processState('h_0123456789abcdef', parse({ fw: '1.2.1' }), false, null);
  assert.equal(db2.log.filter((l) => l.text.includes('template_')).length, 0);
});
