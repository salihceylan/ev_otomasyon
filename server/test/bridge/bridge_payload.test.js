'use strict';

// C8 - Kopru: konu/yuk dogrulama ve toplu guncelleme SQL uretimi.

const test = require('node:test');
const assert = require('node:assert/strict');
const { helpers, KeyedWorkQueue } = require('../../src/mqtt_bridge');

const {
  isValidTopicId,
  parseIncomingTopic,
  parseStatusPayload,
  validateStatePayload,
  buildRelayStateUpdate,
  buildShutterPositionUpdate,
  buildDeviceUpdate,
  buildChildLockReconcile,
  buildHomeChildLockSync,
  serializeCommand,
} = helpers;

test('parseIncomingTopic: yalnizca ev/{id}/state|status kabul edilir', () => {
  assert.deepEqual(parseIncomingTopic('ev/h_0123456789abcdef/state'), { topicId: 'h_0123456789abcdef', kind: 'state' });
  assert.deepEqual(parseIncomingTopic('ev/home_101/status'), { topicId: 'home_101', kind: 'status' });
  for (const bad of [
    'ev/h_x/cmd', // backend konusu: gelen olarak islenmez
    'ev/h_x/sys',
    'ev/h_x/state/extra',
    'ev//state',
    'ev/h x/state',
    'ev/h_x/#',
    'ev/+/state',
    'ahbu/h_x/state',
    '',
    null,
    undefined,
    42,
  ]) {
    assert.equal(parseIncomingTopic(bad), null, `reddedilmeli: ${String(bad)}`);
  }
});

test('isValidTopicId: joker karakter / bosluk / eik cizgi yok', () => {
  assert.equal(isValidTopicId('h_0123456789abcdef'), true);
  assert.equal(isValidTopicId('home_101'), true);
  for (const bad of ['', 'a/b', 'a+b', 'a#', 'a b', '..', 'x'.repeat(65), null, 7]) {
    assert.equal(isValidTopicId(bad), false, `reddedilmeli: ${String(bad)}`);
  }
});

test('parseStatusPayload: duz online/offline (eski firmware) -> {online, uid:null}; JSON durumu bridge_status_uid.test.js', () => {
  assert.deepEqual(parseStatusPayload('online'), { online: true, uid: null });
  assert.deepEqual(parseStatusPayload(' ONLINE \n'), { online: true, uid: null });
  assert.deepEqual(parseStatusPayload('offline'), { online: false, uid: null });
  assert.deepEqual(parseStatusPayload('Offline'), { online: false, uid: null });
  // guvenlik-6: JSON {status|state, uid?} artik gecerli (firmware 1.3.1)
  assert.deepEqual(parseStatusPayload('{"status":"online"}'), { online: true, uid: null });
  for (const bad of ['', 'on', 'true', '1', 'online!', '{"online":true}', null, undefined]) {
    assert.equal(parseStatusPayload(bad), null, `reddedilmeli: ${String(bad)}`);
  }
});

test('validateStatePayload: tam ve gecerli yuk', () => {
  const r = validateStatePayload({
    v: 2,
    uid: 'ahbu-s3-0001',
    fw: '1.1.0',
    seq: 1234,
    uptime: 3600,
    ip: '192.168.1.30',
    child_lock: false,
    last_id: 'abc123',
    relays: [
      { id: 1, name: 'Salon', type: 'light', state: true },
      { id: 2, state: false },
    ],
    shutters: [{ pair: 1, pos: 100, moving: false, dir: 0, target: 255 }],
    dis: [{ id: 1, state: false }],
  });
  assert.equal(r.ok, true);
  assert.equal(r.value.uid, 'AHBU-S3-0001'); // buyuk harfe normalize
  assert.equal(r.value.fw, '1.1.0');
  assert.equal(r.value.ip, '192.168.1.30');
  assert.equal(r.value.childLock, false);
  assert.equal(r.value.lastId, 'abc123');
  assert.deepEqual(r.value.relays, [{ id: 1, state: true }, { id: 2, state: false }]);
  assert.deepEqual(r.value.shutters, [{ pair: 1, pos: 100 }]);
  assert.equal(r.value.skipped, 0);
});

test('validateStatePayload: kok nesne degilse reddedilir', () => {
  for (const bad of [null, undefined, 5, 'x', true, [], [1, 2]]) {
    const r = validateStatePayload(bad);
    assert.equal(r.ok, false, `reddedilmeli: ${JSON.stringify(bad)}`);
  }
});

test('validateStatePayload: state yalnizca boolean ("ON" / 1 / "true" KABUL EDILMEZ)', () => {
  const r = validateStatePayload({
    relays: [
      { id: 1, state: 'ON' },
      { id: 2, state: 1 },
      { id: 3, state: 'true' },
      { id: 4, state: null },
      { id: 5, state: true },
    ],
  });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.relays, [{ id: 5, state: true }]);
  assert.equal(r.value.skipped, 4);
});

test('validateStatePayload: role id araligi ve tamsayi kurali', () => {
  const r = validateStatePayload({
    relays: [
      { id: 0, state: true }, // 1 tabanli: 0 gecersiz
      { id: 65, state: true }, // ust sinir asildi
      { id: 1.5, state: true },
      { id: '3', state: true }, // string kimlik
      { id: -1, state: true },
      { id: 64, state: false },
      { id: 1, state: true },
    ],
  });
  assert.deepEqual(r.value.relays.map((x) => x.id).sort((a, b) => a - b), [1, 64]);
  assert.equal(r.value.skipped, 5);
});

test('validateStatePayload: panjur pair 1 tabanli, pos 0..100 tamsayi', () => {
  const r = validateStatePayload({
    shutters: [
      { pair: 0, pos: 10 },
      { pair: 1, pos: -1 },
      { pair: 1, pos: 101 },
      { pair: 1, pos: 50.5 },
      { pair: 1, pos: '50' },
      { pair: 2, pos: 256 }, // 256 -> 0 kesmesi YOK: reddedilir
      { pair: 33, pos: 10 },
      { pair: 2, pos: 0 },
      { pair: 3, pos: 100 },
    ],
  });
  assert.deepEqual(r.value.shutters, [{ pair: 2, pos: 0 }, { pair: 3, pos: 100 }]);
  assert.equal(r.value.skipped, 7);
});

test('validateStatePayload: ayni id tekrarlanirsa sonuncu gecerli (UPDATE...FROM belirsizligi onlenir)', () => {
  const r = validateStatePayload({
    relays: [
      { id: 1, state: true },
      { id: 1, state: false },
    ],
    shutters: [
      { pair: 1, pos: 10 },
      { pair: 1, pos: 90 },
    ],
  });
  assert.deepEqual(r.value.relays, [{ id: 1, state: false }]);
  assert.deepEqual(r.value.shutters, [{ pair: 1, pos: 90 }]);
});

test('validateStatePayload: diziler 64 ogeyle sinirlanir', () => {
  const relays = Array.from({ length: 200 }, (_, i) => ({ id: (i % 64) + 1, state: true }));
  const r = validateStatePayload({ relays });
  assert.equal(r.ok, true);
  assert.ok(r.value.relays.length <= 64);
  assert.ok(r.value.skipped >= 1);
});

test('validateStatePayload: ip / fw / uid / last_id / child_lock tip denetimi', () => {
  const bad = validateStatePayload({
    ip: '999.1.1.1',
    fw: 'x'.repeat(40),
    uid: 'a b',
    last_id: 'x'.repeat(25),
    child_lock: 'false',
  });
  assert.equal(bad.ok, true);
  assert.equal(bad.value.ip, null);
  assert.equal(bad.value.fw, null);
  assert.equal(bad.value.uid, null);
  assert.equal(bad.value.lastId, null);
  assert.equal(bad.value.childLock, null);
  assert.equal(bad.value.skipped, 5);

  const good = validateStatePayload({ ip: 'fe80::1', fw: 'v1.0.0', last_id: 'sr12-ab:cd', child_lock: true });
  assert.equal(good.value.ip, 'fe80::1');
  assert.equal(good.value.fw, 'v1.0.0');
  assert.equal(good.value.lastId, 'sr12-ab:cd');
  assert.equal(good.value.childLock, true);
});

test('validateStatePayload: last_id BOS DIZGE (taze pano) gecerli sayilir: uyari uretmez, ack yok', () => {
  const r = validateStatePayload({ last_id: '', relays: [{ id: 1, state: true }] });
  assert.equal(r.ok, true);
  assert.equal(r.value.lastId, null);
  assert.equal(r.value.skipped, 0, 'bos last_id atlanan alan sayilmamali');
  // gercekten bozuk degerler hala atlanir
  for (const bad of ['a b', 'x'.repeat(25), 5, null, {}, true]) {
    const b = validateStatePayload({ last_id: bad });
    assert.equal(b.value.skipped, 1, `atlanmali: ${JSON.stringify(bad)}`);
    assert.equal(b.value.lastId, null);
  }
});

test('validateStatePayload: relays/shutters dizi degilse atlanir', () => {
  const r = validateStatePayload({ relays: { id: 1, state: true }, shutters: 'x' });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.relays, []);
  assert.deepEqual(r.value.shutters, []);
  assert.equal(r.value.skipped, 2);
});

test('buildRelayStateUpdate: toplu UPDATE ... FROM (VALUES ...) + IS DISTINCT FROM', () => {
  assert.equal(buildRelayStateUpdate('dev-1', []), null);
  const q = buildRelayStateUpdate('dev-1', [
    { id: 1, state: true },
    { id: 2, state: false },
    { id: 8, state: true },
  ]);
  assert.deepEqual(q.values, ['dev-1', 1, true, 2, false, 8, true]);
  assert.match(q.text, /^UPDATE endpoints e SET current_state = v\.state/);
  assert.match(q.text, /FROM \(VALUES \(\$2::int, \$3::boolean\), \(\$4::int, \$5::boolean\), \(\$6::int, \$7::boolean\)\) AS v\(channel, state\)/);
  assert.match(q.text, /WHERE e\.device_id = \$1 AND e\.channel_index = v\.channel/);
  assert.match(q.text, /e\.current_state IS DISTINCT FROM v\.state/);
  // kullanici girdisi SQL metnine KATILMAZ (yalnizca $n yer tutucular; dogrudan deger yok)
  assert.doesNotMatch(q.text, /\b(true|false)\b/i);
});

test('buildShutterPositionUpdate: pair eslemesi ve yedek (2N-1/2N) kurali', () => {
  assert.equal(buildShutterPositionUpdate('dev-1', []), null);
  const q = buildShutterPositionUpdate('dev-1', [
    { pair: 1, pos: 40 },
    { pair: 2, pos: 0 },
  ]);
  assert.deepEqual(q.values, ['dev-1', 1, 40, 2, 0]);
  assert.match(q.text, /AS v\(pair, pos\)/);
  assert.match(q.text, /e\.type = 'shutter'/);
  assert.match(q.text, /e\.shutter_pair_index = v\.pair/);
  assert.match(q.text, /e\.shutter_pair_index IS NULL AND e\.channel_index IN \(v\.pair \* 2 - 1, v\.pair \* 2\)/);
  assert.match(q.text, /e\.current_position IS DISTINCT FROM v\.pos/);
});

test('buildDeviceUpdate: canli mesaj cevrimici + last_seen + ack; retained DEGIL', () => {
  const v = { ip: '10.0.0.5', fw: '1.2.0', childLock: true, lastId: 'abc' };

  const live = buildDeviceUpdate('dev-1', v, true);
  assert.match(live.text, /is_online = TRUE/);
  assert.match(live.text, /last_seen_at = CURRENT_TIMESTAMP/);
  assert.match(live.text, /ip_address = \$2/);
  assert.match(live.text, /firmware_version = \$3/);
  assert.match(live.text, /child_lock_enabled = \$4/);
  assert.match(live.text, /last_ack_id = \$5/);
  assert.match(live.text, /last_ack_at = CASE WHEN last_ack_id IS DISTINCT FROM \$5/);
  assert.deepEqual(live.values, ['dev-1', '10.0.0.5', '1.2.0', true, 'abc']);

  const retained = buildDeviceUpdate('dev-1', v, false);
  assert.doesNotMatch(retained.text, /is_online/);
  assert.doesNotMatch(retained.text, /last_seen_at/);
  assert.doesNotMatch(retained.text, /last_ack/);
  // C9: bayat retained cocuk kilidini YAZMAZ (yeni uygulanmis komutu ezmesin)
  assert.doesNotMatch(retained.text, /child_lock_enabled/);
  assert.match(retained.text, /IS DISTINCT FROM/); // gereksiz yazim yok
  assert.deepEqual(retained.values, ['dev-1', '10.0.0.5', '1.2.0']);
});

test('buildDeviceUpdate: yalnizca cocuk kilidi iceren RETAINED state cihaz satirini yazmaz', () => {
  assert.equal(buildDeviceUpdate('d', { ip: null, fw: null, childLock: true, lastId: null }, false), null);
});

test('buildChildLockReconcile: retained uzlastirma yalnizca CEVRIMDISI/bilinmeyen panoda ve degisiklik varsa', () => {
  const q = buildChildLockReconcile('dev-1', true);
  assert.equal(
    q.text,
    'UPDATE devices SET child_lock_enabled = $2 WHERE id = $1 AND is_online IS NOT TRUE AND child_lock_enabled IS DISTINCT FROM $2'
  );
  assert.deepEqual(q.values, ['dev-1', true]);
  assert.deepEqual(buildChildLockReconcile('dev-1', false).values, ['dev-1', false]);
  for (const bad of [null, undefined, 'true', 1, 0]) assert.equal(buildChildLockReconcile('dev-1', bad), null);
});

test('buildHomeChildLockSync: ev kilidi = cihazlarin bool_and degeri; cihaz yoksa (NULL) DEGISMEZ', () => {
  const q = buildHomeChildLockSync('home-1');
  assert.deepEqual(q.values, ['home-1']);
  assert.match(q.text, /^UPDATE homes h SET child_lock_enabled = s\.v FROM \(SELECT bool_and\(COALESCE\(d\.child_lock_enabled, FALSE\)\) AS v FROM devices d WHERE d\.home_id = \$1\) s /);
  assert.match(q.text, /WHERE h\.id = \$1 AND s\.v IS NOT NULL AND h\.child_lock_enabled IS DISTINCT FROM s\.v$/);
});

test('buildDeviceUpdate: retained ve alan yoksa guncelleme uretilmez; canli ise yine last_seen', () => {
  const empty = { ip: null, fw: null, childLock: null, lastId: null };
  assert.equal(buildDeviceUpdate('d', empty, false), null);
  const live = buildDeviceUpdate('d', empty, true);
  assert.equal(live.text, 'UPDATE devices SET is_online = TRUE, last_seen_at = CURRENT_TIMESTAMP WHERE id = $1');
  assert.deepEqual(live.values, ['d']);
});

test('serializeCommand: nesne zorunlu ve 1024 bayt siniri', () => {
  assert.equal(serializeCommand({ relay: 3, state: true }), '{"relay":3,"state":true}');
  assert.throws(() => serializeCommand(null), TypeError);
  assert.throws(() => serializeCommand([1]), TypeError);
  assert.throws(() => serializeCommand('x'), TypeError);
  assert.throws(() => serializeCommand({ pad: 'x'.repeat(2000) }), RangeError);
});

// -- Anahtarli is kuyrugu ------------------------------------------------------

function deferred() {
  let resolve;
  const promise = new Promise((r) => (resolve = r));
  return { promise, resolve };
}

test('KeyedWorkQueue: ayni anahtar sirali, farkli anahtarlar sinirli es zamanli', async () => {
  const q = new KeyedWorkQueue({ concurrency: 2 });
  const order = [];
  const gates = { a1: deferred(), a2: deferred(), b1: deferred(), c1: deferred() };
  let running = 0;
  let maxRunning = 0;
  const job = (name) => async () => {
    running++;
    maxRunning = Math.max(maxRunning, running);
    order.push(`start:${name}`);
    await gates[name].promise;
    order.push(`end:${name}`);
    running--;
  };
  const pa1 = q.push('A', 'status', job('a1'));
  const pa2 = q.push('A', 'status', job('a2'));
  const pb1 = q.push('B', 'status', job('b1'));
  const pc1 = q.push('C', 'status', job('c1'));
  await new Promise((r) => setImmediate(r));
  // concurrency=2: a1 ve b1 calisir; a2 (ayni anahtar) ve c1 bekler
  assert.deepEqual(order, ['start:a1', 'start:b1']);
  gates.a1.resolve();
  await new Promise((r) => setImmediate(r));
  assert.ok(order.includes('end:a1'));
  // a1 bitince FIFO adaleti geregi sirada bekleyen farkli anahtar (C) one gecebilir;
  // ama A'nin ikinci isi, birincisi bitmeden ASLA baslamaz.
  assert.ok(order.indexOf('start:a2') === -1 || order.indexOf('start:a2') > order.indexOf('end:a1'));
  gates.b1.resolve();
  gates.a2.resolve();
  gates.c1.resolve();
  await Promise.all([pa1, pa2, pb1, pc1]);
  assert.ok(order.indexOf('start:a2') > order.indexOf('end:a1'), 'ayni anahtar sirali olmali');
  assert.ok(maxRunning <= 2, 'es zamanlilik siniri asilmamali');
  assert.equal(q.pending, 0);
  assert.equal(order.filter((x) => x.startsWith('start:')).length, 4);
});

test('KeyedWorkQueue: bekleyen son state yenisiyle birlestirilir; araya giren status siralamayi bozmaz', async () => {
  const q = new KeyedWorkQueue({ concurrency: 1 });
  const ran = [];
  const gate = deferred();
  // Anahtar X'i mesgul tut
  const first = q.push('X', 'state', async () => {
    await gate.promise;
    ran.push('state0');
  }, { coalesce: true });
  await new Promise((r) => setImmediate(r));
  const s1 = q.push('X', 'state', async () => ran.push('state1'), { coalesce: true });
  const s2 = q.push('X', 'state', async () => ran.push('state2'), { coalesce: true }); // s1'in yerine gecer
  const st = q.push('X', 'status', async () => ran.push('status-offline'));
  const s3 = q.push('X', 'state', async () => ran.push('state3'), { coalesce: true }); // status'tan SONRA: birlesmez
  gate.resolve();
  await Promise.all([first, s1, s2, st, s3]);
  assert.deepEqual(ran, ['state0', 'state2', 'status-offline', 'state3']);
  assert.equal(q.stats.coalesced, 1);
});

test('KeyedWorkQueue: hata diger isleri durdurmaz, push asla reddetmez', async () => {
  const q = new KeyedWorkQueue({ concurrency: 2 });
  const r1 = await q.push('A', 'status', async () => {
    throw new Error('boom');
  });
  const r2 = await q.push('A', 'status', async () => 'ok');
  assert.ok(r1.error instanceof Error);
  assert.equal(r2.value, 'ok');
  assert.equal(q.stats.failed, 1);
  assert.equal(q.stats.completed, 1);
});

test('KeyedWorkQueue: maxPending asilinca yeni isler atilir', async () => {
  const q = new KeyedWorkQueue({ concurrency: 1, maxPending: 2 });
  const gate = deferred();
  const p1 = q.push('A', 'status', () => gate.promise);
  const p2 = q.push('B', 'status', async () => 'b');
  const p3 = await q.push('C', 'status', async () => 'c');
  assert.deepEqual(p3, { dropped: true });
  assert.equal(q.stats.dropped, 1);
  gate.resolve();
  await Promise.all([p1, p2]);
  assert.equal(await q.drain(100), true);
});
