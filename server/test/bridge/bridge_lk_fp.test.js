'use strict';

// pano-5 (f) + CONTRACTS 1: kopru state.lk_fp (firmware 1.3.1) alanini isler.
//  - yalniz /^[0-9a-f]{8}$/ gecerli (buyuk harf / uzunluk / tur disi -> atlanir, skipped++)
//  - yalniz CANLI (retained OLMAYAN) state: UPDATE devices SET local_key_fp, local_key_fp_at ... IS DISTINCT FROM
//    (COMMIT sonrasi, ana islemden AYRI; 037 oncesi 42703 sessizce atlanir, state islemesi bozulmaz)
//  - uzlastiriciya onLocalKeyFp({topicId, homeId, deviceId, fp, changed}) bildirilir (changed = satir degisti)
//  - lk_fp yoksa (eski firmware / provizyonsuz pano) ek sorgu ve bildirim YOK

const test = require('node:test');
const assert = require('node:assert/strict');
const { MqttBridge, helpers } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger } = require('./_helpers');

const HOME = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const DEV = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: 'AHBU-S3-1A2B3C' };
const FP_RE = /^UPDATE devices SET local_key_fp = \$2/;

function setup({ fpReply = { rows: [], rowCount: 1 } } = {}) {
  const db = makeFakeDb([
    { match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [DEV], rowCount: 1 } },
    { match: FP_RE, reply: () => fpReply },
  ]);
  const logger = makeLogger();
  const calls = [];
  const spy = { onLiveState() {}, onOffline() {}, onLocalKeyFp: (a) => calls.push(a), stop() {}, stats: () => ({}) };
  const bridge = new MqttBridge({ db, logger, env: {}, now: () => 1_700_000_000_000, reconciler: spy });
  return { bridge, db, logger, calls };
}

const send = (bridge, obj, retain = false) =>
  bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.from(JSON.stringify(obj)), { retain });
const state = (over = {}) => ({ v: 3, uid: 'AHBU-S3-1A2B3C', fw: '1.3.1', child_lock: false, relays: [{ id: 1, state: true }], ...over });

test('validateStatePayload: lk_fp yalniz 8 kucuk harf hex; aksi atlanir (skipped)', () => {
  const ok = helpers.validateStatePayload(state({ lk_fp: 'c7076562' }));
  assert.equal(ok.ok, true);
  assert.equal(ok.value.lkFp, 'c7076562');
  assert.equal(ok.value.skipped, 0);
  for (const bad of ['C7076562', 'c707656', 'c70765621', 'zz076562', 12345678, null, '']) {
    const r = helpers.validateStatePayload(state({ lk_fp: bad }));
    assert.equal(r.ok, true);
    assert.equal(r.value.lkFp, null, JSON.stringify(bad));
    assert.equal(r.value.skipped, 1, JSON.stringify(bad));
  }
  const none = helpers.validateStatePayload(state());
  assert.equal(none.value.lkFp, null);
  assert.equal(none.value.skipped, 0, 'alan yok = gecerli (eski firmware / provizyonsuz)');
});

test('canli state lk_fp -> iz yazilir (IS DISTINCT FROM) + uzlastirici onLocalKeyFp(changed:true)', async () => {
  const { bridge, db, calls } = setup();
  await send(bridge, state({ lk_fp: '9814f286' }));
  const w = db.find(FP_RE);
  assert.equal(w.length, 1);
  assert.match(w[0].text, /local_key_fp_at = CURRENT_TIMESTAMP/);
  assert.match(w[0].text, /WHERE id = \$1 AND local_key_fp IS DISTINCT FROM \$2/);
  assert.deepEqual(w[0].params, [DEV.device_id, '9814f286']);
  assert.equal(w[0].inTx, false, 'ana islemden ayri (COMMIT sonrasi)');
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
  assert.deepEqual(calls, [{ topicId: HOME, homeId: HOME_ID, deviceId: DEV.device_id, fp: '9814f286', changed: true }]);
  assert.equal(bridge.counters.dbErrors, 0);
});

test('iz degismediyse (rowCount 0) bildirim changed:false (uzlastirici bekleyen onay yoksa is yapmaz)', async () => {
  const { bridge, calls } = setup({ fpReply: { rows: [], rowCount: 0 } });
  await send(bridge, state({ lk_fp: '9814f286' }));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].changed, false);
});

test('retained state lk_fp ISLENMEZ (bayat olabilir); lk_fp yoksa ek sorgu/bildirim yok', async () => {
  const { bridge, db, calls } = setup();
  await send(bridge, state({ lk_fp: '9814f286' }), true);
  await send(bridge, state());
  await send(bridge, state({ lk_fp: 'BOZUK' }));
  assert.equal(db.find(FP_RE).length, 0);
  assert.deepEqual(calls, []);
});

test('037 oncesi (42703): state islemesi bozulmaz, hata sayilmaz, bildirim yok; uyari bir kez', async () => {
  const err = Object.assign(new Error('column "local_key_fp" does not exist'), { code: '42703' });
  const { bridge, db, logger, calls } = setup({ fpReply: err });
  await send(bridge, state({ lk_fp: '9814f286' }));
  await send(bridge, state({ lk_fp: '9814f286' }));
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT', 'BEGIN', 'COMMIT'], 'ana state yazimi surer');
  assert.equal(bridge.counters.dbErrors, 0);
  assert.deepEqual(calls, []);
  assert.equal(logger.lines.filter((l) => /local_key_fp/.test(l) || /037/.test(l)).length, 1);
});
