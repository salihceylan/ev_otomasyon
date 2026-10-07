'use strict';

// WP-L - Kopru KANCASI (src/mqtt_bridge.js <-> src/services/endpoint_layout_sync.js).
//
// Gercek veritabani / broker YOKTUR. Iki duzenek:
//   * setup():     sahte db (test/bridge/_helpers.js) + casus `layoutSyncer` -> kopru ne zaman, neyle bildirir?
//   * setupReal(): sahte db + servisin bellek ici dunyasi (test/layout/_helpers.js) + GERCEK servis
//                  (`layoutSync: true`) -> servisin sorgulari veritabanina ulasir mi, ana yol ayni mi?
// Plan: docs/superpowers/plans/2026-10-03-uc-nokta-yerlesim-esitleme.md, Task 4 (Step 7).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const bridgeModule = require('../../src/mqtt_bridge');
const layoutModule = require('../../src/utils/endpoint_layout');
const syncModule = require('../../src/services/endpoint_layout_sync');
const { makeFakeDb, makeLogger } = require('../bridge/_helpers');
const { T0, fwState, makeWorld } = require('./_helpers');

const { MqttBridge, helpers } = bridgeModule;
const { SQL, EndpointLayoutSync } = syncModule;
const extractReportedLayout = layoutModule.extractReportedLayout; // ozgun islev (yamalanan testlerden bagimsiz)

const TOPIC = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const UID = 'AHBU-S3-A1B2C3'; // fwState() ile ayni
const DEV = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: UID };
const DEV_B = { home_id: HOME_ID, device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', device_uuid: 'AHBU-S3-0F0F0F' };
const RESOLVE_RE = /FROM homes h LEFT JOIN devices d/;
const SERVICE_TEXTS = new Set(Object.values(SQL));

const SHUTTER_56 = { 5: { type: 'shutter_up', name: 'Salon (Yukari)' }, 6: { type: 'shutter_down', name: 'Salon (Asagi)' } };

function makeSpy({ throws = null } = {}) {
  const spy = {
    calls: [],
    offline: [],
    stopped: 0,
    onLiveState(evt) {
      spy.calls.push(evt);
      if (throws) throw throws;
    },
    onOffline(topicId) {
      spy.offline.push(topicId);
      if (throws) throw throws;
    },
    stop() {
      spy.stopped += 1;
    },
    stats() {
      return { applied: 7, noops: 3 };
    },
  };
  return spy;
}

/** Sahte db + kopru. `opts` dogrudan MqttBridge kurucusuna gider (layoutSyncer / layoutSync / reconciler ...). */
function setup({ homeRows = [DEV], env = {}, ...opts } = {}) {
  const db = makeFakeDb([
    {
      match: RESOLVE_RE,
      reply: (_t, params) => (params[0] === TOPIC ? { rows: homeRows, rowCount: homeRows.length } : { rows: [], rowCount: 0 }),
    },
  ]);
  const logger = makeLogger();
  const bridge = new MqttBridge({ db, logger, env, now: () => T0, ...opts });
  return { bridge, db, logger };
}

/**
 * GERCEK servis icin birlesik db: servisin SQL metinleri bellek ici dunyaya, digerleri (kopru ana yolu) sahte db'ye
 * gider. Ana yol cagrilari `fake.calls`, servis cagrilari `w.calls` icinde birikir.
 */
function setupReal({ layoutSync = true, env = {}, rows = 8 } = {}) {
  const w = makeWorld(SQL);
  const d = { id: DEV.device_id, home_id: HOME_ID, device_uuid: UID, reported_layout: null };
  w.devices.set(d.id, d);
  if (rows > 0) w.seed(d, rows);
  const fake = makeFakeDb([{ match: RESOLVE_RE, reply: { rows: [DEV], rowCount: 1 } }]);
  const pick = (text, a, b) => (SERVICE_TEXTS.has(text) ? a : b);
  const db = {
    query: (text, params) => pick(text, w.db, fake).query(text, params),
    withTransaction: (fn) =>
      w.db.withTransaction((wtx) =>
        fake.withTransaction((ftx) => fn({ query: (text, params) => pick(text, wtx, ftx).query(text, params) }))
      ),
  };
  const logger = makeLogger();
  const bridge = new MqttBridge({ db, logger, env, now: () => w.now, layoutSync });
  return { w, d, fake, db, logger, bridge };
}

const send = (bridge, obj, retain = false, topic = TOPIC) =>
  bridge.handleIncomingMessage(`ev/${topic}/state`, Buffer.from(JSON.stringify(obj)), { retain });
const trace = (db) => db.calls.map((c) => ({ text: c.text, params: c.params, inTx: c.inTx }));
const writes = (db) => db.calls.filter((c) => /^UPDATE /.test(c.text));
const serviceCalls = (db) => db.calls.filter((c) => SERVICE_TEXTS.has(c.text));
const warnings = (logger) => logger.lines.filter((l) => l.startsWith('warn:'));
const tick = () => new Promise((resolve) => setImmediate(resolve));

/** Bir modul disa aktarimini test suresince degistirir (kopru bu islevleri TEMBEL ve cagri aninda okur). */
async function withPatched(target, key, value, fn) {
  const original = target[key];
  target[key] = value;
  try {
    return await fn();
  } finally {
    target[key] = original;
  }
}

/** extractReportedLayout cagri sayaci (ozgun davranisi korur). */
function countingExtractor() {
  const counter = { calls: 0 };
  counter.fn = (obj) => {
    counter.calls += 1;
    return extractReportedLayout(obj);
  };
  return counter;
}

// ------------------------------------------------------------------------------
// Bildirim: yalniz CANLI + gecerli yerlesim + cozulmus cihaz + basarili transaction
// ------------------------------------------------------------------------------
test('canli state + gecerli yerlesim: onLiveState BIR kez, dogru topicId / homeId / deviceId / layout ile', async () => {
  const spy = makeSpy();
  const { bridge, db } = setup({ layoutSyncer: spy });
  const payload = fwState();
  await send(bridge, payload);

  assert.equal(spy.calls.length, 1);
  const evt = spy.calls[0];
  assert.deepEqual(Object.keys(evt).sort(), ['deviceId', 'homeId', 'layout', 'topicId']);
  assert.equal(evt.topicId, TOPIC);
  assert.equal(evt.homeId, HOME_ID);
  assert.equal(evt.deviceId, DEV.device_id);
  assert.equal(evt.layout.count, 8);
  assert.deepEqual(evt.layout.pairs, [1, 2]);
  assert.deepEqual(evt.layout, extractReportedLayout(payload), 'yerlesim HAM yukten extractReportedLayout ile cikarilir');
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
  assert.equal(bridge.counters.state, 1);
  assert.equal(bridge.counters.dbErrors, 0);
});

test('bildirim COMMIT edildikten SONRA ve uzlastirici bildiriminden SONRA yapilir', async () => {
  const order = [];
  let txAtNotify = null;
  const layoutSyncer = {
    onLiveState() {
      order.push('layout');
      txAtNotify = [...ctx.db.txLog];
    },
    stop() {},
    stats: () => ({}),
  };
  const reconciler = { onLiveState: () => order.push('reconcile'), onOffline() {}, stop() {}, stats: () => ({}) };
  const ctx = setup({ layoutSyncer, reconciler });
  await send(ctx.bridge, fwState());
  assert.deepEqual(order, ['reconcile', 'layout']);
  assert.deepEqual(txAtNotify, ['BEGIN', 'COMMIT'], 'bildirim aninda durum guncellemesi COMMIT edilmis olmali');
});

test('RETAINED state: bildirim YOK (bayat yerlesim satir degistirmez); durum guncellemesi yine yapilir', async () => {
  const spy = makeSpy();
  const { bridge, db } = setup({ layoutSyncer: spy });
  await send(bridge, fwState({ set: SHUTTER_56 }), true);
  assert.equal(spy.calls.length, 0);
  assert.equal(bridge.counters.retained, 1);
  assert.ok(writes(db).some((c) => /UPDATE endpoints e SET current_state/.test(c.text)), 'role durumu yazilmali');
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
});

test('_processState: retain=true iken yerlesim verilse bile bildirim YOK; retain=false iken VAR', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy });
  const payload = fwState();
  const value = helpers.validateStatePayload(payload).value;
  const layout = extractReportedLayout(payload);
  await bridge._processState(TOPIC, value, true, layout);
  assert.equal(spy.calls.length, 0, 'retained: bildirim olmamali');
  await bridge._processState(TOPIC, value, false, layout);
  assert.equal(spy.calls.length, 1);
  assert.equal(spy.calls[0].layout, layout);
  await bridge._processState(TOPIC, value, false);
  assert.equal(spy.calls.length, 1, '4. parametre verilmezse (varsayilan null) bildirim olmamali');
});

test('yerlesimsiz / bozuk yuk: bildirim YOK ama durum guncellemesi yine yapilir', async () => {
  const cases = {
    'tip alani yok (eski yazilim)': { v: 2, uid: UID, relays: [{ id: 1, state: true }, { id: 2, state: false }], shutters: [] },
    'yetim panjur rolesi': fwState({ set: { 2: { type: 'light' } } }),
    'ters cift': fwState({ set: { 1: { type: 'shutter_down' }, 2: { type: 'shutter_up' } } }),
    'bilinmeyen tip (shutter)': fwState({ set: { 5: { type: 'shutter' } } }),
    'v: 1': fwState({ v: 1 }),
    'shutters[] tiplerle uyusmuyor': { ...fwState(), shutters: [{ pair: 1, pos: 0 }] },
    'boslluklu id': { v: 2, uid: UID, relays: [1, 2, 4].map((id) => ({ id, type: 'light', state: false })), shutters: [] },
  };
  for (const [name, payload] of Object.entries(cases)) {
    const spy = makeSpy();
    const { bridge, db } = setup({ layoutSyncer: spy });
    await send(bridge, payload);
    assert.equal(spy.calls.length, 0, `${name}: bildirim olmamali`);
    assert.equal(bridge.counters.state, 1, `${name}: state sayilmali`);
    assert.equal(bridge.counters.invalid, 0, `${name}: yuk gecersiz sayilmamali`);
    assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT'], `${name}: durum transaction'i calismali`);
    assert.ok(writes(db).some((c) => /UPDATE endpoints e SET current_state/.test(c.text)), `${name}: role durumu yazilmali`);
    assert.ok(writes(db).some((c) => /^UPDATE devices SET/.test(c.text) && /is_online = TRUE/.test(c.text)), `${name}: cihaz cevrimici`);
  }
});

test('cihaz cozulemezse bildirim YOK: bilinmeyen uid, bilinmeyen ev konusu, belirsiz cihaz, cihazsiz ev', async () => {
  const { uid: _uid, ...noUid } = fwState();
  const cases = [
    { name: 'bilinmeyen uid', payload: { ...fwState(), uid: 'AHBU-S3-FFFFFF' }, homeRows: [DEV] },
    { name: 'bilinmeyen ev konusu', payload: fwState(), homeRows: [DEV], topic: 'h_baska' },
    { name: 'iki cihaz, uid yok', payload: noUid, homeRows: [DEV, DEV_B] },
    { name: 'cihazsiz ev', payload: noUid, homeRows: [{ home_id: HOME_ID, device_id: null, device_uuid: null }] },
  ];
  for (const c of cases) {
    const spy = makeSpy();
    const { bridge, db } = setup({ layoutSyncer: spy, homeRows: c.homeRows });
    await send(bridge, c.payload, false, c.topic || TOPIC);
    assert.equal(spy.calls.length, 0, `${c.name}: bildirim olmamali`);
    assert.equal(bridge.counters.ignored, 1, `${c.name}: yok sayilmali`);
    assert.deepEqual(db.txLog, [], `${c.name}: yazma olmamali`);
  }
});

test('iki cihazli evde bildirim uid ile eslesen cihaz icin yapilir', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy, homeRows: [DEV_B, DEV] });
  await send(bridge, fwState());
  assert.equal(spy.calls.length, 1);
  assert.equal(spy.calls[0].deviceId, DEV.device_id);
});

test('durum transaction\'i BASARISIZ olursa bildirim YOK', async () => {
  const spy = makeSpy();
  const { bridge, db } = setup({ layoutSyncer: spy });
  db.addRule({ match: /^UPDATE devices SET/, reply: new Error('baglanti koptu') });
  await send(bridge, fwState());
  assert.deepEqual(db.txLog, ['BEGIN', 'ROLLBACK']);
  assert.equal(bridge.counters.dbErrors, 1);
  assert.equal(spy.calls.length, 0);
});

test('erken donus kancayi atlamaz: en kucuk canli yukte de (uid/ip/fw/kilit yok) deviceUpdate dolu ve bildirim VAR', async () => {
  const payload = { v: 2, relays: [{ id: 1, type: 'light', state: false }], shutters: [] };
  const value = helpers.validateStatePayload(payload).value;
  assert.notEqual(helpers.buildDeviceUpdate(DEV.device_id, value, true), null, 'canli state her zaman cihaz satirini yazar');
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy });
  await send(bridge, payload);
  assert.equal(spy.calls.length, 1);
  assert.equal(spy.calls[0].layout.count, 1);
});

test('status mesaji yerlesim bildirimi uretmez', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('online'), { retain: false });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('offline'), { retain: false });
  assert.equal(spy.calls.length, 0);
});

test('CANLI status offline (LWT) -> servise onOffline(topicId); online ve RETAINED offline -> cagrilmaz', async () => {
  const spy = makeSpy();
  const { bridge, db } = setup({ layoutSyncer: spy });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('online'), { retain: false });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('offline'), { retain: true }); // bayat retained
  assert.deepEqual(spy.offline, [], 'online / retained offline cevrimici donemi bitirmez');
  await bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('offline'), { retain: false });
  assert.deepEqual(spy.offline, [TOPIC]);
  // durum guncellemesi her uc mesajda da yapildi (ana yol degismedi)
  assert.equal(db.calls.filter((c) => /^UPDATE devices d/.test(c.text)).length, 3);
});

test('onOffline PATLARSA kopru etkilenmez; esitleme kapali kopru (servis yok) offline\'da hicbir sey yapmaz', async () => {
  const spy = makeSpy({ throws: new Error('servis patladi') });
  const { bridge, db, logger } = setup({ layoutSyncer: spy });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('offline'), { retain: false });
  assert.deepEqual(spy.offline, [TOPIC]);
  assert.equal(db.calls.filter((c) => /^UPDATE devices d/.test(c.text)).length, 1);
  assert.equal(bridge.counters.dbErrors, 0);
  assert.ok(warnings(logger).some((l) => /Yerlesim esitleme bildirimi hatasi/.test(l)));
  assert.ok(!warnings(logger).some((l) => /servis patladi/.test(l)), 'hata iletisi gunluge yazilmaz');

  const off = setup();
  await off.bridge.handleIncomingMessage(`ev/${TOPIC}/status`, Buffer.from('offline'), { retain: false });
  assert.equal(off.bridge._layoutSync, null);
  assert.equal(off.db.calls.filter((c) => /^UPDATE devices d/.test(c.text)).length, 1);
});

test('kuyruk birlestirmesi: bekleyen eski state atilinca EN YENI mesajin yerlesimi bildirilir', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy });
  const first = fwState();
  const middle = fwState({ set: { 6: { name: 'Mutfak Spot' } } });
  const last = fwState({ set: { 6: { name: 'Mutfak Tezgah' } } });
  // 1. is hemen baslar; 2. bekler; 3. ayni turdeki bekleyen 2. isin yerine gecer.
  await Promise.all([send(bridge, first), send(bridge, middle), send(bridge, last)]);
  assert.equal(bridge.getStatus().counters.queue.coalesced, 1);
  assert.deepEqual(
    spy.calls.map((c) => c.layout.signature),
    [extractReportedLayout(first).signature, extractReportedLayout(last).signature]
  );
});

// ------------------------------------------------------------------------------
// Hata yalitimi
// ------------------------------------------------------------------------------
test('onLiveState PATLARSA kopru etkilenmez: sayaclar / veritabani yazimi ayni, sonraki mesaj islenir', async () => {
  const spy = makeSpy({ throws: new Error('gizli-ileti Mutfak Spot') });
  const { bridge, db, logger } = setup({ layoutSyncer: spy });
  await send(bridge, fwState());
  await send(bridge, fwState({ set: { 5: { name: 'Salon Avize' } } }));

  assert.equal(spy.calls.length, 2, 'ikinci mesajda da bildirim denenir');
  assert.equal(bridge.counters.dbErrors, 0, 'esitleme hatasi veritabani hatasi sayilmaz');
  assert.equal(bridge.counters.state, 2);
  assert.equal(bridge.counters.invalid, 0);
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT', 'BEGIN', 'COMMIT']);
  const warns = warnings(logger).filter((l) => /Yerlesim esitleme bildirimi hatasi/.test(l));
  assert.equal(warns.length, 1, 'tek uyari satiri (_warnOnce)');
  const all = logger.lines.join('\n');
  assert.doesNotMatch(all, /gizli-ileti|Mutfak Spot|Salon Avize/, 'gunluge hata iletisi / ad yazilmaz');
  assert.equal(all.includes(TOPIC), false, 'gunluge konu kimligi yazilmaz');
  assert.equal(all.includes(UID), false, 'gunluge uid yazilmaz');
});

test('cikarici PATLARSA ana state yolu etkilenmez; bildirim yapilmaz', async () => {
  const spy = makeSpy();
  const { bridge, db, logger } = setup({ layoutSyncer: spy });
  const boom = () => {
    throw new Error('cikarici patladi');
  };
  await withPatched(layoutModule, 'extractReportedLayout', boom, () => send(bridge, fwState()));
  assert.equal(spy.calls.length, 0);
  assert.equal(bridge.counters.state, 1);
  assert.equal(bridge.counters.dbErrors, 0);
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT'], 'durum guncellemesi yine yapilmali');
  assert.equal(warnings(logger).filter((l) => /Yerlesim cikarma hatasi/.test(l)).length, 1);
});

test('servis yuklenemezse / kurulamazsa kopru etkilenmez; bir kez uyarir ve yeniden denemez', async () => {
  const { bridge, db, logger } = setup({ layoutSync: true });
  let attempts = 0;
  const failing = () => {
    attempts += 1;
    throw new TypeError('kurulamadi');
  };
  const counter = countingExtractor();
  await withPatched(syncModule, 'createEndpointLayoutSync', failing, () =>
    withPatched(layoutModule, 'extractReportedLayout', counter.fn, async () => {
      await send(bridge, fwState());
      await send(bridge, fwState());
    })
  );
  assert.equal(attempts, 1, 'yuklenemeyen servis her mesajda yeniden denenmez');
  assert.equal(counter.calls, 0, 'servis yokken yerlesim cikarilmaz');
  assert.equal(bridge._layoutSync, null);
  assert.equal(bridge._layoutSyncEnabled, false);
  assert.equal(bridge.counters.state, 2);
  assert.equal(bridge.counters.dbErrors, 0);
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT', 'BEGIN', 'COMMIT']);
  assert.equal(warnings(logger).filter((l) => /Yerlesim esitleme baslatilamadi/.test(l)).length, 1);
  assert.equal('layout_sync' in bridge.getStatus(), false);
});

// ------------------------------------------------------------------------------
// Varsayilan KAPALI + ana yol degismez
// ------------------------------------------------------------------------------
test('varsayilan KAPALI: layoutSync / layoutSyncer verilmeyen kopru yerlesim CIKARMAZ, servis KURMAZ, ek sorgu URETMEZ', async () => {
  const counter = countingExtractor();
  let created = 0;
  const realCreate = syncModule.createEndpointLayoutSync;
  const countingCreate = (deps) => {
    created += 1;
    return realCreate(deps);
  };
  const { bridge, db } = setup();
  await withPatched(syncModule, 'createEndpointLayoutSync', countingCreate, () =>
    withPatched(layoutModule, 'extractReportedLayout', counter.fn, async () => {
      await send(bridge, fwState({ set: SHUTTER_56 }));
      await send(bridge, fwState({ set: SHUTTER_56 }), true);
    })
  );
  assert.equal(counter.calls, 0, 'extractReportedLayout cagrilmamali');
  assert.equal(created, 0, 'servis olusturulmamali');
  assert.equal(bridge._layoutSyncEnabled, false);
  assert.equal(bridge._layoutSync, null);
  assert.equal(serviceCalls(db).length, 0);
  assert.equal('layout_sync' in bridge.getStatus(), false);
  for (const flag of [false, undefined, null, 'true', 1]) {
    assert.equal(new MqttBridge({ env: {}, layoutSync: flag })._layoutSyncEnabled, false, `layoutSync: ${String(flag)}`);
  }
});

test('ana yol DEGISMEZ: esitleme kapali ve acik (casus) koprulerde sorgu metni / parametresi / sirasi / transaction ayni', async () => {
  const off = setup();
  const on = setup({ layoutSyncer: makeSpy() });
  const messages = [
    [fwState({ set: SHUTTER_56, pos: { 1: 40, 3: 70 } }), false],
    [{ ...fwState(), child_lock: true, fw: '1.1.0', ip: '192.168.1.30', last_id: 'cmd-9' }, false],
    [fwState({ count: 16 }), true],
    [{ ...fwState(), child_lock: false }, true],
  ];
  for (const [payload, retain] of messages) {
    await send(off.bridge, payload, retain);
    await send(on.bridge, payload, retain);
  }
  assert.ok(trace(off.db).length >= 12, 'karsilastirma bos olmamali');
  assert.deepEqual(trace(on.db), trace(off.db));
  assert.deepEqual(on.db.txLog, off.db.txLog);
  assert.deepEqual(on.bridge.counters, off.bridge.counters);

  // Sabit taban: canli tam yuk = RESOLVE + (cihaz + role + panjur + ev kilidi) -> 5 sorgu, 1 transaction.
  const base = setup({ layoutSyncer: makeSpy() });
  await send(base.bridge, { ...fwState(), child_lock: false });
  assert.equal(base.db.calls.length, 5);
  assert.deepEqual(base.db.calls.map((c) => c.inTx), [false, true, true, true, true]);
  assert.deepEqual(base.db.txLog, ['BEGIN', 'COMMIT']);
});

// ------------------------------------------------------------------------------
// GERCEK servis ile birlesik
// ------------------------------------------------------------------------------
test('gercek servis (layoutSync: true): canli state -> servisin sorgulari veritabanina ulasir, satirlar esitlenir', async () => {
  const { w, d, bridge, logger } = setupReal();
  assert.equal(bridge._layoutSync, null, 'servis tembel olusturulur (ilk state mesajinda)');

  await send(bridge, fwState());
  const svc = bridge._layoutSync;
  assert.ok(svc instanceof EndpointLayoutSync);
  assert.equal(await svc.whenIdle(2000), true);
  // Varsayilan pano + tohum satirlari: satir degismez, yalniz taban yazilir.
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'saveBase']);
  assert.equal(w.audits.length, 0);
  assert.notEqual(d.reported_layout, null);

  w.now += syncModule.constants.MIN_RUN_INTERVAL_MS + 1;
  const before = w.calls.length;
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(await svc.whenIdle(2000), true);
  assert.deepEqual(w.names(before), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'updateRow', 'updateRow', 'disableRules', 'saveBase', 'audit']);
  for (const channel of [5, 6]) {
    const row = w.row(d, channel);
    assert.equal(row.type, 'shutter', `kanal ${channel}`);
    assert.equal(row.shutter_pair_index, 3);
    assert.equal(row.shutter_duration_sec, 20);
    assert.equal(row.id, `ep-${d.id.slice(0, 4)}-${channel}`, 'satir yerinde guncellenir (kimlik korunur)');
  }
  assert.equal(w.row(d, 5).name, 'Salon (Yukari)');
  assert.equal(w.audits.length, 1);
  assert.equal(w.audits[0].event, 'endpoint_layout_synced');

  const st = bridge.getStatus();
  assert.equal(st.layout_sync.applied, 2);
  assert.equal(st.layout_sync.retyped, 2);
  assert.equal(st.layout_sync.errors, 0);
  assert.equal(st.layout_sync.devices, 1);
  assert.equal(bridge._layoutSync, svc, 'ayni ornek yeniden kullanilir');
  assert.equal(bridge.counters.dbErrors, 0);
  assert.ok(logger.lines.some((l) => /\[LAYOUT\] cihaz=aaaaaaaa ev=11111111 .*tip=2/.test(l)));
});

test('gercek servis: RETAINED state esitlemez; ayni canli yerlesim ikinci kez sifir servis sorgusu', async () => {
  const { w, d, bridge } = setupReal();
  await send(bridge, fwState({ set: SHUTTER_56 }), true);
  if (bridge._layoutSync) assert.equal(await bridge._layoutSync.whenIdle(2000), true);
  assert.equal(w.calls.length, 0, 'retained: servis sorgusu olmamali');
  assert.equal(w.row(d, 5).type, 'light');
  assert.equal(d.reported_layout, null);

  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(await bridge._layoutSync.whenIdle(2000), true);
  assert.equal(w.row(d, 5).type, 'shutter');
  const after = w.calls.length;
  assert.ok(after > 0);

  w.now += 30 * 1000; // sonraki kalp atisi
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(await bridge._layoutSync.whenIdle(2000), true);
  assert.equal(w.calls.length, after, 'imza degismedi: hicbir servis sorgusu yok');
});

test('gercek servis ACIK iken de ana yol sorgulari (metin / parametre / sira) kapali kopruyle birebir ayni', async () => {
  const on = setupReal({ layoutSync: true });
  const off = setupReal({ layoutSync: false });
  const messages = [
    [fwState(), false],
    [fwState({ set: SHUTTER_56, pos: { 3: 55 } }), false],
    [fwState({ count: 16 }), true],
    [{ ...fwState({ count: 16 }), child_lock: true }, false],
  ];
  for (const [payload, retain] of messages) {
    for (const ctx of [on, off]) {
      ctx.w.now += 10 * 1000;
      await send(ctx.bridge, payload, retain);
      if (ctx.bridge._layoutSync) assert.equal(await ctx.bridge._layoutSync.whenIdle(2000), true);
    }
  }
  assert.ok(on.w.calls.length > 0, 'acik koprude servis calismis olmali');
  assert.equal(off.w.calls.length, 0, 'kapali koprude servis sorgusu yok');
  assert.equal(off.bridge._layoutSync, null);
  assert.ok(trace(off.fake).length >= 12);
  assert.deepEqual(trace(on.fake), trace(off.fake));
  assert.deepEqual(on.bridge.counters, off.bridge.counters);
  assert.equal(on.w.rowsOf(on.d).length, 16, 'ek modul satirlari acildi');
  assert.equal(off.w.rowsOf(off.d).length, 8);
});

test('gercek servis: servis veritabani hatasi kopru sayaclarini / ana yolu etkilemez', async () => {
  const { w, bridge } = setupReal();
  const failure = Object.assign(new Error('deadlock'), { code: '40P01' });
  w.failWhen = (text) => (SERVICE_TEXTS.has(text) ? failure : null);
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(await bridge._layoutSync.whenIdle(2000), true);
  assert.equal(bridge.counters.dbErrors, 0);
  assert.equal(bridge.counters.state, 1);
  assert.equal(bridge.getStatus().layout_sync.errors, 1);
});

// ------------------------------------------------------------------------------
// Kapatma anahtari
// ------------------------------------------------------------------------------
test('ENDPOINT_LAYOUT_SYNC = off / 0 / false (harf duyarsiz, bosluk kirpilmis): servis OLUSTURULMAZ, yerlesim cikarilmaz', async () => {
  for (const value of ['off', 'OFF', ' Off ', '0', 'false', 'FALSE', ' false\n', '\toff']) {
    const counter = countingExtractor();
    const { bridge, db } = setup({ layoutSync: true, env: { ENDPOINT_LAYOUT_SYNC: value } });
    await withPatched(layoutModule, 'extractReportedLayout', counter.fn, () => send(bridge, fwState({ set: SHUTTER_56 })));
    const label = JSON.stringify(value);
    assert.equal(bridge._layoutSync, null, `${label}: servis olusmamali`);
    assert.equal(counter.calls, 0, `${label}: yerlesim cikarilmamali`);
    assert.equal(serviceCalls(db).length, 0, `${label}: servis sorgusu olmamali`);
    assert.equal('layout_sync' in bridge.getStatus(), false, label);
    assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT'], `${label}: ana yol calismali`);
    assert.equal(bridge.counters.dbErrors, 0, label);
  }
});

test('ENDPOINT_LAYOUT_SYNC baska bir degerse ya da tanimsizsa servis olusturulur (varsayilan ACIK)', async () => {
  for (const value of [undefined, '', 'on', '1', 'true', 'offf', 'no']) {
    const env = value === undefined ? {} : { ENDPOINT_LAYOUT_SYNC: value };
    const { bridge, db } = setup({ layoutSync: true, env });
    await send(bridge, fwState());
    const label = JSON.stringify(value);
    assert.ok(bridge._layoutSync instanceof EndpointLayoutSync, `${label}: servis olusmali`);
    assert.equal(await bridge._layoutSync.whenIdle(2000), true);
    assert.equal(db.calls.filter((c) => c.text === SQL.device).length, 1, `${label}: servis sorgusu veritabanina ulasmali`);
  }
});

test('ENDPOINT_LAYOUT_SYNC=off enjekte edilen layoutSyncer\'i ETKILEMEZ', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy, env: { ENDPOINT_LAYOUT_SYNC: 'off' } });
  await send(bridge, fwState());
  assert.equal(spy.calls.length, 1);
  assert.deepEqual(bridge.getStatus().layout_sync, { applied: 7, noops: 3 });
});

// ------------------------------------------------------------------------------
// getStatus / end
// ------------------------------------------------------------------------------
test('getStatus().layout_sync = servis stats(); servis yoksa alan yok; stats patlarsa durum yine doner', async () => {
  const spy = makeSpy();
  const on = setup({ layoutSyncer: spy });
  assert.deepEqual(on.bridge.getStatus().layout_sync, { applied: 7, noops: 3 });

  const lazy = setup({ layoutSync: true });
  assert.equal('layout_sync' in lazy.bridge.getStatus(), false, 'tembel servis henuz kurulmadi');
  await send(lazy.bridge, fwState());
  assert.equal(await lazy.bridge._layoutSync.whenIdle(2000), true);
  const stats = lazy.bridge.getStatus().layout_sync;
  assert.equal(stats.checks, 1);
  assert.deepEqual(Object.keys(stats).sort(), Object.keys(lazy.bridge._layoutSync.stats()).sort());

  const broken = setup({ layoutSyncer: { onLiveState() {}, stop() {}, stats() { throw new Error('x'); } } });
  const st = broken.bridge.getStatus();
  assert.equal('layout_sync' in st, false);
  assert.equal(st.connected, false);
  assert.ok(st.counters);
});

test('end(): enjekte servis durdurulur ama ATILMAZ; stop patlasa da kapanis tamamlanir', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy });
  await send(bridge, fwState());
  await bridge.end();
  assert.equal(spy.stopped, 1);
  assert.equal(bridge._layoutSync, spy, 'enjekte ornegi test sahibi yonetir');

  const broken = setup({ layoutSyncer: { onLiveState() {}, stats: () => ({}), stop() { throw new Error('x'); } } });
  await broken.bridge.end(); // firlatmamali
});

test('end(): tembel olusturulan servis durdurulur ve atilir; end() sonrasi mesaj servis KURMAZ, init() sonrasi TAZE ornek kurulur', async () => {
  const { bridge, db } = setup({ layoutSync: true });
  await send(bridge, fwState());
  const first = bridge._layoutSync;
  assert.ok(first instanceof EndpointLayoutSync);
  assert.equal(await first.whenIdle(2000), true);

  await bridge.end();
  assert.equal(bridge._layoutSync, null, 'ornek atilmali');
  assert.equal(first._stopped, true, 'stop() cagrilmis olmali');
  assert.deepEqual(await first.syncNow({ homeId: HOME_ID, deviceId: DEV.device_id, layout: extractReportedLayout(fwState()) }), {
    status: 'skipped',
    reason: 'stopped',
  });
  assert.equal('layout_sync' in bridge.getStatus(), false);

  // D11: kapanmis kopruye gec teslim edilen mesaj servisi YENIDEN kurmaz
  const before = db.calls.filter((c) => c.text === SQL.device).length;
  await send(bridge, fwState());
  await tick();
  assert.equal(bridge._layoutSync, null, 'end() sonrasi servis kurulmamali');
  assert.equal(db.calls.filter((c) => c.text === SQL.device).length, before, 'servis sorgusu yok');

  // init() bayragi sifirlar (kimlik yoksa baglanmaz ama kopru yeniden acilmis sayilir)
  bridge.init();
  await send(bridge, fwState());
  const second = bridge._layoutSync;
  assert.ok(second instanceof EndpointLayoutSync);
  assert.notEqual(second, first, 'taze (durdurulmamis) ornek');
  assert.equal(await second.whenIdle(2000), true);
  assert.equal(db.calls.filter((c) => c.text === SQL.device).length, before + 1, 'taze ornek calisir');
});

test('end(): kapanis sirasinda BASLAMIS state isi bitince yeni servis kurulmaz, servis sorgusu yapilmaz', async () => {
  const { bridge, db } = setup({ layoutSync: true });
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  db.addRule({ match: RESOLVE_RE, reply: () => gate.then(() => ({ rows: [DEV], rowCount: 1 })) });
  const pending = send(bridge, fwState({ set: SHUTTER_56 }));
  await tick();
  const first = bridge._layoutSync;
  assert.ok(first instanceof EndpointLayoutSync, 'servis mesaj alindiginda kurulur');

  await bridge.end();
  release();
  await pending;
  await tick();
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT'], 'baslamis is yarida kesilmez');
  assert.equal(bridge._layoutSync, null, 'kapanmis kopru yeni servis kurmamali');
  assert.equal(first.stats().checks, 0);
  assert.equal(serviceCalls(db).length, 0);
});

test('D11 end() kapanis bayragi: _getLayoutSync / _extractLayout null; cikarici cagrilmaz; init() bayragi sifirlar', async () => {
  const { bridge, db } = setup({ layoutSync: true });
  await bridge.end();
  assert.equal(bridge._getLayoutSync(), null);
  assert.equal(bridge._extractLayout(fwState({ set: SHUTTER_56 })), null);
  assert.equal(bridge._layoutSync, null, 'kapanmis kopru servis kurmaz');

  const counter = countingExtractor();
  await withPatched(layoutModule, 'extractReportedLayout', counter.fn, async () => {
    await send(bridge, fwState({ set: SHUTTER_56 }));
    await tick();
    assert.equal(counter.calls, 0, 'kapanmis koprude cikarici calismaz');
    assert.equal(bridge._layoutSync, null);
    assert.equal(serviceCalls(db).length, 0);
    assert.ok(db.calls.some((c) => RESOLVE_RE.test(c.text)), 'koprunun kendi state yolu (onceden var olan davranis) surer');

    bridge.init(); // kimlik yok: baglanmaz ama bayrak sifirlanir
    await send(bridge, fwState({ set: SHUTTER_56 }));
    assert.equal(counter.calls, 1, 'init() sonrasi cikarici calisir');
    assert.ok(bridge._layoutSync instanceof EndpointLayoutSync, 'init() sonrasi servis kurulur');
    assert.equal(await bridge._layoutSync.whenIdle(2000), true);
  });
});

test('D11 enjekte servis: end() sonrasi kopru ona yerlesim iletmez (cikarici null); init() sonrasi yine iletir', async () => {
  const spy = makeSpy();
  const { bridge } = setup({ layoutSyncer: spy });
  await bridge.end();
  assert.equal(bridge._getLayoutSync(), null);
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(spy.calls.length, 0, 'kapanmis koprude yerlesim bildirimi yok');
  bridge.init();
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(spy.calls.length, 1);
});

// ------------------------------------------------------------------------------
// D6 - invalidateLayout(deviceId): genel, en iyi caba, ASLA firlatmaz, servis KURMAZ
// ------------------------------------------------------------------------------
test('D6 invalidateLayout: mevcut servisin invalidate(deviceId) metoduna iletir', () => {
  const spy = makeSpy();
  spy.invalidated = [];
  spy.invalidate = (id) => spy.invalidated.push(id);
  const { bridge } = setup({ layoutSyncer: spy });
  assert.equal(bridge.invalidateLayout(DEV.device_id), undefined);
  assert.deepEqual(spy.invalidated, [DEV.device_id]);
});

test('D6 invalidateLayout: servis yoksa no-op (servis KURULMAZ); metot yoksa / patlarsa / kapali koprude FIRLATMAZ', async () => {
  const lazy = setup({ layoutSync: true });
  lazy.bridge.invalidateLayout(DEV.device_id);
  assert.equal(lazy.bridge._layoutSync, null, 'yalniz onbellek icin servis kurulmaz');
  assert.equal(lazy.db.calls.length, 0);

  const off = setup();
  off.bridge.invalidateLayout(DEV.device_id);
  assert.equal(off.bridge._layoutSync, null);

  const noMethod = setup({ layoutSyncer: makeSpy() });
  noMethod.bridge.invalidateLayout(DEV.device_id);

  const { bridge, logger } = setup({
    layoutSyncer: { ...makeSpy(), invalidate() { throw new Error('onbellek patladi AHBU-S3-A1B2C3'); } },
  });
  assert.doesNotThrow(() => bridge.invalidateLayout(DEV.device_id));
  assert.doesNotThrow(() => bridge.invalidateLayout(undefined));
  assert.ok(!logger.lines.some((l) => /AHBU-S3-A1B2C3/.test(l)), 'hata iletisi (kimlik) gunluge yazilmaz');

  await lazy.bridge.end();
  assert.doesNotThrow(() => lazy.bridge.invalidateLayout(DEV.device_id));
});

test('D6 invalidateLayout (gercek servis): ayni imzali sonraki canli state RECHECK beklenmeden yeniden kontrol edilir', async () => {
  const { w, d, bridge } = setupReal();
  await send(bridge, fwState({ set: SHUTTER_56 }));
  const svc = bridge._layoutSync;
  assert.equal(await svc.whenIdle(2000), true);
  assert.equal(w.row(d, 5).type, 'shutter');

  // ayni imza, RECHECK dolmadan: sorgu yok
  w.now += 30 * 1000;
  let before = w.calls.length;
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(await svc.whenIdle(2000), true);
  assert.equal(w.calls.length, before, 'onbellek: sifir servis sorgusu');

  // satirlar disaridan tohuma dondu (REASSIGNED benzeri) + kopru onbellegi gecersizlestirdi
  w.row(d, 5).type = 'light';
  w.row(d, 6).type = 'light';
  bridge.invalidateLayout(d.id);
  w.now += 30 * 1000;
  before = w.calls.length;
  await send(bridge, fwState({ set: SHUTTER_56 }));
  assert.equal(await svc.whenIdle(2000), true);
  assert.ok(w.names(before).includes('device'), 'yeniden kontrol edildi');
  assert.equal(w.row(d, 5).type, 'shutter', 'tohum sablonu hemen panoya esitlendi');
  assert.equal(w.row(d, 6).type, 'shutter');
});

// ------------------------------------------------------------------------------
// Pano sozlesmesi + tekil + belge
// ------------------------------------------------------------------------------
test('gercek pano yuku (MqttManager.cpp publishState bicimi) extractReportedLayout\'tan gecer ve kopruden bildirilir', async () => {
  // bridge_firmware_contract.test.js `firmwareState()` zarfi (v, uid, fw, seq, uptime, ip, child_lock, dis; last_id YOK)
  // + panonun GERCEK tip adlari (relayTypeName: shutter_up / shutter_down / impulse / light).
  const payload = {
    v: 2,
    uid: UID,
    fw: '1.1.0',
    seq: 1234,
    uptime: 3600,
    ip: '192.168.1.30',
    child_lock: false,
    relays: [
      { id: 1, name: 'Salon Panjur (Yukari)', type: 'shutter_up', state: false },
      { id: 2, name: 'Salon Panjur (Asagi)', type: 'shutter_down', state: false },
      { id: 3, name: 'Oda Panjur (Yukari)', type: 'shutter_up', state: false },
      { id: 4, name: 'Oda Panjur (Asagi)', type: 'shutter_down', state: false },
      { id: 5, name: 'Salon Aydinlatma', type: 'light', state: true },
      { id: 6, name: 'Mutfak Aydinlatma', type: 'light', state: false },
      { id: 7, name: 'Kombi', type: 'impulse', state: false },
      { id: 8, name: 'Balkon Aydinlatma', type: 'light', state: false },
    ],
    shutters: [
      { pair: 1, pos: 100, moving: false, dir: 0, target: 255 },
      { pair: 2, pos: 35, moving: true, dir: 2, target: 10 },
    ],
    dis: [{ id: 1, state: false }, { id: 2, state: true }],
  };
  const check = helpers.validateStatePayload(payload);
  assert.equal(check.ok, true);
  assert.equal(check.value.skipped, 0);

  const layout = extractReportedLayout(payload);
  assert.notEqual(layout, null);
  assert.equal(layout.count, 8);
  assert.deepEqual(layout.pairs, [1, 2]);
  assert.deepEqual(layout.shutterPos, { 1: 100, 2: 35 });
  assert.deepEqual(layout.relays[6], { id: 7, type: 'impulse', name: 'Kombi', state: false });

  const spy = makeSpy();
  const { bridge, logger } = setup({ layoutSyncer: spy });
  await send(bridge, payload);
  assert.equal(spy.calls.length, 1);
  assert.deepEqual(spy.calls[0].layout, layout);
  assert.deepEqual(warnings(logger), []);
});

test('tekil: uretim kopru ornegi (require) yerlesim esitleme ACIK + uzlastirma ACIK; test ornekleri kapali', () => {
  assert.equal(bridgeModule._layoutSyncEnabled, true);
  assert.equal(bridgeModule._reconcileEnabled, true);
  assert.equal(bridgeModule._layoutSync, null, 'modul yuklenirken servis kurulmaz (tembel)');
  const plain = new MqttBridge({ env: {} });
  assert.equal(plain._layoutSyncEnabled, false);
  assert.equal(plain._reconcileEnabled, false);
});

test('kaynak: bas aciklama blogu WP-L maddesini tasir; "kopru kullanmaz" ifadesi guncellendi; tekil satiri', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'mqtt_bridge.js'), 'utf8');
  const header = source.slice(0, source.indexOf("const os = require('os');"));
  assert.match(header, /YERLESIM ESITLEME \(WP-L, CONTRACTS .?2\.4b\)/);
  assert.match(header, /endpoint_layout_sync\.js/);
  assert.match(header, /ENDPOINT_LAYOUT_SYNC/);
  assert.doesNotMatch(source, /metindir \(kopru kullanmaz\)/);
  assert.match(header, /relays\[\]\.type/);
  assert.match(source, /new MqttBridge\(\{ reconcile: true, layoutSync: true, alarms: true \}\)/); // WP-S2: alarm servisi
  assert.equal(source.includes('\r'), false, 'satir sonu LF');
});
