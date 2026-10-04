'use strict';

// D12 - GERCEK PostgreSQL: endpoint PUT yarisi ve kilit sirasi (endpoint_service.updateEndpoint).
//
// Varsayilan olarak ATLANIR. Etkinlestirmek icin migration'lanmis (001..031) bir veritabani verin:
//
//   EV_PG_TEST_URL=postgresql://kullanici@127.0.0.1:5432/<db> node --test test/devices/endpoints_pg.test.js
//
// Her test kendi ev/cihaz/kanal satirlarini olusturur (etiketli: ev adi F4EP-<ETIKET>-n, cihaz AHBU-F4<ETIKET>-n)
// ve sonunda yalnizca bunlari siler. UYGULAMA VERITABANINA KARSI CALISTIRMAYIN.
//
// Sinanan:
//   (a) PUT {type:'plug'} kilitsiz okumadan sonra kanal panjur yapilirsa 409 CONFLICT; satir plug OLMAZ.
//   (b) Panjur suresi yolu ile esitleme benzeri transaction (devices FOR UPDATE -> endpoints ORDER BY channel_index
//       FOR UPDATE) es zamanli calisinca kilitlenme (40P01) YOK.
//   (c) Sure yolunda kilit beklerken kanal panjur olmaktan cikarsa kilit altindaki dogrulama 409 verir; sure yazilmaz.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const TAG = crypto.randomBytes(3).toString('hex').toUpperCase();
const TYPE_CHANGED = 'Kanal tipi değişti; listeyi yenileyin.';
const SEED = [
  null,
  ['Salon Panjur Yukarı', 'shutter', 'Salon', 1, 20],
  ['Salon Panjur Aşağı', 'shutter', 'Salon', 1, 20],
  ['Oda Panjur Yukarı', 'shutter', 'Oda', 2, 20],
  ['Oda Panjur Aşağı', 'shutter', 'Oda', 2, 20],
  ['Salon Aydınlatma', 'light', 'Salon', null, null],
  ['Mutfak Aydınlatma', 'light', 'Mutfak', null, null],
  ['Koridor Aydınlatma', 'light', 'Koridor', null, null],
  ['Balkon Aydınlatma', 'light', 'Balkon', null, null],
];

// Esitleme servisinin kilit sorgulari (yuklenemezse ayni metnin kopyasi; servis dosyasi DEGISTIRILMEZ).
function syncLockSql() {
  try {
    const { SQL } = require('../../src/services/endpoint_layout_sync');
    if (SQL && SQL.deviceLocked && SQL.rowsLocked) return { deviceLocked: SQL.deviceLocked, rowsLocked: SQL.rowsLocked };
  } catch (_) {
    // yedek asagida
  }
  return {
    deviceLocked: 'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout FROM devices d WHERE d.id = $1 FOR UPDATE',
    rowsLocked:
      'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
      'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index FOR UPDATE',
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function gate() {
  let open;
  const p = new Promise((r) => (open = r));
  return { p, open };
}

let ctxPromise = null;
let seq = 0;
const homes = [];

function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    const { Pool } = require('pg');
    const pool = new Pool({ connectionString: URL_, max: 10, connectionTimeoutMillis: 15000 });
    pool.on('error', () => {});

    // Kancalar: okuma (db.query) sonrasi tek seferlik; transaction icindeki ilk sorgu sonrasi tek seferlik.
    const hooks = { afterRead: null, afterFirstTxQuery: null };
    const db = {
      async query(text, params) {
        const r = await pool.query(text, params);
        if (hooks.afterRead && /JOIN homes h ON h\.id = e\.home_id/.test(text)) {
          const h = hooks.afterRead;
          hooks.afterRead = null;
          await h();
        }
        return r;
      },
      async withTransaction(fn) {
        const client = await pool.connect();
        let first = true;
        try {
          await client.query('BEGIN');
          const result = await fn({
            query: async (t, p) => {
              const r = await client.query(t, p);
              if (first) {
                first = false;
                if (hooks.afterFirstTxQuery) {
                  const h = hooks.afterFirstTxQuery;
                  hooks.afterFirstTxQuery = null;
                  await h();
                }
              }
              return r;
            },
          });
          await client.query('COMMIT');
          return result;
        } catch (err) {
          await client.query('ROLLBACK').catch(() => {});
          throw err;
        } finally {
          client.release();
        }
      },
    };

    // Cihaz onayi (expectAck, DAIRE-03): pano yayinlanan komutu uygular ('auto').
    const bridge = require('./_ack_bridge').withAckSupport({
      commands: [],
      isConnected() { return true; },
      async publishCommand(topic, obj) { this.commands.push({ topic, obj: JSON.parse(JSON.stringify(obj)) }); return {}; },
    });
    const { EndpointService } = require('../../src/services/endpoint_service');
    const endpointService = new EndpointService({ db, deviceService: {}, mqttBridge: bridge });
    return { pool, db, hooks, bridge, endpointService };
  })();
  return ctxPromise;
}

async function makeHome(c) {
  const n = ++seq;
  const home = (await c.pool.query(
    'INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id, mqtt_username',
    [`F4EP-${TAG}-${n}`, `f4ep${TAG.toLowerCase()}${n}`]
  )).rows[0];
  homes.push(home.id);
  const dev = (await c.pool.query(
    'INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed, is_online) VALUES ($1, $2, $3, TRUE, TRUE) RETURNING id',
    [home.id, `AHBU-F4${TAG}-${n}`, `F4:${TAG}:${n}`]
  )).rows[0];
  for (let ch = 1; ch <= 8; ch++) {
    const [name, type, room, pair, dur] = SEED[ch];
    await c.pool.query(
      `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [home.id, dev.id, ch, name, type, room, pair, dur]
    );
  }
  const row = async (ch) =>
    (await c.pool.query('SELECT * FROM endpoints WHERE device_id = $1 AND channel_index = $2', [dev.id, ch])).rows[0];
  const update = (ep, patch) =>
    c.endpointService.updateEndpoint({
      actor: { userId: null, globalRole: 'user', ip: '127.0.0.1', access: 'owner' },
      homeId: home.id,
      endpointId: ep.id,
      patch,
    });
  return { home, dev, row, update };
}

async function rejects(promise, status, code) {
  let caught = null;
  try {
    await promise;
  } catch (err) {
    caught = err;
  }
  assert.ok(caught, `HTTP ${status} ${code} bekleniyordu ama islem basarili oldu`);
  assert.equal(caught.status, status, `durum ${caught.status}: ${caught.message} (${caught.code})`);
  assert.equal(caught.code, code);
  return caught;
}

test.after(async () => {
  if (SKIP || !ctxPromise) return;
  const c = await ctxPromise;
  try {
    if (homes.length) {
      await c.pool.query('DELETE FROM endpoints WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.pool.query('DELETE FROM devices WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.pool.query('DELETE FROM homes WHERE id = ANY ($1::uuid[])', [homes]);
    }
    const left = (await c.pool.query('SELECT count(*)::int AS n FROM devices WHERE device_uuid LIKE $1', [`AHBU-F4${TAG}-%`])).rows[0].n;
    assert.equal(left, 0, 'test satirlari temizlenmeli');
  } finally {
    await c.pool.end();
  }
});

// ------------------------------------------------------------------------------------------------
test('(a) PUT {type:plug}: kilitsiz okumadan sonra kanal panjur yapilirsa 409 CONFLICT; satir plug OLMAZ, ad korunur', { skip: SKIP }, async () => {
  const c = await getCtx();
  const t = await makeHome(c);
  const ep5 = await t.row(5);
  c.hooks.afterRead = async () => {
    // esitleme benzeri: pano 5-6'yi panjur 3 yapti (commit edildi)
    await c.pool.query(
      `UPDATE endpoints SET type = 'shutter', shutter_pair_index = 3, shutter_duration_sec = 20, name = 'Panjur 3 Yukarı'
        WHERE device_id = $1 AND channel_index = 5`,
      [t.dev.id]
    );
  };
  const err = await rejects(t.update(ep5, { type: 'plug', name: 'Salon Priz' }), 409, 'CONFLICT');
  assert.equal(err.message, TYPE_CHANGED);
  const after = await t.row(5);
  assert.equal(after.type, 'shutter', 'panjur satirina plug yazilmamali');
  assert.equal(after.shutter_pair_index, 3);
  assert.equal(after.name, 'Panjur 3 Yukarı', 'ayni istekteki ad da yazilmaz');
});

test('(a2) yarissiz PUT: light->plug, ad/oda ve panjurda ayni tip + ad gercek PG\'de calisir (kosullu SQL gecerli)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const t = await makeHome(c);
  const r = await t.update(await t.row(5), { type: 'plug', name: 'Salon Priz' });
  assert.equal(r.type, 'plug');
  assert.equal(r.name, 'Salon Priz');
  const r2 = await t.update(await t.row(1), { type: 'shutter', name: 'Salon Panjuru', room: 'Salon 2' });
  assert.equal(r2.type, 'shutter');
  assert.equal(r2.name, 'Salon Panjuru');
  assert.equal(r2.room, 'Salon 2');
  const r3 = await t.update(await t.row(2), { shutter_duration_sec: 27, name: 'Salon Asagi' });
  assert.equal(r3.shutter_duration_sec, 27);
  assert.equal((await t.row(1)).shutter_duration_sec, 27);
  assert.equal((await t.row(3)).shutter_duration_sec, 20);
});

test('(b) sure yolu + esitleme benzeri transaction es zamanli: kilitlenme (40P01) YOK, ikisi de COMMIT', { skip: SKIP }, async () => {
  const c = await getCtx();
  const t = await makeHome(c);
  const sql = syncLockSql();
  const ep2 = await t.row(2);
  const syncClient = await c.pool.connect();
  const out = [];
  try {
    const held = gate();
    const go = gate();
    // updateEndpoint transaction'i ilk sorgusundan sonra bekler (eski kodda: ch2 UPDATE edilmis ve kilitli).
    c.hooks.afterFirstTxQuery = async () => {
      held.open();
      await go.p;
    };
    const pUpd = t.update(ep2, { shutter_duration_sec: 30, name: 'Kullanici' })
      .then(() => 'update COMMIT')
      .catch((e) => `update HATA ${e.code} ${e.status || ''}`);
    await held.p;
    const pSync = (async () => {
      await syncClient.query('BEGIN');
      try {
        await syncClient.query(sql.deviceLocked, [t.dev.id]);
        await syncClient.query(sql.rowsLocked, [t.dev.id]);
        await syncClient.query('UPDATE endpoints SET name = $2, updated_at = CURRENT_TIMESTAMP WHERE device_id = $1 AND channel_index = 7', [t.dev.id, 'Esitleme Adi']);
        await syncClient.query('COMMIT');
        return 'sync COMMIT';
      } catch (e) {
        await syncClient.query('ROLLBACK').catch(() => {});
        return `sync HATA ${e.code}`;
      }
    })();
    await sleep(300); // esitleme kanal 1 kilidinde beklemeye girsin (eski kodda: ch1 kilitli, ch2'yi bekler)
    go.open();
    out.push(...(await Promise.all([pUpd, pSync])));
  } finally {
    c.hooks.afterFirstTxQuery = null;
    syncClient.release();
  }
  assert.deepEqual(out, ['update COMMIT', 'sync COMMIT'], `sonuc: ${JSON.stringify(out)}`);
  assert.equal((await t.row(1)).shutter_duration_sec, 30);
  assert.equal((await t.row(2)).shutter_duration_sec, 30);
  assert.equal((await t.row(2)).name, 'Kullanici');
  assert.equal((await t.row(7)).name, 'Esitleme Adi');
});

test('(c) sure yolu: esitleme kanallari kilitliyken panjuru isiga cevirip commit ederse kilit altindaki dogrulama 409 verir; sure yazilmaz', { skip: SKIP }, async () => {
  const c = await getCtx();
  const t = await makeHome(c);
  const sql = syncLockSql();
  const ep1 = await t.row(1);
  const syncClient = await c.pool.connect();
  const before = c.bridge.commands.length;
  let res;
  try {
    await syncClient.query('BEGIN');
    await syncClient.query(sql.deviceLocked, [t.dev.id]);
    await syncClient.query(sql.rowsLocked, [t.dev.id]);
    await syncClient.query(
      `UPDATE endpoints SET type = 'light', shutter_pair_index = NULL, shutter_duration_sec = NULL
        WHERE device_id = $1 AND channel_index IN (1, 2)`,
      [t.dev.id]
    );
    // PUT: kilitsiz okuma eski (commit edilmis) panjur satirini gorur, yayinlar, sonra kilitte bekler.
    const pUpd = t.update(ep1, { shutter_duration_sec: 41 }).then(() => null, (e) => e);
    await sleep(300);
    await syncClient.query('COMMIT');
    res = await pUpd;
  } finally {
    syncClient.release();
  }
  assert.ok(res, 'hata bekleniyordu');
  assert.equal(res.status, 409, `durum ${res.status}: ${res.message}`);
  assert.equal(res.code, 'CONFLICT');
  assert.equal(res.message, TYPE_CHANGED);
  assert.equal(c.bridge.commands.length - before, 1, 'tasarim geregi yayin transaction oncesi yapildi');
  assert.equal((await t.row(1)).shutter_duration_sec, null);
  assert.equal((await t.row(2)).shutter_duration_sec, null);
  assert.equal((await t.row(1)).type, 'light');
});

test('(d) sure yolu: uc nokta kimligi BUYUK harfle gelse de (PG uuid harf duyarsiz) kilit altindaki dogrulama gecer', { skip: SKIP }, async () => {
  const c = await getCtx();
  const t = await makeHome(c);
  const ep2 = await t.row(2);
  const r = await c.endpointService.updateEndpoint({
    actor: { userId: null, globalRole: 'user', ip: '127.0.0.1', access: 'owner' },
    homeId: t.home.id.toUpperCase(),
    endpointId: ep2.id.toUpperCase(),
    patch: { shutter_duration_sec: 33 },
  });
  assert.equal(r.shutter_duration_sec, 33);
  assert.equal((await t.row(1)).shutter_duration_sec, 33, 'cift satiri da guncellenmeli');
  assert.equal((await t.row(2)).shutter_duration_sec, 33);
});
