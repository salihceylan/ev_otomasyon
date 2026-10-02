'use strict';

// S3 (plan §5d-5) - SUREC SAGLAMLIGI: unhandledRejection / uncaughtException gunlugu (sir sizdirmaz), uncaughtException'da
// zarif kapanis + cikis kodu 1, SIGTERM/SIGINT'te SIRALI kapanis (HTTP -> zamanlayici -> MQTT -> pg), toplam sinir.
//
// Gercek HTTP sunucusu (port 0) + sahte db/koprü/zamanlayici. `process.exit` ve sinyal/hata isleyicileri test icin
// sarilir; gercek bir sinyal/istisna URETILMEZ (test calistiricisinin kendi isleyicileri tetiklenmesin).

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const http = require('http');
const { once } = require('events');
const { setTestEnv, installFakeDb, installModule } = require('./_helpers');

setTestEnv({ LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex'), PORT: '0', BIND_HOST: '127.0.0.1' });

const events = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const fakeDb = installFakeDb();
let queryDelayMs = 0;
fakeDb.query = async () => {
  if (queryDelayMs > 0) await sleep(queryDelayMs);
  return { rows: [{ ok: 1 }], rowCount: 1 };
};
let poolEnd = async () => { events.push('db.end'); };
fakeDb.pool = { end: () => poolEnd() };

let mqttEndArgs = null;
installModule('mqtt_bridge.js', {
  init: () => events.push('mqtt.init'),
  isConnected: () => true,
  end: async (opts) => { mqttEndArgs = opts; events.push('mqtt.end'); },
});
let schedulerStop = async () => { events.push('scheduler.stop'); };
installModule('scheduler.js', {
  start: () => events.push('scheduler.start'),
  stop: () => schedulerStop(),
});
installModule('services/mqtt_credential_service.js', {
  startCleanup: () => events.push('cred.startCleanup'),
  stopCleanup: () => events.push('cred.stopCleanup'),
  kickUsernames: async () => ({}),
  revokeUserAccess: async () => ({ usernames: [] }),
  revokeHomeAccess: async () => ({ usernames: [] }),
});

const { start } = require('../../src/server');
const { describeFatal, redactSensitive } = require('../../src/utils/fatal_log');

const SIGNALS = ['SIGTERM', 'SIGINT', 'unhandledRejection', 'uncaughtException'];

/**
 * Sunucuyu baslatir; process.exit'i sarar; start()'in ekledigi isleyicileri ayirir (calistiricinin isleyicilerine
 * dokunulmaz) ve sonunda hepsini geri alir.
 */
async function withServer(options, fn) {
  events.length = 0;
  mqttEndArgs = null;
  queryDelayMs = 0;
  poolEnd = async () => { events.push('db.end'); };
  schedulerStop = async () => { events.push('scheduler.stop'); };

  const before = {};
  for (const ev of SIGNALS) before[ev] = process.listeners(ev).slice();
  const realExit = process.exit;
  const realExitCode = process.exitCode;
  const exits = [];
  process.exit = (code) => { exits.push(code); };

  const errors = [];
  const realConsoleError = console.error;
  const realConsoleLog = console.log;
  console.error = (...a) => { errors.push(a.map((x) => (typeof x === 'string' ? x : String(x))).join(' ')); };
  console.log = () => {};

  let ctx = null;
  try {
    const { app, server, shutdown } = start(options);
    if (!server.listening) await once(server, 'listening');
    const mine = {};
    for (const ev of SIGNALS) mine[ev] = process.listeners(ev).filter((l) => !before[ev].includes(l));
    ctx = { app, server, shutdown, port: server.address().port, exits, errors, handlers: mine };
    await fn(ctx);
  } finally {
    process.exit = realExit;
    process.exitCode = realExitCode;
    console.error = realConsoleError;
    console.log = realConsoleLog;
    for (const ev of SIGNALS) {
      for (const l of process.listeners(ev)) if (!before[ev].includes(l)) process.removeListener(ev, l);
    }
    if (ctx && ctx.server.listening) await new Promise((r) => ctx.server.close(() => r()));
  }
}

// ======================================================================================================
// 1) Guvenli gunluk (fatal_log): yigin var, sir/govde YOK
// ======================================================================================================
test('describeFatal: Error -> ad + kod + maskelenmis mesaj + yigin KARELERI; mesajdaki sirlar maskelenir', () => {
  const secretToken = crypto.randomBytes(32).toString('base64url');
  const jwtLike = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4eXoxMjM0NTYifQ.c2lnbmF0dXJlLWRlZ2VyaQ';
  const err = new Error(
    `sorgu hatasi password=Cok-Gizli-Parola-9 Authorization: Bearer ${secretToken} e-posta kisi@example.com pin 483920 jwt ${jwtLike} ` +
    `api_key: "abc123secret" opak ${crypto.randomBytes(24).toString('hex')}`
  );
  err.code = 'XX000';
  err.detail = 'Key (email)=(gizli@example.com) already exists.'; // ayrinti alanlari ASLA yazilmaz
  err.config = { headers: { Authorization: 'Bearer ASLA-YAZILMAZ-1234567890' } };
  const text = describeFatal('UNCAUGHT-EXCEPTION', err, { origin: 'uncaughtException' });

  assert.match(text, /^\[UNCAUGHT-EXCEPTION\] \(uncaughtException\) Error \[XX000\]: /);
  assert.match(text, /\n {4}at /, 'yigin kareleri yazilmali');
  for (const secret of [secretToken, 'Cok-Gizli-Parola-9', 'kisi@example.com', '483920', jwtLike, 'abc123secret', 'gizli@example.com', 'ASLA-YAZILMAZ', 'already exists']) {
    assert.ok(!text.includes(secret), `sizdi: ${secret.slice(0, 24)}`);
  }
  assert.match(text, /\[GIZLENDI\]|\[JWT\]|\[e-posta\]|\[sayi\]/);
  // yigin satirlari: ilk satir (mesaj) yigin olarak tekrar yazilmaz
  assert.strictEqual((text.match(/sorgu hatasi/g) || []).length, 1);
});

test('describeFatal: Error OLMAYAN neden -> tur/anahtar adlari; DEGERLER ve govde asla yazilmaz', () => {
  const body = { email: 'kisi@example.com', password: 'Cok-Gizli-Parola-9', token: crypto.randomBytes(24).toString('hex') };
  const t1 = describeFatal('UNHANDLED-REJECTION', body);
  assert.match(t1, /Error olmayan neden \(Object; anahtarlar: email, password, token\)/);
  for (const v of Object.values(body)) assert.ok(!t1.includes(v));

  class FakeResponse { constructor() { this.statusCode = 500; this.rawBody = 'GIZLI-GOVDE-123456'; } }
  const t2 = describeFatal('UNHANDLED-REJECTION', new FakeResponse());
  assert.match(t2, /FakeResponse; anahtarlar: statusCode, rawBody/);
  assert.ok(!t2.includes('GIZLI-GOVDE'));

  assert.match(describeFatal('X', 'duz metin neden 987654 e@x.com'), /Error olmayan neden \(metin\): duz metin neden \[sayi\] \[e-posta\]/);
  assert.match(describeFatal('X', null), /null/);
  assert.match(describeFatal('X', undefined), /undefined/);
  assert.match(describeFatal('X', 42), /\(number\)/);
  assert.match(describeFatal('X', Symbol('s')), /\(symbol\)/);
});

test('describeFatal: cause zinciri en cok 2 seviye; dairesel/tuhaf nesneler ve patlayan getter FIRLATMAZ', () => {
  const e3 = new Error('uc'); const e2 = new Error('iki', { cause: e3 }); const e1 = new Error('bir', { cause: e2 });
  const top = new Error('ust', { cause: e1 });
  const text = describeFatal('T', top);
  assert.match(text, /ust/);
  assert.match(text, /neden: Error: bir/);
  assert.match(text, /neden: Error: iki/);
  assert.ok(!/uc\b/.test(text.split('neden: Error: iki')[1] || ''), '3. seviye yazilmaz');

  const circular = {}; circular.self = circular;
  assert.doesNotThrow(() => describeFatal('T', circular));
  const evil = new Proxy({}, { ownKeys() { throw new Error('anahtar okunamaz'); }, get() { throw new Error('alan okunamaz'); } });
  assert.doesNotThrow(() => describeFatal('T', evil));
  const weird = new Error('x');
  Object.defineProperty(weird, 'code', { get() { throw new Error('getter patladi'); } });
  assert.throws(() => weird.code); // getter gercekten patliyor ...
  assert.doesNotThrow(() => describeFatal('T', weird), '... ama gunluk FIRLATMAZ'); // (server.js logFatal ayrica try/catch)
});

test('redactSensitive: kisaltir, kontrol karakterlerini atar, kisa zararsiz metni korur', () => {
  assert.strictEqual(redactSensitive('ECONNREFUSED 127.0.0.1:5432'), 'ECONNREFUSED 127.0.0.1:5432');
  assert.ok(redactSensitive('a'.repeat(1000)).length <= 410);
  assert.ok(!/\n/.test(redactSensitive('satir1\nsatir2\r\nsatir3')));
});

// ======================================================================================================
// 2) uncaughtException: zarif kapanis + cikis kodu 1; unhandledRejection: yalniz log
// ======================================================================================================
test('uncaughtException: yigin loglanir (sir YOK), siralı kapanis calisir, cikis kodu 1, process.exitCode=1', async () => {
  await withServer({}, async (ctx) => {
    assert.strictEqual(ctx.handlers.uncaughtException.length, 1);
    const err = new Error('beklenmeyen hata password=Cok-Gizli-Parola-9 token=' + crypto.randomBytes(24).toString('hex'));
    ctx.handlers.uncaughtException[0](err, 'uncaughtException');
    // kapanis asenkron: sunucu kapaninca process.exit(1) cagrilir
    for (let i = 0; i < 100 && ctx.exits.length === 0; i++) await sleep(20);

    assert.deepStrictEqual(ctx.exits, [1], 'cikis kodu 1');
    assert.strictEqual(process.exitCode, 1, 'zarif yol yarida kalsa bile cikis kodu korunur');
    assert.deepStrictEqual(events.filter((e) => /\.(stop|end|stopCleanup)$/.test(e)), ['scheduler.stop', 'cred.stopCleanup', 'mqtt.end', 'db.end']);
    assert.strictEqual(ctx.server.listening, false);

    const fatal = ctx.errors.find((l) => l.startsWith('[UNCAUGHT-EXCEPTION]'));
    assert.ok(fatal, 'uncaughtException loglanmali');
    assert.match(fatal, /beklenmeyen hata/);
    assert.match(fatal, /\n {4}at /, 'yigin var');
    assert.ok(!fatal.includes('Cok-Gizli-Parola-9'));
    assert.ok(!/[0-9a-f]{40}/.test(fatal), 'opak jeton yazilmamali');
  });
});

test('uncaughtException: bir kapanis adimi TAKILSA da (zaman asimi) sonraki adimlar calisir ve cikis kodu yine 1', async () => {
  await withServer({ stepTimeoutMs: 150 }, async (ctx) => {
    schedulerStop = () => new Promise(() => {}); // asla bitmez
    ctx.handlers.uncaughtException[0](new Error('x'), 'uncaughtException');
    for (let i = 0; i < 150 && ctx.exits.length === 0; i++) await sleep(20);
    assert.deepStrictEqual(ctx.exits, [1]);
    assert.ok(events.includes('mqtt.end') && events.includes('db.end'), 'takilan adim sonrakini engellememeli');
    assert.ok(ctx.errors.some((l) => /zaman asimina ugradi \(scheduler\)/.test(l)));
  });
});

test('unhandledRejection: yalniz log (surec KAPANMAZ); Error olmayan nedenin degerleri yazilmaz', async () => {
  await withServer({}, async (ctx) => {
    assert.strictEqual(ctx.handlers.unhandledRejection.length, 1);
    ctx.handlers.unhandledRejection[0](new Error('reddedildi'), Promise.resolve());
    ctx.handlers.unhandledRejection[0]({ authorization: 'Bearer ASLA-YAZILMAZ-1234567890', body: 'GIZLI' });
    await sleep(30);
    assert.deepStrictEqual(ctx.exits, [], 'unhandledRejection surecı kapatmaz');
    assert.strictEqual(ctx.server.listening, true);
    const rej = ctx.errors.filter((l) => l.startsWith('[UNHANDLED-REJECTION]'));
    assert.strictEqual(rej.length, 2);
    assert.match(rej[0], /reddedildi/);
    assert.match(rej[0], /\n {4}at /);
    assert.match(rej[1], /anahtarlar: authorization, body/);
    assert.ok(!rej.join('\n').includes('ASLA-YAZILMAZ') && !rej.join('\n').includes('GIZLI'));
    await ctx.shutdown('TEST');
  });
});

// ======================================================================================================
// 3) Sirali kapanis (SIGTERM/SIGINT)
// ======================================================================================================
test('SIGTERM/SIGINT isleyicileri kayitli; sinyal -> siralı kapanis -> cikis kodu 0; ikinci cagri yok sayilir', async () => {
  await withServer({}, async (ctx) => {
    assert.strictEqual(ctx.handlers.SIGTERM.length, 1);
    assert.strictEqual(ctx.handlers.SIGINT.length, 1);
    ctx.handlers.SIGTERM[0]();
    ctx.handlers.SIGINT[0](); // ikinci sinyal: yok sayilir
    for (let i = 0; i < 100 && ctx.exits.length === 0; i++) await sleep(20);
    await sleep(50);
    assert.deepStrictEqual(ctx.exits, [0]);
    assert.deepStrictEqual(events.slice(events.indexOf('scheduler.start') + 1).filter((e) => /\.(stop|end|stopCleanup)$/.test(e)),
      ['scheduler.stop', 'cred.stopCleanup', 'mqtt.end', 'db.end'], 'HTTP -> zamanlayici -> MQTT -> pg havuzu');
    assert.ok(mqttEndArgs && Number.isFinite(mqttEndArgs.timeoutMs), 'kopru kapanisi zaman sinirli');
  });
});

test('kapanis: MESGUL keep-alive baglantisi varken sunucu hizla kapanir (Node close() yalniz bosta baglantilari kapatir)', async () => {
  await withServer({ shutdownTimeoutMs: 8000, httpDrainMs: 4000 }, async (ctx) => {
    queryDelayMs = 400; // /ready 400 ms surer: kapanis aninda istek devam ediyor
    const agent = new http.Agent({ keepAlive: true });
    const respPromise = new Promise((resolve, reject) => {
      http.get({ host: '127.0.0.1', port: ctx.port, path: '/ready', agent }, (res) => {
        let body = '';
        res.on('data', (d) => { body += d; });
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
      }).on('error', reject);
    });
    await sleep(100);
    const t0 = Date.now();
    await ctx.shutdown('TEST');
    const elapsed = Date.now() - t0;
    const resp = await respPromise;
    agent.destroy();

    assert.ok(elapsed < 2500, `kapanis keepAliveTimeout'u (65 sn) / drain suresini beklememeli (${elapsed} ms)`);
    assert.deepStrictEqual(ctx.exits, [0], 'zorla cikis (zaman asimi) yolu KULLANILMAMALI');
    assert.ok(events.includes('mqtt.end') && events.includes('db.end'), 'MQTT ve havuz kapanisi calismis olmali');
    // suren istek tamamlandi: kapaniyor -> /ready 503 shutting_down + Connection: close
    assert.strictEqual(resp.status, 503);
    assert.match(resp.body, /shutting_down/);
    assert.strictEqual(String(resp.headers.connection).toLowerCase(), 'close');
  });
});

test('kapanis: drain suresini ASAN istek kesilir; sonraki adimlar yine calisir', async () => {
  await withServer({ shutdownTimeoutMs: 8000, httpDrainMs: 300 }, async (ctx) => {
    queryDelayMs = 3000; // takili istek
    const agent = new http.Agent({ keepAlive: true });
    const outcome = new Promise((resolve) => {
      const req = http.get({ host: '127.0.0.1', port: ctx.port, path: '/ready', agent }, (res) => { res.resume(); res.on('end', () => resolve('yanit')); });
      req.on('error', () => resolve('kesildi'));
    });
    await sleep(80);
    const t0 = Date.now();
    await ctx.shutdown('TEST');
    const elapsed = Date.now() - t0;
    assert.ok(elapsed < 2000, `drain sonrasi baglanti kesilmeli (${elapsed} ms)`);
    assert.strictEqual(await outcome, 'kesildi');
    agent.destroy();
    assert.deepStrictEqual(ctx.exits, [0]);
    assert.ok(events.includes('mqtt.end') && events.includes('db.end'));
  });
});

test('kapanis: toplam sinir asilirsa ZORLA cikis (kod 1) ve hata loglanir; zamanlayici unref EDILMEZ', async () => {
  await withServer({ shutdownTimeoutMs: 250, stepTimeoutMs: 5000 }, async (ctx) => {
    poolEnd = () => new Promise(() => {}); // pg havuzu hic kapanmaz
    ctx.shutdown('TEST'); // beklenmez: takiliyor
    for (let i = 0; i < 100 && ctx.exits.length === 0; i++) await sleep(20);
    assert.deepStrictEqual(ctx.exits, [1], 'zorla cikis kodu 1 (zarif cikis kodu 0 olsa bile)');
    assert.ok(ctx.errors.some((l) => /zorla cikiliyor/.test(l)));
    assert.ok(events.includes('mqtt.end'), 'havuzdan once MQTT kapanmis olmali');
  });
});

test('kapanis: adim hatasi (atilan hata) yutulur ve MASKELENIR; diger adimlar calisir', async () => {
  await withServer({}, async (ctx) => {
    schedulerStop = async () => { throw new Error('durdurma hatasi password=Cok-Gizli-Parola-9'); };
    await ctx.shutdown('TEST');
    assert.deepStrictEqual(ctx.exits, [0]);
    const l = ctx.errors.find((x) => /Kapanis adimi basarisiz \(scheduler\)/.test(x));
    assert.ok(l, 'hata loglanmali');
    assert.ok(!l.includes('Cok-Gizli-Parola-9'));
    assert.ok(events.includes('db.end'));
  });
});

test('kapanis sirasinda /ready 503 shutting_down; kapanis oncesi 200 ready (varsayilan)', async () => {
  await withServer({}, async (ctx) => {
    const get = (path) => new Promise((resolve, reject) => {
      http.get({ host: '127.0.0.1', port: ctx.port, path, agent: false }, (res) => {
        let b = ''; res.on('data', (d) => { b += d; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(b) }));
      }).on('error', reject);
    });
    const ok = await get('/ready');
    assert.strictEqual(ok.status, 200);
    assert.strictEqual(ok.body.status, 'ready');
    ctx.app.locals.shuttingDown = true;
    const draining = await get('/ready');
    assert.strictEqual(draining.status, 503);
    assert.strictEqual(draining.body.status, 'shutting_down');
    ctx.app.locals.shuttingDown = false;
    await ctx.shutdown('TEST');
  });
});
