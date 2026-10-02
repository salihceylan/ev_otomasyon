'use strict';

// services/home_cleanup.js - devir / acil sifirlama ortak ev temizligi (to_regclass korumali)

const test = require('node:test');
const assert = require('node:assert');

const { FakeDb } = require('./_fake_db');
const { cleanupHome } = require('../../src/services/home_cleanup');

const HOME = '11111111-1111-4111-8111-111111111111';

/**
 * schema: { tablo: [sutunlar] } - olmayan tablo sorgulandiginda to_regclass NULL doner.
 * rows: { tablo: satir sayisi } - DELETE/UPDATE'in etkiledigi satir sayisi.
 */
function makeDb(schema, rows = {}) {
  const db = new FakeDb();
  db.on('SELECT to_regclass($1)', ({ params }) => {
    const name = String(params[0]).replace(/^public\./, '');
    return [{ t: schema[name] ? `public.${name}` : null }];
  });
  db.on('FROM information_schema.columns', ({ params }) => {
    const [table, column] = params;
    return schema[table] && schema[table].includes(column) ? [{ '?column?': 1 }] : [];
  });
  db.on(/^DELETE FROM scheduled_rule_runs/, () => ({ rows: [], rowCount: rows.scheduled_rule_runs || 0 }));
  db.on(/^DELETE FROM (\w+) WHERE home_id = \$1$/, ({ sql }) => {
    const table = /^DELETE FROM (\w+)/.exec(sql)[1];
    return { rows: [], rowCount: rows[table] || 0 };
  });
  db.on(/^UPDATE (\w+) SET .* WHERE home_id = \$1/, ({ sql }) => {
    const table = /^UPDATE (\w+)/.exec(sql)[1];
    return { rows: [], rowCount: rows[table] || 0 };
  });
  return db;
}

const FULL_SCHEMA = {
  scheduled_rules: ['id', 'home_id'],
  scheduled_rule_runs: ['id', 'rule_id'],
  home_invitations: ['id', 'home_id'],
  service_tokens: ['id', 'home_id', 'revoked_at', 'used_at'],
  service_sessions: ['id', 'home_id', 'revoked_at', 'revoked_reason'],
  home_transfers: ['id', 'home_id', 'status'],
  peace_notification_logs: ['id', 'home_id'],
  endpoints: ['id', 'home_id'],
};

async function run(db, options) {
  return db.withTransaction((tx) => cleanupHome(tx, HOME, options));
}

test('tum tablolar varken: kurallar, davetler, servis PIN/oturumlari, devir, gunluk ve kanallar temizlenir', async () => {
  const db = makeDb(FULL_SCHEMA, {
    scheduled_rules: 3, home_invitations: 2, service_tokens: 1, service_sessions: 2, home_transfers: 1,
    peace_notification_logs: 4, endpoints: 8,
  });
  const r = await run(db);
  assert.deepStrictEqual(r.cleaned, {
    scheduled_rules: 3, home_invitations: 2, service_tokens: 1, service_sessions: 2,
    peace_notification_logs: 4, home_transfers: 1, endpoints: 8,
  });
  assert.deepStrictEqual(r.skipped, []);

  const sqls = db.sqls();
  assert.ok(sqls.some((s) => s === 'DELETE FROM scheduled_rules WHERE home_id = $1'));
  assert.ok(sqls.some((s) => s === 'DELETE FROM home_invitations WHERE home_id = $1'));
  assert.ok(sqls.some((s) => s === 'DELETE FROM endpoints WHERE home_id = $1'));
  assert.ok(sqls.some((s) => s === 'DELETE FROM peace_notification_logs WHERE home_id = $1'));
  assert.ok(sqls.some((s) => /^UPDATE home_transfers SET status = 'CANCELLED' WHERE home_id = \$1 AND status = 'PENDING'$/.test(s)));
  // her sorgu ev kimligiyle sinirli
  const mutating = db.log.filter((l) => /^(DELETE|UPDATE)/.test(l.sql) && !l.sql.includes('scheduled_rule_runs'));
  assert.ok(mutating.length >= 7);
  assert.ok(mutating.every((l) => l.params[0] === HOME), 'her temizlik sorgusu yalnizca bu evin kayitlarina dokunmali');
  // hepsi ayni transaction icinde
  assert.ok(db.log.every((l) => l.tx !== null));
  assert.strictEqual(db.commits, 1);
});

test('servis PIN ve oturumlari revoked_at sutunu varsa IPTAL EDILIR (denetim izi korunur), yoksa silinir', async () => {
  const db = makeDb(FULL_SCHEMA);
  await run(db);
  const tok = db.sqls().find((s) => s.startsWith('UPDATE service_tokens'));
  const ses = db.sqls().find((s) => s.startsWith('UPDATE service_sessions'));
  assert.match(tok, /SET revoked_at = NOW\(\) WHERE home_id = \$1 AND revoked_at IS NULL/);
  assert.ok(!/revoked_reason/.test(tok), 'service_tokens\'ta revoked_reason sutunu yok: yazilmamali');
  assert.match(ses, /SET revoked_at = NOW\(\), revoked_reason = 'home_reset' WHERE home_id = \$1 AND revoked_at IS NULL/);
  assert.ok(!db.sqls().some((s) => /^DELETE FROM service_(tokens|sessions)/.test(s)));

  // revoked_at yoksa DELETE
  const db2 = makeDb({ ...FULL_SCHEMA, service_tokens: ['id', 'home_id'], service_sessions: ['id', 'home_id'] });
  await run(db2);
  assert.ok(db2.sqls().includes('DELETE FROM service_tokens WHERE home_id = $1'));
  assert.ok(db2.sqls().includes('DELETE FROM service_sessions WHERE home_id = $1'));
});

test('tablolar YOKSA hata firlatilmaz ve ilgili tablo icin hicbir DELETE/UPDATE gonderilmez', async () => {
  const db = makeDb({ endpoints: ['id', 'home_id'] }); // yalniz endpoints var
  const r = await run(db);
  assert.deepStrictEqual(r.cleaned, { endpoints: 0 });
  assert.deepStrictEqual(
    [...r.skipped].sort(),
    ['home_invitations', 'home_transfers', 'peace_notification_logs', 'scheduled_rules', 'service_sessions', 'service_tokens'].sort()
  );
  const mutating = db.sqls().filter((s) => /^(DELETE|UPDATE)/.test(s));
  assert.deepStrictEqual(mutating, ['DELETE FROM endpoints WHERE home_id = $1']);
});

test('tablo var ama home_id sutunu yok: atlanir (basarisiz sorgu transaction\'i iptal etmesin)', async () => {
  const db = makeDb({ ...FULL_SCHEMA, service_sessions: ['id', 'user_id'] });
  const r = await run(db);
  assert.ok(r.skipped.includes('service_sessions'));
  assert.ok(!db.sqls().some((s) => s.includes('service_sessions') && /^(DELETE|UPDATE)/.test(s)));
});

test('keepEndpoints:true kanallara DOKUNMAZ (devir: donanim ayni kalir); varsayilan siler', async () => {
  const keep = makeDb(FULL_SCHEMA);
  const r1 = await run(keep, { keepEndpoints: true });
  assert.ok(!('endpoints' in r1.cleaned));
  assert.ok(!keep.sqls().some((s) => s.startsWith('DELETE FROM endpoints')));

  const drop = makeDb(FULL_SCHEMA);
  await run(drop, { keepEndpoints: false });
  assert.ok(drop.sqls().includes('DELETE FROM endpoints WHERE home_id = $1'));
  const dflt = makeDb(FULL_SCHEMA);
  await run(dflt);
  assert.ok(dflt.sqls().includes('DELETE FROM endpoints WHERE home_id = $1'));
});

test('cancelPendingTransfers:false bekleyen devir kayitlarina dokunmaz (kabul eden akis kendi kaydini kapatir)', async () => {
  const db = makeDb(FULL_SCHEMA);
  const r = await run(db, { cancelPendingTransfers: false });
  assert.ok(!('home_transfers' in r.cleaned));
  assert.ok(!db.sqls().some((s) => s.includes('home_transfers') && s.startsWith('UPDATE')));
});

test('zamanlanmis kural calisma gunlugu (rule_id FK) once silinir: FK CASCADE olmasa da kural silme basarisiz olmaz', async () => {
  const db = makeDb(FULL_SCHEMA);
  await run(db);
  const sqls = db.sqls();
  const iRuns = sqls.findIndex((s) => s.startsWith('DELETE FROM scheduled_rule_runs'));
  const iRules = sqls.findIndex((s) => s === 'DELETE FROM scheduled_rules WHERE home_id = $1');
  assert.ok(iRuns >= 0 && iRules > iRuns);
  assert.match(sqls[iRuns], /rule_id IN \(SELECT id FROM scheduled_rules WHERE home_id = \$1\)/);

  // gunluk tablosu yoksa atlanir
  const db2 = makeDb({ ...FULL_SCHEMA, scheduled_rule_runs: undefined });
  await run(db2);
  assert.ok(!db2.sqls().some((s) => s.startsWith('DELETE FROM scheduled_rule_runs')));
});

test('uyelikler (home_users) ve MQTT kimlikleri temizligin KAPSAMINDA DEGILDIR (cagiran yonetir)', async () => {
  const db = makeDb(FULL_SCHEMA);
  await run(db);
  assert.ok(!db.sqls().some((s) => /home_users|mqtt_credentials|mqtt_acl/.test(s)));
});

test('gecersiz kullanim: tx veya homeId yoksa TypeError', async () => {
  await assert.rejects(cleanupHome(null, HOME), TypeError);
  await assert.rejects(cleanupHome({}, HOME), TypeError);
  const db = makeDb(FULL_SCHEMA);
  await assert.rejects(db.withTransaction((tx) => cleanupHome(tx, '')), TypeError);
});

test('SQL yalniz bu dosyadaki SABIT tablo adlarini iceriyor (kullanici girdisi enjekte edilemez)', async () => {
  const db = makeDb(FULL_SCHEMA);
  await db.withTransaction((tx) => cleanupHome(tx, "x'; DROP TABLE users; --"));
  for (const l of db.log) {
    assert.ok(!/DROP TABLE|--/.test(l.sql), l.sql);
  }
  // ev kimligi yalnizca parametre olarak gider
  assert.ok(db.log.some((l) => l.params[0] === "x'; DROP TABLE users; --"));
});
