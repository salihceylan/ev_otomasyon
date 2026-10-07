// WP-Q1: guvenlik katmani UCTAN UCA senaryolari (spec 5.4-5.5 QA listesi): cihaz simulatoru (firmware portlari) <-> QA brokeri + yerel HTTP.
// Islak -> vana kapandi -> state v:3 -> ev/{t}/event -> event_ack; broker kesikken alarm ve sonra teslim; alarm sirasinda yeniden baslatma
// (ayni aid, vana kapali); stuck_open geri bildirim -> FAULT; acma reddi last_rej; kesinti/yeniden baslatma senaryolari (a-e); yasak yollar
// (/api/rs485/relay, /api/config, ek modul kapatma); ek modul arizasi (ok=false, sensor_fault, tarama 409); sys cfg_get/cfg_patch (cfg_dump,
// cakisma, buluttan gevsetme / LAN'dan gevsetme yasagi); COK PANOLU EV (ayni a1, uid'li komut yalniz hedefte, A'nin last_rej'i B'yi etkilemez,
// event_ack yalniz hedef panonun eid'lerini siler).
import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceSimulator } from '../sim/device_sim.js';
import { randomB64Url, randomHex } from '../lib/util.js';
import { startTestBroker, connect, subscribe, collect, publish, endClients, hashPw, waitFor, sleep } from './_helpers.js';

const KEY = 'sim-key-safety01';

async function startHome({ boards = [{ uid: 'AHBU-S3-0B0001' }], relays = 8 } = {}) {
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
  const sims = [];
  for (const b of boards) {
    const sim = new DeviceSimulator({
      uid: b.uid, relays: b.relays ?? relays, httpPort: 0, timeScale: 1, localKey: KEY, wifiConnected: true,
      homeWifi: { ssid: 'TestHome', pass: 'home-pass-123' }, wifiTiming: { connectMs: 40, scanMs: 40, sntpMs: 20 },
      mqtt: { host: '127.0.0.1', port: ctx.port, user: `d_${T}`, pass: devPass },
      mqttTiming: { ignoreWindowMs: 300, backoffMinMs: 200, backoffMaxMs: 400, authFailWaitMs: 300 },
      bootHoldMs: 0, bootMs: 150, rebootMs: 250, strict: true,
    });
    await sim.start();
    sims.push(sim);
  }
  const fromUid = (uid) => (m) => { try { return JSON.parse(m.payload).uid === uid; } catch (_) { return false; } };
  const h = {
    ctx, T, backend, msgs, sims,
    states: (uid) => msgs.filter((m) => m.topic === `ev/${T}/state`).filter(fromUid(uid)).map((m) => JSON.parse(m.payload)),
    events: (uid) => msgs.filter((m) => m.topic === `ev/${T}/event`).filter(fromUid(uid)).map((m) => JSON.parse(m.payload)),
    waitState: (uid, pred, label = 'state', timeoutMs = 8000) => waitFor(() => { const s = h.states(uid).at(-1); return s && pred(s) ? s : null; }, { timeoutMs, label }),
    waitEvent: (uid, pred, label = 'event', timeoutMs = 8000) => waitFor(() => h.events(uid).find(pred) || null, { timeoutMs, label }),
    cmd: (obj) => publish(backend, `ev/${T}/cmd`, obj),
    sys: (obj) => publish(backend, `ev/${T}/sys`, obj),
    http: async (sim, method, path, body) => {
      const r = await fetch(`http://127.0.0.1:${sim.httpPort}${path}`, {
        method, headers: { 'X-Device-Key': KEY, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined,
      });
      const text = await r.text();
      let json = null;
      try { json = JSON.parse(text); } catch (_) { /* metin */ }
      return { status: r.status, json };
    },
    ready: (sim) => waitFor(() => { const m = sim.fw && sim.qaState().mqtt; return m && m.connected && m.cmd_subscribed && m.in_startup_window === false ? m : null; }, { timeoutMs: 8000, label: 'cihaz hazir olmadi' }),
    async close() {
      for (const s of sims) await s.stop().catch(() => {});
      await endClients(backend);
      await ctx.broker.close();
    },
  };
  return h;
}

/** LAN uzerinden guvenlik yapilandirmasi: her yama tek oge, base_rev zinciri. */
async function configure(h, sim, ops) {
  let rev = (await h.http(sim, 'GET', '/api/safety/config')).json.rev;
  for (const op of ops) {
    const r = await h.http(sim, 'POST', '/api/safety/config', { base_rev: rev, ...op });
    assert.equal(r.status, 200, `yama reddedildi: ${JSON.stringify(op)} -> ${r.status} ${JSON.stringify(r.json)}`);
    rev = r.json.rev;
  }
  return rev;
}

/** Kuruluk suresini kisaltmak gevsetmedir (LAN'dan yasak, karar 7.2b-7): bulut yolu (sys cfg_patch) ile yapilir. */
async function fastDry(h, sim) {
  const rev = (await h.http(sim, 'GET', '/api/safety/config')).json.rev;
  await h.sys({ cmd: 'cfg_patch', module: 'safety', uid: sim.uid, base_rev: rev, set: { policy: { dry_hold_ms: 1000 } } });
  await waitFor(async () => (await h.http(sim, 'GET', '/api/safety/config')).json.policy.dry_hold_ms === 1000, { timeoutMs: 4000, label: 'dry_hold 1000 olmadi' });
}

const WATER = [
  { set: { sensor: { id: 'd2', kind: 'water', zone: 1, name: 'Banyo zemini' } } },
  { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1], name: 'Ana vana' } } },
  { set: { actuator: { relay: 6, kind: 'siren', zones: [1], run_limit_s: 30 } } },
];
const relayOn = (sim, n) => sim.qaState().relays[n - 1].state;
/** seq0'dan sonra yeni bir acilis (booted) olayi ve cihaz hazir. */
const waitBooted = (sim, seq0, label = 'yeniden acilis') => waitFor(() => !sim.booting && sim.fw && sim.events.some((e) => e.n > seq0 && e.type === 'booted'), { timeoutMs: 6000, label });
const zoneSt = (s, z = 1) => s.safety?.zones?.find((x) => x.id === z)?.st ?? 'normal';

test('Q1: islak -> vana ayni dongude kapanir -> state v:3 (latched, aid) -> ev/{t}/event alarm_raised -> event_ack tampondan siler', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    await configure(h, sim, WATER);
    let s = await h.waitState(uid, (x) => Array.isArray(x.sensors) && x.actuators?.length === 2, 'yapilandirilmis state');
    assert.equal(s.v, 3);
    assert.deepEqual(s.sensors, [{ id: 'd2', src: 'di', kind: 'water', zone: 1, active: false, ok: true }]);
    assert.equal(s.relays[4].act, 'valve');
    assert.equal(s.relays[4].type, 'light', 'type degismez (eski istemci yerlesimi bozulmaz) [K1]');
    assert.equal(s.cfg.safety.rev >= 3, true);
    assert.ok(!JSON.stringify(s).includes('Banyo zemini'), 'adlar state\'te yok [B12]');
    sim.setSensor('d2', true);
    s = await h.waitState(uid, (x) => zoneSt(x) === 'latched' && x.relays[4].state === true, 'kilitli state');
    const z = s.safety.zones[0];
    assert.match(z.aid, /^[0-9a-f]{8}-\d+$/);
    assert.deepEqual(z.srcs, ['d2']);
    assert.equal(s.actuators[0].pos, 'cmd_closed');
    assert.equal(s.relays[5].state, true, 'siren calar');
    const ev = await h.waitEvent(uid, (e) => e.type === 'alarm_raised', 'alarm_raised olayi');
    assert.equal(ev.eid, z.aid, 'alarm kimligi = alarmi acan olayin eid\'si');
    assert.deepEqual(ev.actions, [{ a: 'a1', do: 'close' }, { a: 'a2', do: 'on' }]);
    assert.ok(sim.qaSafetyState().outbox.some((o) => o.eid === ev.eid), 'onaysiz olay tamponda bekler');
    await h.cmd({ cmd: 'event_ack', eids: [ev.eid], uid });
    await waitFor(() => !sim.qaSafetyState().outbox.some((o) => o.eid === ev.eid), { timeoutMs: 3000, label: 'event_ack olayi silmedi' });
    // LAN: /api/status ayni ek alanlari tasir; /api/events onaylanan olayi da listeler (K5)
    const st = await h.http(sim, 'GET', '/api/status');
    assert.equal(st.json.safety.zones[0].aid, z.aid);
    assert.deepEqual(st.json.caps, ['safety', 'actuator', 'event', 'cfg', 'intrusion']);
    const evs = await h.http(sim, 'GET', '/api/events');
    assert.ok(evs.json.events.some((e) => e.eid === ev.eid && e.type === 'alarm_raised'));
    const after = await h.http(sim, 'GET', `/api/events?after=${ev.eid}`);
    assert.ok(!after.json.events.some((e) => e.eid === ev.eid));
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('Q1: acma reddi last_rej ile aninda gorulur; uid\'siz guvenlik komutu bad_cmd; kurumadan acilmaz, onay + kuruluk sonrasi acma kabul', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    await configure(h, sim, WATER);
    await fastDry(h, sim);
    sim.setSensor('d2', true);
    let s = await h.waitState(uid, (x) => zoneSt(x) === 'latched', 'kilit');
    await h.cmd({ actuator: 'a1', to: 'open', uid, id: 'ac1' });
    s = await h.waitState(uid, (x) => x.last_rej?.id === 'ac1', 'last_rej');
    assert.deepEqual(s.last_rej, { id: 'ac1', code: 'zone_latched' });
    assert.equal(relayOn(sim, 5), true, 'vana kapali kaldi');
    await h.cmd({ actuator: 'a1', to: 'open', id: 'ac2' });
    s = await h.waitState(uid, (x) => x.last_rej?.id === 'ac2', 'uid zorunlu');
    assert.equal(s.last_rej.code, 'bad_cmd');
    await h.cmd({ actuator: 'a2', to: 'closed', uid, id: 'ac3' });   // siren vana degil
    s = await h.waitState(uid, (x) => x.last_rej?.id === 'ac3', 'bad_state');
    assert.equal(s.last_rej.code, 'bad_state');
    // bayat aid ile onay: susturma yok [Y-9]
    await h.cmd({ cmd: 'alarm_ack', zone: 1, aid: 'deadbeef-9', uid, id: 'k1' });
    s = await h.waitState(uid, (x) => x.last_rej?.id === 'k1', 'stale_ack');
    assert.equal(s.last_rej.code, 'stale_ack');
    // dogru aid: islakken yalniz susturur
    const aid = s.safety.zones[0].aid;
    await h.cmd({ cmd: 'alarm_ack', zone: 1, aid, uid, id: 'k2' });
    s = await h.waitState(uid, (x) => x.last_id === 'k2' && x.safety.zones[0]?.silenced === true, 'susturuldu');
    assert.equal(relayOn(sim, 6), false, 'siren sustu');
    sim.setSensor('d2', false);
    s = await h.waitState(uid, (x) => zoneSt(x) === 'normal', 'kuruluk sonrasi kilit kalkti', 12000);
    assert.equal(relayOn(sim, 5), true, 'vana KAPALI kalir; acmak ayri komut [K-1]');
    const r = await h.http(sim, 'POST', '/api/actuator', { actuator: 'a1', to: 'open' });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    await waitFor(() => relayOn(sim, 5) === false, { timeoutMs: 2000, label: 'vana acilmadi' });
  } finally {
    await h.close();
  }
});

test('Q1: broker kesikken alarm olusur, olay bekler; baglanti donunce (1500 ms penceresinden sonra) teslim edilir; onay kaybinda yeniden denenir', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    await configure(h, sim, WATER);
    sim.forceOffline();
    sim.setSensor('d2', true);
    await waitFor(() => sim.qaSafetyState().latched_mask === 1, { timeoutMs: 4000, label: 'cevrimdisi kilit' });
    assert.equal(relayOn(sim, 5), true, 'buluttan bagimsiz: vana kapandi (K5)');
    assert.equal(h.events(uid).length, 0);
    sim.dropEventAcks(1);
    sim.forceOnline();
    const ev = await h.waitEvent(uid, (e) => e.type === 'alarm_raised', 'baglanti donunce teslim', 10000);
    await h.cmd({ cmd: 'event_ack', eids: [ev.eid], uid });   // QA: bu onay cihazda kaybolur
    await waitFor(() => h.events(uid).filter((e) => e.eid === ev.eid).length >= 2, { timeoutMs: 9000, label: 'onaysiz olay 5 sn sonra yeniden yayinlanmadi' });
    await h.cmd({ cmd: 'event_ack', eids: [ev.eid], uid });
    await waitFor(() => !sim.qaSafetyState().outbox.some((o) => o.eid === ev.eid), { timeoutMs: 3000, label: 'ikinci onay silmedi' });
  } finally {
    await h.close();
  }
});

test('Q1: alarm sirasinda elektrik kesintisi: vana kapali kalir, state latched ve AYNI aid; stuck_open geri bildirim FAULT uretir', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    await configure(h, sim, [
      { set: { sensor: { id: 'd2', kind: 'water', zone: 1 } } },
      { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1], fb_di: 4, fb_closed_active: 1, fb_timeout_s: 2 } } },
    ]);
    sim.setValveFeedback('a1', 'follow', 300);
    sim.setSensor('d2', true);
    let s = await h.waitState(uid, (x) => zoneSt(x) === 'latched' && x.actuators[0].pos === 'closed', 'kilit + geri bildirim kapali');
    const aid = s.safety.zones[0].aid;
    const seq0 = sim.eventSeq;
    sim.reboot();
    await waitBooted(sim, seq0);
    assert.equal(sim.fw.automation.tca.latch & 0x10, 0x10, 'Relay_Init kilit maskesiyle: vana hic acilmadi');
    await h.ready(sim);
    s = await h.waitState(uid, (x) => zoneSt(x) === 'latched' && x.boot >= 2, 'yeniden acilista kilit');
    assert.equal(s.safety.zones[0].aid, aid, 'ayni alarm kimligi (NVS kilit kaydi)');
    assert.equal(relayOn(sim, 5), true);
    sim.setValveFeedback('a1', 'stuck_open');
    s = await h.waitState(uid, (x) => zoneSt(x) === 'fault', 'FAULT', 8000);
    assert.equal(s.actuators[0].fault, true);
    await h.waitEvent(uid, (e) => e.type === 'valve_fault', 'valve_fault olayi');
  } finally {
    await h.close();
  }
});

test('Q1: kesinti/yeniden baslatma senaryolari: (e) kilitliyken reboot 409, (b) force ile yazilimsal yeniden baslatma bit izi korunur, (a) kilit kalktiktan sonra reboot vana kapali, (c) force fabrika sifirlamasi guvenli kip', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    await configure(h, sim, WATER);
    await fastDry(h, sim);
    sim.setSensor('d2', true);
    await h.waitState(uid, (x) => zoneSt(x) === 'latched', 'kilit');
    // (e)
    let r = await h.http(sim, 'POST', '/api/system/reboot');
    assert.deepEqual([r.status, r.json], [409, { error: 'zone_latched' }]);
    r = await h.http(sim, 'POST', '/api/system/reset');
    assert.deepEqual([r.status, r.json], [409, { error: 'zone_latched' }]);
    // (b) force: kapatma yolu boyunca E2C vana biti hic 0'a dusmez
    let dropped = false;
    const sampler = setInterval(() => { if (sim.fw && (sim.fw.automation.tca.latch & 0x10) === 0) dropped = true; }, 2);
    let seq0 = sim.eventSeq;
    r = await h.http(sim, 'POST', '/api/system/reboot?force=1');
    assert.equal(r.status, 200);
    await waitBooted(sim, seq0);
    await sleep(300);
    clearInterval(sampler);
    assert.equal(dropped, false, 'shutdownHandler / Relay_Init boyunca bit izi 0 olmadi');
    await h.ready(sim);
    // (a) kurut + onayla -> kilit kalkar; sonra elektrik kesintisi: vana kapali gelir (act_pos) [K-1]
    sim.setSensor('d2', false);
    const s0 = await h.waitState(uid, (x) => zoneSt(x) === 'latched' && x.safety.zones[0].aid, 'kilit geri geldi');
    await h.cmd({ cmd: 'alarm_ack', zone: 1, aid: s0.safety.zones[0].aid, uid });
    await h.waitState(uid, (x) => zoneSt(x) === 'normal', 'kilit kalkti', 12000);
    seq0 = sim.eventSeq;
    sim.reboot();
    await waitBooted(sim, seq0);
    await sleep(300);
    assert.equal(relayOn(sim, 5), true, 'kilit kalktiktan sonra kesinti: vana KAPALI acildi');
    await h.ready(sim);
    // (c) yeniden kilitle ve force ile fabrika sifirlamasi: kilit sag cikar, guvenli kip (latch_orphan), vana kapali
    sim.setSensor('d2', true);
    await h.waitState(uid, (x) => zoneSt(x) === 'latched', 'ikinci kilit');
    seq0 = sim.eventSeq;
    r = await h.http(sim, 'POST', '/api/system/reset?force=1');
    assert.equal(r.status, 200);
    await waitBooted(sim, seq0);
    await waitFor(() => sim.qaSafetyState()?.mode === 'latch_orphan', { timeoutMs: 5000, label: 'guvenli kip yok' });
    await sleep(200);
    assert.equal(relayOn(sim, 5), true, 'fabrika sifirlamasindan sonra vana kapali');
    const st = await h.http(sim, 'GET', '/api/status');
    assert.equal(st.json.safety.mode, 'safe');
    assert.equal(st.json.safety.reason, 'latch_orphan');
    // LAN force onayi guvenli kipten CIKARMAZ (yalniz fiziksel erisim, karar 7.2b-10)
    r = await h.http(sim, 'POST', '/api/alarm/ack', { zone: 0, force: true, id: 'f1' });
    assert.deepEqual([r.status, r.json.ok, r.json.rej], [200, false, 'safe_mode']);
    r = await h.http(sim, 'POST', '/api/relay?ch=5&state=0');
    await sleep(200);
    assert.equal(relayOn(sim, 5), true, 'guvenli kipte kilitli role ham komutla acilmaz');
  } finally {
    await h.close();
  }
});

test('Q1: bozuk guvenlik yapilandirmasi (CRC) -> guvenli kip cfg_corrupt, kilitli vana kapali; safe_mode olayi; ham acma reddi', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    await configure(h, sim, WATER);
    sim.setSensor('d2', true);
    await h.waitState(uid, (x) => zoneSt(x) === 'latched', 'kilit');
    const seq0 = sim.eventSeq;
    sim.corruptSafetyCfg();
    await waitBooted(sim, seq0);
    await waitFor(() => sim.qaSafetyState()?.mode === 'cfg_corrupt', { timeoutMs: 5000, label: 'cfg_corrupt yok' });
    await sleep(200);
    assert.equal(relayOn(sim, 5), true, 'kilit maskesi yapilandirmasiz uygulandi [Y-4]');
    await h.ready(sim);
    const s = await h.waitState(uid, (x) => x.safety?.mode === 'safe', 'safe');
    assert.equal(s.safety.reason, 'cfg_corrupt');
    await h.waitEvent(uid, (e) => e.type === 'safe_mode' && e.reason === 'cfg_corrupt', 'safe_mode olayi');
    // ham acma: guvenli kipte kilit seviyesinden baska yon reddedilir
    await h.cmd({ relay: 5, state: false, uid, id: 'h1' });
    const s2 = await h.waitState(uid, (x) => x.last_rej?.id === 'h1', 'ham ret');
    assert.equal(s2.last_rej.code, 'actuator_relay');
  } finally {
    await h.close();
  }
});

test('Q1: yasak yollar ve ek modul arizasi: /api/rs485/relay ile ek modul vanasini acma 409, /api/config eylemci rolesini panjura cevirme 409, kilitliyken ek modul kapatma 409; ek modul susunca sensor ok=false + sensor_fault; tarama 409', async () => {
  const h = await startHome({ boards: [{ uid: 'AHBU-S3-0B0002', relays: 16 }] });
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    // DI 10 varsayilan olarak duvar butonu (hedef role 10): once serbest birakilir (sensor DI'si duvar butonu olamaz [B3])
    const dis = Array.from({ length: 10 }, () => ({}));
    dis[9] = { target_relay: 0 };
    assert.equal((await h.http(sim, 'POST', '/api/config', { dis })).status, 200);
    await configure(h, sim, [
      { set: { sensor: { id: 'd10', kind: 'water', zone: 1 } } },
      { set: { actuator: { relay: 11, kind: 'valve', close_mode: 'deenergize', medium: 'water', zones: [1] } } },
    ]);
    await h.waitState(uid, (x) => x.sensors?.[0]?.ok === true, 'ek modul sensoru ok', 8000);
    // ek modul vanasini ham komutla acma (D2C: role ON = acik) -> 409
    let r = await h.http(sim, 'POST', '/api/rs485/relay', { slaveId: 1, channel: 3, action: 1 });
    assert.deepEqual([r.status, r.json], [409, { error: 'actuator_relay' }]);
    r = await h.http(sim, 'POST', '/api/rs485/relay', { slaveId: 1, channel: 0, action: 0 });
    assert.deepEqual([r.status, r.json], [409, { error: 'actuator_relay' }], 'toplu yazim eylemci varken reddedilir');
    r = await h.http(sim, 'POST', '/api/rs485/send', { data: '01 05 00 02 FF 00 2D FA', isHex: true });   // kanal 3 AC (CRC'li)
    assert.deepEqual([r.status, r.json], [409, { error: 'actuator_relay' }]);
    // eylemci rolesini panjura cevirme -> 409 cfg_invalid
    const relays = Array.from({ length: 12 }, () => ({}));
    relays[10] = { type: 1, runtime_sec: 20 };   // role 11 (vana) -> panjur yukari
    relays[11] = { type: 2, runtime_sec: 20 };
    r = await h.http(sim, 'POST', '/api/config', { relays });
    assert.equal(r.status, 409);
    assert.equal(r.json.error, 'cfg_invalid');
    // RS485 taramasi: ek modulde eylemci varken 409
    r = await h.http(sim, 'POST', '/api/rs485/scan');
    assert.deepEqual([r.status, r.json], [409, { error: 'safety_active' }]);
    // kilitliyken ek modulu kapatma -> 409 zone_latched
    sim.setSensor('d10', true);
    await h.waitState(uid, (x) => zoneSt(x) === 'latched', 'ek modul sensoru alarm', 8000);
    r = await h.http(sim, 'POST', '/api/config', { ext_module_enabled: false });
    assert.deepEqual([r.status, r.json], [409, { error: 'zone_latched' }]);
    // ek modul susar: sensor ok=false, sensor_fault olayi
    sim.extModuleDown(4000);
    const s = await h.waitState(uid, (x) => x.sensors?.[0]?.ok === false, 'ok=false', 8000);
    assert.equal(s.sensors[0].active, false, 'ok=false sensor bilinmeyendir');
    await h.waitEvent(uid, (e) => e.type === 'sensor_fault' && e.srcs?.[0] === 'd10', 'sensor_fault', 8000);
  } finally {
    await h.close();
  }
});

test('Q1: sys cfg_get -> cfg_dump; cfg_patch bayat base_rev -> cfg_conflict olayi + last_rej; buluttan politika kapatma kabul (policy_changed via cloud), LAN\'dan 403', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    const rev = await configure(h, sim, WATER);
    // LAN gevsetme yasagi (karar 7.2b-7)
    let r = await h.http(sim, 'POST', '/api/safety/config', { base_rev: rev, set: { policy: { on: false } } });
    assert.deepEqual([r.status, r.json], [403, { error: 'local_loosen_forbidden' }]);
    r = await h.http(sim, 'POST', '/api/safety/config', { base_rev: rev, del: { actuator: 'a2' } });
    assert.equal(r.status, 403);
    r = await h.http(sim, 'POST', '/api/safety/config', { base_rev: rev - 1, set: { zone: { id: 2, name: 'Mutfak' } } });
    assert.equal(r.status, 409);
    assert.equal(r.json.error, 'cfg_conflict');
    // cfg_get -> cfg_dump (adlar dahil)
    await h.sys({ cmd: 'cfg_get', module: 'safety', uid });
    const dump = await h.waitEvent(uid, (e) => e.type === 'cfg_dump', 'cfg_dump');
    assert.equal(dump.rev, rev);
    assert.equal(dump.part, 1);
    assert.equal(dump.parts, 1);
    assert.equal(dump.sensors[0].name, 'Banyo zemini');
    assert.equal(dump.actuators[0].name, 'Ana vana');
    // cfg_patch: bayat base_rev -> cfg_conflict olayi, pano kazanir
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev - 1, set: { zone: { id: 2, name: 'Mutfak' } }, id: 'p1' });
    const conf = await h.waitEvent(uid, (e) => e.type === 'cfg_conflict', 'cfg_conflict olayi');
    assert.equal(conf.rev, rev);
    await h.waitState(uid, (x) => x.last_rej?.id === 'p1' && x.last_rej.code === 'cfg_conflict', 'last_rej cfg_conflict');
    // bulut (owner/servis yetkisi sunucuda) gevsetebilir
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, set: { policy: { on: false } } });
    const s = await h.waitState(uid, (x) => x.safety?.policy === 'off', 'politika kapandi');
    assert.equal(s.cfg.safety.rev, rev + 1);
    const pc = await h.waitEvent(uid, (e) => e.type === 'policy_changed', 'policy_changed');
    assert.deepEqual([pc.policy, pc.via], ['off', 'cloud']);
    // baska panonun uid'si: sessizce yok sayilir
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid: 'AHBU-S3-FFFFFF', base_rev: rev + 1, set: { policy: { on: true } } });
    await sleep(500);
    assert.equal(h.states(uid).at(-1).safety.policy, 'off');
  } finally {
    await h.close();
  }
});

test('Q1: COK PANOLU EV: ayni a1; uid\'li komut yalniz hedefte uygulanir; A\'nin last_rej\'i B\'yi etkilemez; event_ack yalniz hedef panonun eid\'lerini siler', async () => {
  const A = 'AHBU-S3-0B00A1';
  const B = 'AHBU-S3-0B00B2';
  const h = await startHome({ boards: [{ uid: A }, { uid: B }] });
  const [sa, sb] = h.sims;
  try {
    await h.ready(sa);
    await h.ready(sb);
    await configure(h, sa, WATER);
    await configure(h, sb, WATER);
    await h.waitState(A, (x) => x.actuators?.length === 2, 'A yapilandirildi');
    await h.waitState(B, (x) => x.actuators?.length === 2, 'B yapilandirildi');
    // E2C vana: closed = role ON. Yalniz B'yi kapat
    await h.cmd({ actuator: 'a1', to: 'closed', uid: B, id: 'm1' });
    await h.waitState(B, (x) => x.last_id === 'm1' && x.relays[4].state === true, 'B kapandi');
    await sleep(300);
    assert.equal(relayOn(sa, 5), false, 'A etkilenmedi');
    assert.notEqual(h.states(A).at(-1).last_id, 'm1');
    // A'ya giden hatali komut: A last_rej yazar, B sessiz
    await h.cmd({ cmd: 'alarm_test', zone: 9, uid: A, id: 'm2' });
    await h.waitState(A, (x) => x.last_rej?.id === 'm2', 'A last_rej');
    await sleep(300);
    assert.ok(!h.states(B).some((x) => x.last_rej?.id === 'm2'), 'B\'ye giden/olmayan ret B\'de gorunmez');
    // iki panoda alarm: event_ack yalniz hedefin eid'lerini siler
    sa.setSensor('d2', true);
    sb.setSensor('d2', true);
    const ea = await h.waitEvent(A, (e) => e.type === 'alarm_raised', 'A alarm');
    const eb = await h.waitEvent(B, (e) => e.type === 'alarm_raised', 'B alarm');
    assert.notEqual(ea.bn, eb.bn, 'acilis nonce\'lari farkli: eid\'ler cakismaz [Y4]');
    await h.cmd({ cmd: 'event_ack', eids: [ea.eid, eb.eid], uid: A });
    await waitFor(() => !sa.qaSafetyState().outbox.some((o) => o.eid === ea.eid), { timeoutMs: 3000, label: 'A olayi silinmedi' });
    await sleep(300);
    assert.ok(sb.qaSafetyState().outbox.some((o) => o.eid === eb.eid), 'B\'nin olayi A\'ya giden onayla silinmedi');
    await h.cmd({ cmd: 'event_ack', eids: [eb.eid], uid: B });
    await waitFor(() => !sb.qaSafetyState().outbox.some((o) => o.eid === eb.eid), { timeoutMs: 3000, label: 'B olayi silinmedi' });
  } finally {
    await h.close();
  }
});

test('Q1 (inceleme RV-2): uid\'siz duz role komutu eylemci rolesine dusmez (calan siren susmaz); uid\'li komut uygulanir; lamba rolesi uid\'siz calisir', async () => {
  const A = 'AHBU-S3-0B00A1';
  const h = await startHome({ boards: [{ uid: A }] });
  const [sa] = h.sims;
  try {
    await h.ready(sa);
    await configure(h, sa, WATER);
    await h.waitState(A, (x) => x.actuators?.length === 2, 'A yapilandirildi');
    sa.setSensor('d2', true);
    await h.waitState(A, (x) => zoneSt(x) === 'latched' && x.relays[5].state === true, 'A alarmda, siren calar');
    // baska panonun lambasi icin (role 6) uid'siz duz komut: A'nin sireni SUSMAZ
    await h.cmd({ relay: 6, state: false, id: 'x1' });
    await sleep(400);
    assert.equal(relayOn(sa, 6), true, 'uid\'siz komut sireni susturmadi');
    assert.ok(sa.events.some((e) => e.type === 'cmd_ignored' && e.reason === 'actuator_relay_without_uid'));
    // eylemci olmayan role: uid'siz duz komut bugunku gibi uygulanir
    await h.cmd({ relay: 7, state: true, id: 'x2' });
    await h.waitState(A, (x) => x.last_id === 'x2' && x.relays[6].state === true, 'lamba uid\'siz acildi');
    // ayni komut uid ile: bu panonun komutu, kapatma yonu kabul (sustur)
    await h.cmd({ relay: 6, state: false, uid: A, id: 'x3' });
    await h.waitState(A, (x) => x.last_id === 'x3' && x.relays[5].state === false, 'uid\'li komut sireni susturdu');
  } finally {
    await h.close();
  }
});

test('C1 (Faz 2 F2.D.6): cfg_patch basarisinda last_id = id (otomasyon yeni komut isleyene dek); NVS payi yetmezse last_rej cfg_storage', async () => {
  const h = await startHome();
  const [sim] = h.sims;
  const uid = sim.uid;
  try {
    await h.ready(sim);
    let rev = await configure(h, sim, WATER);
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id: 'cfg-1', set: { zone: { id: 2, name: 'Mutfak' } } });
    let s = await h.waitState(uid, (x) => x.last_id === 'cfg-1', 'cfg_patch kabul yankisi (last_id)');
    assert.equal(s.cfg.safety.rev, rev + 1);
    assert.equal(s.last_rej, undefined);
    // otomasyon yeni bir komut isleyince onun kimligi gecerli olur
    await h.cmd({ relay: 1, state: true, id: 'r-1' });
    await h.waitState(uid, (x) => x.last_id === 'r-1', 'role komutu last_id');
    // id'siz yama: last_id degismez (yalniz yayin)
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev + 1, set: { zone: { id: 3, name: 'Salon' } } });
    s = await h.waitState(uid, (x) => x.cfg.safety.rev === rev + 2, 'id\'siz yama');
    assert.equal(s.last_id, 'r-1');
    // NVS payi yetmedi: eskiden "busy", artik "cfg_storage"
    sim.nvs.failKeys.add('safety');
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev + 2, id: 'cfg-2', set: { zone: { id: 4, name: 'Bahce' } } });
    s = await h.waitState(uid, (x) => x.last_rej?.id === 'cfg-2', 'cfg_storage reddi');
    assert.equal(s.last_rej.code, 'cfg_storage');
    assert.equal(s.cfg.safety.rev, rev + 2);
    sim.nvs.failKeys.delete('safety');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});
