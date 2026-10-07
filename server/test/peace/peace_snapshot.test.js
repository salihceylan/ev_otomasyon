'use strict';

// WP-H / evaluator - peace_snapshot: canli/bayat cihaz, acik lamba, panjur cifti tekillestirme
// (NULL shutter_pair_index dahil), cihaz yok, SQL parametreleri ve salt-okunurluk.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLiveSnapshot, OPEN_SHUTTER_MIN_POS, LIVE_WINDOW_SEC, SQL } = require('../../src/services/peace_snapshot');
const { makePeaceWorld, Z, HOME_A, HOME_B, DEV_A, DEV_B } = require('./_helpers');

const NOW = Z('2026-10-01T20:30:20Z');

function light(id, device, channel, room, on = true, extra = {}) {
  return { id, device_id: device, type: 'light', channel_index: channel, shutter_pair_index: null, name: `Lamba ${channel}`, room, current_state: on, current_position: 0, ...extra };
}
function shutterRow(id, device, channel, pair, position, room = 'Salon') {
  return { id, device_id: device, type: 'shutter', channel_index: channel, shutter_pair_index: pair, name: `Panjur ${channel}`, room, current_state: false, current_position: position };
}

function build({ devices, endpoints }) {
  return makePeaceWorld({
    clock: { ms: NOW },
    homes: [{ id: HOME_A, name: 'Ev' }],
    devices,
    endpoints,
  });
}

const liveDevice = (id = DEV_A, over = {}) => ({ id, home_id: HOME_A, is_online: true, last_seen_ms: NOW - 5000, ...over });

test('sabitler: panjur esigi 1, canlilik penceresi 120 sn', () => {
  assert.equal(OPEN_SHUTTER_MIN_POS, 1);
  assert.equal(LIVE_WINDOW_SEC, 120);
});

test('canli cihaz: acik lambalar kanal/oda/ad ile listelenir, kapali olanlar gelmez', async () => {
  const { db } = build({
    devices: [liveDevice()],
    endpoints: [light('e1', DEV_A, 5, 'Salon'), light('e2', DEV_A, 6, 'Mutfak', false), light('e3', DEV_A, 7, 'Mutfak')],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.equal(snap.live, true);
  assert.equal(snap.devicesTotal, 1);
  assert.equal(snap.devicesLive, 1);
  assert.deepEqual(snap.lights, [
    { endpointId: 'e1', deviceId: DEV_A, channel: 5, name: 'Lamba 5', room: 'Salon' },
    { endpointId: 'e3', deviceId: DEV_A, channel: 7, name: 'Lamba 7', room: 'Mutfak' },
  ]);
  assert.deepEqual(snap.shutters, []);
});

test('BAYAT cihaz (last_seen 121 sn once): acik lamba olsa bile live=false ve listeler bos', async () => {
  const { db } = build({
    devices: [liveDevice(DEV_A, { last_seen_ms: NOW - 121 * 1000 })],
    endpoints: [light('e1', DEV_A, 5, 'Salon')],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.equal(snap.live, false);
  assert.equal(snap.devicesTotal, 1);
  assert.equal(snap.devicesLive, 0);
  assert.deepEqual(snap.lights, []);
  assert.deepEqual(snap.shutters, []);
});

test('canlilik siniri: tam 120 sn hala canli; is_online=false veya last_seen NULL canli degil', async () => {
  for (const [over, expected] of [
    [{ last_seen_ms: NOW - 120 * 1000 }, true],
    [{ is_online: false }, false],
    [{ is_online: null }, false],
    [{ last_seen_ms: null }, false],
  ]) {
    const { db } = build({ devices: [liveDevice(DEV_A, over)], endpoints: [light('e1', DEV_A, 5, 'Salon')] });
    const snap = await loadLiveSnapshot(db, HOME_A);
    assert.equal(snap.live, expected, JSON.stringify(over));
    assert.equal(snap.lights.length, expected ? 1 : 0);
  }
});

test('iki cihaz: yalnizca CANLI olanin satirlari sayilir; bayat cihazin acik lambasi yok sayilir', async () => {
  const { db } = build({
    devices: [liveDevice(DEV_A), liveDevice(DEV_B, { last_seen_ms: NOW - 600 * 1000 })],
    endpoints: [light('live-1', DEV_A, 5, 'Salon'), light('stale-1', DEV_B, 5, 'Balkon'), shutterRow('stale-s', DEV_B, 1, 1, 100)],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.equal(snap.devicesTotal, 2);
  assert.equal(snap.devicesLive, 1);
  assert.equal(snap.live, true);
  assert.deepEqual(snap.lights.map((l) => l.endpointId), ['live-1']);
  assert.deepEqual(snap.shutters, []);
});

test('panjur cifti: yukari+asagi satirlari TEK cift olur, konum MAX; kapali (0) cift gelmez', async () => {
  const { db } = build({
    devices: [liveDevice()],
    endpoints: [
      shutterRow('s1', DEV_A, 1, 1, 100),
      shutterRow('s2', DEV_A, 2, 1, 100),
      shutterRow('s3', DEV_A, 3, 2, 0),
      shutterRow('s4', DEV_A, 4, 2, 0),
      shutterRow('s5', DEV_A, 5, 3, 40, 'Yatak Odası'),
      shutterRow('s6', DEV_A, 6, 3, 60, 'Yatak Odası'), // iki satir ayrisirsa en buyuk konum
    ],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.deepEqual(snap.shutters, [
    { pair: 1, deviceId: DEV_A, room: 'Salon', position: 100 },
    { pair: 3, deviceId: DEV_A, room: 'Yatak Odası', position: 60 },
  ]);
  assert.deepEqual(snap.lights, []);
});

test('panjur cifti: shutter_pair_index NULL (eski satirlar) kanaldan cozulur: (kanal+1)/2', async () => {
  const { db } = build({
    devices: [liveDevice()],
    endpoints: [shutterRow('n1', DEV_A, 3, null, 100), shutterRow('n2', DEV_A, 4, null, 100)],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.equal(snap.shutters.length, 1, 'iki NULL-pair satiri tek cift');
  assert.equal(snap.shutters[0].pair, 2);
});

test('cift numarasi CIHAZA ozeldir: iki cihazda da "1. panjur" acikse iki ayri cift sayilir', async () => {
  const { db } = build({
    devices: [liveDevice(DEV_A), liveDevice(DEV_B)],
    endpoints: [shutterRow('a1', DEV_A, 1, 1, 100), shutterRow('a2', DEV_A, 2, 1, 100), shutterRow('b1', DEV_B, 1, 1, 100), shutterRow('b2', DEV_B, 2, 1, 100)],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.equal(snap.shutters.length, 2);
  assert.deepEqual(snap.shutters.map((s) => s.deviceId).sort(), [DEV_A, DEV_B]);
});

test('hic cihaz yok: live=false, sayilar 0, listeler bos', async () => {
  const { db } = build({ devices: [], endpoints: [] });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.deepEqual(snap, { devicesTotal: 0, devicesLive: 0, live: false, lights: [], shutters: [], gasAlarm: false });
});

test('baska evin cihazi karismaz', async () => {
  const { db } = build({
    devices: [liveDevice(DEV_A), { id: DEV_B, home_id: HOME_B, is_online: true, last_seen_ms: NOW }],
    endpoints: [light('other', DEV_B, 5, 'Salon')],
  });
  const snap = await loadLiveSnapshot(db, HOME_A);
  assert.equal(snap.devicesTotal, 1);
  assert.deepEqual(snap.lights, []);
});

test('SQL PARAMETRELERI: [homeId, 120, 1]; yalnizca SELECT; DB saati; panjur cifti COALESCE', async () => {
  const { db } = build({ devices: [liveDevice()], endpoints: [] });
  await loadLiveSnapshot(db, HOME_A);
  assert.equal(db.calls.length, 1);
  const { text, params } = db.calls[0];
  assert.deepEqual(params, [HOME_A, 120, 1]);
  assert.equal(text, SQL.snapshot);
  assert.match(text, /^SELECT /);
  assert.doesNotMatch(text, /\b(INSERT|UPDATE|DELETE|DROP|ALTER)\b/i, 'degerlendirici DB yazmaz');
  assert.match(text, /CURRENT_TIMESTAMP - \(\$2::int \* INTERVAL '1 second'\)/, 'sure DB saatiyle ve parametreyle');
  assert.match(text, /d\.is_online IS TRUE/);
  assert.match(text, /COALESCE\(e\.shutter_pair_index, \(e\.channel_index \+ 1\) \/ 2\)/);
  // WP-S2 [Y3]: eylemci kanali (actuator_type dolu) lamba sayilmaz
  assert.match(text, /e\.type = 'light' AND e\.actuator_type IS NULL AND e\.current_state IS TRUE/);
  assert.match(text, /e\.type = 'shutter' AND e\.current_position >= \$3/);
  assert.match(text, /WHERE d\.home_id = \$1/);
  assert.doesNotMatch(text, /'plug'|'impulse'/, 'priz/impuls lamba sayilmaz');
});

test('savunma: sahte db kapali/priz/sifir konumlu satir dondururse bile acik SAYILMAZ; bayat satir yok sayilir', async () => {
  const rows = [
    { device_id: DEV_A, live: true, endpoint_id: 'x1', type: 'plug', channel_index: 1, pair: 1, name: 'Priz', room: 'Salon', current_state: true, current_position: 0 },
    { device_id: DEV_A, live: true, endpoint_id: 'x2', type: 'light', channel_index: 2, pair: 1, name: 'Kapali', room: 'Salon', current_state: false, current_position: 0 },
    { device_id: DEV_A, live: true, endpoint_id: 'x3', type: 'shutter', channel_index: 3, pair: 2, name: 'Kapali panjur', room: 'Salon', current_state: false, current_position: 0 },
    { device_id: DEV_A, live: true, endpoint_id: 'x4', type: 'light', channel_index: 4, pair: 2, name: 'Acik', room: null, current_state: true, current_position: 0 },
    { device_id: DEV_B, live: false, endpoint_id: 'x5', type: 'light', channel_index: 1, pair: 1, name: 'Bayat', room: 'Salon', current_state: true, current_position: 0 },
  ];
  const snap = await loadLiveSnapshot({ query: async () => ({ rows }) }, HOME_A);
  assert.deepEqual(snap.lights.map((l) => [l.endpointId, l.room]), [['x4', 'Genel']], 'oda NULL -> Genel');
  assert.deepEqual(snap.shutters, []);
  assert.equal(snap.devicesTotal, 2);
  assert.equal(snap.devicesLive, 1);
});

test('db.pool.query arayuzu de desteklenir; gecersiz db TypeError; sorgu hatasi yayilir', async () => {
  const viaPool = await loadLiveSnapshot({ pool: { query: async () => ({ rows: [{ device_id: DEV_A, live: true, endpoint_id: null }] }) } }, HOME_A);
  assert.equal(viaPool.live, true);
  assert.equal(viaPool.devicesTotal, 1);

  await assert.rejects(loadLiveSnapshot(null, HOME_A), TypeError);
  await assert.rejects(loadLiveSnapshot({}, HOME_A), /db \(query\) zorunludur/);
  await assert.rejects(loadLiveSnapshot({ query: async () => { throw new Error('baglanti koptu'); } }, HOME_A), /baglanti koptu/);
});

test('pg metin boolean/sayi donusleri (t, "100") tolere edilir', async () => {
  const rows = [
    { device_id: DEV_A, live: 't', endpoint_id: 'p1', type: 'shutter', channel_index: '1', pair: '1', name: 'P', room: 'Salon', current_state: false, current_position: '100' },
    { device_id: DEV_A, live: 't', endpoint_id: 'l1', type: 'light', channel_index: '5', pair: '3', name: 'L', room: 'Salon', current_state: 't', current_position: 0 },
  ];
  const snap = await loadLiveSnapshot({ query: async () => ({ rows }) }, HOME_A);
  assert.equal(snap.live, true);
  assert.deepEqual(snap.shutters, [{ pair: 1, deviceId: DEV_A, room: 'Salon', position: 100 }]);
  assert.equal(snap.lights[0].channel, 5);
});

test('F2.A.4: anlik goruntu evde acik gaz alarmini tasir (gasAlarm); sorgu tek, alarms EXISTS', async () => {
  const { loadLiveSnapshot: load, SQL: S } = require('../../src/services/peace_snapshot');
  const rows = [{ device_id: 'd1', live: true, gas_alarm: true, endpoint_id: null }];
  const calls = [];
  const db = { query: async (t, p) => { calls.push(t); return { rows }; } };
  const snap = await load(db, 'h1');
  assert.equal(snap.gasAlarm, true);
  assert.equal(calls.length, 1);
  assert.match(S.snapshot, /EXISTS \(SELECT 1 FROM alarms a WHERE a\.home_id = \$1 AND a\.kind = 'gas' AND a\.status IN \('latched', 'fault', 'silenced'\)\) AS gas_alarm/);
  const none = await load({ query: async () => ({ rows: [{ device_id: 'd1', live: true, endpoint_id: null }] }) }, 'h1');
  assert.equal(none.gasAlarm, false, 'kolon yoksa (eski sorgu/sahte) gaz alarmi yok sayilir');
});
