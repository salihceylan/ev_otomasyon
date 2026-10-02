'use strict';

// C8 - Kopru: gelen mesaj isleme (retain farkindaligi, cihaz esleme, toplu guncelleme,
// durum/LWT, bozuk girdi dayanikliligi).

const test = require('node:test');
const assert = require('node:assert/strict');
const { MqttBridge } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger } = require('./_helpers');

const HOME = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const DEV_A = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: 'AHBU-S3-0001' };
const DEV_B = { home_id: HOME_ID, device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', device_uuid: 'AHBU-S3-0002' };

function setup(homeRows) {
  const rowsByTopic = { [HOME]: homeRows };
  const db = makeFakeDb([
    {
      match: /FROM homes h LEFT JOIN devices d/,
      reply: (_t, params) => ({ rows: rowsByTopic[params[0]] || [], rowCount: (rowsByTopic[params[0]] || []).length }),
    },
  ]);
  const logger = makeLogger();
  const bridge = new MqttBridge({ db, logger, env: {}, now: () => 1_700_000_000_000 });
  return { bridge, db, logger };
}

const stateMsg = (obj) => Buffer.from(JSON.stringify(obj));
const writes = (db) => db.calls.filter((c) => /^UPDATE /.test(c.text));

test('canli state: cihaz telemetri + role + panjur TEK transaction icinde, cevrimici isaretlenir', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(
    `ev/${HOME}/state`,
    stateMsg({
      v: 2,
      uid: 'ahbu-s3-0001',
      fw: '1.1.0',
      ip: '192.168.1.30',
      child_lock: false,
      last_id: 'cmd-42',
      relays: [{ id: 1, state: true }, { id: 3, state: false }],
      shutters: [{ pair: 1, pos: 55 }],
    }),
    { retain: false }
  );

  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
  const w = writes(db);
  assert.equal(w.length, 4, 'cihaz + role + panjur + ev cocuk kilidi esitlemesi');
  assert.ok(w.every((c) => c.inTx), 'tum yazimlar transaction icinde olmali');

  const [dev, relays, shutters, homeSync] = w;
  // C9: cocuk kilidi tek dogruluk kaynagi cihaz; ayni transaction'da homes esitlenir
  assert.match(homeSync.text, /^UPDATE homes h SET child_lock_enabled = s\.v/);
  assert.deepEqual(homeSync.params, [HOME_ID]);
  assert.match(dev.text, /^UPDATE devices SET/);
  assert.match(dev.text, /is_online = TRUE/);
  assert.match(dev.text, /last_seen_at = CURRENT_TIMESTAMP/);
  assert.deepEqual(dev.params, [DEV_A.device_id, '192.168.1.30', '1.1.0', false, 'cmd-42']);
  assert.match(relays.text, /UPDATE endpoints e SET current_state/);
  assert.deepEqual(relays.params, [DEV_A.device_id, 1, true, 3, false]);
  assert.match(shutters.text, /SET current_position/);
  assert.deepEqual(shutters.params, [DEV_A.device_id, 1, 55]);
});

test('RETAINED state: yalnizca endpoint + ip/fw gunceller; is_online / last_seen / ack DEGISMEZ', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(
    `ev/${HOME}/state`,
    stateMsg({
      ip: '192.168.1.30',
      fw: '1.1.0',
      last_id: 'old-id',
      relays: [{ id: 1, state: true }],
      shutters: [{ pair: 1, pos: 20 }],
    }),
    { retain: true }
  );
  const w = writes(db);
  assert.equal(w.length, 3);
  const all = w.map((c) => c.text).join('\n');
  assert.doesNotMatch(all, /is_online/);
  assert.doesNotMatch(all, /last_seen_at/);
  assert.doesNotMatch(all, /last_ack/);
  assert.equal(bridge.counters.retained, 1);
});

test('C9 cocuk kilidi: CANLI state devices.child_lock_enabled yazar ve ayni transaction icinde homes tablosunu esitler', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ child_lock: true }), { retain: false });
  const w = writes(db);
  assert.equal(w.length, 2);
  assert.match(w[0].text, /child_lock_enabled = \$2/);
  assert.deepEqual(w[0].params, [DEV_A.device_id, true]);
  assert.match(w[1].text, /^UPDATE homes h SET child_lock_enabled = s\.v/);
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
  assert.ok(w.every((c) => c.inTx));
});

test('C9 cocuk kilidi: RETAINED state kilidi YAZMAZ (cevrimici koruma SQL kosulunda); satir degismezse homes esitlenmez', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ child_lock: false }), { retain: true });
  const w = writes(db);
  // yalnizca uzlastirma ifadesi: cevrimici panoda SQL kosulu (is_online IS NOT TRUE) satiri degistirmez
  assert.equal(w.length, 1);
  assert.match(w[0].text, /is_online IS NOT TRUE/);
  // rowCount 0 (satir degismedi: pano cevrimici ya da zaten ayni) -> homes esitlemesi YOK
  assert.equal(w.some((c) => /UPDATE homes/.test(c.text)), false);
});

test('C9 cocuk kilidi: CEVRIMDISI panoda retained uzlastirma satiri degistirirse homes de esitlenir', async () => {
  const { bridge, db } = setup([DEV_A]);
  db.addRule({ match: /is_online IS NOT TRUE/, reply: { rows: [], rowCount: 1 } }); // pano cevrimdisiydi: satir degisti
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ child_lock: true, relays: [{ id: 1, state: false }] }), { retain: true });
  const w = writes(db);
  assert.match(w[0].text, /is_online IS NOT TRUE/);
  assert.deepEqual(w[0].params, [DEV_A.device_id, true]);
  assert.ok(w.some((c) => /UPDATE homes h SET child_lock_enabled/.test(c.text)), 'homes esitlenmeli');
  assert.ok(w.every((c) => c.inTx));
});

test('C9 last_id bos dizge (taze pano): uyari ve gecersiz sayaci YOK, ack yazilmaz', async () => {
  const { bridge, db, logger } = setup([DEV_A]);
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ last_id: '', relays: [{ id: 1, state: true }] }), { retain: false });
  assert.equal(logger.lines.filter((l) => l.startsWith('warn:')).length, 0, 'her kalp atisinda uyari uretmemeli');
  assert.equal(bridge.counters.invalid, 0);
  const dev = writes(db).find((c) => /UPDATE devices SET/.test(c.text));
  assert.doesNotMatch(dev.text, /last_ack/);
});

test('RETAINED state yalnizca endpoint iceriyorsa cihaz satiri HIC yazilmaz', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ relays: [{ id: 2, state: true }] }), { retain: true });
  const w = writes(db);
  assert.equal(w.length, 1);
  assert.match(w[0].text, /UPDATE endpoints/);
});

test('cihaz eslemesi uid ile: iki cihazli evde dogru cihaz secilir', async () => {
  const { bridge, db } = setup([DEV_A, DEV_B]);
  await bridge.handleIncomingMessage(
    `ev/${HOME}/state`,
    stateMsg({ uid: 'AHBU-S3-0002', relays: [{ id: 1, state: true }] }),
    { retain: false }
  );
  const w = writes(db);
  assert.ok(w.length >= 2);
  assert.ok(w.every((c) => c.params[0] === DEV_B.device_id), 'yalniz ikinci cihaz guncellenmeli');
});

test('uid bu eve ait degilse mesaj atilir (baska evin cihazi etkilenemez)', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(
    `ev/${HOME}/state`,
    stateMsg({ uid: 'AHBU-S3-9999', relays: [{ id: 1, state: true }] }),
    { retain: false }
  );
  assert.equal(writes(db).length, 0);
  assert.equal(bridge.counters.ignored, 1);
});

test('uid yok: evin tek cihazi kullanilir; birden cok / hic cihaz yoksa atilir', async () => {
  const one = setup([DEV_A]);
  await one.bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ relays: [{ id: 1, state: true }] }), {});
  assert.equal(writes(one.db).length >= 1, true);
  assert.equal(writes(one.db)[0].params[0], DEV_A.device_id);

  const many = setup([DEV_A, DEV_B]);
  await many.bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ relays: [{ id: 1, state: true }] }), {});
  assert.equal(writes(many.db).length, 0, 'belirsiz: atilmali');

  const none = setup([{ home_id: HOME_ID, device_id: null, device_uuid: null }]);
  await none.bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ relays: [{ id: 1, state: true }] }), {});
  assert.equal(writes(none.db).length, 0);
});

test('bilinmeyen ev konusu: yazim yok, hata yok', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage('ev/h_bilinmeyen0000000/state', stateMsg({ relays: [{ id: 1, state: true }] }), {});
  assert.equal(writes(db).length, 0);
  assert.equal(db.txLog.length, 0, 'bilinmeyen konu icin transaction acilmamali');
});

test('bozuk / buyuk / gecersiz mesajlar: istisna yok, veritabani cagrisi yok', async () => {
  const { bridge, db, logger } = setup([DEV_A]);
  const secret = 'GIZLI-DEGER-123';
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.from(`{"relays": [ ${secret} `), {}); // bozuk JSON
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.from('null'), {}); // kok nesne degil
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.from('[1,2,3]'), {});
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.alloc(64 * 1024 + 1, 0x41), {}); // 64 KB + 1
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.alloc(0), {}); // bos (clearRetained yankisi)
  await bridge.handleIncomingMessage(`ev/${HOME}/cmd`, stateMsg({ relay: 1, state: true }), {}); // backend konusu
  await bridge.handleIncomingMessage('ev/a/b/c/d', stateMsg({}), {});
  await bridge.handleIncomingMessage(undefined, undefined, undefined);
  assert.equal(db.calls.length, 0);
  assert.equal(bridge.counters.invalid, 3);
  assert.equal(bridge.counters.oversize, 1);
  assert.ok(bridge.counters.ignored >= 4);
  assert.ok(!logger.lines.join('\n').includes(secret), 'yuk icerigi log\'a sizmamali');
});

test('gecerli ama kismen bozuk state: gecerli kisimlar uygulanir, gecersizler atlanir', async () => {
  const { bridge, db } = setup([DEV_A]);
  await bridge.handleIncomingMessage(
    `ev/${HOME}/state`,
    stateMsg({
      relays: [{ id: 1, state: 'ON' }, { id: 2, state: true }],
      shutters: [{ pair: 1, pos: 300 }, { pair: 2, pos: 10 }],
    }),
    {}
  );
  const w = writes(db);
  const relay = w.find((c) => /current_state/.test(c.text));
  const shutter = w.find((c) => /current_position/.test(c.text));
  assert.deepEqual(relay.params, [DEV_A.device_id, 2, true]);
  assert.deepEqual(shutter.params, [DEV_A.device_id, 2, 10]);
});

test('status: canli online/offline ve retained davranisi', async () => {
  const { bridge, db } = setup([DEV_A]);

  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('online'), { retain: false });
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('offline'), { retain: false });
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('online'), { retain: true });

  const w = writes(db);
  assert.equal(w.length, 3);
  assert.deepEqual(w[0].params, [HOME, true, false]); // canli online
  assert.deepEqual(w[1].params, [HOME, false, false]); // canli offline (LWT)
  assert.deepEqual(w[2].params, [HOME, true, true]); // retained online
  // SQL: last_seen_at yalnizca CANLI online'da ilerler
  assert.match(w[0].text, /last_seen_at = CASE WHEN \$2::boolean AND NOT \$3::boolean THEN CURRENT_TIMESTAMP/);
  assert.match(w[0].text, /h\.mqtt_username = \$1/);
});

test('status: gecersiz yuk atilir ("on", JSON, bos olmayan baska metin)', async () => {
  const { bridge, db } = setup([DEV_A]);
  for (const bad of ['on', '1', '{"online":true}', 'ONLINE!', 'degraded']) {
    await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from(bad), {});
  }
  assert.equal(db.calls.length, 0);
  assert.equal(bridge.counters.invalid, 5);
});

test('veritabani hatasi: islenmeyen istisna yok, transaction ROLLBACK, sayac artar', async () => {
  const { bridge, db, logger } = setup([DEV_A]);
  db.addRule({ match: /UPDATE endpoints e SET current_state/, reply: new Error('baglanti kesildi') });
  await bridge.handleIncomingMessage(
    `ev/${HOME}/state`,
    stateMsg({ relays: [{ id: 1, state: true }], ip: '10.0.0.2' }),
    { retain: false }
  );
  assert.deepEqual(db.txLog, ['BEGIN', 'ROLLBACK']);
  assert.equal(bridge.counters.dbErrors, 1);
  assert.ok(logger.lines.some((l) => l.includes('State guncelleme hatasi')));
});

test('status icin veritabani hatasi de yutulur ve sayilir', async () => {
  const { bridge, db } = setup([DEV_A]);
  db.addRule({ match: /UPDATE devices d/, reply: new Error('x') });
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('online'), {});
  assert.equal(bridge.counters.dbErrors, 1);
});

test('ayni evin mesajlari sirayla islenir; bekleyen eski state yenisiyle birlestirilir', async () => {
  const { bridge, db } = setup([DEV_A]);
  // Ilk state'in cihaz sorgusunu bekleterek kuyrugu mesgul tut.
  let release;
  const gate = new Promise((r) => (release = r));
  let first = true;
  db.addRule({
    match: /FROM homes h LEFT JOIN devices d/,
    reply: () => {
      if (first) {
        first = false;
        return gate.then(() => ({ rows: [DEV_A], rowCount: 1 }));
      }
      return { rows: [DEV_A], rowCount: 1 };
    },
  });

  const mk = (n) =>
    bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ relays: [{ id: 1, state: n % 2 === 0 }], last_id: `m${n}` }), {});
  const p0 = mk(0);
  await new Promise((r) => setImmediate(r));
  const p1 = mk(1);
  const p2 = mk(2);
  const p3 = mk(3);
  release();
  await Promise.all([p0, p1, p2, p3]);

  const ackIds = db.calls.filter((c) => /UPDATE devices SET/.test(c.text)).map((c) => c.params[c.params.length - 1]);
  assert.deepEqual(ackIds, ['m0', 'm3'], 'm1 ve m2 birlestirilip yalnizca en yenisi (m3) uygulanmali');
});

test('status araya girerse state birlesmesi sirayi bozmaz (offline sonrasi gelen state onu ezemez)', async () => {
  const { bridge, db } = setup([DEV_A]);
  let release;
  const gate = new Promise((r) => (release = r));
  let first = true;
  db.addRule({
    match: /FROM homes h LEFT JOIN devices d/,
    reply: () => {
      if (first) {
        first = false;
        return gate.then(() => ({ rows: [DEV_A], rowCount: 1 }));
      }
      return { rows: [DEV_A], rowCount: 1 };
    },
  });
  const p0 = bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ last_id: 's0' }), {});
  await new Promise((r) => setImmediate(r));
  const p1 = bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ last_id: 's1' }), {});
  const p2 = bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('offline'), {});
  const p3 = bridge.handleIncomingMessage(`ev/${HOME}/state`, stateMsg({ last_id: 's3' }), {});
  release();
  await Promise.all([p0, p1, p2, p3]);
  const seq = db.calls
    .filter((c) => /UPDATE devices/.test(c.text))
    .map((c) => (/last_ack_id = \$/.test(c.text) ? c.params[c.params.length - 1] : 'status'));
  assert.deepEqual(seq, ['s0', 's1', 'status', 's3']);
});
