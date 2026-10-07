// WP-I3 (Faz 2 F2.B.11): hirsiz alarmi UCTAN UCA senaryolari -- cihaz simulatoru (firmware portlari) <-> QA brokeri + yerel HTTP.
// Kur/cik/gir/coz (MQTT safety_arm), intrusion_alarm -> event_ack, cozme -> intrusion_cleared + arm_changed; LAN POST /api/arm ve not_ready;
// kurulu kipte yeniden baslatma (kip korunur, cikis gecikmesi yok; bellekteki alarm sirensiz, ayni aid); ARM_KEY DI kenarlari ve LAN gevsetme
// kurali (kullanilmis DI'ye arm_key 403, bulut serbest); su alarmi + hirsiz alarmi birlikte (vana ve siren bagimsiz); caps "intrusion".
import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceSimulator } from '../sim/device_sim.js';
import { randomB64Url, randomHex } from '../lib/util.js';
import { startTestBroker, connect, subscribe, collect, publish, endClients, hashPw, waitFor, sleep } from './_helpers.js';

const KEY = 'sim-key-intrus01';

async function startHome({ uid = 'AHBU-S3-0C0001' } = {}) {
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
    uid, relays: 8, httpPort: 0, timeScale: 1, localKey: KEY, wifiConnected: true,
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

/** LAN uzerinden yapilandirma: her yama tek oge, base_rev zinciri. */
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

// Kapi d3 (NC, giris yolu), pencere d4 (NC, anlik), siren role 6; cikis/giris 1 sn.
const HOUSE = [
  { set: { sensor: { id: 'd3', kind: 'door', zone: 1, active_open: 1, name: 'Giris kapisi' } } },
  { set: { sensor: { id: 'd4', kind: 'window', zone: 1, active_open: 1, name: 'Salon penceresi' } } },
  { set: { actuator: { relay: 6, kind: 'siren', zones: [1], run_limit_s: 30 } } },
  { set: { intrusion: { exit_s: 1, entry_s: 1 } } },
];
/** Hirsiz sensorleri okundu (ok) ve arm nesnesi yayinlandi: kurma hazirligi denetimi anlamli (yapilandirma sonrasi ilk okuma). */
const armReady = (h) => h.waitState((x) => !!x.safety?.arm && x.sensors?.every((y) => y.ok), 'hirsiz katmani hazir');
const relayOn = (sim, n) => sim.qaState().relays[n - 1].state;
const arm = (s) => s.safety?.arm;
const closeContacts = (sim) => { sim.setDi(3, true); sim.setDi(4, true); };
const waitBooted = (sim, seq0) => waitFor(() => !sim.booting && sim.fw && sim.events.some((e) => e.n > seq0 && e.type === 'booted'), { timeoutMs: 6000, label: 'yeniden acilis' });

test('I3: kur (away) -> cikis -> bekci -> kapi acilir -> giris -> alarm -> event_ack -> cozme (intrusion_cleared + arm_changed)', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    closeContacts(sim);
    await configure(h, HOUSE);
    await armReady(h);
    let s = await h.waitState((x) => arm(x)?.mode === 'off', 'arm nesnesi');
    assert.ok(s.caps.includes('intrusion'));
    assert.deepEqual(arm(s), { mode: 'off', st: 'idle', ok: true });
    assert.equal(s.sensors.find((x) => x.id === 'd3').kind, 'door');
    await h.cmd({ cmd: 'safety_arm', mode: 'away', uid, id: 'arm-1' });
    s = await h.waitState((x) => x.last_id === 'arm-1' && arm(x)?.st === 'exit', 'cikis gecikmesi');
    assert.equal(arm(s).mode, 'away');
    assert.ok(Number.isInteger(arm(s).until_up) && arm(s).until_up >= s.uptime, 'until_up uptime saniyesi');
    const ac = await h.waitEvent((e) => e.type === 'arm_changed' && e.mode === 'away', 'arm_changed away');
    assert.equal(ac.via, 'cloud');
    s = await h.waitState((x) => arm(x)?.st === 'idle' && arm(x)?.mode === 'away', 'bekci');
    sim.setSensor('d3', true);
    s = await h.waitState((x) => arm(x)?.st === 'entry', 'giris gecikmesi');
    s = await h.waitState((x) => arm(x)?.st === 'alarm', 'hirsiz alarmi', 6000);
    assert.match(arm(s).aid, /^[0-9a-f]{8}-\d+$/);
    assert.deepEqual(arm(s).srcs, ['d3']);
    await waitFor(() => relayOn(sim, 6) === true, { timeoutMs: 3000, label: 'siren calmadi' });
    const ev = await h.waitEvent((e) => e.type === 'intrusion_alarm', 'intrusion_alarm');
    assert.equal(ev.eid, arm(s).aid, 'alarm kimligi = olayin eid\'si');
    assert.equal(ev.kind, 'intrusion');
    assert.equal(ev.zone, 1);
    assert.deepEqual(ev.srcs, ['d3']);
    assert.equal(ev.aid, undefined);
    await h.cmd({ cmd: 'event_ack', eids: [ev.eid], uid });
    await waitFor(() => !sim.qaSafetyState().outbox.some((o) => o.eid === ev.eid), { timeoutMs: 3000, label: 'event_ack silmedi' });
    sim.setSensor('d3', false);
    await h.cmd({ cmd: 'safety_arm', mode: 'off', uid, id: 'arm-2' });
    s = await h.waitState((x) => x.last_id === 'arm-2' && arm(x)?.mode === 'off', 'cozuldu');
    assert.deepEqual(arm(s), { mode: 'off', st: 'idle', ok: true });
    const cl = await h.waitEvent((e) => e.type === 'intrusion_cleared', 'intrusion_cleared');
    assert.equal(cl.aid, ev.eid);
    assert.equal(cl.via, 'cloud');
    await h.waitEvent((e) => e.type === 'arm_changed' && e.mode === 'off', 'arm_changed off');
    await waitFor(() => relayOn(sim, 6) === false, { timeoutMs: 3000, label: 'siren durmadi' });
    assert.ok(!JSON.stringify(s).includes('Giris kapisi'), 'adlar state\'te yok [B12]');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('I3: LAN POST /api/arm -- not_ready (acik pencere), bilinmeyen alan / gecersiz kip 400, home kurulur; /api/status arm; MQTT ret last_rej', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    closeContacts(sim);
    await configure(h, HOUSE);
    await armReady(h);
    sim.setSensor('d4', true);
    await sleep(100);
    let r = await h.http('POST', '/api/arm', { mode: 'away' });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, false);
    assert.equal(r.json.rej, 'not_ready');
    r = await h.http('POST', '/api/arm', { mode: 'away', zone: 1 });
    assert.deepEqual([r.status, r.json.error], [400, 'unknown_field']);
    r = await h.http('POST', '/api/arm', { mode: 'vacation' });
    assert.deepEqual([r.status, r.json.error], [400, 'invalid_value']);
    await h.cmd({ cmd: 'safety_arm', mode: 'home', uid, id: 'arm-nr' });
    await h.waitState((x) => x.last_rej?.id === 'arm-nr' && x.last_rej.code === 'not_ready', 'MQTT not_ready last_rej');
    sim.setSensor('d4', false);
    await sleep(100);
    r = await h.http('POST', '/api/arm', { mode: 'home', id: 'lan-arm-1' });
    assert.deepEqual(r.json, { ok: true, id: 'lan-arm-1' });
    const st = await h.http('GET', '/api/status');
    assert.equal(st.json.safety.arm.mode, 'home');
    assert.ok(st.json.caps.includes('intrusion'));
    await h.waitEvent((e) => e.type === 'arm_changed' && e.mode === 'home' && e.via === 'lan', 'arm_changed via lan');
    r = await h.http('POST', '/api/arm', { mode: 'off' });
    assert.equal(r.json.ok, true);
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('I3: kurulu kipte yeniden baslatma -- kip korunur (cikis yok, arm_changed via boot); bellekteki alarm sirensiz ve ayni aid', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    closeContacts(sim);
    await configure(h, HOUSE);
    await armReady(h);
    await h.cmd({ cmd: 'safety_arm', mode: 'away', uid });
    await h.waitState((x) => arm(x)?.st === 'idle' && arm(x)?.mode === 'away', 'bekci');
    let seq0 = sim.events.at(-1).n;
    sim.reboot();
    await waitBooted(sim, seq0);
    await h.ready();
    closeContacts(sim);
    let s = await h.waitState((x) => x.boot >= 2 && arm(x)?.mode === 'away', 'acilista kip');
    assert.equal(arm(s).st, 'idle', 'acilista cikis gecikmesi YOK');
    await h.waitEvent((e) => e.type === 'arm_changed' && e.via === 'boot' && e.mode === 'away', 'arm_changed via boot');
    sim.setSensor('d4', true);
    s = await h.waitState((x) => arm(x)?.st === 'alarm', 'anlik alarm');
    const aid = arm(s).aid;
    await waitFor(() => relayOn(sim, 6) === true, { timeoutMs: 3000, label: 'siren' });
    sim.setSensor('d4', false);
    seq0 = sim.events.at(-1).n;
    sim.reboot();
    await waitBooted(sim, seq0);
    await h.ready();
    closeContacts(sim);
    s = await h.waitState((x) => x.boot >= 3 && arm(x)?.st === 'alarm', 'alarm bellegi');
    assert.equal(arm(s).aid, aid, 'ayni alarm kimligi');
    await sleep(400);
    assert.equal(relayOn(sim, 6), false, 'bellekteki alarm sireni CALMAZ (F2-4)');
    const r = await h.http('POST', '/api/arm', { mode: 'off' });
    assert.equal(r.json.ok, true);
    const cl = await h.waitEvent((e) => e.type === 'intrusion_cleared' && e.aid === aid, 'intrusion_cleared');
    assert.equal(cl.via, 'lan');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('I3: ARM_KEY anahtarli kontak (kenarla kur/coz, via di); LAN\'dan kullanilmis DI\'ye arm_key 403, yeni DI serbest, bulut serbest', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    closeContacts(sim);
    await configure(h, HOUSE);
    await armReady(h);
    // d3 kapi kontagi: LAN'dan arm_key'e cevirmek gevsetme (kapiyi kapatmak alarmi cozerdi)
    let rev = (await h.http('GET', '/api/safety/config')).json.rev;
    let r = await h.http('POST', '/api/safety/config', { base_rev: rev, set: { sensor: { id: 'd3', kind: 'arm_key', zone: 0, active_open: 1 } } });
    assert.deepEqual([r.status, r.json.error], [403, 'local_loosen_forbidden']);
    // Faz 2 incelemesi RV-E3: anahtarli kontak yalniz NC (active_open 1; kurulu konumda kontak acik): NO 400 cfg_invalid arm_key_not_nc
    r = await h.http('POST', '/api/safety/config', { base_rev: rev, set: { sensor: { id: 'd5', kind: 'arm_key', zone: 0, name: 'Anahtar' } } });
    assert.deepEqual([r.status, r.json.error, r.json.detail], [400, 'cfg_invalid', 'arm_key_not_nc']);
    sim.setDi(5, true);                                   // NC kontak kapali: anahtar cozulu konumda
    r = await h.http('POST', '/api/safety/config', { base_rev: rev, set: { sensor: { id: 'd5', kind: 'arm_key', zone: 0, active_open: 1, name: 'Anahtar' } } });
    assert.equal(r.status, 200);
    rev = r.json.rev;
    await sleep(100);
    sim.setDi(5, false);                                  // kontak acildi (pasif -> aktif): dışarıda kip
    let s = await h.waitState((x) => arm(x)?.mode === 'away', 'anahtarla kuruldu');
    assert.equal(s.sensors.find((x) => x.id === 'd5').kind, 'arm_key');
    await h.waitEvent((e) => e.type === 'arm_changed' && e.mode === 'away' && e.via === 'di', 'arm_changed via di');
    sim.setDi(5, true);                                   // aktif -> pasif: cozme
    s = await h.waitState((x) => arm(x)?.mode === 'off', 'anahtarla cozuldu');
    // bulut (owner/servis yetkisi sunucuda) gevsetebilir: kullanilmis d4'u arm_key yapar
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id: 'cfg-ak', set: { sensor: { id: 'd4', kind: 'arm_key', zone: 0, active_open: 1 } } });
    s = await h.waitState((x) => x.last_id === 'cfg-ak' && x.sensors.find((y) => y.id === 'd4')?.kind === 'arm_key', 'buluttan arm_key');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('I3: su alarmi + hirsiz alarmi birlikte -- vana yalniz su ile kapanir; cozme vanayi acmaz, tehlike sireni surer', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    closeContacts(sim);
    await configure(h, [
      ...HOUSE,
      { set: { sensor: { id: 'd2', kind: 'water', zone: 1 } } },
      { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1] } } },
    ]);
    await armReady(h);
    await h.cmd({ cmd: 'safety_arm', mode: 'home', uid });
    await h.waitState((x) => arm(x)?.st === 'idle' && arm(x)?.mode === 'home', 'bekci');
    sim.setSensor('d4', true);
    let s = await h.waitState((x) => arm(x)?.st === 'alarm', 'hirsiz alarmi');
    assert.equal(relayOn(sim, 5), false, 'hirsiz alarmi vana surmez');
    assert.ok(!(s.safety.zones || []).some((z) => z.st === 'latched'), 'hirsiz alarmi bolge kilidi uretmez');
    sim.setSensor('d2', true);
    s = await h.waitState((x) => (x.safety.zones || []).some((z) => z.st === 'latched' && z.kind === 'water'), 'su kilidi');
    await waitFor(() => relayOn(sim, 5) === true, { timeoutMs: 3000, label: 'vana kapanmadi (E2C)' });
    await h.cmd({ cmd: 'safety_arm', mode: 'off', uid });
    s = await h.waitState((x) => arm(x)?.mode === 'off', 'cozuldu');
    await sleep(200);
    assert.equal(relayOn(sim, 6), true, 'cozme tehlike sirenini susturmaz');
    assert.equal(relayOn(sim, 5), true, 'vana kapali kalir');
    assert.equal(s.safety.zones[0].st, 'latched');
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

// Faz 2 incelemesi G-1b (R1): kurulu kipte bulut yamasi hirsiz sensorunu alarm disi birakamaz / silemez / gecikmeyi uzatamaz (armed);
// cozuluyken ayni yama uygulanir (kurulumcu islemi). LAN B.3 geregi kurulu kipte de serbesttir (yerel anahtar sahibi zaten cozebilir).
test('I3: kurulu kipte bulut yamasi hirsiz alarmini zayiflatamaz (armed); cozuluyken uygulanir; LAN serbest (G-1b)', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    closeContacts(sim);
    await configure(h, HOUSE);
    await armReady(h);
    await h.cmd({ cmd: 'safety_arm', mode: 'away', uid, id: 'g1b-arm' });
    await h.waitState((x) => arm(x)?.st === 'idle' && arm(x)?.mode === 'away', 'bekci');
    let rev = (await h.http('GET', '/api/safety/config')).json.rev;
    const patches = [
      ['g1b-flags', { set: { sensor: { id: 'd4', kind: 'window', zone: 1, active_open: 1, flags: 0 } } }],
      ['g1b-del', { del: { sensor: 'd4' } }],
      ['g1b-entry', { set: { intrusion: { entry_s: 200 } } }],
    ];
    for (const [id, p] of patches) {
      await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id, ...p });
      const s = await h.waitState((x) => x.last_rej?.id === id, `${id} reddi`);
      assert.equal(s.last_rej.code, 'armed', id);
    }
    assert.equal((await h.http('GET', '/api/safety/config')).json.rev, rev, 'yapilandirma degismedi');
    // zayiflatmayan bulut yamasi (gecikme kisaltma) kurulu kipte de uygulanir
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id: 'g1b-tight', set: { intrusion: { entry_s: 1 } } });
    await h.waitState((x) => x.last_id === 'g1b-tight', 'sikilastirma uygulandi');
    rev = (await h.http('GET', '/api/safety/config')).json.rev;
    sim.setSensor('d4', true);                           // pencere hala alarmda (anlik)
    await h.waitState((x) => arm(x)?.st === 'alarm', 'alarm calar (bypass yok)');
    await h.cmd({ cmd: 'safety_arm', mode: 'off', uid, id: 'g1b-off' });
    await h.waitState((x) => arm(x)?.mode === 'off', 'cozuldu');
    sim.setSensor('d4', false);
    await h.sys({ cmd: 'cfg_patch', module: 'safety', uid, base_rev: rev, id: 'g1b-off-flags', set: { sensor: { id: 'd4', kind: 'window', zone: 1, active_open: 1, flags: 0 } } });
    await h.waitState((x) => x.last_id === 'g1b-off-flags', 'cozuluyken uygulandi');
    // LAN kurulu kipte de serbest (B.3)
    await h.cmd({ cmd: 'safety_arm', mode: 'away', uid, id: 'g1b-arm2' });
    await h.waitState((x) => arm(x)?.mode === 'away', 'yeniden kuruldu');
    rev = (await h.http('GET', '/api/safety/config')).json.rev;
    const r = await h.http('POST', '/api/safety/config', { base_rev: rev, del: { sensor: 'd4' } });
    assert.equal(r.status, 200, `LAN silme: ${JSON.stringify(r.json)}`);
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});
