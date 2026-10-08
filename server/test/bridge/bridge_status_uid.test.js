'use strict';

// guvenlik-6 + CONTRACTS 3: cok panolu evde status / state ayrimi.
//  - status yuku: duz 'online'/'offline' (eski firmware) ya da JSON {status|state, uid?} (firmware 1.3.1)
//  - uid varsa YALNIZ o cihaz guncellenir (A'nin LWT'si B'yi cevrimdisi yapmaz)
//  - uid yoksa ve evde >1 cihaz varsa ileti YOK SAYILIR (state + 120 sn supurucu karar verir); tek cihazli evde eski davranis
//  - uzlastirici / yerlesim onOffline: uid'li bildirim; cok panolu evde uid'siz offline bildirilmez
//  - state isleri pano basina birlestirilir (state:<uid>): art arda gelen A ve B state'lerinin IKISI de islenir

const test = require('node:test');
const assert = require('node:assert/strict');
const { MqttBridge, helpers } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger } = require('./_helpers');

const HOME = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const DEV_A = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: 'AHBU-S3-0A0A0A' };
const DEV_B = { home_id: HOME_ID, device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', device_uuid: 'AHBU-S3-0B0B0B' };

function setup(devices = [DEV_A, DEV_B]) {
  const db = makeFakeDb([{ match: /FROM homes h LEFT JOIN devices d/, reply: { rows: devices, rowCount: devices.length } }]);
  const logger = makeLogger();
  const offline = [];
  const layoutOffline = [];
  const spy = { onLiveState() {}, onOffline: (...a) => offline.push(a), stop() {}, stats: () => ({}) };
  const bridge = new MqttBridge({ db, logger, env: {}, now: () => 1_700_000_000_000, reconciler: spy });
  bridge._notifyLayoutSync = (method, ...a) => { if (method === 'onOffline') layoutOffline.push(a); };
  return { bridge, db, logger, offline, layoutOffline };
}
const status = (bridge, body, retain = false) => bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from(body), { retain });
const statusWrites = (db) => db.calls.filter((c) => /^UPDATE devices d/.test(c.text));

test('parseStatusPayload: duz metin + JSON {status|state, uid?}; uid buyuk harfe; gecersiz -> null', () => {
  const p = helpers.parseStatusPayload;
  assert.deepEqual(p('online'), { online: true, uid: null });
  assert.deepEqual(p(' OFFLINE \n'), { online: false, uid: null });
  assert.deepEqual(p('{"status":"offline","uid":"AHBU-S3-0A0A0A"}'), { online: false, uid: 'AHBU-S3-0A0A0A' });
  assert.deepEqual(p('{"state":"online","uid":"ahbu-s3-0b0b0b"}'), { online: true, uid: 'AHBU-S3-0B0B0B' });
  assert.deepEqual(p('{"status":"online"}'), { online: true, uid: null });
  for (const bad of ['on', '1', '', '{"online":true}', '{"status":"degraded"}', '{"status":"online","uid":"x"}', '{"status":"online","uid":5}', '[1]', 'null', '{bozuk', null, undefined]) {
    assert.equal(p(bad), null, `reddedilmeli: ${String(bad)}`);
  }
});

test('iki panolu ev: A nin JSON LWT si YALNIZ A yi cevrimdisi yapar (uid kapsamli SQL); bildirim uid li', async () => {
  const { bridge, db, offline, layoutOffline } = setup();
  await status(bridge, JSON.stringify({ status: 'offline', uid: DEV_A.device_uuid }));
  const w = statusWrites(db);
  assert.equal(w.length, 1);
  assert.match(w[0].text, /upper\(d\.device_uuid\) = upper\(\$4(::text)?\)/);
  assert.deepEqual(w[0].params, [HOME, false, false, DEV_A.device_uuid]);
  assert.deepEqual(offline, [[HOME, DEV_A.device_uuid]]);
  assert.deepEqual(layoutOffline, [[HOME, DEV_A.device_uuid]]);
  assert.equal(bridge.counters.invalid, 0);
});

test('iki panolu ev: uid SIZ offline / online YOK SAYILIR (hangi pano oldugu bilinmez); bildirim yok', async () => {
  const { bridge, db, offline, layoutOffline, logger } = setup();
  await status(bridge, 'offline');
  await status(bridge, 'online');
  assert.equal(statusWrites(db).length, 0);
  assert.deepEqual(offline, []);
  assert.deepEqual(layoutOffline, []);
  assert.equal(bridge.counters.ignored, 2);
  assert.equal(logger.lines.filter((l) => /uid/.test(l) && l.startsWith('warn:')).length, 1, 'bir kez uyari');
});

test('tek panolu ev: duz offline eskisi gibi (3 parametreli SQL, uzlastirici bildirimi)', async () => {
  const { bridge, db, offline } = setup([DEV_A]);
  await status(bridge, 'offline');
  const w = statusWrites(db);
  assert.equal(w.length, 1);
  assert.deepEqual(w[0].params, [HOME, false, false]);
  assert.doesNotMatch(w[0].text, /device_uuid/);
  assert.deepEqual(offline, [[HOME, null]]);
});

test('art arda gelen A ve B state lerinin IKISI de islenir (pano basina birlestirme); ayni panonun bekleyeni birlesir', async () => {
  const { bridge, db } = setup();
  let release;
  const gate = new Promise((r) => (release = r));
  let first = true;
  db.addRule({
    match: /FROM homes h LEFT JOIN devices d/,
    reply: () => {
      if (first) {
        first = false;
        return gate.then(() => ({ rows: [DEV_A, DEV_B], rowCount: 2 }));
      }
      return { rows: [DEV_A, DEV_B], rowCount: 2 };
    },
  });
  const st = (dev, id) => bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.from(JSON.stringify({ uid: dev.device_uuid, last_id: id })), { retain: false });
  const p0 = st(DEV_A, 'a0');
  await new Promise((r) => setImmediate(r));
  const p1 = st(DEV_A, 'a1');
  const p2 = st(DEV_B, 'b1');
  const p3 = st(DEV_B, 'b2'); // B'nin bekleyeni (b1) birlesir
  release();
  await Promise.all([p0, p1, p2, p3]);
  const seq = db.calls.filter((c) => /^UPDATE devices SET/.test(c.text)).map((c) => [c.params[0], c.params[c.params.length - 1]]);
  assert.deepEqual(seq, [[DEV_A.device_id, 'a0'], [DEV_A.device_id, 'a1'], [DEV_B.device_id, 'b2']]);
});
