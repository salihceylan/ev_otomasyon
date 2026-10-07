// EMQX taklidi broker: kimlik dogrulama, ACL, retained, LWT, kick, kontrol ucu, depo kullanilamazligi.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { MemoryCredentialStore } from '../lib/credstore.js';
import {
  startTestBroker, connect, subscribe, collect, publish, endClients, hashPw, waitFor, sleep, tmpDir,
} from './_helpers.js';

const T = 'h_0123456789abcdef'; // ornek ev konu kimligi
const DEV_USER = `d_${T}`;
const APP_USER = `a_${T}_xyz`;

function seedIdentities(store, { devPass = 'dev-pass-1', appPass = 'app-pass-1', appExpires = null } = {}) {
  store.addCredential({ username: DEV_USER, password_hash: hashPw(devPass), kind: 'device' });
  store.addAcl({ username: DEV_USER, permission: 'allow', action: 'publish', topic: `ev/${T}/state` });
  store.addAcl({ username: DEV_USER, permission: 'allow', action: 'publish', topic: `ev/${T}/status` });
  store.addAcl({ username: DEV_USER, permission: 'allow', action: 'subscribe', topic: `ev/${T}/cmd` });
  store.addAcl({ username: DEV_USER, permission: 'allow', action: 'subscribe', topic: `ev/${T}/sys` });

  store.addCredential({ username: APP_USER, password_hash: hashPw(appPass), kind: 'app', expires_at: appExpires });
  store.addAcl({ username: APP_USER, permission: 'allow', action: 'subscribe', topic: `ev/${T}/state` });
  store.addAcl({ username: APP_USER, permission: 'allow', action: 'subscribe', topic: `ev/${T}/status` });
  return { devPass, appPass };
}

test('kimlik dogrulama: backend superuser, cihaz, yanlis parola, bilinmeyen kullanici, suresi dolmus kimlik', async () => {
  const ctx = await startTestBroker();
  try {
    const { devPass, appPass } = seedIdentities(ctx.store, { appExpires: new Date(Date.now() - 1000) });

    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    await endClients(backend);

    await assert.rejects(connect({ port: ctx.port, username: ctx.backend.username, password: 'yanlis' }), (e) => e.code === 4);
    await assert.rejects(connect({ port: ctx.port, username: ctx.backend.username }), (e) => e.code === 4, 'parolasiz');

    const dev = await connect({ port: ctx.port, username: DEV_USER, password: devPass, clientId: 'dev-1' });
    await endClients(dev);
    await assert.rejects(connect({ port: ctx.port, username: DEV_USER, password: 'yanlis' }), (e) => e.code === 4);
    await assert.rejects(connect({ port: ctx.port, username: 'yok_boyle_biri', password: 'x' }), (e) => e.code === 4);

    // suresi dolmus uygulama kimligi: parola dogru olsa da reddedilir
    await assert.rejects(connect({ port: ctx.port, username: APP_USER, password: appPass }), (e) => e.code === 4);

    // suresi gelecekte olan / sinirsiz kimlik kabul edilir
    ctx.store.addCredential({ username: 'a_future', password_hash: hashPw('p'), kind: 'app', expires_at: new Date(Date.now() + 60000) });
    ctx.store.addCredential({ username: 'a_nolimit', password_hash: hashPw('p'), kind: 'app', expires_at: null });
    await endClients(await connect({ port: ctx.port, username: 'a_future', password: 'p' }));
    await endClients(await connect({ port: ctx.port, username: 'a_nolimit', password: 'p' }));

    const lines = ctx.log.lines.join('\n');
    assert.match(lines, /connect_denied .*reason=bad_password/);
    assert.match(lines, /connect_denied .*reason=unknown_user/);
    assert.match(lines, /connect_denied .*reason=expired/);
  } finally {
    await ctx.broker.close();
  }
});

test('ACL: cihaz yalniz kendi konularina yayin yapar; yetkisiz yayin dusurulur, baglanti acik kalir', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    const { devPass } = seedIdentities(ctx.store);
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    const seen = collect(backend);
    await subscribe(backend, 'ev/#');

    const dev = await connect({ port: ctx.port, username: DEV_USER, password: devPass });
    open.push(dev);
    await publish(dev, `ev/${T}/state`, '{"v":2}');
    await publish(dev, `ev/${T}/cmd`, '{"cmd":"all_lights_off"}');            // yetkisiz: dusurulmeli
    await publish(dev, `ev/baska_ev/state`, '{"v":2}');                       // baska eve: dusurulmeli
    await publish(dev, `ev/${T}/status`, 'online', { retain: true });         // yetkili
    await sleep(300);

    const topics = seen.map((m) => m.topic);
    assert.deepEqual(topics.sort(), [`ev/${T}/state`, `ev/${T}/status`].sort(), 'yalniz yetkili yayinlar ulasir');
    assert.ok(dev.connected, 'yetkisiz yayin baglantiyi kapatmaz');

    const lines = ctx.log.lines.filter((l) => l.includes(' pub_denied '));
    assert.equal(lines.length, 2);
    assert.ok(lines.some((l) => l.includes(`topic=ev/${T}/cmd`)));
    assert.ok(lines.some((l) => l.includes('topic=ev/baska_ev/state')));
    assert.equal(ctx.broker.stats().pubDenied, 2);
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('ACL: cihaz cmd/sys konularina abone olur, baska evinkine olamaz', async () => {
  const ctx = await startTestBroker();
  try {
    const { devPass } = seedIdentities(ctx.store);
    const dev = await connect({ port: ctx.port, username: DEV_USER, password: devPass });
    assert.equal((await subscribe(dev, `ev/${T}/cmd`)).granted, true);
    assert.equal((await subscribe(dev, `ev/${T}/sys`)).granted, true);
    assert.equal((await subscribe(dev, `ev/${T}/state`)).granted, false, 'state icin abone izni yok');
    assert.equal((await subscribe(dev, 'ev/baska/cmd')).granted, false);
    await endClients(dev);
  } finally {
    await ctx.broker.close();
  }
});

test('ACL: uygulama kimligi YALNIZ state/status abonesidir; cmd abonelik/yayini ve joker abonelik reddedilir', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    const { devPass, appPass } = seedIdentities(ctx.store);
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    const dev = await connect({ port: ctx.port, username: DEV_USER, password: devPass });
    open.push(dev);
    assert.equal((await subscribe(dev, `ev/${T}/cmd`)).granted, true);
    const devSeen = collect(dev);

    const app = await connect({ port: ctx.port, username: APP_USER, password: appPass });
    open.push(app);
    assert.equal((await subscribe(app, `ev/${T}/state`)).granted, true);
    assert.equal((await subscribe(app, `ev/${T}/status`)).granted, true);
    assert.equal((await subscribe(app, `ev/${T}/cmd`)).granted, false);
    assert.equal((await subscribe(app, `ev/${T}/sys`)).granted, false);
    assert.equal((await subscribe(app, 'ev/+/state')).granted, false, 'joker abonelik tekil kuraldan genis');
    assert.equal((await subscribe(app, 'ev/#')).granted, false);
    assert.equal((await subscribe(app, '#')).granted, false);
    assert.equal((await subscribe(app, '$SYS/#')).granted, false);

    // uygulama cmd'ye yayin yaparsa cihaz ALMAZ (uygulamalar MQTT'ye yayin yapamaz)
    await publish(app, `ev/${T}/cmd`, '{"relay":1,"state":true}');
    // backend (superuser) yayin yapabilir
    await publish(backend, `ev/${T}/cmd`, '{"relay":2,"state":true}');
    await waitFor(() => devSeen.length >= 1, { timeoutMs: 3000, label: 'backend komutu cihaza ulasmadi' });
    await sleep(200);
    assert.deepEqual(devSeen.map((m) => JSON.parse(m.payload)), [{ relay: 2, state: true }]);
    assert.ok(ctx.log.lines.some((l) => l.includes(' pub_denied ') && l.includes(`user=${APP_USER}`)));
    assert.ok(ctx.log.lines.some((l) => l.includes(' sub_denied ') && l.includes(`topic=ev/${T}/cmd`)));
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('ACL: kural olmayan kimlik baglanabilir ama hicbir seye abone/yayin yapamaz (zero trust)', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    ctx.store.addCredential({ username: 'a_norules', password_hash: hashPw('pw'), kind: 'app' });
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    const seen = collect(backend);
    await subscribe(backend, '#');
    const c = await connect({ port: ctx.port, username: 'a_norules', password: 'pw' });
    open.push(c);
    assert.equal((await subscribe(c, `ev/${T}/state`)).granted, false);
    await publish(c, `ev/${T}/state`, 'x');
    await sleep(250);
    assert.equal(seen.filter((m) => !m.topic.startsWith('$SYS')).length, 0);
    assert.match(ctx.log.lines.join('\n'), /sub_denied .*reason=no_rules/);
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('ACL: deny onceliklidir', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    ctx.store.addCredential({ username: 'a_deny', password_hash: hashPw('pw'), kind: 'device' });
    ctx.store.addAcl({ username: 'a_deny', permission: 'allow', action: 'all', topic: `ev/${T}/#` });
    ctx.store.addAcl({ username: 'a_deny', permission: 'deny', action: 'publish', topic: `ev/${T}/cmd` });
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    const seen = collect(backend);
    await subscribe(backend, `ev/${T}/#`);
    const c = await connect({ port: ctx.port, username: 'a_deny', password: 'pw' });
    open.push(c);
    assert.equal((await subscribe(c, `ev/${T}/cmd`)).granted, true, 'deny yalniz publish icin');
    await publish(c, `ev/${T}/cmd`, 'x');
    await publish(c, `ev/${T}/state`, 'y');
    await waitFor(() => seen.length >= 1, { timeoutMs: 3000 });
    await sleep(200);
    assert.deepEqual(seen.map((m) => m.topic), [`ev/${T}/state`]);
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('retained: gec abone retained state/status alir; bos retained yayin temizler', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    const { devPass, appPass } = seedIdentities(ctx.store);
    const dev = await connect({ port: ctx.port, username: DEV_USER, password: devPass });
    open.push(dev);
    await publish(dev, `ev/${T}/state`, '{"v":2,"seq":1}', { retain: true });
    await publish(dev, `ev/${T}/status`, 'online', { retain: true });

    const app = await connect({ port: ctx.port, username: APP_USER, password: appPass });
    open.push(app);
    const seen = collect(app);
    await subscribe(app, `ev/${T}/state`);
    await subscribe(app, `ev/${T}/status`);
    await waitFor(() => seen.length >= 2, { timeoutMs: 3000, label: 'retained mesajlar gelmedi' });
    assert.ok(seen.every((m) => m.retain), 'retained bayragi korunur');
    assert.deepEqual(seen.map((m) => m.topic).sort(), [`ev/${T}/state`, `ev/${T}/status`].sort());

    // backend retained'i bos yayinla temizler (clearRetained)
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    await publish(backend, `ev/${T}/state`, '', { retain: true });
    const app2 = await connect({ port: ctx.port, username: APP_USER, password: appPass, clientId: 'app-2' });
    open.push(app2);
    const seen2 = collect(app2);
    await subscribe(app2, `ev/${T}/state`);
    await sleep(300);
    assert.equal(seen2.length, 0, 'temizlenen retained gelmez');
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('LWT: anormal kopmada offline yayinlanir; temiz DISCONNECT will yayinlamaz', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    const { devPass } = seedIdentities(ctx.store);
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    const seen = collect(backend);
    await subscribe(backend, `ev/${T}/status`);

    const will = { topic: `ev/${T}/status`, payload: 'offline', qos: 1, retain: true };
    const d1 = await connect({ port: ctx.port, username: DEV_USER, password: devPass, clientId: 'dev-lwt-1', will });
    d1.stream.destroy(); // anormal kopma
    await waitFor(() => seen.some((m) => m.payload === 'offline'), { timeoutMs: 4000, label: 'LWT yayinlanmadi' });

    const before = seen.length;
    const d2 = await connect({ port: ctx.port, username: DEV_USER, password: devPass, clientId: 'dev-lwt-2', will });
    await new Promise((r) => d2.end(false, {}, r)); // temiz DISCONNECT
    await sleep(300);
    assert.equal(seen.length, before, 'temiz kapanista will yayinlanmaz');
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('kick: kullanici adi ve clientId ile atma, kontrol ucu (POST /kick, EMQX v5 DELETE /clients/:id)', async () => {
  const key = 'k_test_api_key';
  const secret = 's_test_api_secret';
  const ctx = await startTestBroker({ emqxApiKey: key, emqxApiSecret: secret });
  const open = [];
  try {
    const { devPass, appPass } = seedIdentities(ctx.store);
    const base = `http://127.0.0.1:${ctx.controlPort}`;

    // 1) kullanici adina gore
    const app1 = await connect({ port: ctx.port, username: APP_USER, password: appPass, clientId: 'app-a' });
    let closed1 = false;
    app1.on('close', () => { closed1 = true; });
    const r1 = await fetch(`${base}/kick`, { method: 'POST', body: JSON.stringify({ username: APP_USER }), headers: { 'content-type': 'application/json' } });
    assert.equal(r1.status, 200);
    assert.deepEqual(await r1.json(), { kicked: 1, clients: ['app-a'] });
    await waitFor(() => closed1, { timeoutMs: 3000, label: 'kick sonrasi baglanti kapanmadi' });
    await endClients(app1);

    // 2) EMQX v5: Basic auth gerekli
    const app2 = await connect({ port: ctx.port, username: APP_USER, password: appPass, clientId: 'app-b' });
    let closed2 = false;
    app2.on('close', () => { closed2 = true; });
    const noAuth = await fetch(`${base}/api/v5/clients/app-b`, { method: 'DELETE' });
    assert.equal(noAuth.status, 401);
    assert.equal(closed2, false);
    const basic = `Basic ${Buffer.from(`${key}:${secret}`).toString('base64')}`;
    const list = await fetch(`${base}/api/v5/clients?username=${encodeURIComponent(APP_USER)}`, { headers: { authorization: basic } });
    const listBody = await list.json();
    assert.equal(listBody.meta.count, 1);
    assert.equal(listBody.data[0].clientid, 'app-b');
    const del = await fetch(`${base}/api/v5/clients/app-b`, { method: 'DELETE', headers: { authorization: basic } });
    assert.equal(del.status, 204);
    await waitFor(() => closed2, { timeoutMs: 3000, label: 'EMQX DELETE sonrasi baglanti kapanmadi' });
    await endClients(app2);

    // 3) olmayan istemci -> 404
    const missing = await fetch(`${base}/api/v5/clients/yok`, { method: 'DELETE', headers: { authorization: basic } });
    assert.equal(missing.status, 404);
    const bad = await fetch(`${base}/kick`, { method: 'POST', body: '{}', headers: { 'content-type': 'application/json' } });
    assert.equal(bad.status, 400);

    // 4) kick, will'i yayinlar (anormal sonlanma): cihaz atilinca status=offline
    const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password });
    open.push(backend);
    const seen = collect(backend);
    await subscribe(backend, `ev/${T}/status`);
    const dev = await connect({
      port: ctx.port, username: DEV_USER, password: devPass, clientId: 'dev-kick',
      will: { topic: `ev/${T}/status`, payload: 'offline', qos: 1, retain: true },
    });
    open.push(dev);
    assert.deepEqual(ctx.broker.kick({ clientId: 'dev-kick' }), ['dev-kick']);
    await waitFor(() => seen.some((m) => m.payload === 'offline'), { timeoutMs: 3000, label: 'kick sonrasi LWT yok' });
    assert.equal(ctx.broker.stats().kicks >= 3, true);
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('iptal: depodan silinen kimlik yeni baglantida reddedilir (acik baglanti kick ile dusurulur)', async () => {
  const ctx = await startTestBroker();
  try {
    const { appPass } = seedIdentities(ctx.store);
    const app = await connect({ port: ctx.port, username: APP_USER, password: appPass, clientId: 'app-rev' });
    ctx.store.removeCredential(APP_USER);
    ctx.store.clearAcl(APP_USER);
    // EMQX gibi: acik baglanti kendiliginden dusmez; sunucu kick cagirir
    assert.ok(app.connected);
    ctx.broker.kick({ username: APP_USER });
    await waitFor(() => !app.connected, { timeoutMs: 3000 });
    await assert.rejects(connect({ port: ctx.port, username: APP_USER, password: appPass }), (e) => e.code === 4);
    await endClients(app);
  } finally {
    await ctx.broker.close();
  }
});

test('depo kullanilamiyor (tablolar henuz yok): backend baglanir, digerleri CONNACK 3; hazir olunca calisir, cokme yok', async () => {
  const store = new MemoryCredentialStore();
  store.setAvailable(false, 'tables_missing');
  const ctx = await startTestBroker({ store });
  try {
    seedIdentities(store);
    assert.equal(ctx.broker.isStoreReady(), false);
    // backend ortamdan: veritabani gerektirmez
    await endClients(await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password }));
    await assert.rejects(connect({ port: ctx.port, username: DEV_USER, password: 'dev-pass-1' }), (e) => e.code === 3);
    assert.match(ctx.log.lines.join('\n'), /store_wait/);
    assert.match(ctx.log.lines.join('\n'), /connect_denied .*reason=store_unavailable:tables_missing/);

    store.setAvailable(true);
    await waitFor(() => ctx.broker.isStoreReady(), { timeoutMs: 3000, label: 'depo hazir olarak algilanmadi' });
    const dev = await connect({ port: ctx.port, username: DEV_USER, password: 'dev-pass-1' });
    assert.ok(dev.connected);
    assert.match(ctx.log.lines.join('\n'), /store_ready/);

    // baglanti varken depo duserse yetki kontrolu deny (zero trust), baglanti kapanmaz, broker cokmez
    store.setAvailable(false, 'db_unreachable');
    assert.equal((await subscribe(dev, `ev/${T}/cmd`)).granted, false);
    assert.ok(dev.connected);
    await endClients(dev);
  } finally {
    await ctx.broker.close();
  }
});

test('log: parola yazilmaz; olaylar broker.log dosyasina eklenir', async () => {
  const dir = tmpDir();
  const logFile = path.join(dir, 'broker.log');
  const ctx = await startTestBroker({ logFile });
  try {
    const secretPass = 'cok-gizli-parola-XYZ-987';
    ctx.store.addCredential({ username: 'a_log', password_hash: hashPw(secretPass), kind: 'app' });
    await assert.rejects(connect({ port: ctx.port, username: 'a_log', password: 'yanlis-parola-ABC-123' }), (e) => e.code === 4);
    const ok = await connect({ port: ctx.port, username: 'a_log', password: secretPass });
    await subscribe(ok, 'ev/x/state');
    await endClients(ok);
    await sleep(100);
    const text = fs.readFileSync(logFile, 'utf8');
    assert.match(text, /broker_started/);
    assert.match(text, /connect_denied .*reason=bad_password/);
    assert.match(text, /connect_ok .*user=a_log/);
    assert.match(text, /sub_denied .*topic=ev\/x\/state/);
    assert.ok(!text.includes(secretPass), 'dogru parola loga yazilmamali');
    assert.ok(!text.includes('yanlis-parola-ABC-123'), 'denenen parola loga yazilmamali');
    assert.ok(!text.includes(ctx.backend.password), 'backend parolasi loga yazilmamali');
  } finally {
    await ctx.broker.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('DB\'de is_superuser=true kimlik ACL\'yi atlar (EMQX authn is_superuser)', async () => {
  const ctx = await startTestBroker();
  const open = [];
  try {
    ctx.store.addCredential({ username: 'su_db', password_hash: hashPw('pw'), kind: 'backend', is_superuser: true });
    const su = await connect({ port: ctx.port, username: 'su_db', password: 'pw' });
    open.push(su);
    assert.equal((await subscribe(su, 'ev/#')).granted, true);
    const seen = collect(su);
    await publish(su, `ev/${T}/cmd`, 'x');
    await waitFor(() => seen.length >= 1, { timeoutMs: 3000 });
    // superuser olmayan, kural satiri olmayan kimlik ayni islemi yapamaz
    ctx.store.addCredential({ username: 'plain_db', password_hash: hashPw('pw'), kind: 'backend', is_superuser: false });
    const plain = await connect({ port: ctx.port, username: 'plain_db', password: 'pw' });
    open.push(plain);
    assert.equal((await subscribe(plain, 'ev/#')).granted, false);
  } finally {
    await endClients(open);
    await ctx.broker.close();
  }
});

test('retained yayin ardindan ayni okuma parcasinda gelen retained-siz yayin, retained mesaji DUSURMEZ (cihaz state + event ayni anda)', async () => {
  // aedes 1.2.0: iki yayin es zamanli islenir; storeRetained'i bekleyen state, sonraki event'ten SONRA dagitilir ve abonenin kopya
  // denetimi (brokerCounter) onu "eski" sayardi. EMQX'te boyle bir kayip yok; QA brokeri esdeger davranmali.
  const ctx = await startTestBroker();
  const devPass = 'dev-pass-9';
  ctx.store.addCredential({ username: DEV_USER, password_hash: hashPw(devPass), kind: 'device' });
  ctx.store.addAcl({ username: DEV_USER, permission: 'allow', action: 'publish', topic: `ev/${T}/state` });
  ctx.store.addAcl({ username: DEV_USER, permission: 'allow', action: 'publish', topic: `ev/${T}/event` });
  const backend = await connect({ port: ctx.port, username: ctx.backend.username, password: ctx.backend.password, clientId: 'qa-backend-rt' });
  const dev = await connect({ port: ctx.port, username: DEV_USER, password: devPass, clientId: 'ESP32S3_0000000000AA' });
  try {
    const msgs = collect(backend);
    await subscribe(backend, `ev/${T}/state`);
    await subscribe(backend, `ev/${T}/event`);
    for (let k = 0; k < 20; k++) {
      dev.publish(`ev/${T}/state`, JSON.stringify({ k }), { qos: 0, retain: true });
      dev.publish(`ev/${T}/event`, JSON.stringify({ k }), { qos: 0, retain: false });
    }
    await waitFor(() => msgs.filter((m) => m.topic.endsWith('/event')).length === 20, { timeoutMs: 3000, label: 'olaylar' });
    await sleep(200);
    assert.deepEqual(msgs.filter((m) => m.topic.endsWith('/state')).map((m) => JSON.parse(m.payload).k), Array.from({ length: 20 }, (_, k) => k));
  } finally {
    await endClients(dev, backend);
    await ctx.broker.close();
  }
});
