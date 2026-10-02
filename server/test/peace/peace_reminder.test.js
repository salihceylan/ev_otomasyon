'use strict';

// WP-H / evaluator - peace_reminder: pencere matematigi (gece yarisi, DST), atomik talep (coklu
// instance), yeniden deneme, bayat veri, clear, gonderim oncesi yeniden goruntu, alici yok,
// push yapilandirilmamis, DRY_RUN, kill switch, allowlist, oz-denetim, 500 ev siniri, ev basina
// hata/zaman asimi, yasam dongusu ve bakim. Gercek DB/FCM/zaman YOK.

const test = require('node:test');
const assert = require('node:assert/strict');
const { PeaceReminder, start, SQL, helpers } = require('../../src/peace_reminder');
const scheduler = require('../../src/scheduler');
const {
  Z,
  MIN,
  HOME_A,
  HOME_B,
  HOME_C,
  DEV_A,
  DEV_B,
  makeLogger,
  makeFakeTimers,
  makePeaceWorld,
  makeFakePush,
  makeFakeText,
  standardWorld,
  flush,
} = require('./_helpers');

// 2026-10-01 20:30:20Z = Istanbul (UTC+3) 23:30:20
const T_2330 = '2026-10-01T20:30:20Z';
const at = (iso) => Z(iso);

function make(w, opts = {}) {
  const timers = opts.timers || makeFakeTimers();
  const logger = opts.logger || makeLogger();
  const push = opts.push || makeFakePush();
  const reminder = new PeaceReminder({
    db: w.db,
    push,
    text: makeFakeText(),
    logger,
    now: () => w.clock.ms,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
    env: {},
    ...opts.deps,
    ...(opts.env ? { env: opts.env } : {}),
  });
  return { reminder, timers, logger, push };
}

async function tick(w, reminder, iso) {
  w.clock.ms = at(iso);
  return reminder.runTick(w.clock.ms);
}

// ------------------------------------------------------------------------------
// Pencere matematigi
// ------------------------------------------------------------------------------
const H = helpers;
const TIME = H.loadTimeHelpers();

test('computeWindow: Istanbul 23:30 hedefi 23:30 turunda delta 0, yerel tarih 2026-10-01', () => {
  const w = H.computeWindow(at(T_2330), 'Europe/Istanbul', '23:30', 60, TIME);
  assert.equal(w.delta, 0);
  assert.equal(w.dateKey, '2026-10-01');
  assert.equal(w.scheduledForMs, at('2026-10-01T20:30:00Z'));
});

test('computeWindow: 23:29 henuz erken; delta 60 sinirda aday, 61 degil (telafi)', () => {
  assert.equal(H.computeWindow(at('2026-10-01T20:29:20Z'), 'Europe/Istanbul', '23:30', 60, TIME), null);
  assert.equal(H.computeWindow(at('2026-10-01T20:59:20Z'), 'Europe/Istanbul', '23:30', 60, TIME).delta, 29);
  // 00:30 yerel (= 21:30Z) -> delta 60: hala pencerede, tarih ONCEKI gun
  const edge = H.computeWindow(at('2026-10-01T21:30:20Z'), 'Europe/Istanbul', '23:30', 60, TIME);
  assert.equal(edge.delta, 60);
  assert.equal(edge.dateKey, '2026-10-01');
  assert.equal(H.computeWindow(at('2026-10-01T21:31:20Z'), 'Europe/Istanbul', '23:30', 60, TIME), null);
});

test('computeWindow: gece yarisi asimi - 23:50 hedefi 00:20 turunda gorulurse local_date ONCEKI gun', () => {
  // 2026-10-01T21:20:20Z = Istanbul 2026-10-02 00:20
  const w = H.computeWindow(at('2026-10-01T21:20:20Z'), 'Europe/Istanbul', '23:50', 60, TIME);
  assert.equal(w.delta, 30);
  assert.equal(w.dateKey, '2026-10-01');
  // ayni hedef 23:55'te gorulurse ayni tarih
  assert.equal(H.computeWindow(at('2026-10-01T20:55:20Z'), 'Europe/Istanbul', '23:50', 60, TIME).dateKey, '2026-10-01');
});

test('computeWindow: yil/ay sinirinda onceki gun dogru hesaplanir (01-01 00:10 -> 12-31)', () => {
  const w = H.computeWindow(at('2025-12-31T21:10:20Z'), 'Europe/Istanbul', '23:50', 60, TIME);
  assert.equal(w.dateKey, '2025-12-31');
  assert.equal(H.previousDateKey('2026-03-01'), '2026-02-28');
  assert.equal(H.previousDateKey('2024-03-01'), '2024-02-29');
});

test('DST bahar bosluğu: New York 02:30 hedefi 03:00 turunda (delta 30) AYNI tarihle yakalanir, 01:59 turunda degil', () => {
  // 2026-03-08 02:00 EST -> 03:00 EDT; 03:00 EDT = 07:00Z
  const gapTick = H.computeWindow(at('2026-03-08T07:00:20Z'), 'America/New_York', '02:30', 60, TIME);
  assert.equal(gapTick.delta, 30);
  assert.equal(gapTick.dateKey, '2026-03-08');
  assert.equal(H.computeWindow(at('2026-03-08T06:59:20Z'), 'America/New_York', '02:30', 60, TIME), null, '01:59 EST');
  // aday saatler listesinde var olmayan 02:30 de bulunur
  const c = H.candidateTargets(at('2026-03-08T07:00:20Z'), 'America/New_York', 60, TIME);
  assert.ok(c.targets.includes('02:30'));
  assert.equal(c.nowHHMM, '03:00');
});

test('DST sonbahar tekrari: New York 01:30 iki kez gorulur, ayni local_date uretir', () => {
  const first = H.computeWindow(at('2026-11-01T05:30:20Z'), 'America/New_York', '01:30', 60, TIME); // 01:30 EDT
  const second = H.computeWindow(at('2026-11-01T06:30:20Z'), 'America/New_York', '01:30', 60, TIME); // 01:30 EST
  assert.equal(first.dateKey, '2026-11-01');
  assert.equal(second.dateKey, '2026-11-01');
  assert.equal(first.delta, 0);
  assert.equal(second.delta, 0);
});

test('candidateTargets: son catchup+1 duvar saati dakikasi, tekrarsiz; gece yarisini asar', () => {
  const c = H.candidateTargets(at('2026-10-01T21:10:20Z'), 'Europe/Istanbul', 60, TIME); // 00:10
  assert.equal(c.targets.length, 61);
  assert.equal(new Set(c.targets).size, 61);
  assert.equal(c.targets[0], '00:10');
  assert.ok(c.targets.includes('23:30') && c.targets.includes('23:59') && c.targets.includes('23:10'));
  assert.ok(!c.targets.includes('23:09'));
  assert.equal(c.today, '2026-10-02');
  assert.equal(c.previous, '2026-10-01');
});

test('saat yardimcilari: yedek (Intl) yardimci scheduler.helpers ile ayni sonucu verir; gecersiz tz Istanbul', () => {
  const fb = H.createFallbackTimeHelpers();
  const samples = [
    [at('2026-10-01T20:30:20Z'), 'Europe/Istanbul'],
    [at('2026-03-08T07:00:20Z'), 'America/New_York'],
    [at('2026-11-01T06:30:20Z'), 'America/New_York'],
    [at('2026-03-29T01:30:00Z'), 'Europe/Berlin'],
    [at('2026-10-01T00:00:00Z'), 'Pacific/Auckland'],
  ];
  for (const [ms, tz] of samples) {
    const a = scheduler.helpers.localParts(ms, tz);
    const b = fb.localParts(ms, tz);
    assert.deepEqual([b.year, b.month, b.day, b.hour, b.minute, b.dateKey], [a.year, a.month, a.day, a.hour, a.minute, a.dateKey], `${tz} ${new Date(ms).toISOString()}`);
  }
  assert.equal(fb.resolveTimeZone('Yok/Boyle'), 'Europe/Istanbul');
  assert.equal(fb.resolveTimeZone('Europe/Berlin'), 'Europe/Berlin');
  assert.equal(fb.floorMinute(90001), 60000);
  assert.equal(typeof H.loadTimeHelpers().localParts, 'function');
});

test('parseHHMM/formatHHMM: gecerli ve gecersiz bicimler', () => {
  assert.equal(H.parseHHMM('23:30'), 1410);
  assert.equal(H.parseHHMM('00:00'), 0);
  for (const bad of ['24:00', '9:05', '23.30', '23:60', '', null, undefined, 1230, '23:30\n']) assert.equal(H.parseHHMM(bad), null, String(bad));
  assert.equal(H.formatHHMM(-1), '23:59');
  assert.equal(H.formatHHMM(1440), '00:00');
});

// ------------------------------------------------------------------------------
// Mutlu yol ve kayit
// ------------------------------------------------------------------------------
test('mutlu yol: 23:30 -> tek kayit, tek push; kayit sayilari/ozet/details dogru; veri alanlari STRING', async () => {
  const w = standardWorld({
    extraEndpoints: [
      { id: 'ep-3', device_id: DEV_A, type: 'light', channel_index: 7, shutter_pair_index: null, name: 'Salon spot', room: 'Salon', current_state: true, current_position: 0 },
      { id: 'sh-1', device_id: DEV_A, type: 'shutter', channel_index: 1, shutter_pair_index: 1, name: 'P1 yukari', room: 'Salon', current_state: false, current_position: 100 },
      { id: 'sh-2', device_id: DEV_A, type: 'shutter', channel_index: 2, shutter_pair_index: 1, name: 'P1 asagi', room: 'Salon', current_state: false, current_position: 100 },
    ],
  });
  const { reminder, push } = make(w);
  const res = await tick(w, reminder, T_2330);

  assert.deepEqual(
    { zones: res.zones, candidates: res.candidates, claimed: res.claimed, clear: res.clear, sent: res.sent, noRecipients: res.noRecipients, skippedOffline: res.skippedOffline, failed: res.failed, errors: res.errors },
    { zones: 1, candidates: 1, claimed: 1, clear: 0, sent: 1, noRecipients: 0, skippedOffline: 0, failed: 0, errors: [] }
  );
  assert.equal(push.calls.send.length, 1);
  const call = push.calls.send[0];
  assert.equal(call.title, 'T:Gül Apartmanı 5');
  assert.equal(call.body, 'S:2L1S');
  assert.deepEqual(call.tokens.map((t) => t.id), ['tok-1', 'tok-2'], 'alici satirlari id ile gecer');
  assert.deepEqual(call.data, {
    type: 'peace_open_devices',
    home_id: HOME_A,
    notice_id: String(w.world.logs[0].id),
    open_lights: '2',
    open_shutters: '1',
    action: 'close_all',
    v: '1',
  });
  for (const v of Object.values(call.data)) assert.equal(typeof v, 'string');

  assert.equal(w.world.logs.length, 1);
  const row = w.world.logs[0];
  assert.equal(row.status, 'sent');
  assert.equal(row.local_date, '2026-10-01');
  assert.equal(row.attempts, 1);
  assert.equal(row.open_lights_count, 2);
  assert.equal(row.open_shutters_count, 1);
  assert.equal(row.summary_text, 'S:2L1S');
  assert.equal(row.push_sent_count, 2);
  assert.deepEqual(row.details.lights, [
    { endpoint_id: 'ep-1', channel: 5, room: 'Salon' },
    { endpoint_id: 'ep-3', channel: 7, room: 'Salon' },
  ]);
  assert.deepEqual(row.details.shutters, [{ pair: 1, room: 'Salon', pos: 100 }]);
  assert.deepEqual(row.details.push, { attempted: 2, sent: 2, failed: 0 });
  assert.equal(JSON.stringify(row.details).includes('FAKE-TOKEN'), false, 'details token tasimaz');
});

test('ayni gecenin sonraki turlari yeniden bildirmez (nihai kayit adayligi eler)', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w);
  await tick(w, reminder, T_2330);
  for (const iso of ['2026-10-01T20:31:20Z', '2026-10-01T20:45:20Z', '2026-10-01T21:30:20Z']) {
    const r = await tick(w, reminder, iso);
    assert.equal(r.candidates, 0, iso);
    assert.equal(r.sent, 0);
  }
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs.length, 1);
});

test('ertesi gece yeni kayit uretir (local_date farkli)', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w);
  await tick(w, reminder, T_2330);
  w.world.devices[0].last_seen_ms = at('2026-10-02T20:30:10Z');
  const r = await tick(w, reminder, '2026-10-02T20:30:20Z');
  assert.equal(r.sent, 1);
  assert.deepEqual(w.world.logs.map((l) => l.local_date), ['2026-10-01', '2026-10-02']);
  assert.equal(push.calls.send.length, 2);
});

test('hedef saatten once ve telafi penceresinden sonra HICBIR sey olmaz', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w);
  const early = await tick(w, reminder, '2026-10-01T20:29:20Z');
  assert.equal(early.candidates, 0);
  w.world.devices[0].last_seen_ms = at('2026-10-01T21:31:00Z');
  const late = await tick(w, reminder, '2026-10-01T21:31:20Z'); // 00:31 yerel: delta 61
  assert.equal(late.candidates, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs.length, 0);
});

test('yeniden baslatma telafisi: 23:50 turunda (delta 20) hala bildirir; gece yarisi asiminda tarih dogru', async () => {
  const w = standardWorld();
  const { reminder } = make(w);
  w.world.devices[0].last_seen_ms = at('2026-10-01T21:19:00Z');
  const r = await tick(w, reminder, '2026-10-01T21:20:20Z'); // 00:20 yerel, hedef 23:30 -> delta 50
  assert.equal(r.sent, 1);
  assert.equal(w.world.logs[0].local_date, '2026-10-01');
});

test('hedef 23:50 ve tur 00:20: kayit ONCEKI gunun local_date ile yazilir', async () => {
  const w = standardWorld({ homeOverrides: { peace_notification_time: '23:50' } });
  const { reminder } = make(w);
  w.world.devices[0].last_seen_ms = at('2026-10-01T21:19:00Z');
  const r = await tick(w, reminder, '2026-10-01T21:20:20Z');
  assert.equal(r.sent, 1);
  assert.equal(w.world.logs[0].local_date, '2026-10-01');
});

// ------------------------------------------------------------------------------
// DST uctan uca
// ------------------------------------------------------------------------------
function nyWorld(time) {
  const clock = { ms: at('2026-03-08T07:00:20Z') };
  const built = makePeaceWorld({
    clock,
    homes: [{ id: HOME_A, name: 'NY', timezone: 'America/New_York', peace_notification_time: time }],
    devices: [{ id: DEV_A, home_id: HOME_A, is_online: true, last_seen_ms: clock.ms }],
    endpoints: [{ id: 'e1', device_id: DEV_A, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 }],
  });
  return { ...built, clock };
}

test('DST bahar bosluğu uctan uca: 02:30 hedefi 03:00 turunda BIR kez ates eder, sonraki dakikalarda tekrar etmez', async () => {
  const w = nyWorld('02:30');
  const { reminder, push } = make(w);
  w.world.devices[0].last_seen_ms = at('2026-03-08T06:59:30Z');
  const before = await tick(w, reminder, '2026-03-08T06:59:20Z'); // 01:59 EST
  assert.equal(before.candidates, 0);
  w.world.devices[0].last_seen_ms = at('2026-03-08T07:00:10Z');
  const gap = await tick(w, reminder, '2026-03-08T07:00:20Z'); // 03:00 EDT
  assert.equal(gap.sent, 1);
  for (const iso of ['2026-03-08T07:01:20Z', '2026-03-08T07:20:20Z']) {
    w.world.devices[0].last_seen_ms = at(iso) - 5000;
    assert.equal((await tick(w, reminder, iso)).sent, 0);
  }
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs.length, 1);
  assert.equal(w.world.logs[0].local_date, '2026-03-08');
});

test('DST sonbahar tekrari uctan uca: 01:30 iki kez gorulur ama TEK gonderim (UNIQUE)', async () => {
  const w = nyWorld('01:30');
  const { reminder, push } = make(w);
  w.world.devices[0].last_seen_ms = at('2026-11-01T05:30:10Z');
  const first = await tick(w, reminder, '2026-11-01T05:30:20Z'); // 01:30 EDT
  w.world.devices[0].last_seen_ms = at('2026-11-01T06:30:10Z');
  const second = await tick(w, reminder, '2026-11-01T06:30:20Z'); // 01:30 EST
  assert.equal(first.sent, 1);
  assert.equal(second.sent, 0);
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs.length, 1);
  assert.equal(w.world.logs[0].local_date, '2026-11-01');
});

test('UNIQUE talep korumasi: ayni (ev, gece) icin ikinci dogrudan talep KAYBEDILIR (aday elemesi atlansa bile)', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w);
  await tick(w, reminder, T_2330);
  const home = { id: HOME_A, name: 'x', raw_time: '23:30', peace_time: '23:30' };
  const out = await reminder._processHome(home, 'Europe/Istanbul', at(T_2330));
  assert.deepEqual(out, { status: 'lost' });
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs.length, 1);
});

// ------------------------------------------------------------------------------
// Coklu instance
// ------------------------------------------------------------------------------
test('COKLU INSTANCE: iki ornek ayni anda runTick yapsa da TEK push ve TEK kayit', async () => {
  const w = standardWorld();
  const a = make(w);
  const b = make(w);
  w.clock.ms = at(T_2330);
  const [ra, rb] = await Promise.all([a.reminder.runTick(w.clock.ms), b.reminder.runTick(w.clock.ms)]);
  assert.equal(a.push.calls.send.length + b.push.calls.send.length, 1, 'tam bir push');
  assert.equal(ra.sent + rb.sent, 1);
  assert.equal(ra.claimed + rb.claimed, 1);
  assert.equal(ra.lost + rb.lost, 1);
  assert.equal(w.world.logs.length, 1);
});

test('ayni ornekte ust uste binen iki runTick de tek push yollar', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w);
  w.clock.ms = at(T_2330);
  await Promise.all([reminder.runTick(w.clock.ms), reminder.runTick(w.clock.ms)]);
  assert.equal(push.calls.send.length, 1);
});

test('coker sahiplenici: "claimed" satir 2 dk sonra devralinir; taze "claimed" devralinmaz', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w);
  w.world.logs.push({ id: 99, home_id: HOME_A, local_date: '2026-10-01', status: 'claimed', attempts: 1, updated_at: at(T_2330) - 30 * 1000 });
  const fresh = await tick(w, reminder, T_2330);
  assert.equal(fresh.lost, 1);
  assert.equal(push.calls.send.length, 0);
  w.world.devices[0].last_seen_ms = at('2026-10-01T20:33:10Z');
  const later = await tick(w, reminder, '2026-10-01T20:33:20Z'); // +3 dk
  assert.equal(later.sent, 1);
  assert.equal(w.world.logs[0].attempts, 2);
  assert.equal(push.calls.send.length, 1);
});

// ------------------------------------------------------------------------------
// Bayat veri / canlilik / yeniden deneme
// ------------------------------------------------------------------------------
test('BAYAT cihaz asla bildirmez: skipped_offline yazilir, push yok, alici sorgusu bile yok', async () => {
  const w = standardWorld({ deviceOverrides: { last_seen_ms: at(T_2330) - 121 * 1000 } });
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.skippedOffline, 1);
  assert.equal(r.sent, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(push.calls.recipients.length, 0);
  assert.equal(w.world.logs[0].status, 'skipped_offline');
  assert.equal(w.world.logs[0].details.reason, 'no_live_device');
  assert.equal(w.world.logs[0].open_lights_count, 0, 'bayat veriden sayi uretilmez');
});

test('skipped_offline pencere icinde yeniden denenir; cihaz donunce BIR bildirim gider (deneme sayisi 3)', async () => {
  const w = standardWorld({ deviceOverrides: { is_online: false } });
  const { reminder, push } = make(w);
  await tick(w, reminder, '2026-10-01T20:30:20Z');
  await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(w.world.logs[0].attempts, 2);
  w.world.devices[0].is_online = true;
  w.world.devices[0].last_seen_ms = at('2026-10-01T20:32:15Z');
  const r = await tick(w, reminder, '2026-10-01T20:32:20Z');
  assert.equal(r.sent, 1);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.equal(w.world.logs[0].attempts, 3);
  assert.equal(push.calls.send.length, 1);
});

test('PENCERE SONU: cevrimdisi kalan ev pencere bitince (delta 61) yeniden denenmez', async () => {
  const w = standardWorld({ deviceOverrides: { is_online: false } });
  const { reminder, push } = make(w);
  await tick(w, reminder, T_2330);
  w.world.devices[0].is_online = true;
  w.world.devices[0].last_seen_ms = at('2026-10-01T21:31:10Z');
  const r = await tick(w, reminder, '2026-10-01T21:31:20Z');
  assert.equal(r.candidates, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs[0].status, 'skipped_offline');
});

// ------------------------------------------------------------------------------
// Hicbir sey acik degil / yeniden goruntu
// ------------------------------------------------------------------------------
test('hicbir sey acik degil -> clear: push yok, alici sorgusu yok, kayit tutulur', async () => {
  const w = standardWorld({ lampOn: false });
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.clear, 1);
  assert.equal(r.sent, 0);
  assert.equal(push.calls.recipients.length, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs[0].status, 'clear');
  assert.deepEqual(w.world.logs[0].details, { lights: [], shutters: [] });
  // sonraki dakikada tekrar degerlendirilmez
  const again = await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(again.candidates, 0);
});

test('GONDERIM ONCESI YENIDEN GORUNTU: kullanici arada kapatti -> clear, push YOK', async () => {
  const w = standardWorld();
  w.world.onSnapshot = (n) => {
    if (n === 2) w.world.endpoints.forEach((e) => { e.current_state = false; });
  };
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.clear, 1);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs[0].status, 'clear');
  assert.equal(w.world.logs[0].details.reason, 'closed_before_send');
  assert.equal(w.world.snapshotCalls.get(HOME_A), 2, 'tam iki goruntu');
});

test('yeniden goruntu: arada cihaz cevrimdisi oldu -> skipped_offline (yeniden denenecek), push yok', async () => {
  const w = standardWorld();
  w.world.onSnapshot = (n) => {
    if (n === 2) w.world.devices[0].is_online = false;
  };
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.skippedOffline, 1);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs[0].details.reason, 'went_offline');
});

test('yeniden goruntu: arada baska lamba da acildi -> gonderilen metin/sayi GUNCEL goruntuden', async () => {
  const w = standardWorld();
  w.world.onSnapshot = (n) => {
    if (n === 2) w.world.endpoints.find((e) => e.id === 'ep-2').current_state = true;
  };
  const { reminder, push } = make(w);
  await tick(w, reminder, T_2330);
  assert.equal(push.calls.send[0].body, 'S:2L0S');
  assert.equal(push.calls.send[0].data.open_lights, '2');
  assert.equal(w.world.logs[0].open_lights_count, 2);
});

// ------------------------------------------------------------------------------
// Alicilar / push durumlari
// ------------------------------------------------------------------------------
test('alici yok -> no_recipients (details.reason=no_tokens), push gonderilmez ama sayilar/ozet kayitta', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w, { push: makeFakePush({ recipients: [] }) });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.noRecipients, 1);
  assert.equal(push.calls.send.length, 0);
  const row = w.world.logs[0];
  assert.equal(row.status, 'no_recipients');
  assert.equal(row.details.reason, 'no_tokens');
  assert.equal(row.open_lights_count, 1);
  assert.equal(row.summary_text, 'S:1L0S', 'uygulama ici yedek icin ozet saklanir');
});

test('push yapilandirilmamis -> no_recipients (reason=push_not_configured), KAYIT yazilir, alici sorgulanmaz', async () => {
  const w = standardWorld();
  const { reminder, push } = make(w, { push: makeFakePush({ configured: false }) });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.noRecipients, 1);
  assert.equal(push.calls.recipients.length, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs.length, 1);
  assert.equal(w.world.logs[0].status, 'no_recipients');
  assert.equal(w.world.logs[0].details.reason, 'push_not_configured');
  assert.equal(w.world.logs[0].open_lights_count, 1);
});

test('sendNotice PUSH_NOT_CONFIGURED dondururse (isConfigured yoksa) -> no_recipients', async () => {
  const w = standardWorld();
  const push = makeFakePush({ result: { attempted: 0, sent: 0, failed: 0, disabledTokenIds: [], transient: false, errors: [{ code: 'PUSH_NOT_CONFIGURED' }] } });
  delete push.isConfigured;
  const { reminder } = make(w, { push });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.noRecipients, 1);
  assert.equal(w.world.logs[0].details.reason, 'push_not_configured');
});

test('gecici push hatasi (429/5xx) -> failed; sonraki turda yeniden denenir ve gonderilir (deneme 2)', async () => {
  const w = standardWorld();
  let n = 0;
  const push = makeFakePush({
    result: () => {
      n += 1;
      return n === 1
        ? { attempted: 2, sent: 0, failed: 2, disabledTokenIds: [], transient: true, errors: [{ status: 503 }] }
        : { attempted: 2, sent: 2, failed: 0, disabledTokenIds: [], transient: false, errors: [] };
    },
  });
  const { reminder } = make(w, { push });
  const first = await tick(w, reminder, T_2330);
  assert.equal(first.failed, 1);
  assert.equal(w.world.logs[0].status, 'failed');
  assert.equal(w.world.logs[0].details.reason, 'push_transient');
  const second = await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(second.sent, 1);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.equal(w.world.logs[0].attempts, 2);
  assert.equal(push.calls.send.length, 2);
});

test('tum token\'lar kalici gecersiz (404/UNREGISTERED) -> no_recipients(reason=push_rejected), yeniden denenmez', async () => {
  const w = standardWorld();
  const push = makeFakePush({ result: { attempted: 2, sent: 0, failed: 2, disabledTokenIds: ['tok-1', 'tok-2'], transient: false, errors: [{ status: 404, code: 'UNREGISTERED' }] } });
  const { reminder } = make(w, { push });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.noRecipients, 1);
  assert.equal(w.world.logs[0].details.reason, 'push_rejected');
  assert.equal((await tick(w, reminder, '2026-10-01T20:31:20Z')).candidates, 0);
});

test('kismi basari (1 gitti, 1 gecersiz) -> sent, push_sent_count=1', async () => {
  const w = standardWorld();
  const push = makeFakePush({ result: { attempted: 2, sent: 1, failed: 1, disabledTokenIds: ['tok-2'], transient: false, errors: [{ status: 404 }] } });
  const { reminder } = make(w, { push });
  await tick(w, reminder, T_2330);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.equal(w.world.logs[0].push_sent_count, 1);
});

test('sendNotice istisna firlatirsa -> failed; mesaj/token LOGLANMAZ; sonraki turda yeniden denenir', async () => {
  const w = standardWorld();
  const boom = Object.assign(new Error('POST https://fcm/xyz token=FAKE-TOKEN-AAAA-0000000001 patladi'), { code: 'ECONNRESET' });
  const push = makeFakePush({ throwError: boom });
  const { reminder, logger } = make(w, { push });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.failed, 1);
  assert.equal(w.world.logs[0].status, 'failed');
  assert.equal(w.world.logs[0].details.reason, 'push_exception');
  const all = logger.lines.join('\n');
  assert.match(all, /ECONNRESET/);
  assert.equal(all.includes('FAKE-TOKEN'), false);
  assert.equal(all.includes('patladi'), false);
  push.throwError = null;
  assert.equal((await tick(w, reminder, '2026-10-01T20:31:20Z')).sent, 1);
});

test('LOG SIZINTISI: token, baslik, govde, oda adi ve ev adi hicbir log satirinda gecmez', async () => {
  const w = standardWorld();
  const { reminder, logger } = make(w);
  await tick(w, reminder, T_2330);
  await tick(w, reminder, '2026-10-01T20:31:20Z');
  const all = logger.lines.join('\n');
  for (const secret of ['FAKE-TOKEN', 'Salon', 'Mutfak', 'Gül', 'S:1L0S', 'T:']) assert.equal(all.includes(secret), false, secret);
  assert.match(all, /\[PEACE\]/);
});

test('SALT-OKUNUR sozlesme: endpoints tablosuna yazilmaz, MQTT yok; yazmalar yalniz peace_notification_logs', async () => {
  const w = standardWorld();
  const { reminder } = make(w);
  await tick(w, reminder, T_2330);
  const writes = w.db.calls.filter((c) => /^\s*(INSERT|UPDATE|DELETE)/i.test(c.text));
  assert.ok(writes.length >= 2);
  for (const c of writes) assert.match(c.text, /peace_notification_logs/, c.text.slice(0, 50));
  assert.equal(w.db.calls.some((c) => /endpoints SET|INTO endpoints|DELETE FROM endpoints/i.test(c.text) && /^\s*(INSERT|UPDATE|DELETE)/i.test(c.text)), false);
  const src = require('node:fs').readFileSync(require.resolve('../../src/peace_reminder.js'), 'utf8');
  assert.equal(/publishCommand|mqtt/i.test(src.replace(/\/\/.*$/gm, '')), false, 'degerlendirici MQTT kullanmaz');
});

// ------------------------------------------------------------------------------
// Ortam: DRY_RUN, kill switch, allowlist, catchup
// ------------------------------------------------------------------------------
test('DRY_RUN: degerlendirir ve loglar; claim YAZMAZ, push GONDERMEZ, bakim yapmaz; log tekrarlanmaz', async () => {
  const w = standardWorld();
  const { reminder, push, logger } = make(w, { env: { PEACE_REMINDER_DRY_RUN: 'true' } });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.dryRun, 1);
  assert.equal(r.claimed, 0);
  assert.equal(w.world.logs.length, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(push.calls.recipients.length, 0);
  assert.equal(push.calls.cleanup.length, 0);
  assert.equal(w.world.purged, 0);
  assert.equal(w.db.calls.some((c) => /^\s*(INSERT|UPDATE|DELETE)/i.test(c.text)), false);
  await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(logger.lines.filter((l) => /DRY_RUN ev/.test(l)).length, 1);
  assert.match(logger.lines.find((l) => /DRY_RUN ev/.test(l)), /1 lamba/);
});

test('KILL SWITCH: PEACE_REMINDER_ENABLED=false -> start no-op (zamanlayici yok, DB yok), runTick bos', async () => {
  const w = standardWorld();
  const { reminder, timers, logger } = make(w, { env: { PEACE_REMINDER_ENABLED: 'false' } });
  assert.equal(reminder.start(), reminder);
  assert.equal(reminder.isRunning(), false);
  assert.equal(timers.pending().length, 0);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.zones, 0);
  assert.equal(w.db.calls.length, 0);
  assert.equal(w.world.logs.length, 0);
  assert.match(logger.lines.join('\n'), /PEACE_REMINDER_ENABLED=false/);
});

test('ALLOWLIST: doluysa yalniz listedeki evler islenir; gecersiz girdiler yok sayilir; hepsi gecersiz = kimse', async () => {
  const mk = (env) => {
    const w = standardWorld({
      extraHomes: [{ id: HOME_B, name: 'B' }],
      extraDevices: [{ id: DEV_B, home_id: HOME_B, is_online: true, last_seen_ms: at(T_2330) - 1000 }],
      extraEndpoints: [{ id: 'b-1', device_id: DEV_B, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 }],
    });
    return { w, ...make(w, { env }) };
  };
  const only = mk({ PEACE_REMINDER_HOME_ALLOWLIST: ` ${HOME_B.toUpperCase()} , not-a-uuid` });
  const r1 = await tick(only.w, only.reminder, T_2330);
  assert.equal(r1.sent, 1);
  assert.deepEqual(only.w.world.logs.map((l) => l.home_id), [HOME_B]);
  assert.deepEqual(only.w.db.calls.find((c) => c.text === SQL.zones).params, [[HOME_B]]);
  only.reminder.start();
  assert.match(only.logger.lines.join('\n'), /PEACE_REMINDER_HOME_ALLOWLIST: gecersiz/);

  const nobody = mk({ PEACE_REMINDER_HOME_ALLOWLIST: 'garbage' });
  const r2 = await tick(nobody.w, nobody.reminder, T_2330);
  assert.equal(r2.candidates, 0);
  assert.equal(nobody.w.world.logs.length, 0);

  const everyone = mk({});
  assert.equal((await tick(everyone.w, everyone.reminder, T_2330)).sent, 2);
  assert.deepEqual(everyone.w.db.calls.find((c) => c.text === SQL.zones).params, [null]);
});

test('parseConfig: varsayilanlar, bool bicimleri, PEACE_CATCHUP_MIN sinirlari', () => {
  assert.deepEqual(H.parseConfig({}), { enabled: true, dryRun: false, allowlist: null, catchupMin: 60, maxAttempts: H.maxAttemptsFor(60), warnings: [] });
  assert.equal(H.parseConfig({ PEACE_REMINDER_ENABLED: 'FALSE' }).enabled, false);
  assert.equal(H.parseConfig({ PEACE_REMINDER_ENABLED: '0' }).enabled, false);
  assert.equal(H.parseConfig({ PEACE_REMINDER_ENABLED: 'garip' }).enabled, false, 'anlasilmayan deger kill switch icin GUVENLI taraf (kapali)');
  assert.equal(H.parseConfig({ PEACE_REMINDER_DRY_RUN: '1' }).dryRun, true);
  assert.equal(H.parseConfig({ PEACE_REMINDER_DRY_RUN: 'nope' }).dryRun, true, 'anlasilmayan deger DRY_RUN icin GUVENLI taraf (acik)');
  assert.equal(H.parseConfig({ PEACE_CATCHUP_MIN: '30' }).catchupMin, 30);
  for (const bad of ['0', '-5', '721', '1.5', 'abc']) {
    const c = H.parseConfig({ PEACE_CATCHUP_MIN: bad });
    assert.equal(c.catchupMin, 60, bad);
    assert.equal(c.warnings.length, 1, bad);
  }
});

test('PEACE_CATCHUP_MIN=10 pencereyi daraltir', async () => {
  const w = standardWorld();
  const { reminder } = make(w, { env: { PEACE_CATCHUP_MIN: '10' } });
  const r = await tick(w, reminder, '2026-10-01T20:41:20Z'); // delta 11
  assert.equal(r.candidates, 0);
  w.world.devices[0].last_seen_ms = at('2026-10-01T20:40:10Z');
  const ok = await tick(w, reminder, '2026-10-01T20:40:20Z'); // delta 10
  assert.equal(ok.candidates, 1);
  assert.equal(ok.sent, 1);
});

// ------------------------------------------------------------------------------
// NULL kurallari / bozuk veri
// ------------------------------------------------------------------------------
test('peace_notification_time NULL -> 23:30 sayilir; peace_notification_enabled NULL -> etkin', async () => {
  const w = standardWorld({ homeOverrides: { peace_notification_time: null, peace_notification_enabled: null } });
  const { reminder } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
});

test('peace_notification_enabled=false olan ev hic aday olmaz', async () => {
  const w = standardWorld({ homeOverrides: { peace_notification_enabled: false } });
  const { reminder } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.zones, 0);
  assert.equal(r.candidates, 0);
});

test('bozuk saat bicimi -> 23:30 kullanilir ve TEK uyari yazilir', async () => {
  const w = standardWorld({ homeOverrides: { peace_notification_time: '9.5' } });
  const { reminder, logger } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(logger.lines.filter((l) => /gecersiz saat bicimi/.test(l)).length, 1);
});

test('gecersiz saat dilimi -> Europe/Istanbul + tek uyari; evde cihaz yoksa ev aday olmaz', async () => {
  const w = standardWorld({ homeOverrides: { timezone: 'Yok/Boyle' } });
  const { reminder, logger } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  assert.equal(logger.lines.filter((l) => /Gecersiz saat dilimi/.test(l)).length, 1);

  const empty = makePeaceWorld({ homes: [{ id: HOME_A, name: 'Bos' }], devices: [], endpoints: [] });
  const second = make(empty);
  const r2 = await tick(empty, second.reminder, T_2330);
  assert.equal(r2.zones, 0);
});

// ------------------------------------------------------------------------------
// Oz-denetim
// ------------------------------------------------------------------------------
function schemaWithout(missing) {
  const rows = [];
  for (const [table, columns] of Object.entries(H.REQUIRED_SCHEMA)) {
    for (const column of columns) if (!missing.includes(`${table}.${column}`)) rows.push({ table_name: table, column_name: column });
  }
  return rows;
}

test('OZ-DENETIM basarisiz (push_tokens tablosu yok): TEK error logu, hatirlatma BEKLER (kalici kapanmaz), start FIRLATMAZ', async () => {
  const w = makePeaceWorld({
    homes: [{ id: HOME_A, name: 'x' }],
    devices: [{ id: DEV_A, home_id: HOME_A, is_online: true, last_seen_ms: at(T_2330) }],
    endpoints: [],
    schemaRows: schemaWithout(['push_tokens.id', 'push_tokens.user_id', 'push_tokens.token', 'push_tokens.disabled_at']),
  });
  w.world.clock.ms = at(T_2330);
  const { reminder, timers, logger } = make(w);
  assert.doesNotThrow(() => reminder.start());
  assert.equal(await reminder.ready(), false);
  assert.equal(reminder.isRunning(), true, 'zamanlayici kapanmaz: sema sonradan tamamlanabilir (rolling deploy)');
  assert.equal(timers.pending().length, 1);
  assert.equal(logger.lines.filter((l) => l.startsWith('error:')).length, 1);
  assert.match(logger.lines.join('\n'), /push_tokens\.token/);
  const r = await reminder.runTick(w.world.clock.ms);
  assert.equal(r.zones, 0);
  assert.equal(w.db.count(SQL.zones), 0, 'sema eksikken gece sorgulari calismaz');
  assert.equal(w.db.count(SQL.selfCheck), 1, '5 dk dolmadan yeniden denetim yok');
});

test('OZ-DENETIM: homes.timezone ve peace_notification_logs.local_date eksikse de devre disi', async () => {
  for (const missing of ['homes.timezone', 'peace_notification_logs.local_date']) {
    const w = makePeaceWorld({ homes: [], devices: [], endpoints: [], schemaRows: schemaWithout([missing]) });
    const { reminder, logger } = make(w);
    assert.equal(await reminder.ready(), false, missing);
    assert.match(logger.lines.join('\n'), new RegExp(missing.replace('.', '\\.')));
  }
});

test('OZ-DENETIM sorgusu GECICI hatayla basarisiz olursa kalici devre disi birakmaz: sonraki turda yeniden denenir', async () => {
  const w = standardWorld();
  let failed = false;
  w.world.failOn = (text) => {
    if (text === SQL.selfCheck && !failed) {
      failed = true;
      return new Error('baglanti yok');
    }
    return null;
  };
  const { reminder, logger } = make(w);
  const first = await tick(w, reminder, T_2330);
  assert.equal(first.sent, 0);
  assert.match(logger.lines.join('\n'), /Sema oz-denetimi yapilamadi/);
  const second = await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(second.sent, 1);
});

// ------------------------------------------------------------------------------
// Sinirlar ve hata yalitimi
// ------------------------------------------------------------------------------
test('TICK BASINA 500 EV: 520 ev iki turda islenir (islenmisler elenir), hicbiri iki kez', async () => {
  const homes = [];
  const devices = [];
  const endpoints = [];
  const clock = { ms: at(T_2330) };
  for (let i = 1; i <= 520; i++) {
    const hid = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    const did = `dddddddd-0000-4000-8000-${String(i).padStart(12, '0')}`;
    homes.push({ id: hid, name: `Ev ${i}` });
    devices.push({ id: did, home_id: hid, is_online: true, last_seen_ms: clock.ms - 1000 });
    endpoints.push({ id: `e${i}`, device_id: did, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 });
  }
  const w = { ...makePeaceWorld({ clock, homes, devices, endpoints }), clock };
  const { reminder, push } = make(w);
  const first = await tick(w, reminder, T_2330);
  assert.equal(first.candidates, 500);
  assert.equal(first.sent, 500);
  const second = await tick(w, reminder, '2026-10-01T20:30:25Z');
  assert.equal(second.candidates, 20);
  assert.equal(second.sent, 20);
  const third = await tick(w, reminder, '2026-10-01T20:30:30Z');
  assert.equal(third.candidates, 0);
  assert.equal(push.calls.send.length, 520);
  assert.equal(new Set(push.calls.send.map((c) => c.data.home_id)).size, 520, 'her ev tam bir kez');
  assert.equal(w.db.calls.find((c) => c.text === SQL.candidates).params[2], 500, 'LIMIT parametresi');
});

test('EV BASINA HATA digerlerini durdurmaz (claim hatasi ve degerlendirme hatasi)', async () => {
  const w = standardWorld({
    extraHomes: [{ id: HOME_B, name: 'B' }, { id: HOME_C, name: 'C' }],
    extraDevices: [
      { id: DEV_B, home_id: HOME_B, is_online: true, last_seen_ms: at(T_2330) - 1000 },
      { id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', home_id: HOME_C, is_online: true, last_seen_ms: at(T_2330) - 1000 },
    ],
    extraEndpoints: [
      { id: 'b-1', device_id: DEV_B, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 },
      { id: 'c-1', device_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 },
    ],
  });
  let snapshotFailed = false;
  w.world.failOn = (text, params) => {
    if (text === SQL.claim && params[0] === HOME_B) return new Error('claim patladi');
    if (text === require('../../src/services/peace_snapshot').SQL.snapshot && params[0] === HOME_C && !snapshotFailed) {
      snapshotFailed = true;
      return new Error('snapshot patladi');
    }
    return null;
  };
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1, 'HOME_A gitti');
  assert.equal(r.failed, 2);
  assert.equal(r.errors.length, 1, 'yalniz claim hatasi tur hatasi olarak yukselir');
  assert.equal(r.errors[0].home, HOME_B.slice(0, 8));
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs.find((l) => l.home_id === HOME_C).status, 'failed', 'degerlendirme hatasi kaydi failed yapar');
  // HOME_C sonraki turda yeniden denenir ve gider; HOME_B de (claim artik calisiyor)
  w.world.failOn = null;
  const next = await tick(w, reminder, '2026-10-01T20:31:20Z');
  assert.equal(next.sent, 2);
});

test('EV BASINA ZAMAN ASIMI (15 sn): takili bir ev diger evleri ve turu KILITLEMEZ', async () => {
  const w = standardWorld({
    extraHomes: [{ id: HOME_B, name: 'B' }],
    extraDevices: [{ id: DEV_B, home_id: HOME_B, is_online: true, last_seen_ms: at(T_2330) - 1000 }],
    extraEndpoints: [{ id: 'b-1', device_id: DEV_B, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 }],
  });
  const push = makeFakePush();
  push.sendNotice = async (args) => {
    push.calls.send.push(args);
    if (args.data.home_id === HOME_B) return new Promise(() => {}); // asla donmez
    return push.result;
  };
  const { reminder, timers } = make(w, { push });
  w.clock.ms = at(T_2330);
  const pending = reminder.runTick(w.clock.ms);
  await flush(5);
  const guard = timers.pending().filter((t) => t.ms === H.HOME_TIMEOUT_MS);
  assert.ok(guard.length >= 1, 'ev basina 15 sn zaman asimi kurulmus olmali');
  guard.forEach((t) => timers.fire(t));
  const r = await pending;
  assert.equal(r.sent, 1);
  assert.equal(r.failed, 1);
  assert.match(r.errors[0].message, /zaman asimina ugradi/);
});

test('hatali metin uretici bildirimi susturmaz: yedek cumle/baslik kullanilir', async () => {
  const w = standardWorld();
  const text = { buildTitle: () => { throw new Error('baslik bozuk'); }, buildSummary: () => { throw new Error('ozet bozuk'); } };
  const { reminder, push } = make(w, { deps: { text } });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  assert.equal(push.calls.send[0].body, '1 lamba açık.');
  assert.equal(push.calls.send[0].title, 'Gül Apartmanı 5');
});

test('varsayilan metin uretici tembel yuklenir (peace_text varsa)', async () => {
  let real;
  try {
    real = require('../../src/services/peace_text');
  } catch (_) {
    return; // baska ajanin dosyasi henuz yok: test atlanir
  }
  const w = standardWorld();
  const { reminder, push } = make(w, { deps: { text: null } });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  assert.equal(push.calls.send[0].body, real.buildSummary({ lights: [{ room: 'Salon' }], shutters: [] }));
  assert.equal(push.calls.send[0].title, real.buildTitle('Gül Apartmanı 5'));
});

// ------------------------------------------------------------------------------
// Yasam dongusu ve bakim
// ------------------------------------------------------------------------------
test('start(): dakika siniri + 20 sn\'ye zamanlar; zamanlayici tetiklenince tur kosar ve yeniden zamanlar', async () => {
  const w = standardWorld();
  w.clock.ms = at('2026-10-01T20:30:05Z');
  const { reminder, timers } = make(w);
  assert.equal(reminder.start(), reminder);
  assert.equal(reminder.start(), reminder, 'idempotent');
  assert.equal(reminder.isRunning(), true);
  const [t1] = timers.pending();
  assert.equal(timers.pending().length, 1);
  assert.equal(t1.ms, 55000 + H.TICK_OFFSET_MS, 'sonraki dakika sinirindan 20 sn sonra');

  w.clock.ms = at('2026-10-01T20:30:20Z'); // 23:30:20 yerel
  await reminder.ready();
  await timers.fire(t1);
  await flush(5);
  assert.equal(w.world.logs.length, 1);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.equal(timers.pending().length, 1, 'bir sonraki tur zamanlandi');
  await reminder.stop();
});

test('stop(): zamanlayiciyi TEMIZLER, yeni tur planlanmaz; calisan tur beklenir', async () => {
  const w = standardWorld();
  const { reminder, timers } = make(w);
  reminder.start();
  await reminder.ready();
  assert.equal(timers.pending().length, 1);
  await reminder.stop();
  assert.equal(timers.pending().length, 0);
  assert.equal(reminder.isRunning(), false);
  await reminder.stop(); // ikinci stop zararsiz
});

test('modul start(): ornek doner; eksik/hatali bagimlilik TypeError', () => {
  const w = standardWorld();
  const timers = makeFakeTimers();
  const inst = start({ db: w.db, push: makeFakePush(), text: makeFakeText(), logger: makeLogger(), now: () => w.clock.ms, setTimer: timers.setTimer, clearTimer: timers.clearTimer, env: {} });
  assert.ok(inst instanceof PeaceReminder);
  assert.equal(inst.isRunning(), true);
  assert.equal(timers.pending().length, 1);
  assert.throws(() => start({ push: makeFakePush() }), TypeError);
  assert.throws(() => start({ db: w.db }), TypeError);
  assert.throws(() => start({ db: w.db, push: {} }), TypeError);
  assert.throws(() => start(), TypeError);
});

test('BAKIM gunde bir: ilk turda, sonra 24 saatte bir (90 gun kayit + 30 gun token)', async () => {
  const w = standardWorld({ lampOn: false });
  const { reminder, push } = make(w);
  w.clock.ms = at('2026-10-01T10:00:00Z');
  await reminder.runTick(w.clock.ms);
  assert.equal(w.world.purged, 1);
  assert.deepEqual(w.db.calls.find((c) => c.text === SQL.purgeLogs).params, [90]);
  assert.deepEqual(push.calls.cleanup, [{ olderThanDays: 30 }]);

  await reminder.runTick(at('2026-10-01T11:00:00Z'));
  await reminder.runTick(at('2026-10-02T09:59:00Z'));
  assert.equal(w.world.purged, 1, '24 saat dolmadi');
  await reminder.runTick(at('2026-10-02T10:00:00Z'));
  assert.equal(w.world.purged, 2);
  assert.equal(push.calls.cleanup.length, 2);
});

test('bakim hatasi turu bozmaz (uyari yazilir)', async () => {
  const w = standardWorld();
  w.world.failOn = (text) => (text === SQL.purgeLogs ? new Error('silme patladi') : null);
  const push = makeFakePush();
  push.cleanup = async () => {
    throw Object.assign(new Error('token=SECRET-XYZ'), { code: 'CLEANUP_ERR' });
  };
  const { reminder, logger } = make(w, { push });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  const all = logger.lines.join('\n');
  assert.match(all, /Bildirim kaydi temizligi hatasi/);
  assert.match(all, /CLEANUP_ERR/);
  assert.equal(all.includes('SECRET-XYZ'), false);
});

// ------------------------------------------------------------------------------
// Statik SQL
// ------------------------------------------------------------------------------
test('SQL sozlesmesi: atomik talep, NULL kurallari, UNIQUE anahtari, parametreli saat dilimi', () => {
  assert.match(SQL.claim, /ON CONFLICT \(home_id, local_date\) DO UPDATE/);
  assert.match(SQL.claim, /RETURNING id, attempts/);
  assert.match(SQL.claim, /attempts < \$4/);
  assert.match(SQL.claim, /status IN \('skipped_offline', 'failed'\)/);
  assert.match(SQL.claim, /updated_at <= CURRENT_TIMESTAMP - \(CASE/, 'yeniden deneme araligi');
  assert.match(SQL.claim, /INTERVAL '2 minutes'/);
  assert.match(SQL.candidates, /COALESCE\(h\.peace_notification_enabled, TRUE\)/);
  assert.match(SQL.candidates, /COALESCE\(h\.peace_notification_time, '23:30'\)/);
  assert.match(SQL.candidates, /COALESCE\(h\.timezone, 'Europe\/Istanbul'\) = \$1/);
  assert.match(SQL.candidates, /ANY\(\$2::text\[\]\)/);
  assert.match(SQL.candidates, /LEFT JOIN peace_notification_logs l ON l\.home_id = h\.id/);
  assert.match(SQL.candidates, /ORDER BY COALESCE\(l\.attempts, 0\), h\.id LIMIT \$3/);
  assert.match(SQL.zones, /COALESCE\(h\.peace_notification_enabled, TRUE\)/);
  assert.match(SQL.finish, /WHERE id = \$1 AND status IN \('claimed', 'sending'\) AND attempts = \$8/);
  for (const sql of Object.values(SQL)) assert.doesNotMatch(sql, /\bendpoints\b.*\b(SET|VALUES)\b/i);
  assert.equal(helpers.MAX_ATTEMPTS, undefined, 'sabit 6 deneme siniri kaldirildi (pencereyi tuketiyordu)');
  assert.equal(helpers.MAX_HOMES_PER_TICK, 500);
  assert.equal(helpers.CONCURRENCY, 10);
});

test('classifyPushResult / buildDetails: durum eslemesi ve kisisel veri icermeyen kayit', () => {
  assert.deepEqual(H.classifyPushResult({ attempted: 2, sent: 1, failed: 1 }), { status: 'sent', push: { attempted: 2, sent: 1, failed: 1, failed_other: 1 } });
  assert.deepEqual(H.classifyPushResult({ attempted: 2, sent: 2, failed: 0 }), { status: 'sent', push: { attempted: 2, sent: 2, failed: 0 } });
  assert.equal(H.classifyPushResult({ attempted: 1, sent: 0, failed: 1, transient: true }).status, 'failed');
  assert.equal(H.classifyPushResult({ attempted: 0, sent: 0, failed: 0 }).reason, 'no_tokens');
  assert.equal(H.classifyPushResult(undefined).status, 'no_recipients');
  assert.equal(H.classifyPushResult({ errors: [{ code: 'PUSH_NOT_CONFIGURED' }] }).reason, 'push_not_configured');
  const d = H.buildDetails({ lights: [{ endpointId: 'e', channel: 3, room: 'Salon', name: 'GIZLI' }], shutters: [{ pair: 1, room: 'Salon', position: 100 }] }, { reason: 'x' });
  assert.deepEqual(d, { lights: [{ endpoint_id: 'e', channel: 3, room: 'Salon' }], shutters: [{ pair: 1, room: 'Salon', pos: 100 }], reason: 'x' });
  assert.deepEqual(H.buildDetails(null), { lights: [], shutters: [] });
});

// ==============================================================================
// Duzeltme turu (evaluator fixer): yeniden deneme penceresi, kismi cevrimdisi ev, en cok bir push,
// guvenli ortam anahtarlari, rolling-deploy sema denetimi, kismi FCM basarisi, push_error ayrimi
// ==============================================================================
const isoAt = (k) => new Date(at(T_2330) + k * MIN).toISOString(); // T_2330 + k dakika
const keepLive = (w, iso) => w.world.devices.forEach((d) => { d.is_online = true; d.last_seen_ms = at(iso) - 5000; });

test('YENIDEN DENEME ARALIGI: skipped_offline 1,1,2,2,5 dk aralikla denenir (dakikada bir degil), pencere sonuna kadar surer', async () => {
  const w = standardWorld({ deviceOverrides: { is_online: false } });
  const { reminder } = make(w);
  const attemptTicks = [];
  for (let k = 0; k <= 62; k++) {
    const r = await tick(w, reminder, isoAt(k));
    if (r.skippedOffline === 1) attemptTicks.push(k);
  }
  // 1. deneme k0; sonraki bosluklar: deneme sayisina gore 1, 1, 2, 2, ardindan 5 dk
  assert.deepEqual(attemptTicks.slice(0, 7), [0, 1, 2, 4, 6, 11, 16]);
  const last = attemptTicks[attemptTicks.length - 1];
  assert.ok(last >= 55 && last <= 60, `son deneme pencere sonuna yakin olmali (k=${last})`);
  assert.equal(w.world.logs[0].attempts, attemptTicks.length);
  assert.ok(w.world.logs[0].attempts <= H.maxAttemptsFor(60), 'deneme sigortasi pencereyi KESMEZ');
  assert.ok(w.world.logs[0].attempts > 6, 'eski sabit 6 deneme siniri artik pencereyi tuketmez');
  // pencere bitince (delta 61) aday olmaz
  assert.equal((await tick(w, reminder, isoAt(61))).candidates, 0);
  assert.equal(w.world.logs[0].status, 'skipped_offline');
});

test('8 DAKIKALIK KESINTI: cihaz 23:38\'de acik lambayla donunce pencere icinde TEK bildirim gider (eski kod 6. dakikada vazgeciyordu)', async () => {
  const w = standardWorld({ deviceOverrides: { is_online: false } });
  const { reminder, push } = make(w);
  let sentAt = null;
  for (let k = 0; k <= 20 && sentAt === null; k++) {
    if (k >= 8) keepLive(w, isoAt(k)); // k=8: 23:38 cihaz geri geldi, lamba hala acik
    const r = await tick(w, reminder, isoAt(k));
    if (r.sent === 1) sentAt = k;
  }
  assert.ok(sentAt !== null && sentAt >= 8 && sentAt <= 12, `donusten hemen sonra bildirilmeli (k=${sentAt})`);
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.ok(w.world.logs[0].attempts >= 6, 'ilk denemeler 11 dakikaya yayildi (eski kod 6 denemeyi 6 dakikada tuketiyordu)');
  assert.equal(w.world.logs.length, 1);
});

test('7 DAKIKALIK FCM kesintisi (5xx): failed satiri aralikla yeniden denenir, kesinti bitince TEK basarili push', async () => {
  const w = standardWorld();
  const outageEnd = at(T_2330) + 7 * MIN;
  const push = makeFakePush({
    result: () => (w.clock.ms < outageEnd
      ? { attempted: 2, sent: 0, failed: 2, disabledTokenIds: [], transient: true, errors: [{ status: 503, code: 'UNAVAILABLE' }] }
      : { attempted: 2, sent: 2, failed: 0, disabledTokenIds: [], transient: false, errors: [] }),
  });
  const { reminder } = make(w, { push });
  let sentAt = null;
  for (let k = 0; k <= 14 && sentAt === null; k++) {
    keepLive(w, isoAt(k));
    if ((await tick(w, reminder, isoAt(k))).sent === 1) sentAt = k;
  }
  assert.ok(sentAt !== null && sentAt >= 7, `kesinti bitince gonderilmeli (k=${sentAt})`);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.ok(w.world.logs[0].attempts > 5, 'uzun kesinti 6 denemeye sigdirilmadi');
  assert.equal(push.calls.send.filter((c) => c).length, w.world.logs[0].attempts, 'her deneme bir gonderim denemesi');
});

test('yeniden deneme yardimcilari: aralik basamaklari, toleransli SQL CASE, pencereyi asan deneme sigortasi', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 50].map(H.retryGapSec), [60, 60, 120, 120, 300, 300]);
  assert.deepEqual([1, 3, 5].map(H.retryDueSec), [50, 110, 290], 'tur ms kaymasi icin 10 sn tolerans');
  assert.equal(H.retryDueSql('x.attempts'), '(CASE WHEN x.attempts <= 2 THEN 50 WHEN x.attempts <= 4 THEN 110 ELSE 290 END)');
  assert.match(SQL.claim, /updated_at <= CURRENT_TIMESTAMP - \(CASE WHEN peace_notification_logs\.attempts <= 2 THEN 50/);
  assert.match(SQL.candidates, /l\.updated_at <= CURRENT_TIMESTAMP - \(CASE WHEN l\.attempts <= 2 THEN 50/);
  // 60 dk pencerede ~15 deneme gerekir (1,1,2,2 sonra 5 dk'da bir); sigorta bunun USTUNDE
  assert.ok(H.maxAttemptsFor(60) >= 15 + 2);
  assert.ok(H.maxAttemptsFor(720) > H.maxAttemptsFor(60));
  assert.ok(H.maxAttemptsFor(1) >= 2);
  assert.equal(H.parseConfig({ PEACE_CATCHUP_MIN: '30' }).maxAttempts, H.maxAttemptsFor(30));
});

test('ADAY SIRASI: denenmemis evler once; kalici cevrimdisi evler yeni evin 500\'luk dilimini isgal edemez', async () => {
  const homes = [];
  const devices = [];
  const endpoints = [];
  const clock = { ms: at(T_2330) };
  for (let i = 1; i <= 506; i++) {
    const hid = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    const did = `dddddddd-0000-4000-8000-${String(i).padStart(12, '0')}`;
    homes.push({ id: hid, name: `Ev ${i}` });
    // 1..505 kalici cevrimdisi; 506 canli (en BUYUK kimlik: eski ORDER BY h.id ile 500'luk dilimin disinda kalirdi)
    devices.push({ id: did, home_id: hid, is_online: i === 506, last_seen_ms: clock.ms - 1000 });
    endpoints.push({ id: `e${i}`, device_id: did, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'L', room: 'Salon', current_state: true, current_position: 0 });
  }
  const w = { ...makePeaceWorld({ clock, homes, devices, endpoints }), clock };
  const { reminder, push } = make(w);
  const first = await tick(w, reminder, T_2330);
  assert.equal(first.candidates, 500);
  assert.equal(push.calls.send.length, 0, 'ilk 500 ev cevrimdisi');
  keepLive(w, isoAt(1)); // tum cihazlar canli degil: yalniz 506 canli olmali
  w.world.devices.forEach((d, idx) => { d.is_online = idx === 505; });
  const second = await tick(w, reminder, isoAt(1));
  assert.equal(second.candidates, 500);
  assert.equal(second.sent, 1, 'canli ev 2. turda ONCE islenir');
  assert.equal(push.calls.send[0].data.home_id, homes[505].id);
});

// ------------------------------------------------------------------------------
// Kismi cevrimdisi ev (cok cihazli): bilinmeyen durum "temiz" sayilmaz
// ------------------------------------------------------------------------------
function twoBoardWorld({ boardBOnline = false, boardBLamp = true } = {}) {
  return standardWorld({
    lampOn: false,
    extraDevices: [{ id: DEV_B, home_id: HOME_A, is_online: boardBOnline, last_seen_ms: at(T_2330) - 10 * MIN }],
    extraEndpoints: [
      { id: 'b-1', device_id: DEV_B, type: 'light', channel_index: 1, shutter_pair_index: null, name: 'Yatak', room: 'Yatak Odasi', current_state: boardBLamp, current_position: 0 },
    ],
  });
}

test('KISMI CEVRIMDISI: canli kartta hicbir sey acik degil ama diger kart cevrimdisi -> clear YAZILMAZ, skipped_offline (partial_offline)', async () => {
  const w = twoBoardWorld();
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.clear, 0);
  assert.equal(r.skippedOffline, 1);
  assert.equal(push.calls.send.length, 0, 'bayat veriyle bildirilmez');
  const row = w.world.logs[0];
  assert.equal(row.status, 'skipped_offline');
  assert.equal(row.details.reason, 'partial_offline');
  assert.equal(row.details.devices_live, 1);
  assert.equal(row.details.devices_total, 2);

  // 2. kart 23:40'ta lambasi ACIK donunce ayni gece bildirilir (clear nihai olsaydi bildirilmezdi)
  w.world.devices.find((d) => d.id === DEV_B).is_online = true;
  keepLive(w, isoAt(10));
  const later = await tick(w, reminder, isoAt(10));
  assert.equal(later.sent, 1);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.equal(w.world.logs.length, 1);
  assert.equal(w.world.logs[0].details.devices_live, undefined, 'tum cihazlar canliyken sayac yazilmaz');
});

test('KISMI CEVRIMDISI: tum cihazlar canli ve hicbir sey acik degil -> clear (nihai)', async () => {
  const w = twoBoardWorld({ boardBOnline: true, boardBLamp: false });
  w.world.devices.forEach((d) => { d.last_seen_ms = at(T_2330) - 5000; });
  const { reminder } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.clear, 1);
  assert.equal(w.world.logs[0].status, 'clear');
  assert.equal((await tick(w, reminder, isoAt(1))).candidates, 0);
});

test('KISMI CEVRIMDISI: acik lamba varsa push gider ve kayit canli/toplam cihaz sayisini tasir', async () => {
  const w = standardWorld({
    extraDevices: [{ id: DEV_B, home_id: HOME_A, is_online: false, last_seen_ms: at(T_2330) - 10 * MIN }],
    extraEndpoints: [],
  });
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs[0].details.devices_live, 1);
  assert.equal(w.world.logs[0].details.devices_total, 2);
});

test('KISMI CEVRIMDISI: gonderim oncesi yeniden goruntude her sey kapali + diger kart cevrimdisi -> clear degil skipped_offline', async () => {
  const w = standardWorld({
    extraDevices: [{ id: DEV_B, home_id: HOME_A, is_online: true, last_seen_ms: at(T_2330) - 5000 }],
    extraEndpoints: [],
  });
  w.world.onSnapshot = (n) => {
    if (n === 2) {
      w.world.endpoints.forEach((e) => { e.current_state = false; });
      w.world.devices.find((d) => d.id === DEV_B).is_online = false;
    }
  };
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.clear, 0);
  assert.equal(r.skippedOffline, 1);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.world.logs[0].details.reason, 'partial_offline');
  assert.equal(w.world.logs[0].open_lights_count, 0);
});

test('H.isPartiallyOffline: yalniz en az bir canli ve bazilari degil iken true', () => {
  assert.equal(H.isPartiallyOffline({ devicesTotal: 2, devicesLive: 1 }), true);
  assert.equal(H.isPartiallyOffline({ devicesTotal: 2, devicesLive: 2 }), false);
  assert.equal(H.isPartiallyOffline({ devicesTotal: 2, devicesLive: 0 }), false, 'hic canli yok zaten skipped_offline');
  assert.equal(H.isPartiallyOffline(null), false);
  assert.equal(H.isPartiallyOffline({}), false);
});

// ------------------------------------------------------------------------------
// En cok bir push: gonderimden once 'sending', gonderimden sonra 'failed'a dusme yok
// ------------------------------------------------------------------------------
test('PUSH SONRASI KAYIT YAZIMI bir kez basarisiz olursa: yeniden denenir, TEK push, nihai durum sent (attempts 1)', async () => {
  const w = standardWorld();
  let failed = 0;
  w.world.failOn = (text, params) => {
    if (text === SQL.finish && params[1] === 'sent' && failed === 0) {
      failed += 1;
      return new Error('baglanti koptu');
    }
    return null;
  };
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1);
  assert.equal(push.calls.send.length, 1);
  assert.equal(w.world.logs[0].status, 'sent');
  assert.equal(w.world.logs[0].attempts, 1);
  const later = await tick(w, reminder, isoAt(1));
  assert.equal(later.candidates, 0);
  assert.equal(push.calls.send.length, 1);
});

test('PUSH SONRASI KAYIT YAZIMI tamamen basarisiz: satir \'sending\' kalir, kira suresi dolsa da ikinci push GITMEZ; hata loglanir', async () => {
  const w = standardWorld();
  w.world.failOn = (text, params) => (text === SQL.finish && params[1] === 'sent' ? new Error('db kapali') : null);
  const { reminder, push, logger } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.sent, 1, 'push gitti: sonuc "sent" sayilir');
  assert.equal(w.db.calls.filter((c) => c.text === SQL.finish && c.params[1] === 'sent').length, H.FINISH_WRITE_TRIES);
  assert.equal(w.world.logs[0].status, 'sending');
  assert.match(logger.lines.join('\n'), /error: \[PEACE\] .*sending/);
  for (const k of [1, 3, 10, 30]) {
    keepLive(w, isoAt(k));
    const again = await tick(w, reminder, isoAt(k));
    assert.equal(again.candidates, 0, `k=${k}`);
  }
  // aday elemesi atlansa bile dogrudan talep kaybedilir (sending asla yeniden talep edilmez)
  const home = { id: HOME_A, name: 'x', raw_time: '23:30', peace_time: '23:30' };
  assert.deepEqual(await reminder._processHome(home, 'Europe/Istanbul', at(isoAt(30))), { status: 'lost' });
  assert.equal(push.calls.send.length, 1, 'gece boyunca TEK push');
  assert.equal(w.world.logs[0].status, 'sending');
});

test('talep ile gonderim arasinda kira devredildiyse (markSending 0 satir) push GONDERILMEZ', async () => {
  const w = standardWorld();
  w.world.onSnapshot = (n) => {
    if (n === 2) w.world.logs[0].attempts += 1; // baska ornek satiri devraldi
  };
  const { reminder, push } = make(w);
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.lost, 1);
  assert.equal(r.sent, 0);
  assert.equal(push.calls.send.length, 0);
  assert.equal(w.db.count(SQL.markSending), 1);
});

test('markSending SQL: yalniz kendi talebimiz (claimed + attempts) sending olur; finish claimed|sending kabul eder', () => {
  assert.match(SQL.markSending, /SET status = 'sending'/);
  assert.match(SQL.markSending, /WHERE id = \$1 AND status = 'claimed' AND attempts = \$2/);
  assert.match(SQL.finish, /status IN \('claimed', 'sending'\) AND attempts = \$8/);
  // 'sending' ne aday secimi ne talep sorgusunda yeniden denenebilir listede
  assert.doesNotMatch(SQL.claim, /sending/);
  assert.doesNotMatch(SQL.candidates, /sending/);
});

test('sendNotice istisnasi + kayit yazimi da basarisiz: satir \'sending\' kalir, yeniden gonderim yok (belirsiz teslim)', async () => {
  const w = standardWorld();
  w.world.failOn = (text, params) => (text === SQL.finish && params[1] === 'failed' ? new Error('db kapali') : null);
  const push = makeFakePush({ throwError: Object.assign(new Error('x'), { code: 'ECONNRESET' }) });
  const { reminder } = make(w, { push });
  const r = await tick(w, reminder, T_2330);
  assert.equal(r.failed, 1);
  assert.equal(w.world.logs[0].status, 'sending');
  push.throwError = null;
  keepLive(w, isoAt(5));
  assert.equal((await tick(w, reminder, isoAt(5))).candidates, 0);
  assert.equal(push.calls.send.length, 1);
});

// ------------------------------------------------------------------------------
// Guvenli ortam anahtarlari
// ------------------------------------------------------------------------------
test('GUVENLI ANAHTARLAR: DRY_RUN tanimsiz deger -> ACIK + uyari; ENABLED tanimsiz deger -> KAPALI + uyari', () => {
  for (const bad of ['ture', 'dry', 'flase', 'evet', '2']) {
    const c = H.parseConfig({ PEACE_REMINDER_DRY_RUN: bad });
    assert.equal(c.dryRun, true, bad);
    assert.equal(c.warnings.length, 1, bad);
    assert.match(c.warnings[0], /PEACE_REMINDER_DRY_RUN/);
  }
  for (const bad of ['disabled', 'flase', 'hayir', 'x']) {
    const c = H.parseConfig({ PEACE_REMINDER_ENABLED: bad });
    assert.equal(c.enabled, false, bad);
    assert.match(c.warnings[0], /PEACE_REMINDER_ENABLED/);
  }
  // taninan degerler ve bos deger: uyari yok, varsayilanlar
  const ok = H.parseConfig({ PEACE_REMINDER_ENABLED: ' TRUE ', PEACE_REMINDER_DRY_RUN: 'off' });
  assert.deepEqual([ok.enabled, ok.dryRun, ok.warnings.length], [true, false, 0]);
  const empty = H.parseConfig({ PEACE_REMINDER_ENABLED: '  ', PEACE_REMINDER_DRY_RUN: '' });
  assert.deepEqual([empty.enabled, empty.dryRun, empty.warnings.length], [true, false, 0]);
});

test('GUVENLI ANAHTARLAR uctan uca: DRY_RUN="ture" hic push gondermez ve uyarir; ENABLED="flase" start no-op', async () => {
  const w = standardWorld();
  const dry = make(w, { env: { PEACE_REMINDER_DRY_RUN: 'ture' } });
  dry.reminder.start();
  assert.match(dry.logger.lines.join('\n'), /warn: \[PEACE\] PEACE_REMINDER_DRY_RUN taninmayan/);
  const r = await tick(w, dry.reminder, T_2330);
  assert.equal(r.dryRun, 1);
  assert.equal(dry.push.calls.send.length, 0);
  assert.equal(w.world.logs.length, 0);

  const w2 = standardWorld();
  const off = make(w2, { env: { PEACE_REMINDER_ENABLED: 'flase' } });
  off.reminder.start();
  assert.equal(off.reminder.isRunning(), false);
  assert.equal(off.timers.pending().length, 0);
  assert.match(off.logger.lines.join('\n'), /PEACE_REMINDER_ENABLED taninmayan/);
  assert.equal((await tick(w2, off.reminder, T_2330)).zones, 0);
});

// ------------------------------------------------------------------------------
// Rolling deploy: sema sonradan tamamlanirsa yeniden baslatmadan etkinlesir
// ------------------------------------------------------------------------------
test('SEMA SONRADAN TAMAMLANIR (kod migration\'dan once basladi): zamanlayici kapanmaz, 5 dk\'da bir yeniden denetlenir, tamamlaninca ETKINLESIR', async () => {
  const w = standardWorld();
  const full = w.world.schemaRows;
  w.world.schemaRows = full.filter((r) => !(r.table_name === 'push_tokens' || r.column_name === 'local_date'));
  const { reminder, timers, logger } = make(w);
  reminder.start();
  assert.equal(await reminder.ready(), false);
  assert.equal(reminder.isRunning(), true, 'zamanlayici KAPANMAZ');
  assert.equal(timers.pending().length, 1);
  assert.equal(logger.lines.filter((l) => l.startsWith('error:')).length, 1, 'TEK error logu');
  assert.match(logger.lines.join('\n'), /BEKLEMEDE/);

  // migration uygulandi (operator PM2'yi yeniden baslatmadi)
  w.world.schemaRows = full;
  const early = await tick(w, reminder, T_2330); // < 5 dk: yeniden denetim yok, hala bekliyor
  assert.equal(early.zones, 0);
  assert.equal(w.db.count(SQL.selfCheck), 1);
  assert.equal(logger.lines.filter((l) => l.startsWith('error:')).length, 1, 'log bogulmaz');

  const t6 = at(T_2330) + 6 * MIN;
  w.world.devices[0].last_seen_ms = t6 - 5000;
  w.clock.ms = t6;
  const late = await reminder.runTick(t6); // runTick ready(nowMs) ile 5 dk'yi dolu gorur
  assert.equal(w.db.count(SQL.selfCheck), 2, '5 dk sonra yeniden denetlendi');
  assert.equal(late.sent, 1, 'sema tamamlaninca hatirlatma ayni surecte etkinlesti (pencere 23:36)');
  assert.match(logger.lines.join('\n'), /Sema tamamlandi/);
  assert.equal(await reminder.ready(), true);
  await reminder.stop();
});

test('eksik sema hata logu WARN_INTERVAL ile sinirlidir (her denetimde tekrarlanmaz)', async () => {
  const w = standardWorld();
  w.world.schemaRows = [];
  const { reminder, logger } = make(w);
  for (let k = 0; k < 4; k++) {
    w.clock.ms = at(T_2330) + k * 5 * MIN; // her tur yeni denetim (5 dk aralik)
    await reminder.runTick(w.clock.ms);
  }
  assert.equal(w.db.count(SQL.selfCheck), 4);
  assert.equal(logger.lines.filter((l) => l.startsWith('error:')).length, 2, '10 dk\'da bir (0 ve 10. dk)');
});

// ------------------------------------------------------------------------------
// Kismi FCM basarisi ve push_error ayrimi
// ------------------------------------------------------------------------------
test('KISMI FCM BASARISI (1 gitti, 1 gecici hata): sent, details.push.failed_other gozlemlenebilir, uyari loglanir, tekrar GONDERILMEZ', async () => {
  const w = standardWorld();
  const push = makeFakePush({ result: { attempted: 2, sent: 1, failed: 1, disabledTokenIds: [], transient: false, errors: [{ status: 503, code: 'UNAVAILABLE' }] } });
  const { reminder, logger } = make(w, { push });
  await tick(w, reminder, T_2330);
  const row = w.world.logs[0];
  assert.equal(row.status, 'sent');
  assert.equal(row.push_sent_count, 1);
  assert.deepEqual(row.details.push, { attempted: 2, sent: 1, failed: 1, failed_other: 1 });
  assert.match(logger.lines.join('\n'), /warn: \[PEACE\] Ev 11111111: 1 aliciya/);
  assert.equal(logger.lines.join('\n').includes('FAKE-TOKEN'), false);
  keepLive(w, isoAt(2));
  assert.equal((await tick(w, reminder, isoAt(2))).candidates, 0);
  assert.equal(push.calls.send.length, 1, 'cift bildirim olmasin');
});

test('classifyPushResult: kalici gecersiz jetonlar failed_other sayilmaz; hic jeton gecersiz degilse push_error', () => {
  assert.deepEqual(
    H.classifyPushResult({ attempted: 2, sent: 1, failed: 1, disabledTokenIds: ['a'] }),
    { status: 'sent', push: { attempted: 2, sent: 1, failed: 1 } }
  );
  assert.deepEqual(
    H.classifyPushResult({ attempted: 3, sent: 1, failed: 2, disabledTokenIds: ['a'] }).push,
    { attempted: 3, sent: 1, failed: 2, failed_other: 1 }
  );
  // hepsi kalici gecersiz -> bayat jetonlar
  assert.equal(H.classifyPushResult({ attempted: 2, sent: 0, failed: 2, disabledTokenIds: ['a', 'b'], errors: [{ status: 404 }] }).reason, 'push_rejected');
  // gecersiz jeton yok, gecici de degil (400 INVALID_ARGUMENT mesaji, 403 SENDER_ID_MISMATCH, VALIDATION) -> mesaj/kimlik sorunu
  for (const errors of [[{ status: 400, code: 'INVALID_ARGUMENT' }], [{ status: 403, code: 'SENDER_ID_MISMATCH' }], [{ code: 'VALIDATION' }]]) {
    const v = H.classifyPushResult({ attempted: 2, sent: 0, failed: 2, disabledTokenIds: [], transient: false, errors });
    assert.deepEqual([v.status, v.reason], ['no_recipients', 'push_error'], JSON.stringify(errors));
  }
  // hala nihai (yeniden denenmez)
  assert.equal(H.classifyPushResult({ attempted: 1, sent: 0, failed: 1, disabledTokenIds: [] }).status, 'no_recipients');
});

test('push_error uctan uca: mesaj reddedildi (400) -> no_recipients/push_error, yeniden denenmez', async () => {
  const w = standardWorld();
  const push = makeFakePush({ result: { attempted: 2, sent: 0, failed: 2, disabledTokenIds: [], transient: false, errors: [{ status: 400, code: 'INVALID_ARGUMENT' }] } });
  const { reminder } = make(w, { push });
  await tick(w, reminder, T_2330);
  assert.equal(w.world.logs[0].status, 'no_recipients');
  assert.equal(w.world.logs[0].details.reason, 'push_error');
  keepLive(w, isoAt(2));
  assert.equal((await tick(w, reminder, isoAt(2))).candidates, 0);
});
