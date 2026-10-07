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
