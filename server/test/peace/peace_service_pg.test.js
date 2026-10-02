'use strict';

// WP-H / peace_service - GERCEK PostgreSQL ile (KAPILI: EV_PG_TEST_URL yoksa ATLANIR; `npm test` PostgreSQL gerektirmez).
//
// Hermetik peace_service.test.js sahte db kullanir; SQL'in PostgreSQL'de gecerli olup olmadigini, durum kisitinin
// (claimed/failed/... satirina dokunmama), ev korumasinin, es zamanli cozumlemenin ve transaction geri almanin
// KANITI degildir. Bu dosya GERCEK SQL metinlerini (peace_service.SQL.*, peace_snapshot.SQL.*) gercek veritabaninda
// calistirir; yalnizca MQTT yayinci ve komut kimligi uretici sahtedir. Calistirma: bkz. _pg_helpers.js.

const test = require('node:test');
const assert = require('node:assert/strict');

const { createPeaceService } = require('../../src/services/peace_service');
const { httpError } = require('../../src/utils/http_errors');
const { PG_SKIP, silent, closePool, auditLikeDeviceService, withPgFixture, pgFixture, getDb, OPEN_ENDPOINTS } = require('./_pg_helpers');

test.after(closePool);

const opts = { skip: PG_SKIP };

function makeService(db, { publish, audit } = {}) {
  const published = [];
  let n = 0;
  const svc = createPeaceService({
    db,
    publishCommand: publish || (async (topic, payload) => { published.push({ topic, payload }); }),
    newCommandId: () => `pgc${String(++n).padStart(3, '0')}`,
    audit: audit || auditLikeDeviceService,
    httpError,
    sleep: async () => {},
    logger: silent,
  });
  return { svc, published };
}

const actorOf = (fx) => ({ userId: fx.userId, globalRole: 'user', access: 'owner', ip: '203.0.113.7' });

async function addNotice(db, homeId, date, status, { lights = 2, shutters = 1 } = {}) {
  return (
    await db.query(
      `INSERT INTO peace_notification_logs (home_id, local_date, status, open_lights_count, open_shutters_count, summary_text, push_sent_count)
       VALUES ($1, $2::date, $3, $4, $5, 'Salonda 2 lamba, 1 panjur açık.', 1) RETURNING id`,
      [homeId, date, status, lights, shutters]
    )
  ).rows[0].id;
}

const noticeRow = async (db, id) =>
  (await db.query('SELECT status, resolved_at, resolved_by_user, resolved_by_user_id, resolved_via, command_id FROM peace_notification_logs WHERE id = $1', [id])).rows[0];
const manualRows = async (db, homeId) =>
  (await db.query("SELECT * FROM peace_notification_logs WHERE home_id = $1 AND status = 'manual' ORDER BY id", [homeId])).rows;
const auditRows = async (db, homeId) =>
  (await db.query("SELECT event, actor_user_id, actor_role, details FROM device_audit_logs WHERE home_id = $1 AND event = 'peace_close_all' ORDER BY id", [homeId])).rows;

// ------------------------------------------------------------------------------
// getSettings
// ------------------------------------------------------------------------------
test('PG getSettings: canli cihaz -> v2 sekli, acik lamba/panjur, last_notice yalniz gorunur durumlardan (DATE metin kalir)', opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 10, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const { svc } = makeService(db);

    const empty = await svc.getSettings({ homeId: fx.homeId });
    assert.equal(empty.home_id, fx.homeId);
    assert.equal(empty.enabled, true);
    assert.equal(empty.time, '23:30');
    assert.equal(empty.peace_notification_enabled, true);
    assert.equal(empty.peace_notification_time, '23:30');
    assert.equal(empty.timezone, 'Europe/Istanbul');
    assert.equal(empty.devices_total, 1);
    assert.equal(empty.devices_online, 1);
    assert.equal(empty.stale, false);
    assert.equal(empty.open_lights_count, 2);
    assert.equal(empty.open_shutters_count, 1);
    assert.deepEqual(empty.open_lights.map((l) => l.channel_index).sort(), [3, 4]);
    assert.ok(empty.open_lights.every((l) => l.room === 'Salon' && typeof l.id === 'string'));
    assert.deepEqual(empty.open_shutters, [{ pair: 1, room: 'Salon', position: 100 }]);
    assert.match(empty.summary_text, /Salon/);
    assert.equal(empty.last_notice, null);

    await addNotice(db, fx.homeId, '2026-09-29', 'resolved');
    const sentId = await addNotice(db, fx.homeId, '2026-09-30', 'sent');
    await addNotice(db, fx.homeId, '2026-10-01', 'claimed'); // gorunur degil (degerlendirici sahipliginde)
    await db.query("INSERT INTO peace_notification_logs (home_id, status) VALUES ($1, 'manual')", [fx.homeId]); // local_date NULL: gorunmez

    const withNotice = await svc.getSettings({ homeId: fx.homeId });
    assert.equal(withNotice.last_notice.id, sentId);
    assert.equal(withNotice.last_notice.local_date, '2026-09-30', 'DATE saat dilimiyle kaymaz');
    assert.equal(withNotice.last_notice.status, 'sent');
    assert.equal(withNotice.last_notice.open_lights_count, 2);
    assert.equal(withNotice.last_notice.open_shutters_count, 1);
    assert.equal(withNotice.last_notice.resolved_at, null);
    assert.match(withNotice.last_notice.created_at, /^\d{4}-\d{2}-\d{2}T/);
  });
});

test('PG getSettings: bayat cihaz -> stale, sayilar 0 (bilinmiyor); bilinmeyen ev 404; closeAll bayatta 409 DEVICE_OFFLINE', opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 600, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    const s = await svc.getSettings({ homeId: fx.homeId });
    assert.equal(s.stale, true);
    assert.equal(s.devices_online, 0);
    assert.equal(s.open_lights_count, 0);
    assert.deepEqual(s.open_lights, []);

    await assert.rejects(svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId }), (e) => e.status === 409 && e.code === 'DEVICE_OFFLINE' && e.extra && e.extra.device_online === false);
    assert.equal(published.length, 0, 'bayatta komut yayinlanmaz');
    assert.deepEqual(await manualRows(db, fx.homeId), []);

    await assert.rejects(svc.getSettings({ homeId: '00000000-0000-4000-8000-00000000dead' }), (e) => e.status === 404 && e.code === 'NOT_FOUND');
  });
});

test('PG closeAll: cihazsiz ev -> 404 (yayin yok)', opts, async () => {
  await withPgFixture({ devices: [] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    await assert.rejects(svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId }), (e) => e.status === 404 && e.code === 'NOT_FOUND');
    assert.equal(published.length, 0);
  });
});

// ------------------------------------------------------------------------------
// closeAll: komutlar, cozumleme, denetim
// ------------------------------------------------------------------------------
test('PG closeAll: all_lights_off + panjur down yayinlanir; bildirim COZULUR (resolveNotice), denetim kaydi yazilir', opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    const noticeId = await addNotice(db, fx.homeId, '2026-10-01', 'sent');

    const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId });
    assert.equal(r.closed_lights, 2);
    assert.equal(r.closed_shutters, 1);
    assert.equal(r.skipped_count, 0);
    assert.equal(r.nothing_to_do, false);
    assert.equal(r.resolved, true);
    assert.equal(r.notice_id, noticeId);
    assert.deepEqual(r.command_ids, ['pgc001', 'pgc002']);
    assert.equal(r.command_id, 'pgc001');

    assert.deepEqual(published, [
      { topic: fx.topic, payload: { cmd: 'all_lights_off', id: 'pgc001' } },
      { topic: fx.topic, payload: { shutter: 1, cmd: 'down', id: 'pgc002' } },
    ]);

    const row = await noticeRow(db, noticeId);
    assert.equal(row.status, 'resolved');
    assert.equal(row.resolved_by_user, true);
    assert.equal(row.resolved_by_user_id, fx.userId);
    assert.equal(row.resolved_via, 'close_all');
    assert.equal(row.command_id, 'pgc001');
    assert.ok(row.resolved_at instanceof Date);
    assert.deepEqual(await manualRows(db, fx.homeId), [], 'bildirim cozuldu -> elle satir yok');

    const audits = await auditRows(db, fx.homeId);
    assert.equal(audits.length, 1);
    assert.equal(audits[0].actor_user_id, fx.userId);
    assert.equal(audits[0].actor_role, 'user'); // _audit: globalRole || access
    assert.equal(audits[0].details.notice_id, noticeId);
    assert.equal(audits[0].details.resolved, true);
    assert.deepEqual(audits[0].details.command_ids, ['pgc001', 'pgc002']);
  });
});

test("PG closeAll: durum kisiti - yalniz sent/no_recipients/sending cozulur; claimed/failed/skipped_offline/clear'a DOKUNULMAZ (elle satir eklenir)", opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const { svc } = makeService(db);
    const cases = [
      ['2026-09-20', 'sent', true],
      ['2026-09-21', 'no_recipients', true],
      ['2026-09-22', 'sending', true],
      ['2026-09-23', 'claimed', false],
      ['2026-09-24', 'failed', false],
      ['2026-09-25', 'skipped_offline', false],
      ['2026-09-26', 'clear', false],
      ['2026-09-27', 'resolved', false], // zaten cozulmus: ikinci kez cozulmez
    ];
    let expectedManual = 0;
    for (const [date, status, resolvable] of cases) {
      const id = await addNotice(db, fx.homeId, date, status);
      const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId: id });
      assert.equal(r.resolved, resolvable, `${status}: resolved`);
      assert.equal(r.notice_id, resolvable ? id : null, `${status}: notice_id`);
      const row = await noticeRow(db, id);
      assert.equal(row.status, resolvable ? 'resolved' : status, `${status}: yeni durum`);
      if (!resolvable) {
        assert.equal(row.resolved_via, null, `${status}: dokunulmadi`);
        expectedManual += 1;
      }
    }
    const manual = await manualRows(db, fx.homeId);
    assert.equal(manual.length, expectedManual, 'cozulemeyen her tiklama icin ayri elle satir (local_date NULL: UNIQUE ile cakismaz)');
    assert.ok(manual.every((m) => m.local_date === null && m.resolved_via === 'close_all' && m.resolved_by_user === true && m.open_lights_count === 2 && m.open_shutters_count === 1));
    assert.equal(manual[0].summary_text, '2 lamba ve 1 panjur tek tıkla kapatıldı.');
  });
});

test('PG closeAll: notice_id verilmezse evin EN YENI cozulebilir bildirimi cozulur; baska evin bildirimi asla', opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: [] }] }, async ({ fx: other }) => {
      const { svc } = makeService(db);
      const old = await addNotice(db, fx.homeId, '2026-09-28', 'sent');
      const newest = await addNotice(db, fx.homeId, '2026-09-30', 'no_recipients');
      const claimed = await addNotice(db, fx.homeId, '2026-10-01', 'claimed'); // en yeni ama cozulemez
      const foreign = await addNotice(db, other.homeId, '2026-10-01', 'sent');

      const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId });
      assert.equal(r.notice_id, newest);
      assert.equal((await noticeRow(db, newest)).status, 'resolved');
      assert.equal((await noticeRow(db, old)).status, 'sent');
      assert.equal((await noticeRow(db, claimed)).status, 'claimed');

      // baska evin kimligi verilirse: cozulmez, kendi evine elle satir yazilir
      const r2 = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId: foreign });
      assert.equal(r2.resolved, false);
      assert.equal((await noticeRow(db, foreign)).status, 'sent', 'baska evin kaydina dokunulmaz');
    });
  });
});

test('PG closeAll: ES ZAMANLI iki tiklama ayni bildirimi cozer -> tam BIR kazanan, digeri elle satir', opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const noticeId = await addNotice(db, fx.homeId, '2026-10-01', 'sent');
    const a = makeService(db);
    const b = makeService(db);
    const [ra, rb] = await Promise.all([
      a.svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId }),
      b.svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId }),
    ]);
    assert.equal([ra, rb].filter((r) => r.resolved).length, 1, 'tek kazanan');
    assert.equal((await noticeRow(db, noticeId)).status, 'resolved');
    assert.equal((await manualRows(db, fx.homeId)).length, 1, 'kaybeden elle satir yazar');
    assert.equal((await auditRows(db, fx.homeId)).length, 2, 'iki tiklama da denetimde');
  });
});

test('PG closeAll: kayit transaction\'i hata verirse (denetim) cozumleme GERI ALINIR; komutlar iletildigi icin yanit basarili, resolved:false', opts, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const noticeId = await addNotice(db, fx.homeId, '2026-10-01', 'sent');
    const { svc, published } = makeService(db, {
      audit: async (q) => {
        await q('SELECT 1'); // transaction icinde
        throw new Error('denetim yazilamadi (test)');
      },
    });
    const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId });
    assert.equal(published.length, 2, 'komutlar iletildi');
    assert.equal(r.resolved, false);
    assert.equal(r.notice_id, null);
    assert.equal(r.closed_lights, 2);
    assert.equal((await noticeRow(db, noticeId)).status, 'sent', 'UPDATE geri alindi: yarim kayit yok');
    assert.deepEqual(await manualRows(db, fx.homeId), []);
  });
});

test('PG closeAll: acik bir sey yoksa komut YOK ama bildirim cozulur (nothing_to_do); elle satir yazilmaz', opts, async () => {
  const closed = [
    { ch: 1, type: 'shutter', room: 'Salon', pos: 0 },
    { ch: 2, type: 'shutter', room: 'Salon', pos: 0 },
    { ch: 3, type: 'light', room: 'Salon', on: false },
  ];
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: closed }] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    const noticeId = await addNotice(db, fx.homeId, '2026-10-01', 'sent', { lights: 1, shutters: 0 });
    const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId });
    assert.equal(published.length, 0);
    assert.equal(r.nothing_to_do, true);
    assert.equal(r.resolved, true);
    assert.equal(r.command_id, null);
    assert.equal(r.closed_lights + r.closed_shutters, 0);
    assert.equal((await noticeRow(db, noticeId)).status, 'resolved');
    assert.equal((await noticeRow(db, noticeId)).command_id, null);
    assert.deepEqual(await manualRows(db, fx.homeId), []);
  });
});

// ------------------------------------------------------------------------------
// priz korumasi ve cok panolu ev (SQL.hasPlug, SQL.layout)
// ------------------------------------------------------------------------------
test('PG closeAll: evde priz varsa all_lights_off KULLANILMAZ; yalniz acik isik roleleri tek tek kapanir (SQL.hasPlug)', opts, async () => {
  const eps = [
    { ch: 3, type: 'light', room: 'Salon', on: true },
    { ch: 4, type: 'plug', room: 'Salon', on: true },
    { ch: 5, type: 'light', room: 'Mutfak', on: false },
  ];
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: eps }] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId });
    assert.deepEqual(published.map((p) => p.payload), [{ relay: 3, state: false, id: 'pgc001' }]);
    assert.equal(r.closed_lights, 1);
    assert.equal(r.closed_shutters, 0);
    assert.equal((await manualRows(db, fx.homeId)).length, 1, 'cozulecek bildirim yok -> elle satir');
  });
});

test('PG closeAll: cok panolu ev - ayni kanalda baska panoda PRIZ varsa o lamba kapatilmaz (skipped_count, bildirim cozulmez, SQL.layout)', opts, async () => {
  const devA = { online: true, seenSecAgo: 5, endpoints: [{ ch: 3, type: 'light', room: 'Salon', on: true }] };
  const devB = { online: true, seenSecAgo: 5, endpoints: [{ ch: 3, type: 'plug', room: 'Mutfak', on: true }] };
  await withPgFixture({ devices: [devA, devB] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    const noticeId = await addNotice(db, fx.homeId, '2026-10-01', 'sent', { lights: 1, shutters: 0 });
    const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, noticeId, includeShutters: false });
    assert.equal(published.length, 0, 'priz kapanmasin');
    assert.equal(r.closed_lights, 0);
    assert.equal(r.skipped_count, 1);
    assert.equal(r.nothing_to_do, false);
    assert.equal(r.resolved, false, 'atlanan oge varken bildirim cozulmez');
    assert.match(r.message, /ortak bağlantısı/);
    assert.equal((await noticeRow(db, noticeId)).status, 'sent');
  });
});

test('PG closeAll: cok panolu ev - ayni kanal iki panoda da ISIK ise tek relay komutu yeter, iki lamba sayilir', opts, async () => {
  const devA = {
    online: true,
    seenSecAgo: 5,
    endpoints: [
      { ch: 3, type: 'light', room: 'Salon', on: true },
      { ch: 7, type: 'plug', room: 'Salon', on: true }, // priz: toplu all_lights_off yerine tek tek yola zorlar
    ],
  };
  const devB = { online: true, seenSecAgo: 5, endpoints: [{ ch: 3, type: 'light', room: 'Yatak', on: true }] };
  await withPgFixture({ devices: [devA, devB] }, async ({ db, fx }) => {
    const { svc, published } = makeService(db);
    const r = await svc.closeAll({ actor: actorOf(fx), homeId: fx.homeId, includeShutters: false });
    assert.deepEqual(published.map((p) => p.payload), [{ relay: 3, state: false, id: 'pgc001' }]);
    assert.equal(r.closed_lights, 2);
    assert.equal(r.skipped_count, 0);
  });
});

test('PG getSettings: yalniz bir pano canli, digeri bayat -> canli panonun verisi sayilir, bayat panonun lambasi sayilmaz', opts, async () => {
  const live = { online: true, seenSecAgo: 5, endpoints: [{ ch: 3, type: 'light', room: 'Salon', on: true }] };
  const stale = { online: false, seenSecAgo: 3600, endpoints: [{ ch: 4, type: 'light', room: 'Yatak', on: true }] };
  await withPgFixture({ devices: [live, stale] }, async ({ db, fx }) => {
    const { svc } = makeService(db);
    const s = await svc.getSettings({ homeId: fx.homeId });
    assert.equal(s.devices_total, 2);
    assert.equal(s.devices_online, 1);
    assert.equal(s.stale, false);
    assert.equal(s.open_lights_count, 1, 'bayat panonun lambasi sayilmaz');
  });
});

// ------------------------------------------------------------------------------
// Kendi baglantisi: iki ayri ev birbirinin kaydini gormez
// ------------------------------------------------------------------------------
test('PG: iki ev birbirinin ayar/son bildirimini gormez', opts, async () => {
  const db = getDb();
  const a = await pgFixture(db, { devices: [{ online: true, seenSecAgo: 5, endpoints: OPEN_ENDPOINTS }] });
  const b = await pgFixture(db, { devices: [{ online: true, seenSecAgo: 5, endpoints: [] }] });
  try {
    const { svc } = makeService(db);
    await addNotice(db, a.homeId, '2026-10-01', 'sent');
    const sb = await svc.getSettings({ homeId: b.homeId });
    assert.equal(sb.last_notice, null);
    assert.equal(sb.open_lights_count, 0);
    const sa = await svc.getSettings({ homeId: a.homeId });
    assert.ok(sa.last_notice);
  } finally {
    await a.cleanup();
    await b.cleanup();
  }
});
