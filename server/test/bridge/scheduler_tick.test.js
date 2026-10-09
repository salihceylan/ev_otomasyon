'use strict';

// C8 - Zamanlayici: tur davranisi (atomik talep, telafi, yetki, cihaz, cevrimdisi, broker
// hatasi, zaman asimi, saat dilimi birlesimi, yasam dongusu).

const test = require('node:test');
const assert = require('node:assert/strict');
const { Scheduler, SQL } = require('../../src/scheduler');
const { makeFakeDb, makeFakeTimers, makeLogger, flush } = require('./_helpers');

const Z = (iso) => Date.parse(iso);
const MIN = 60 * 1000;

const HOME_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_HOME_ID = '22222222-2222-4222-8222-222222222222';
const DEVICE_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const USER_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const TOPIC = 'h_0123456789abcdef';

/**
 * Dunyayi kurar: sahte veritabani (talep/gunluk mantigini gercek SQL semantigine uygun taklit eder),
 * sahte kopru ve zamanlayici. `rules` satirlari `world.rules` icinde yasar; talep/geri birakma bunlari
 * degistirir, boylece ardisik turlar gercek `last_run_at` durumunu gorur.
 */
function makeWorld({
  rules,
  zones = ['Europe/Istanbul'],
  creator = { is_active: true, account_status: null, global_role: 'user', home_role: 'owner', installer_expires_at: null },
  devices = [{ id: DEVICE_ID, home_id: HOME_ID, is_online: true }],
  endpoints = [], // WP-L D4: [{ device_id, channel_index, type }]; bos -> eski davranis (yayin)
  bridge = {},
} = {}) {
  const world = {
    rules: rules.map((r) => ({
      home_id: HOME_ID,
      device_id: null,
      channel_type: 'relay',
      days_of_week: [0, 1, 2, 3, 4, 5, 6],
      created_by: USER_ID,
      last_run_at: null,
      schedule_changed_at: new Date(Z('2026-01-01T00:00:00Z')),
      mqtt_username: TOPIC,
      timezone: 'Europe/Istanbul',
      ...r,
    })),
    runs: [],
    creator,
    devices,
    published: [],
    housekeeping: 0,
    eventRetention: 0,
    creatorQueries: 0,
    endpoints,
    targetQueries: [],
  };

  const db = makeFakeDb([
    { match: (t) => t === SQL.timezones, reply: () => ({ rows: zones.map((tz) => ({ tz })) }) },
    {
      match: (t) => t === SQL.candidates,
      reply: (_t, [hours, minutes]) => {
        const pairs = new Set(hours.map((h, i) => `${h}:${minutes[i]}`));
        return { rows: world.rules.filter((r) => r.enabled !== false && pairs.has(`${r.hour}:${r.minute}`)).map((r) => ({ ...r })) };
      },
    },
    {
      match: (t) => t === SQL.claim,
      reply: (_t, [id, slotIso]) => {
        const rule = world.rules.find((r) => r.id === id);
        const slot = new Date(slotIso);
        if (rule && rule.enabled !== false && (rule.last_run_at === null || rule.last_run_at < slot)) {
          rule.last_run_at = slot;
          return { rows: [{ id }], rowCount: 1 };
        }
        return { rows: [], rowCount: 0 };
      },
    },
    {
      match: (t) => t === SQL.release,
      reply: (_t, [id, slotIso, prevIso]) => {
        const rule = world.rules.find((r) => r.id === id);
        if (rule && rule.last_run_at && rule.last_run_at.getTime() === new Date(slotIso).getTime()) {
          rule.last_run_at = prevIso ? new Date(prevIso) : null;
        }
        return { rows: [], rowCount: 1 };
      },
    },
    {
      match: (t) => t === SQL.creator,
      reply: () => {
        world.creatorQueries++;
        return { rows: world.creator ? [world.creator] : [] };
      },
    },
    { match: (t) => t === SQL.devices, reply: (_t, [homeId, deviceId]) => ({ rows: world.devices.filter((d) => d.home_id === homeId && (!deviceId || d.id === deviceId)) }) },
    {
      match: (t) => t === SQL.logRun,
      reply: (_t, p) => {
        const [rule_id, home_id, device_id, slot_at, status, detail, command_id] = p;
        const existing = world.runs.find((r) => r.rule_id === rule_id && r.slot_at === slot_at);
        if (existing) Object.assign(existing, { status, detail, command_id, attempts: existing.attempts + 1 });
        else world.runs.push({ rule_id, home_id, device_id, slot_at, status, detail, command_id, attempts: 1 });
        return { rows: [], rowCount: 1 };
      },
    },
    {
      match: (t) => SQL.target !== undefined && t === SQL.target,
      reply: (_t, [deviceId, channels]) => {
        world.targetQueries.push({ deviceId, channels: [...channels] });
        return { rows: world.endpoints.filter((e) => e.device_id === deviceId && channels.includes(e.channel_index)).map((e) => ({ channel_index: e.channel_index, type: e.type })) };
      },
    },
    { match: (t) => t === SQL.housekeeping, reply: () => { world.housekeeping++; return { rows: [], rowCount: 0 }; } },
    { match: (t) => t === SQL.eventRetention, reply: () => { world.eventRetention++; return { rows: [], rowCount: 0 }; } },
  ]);

  const mqttBridge = {
    connected: true,
    failWith: null,
    hang: false,
    isConnected() {
      return this.connected;
    },
    async publishCommand(topicId, cmd) {
      if (this.hang) return new Promise(() => {});
      if (this.failWith) throw this.failWith;
      world.published.push({ topicId, cmd });
      return { topic: `ev/${topicId}/cmd`, payload: JSON.stringify(cmd) };
    },
    ...bridge,
  };

  const logger = makeLogger();
  const timers = makeFakeTimers();
  const makeScheduler = (opts = {}) => {
    const s = new Scheduler({ logger, timers, ...opts });
    s.db = db;
    s.mqttBridge = mqttBridge;
    return s;
  };
  return { world, db, mqttBridge, logger, timers, makeScheduler };
}

// 2026-10-01 05:30:20Z = Istanbul 08:30:20 (Persembe)
const AT_0830 = Z('2026-10-01T05:30:20Z');

test('vadesi gelen kural: talep -> yetki -> cihaz -> yayin; last_run_at yuvaya ayarlanir; gunluk "sent"', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  const s = w.makeScheduler();
  const res = await s.runTick(AT_0830);

  assert.equal(res.due, 1);
  assert.equal(res.sent, 1);
  assert.equal(w.world.published.length, 1);
  const pub = w.world.published[0];
  assert.equal(pub.topicId, TOPIC);
  assert.deepEqual({ relay: pub.cmd.relay, state: pub.cmd.state }, { relay: 3, state: true });
  assert.match(pub.cmd.id, /^sr7-[0-9a-z]+$/);
  assert.equal(w.world.rules[0].last_run_at.toISOString(), '2026-10-01T05:30:00.000Z');
  assert.equal(w.world.runs[0].status, 'sent');
  assert.equal(w.world.runs[0].command_id, pub.cmd.id);
});

test('ayni dakikanin tekrar turu ve sonraki dakikalar kurali TEKRAR calistirmaz', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  const s = w.makeScheduler();
  await s.runTick(AT_0830);
  await s.runTick(AT_0830 + 5000);
  await s.runTick(AT_0830 + MIN);
  await s.runTick(AT_0830 + 2 * MIN);
  assert.equal(w.world.published.length, 1);
});

test('COKLU INSTANCE: iki scheduler ayni anda tur atsa da yalniz biri yayin yapar (atomik talep)', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  const a = w.makeScheduler();
  const b = w.makeScheduler();
  const [ra, rb] = await Promise.all([a.runTick(AT_0830), b.runTick(AT_0830)]);
  assert.equal(w.world.published.length, 1, 'komut tam bir kez yayinlanmali');
  assert.equal(ra.sent + rb.sent, 1);
  assert.equal(ra.lost + rb.lost, 1);
});

test('kapali kural / eslesmeyen dakika / eslesmeyen gun: yayin yok', async () => {
  const w = makeWorld({
    rules: [
      { id: 1, channel: 1, action: 'on', hour: 8, minute: 30, enabled: false },
      { id: 2, channel: 1, action: 'on', hour: 8, minute: 31 },
      { id: 3, channel: 1, action: 'on', hour: 8, minute: 30, days_of_week: [1, 2] }, // Pzt-Sal; bugun Persembe
    ],
  });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.due, 0);
  assert.equal(w.world.published.length, 0);
});

test('TELAFI: 1-2 dakika gecikmis tur kurali yakalar; 3 dakika gecikmis yakalamaz', async () => {
  for (const [delayMin, expected] of [[1, 1], [2, 1], [3, 0]]) {
    const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
    await w.makeScheduler().runTick(Z('2026-10-01T05:30:05Z') + delayMin * MIN);
    assert.equal(w.world.published.length, expected, `${delayMin} dk gecikme`);
  }
});

test('olusturulmadan once baslayan yuva telafi EDILMEZ', async () => {
  const w = makeWorld({
    rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30, schedule_changed_at: new Date(Z('2026-10-01T05:30:10Z')) }],
  });
  await w.makeScheduler().runTick(Z('2026-10-01T05:31:05Z'));
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs.length, 0);
});

test('YETKI: kural sahibi evden cikarildiysa (uyelik yok) / misafire dusurulduyse kural calismaz', async () => {
  for (const creator of [
    { is_active: true, global_role: 'user', home_role: null }, // uyelik silinmis
    { is_active: true, global_role: 'user', home_role: 'guest' }, // misafire dusmus
    { is_active: false, global_role: 'user', home_role: 'owner' }, // hesap pasif
    { is_active: true, account_status: 'suspended', global_role: 'user', home_role: 'owner' }, // donduruldu
  ]) {
    const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }], creator });
    const res = await w.makeScheduler().runTick(AT_0830);
    assert.equal(w.world.published.length, 0, JSON.stringify(creator));
    assert.equal(res.skipped, 1);
    assert.equal(w.world.runs[0].status, 'skipped_creator');
    // kalici durum: talep GERI BIRAKILMAZ (her dakika yeniden denenmez)
    assert.ok(w.world.rules[0].last_run_at, 'yuva tuketilmeli');
  }
});

test('YETKI: kullanici tamamen silinmisse (satir yok) kural calismaz', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }], creator: null });
  await w.makeScheduler().runTick(AT_0830);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'skipped_creator');
});

test('CIHAZ: kural cihazi baska eve tasindiysa / evde cihaz yoksa / belirsizse atlanir', async () => {
  // device_id belirtilmis ama cihaz artik baska evde
  const moved = makeWorld({
    rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30, device_id: DEVICE_ID }],
    devices: [{ id: DEVICE_ID, home_id: OTHER_HOME_ID, is_online: true }],
  });
  await moved.makeScheduler().runTick(AT_0830);
  assert.equal(moved.world.published.length, 0);
  assert.equal(moved.world.runs[0].status, 'skipped_device');

  // device_id yok, evde cihaz yok
  const none = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }], devices: [] });
  await none.makeScheduler().runTick(AT_0830);
  assert.equal(none.world.runs[0].status, 'skipped_device');

  // device_id yok, evde iki cihaz: hedef belirsiz
  const two = makeWorld({
    rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }],
    devices: [
      { id: DEVICE_ID, home_id: HOME_ID, is_online: true },
      { id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', home_id: HOME_ID, is_online: true },
    ],
  });
  await two.makeScheduler().runTick(AT_0830);
  assert.equal(two.world.published.length, 0);
  assert.equal(two.world.runs[0].status, 'skipped_device');
});

test('CIHAZ: device_id belirtilmis ve evdeyse o cihaz kullanilir', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30, device_id: DEVICE_ID }] });
  await w.makeScheduler().runTick(AT_0830);
  assert.equal(w.world.published.length, 1);
  assert.equal(w.world.runs[0].device_id, DEVICE_ID);
});

test('CEVRIMDISI cihaz atlanir + gunluk; talep geri birakilir, ayni pencerede cihaz donunce kural calisir', async () => {
  const w = makeWorld({
    rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }],
    devices: [{ id: DEVICE_ID, home_id: HOME_ID, is_online: false }],
  });
  const s = w.makeScheduler();

  const r1 = await s.runTick(AT_0830);
  assert.equal(r1.skipped, 1);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'skipped_offline');
  assert.equal(w.world.rules[0].last_run_at, null, 'gecici neden: talep geri birakilmali');

  // 1 dk sonra cihaz cevrimici -> telafi penceresinde calisir
  w.world.devices[0].is_online = true;
  const r2 = await s.runTick(AT_0830 + MIN);
  assert.equal(r2.sent, 1);
  assert.equal(w.world.published.length, 1);
  assert.equal(w.world.runs.length, 1, 'ayni yuva tek gunluk satiri (guncellenir)');
  assert.equal(w.world.runs[0].status, 'sent');
  assert.equal(w.world.runs[0].attempts, 2);
});

test('sko-4: yayindan ONCEKI gecici veritabani hatasi yuvayi TUKETMEZ: talep geri birakilir, sonraki dakikada gonderilir', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  let failOnce = true;
  w.db.addRule({
    match: (t) => t === SQL.devices && failOnce,
    reply: () => {
      failOnce = false;
      return Object.assign(new Error('Connection terminated unexpectedly'), { code: 'ECONNRESET' });
    },
  });
  const s = w.makeScheduler();
  const r1 = await s.runTick(AT_0830);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'failed');
  assert.equal(r1.outcomes[0].released, true, 'gecici hata: talep geri birakilir');
  assert.equal(w.world.rules[0].last_run_at, null);
  const r2 = await s.runTick(AT_0830 + MIN);
  assert.equal(r2.sent, 1, 'ayni yuva telafi penceresinde gonderilir');
  assert.equal(w.world.published.length, 1);
  assert.equal(w.world.runs[0].status, 'sent');
});

test('sko-4: yetki sorgusu (SQL.creator) gecici hatasi da yuvayi tuketmez', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  let failOnce = true;
  w.db.addRule({ match: (t) => t === SQL.creator && failOnce, reply: () => { failOnce = false; return new Error('timeout'); } });
  const s = w.makeScheduler();
  await s.runTick(AT_0830);
  assert.equal(w.world.rules[0].last_run_at, null);
  assert.equal((await s.runTick(AT_0830 + MIN)).sent, 1);
});

test('CEVRIMDISI cihaz pencere (2 dk) bitene kadar donmezse kural o gun atlanmis kalir', async () => {
  const w = makeWorld({
    rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }],
    devices: [{ id: DEVICE_ID, home_id: HOME_ID, is_online: false }],
  });
  const s = w.makeScheduler();
  await s.runTick(AT_0830);
  await s.runTick(AT_0830 + MIN);
  await s.runTick(AT_0830 + 2 * MIN);
  w.world.devices[0].is_online = true;
  await s.runTick(AT_0830 + 3 * MIN); // pencere disi
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'skipped_offline');
});

test('BROKER hatasi: yayin reddedilirse "failed_broker", talep geri birakilir, sonraki dakikada yeniden denenir', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  const s = w.makeScheduler();
  w.mqttBridge.failWith = new Error('MQTT Broker baglantisi aktif degil');
  const r1 = await s.runTick(AT_0830);
  assert.equal(r1.failed, 1);
  assert.equal(w.world.runs[0].status, 'failed_broker');
  assert.equal(w.world.rules[0].last_run_at, null);

  w.mqttBridge.failWith = null;
  const r2 = await s.runTick(AT_0830 + MIN);
  assert.equal(r2.sent, 1);
  assert.equal(w.world.published.length, 1);
  // ayni yuva -> ayni komut kimligi (cihaz yinelenmeyi tekillestirir)
  assert.match(w.world.published[0].cmd.id, /^sr7-/);
});

test('kopru bagli degilse yayin denenmeden "failed_broker" (talep geri birakilir)', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  w.mqttBridge.connected = false;
  await w.makeScheduler().runTick(AT_0830);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'failed_broker');
  assert.equal(w.world.rules[0].last_run_at, null);
});

test('Promise.allSettled + ZAMAN ASIMI: takilan kural digerlerini bloklamaz', async () => {
  const w = makeWorld({
    rules: [
      { id: 1, channel: 1, action: 'on', hour: 8, minute: 30 },
      { id: 2, channel: 2, action: 'on', hour: 8, minute: 30 },
      { id: 3, channel: 3, action: 'on', hour: 8, minute: 30 },
    ],
  });
  // Gercek zamanlayicilar + kisa zaman asimi
  const real = { setTimeout: (...a) => setTimeout(...a), clearTimeout: (...a) => clearTimeout(...a) };
  const s = w.makeScheduler({ timers: real, ruleTimeoutMs: 40 });
  w.mqttBridge.publishCommand = async (topicId, cmd) => {
    if (cmd.relay === 2) return new Promise(() => {}); // asla donmeyen yayin
    w.world.published.push({ topicId, cmd });
    return {};
  };
  const res = await s.runTick(AT_0830);
  assert.equal(res.due, 3);
  assert.equal(res.sent, 2);
  assert.equal(res.failed, 1);
  const timedOut = res.outcomes.find((o) => o.ruleId === 2);
  assert.equal(timedOut.status, 'failed');
  assert.match(timedOut.detail, /zaman asimina/);
  assert.deepEqual(w.world.published.map((p) => p.cmd.relay).sort(), [1, 3]);
});

test('bir kuralin istisnasi digerlerini etkilemez (kural bazli izolasyon)', async () => {
  const w = makeWorld({
    rules: [
      { id: 1, channel: 1, action: 'on', hour: 8, minute: 30 },
      { id: 2, channel: 2, action: 'on', hour: 8, minute: 30 },
    ],
  });
  w.db.addRule({
    match: (t) => t === SQL.creator,
    reply: (_t, [, userId]) => {
      throw new Error('beklenmeyen');
    },
  });
  // ilk kuralin yetki sorgusu patlar -> failed; ikinci kural da ayni sorguyu kullandigindan failed;
  // onemli olan turun cokmemesi ve sonucun toplanmasi
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.due, 2);
  assert.equal(res.failed, 2);
  assert.equal(w.world.published.length, 0);
});

test('KANAL/EYLEM gecersiz kayit: komuta cevrilemezse atlanir (firmware\'e bozuk komut gitmez)', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 0, action: 'on', hour: 8, minute: 30 }] }); // eski 0 tabanli kayit
  await w.makeScheduler().runTick(AT_0830);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'skipped_invalid');
});

test('panjur kurali: open -> {shutter:N, cmd:up}', async () => {
  const w = makeWorld({ rules: [{ id: 9, channel: 2, channel_type: 'shutter', action: 'open', hour: 8, minute: 30 }] });
  await w.makeScheduler().runTick(AT_0830);
  const cmd = w.world.published[0].cmd;
  assert.equal(cmd.shutter, 2);
  assert.equal(cmd.cmd, 'up');
});

test('SAAT DILIMI: farkli dilimdeki evler kendi yerel saatinde calisir; aday sorgusu dilimlerin birlesimini kullanir', async () => {
  // 2026-01-16T00:00:30Z = Istanbul 03:00:30, New_York 19:00:30 (kis, UTC-5)
  const now = Z('2026-01-16T00:00:30Z');
  const w = makeWorld({
    zones: ['Europe/Istanbul', 'America/New_York'],
    rules: [
      { id: 1, channel: 1, action: 'on', hour: 3, minute: 0, timezone: 'Europe/Istanbul' },
      { id: 2, channel: 2, action: 'on', hour: 19, minute: 0, timezone: 'America/New_York' },
      // yanlis dilimde ayni saat: Istanbul'da 19:00 degil, NY'de 03:00 degil
      { id: 3, channel: 3, action: 'on', hour: 19, minute: 0, timezone: 'Europe/Istanbul' },
      { id: 4, channel: 4, action: 'on', hour: 3, minute: 0, timezone: 'America/New_York' },
    ],
  });
  const res = await w.makeScheduler().runTick(now);
  assert.equal(res.due, 2);
  assert.deepEqual(w.world.published.map((p) => p.cmd.relay).sort(), [1, 2]);

  const candQuery = w.db.calls.find((c) => c.text === SQL.candidates);
  const pairs = candQuery.params[0].map((h, i) => `${h}:${candQuery.params[1][i]}`);
  for (const expected of ['3:0', '2:59', '2:58', '19:0', '18:59', '18:58']) {
    assert.ok(pairs.includes(expected), `${expected} aday kumesinde olmali: ${pairs}`);
  }
});

test('gecersiz saat dilimi Europe/Istanbul\'a duser ve uyari loglanir', async () => {
  const w = makeWorld({
    zones: ['Mars/Phobos'],
    rules: [{ id: 1, channel: 1, action: 'on', hour: 8, minute: 30, timezone: 'Mars/Phobos' }],
  });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.sent, 1);
  assert.ok(w.logger.lines.some((l) => l.startsWith('warn:') && l.includes('Gecersiz saat dilimi')));
});

test('hic kural yoksa aday sorgusu bile calistirilmaz', async () => {
  const w = makeWorld({ rules: [], zones: [] });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.due, 0);
  assert.equal(w.db.calls.filter((c) => c.text === SQL.candidates).length, 0);
});

test('SQL sozlesmesi: aday sorgusu yalnizca etkin kurallar + (hour,minute) kume uyelikli, talep atomik', () => {
  assert.match(SQL.candidates, /sr\.enabled = TRUE/);
  assert.match(SQL.candidates, /\(sr\.hour, sr\.minute\) IN \(SELECT t\.h, t\.m FROM unnest\(\$1::int\[\], \$2::int\[\]\)/);
  assert.match(SQL.candidates, /LIMIT \d+/);
  assert.match(SQL.claim, /last_run_at IS NULL OR last_run_at < \$2::timestamptz/);
  assert.match(SQL.claim, /RETURNING id/);
  assert.match(SQL.release, /WHERE id = \$1 AND last_run_at = \$2::timestamptz/);
  assert.match(SQL.logRun, /ON CONFLICT \(rule_id, slot_at\) DO UPDATE/);
  // kullanici girdisi yok: tum degerler yer tutucu
  for (const q of [SQL.claim, SQL.release, SQL.creator, SQL.devices, SQL.logRun]) assert.match(q, /\$1/);
});

test('sema eksikse (42703/42P01) tur COKMEZ, ozet hata doner ve ipucu loglanir (spam yok)', async () => {
  const w = makeWorld({ rules: [] });
  const err = Object.assign(new Error('column "timezone" does not exist'), { code: '42703' });
  w.db.addRule({ match: (t) => t === SQL.timezones, reply: err });
  const s = w.makeScheduler();
  const r1 = await s.runTick(AT_0830);
  const r2 = await s.runTick(AT_0830 + MIN);
  assert.ok(r1.error);
  assert.ok(r2.error);
  const warns = w.logger.lines.filter((l) => l.includes('022_scheduled_rules_fix'));
  assert.equal(warns.length, 1, 'ayni uyari tekrarlanmamali');
});

test('gunluk temizligi gunde bir kez calisir', async () => {
  const w = makeWorld({ rules: [], zones: [] });
  const s = w.makeScheduler();
  await s.runTick(AT_0830);
  await s.runTick(AT_0830 + MIN);
  assert.equal(w.world.housekeeping, 1);
  assert.equal(w.world.eventRetention, 1, 'device_events 90 gun temizligi ayni gunluk isle');
  await s.runTick(AT_0830 + 25 * 60 * MIN);
  assert.equal(w.world.housekeeping, 2);
  assert.equal(w.world.eventRetention, 2);
});

test('olay gunlugu temizligi: 90 gun; hatasi kural turunu ve calisma gunlugu temizligini bozmaz', async () => {
  assert.match(SQL.eventRetention, /DELETE FROM device_events WHERE received_at < CURRENT_TIMESTAMP - INTERVAL '90 days'/);
  const w = makeWorld({ rules: [] });
  w.db.addRule({ match: (t) => t === SQL.eventRetention, reply: new Error('tablo yok') });
  const s = w.makeScheduler();
  const r = await s.runTick(AT_0830);
  assert.ok(!r.error);
  assert.equal(w.world.housekeeping, 1);
  assert.ok(w.logger.lines.some((l) => l.includes('Olay gunlugu temizligi')));
});

test('gunluk yazimi basarisiz olsa da kural calisir (gunluk yardimcidir)', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }] });
  w.db.addRule({ match: (t) => t === SQL.logRun, reply: new Error('tablo yok') });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.sent, 1);
  assert.equal(w.world.published.length, 1);
});

// -- Yasam dongusu --------------------------------------------------------------

test('start: bagimlilik zorunlu; dakika sinirina hizalanir; idempotent', () => {
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const s = new Scheduler({ timers, logger, now: () => Z('2026-10-01T05:30:30Z') });
  assert.throws(() => s.start({}), TypeError);
  assert.throws(() => s.start({ mqttBridge: { publishCommand() {} } }), TypeError);
  assert.throws(() => s.start({ db: { query() {} } }), TypeError);

  s.start({ mqttBridge: { publishCommand() {}, isConnected: () => true }, db: { query: async () => ({ rows: [] }) } });
  s.start({ mqttBridge: { publishCommand() {} }, db: { query: async () => ({ rows: [] }) } }); // ikinci cagri etkisiz
  const pending = timers.pendingTimeouts();
  assert.equal(pending.length, 1);
  // 05:30:30 -> sonraki dakika sinirina 30 sn + 1 sn pay = 31000 ms
  assert.equal(pending[0].ms, 31000);
  assert.equal(s.isRunning(), true);
});

test('zamanlayici tetiklenince tur calisir ve bir sonraki dakika planlanir; stop yeni tur planlamaz', async () => {
  const timers = makeFakeTimers();
  let nowMs = Z('2026-10-01T05:30:30Z');
  const ticks = [];
  const s = new Scheduler({ timers, logger: makeLogger(), now: () => nowMs });
  s.runTick = async (t) => {
    ticks.push(t);
    return {};
  };
  s.start({ mqttBridge: { publishCommand() {} }, db: { query: async () => ({ rows: [] }) } });

  nowMs = Z('2026-10-01T05:31:01Z');
  timers.fireTimeout(timers.pendingTimeouts()[0]);
  await flush();
  assert.deepEqual(ticks, [Z('2026-10-01T05:31:01Z')]);
  const next = timers.pendingTimeouts();
  assert.equal(next.length, 1, 'bir sonraki tur planlanmali');
  assert.equal(next[0].ms, 60000 - (Z('2026-10-01T05:31:01Z') % 60000) + 1000);

  await s.stop();
  assert.equal(timers.pendingTimeouts().length, 0);
  assert.equal(s.isRunning(), false);
  // stop sonrasi zamanlayici tetiklense bile tur calismaz
  assert.equal(ticks.length, 1);
});

test('stop: calisan tur bitene kadar bekler', async () => {
  const timers = makeFakeTimers();
  const s = new Scheduler({ timers, logger: makeLogger(), now: () => Z('2026-10-01T05:30:30Z') });
  let finish;
  s.runTick = () => new Promise((r) => (finish = r));
  s.start({ mqttBridge: { publishCommand() {} }, db: { query: async () => ({ rows: [] }) } });
  timers.fireTimeout(timers.pendingTimeouts()[0]);
  await flush();
  let stopped = false;
  const stopP = s.stop().then(() => (stopped = true));
  await flush();
  assert.equal(stopped, false, 'tur bitmeden stop donmemeli');
  finish({});
  await stopP;
  assert.equal(stopped, true);
});

test('tur hatasi zamanlayiciyi oldurmez (bir sonraki dakika yine planlanir)', async () => {
  const timers = makeFakeTimers();
  const s = new Scheduler({ timers, logger: makeLogger(), now: () => Z('2026-10-01T05:30:30Z') });
  s.runTick = async () => {
    throw new Error('patladi');
  };
  s.start({ mqttBridge: { publishCommand() {} }, db: { query: async () => ({ rows: [] }) } });
  timers.fireTimeout(timers.pendingTimeouts()[0]);
  await flush();
  assert.equal(timers.pendingTimeouts().length, 1);
});

// -- WP-L D4: atesleme aninda hedef denetimi ------------------------------------------

const ep = (channel_index, type, device_id = DEVICE_ID) => ({ device_id, channel_index, type });
const ROLE_SHUTTER_DETAIL = 'kanal artik panjur; role kurali calistirilmadi';
const PAIR_DETAIL = 'kanal cifti artik panjur degil';

test('D4: role kurali, kanali artik panjurken YAYINLANMAZ -> skipped_invalid (talep birakilmaz, pencerede yeniden denenmez)', async () => {
  const w = makeWorld({
    rules: [{ id: 7, channel: 5, action: 'on', hour: 8, minute: 30 }],
    endpoints: [ep(5, 'shutter'), ep(6, 'shutter')],
  });
  const s = w.makeScheduler();
  const r1 = await s.runTick(AT_0830);
  assert.equal(w.world.published.length, 0, 'panjur motoru role komutuyla surulmemeli');
  assert.equal(r1.skipped, 1);
  assert.equal(r1.outcomes[0].status, 'skipped_invalid');
  assert.equal(r1.outcomes[0].released, false);
  assert.equal(w.world.runs[0].status, 'skipped_invalid');
  assert.equal(w.world.runs[0].detail, ROLE_SHUTTER_DETAIL);
  assert.equal(w.world.rules[0].last_run_at.toISOString(), '2026-10-01T05:30:00.000Z', 'kalici durum: yuva tuketilir (diger skipped_* gibi)');
  assert.equal(w.db.find(/^UPDATE scheduled_rules SET last_run_at = \$3/).length, 0, 'release cagrilmaz');

  // ayni pencerede sonraki turlar yeniden denemez
  await s.runTick(AT_0830 + MIN);
  await s.runTick(AT_0830 + 2 * MIN);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs.length, 1);
  assert.equal(w.world.runs[0].attempts, 1);
});

test('D4: role kurali, kanal lamba/priz/darbe iken yayinlanir; hedef sorgusu TEK ve cozulen cihaz + kanal ile', async () => {
  for (const type of ['light', 'plug', 'impulse']) {
    const w = makeWorld({
      rules: [{ id: 7, channel: 5, action: 'on', hour: 8, minute: 30 }],
      endpoints: [ep(5, type), ep(6, 'shutter')],
    });
    const res = await w.makeScheduler().runTick(AT_0830);
    assert.equal(res.sent, 1, type);
    assert.deepEqual(w.world.published.map((p) => p.cmd.relay), [5]);
    assert.deepEqual(w.world.targetQueries, [{ deviceId: DEVICE_ID, channels: [5] }], type);
  }
});

test('D4: uc nokta satiri yoksa eski davranis surer (yayin)', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 5, action: 'on', hour: 8, minute: 30 }, { id: 8, channel: 2, channel_type: 'shutter', action: 'close', hour: 8, minute: 30 }] });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.sent, 2);
  assert.equal(w.world.targetQueries.length, 2);
});

test('D4: panjur kurali, ciftin iki kanali panjurken yayinlanir; biri panjur degilse YAYINLANMAZ', async () => {
  const ok = makeWorld({
    rules: [{ id: 9, channel: 3, channel_type: 'shutter', action: 'open', hour: 8, minute: 30 }],
    endpoints: [ep(5, 'shutter'), ep(6, 'shutter')],
  });
  const r1 = await ok.makeScheduler().runTick(AT_0830);
  assert.equal(r1.sent, 1);
  assert.deepEqual({ shutter: ok.world.published[0].cmd.shutter, cmd: ok.world.published[0].cmd.cmd }, { shutter: 3, cmd: 'up' });
  assert.deepEqual(ok.world.targetQueries, [{ deviceId: DEVICE_ID, channels: [5, 6] }]);

  for (const endpoints of [[ep(5, 'light'), ep(6, 'shutter')], [ep(5, 'shutter'), ep(6, 'light')], [ep(5, 'light'), ep(6, 'light')]]) {
    const bad = makeWorld({ rules: [{ id: 9, channel: 3, channel_type: 'shutter', action: 'open', hour: 8, minute: 30 }], endpoints });
    const r = await bad.makeScheduler().runTick(AT_0830);
    assert.equal(bad.world.published.length, 0, JSON.stringify(endpoints));
    assert.equal(r.skipped, 1);
    assert.equal(bad.world.runs[0].status, 'skipped_invalid');
    assert.equal(bad.world.runs[0].detail, PAIR_DETAIL);
    assert.ok(bad.world.rules[0].last_run_at, 'yuva tuketilir');
  }
});

test('D4: panjur ciftinin yalniz bir satiri varsa (cift eksik) yayin yapilmaz (veriyi koruyan yorum)', async () => {
  const w = makeWorld({
    rules: [{ id: 9, channel: 4, channel_type: 'shutter', action: 'close', hour: 8, minute: 30 }],
    endpoints: [ep(7, 'shutter')],
  });
  await w.makeScheduler().runTick(AT_0830);
  assert.equal(w.world.published.length, 0);
  assert.equal(w.world.runs[0].status, 'skipped_invalid');
  assert.equal(w.world.runs[0].detail, PAIR_DETAIL);
});

test('D4: hedef denetimi cozulen cihazin satirlarina bakar (device_id belirtilmis kural, cok panolu ev)', async () => {
  const OTHER_DEV = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  const w = makeWorld({
    rules: [{ id: 7, channel: 5, action: 'on', hour: 8, minute: 30, device_id: DEVICE_ID }],
    devices: [
      { id: DEVICE_ID, home_id: HOME_ID, is_online: true },
      { id: OTHER_DEV, home_id: HOME_ID, is_online: true },
    ],
    endpoints: [ep(5, 'light'), ep(5, 'shutter', OTHER_DEV)],
  });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.sent, 1, 'kardes panonun panjur satiri bu kurali durdurmaz');
  assert.deepEqual(w.world.targetQueries, [{ deviceId: DEVICE_ID, channels: [5] }]);
});

test('D4: hedef sorgusu cihaz belirsiz/yoksa veya yetki yoksa hic calismaz (ek yuk yok)', async () => {
  const noCreator = makeWorld({ rules: [{ id: 7, channel: 5, action: 'on', hour: 8, minute: 30 }], creator: null, endpoints: [ep(5, 'shutter')] });
  await noCreator.makeScheduler().runTick(AT_0830);
  assert.equal(noCreator.world.targetQueries.length, 0);
  const noDevice = makeWorld({ rules: [{ id: 7, channel: 5, action: 'on', hour: 8, minute: 30 }], devices: [], endpoints: [ep(5, 'shutter')] });
  await noDevice.makeScheduler().runTick(AT_0830);
  assert.equal(noDevice.world.targetQueries.length, 0);
  assert.equal(noDevice.world.runs[0].status, 'skipped_device');
});

test('D4 SQL sozlesmesi: hedef sorgusu yalniz yer tutucu (cihaz + kanal dizisi), endpoints tipini okur', () => {
  assert.equal(typeof SQL.target, 'string');
  // WP-S2 [O6]: eylemci kanalini ayirt etmek icin actuator_type da okunur
  assert.match(SQL.target, /^SELECT channel_index, type, actuator_type FROM endpoints WHERE device_id = \$1::uuid AND channel_index = ANY\(\$2::int\[\]\)$/);
});

// ------------------------------------------------------------------------------
// Faz 2 / WP-G1 (F2.A.4): gaz alarmi acik evde otomatik anahtarlama YOK
// ------------------------------------------------------------------------------
test('F2.A.4: evde acik gaz alarmi varken role/panjur kurali YAYINLANMAZ -> skipped_hazard (gas_alarm); yuva tuketilir', async () => {
  for (const rule of [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }, { id: 8, channel: 1, channel_type: 'shutter', action: 'close', hour: 8, minute: 30 }]) {
    const w = makeWorld({ rules: [rule], devices: [{ id: DEVICE_ID, home_id: HOME_ID, is_online: true, gas_alarm: true }] });
    const s = w.makeScheduler();
    const r1 = await s.runTick(AT_0830);
    assert.equal(w.world.published.length, 0, 'gaz alarminda anahtarlama kivilcim kaynagi');
    assert.equal(r1.skipped, 1);
    assert.equal(r1.outcomes[0].status, 'skipped_hazard');
    assert.equal(r1.outcomes[0].released, false);
    assert.equal(w.world.runs[0].status, 'skipped_hazard');
    assert.equal(w.world.runs[0].detail, 'gas_alarm');
    await s.runTick(AT_0830 + MIN);
    assert.equal(w.world.published.length, 0, 'ayni pencerede yeniden denenmez');
  }
});

test('F2.A.4: gaz alarmi yokken davranis ve SORGU SAYISI aynen (gaz denetimi cihaz sorgusunun icinde)', async () => {
  const w = makeWorld({ rules: [{ id: 7, channel: 3, action: 'on', hour: 8, minute: 30 }], devices: [{ id: DEVICE_ID, home_id: HOME_ID, is_online: true, gas_alarm: false }] });
  const res = await w.makeScheduler().runTick(AT_0830);
  assert.equal(res.sent, 1);
  assert.equal(w.db.find(/alarms/).filter((c) => c.text !== SQL.devices).length, 0, 'ayri bir alarm sorgusu yok');
  // guvenlik-1: yalniz hala bu evde olan panonun satiri sayilir (devices ile birlesim)
  assert.match(SQL.devices, /EXISTS \(SELECT 1 FROM alarms a JOIN devices ad ON ad\.id = a\.device_id AND ad\.home_id = a\.home_id WHERE a\.home_id = devices\.home_id AND a\.kind = 'gas' AND a\.status IN \('latched', 'fault', 'silenced'\)\) AS gas_alarm/);
});
