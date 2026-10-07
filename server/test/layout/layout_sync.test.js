'use strict';

// WP-L - Uc nokta yerlesim esitleme SERVISI (services/endpoint_layout_sync.js).
//
// Gercek veritabani YOKTUR: servisin SQL'ini (SQL.x metin esitligi) taklit eden bellek ici dunya (_helpers.js) ve
// elle ilerletilen saat. Kuyruk gercek KeyedWorkQueue'dur (kopru ile ayni sinif).
// Plan: docs/superpowers/plans/2026-10-03-uc-nokta-yerlesim-esitleme.md, Task 3 (13 davranis).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { KeyedWorkQueue } = require('../../src/mqtt_bridge');
const { createEndpointLayoutSync, EndpointLayoutSync, SQL, constants } = require('../../src/services/endpoint_layout_sync');
const { serializeBase } = require('../../src/utils/endpoint_layout');
const { T0, layoutOf, makeLogger, makeWorld } = require('./_helpers');

const TOPIC = 't_9f8e7d6c5b4a';
const UID = 'AHBU-S3-A1B2C3';
const WRITES = ['insertRow', 'updateRow', 'deleteAbove', 'disableRules', 'saveBase', 'audit'];

// commissioned: D1 gecici (fabrika) pano korumasi devreye alinmis cihazda calismaz; normal yolu (kuculme, panjurdan
// roleye donus) fabrika bildirimiyle sinayan testler cihazi devreye alinmis kurar.
function setup({ rows = 8, base = null, extra = {}, commissioned = false } = {}) {
  const w = makeWorld(SQL);
  const d = w.addDevice({ base, uuid: UID, commissioned });
  if (rows > 0) w.seed(d, rows);
  const logger = makeLogger();
  const svc = createEndpointLayoutSync({ db: w.db, logger, now: () => w.now, QueueClass: KeyedWorkQueue, ...extra });
  const live = (layout, over = {}) => svc.onLiveState({ topicId: TOPIC, homeId: d.home_id, deviceId: d.id, layout, ...over });
  const now = (layout, over = {}) => svc.syncNow({ homeId: d.home_id, deviceId: d.id, layout, ...over });
  const settle = async () => assert.equal(await svc.whenIdle(2000), true, 'kuyruk bosalmali');
  return { w, d, svc, logger, live, now, settle };
}

const writesIn = (w, from = 0) => w.names(from).filter((n) => WRITES.includes(n));

// ------------------------------------------------------------------------------
// Disa aktarim / sozlesme
// ------------------------------------------------------------------------------
test('disa aktarim: fabrika, sinif, sabitler', () => {
  assert.equal(typeof createEndpointLayoutSync, 'function');
  assert.equal(typeof EndpointLayoutSync, 'function');
  const { svc } = setup();
  assert.ok(svc instanceof EndpointLayoutSync);
  for (const m of ['onLiveState', 'syncNow', 'invalidate', 'whenIdle', 'stop', 'stats']) {
    assert.equal(typeof svc[m], 'function', m);
  }
  assert.equal(constants.RECHECK_MS, 5 * 60 * 1000);
  assert.equal(constants.MIN_RUN_INTERVAL_MS, 5000);
  assert.equal(constants.SHRINK_CONFIRM_MS, 20000);
  assert.equal(constants.CACHE_IDLE_MS, 60 * 60 * 1000);
  assert.equal(constants.GC_INTERVAL_MS, 60000);
  assert.equal(constants.MAX_CONCURRENT_HOMES, 2);
  assert.equal(constants.MAX_PENDING, 20000);
  assert.equal(constants.AUDIT_EVENT, 'endpoint_layout_synced');
  assert.equal(constants.APPLY_BUDGET_PER_HOUR, 30); // D10: cihaz basina saatte en cok 30 satir degistiren calisma
  assert.ok(Object.isFrozen(constants));
});

test('disa aktarim: SQL metinleri plandakiyle BIREBIR (gercek PG testleri ve kopru bunlara dayanir)', () => {
  assert.ok(Object.isFrozen(SQL));
  assert.deepEqual({ ...SQL }, {
    // D1: devreye alma bayragi gecici (fabrika) pano korumasi icin okunur
    device: 'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout, d.is_commissioned FROM devices d WHERE d.id = $1',
    deviceLocked:
      'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout, d.is_commissioned FROM devices d WHERE d.id = $1 FOR UPDATE',
    rows:
      'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
      'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index',
    rowsLocked:
      'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
      'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index FOR UPDATE',
    insertRow:
      'INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, ' +
      'shutter_duration_sec, current_state, current_position) ' +
      'VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) ON CONFLICT (device_id, channel_index) DO NOTHING',
    updateRow:
      'UPDATE endpoints SET name = $3, type = $4, room = $5, shutter_pair_index = $6, shutter_duration_sec = $7, ' +
      'current_position = COALESCE($8::int, current_position), updated_at = CURRENT_TIMESTAMP ' +
      'WHERE id = $1 AND device_id = $2',
    deleteAbove: 'DELETE FROM endpoints WHERE device_id = $1 AND channel_index > $2',
    // D14: device_id NULL kural yalniz evde tek cihaz varsa (cok panolu evde baska panoya ait olabilir)
    disableRules:
      'UPDATE scheduled_rules SET enabled = FALSE ' +
      'WHERE home_id = $1 AND enabled = TRUE ' +
      'AND (device_id = $2 OR (device_id IS NULL AND (SELECT COUNT(*) FROM devices dv WHERE dv.home_id = $1) = 1)) ' +
      "AND ((channel_type = 'relay' AND channel = ANY($3::int[])) OR (channel_type = 'shutter' AND channel = ANY($4::int[]))) " +
      'RETURNING id',
    saveBase: 'UPDATE devices SET reported_layout = $2::jsonb, reported_layout_at = CURRENT_TIMESTAMP WHERE id = $1',
    // WP-S2 [Y2]: yalniz bildirimde/tabanda eylemci (act) varsa calisir; v:2 yolunda HIC cagrilmaz
    syncActuators:
      'UPDATE endpoints e SET actuator_type = v.act, updated_at = CURRENT_TIMESTAMP ' +
      'FROM unnest($2::int[], $3::varchar[]) AS v(channel, act) ' +
      'WHERE e.device_id = $1 AND e.channel_index = v.channel AND e.actuator_type IS DISTINCT FROM v.act ' +
      'RETURNING e.channel_index, e.actuator_type',
    audit:
      'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
      "VALUES ($1, $2, $3, NULL, 'device', NULL, $4::jsonb)",
  });
});

test('kurucu: db.query ve db.withTransaction zorunlu; QueueClass verilmezse kopru kuyrugu (tembel) kullanilir', async () => {
  assert.throws(() => createEndpointLayoutSync({}), TypeError);
  assert.throws(() => createEndpointLayoutSync({ db: { query() {} } }), TypeError);
  const w = makeWorld(SQL);
  const d = w.addDevice();
  w.seed(d, 8);
  const svc = createEndpointLayoutSync({ db: w.db, logger: makeLogger(), now: () => w.now });
  const r = await svc.syncNow({ homeId: d.home_id, deviceId: d.id, layout: layoutOf() });
  assert.equal(r.status, 'applied');
});

// ------------------------------------------------------------------------------
// 1) onLiveState: korumalar
// ------------------------------------------------------------------------------
test('1: onLiveState layout / deviceId / homeId yoksa hicbir sey yapmaz (sorgu yok, kayit yok)', async () => {
  const { w, d, svc, settle } = setup();
  svc.onLiveState();
  svc.onLiveState(null);
  svc.onLiveState({});
  svc.onLiveState({ topicId: TOPIC, homeId: d.home_id, deviceId: d.id });
  svc.onLiveState({ topicId: TOPIC, homeId: d.home_id, deviceId: d.id, layout: null });
  svc.onLiveState({ topicId: TOPIC, homeId: d.home_id, layout: layoutOf() });
  svc.onLiveState({ topicId: TOPIC, deviceId: d.id, layout: layoutOf() });
  await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(svc.stats().devices, 0);
  assert.equal(svc.stats().checks, 0);
});

test('1: onLiveState ASLA firlatmaz (saat hatasi, kuyruk hatasi) ve void doner', async () => {
  const boom = () => {
    throw new Error('saat bozuk');
  };
  const a = setup({ extra: { now: boom } });
  let out;
  assert.doesNotThrow(() => {
    out = a.live(layoutOf());
  });
  assert.equal(out, undefined);
  assert.equal(a.svc.stats().errors, 1);

  class BrokenQueue extends KeyedWorkQueue {
    push() {
      throw new Error('kuyruk bozuk');
    }
  }
  const b = setup({ extra: { QueueClass: BrokenQueue } });
  assert.doesNotThrow(() => b.live(layoutOf()));
  assert.equal(b.svc.stats().errors, 1);
  assert.equal(b.w.calls.length, 0);
});

// ------------------------------------------------------------------------------
// 2) Onbellek
// ------------------------------------------------------------------------------
test('2: ayni imzayla ikinci onLiveState SIFIR sorgu uretir', async () => {
  const { w, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'saveBase']);
  const mark = w.calls.length;

  w.now += 30 * 1000; // sonraki kalp atisi
  live(layoutOf()); // yeni nesne, ayni imza (state farki imzayi degistirmez)
  await settle();
  w.now += 30 * 1000;
  live(layoutOf());
  await settle();
  assert.equal(w.calls.length, mark, 'degismeyen imza veritabanina gitmemeli');
  assert.equal(svc.stats().checks, 1);
  assert.equal(svc.stats().rateLimited, 0, 'onbellek isabeti hiz siniri sayilmaz');
});

test('2: RECHECK_MS sonra ayni imza yalniz KILITSIZ okuma yapar (transaction ve yazma yok)', async () => {
  const { w, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;
  const txMark = w.txLog.length;

  w.now += constants.RECHECK_MS - 1;
  live(layoutOf());
  await settle();
  assert.equal(w.calls.length, mark, 'sure dolmadan dogrulama yok');

  w.now += 1;
  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows']);
  assert.ok(w.calls.slice(mark).every((c) => c.inTx === false));
  assert.equal(w.txLog.length, txMark, 'transaction acilmamali');
  assert.equal(svc.stats().noops, 1);

  // dogrulama zamani yenilendi: hemen ardindan gelen mesaj yine sorgusuz
  const mark2 = w.calls.length;
  w.now += 30 * 1000;
  live(layoutOf());
  await settle();
  assert.equal(w.calls.length, mark2);
});

test('2: imza degisince (ad) yeniden calisir; RECHECK kendi kendini onarir (satir disaridan bozulmus)', async () => {
  const { w, d, live, settle } = setup();
  live(layoutOf());
  await settle();
  w.now += 30 * 1000;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  await settle();
  assert.equal(w.row(d, 6).name, 'Mutfak Spot');
  assert.equal(w.row(d, 6).room, 'Mutfak');

  // yeniden tohumlama benzeri: satir sablon adina dondu, pano ayni seyi bildirmeye devam ediyor
  w.row(d, 6).name = 'Mutfak Aydınlatma';
  w.now += 30 * 1000;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  await settle();
  assert.equal(w.row(d, 6).name, 'Mutfak Aydınlatma', 'onbellek suresi dolmadan fark edilmez');
  w.now += constants.RECHECK_MS;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  await settle();
  assert.equal(w.row(d, 6).name, 'Mutfak Spot', 'dogrulama okumasinda fark edilip onarilir');
});

test('2: ayni imza ama homeId degismisse onbellek gecersizdir', async () => {
  const { w, d, live, settle } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;
  // cihaz baska eve tasindi; kopru artik yeni evin kimligiyle bildiriyor
  d.home_id = crypto.randomUUID();
  w.now += 30 * 1000;
  live(layoutOf());
  await settle();
  assert.ok(w.calls.length > mark, 'ev degisince yeniden kontrol edilmeli');
});

test('2: imzasi olmayan layout onbellege "tamam" diye yazilmaz (undefined === undefined isabeti yok)', async () => {
  const { w, live, settle } = setup();
  const noSig = () => ({ ...layoutOf(), signature: undefined });
  live(noSig());
  await settle();
  const mark = w.calls.length;
  w.now += 30 * 1000;
  live(noSig());
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows'], 'imzasiz yerlesim her seferinde dogrulanmali');
});

// ------------------------------------------------------------------------------
// 3) Hiz siniri
// ------------------------------------------------------------------------------
test('3: cihaz basina MIN_RUN_INTERVAL_MS icinde ikinci calisma atlanir; sonraki mesaj yeniden dener', async () => {
  const { w, d, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;

  w.now += constants.MIN_RUN_INTERVAL_MS - 1;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } })); // imza farkli ama cok erken
  await settle();
  assert.equal(w.calls.length, mark);
  assert.equal(svc.stats().rateLimited, 1);
  assert.equal(w.row(d, 6).name, 'Mutfak Aydınlatma');

  w.now += 1;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  await settle();
  assert.ok(w.calls.length > mark);
  assert.equal(svc.stats().rateLimited, 1);
  assert.equal(w.row(d, 6).name, 'Mutfak Spot');
});

test('3: hiz siniri cihaz basinadir (baska cihaz etkilenmez)', async () => {
  const { w, live, settle, svc } = setup();
  const d2 = w.addDevice({ uuid: 'AHBU-S3-FFEEDD' });
  w.seed(d2, 8);
  live(layoutOf());
  svc.onLiveState({ topicId: 't_other', homeId: d2.home_id, deviceId: d2.id, layout: layoutOf() });
  await settle();
  assert.equal(svc.stats().checks, 2);
  assert.equal(svc.stats().rateLimited, 0);
  assert.equal(svc.stats().devices, 2);
});

// ------------------------------------------------------------------------------
// 4) Kuyruk
// ------------------------------------------------------------------------------
test('4: is EV anahtarli kuyruga coalesce:true ile atilir; ayni evdeki iki pano birbirinin isini ezmez', async () => {
  let q = null;
  class SpyQueue extends KeyedWorkQueue {
    constructor(opts) {
      super(opts);
      this.opts = opts;
      this.pushes = [];
      q = this;
    }

    push(key, kind, run, opts) {
      this.pushes.push({ key, kind, opts });
      return super.push(key, kind, run, opts);
    }
  }
  const { w, d, live, now, settle } = setup({ extra: { QueueClass: SpyQueue } });
  assert.deepEqual(q.opts, { concurrency: constants.MAX_CONCURRENT_HOMES, maxPending: constants.MAX_PENDING });
  const d2 = w.addDevice({ homeId: d.home_id, uuid: 'AHBU-S3-FFEEDD' });
  w.seed(d2, 8);

  live(layoutOf());
  live(layoutOf(), { deviceId: d2.id });
  await settle();
  assert.equal(q.pushes.length, 2);
  assert.equal(q.pushes[0].key, d.home_id);
  assert.equal(q.pushes[1].key, d.home_id);
  assert.equal(q.pushes[0].opts.coalesce, true);
  assert.notEqual(q.pushes[0].kind, q.pushes[1].kind, 'tur cihaza ozgu olmali (birlestirme baska cihazin isini silmesin)');
  assert.ok(w.devices.get(d.id).reported_layout && w.devices.get(d2.id).reported_layout, 'iki cihaz da islenmeli');

  await now(layoutOf());
  assert.equal(q.pushes[2].key, d.home_id, 'syncNow da ayni ev seridinde sirali calisir');
});

test('4: is surerken gelen yeni mesajlar tek bekleyen iste birlesir (en yeni yerlesim uygulanir)', async () => {
  const { w, d, live, settle, svc } = setup();
  let release;
  w.hold = new Promise((resolve) => {
    release = resolve;
  });
  live(layoutOf()); // calisiyor (sorguda bekliyor)
  await new Promise((resolve) => setImmediate(resolve));
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } })); // bekleyen is
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf({ set: { 6: { name: 'Mutfak Tezgah' } } })); // bekleyen isin yerine gecer
  w.hold = null;
  release();
  await settle();
  assert.equal(svc.stats().checks, 2, 'uc mesaj -> iki calisma');
  assert.equal(svc.stats().queue.coalesced, 1);
  assert.equal(w.row(d, 6).name, 'Mutfak Tezgah');
});

// ------------------------------------------------------------------------------
// 5) Kilitsiz on okuma
// ------------------------------------------------------------------------------
test('5: cihaz yok -> skipped, onbellek kaydi silinir, satir sorgusu bile yapilmaz', async () => {
  const { w, svc, live, settle } = setup();
  const ghost = crypto.randomUUID();
  live(layoutOf(), { deviceId: ghost });
  await settle();
  assert.deepEqual(w.names(), ['device']);
  assert.equal(svc.stats().skipped, 1);
  assert.equal(svc.stats().devices, 0);
  const r = await svc.syncNow({ homeId: crypto.randomUUID(), deviceId: ghost, layout: layoutOf() });
  assert.deepEqual(r, { status: 'skipped', reason: 'device_not_found' });
});

test('5: cihaz baska eve tasinmis (home_id farkli) -> hicbir sey yazilmaz', async () => {
  const { w, d, svc, live, now, settle } = setup();
  const before = JSON.stringify(w.rowsOf(d));
  const oldHome = d.home_id;
  d.home_id = crypto.randomUUID(); // veritabaninda cihaz artik baska evde
  live(layoutOf({ set: { 5: { type: 'shutter_up', name: 'Salon (Yukari)' }, 6: { type: 'shutter_down', name: 'Salon (Asagi)' } } }), { homeId: oldHome });
  await settle();
  assert.deepEqual(w.names(), ['device']);
  assert.equal(w.txLog.length, 0);
  assert.equal(JSON.stringify(w.rowsOf(d)), before);
  assert.equal(d.reported_layout, null);
  assert.equal(svc.stats().skipped, 1);
  assert.equal(svc.stats().devices, 0, 'onbellek kaydi silinmeli');

  d.home_id = null; // sahipsiz cihaz
  const r = await now(layoutOf(), { homeId: oldHome });
  assert.deepEqual(r, { status: 'skipped', reason: 'home_mismatch' });
  assert.deepEqual(writesIn(w), []);
});

// ------------------------------------------------------------------------------
// 6) Degisiklik yok
// ------------------------------------------------------------------------------
test('6: plan degisiklik ve taban farki icermiyorsa transaction ACILMAZ (noop)', async () => {
  const layout = layoutOf();
  const { w, now, svc } = setup({ base: serializeBase(layout) });
  const r = await now(layout);
  assert.equal(r.status, 'noop');
  assert.deepEqual(w.names(), ['device', 'rows']);
  assert.equal(w.txLog.length, 0);
  assert.equal(svc.stats().noops, 1);
  assert.equal(svc.stats().applied, 0);
  assert.equal(w.audits.length, 0);
});

// ------------------------------------------------------------------------------
// 7) Transaction
// ------------------------------------------------------------------------------
test('7: transaction icindeki SQL sirasi ve parametreleri (sil -> guncelle -> ekle -> kural -> taban -> denetim)', async () => {
  const { w, d, now, svc, logger } = setup({ rows: 10, commissioned: true }); // D1: normal yol (fabrika bildirimi + kuculme)
  const r1 = await now(layoutOf()); // kuculme ilk kez goruldu (kanal 9-10 fazla); yalniz taban yazilir
  assert.equal(r1.status, 'applied');
  assert.deepEqual(writesIn(w), ['saveBase']);

  w.removeRows(d, (e) => e.channel_index === 7 || e.channel_index === 8); // eksik satir senaryosu
  const ruleA = w.addRule(d, 'relay', 5); // panjura donen kanal
  const ruleB = w.addRule(d, 'relay', 9, { deviceId: d.id }); // silinen kanal
  const ruleKeep1 = w.addRule(d, 'relay', 7); // sinifi degismeyen kanal
  const ruleKeep2 = w.addRule(d, 'relay', 5, { homeId: crypto.randomUUID() }); // baska ev
  const ruleKeep3 = w.addRule(d, 'relay', 6, { deviceId: crypto.randomUUID() }); // ayni ev, baska pano
  const ruleKeep4 = w.addRule(d, 'shutter', 5); // panjur kurali (cift 5): listede yok
  const ruleOff = w.addRule(d, 'relay', 6, { enabled: false }); // zaten kapali: RETURNING'e girmez

  w.now += constants.SHRINK_CONFIRM_MS;
  const mark = w.calls.length;
  const layout = layoutOf({
    set: { 5: { type: 'shutter_up', name: 'Salon (Yukari)' }, 6: { type: 'shutter_down', name: 'Salon (Asagi)' } },
    pos: { 3: 40 },
  });
  const r2 = await now(layout);
  assert.equal(r2.status, 'applied');

  const calls = w.calls.slice(mark);
  assert.deepEqual(calls.map((c) => c.name), [
    'device', 'rows',
    'deviceLocked', 'rowsLocked', 'deleteAbove', 'updateRow', 'updateRow', 'insertRow', 'insertRow', 'disableRules', 'saveBase', 'audit',
  ]);
  assert.deepEqual(calls.map((c) => c.inTx), [false, false, true, true, true, true, true, true, true, true, true, true]);
  assert.deepEqual(w.txLog, ['BEGIN', 'COMMIT', 'BEGIN', 'COMMIT']);

  const ep = (c) => `ep-${d.id.slice(0, 4)}-${c}`;
  const p = (i) => calls[i].params;
  assert.deepEqual(p(0), [d.id]);
  assert.deepEqual(p(1), [d.id]);
  assert.deepEqual(p(2), [d.id]);
  assert.deepEqual(p(3), [d.id]);
  assert.deepEqual(p(4), [d.id, 8]);
  assert.deepEqual(p(5), [ep(5), d.id, 'Salon (Yukari)', 'shutter', 'Salon', 3, 20, 40]);
  assert.deepEqual(p(6), [ep(6), d.id, 'Salon (Asagi)', 'shutter', 'Salon', 3, 20, 40]);
  assert.deepEqual(p(7), [d.home_id, d.id, 7, 'Koridor Aydınlatma', 'light', 'Koridor', null, null, false, 0]);
  assert.deepEqual(p(8), [d.home_id, d.id, 8, 'Balkon Aydınlatma', 'light', 'Balkon', null, null, false, 0]);
  assert.deepEqual(p(9), [d.home_id, d.id, [5, 6, 9, 10], []]);
  assert.deepEqual(p(10), [d.id, JSON.stringify(serializeBase(layout))]);
  assert.equal(p(11).length, 4);
  assert.deepEqual(p(11).slice(0, 3), [constants.AUDIT_EVENT, UID, d.home_id]);
  assert.equal(typeof p(11)[3], 'string');
  assert.deepEqual(JSON.parse(p(11)[3]), {
    relays: 8, inserted: 2, retyped: 2, renamed: 2, reroomed: 1, deleted: 2, rules_disabled: [ruleA.id, ruleB.id],
  });
  assert.ok(!/Salon|Koridor|Balkon|Yukari|AHBU/.test(p(11)[3]), 'denetim ayrintisi ad/uid icermez');

  // dunya durumu
  assert.deepEqual(w.rowsOf(d).map((e) => e.channel_index), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(w.row(d, 5).id, ep(5), 'satir yerinde guncellenir (kimlik korunur)');
  assert.equal(w.row(d, 5).type, 'shutter');
  assert.equal(w.row(d, 5).current_position, 40);
  assert.equal(w.row(d, 1).shutter_duration_sec, 20);
  assert.equal(ruleA.enabled, false);
  assert.equal(ruleB.enabled, false);
  for (const keep of [ruleKeep1, ruleKeep2, ruleKeep3, ruleKeep4]) assert.equal(keep.enabled, true);
  assert.equal(ruleOff.enabled, false);
  assert.deepEqual(w.devices.get(d.id).reported_layout, serializeBase(layout));

  // donus degeri + sayaclar
  assert.equal(r2.summary.relays, 8);
  assert.equal(r2.summary.inserted, 2);
  assert.equal(r2.summary.retyped, 2);
  assert.equal(r2.summary.renamed, 2);
  assert.equal(r2.summary.reroomed, 1);
  assert.equal(r2.summary.deleted, 2);
  assert.equal(r2.summary.rulesDisabled, 2);
  const s = svc.stats();
  assert.equal(s.applied, 2);
  assert.equal(s.inserted, 2);
  assert.equal(s.retyped, 2);
  assert.equal(s.renamed, 2);
  assert.equal(s.deleted, 2);
  assert.equal(s.rulesDisabled, 2);

  // 10) gunluk: tek satir, yalniz sayilar ve kisaltilmis kimlik
  const lines = logger.lines.filter((l) => l.includes('[LAYOUT]'));
  assert.deepEqual(lines, [
    `log: [LAYOUT] cihaz=${d.id.slice(0, 8)} ev=${d.home_id.slice(0, 8)} eklendi=2 tip=2 ad=2 oda=1 silindi=2 kural=2`,
  ]);
  for (const l of logger.lines) {
    assert.ok(!l.includes(UID) && !l.includes(TOPIC) && !l.includes(d.id) && !l.includes(d.home_id), l);
    assert.ok(!/Salon|Mutfak|Koridor|Balkon/.test(l), l);
  }
});

test('7: yalniz ad degisimi -> updateRow TAM degerlerle, $8 null; kural sorgusu YOK; denetim kaydi var', async () => {
  const { w, d, now } = setup();
  w.row(d, 6).shutter_pair_index = undefined; // surucu alani hic dondurmezse de null gonderilir
  const r = await now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.equal(r.status, 'applied');
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'updateRow', 'saveBase', 'audit']);
  assert.deepEqual(w.find('updateRow')[0].params, [w.row(d, 6).id, d.id, 'Mutfak Spot', 'light', 'Mutfak', null, null, null]);
  assert.deepEqual(w.audits[0].details, { relays: 8, inserted: 0, retyped: 0, renamed: 1, reroomed: 0, deleted: 0, rules_disabled: [] });
  assert.equal(w.row(d, 6).current_position, 0);
});

test('7: panjur -> role: cift/sure null, konum 0; panjur kurali cift numarasiyla kapatilir', async () => {
  const { w, d, now } = setup();
  w.row(d, 1).current_position = 70;
  w.row(d, 2).current_position = 70;
  const shutterRule = w.addRule(d, 'shutter', 1);
  const relayRule = w.addRule(d, 'relay', 1); // role kurali panjurdan roleye donen kanalda kapatilmaz
  const r = await now(layoutOf({ set: { 1: { type: 'light', name: 'Röle 1 Aydınlatma' }, 2: { type: 'light', name: 'Röle 2 Aydınlatma' } } }));
  assert.equal(r.status, 'applied');
  assert.deepEqual(w.find('updateRow').map((c) => c.params), [
    [w.row(d, 1).id, d.id, 'Röle 1 Aydınlatma', 'light', 'Genel', null, null, 0],
    [w.row(d, 2).id, d.id, 'Röle 2 Aydınlatma', 'light', 'Genel', null, null, 0],
  ]);
  assert.deepEqual(w.find('disableRules')[0].params, [d.home_id, d.id, [], [1]]);
  assert.equal(shutterRule.enabled, false);
  assert.equal(relayRule.enabled, true);
  assert.equal(w.row(d, 1).current_position, 0);
  assert.deepEqual(w.audits[0].details.rules_disabled, [shutterRule.id]);
});

test('7: yalniz taban farki -> saveBase yazilir, denetim kaydi ve gunluk satiri YOK', async () => {
  const { w, d, now, logger } = setup();
  const layout = layoutOf();
  const r = await now(layout);
  assert.equal(r.status, 'applied');
  assert.equal(r.summary.baseSaved, true);
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'saveBase']);
  assert.deepEqual(w.find('saveBase')[0].params, [d.id, JSON.stringify(serializeBase(layout))]);
  assert.equal(w.audits.length, 0);
  assert.deepEqual(logger.lines, []);
});

test('7: ek modul -> eksik satirlar kanal sirasiyla eklenir', async () => {
  const { w, d, now } = setup();
  const r = await now(layoutOf({ count: 12, set: { 11: { type: 'shutter_up', name: 'Teras Tente (Yukari)' }, 12: { type: 'shutter_down', name: 'Teras Tente (Asagi)' } }, pos: { 6: 55 } }));
  assert.equal(r.status, 'applied');
  assert.deepEqual(w.find('insertRow').map((c) => c.params), [
    [d.home_id, d.id, 9, 'Ek Modül Röle 1', 'light', 'Genel', null, null, false, 0],
    [d.home_id, d.id, 10, 'Ek Modül Röle 2', 'light', 'Genel', null, null, false, 0],
    [d.home_id, d.id, 11, 'Teras Tente (Yukari)', 'shutter', 'Teras', 6, 20, false, 55],
    [d.home_id, d.id, 12, 'Teras Tente (Asagi)', 'shutter', 'Teras', 6, 20, false, 55],
  ]);
  assert.equal(w.rowsOf(d).length, 12);
  assert.deepEqual(w.find('disableRules'), [], 'yeni satir kural kapatmaz');
});

test('7: karar KILITLI veriye gore verilir (kilitsiz okumadan sonra kullanici adi degisti -> ezilmez)', async () => {
  const { w, d, now } = setup();
  w.beforeTx = async () => {
    w.row(d, 6).name = 'Tezgah'; // es zamanli PUT /endpoints: kullanici ad verdi
  };
  const r = await now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.equal(w.row(d, 6).name, 'Tezgah', 'kullanicinin adi korunmali');
  assert.deepEqual(w.find('updateRow'), []);
  assert.equal(w.audits.length, 0);
  assert.equal(r.status, 'applied'); // yalniz taban yazildi
  assert.equal(r.summary.renamed, 0);
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'saveBase']);
});

test('7: kilitli okumada fark kalmamissa (baska calisma uygulamis) hicbir sey yazilmaz -> noop', async () => {
  const layout = layoutOf({ set: { 6: { name: 'Mutfak Spot' } } });
  const { w, d, now, svc } = setup();
  w.beforeTx = async () => {
    w.row(d, 6).name = 'Mutfak Spot';
    d.reported_layout = serializeBase(layout);
  };
  const r = await now(layout);
  assert.equal(r.status, 'noop');
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked']);
  assert.equal(svc.stats().noops, 1);
  assert.equal(svc.stats().applied, 0);
});

test('7: transaction icinde cihaz baska eve tasinmis / silinmis -> hicbir sey yazilmaz', async () => {
  const a = setup();
  const oldHome = a.d.home_id;
  a.w.beforeTx = async () => {
    a.d.home_id = crypto.randomUUID();
  };
  const r1 = await a.now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }), { homeId: oldHome });
  assert.deepEqual(r1, { status: 'skipped', reason: 'home_mismatch' });
  assert.deepEqual(a.w.names(), ['device', 'rows', 'deviceLocked']);
  assert.equal(a.w.row(a.d, 6).name, 'Mutfak Aydınlatma');
  assert.equal(a.d.reported_layout, null);
  assert.equal(a.svc.stats().skipped, 1);
  assert.equal(a.svc.stats().devices, 0);

  const b = setup();
  b.w.beforeTx = async () => {
    b.w.devices.delete(b.d.id);
  };
  const r2 = await b.now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.deepEqual(r2, { status: 'skipped', reason: 'device_not_found' });
  assert.deepEqual(b.w.names(), ['device', 'rows', 'deviceLocked']);
  assert.deepEqual(writesIn(b.w), []);
});

// ------------------------------------------------------------------------------
// 8) Kuculme onayi
// ------------------------------------------------------------------------------
test('8: kuculme ilk gorulmede SILMEZ; SHRINK_CONFIRM_MS sonra ayni sayi yeniden gorulunce deleteAbove calisir', async () => {
  const { w, d, live, settle, svc } = setup({ rows: 16, commissioned: true }); // D1: normal yol
  const rule = w.addRule(d, 'relay', 12);
  live(layoutOf());
  await settle();
  assert.equal(w.rowsOf(d).length, 16, 'tek mesaj satir silemez');
  assert.deepEqual(w.find('deleteAbove'), []);
  assert.equal(rule.enabled, true);

  // kuculme beklerken onbellek "tamam" sayilmaz: sonraki mesaj yeniden girer (hiz siniri gecerli)
  let mark = w.calls.length;
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows'], 'yeniden kontrol edilir ama yazilmaz');
  assert.equal(w.rowsOf(d).length, 16);

  w.now += constants.SHRINK_CONFIRM_MS - constants.MIN_RUN_INTERVAL_MS - 1; // ilk gorulmeden 19.999 sn sonra
  live(layoutOf());
  await settle();
  assert.equal(w.rowsOf(d).length, 16, 'onay suresi dolmadan silinmez');

  w.now += constants.MIN_RUN_INTERVAL_MS;
  mark = w.calls.length;
  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'deleteAbove', 'disableRules', 'audit']);
  assert.deepEqual(w.find('deleteAbove')[0].params, [d.id, 8]);
  assert.deepEqual(w.find('disableRules')[0].params, [d.home_id, d.id, [9, 10, 11, 12, 13, 14, 15, 16], []]);
  assert.equal(w.rowsOf(d).length, 8);
  assert.equal(rule.enabled, false);
  assert.equal(w.audits[0].details.deleted, 8);
  assert.equal(svc.stats().deleted, 8);

  // silindikten sonra onbellek tamam: ayni imza sorgusuz
  mark = w.calls.length;
  w.now += 30 * 1000;
  live(layoutOf());
  await settle();
  assert.equal(w.calls.length, mark);
});

test('8: bildirilen sayi degisirse onay sifirlanir (8 -> 10 -> 8: her biri yeni ilk gorulme)', async () => {
  const { w, d, now } = setup({ rows: 16, commissioned: true }); // D1: normal yol
  await now(layoutOf()); // {8, T0}
  w.now += constants.SHRINK_CONFIRM_MS;
  await now(layoutOf({ count: 10 })); // sayi farkli: {10, T0+20}
  assert.equal(w.rowsOf(d).length, 16);
  w.now += constants.MIN_RUN_INTERVAL_MS;
  await now(layoutOf()); // sayi yine farkli: {8, T0+25}
  assert.equal(w.rowsOf(d).length, 16, 'eski 8 gorulmesi sayilmaz');
  w.now += constants.SHRINK_CONFIRM_MS - 1;
  await now(layoutOf());
  assert.equal(w.rowsOf(d).length, 16);
  w.now += 1;
  const r = await now(layoutOf());
  assert.equal(r.status, 'applied');
  assert.equal(r.summary.deleted, 8);
  assert.equal(w.rowsOf(d).length, 8);
});

test('8: bildirilen sayi satirlari kapsayinca kuculme kaydi silinir (sonraki kuculme yeniden iki kez gorulmeli)', async () => {
  const { w, d, now } = setup({ rows: 16, commissioned: true }); // D1: normal yol
  const r1 = await now(layoutOf());
  assert.equal(r1.summary.pendingShrink, true);
  w.now += 6000;
  const r2 = await now(layoutOf({ count: 16 })); // ek modul geri geldi: kapsiyor
  assert.equal(r2.summary.pendingShrink, false);
  w.now += constants.SHRINK_CONFIRM_MS;
  const r3 = await now(layoutOf()); // T0'daki gorulme GECERSIZ: bu yeni ilk gorulme
  assert.equal(r3.summary.pendingShrink, true);
  assert.equal(w.rowsOf(d).length, 16);
  assert.deepEqual(w.find('deleteAbove'), []);
});

// D10 (2026-10-04): kuculme onayi imza onbelleginden AYRI tutulur; invalidate onu SIFIRLAMAZ (onceki beklenti
// "invalidate onayi sifirlar" D10 karariyla degisti).
test('8: syncNow kuculme onayini ATLAMAZ; invalidate kuculme onayini SIFIRLAMAZ (D10)', async () => {
  const { w, d, now, svc } = setup({ rows: 16, commissioned: true }); // D1: normal yol
  await now(layoutOf());
  await now(layoutOf());
  assert.equal(w.rowsOf(d).length, 16, 'art arda iki syncNow silmez (sure sarti)');
  svc.invalidate(d.id);
  w.now += constants.SHRINK_CONFIRM_MS - 1;
  await now(layoutOf());
  assert.equal(w.rowsOf(d).length, 16, 'onay suresi dolmadan silinmez');
  w.now += 1;
  await now(layoutOf());
  assert.equal(w.rowsOf(d).length, 8, 'ilk gorulme invalidate ile silinmedi: sure dolunca silinir');
});

test('8: kuculme beklerken diger degisiklikler uygulanir, satir silinmez', async () => {
  const { w, d, now } = setup({ rows: 16, commissioned: true }); // D1: normal yol
  const r = await now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.equal(r.status, 'applied');
  assert.equal(r.summary.pendingShrink, true);
  assert.equal(w.row(d, 6).name, 'Mutfak Spot');
  assert.equal(w.rowsOf(d).length, 16);
  assert.equal(w.audits[0].details.deleted, 0);
});

// ------------------------------------------------------------------------------
// 9) Hata yalitimi
// ------------------------------------------------------------------------------
test('9: withTransaction firlatinca onLiveState firlatmaz, errors artar, sonraki mesaj yeniden dener', async () => {
  const { w, d, live, settle, svc } = setup();
  const layout = () => layoutOf({ set: { 6: { name: 'Mutfak Spot' } } });
  w.failTx = Object.assign(new Error('baglanti koptu'), { code: '08006' });
  assert.doesNotThrow(() => live(layout()));
  await settle();
  assert.equal(svc.stats().errors, 1);
  assert.equal(svc.stats().applied, 0);
  assert.equal(svc.stats().queue.failed, 0, 'kuyruk isi reddetmemeli (hata serviste yutulur)');
  assert.equal(w.row(d, 6).name, 'Mutfak Aydınlatma');

  // hiz siniri hata sonrasi da gecerli
  const mark = w.calls.length;
  w.now += constants.MIN_RUN_INTERVAL_MS - 1;
  live(layout());
  await settle();
  assert.equal(w.calls.length, mark);
  assert.equal(svc.stats().rateLimited, 1);

  // onbellek guncellenmedi: ayni imza yeniden dener ve bu kez uygular
  w.failTx = null;
  w.now += 1;
  live(layout());
  await settle();
  assert.equal(w.row(d, 6).name, 'Mutfak Spot');
  assert.equal(svc.stats().applied, 1);
  assert.equal(svc.stats().errors, 1);
});

test('9: kilitsiz okuma hatasi -> syncNow {status:error} (reddetmez); yarim transaction geri alinir', async () => {
  const a = setup();
  a.w.failWhen = (text) => (text === SQL.device ? Object.assign(new Error('zaman asimi'), { code: '57014' }) : null);
  const r1 = await a.now(layoutOf());
  assert.deepEqual(r1, { status: 'error', reason: '57014' });
  assert.equal(a.svc.stats().errors, 1);

  const b = setup();
  b.w.failWhen = (text, params, inTx) => (inTx && text === SQL.saveBase ? new Error('disk dolu') : null);
  const r2 = await b.now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.equal(r2.status, 'error');
  assert.equal(r2.reason, 'Error');
  assert.deepEqual(b.w.txLog, ['BEGIN', 'ROLLBACK']);
  assert.equal(b.w.row(b.d, 6).name, 'Mutfak Aydınlatma', 'ROLLBACK: yarim yazma kalmaz');
  assert.equal(b.svc.stats().applied, 0);
  assert.equal(b.svc.stats().renamed, 0, 'geri alinan calisma sayaclara yansimaz');
  assert.equal(b.logger.lines.filter((l) => l.startsWith('log:')).length, 0, 'geri alinan calisma "uygulandi" diye gunluklenmez');
});

test('9: plan hatasi (bozuk layout nesnesi) yakalanir; onLiveState ve syncNow firlatmaz', async () => {
  const { w, live, now, settle, svc } = setup();
  const broken = { signature: 'x', count: 8, relays: null, pairs: [], shutterPos: {} };
  assert.doesNotThrow(() => live(broken));
  await settle();
  assert.equal(svc.stats().errors, 1);
  const r = await now(broken);
  assert.equal(r.status, 'error');
  assert.equal(svc.stats().errors, 2);
  assert.deepEqual(writesIn(w), []);
});

test('9: hata uyarisi ayni tur icin 10 dakikada tek satir; ad/uid/konu/tam kimlik icermez', async () => {
  const { w, d, now, logger } = setup();
  w.failTx = Object.assign(new Error(`gizli ${UID} Mutfak Spot`), { code: '08006' });
  const layout = layoutOf({ set: { 6: { name: 'Mutfak Spot' } } });
  await now(layout);
  w.now += 6000;
  await now(layout);
  w.now += 6000;
  await now(layout);
  const warns = () => logger.lines.filter((l) => l.startsWith('warn:'));
  assert.equal(warns().length, 1);
  assert.match(warns()[0], /^warn: \[LAYOUT\] /);
  assert.ok(warns()[0].includes('08006'));
  assert.ok(warns()[0].includes(`cihaz=${d.id.slice(0, 8)}`));
  for (const l of logger.lines) {
    assert.ok(!l.includes(UID) && !l.includes('Mutfak') && !l.includes(d.id) && !l.includes(d.home_id) && !l.includes('gizli'), l);
  }
  w.now += 10 * 60 * 1000;
  await now(layout);
  assert.equal(warns().length, 2);
});

test('9: gunluk (logger) hatasi esitlemeyi bozmaz', async () => {
  const bad = {
    log() {
      throw new Error('gunluk bozuk');
    },
    warn() {
      throw new Error('gunluk bozuk');
    },
  };
  const { w, d, now, svc } = setup({ extra: { logger: bad } });
  const r = await now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.equal(r.status, 'applied');
  assert.equal(w.row(d, 6).name, 'Mutfak Spot');
  assert.equal(svc.stats().errors, 0);
  w.failTx = new Error('x');
  const r2 = await now(layoutOf({ set: { 6: { name: 'Mutfak Tezgah' } } }));
  assert.equal(r2.status, 'error');
});

// ------------------------------------------------------------------------------
// 11) stats
// ------------------------------------------------------------------------------
test('11: stats() alanlari', async () => {
  const { svc, live, settle, w } = setup();
  // D1: deferred (ertelenen degisiklikli calisma sayisi); D10: throttled (yazma butcesi asimi) eklendi
  assert.deepEqual(Object.keys(svc.stats()).sort(), [
    'applied', 'checks', 'deferred', 'deleted', 'devices', 'errors', 'inserted', 'noops', 'queue', 'rateLimited', 'renamed',
    'retyped', 'rulesDisabled', 'skipped', 'throttled',
  ]);
  const zero = svc.stats();
  for (const k of Object.keys(zero)) if (k !== 'queue') assert.equal(zero[k], 0, k);
  assert.equal(zero.queue.pending, 0);
  assert.equal(typeof zero.queue.enqueued, 'number');

  live(layoutOf({ count: 9, set: { 7: { type: 'impulse' } } }));
  await settle();
  w.now += constants.MIN_RUN_INTERVAL_MS - 1;
  live(layoutOf());
  await settle();
  const s = svc.stats();
  assert.deepEqual(
    { devices: s.devices, checks: s.checks, applied: s.applied, noops: s.noops, skipped: s.skipped, rateLimited: s.rateLimited, errors: s.errors },
    { devices: 1, checks: 1, applied: 1, noops: 0, skipped: 0, rateLimited: 1, errors: 0 }
  );
  assert.deepEqual(
    { inserted: s.inserted, retyped: s.retyped, renamed: s.renamed, deleted: s.deleted, rulesDisabled: s.rulesDisabled },
    { inserted: 1, retyped: 1, renamed: 0, deleted: 0, rulesDisabled: 0 }
  );
  assert.equal(s.queue.enqueued, 1);
  assert.equal(s.queue.pending, 0);
  // stats() kopyadir: disaridan degistirmek sayaclari bozmaz
  s.applied = 99;
  assert.equal(svc.stats().applied, 1);
});

// ------------------------------------------------------------------------------
// 12) invalidate / stop / whenIdle / syncNow
// ------------------------------------------------------------------------------
// D10 (2026-10-04): invalidate YALNIZ imza onbellegini siler; hiz siniri ayri haritada kalir (onceki beklenti
// "hiz sinirini sifirlar / ayni an hemen yeniden kontrol" D10 karariyla degisti).
test('12: invalidate(deviceId) yalniz imza onbellegini siler; hiz siniri SURER, sure dolunca ayni imza yeniden kontrol edilir', async () => {
  const { w, d, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;
  svc.invalidate(d.id);
  assert.equal(svc.stats().devices, 0);
  live(layoutOf()); // ayni an, ayni imza: hiz siniri
  await settle();
  assert.equal(w.calls.length, mark);
  assert.equal(svc.stats().rateLimited, 1);
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf()); // onbellek "tamam" yok: kilitsiz yeniden kontrol
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows']);
  assert.doesNotThrow(() => svc.invalidate('yok'));
  assert.doesNotThrow(() => svc.invalidate());
});

test('12: calisma SIRASINDA invalidate edilirse o calisma "tamam" kaydi yazmaz', async () => {
  const { w, d, live, settle, svc } = setup();
  w.beforeTx = async () => {
    svc.invalidate(d.id); // ornegin sahiplenme/sifirlama bu sirada oldu
  };
  live(layoutOf());
  await settle();
  const mark = w.calls.length;
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf());
  await settle();
  assert.ok(w.calls.length > mark, 'bayat sonuc onbellege yazilmamali; sonraki mesaj yeniden kontrol etmeli');
});

test('12: stop() sonrasi cagrilar yok sayilir; bekleyen isler atilir', async () => {
  const { w, d, live, now, settle, svc } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;
  svc.stop();
  assert.equal(svc.stats().devices, 0);
  w.now += constants.RECHECK_MS;
  assert.doesNotThrow(() => live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } })));
  const r = await now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  assert.deepEqual(r, { status: 'skipped', reason: 'stopped' });
  await settle();
  assert.equal(w.calls.length, mark);
  assert.equal(w.row(d, 6).name, 'Mutfak Aydınlatma');
  assert.equal(svc.stats().devices, 0, 'durmus servis bellek kaydi acmaz');
  assert.equal(svc.stats().queue.enqueued, 1, 'durmus servis kuyruga is atmaz');
  assert.doesNotThrow(() => svc.stop());
  assert.doesNotThrow(() => svc.invalidate(d.id));

  // kuyrukta bekleyen (baslamamis) is stop ile atilir
  const b = setup();
  let release;
  b.w.hold = new Promise((resolve) => {
    release = resolve;
  });
  b.live(layoutOf()); // calisiyor
  await new Promise((resolve) => setImmediate(resolve));
  const pending = b.now(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } })); // bekliyor
  b.svc.stop();
  b.w.hold = null;
  release();
  assert.deepEqual(await pending, { status: 'skipped', reason: 'dropped' });
  await b.settle();
  assert.equal(b.w.row(b.d, 6).name, 'Mutfak Aydınlatma');
});

test('12: whenIdle kuyruk bosalinca true doner', async () => {
  const { w, d, live, svc } = setup();
  assert.equal(await svc.whenIdle(100), true);
  live(layoutOf());
  assert.equal(w.devices.get(d.id).reported_layout, null, 'is eszamansiz');
  assert.equal(await svc.whenIdle(2000), true);
  assert.notEqual(w.devices.get(d.id).reported_layout, null);
});

test('12: syncNow onbellegi ve hiz sinirini atlar, sonucu dondurur, onbellegi doldurur', async () => {
  const { w, d, live, now, settle, svc } = setup();
  const layout = layoutOf({ set: { 7: { type: 'impulse' } } });
  const r1 = await now(layout);
  assert.equal(r1.status, 'applied');
  assert.deepEqual(r1.summary, {
    relays: 8, inserted: 0, retyped: 1, renamed: 0, reroomed: 0, deleted: 0, rulesDisabled: 0, baseSaved: true, pendingShrink: false,
  });
  assert.equal(w.row(d, 7).type, 'impulse');
  assert.equal(w.row(d, 7).name, 'Koridor Aydınlatma');

  const mark = w.calls.length;
  const r2 = await now(layout); // ayni an, ayni imza: yine de calisir
  assert.equal(r2.status, 'noop');
  assert.deepEqual(w.names(mark), ['device', 'rows']);
  assert.equal(svc.stats().rateLimited, 0);

  // syncNow onbellegi doldurdu: ardindan gelen ayni imzali canli mesaj sorgusuz
  const mark2 = w.calls.length;
  w.now += 30 * 1000;
  live(layout);
  await settle();
  assert.equal(w.calls.length, mark2);

  // gecersiz arguman: reddetmez
  assert.deepEqual(await svc.syncNow(), { status: 'skipped', reason: 'invalid_args' });
  assert.deepEqual(await svc.syncNow({ homeId: d.home_id, deviceId: d.id }), { status: 'skipped', reason: 'invalid_args' });
});

// ------------------------------------------------------------------------------
// 13) Bellek temizligi
// ------------------------------------------------------------------------------
test('13: CACHE_IDLE_MS boyunca gorulmeyen cihaz kaydi onLiveState icinde temizlenir (zamanlayici yok)', async () => {
  const timers = {
    setTimeout() {
      throw new Error('servis zamanlayici kurmamali');
    },
    clearTimeout() {},
  };
  const { w, live, settle, svc } = setup({ extra: { timers } });
  const d2 = w.addDevice({ uuid: 'AHBU-S3-FFEEDD' });
  w.seed(d2, 8);
  const live2 = () => svc.onLiveState({ topicId: 't_other', homeId: d2.home_id, deviceId: d2.id, layout: layoutOf() });
  live(layoutOf());
  live2();
  await settle();
  assert.equal(svc.stats().devices, 2);

  w.now += constants.CACHE_IDLE_MS - constants.GC_INTERVAL_MS;
  live2();
  await settle();
  assert.equal(svc.stats().devices, 2, 'sure dolmadan atilmaz');

  w.now += constants.GC_INTERVAL_MS; // ilk cihaz tam CACHE_IDLE_MS suredir sessiz; temizlik araligi da doldu
  live2();
  await settle();
  assert.equal(svc.stats().devices, 1);
  assert.equal(svc.stats().errors, 0);
});

// ------------------------------------------------------------------------------
// 14) Cevrimdisi (LWT) -> cevrimici donem biter: onbellek atilir
// ------------------------------------------------------------------------------
// Neden: acil sifirlama / pano degisimi satirlari yeniden tohumlar ve cihaz kimligini yeniler (pano atilir ->
// LWT "offline"). Pano yeni kimlikle donunce ayni imza gelir; onbellek "tamam" dese RECHECK_MS'e (5 dk) kadar
// tohum sablonu kalirdi. Canli offline bildirimi o konunun cihaz kayitlarini atar: ilk canli state hemen kontrol eder.
test('14: onOffline(topicId): o konunun cihaz kaydi atilir; sonraki canli state hemen yeniden kontrol eder', async () => {
  const { w, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;

  svc.onOffline(TOPIC);
  assert.equal(svc.stats().devices, 0, 'konunun cihaz kaydi atilmali');
  w.now += 10 * 1000; // yeniden baglanan pano ayni imzayla donuyor (hiz siniri de sifirlanmis olmali)
  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows'], 'ayni imza olsa da kilitsiz yeniden kontrol yapilmali');
  assert.equal(svc.stats().rateLimited, 0);
});

test('14: onOffline yalniz ilgili konuyu etkiler; bilinmeyen konu / bos deger / durmus servis zararsiz', async () => {
  const { w, live, settle, svc } = setup();
  const d2 = w.addDevice({ uuid: 'AHBU-S3-FFEEDD' });
  w.seed(d2, 8);
  const live2 = () => svc.onLiveState({ topicId: 't_other', homeId: d2.home_id, deviceId: d2.id, layout: layoutOf() });
  live(layoutOf());
  live2();
  await settle();
  assert.equal(svc.stats().devices, 2);

  svc.onOffline('t_other');
  assert.equal(svc.stats().devices, 1, 'yalniz t_other atilmali');
  assert.doesNotThrow(() => svc.onOffline('bilinmeyen_konu'));
  assert.doesNotThrow(() => svc.onOffline(undefined));
  assert.doesNotThrow(() => svc.onOffline(null));
  assert.doesNotThrow(() => svc.onOffline({}));
  assert.equal(svc.stats().devices, 1, 'bilinmeyen / bos konu hicbir kaydi atmamali');

  const mark = w.calls.length;
  w.now += 30 * 1000;
  live(layoutOf()); // TOPIC: onbellek hala gecerli
  await settle();
  assert.equal(w.calls.length, mark, 'baska konunun offline bildirimi bu cihazi gecersiz kilmamali');

  svc.stop();
  assert.doesNotThrow(() => svc.onOffline(TOPIC));
  assert.equal(svc.stats().errors, 0);
});

// ------------------------------------------------------------------------------
// 15) D1 - gecici (fabrika) pano korumasi
// ------------------------------------------------------------------------------
// Pano degisimi: replaceBoard satirlari yeni cihaz satirina tasir (taban NULL, devreye alinmamis). Yeni pano fabrika
// ayarinda baglaninca kullanicinin ad/oda/olculmus suresi, ek modul satirlari ve kurallari korunmalidir.
function moveUserRows(w, d) {
  w.seed(d, 16);
  Object.assign(w.row(d, 5), { name: 'Mutfak Stor Yukarı', type: 'shutter', room: 'Mutfak', shutter_pair_index: 3, shutter_duration_sec: 35 });
  Object.assign(w.row(d, 6), { name: 'Mutfak Stor Aşağı', type: 'shutter', room: 'Mutfak', shutter_pair_index: 3, shutter_duration_sec: 35 });
  Object.assign(w.row(d, 9), { name: 'Bahçe Sulama', room: 'Bahçe' });
}

test('15 D1: devreye alinmamis + taban bos + fabrika bildirimi -> satirlar/kurallar korunur, taban yazilmaz, sonraki mesajlar da erteler', async () => {
  const { w, d, live, now, settle, svc } = setup({ rows: 0 });
  moveUserRows(w, d);
  const pair3 = w.addRule(d, 'shutter', 3);
  const relay9 = w.addRule(d, 'relay', 9);
  const before = JSON.stringify(w.rowsOf(d));

  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(), ['device', 'rows'], 'uygulanacak guvenli bir sey yok: transaction acilmaz');
  assert.equal(JSON.stringify(w.rowsOf(d)), before, 'hicbir kullanici verisi degismez');
  assert.equal(d.reported_layout, null, 'taban yazilmaz');
  assert.equal(pair3.enabled, true);
  assert.equal(relay9.enabled, true);
  assert.equal(svc.stats().deferred, 1);

  // onbellege "tamam" yazilmadi: hiz siniri sonrasi ayni imza yeniden degerlendirilir; kuculme onayi da islemez
  for (const step of [constants.MIN_RUN_INTERVAL_MS, constants.SHRINK_CONFIRM_MS, constants.SHRINK_CONFIRM_MS]) {
    w.now += step;
    const mark = w.calls.length;
    live(layoutOf());
    await settle();
    assert.deepEqual(w.names(mark), ['device', 'rows']);
  }
  assert.equal(svc.stats().deferred, 4);
  assert.equal(JSON.stringify(w.rowsOf(d)), before, '9-16 silinmez');
  assert.equal(d.reported_layout, null);

  const r = await now(layoutOf());
  assert.equal(r.status, 'noop');
  assert.equal(r.summary.deferred, 10, '5-6 panjurdan roleye donus (2) + 9-16 silme (8)');
  assert.equal(r.summary.pendingShrink, false);

  // servis sorumlusu panoyu ESKI yerlesime getirdi -> normal kurallar, her sey yerinde, taban yazilir
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf({ count: 16, set: { 5: { type: 'shutter_up' }, 6: { type: 'shutter_down' } } }));
  await settle();
  assert.equal(JSON.stringify(w.rowsOf(d)), before, 'eski yerlesim: satirlar oldugu gibi');
  assert.notEqual(d.reported_layout, null, 'taban artik yazildi');
  assert.equal(pair3.enabled, true);
  assert.equal(relay9.enabled, true);
  assert.equal(w.audits.length, 0);
});

test('15 D1: gecici modda guvenli kisim (darbe -> lamba + kural kapatma) uygulanir; denetimde deferred, taban YOK', async () => {
  const { w, d, now, svc, logger } = setup({ rows: 0 });
  moveUserRows(w, d);
  Object.assign(w.row(d, 7), { name: 'Garaj Kapısı', type: 'impulse', room: 'Garaj' });
  const relay7 = w.addRule(d, 'relay', 7);
  const r = await now(layoutOf());
  assert.equal(r.status, 'applied');
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'updateRow', 'disableRules', 'audit']);
  assert.deepEqual(w.find('updateRow')[0].params, [w.row(d, 7).id, d.id, 'Garaj Kapısı', 'light', 'Garaj', null, null, null]);
  assert.equal(relay7.enabled, false);
  assert.deepEqual(w.audits[0].details, {
    relays: 8, inserted: 0, retyped: 1, renamed: 0, reroomed: 0, deleted: 0, rules_disabled: [relay7.id], deferred: 10,
  });
  assert.equal(r.summary.deferred, 10);
  assert.equal(r.summary.baseSaved, false);
  assert.equal(d.reported_layout, null);
  assert.equal(w.row(d, 5).type, 'shutter');
  assert.equal(w.rowsOf(d).length, 16);
  assert.equal(svc.stats().deferred, 1);
  const lines = logger.lines.filter((l) => l.startsWith('log:'));
  assert.equal(lines.length, 1);
  assert.ok(/ertelendi=10$/.test(lines[0]), lines[0]);
  assert.ok(!/Garaj|Mutfak|Bahçe/.test(lines[0]));
});

test('15 D1: cihaz DEVREYE ALINMISSA ayni fabrika bildirimi normal kurallarla uygulanir', async () => {
  const { w, d, now } = setup({ rows: 0, commissioned: true });
  moveUserRows(w, d);
  const pair3 = w.addRule(d, 'shutter', 3);
  const r = await now(layoutOf());
  assert.equal(r.status, 'applied');
  assert.equal(r.summary.deferred, undefined);
  assert.equal(w.row(d, 5).type, 'light');
  assert.equal(w.row(d, 5).shutter_duration_sec, null);
  assert.equal(pair3.enabled, false);
  assert.equal(r.summary.pendingShrink, true);
  assert.notEqual(d.reported_layout, null);
});

test('15 D1: taban DOLUYSA (bu cihaz satiriyla esitlenmis) fabrika bildirimi normal kurallarla uygulanir', async () => {
  const { w, d, now } = setup({ rows: 0, base: serializeBase(layoutOf({ count: 16, set: { 5: { type: 'shutter_up' }, 6: { type: 'shutter_down' } } })) });
  moveUserRows(w, d);
  const r = await now(layoutOf());
  assert.equal(r.status, 'applied');
  assert.equal(w.row(d, 5).type, 'light');
  assert.equal(r.summary.pendingShrink, true);
});

test('15 D1: ertelenecek bir sey yoksa (tohum satirlari + fabrika pano) davranis birebir normal: taban yazilir, onbellek dolar', async () => {
  const { w, d, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  assert.deepEqual(w.names(), ['device', 'rows', 'deviceLocked', 'rowsLocked', 'saveBase']);
  assert.notEqual(d.reported_layout, null);
  const mark = w.calls.length;
  w.now += 30 * 1000;
  live(layoutOf());
  await settle();
  assert.equal(w.calls.length, mark, 'onbellek tamam: sorgu yok');
  assert.equal(svc.stats().deferred, 0);
});

test('15 D1: karar KILITLI cihaz satirina gore verilir (arada devreye alindi -> normal plan)', async () => {
  const { w, d, now } = setup({ rows: 0 });
  moveUserRows(w, d);
  Object.assign(w.row(d, 7), { type: 'impulse' }); // kilitsiz gecici plan: yazilacak bir sey var
  w.beforeTx = async () => {
    d.is_commissioned = true;
  };
  const r = await now(layoutOf());
  assert.equal(r.status, 'applied');
  assert.equal(w.row(d, 5).type, 'light', 'kilitli okumada devreye alinmis: normal kural');
  assert.notEqual(d.reported_layout, null);
  assert.equal(r.summary.deferred, undefined);
});

// ------------------------------------------------------------------------------
// 16) D14 - cok panolu evde device_id NULL kural
// ------------------------------------------------------------------------------
test('16 D14: iki panolu evde device_id NULL kural kapatilmaz; tek panolu evde kapatilir', async () => {
  const a = setup();
  const d2 = a.w.addDevice({ homeId: a.d.home_id, uuid: 'AHBU-S3-FFEEDD' });
  const nullRule = a.w.addRule(a.d, 'relay', 5);
  const ownRule = a.w.addRule(a.d, 'relay', 5, { deviceId: a.d.id });
  const otherRule = a.w.addRule(a.d, 'relay', 5, { deviceId: d2.id });
  const set = { 5: { type: 'shutter_up', name: 'Salon (Yukari)' }, 6: { type: 'shutter_down', name: 'Salon (Asagi)' } };
  const r = await a.now(layoutOf({ set }));
  assert.equal(r.status, 'applied');
  assert.equal(nullRule.enabled, true);
  assert.equal(ownRule.enabled, false);
  assert.equal(otherRule.enabled, true);
  assert.deepEqual(a.w.audits[0].details.rules_disabled, [ownRule.id]);

  const b = setup();
  const single = b.w.addRule(b.d, 'relay', 5);
  await b.now(layoutOf({ set }));
  assert.equal(single.enabled, false, 'tek panolu ev: NULL kural bu panonundur');
});

// ------------------------------------------------------------------------------
// 17) D10 - kotuye kullanim / yazma butcesi
// ------------------------------------------------------------------------------
test('17 D10: onOffline hiz sinirini SIFIRLAMAZ (yeni kayit yolunda da hiz siniri); sure dolunca yeniden kontrol', async () => {
  const { w, live, settle, svc } = setup();
  live(layoutOf());
  await settle();
  const mark = w.calls.length;
  for (let i = 0; i < 4; i += 1) {
    svc.onOffline(TOPIC); // ele gecirilmis kimlik her state'ten once offline yayinliyor (1..4 sn)
    w.now += 1000;
    live(layoutOf({ set: { 6: { name: `Mutfak ${i}` } } }));
    await settle();
  }
  assert.equal(w.calls.length, mark, '5 sn icinde hicbir calisma yok');
  assert.equal(svc.stats().rateLimited, 4);
  assert.equal(svc.stats().checks, 1);
  svc.onOffline(TOPIC);
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
  await settle();
  assert.equal(svc.stats().checks, 2);
  assert.equal(svc.stats().rateLimited, 4);
});

test('17 D10: kuculme onayi onOffline ile SILINMEZ (ilk gorulme korunur)', async () => {
  const { w, d, live, settle, svc } = setup({ rows: 16, commissioned: true });
  live(layoutOf());
  await settle();
  assert.equal(w.rowsOf(d).length, 16);
  svc.onOffline(TOPIC);
  w.now += constants.SHRINK_CONFIRM_MS;
  live(layoutOf());
  await settle();
  assert.equal(w.rowsOf(d).length, 8, 'ikinci gorulme ilk gorulmeyle eslesti: silindi');
});

test('17 D10: cihaz basina saatte en cok APPLY_BUDGET_PER_HOUR satir degistiren calisma; asiminda yazma yok, saatte tek uyari', async () => {
  const { w, d, now, svc, logger } = setup();
  const N = constants.APPLY_BUDGET_PER_HOUR;
  for (let i = 0; i < N; i += 1) {
    w.now += 1000;
    const r = await now(layoutOf({ set: { 6: { name: `Mutfak ${i}` } } }));
    assert.equal(r.status, 'applied', `calisma ${i}`);
  }
  assert.equal(w.audits.length, N);
  const mark = w.calls.length;
  w.now += 1000;
  const over = await now(layoutOf({ set: { 6: { name: 'Mutfak Asim' } } }));
  assert.deepEqual(over, { status: 'skipped', reason: 'throttled' });
  assert.deepEqual(w.names(mark), ['device', 'rows'], 'butce asiminda transaction acilmaz');
  assert.equal(w.row(d, 6).name, `Mutfak ${N - 1}`);
  w.now += 1000;
  await now(layoutOf({ set: { 6: { name: 'Mutfak Asim 2' } } }));
  assert.equal(svc.stats().throttled, 2);
  const warns = logger.lines.filter((l) => l.startsWith('warn:'));
  assert.equal(warns.length, 1, 'cihaz basina saatte tek uyari');
  assert.ok(warns[0].includes(`cihaz=${d.id.slice(0, 8)}`));
  assert.ok(!warns[0].includes(d.id) && !warns[0].includes('Mutfak') && !warns[0].includes(UID), warns[0]);
  assert.equal(svc.stats().errors, 0, 'butce asimi hata sayilmaz');

  // yalniz taban degisen calisma (satir degismez) butceye takilmaz
  const mark2 = w.calls.length;
  w.now += 1000;
  const baseOnly = await now(layoutOf({ set: { 6: { name: `Mutfak ${N - 1}` }, 5: { name: 'SALON AYDINLATMA' } } }));
  assert.equal(baseOnly.status, 'applied');
  assert.deepEqual(writesIn(w, mark2), ['saveBase']);

  // pencere dolunca yeniden yazilir; uyari da yeniden yazilabilir
  w.now += 60 * 60 * 1000;
  const again = await now(layoutOf({ set: { 6: { name: 'Mutfak Yeni' } } }));
  assert.equal(again.status, 'applied');
  assert.equal(w.row(d, 6).name, 'Mutfak Yeni');
});

test('17 D10: butce asiminda onbellege "tamam" yazilmaz; butce cihaz basinadir', async () => {
  const { w, d, live, now, settle, svc } = setup();
  const d2 = w.addDevice({ uuid: 'AHBU-S3-FFEEDD' });
  w.seed(d2, 8);
  for (let i = 0; i < constants.APPLY_BUDGET_PER_HOUR; i += 1) {
    w.now += 1000;
    await now(layoutOf({ set: { 6: { name: `Mutfak ${i}` } } }));
  }
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf({ set: { 6: { name: 'Mutfak Asim' } } }));
  await settle();
  assert.equal(svc.stats().throttled, 1);
  const mark = w.calls.length;
  w.now += constants.MIN_RUN_INTERVAL_MS;
  live(layoutOf({ set: { 6: { name: 'Mutfak Asim' } } }));
  await settle();
  assert.deepEqual(w.names(mark), ['device', 'rows'], 'ayni imza yeniden degerlendirilir (onbellek tamam degil)');
  // baska cihaz etkilenmez
  const r2 = await svc.syncNow({ homeId: d2.home_id, deviceId: d2.id, layout: layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }) });
  assert.equal(r2.status, 'applied');
  assert.equal(w.row(d, 6).name, `Mutfak ${constants.APPLY_BUDGET_PER_HOUR - 1}`);
});
