// Faz 2 KATMANLAR ARASI SOZLESME (birlestirme hizalamasi, CONTRACTS §1.5e / §2.6 / §2.7): firmware simulatorunun (fw portlari) GERCEKTEN
// yayinladigi yukler sunucunun GERCEK dogrulayicilarindan (server/src/utils) gecmeli; sunucunun urettigi komut / yama yukleri de
// firmware'de kabul edilmeli. Uc ekip ayri klonlarda calistigi icin alan adlari ancak bu testle uctan uca baglanir:
//   - ev/{t}/event: intrusion_alarm / intrusion_cleared / arm_changed -> validateEventPayload (KATI alan listesi) kabul eder;
//   - ev/{t}/state: safety.arm -> parseStateSafety ozetinde ayni mode/st/aid/srcs; arm_key kumandasi 'generic'e dusmez;
//   - sunucu command_schema 'safety_arm' komutu -> firmware ayristiricisi kabul eder (last_id yankisi);
//   - sunucu cfg_patch (set.intrusion, caps 'intrusion') -> firmware uygular, state.last_id = yama id'si (C1) ve cfg.rev = base_rev+1;
//   - cfg_dump (cfg_get) -> validateEventPayload + mergeCfgDumpParts "intrusion" gecikmelerini KORUR (uygulama sihirbazi okur).
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { DeviceSimulator } from '../sim/device_sim.js';
import { randomB64Url, randomHex } from '../lib/util.js';
import { startTestBroker, connect, subscribe, collect, publish, endClients, hashPw, waitFor, sleep } from './_helpers.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER_SRC = path.resolve(HERE, '..', '..', '..', 'server', 'src');
const require = createRequire(import.meta.url);
const payload = require(path.join(SERVER_SRC, 'utils', 'safety_payload.js'));
const commandSchema = require(path.join(SERVER_SRC, 'utils', 'command_schema.js'));
const cfgPatch = require(path.join(SERVER_SRC, 'utils', 'safety_cfg_patch.js'));

const KEY = 'sim-key-contract1';

async function startHome({ uid = 'AHBU-S3-0C00F2' } = {}) {
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
    backend, sim, uid,
    states: () => msgs.filter((m) => m.topic === `ev/${T}/state`).filter(mine).map((m) => JSON.parse(m.payload)),
    events: () => msgs.filter((m) => m.topic === `ev/${T}/event`).filter(mine).map((m) => JSON.parse(m.payload)),
    waitState: (pred, label = 'state', timeoutMs = 8000) => waitFor(() => { const s = h.states().at(-1); return s && pred(s) ? s : null; }, { timeoutMs, label }),
    waitEvent: (pred, label = 'event', timeoutMs = 8000) => waitFor(() => h.events().find(pred) || null, { timeoutMs, label }),
    cmd: (obj) => publish(backend, `ev/${T}/cmd`, obj),
    sys: (obj) => publish(backend, `ev/${T}/sys`, obj),
    http: async (method, p, body) => {
      const r = await fetch(`http://127.0.0.1:${sim.httpPort}${p}`, {
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

async function freeIo(h) {
  const dis = Array.from({ length: 8 }, () => ({ target_relay: 0 }));
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

/** Sunucunun komut semasindan gecen komut (uygulama -> REST -> kopru yolu). */
function serverCommand(input) {
  const v = commandSchema.validateCommand(input);
  assert.equal(v.ok, true, `sunucu semasi reddetti: ${JSON.stringify(input)} -> ${v.error}`);
  return v.command;
}

const HOUSE = [
  { set: { sensor: { id: 'd3', kind: 'door', zone: 1, active_open: 1, name: 'Giris kapisi' } } },
  { set: { sensor: { id: 'd4', kind: 'window', zone: 2, active_open: 1, name: 'Salon penceresi' } } },
  { set: { sensor: { id: 'd6', kind: 'arm_key', zone: 0, active_open: 1, name: 'Anahtar' } } },
  { set: { actuator: { relay: 6, kind: 'siren', zones: [1], run_limit_s: 30 } } },
  { set: { intrusion: { exit_s: 1, entry_s: 1 } } },
];

test('F2 sozlesme: firmware hirsiz olaylari / state.safety.arm sunucu dogrulayicilarindan gecer; sunucu safety_arm komutunu firmware kabul eder', async () => {
  const h = await startHome();
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(3, true);
    sim.setDi(4, true);
    await configure(h, HOUSE);
    let s = await h.waitState((x) => x.safety?.arm?.mode === 'off' && x.sensors?.every((y) => y.ok), 'hirsiz katmani hazir');

    // state: caps + arm_key kumandasi + arm ozeti
    let sum = payload.parseStateSafety(s);
    assert.ok(sum.caps.includes('intrusion'), 'caps intrusion sunucuya ulasir');
    assert.equal(sum.skipped, 0, `state ozetinde atlanan alan yok: ${sum.skipped}`);
    assert.deepEqual(sum.summary.arm, { mode: 'off', st: 'idle', ok: true, aid: null, srcs: [] });
    const key = sum.summary.sensors.find((x) => x.id === 'd6');
    assert.equal(key && key.kind, 'arm_key', 'arm_key kumandasi sunucu ozetinde generic\'e dusmez');

    // sunucu semasindan gecen kurma komutu
    await h.cmd(serverCommand({ cmd: 'safety_arm', mode: 'away', uid, id: 'srv-arm-1' }));
    s = await h.waitState((x) => x.last_id === 'srv-arm-1' && x.safety?.arm?.st === 'exit', 'cikis gecikmesi (sunucu komutu)');
    s = await h.waitState((x) => x.safety?.arm?.st === 'idle' && x.safety.arm.mode === 'away', 'bekci');
    sim.setSensor('d4', true); // anlik sensor (pencere, bolge 2)
    s = await h.waitState((x) => x.safety?.arm?.st === 'alarm', 'hirsiz alarmi', 6000);
    sum = payload.parseStateSafety(s);
    assert.equal(sum.summary.arm.st, 'alarm');
    assert.equal(sum.summary.arm.mode, 'away');
    assert.equal(sum.summary.arm.aid, s.safety.arm.aid);
    assert.deepEqual(sum.summary.arm.srcs, ['d4']);

    sim.setSensor('d4', false);
    await h.cmd(serverCommand({ cmd: 'safety_arm', mode: 'off', uid, id: 'srv-arm-2' }));
    await h.waitState((x) => x.last_id === 'srv-arm-2' && x.safety?.arm?.mode === 'off', 'cozuldu');
    await h.waitEvent((e) => e.type === 'arm_changed' && e.mode === 'off', 'arm_changed off');

    // olaylar: her hirsiz olayi sunucunun KATI dogrulamasindan gecer
    const evs = h.events().filter((e) => ['intrusion_alarm', 'intrusion_cleared', 'arm_changed'].includes(e.type));
    const types = new Set(evs.map((e) => e.type));
    assert.deepEqual([...types].sort(), ['arm_changed', 'intrusion_alarm', 'intrusion_cleared']);
    for (const e of evs) {
      const v = payload.validateEventPayload(e);
      assert.equal(v.ok, true, `sunucu olayi reddetti: ${JSON.stringify(e)} -> ${v.reason}`);
      assert.notEqual(v.value.unknown, true, `bilinmeyen tur sayildi: ${e.type}`);
    }
    const alarm = evs.find((e) => e.type === 'intrusion_alarm');
    const va = payload.validateEventPayload(alarm).value;
    assert.equal(va.aid, alarm.eid, 'alarm kimligi olayin eid\'si');
    assert.equal(va.kind, 'intrusion');
    assert.equal(va.zone, 2, 'ilk tetikleyen sensorun bolgesi');
    const cl = payload.validateEventPayload(evs.find((e) => e.type === 'intrusion_cleared')).value;
    assert.equal(cl.aid, alarm.eid);
    assert.equal(cl.via, 'cloud');
    assert.ok(evs.filter((e) => e.type === 'arm_changed').every((e) => payload.validateEventPayload(e).value.mode === e.mode));
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});

test('F2 sozlesme: sunucu cfg_patch (set.intrusion) firmware\'de uygulanir, last_id yankisi; cfg_dump "intrusion" gecikmeleri sunucu kopyasinda korunur', async () => {
  const h = await startHome({ uid: 'AHBU-S3-0C00F3' });
  const { sim, uid } = h;
  try {
    await h.ready();
    await freeIo(h);
    sim.setDi(3, true);
    await configure(h, HOUSE.slice(0, 1));
    const s0 = await h.waitState((x) => x.safety?.arm && x.cfg?.safety, 'yapilandirilmis state');
    const sum0 = payload.parseStateSafety(s0);
    const baseRev = sum0.summary.cfg.rev;

    const body = { base_rev: baseRev, id: 'srv-cfg-1', set: { intrusion: { exit_s: 20, entry_s: 15 } } };
    const v = cfgPatch.validatePatchRequest(body, { caps: sum0.caps });
    assert.equal(v.ok, true, `sunucu yamayi reddetti: ${v.error}`);
    const sys = cfgPatch.buildSysPayload({ uid, id: body.id, baseRev, patch: v.patch });
    await h.sys(sys);
    const s1 = await h.waitState((x) => x.last_id === 'srv-cfg-1', 'cfg_patch last_id yankisi (C1)');
    assert.equal(payload.parseStateSafety(s1).summary.cfg.rev, baseRev + 1, 'kopru bekleyicisinin cfgRev\'i (base_rev + 1)');

    // cfg_get -> cfg_dump: sunucu dogrulamasi + parca birlestirme intrusion'i korur
    await h.sys({ cmd: 'cfg_get', module: 'safety', uid });
    const dump = await h.waitEvent((e) => e.type === 'cfg_dump' && e.rev === baseRev + 1 && e.part === 1, 'cfg_dump');
    const parts = h.events().filter((e) => e.type === 'cfg_dump' && e.rev === baseRev + 1);
    const vd = payload.validateEventPayload(dump);
    assert.equal(vd.ok, true, `cfg_dump reddedildi: ${vd.reason}`);
    assert.deepEqual(vd.value.body.intrusion, { exit_s: 20, entry_s: 15 }, 'cfg_dump intrusion govdede');
    const merged = payload.mergeCfgDumpParts(parts.map((p) => payload.validateEventPayload(p).value.body));
    assert.deepEqual(merged.intrusion, { exit_s: 20, entry_s: 15 }, 'birlesik kopyada intrusion');
    // yama kopyaya uygulanirken de ayni bicim (gevsetme siniflandirmasi)
    const copy = cfgPatch.applyPatch(merged, { set: { intrusion: { exit_s: 30 } } });
    assert.deepEqual(copy.intrusion, { exit_s: 30, entry_s: 15 });
    await sleep(50);
    assert.deepEqual(sim.violations, []);
  } finally {
    await h.close();
  }
});
