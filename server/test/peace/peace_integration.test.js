'use strict';

// WP-H / integrator - GERCEK peace_text + GERCEK push_service + GERCEK PeaceReminder birlikte.
//
// Sahte olanlar yalnizca sinirlardir: veritabani (evaluator'in _helpers.js dunyasi + push token
// deposu, SQL semantigini JS ile taklit eder), fetch (FCM), authFactory (Google kimligi), saat ve
// zamanlayicilar. Ag / gercek DB / gercek FCM YOKTUR. Amac, uc modulun arayuzlerinin (isimler,
// arguman/donus bicimleri, yalniz-string FCM data, durum degerleri <-> migration CHECK, kolon
// adlari <-> migration) birbirine UYDUGUNU uctan uca kanitlamaktir.
//
// Bolum 10 GERCEK PostgreSQL ister ve varsayilan olarak ATLANIR (EV_PG_TEST_URL, bkz. test/bridge/
// pg_integration.test.js): JS sahte db'si SQL'in gecerliligini/atomikligini KANITLAMAZ. Bolum 11,
// kilitli dosyalardaki entegrasyon adimlari (CONTRACTS, .env.example, server.js, device_service.js)
// yapilana kadar `todo` olarak raporlanir; yapilinca otomatik olarak gercek denetime donusur.

const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');

const { PeaceReminder, start, SQL: REMINDER_SQL, helpers: REMINDER_HELPERS } = require('../../src/peace_reminder');
const { loadLiveSnapshot } = require('../../src/services/peace_snapshot');
const { createPushService } = require('../../src/services/push_service');
const { createPushRouter } = require('../../src/routes/push_routes');
const { MIN, Z, HOME_A, HOME_B, DEV_A, DEV_B, makeLogger, makeFakeTimers, standardWorld } = require('./_helpers');
const { CONFIGURED_ENV, makeResponse, fcmError, createFakeFetch, createFakeAuthFactory, FAKE_BEARER_1 } = require('./_push_helpers');

const ROOT = path.join(__dirname, '..', '..');
const DAY_MS = 24 * 60 * MIN;

// Sahte (uydurma) jetonlar: 20+ karakter gorunur ASCII
const TOK = {
  owner: 'fake-int-token-OWNER-000000000001',
  resident: 'fake-int-token-RESIDENT-0000000002',
  guest: 'fake-int-token-GUEST-000000000003',
  service: 'fake-int-token-SERVICE-00000000004',
  inactive: 'fake-int-token-INACTIVE-0000000005',
  suspended: 'fake-int-token-SUSPENDED-000000006',
  disabled: 'fake-int-token-DISABLED-0000000007',
  other: 'fake-int-token-OTHERHOME-000000008',
};
const ALL_TOKENS = Object.values(TOK);

const BODY_2L_1S = 'Salonda 2 lamba, 1 panjur açık.';
const FCM_URL = 'https://fcm.googleapis.com/v1/projects/fake-project/messages:send';

// Gercek akis boyunca reminder'in yazdigi tum durumlar (son testte migration CHECK ile karsilastirilir)
const seenStatuses = new Set();

// ------------------------------------------------------------------------------
// Sahte veritabani: evaluator dunyasi + push_tokens / home_users / users
// ------------------------------------------------------------------------------
function defaultStore() {
  const mk = (n, userId, token, extra = {}) => ({ id: `00000000-0000-4000-8000-00000000000${n}`, user_id: userId, token, platform: n % 2 ? 'android' : 'ios', disabled_at: null, last_seen_at: n, ...extra });
  return {
    users: [
      { id: 'aaaaaaaa-0000-4000-8000-000000000001', is_active: true, account_status: 'active' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000002', is_active: true, account_status: 'active' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000003', is_active: true, account_status: 'active' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000004', is_active: true, account_status: 'active' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000005', is_active: false, account_status: 'active' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000006', is_active: true, account_status: 'suspended' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000007', is_active: true, account_status: 'active' },
      { id: 'aaaaaaaa-0000-4000-8000-000000000008', is_active: true, account_status: 'active' },
    ],
    homeUsers: [
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000001', role: 'owner' },
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000002', role: 'resident' },
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000003', role: 'guest' },
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000004', role: 'service_user' },
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000005', role: 'resident' },
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000006', role: 'resident' },
      { home_id: HOME_A, user_id: 'aaaaaaaa-0000-4000-8000-000000000007', role: 'resident' },
      { home_id: HOME_B, user_id: 'aaaaaaaa-0000-4000-8000-000000000008', role: 'owner' },
    ],
    tokens: [
      mk(1, 'aaaaaaaa-0000-4000-8000-000000000001', TOK.owner),
      mk(2, 'aaaaaaaa-0000-4000-8000-000000000002', TOK.resident),
      mk(3, 'aaaaaaaa-0000-4000-8000-000000000003', TOK.guest),
      mk(4, 'aaaaaaaa-0000-4000-8000-000000000004', TOK.service),
      mk(5, 'aaaaaaaa-0000-4000-8000-000000000005', TOK.inactive),
      mk(6, 'aaaaaaaa-0000-4000-8000-000000000006', TOK.suspended),
      mk(7, 'aaaaaaaa-0000-4000-8000-000000000007', TOK.disabled, { disabled_at: 1 }),
      mk(8, 'aaaaaaaa-0000-4000-8000-000000000008', TOK.other),
    ],
  };
}

/** push_service'in SQL'lerini bicimden (bosluk/satir) bagimsiz taniyan kalip: yalnizca anlamsal belirtecler. */
const flat = (text) => String(text).replace(/\s+/g, ' ').trim();
const RECIPIENTS_RE = /^SELECT .*FROM home_users hu JOIN users u .*JOIN push_tokens pt /;

/**
 * Evaluator dunyasinin db'sini push servisinin SQL'leriyle genisletir. Sorgular ANLAMSAL belirteclerle
 * taninir (tam metin degil): push_service SQL'ini yeniden bicimlendirmek/sinirlamak bu testi kirmasin;
 * ama taninmayan sorgu yine de HATA verir (sessiz yutulmaz).
 */
function makeDb(w, store) {
  const calls = [];
  const nowMs = () => w.clock.ms;
  let seq = 100;
  const disableWhere = (pred) => {
    let n = 0;
    for (const t of store.tokens) if (t.disabled_at === null && pred(t)) { t.disabled_at = nowMs(); n += 1; }
    return { rows: [], rowCount: n };
  };

  async function query(text, params = []) {
    calls.push({ text, params });
    const sql = flat(text);

    if (/INSERT INTO push_tokens/.test(sql)) {
      // upsertToken: [userId, token, platform, appVersion, kullanici basina korunacak diger jeton sayisi]
      const [userId, token, platform, , keepOthers] = params;
      let row = store.tokens.find((t) => t.token === token);
      if (row) Object.assign(row, { user_id: userId, platform, last_seen_at: nowMs(), disabled_at: null });
      else {
        seq += 1;
        row = { id: `00000000-0000-4000-8000-${String(seq).padStart(12, '0')}`, user_id: userId, token, platform, disabled_at: null, last_seen_at: nowMs() };
        store.tokens.push(row);
      }
      if (/DELETE FROM push_tokens/.test(sql) && Number.isInteger(keepOthers)) {
        // pruned: en yeni `keepOthers` etkin jetondan fazlasini sil (kaydedilen jeton korunur)
        const others = store.tokens.filter((t) => t.user_id === userId && t.disabled_at === null && t.token !== token)
          .sort((a, b) => b.last_seen_at - a.last_seen_at || (a.id < b.id ? -1 : 1));
        for (const t of others.slice(keepOthers)) store.tokens.splice(store.tokens.indexOf(t), 1);
      }
      return { rows: [{ id: row.id }], rowCount: 1 };
    }

    if (RECIPIENTS_RE.test(sql)) {
      // SQL anlami: owner/resident + aktif hesap + devre disi olmayan jeton; kullanici basina en yeni
      // `perUser` jeton, sonra genel LIMIT (parametreler: [homeId, perUser, limit]; eski bicim [homeId, limit])
      assert.match(sql, /hu\.role IN \('owner', 'resident'\)/);
      assert.match(sql, /u\.account_status = 'active'/);
      assert.match(sql, /pt\.disabled_at IS NULL/);
      const limit = params[params.length - 1];
      const perUser = params.length >= 3 ? params[1] : Infinity;
      const eligible = store.tokens
        .filter((t) => t.disabled_at === null)
        .filter((t) => {
          const u = store.users.find((x) => x.id === t.user_id);
          return u && u.is_active !== false && u.account_status === 'active'
            && store.homeUsers.some((h) => h.home_id === params[0] && h.user_id === u.id && ['owner', 'resident'].includes(h.role));
        })
        .sort((a, b) => b.last_seen_at - a.last_seen_at || (a.id < b.id ? -1 : 1));
      const rank = new Map();
      const rows = eligible
        .filter((t) => { const n = (rank.get(t.user_id) || 0) + 1; rank.set(t.user_id, n); return n <= perUser; })
        .slice(0, limit)
        .map((t) => ({ id: t.id, user_id: t.user_id, token: t.token, platform: t.platform }));
      return { rows, rowCount: rows.length };
    }

    if (/^UPDATE push_tokens SET disabled_at = now\(\)/.test(sql)) {
      if (/WHERE id = ANY/.test(sql)) return disableWhere((t) => params[0].includes(t.id));
      if (/WHERE token = ANY/.test(sql)) return disableWhere((t) => params[0].includes(t.token));
      if (/WHERE token = \$1 AND user_id = \$2/.test(sql)) return disableWhere((t) => t.token === params[0] && t.user_id === params[1]);
      if (/WHERE token = \$1/.test(sql)) return disableWhere((t) => t.token === params[0]);
      if (/WHERE user_id = \$1/.test(sql)) return disableWhere((t) => t.user_id === params[0]);
    }
    // cleanup: eski/devre disi jetonlari siler; bu senaryolarda silinecek eski satir yok
    if (/^DELETE FROM push_tokens/.test(sql)) return { rows: [], rowCount: 0 };

    if (text === REMINDER_SQL.finish) seenStatuses.add(params[1]);
    return w.db.query(text, params);
  }

  return {
    calls,
    query,
    count: (sql) => calls.filter((c) => c.text === sql).length,
    matching: (re) => calls.filter((c) => re.test(c.text)),
    /** Alici (home_users + push_tokens) sorgusu; cleanup DELETE'i bunu SAYMAZ. */
    recipientQueries: () => calls.filter((c) => RECIPIENTS_RE.test(flat(c.text))),
  };
}

/** Acik Salon lambasi (ep-3) + bir panjur cifti (pair NULL, 2 rele de %100): Salon 2 lamba, 1 panjur. */
const OPEN_EXTRAS = [
  { id: 'ep-3', device_id: DEV_A, type: 'light', channel_index: 7, shutter_pair_index: null, name: 'Salon spot', room: 'Salon', current_state: true, current_position: 0 },
  { id: 'ep-4', device_id: DEV_A, type: 'shutter', channel_index: 1, shutter_pair_index: null, name: 'Panjur yukari', room: 'Salon', current_state: false, current_position: 100 },
  { id: 'ep-5', device_id: DEV_A, type: 'shutter', channel_index: 2, shutter_pair_index: null, name: 'Panjur asagi', room: 'Salon', current_state: false, current_position: 100 },
];

/**
 * Tum parcalari kurar. `fetchResponder(call)` FCM yanitini belirler; `pushEnv` push servisinin
 * ortami; `reminderEnv` degerlendirici ortami. Her cagri YENI bir dunya/store/saat uretir.
 */
function setup({ world = {}, store = defaultStore(), fetchResponder, pushEnv = CONFIGURED_ENV, reminderEnv = {}, withText = false } = {}) {
  // Uc nesneler testler arasinda PAYLASILMAZ (bir test lambayi kapatinca digerini bozmasin)
  const w = standardWorld({ ...world, extraEndpoints: (world.extraEndpoints || OPEN_EXTRAS).map((e) => ({ ...e })) });
  const db = makeDb(w, store);
  const logger = makeLogger();
  const fetchImpl = createFakeFetch(fetchResponder);
  const authFactory = createFakeAuthFactory();
  const push = createPushService({ db, logger, fetchImpl, authFactory, env: pushEnv, now: () => w.clock.ms });
  const timers = makeFakeTimers();
  const deps = { db, push, logger, now: () => w.clock.ms, setTimer: timers.setTimer, clearTimer: timers.clearTimer, env: reminderEnv };
  // GERCEK peace_text: `text` ENJEKTE EDILMEZ (varsayilan tembel yukleme denenir)
  const make = (extra = {}) => new PeaceReminder({ ...deps, ...extra });
  void withText;
  return { w, store, db, logger, fetchImpl, authFactory, push, timers, deps, make, reminder: make() };
}

const pushedTokens = (fetchImpl) => fetchImpl.calls.map((c) => c.body.message.token).sort();
const rowOf = (h, homeId = HOME_A) => h.w.world.logs.find((l) => l.home_id === homeId);

/** Bir sonraki yerel geceye gecer; cihaz canli kalsin diye last_seen tazelenir. */
function nextNight(w) {
  w.clock.ms += DAY_MS;
  for (const d of w.world.devices) d.last_seen_ms = w.clock.ms - 10 * 1000;
}

/** Hicbir gunluk satirinda token, ev adi, oda adi veya govde metni gecmemeli. */
function assertNoLeak(h, extra = []) {
  const haystack = h.logger.lines.join('\n');
  for (const secret of [...ALL_TOKENS, FAKE_BEARER_1, 'Gül Apartmanı', 'Salon', 'Mutfak', ...extra]) {
    assert.ok(!haystack.includes(secret), `logda sizinti: ${secret.slice(0, 12)}`);
  }
}

// ==============================================================================
// 1. Mutlu yol
// ==============================================================================
test('vadesi gelen ev: acik lamba + panjur -> TEK push, dogru Turkce govde, yalniz-string data', async () => {
  const h = setup();
  const summary = await h.reminder.runTick();

  assert.deepEqual({ ...summary, errors: undefined }, {
    zones: 1, candidates: 1, claimed: 1, clear: 0, sent: 1, noRecipients: 0, skippedOffline: 0, failed: 0, lost: 0, dryRun: 0, errors: undefined,
  });

  // Alicilar: yalniz owner + resident (guest/service_user/pasif/askida/devre disi/baska ev HARIC)
  assert.deepEqual(pushedTokens(h.fetchImpl), [TOK.owner, TOK.resident].sort());
  assert.equal(h.fetchImpl.calls.length, 2, 'jeton basina tek istek');

  const row = rowOf(h);
  assert.ok(row, 'bildirim kaydi yazilmis olmali');
  for (const call of h.fetchImpl.calls) {
    assert.equal(call.url, FCM_URL);
    assert.equal(call.init.method, 'POST');
    assert.equal(call.init.headers.Authorization, `Bearer ${FAKE_BEARER_1}`);
    const m = call.body.message;
    assert.equal(m.notification.title, 'Gül Apartmanı 5');
    assert.equal(m.notification.body, BODY_2L_1S);
    // FCM v1 data: map<string,string> -> TUM degerler string
    assert.deepEqual(m.data, {
      type: 'peace_open_devices',
      home_id: HOME_A,
      notice_id: String(row.id),
      open_lights: '2',
      open_shutters: '1',
      action: 'close_all',
      v: '1',
    });
    for (const [k, v] of Object.entries(m.data)) assert.equal(typeof v, 'string', `data.${k} string olmali`);
    assert.equal(m.android.collapse_key, `peace_${HOME_A}`);
    assert.equal(m.android.notification.channel_id, 'peace_reminder');
    assert.equal(m.apns.headers['apns-collapse-id'], `peace_${HOME_A}`);
  }

  // Kayit: nihai durum ve alanlar
  assert.equal(row.status, 'sent');
  assert.equal(row.local_date, '2026-10-01');
  assert.equal(row.scheduled_for, '2026-10-01T20:30:00.000Z');
  assert.equal(row.attempts, 1);
  assert.equal(row.open_lights_count, 2);
  assert.equal(row.open_shutters_count, 1);
  assert.equal(row.summary_text, BODY_2L_1S);
  assert.equal(row.push_sent_count, 2);
  assert.deepEqual(row.details.push, { attempted: 2, sent: 2, failed: 0 });
  assert.equal(row.details.lights.length, 2);
  assert.deepEqual(row.details.shutters, [{ pair: 1, room: 'Salon', pos: 100 }]);
  const serialized = JSON.stringify(row);
  for (const t of ALL_TOKENS) assert.ok(!serialized.includes(t), 'kayitta jeton olmamali');

  // Bakim: gunde bir (ilk turda) kayit temizligi + push.cleanup
  assert.equal(h.db.count(REMINDER_SQL.purgeLogs), 1);
  assert.equal(h.db.matching(/^\s*DELETE FROM push_tokens/).length, 1);
  // Degerlendirici endpoints'e YAZMAZ, MQTT yok
  assert.equal(h.db.matching(/(INSERT INTO|UPDATE|DELETE FROM) endpoints/i).length, 0);
  assertNoLeak(h);
});

test('iki ev ayni turda: biri push alir, digeri (hicbir sey acik degil) clear', async () => {
  const h = setup({
    world: {
      extraHomes: [{ id: HOME_B, name: 'Sessiz Ev' }],
      extraDevices: [{ id: DEV_B, home_id: HOME_B, is_online: true, last_seen_ms: Z('2026-10-01T20:30:10Z') }],
      extraEndpoints: [...OPEN_EXTRAS, { id: 'ep-b1', device_id: DEV_B, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'Lamba', room: 'Salon', current_state: false, current_position: 0 }],
    },
  });
  const summary = await h.reminder.runTick();
  assert.equal(summary.candidates, 2);
  assert.equal(summary.sent, 1);
  assert.equal(summary.clear, 1);
  assert.equal(rowOf(h, HOME_A).status, 'sent');
  assert.equal(rowOf(h, HOME_B).status, 'clear');
  assert.equal(h.fetchImpl.calls.length, 2, 'yalniz HOME_A alicilarina (2 jeton)');
});

// ==============================================================================
// 2. Eszamanlilik: tek gece = tek push
// ==============================================================================
test('iki ESZAMANLI tur (iki ayri ornek, ortak db/push) -> tek push, biri lost', async () => {
  const h = setup();
  const a = h.make();
  const b = h.make();
  const [ra, rb] = await Promise.all([a.runTick(), b.runTick()]);

  assert.equal(ra.sent + rb.sent, 1, 'tam bir kazanan');
  assert.equal(ra.lost + rb.lost, 1, 'tam bir kaybeden');
  assert.equal(h.fetchImpl.calls.length, 2, 'bir bildirim = 2 jeton, ikinci tur gondermedi');
  assert.equal(h.w.world.logs.length, 1);

  // Sonraki dakikalar ayni geceyi yeniden gondermez
  h.w.clock.ms += MIN;
  h.w.world.devices[0].last_seen_ms = h.w.clock.ms - 5000;
  const again = await a.runTick();
  assert.equal(again.candidates, 0);
  assert.equal(h.fetchImpl.calls.length, 2);
});

test('ayni ornekte iki eszamanli runTick -> tek push', async () => {
  const h = setup();
  const [r1, r2] = await Promise.all([h.reminder.runTick(), h.reminder.runTick()]);
  assert.equal(r1.sent + r2.sent, 1);
  assert.equal(h.fetchImpl.calls.length, 2);
  assert.equal(rowOf(h).status, 'sent');
});

test('ayni ev ertesi gece yeniden bildirilir (yeni local_date), devre disi jeton tekrar denenmez', async () => {
  const h = setup();
  await h.reminder.runTick();
  assert.equal(h.fetchImpl.calls.length, 2);
  nextNight(h.w);
  const s = await h.reminder.runTick();
  assert.equal(s.sent, 1);
  assert.equal(h.fetchImpl.calls.length, 4);
  assert.deepEqual(h.w.world.logs.map((l) => l.local_date), ['2026-10-01', '2026-10-02']);
});

// ==============================================================================
// 3. Hicbir sey acik degil / bayat cihaz
// ==============================================================================
test('hicbir sey acik degil -> clear, push YOK, alici bile sorgulanmaz', async () => {
  const h = setup();
  for (const e of h.w.world.endpoints) { e.current_state = false; if (e.type === 'shutter') e.current_position = 0; }
  const summary = await h.reminder.runTick();
  assert.equal(summary.clear, 1);
  assert.equal(summary.sent, 0);
  assert.equal(rowOf(h).status, 'clear');
  assert.equal(h.fetchImpl.calls.length, 0);
  assert.equal(h.authFactory.calls.length, 0, 'kimlik bile istenmez');
  assert.equal(h.db.recipientQueries().length, 0);
  assertNoLeak(h);
});

test('bayat cihaz (last_seen 5 dk once) -> skipped_offline, push YOK; cihaz donunce sonraki turda TEK push', async () => {
  const h = setup();
  h.w.world.devices[0].last_seen_ms = h.w.clock.ms - 5 * MIN;
  const first = await h.reminder.runTick();
  assert.equal(first.skippedOffline, 1);
  assert.equal(first.sent, 0);
  assert.equal(rowOf(h).status, 'skipped_offline');
  assert.equal(rowOf(h).attempts, 1);
  assert.equal(h.fetchImpl.calls.length, 0, 'bayat veriyle ASLA bildirilmez');

  // Cihaz geri geldi (1 dk sonra, taze last_seen): ayni gece yeniden denenir
  h.w.clock.ms += MIN;
  h.w.world.devices[0].last_seen_ms = h.w.clock.ms - 3000;
  const second = await h.reminder.runTick();
  assert.equal(second.sent, 1);
  assert.equal(rowOf(h).status, 'sent');
  assert.equal(rowOf(h).attempts, 2);
  assert.equal(h.fetchImpl.calls.length, 2);
  assert.equal(h.w.world.logs.length, 1, 'ayni gece icin tek kayit');
});

test('is_online=false (last_seen taze olsa da) -> skipped_offline, push yok', async () => {
  const h = setup();
  h.w.world.devices[0].is_online = false;
  const s = await h.reminder.runTick();
  assert.equal(s.skippedOffline, 1);
  assert.equal(h.fetchImpl.calls.length, 0);
});

// ==============================================================================
// 4. Push sonuclari: devre disi jeton, gecici hata, yapilandirilmamis
// ==============================================================================
test('FCM UNREGISTERED -> jeton devre disi isaretlenir, kayit sent (kismi basari), ertesi gece o jetona gitmez', async () => {
  const h = setup({
    fetchResponder: (call) => (call.body.message.token === TOK.owner
      ? makeResponse(404, fcmError(404, 'UNREGISTERED'))
      : makeResponse(200, { name: 'projects/x/messages/1' })),
  });
  const s = await h.reminder.runTick();
  assert.equal(s.sent, 1);

  const owner = h.store.tokens.find((t) => t.token === TOK.owner);
  const resident = h.store.tokens.find((t) => t.token === TOK.resident);
  assert.notEqual(owner.disabled_at, null, 'gecersiz jeton disabled_at ile isaretlenmeli');
  assert.equal(resident.disabled_at, null);

  const row = rowOf(h);
  assert.equal(row.status, 'sent');
  assert.equal(row.push_sent_count, 1);
  assert.deepEqual(row.details.push, { attempted: 2, sent: 1, failed: 1 });

  nextNight(h.w);
  await h.reminder.runTick();
  const lastTwo = h.fetchImpl.calls.slice(2).map((c) => c.body.message.token);
  assert.deepEqual(lastTwo, [TOK.resident], 'devre disi jeton ertesi gece alici listesinde yok');
  assertNoLeak(h);
});

test('FCM tum jetonlari reddeder (UNREGISTERED) -> no_recipients/push_rejected, jetonlar kapanir, yeniden gonderim yok', async () => {
  const h = setup({ fetchResponder: () => makeResponse(404, fcmError(404, 'UNREGISTERED')) });
  const s = await h.reminder.runTick();
  assert.equal(s.noRecipients, 1);
  const row = rowOf(h);
  assert.equal(row.status, 'no_recipients');
  assert.equal(row.details.reason, 'push_rejected');
  assert.equal(h.store.tokens.filter((t) => [TOK.owner, TOK.resident].includes(t.token) && t.disabled_at !== null).length, 2);

  const before = h.fetchImpl.calls.length;
  h.w.clock.ms += MIN;
  h.w.world.devices[0].last_seen_ms = h.w.clock.ms - 1000;
  await h.reminder.runTick();
  assert.equal(h.fetchImpl.calls.length, before, 'nihai durum: ayni gece tekrar denenmez');
});

test('FCM 503 (gecici) -> failed/push_transient, sonraki turda yeniden denenir ve TEK basarili push', async () => {
  let healthy = false;
  const h = setup({ fetchResponder: () => (healthy ? makeResponse(200, { name: 'x' }) : makeResponse(503, fcmError(503, 'UNAVAILABLE'), { 'Retry-After': '30' })) });
  const first = await h.reminder.runTick();
  assert.equal(first.failed, 1);
  assert.equal(rowOf(h).status, 'failed');
  assert.equal(rowOf(h).details.reason, 'push_transient');
  assert.equal(h.store.tokens.filter((t) => t.disabled_at === null).length, 7, 'gecici hata jetonu kapatmaz');

  healthy = true;
  h.w.clock.ms += MIN;
  h.w.world.devices[0].last_seen_ms = h.w.clock.ms - 1000;
  const second = await h.reminder.runTick();
  assert.equal(second.sent, 1);
  assert.equal(rowOf(h).status, 'sent');
  assert.equal(rowOf(h).attempts, 2);
});

test('push yapilandirilmamis (FCM env yok) -> no_recipients/push_not_configured, kayit yine yazilir, ag/kimlik YOK', async () => {
  const h = setup({ pushEnv: {} });
  const s = await h.reminder.runTick();
  assert.equal(s.noRecipients, 1);
  assert.equal(s.sent, 0);
  const row = rowOf(h);
  assert.equal(row.status, 'no_recipients');
  assert.equal(row.details.reason, 'push_not_configured');
  // Uygulama ici yedek (last_notice) icin sayilar ve ozet yine kayitta
  assert.equal(row.open_lights_count, 2);
  assert.equal(row.open_shutters_count, 1);
  assert.equal(row.summary_text, BODY_2L_1S);
  assert.equal(row.push_sent_count, 0);
  assert.equal(h.fetchImpl.calls.length, 0);
  assert.equal(h.authFactory.calls.length, 0);
  assert.equal(h.db.recipientQueries().length, 0, 'yapilandirma yoksa alici sorgusu bile yok');
});

test('isConfigured() olmayan push (yalniz sendNotice PUSH_NOT_CONFIGURED doner) -> yine no_recipients/push_not_configured', async () => {
  const h = setup({ pushEnv: {} });
  const bare = { recipientsForHome: h.push.recipientsForHome, sendNotice: h.push.sendNotice, cleanup: h.push.cleanup };
  const r = h.make({ push: bare });
  const s = await r.runTick();
  assert.equal(s.noRecipients, 1);
  assert.equal(rowOf(h).details.reason, 'push_not_configured');
  assert.equal(h.fetchImpl.calls.length, 0);
  assert.equal(h.authFactory.calls.length, 0);
  assert.equal(h.db.recipientQueries().length, 1, 'bu yolda alici sorgulanir, ag yine yok');
});

test('alici (jeton) yok -> no_recipients/no_tokens, kayit yazilir, ag yok', async () => {
  const store = defaultStore();
  store.tokens = [];
  const h = setup({ store });
  const s = await h.reminder.runTick();
  assert.equal(s.noRecipients, 1);
  assert.equal(rowOf(h).details.reason, 'no_tokens');
  assert.equal(rowOf(h).summary_text, BODY_2L_1S);
  assert.equal(h.fetchImpl.calls.length, 0);
});

// ==============================================================================
// 5. Talep ile gonderim arasinda kullanici kapatirsa
// ==============================================================================
test('kullanici talep ile gonderim arasinda HER SEYI kapatti -> clear/closed_before_send, push yok', async () => {
  const h = setup();
  h.w.world.onSnapshot = (n) => {
    if (n === 2) { // 1. goruntu: degerlendirme, 2. goruntu: gonderimden hemen once
      for (const e of h.w.world.endpoints) { e.current_state = false; if (e.type === 'shutter') e.current_position = 0; }
    }
  };
  const s = await h.reminder.runTick();
  assert.equal(s.clear, 1);
  assert.equal(s.sent, 0);
  assert.equal(rowOf(h).status, 'clear');
  assert.equal(rowOf(h).details.reason, 'closed_before_send');
  assert.equal(h.fetchImpl.calls.length, 0);
  assert.equal(h.w.world.snapshotCalls.get(HOME_A), 2, 'gonderimden once yeniden goruntu alinmis olmali');
});

test('kullanici bu arada KISMEN kapatti -> push GUNCEL durumu soyler (1 lamba), kayit da guncel', async () => {
  const h = setup();
  h.w.world.onSnapshot = (n) => {
    if (n === 2) h.w.world.endpoints.find((e) => e.id === 'ep-3').current_state = false;
  };
  await h.reminder.runTick();
  const m = h.fetchImpl.calls[0].body.message;
  assert.equal(m.notification.body, 'Salonda 1 lamba, 1 panjur açık.');
  assert.equal(m.data.open_lights, '1');
  assert.equal(m.data.open_shutters, '1');
  assert.equal(rowOf(h).open_lights_count, 1);
  assert.equal(rowOf(h).summary_text, 'Salonda 1 lamba, 1 panjur açık.');
});

// ==============================================================================
// 6. DRY_RUN
// ==============================================================================
test('DRY_RUN: claim/kayit/push/jeton guncellemesi/bakim YOK, yalniz degerlendirir ve loglar', async () => {
  const h = setup({ reminderEnv: { PEACE_REMINDER_DRY_RUN: 'true' } });
  const s = await h.reminder.runTick();
  assert.equal(s.dryRun, 1);
  assert.equal(s.claimed, 0);
  assert.equal(s.sent, 0);
  assert.equal(h.w.world.logs.length, 0, 'peace_notification_logs yazilmaz');
  assert.equal(h.fetchImpl.calls.length, 0);
  assert.equal(h.authFactory.calls.length, 0);
  assert.equal(h.db.count(REMINDER_SQL.claim), 0);
  assert.equal(h.db.count(REMINDER_SQL.finish), 0);
  assert.equal(h.db.count(REMINDER_SQL.purgeLogs), 0);
  assert.equal(h.db.matching(/push_tokens/).length, 0, 'jeton tablosuna hic dokunulmaz');
  assert.ok(h.logger.lines.some((l) => l.includes('DRY_RUN')));
  assertNoLeak(h);
});

// ==============================================================================
// 7. Yasam dongusu (start/stop) gercek push + gercek metin ile
// ==============================================================================
test('start(): dakika sinirina hizali tek zamanlayici; tetiklenince tek push; stop() zamanlayiciyi temizler', async () => {
  const h = setup();
  const inst = start(h.deps);
  assert.ok(inst instanceof PeaceReminder);
  assert.equal(inst.isRunning(), true);
  assert.equal(await inst.ready(), true, 'oz-denetim gecmeli (migration 022/025/030 sutunlari)');

  const pending = h.timers.pending();
  assert.equal(pending.length, 1);
  assert.equal(pending[0].ms, 60000, '23:30:20 -> sonraki dakika sinirina 40 sn + 20 sn ofset');

  await h.timers.fire(pending[0]);
  assert.equal(h.fetchImpl.calls.length, 2);
  assert.equal(rowOf(h).status, 'sent');
  assert.equal(h.timers.pending().length, 1, 'sonraki tur planlandi');

  await inst.stop();
  assert.equal(inst.isRunning(), false);
  assert.equal(h.timers.pending().length, 0);
});

// ==============================================================================
// 8. Token kaydi (route) -> alici -> push -> cikis
// ==============================================================================
test('PUT /me/push-tokens ile kaydolan cihaz gece push alir; DELETE sonrasi almaz', async () => {
  const store = defaultStore();
  store.tokens = [];
  const h = setup({ store });
  const authenticateToken = (req, res, next) => {
    const raw = req.headers['x-test-user'];
    if (!raw) return res.status(401).json({ success: false, message: 'token yok', code: 'INVALID_TOKEN' });
    req.user = JSON.parse(raw);
    return next();
  };
  const app = express();
  app.use('/api/v1', createPushRouter({ pushService: h.push, authenticateToken, logger: h.logger }));
  const asOwner = JSON.stringify({ id: 'aaaaaaaa-0000-4000-8000-000000000001', role: 'user' });

  const put = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asOwner)
    .send({ token: TOK.owner, platform: 'android', app_version: '1.0.0' });
  assert.equal(put.status, 200);
  assert.equal(put.body.success, true);
  assert.equal(put.body.data.registered, true);
  assert.equal(h.store.tokens.length, 1);

  const s = await h.reminder.runTick();
  assert.equal(s.sent, 1);
  assert.deepEqual(pushedTokens(h.fetchImpl), [TOK.owner]);
  assert.equal(h.fetchImpl.calls[0].body.message.notification.body, BODY_2L_1S);

  const del = await request(app).delete('/api/v1/me/push-tokens').set('x-test-user', asOwner).send({ token: TOK.owner });
  assert.equal(del.status, 200);
  assert.equal(del.body.data.registered, false);
  assert.notEqual(h.store.tokens[0].disabled_at, null);

  nextNight(h.w);
  const s2 = await h.reminder.runTick();
  assert.equal(s2.noRecipients, 1);
  assert.equal(h.w.world.logs[1].details.reason, 'no_tokens');
  assert.equal(h.fetchImpl.calls.length, 1, 'cikis yapan cihaza ikinci gece push gitmez');
});

// ==============================================================================
// 9. Statik sozlesme: durumlar / kolonlar / indeks <-> migration 030
// ==============================================================================
const migration = fs.readFileSync(path.join(ROOT, 'migrations', '030_peace_reminder.sql'), 'utf8');
const migration010 = fs.readFileSync(path.join(ROOT, 'migrations', '010_night_peace_and_child_lock.sql'), 'utf8');

function logTableColumns() {
  const cols = new Set();
  const create = migration010.match(/CREATE TABLE IF NOT EXISTS peace_notification_logs \(([\s\S]*?)\);/);
  for (const line of create[1].split('\n')) {
    const m = line.trim().match(/^([a-z_]+)\s+[A-Z]/);
    if (m) cols.add(m[1]);
  }
  for (const m of migration.matchAll(/ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS (\w+)/g)) cols.add(m[1]);
  return cols;
}

function pushTokenColumns() {
  const create = migration.match(/CREATE TABLE IF NOT EXISTS push_tokens \(([\s\S]*?)\n\);/);
  const cols = new Set();
  for (const line of create[1].split('\n')) {
    const m = line.trim().match(/^([a-z_]+)\s+[A-Z]/);
    if (m) cols.add(m[1]);
  }
  return cols;
}

test('sozlesme: reminder claim/finish SQL kolonlari ve ON CONFLICT hedefi migration (010 + 030) ile uyumlu', () => {
  const cols = logTableColumns();
  const insert = REMINDER_SQL.claim.match(/INSERT INTO peace_notification_logs \(([^)]*)\)/)[1].split(',').map((s) => s.trim());
  for (const c of insert) assert.ok(cols.has(c), `claim INSERT kolonu migration'da yok: ${c}`);
  const setPart = REMINDER_SQL.finish.match(/SET (.*) WHERE/)[1];
  for (const m of setPart.matchAll(/\b([a-z_]+) = /g)) assert.ok(cols.has(m[1]), `finish SET kolonu migration'da yok: ${m[1]}`);
  for (const m of REMINDER_SQL.finish.match(/WHERE (.*)$/)[1].matchAll(/\b([a-z_]+) = /g)) assert.ok(cols.has(m[1]), `finish WHERE kolonu yok: ${m[1]}`);
  for (const m of REMINDER_SQL.candidates.matchAll(/\bl\.([a-z_]+)/g)) assert.ok(cols.has(m[1]), `candidates l.${m[1]} yok`);

  // ON CONFLICT (home_id, local_date) -> migration'daki benzersiz indeks (KISMI DEGIL: ON CONFLICT hedefi tam eslesmeli)
  assert.match(REMINDER_SQL.claim, /ON CONFLICT \(home_id, local_date\)/);
  assert.match(migration, /CREATE UNIQUE INDEX IF NOT EXISTS \w+ ON peace_notification_logs \(home_id, local_date\);/);
});

test('sozlesme: reminder\'in yazdigi TUM durumlar migration CHECK kumesinde', () => {
  const allowed = migration.match(/CHECK \(status IN \(([^)]*)\)\)/)[1].split(',').map((s) => s.trim().replace(/'/g, ''));
  assert.ok(seenStatuses.size >= 5, `onceki testler yeterli durum uretmeli (gorulen: ${[...seenStatuses].join(',')})`);
  for (const s of seenStatuses) assert.ok(allowed.includes(s), `durum CHECK disinda: ${s}`);
  // Kaynakta DB'ye yazilan her durum sabiti de kume icinde olmali (henuz calismamis yollar dahil):
  // `_finish(ticket, { ... status: 'x' ...})` cagrilari + classifyPushResult donusleri
  const src = fs.readFileSync(path.join(ROOT, 'src', 'peace_reminder.js'), 'utf8');
  const written = [...src.matchAll(/_finish\(ticket,\s*\{[^}]*?status: '([a-z_]+)'/g)].map((m) => m[1]);
  const classify = src.match(/function classifyPushResult[\s\S]*?\n\}\n/)[0];
  written.push(...[...classify.matchAll(/status: '([a-z_]+)'/g)].map((m) => m[1]));
  assert.ok(written.length >= 8, `kaynaktan yeterli durum sabiti bulunamadi: ${written.length}`);
  for (const s of written) assert.ok(allowed.includes(s), `kaynakta CHECK disi durum: ${s}`);
  // En uzun durum VARCHAR(20)'ye sigar
  for (const s of allowed) assert.ok(s.length <= 20);
});

test('sozlesme: push_service SQL kolonlari push_tokens/users/home_users semasiyla uyumlu', async () => {
  const cols = pushTokenColumns();
  for (const c of ['id', 'user_id', 'token', 'platform', 'app_version', 'created_at', 'last_seen_at', 'disabled_at']) assert.ok(cols.has(c), `push_tokens.${c}`);
  const h = setup();
  await h.push.recipientsForHome(HOME_A);
  await h.push.upsertToken({ userId: 'aaaaaaaa-0000-4000-8000-0000000000ff', token: TOK.owner, platform: 'android' });
  await h.push.disableToken({ token: TOK.owner, userId: 'aaaaaaaa-0000-4000-8000-0000000000ff' });
  await h.push.cleanup({ olderThanDays: 30 });
  for (const call of h.db.calls) {
    for (const m of call.text.matchAll(/\bpt\.([a-z_]+)/g)) assert.ok(cols.has(m[1]), `pt.${m[1]} migration'da yok`);
  }
  const rec = h.db.recipientQueries()[0];
  assert.equal(rec.params[0], HOME_A);
  assert.ok(rec.params.slice(1).every((n) => Number.isInteger(n) && n >= 1), 'alici sinirlari pozitif tamsayi');
  // Roller 018 CHECK kumesinde: owner/resident var; misafir/servis alici DEGIL
  const m018 = fs.readFileSync(path.join(ROOT, 'migrations', '018_auth_hardening.sql'), 'utf8');
  const roles = m018.match(/home_users_role_check\s+CHECK \(role IN \(([^)]*)\)\)/)[1];
  assert.ok(roles.includes("'owner'") && roles.includes("'resident'"));
});

test('sozlesme: PeaceReminder yalnizca push.recipientsForHome/sendNotice/cleanup/isConfigured kullanir; veri anahtarlari push_service ile ayni', async () => {
  const h = setup();
  await h.reminder.runTick();
  const sent = Object.keys(h.fetchImpl.calls[0].body.message.data).sort();
  assert.deepEqual(sent, ['action', 'home_id', 'notice_id', 'open_lights', 'open_shutters', 'type', 'v']);
  // FCM'e giden TEK anahtar kumesi: reminder'in verdigi her alan push_service tarafindan korunmus
  const src = fs.readFileSync(path.join(ROOT, 'src', 'peace_reminder.js'), 'utf8');
  for (const key of ['type', 'home_id', 'notice_id', 'open_lights', 'open_shutters', 'action', 'v']) {
    assert.match(src, new RegExp(`\\b${key}:`), `reminder data.${key} vermiyor`);
  }
});

// ==============================================================================
// 10. GERCEK PostgreSQL (KAPILI: EV_PG_TEST_URL yoksa ATLANIR; `npm test` PostgreSQL gerektirmez)
// ==============================================================================
//
// Etkinlestirmek icin TAMAMEN migration'lanmis (030 dahil) bir veritabani verin:
//   node scripts/migrate.js            (MIGRATE_CONFIRM=<db>, DATABASE_URL=<hedef>)
//   EV_PG_TEST_URL=postgresql://kullanici:parola@127.0.0.1:5432/<db> node --test test/peace/peace_integration.test.js
//
// Neden: yukaridaki testlerde sahte db, SQL'in ANLAMINI JS ile taklit eder ve sorgulari metin
// kimligiyle eslestirir; SQL'in PostgreSQL'de gecerli olup olmadigini (parametre tip cikarimi, ON CONFLICT
// ... WHERE ... RETURNING, es zamanli talep, 030'un 010/022/025 ustune uygulanmasi) KANITLAMAZ.
// JS tek is parcacikli oldugu icin sahtedeki "iki es zamanli talep -> tek push" PG hakkinda hicbir sey soylemez.
//
// Her test KENDI satirlarini (rastgele ev/kullanici/cihaz) olusturur ve sonunda siler; paylasilan bir
// veritabaninda baska evlere DOKUNMAMAK icin degerlendirici izin listesiyle (PEACE_REMINDER_HOME_ALLOWLIST /
// SQL $8) yalnizca fixture evine kapsamlanir, gunluk/jeton temizligi (genel DELETE) calistirilmaz.

const PG_URL = process.env.EV_PG_TEST_URL;
const PG_SKIP = PG_URL ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

let pgPool = null;
function getPgDb() {
  if (!pgPool) {
    const { Pool } = require('pg');
    pgPool = new Pool({ connectionString: PG_URL, max: 12 });
    pgPool.on('error', () => {});
  }
  return { query: (text, params) => pgPool.query(text, params) };
}

test.after(async () => {
  if (pgPool) await pgPool.end();
});

const hex = (n) => crypto.randomBytes(n).toString('hex');
const silent = { log() {}, warn() {}, error() {} };
const PG_NOW = Z('2026-10-01T20:30:20Z'); // Istanbul 23:30:20 (hedef saat)
const TIME_HELPERS = REMINDER_HELPERS.loadTimeHelpers();
// runTick'in aday sorgusuna verdigi deneme siniri ile ayni kaynak (parseConfig): sabit kopyalanmaz
const PG_MAX_ATTEMPTS = REMINDER_HELPERS.parseConfig({}).maxAttempts;

/** Rastgele kullanici (yalniz FK ve alici sorgulari icin). */
async function pgUser(db, tag) {
  return (
    await db.query("INSERT INTO users (email, password_hash, full_name, role, is_active) VALUES ($1, $2, 'Test Kullanici', 'user', TRUE) RETURNING id", [
      `p_${tag}_${hex(3)}@example.invalid`,
      'x',
    ])
  ).rows[0].id;
}

/**
 * Rastgele ev + sahip + cihazlar. devices: [{ online, seenSecAgo, endpoints:[{ ch, type, room, pair, on, pos }] }]
 * (seenSecAgo veritabani saatine gore; null = hic gorulmedi). Temizleyici dondurur.
 */
async function pgFixture(db, { timezone = 'Europe/Istanbul', time = '23:30', enabled = true, devices = [{ online: true, seenSecAgo: 10, endpoints: [] }] } = {}) {
  const tag = hex(5);
  const userId = await pgUser(db, tag);
  const homeId = (
    await db.query(
      'INSERT INTO homes (name, mqtt_username, timezone, peace_notification_time, peace_notification_enabled) VALUES ($1, $2, $3, $4, $5) RETURNING id',
      [`P-${tag}`, `h_${hex(8)}`, timezone, time, enabled]
    )
  ).rows[0].id;
  await db.query("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')", [homeId, userId]);

  const deviceIds = [];
  for (let i = 0; i < devices.length; i++) {
    const spec = devices[i];
    const id = (
      await db.query('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE) RETURNING id', [
        homeId,
        `AHBU-P${tag}-${i}`.toUpperCase(),
        `P${tag}${i}`,
      ])
    ).rows[0].id;
    await db.query("UPDATE devices SET is_online = $2, last_seen_at = CASE WHEN $3::int IS NULL THEN NULL ELSE now() - ($3::int * interval '1 second') END WHERE id = $1", [
      id,
      spec.online,
      spec.seenSecAgo === undefined ? null : spec.seenSecAgo,
    ]);
    for (const e of spec.endpoints || []) {
      await db.query(
        `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, current_state, current_position)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [homeId, id, e.ch, `K${e.ch}`, e.type, e.room === undefined ? 'Genel' : e.room, e.pair === undefined ? null : e.pair, Boolean(e.on), e.pos || 0]
      );
    }
    deviceIds.push(id);
  }
  return {
    tag,
    userId,
    homeId,
    deviceIds,
    async cleanup() {
      await db.query('DELETE FROM homes WHERE id = $1', [homeId]).catch(() => {});
      if (deviceIds.length > 0) await db.query('DELETE FROM devices WHERE id = ANY($1::uuid[])', [deviceIds]).catch(() => {});
      await db.query('DELETE FROM users WHERE id = $1', [userId]).catch(() => {});
    },
  };
}

async function withPgFixture(opts, fn) {
  const db = getPgDb();
  const fx = await pgFixture(db, opts);
  try {
    await fn({ db, fx });
  } finally {
    await fx.cleanup();
  }
}

/** Salon: 2 lamba acik + 1 panjur cifti (pair NULL, iki role %100) + kapali lamba. */
const PG_OPEN_ENDPOINTS = [
  { ch: 1, type: 'shutter', room: 'Salon', pos: 100 },
  { ch: 2, type: 'shutter', room: 'Salon', pos: 100 },
  { ch: 3, type: 'light', room: 'Salon', on: true },
  { ch: 4, type: 'light', room: 'Salon', on: true },
  { ch: 5, type: 'light', room: 'Mutfak', on: false },
];

const pgCandidates = async (db, homeId, nowMs, { tz = 'Europe/Istanbul', allow = [homeId] } = {}) => {
  const win = REMINDER_HELPERS.candidateTargets(nowMs, tz, REMINDER_HELPERS.DEFAULT_CATCHUP_MIN, TIME_HELPERS);
  const res = await db.query(REMINDER_SQL.candidates, [
    tz, win.targets, REMINDER_HELPERS.MAX_HOMES_PER_TICK, win.nowHHMM, win.today, win.previous, PG_MAX_ATTEMPTS, allow,
  ]);
  return res.rows;
};
const pgClaim = (db, homeId, dateKey, maxAttempts = PG_MAX_ATTEMPTS) =>
  db.query(REMINDER_SQL.claim, [homeId, dateKey, new Date(PG_NOW).toISOString(), maxAttempts]);
const pgFinish = (db, id, status, attempts, extra = {}) =>
  db.query(REMINDER_SQL.finish, [
    id, status, extra.lights || 0, extra.shutters || 0, extra.summary || null,
    JSON.stringify(extra.details || { lights: [], shutters: [] }), extra.pushSent || 0, attempts,
  ]);
// Yeniden deneme araligi DB saatine baglidir (updated_at): "zaman gecti" = kaydin updated_at'ini eskitmek
const pgAge = (db, where, params, interval = '1 hour') =>
  db.query(`UPDATE peace_notification_logs SET updated_at = now() - interval '${interval}' WHERE ${where}`, params);
const pgMarkSending = (db, id, attempts) => db.query(REMINDER_SQL.markSending, [id, attempts]);
const pgLog = async (db, id) =>
  (await db.query(
    `SELECT status, attempts, to_char(local_date, 'YYYY-MM-DD') AS local_date, details, push_sent_count, resolved_at, resolved_by_user_id, resolved_via
       FROM peace_notification_logs WHERE id = $1`,
    [id]
  )).rows[0];

// "Hepsini kapat" kayit cozumleme deyimi: GERCEK peace_service.SQL.resolveNotice kullanilir (kopya YOK: kopya, gercek
// deyimden sapinca testi anlamsizlastirir). Parametreler: $1 cozen kullanici, $2 ilk komut kimligi, $3 bildirim kimligi
// (NULL = evin en yeni cozulebilir bildirimi), $4 ev. Kapsamli kosullu satirlar icin bkz. peace_service_pg.test.js.
const { SQL: SERVICE_SQL } = require('../../src/services/peace_service');

// ------------------------------------------------------------------------------
// 10.1 Sema / migration
// ------------------------------------------------------------------------------
test('PG: 022/025/030 uygulanmis; 030 tekrar calisinca hata vermez (idempotent); oz-denetim TAM semayi gorur', { skip: PG_SKIP }, async () => {
  const db = getPgDb();
  const names = (await db.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name);
  for (const required of ['022_scheduled_rules_fix.sql', '025_child_lock_and_peace_constraints.sql', '030_peace_reminder.sql']) {
    assert.ok(names.includes(required), `${required} uygulanmamis: once scripts/migrate.js calistirin`);
  }

  // Idempotentlik: 030 ust uste IKI kez, tek transaction'da calisir ve GERI ALINIR (paylasilan veritabaninda kalici
  // degisiklik/uzun kilit yok: lock_timeout 5 sn).
  const client = await pgPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout = '5s'");
    await client.query(migration);
    await client.query(migration);
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    client.release();
  }

  // Degerlendiricinin KENDI oz-denetim sorgusu gercek information_schema'ya karsi
  const res = await db.query(REMINDER_SQL.selfCheck, [Object.keys(REMINDER_HELPERS.REQUIRED_SCHEMA)]);
  const present = new Set(res.rows.map((r) => `${r.table_name}.${r.column_name}`));
  for (const [table, columns] of Object.entries(REMINDER_HELPERS.REQUIRED_SCHEMA)) {
    for (const column of columns) assert.ok(present.has(`${table}.${column}`), `sema eksik: ${table}.${column}`);
  }
  const reminder = new PeaceReminder({ db, push: { recipientsForHome: async () => [], sendNotice: async () => ({}) }, logger: silent, env: {} });
  assert.equal(await reminder.ready(), true, 'oz-denetim canli semada gecmeli');
});

test('PG: 030 kisitlari - eski INSERT bicimi calisir (manual, NULL local_date cakismaz), (ev, gece) tekil, durum/platform CHECK', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [] }, async ({ db, fx }) => {
    // Rolling deploy: eski kod yeni kolonlari vermeden INSERT eder
    for (let i = 0; i < 2; i++) {
      await db.query("INSERT INTO peace_notification_logs (home_id, open_lights_count, open_shutters_count, summary_text) VALUES ($1, 2, 1, 'eski tiklama')", [fx.homeId]);
    }
    const legacy = (await db.query('SELECT status, local_date, attempts FROM peace_notification_logs WHERE home_id = $1', [fx.homeId])).rows;
    assert.equal(legacy.length, 2, 'NULL local_date satirlari birbiriyle cakismaz');
    assert.ok(legacy.every((r) => r.status === 'manual' && r.local_date === null && r.attempts === 0));

    const ins = (date, status) => db.query('INSERT INTO peace_notification_logs (home_id, local_date, status) VALUES ($1, $2::date, $3)', [fx.homeId, date, status]);
    await ins('2026-10-01', 'claimed');
    await assert.rejects(() => ins('2026-10-01', 'claimed'), (e) => e.code === '23505', 'ayni (ev, gece) ikinci kez eklenemez');
    await ins('2026-10-02', 'claimed');
    await assert.rejects(() => ins('2026-10-03', 'bogus'), (e) => e.code === '23514', 'bilinmeyen durum CHECK ile reddedilir');

    const tok = `pg-int-token-${hex(16)}`;
    await db.query("INSERT INTO push_tokens (user_id, token, platform) VALUES ($1, $2, 'android')", [fx.userId, tok]);
    await assert.rejects(() => db.query("INSERT INTO push_tokens (user_id, token, platform) VALUES ($1, $2, 'ios')", [fx.userId, tok]), (e) => e.code === '23505', 'token benzersiz');
    await assert.rejects(() => db.query("INSERT INTO push_tokens (user_id, token, platform) VALUES ($1, $2, 'windows')", [fx.userId, `pg-int-token-${hex(16)}`]), (e) => e.code === '23514', 'platform CHECK');
  });
});

// ------------------------------------------------------------------------------
// 10.2 Aday secimi (SQL.zones / SQL.candidates)
// ------------------------------------------------------------------------------
test('PG SQL.zones/candidates: saat dilimi, NULL kurallari, pencere, izin listesi, cihazsiz ev, gece yarisi asimi, nihai kayit eleme', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 10, endpoints: PG_OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    // zones: izin listesi ($1::uuid[]) ve kisitsiz (NULL)
    const zones = (await db.query(REMINDER_SQL.zones, [[fx.homeId]])).rows.map((r) => r.tz);
    assert.deepEqual(zones, ['Europe/Istanbul']);
    assert.deepEqual((await db.query(REMINDER_SQL.zones, [[crypto.randomUUID()]])).rows, []);
    assert.ok((await db.query(REMINDER_SQL.zones, [null])).rows.some((r) => r.tz === 'Europe/Istanbul'), 'kisitsiz bolge listesi bu evin dilimini icerir');

    // varsayilan: 23:30, Istanbul, hedef saatte aday
    let rows = await pgCandidates(db, fx.homeId, PG_NOW);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, fx.homeId);
    assert.equal(rows[0].peace_time, '23:30');
    assert.equal(rows[0].timezone, 'Europe/Istanbul');

    // NULL saat (025 = "ayarlanmamis") -> 23:30
    await db.query('UPDATE homes SET peace_notification_time = NULL WHERE id = $1', [fx.homeId]);
    rows = await pgCandidates(db, fx.homeId, PG_NOW);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].raw_time, null);
    assert.equal(rows[0].peace_time, '23:30');

    // pencere: 23:00 (30 dk once) aday; 23:50 (henuz gelmedi) aday DEGIL
    await db.query("UPDATE homes SET peace_notification_time = '23:00' WHERE id = $1", [fx.homeId]);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 1);
    await db.query("UPDATE homes SET peace_notification_time = '23:50' WHERE id = $1", [fx.homeId]);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 0);

    // etkin bayragi: FALSE elenir, NULL = etkin
    await db.query("UPDATE homes SET peace_notification_time = '23:30', peace_notification_enabled = FALSE WHERE id = $1", [fx.homeId]);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 0);
    await db.query('UPDATE homes SET peace_notification_enabled = NULL WHERE id = $1', [fx.homeId]);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 1);

    // izin listesi baska bir ev ise elenir; yanlis saat dilimi elenir
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW, { allow: [crypto.randomUUID()] })).length, 0);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW, { tz: 'America/New_York' })).length, 0);

    // kayit durumlari: 'claimed' aday kalir (kaybeden talepte elenir); 'skipped_offline' yeniden deneme araligi
    // dolana kadar aday DEGIL (aksi halde cevrimdisi ev her dakika denenir), sonra aday; deneme hakki bitince /
    // nihai ('sent', 'sending', ...) durumda aday degil
    const claimed = (await pgClaim(db, fx.homeId, '2026-10-01')).rows[0];
    assert.ok(claimed, 'talep alinmali');
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 1, "'claimed' satir aday kalir");
    await pgFinish(db, claimed.id, 'skipped_offline', claimed.attempts);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 0, 'yeniden deneme araligi dolmadi');
    await pgAge(db, 'id = $1', [claimed.id]);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 1, 'aralik doldu: yeniden denenebilir');
    await db.query('UPDATE peace_notification_logs SET attempts = $2 WHERE id = $1', [claimed.id, PG_MAX_ATTEMPTS]);
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 0, 'deneme hakki bitti');
    for (const status of ['sent', 'sending', 'clear', 'no_recipients', 'resolved']) {
      await db.query('UPDATE peace_notification_logs SET attempts = 1, status = $2 WHERE id = $1', [claimed.id, status]);
      await pgAge(db, 'id = $1', [claimed.id]);
      assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 0, `nihai durum (${status}) aday degil`);
    }

    // gece yarisi asimi: 23:50 hedefi 00:20'de (Istanbul 2026-10-02) gorulur; kayit ONCEKI gunun tarihindedir
    const after = Z('2026-10-01T21:20:20Z');
    await db.query("UPDATE homes SET peace_notification_time = '23:50' WHERE id = $1", [fx.homeId]);
    assert.equal((await pgCandidates(db, fx.homeId, after)).length, 0, "01 Ekim kaydi (sent) var: dun tarihiyle elenir");
    await db.query('DELETE FROM peace_notification_logs WHERE id = $1', [claimed.id]);
    assert.equal((await pgCandidates(db, fx.homeId, after)).length, 1, 'kayit yok: 00:20 de 23:50 hedefi aday');
    const wrongDay = (await pgClaim(db, fx.homeId, '2026-10-02')).rows[0];
    await pgFinish(db, wrongDay.id, 'sent', wrongDay.attempts);
    assert.equal((await pgCandidates(db, fx.homeId, after)).length, 1, 'bugunun (2 Ekim) kaydi gece yarisi asiminda DUNUN gecesini kapatmaz');
  });

  // cihazi olmayan ev aday olmaz
  await withPgFixture({ devices: [] }, async ({ db, fx }) => {
    assert.equal((await pgCandidates(db, fx.homeId, PG_NOW)).length, 0);
    assert.deepEqual((await db.query(REMINDER_SQL.zones, [[fx.homeId]])).rows, []);
  });
});

// ------------------------------------------------------------------------------
// 10.3 Atomik talep / nihai kayit (SQL.claim / SQL.finish) + es zamanlilik
// ------------------------------------------------------------------------------
test('PG SQL.claim/finish: tek kazanan, kira suresi, deneme siniri, yalniz kendi talebi guncellenir', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 10 }] }, async ({ db, fx }) => {
    const first = await pgClaim(db, fx.homeId, '2026-10-01');
    assert.equal(first.rows.length, 1);
    assert.equal(first.rows[0].attempts, 1);
    const log1 = await pgLog(db, first.rows[0].id);
    assert.deepEqual([log1.status, log1.local_date, log1.attempts], ['claimed', '2026-10-01', 1]);

    assert.equal((await pgClaim(db, fx.homeId, '2026-10-01')).rows.length, 0, 'taze talep (kira suresi dolmadi) baskasina gecmez');

    // yanlis deneme numarasi (kira devralinmis) yazmaz; dogru olan yazar ve jsonb sorunsuz gider
    const id = first.rows[0].id;
    assert.equal((await pgFinish(db, id, 'sent', 99)).rowCount, 0);
    const details = { lights: [{ endpoint_id: 'x', channel: 3, room: 'Salon' }], shutters: [], reason: 'ornek' };
    assert.equal((await pgFinish(db, id, 'skipped_offline', 1, { lights: 2, details })).rowCount, 1);
    const log2 = await pgLog(db, id);
    assert.equal(log2.status, 'skipped_offline');
    assert.deepEqual(log2.details, details);

    // bekleyen kayit: yeniden deneme araligi dolmadan talep edilemez; dolunca (deneme 2) talep edilir
    assert.equal((await pgClaim(db, fx.homeId, '2026-10-01')).rows.length, 0, 'yeniden deneme araligi dolmadi');
    await pgAge(db, 'id = $1', [id]);
    const second = (await pgClaim(db, fx.homeId, '2026-10-01')).rows[0];
    assert.equal(second.id, id, 'ayni gece = ayni satir');
    assert.equal(second.attempts, 2);

    // 'sending' (push basladi): tek kazananli gecis; sonra kira suresi ne kadar eski olursa olsun YENIDEN talep edilemez
    assert.equal((await pgMarkSending(db, id, 99)).rowCount, 0, 'yanlis deneme numarasi');
    assert.equal((await pgMarkSending(db, id, 2)).rowCount, 1);
    assert.equal((await pgMarkSending(db, id, 2)).rowCount, 0, 'ikinci gecis yok');
    await pgAge(db, 'id = $1', [id], '1 day');
    assert.equal((await pgClaim(db, fx.homeId, '2026-10-01')).rows.length, 0, "'sending' ASLA yeniden talep edilmez (cift push olmasin)");

    // finish 'claimed' ve 'sending' satirlarini yazar; sonra nihai satir ezilmez
    assert.equal((await pgFinish(db, id, 'sent', 2, { lights: 2, shutters: 1, summary: 'Salonda 2 lamba, 1 panjur açık.', pushSent: 2 })).rowCount, 1);
    assert.equal((await pgClaim(db, fx.homeId, '2026-10-01')).rows.length, 0, "'sent' nihai: yeniden talep edilemez");
    assert.equal((await pgFinish(db, id, 'failed', 2)).rowCount, 0, 'nihai satir finish ile ezilmez');
    const log3 = await pgLog(db, id);
    assert.deepEqual([log3.status, log3.push_sent_count], ['sent', 2]);

    // kira suresi dolan 'claimed' (coken sahiplenici) devralinir; eski sahibin finish'i dusmez
    const lease = (await pgClaim(db, fx.homeId, '2026-10-02')).rows[0];
    await db.query("UPDATE peace_notification_logs SET updated_at = now() - interval '3 minutes' WHERE id = $1", [lease.id]);
    const taken = (await pgClaim(db, fx.homeId, '2026-10-02')).rows[0];
    assert.equal(taken.id, lease.id);
    assert.equal(taken.attempts, 2);
    assert.equal((await pgFinish(db, lease.id, 'sent', 1)).rowCount, 0, 'kira devralindi: eski sahibin yazisi dusmeli');
    assert.equal((await pgFinish(db, lease.id, 'clear', 2)).rowCount, 1);

    // deneme siniri: sinir kadar denendikten sonra (aralik dolsa bile) talep edilemez
    for (let n = 1; n <= PG_MAX_ATTEMPTS; n++) {
      const last = (await pgClaim(db, fx.homeId, '2026-10-03')).rows[0];
      assert.ok(last, `${n}. deneme talep edilmeli`);
      assert.equal(last.attempts, n);
      assert.equal((await pgFinish(db, last.id, 'failed', n)).rowCount, 1);
      await pgAge(db, 'id = $1', [last.id]);
    }
    assert.equal((await pgClaim(db, fx.homeId, '2026-10-03')).rows.length, 0, 'deneme hakki bitti');
  });
});

test('PG SQL.claim: ES ZAMANLI talepler - her gece icin TAM BIR kazanan (ON CONFLICT ... WHERE ... RETURNING)', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 10 }] }, async ({ db, fx }) => {
    for (const day of ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05']) {
      const results = await Promise.all(Array.from({ length: 8 }, () => pgClaim(db, fx.homeId, day)));
      const winners = results.filter((r) => r.rows.length === 1);
      assert.equal(winners.length, 1, `${day}: kazanan sayisi ${winners.length}`);
      assert.equal(winners[0].rows[0].attempts, 1);
    }
    assert.equal((await db.query('SELECT 1 FROM peace_notification_logs WHERE home_id = $1', [fx.homeId])).rows.length, 5, 'gece basina tek satir');

    // 'skipped_offline' bekleyen kaydi da es zamanli yeniden talepte tek kazanana gider
    const row = (await db.query('SELECT id FROM peace_notification_logs WHERE home_id = $1 AND local_date = $2::date', [fx.homeId, '2026-10-01'])).rows[0];
    await pgFinish(db, row.id, 'skipped_offline', 1);
    await pgAge(db, 'id = $1', [row.id]);
    const retry = await Promise.all(Array.from({ length: 8 }, () => pgClaim(db, fx.homeId, '2026-10-01')));
    assert.equal(retry.filter((r) => r.rows.length === 1).length, 1);
    assert.equal((await pgLog(db, row.id)).attempts, 2);
  });
});

test("PG: gercek resolveNotice - 'claimed' satira DOKUNMAZ; 'sending' cozulur ve sonradan finish cozulmus kaydi EZMEZ", { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 10 }] }, async ({ db, fx }) => {
    const claim = (await pgClaim(db, fx.homeId, '2026-10-01')).rows[0];
    const resolve = (id = claim.id, homeId = fx.homeId) => db.query(SERVICE_SQL.resolveNotice, [fx.userId, 'cmd000000001', id, homeId]);

    // degerlendirici satiri talep ettiyse (claimed) kullanici cozumlemesi 0 satir: finish/sending akisi bozulmaz
    assert.equal((await resolve()).rowCount, 0, 'claimed satir cozumlenmez');
    assert.equal((await resolve(null)).rowCount, 0, 'notice_id yok: en yeni COZULEBILIR satir secilir, claimed degil');
    assert.equal((await pgMarkSending(db, claim.id, claim.attempts)).rowCount, 1);

    // sending: push yolda, kullanici bildirime dokundu (bildirim kimligi push'ta sending satirindan gelir) -> cozulur
    assert.equal((await resolve(claim.id, crypto.randomUUID())).rowCount, 0, 'baska evin kimligiyle cozulmez');
    assert.equal((await resolve()).rowCount, 1, 'sending satir cozulur');
    const log = await pgLog(db, claim.id);
    assert.deepEqual([log.status, log.resolved_by_user_id, log.resolved_via], ['resolved', fx.userId, 'close_all']);
    assert.ok(log.resolved_at);

    // degerlendirici sonradan bitirir: cozulmus kayit EZILMEZ (rowCount 0; degerlendirici bunu tolere eder)
    assert.equal((await pgFinish(db, claim.id, 'sent', claim.attempts, { lights: 2, pushSent: 1 })).rowCount, 0);
    assert.equal((await pgLog(db, claim.id)).status, 'resolved');
    assert.equal((await resolve()).rowCount, 0, 'ikinci tiklama no-op');

    // 'no_recipients' (push yoktu, uygulama ici yedek) kaydi notice_id olmadan da cozulur
    const second = (await pgClaim(db, fx.homeId, '2026-10-02')).rows[0];
    await pgFinish(db, second.id, 'no_recipients', second.attempts);
    assert.equal((await resolve(null)).rowCount, 1);
    assert.equal((await pgLog(db, second.id)).status, 'resolved');
  });
});

// ------------------------------------------------------------------------------
// 10.4 Canli anlik goruntu (loadLiveSnapshot)
// ------------------------------------------------------------------------------
test('PG loadLiveSnapshot: canli/bayat/cevrimdisi cihaz, acik lamba, panjur cifti tekillestirme (NULL pair, cihaza ozel), room NULL', { skip: PG_SKIP }, async () => {
  const devices = [
    { // 0: canli
      online: true, seenSecAgo: 10,
      endpoints: [
        { ch: 1, type: 'shutter', room: 'Salon', pos: 100 },
        { ch: 2, type: 'shutter', room: 'Salon', pos: 100 },
        { ch: 3, type: 'light', room: 'Salon', on: true },
        { ch: 4, type: 'light', room: 'Mutfak', on: false },
        { ch: 5, type: 'plug', room: 'Salon', on: true },
        { ch: 6, type: 'light', room: null, on: true },
      ],
    },
    { online: true, seenSecAgo: 300, endpoints: [{ ch: 1, type: 'light', room: 'Bayat', on: true }] }, // 1: bayat (5 dk)
    { online: false, seenSecAgo: 10, endpoints: [{ ch: 1, type: 'light', room: 'Kapali', on: true }] }, // 2: cevrimdisi
    { // 3: canli, acik pair 1 (aciklik pair indeksiyle), kapali pair 2
      online: true, seenSecAgo: 10,
      endpoints: [
        { ch: 1, type: 'shutter', room: 'Oda', pair: 1, pos: 100 },
        { ch: 2, type: 'shutter', room: 'Oda', pair: 1, pos: 100 },
        { ch: 3, type: 'shutter', room: 'Oda', pair: 2, pos: 0 },
        { ch: 4, type: 'shutter', room: 'Oda', pair: 2, pos: 0 },
      ],
    },
  ];
  await withPgFixture({ devices }, async ({ db, fx }) => {
    const snap = await loadLiveSnapshot(db, fx.homeId);
    assert.equal(snap.devicesTotal, 4);
    assert.equal(snap.devicesLive, 2);
    assert.equal(snap.live, true);

    assert.deepEqual(snap.lights.map((l) => [l.channel, l.room]), [[3, 'Salon'], [6, 'Genel']], 'plug ve kapali lamba sayilmaz; bayat/cevrimdisi cihaz yok sayilir; room NULL -> Genel');
    assert.ok(snap.lights.every((l) => l.deviceId === fx.deviceIds[0]));

    assert.equal(snap.shutters.length, 2, 'cihaz basina bir acik cift (NULL pair kanaldan cozulur; kapali cift sayilmaz)');
    assert.deepEqual(snap.shutters.map((s) => s.pair), [1, 1]);
    assert.deepEqual(snap.shutters.map((s) => s.deviceId).sort(), [fx.deviceIds[0], fx.deviceIds[3]].sort());
    assert.ok(snap.shutters.every((s) => s.position === 100));

    // tum cihazlar bayatlayinca: bilinmiyor (live=false, bos listeler)
    await db.query("UPDATE devices SET last_seen_at = now() - interval '10 minutes' WHERE home_id = $1", [fx.homeId]);
    const stale = await loadLiveSnapshot(db, fx.homeId);
    assert.deepEqual([stale.live, stale.devicesTotal, stale.devicesLive, stale.lights.length, stale.shutters.length], [false, 4, 0, 0, 0]);
  });

  await withPgFixture({ devices: [] }, async ({ db, fx }) => {
    const none = await loadLiveSnapshot(db, fx.homeId);
    assert.deepEqual([none.live, none.devicesTotal, none.lights.length, none.shutters.length], [false, 0, 0, 0]);
  });
});

// ------------------------------------------------------------------------------
// 10.5 push_service SQL'i (gercek PG)
// ------------------------------------------------------------------------------
test('PG push_service: upsertToken yeniden baglar, recipientsForHome yalniz owner/resident+aktif+etkin, disableToken kullaniciya ozel, cleanup eskileri siler', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [] }, async ({ db, fx }) => {
    const push = createPushService({ db, logger: silent, env: {} });
    const otherUser = await pgUser(db, fx.tag);
    const guestUser = await pgUser(db, fx.tag);
    try {
      // misafir satiri 018 CHECK'i geregi gecerlilik bitisi ister (home_users_guest_window_check)
      await db.query("INSERT INTO home_users (home_id, user_id, role, valid_until) VALUES ($1, $2, 'guest', now() + interval '1 day')", [fx.homeId, guestUser]);
      const tokA = `pg-int-token-A-${hex(12)}`;
      const tokB = `pg-int-token-B-${hex(12)}`;
      const tokG = `pg-int-token-G-${hex(12)}`;

      assert.ok((await push.upsertToken({ userId: fx.userId, token: tokA, platform: 'android', appVersion: '1.0.0' })).id);
      await push.upsertToken({ userId: fx.userId, token: tokB, platform: 'ios' });
      await push.upsertToken({ userId: guestUser, token: tokG, platform: 'android' });
      const recipients = await push.recipientsForHome(fx.homeId);
      assert.deepEqual(recipients.map((r) => r.token).sort(), [tokA, tokB].sort(), 'misafir alici degil');
      assert.ok(recipients.every((r) => r.userId === fx.userId && r.id));

      // paylasilan telefon: ayni token baska kullaniciya yeniden baglanir (ev uyesi degil -> alici degil)
      await push.upsertToken({ userId: otherUser, token: tokA, platform: 'android' });
      assert.deepEqual((await push.recipientsForHome(fx.homeId)).map((r) => r.token), [tokB]);

      // disableToken yalnizca KENDI kullanicisinin jetonunu kapatir
      assert.equal(await push.disableToken({ token: tokA, userId: fx.userId }), 0, 'baskasinin jetonu');
      assert.equal(await push.disableToken({ token: tokB, userId: fx.userId }), 1);
      assert.deepEqual(await push.recipientsForHome(fx.homeId), []);
      // yeniden kayit devre disi isareti kaldirir
      await push.upsertToken({ userId: fx.userId, token: tokB, platform: 'ios' });
      assert.equal((await push.recipientsForHome(fx.homeId)).length, 1);

      // askiya alinan hesap alici degildir
      await db.query("UPDATE users SET account_status = 'suspended' WHERE id = $1", [fx.userId]);
      assert.deepEqual(await push.recipientsForHome(fx.homeId), []);
    } finally {
      await db.query('DELETE FROM users WHERE id = ANY($1::uuid[])', [[otherUser, guestUser]]).catch(() => {});
    }

    // cleanup: genel DELETE paylasilan veritabaninda baska satirlari silmesin diye transaction'da calisir ve GERI ALINIR
    const client = await pgPool.connect();
    try {
      await client.query('BEGIN');
      const old = `pg-int-token-OLD-${hex(12)}`;
      await client.query("INSERT INTO push_tokens (user_id, token, platform, disabled_at) VALUES ($1, $2, 'android', now() - interval '31 days')", [fx.userId, old]);
      const cleaner = createPushService({ db: { query: (t, p) => client.query(t, p) }, logger: silent, env: {} });
      const removed = await cleaner.cleanup({ olderThanDays: 30 });
      assert.ok(Number.isInteger(removed) && removed >= 1);
      assert.equal((await client.query('SELECT 1 FROM push_tokens WHERE token = $1', [old])).rows.length, 0);
    } finally {
      await client.query('ROLLBACK').catch(() => {});
      client.release();
    }
  });
});

// ------------------------------------------------------------------------------
// 10.6 Uctan uca: gercek peace_reminder + gercek push_service SQL'i + gercek PG (FCM sahte)
// ------------------------------------------------------------------------------
async function pgReminder(db, fx, fetchImpl) {
  const logger = makeLogger();
  const realPush = createPushService({ db, logger, fetchImpl, authFactory: createFakeAuthFactory(), env: CONFIGURED_ENV, now: () => PG_NOW });
  // Bakim (genel DELETE'ler) paylasilan veritabaninda baska satirlara dokunmasin: yok sayilir.
  const push = { ...realPush, cleanup: async () => 0 };
  const scoped = { query: (text, params) => (text === REMINDER_SQL.purgeLogs ? Promise.resolve({ rows: [], rowCount: 0 }) : db.query(text, params)) };
  const timers = makeFakeTimers();
  const make = () => new PeaceReminder({
    db: scoped, push, logger, now: () => PG_NOW, setTimer: timers.setTimer, clearTimer: timers.clearTimer,
    env: { PEACE_REMINDER_HOME_ALLOWLIST: fx.homeId },
  });
  return { push, logger, make };
}

test('PG uctan uca: tek tur -> kayit + TEK push (gercek SQL), ikinci tur ayni geceyi tekrar gondermez, es zamanli iki ornek tek push', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 10, endpoints: PG_OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const token = `pg-int-token-E2E-${hex(12)}`;
    const fetchImpl = createFakeFetch();
    const h = await pgReminder(db, fx, fetchImpl);
    await h.push.upsertToken({ userId: fx.userId, token, platform: 'android' });

    const a = h.make();
    const b = h.make();
    const [ra, rb] = await Promise.all([a.runTick(PG_NOW), b.runTick(PG_NOW)]);
    assert.deepEqual(ra.errors.concat(rb.errors), [], 'gercek SQL hatasiz calismali');
    assert.equal(ra.sent + rb.sent, 1, 'tam bir gonderen');
    // Kaybeden talepte kaybeder (lost) ya da kazanan bitirdikten SONRA aday sorgusu calistiysa hic aday gormez:
    // kesin sayi zamanlamaya baglidir, tek degismez "en fazla bir gonderim"dir.
    assert.ok(ra.lost + rb.lost <= 1, `kaybeden sayisi: ${ra.lost + rb.lost}`);
    assert.equal(fetchImpl.calls.length, 1, 'tek jeton = tek push');

    const m = fetchImpl.calls[0].body.message;
    assert.equal(m.token, token);
    assert.equal(m.notification.body, BODY_2L_1S);
    const rows = (await db.query("SELECT id, status, attempts, to_char(local_date, 'YYYY-MM-DD') AS local_date, open_lights_count, open_shutters_count, summary_text, push_sent_count, details FROM peace_notification_logs WHERE home_id = $1", [fx.homeId])).rows;
    assert.equal(rows.length, 1);
    assert.deepEqual(
      [rows[0].status, rows[0].local_date, rows[0].open_lights_count, rows[0].open_shutters_count, rows[0].summary_text, rows[0].push_sent_count],
      ['sent', '2026-10-01', 2, 1, BODY_2L_1S, 1]
    );
    assert.deepEqual(rows[0].details.shutters, [{ pair: 1, room: 'Salon', pos: 100 }]);
    assert.equal(m.data.notice_id, String(rows[0].id), 'FCM notice_id = SERIAL kayit kimligi (tam sayi, dize olarak)');
    assert.ok(!JSON.stringify(rows[0].details).includes(token), 'kayitta jeton olmaz');

    // sonraki dakikalar: nihai kayit var -> aday bile degil
    const again = await a.runTick(PG_NOW + MIN);
    assert.equal(again.candidates, 0);
    assert.equal(fetchImpl.calls.length, 1);
  });
});

test('PG uctan uca: cihaz bayat -> skipped_offline (push yok); cihaz donunce ayni gece TEK push; hicbir sey acik degilse clear', { skip: PG_SKIP }, async () => {
  await withPgFixture({ devices: [{ online: true, seenSecAgo: 600, endpoints: PG_OPEN_ENDPOINTS }] }, async ({ db, fx }) => {
    const fetchImpl = createFakeFetch();
    const h = await pgReminder(db, fx, fetchImpl);
    await h.push.upsertToken({ userId: fx.userId, token: `pg-int-token-E2E-${hex(12)}`, platform: 'ios' });
    const r = h.make();

    const first = await r.runTick(PG_NOW);
    assert.equal(first.skippedOffline, 1);
    assert.equal(fetchImpl.calls.length, 0, 'bayat veriyle ASLA bildirilmez');

    await db.query('UPDATE devices SET last_seen_at = now(), is_online = TRUE WHERE home_id = $1', [fx.homeId]);
    const early = await r.runTick(PG_NOW + MIN);
    assert.equal(early.candidates, 0, 'yeniden deneme araligi dolmadan ayni ev tekrar denenmez');
    await pgAge(db, 'home_id = $1', [fx.homeId]);
    const second = await r.runTick(PG_NOW + 2 * MIN);
    assert.equal(second.sent, 1);
    assert.equal(fetchImpl.calls.length, 1);
    const row = (await db.query('SELECT status, attempts FROM peace_notification_logs WHERE home_id = $1', [fx.homeId])).rows;
    assert.deepEqual(row.map((x) => [x.status, x.attempts]), [['sent', 2]], 'ayni gece tek satir, 2 deneme');
  });

  await withPgFixture({ devices: [{ online: true, seenSecAgo: 5, endpoints: PG_OPEN_ENDPOINTS.map((e) => ({ ...e, on: false, pos: 0 })) }] }, async ({ db, fx }) => {
    const fetchImpl = createFakeFetch();
    const h = await pgReminder(db, fx, fetchImpl);
    const s = await h.make().runTick(PG_NOW);
    assert.equal(s.clear, 1);
    assert.equal(fetchImpl.calls.length, 0);
    assert.equal((await db.query('SELECT status FROM peace_notification_logs WHERE home_id = $1', [fx.homeId])).rows[0].status, 'clear');
  });
});

// ==============================================================================
// 11. Kilitli dosyalardaki ENTEGRASYON adimlari (todo: yapilana kadar rapor edilir, testi KIRMAZ)
// ==============================================================================
//
// WP-H yalnizca yeni dosyalar yazabildi; asagidaki dosyalar kilitliydi (SPEC 0.1). Bu testler, entegrasyon
// yapilmadan "bitti" sayilmasin diye yuzeyi sabitler. Her biri entegrasyon yapilinca GECER; o zaman
// `todo` secenegi kaldirilmalidir (todo testler basarisiz olsa da sureci kirmaz, yalnizca "todo" sayilir).
// Dosyalar baska ajanlarca duzenlenirken okunur: salt okuma, yazma YOK; `.env` OKUNMAZ (yalniz `.env.example`).

const TODO_INTEGRATION = 'WP-H entegrasyonu bekliyor (kilitli dosya); yapilinca bu todo kaldirilmali';
// assert.match basarisizken denetlenen DOSYANIN TAMAMINI ekrana basar: kisa mesajli bu yardimci gurultuyu onler
const has = (text, re, message) => assert.ok(re.test(text), message);
const readRepo = (...parts) => fs.readFileSync(path.join(ROOT, '..', ...parts), 'utf8');

test('entegrasyon: CONTRACTS - /me/push-tokens, FCM/PEACE degiskenleri, dosya sahipligi, notice_id tam sayi istisnasi', {}, () => {
  const contracts = readRepo('docs', 'CONTRACTS.md');
  assert.ok(/PUT[^\n]*\/me\/push-tokens/.test(contracts), 'PUT /me/push-tokens (bolum 1.5)');
  assert.ok(/DELETE[^\n]*\/me\/push-tokens/.test(contracts), 'DELETE /me/push-tokens (bolum 1.5)');
  for (const name of ['FCM_PROJECT_ID', 'FCM_SERVICE_ACCOUNT_FILE', 'GOOGLE_APPLICATION_CREDENTIALS', 'PEACE_REMINDER_ENABLED', 'PEACE_REMINDER_DRY_RUN', 'PEACE_REMINDER_HOME_ALLOWLIST', 'PEACE_CATCHUP_MIN']) {
    assert.ok(contracts.includes(name), `CONTRACTS bolum 6: ${name}`);
  }
  for (const file of ['peace_reminder.js', 'push_service.js', 'push_routes.js']) assert.ok(contracts.includes(file), `CONTRACTS bolum 7: ${file}`);
  // "kimlikler UUID dizesidir" kuralinin belgelenmis istisnasi: peace_notification_logs.id SERIAL
  assert.ok(/notice_id[^\n]*(tam ?sayı|tam ?sayi|integer|SERIAL)/i.test(contracts), 'notice_id UUID DEGIL, tam sayidir');
});

test('entegrasyon: server/.env.example FCM ve PEACE yer tutucularini icerir (gercek deger YOK)', {}, () => {
  const example = fs.readFileSync(path.join(ROOT, '.env.example'), 'utf8');
  for (const name of ['FCM_PROJECT_ID', 'FCM_SERVICE_ACCOUNT_FILE', 'PEACE_REMINDER_ENABLED', 'PEACE_REMINDER_DRY_RUN', 'PEACE_REMINDER_HOME_ALLOWLIST', 'PEACE_CATCHUP_MIN']) {
    assert.ok(new RegExp(`^#?\\s*${name}=`, 'm').test(example), `.env.example: ${name}`);
  }
});

test('entegrasyon: server.js - push router /api/v1 ve /api altinda, peace_reminder KENDI try/catch\'inde, kapanista mqtt ve db\'den ONCE durur', {}, () => {
  const src = fs.readFileSync(path.join(ROOT, 'src', 'server.js'), 'utf8');
  has(src, /push_routes/, 'push router baglanmali');
  has(src, /createPushRouter/, 'createPushRouter kullanilmali');
  has(src, /app\.use\('\/api\/v1',\s*\w+\)/, "push router /api/v1 altinda");
  has(src, /app\.use\('\/api',\s*\w+\)/, "push router /api altinda");
  // start() yalniz push varken ve ayri try icinde: eksik push/tablo hatasi rota kurulumunu dusurmesin
  has(src, /try\s*\{[^{}]*peace_reminder[^{}]*\}\s*catch/, 'peace_reminder baslatma kendi try/catch icinde');
  // Kapanis adimlari: `runShutdownStep('<ad>', ...)` (S3: her adimin kendi zaman asimi var; eski `['<ad>', fn]` dizisi yok).
  const idx = (name) => src.indexOf(`runShutdownStep('${name}'`);
  assert.ok(idx('peace-reminder') >= 0, "kapanis adimi 'peace-reminder'");
  assert.ok(idx('mqtt') >= 0 && idx('db') >= 0, "kapanis adimlari 'mqtt' ve 'db'");
  assert.ok(idx('peace-reminder') < idx('mqtt'), 'mqtt kapanmadan once');
  assert.ok(idx('peace-reminder') < idx('db'), 'db kapanmadan once');
});

test("entegrasyon: device_service - 'Hepsini kapat' peace_service'e devredilir (noticeId iletilir); route notice_id/include_shutters okur", {}, () => {
  const svc = fs.readFileSync(path.join(ROOT, 'src', 'services', 'device_service.js'), 'utf8');
  const fn = svc.slice(svc.indexOf('async closeAllOpenLights'));
  has(fn, /noticeId/, 'closeAllOpenLights({ actor, homeId, noticeId, includeShutters })');
  has(fn, /peace\.closeAll\(/, 'peace_service.closeAll cagrilmali (v2: canli anlik goruntu, panjur, bildirim cozme)');
  has(svc, /createPeaceService/, 'peace_service lazily olusturulmali');
  // yetki denetimi DeviceService'te kalir (peace_service yetki bilmez)
  has(fn, /can\('group'/, "toplu komut yetkisi (can('group')) closeAllOpenLights icinde");
  const routes = fs.readFileSync(path.join(ROOT, 'src', 'routes', 'device_routes.js'), 'utf8');
  has(routes, /notice_id/, 'close-all govdesi istege bagli tam sayi notice_id kabul eder');
  has(routes, /include_shutters/, 'close-all govdesi istege bagli include_shutters kabul eder');
});
