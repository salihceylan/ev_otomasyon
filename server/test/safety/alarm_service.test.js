'use strict';

// WP-S2/S3 - alarm_service birim testleri (veritabanisiz kisimlar + sahte db ile akis):
//   - event_ack birlestirme: pano basina 250 ms pencere, en cok 8 eid, uid ZORUNLU; baglanti yoksa gonderilmez.
//   - Push: en cok bir kez (pending -> claimed -> sending -> sent); yapilandirilmamissa `skipped`; alicilar
//     owner+resident (push servisi), bilgi push'u yalniz owner; misafir hicbir zaman.
//   - Hata yalitimi: db hatasi firlatilmaz, sonuc 'error' doner.
// Gercek SQL davranisi: alarm_service_pg.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');

const { createAlarmService, helpers } = require('../../src/services/alarm_service');

const UID = 'AHBU-S3-1A2B3C';

function fakeTimers() {
  const list = [];
  return {
    list,
    setTimeout(fn, ms) {
      const t = { fn, ms, cleared: false, unref() {} };
      list.push(t);
      return t;
    },
    clearTimeout(t) {
      if (t) t.cleared = true;
    },
    async flush() {
      while (list.some((t) => !t.cleared)) {
        const t = list.find((x) => !x.cleared);
        t.cleared = true;
        await t.fn();
      }
    },
  };
}

function setup({ connected = true, db = null, push = null, sleeps = null } = {}) {
  const published = [];
  const timers = fakeTimers();
  const svc = createAlarmService({
    db: db || { query: async () => ({ rows: [], rowCount: 0 }), withTransaction: async (fn) => fn({ query: async () => ({ rows: [], rowCount: 0 }) }) },
    publishCommand: async (topicId, cmd) => {
      published.push({ topicId, cmd });
    },
    publishSys: async () => {},
    isConnected: () => connected,
    getPush: () => push,
    logger: { log() {}, warn() {}, error() {} },
    timers,
    sleep: async (ms) => {
      if (sleeps) sleeps.push(ms);
    },
  });
  return { svc, published, timers };
}

test('event_ack: pencere icinde biriken eid\'ler tek komutta (uid ile); 8\'den fazlasi bolunur; yinelenen eid bir kez', async () => {
  const { svc, published, timers } = setup();
  for (let i = 1; i <= 10; i += 1) svc.queueAck('h_t', UID, `9f3a11c0-${i}`);
  svc.queueAck('h_t', UID, '9f3a11c0-3'); // ayni eid tekrar
  assert.equal(published.length, 0, 'pencere dolmadan gonderilmez');
  assert.equal(timers.list[0].ms, 250);
  await timers.flush();
  assert.equal(published.length, 2);
  assert.deepEqual(published[0], { topicId: 'h_t', cmd: { cmd: 'event_ack', uid: UID, eids: ['9f3a11c0-1', '9f3a11c0-2', '9f3a11c0-3', '9f3a11c0-4', '9f3a11c0-5', '9f3a11c0-6', '9f3a11c0-7', '9f3a11c0-8'] } });
  assert.deepEqual(published[1].cmd.eids, ['9f3a11c0-9', '9f3a11c0-10']);
  // farkli pano (uid) ayri komut alir
  svc.queueAck('h_t', 'AHBU-S3-FFFFFF', 'aaaaaaaa-1');
  svc.queueAck('h_t', UID, 'bbbbbbbb-1');
  await timers.flush();
  assert.deepEqual(published.slice(2).map((p) => p.cmd.uid).sort(), ['AHBU-S3-FFFFFF', UID].sort());
});

test('event_ack: kopru bagli degilse gonderilmez (pano yeniden dener); yayin hatasi firlatilmaz', async () => {
  const off = setup({ connected: false });
  off.svc.queueAck('h_t', UID, '9f3a11c0-1');
  await off.timers.flush();
  assert.equal(off.published.length, 0);
  const bad = setup();
  bad.svc._deps.publishCommand = async () => {
    throw new Error('broker');
  };
  bad.svc.queueAck('h_t', UID, '9f3a11c0-1');
  await bad.timers.flush(); // firlatmaz
});

test('push metinleri: tur bazli baslik; serbest metin/ad icermez', () => {
  assert.equal(helpers.alarmTitle('water'), 'Su baskını alarmı');
  assert.equal(helpers.alarmTitle('gas'), 'Gaz kaçağı alarmı');
  assert.equal(helpers.alarmTitle('smoke'), 'Duman alarmı');
  assert.equal(helpers.alarmTitle('door'), 'Güvenlik alarmı');
  assert.match(helpers.alarmBody({ kind: 'water', zone: 1 }), /vana/i);
  assert.match(helpers.faultBody(), /elle kapat/i);
});

function scriptedDb(handlers) {
  const calls = [];
  const run = async (text, params) => {
    calls.push({ text, params });
    for (const h of handlers) if (h.match.test(text)) return h.reply(params, text);
    return { rows: [], rowCount: 0 };
  };
  return { calls, query: run, withTransaction: async (fn) => fn({ query: run }) };
}

test('push: claim tek sefer; yapilandirilmamissa skipped; alicilar owner+resident (roles verilmez), gonderilince sent', async () => {
  const states = [];
  const db = scriptedDb([
    { match: /SET push_status = 'claimed'/, reply: () => ({ rows: [{ id: 7, home_id: 'h1', device_id: 'd1', zone: 1, kind: 'water', status: 'latched' }], rowCount: 1 }) },
    { match: /SET push_status = \$2/, reply: (p) => { states.push(p[1]); return { rows: [], rowCount: 1 }; } },
  ]);
  const sent = [];
  const push = {
    isConfigured: () => true,
    recipientsForHome: async (homeId, opts) => {
      sent.push({ recipients: homeId, opts });
      return [{ id: 'p1', token: 'tok-aaaaaaaaaaaaaaaaaaaaa' }];
    },
    sendNotice: async (args) => {
      sent.push({ notice: args });
      return { sent: 1, failed: 0, errors: [] };
    },
  };
  const { svc } = setup({ db, push });
  await svc.pushAlarm(7);
  assert.deepEqual(states, ['sending', 'sent']);
  assert.equal(sent[0].opts, undefined, 'alarm push: owner+resident (varsayilan alici kumesi; misafir yok)');
  assert.equal(sent[1].notice.kind, 'safety_alarm');
  assert.equal(sent[1].notice.data.alarm_id, 7);

  const states2 = [];
  const db2 = scriptedDb([
    { match: /SET push_status = 'claimed'/, reply: () => ({ rows: [{ id: 8, home_id: 'h1', device_id: 'd1', zone: 1, kind: 'water', status: 'latched' }], rowCount: 1 }) },
    { match: /SET push_status = \$2/, reply: (p) => { states2.push(p[1]); return { rows: [], rowCount: 1 }; } },
  ]);
  const off = setup({ db: db2, push: { isConfigured: () => false } });
  await off.svc.pushAlarm(8);
  assert.deepEqual(states2, ['skipped']);

  // claim alinamazsa (zaten gonderildi / baska ornek aldi) hicbir sey yapilmaz
  const db3 = scriptedDb([]);
  const none = setup({ db: db3, push });
  sent.length = 0;
  await none.svc.pushAlarm(9);
  assert.equal(sent.length, 0);
});

test('bilgi push\'u (lost / politika) yalniz owner\'a gider', async () => {
  const sent = [];
  const push = {
    isConfigured: () => true,
    recipientsForHome: async (homeId, opts) => {
      sent.push(opts);
      return [{ id: 'p1', token: 'tok-aaaaaaaaaaaaaaaaaaaaa' }];
    },
    sendNotice: async (args) => {
      sent.push(args.kind);
      return { sent: 1 };
    },
  };
  const { svc } = setup({ push });
  await svc.pushInfo({ homeId: 'h1', deviceId: 'd1', alarmId: 3, reason: 'alarm_lost' });
  assert.deepEqual(sent, [{ roles: ['owner'] }, 'safety_info']);
});

test('push: basarisiz alarm push\'u BIR kez yeniden denenir (alicilar yeniden okunur); ikinci deneme de basarisizsa failed', async () => {
  const run = async (results) => {
    const states = [];
    const db = scriptedDb([
      { match: /SET push_status = 'claimed'/, reply: () => ({ rows: [{ id: 7, home_id: 'h1', device_id: 'd1', zone: 1, kind: 'water', status: 'latched' }], rowCount: 1 }) },
      { match: /SET push_status = \$2/, reply: (p) => { states.push(p[1]); return { rows: [], rowCount: 1 }; } },
    ]);
    let recipients = 0;
    let sends = 0;
    const push = {
      isConfigured: () => true,
      recipientsForHome: async () => {
        recipients += 1;
        return [{ id: 'p1', token: 'tok-aaaaaaaaaaaaaaaaaaaaa' }];
      },
      sendNotice: async () => {
        const r = results[sends++];
        if (r instanceof Error) throw r;
        return r;
      },
    };
    const sleeps = [];
    const { svc } = setup({ db, push, sleeps });
    const status = await svc.pushAlarm(7);
    return { status, states, recipients, sends, sleeps, retries: svc.counters.pushRetries };
  };
  const ok = await run([{ sent: 0, failed: 1 }, { sent: 1, failed: 0 }]);
  assert.equal(ok.status, 'sent');
  assert.deepEqual(ok.states, ['sending', 'sent']);
  assert.deepEqual([ok.recipients, ok.sends, ok.retries], [2, 2, 1]);
  assert.equal(ok.sleeps.length, 1);
  const thrown = await run([new Error('fcm 503'), { sent: 1 }]);
  assert.equal(thrown.status, 'sent');
  const bad = await run([{ sent: 0 }, { sent: 0 }]);
  assert.equal(bad.status, 'failed');
  assert.deepEqual(bad.states, ['sending', 'failed']);
  assert.equal(bad.sends, 2, 'yalniz BIR yeniden deneme');
  const first = await run([{ sent: 1 }]);
  assert.deepEqual([first.status, first.sends, first.retries], ['sent', 1, 0]);
});

// ---- Inceleme turu (entegrasyon) ----
function liveDb(openRows) {
  const calls = { open: 0, cleared: [], lost: [] };
  const db = {
    async query(text, params) {
      if (/WHERE device_id = \$1 AND home_id <> \$2/.test(text)) return { rows: [], rowCount: 0 }; // guvenlik-1: baska evde acik satir yok
      if (/^SELECT id, aid, zone, kind, status, ack_requested_at/.test(text)) { calls.open += 1; return { rows: openRows() }; }
      if (/SET status = 'cleared'/.test(text)) { calls.cleared.push(params); return { rows: [], rowCount: 1 }; }
      if (/SET status = 'lost'/.test(text)) { calls.lost.push(params); return { rows: [{ id: params[0] }], rowCount: 1 }; }
      return { rows: [], rowCount: 0 };
    },
    async withTransaction(fn) {
      return fn({ query: async (t) => (/INSERT INTO device_events/.test(t) ? { rows: [{ eid: 'x' }] } : /INSERT INTO alarms/.test(t) ? { rows: [{ id: 9 }] } : { rows: [] }) });
    },
  };
  return { db, calls };
}
const CAPS = ['safety', 'actuator', 'event', 'cfg'];
const sum = (zones, over = {}) => ({ v: 1, present: true, policy: 'on', mode: 'normal', zones, ...over });
const liveArgs = (summary) => ({ topicId: 't', homeId: 'h', deviceId: 'd1', uid: UID, caps: CAPS, summary, prev: null, hadCaps: true });

test('RV-7: acik alarm yoksa ve bolgeler normalse sonraki canli state acik alarm sorgusu yapmaz; olay ya da kilitli bolge onbellegi bozar', async () => {
  let open = [];
  const { db, calls } = liveDb(() => open);
  const { svc } = setup({ db });
  await svc.onLiveState(liveArgs(sum([])));
  assert.equal(calls.open, 1);
  await svc.onLiveState(liveArgs(sum([])));
  await svc.onLiveState(liveArgs(sum([])));
  assert.equal(calls.open, 1, 'temiz panoda her state sorgu yapmaz');
  await svc.onLiveState(liveArgs(sum([{ id: 1, st: 'latched', aid: 'abcd0001-1', kind: 'water', srcs: [] }])));
  assert.equal(calls.open, 2, 'kilitli bolge her zaman sorgulanir');
  open = [{ id: 9, aid: 'abcd0001-1', zone: 1, kind: 'water', status: 'latched', ack_requested_at: null }];
  await svc.onLiveState(liveArgs(sum([])));
  assert.equal(calls.open, 3, 'onceki sorgu satir acti: onbellek gecersiz');
  open = [];
  await svc.onLiveState(liveArgs(sum([])));
  await svc.onLiveState(liveArgs(sum([])));
  assert.equal(calls.open, 4);
  await svc.handleEvent({ topicId: 't', homeId: 'h', deviceId: 'd1', uid: UID, event: { type: 'alarm_raised', eid: 'abcd0001-2', zone: 1, kind: 'water' } });
  await svc.onLiveState(liveArgs(sum([])));
  assert.equal(calls.open, 5, 'alarm_raised olayi onbellegi gecersiz kilar');
});

test('RV-1: bolge listede yoksa normal sayilir (sozlesme): mode normal -> cleared, mode safe -> lost', async () => {
  const row = { id: 7, aid: 'abcd0001-1', zone: 1, kind: 'water', status: 'latched', ack_requested_at: null };
  let a = liveDb(() => [row]);
  let s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([])));
  assert.equal(a.calls.cleared.length, 1);
  assert.equal(a.calls.cleared[0][1], 'device_state');
  a = liveDb(() => [row]);
  s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([], { mode: 'safe', reason: 'cfg_corrupt' })));
  assert.equal(a.calls.cleared.length, 0);
  assert.equal(a.calls.lost.length, 1);
  a = liveDb(() => [row]);
  s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([{ id: 1, st: 'latched', aid: 'abcd0001-5', kind: 'gas', srcs: [] }])));
  assert.equal(a.calls.cleared.length, 1);
  assert.equal(a.calls.cleared[0][1], 'superseded', 'ayni bolgede yeni aid: eski satir superseded');
});

// ---- Inceleme turu 2 ----
test('RV2-1: zones_complete=false iken listede olmayan bolgenin satirina dokunulmaz (cleared/lost yok); listedeki bolge islenir; onbellek kurulmaz', async () => {
  const row = { id: 7, aid: 'abcd0001-1', zone: 1, kind: 'water', status: 'latched', ack_requested_at: null };
  let a = liveDb(() => [row]);
  let s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([], { zones_complete: false })));
  assert.equal(a.calls.cleared.length, 0, 'eksik listede bolge normal sayilmaz');
  assert.equal(a.calls.lost.length, 0);
  a = liveDb(() => [row]);
  s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([{ id: 1, st: 'normal', aid: null }], { zones_complete: false })));
  assert.equal(a.calls.cleared.length, 1, 'listede normal bildirilen bolge yine kapanir');
  a = liveDb(() => []);
  s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([], { zones_complete: false })));
  await s.svc.onLiveState(liveArgs(sum([], { zones_complete: false })));
  assert.equal(a.calls.open, 2, 'eksik liste "temiz pano" onbellegini kurmaz');
  a = liveDb(() => [row]);
  s = setup({ db: a.db });
  await s.svc.onLiveState(liveArgs(sum([])));
  assert.equal(a.calls.cleared.length, 1, 'alan yoksa (eski ozet) tam sayilir');
});

// ---- sko-1 (sozlesme C11): kuyruktaki (cevrimdisi) onay istegi yalniz 24 saatten genc ve isteyen hala yetkiliyse iletilir;
// aksi halde duser + device_audit_logs 'alarm_ack_request_dropped' {reason: expired|revoked}. ----
const T0 = Date.parse('2026-10-09T10:00:00.000Z');
const HOUR = 3600 * 1000;
const SID = '5e55e55e-0000-4000-8000-000000000001';
const OWNER_ID = '0a0a0a0a-0000-4000-8000-000000000001';

function ackWorld({ row, users = {}, sessions = [] }) {
  const w = { published: [], dropped: [], taken: [], audits: [], requests: [] };
  const run = async (text, params) => {
    if (/home_id <> \$2/.test(text)) return { rows: [], rowCount: 0 };
    if (/^SELECT id, aid, zone, kind, status, ack_requested_at/.test(text)) return { rows: row ? [{ ...row }] : [] };
    if (/FROM users u WHERE u\.id = \$1/.test(text)) {
      const u = users[params[0]];
      return { rows: u ? [{ id: params[0], ...u }] : [] };
    }
    if (/FROM service_sessions WHERE id = \$1/.test(text)) {
      return { rows: sessions.filter((s) => s.id === params[0] && s.home_id === params[1]).map((s) => ({ revoked_at: s.revoked_at, expires_at: s.expires_at })) };
    }
    if (/revoked_at >= \$2/.test(text)) {
      const since = Date.parse(params[1] instanceof Date ? params[1].toISOString() : params[1]);
      return { rows: [{ revoked: sessions.some((s) => s.home_id === params[0] && s.revoked_at && Date.parse(s.revoked_at) >= since) }] };
    }
    if (/SET ack_requested_at = NULL, acked_by = ack_requested_by/.test(text)) {
      w.taken.push(params[0]);
      return { rows: [{ id: params[0] }], rowCount: 1 };
    }
    if (/SET ack_requested_at = NULL, ack_requested_by = NULL/.test(text)) {
      w.dropped.push(params[0]);
      return { rows: [], rowCount: 1 };
    }
    if (/SET ack_requested_at = CURRENT_TIMESTAMP/.test(text)) {
      w.requests.push({ text, params });
      return { rows: [{ id: params[0] }], rowCount: 1 };
    }
    if (/INSERT INTO device_audit_logs/.test(text)) {
      w.audits.push({ event: params[0], home: params[2], details: JSON.parse(params[params.length - 1]) });
      return { rows: [], rowCount: 1 };
    }
    return { rows: [], rowCount: 0 };
  };
  w.svc = createAlarmService({
    db: { query: run, withTransaction: async (fn) => fn({ query: run }) },
    publishCommand: async (topicId, cmd) => w.published.push({ topicId, cmd }),
    publishSys: async () => {},
    isConnected: () => true,
    getPush: () => null,
    logger: { log() {}, warn() {}, error() {} },
    timers: fakeTimers(),
    now: () => T0,
  });
  w.live = () => w.svc.onLiveState({ topicId: 't', homeId: 'h', deviceId: 'd1', uid: UID, caps: CAPS, summary: sum([{ id: 1, st: 'latched', aid: 'abcd0001-1', kind: 'water', srcs: [] }]), prev: null, hadCaps: true });
  w.acks = () => w.published.filter((p) => p.cmd.cmd === 'alarm_ack');
  return w;
}
const ackRow = (over) => ({ id: 7, aid: 'abcd0001-1', zone: 1, kind: 'water', status: 'latched', ack_requested_at: new Date(T0 - HOUR), ack_requested_by: null, ack_requested_sid: null, ...over });
const OWNER_ROW = { is_active: true, account_status: 'active', global_role: 'user', member: true, home_role: 'owner' };

test('sko-1: requestAck servis (PIN) oturumunun kimligini (sid) satira yazar', async () => {
  const w = ackWorld({ row: null });
  assert.equal(await w.svc.requestAck({ alarmId: '7', homeId: 'h', userId: null, sessionId: SID }), true);
  assert.equal(w.requests.length, 1);
  assert.match(w.requests[0].text, /ack_requested_sid = \$4/);
  assert.deepEqual(w.requests[0].params, ['7', 'h', null, SID]);
  await w.svc.requestAck({ alarmId: '7', homeId: 'h', userId: OWNER_ID });
  assert.deepEqual(w.requests[1].params, ['7', 'h', OWNER_ID, null]);
});

test('sko-1: servis oturumu iptal edildiyse kuyruktaki onay iletilmez; istek duser + revoked denetim kaydi', async () => {
  const w = ackWorld({
    row: ackRow({ ack_requested_sid: SID }),
    sessions: [{ id: SID, home_id: 'h', revoked_at: new Date(T0 - 10 * 60 * 1000).toISOString(), expires_at: new Date(T0 + HOUR).toISOString() }],
  });
  await w.live();
  assert.equal(w.acks().length, 0, 'iptal edilen oturumun onayi panoya GITMEZ');
  assert.deepEqual(w.taken, []);
  assert.deepEqual(w.dropped, [7]);
  assert.deepEqual(w.audits.map((a) => [a.event, a.details.reason, a.details.alarm_id]), [['alarm_ack_request_dropped', 'revoked', 7]]);
});

test('sko-1: suresi dolmus servis oturumu da revoked; gecerli oturumun onayi iletilir', async () => {
  const expired = ackWorld({ row: ackRow({ ack_requested_sid: SID }), sessions: [{ id: SID, home_id: 'h', revoked_at: null, expires_at: new Date(T0 - 1000).toISOString() }] });
  await expired.live();
  assert.equal(expired.acks().length, 0);
  assert.deepEqual(expired.audits.map((a) => a.details.reason), ['revoked']);
  const ok = ackWorld({ row: ackRow({ ack_requested_sid: SID }), sessions: [{ id: SID, home_id: 'h', revoked_at: null, expires_at: new Date(T0 + HOUR).toISOString() }] });
  await ok.live();
  assert.equal(ok.acks().length, 1);
  assert.deepEqual(ok.taken, [7]);
  assert.deepEqual(ok.audits, []);
});

test('sko-1: 24 saatten eski istek duser (expired); 1 saatlik yetkili kullanici istegi iletilir', async () => {
  const old = ackWorld({ row: ackRow({ ack_requested_by: OWNER_ID, ack_requested_at: new Date(T0 - 25 * HOUR) }), users: { [OWNER_ID]: OWNER_ROW } });
  await old.live();
  assert.equal(old.acks().length, 0, '25 saatlik istek panoya GITMEZ');
  assert.deepEqual(old.dropped, [7]);
  assert.deepEqual(old.audits.map((a) => [a.event, a.details.reason]), [['alarm_ack_request_dropped', 'expired']]);
  const fresh = ackWorld({ row: ackRow({ ack_requested_by: OWNER_ID }), users: { [OWNER_ID]: OWNER_ROW } });
  await fresh.live();
  assert.equal(fresh.acks().length, 1);
  assert.equal(fresh.acks()[0].cmd.aid, 'abcd0001-1');
  assert.deepEqual(fresh.dropped, []);
});

test('sko-1: isteyen kullanicinin yetkisi bittiyse (uyelik yok / misafire dusuruldu / donduruldu) istek duser; super_user gecer', async () => {
  for (const u of [
    { ...OWNER_ROW, member: false, home_role: null },
    { ...OWNER_ROW, home_role: 'guest' },
    { ...OWNER_ROW, is_active: false },
    { ...OWNER_ROW, account_status: 'suspended' },
    { ...OWNER_ROW, global_role: 'user', home_role: 'service_user' }, // personelligi kaldirilmis eski servis uyeligi
    null, // hesap silinmis
  ]) {
    const w = ackWorld({ row: ackRow({ ack_requested_by: OWNER_ID }), users: u ? { [OWNER_ID]: u } : {} });
    await w.live();
    assert.equal(w.acks().length, 0, JSON.stringify(u));
    assert.deepEqual(w.audits.map((a) => a.details.reason), ['revoked'], JSON.stringify(u));
  }
  for (const u of [
    { ...OWNER_ROW, global_role: 'super_user', member: false, home_role: null },
    { ...OWNER_ROW, home_role: 'resident' },
    { ...OWNER_ROW, global_role: 'service_user', home_role: 'service_user' },
  ]) {
    const w = ackWorld({ row: ackRow({ ack_requested_by: OWNER_ID }), users: { [OWNER_ID]: u } });
    await w.live();
    assert.equal(w.acks().length, 1, JSON.stringify(u));
  }
});

test('sko-1: by ve sid bos ESKI istek: istekten sonra evde servis oturumu iptal edildiyse duser, edilmediyse iletilir', async () => {
  const at = new Date(T0 - 2 * HOUR);
  const revoked = ackWorld({ row: ackRow({ ack_requested_at: at }), sessions: [{ id: SID, home_id: 'h', revoked_at: new Date(T0 - HOUR).toISOString(), expires_at: null }] });
  await revoked.live();
  assert.equal(revoked.acks().length, 0);
  assert.deepEqual(revoked.audits.map((a) => a.details.reason), ['revoked']);
  const before = ackWorld({ row: ackRow({ ack_requested_at: at }), sessions: [{ id: SID, home_id: 'h', revoked_at: new Date(T0 - 3 * HOUR).toISOString(), expires_at: null }] });
  await before.live();
  assert.equal(before.acks().length, 1);
});

// ---- sko-2 (sozlesme C12): acik (latched/fault) alarmda push en az bir kez teslim edilir. Sahte tablo, gercek SQL'in
// kosullarini taklit eder (gercek davranis: alarm_service_pg.test.js); veritabani saati `w.dbNow`. ----
function pushWorld(rows) {
  const w = { dbNow: T0, rows: new Map(rows.map((r) => [r.id, { push_attempts: 0, fault_push_status: null, updated_at: T0, ...r }])), sends: 0, results: [] };
  const open = (r) => r.status === 'latched' || r.status === 'fault';
  const age = (r) => w.dbNow - r.updated_at;
  const alarmDue = (r) => open(r) && (r.push_status === 'pending' || (['claimed', 'sending'].includes(r.push_status) && age(r) > 120000) || (r.push_status === 'failed' && r.push_attempts < 5 && age(r) > 60000));
  const faultDue = (r) => r.status === 'fault' && (r.fault_push_status === 'pending' || (['claimed', 'sending'].includes(r.fault_push_status) && age(r) > 120000));
  const out = (r) => ({ rows: [{ id: r.id, home_id: 'h1', device_id: 'd1', zone: 1, kind: 'gas', status: r.status, device_uuid: UID }], rowCount: 1 });
  const run = async (text, params) => {
    const r = w.rows.get(params && params[0]);
    if (/^SELECT id FROM alarms/.test(text)) {
      const due = /fault_push_status/.test(text) ? faultDue : alarmDue;
      return { rows: [...w.rows.values()].filter(due).slice(0, params[0]).map((x) => ({ id: x.id })) };
    }
    if (/SET push_status = 'claimed'/.test(text)) {
      const retry = /push_attempts < 5/.test(text);
      if (!r || !(retry ? alarmDue(r) : r.push_status === 'pending')) return { rows: [], rowCount: 0 };
      Object.assign(r, { push_status: 'claimed', push_attempts: r.push_attempts + 1, updated_at: w.dbNow });
      return out(r);
    }
    if (/SET fault_push_status = 'claimed'/.test(text)) {
      const retry = /INTERVAL/.test(text);
      if (!r || !(retry ? faultDue(r) : r.fault_push_status === 'pending')) return { rows: [], rowCount: 0 };
      Object.assign(r, { fault_push_status: 'claimed', updated_at: w.dbNow });
      return out(r);
    }
    if (/SET push_status = \$2/.test(text)) { Object.assign(r, { push_status: params[1], updated_at: w.dbNow }); return { rows: [], rowCount: 1 }; }
    if (/SET fault_push_status = \$2/.test(text)) { Object.assign(r, { fault_push_status: params[1], updated_at: w.dbNow }); return { rows: [], rowCount: 1 }; }
    return { rows: [], rowCount: 0 };
  };
  const push = {
    isConfigured: () => true,
    recipientsForHome: async () => [{ id: 'p1', token: 'tok-aaaaaaaaaaaaaaaaaaaaa' }],
    sendNotice: async (args) => {
      w.sends += 1;
      const res = w.results.length > 0 ? w.results.shift() : { sent: 1, failed: 0 };
      if (res instanceof Error) throw res;
      w.notices = (w.notices || []).concat([args]);
      return res;
    },
  };
  w.svc = createAlarmService({
    db: { query: run, withTransaction: async (fn) => fn({ query: run }) },
    publishCommand: async () => {},
    isConnected: () => true,
    getPush: () => push,
    logger: { log() {}, warn() {}, error() {} },
    timers: fakeTimers(),
    sleep: async () => {},
    now: () => w.dbNow,
  });
  return w;
}

test('sko-2: gecici FCM hatasiyla failed kalan acik alarmin push\'u 1 dk sonra yeniden denenir ve gonderilir', async () => {
  const w = pushWorld([{ id: 7, status: 'latched', push_status: 'pending' }]);
  w.results.push(new Error('fcm 503'), new Error('fcm 503'));
  assert.equal(await w.svc.pushAlarm(7), 'failed');
  assert.equal(w.sends, 2);
  assert.equal(w.rows.get(7).push_status, 'failed');
  await w.svc.retryStuckPushes();
  assert.equal(w.sends, 2, '1 dakika dolmadan yeniden denenmez');
  w.dbNow += 61 * 1000;
  const r = await w.svc.retryStuckPushes();
  assert.equal(w.sends, 3, 'yeniden gonderildi');
  assert.equal(w.rows.get(7).push_status, 'sent');
  assert.equal(w.rows.get(7).push_attempts, 2);
  assert.equal(r.sent, 1);
  await w.svc.retryStuckPushes();
  assert.equal(w.sends, 3, "'sent' yeniden gonderilmez");
});

test('sko-2: 2 dk\'dan eski claimed/sending (surec coktu) yeniden gonderilir; taze olan, kapali alarm ve 5 deneme sinirini asan gonderilmez', async () => {
  const w = pushWorld([
    { id: 1, status: 'latched', push_status: 'claimed', updated_at: T0 - 3 * 60 * 1000 },
    { id: 2, status: 'fault', push_status: 'sending', updated_at: T0 - 3 * 60 * 1000 },
    { id: 3, status: 'latched', push_status: 'sending', updated_at: T0 - 30 * 1000 },
    { id: 4, status: 'cleared', push_status: 'claimed', updated_at: T0 - 3 * 60 * 1000 },
    { id: 5, status: 'silenced', push_status: 'failed', push_attempts: 1, updated_at: T0 - 3 * 60 * 1000 },
    { id: 6, status: 'latched', push_status: 'failed', push_attempts: 5, updated_at: T0 - 3 * 60 * 1000 },
    { id: 8, status: 'latched', push_status: 'pending' }, // yeniden baslatmada talep edilmemis
  ]);
  await w.svc.retryStuckPushes();
  assert.deepEqual([...w.rows.values()].filter((r) => r.push_status === 'sent').map((r) => r.id), [1, 2, 8]);
  assert.equal(w.sends, 3);
  assert.equal(w.rows.get(4).push_status, 'claimed', 'kapali alarm yeniden denenmez');
  assert.equal(w.rows.get(6).push_status, 'failed', '5 deneme siniri');
});

test('sko-2: yarim kalan vana arizasi (fault) push\'u da yeniden denenir', async () => {
  const w = pushWorld([{ id: 9, status: 'fault', push_status: 'sent', fault_push_status: 'claimed', updated_at: T0 - 3 * 60 * 1000 }]);
  await w.svc.retryStuckPushes();
  assert.equal(w.rows.get(9).fault_push_status, 'sent');
  assert.equal(w.notices[0].data.status, 'fault');
});
