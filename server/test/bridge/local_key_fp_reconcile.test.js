'use strict';

// pano-5 (g): yerel anahtar takasi panoda DOGRULANIR (firmware 1.3.1 lk_fp).
//  - fp bildiren panoda (devices.local_key_fp dolu) PUBACK'te takas YAPILMAZ; state'te bekleyen anahtarin izi gorulunce
//    CAS takas (current = pending, pending = NULL; envanter; denetim local_key_rotated {via:'state'})
//  - 30 sn icinde onay gelmezse deneme sayilir (ustel bekleme, MAX_ATTEMPTS) ve yeniden yayinlanir
//  - fp'siz (eski firmware) panoda eski davranis (PUBACK'te CAS takas); ESKI anahtar SAKLANMAZ (inceleme: eski anahtari
//    bilen kisi bootstrap / iz ile rotasyonu geri aldiramaz)
//  - takastan sonra pano ESKI anahtarin izini bildirirse geri donus YOK: uyumsuzluk kaydi (kurtarma: RESETKEY + FACTORYINIT)
//  - hicbirine uymayan fp -> (cihaz, fp) basina BIR kez uyari + denetim local_key_mismatch (anahtarsiz)
//  - cok panolu evde yalniz "fp == pending -> takas" ve uyumsuzluk kaydi; yeniden yayin YOK
//  - degismeyen fp ve bekleyen onay yokken veritabanina gidilmez

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
const secretBox = require('../../src/utils/secret_box');
const { localKeyFingerprint } = require('../../src/utils/local_key_fp');

const { KeyedWorkQueue } = require('../../src/mqtt_bridge');
const { createDeviceReconciler, SQL, constants } = require('../../src/services/device_reconciler');
const { makeFakeTimers, makeLogger } = require('./_helpers');

const { SETTLE_MS, BACKOFF_BASE_MS, MAX_ATTEMPTS } = constants;
const T0 = Date.parse('2026-10-08T12:00:00Z');
const TOPIC = 'h_bbbbbbbbbbbbbbbb';
const OLD = 'EskiAnahtar1234567';
const NEW = 'YeniAnahtar9876543';

function makeWorld() {
  const w = { now: T0, homeId: crypto.randomUUID(), devices: [], inventory: new Map(), audits: [], queries: [], sys: [], failSys: false };
  w.addDevice = (uuid, { fp = null, current = OLD, pending = null, prev = null, prevValid = true, live = true } = {}) => {
    const d = {
      id: crypto.randomUUID(), uuid, live, fp,
      currentEnc: secretBox.encrypt(current),
      pendingEnc: pending ? secretBox.encrypt(pending) : null,
      prevEnc: prev ? secretBox.encrypt(prev) : null,
      prevUntil: prev ? new Date(w.now + (prevValid ? 86400000 : -1000)) : null,
    };
    w.devices.push(d);
    w.inventory.set(uuid, { id: crypto.randomUUID(), enc: d.currentEnc });
    return d;
  };
  const byId = (id) => w.devices.find((x) => x.id === id);
  w.db = {
    async query(text, params) {
      w.queries.push({ text, params });
      switch (text) {
        case SQL.childLock:
        case SQL.runtimePending:
          return { rows: [] };
        case SQL.localKeyPending:
          return {
            rows: w.devices.filter((d) => d.pendingEnc).map((d) => ({
              home_id: w.homeId, device_id: d.id, device_uuid: d.uuid, pending_enc: d.pendingEnc, live: d.live,
              device_count: w.devices.length, key_fp: d.fp,
            })),
          };
        case SQL.localKeyRow: {
          const d = byId(params[0]);
          if (!d) return { rows: [] };
          return {
            rows: [{
              device_id: d.id, device_uuid: d.uuid, home_id: w.homeId, current_enc: d.currentEnc, pending_enc: d.pendingEnc,
              prev_enc: d.prevEnc && d.prevUntil && d.prevUntil.getTime() > w.now ? d.prevEnc : null, device_count: w.devices.length,
            }],
          };
        }
        case SQL.localKeyLockInventory: {
          const inv = w.inventory.get(params[0]);
          return { rows: inv ? [{ id: inv.id }] : [] };
        }
        case SQL.localKeySwap: { // CAS takas (PUBACK ya da iz onayi); SQL onceki anahtari yaziyorsa sahte db de yazar
          const d = byId(params[0]);
          if (!d || d.pendingEnc !== params[1]) return { rows: [], rowCount: 0 };
          if (/local_key_prev_enc = CASE/.test(text) && d.currentEnc !== d.pendingEnc) {
            d.prevEnc = d.currentEnc;
            d.prevUntil = new Date(w.now + 30 * 86400000);
          }
          if (/local_key_prev_enc = NULL/.test(text)) {
            d.prevEnc = null;
            d.prevUntil = null;
          }
          d.currentEnc = d.pendingEnc;
          d.pendingEnc = null;
          return { rows: [], rowCount: 1 };
        }
        case SQL.localKeySwapConfirmed: { // (eski kod) iz onayli takas: onceki anahtar temizlenir
          const d = byId(params[0]);
          if (!d || d.pendingEnc !== params[1]) return { rows: [], rowCount: 0 };
          d.currentEnc = d.pendingEnc;
          d.pendingEnc = null;
          d.prevEnc = null;
          d.prevUntil = null;
          return { rows: [], rowCount: 1 };
        }
        case SQL.localKeyRevert: { // (eski kod) [id, prevEnc, oldCurrentEnc]
          const d = byId(params[0]);
          if (!d || d.currentEnc !== params[2]) return { rows: [], rowCount: 0 };
          d.currentEnc = params[1];
          d.pendingEnc = d.pendingEnc || params[2];
          d.prevEnc = null;
          d.prevUntil = null;
          return { rows: [], rowCount: 1 };
        }
        case SQL.localKeyInventory: {
          const inv = w.inventory.get(params[0]);
          if (inv) inv.enc = params[1];
          return { rows: [], rowCount: inv ? 1 : 0 };
        }
        case SQL.localKeyAudit:
          w.audits.push({ event: 'local_key_rotated', uuid: params[0], details: JSON.parse(params[2]) });
          return { rows: [], rowCount: 1 };
        case SQL.localKeyAuditEvent:
          w.audits.push({ event: params[0], uuid: params[1], details: JSON.parse(params[3]) });
          return { rows: [], rowCount: 1 };
        default:
          throw new Error(`beklenmeyen sorgu: ${String(text).slice(0, 80)}`);
      }
    },
    async withTransaction(fn) {
      return fn({ query: (t, p) => w.db.query(t, p) });
    },
  };
  w.publishSys = async (topic, obj) => {
    if (w.failSys) throw Object.assign(new Error('broker down'), { code: 'BROKER_UNAVAILABLE' });
    w.sys.push({ topic, obj: JSON.parse(JSON.stringify(obj)) });
    return {};
  };
  return w;
}

function makeRec(w) {
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const rec = createDeviceReconciler({
    db: w.db,
    publishCommand: async () => { throw new Error('cmd yayini beklenmiyordu'); },
    publishSys: w.publishSys,
    secretBox,
    isConnected: () => true,
    logger,
    now: () => w.now,
    timers,
    offlineAfterSec: 120,
    QueueClass: KeyedWorkQueue,
    sleep: async () => {},
  });
  return { rec, timers, logger };
}

const live = (rec, w, d) => rec.onLiveState({ topicId: TOPIC, homeId: w.homeId, deviceId: d.id });
const fpState = (rec, w, d, fp, changed = true) => rec.onLocalKeyFp({ topicId: TOPIC, homeId: w.homeId, deviceId: d.id, fp, changed });

async function fireNext(w, rec, timers, expectedDelay) {
  const pending = timers.pendingTimeouts();
  assert.equal(pending.length, 1, `tam bir zamanlayici bekleniyordu (${pending.length})`);
  const [h] = pending;
  if (expectedDelay !== undefined) assert.equal(h.ms, expectedDelay, 'zamanlayici suresi');
  w.now += h.ms;
  timers.fireTimeout(h);
  await rec.whenIdle();
}

function noSecrets(logger) {
  for (const line of logger.lines) {
    assert.ok(!line.includes(OLD) && !line.includes(NEW), `anahtar log'a yazilmis: ${line}`);
  }
}

test('fp bildiren pano: PUBACK te takas YOK; state te bekleyen anahtarin izi gorulunce CAS takas (via state)', async () => {
  const w = makeWorld();
  const d = w.addDevice('AHBU-S3-FP0001', { fp: localKeyFingerprint(OLD, 'AHBU-S3-FP0001'), pending: NEW });
  const pendingEnc = d.pendingEnc;
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, d);
  await fireNext(w, rec, timers, SETTLE_MS);
  assert.equal(w.sys.length, 1, 'yayin yapildi');
  assert.equal(w.sys[0].obj.local_key, NEW);
  assert.equal(d.pendingEnc, pendingEnc, 'PUBACK te takas YOK (pano dogrulamadi)');
  assert.ok(!w.queries.some((q) => q.text === SQL.localKeySwap));
  assert.equal(w.audits.length, 0);

  // pano yeni anahtari uyguladi: state lk_fp = fp(NEW)
  fpState(rec, w, d, localKeyFingerprint(NEW, 'AHBU-S3-FP0001'));
  await rec.whenIdle();
  assert.equal(d.currentEnc, pendingEnc, 'gecerli = bekleyen');
  assert.equal(d.pendingEnc, null);
  assert.equal(d.prevEnc, null, 'onceki anahtar saklanmaz');
  assert.equal(w.inventory.get('AHBU-S3-FP0001').enc, pendingEnc, 'envanter ayni deger');
  assert.deepEqual(w.audits.map((a) => [a.event, a.details.via]), [['local_key_rotated', 'state']]);
  assert.ok(!JSON.stringify(w.audits).includes(NEW));
  noSecrets(logger);
});

test('onay 30 sn icinde gelmezse deneme sayilir; ustel bekleme sonrasi yeniden yayin; MAX_ATTEMPTS sonra durur', async () => {
  const w = makeWorld();
  const d = w.addDevice('AHBU-S3-FP0002', { fp: localKeyFingerprint(OLD, 'AHBU-S3-FP0002'), pending: NEW });
  const { rec, timers } = makeRec(w);
  live(rec, w, d);
  await fireNext(w, rec, timers, SETTLE_MS);
  assert.equal(w.sys.length, 1);
  for (let i = 1; i < MAX_ATTEMPTS; i++) {
    await fireNext(w, rec, timers, 30 * 1000); // onay penceresi doldu: deneme sayilir, bekleme planlanir
    await fireNext(w, rec, timers, BACKOFF_BASE_MS * 2 ** (i - 1)); // ustel bekleme sonrasi yeniden yayin
    assert.equal(w.sys.length, i + 1, `yeniden yayin ${i + 1}`);
  }
  await fireNext(w, rec, timers, 30 * 1000);
  const after = w.sys.length;
  // deneme hakki bitti: yeni yayin yok
  for (const h of timers.pendingTimeouts()) {
    w.now += h.ms;
    timers.fireTimeout(h);
    await rec.whenIdle();
  }
  assert.equal(w.sys.length, after, 'hak bitince yeniden yayin yok');
  assert.ok(d.pendingEnc, 'bekleyen korunur');
});

test('fp siz (eski firmware) pano: PUBACK sonrasi CAS takas; ESKI anahtar SAKLANMAZ (takas SQL i onceki anahtari yazmaz)', async () => {
  const w = makeWorld();
  const d = w.addDevice('AHBU-S3-OLD001', { fp: null, pending: NEW });
  const { rec, timers } = makeRec(w);
  live(rec, w, d);
  await fireNext(w, rec, timers, SETTLE_MS);
  assert.equal(w.sys.length, 1);
  assert.equal(d.pendingEnc, null, 'PUBACK te takas');
  assert.equal(secretBox.decrypt(d.currentEnc), NEW);
  assert.equal(secretBox.decrypt(w.inventory.get('AHBU-S3-OLD001').enc), NEW, 'envanter yeni anahtar');
  assert.equal(d.prevEnc, null, 'eski anahtar saklanmaz');
  assert.doesNotMatch(SQL.localKeySwap, /local_key_prev/);
  assert.deepEqual(w.audits.map((a) => [a.event, a.details.via]), [['local_key_rotated', 'reconciler']]);
});

test('takastan sonra pano ESKI anahtarin izini bildirirse GERI DONUS YOK: anahtarlar degismez, uyumsuzluk bir kez denetlenir', async () => {
  const w = makeWorld();
  const d = w.addDevice('AHBU-S3-REV001', { fp: null, pending: NEW });
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, d);
  await fireNext(w, rec, timers, SETTLE_MS); // eski firmware: PUBACK te takas
  const newEnc = d.currentEnc;
  assert.equal(secretBox.decrypt(newEnc), NEW);
  // pano anahtari aslinda almadi (ya da eski anahtari bilen biri iz uyduruyor): eski iz
  fpState(rec, w, d, localKeyFingerprint(OLD, 'AHBU-S3-REV001'));
  await rec.whenIdle();
  assert.equal(d.currentEnc, newEnc, 'gecerli anahtar eskiye DONMEZ');
  assert.equal(d.pendingEnc, null);
  assert.equal(w.inventory.get('AHBU-S3-REV001').enc, newEnc);
  assert.equal(w.audits.filter((a) => a.event === 'local_key_reverted').length, 0);
  assert.equal(w.audits.filter((a) => a.event === 'local_key_mismatch').length, 1);
  assert.ok(!w.queries.some((q) => /local_key_prev/.test(q.text)), 'onceki anahtar sorgulanmaz');
  noSecrets(logger);
});

test('hicbirine uymayan fp: (cihaz, fp) basina BIR kez uyari + local_key_mismatch denetimi (anahtar yok); anahtarlar degismez', async () => {
  const w = makeWorld();
  const d = w.addDevice('AHBU-S3-MIS001', { fp: null, current: OLD });
  const before = d.currentEnc;
  const { rec, logger } = makeRec(w);
  fpState(rec, w, d, 'deadbeef');
  await rec.whenIdle();
  fpState(rec, w, d, 'deadbeef');
  await rec.whenIdle();
  assert.equal(d.currentEnc, before);
  assert.equal(w.audits.filter((a) => a.event === 'local_key_mismatch').length, 1, 'bir kez');
  assert.equal(logger.lines.filter((l) => /yerel_anahtar .*uyumsuz/.test(l)).length, 1, logger.lines.join('\n'));
  assert.ok(!JSON.stringify(w.audits).includes(OLD));
  // iz panonun gecerli anahtarina uyuyorsa sessiz
  fpState(rec, w, d, localKeyFingerprint(OLD, 'AHBU-S3-MIS001'));
  await rec.whenIdle();
  assert.equal(w.audits.length, 1);
});

test('cok panolu ev: fp == pending -> takas calisir; geri donus YAPILMAZ (uyumsuzluk kaydi)', async () => {
  const w = makeWorld();
  const a = w.addDevice('AHBU-S3-MUL001', { fp: 'aaaaaaaa', pending: NEW });
  const b = w.addDevice('AHBU-S3-MUL002', { fp: null, current: NEW });
  const { rec } = makeRec(w);
  fpState(rec, w, a, localKeyFingerprint(NEW, 'AHBU-S3-MUL001'));
  await rec.whenIdle();
  assert.equal(a.pendingEnc, null, 'pending izi -> takas');
  const bCurrent = b.currentEnc;
  fpState(rec, w, b, localKeyFingerprint(OLD, 'AHBU-S3-MUL002'));
  await rec.whenIdle();
  assert.equal(b.currentEnc, bCurrent, 'eski iz: anahtar degismez');
  assert.ok(w.audits.some((x) => x.event === 'local_key_mismatch' && x.uuid === 'AHBU-S3-MUL002'));
});

test('degismeyen fp ve bekleyen onay yokken veritabanina gidilmez', async () => {
  const w = makeWorld();
  const d = w.addDevice('AHBU-S3-IDL001', { fp: 'cccccccc' });
  const { rec } = makeRec(w);
  fpState(rec, w, d, 'cccccccc', false);
  await rec.whenIdle();
  assert.equal(w.queries.length, 0);
});
