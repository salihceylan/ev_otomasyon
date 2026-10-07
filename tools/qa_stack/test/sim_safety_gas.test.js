// WP-G3 (Faz 2 F2.A.9): gaz ve duman UCTAN UCA senaryolari -- cihaz simulatoru (firmware portlari) <-> QA brokeri + yerel HTTP.
// Davranis tablosu F2.A.2 (firmware zaten boyle; bu dosya uctan uca kilitler):
//  (1) gaz -> gaz vanasi KAPANIR, su vanasi acik kalir, siren, alarm_raised kind=gas; (2) ex-proof olmayan fana dokunulmaz, ex-proof fan
//  acilir, kullanicinin ex-proof olmayan fani acma istegi zone_latched; (3) duman -> hicbir vana kapanmaz, fan zorla kapatilir;
//  (4) gaz kuruyup ACK sonrasi gaz vanasi kapali kalir; MQTT ve LAN acma gas_local_only; GAS_RESET DI'si acar, sensor aktifken acmaz;
//  (5) kilitliyken ve kilitsizken yeniden baslatmada gaz vanasi kapali; (6) gaz ek modulu susunca (once saglikli gorulmus) vana kapanir
//  (SF_FAULT_CLOSE); (7) su alarmi surerken ayni bolgede gaz -> yeni aid, kind=gas (E2E-2).
import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceSimulator } from '../sim/device_sim.js';
import { randomB64Url, randomHex } from '../lib/util.js';
import { startTestBroker, connect, subscribe, collect, publish, endClients, hashPw, waitFor, sleep } from './_helpers.js';

const KEY = 'sim-key-gasduman';

async function startHome({ uid = 'AHBU-S3-0D0001', relays = 8 } = {}) {
  const ctx = await startTestBroker();
  const T = `h_${randomHex(8)}`;
  const devPass = randomB64Url(12);
  ctx.store.addCredential({ username: `d_${T}`, password_hash: hashPw(devPass), kind: 'device' });
  for (const [perm, act, topic] of [['allow', 'publish', `ev/${T}/state`], ['allow', 'publish', `ev/${T}/status`], ['allow', 'publish', `ev/${T}/event`],
    ['allow', 'subscribe', `ev/${T}/cmd`], ['allow', 'subscribe', `ev/${T}/sys`]]) {
    ctx.store.addAcl({ username: `d_${T}`, permission: perm, action: act, topic });
  }
  const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password, clientId: `qa-backend-${randomHex(4)}` });
  const msgs = collect(backend);
  await subscribe(backend, `ev/${T}/state`);
  await subscribe(backend, `ev/${T}/event`);
  const sim = new DeviceSimulator({
    uid, relays, httpPort: 0, timeScale: 1, localKey: KEY, wifiConnected: true,
    homeWifi: { ssid: 'TestHome', pass: 'home-pass-123' }, wifiTiming: { connectMs: 40, scanMs: 40, sntpMs: 20 },
    mqtt: { host: '127.0.0.1', port: ctx.port, user: `d_${T}`, pass: devPass },
    mqttTiming: { ignoreWindowMs: 300, backoffMinMs: 200, backoffMaxMs: 400, authFailWaitMs: 300 },
    bootHoldMs: 0, bootMs: 150, rebootMs: 250, strict: true,
  });
  await sim.start();
  const mine = (m) => { try { return JSON.parse(m.payload).uid === uid; } catch (_) { return false; } };
  const h = {
    ctx, T, backend, msgs, sim, uid,
    states: () => msgs.filter((m) => m.topic === `ev/${T}/state`).filter(mine).map((m) => JSON.parse(m.payload)),
    events: () => msgs.filter((m) => m.topic === `ev/${T}/event`).filter(mine).map((m) => JSON.parse(m.payload)),
    waitState: (pred, label = 'state', timeoutMs = 8000) => waitFor(() => { const s = h.states().at(-1); return s && pred(s) ? s : null; }, { timeoutMs, label }),
    waitEvent: (pred, label = 'event', timeoutMs = 8000) => waitFor(() => h.events().find(pred) || null, { timeoutMs, label }),
    cmd: (obj) => publish(backend, `ev/${T}/cmd`, obj),
    sys: (obj) => publish(backend, `ev/${T}/sys`, obj),
    http: async (method, path, body) => {
      const r = await fetch(`http://127.0.0.1:${sim.httpPort}${path}`, {
        method, headers: { 'X-Device-Key': KEY, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined,
      });
      const text = await r.text();
      let json = null;
      try { json = JSON.parse(text); } catch (_) { /* metin */ }
      return { status: r.status, json };
    },
    ready: () => waitFor(() => { const m = sim.fw && sim.qaState().mqtt; return m && m.connected && m.cmd_subscribed && m.in_startup_window === false ? m : null; }, { timeoutMs: 8000, label: 'cihaz hazir olmadi' }),
    async close() {
      await sim.stop().catch(() => {});
      await endClients(backend);
      await ctx.broker.close();
    },
  };
  return h;
}

/** Varsayilan sim yapilandirmasinda DI 1,3,5..8 duvar butonu ve role 1-4 panjurdur: senaryo icin butonsuz girisler ve lamba roleleri. */
async function freeIo(h, nDi = 8) {
  const dis = Array.from({ length: nDi }, () => ({ target_relay: 0 }));
  const relays = Array.from({ length: 8 }, () => ({ type: 0 }));
  const r = await h.http('POST', '/api/config', { dis, relays });
  assert.equal(r.status, 200, `serbest G/C yapilandirmasi: ${JSON.stringify(r.json)}`);
}

async function configure(h, ops) {
  let rev = (await h.http('GET', '/api/safety/config')).json.rev;
  for (const op of ops) {
    const r = await h.http('POST', '/api/safety/config', { base_rev: rev, ...op });
    assert.equal(r.status, 200, `yama reddedildi: ${JSON.stringify(op)} -> ${r.status} ${JSON.stringify(r.json)}`);
    rev = r.json.rev;
  }
  return rev;
}

/** Bulut yolu (gevsetme serbest): ex-proof fan, kuruluk suresini kisaltma. */
async function cloudPatch(h, patch) {
  const rev = (await h.http('GET', '/api/safety/config')).json.rev;
  const id = `p-${randomHex(3)}`;
  await h.sys({ cmd: 'cfg_patch', module: 'safety', uid: h.uid, base_rev: rev, id, ...patch });
  await h.waitState((x) => x.last_id === id, `bulut yamasi ${JSON.stringify(patch)}`);
}

const relayOn = (sim, n) => sim.qaState().relays[n - 1].state;
const zone = (s, z = 1) => (s.safety?.zones || []).find((x) => x.id === z);
const waitBooted = (sim, seq0) => waitFor(() => !sim.booting && sim.fw && sim.events.some((e) => e.n > seq0 && e.type === 'booted'), { timeoutMs: 6000, label: 'yeniden acilis' });
const waitRelay = (sim, n, on, label) => waitFor(() => relayOn(sim, n) === on, { timeoutMs: 3000, label });

// a1 su vanasi (role 7, E2C: role ON = kapali), a2 gaz vanasi (role 5, E2C), a3 siren (role 6), a4 fan (role 8, ex-proof DEGIL),
// gaz dedektoru d3 (NC), GAS_RESET d6 (yerinde acma dugmesi). a5 ex-proof fan (role 4) buluttan eklenir (LAN'dan gevsetme).
const GAS_HOUSE = [
  { set: { sensor: { id: 'd3', kind: 'gas', zone: 1, active_open: 1, name: 'Mutfak gaz' } } },
  { set: { actuator: { relay: 7, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1] } } },
  { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1] } } },
  { set: { actuator: { relay: 6, kind: 'siren', zones: [1], run_limit_s: 30 } } },
  { set: { actuator: { relay: 8, kind: 'fan', zones: [1] } } },
  { set: { sensor: { id: 'd6', kind: 'gas_reset', zone: 1 } } },
];

test('G3: gaz -> gaz vanasi kapanir, su vanasi acik, siren, ex-proof fan acilir / digerine dokunulmaz; kuruyup ACK: gaz vanasi kapali, uzaktan acma gas_local_only, GAS_RESET acar (sensor aktifken acmaz)', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(3, true);                                  // NC dedektor: normal
    await configure(h, GAS_HOUSE);
    await cloudPatch(h, { set: { actuator: { relay: 4, kind: 'fan', zones: [1], exproof: true } } });
    await cloudPatch(h, { set: { policy: { dry_hold_ms: 1000 } } });
    await waitRelay(sim, 5, true, 'gaz vanasi acilista kapali (E2C: role ON)');
    // su vanasi acilir (uzaktan acma su icin serbest), gaz vanasi uzaktan acilamaz
    let r = await h.http('POST', '/api/actuator', { actuator: 'a1', to: 'open' });
    assert.equal(r.json.ok, true);
    r = await h.http('POST', '/api/actuator', { actuator: 'a2', to: 'open' });
    assert.equal(r.json.rej, 'gas_local_only');
    sim.pressDi(6, 150);                                 // yerinde GAS_RESET: gaz vanasi acilir
    await waitRelay(sim, 5, false, 'GAS_RESET gaz vanasini acmadi');
    assert.equal(relayOn(sim, 7), false, 'su vanasi acik');
    // gaz alarmi
    sim.setSensor('d3', true);
    let s = await h.waitState((x) => zone(x)?.st === 'latched' && zone(x)?.kind === 'gas', 'gaz kilidi');
    await waitRelay(sim, 5, true, 'gaz vanasi kapanmadi');
    assert.equal(relayOn(sim, 7), false, 'su vanasina dokunulmaz [K-3]');
    assert.equal(relayOn(sim, 6), true, 'siren');
    assert.equal(relayOn(sim, 4), true, 'ex-proof fan acilir [Y-1]');
    assert.equal(relayOn(sim, 8), false, 'ex-proof olmayan fana dokunulmaz');
    const ev = await h.waitEvent((e) => e.type === 'alarm_raised' && e.kind === 'gas', 'alarm_raised gas');
    assert.equal(ev.eid, zone(s).aid);
    assert.deepEqual(ev.srcs, ['d3']);
    assert.ok(ev.actions.some((a) => a.a === 'a2' && a.do === 'close'));
    assert.ok(!ev.actions.some((a) => a.a === 'a1'), 'su vanasi eylem listesinde yok');
    assert.ok(ev.actions.some((a) => a.a === 'a5' && a.do === 'on'));
    // kullanici ex-proof olmayan fani acmak ister -> zone_latched
    r = await h.http('POST', '/api/actuator', { actuator: 'a4', to: 'on' });
    assert.equal(r.json.rej, 'zone_latched');
    assert.equal(relayOn(sim, 8), false);
    // sensor hala aktifken GAS_RESET acmaz
    sim.pressDi(6, 150);
    await sleep(400);
    assert.equal(relayOn(sim, 5), true, 'kilitli bolgede GAS_RESET acmaz');
    // kuru + ACK -> NORMAL; gaz vanasi KAPALI kalir
    sim.setSensor('d3', false);
    await h.cmd({ cmd: 'alarm_ack', zone: 1, aid: ev.eid, uid });
    s = await h.waitState((x) => !zone(x), 'bolge normal', 8000);
    assert.equal(relayOn(sim, 5), true, 'gaz vanasi kapali kalir');
    assert.equal(relayOn(sim, 4), false, 'ex-proof fan durur');
    await h.cmd({ actuator: 'a2', to: 'open', uid, id: 'open-gas' });
    await h.waitState((x) => x.last_rej?.id === 'open-gas' && x.last_rej.code === 'gas_local_only', 'MQTT gas_local_only');
    r = await h.http('POST', '/api/actuator', { actuator: 'a2', to: 'open' });
    assert.equal(r.json.rej, 'gas_local_only');
    sim.pressDi(6, 150);
    await waitRelay(sim, 5, false, 'GAS_RESET kuru bolgede acar');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('G3: duman -> hicbir vana kapanmaz (yangin suyu), fan zorla kapatilir; ACK + kuruluk sonrasi normal', async () => {
  const h = await startHome({ uid: 'AHBU-S3-0D0002' });
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(4, true);
    await configure(h, [
      { set: { sensor: { id: 'd4', kind: 'smoke', zone: 1, active_open: 1 } } },
      { set: { actuator: { relay: 7, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1] } } },
      { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1] } } },
      { set: { actuator: { relay: 6, kind: 'siren', zones: [1], run_limit_s: 30 } } },
      { set: { actuator: { relay: 8, kind: 'fan', zones: [1] } } },
      { set: { sensor: { id: 'd6', kind: 'gas_reset', zone: 1 } } },
    ]);
    await cloudPatch(h, { set: { policy: { dry_hold_ms: 1000 } } });
    assert.equal((await h.http('POST', '/api/actuator', { actuator: 'a1', to: 'open' })).json.ok, true);
    sim.pressDi(6, 150);
    await waitRelay(sim, 5, false, 'gaz vanasi acildi');
    assert.equal((await h.http('POST', '/api/actuator', { actuator: 'a4', to: 'on' })).json.ok, true);
    await waitRelay(sim, 8, true, 'fan acik');
    sim.setSensor('d4', true);
    const s = await h.waitState((x) => zone(x)?.st === 'latched' && zone(x)?.kind === 'smoke', 'duman kilidi');
    await waitRelay(sim, 8, false, 'duman fani kapatmadi');
    assert.equal(relayOn(sim, 7), false, 'su vanasi KAPANMAZ (yangin suyu)');
    assert.equal(relayOn(sim, 5), false, 'gaz vanasi da kapanmaz (duman)');
    assert.equal(relayOn(sim, 6), true, 'siren');
    const ev = await h.waitEvent((e) => e.type === 'alarm_raised' && e.kind === 'smoke', 'alarm_raised smoke');
    assert.ok(!ev.actions.some((a) => a.do === 'close'), 'vana kapatma eylemi yok');
    assert.ok(ev.actions.some((a) => a.a === 'a4' && a.do === 'off'));
    // dumanda fani acma istegi reddedilir
    assert.equal((await h.http('POST', '/api/actuator', { actuator: 'a4', to: 'on' })).json.rej, 'zone_latched');
    sim.setSensor('d4', false);
    await h.cmd({ cmd: 'alarm_ack', zone: 1, aid: zone(s).aid, uid });
    await h.waitState((x) => !zone(x), 'bolge normal', 8000);
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('G3: yeniden baslatma -- kilitliyken ve kilitsizken gaz vanasi her acilista kapali [K-4]', async () => {
  const h = await startHome({ uid: 'AHBU-S3-0D0003' });
  const { sim } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(3, true);
    await configure(h, GAS_HOUSE);
    sim.pressDi(6, 150);
    await waitRelay(sim, 5, false, 'GAS_RESET acti');
    await sleep(300);                                    // dugme birakildi (basiliyken acilan pano ilk okumayi kenar saymaz)
    // kilitsiz yeniden baslatma: gaz vanasi kapali baslar
    let seq0 = sim.events.at(-1).n;
    sim.reboot();
    await waitBooted(sim, seq0);
    await h.ready();
    sim.setDi(3, true);
    await waitRelay(sim, 5, true, 'kilitsiz acilista gaz vanasi kapali');
    // acilista DI'ler ilk okunana dek kumanda kenari sayilmaz (SensorHub: ilk okuma kenar degil): once sensorler okunsun
    await h.waitState((x) => x.boot >= 2 && x.sensors?.length === 2 && x.sensors.every((y) => y.ok), 'acilista sensorler okundu');
    await sleep(200);
    sim.pressDi(6, 150);
    await waitRelay(sim, 5, false, 'GAS_RESET yeniden acti');
    await sleep(300);
    // kilitliyken yeniden baslatma
    sim.setSensor('d3', true);
    await h.waitState((x) => zone(x)?.st === 'latched', 'gaz kilidi');
    await waitRelay(sim, 5, true, 'kapandi');
    seq0 = sim.events.at(-1).n;
    sim.reboot();
    await waitBooted(sim, seq0);
    await h.ready();
    const s = await h.waitState((x) => x.boot >= 3 && zone(x)?.st === 'latched' && zone(x)?.kind === 'gas', 'acilista kilit');
    assert.ok(s);
    assert.equal(relayOn(sim, 5), true, 'kilitliyken acilista gaz vanasi kapali');
    await h.waitState((x) => x.boot >= 3 && x.sensors?.find((y) => y.id === 'd6')?.ok === true, 'acilista GAS_RESET okundu');
    await sleep(200);
    sim.pressDi(6, 150);
    await sleep(400);
    assert.equal(relayOn(sim, 5), true, 'kilitliyken GAS_RESET acmaz');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('G3: gaz dedektoru ek modulde; modul susunca (once saglikli gorulmus sensor) gaz vanasi kapanir (SF_FAULT_CLOSE), sensor_fault', async () => {
  const h = await startHome({ uid: 'AHBU-S3-0D0004', relays: 16 });
  const { sim } = h;
  try {
    await h.ready();
    await freeIo(h);
    const dis = Array.from({ length: 10 }, () => ({}));
    dis[9] = { target_relay: 0 };                        // DI 10 varsayilan duvar butonu: once serbest
    assert.equal((await h.http('POST', '/api/config', { dis })).status, 200);
    sim.setDi(10, true);
    await configure(h, [
      { set: { sensor: { id: 'd10', kind: 'gas', zone: 1, active_open: 1 } } },
      { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1] } } },
      { set: { sensor: { id: 'd6', kind: 'gas_reset', zone: 1 } } },
    ]);
    await h.waitState((x) => x.sensors?.find((y) => y.id === 'd10')?.ok === true, 'ek modul gaz sensoru ok', 8000);
    sim.pressDi(6, 150);
    await waitRelay(sim, 5, false, 'GAS_RESET acti');
    sim.extModuleDown(6000);
    const s = await h.waitState((x) => zone(x)?.st === 'latched' && zone(x)?.kind === 'gas', 'ariza -> gaz kilidi', 8000);
    assert.equal(s.sensors.find((y) => y.id === 'd10').ok, false);
    await waitRelay(sim, 5, true, 'ariza gaz vanasini kapatmadi');
    await h.waitEvent((e) => e.type === 'sensor_fault' && e.srcs?.[0] === 'd10', 'sensor_fault', 8000);
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('G3: su alarmi surerken ayni bolgede gaz -> yeni alarm olayi (yeni aid, kind=gas), gaz vanasi da kapanir [E2E-2]', async () => {
  const h = await startHome({ uid: 'AHBU-S3-0D0005' });
  const { sim } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(3, true);
    await configure(h, [...GAS_HOUSE, { set: { sensor: { id: 'd2', kind: 'water', zone: 1 } } }]);
    sim.pressDi(6, 150);
    await waitRelay(sim, 5, false, 'GAS_RESET acti');
    assert.equal((await h.http('POST', '/api/actuator', { actuator: 'a1', to: 'open' })).json.ok, true);
    sim.setSensor('d2', true);
    let s = await h.waitState((x) => zone(x)?.st === 'latched' && zone(x)?.kind === 'water', 'su kilidi');
    const waterAid = zone(s).aid;
    await waitRelay(sim, 7, true, 'su vanasi kapandi');
    assert.equal(relayOn(sim, 5), false, 'su alarmi gaz vanasina dokunmaz');
    sim.setSensor('d3', true);
    const ev = await h.waitEvent((e) => e.type === 'alarm_raised' && e.kind === 'gas', 'gaz alarm olayi');
    assert.notEqual(ev.eid, waterAid);
    s = await h.waitState((x) => zone(x)?.aid === ev.eid && zone(x)?.kind === 'gas', 'bolgenin aid\'si yenilendi');
    await waitRelay(sim, 5, true, 'gaz vanasi kapandi');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

// Faz 2 incelemesi G-1a (RV-E1): bulut yamasi (owner/servis gevsetebilir, D.4) gaz vanasini uzaktan acilabilir KILAMAZ (karar 7.2b-8):
// akiskani suya cevirmek ve eylemciyi silmek gas_local_only ile reddedilir; vana kapali kalir, rolesi uzaktan acilamaz. Bolge degisimi gibi
// vanayi acmayan bulut gevsetmesi uygulanir.
test('G3: buluttan gaz vanasini su yapmak / silmek gas_local_only; vana ve rolesi uzaktan acilamaz (G-1a)', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(3, true);
    await configure(h, [
      { set: { sensor: { id: 'd3', kind: 'gas', zone: 1, active_open: 1, name: 'Mutfak gaz' } } },
      { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1] } } },
    ]);
    await waitRelay(sim, 5, true, 'gaz vanasi kapali (E2C role ON)');
    let rev = (await h.http('GET', '/api/safety/config')).json.rev;
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id: 'g1-med', set: { actuator: { id: 'a1', relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1] } } });
    let s = await h.waitState((x) => x.last_rej?.id === 'g1-med', 'akiskan degisimi reddi');
    assert.equal(s.last_rej.code, 'gas_local_only');
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id: 'g1-del', del: { actuator: 'a1' } });
    s = await h.waitState((x) => x.last_rej?.id === 'g1-del', 'silme reddi');
    assert.equal(s.last_rej.code, 'gas_local_only');
    assert.equal((await h.http('GET', '/api/safety/config')).json.rev, rev, 'yapilandirma degismedi');
    await h.cmd({ actuator: 'a1', to: 'open', uid, id: 'g1-open' });
    await h.cmd({ cmd: 'toggle', relay: 5 });
    await sleep(500);
    assert.equal(relayOn(sim, 5), true, 'gaz vanasi uzaktan acilmadi');
    await cloudPatch(h, { set: { actuator: { id: 'a1', relay: 5, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1, 2] } } });
    rev = (await h.http('GET', '/api/safety/config')).json.rev;
    const r = await h.http('POST', '/api/safety/config', { base_rev: rev, del: { actuator: 'a1' } });
    assert.deepEqual([r.status, r.json.error], [403, 'local_loosen_forbidden'], 'LAN da silemez');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});
