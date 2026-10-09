// Cihaz simulatoru <-> broker (CONTRACTS §2) = firmware MqttManager portu: kimlikle baglanma, retained state v3 (v1.2.0; v2'nin ust kumesi)/status, LWT, cmd hatti,
// abonelik sonrasi 1500 ms yok sayma, id tekillestirme, sys, offline/crash/power-cycle, slow, DI, Wi-Fi kaybi.
import test from 'node:test';
import { performance } from 'node:perf_hooks';
import assert from 'node:assert/strict';
import { DeviceSimulator } from '../sim/device_sim.js';
import { FW_VERSION_DEFAULT } from '../sim/fw/wifi_manager.js';
import { compute as lkFp } from '../sim/fw/local_key_fp.js';
import { randomB64Url, randomHex } from '../lib/util.js';
import {
  startTestBroker, connect, subscribe, collect, publish, endClients, hashPw, waitFor, sleep,
} from './_helpers.js';

const KEY = 'sim-key-abcdef12';
const UID = 'AHBU-S3-0A0010';
/** ev/{t}/status yuku v1.3.1: gercek JSON {status, uid} (guvenlik-6). Gecersiz/eksik yuk -> null. */
const statusOf = (m) => {
  if (!m) return null;
  try { return JSON.parse(m.payload).status ?? null; } catch (_) { return null; }
};

async function setup({ simOpts = {}, startSim = true, retainedCmd = null, store, windowMs = 250 } = {}) {
  const ctx = await startTestBroker(store ? { store } : {});
  const T = `h_${randomHex(8)}`;
  const devPass = randomB64Url(12);
  ctx.store.addCredential({ username: `d_${T}`, password_hash: hashPw(devPass), kind: 'device' });
  for (const [perm, act, topic] of [['allow', 'publish', `ev/${T}/state`], ['allow', 'publish', `ev/${T}/status`],
    ['allow', 'subscribe', `ev/${T}/cmd`], ['allow', 'subscribe', `ev/${T}/sys`]]) {
    ctx.store.addAcl({ username: `d_${T}`, permission: perm, action: act, topic });
  }
  ctx.store.addCredential({ username: `a_${T}_x`, password_hash: hashPw('app-pw'), kind: 'app' });
  ctx.store.addAcl({ username: `a_${T}_x`, permission: 'allow', action: 'subscribe', topic: `ev/${T}/state` });
  ctx.store.addAcl({ username: `a_${T}_x`, permission: 'allow', action: 'subscribe', topic: `ev/${T}/status` });

  const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password, clientId: 'qa-backend' });
  const msgs = collect(backend);
  await subscribe(backend, `ev/${T}/state`);
  await subscribe(backend, `ev/${T}/status`);
  if (retainedCmd) await publish(backend, `ev/${T}/cmd`, retainedCmd, { retain: true });

  const sim = new DeviceSimulator({
    uid: UID,
    relays: 8,
    httpPort: 0,
    timeScale: 50,
    localKey: KEY,
    wifiConnected: true,
    homeWifi: { ssid: 'TestHome', pass: 'home-pass-123' },
    wifiTiming: { connectMs: 60, scanMs: 60, sntpMs: 20 },
    mqtt: { host: '127.0.0.1', port: ctx.port, user: `d_${T}`, pass: devPass },
    mqttTiming: { ignoreWindowMs: windowMs, backoffMinMs: 200, backoffMaxMs: 400, authFailWaitMs: 300 },
    bootHoldMs: 0,
    bootMs: 200,
    rebootMs: 300,
    strict: true,
    ...simOpts,
  });
  if (startSim) await sim.start();

  const states = () => msgs.filter((m) => m.topic === `ev/${T}/state`).map((m) => ({ ...m, json: JSON.parse(m.payload) }));
  const statuses = () => msgs.filter((m) => m.topic === `ev/${T}/status`);
  const api = {
    ctx, T, sim, backend, msgs, devPass, states, statuses,
    lastState: () => states().at(-1)?.json,
    waitState: (pred, label = 'state') => waitFor(() => { const l = states().at(-1); return l && pred(l.json) ? l.json : null; }, { timeoutMs: 6000, label: `${label} beklenen duruma gelmedi` }),
    ready: () => waitFor(() => { const m = sim.qaState().mqtt; return m && m.connected && m.cmd_subscribed && m.in_startup_window === false; }, { timeoutMs: 8000, label: 'cihaz hazir olmadi' }),
    cmd: (obj, opts) => publish(backend, `ev/${T}/cmd`, obj, opts),
    log: () => sim.eventsSince(0, 500),
    http: (method, path, body) => fetch(`http://127.0.0.1:${sim.httpPort}${path}`, {
      method, headers: { 'X-Device-Key': KEY, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined,
    }),
    async close() {
      await sim.stop().catch(() => {});
      await endClients(backend);
      await ctx.broker.close();
    },
  };
  return api;
}

test('baglanma: cihaz kimligiyle baglanir; status=online (QoS0 retained) ve state v2 (QoS0 retained) yayinlanir; bos last_id gonderilmez; yalniz gercek panjur ciftleri', async () => {
  const h = await setup();
  const app = [];
  try {
    await h.ready();
    await h.waitState((s) => s.seq >= 1, 'ilk state');
    assert.deepEqual(JSON.parse(h.statuses()[0].payload), { status: 'online', uid: UID }, 'status JSON + uid (guvenlik-6)');
    assert.equal(h.states()[0].qos, 0, 'state QoS 0');

    const s = h.states()[0].json;
    assert.equal(s.v, 3);   // v1.2.0: v:3 = v:2'nin kati ust kumesi (spec 3.1); yapilandirilmamis panoda ek anahtarlar yalniz caps/boot/bn/time_ok/epoch
    assert.deepEqual(s.caps, ['safety', 'actuator', 'event', 'cfg', 'intrusion']);
    assert.match(s.bn, /^[0-9a-f]{8}$/);
    for (const k of ['sensors', 'actuators', 'safety', 'last_rej']) assert.ok(!(k in s), `${k} yapilandirilmamis panoda yazilmaz`);
    assert.equal(s.cfg.safety.rev, 0, 'cfg.safety yapilandirilmamis panoda da var (guvenlik-3)');
    assert.match(s.cfg.safety.crc, /^[0-9a-f]{8}$/);
    assert.equal(s.lk_fp, lkFp(KEY, UID), 'provizyonlu panoda lk_fp (pano-5)');
    assert.equal(s.uid, UID);
    assert.equal(s.fw, FW_VERSION_DEFAULT);
    assert.equal(s.seq, 1);
    assert.equal(typeof s.uptime, 'number');
    assert.match(s.ip, /^192\.168\.1\.\d+$/);
    assert.equal(s.child_lock, false);
    assert.ok(!('last_id' in s), 'bos last_id gonderilmez (backend bos degeri atlandi sayar)');
    assert.equal(s.relays.length, 8);
    assert.deepEqual(s.relays[0], { id: 1, name: 'Salon Panjur (Yukari)', type: 'shutter_up', state: false });
    assert.deepEqual(s.relays[4], { id: 5, name: 'Röle 5', type: 'light', state: false });   // fabrika varsayilani (sabit rol yok)
    assert.deepEqual(s.shutters, [
      { pair: 1, pos: 0, moving: false, dir: 0, target: 255 },
      { pair: 2, pos: 0, moving: false, dir: 0, target: 255 },
    ]);
    assert.equal(s.dis.length, 8);
    assert.deepEqual(s.dis[0], { id: 1, state: false });

    // gec abone (salt-okunur uygulama kimligi) retained state/status alir
    const a = await connect({ port: h.ctx.port, username: `a_${h.T}_x`, password: 'app-pw' });
    app.push(a);
    const got = collect(a);
    await subscribe(a, `ev/${h.T}/state`);
    await subscribe(a, `ev/${h.T}/status`);
    await waitFor(() => got.length >= 2, { timeoutMs: 3000, label: 'retained mesajlar gelmedi' });
    assert.ok(got.every((m) => m.retain), 'state ve status retained');
    assert.equal(statusOf(got.find((m) => m.topic.endsWith('/status'))), 'online');
    assert.equal(JSON.parse(got.find((m) => m.topic.endsWith('/state')).payload).v, 3);
  } finally {
    await endClients(app);
    await h.close();
  }
});

test('cmd hatti: role/panjur/toplu/cocuk kilidi/set_runtime komutlari uygulanir ve state yayinlanir; last_id yankilanir', async () => {
  const h = await setup({ simOpts: { timeScale: 5 } });
  try {
    await h.ready();
    await h.cmd({ relay: 5, state: true, id: 'c1' });
    let s = await h.waitState((x) => x.relays[4].state === true);
    assert.equal(s.last_id, 'c1', 'id geri yankilanir');

    await h.cmd({ relay: 5, cmd: 'toggle' });
    await h.waitState((x) => x.relays[4].state === false);

    await h.cmd({ relay: 6, state: true });
    await h.cmd({ relay: 7, state: true });
    await h.waitState((x) => x.relays[5].state && x.relays[6].state);
    await h.cmd({ cmd: 'all_lights_off' });
    await h.waitState((x) => !x.relays[5].state && !x.relays[6].state);
    await h.cmd({ relay: 6, state: true });
    await h.waitState((x) => x.relays[5].state);
    await h.cmd({ cmd: 'all_off' });
    await h.waitState((x) => !x.relays[5].state);

    await h.cmd({ shutter: 1, cmd: 'up' });
    s = await h.waitState((x) => x.shutters[0].moving === true);
    assert.deepEqual([s.shutters[0].dir, s.shutters[0].target], [1, 100]);
    assert.equal(s.relays[0].state, true);
    assert.equal(s.relays[1].state, false);
    await h.cmd({ shutter: 1, cmd: 'stop' });
    s = await h.waitState((x) => x.shutters[0].moving === false);
    assert.equal(s.shutters[0].target, 255);

    await h.cmd({ shutter: 2, pos: 30 });
    s = await h.waitState((x) => x.shutters[1].moving === true && x.shutters[1].target === 30);
    await h.waitState((x) => x.shutters[1].moving === false && x.shutters[1].pos === 30, 'hedef konum');

    await h.cmd({ cmd: 'all_shutters_up' });
    await h.waitState((x) => x.shutters[0].dir === 1 && x.shutters[1].dir === 1);
    await h.cmd({ cmd: 'all_shutters_stop' });
    await h.waitState((x) => x.shutters[0].dir === 0 && x.shutters[1].dir === 0);

    await h.cmd({ cmd: 'set_child_lock', enabled: true });
    await h.waitState((x) => x.child_lock === true);
    await h.cmd({ cmd: 'set_runtime', shutter: 2, sec: 24 });
    await waitFor(() => h.sim.qaState().relays[2].runtime_sec === 24, { timeoutMs: 3000, label: 'set_runtime uygulanmadi' });
    assert.equal(h.sim.qaState().violation_count, 0);
  } finally {
    await h.close();
  }
});

test('hareket sirasinda durum ~1 sn\'de bir (konum ilerlemesi) yayinlanir; konum imzaya girmedigi icin firtina yok', async () => {
  const h = await setup({ simOpts: { timeScale: 4 } });   // 20 sn -> 5 sn
  try {
    await h.ready();
    await h.cmd({ shutter: 1, cmd: 'up' });
    await h.waitState((x) => x.shutters[0].moving === true);
    await h.waitState((x) => x.shutters[0].moving === false && x.shutters[0].pos === 100, 'tam acik');
    const moving = h.states().map((m) => m.json).filter((x) => x.shutters[0].moving);
    const positions = moving.map((x) => x.shutters[0].pos);
    assert.ok(moving.length >= 3 && moving.length <= 12, `hareket sirasinda yayin sayisi: ${moving.length}`);
    assert.ok(new Set(positions).size >= 3, `ilerleme yayinlanmadi: ${positions}`);
    assert.deepEqual([...positions].sort((a, b) => a - b), positions, 'konum artarak ilerler');
  } finally {
    await h.close();
  }
});

test('dogrulama: bilinmeyen alan/komut, tip/aralik hatasi, bozuk JSON UYGULANMAZ ve nedeni kaydedilir; >512 bayt yuk sessizce yok sayilir', async () => {
  const h = await setup();
  try {
    await h.ready();
    const before = JSON.stringify(h.sim.qaState().relays.map((r) => r.state));
    const bad = [
      '{"relay":3,"state":"ON"}', '{"relay":99,"state":true}', '{"relay":0,"state":true}', '{"shutter":1,"pos":101}',
      '{"shutter":1,"pos":256}', '{"bogus":1}', '{"cmd":"reboot"}', '{"relay":3,"state":true,"extra":1}',
      '{"cmd":"set_runtime","shutter":1,"sec":301}', '{bozuk', '[1]', '"x"', `{"relay":3,"state":true,"id":"${'x'.repeat(25)}"}`,
      '{"relay":3,"state":1}', '{"relay":3.5,"state":true}', '{"relay":"3","state":true}', '{"relay":3,"state":true,"id":"a b"}',
      '{"cmd":"toggle","relay":3,"state":true}', '{"shutter":1,"cmd":"up","pos":5}', '{"cmd":"set_child_lock"}', '{"cmd":"set_child_lock","enabled":1}',
      '{"cmd":"all_lights_off","relay":1}', '{"relay":3}', '{}',
    ];
    for (const p of bad) await h.cmd(p);
    await h.cmd(JSON.stringify({ relay: 3, state: true, id: 'big', pad: 'x'.repeat(600) }));   // > 512 bayt
    await h.cmd({ relay: 5, state: true });                                                     // gecerli komut en sonda: isleme sirasini dogrular
    await h.waitState((x) => x.relays[4].state === true);
    const rejected = h.log().filter((e) => e.type === 'cmd_rejected');
    assert.equal(rejected.length, bad.length, JSON.stringify(rejected.map((r) => r.reason)));
    const reasons = rejected.map((r) => r.reason).join(' | ');
    for (const r of ['bilinmeyen alan', 'bilinmeyen komut', 'JSON hatasi', 'kok nesne olmali', 'araligi', 'id gecersiz', 'boolean olmali', 'tamsayi olmali', 'gecersiz komut bicimi']) {
      assert.ok(reasons.includes(r), `neden kaydedilmedi: ${r}`);
    }
    assert.ok(h.log().some((e) => e.type === 'cmd_ignored' && e.reason === 'bad_payload_size'), '> 512 bayt yuk yok sayildi');
    const after = h.sim.qaState().relays.map((r) => r.state);
    assert.equal(after[2], false, 'state:"ON" uygulanmadi');
    assert.deepEqual(after.filter((s, i) => i !== 4), JSON.parse(before).filter((s, i) => i !== 4));
  } finally {
    await h.close();
  }
});

test('retained cmd ve abonelik sonrasi ILK 1500 ms icindeki cmd/sys mesajlari YOK SAYILIR; sonrasi uygulanir', async () => {
  const h = await setup({ startSim: false, retainedCmd: { relay: 6, state: true }, windowMs: 1500 });
  try {
    assert.equal(h.sim.opts.mqttTiming.ignoreWindowMs, 1500);
    await h.sim.start();
    await waitFor(() => h.sim.qaState().mqtt.connected, { timeoutMs: 6000, label: 'baglanti' });
    await sleep(300);
    assert.equal(h.sim.qaState().relays[5].state, false, 'retained cmd tekrar uygulanmamali');
    const ign = h.log().filter((e) => e.type === 'cmd_ignored' && e.reason === 'startup_window');
    assert.equal(ign.length >= 1, true);
    assert.equal(ign[0].retain, true, 'retained mesaj yok sayildi');

    // pencere icindeki canli komut da yok sayilir
    await h.cmd({ relay: 7, state: true });
    await sleep(200);
    assert.equal(h.sim.qaState().relays[6].state, false);
    assert.equal(h.sim.qaState().mqtt.in_startup_window, true);

    // pencere icindeki sys (anahtar) mesaji da yok sayilir
    await publish(h.backend, `ev/${h.T}/sys`, { cmd: 'set_local_key', local_key: 'pencere-icinde-1' });
    await sleep(150);
    assert.equal((await h.http('GET', '/api/auth/check')).status, 200, 'pencere icindeki sys uygulanmadi');

    await h.ready();
    await h.cmd({ relay: 7, state: true });
    await h.waitState((x) => x.relays[6].state === true);
    assert.equal(h.sim.qaState().relays[5].state, false, 'retained komut hala uygulanmadi');
  } finally {
    await h.close();
  }
});

test('id tekillestirme: ayni id ikinci kez yok sayilir; son 8 id hatirlanir; baglanti kurulunca temizlenir', async () => {
  const h = await setup();
  try {
    await h.ready();
    await h.cmd({ relay: 5, state: true, id: 'dup-1' });
    await h.waitState((x) => x.relays[4].state === true);
    await h.cmd({ relay: 5, state: false, id: 'dup-1' });   // tekrar: yok sayilmali
    await sleep(250);
    assert.equal(h.sim.qaState().relays[4].state, true);
    assert.ok(h.log().some((e) => e.type === 'cmd_ignored' && e.reason === 'duplicate_id' && e.id === 'dup-1'));
    assert.equal(h.lastState().last_id, 'dup-1');

    // 8 farkli id sonra dup-1 unutulur (pencere 8)
    for (let i = 0; i < 8; i++) await h.cmd({ relay: 6, cmd: 'toggle', id: `u-${i}` });
    await waitFor(() => h.sim.qaState().recent_ids.length === 8 && !h.sim.qaState().recent_ids.includes('dup-1'), { timeoutMs: 4000, label: 'id penceresi' });
    await h.cmd({ relay: 5, state: false, id: 'dup-1' });
    await h.waitState((x) => x.relays[4].state === false);
    // idsiz komutlar her zaman uygulanir
    await h.cmd({ relay: 5, cmd: 'toggle' });
    await h.cmd({ relay: 5, cmd: 'toggle' });
    await sleep(250);
    assert.equal(h.sim.qaState().relays[4].state, false);
  } finally {
    await h.close();
  }
});

test('sys konusu: yalniz set_local_key (alan "local_key" veya "key"); anahtar HTTP kimligini degistirir ve loglanmaz', async () => {
  const h = await setup();
  try {
    await h.ready();
    const call = (key) => h.http('GET', '/api/auth/check').then(() => fetch(`http://127.0.0.1:${h.sim.httpPort}/api/auth/check`, { headers: { 'X-Device-Key': key } })).then((r) => r.status);
    assert.equal(await call(KEY), 200);

    const sys = (obj) => publish(h.backend, `ev/${h.T}/sys`, obj);
    await sys({ cmd: 'reboot' });
    await sys({ cmd: 'set_local_key', local_key: 'kisa' });
    await sys({ cmd: 'set_local_key', local_key: 'yeni-anahtar-99', extra: 1 });
    await sys('{bozuk');
    await sys({ cmd: 'set_local_key' });
    await sys({ cmd: 'set_local_key', local_key: 'a', key: 'b' });
    await waitFor(() => h.log().filter((e) => e.type === 'sys_rejected').length === 6, { timeoutMs: 3000, label: 'sys redleri' });
    assert.equal(await call(KEY), 200, 'reddedilen sys komutlari anahtari degistirmedi');

    await sys({ cmd: 'set_local_key', local_key: 'yeni-anahtar-99', id: 'k1' });
    await waitFor(() => h.log().some((e) => e.type === 'sys_applied'), { timeoutMs: 3000 });
    assert.equal(await call(KEY), 401, 'eski anahtar gecersiz');
    assert.equal(await call('yeni-anahtar-99'), 200);
    await sys({ cmd: 'set_local_key', key: 'alias-anahtar-77' });
    await waitFor(() => h.log().filter((e) => e.type === 'sys_applied').length === 2, { timeoutMs: 3000 });
    assert.equal(await call('alias-anahtar-77'), 200, '"key" alani takma ad olarak kabul edilir');
    assert.equal(JSON.stringify(h.log()).includes('anahtar-99'), false, 'anahtar loglanmaz');
    assert.equal(JSON.stringify(h.log()).includes('alias-anahtar'), false);
    assert.equal(h.sim.qaState().relays.every((r) => !r.state), true, 'sys, rolelere dokunmaz');
  } finally {
    await h.close();
  }
});

// pano-5 (sozlesme 1): provizyonlu panonun state'inde lk_fp; sys set_local_key uygulaninca yeni izli state kalp atisini (30 sn) beklemeden
// yayinlanir (sunucu anahtar takasini state'te yeni izi gorunce kesinlestirir). Anahtarin kendisi hicbir yayinda yok.
test('sys set_local_key: uygulaninca yeni lk_fp li state gecikmeden yayinlanir; anahtar degeri yayinlarda yok (pano-5)', async () => {
  const h = await setup();
  try {
    await h.ready();
    const s0 = await h.waitState((x) => x.seq >= 1, 'ilk state');
    assert.equal(s0.lk_fp, lkFp(KEY, UID));
    const n = h.states().length;
    const t0 = performance.now();
    await publish(h.backend, `ev/${h.T}/sys`, { cmd: 'set_local_key', local_key: 'yeni-anahtar-42' });
    await h.waitState((x) => x.lk_fp === lkFp('yeni-anahtar-42', UID), 'yeni lk_fp');
    assert.ok(performance.now() - t0 < 2500, 'yeni iz gecikmeden yayinlandi');
    assert.ok(h.states().length > n);
    assert.equal(h.msgs.some((m) => String(m.payload).includes('yeni-anahtar-42')), false, 'anahtar hicbir yayinda yok');
  } finally {
    await h.close();
  }
});

// pano-7: provizyonsuz panoya buluttan anahtar yazilmaz (AP parolasiz yarim provizyon kalirdi): pano provizyonsuz kalir, state'te lk_fp yok,
// ilk anahtar yine factory/init ile yazilabilir.
test('sys set_local_key provizyonsuz panoda yok sayilir: pano provizyonsuz kalir, factory/init calisir (pano-7)', async () => {
  const h = await setup({ simOpts: { localKey: '' } });
  try {
    await h.ready();
    const s0 = await h.waitState((x) => x.seq >= 1, 'ilk state');
    assert.equal('lk_fp' in s0, false, 'provizyonsuz: lk_fp yok');
    await publish(h.backend, `ev/${h.T}/sys`, { cmd: 'set_local_key', local_key: 'buluttan-anahtar-1' });
    await waitFor(() => h.log().some((e) => e.type === 'sys_rejected' && e.reason === 'unprovisioned'), { timeoutMs: 3000, label: 'red olayi' });
    assert.equal(h.sim.isProvisioned(), false);
    const st = await fetch(`http://127.0.0.1:${h.sim.httpPort}/api/status`).then((r) => r.json());
    assert.equal(st.provisioned, false);
    const init = await fetch(`http://127.0.0.1:${h.sim.httpPort}/api/factory/init`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ local_key: 'fabrika-anahtar-1', ap_pass: 'ap-pass-1234' }),
    });
    assert.equal(init.status, 200, 'ilk anahtar factory/init ile yazilir');
    assert.equal(h.sim.isProvisioned(), true);
  } finally {
    await h.close();
  }
});

test('offline/online: soket anormal kesilir -> LWT offline (retained, QoS1); online ile geri gelir', async () => {
  const h = await setup();
  const late = [];
  try {
    await h.ready();
    await waitFor(() => h.statuses().some((m) => statusOf(m) === 'online'), { timeoutMs: 3000 });
    h.sim.forceOffline();
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'offline', { timeoutMs: 4000, label: 'LWT offline gelmedi' });
    assert.equal(h.sim.qaState().mqtt.connected, false);

    const a = await connect({ port: h.ctx.port, username: `a_${h.T}_x`, password: 'app-pw' });
    late.push(a);
    const got = collect(a);
    await subscribe(a, `ev/${h.T}/status`);
    await waitFor(() => got.length >= 1, { timeoutMs: 3000 });
    assert.deepEqual(JSON.parse(got[0].payload), { status: 'offline', uid: UID }, 'LWT JSON + uid (guvenlik-6)');
    assert.equal(got[0].retain, true, 'LWT retained');

    await sleep(500);
    assert.equal(h.sim.qaState().mqtt.connected, false, 'forceOffline sirasinda yeniden baglanma YOK');
    h.sim.forceOnline();
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'online', { timeoutMs: 4000, label: 'online gelmedi' });
    await h.ready();
  } finally {
    await endClients(late);
    await h.close();
  }
});

test('crash: temiz kopma, LWT YOK ve offline yayinlanmaz -> retained online BAYAT kalir (120 sn supurucu senaryosu)', async () => {
  const h = await setup();
  const late = [];
  try {
    await h.ready();
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'online', { timeoutMs: 3000 });
    const before = h.statuses().length;
    h.sim.crash();
    await waitFor(() => h.sim.qaState().mqtt.state === 'disconnected', { timeoutMs: 3000 });
    await sleep(700);
    assert.equal(h.statuses().length, before, 'hicbir offline/status mesaji yok');

    const a = await connect({ port: h.ctx.port, username: `a_${h.T}_x`, password: 'app-pw' });
    late.push(a);
    const got = collect(a);
    await subscribe(a, `ev/${h.T}/status`);
    await waitFor(() => got.length >= 1, { timeoutMs: 3000 });
    assert.equal(statusOf(got[0]), 'online', 'bayat retained online');
    assert.equal(h.sim.qaState().mqtt.forced_offline, true);

    h.sim.forceOnline();
    await h.ready();
  } finally {
    await endClients(late);
    await h.close();
  }
});

test('Wi-Fi kaybi (ev agi kapandi): LWT offline; ag gelince STA yeniden baglanir, MQTT geri gelir', async () => {
  const h = await setup();
  try {
    await h.ready();
    h.sim.setWifiWorld({ up: false });
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'offline', { timeoutMs: 5000, label: 'LWT (Wi-Fi kaybi)' });
    assert.equal(h.sim.qaState().wifi.connected, false);
    assert.equal(h.sim.qaState().wifi.last_reason, 200, 'beacon timeout');
    assert.equal(h.sim.qaState().mqtt.connected, false);
    // yerel HTTP hala yanit verir (AP penceresi 3 dk sonra; STA kaybinda cihaz canli)
    assert.equal((await h.http('GET', '/api/auth/check')).status, 200);
    h.sim.setWifiWorld({ up: true });
    await waitFor(() => h.sim.qaState().wifi.connected, { timeoutMs: 20000, label: 'STA geri baglanmadi' });
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'online', { timeoutMs: 10000, label: 'MQTT geri gelmedi' });
  } finally {
    await h.close();
  }
});

test('power-cycle: LWT offline, roleler OFF, seq/uptime sifirlanir, yeniden baglanir; konum NVS\'e yazildigi kadar korunur', async () => {
  const h = await setup();
  try {
    await h.ready();
    await h.cmd({ relay: 5, state: true });
    await h.waitState((x) => x.relays[4].state === true);
    const seqBefore = h.lastState().seq;
    assert.ok(seqBefore >= 2);

    h.sim.powerCycle();
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'offline', { timeoutMs: 4000, label: 'LWT offline gelmedi' });
    await waitFor(() => h.sim.booting === false && h.sim.qaState().relays, { timeoutMs: 4000, label: 'acilis' });
    assert.equal(h.sim.qaState().relays.every((r) => !r.state), true, 'guc kesintisinde roleler OFF');
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'online', { timeoutMs: 10000, label: 'yeniden baglanmadi' });
    const s = await h.waitState((x) => x.seq === 1, 'seq sifirlandi');
    assert.equal(s.relays[4].state, false);
    assert.ok(s.uptime <= 6);
    assert.equal(h.sim.qaState().mqtt.in_startup_window === true || h.sim.qaState().mqtt.in_startup_window === false, true);
    assert.equal(h.sim.qaState().violation_count, 0);
  } finally {
    await h.close();
  }
});

test('planli yeniden baslatma (HTTP reboot): once status "offline" yayinlanir (LWT degil), baglanti temiz kapanir; sonra yeniden online', async () => {
  const h = await setup();
  try {
    await h.ready();
    const before = h.statuses().length;
    assert.equal((await h.http('POST', '/api/system/reboot')).status, 200);
    await waitFor(() => h.statuses().length > before && statusOf(h.statuses().at(-1)) === 'offline', { timeoutMs: 4000, label: 'offline yayini' });
    const off = h.statuses().at(-1);
    assert.deepEqual(JSON.parse(off.payload), { status: 'offline', uid: UID }, 'planli offline da JSON + uid (guvenlik-6)');
    assert.equal(off.qos, 0, 'planli offline: PubSubClient QoS 0 (LWT QoS 1 olurdu)');
    assert.ok(h.ctx.log.lines.some((l) => l.includes('disconnect') || l.includes('client_close') || l.includes('close')), 'broker kapanisi kaydetti');
    await waitFor(() => statusOf(h.statuses().at(-1)) === 'online', { timeoutMs: 12000, label: 'yeniden online' });
    assert.ok(h.sim.events.some((e) => e.type === 'booted' && e.kind === 'soft'));
  } finally {
    await h.close();
  }
});

test('slow: komut gecikmesi enjekte edilir; drop komutu hic uygulamaz', async () => {
  const h = await setup();
  try {
    await h.ready();
    h.sim.setSlow({ delay_ms: 500 });
    const t0 = Date.now();
    await h.cmd({ relay: 5, state: true });
    await sleep(200);
    assert.equal(h.sim.qaState().relays[4].state, false, 'gecikme suresince uygulanmaz');
    await h.waitState((x) => x.relays[4].state === true);
    assert.ok(Date.now() - t0 >= 450, 'gecikme uygulandi');

    h.sim.setSlow({ drop: true });
    await h.cmd({ relay: 6, state: true });
    await sleep(500);
    assert.equal(h.sim.qaState().relays[5].state, false, 'drop: uygulanmaz');
    h.sim.setSlow({});
    await h.cmd({ relay: 6, state: true });
    await h.waitState((x) => x.relays[5].state === true);
  } finally {
    await h.close();
  }
});

test('duvar butonu (DI): state.dis (suzgeclenmis) guncellenir; DI ile degisen durum MQTT disindan da yayinlanir; cocuk kilidi basmayi engeller', async () => {
  const h = await setup();
  try {
    await h.ready();
    h.sim.pressDi(5, 700);                          // durum yayini ~250 ms birlestirir: kisa dokunus state.dis'te gorunmeyebilir
    await h.waitState((x) => x.dis[4].state === true && x.relays[4].state === true, 'DI basildi');
    await h.waitState((x) => x.dis[4].state === false, 'DI birakildi');
    assert.equal(h.lastState().relays[4].state, true, 'toggle: birakma roleyi kapatmaz');

    await h.cmd({ cmd: 'set_child_lock', enabled: true });
    await h.waitState((x) => x.child_lock === true);
    h.sim.pressDi(6, 700);
    await h.waitState((x) => x.dis[5].state === true, 'DI kenari state\'te gorunur (kilitliyken de)');
    await h.waitState((x) => x.dis[5].state === false);
    assert.equal(h.lastState().relays[5].state, false, 'kilitliyken role tetiklenmedi');
    assert.ok(h.log().some((e) => e.type === 'di_blocked_child_lock'));
  } finally {
    await h.close();
  }
});

test('MQTT kimlik hatasi: CONNACK 4 -> uzun bekleme ve tekrar; dogru kimlikle /api/mqtt/config sonrasi baglanir (reconfigure bekleme sifirlar)', async () => {
  const h = await setup({ startSim: false });
  try {
    const wrong = { host: '127.0.0.1', port: h.ctx.port, user: `d_${h.T}`, pass: 'yanlis-parola' };
    h.sim.opts.mqtt = wrong;
    await h.sim.start();
    await waitFor(() => /code 4/.test(h.sim.qaState().mqtt.last_error || ''), { timeoutMs: 8000, label: 'CONNACK 4 gorulmedi' });
    assert.equal(h.sim.qaState().mqtt.connected, false);
    assert.ok(h.ctx.log.lines.some((l) => l.includes('connect_denied') && l.includes('reason=bad_password')));

    const r = await h.http('POST', '/api/mqtt/config', { server: '127.0.0.1', port: h.ctx.port, user: `d_${h.T}`, pass: h.devPass });
    assert.equal(r.status, 200);
    await h.ready();
    await h.waitState((x) => x.seq >= 1);
  } finally {
    await h.close();
  }
});

test('emulator adresi: 10.0.2.2 yapilandirmasi simulator icinde 127.0.0.1\'e eslenir', async () => {
  const h = await setup({ startSim: false });
  try {
    h.sim.opts.mqtt = { host: '10.0.2.2', port: h.ctx.port, user: `d_${h.T}`, pass: h.devPass };
    await h.sim.start();
    await h.ready();
    assert.equal(h.sim.qaState().mqtt.server, '10.0.2.2');
    await h.waitState((x) => x.seq >= 1);
  } finally {
    await h.close();
  }
});

test('provizyonsuz cihaz da MQTT yolunu kullanir (kimlik yerel HTTP erisimini etkiler, MQTT\'yi etkilemez)', async () => {
  const h = await setup({ simOpts: { localKey: '' } });
  try {
    await h.ready();
    assert.equal(h.sim.isProvisioned(), false);
    await h.cmd({ relay: 5, state: true });
    await h.waitState((x) => x.relays[4].state === true);
  } finally {
    await h.close();
  }
});

test('Wi-Fi baglanmadan MQTT baslamaz; HTTP ile baglaninca (dogrulanir, NVS) baslar', async () => {
  const h = await setup({ startSim: false, simOpts: { wifiConnected: false } });
  try {
    await h.sim.start();
    await sleep(600);
    assert.equal(h.sim.qaState().mqtt.state, 'disconnected', 'Wi-Fi yokken MQTT denenmez');
    assert.equal(h.statuses().length, 0);
    assert.equal((await h.http('POST', '/api/wifi/connect', { ssid: 'TestHome', pass: 'home-pass-123' })).status, 200);
    await h.ready();
    assert.equal(statusOf(h.statuses()[0]), 'online');
  } finally {
    await h.close();
  }
});

test('ACL: abone izni olmayan cihaz komut alamaz AMA bagli sanir ve state yayinlamaya devam eder (firmware SUBACK\'e bakmaz)', async () => {
  const h = await setup({ startSim: false });
  try {
    h.ctx.store.clearAcl(`d_${h.T}`);
    h.ctx.store.addAcl({ username: `d_${h.T}`, permission: 'allow', action: 'publish', topic: `ev/${h.T}/state` });
    h.ctx.store.addAcl({ username: `d_${h.T}`, permission: 'allow', action: 'publish', topic: `ev/${h.T}/status` });
    await h.sim.start();
    await waitFor(() => h.log().some((e) => e.type === 'mqtt_subscribe_denied'), { timeoutMs: 6000, label: 'abonelik reddi gorulmedi' });
    await h.waitState((x) => x.seq >= 1);
    assert.equal(h.sim.qaState().mqtt.cmd_subscribed, false);
    assert.equal(h.sim.qaState().mqtt.connected, true, 'cihaz kendini bagli sanir (sessiz ariza)');
    await h.cmd({ relay: 5, state: true });
    await sleep(400);
    assert.equal(h.sim.qaState().relays[4].state, false, 'komut ulasmaz');
  } finally {
    await h.close();
  }
});

test('16 role (ek modul): state 16 role / 16 DI icerir; ek modul panjur cifti yapilandirilinca raporlanir ve komutla hareket eder', async () => {
  const h = await setup({ simOpts: { relays: 16 } });
  try {
    await h.ready();
    const s = await h.waitState((x) => x.relays.length === 16);
    assert.equal(s.shutters.length, 2, 'varsayilan: ek moduldeki roleler lamba');
    assert.equal(s.dis.length, 16);
    assert.deepEqual(s.relays[8], { id: 9, name: 'Ek Modül Röle 1', type: 'light', state: false });
    assert.ok(h.states().at(-1).payload.length < 4096, `state boyutu: ${h.states().at(-1).payload.length}`);
    const cfg = await h.http('POST', '/api/config', { relays: [...Array(8).fill({}), { type: 1, runtime_sec: 20 }, { type: 2, runtime_sec: 20 }] });
    assert.equal(cfg.status, 200);
    await h.waitState((x) => x.shutters.length === 3);
    await h.cmd({ shutter: 5, cmd: 'up' });
    await h.waitState((x) => x.shutters[2].dir === 1 && x.relays[8].state === true);
    assert.equal(h.sim.ext.coils[0], true, 'ek modul coil\'i acildi');
    await h.cmd({ relay: 12, cmd: 'toggle' });
    await h.waitState((x) => x.relays[11].state === true);
    assert.equal(h.sim.qaState().violation_count, 0);
  } finally {
    await h.close();
  }
});

test('kalp atisi: 30 sn icinde bir tam durum (cihaz saati ilerletilerek); durum degismese de yayin gelir', async () => {
  const off = { v: 0 };
  const clock = { now: () => performance.now() + off.v };
  const h = await setup({ simOpts: { clock } });
  try {
    await h.ready();
    await sleep(500);
    const n = h.states().length;
    // 30 sn kalp atisi zamanlayicisi (NetUtil::PublishPacer.heartbeat: son BASARILI yayindan beri gecen sure; N6 "son olay + bekleme" cifti)
    const hb = h.sim.fw.mqtt.pace.heartbeat;
    assert.equal(hb.isArmed(), true, 'ilk tam durum yayinlandi: kalp atisi zamanlayicisi kurulu');
    const sinceLast = hb.passed(h.sim.millis());
    off.v += 29000 - sinceLast;                     // son yayindan 29 sn sonrasi
    await sleep(400);
    assert.equal(h.states().length, n, '30 sn dolmadan yayin yok');
    off.v += 2000;
    await waitFor(() => h.states().length > n, { timeoutMs: 3000, label: 'kalp atisi' });
    const last = h.states().at(-1).json;
    assert.equal(last.seq, h.states().at(-2).json.seq + 1);
    assert.ok(last.uptime >= 31, `uptime cihaz saatini izler: ${last.uptime}`);
  } finally {
    await h.close();
  }
});
