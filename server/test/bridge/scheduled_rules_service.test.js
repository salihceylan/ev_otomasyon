'use strict';

// C8 - Zamanli kural servisi: sema dogrulama, 1 tabanli kanal, ev siniri, cihaz/uc nokta
// dogrulama, guncelleme semantigi, temizlik kancasi. (Sahte db; gercek PostgreSQL YOK.)

const test = require('node:test');
const assert = require('node:assert/strict');
const { createService, ValidationError, MAX_RULES_PER_HOME, helpers } = require('../../src/services/scheduled_rules_service');
const { HttpError } = require('../../src/utils/helpers');
const { makeFakeDb } = require('./_helpers');

const { parseRuleFields, checkTypeAction, checkChannelAgainstEndpoints, mapRule } = helpers;

const HOME = '11111111-1111-4111-8111-111111111111';
const DEVICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const USER = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

const validBody = (extra = {}) => ({ channel: 3, channel_type: 'relay', action: 'on', hour: 8, minute: 30, ...extra });

const fieldsOf = (errors) => errors.map((e) => e.field).sort();

// -- Saf alan dogrulama ---------------------------------------------------------

test('parseRuleFields: gecerli govde (snake_case)', () => {
  const { values, errors } = parseRuleFields({
    channel: 2,
    channel_type: 'shutter',
    action: 'open',
    hour: 6,
    minute: 5,
    days_of_week: [5, 1, 3],
    device_id: DEVICE.toUpperCase(),
    label: '  Sabah panjuru  ',
    enabled: false,
  });
  assert.deepEqual(errors, []);
  assert.deepEqual(values, {
    channel: 2,
    channel_type: 'shutter',
    action: 'open',
    hour: 6,
    minute: 5,
    days_of_week: [1, 3, 5], // siralanir
    device_id: DEVICE, // kucuk harfe normalize
    label: 'Sabah panjuru', // kirpilir
    enabled: false,
  });
});

test('parseRuleFields: camelCase de kabul edilir; snake_case oncelikli', () => {
  const { values, errors } = parseRuleFields({
    channel: 1,
    channelType: 'shutter',
    daysOfWeek: [0, 6],
    deviceId: DEVICE,
    action: 'close',
    hour: 1,
    minute: 2,
  });
  assert.deepEqual(errors, []);
  assert.equal(values.channel_type, 'shutter');
  assert.deepEqual(values.days_of_week, [0, 6]);
  assert.equal(values.device_id, DEVICE);

  const both = parseRuleFields({ channel_type: 'relay', channelType: 'shutter' });
  assert.equal(both.values.channel_type, 'relay');
});

test('parseRuleFields: kanal 1..40 tamsayi (0 tabanli ve kesirli reddedilir; rakam metni kabul)', () => {
  for (const ok of [1, 2, 40, '7']) assert.deepEqual(parseRuleFields({ channel: ok }).errors, [], String(ok));
  for (const bad of [0, -1, 41, 1.5, '1.5', 'a', '', null, true, [], {}, '12345', NaN, Infinity]) {
    assert.deepEqual(fieldsOf(parseRuleFields({ channel: bad }).errors), ['channel'], `reddedilmeli: ${JSON.stringify(bad)}`);
  }
});

test('parseRuleFields: saat 0..23, dakika 0..59', () => {
  for (const [h, m] of [[0, 0], [23, 59], ['9', '5']]) {
    assert.deepEqual(parseRuleFields({ hour: h, minute: m }).errors, []);
  }
  for (const bad of [-1, 24, 8.5, 'x', null, true]) {
    assert.deepEqual(fieldsOf(parseRuleFields({ hour: bad }).errors), ['hour']);
  }
  for (const bad of [-1, 60, 30.5, 'x', null, true]) {
    assert.deepEqual(fieldsOf(parseRuleFields({ minute: bad }).errors), ['minute']);
  }
});

test('parseRuleFields: days_of_week benzersiz tamsayi 0..6, bos olamaz', () => {
  assert.deepEqual(parseRuleFields({ days_of_week: [0, 1, 2, 3, 4, 5, 6] }).errors, []);
  for (const bad of [[], [7], [-1], [1, 1], ['1'], [1.5], 'hepsi', null, {}, [0, 1, 2, 3, 4, 5, 6, 0], [null]]) {
    assert.deepEqual(fieldsOf(parseRuleFields({ days_of_week: bad }).errors), ['days_of_week'], JSON.stringify(bad));
  }
});

test('parseRuleFields: action / channel_type beyaz liste', () => {
  for (const ok of ['on', 'off', 'open', 'close']) assert.deepEqual(parseRuleFields({ action: ok }).errors, []);
  for (const bad of ['toggle', 'ON', 'up', '', null, 1, 'on ', "on'; DROP TABLE x;--"]) {
    assert.deepEqual(fieldsOf(parseRuleFields({ action: bad }).errors), ['action'], JSON.stringify(bad));
  }
  for (const ok of ['relay', 'shutter']) assert.deepEqual(parseRuleFields({ channel_type: ok }).errors, []);
  for (const bad of ['plug', 'light', 'Relay', '', null, 5]) {
    assert.deepEqual(fieldsOf(parseRuleFields({ channel_type: bad }).errors), ['channel_type'], JSON.stringify(bad));
  }
});

test('parseRuleFields: device_id UUID veya null; label sinirlari; enabled boolean', () => {
  assert.deepEqual(parseRuleFields({ device_id: null }).values, { device_id: null });
  assert.deepEqual(parseRuleFields({ device_id: '' }).values, { device_id: null });
  for (const bad of ['abc', 5, {}, '11111111-1111-4111-8111-11111111111', 'AHBU-S3-0001']) {
    assert.deepEqual(fieldsOf(parseRuleFields({ device_id: bad }).errors), ['device_id']);
  }
  assert.equal(parseRuleFields({ label: 'x'.repeat(100) }).errors.length, 0);
  assert.deepEqual(fieldsOf(parseRuleFields({ label: 'x'.repeat(101) }).errors), ['label']);
  assert.deepEqual(fieldsOf(parseRuleFields({ label: 5 }).errors), ['label']);
  assert.equal(parseRuleFields({ label: 'a\u0000b\u001fc\n' }).values.label, 'abc', 'kontrol karakterleri temizlenir');
  assert.equal(parseRuleFields({ label: '   ' }).values.label, null);
  assert.equal(parseRuleFields({ label: null }).values.label, null);
  for (const bad of ['true', 1, 0, null, 'false']) {
    assert.deepEqual(fieldsOf(parseRuleFields({ enabled: bad }).errors), ['enabled'], JSON.stringify(bad));
  }
});

test('parseRuleFields: yetkiyi/kimligi etkileyen alanlar yok sayilir (home_id, created_by, id, last_run_at)', () => {
  const { values } = parseRuleFields({
    ...validBody(),
    home_id: 'x',
    homeId: 'x',
    created_by: 'x',
    id: 5,
    last_run_at: '2020-01-01',
    schedule_changed_at: '2020-01-01',
    role: 'owner',
  });
  for (const forbidden of ['home_id', 'created_by', 'id', 'last_run_at', 'schedule_changed_at', 'role']) {
    assert.equal(forbidden in values, false, forbidden);
  }
});

test('checkTypeAction: role on|off, panjur open|close', () => {
  assert.equal(checkTypeAction('relay', 'on'), null);
  assert.equal(checkTypeAction('relay', 'off'), null);
  assert.equal(checkTypeAction('shutter', 'open'), null);
  assert.equal(checkTypeAction('shutter', 'close'), null);
  assert.equal(checkTypeAction('relay', 'open').field, 'action');
  assert.equal(checkTypeAction('shutter', 'on').field, 'action');
  assert.equal(checkTypeAction('plug', 'on').field, 'action');
});

test('checkChannelAgainstEndpoints: gercek uc noktalara gore kanal 1..N, panjur kanallari role kuralina kapali', () => {
  // 8 kanal: 1-2 panjur cifti, 3..8 isik
  const endpoints = [
    { channel_index: 1, type: 'shutter' },
    { channel_index: 2, type: 'shutter' },
    ...[3, 4, 5, 6, 7, 8].map((c) => ({ channel_index: c, type: 'light' })),
  ];
  assert.equal(checkChannelAgainstEndpoints('relay', 3, endpoints), null);
  assert.equal(checkChannelAgainstEndpoints('relay', 8, endpoints), null);
  assert.equal(checkChannelAgainstEndpoints('relay', 9, endpoints).field, 'channel'); // evde 8 kanal var
  assert.match(checkChannelAgainstEndpoints('relay', 1, endpoints).message, /panjura ayrılmış/); // panjur rölesi
  assert.equal(checkChannelAgainstEndpoints('shutter', 1, endpoints), null); // pair 1 = role 1+2
  assert.equal(checkChannelAgainstEndpoints('shutter', 2, endpoints).field, 'channel'); // role 3/4 isik
  assert.equal(checkChannelAgainstEndpoints('shutter', 5, endpoints).field, 'channel'); // var olmayan
});

test('checkChannelAgainstEndpoints: karisik duzen (panjur cifti ortada) 2N-1/2N kuralina gore', () => {
  const endpoints = [
    { channel_index: 1, type: 'light' },
    { channel_index: 2, type: 'light' },
    { channel_index: 3, type: 'shutter' },
    { channel_index: 4, type: 'shutter' },
  ];
  assert.equal(checkChannelAgainstEndpoints('shutter', 2, endpoints), null); // pair 2 = role 3+4
  assert.equal(checkChannelAgainstEndpoints('shutter', 1, endpoints).field, 'channel'); // role 1/2 isik
  assert.equal(checkChannelAgainstEndpoints('relay', 2, endpoints), null);
  assert.equal(checkChannelAgainstEndpoints('relay', 3, endpoints).field, 'channel');
});

test('checkChannelAgainstEndpoints: uc nokta yoksa genel sinirlara dusulur', () => {
  assert.equal(checkChannelAgainstEndpoints('relay', 40, []), null);
  assert.equal(checkChannelAgainstEndpoints('shutter', 20, []), null);
  assert.equal(checkChannelAgainstEndpoints('shutter', 21, []).field, 'channel');
  assert.equal(checkChannelAgainstEndpoints('relay', 41, undefined).field, 'channel');
});

test('mapRule: snake_case, ISO UTC zaman, e-posta yok', () => {
  const r = mapRule({
    id: '12',
    home_id: HOME,
    device_id: null,
    channel: 3,
    channel_type: 'relay',
    action: 'on',
    hour: 8,
    minute: 30,
    days_of_week: '[0,1]',
    label: null,
    enabled: true,
    created_by: USER,
    created_by_name: 'Ayse Demir',
    last_run_at: new Date('2026-10-01T05:30:00Z'),
    created_at: '2026-09-01T00:00:00.000Z',
    updated_at: new Date('2026-09-02T00:00:00Z'),
    email: 'gizli@example.com',
  });
  assert.equal(r.id, 12);
  assert.deepEqual(r.days_of_week, [0, 1]);
  assert.equal(r.last_run_at, '2026-10-01T05:30:00.000Z');
  assert.equal(r.created_by_name, 'Ayse Demir');
  assert.equal('email' in r, false);
  assert.equal(mapRule({ ...r, last_run_at: null, days_of_week: null, enabled: false }).last_run_at, null);
});

// -- createRule ------------------------------------------------------------------

function makeCreateDb({ ruleCount = 0, homeExists = true, deviceInHome = true, endpoints = [] } = {}) {
  return makeFakeDb([
    { match: /pg_advisory_xact_lock/, reply: { rows: [{}] } },
    { match: /^SELECT id FROM homes WHERE id = \$1$/, reply: () => ({ rows: homeExists ? [{ id: HOME }] : [] }) },
    { match: /SELECT COUNT\(\*\)::int AS n FROM scheduled_rules/, reply: () => ({ rows: [{ n: ruleCount }] }) },
    { match: /^SELECT id FROM devices WHERE id = \$1 AND home_id = \$2$/, reply: () => ({ rows: deviceInHome ? [{ id: DEVICE }] : [] }) },
    { match: /FROM endpoints WHERE home_id = \$1/, reply: () => ({ rows: endpoints }) },
    {
      match: /INSERT INTO scheduled_rules/,
      reply: (_t, p) => ({
        rows: [
          {
            id: 77,
            home_id: p[0],
            device_id: p[1],
            channel: p[2],
            channel_type: p[3],
            action: p[4],
            hour: p[5],
            minute: p[6],
            days_of_week: JSON.parse(p[7]),
            label: p[8],
            enabled: p[9],
            created_by: p[10],
            created_by_name: 'Ayse Demir',
            last_run_at: null,
            created_at: new Date('2026-10-01T00:00:00Z'),
            updated_at: new Date('2026-10-01T00:00:00Z'),
          },
        ],
      }),
    },
  ]);
}

test('createRule: gecerli kural -> tek transaction, kilit, sayac, ekleme; yanit snake_case', async () => {
  const db = makeCreateDb({ endpoints: [{ channel_index: 3, type: 'light' }] });
  const svc = createService({ db });
  const rule = await svc.createRule(HOME, USER, validBody({ label: 'Salon', days_of_week: [1, 2] }));

  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
  assert.ok(db.calls.every((c) => c.inTx), 'tum sorgular ayni transaction icinde');
  assert.match(db.calls[0].text, /pg_advisory_xact_lock/);
  assert.deepEqual(db.calls[0].params, [`scheduled_rules:${HOME}`]);

  const insert = db.calls.find((c) => /INSERT INTO scheduled_rules/.test(c.text));
  assert.deepEqual(insert.params, [HOME, null, 3, 'relay', 'on', 8, 30, '[1,2]', 'Salon', true, USER]);
  assert.match(insert.text, /\$8::jsonb/);
  assert.equal(rule.id, 77);
  assert.equal(rule.channel, 3);
  assert.equal(rule.created_by_name, 'Ayse Demir');
  assert.deepEqual(rule.days_of_week, [1, 2]);
});

test('createRule: varsayilanlar (relay, her gun, etkin) ve camelCase', async () => {
  const db = makeCreateDb();
  const svc = createService({ db });
  const rule = await svc.createRule(HOME, USER, { channel: 2, action: 'off', hour: 22, minute: 0 });
  assert.equal(rule.channel_type, 'relay');
  assert.deepEqual(rule.days_of_week, [0, 1, 2, 3, 4, 5, 6]);
  assert.equal(rule.enabled, true);
  const insert = db.calls.find((c) => /INSERT/.test(c.text));
  assert.equal(insert.params[1], null); // device_id

  const db2 = makeCreateDb();
  const r2 = await createService({ db: db2 }).createRule(HOME, USER, {
    channel: 1,
    channelType: 'shutter',
    action: 'close',
    hour: 23,
    minute: 59,
    daysOfWeek: [6, 0],
  });
  assert.equal(r2.channel_type, 'shutter');
  assert.deepEqual(r2.days_of_week, [0, 6]);
});

test('createRule: home_id / created_by govdeden ALINMAZ (ev URL\'den, kullanici token\'dan)', async () => {
  const db = makeCreateDb();
  const svc = createService({ db });
  await svc.createRule(HOME, USER, validBody({ home_id: 'baska-ev', homeId: 'baska-ev', created_by: 'baska-kullanici' }));
  const insert = db.calls.find((c) => /INSERT/.test(c.text));
  assert.equal(insert.params[0], HOME);
  assert.equal(insert.params[10], USER);
});

test('createRule: zorunlu alanlar ve tum hatalar birlikte raporlanir (VALIDATION)', async () => {
  const db = makeCreateDb();
  const svc = createService({ db });
  await assert.rejects(
    () => svc.createRule(HOME, USER, { channel_type: 'relay' }),
    (err) => {
      assert.ok(err instanceof ValidationError);
      assert.equal(err.status, 400);
      assert.equal(err.code, 'VALIDATION');
      assert.deepEqual(fieldsOf(err.errors), ['action', 'channel', 'hour', 'minute']);
      return true;
    }
  );
  assert.equal(db.calls.length, 0, 'gecersiz girdide veritabani cagrilmamali');

  await assert.rejects(
    () => svc.createRule(HOME, USER, validBody({ hour: 25, days_of_week: [1, 1] })),
    (err) => err instanceof ValidationError && fieldsOf(err.errors).join() === 'days_of_week,hour'
  );
});

test('createRule: govde nesne degilse reddedilir', async () => {
  const svc = createService({ db: makeCreateDb() });
  for (const bad of [null, undefined, 'x', 5, [], [1]]) {
    await assert.rejects(() => svc.createRule(HOME, USER, bad), ValidationError);
  }
});

test('createRule: tip/eylem uyumsuzlugu (panjura "on") reddedilir', async () => {
  const db = makeCreateDb();
  await assert.rejects(
    () => createService({ db }).createRule(HOME, USER, validBody({ channel_type: 'shutter', action: 'on' })),
    (err) => err instanceof ValidationError && err.errors[0].field === 'action'
  );
  await assert.rejects(
    () => createService({ db }).createRule(HOME, USER, validBody({ channel_type: 'relay', action: 'open' })),
    ValidationError
  );
});

test('createRule: ev basina en cok 50 kural (409 CONFLICT)', async () => {
  assert.equal(MAX_RULES_PER_HOME, 50);
  const full = makeCreateDb({ ruleCount: 50 });
  await assert.rejects(
    () => createService({ db: full }).createRule(HOME, USER, validBody()),
    (err) => err instanceof HttpError && err.status === 409 && err.code === 'CONFLICT'
  );
  assert.deepEqual(full.txLog, ['BEGIN', 'ROLLBACK']);
  assert.equal(full.calls.some((c) => /INSERT/.test(c.text)), false);

  const almost = makeCreateDb({ ruleCount: 49 });
  await createService({ db: almost }).createRule(HOME, USER, validBody());
  assert.ok(almost.calls.some((c) => /INSERT/.test(c.text)));
});

test('createRule: ev yoksa 404; cihaz bu eve ait degilse 400 (baska evin cihazina kural yazilamaz)', async () => {
  await assert.rejects(
    () => createService({ db: makeCreateDb({ homeExists: false }) }).createRule(HOME, USER, validBody()),
    (err) => err.status === 404 && err.code === 'NOT_FOUND'
  );
  const db = makeCreateDb({ deviceInHome: false });
  await assert.rejects(
    () => createService({ db }).createRule(HOME, USER, validBody({ device_id: DEVICE })),
    (err) => err instanceof ValidationError && err.errors[0].field === 'device_id'
  );
  assert.equal(db.calls.some((c) => /INSERT/.test(c.text)), false);

  const ok = makeCreateDb({ deviceInHome: true });
  const rule = await createService({ db: ok }).createRule(HOME, USER, validBody({ device_id: DEVICE }));
  assert.equal(rule.device_id, DEVICE);
});

test('createRule: uc nokta dogrulamasi (panjur role kanalina role kurali reddedilir; kanal evde yok reddedilir)', async () => {
  const endpoints = [
    { channel_index: 1, type: 'shutter' },
    { channel_index: 2, type: 'shutter' },
    { channel_index: 3, type: 'light' },
    { channel_index: 4, type: 'light' },
  ];
  await assert.rejects(
    () => createService({ db: makeCreateDb({ endpoints }) }).createRule(HOME, USER, validBody({ channel: 1 })),
    (err) => err instanceof ValidationError && /panjura ayrılmış/.test(err.errors[0].message)
  );
  await assert.rejects(
    () => createService({ db: makeCreateDb({ endpoints }) }).createRule(HOME, USER, validBody({ channel: 5 })),
    ValidationError
  );
  // dogru panjur kurali
  const rule = await createService({ db: makeCreateDb({ endpoints }) }).createRule(
    HOME,
    USER,
    validBody({ channel: 1, channel_type: 'shutter', action: 'open' })
  );
  assert.equal(rule.channel_type, 'shutter');
  // channel_type DOGRU kaydedilir (eski kod her zaman 'relay' yaziyordu)
});

test('createRule: channel_type dogru kaydedilir', async () => {
  const db = makeCreateDb();
  await createService({ db }).createRule(HOME, USER, validBody({ channel: 2, channel_type: 'shutter', action: 'close' }));
  const insert = db.calls.find((c) => /INSERT/.test(c.text));
  assert.equal(insert.params[3], 'shutter');
  assert.equal(insert.params[4], 'close');
});

// -- updateRule ------------------------------------------------------------------

const EXISTING = Object.freeze({
  id: 5,
  home_id: HOME,
  device_id: null,
  channel: 3,
  channel_type: 'relay',
  action: 'on',
  hour: 8,
  minute: 30,
  days_of_week: [0, 1, 2, 3, 4, 5, 6],
  label: 'Mevcut',
  enabled: true,
  created_by: USER,
});

function makeUpdateDb({ existing = EXISTING, endpoints = [{ channel_index: 3, type: 'light' }, { channel_index: 4, type: 'light' }], deviceInHome = true } = {}) {
  return makeFakeDb([
    { match: /^SELECT \* FROM scheduled_rules WHERE id = \$1 AND home_id = \$2 FOR UPDATE$/, reply: () => ({ rows: existing ? [{ ...existing }] : [] }) },
    { match: /^SELECT id FROM devices WHERE id = \$1 AND home_id = \$2$/, reply: () => ({ rows: deviceInHome ? [{ id: DEVICE }] : [] }) },
    { match: /FROM endpoints WHERE home_id = \$1/, reply: () => ({ rows: endpoints }) },
    {
      match: /WITH upd AS/,
      reply: (text, p) => ({ rows: [{ ...existing, id: p[p.length - 2], created_by_name: 'Ayse', _sql: text }] }),
    },
  ]);
}

const updateCall = (db) => db.calls.find((c) => /WITH upd AS/.test(c.text));

test('updateRule: yalnizca gonderilen alanlar guncellenir; kimlik/ev WHERE ile baglanir', async () => {
  const db = makeUpdateDb();
  const svc = createService({ db });
  await svc.updateRule(HOME, 5, { label: 'Yeni etiket', enabled: false });
  const upd = updateCall(db);
  assert.match(upd.text, /SET label = \$1, enabled = \$2\s+WHERE id = \$3 AND home_id = \$4/);
  assert.deepEqual(upd.params, ['Yeni etiket', false, 5, HOME]);
  assert.deepEqual(db.txLog, ['BEGIN', 'COMMIT']);
});

test('updateRule: ETIKET/eylem degisimi son calismayi SIFIRLAMAZ; saat/dakika/gun/etkinlestirme SIFIRLAR', async () => {
  const noReset = makeUpdateDb();
  await createService({ db: noReset }).updateRule(HOME, 5, { label: 'x' });
  assert.doesNotMatch(updateCall(noReset).text, /last_run_at/);
  assert.doesNotMatch(updateCall(noReset).text, /schedule_changed_at/);

  const sameTime = makeUpdateDb();
  await createService({ db: sameTime }).updateRule(HOME, 5, { hour: 8, minute: 30, days_of_week: [6, 5, 4, 3, 2, 1, 0] });
  assert.doesNotMatch(updateCall(sameTime).text, /last_run_at/, 'degerler ayniysa sifirlanmaz');

  for (const patch of [{ hour: 9 }, { minute: 31 }, { days_of_week: [1, 2] }]) {
    const db = makeUpdateDb();
    await createService({ db }).updateRule(HOME, 5, patch);
    assert.match(updateCall(db).text, /schedule_changed_at = CURRENT_TIMESTAMP, last_run_at = NULL/, JSON.stringify(patch));
  }

  // kapaliyken yeniden etkinlestirme sifirlar; acikken enabled:true sifirlamaz
  const reEnable = makeUpdateDb({ existing: { ...EXISTING, enabled: false } });
  await createService({ db: reEnable }).updateRule(HOME, 5, { enabled: true });
  assert.match(updateCall(reEnable).text, /last_run_at = NULL/);
  const stillOn = makeUpdateDb();
  await createService({ db: stillOn }).updateRule(HOME, 5, { enabled: true });
  assert.doesNotMatch(updateCall(stillOn).text, /last_run_at/);
});

test('updateRule: hedefi etkileyen degisiklikte (kanal/tip/eylem/cihaz) yeniden dogrulama', async () => {
  // kanal 9: evde yok
  await assert.rejects(
    () => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, { channel: 9 }),
    ValidationError
  );
  // role kurali panjura cevrilince eylem uyumsuz ("on" -> panjur)
  await assert.rejects(
    () => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, { channel_type: 'shutter' }),
    (err) => err instanceof ValidationError && err.errors[0].field === 'action'
  );
  // tip + eylem birlikte dogru ama panjur ciftine uc nokta yok
  await assert.rejects(
    () => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, { channel_type: 'shutter', action: 'open', channel: 1 }),
    ValidationError
  );
  // baska evin cihazi
  await assert.rejects(
    () => createService({ db: makeUpdateDb({ deviceInHome: false }) }).updateRule(HOME, 5, { device_id: DEVICE }),
    (err) => err instanceof ValidationError && err.errors[0].field === 'device_id'
  );
  // gecerli kanal degisimi
  const ok = makeUpdateDb();
  await createService({ db: ok }).updateRule(HOME, 5, { channel: 4 });
  assert.match(updateCall(ok).text, /SET channel = \$1/);
});

test('updateRule: bozuk eski kural yalnizca kapatilirken (etkin/etiket) uc nokta dogrulamasina TAKILMAZ', async () => {
  const broken = { ...EXISTING, channel: 30 }; // evde 30. kanal yok
  const db = makeUpdateDb({ existing: broken });
  await createService({ db }).updateRule(HOME, 5, { enabled: false });
  assert.ok(updateCall(db));
});

test('updateRule: kural yoksa / baska evin kuraliysa 404; bos veya gecersiz govde 400', async () => {
  await assert.rejects(
    () => createService({ db: makeUpdateDb({ existing: null }) }).updateRule(HOME, 999, { label: 'x' }),
    (err) => err.status === 404 && err.code === 'NOT_FOUND'
  );
  await assert.rejects(() => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, {}), (err) => err instanceof ValidationError);
  await assert.rejects(() => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, { hour: 99 }), ValidationError);
  await assert.rejects(() => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, null), ValidationError);
  // SELECT ... FOR UPDATE home_id ile sinirli: baska evin kurali bulunamaz
  const db = makeUpdateDb({ existing: null });
  await assert.rejects(() => createService({ db }).updateRule(HOME, 5, { label: 'x' }));
  assert.deepEqual(db.calls[0].params, [5, HOME]);
});

// -- deleteRule / temizlik kancasi ------------------------------------------------

test('deleteRule: ev ile sinirli silme; yoksa 404', async () => {
  const db = makeFakeDb([{ match: /^DELETE FROM scheduled_rules WHERE id = \$1 AND home_id = \$2 RETURNING id$/, reply: { rows: [{ id: 5 }], rowCount: 1 } }]);
  assert.deepEqual(await createService({ db }).deleteRule(HOME, 5), { id: 5 });
  assert.deepEqual(db.calls[0].params, [5, HOME]);

  const none = makeFakeDb();
  await assert.rejects(() => createService({ db: none }).deleteRule(HOME, 5), (err) => err.status === 404);
});

test('listRules: ev ile sinirli, saate gore sirali, e-posta yok', async () => {
  const db = makeFakeDb([
    {
      match: /FROM scheduled_rules sr LEFT JOIN users u/,
      reply: { rows: [{ ...EXISTING, created_by_name: 'Ayse', created_at: new Date(0), updated_at: new Date(0), last_run_at: null }] },
    },
  ]);
  const rules = await createService({ db }).listRules(HOME);
  assert.equal(rules.length, 1);
  assert.match(db.calls[0].text, /WHERE sr\.home_id = \$1 ORDER BY sr\.hour ASC, sr\.minute ASC, sr\.id ASC/);
  assert.match(db.calls[0].text, /u\.full_name AS created_by_name/);
  assert.doesNotMatch(db.calls[0].text, /u\.email/);
  assert.deepEqual(db.calls[0].params, [HOME]);
});

test('homeCleanupHook: devir/sifirlamada evin kurallari ve calisma gunlugu cagiranin transaction\'inda silinir', async () => {
  const db = makeFakeDb([
    { match: /DELETE FROM scheduled_rule_runs/, reply: { rows: [], rowCount: 3 } },
    { match: /DELETE FROM scheduled_rules/, reply: { rows: [], rowCount: 2 } },
  ]);
  let result;
  await db.withTransaction(async (tx) => {
    result = await createService({ db }).homeCleanupHook(tx, HOME);
  });
  assert.deepEqual(result, { rules: 2, runs: 3 });
  assert.ok(db.calls.every((c) => c.inTx));
  assert.deepEqual(db.calls.map((c) => c.params), [[HOME], [HOME]]);
  // calisma gunlugu once (rule_id FK SET NULL oldugundan sirasi onemsiz ama home_id ile silinir)
  assert.match(db.calls[0].text, /scheduled_rule_runs/);
});

test('varsayilan servis nesnesi beklenen arayuzu sunar (A/B cagirabilsin)', () => {
  const svc = require('../../src/services/scheduled_rules_service');
  for (const fn of ['listRules', 'createRule', 'updateRule', 'deleteRule', 'homeCleanupHook', 'deleteRulesForHome']) {
    assert.equal(typeof svc[fn], 'function', fn);
  }
});

// -- C9: kullaniciya donen mesajlar DOGRU Turkce karakterlerle (UTF-8) ---------------------------

const ASCII_FOLDED = /\b(Gecersiz|gecersiz|olmali|bulunamadi|icin|degil|yalnizca|olusturun|ayrilmis|Guncellenecek|Istek|govdesi|zamanli|ogeli|araliginda|icermeli|kimligi|numarasi)\b/;

test('C9: dogrulama / hata mesajlari ASCII\'ye INDIRGENMEMIS, dogru Turkce karakterlerle yazilmis', async () => {
  const messages = [];
  const collect = (fields) => parseRuleFields(fields).errors.forEach((e) => messages.push(e.message));
  collect({ channel: 0, channel_type: 'x', action: 'x', hour: 99, minute: 99, days_of_week: [9], device_id: 'x', label: 5, enabled: 'x' });
  collect({ days_of_week: [] });
  collect({ days_of_week: [1, 1] });
  collect({ days_of_week: [1, 2, 3, 4, 5, 6, 7, 8] });
  messages.push(checkTypeAction('relay', 'open').message);
  messages.push(checkChannelAgainstEndpoints('relay', 41, []).message);
  messages.push(checkChannelAgainstEndpoints('shutter', 5, [{ channel_index: 1, type: 'light' }, { channel_index: 2, type: 'light' }]).message);
  messages.push(checkChannelAgainstEndpoints('relay', 9, [{ channel_index: 1, type: 'light' }]).message);
  messages.push(checkChannelAgainstEndpoints('shutter', 1, [{ channel_index: 1, type: 'light' }, { channel_index: 2, type: 'light' }]).message);

  const svc = createService({ db: makeCreateDb({ ruleCount: 50 }) });
  for (const fn of [
    () => svc.createRule(HOME, USER, null),
    () => svc.createRule(HOME, USER, { channel_type: 'relay' }),
    () => svc.createRule(HOME, USER, validBody()), // 50 kural siniri
    () => createService({ db: makeCreateDb({ homeExists: false }) }).createRule(HOME, USER, validBody()),
    () => createService({ db: makeCreateDb({ deviceInHome: false }) }).createRule(HOME, USER, validBody({ device_id: DEVICE })),
    () => createService({ db: makeUpdateDb({ existing: null }) }).updateRule(HOME, 9, { label: 'x' }),
    () => createService({ db: makeUpdateDb() }).updateRule(HOME, 5, {}),
    () => createService({ db: makeFakeDb() }).deleteRule(HOME, 5),
  ]) {
    await fn().then(() => assert.fail('hata bekleniyordu'), (err) => messages.push(err.message));
  }

  assert.ok(messages.length >= 20);
  for (const m of messages) {
    assert.doesNotMatch(m, ASCII_FOLDED, `ASCII'ye indirgenmis mesaj: ${m}`);
  }
  // somut beklenen metinler (UTF-8)
  const all = messages.join('\n');
  for (const expected of ['Geçersiz kanal numarası', 'Geçersiz saat', 'Geçersiz dakika', 'Gün listesi', 'Geçersiz cihaz kimliği', 'Kural bulunamadı', 'Ev bulunamadı', 'zamanlı kural', 'İstek gövdesi', 'Güncellenecek alan yok', 'Cihaz bu eve ait değil']) {
    assert.ok(all.includes(expected), `beklenen metin yok: ${expected}`);
  }
});
