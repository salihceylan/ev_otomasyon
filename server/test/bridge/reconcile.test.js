'use strict';

// S2 (plan §5d-3) - CEVRIMICI OLUNCA UZLASTIRMA: bekleyen cocuk kilidi niyeti ve pano degisimi sonrasi panjur sureleri
// (`set_runtime`), cihaz cevrimici olunca BIR KEZ uygulanir; idempotent, dongusuz, deneme sinirli, hata yalitimli.
//
// Gercek veritabani / broker YOKTUR: uzlastiricinin SQL'ini (SQL sabitleri, esitlikle eslesir) taklit eden bellek ici
// dunya + sahte yayinci + sahte zamanlayicilar. Yayin yolu (QoS1/retain=false/PUBACK) kopru testlerinde (asagida,
// "kopru entegrasyonu") sahte mqtt istemcisiyle ayrica dogrulanir.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { MqttBridge, KeyedWorkQueue } = require('../../src/mqtt_bridge');
const { createDeviceReconciler, SQL, constants } = require('../../src/services/device_reconciler');
const { makeFakeTimers, makeLogger, makeFakeClient, makeFakeMqttLib, makeFakeDb, flush } = require('./_helpers');

const { MAX_ATTEMPTS, BACKOFF_BASE_MS, SETTLE_MS, RUNTIME_SPACING_MS, INTENT_MAX_AGE_SEC } = constants;
const CMD_ID_RE = /^[A-Za-z0-9._:-]{1,24}$/;
const T0 = Date.parse('2026-10-01T12:00:00Z');

// ------------------------------------------------------------------------------
// Dunya: evler, cihazlar, panjur satirlari + uzlastiricinin SQL'ini taklit eden sahte db
// ------------------------------------------------------------------------------
function makeWorld() {
  const w = {
    now: T0,
    homes: new Map(), // topic -> { id, requested, requestedAtText, ageSec }
    devices: [], // { id, uuid, topic, live, childLock, snapshot }
    endpoints: [], // { deviceId, pair, sec }
    queries: [],
    published: [], // basarili yayinlar { topic, cmd }
    publishAttempts: [], // basarili + basarisiz { topic, cmd, ok }
    failTopics: new Set(),
    failNthPublish: null, // global sira (1 tabanli) basarisiz olsun
    dbFailTopics: new Set(),
    sleeps: [],
    connected: true,
    seq: 0,
  };
  w.addHome = (topic, { requested = null, requestedAtText = '2026-10-01 12:00:00.123456+00', ageSec = 5 } = {}) => {
    const h = { id: crypto.randomUUID(), requested, requestedAtText: requested === null ? null : requestedAtText, ageSec };
    w.homes.set(topic, h);
    return h;
  };
  w.addDevice = (topic, uuid, { live = true, childLock = false, snapshot = null, caps } = {}) => {
    const d = { id: crypto.randomUUID(), uuid, topic, live, childLock, snapshot, caps };
    w.devices.push(d);
    return d;
  };
  w.addShutter = (device, pair, sec) => {
    // yukari + asagi satirlari ayni sureyi paylasir
    w.endpoints.push({ deviceId: device.id, pair, sec }, { deviceId: device.id, pair, sec });
  };
  w.markerFor = (topic) => ({ runtime_sync: 'pending', home_id: w.homes.get(topic).id, replaced_at: new Date(w.now).toISOString() });
  const devicesOf = (topic) => w.devices.filter((d) => d.topic === topic);

  w.db = {
    async query(text, params) {
      w.queries.push({ text, params });
      switch (text) {
        case SQL.childLock: {
          const topic = params[0];
          if (w.dbFailTopics.has(topic)) throw Object.assign(new Error('veritabani hatasi'), { code: '57014' });
          const h = w.homes.get(topic);
          if (!h) return { rows: [] };
          const devs = devicesOf(topic);
          const base = { home_id: h.id, requested: h.requested, requested_at_text: h.requestedAtText, requested_age_sec: h.ageSec };
          if (devs.length === 0) return { rows: [{ ...base, device_id: null, device_uuid: null, live: null, child_lock_enabled: null }] };
          return { rows: devs.map((d) => ({ ...base, device_id: d.id, device_uuid: d.uuid, live: d.live, child_lock_enabled: d.childLock })) };
        }
        case SQL.clearSatisfied: {
          const [homeId, requested, atText] = params;
          const entry = [...w.homes.entries()].find(([, h]) => h.id === homeId);
          if (!entry) return { rowCount: 0 };
          const [topic, h] = entry;
          const allSame = devicesOf(topic).every((d) => d.childLock === requested);
          if (h.requested === requested && h.requestedAtText === atText && allSame) {
            h.requested = null; h.requestedAtText = null;
            return { rowCount: 1 };
          }
          return { rowCount: 0 };
        }
        case SQL.clearExpired: {
          const [homeId, requested, atText] = params;
          const h = [...w.homes.values()].find((x) => x.id === homeId);
          if (h && h.requested === requested && h.requestedAtText === atText) {
            h.requested = null; h.requestedAtText = null;
            return { rowCount: 1 };
          }
          return { rowCount: 0 };
        }
        case SQL.runtimePending: {
          const topic = params[0];
          const h = w.homes.get(topic);
          const devs = devicesOf(topic);
          return {
            rows: devs.filter((d) => d.snapshot && d.snapshot.runtime_sync === 'pending').map((d) => ({
              home_id: h.id, device_id: d.id, device_uuid: d.uuid, live: d.live,
              marker_home_id: d.snapshot.home_id, marker_replaced_at: d.snapshot.replaced_at, device_count: devs.length,
              ...(d.caps !== undefined ? { caps: d.caps } : {}),
            })),
          };
        }
        case SQL.runtimeShutters: {
          const byPair = new Map();
          for (const e of w.endpoints.filter((x) => x.deviceId === params[0])) byPair.set(e.pair, e.sec);
          return { rows: [...byPair].sort((a, b) => a[0] - b[0]).map(([pair, sec]) => ({ pair, sec })) };
        }
        case SQL.runtimeDone: {
          const d = w.devices.find((x) => x.id === params[0]);
          if (d && d.snapshot && d.snapshot.runtime_sync === 'pending' && d.snapshot.replaced_at === params[1]) {
            d.snapshot = { ...d.snapshot, runtime_sync: 'synced' };
            return { rowCount: 1 };
          }
          return { rowCount: 0 };
        }
        case SQL.localKeyPending:
          // bu dunyada bekleyen yerel anahtar yok (ayrintili testler: local_key_reconcile.test.js)
          return { rows: [] };
        default:
          throw new Error(`beklenmeyen sorgu: ${String(text).slice(0, 60)}`);
      }
    },
  };

  w.publishCommand = async (topic, cmd) => {
    const n = w.publishAttempts.length + 1;
    const fail = w.failTopics.has(topic) || w.failNthPublish === n;
    w.publishAttempts.push({ topic, cmd, ok: !fail });
    if (fail) throw Object.assign(new Error('broker down'), { code: 'BROKER_UNAVAILABLE' });
    w.published.push({ topic, cmd });
    return { topic, payload: JSON.stringify(cmd) };
  };
  return w;
}

function makeRec(w, extra = {}) {
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const rec = createDeviceReconciler({
    db: w.db,
    publishCommand: w.publishCommand,
    isConnected: () => w.connected,
    logger,
    now: () => w.now,
    timers,
    offlineAfterSec: 120,
    QueueClass: KeyedWorkQueue,
    sleep: async (ms) => { w.sleeps.push(ms); },
    ...extra,
  });
  return { rec, timers, logger };
}

const live = (rec, w, topic, device, extra = {}) => rec.onLiveState({ topicId: topic, homeId: w.homes.get(topic).id, deviceId: device.id, ...extra });

/** Tek bekleyen zamanlayiciyi calistirir (zamani onun suresi kadar ilerletir) ve kuyruk bosalana kadar bekler. */
async function runTimer(w, rec, timers, expectedDelay) {
  const pending = timers.pendingTimeouts();
  assert.equal(pending.length, 1, `tam bir zamanlayici bekleniyordu (${pending.length})`);
  const [h] = pending;
  if (expectedDelay !== undefined) assert.equal(h.ms, expectedDelay, 'zamanlayici suresi');
  w.now += h.ms;
  timers.fireTimeout(h);
  await rec.whenIdle();
  return h.ms;
}

const childLockCmds = (w) => w.published.filter((p) => p.cmd.cmd === 'set_child_lock');
const runtimeCmds = (w) => w.published.filter((p) => p.cmd.cmd === 'set_runtime');
const TOPIC = 'h_aaaaaaaaaaaaaaaa';
const TOPIC_B = 'h_bbbbbbbbbbbbbbbb';

// ======================================================================================================
// COCUK KILIDI
// ======================================================================================================
test('cevrimdisi -> cevrimici gecisi: ilk canli state SETTLE_MS sonra tek yayin planlar; cmd sozlesmeye uygun, kimlik gecerli', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers, logger } = makeRec(w);

  live(rec, w, TOPIC, d);
  assert.equal(w.queries.length, 0, 'tetik anında VERITABANI sorgusu yok (yalniz bellek)');
  assert.equal(timers.pendingTimeouts().length, 1);
  assert.equal(timers.pendingTimeouts()[0].ms, SETTLE_MS, 'firmware cmd aboneliginden sonraki ilk 1500 ms yok sayar -> 2 sn bekle');
  assert.equal(w.published.length, 0);

  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(childLockCmds(w).length, 1);
  const { topic, cmd } = childLockCmds(w)[0];
  assert.equal(topic, TOPIC);
  assert.deepEqual(Object.keys(cmd).sort(), ['cmd', 'enabled', 'id']);
  assert.equal(cmd.enabled, true);
  assert.match(cmd.id, CMD_ID_RE);
  assert.equal(rec.stats().published, 1);
  // yayin sonucu gunlukte; konu kimligi / komut kimligi / sir YOK
  const line = logger.lines.find((l) => /cocuk_kilidi/.test(l));
  assert.match(line, /sonuc=yayinlandi/);
  assert.match(line, /deneme=1\/3/);
  assert.ok(!line.includes(TOPIC) && !line.includes(cmd.id), 'konu kimligi / komut kimligi loglanmaz');
  // ustel bekleme: ilk yayindan 5 sn sonra yeniden dogrulama planlanir
  assert.equal(timers.pendingTimeouts()[0].ms, BACKOFF_BASE_MS);
});

test('yanki dogrulamasi: cihaz niyeti bildirirse niyet TEMIZLENIR, yeniden yayin YOK, dongu yok', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(childLockCmds(w).length, 1);

  d.childLock = true; // cihaz uyguladi ve state yankisi gonderdi
  live(rec, w, TOPIC, d); // yanki state'i (ayni cevrimici donem): yeni kontrol planlamaz (zamanlayici zaten bekliyor)
  await runTimer(w, rec, timers, BACKOFF_BASE_MS);
  assert.equal(childLockCmds(w).length, 1, 'ikinci yayin OLMAMALI');
  assert.equal(home.requested, null, 'bekleyen niyet temizlenmeli');
  assert.equal(timers.pendingTimeouts().length, 0, 'artik zamanlayici yok: dongu yok');
  assert.ok(logger.lines.some((l) => /sonuc=uyumlu.*bekleyen niyet temizlendi/.test(l)));
  assert.equal(rec.stats().satisfied, 1);

  // sonraki canli state'ler (kalp atisi) hicbir sey tetiklemez
  w.now += 30000; live(rec, w, TOPIC, d);
  assert.equal(timers.pendingTimeouts().length, 0);
});

test('AYNI DURUM: cihaz zaten niyeti bildiriyorsa HICBIR sey yayinlanmaz; niyet yine de temizlenir', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: false });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(w.publishAttempts.length, 0, 'yayin denemesi bile olmamali');
  assert.equal(home.requested, null);
});

test('YANKI ESLESMESI (REST ile cevrimici cihaza uygulanan istek): kararli cihazda niyetle ayni canli state niyeti TEMIZLER; yayin yok', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: true }); // cihaz zaten uyguladi
  const { rec, timers } = makeRec(w);
  // cihaz uzun suredir cevrimici: ilk state'i donem baslangici olarak tuketilir (niyet o anda da uyumlu)
  live(rec, w, TOPIC, d, { intent: null, reported: true });
  await runTimer(w, rec, timers);
  w.now += 30000;

  // REST kilidi istedi (niyet=true) ve cihaz yankiladi: ayni donemde, DB'ye gitmeden BELLEK karariyla kontrol planlanir
  assert.equal(timers.pendingTimeouts().length, 0);
  live(rec, w, TOPIC, d, { intent: true, reported: true });
  assert.equal(timers.pendingTimeouts().length, 1, 'yanki kontrolu planlandi');
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.publishAttempts.length, 0);
  assert.equal(home.requested, null, 'niyet temizlendi (sonradan yerel/LAN degisikligi eski niyetle geri alinmasin)');
});

test('niyetle UYUSMAYAN canli state (donem baslangici degil) kontrol URETMEZ: cevrimici cihazdaki yerel/LAN degisikligi ezilmez', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d, { intent: null, reported: false });
  await runTimer(w, rec, timers); // donem baslangici: bekleyen niyet yok
  assert.equal(w.publishAttempts.length, 0);
  // sonradan niyet yazildi (REST) ama cihaz uygulamadi / yerelden degistirildi: kararli cihaz -> uzlastirma YOK
  home.requested = true; home.requestedAtText = '2026-10-01 12:30:00.000001+00';
  w.now += 30000;
  live(rec, w, TOPIC, d, { intent: true, reported: false }); // kararli cihaz: niyetle farkli
  assert.equal(timers.pendingTimeouts().length, 0);
  assert.equal(w.queries.filter((q) => q.text === SQL.childLock).length, 1, 'yeni sorgu yok');
});

test('yanki kontrolleri evde dakikada en cok bir kez; baska cihaz CEVRIMDISI uyumsuzsa 10 dk sessiz kalinir', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true });
  const a = w.addDevice(TOPIC, 'AHBU-S3-000A', { childLock: true });
  w.addDevice(TOPIC, 'AHBU-S3-000B', { live: false, childLock: false }); // cevrimdisi, uyumsuz
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, a, { intent: true, reported: true });
  await runTimer(w, rec, timers); // donem baslangici: B cevrimdisi -> yayin yok, niyet bekler
  assert.equal(home.requested, true);
  const queries = () => w.queries.filter((q) => q.text === SQL.childLock).length;
  assert.equal(queries(), 1);

  // ayni dakikada ve sonraki 10 dk icinde yankilar kontrol uretmez
  for (let i = 0; i < 10; i += 1) { w.now += 30000; live(rec, w, TOPIC, a, { intent: true, reported: true }); }
  assert.equal(timers.pendingTimeouts().length, 0);
  assert.equal(queries(), 1);

  // 10 dk sonra tekrar bakilir (B hala cevrimdisi -> yine bekler)
  w.now += 6 * 60000; live(rec, w, TOPIC, a, { intent: true, reported: true });
  assert.equal(timers.pendingTimeouts().length, 1);
  await runTimer(w, rec, timers);
  assert.equal(queries(), 2);
});

test('bekleyen niyet YOKSA: yayin yok, yazma yok (yalniz okuma)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: true });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(w.publishAttempts.length, 0);
  assert.equal(w.queries.filter((q) => /^UPDATE/.test(q.text)).length, 0, 'hicbir UPDATE yok');
});

test('DENEME SINIRI: cihaz uygulamazsa en cok 3 yayin, ustel bekleme 5/10/20 sn; sonra birakilir (yeni cevrimici donemde yeniden)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, TOPIC, d);

  const delays = [];
  delays.push(await runTimer(w, rec, timers, SETTLE_MS)); // deneme 1
  delays.push(await runTimer(w, rec, timers, 5000)); // deneme 2
  delays.push(await runTimer(w, rec, timers, 10000)); // deneme 3
  delays.push(await runTimer(w, rec, timers, 20000)); // son dogrulama: tukendi
  assert.deepEqual(delays, [2000, 5000, 10000, 20000]);
  assert.equal(childLockCmds(w).length, MAX_ATTEMPTS, `tam ${MAX_ATTEMPTS} yayin`);
  assert.equal(timers.pendingTimeouts().length, 0, 'tukendikten sonra yeniden planlama yok');
  assert.equal(rec.stats().exhausted, 1);
  assert.ok(logger.lines.some((l) => /warn: .*deneme_hakki_bitti/.test(l)));
  // her yayin FARKLI kimlik tasir (cihaz ayni kimligi yok sayar)
  assert.equal(new Set(childLockCmds(w).map((p) => p.cmd.id)).size, MAX_ATTEMPTS);

  // ayni cevrimici donemde kalp atislari yeniden DENEMEZ
  for (let i = 0; i < 5; i += 1) { w.now += 30000; live(rec, w, TOPIC, d); }
  assert.equal(timers.pendingTimeouts().length, 0);
  assert.equal(childLockCmds(w).length, MAX_ATTEMPTS);

  // cihaz cevrimdisi kalip (120 sn+) geri gelirse: yeni donem = taze butce
  w.now += 130000; live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(childLockCmds(w).length, MAX_ATTEMPTS + 1);
});

test('canli status: offline cevrimici donemi bitirir -> sonraki canli state (kisa sessizlikten sonra bile) yeni donemdir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  for (let i = 0; i < 4; i += 1) await runTimer(w, rec, timers);
  assert.equal(childLockCmds(w).length, 3);

  w.now += 20000;
  rec.onOffline(TOPIC); // LWT: offline
  w.now += 20000; // 40 sn: kalp atisi bosluk esiginin (120 sn) ALTINDA
  live(rec, w, TOPIC, d);
  assert.equal(timers.pendingTimeouts().length, 1, 'yeni cevrimici donem tetiklenmeli');
});

test('yeni niyet (REST yeni istek yazdi) deneme butcesini sifirlar', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true, requestedAtText: '2026-10-01 12:00:00.000001+00' });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  for (let i = 0; i < 4; i += 1) await runTimer(w, rec, timers);
  assert.equal(childLockCmds(w).length, 3);
  assert.equal(rec.stats().exhausted, 1);

  // kullanici kilidi KAPATMA istedi (farkli niyet + yeni zaman damgasi); cihaz hala kilitli
  home.requested = false; home.requestedAtText = '2026-10-01 12:05:00.000002+00';
  d.childLock = true;
  rec.checkNow(TOPIC);
  await rec.whenIdle();
  assert.equal(childLockCmds(w).length, 4, 'yeni niyet icin taze butce: bir yayin daha');
  assert.equal(childLockCmds(w)[3].cmd.enabled, false);
});

test('CEVRIMDISI cihaza yayin DENENMEZ (canli degil -> yayin yok, zamanlayici yok)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { live: false, childLock: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(w.publishAttempts.length, 0);
  assert.equal(timers.pendingTimeouts().length, 0);
  assert.equal(rec.stats().skippedOffline, 1);
});

test('cok panolu ev: fark yalniz CEVRIMDISI panoda ise yayin yok; pano cevrimici olunca (kendi donemi) yayinlanir; niyet ancak hepsi uyunca temizlenir', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true });
  const a = w.addDevice(TOPIC, 'AHBU-S3-000A', { live: true, childLock: true });
  const b = w.addDevice(TOPIC, 'AHBU-S3-000B', { live: false, childLock: false });
  const { rec, timers } = makeRec(w);

  live(rec, w, TOPIC, a);
  await runTimer(w, rec, timers);
  assert.equal(w.publishAttempts.length, 0, 'online pano uyumlu, offline pano icin yayin yok');
  assert.equal(home.requested, true, 'B hala uyumsuz: niyet bekliyor');

  b.live = true; // B cevrimici oldu
  live(rec, w, TOPIC, b);
  await runTimer(w, rec, timers);
  assert.equal(childLockCmds(w).length, 1);

  a.childLock = true; b.childLock = true;
  await runTimer(w, rec, timers, BACKOFF_BASE_MS);
  assert.equal(home.requested, null);
});

test('BAYAT niyet (> 7 gun): uygulanmaz, TEMIZLENIR (yerel/LAN degisikligini ezmez)', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true, ageSec: INTENT_MAX_AGE_SEC + 60 });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(w.publishAttempts.length, 0);
  assert.equal(home.requested, null);
  assert.ok(logger.lines.some((l) => /niyet_bayat/.test(l)));
  assert.equal(rec.stats().expired, 1);
});

test('yaris korumasi: temizleme sirasinda REST yeni niyet yazdiysa (zaman damgasi degisti) DOKUNULMAZ', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC, { requested: true, requestedAtText: '2026-10-01 12:00:00.000001+00' });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: true });
  const { rec, timers } = makeRec(w);
  // okuma sonrasi, temizlemeden once REST ayni degeri YENI zaman damgasiyla yeniden istedi
  const origQuery = w.db.query;
  w.db.query = async (text, params) => {
    const r = await origQuery(text, params);
    if (text === SQL.childLock) home.requestedAtText = '2026-10-01 12:00:09.000009+00';
    return r;
  };
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(home.requested, true, 'yeni niyet silinmemeli');
});

test('MQTT koprusu bagli degilse yayin denenmez, deneme hakki HARCANMAZ; kontrol sinirli sayida yeniden planlanir; baglaninca ILK deneme yapilir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers, logger } = makeRec(w);
  w.connected = false;
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.publishAttempts.length, 0);
  assert.equal(rec.stats().skippedNotConnected, 1);
  assert.equal(timers.pendingTimeouts().length, 1, 'kisa kopukluk icin yeniden planlandi');
  assert.equal(timers.pendingTimeouts()[0].ms, 15000);

  w.connected = true; // kopukluk bitti
  await runTimer(w, rec, timers, 15000);
  assert.equal(childLockCmds(w).length, 1);
  assert.ok(logger.lines.some((l) => l.includes('deneme=1/3 sonuc=yayinlandi')), 'erteleme denemeyi tuketmemis olmali');

  // kopukluk surerse en cok 8 kez yeniden planlanir, sonra sonraki cevrimici doneme birakilir
  const w2 = makeWorld();
  w2.addHome(TOPIC, { requested: true });
  const d2 = w2.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const r2 = makeRec(w2);
  w2.connected = false;
  live(r2.rec, w2, TOPIC, d2);
  for (let i = 0; i < 9; i += 1) await runTimer(w2, r2.rec, r2.timers);
  assert.equal(r2.timers.pendingTimeouts().length, 0, 'sinir asildi: yeniden planlama yok');
  assert.equal(w2.publishAttempts.length, 0);

  // yeni cevrimici donem (cihaz yeniden baglandi) erteleme hakkini da yeniler; baglanti geldiyse yayin yapilir
  w2.connected = true;
  w2.now += 130000;
  live(r2.rec, w2, TOPIC, d2);
  await runTimer(w2, r2.rec, r2.timers, SETTLE_MS);
  assert.equal(childLockCmds(w2).length, 1);
});

// ======================================================================================================
// HATA YALITIMI
// ======================================================================================================
test('bir evin yayin hatasi digerlerini ETKILEMEZ; hata sonucu loglanir (sir yok); butce harcanir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  w.addHome(TOPIC_B, { requested: true });
  const a = w.addDevice(TOPIC, 'AHBU-S3-000A', { childLock: false });
  const b = w.addDevice(TOPIC_B, 'AHBU-S3-000B', { childLock: false });
  w.failTopics.add(TOPIC);
  const { rec, timers, logger } = makeRec(w);

  live(rec, w, TOPIC, a);
  live(rec, w, TOPIC_B, b);
  const pending = timers.pendingTimeouts();
  assert.equal(pending.length, 2);
  for (const h of pending) timers.fireTimeout(h);
  await rec.whenIdle();

  assert.equal(childLockCmds(w).length, 1);
  assert.equal(childLockCmds(w)[0].topic, TOPIC_B, 'B yayinlandi');
  assert.equal(w.publishAttempts.filter((p) => p.topic === TOPIC && !p.ok).length, 1, 'A denendi ve basarisiz');
  assert.equal(rec.stats().publishFailed, 1);
  const failed = logger.lines.find((l) => /warn: .*sonuc=yayin_basarisiz/.test(l));
  assert.ok(failed && /hata=BROKER_UNAVAILABLE/.test(failed));
  assert.ok(!logger.lines.join('\n').includes(TOPIC));
  // A icin yeniden deneme planlandi (ustel bekleme), B icin yanki dogrulamasi
  assert.equal(timers.pendingTimeouts().length, 2);
});

test('bir evin VERITABANI hatasi digerlerini etkilemez; hata loglanir (ayrinti yok), akis bozulmaz', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  w.addHome(TOPIC_B, { requested: true });
  const a = w.addDevice(TOPIC, 'AHBU-S3-000A', { childLock: false });
  const b = w.addDevice(TOPIC_B, 'AHBU-S3-000B', { childLock: false });
  w.dbFailTopics.add(TOPIC);
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, TOPIC, a);
  live(rec, w, TOPIC_B, b);
  for (const h of timers.pendingTimeouts()) timers.fireTimeout(h);
  await rec.whenIdle();
  assert.equal(childLockCmds(w).length, 1);
  assert.equal(childLockCmds(w)[0].topic, TOPIC_B);
  assert.equal(rec.stats().errors, 1);
  const line = logger.lines.find((l) => /kontrol hatasi/.test(l));
  assert.match(line, /57014/);
  assert.ok(!/veritabani hatasi/.test(line), 'hata MESAJI yazilmaz, yalniz kod');
});

// ======================================================================================================
// PANJUR SURELERI (pano degisimi sonrasi set_runtime)
// ======================================================================================================
test('pano degisimi sonrasi: yeni pano cevrimici olunca her panjur cifti icin set_runtime SIRAYLA yayinlanir; isaret temizlenir; ikinci donemde yayin yok', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { childLock: false, snapshot: w.markerFor(TOPIC) });
  w.addShutter(d, 1, 24);
  w.addShutter(d, 2, 20);
  const { rec, timers, logger } = makeRec(w);

  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  const cmds = runtimeCmds(w).map((p) => p.cmd);
  assert.equal(cmds.length, 2);
  assert.deepEqual(cmds.map((c) => [c.shutter, c.sec]), [[1, 24], [2, 20]], 'pair sirasiyla (FIFO)');
  for (const c of cmds) {
    assert.deepEqual(Object.keys(c).sort(), ['cmd', 'id', 'sec', 'shutter']);
    assert.match(c.id, CMD_ID_RE);
  }
  assert.notEqual(cmds[0].id, cmds[1].id);
  assert.deepEqual(w.sleeps, [RUNTIME_SPACING_MS], 'ardisik komutlar arasi aralik');
  assert.equal(d.snapshot.runtime_sync, 'synced', 'bekleyen isaret temizlendi');
  assert.equal(rec.stats().runtimeSynced, 1);
  assert.ok(logger.lines.some((l) => /panjur_suresi .*sonuc=uygulandi yayinlanan=2/.test(l)));

  // sonraki cevrimici donem (cihaz yeniden baglandi): isaret yok -> yayin YOK
  w.now += 200000; live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(runtimeCmds(w).length, 2);
});

test('panjur: yayin yarida basarisiz olursa isaret KALIR; sonraki denemede yalniz KALANLAR yayinlanir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC) });
  w.addShutter(d, 1, 24);
  w.addShutter(d, 2, 31);
  w.addShutter(d, 3, 40);
  w.failNthPublish = 2; // ikinci komut basarisiz
  const { rec, timers } = makeRec(w);

  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.deepEqual(runtimeCmds(w).map((p) => p.cmd.shutter), [1]);
  assert.equal(d.snapshot.runtime_sync, 'pending', 'isaret kalmali');

  await runTimer(w, rec, timers, BACKOFF_BASE_MS); // ustel bekleme sonrasi yeniden
  assert.deepEqual(runtimeCmds(w).map((p) => p.cmd.shutter), [1, 2, 3], 'pair 1 TEKRAR yayinlanmaz (NVS yazimi)');
  assert.equal(d.snapshot.runtime_sync, 'synced');
});

test('panjur: cevrimdisi pano, cok panolu ev, baska eve ait / bayat isaret -> yayin YOK', async () => {
  // cevrimdisi
  {
    const w = makeWorld();
    w.addHome(TOPIC);
    const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { live: false, snapshot: w.markerFor(TOPIC) });
    w.addShutter(d, 1, 24);
    const { rec, timers } = makeRec(w);
    live(rec, w, TOPIC, d);
    await runTimer(w, rec, timers);
    assert.equal(w.publishAttempts.length, 0);
    assert.equal(d.snapshot.runtime_sync, 'pending');
  }
  // cok panolu ev: ev konusu tum panolara gider -> saglam panonun kalibrasyonu ezilmez
  {
    const w = makeWorld();
    w.addHome(TOPIC);
    const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC) });
    w.addDevice(TOPIC, 'AHBU-S3-0003', {});
    w.addShutter(d, 1, 24);
    const { rec, timers, logger } = makeRec(w);
    live(rec, w, TOPIC, d);
    await runTimer(w, rec, timers);
    assert.equal(w.publishAttempts.length, 0);
    assert.equal(rec.stats().skippedMultiDevice, 1);
    assert.ok(logger.lines.some((l) => /atlandi \(evde 2 pano var/.test(l)));
  }
  // baska eve ait isaret (cihaz sonradan baska eve tasindi)
  {
    const w = makeWorld();
    w.addHome(TOPIC);
    const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: { ...w.markerFor(TOPIC), home_id: crypto.randomUUID() } });
    w.addShutter(d, 1, 24);
    const { rec, timers, logger } = makeRec(w);
    live(rec, w, TOPIC, d);
    await runTimer(w, rec, timers);
    assert.equal(w.publishAttempts.length, 0);
    assert.ok(logger.lines.some((l) => /isaret_gecersiz/.test(l)));
  }
  // bayat isaret (> 14 gun)
  {
    const w = makeWorld();
    w.addHome(TOPIC);
    const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: { ...w.markerFor(TOPIC), replaced_at: new Date(w.now - 15 * 86400e3).toISOString() } });
    w.addShutter(d, 1, 24);
    const { rec, timers } = makeRec(w);
    live(rec, w, TOPIC, d);
    await runTimer(w, rec, timers);
    assert.equal(w.publishAttempts.length, 0);
  }
});

test('panjur: aralik disi sure atlanir (gecersiz komut yayinlanmaz); gecerli olanlar yayinlanir; panjur yoksa isaret temizlenir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC) });
  w.addShutter(d, 1, 0); // gecersiz (1..300)
  w.addShutter(d, 2, 301); // gecersiz
  w.addShutter(d, 3, 45);
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.deepEqual(runtimeCmds(w).map((p) => [p.cmd.shutter, p.cmd.sec]), [[3, 45]]);
  assert.equal(d.snapshot.runtime_sync, 'synced');

  const w2 = makeWorld();
  w2.addHome(TOPIC);
  const d2 = w2.addDevice(TOPIC, 'AHBU-S3-0004', { snapshot: w2.markerFor(TOPIC) }); // panjursuz kurulum
  const r2 = makeRec(w2);
  live(r2.rec, w2, TOPIC, d2);
  await runTimer(w2, r2.rec, r2.timers);
  assert.equal(w2.publishAttempts.length, 0);
  assert.equal(d2.snapshot.runtime_sync, 'synced', 'uygulanacak sey yok -> isaret temizlenir');
});

test('panjur: yeni pano degisimi isareti yeniden kurduysa (farkli replaced_at) eski uzlastirma onu SILMEZ', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC) });
  w.addShutter(d, 1, 24);
  const { rec, timers } = makeRec(w);
  const orig = w.db.query;
  w.db.query = async (text, params) => {
    const r = await orig(text, params);
    if (text === SQL.runtimeShutters) d.snapshot = { ...d.snapshot, replaced_at: new Date(w.now + 5000).toISOString() }; // arada yeniden kuruldu
    return r;
  };
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(d.snapshot.runtime_sync, 'pending', 'yeni isaret korunmali');
});

// sko-3: yanki veren panoda (caps 'intrusion'; firmware last_id/last_rej) set_runtime yalniz PANONUN ONAYIYLA 'synced'.
const ECHO_CAPS = ['safety', 'actuator', 'event', 'cfg', 'intrusion'];
function echoRec(w, verdicts) {
  const order = [];
  const waits = [];
  const cancelled = [];
  const pub = w.publishCommand;
  w.publishCommand = async (t, c) => { order.push('publish'); return pub(t, c); };
  const r = makeRec(w, {
    expectOutcome: (topic, id, ms, opts) => {
      order.push('wait');
      waits.push({ topic, id, ms, opts });
      const v = verdicts.length > 1 ? verdicts.shift() : verdicts[0];
      return Promise.resolve(typeof v === 'function' ? v() : v);
    },
    cancelAck: (t, id) => cancelled.push(id),
  });
  return { ...r, order, waits, cancelled };
}

test('sko-3: yanki veren pano set_runtime REDDEDERSE isaret synced OLMAZ (geri cekilmeyle yeniden denenir); onaylayinca synced', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC), caps: ECHO_CAPS });
  w.addShutter(d, 1, 24);
  w.addShutter(d, 3, 30);
  const verdicts = [{ ok: true }, { ok: false, rejected: 'bad_cmd' }];
  const { rec, timers, logger, order, waits } = echoRec(w, verdicts);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  const cmds = runtimeCmds(w).map((p) => p.cmd);
  assert.deepEqual(cmds.map((c) => c.shutter), [1, 3]);
  assert.deepEqual(order, ['wait', 'publish', 'wait', 'publish'], 'bekleyici YAYINDAN ONCE kurulur');
  assert.deepEqual(waits.map((x) => [x.id, x.ms, x.opts]), cmds.map((c) => [c.id, 5000, { uid: 'AHBU-S3-0002' }]));
  assert.equal(d.snapshot.runtime_sync, 'pending', 'reddedilen komut synced sayilmaz');
  assert.ok(logger.lines.some((l) => /panjur_suresi .*reddedildi/.test(l)), logger.lines.join('\n'));
  // geri cekilme sonrasi yalniz onaylanmayan cift yeniden; pano onaylar -> synced
  verdicts.length = 0;
  verdicts.push({ ok: true });
  await runTimer(w, rec, timers, BACKOFF_BASE_MS);
  assert.deepEqual(runtimeCmds(w).map((p) => p.cmd.shutter), [1, 3, 3]);
  assert.equal(d.snapshot.runtime_sync, 'synced');
});

test('sko-3: onay zaman asimi da synced saymaz; yayin hatasinda bekleyici iptal edilir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC), caps: ECHO_CAPS });
  w.addShutter(d, 1, 24);
  const { rec, timers } = echoRec(w, [{ ok: false, timeout: true }]);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(runtimeCmds(w).length, 1);
  assert.equal(d.snapshot.runtime_sync, 'pending');

  const w2 = makeWorld();
  w2.addHome(TOPIC, { requested: null });
  const d2 = w2.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w2.markerFor(TOPIC), caps: ECHO_CAPS });
  w2.addShutter(d2, 1, 24);
  w2.failTopics.add(TOPIC);
  const r2 = echoRec(w2, [{ ok: true }]);
  live(r2.rec, w2, TOPIC, d2);
  await runTimer(w2, r2.rec, r2.timers, SETTLE_MS);
  assert.equal(r2.cancelled.length, 1, 'yayin basarisiz: bekleyici iptal');
  assert.equal(d2.snapshot.runtime_sync, 'pending');
});

test('sko-3: yanki vermeyen (caps intrusion yok) ya da caps bilinmeyen pano: bugunku PUBACK davranisi (bekleyici kurulmaz)', async () => {
  for (const caps of [['safety', 'actuator', 'event', 'cfg'], null, undefined]) {
    const w = makeWorld();
    w.addHome(TOPIC, { requested: null });
    const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { snapshot: w.markerFor(TOPIC), caps });
    w.addShutter(d, 1, 24);
    const { rec, timers, waits } = echoRec(w, [{ ok: false, rejected: 'bad_cmd' }]);
    live(rec, w, TOPIC, d);
    await runTimer(w, rec, timers, SETTLE_MS);
    assert.equal(waits.length, 0, JSON.stringify(caps));
    assert.equal(d.snapshot.runtime_sync, 'synced', JSON.stringify(caps));
  }
});

test('cocuk kilidi ve panjur ayni pano degisiminde birlikte uzlastirilir; biri patlarsa digeri calisir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0002', { childLock: false, snapshot: w.markerFor(TOPIC) });
  w.addShutter(d, 1, 24);
  const { rec, timers } = makeRec(w);
  // cocuk kilidi sorgusu patlar -> panjur yine de uygulanir
  const orig = w.db.query;
  w.db.query = async (text, params) => {
    if (text === SQL.childLock) throw Object.assign(new Error('x'), { code: '40001' });
    return orig(text, params);
  };
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers);
  assert.equal(runtimeCmds(w).length, 1);
  assert.equal(rec.stats().errors, 1);
});

// ======================================================================================================
// YASAM DONGUSU
// ======================================================================================================
test('stop(): zamanlayicilar iptal, sonraki tetikler yok sayilir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: true });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  assert.equal(timers.pendingTimeouts().length, 1);
  rec.stop();
  assert.equal(timers.pendingTimeouts().length, 0);
  live(rec, w, TOPIC, d);
  assert.equal(timers.pendingTimeouts().length, 0);
  assert.equal(w.publishAttempts.length, 0);
});

test('kararli durumdaki cihaz (kalp atislari) HICBIR veritabani sorgusu / zamanlayici uretmez', async () => {
  const w = makeWorld();
  w.addHome(TOPIC, { requested: null });
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { childLock: true });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers); // ilk donem: tek kontrol
  const queriesAfterFirst = w.queries.length;
  for (let i = 0; i < 20; i += 1) { w.now += 30000; live(rec, w, TOPIC, d); }
  assert.equal(w.queries.length, queriesAfterFirst, 'kalp atislari sorgu uretmemeli');
  assert.equal(timers.pendingTimeouts().length, 0);
});

test('olusturucu: db ve publishCommand zorunlu', () => {
  assert.throws(() => createDeviceReconciler({}), /db/);
  assert.throws(() => createDeviceReconciler({ db: { query() {} } }), /publishCommand/);
});

// ======================================================================================================
// KOPRU ENTEGRASYONU (gercek MqttBridge + sahte istemci): hook'lar, yayin yolu, ana yolun bozulmamasi
// ======================================================================================================
const BR_TOPIC = 'h_0123456789abcdef';
const BR_HOME_ID = '11111111-1111-4111-8111-111111111111';
const BR_DEV = { home_id: BR_HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: 'AHBU-S3-0001' };

function makeBridgeWorld({ reconcile = true, reconciler } = {}) {
  const w = makeWorld();
  const home = w.addHome(BR_TOPIC, { requested: true });
  home.id = BR_HOME_ID;
  const dev = w.addDevice(BR_TOPIC, BR_DEV.device_uuid, { childLock: false });
  dev.id = BR_DEV.device_id;
  const db = makeFakeDb([
    { match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [BR_DEV], rowCount: 1 } }, // kopru cihaz eslemesi
  ]);
  // uzlastirici sorgulari (SQL sabitleri) dunyaya yonlendirilir
  const baseQuery = db.query;
  const route = (text, params) => (Object.values(SQL).includes(text) ? w.db.query(text, params) : baseQuery(text, params));
  db.query = route;
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const client = makeFakeClient();
  const bridge = new MqttBridge({
    db,
    logger,
    env: { MQTT_BACKEND_USER: 'u', MQTT_BACKEND_PASS: 'p' },
    now: () => w.now,
    timers,
    mqttLib: makeFakeMqttLib(client),
    reconcile,
    reconciler,
  });
  return { w, bridge, db, timers, logger, client, home, dev };
}

async function connectBridge(ctx) {
  ctx.bridge.init();
  ctx.client.connected = true;
  ctx.client.emit('connect', { sessionPresent: false });
  await flush();
}

const stateMsg = (obj) => Buffer.from(JSON.stringify(obj));

test('kopru: CANLI state COMMIT sonrasi uzlastiriciyi tetikler; yayin kopru yolundan (ev/{t}/cmd, QoS1, retain=false); ana yazimlar degismez', async () => {
  const ctx = makeBridgeWorld();
  await connectBridge(ctx);
  const mainWrites = () => ctx.db.calls.filter((c) => /^UPDATE /.test(c.text) && !Object.values(SQL).includes(c.text));

  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: false, relays: [{ id: 1, state: true }] }), { retain: false });
  assert.deepEqual(ctx.db.txLog, ['BEGIN', 'COMMIT']);
  assert.equal(mainWrites().length, 3, 'cihaz + role + ev kilit esitlemesi: ana yol ayni');
  assert.equal(ctx.timers.pendingTimeouts().length, 1, 'uzlastirici kontrol planladi');
  assert.equal(ctx.client.published.length, 0, 'henuz yayin yok (SETTLE)');

  const [h] = ctx.timers.pendingTimeouts();
  ctx.w.now += h.ms;
  ctx.timers.fireTimeout(h);
  await ctx.bridge._reconciler.whenIdle();
  await flush();

  assert.equal(ctx.client.published.length, 1);
  const p = ctx.client.published[0];
  assert.equal(p.topic, `ev/${BR_TOPIC}/cmd`);
  assert.deepEqual(p.opts, { qos: 1, retain: false });
  const cmd = JSON.parse(p.payload);
  assert.equal(cmd.cmd, 'set_child_lock');
  assert.equal(cmd.enabled, true);
  assert.match(cmd.id, CMD_ID_RE);
  assert.equal(ctx.bridge.getStatus().reconcile.published, 1);
  assert.equal(ctx.bridge.getStatus().reconcile.errors, 0, 'yerel anahtar turu dahil hicbir kontrol hata vermez');
  assert.ok(ctx.w.queries.some((q) => q.text === SQL.localKeyPending), 'kopru uzlastiricisinda yerel anahtar turu ACIK (publishSys)');
});

test('kopru: RETAINED state uzlastirmayi TETIKLEMEZ (canli oldugunu kanitlamaz); canli status offline donemi bitirir', async () => {
  const ctx = makeBridgeWorld();
  await connectBridge(ctx);
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: false }), { retain: true });
  assert.equal(ctx.timers.pendingTimeouts().length, 0);

  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: false }), { retain: false });
  assert.equal(ctx.timers.pendingTimeouts().length, 1);
  // retained 'offline' bayat olabilir: donemi bitirmez; canli 'offline' bitirir
  const rec = ctx.bridge._reconciler;
  const home = () => rec._homes.get(BR_TOPIC);
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/status`, Buffer.from('offline'), { retain: true });
  assert.equal(home().devices.size, 1);
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/status`, Buffer.from('offline'), { retain: false });
  assert.equal(home().devices.size, 0);
});

test('kopru: RESOLVE satirindaki bekleyen niyet + cihazin bildirdigi kilit uzlastiriciya EK SORGU OLMADAN iletilir', async () => {
  const calls = [];
  const spy = { onLiveState: (a) => calls.push(a), onOffline() {}, stop() {}, stats: () => ({}) };
  const ctx = makeBridgeWorld({ reconciler: spy });
  ctx.db.addRule({ match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [{ ...BR_DEV, child_lock_requested: true }], rowCount: 1 } });
  await connectBridge(ctx);
  const resolveCalls = () => ctx.db.calls.filter((c) => /FROM homes h LEFT JOIN devices d/.test(c.text)).length;

  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: true }), { retain: false });
  assert.deepEqual(calls[0], { topicId: BR_TOPIC, homeId: BR_HOME_ID, deviceId: BR_DEV.device_id, intent: true, reported: true });
  assert.equal(resolveCalls(), 1, 'ayni RESOLVE sorgusu: ek sorgu yok');

  // child_lock alani yoksa reported null; niyet satirda yoksa intent null
  ctx.db.addRule({ match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [BR_DEV], rowCount: 1 } });
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', relays: [{ id: 1, state: true }] }), { retain: false });
  assert.deepEqual(calls[1], { topicId: BR_TOPIC, homeId: BR_HOME_ID, deviceId: BR_DEV.device_id, intent: null, reported: null });
});

test('kopru: reconcile KAPALI (varsayilan) ornekte hicbir uzlastirici/zamanlayici olusmaz', async () => {
  const ctx = makeBridgeWorld({ reconcile: false });
  await connectBridge(ctx);
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: false }), { retain: false });
  assert.equal(ctx.bridge._reconciler, null);
  assert.equal(ctx.timers.pendingTimeouts().filter((t) => t.ms === SETTLE_MS).length, 0);
  assert.equal('reconcile' in ctx.bridge.getStatus(), false);
});

test('kopru: uzlastirici bildirimi PATLARSA mesaj isleme etkilenmez (sayac/veritabani yazimi ayni)', async () => {
  const boom = { onLiveState() { throw new Error('uzlastirici patladi'); }, onOffline() { throw new Error('x'); }, stop() {}, stats: () => ({}) };
  const ctx = makeBridgeWorld({ reconciler: boom });
  await connectBridge(ctx);
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: false, relays: [{ id: 1, state: true }] }), { retain: false });
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/status`, Buffer.from('offline'), { retain: false });
  assert.equal(ctx.bridge.counters.dbErrors, 0, 'uzlastirici hatasi veritabani hatasi sayilmamali');
  assert.deepEqual(ctx.db.txLog, ['BEGIN', 'COMMIT']);
  assert.ok(ctx.logger.lines.some((l) => /Uzlastirici bildirimi hatasi/.test(l)));
});

test('kopru: end() uzlastiriciyi durdurur (bekleyen zamanlayici iptal)', async () => {
  const ctx = makeBridgeWorld();
  await connectBridge(ctx);
  await ctx.bridge.handleIncomingMessage(`ev/${BR_TOPIC}/state`, stateMsg({ uid: 'AHBU-S3-0001', child_lock: false }), { retain: false });
  const before = ctx.timers.pendingTimeouts().filter((t) => t.ms === SETTLE_MS).length;
  assert.equal(before, 1);
  await ctx.bridge.end({ force: true, timeoutMs: 50 });
  assert.equal(ctx.timers.pendingTimeouts().filter((t) => t.ms === SETTLE_MS).length, 0);
});

test('tekil: uretim kopru ornegi (require) reconcile ACIK; test ornekleri kapali', () => {
  const singleton = require('../../src/mqtt_bridge');
  assert.equal(singleton._reconcileEnabled, true);
  assert.equal(new MqttBridge({ env: {} })._reconcileEnabled, false);
});
