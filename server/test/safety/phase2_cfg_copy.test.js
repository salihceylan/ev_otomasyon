'use strict';

// Faz 2 / WP-C2: yapilandirma kopyasinin (device_configs) tazelenmesi.
//   - KUSUR (Faz 2'de ortaya cikti): dakika sinirina takilan cfg_get bir daha istenmiyordu (sonraki state'ler ayni rev'i
//     tasidigi icin erken donus). Coklu yama (sihirbaz) sonrasi kopya kalici bayat kalirdi. Artik kopya dogrulanmadikca
//     dakikada en cok bir kez yeniden denenir.
//   - requestConfig({force}): yama/cakisma sonrasi dakika siniri yerine 5 sn taban araligiyla cfg_get (kopru ve REST).
//   - Bilgi push'u metni: cfg_pending_dropped.

const test = require('node:test');
const assert = require('node:assert/strict');

const { createAlarmService, helpers } = require('../../src/services/alarm_service');

const UID = 'AHBU-S3-1A2B3C';
const DEV = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function setup(copy = { rev: 4, crc: '00000004' }) {
  let t = 0;
  const sys = [];
  const db = {
    query: async (text) => {
      if (/^SELECT rev, crc FROM device_configs/.test(text)) return { rows: copy ? [copy] : [] };
      return { rows: [], rowCount: 0 };
    },
    withTransaction: async (fn) => fn({ query: db.query }),
  };
  const svc = createAlarmService({
    db,
    publishCommand: async () => {},
    publishSys: async (topicId, obj) => sys.push({ at: t, obj }),
    logger: { log() {}, warn() {}, error() {} },
    now: () => t,
  });
  return { svc, sys, set: (ms) => { t = ms; }, copy: (c) => { copy = c; } };
}

const sum = (rev) => ({ present: true, mode: 'normal', policy: 'on', cfg: { rev, crc: `0000000${rev}`.slice(-8) }, zones: [], zones_complete: true, sensors: [], actuators: [] });

async function live(svc, rev, prevRev) {
  await svc.onLiveState({ topicId: 'h_t', homeId: 'h', deviceId: DEV, uid: UID, caps: ['safety', 'cfg'], summary: sum(rev), prev: prevRev === undefined ? null : sum(prevRev), hadCaps: true });
  await svc.idle();
}

test('KUSUR: dakika sinirina takilan cfg_get, kopya dogrulanana kadar sonraki state\'te yeniden istenir', async () => {
  const h = setup();
  await live(h.svc, 5); // kopya 4, pano 5 -> cfg_get
  assert.equal(h.sys.length, 1);
  h.set(10_000);
  await live(h.svc, 6, 5); // 60 sn dolmadi -> bastirildi
  assert.equal(h.sys.length, 1);
  h.set(70_000);
  await live(h.svc, 6, 6); // ayni rev, ama kopya hala 4: yeniden istenmeli
  assert.equal(h.sys.length, 2, 'bayat kopya icin cfg_get yinelenir');
  h.copy({ rev: 6, crc: '00000006' });
  h.set(140_000);
  await live(h.svc, 6, 6);
  assert.equal(h.sys.length, 2, 'kopya eslesti: istek yok');
  h.set(300_000);
  await live(h.svc, 6, 6);
  assert.equal(h.sys.length, 2, 'dogrulanmis kopya icin DB bile sorgulanmaz');
});

test('requestConfig: force dakika sinirini 5 sn tabana indirir; force yoksa dakika siniri', async () => {
  const h = setup();
  assert.equal(await h.svc.requestConfig({ topicId: 'h_t', deviceId: DEV, uid: UID, force: true }), true);
  h.set(3_000);
  assert.equal(await h.svc.requestConfig({ topicId: 'h_t', deviceId: DEV, uid: UID, force: true }), false);
  h.set(6_000);
  assert.equal(await h.svc.requestConfig({ topicId: 'h_t', deviceId: DEV, uid: UID, force: true }), true);
  h.set(30_000);
  assert.equal(await h.svc.requestConfig({ topicId: 'h_t', deviceId: DEV, uid: UID }), false);
  assert.deepEqual(h.sys.map((x) => x.obj), [
    { cmd: 'cfg_get', module: 'safety', uid: UID },
    { cmd: 'cfg_get', module: 'safety', uid: UID },
  ]);
});

test('bilgi push\'u metni: cfg_pending_dropped', () => {
  const t = helpers.infoText('cfg_pending_dropped');
  assert.equal(t.title, 'Bekleyen yapılandırma iptal edildi');
  assert.match(t.body, /panodaki yapılandırma geçerli/);
});

// guvenlik-3: yapilandirilmamis (present:false) panoda da kopya istenir (firmware 1.3.1 cfg{rev,crc} yazar); caps 'cfg' sart
test('guvenlik-3: present:false (bos pano) + caps cfg -> kopya yoksa cfg_get istenir; caps cfg yoksa istenmez', async () => {
  const h = setup(null);
  const empty = { present: false, cfg: { rev: 0, crc: '00000000' } };
  await h.svc.onLiveState({ topicId: 'h_t', homeId: 'h', deviceId: DEV, uid: UID, caps: ['safety', 'cfg'], summary: empty, prev: null, hadCaps: true });
  await h.svc.idle();
  assert.deepEqual(h.sys.map((x) => x.obj), [{ cmd: 'cfg_get', module: 'safety', uid: UID }]);

  const h2 = setup(null);
  await h2.svc.onLiveState({ topicId: 'h_t', homeId: 'h', deviceId: DEV, uid: UID, caps: ['safety'], summary: empty, prev: null, hadCaps: true });
  await h2.svc.idle();
  assert.equal(h2.sys.length, 0, 'cfg yetenegi yok: istek yok');

  // ikinci (onbellekli) tur da ayni kosulu kullanir: kopya dogrulanana kadar dakikada bir
  h.set(70_000);
  await h.svc.onLiveState({ topicId: 'h_t', homeId: 'h', deviceId: DEV, uid: UID, caps: ['safety', 'cfg'], summary: empty, prev: empty, hadCaps: true });
  await h.svc.idle();
  assert.equal(h.sys.length, 2);
});
