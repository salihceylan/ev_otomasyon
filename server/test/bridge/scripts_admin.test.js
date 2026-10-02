'use strict';

// C8 - Yonetim betikleri: hedef onayi/maskeleme, gelistirme tohumu, ilk super kullanici,
// backend MQTT kimligi, legacy yukseltme. Sahte pg istemcisi; sirlar test icinde RASTGELE uretilir.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const bcrypt = require('bcryptjs');

const target = require('../../scripts/lib/target');
const seedDev = require('../../scripts/seed_dev');
const createSuper = require('../../scripts/create_super_user');
const createBackend = require('../../scripts/create_backend_mqtt_user');
const upgradeLegacy = require('../../scripts/upgrade_legacy_mqtt_user');
const { listMigrationFiles, maskSql, MIGRATIONS_DIR } = require('../../scripts/migrate');

// Cost dusuk bcrypt: hash dogrulugu compareSync ile yine denetlenir; yalnizca test suresini kisaltir.
const fastBcrypt = { hashSync: (p) => bcrypt.hashSync(p, 4), compareSync: (p, h) => bcrypt.compareSync(p, h) };
const rnd = (n = 24) => crypto.randomBytes(n).toString('base64url'); // test icin rastgele, kodda sabit sir yok
const DB_PASS = rnd(12);
const URL_OK = `postgresql://svc_user:${DB_PASS}@127.0.0.1:5434/ev_otomasyon`;

function makeClient(responders = [], state = { queries: [] }) {
  state.options = null;
  const Client = class {
    constructor(opts) {
      state.options = opts;
    }
    async connect() {}
    async end() {
      state.ended = true;
    }
    async query(text, params) {
      state.queries.push({ text, params });
      for (const r of responders) {
        if (r.match.test(text)) {
          const out = typeof r.reply === 'function' ? r.reply(text, params) : r.reply;
          if (out instanceof Error) throw out;
          return out;
        }
      }
      return { rows: [], rowCount: 0 };
    }
  };
  return { Client, state };
}

const sink = () => {
  const lines = [];
  return { fn: (...a) => lines.push(a.join(' ')), lines };
};

// -- scripts/lib/target.js ---------------------------------------------------------------

test('parseDatabaseUrl: host/port/db/kullanici; PAROLA donmez; yuzde kodlu degerler cozulur', () => {
  const t = target.parseDatabaseUrl(`postgres://ev%5Fadmin:p%40ss%3Aw%2Frd@db.internal:5434/ev%5Fotomasyon`);
  assert.deepEqual(t, { protocol: 'postgres', host: 'db.internal', port: 5434, database: 'ev_otomasyon', user: 'ev_admin' });
  assert.equal(JSON.stringify(t).includes('p@ss'), false);
  assert.equal(target.parseDatabaseUrl('postgresql://u@h/db').port, 5432);
  assert.equal(target.describeTarget(t), 'ev_admin@db.internal:5434/ev_otomasyon');
});

test('parseDatabaseUrl: gecersiz girdiler TargetError; hata iletisi URL (parola) icermez', () => {
  const secretUrl = `mysql://u:${DB_PASS}@h/db`;
  for (const bad of [undefined, null, '', '   ', 'notaurl', secretUrl, 'postgres://u@h', 'postgres://u@h/']) {
    assert.throws(() => target.parseDatabaseUrl(bad), (err) => {
      assert.ok(err instanceof target.TargetError);
      assert.ok(!err.message.includes(DB_PASS), 'hata iletisinde parola olmamali');
      return true;
    }, String(bad));
  }
});

test('assertConfirmed: MIGRATE_CONFIRM hedef veritabani adina TAM esit olmali', () => {
  const t = target.parseDatabaseUrl(URL_OK);
  assert.equal(target.assertConfirmed({ MIGRATE_CONFIRM: 'ev_otomasyon' }, t), true);
  for (const bad of [undefined, '', 'ev', 'EV_OTOMASYON', 'ev_otomasyon ', 'ev_otomasyon2']) {
    assert.throws(() => target.assertConfirmed({ MIGRATE_CONFIRM: bad }, t), target.TargetError, String(bad));
  }
  // hata iletisi hedefi gosterir (operator yanlis veritabanini fark etsin)
  assert.throws(() => target.assertConfirmed({}, t), /127\.0\.0\.1:5434\/ev_otomasyon/);
});

test('redactUrl: baglanti dizesindeki parola maskelenir', () => {
  assert.equal(target.redactUrl(URL_OK), 'postgresql://svc_user:***@127.0.0.1:5434/ev_otomasyon');
});

test('requireSecretEnv: eksik / kisa / bicim hatali sirlar reddedilir; hata iletisinde deger yok', () => {
  const secret = rnd(8);
  assert.equal(target.requireSecretEnv({ X: secret }, 'X', { minLength: 5 }), secret);
  assert.throws(() => target.requireSecretEnv({}, 'X'), /X ortam degiskeni tanimli degil/);
  assert.throws(() => target.requireSecretEnv({ X: 'ab' }, 'X', { minLength: 5 }), (e) => !e.message.includes('ab') || /en az 5/.test(e.message));
  assert.throws(() => target.requireSecretEnv({ X: secret }, 'X', { pattern: /^\d+$/ }), (e) => !e.message.includes(secret));
});

// -- scripts/seed_dev.js ---------------------------------------------------------------------

const DEV_ENV = () => ({
  DATABASE_URL: URL_OK,
  ALLOW_DEV_SEEDS: 'true',
  MIGRATE_CONFIRM: 'ev_otomasyon',
  DEV_SEED_PASSWORD: rnd(16),
  DEV_SEED_PIN: '482913',
});

test('assertDevSeedAllowed: uretimde, izinsiz veya onaysiz CALISMAZ', () => {
  assert.throws(() => seedDev.assertDevSeedAllowed({ ...DEV_ENV(), NODE_ENV: 'production' }), /URETIMDE/);
  assert.throws(() => seedDev.assertDevSeedAllowed({ ...DEV_ENV(), NODE_ENV: 'PRODUCTION' }), /URETIMDE/);
  assert.throws(() => seedDev.assertDevSeedAllowed({ ...DEV_ENV(), ALLOW_DEV_SEEDS: undefined }), /ALLOW_DEV_SEEDS/);
  assert.throws(() => seedDev.assertDevSeedAllowed({ ...DEV_ENV(), ALLOW_DEV_SEEDS: '1' }), /ALLOW_DEV_SEEDS/);
  assert.throws(() => seedDev.assertDevSeedAllowed({ ...DEV_ENV(), MIGRATE_CONFIRM: 'baska' }), target.TargetError);
  assert.throws(() => seedDev.assertDevSeedAllowed({ ...DEV_ENV(), DATABASE_URL: undefined }), target.TargetError);
  assert.equal(seedDev.assertDevSeedAllowed({ ...DEV_ENV(), NODE_ENV: 'development' }).database, 'ev_otomasyon');
});

test('buildTokens: parola/PIN ortamdan zorunlu; bcrypt cost 12; PIN ozeti pepper\'a gore', () => {
  const env = DEV_ENV();
  const tokens = seedDev.buildTokens(env, {});
  assert.match(tokens.DEV_PASSWORD_HASH, /^\$2[aby]\$12\$/);
  assert.equal(bcrypt.compareSync(env.DEV_SEED_PASSWORD, tokens.DEV_PASSWORD_HASH), true);
  assert.equal(tokens.DEV_PIN_HASH, crypto.createHash('sha256').update(env.DEV_SEED_PIN).digest('hex'));
  assert.equal(tokens.DEV_OWNER_EMAIL, 'dev.owner@example.invalid');
  assert.equal(tokens.DEV_SUPER_EMAIL, 'dev.super@example.invalid');

  const peppered = seedDev.buildTokens({ ...env, PIN_PEPPER: rnd(40) }, { pinLib: { hashPin: (p) => `h1$${'ab'.repeat(32)}` } });
  assert.match(peppered.DEV_PIN_HASH, /^h1\$[0-9a-f]{64}$/);

  assert.throws(() => seedDev.buildTokens({ ...env, DEV_SEED_PASSWORD: undefined }, {}), /DEV_SEED_PASSWORD/);
  assert.throws(() => seedDev.buildTokens({ ...env, DEV_SEED_PASSWORD: 'kisa' }, {}), /en az 10/);
  assert.throws(() => seedDev.buildTokens({ ...env, DEV_SEED_PIN: '12345' }, {}), /DEV_SEED_PIN/);
  assert.throws(() => seedDev.buildTokens({ ...env, DEV_SEED_PIN: 'abcdef' }, {}), /DEV_SEED_PIN/);
  assert.throws(() => seedDev.buildTokens({ ...env, DEV_SEED_OWNER_EMAIL: 'bozuk' }, {}), /e-posta/);
});

test('renderSeed: yer tutucular tirnak kacisli doldurulur; bilinen olmayan yer tutucu hatadir', () => {
  assert.equal(seedDev.renderSeed("VALUES ('{{A}}', '{{B}}')", { A: "o'k", B: '$2a$12$x' }), "VALUES ('o''k', '$2a$12$x')");
  assert.throws(() => seedDev.renderSeed("'{{NOPE}}'", { A: '1' }), /Bilinmeyen tohum yer tutucusu: NOPE/);
  assert.equal(seedDev.renderSeed('SELECT 1;', {}), 'SELECT 1;');
});

test('GERCEK dev_seeds/*.sql: tum yer tutucular bilinen kume icinde, sabit parola/PIN/e-posta yok, DO NOTHING', () => {
  const dir = path.join(MIGRATIONS_DIR, 'dev_seeds');
  const names = seedDev.listSeedFiles(dir);
  // WP-C'nin uc tohumu mutlaka var ve sirali; baska oturumlar dev_seeds'e yeni dosya ekleyebilir (tam esitlik aranmaz)
  for (const required of ['002_demo_home.sql', '003_demo_inventory.sql', '014_demo_super_user.sql']) {
    assert.ok(names.includes(required), `${required} eksik`);
  }
  const ours = names.filter((n) => ['002_demo_home.sql', '003_demo_inventory.sql', '014_demo_super_user.sql'].includes(n));
  assert.deepEqual(ours, ['002_demo_home.sql', '003_demo_inventory.sql', '014_demo_super_user.sql']);
  const known = ['DEV_PASSWORD_HASH', 'DEV_PIN_HASH', 'DEV_OWNER_EMAIL', 'DEV_SUPER_EMAIL'];
  for (const n of names.filter((x) => ours.includes(x))) {
    const sql = fs.readFileSync(path.join(dir, n), 'utf8');
    const used = [...sql.matchAll(/\{\{([A-Z0-9_]+)\}\}/g)].map((m) => m[1]);
    assert.ok(used.every((u) => known.includes(u)), `${n}: bilinmeyen yer tutucu`);
    const rendered = seedDev.renderSeed(sql, Object.fromEntries(known.map((k) => [k, 'x'])));
    assert.doesNotMatch(rendered, /\{\{/);
    assert.doesNotMatch(maskSql(sql), /DO\s+UPDATE/i, `${n}: yeniden calistirmada mevcut satiri EZMEMELI (yorumlar haric)`);
    assert.doesNotMatch(sql, /\$2[aby]\$\d{2}\$[./A-Za-z0-9]{50,}/, `${n}: gomulu bcrypt ozeti olmamali`);
    assert.doesNotMatch(sql, /[0-9a-f]{64}/i, `${n}: gomulu SHA-256 ozeti olmamali`);
    assert.doesNotMatch(sql, /@(gmail|gudeteknoloji|ahbu)\./i, `${n}: gercek e-posta alani olmamali`);
  }
  // 002: eski sabit demo PIN'i / "setup_pin" duz metin kolonu yazilmiyor
  const demo = fs.readFileSync(path.join(dir, '002_demo_home.sql'), 'utf8');
  assert.doesNotMatch(demo, /INSERT INTO devices \([^)]*setup_pin/);
});

test('seed_dev.main: izin/onay yoksa 2 (baglanti yok); bekleyen migration varsa 1; basarida tohumlar TEK transaction', async () => {
  // izinsiz
  const a = makeClient();
  const o1 = sink();
  const e1 = sink();
  assert.equal(await seedDev.main({ env: { ...DEV_ENV(), ALLOW_DEV_SEEDS: 'false' }, Client: a.Client, log: o1.fn, errLog: e1.fn }), 2);
  assert.equal(a.state.options, null, 'baglanti acilmamali');

  // bekleyen migration
  const b = makeClient([
    { match: /to_regclass/, reply: { rows: [{ t: 'schema_migrations' }] } },
    { match: /SELECT name FROM schema_migrations/, reply: { rows: [{ name: '001_multi_tenant_schema.sql' }] } },
  ]);
  const e2 = sink();
  assert.equal(await seedDev.main({ env: DEV_ENV(), Client: b.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: e2.fn }), 1);
  assert.match(e2.lines.join('\n'), /bekleyen migration/);
  assert.equal(b.state.queries.some((q) => /^BEGIN/.test(q.text)), false);

  // basari: tum migration'lar uygulanmis
  const allApplied = listMigrationFiles(MIGRATIONS_DIR).map((f) => ({ name: f.name }));
  const env = DEV_ENV();
  const c = makeClient([
    { match: /to_regclass/, reply: { rows: [{ t: 'schema_migrations' }] } },
    { match: /SELECT name FROM schema_migrations/, reply: { rows: allApplied } },
  ]);
  const o3 = sink();
  const e3 = sink();
  assert.equal(await seedDev.main({ env, Client: c.Client, log: o3.fn, errLog: e3.fn }), 0, e3.lines.join('\n'));
  const texts = c.state.queries.map((q) => q.text);
  const iBegin = texts.indexOf('BEGIN');
  const iCommit = texts.indexOf('COMMIT');
  assert.ok(iBegin >= 0 && iCommit > iBegin);
  const seeds = texts.slice(iBegin + 1, iCommit);
  // tohum sayisi dizinden turetilir (dev_seeds'e dosya eklenmesi testi kirmaz); en az WP-C'nin uc tohumu
  const seedCount = seedDev.listSeedFiles(path.join(MIGRATIONS_DIR, 'dev_seeds')).length;
  assert.ok(seedCount >= 3);
  assert.equal(seeds.length, seedCount);
  assert.ok(seeds.every((s) => !/\{\{/.test(s)), 'yer tutucular doldurulmus olmali');
  assert.ok(seeds.some((s) => /INSERT INTO users/.test(s)), 'kullanici tohumu (002) calistirilmis olmali');
  assert.ok(seeds.join('\n').includes('$2'), 'bcrypt ozeti SQL\'e yazilmis olmali');
  // PAROLA ve PIN hicbir ciktida gorunmez
  const everything = [...o3.lines, ...e3.lines].join('\n');
  assert.ok(!everything.includes(env.DEV_SEED_PASSWORD));
  assert.ok(!everything.includes(env.DEV_SEED_PIN));
  assert.ok(!seeds.join('\n').includes(env.DEV_SEED_PASSWORD), 'SQL\'de duz metin parola olmamali (yalniz ozet)');
});

// -- scripts/create_super_user.js ----------------------------------------------------------------

const SU_ENV = () => ({ DATABASE_URL: URL_OK, MIGRATE_CONFIRM: 'ev_otomasyon', SUPER_USER_EMAIL: 'Yonetici@Ornek.example', SUPER_USER_PASSWORD: rnd(18) });

test('create_super_user: onay ve ortam sirlari zorunlu (parola >= 12, gecerli e-posta)', async () => {
  for (const patch of [{ MIGRATE_CONFIRM: undefined }, { SUPER_USER_EMAIL: undefined }, { SUPER_USER_EMAIL: 'bozuk' }, { SUPER_USER_PASSWORD: 'kisa' }, { SUPER_USER_PASSWORD: undefined }]) {
    const { Client, state } = makeClient();
    const code = await createSuper.main({ env: { ...SU_ENV(), ...patch }, argv: [], Client, log: sink().fn, errLog: sink().fn });
    assert.equal(code, 2, JSON.stringify(Object.keys(patch)));
    assert.equal(state.options, null, 'baglanti acilmamali');
  }
  assert.equal(await createSuper.main({ env: SU_ENV(), argv: ['--bilinmeyen'], Client: makeClient().Client, log: sink().fn, errLog: sink().fn }), 2);
});

test('create_super_user: yeni kullanici bcrypt cost 12 ile olusur; e-posta kucuk harfe; parola cikti/SQL\'de yok', async () => {
  const env = SU_ENV();
  const { Client, state } = makeClient([{ match: /INSERT INTO users/, reply: { rows: [{ id: 'u1' }] } }]);
  const out = sink();
  const err = sink();
  const code = await createSuper.main({ env, argv: [], Client, log: out.fn, errLog: err.fn });
  assert.equal(code, 0, err.lines.join('\n'));
  const ins = state.queries.find((q) => /INSERT INTO users/.test(q.text));
  assert.match(ins.text, /'super_user'/);
  assert.match(ins.text, /ON CONFLICT \(email\) DO NOTHING/);
  assert.equal(ins.params[0], 'yonetici@ornek.example');
  assert.equal(bcrypt.compareSync(env.SUPER_USER_PASSWORD, ins.params[1]), true);
  assert.equal(bcrypt.getRounds(ins.params[1]), 12);
  assert.deepEqual(state.queries.map((q) => q.text).filter((t) => /^(BEGIN|COMMIT|ROLLBACK)/.test(t)), ['BEGIN', 'COMMIT']);
  assert.ok(![...out.lines, ...err.lines].join('\n').includes(env.SUPER_USER_PASSWORD));
  assert.ok(![...out.lines, ...err.lines].join('\n').includes(DB_PASS));
});

test('create_super_user: kullanici zaten varsa DOKUNMAZ; --promote rol, --reset-password parola+oturum', async () => {
  const exists = [{ match: /INSERT INTO users/, reply: { rows: [] } }];

  const plain = makeClient(exists);
  assert.equal(await createSuper.main({ env: SU_ENV(), argv: [], Client: plain.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: sink().fn }), 0);
  assert.ok(!plain.state.queries.some((q) => /^UPDATE users/.test(q.text)));
  assert.deepEqual(plain.state.queries.map((q) => q.text).filter((t) => /^(BEGIN|COMMIT|ROLLBACK)/.test(t)), ['BEGIN', 'ROLLBACK']);

  const promote = makeClient(exists);
  assert.equal(await createSuper.main({ env: SU_ENV(), argv: ['--promote'], Client: promote.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: sink().fn }), 0);
  const up = promote.state.queries.find((q) => /^UPDATE users SET role = 'super_user'/.test(q.text));
  assert.ok(up, 'rol guncellemesi');
  assert.ok(!promote.state.queries.some((q) => /password_hash/.test(q.text) && /^UPDATE/.test(q.text)), 'parolaya dokunulmaz');

  const reset = makeClient(exists);
  const env = SU_ENV();
  assert.equal(await createSuper.main({ env, argv: ['--reset-password'], Client: reset.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: sink().fn }), 0);
  const pw = reset.state.queries.find((q) => /UPDATE users SET password_hash/.test(q.text));
  assert.match(pw.text, /token_version = token_version \+ 1/);
  assert.equal(bcrypt.compareSync(env.SUPER_USER_PASSWORD, pw.params[1]), true);
});

test('create_super_user: veritabani hatasinda ROLLBACK ve cikis 1', async () => {
  const { Client, state } = makeClient([{ match: /INSERT INTO users/, reply: new Error('baglanti koptu') }]);
  const err = sink();
  assert.equal(await createSuper.main({ env: SU_ENV(), argv: [], Client, bcrypt: fastBcrypt, log: sink().fn, errLog: err.fn }), 1);
  assert.deepEqual(state.queries.map((q) => q.text).filter((t) => /^(BEGIN|COMMIT|ROLLBACK)/.test(t)), ['BEGIN', 'ROLLBACK']);
});

// -- scripts/create_backend_mqtt_user.js -----------------------------------------------------------

const BE_ENV = () => ({ DATABASE_URL: URL_OK, MIGRATE_CONFIRM: 'ev_otomasyon', MQTT_BACKEND_USER: 'backend_service', MQTT_BACKEND_PASS: rnd(32) });

test('create_backend_mqtt_user: onay + kullanici adi + parola (>= 24) zorunlu', async () => {
  for (const patch of [{ MIGRATE_CONFIRM: undefined }, { MQTT_BACKEND_PASS: undefined }, { MQTT_BACKEND_PASS: 'kisa-parola' }, { MQTT_BACKEND_USER: 'a b' }, { MQTT_BACKEND_USER: 'x' }]) {
    const { Client, state } = makeClient();
    const code = await createBackend.main({ env: { ...BE_ENV(), ...patch }, Client, log: sink().fn, errLog: sink().fn });
    assert.equal(code, 2, JSON.stringify(Object.keys(patch)));
    assert.equal(state.options, null);
  }
});

test('create_backend_mqtt_user: tablo yoksa acik hata; varsa superuser + backend turu + bcrypt ozeti, parola yazdirilmaz', async () => {
  const missing = makeClient([{ match: /to_regclass/, reply: { rows: [{ t: null }] } }]);
  const e1 = sink();
  assert.equal(await createBackend.main({ env: BE_ENV(), Client: missing.Client, log: sink().fn, errLog: e1.fn }), 1);
  assert.match(e1.lines.join('\n'), /mqtt_credentials tablosu yok/);

  const env = BE_ENV();
  const ok = makeClient([
    { match: /to_regclass/, reply: { rows: [{ t: 'mqtt_credentials' }] } },
    { match: /INSERT INTO mqtt_credentials/, reply: { rows: [{ username: 'backend_service' }] } },
  ]);
  const out = sink();
  const err = sink();
  assert.equal(await createBackend.main({ env, Client: ok.Client, log: out.fn, errLog: err.fn }), 0, err.lines.join('\n'));
  const ins = ok.state.queries.find((q) => /INSERT INTO mqtt_credentials/.test(q.text));
  assert.match(ins.text, /\(username, password_hash, is_superuser, kind, expires_at\)/);
  assert.match(ins.text, /VALUES \(\$1, \$2, TRUE, 'backend', NULL\)/);
  assert.match(ins.text, /WHERE mqtt_credentials\.kind = 'backend'/, 'cihaz/uygulama kimligi ezilmemeli');
  assert.equal(ins.params[0], 'backend_service');
  assert.equal(bcrypt.compareSync(env.MQTT_BACKEND_PASS, ins.params[1]), true);
  assert.equal(bcrypt.getRounds(ins.params[1]), 12);
  assert.ok(![...out.lines, ...err.lines].join('\n').includes(env.MQTT_BACKEND_PASS));
});

test('create_backend_mqtt_user: kullanici adi baska turde bir kimlige aitse DEGISTIRMEZ; CHECK ihlalinde ipucu', async () => {
  const taken = makeClient([
    { match: /to_regclass/, reply: { rows: [{ t: 'x' }] } },
    { match: /INSERT INTO mqtt_credentials/, reply: { rows: [] } },
  ]);
  const e = sink();
  assert.equal(await createBackend.main({ env: BE_ENV(), Client: taken.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: e.fn }), 1);
  assert.match(e.lines.join('\n'), /backend disi bir kimlige ait/);

  const check = makeClient([
    { match: /to_regclass/, reply: { rows: [{ t: 'x' }] } },
    { match: /INSERT INTO mqtt_credentials/, reply: Object.assign(new Error('check'), { code: '23514' }) },
  ]);
  const e2 = sink();
  assert.equal(await createBackend.main({ env: BE_ENV(), Client: check.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: e2.fn }), 1);
  assert.match(e2.lines.join('\n'), /"backend" turunu reddetti/);
});

// -- scripts/upgrade_legacy_mqtt_user.js --------------------------------------------------------------

const LG_ENV = (pass) => ({ DATABASE_URL: URL_OK, MIGRATE_CONFIRM: 'ev_otomasyon', LEGACY_MQTT_USER: 'home_101', LEGACY_MQTT_PASS: pass });

test('upgrade_legacy: dogru parola -> SHA-256 satir bcrypt\'e yukseltilir (yalnizca eski ozet hala aynıysa)', async () => {
  const pass = rnd(16);
  const stored = crypto.createHash('sha256').update(pass).digest('hex');
  const { Client, state } = makeClient([
    { match: /SELECT password_hash, is_superuser FROM mqtt_users/, reply: { rows: [{ password_hash: stored, is_superuser: false }] } },
    { match: /UPDATE mqtt_users/, reply: { rows: [], rowCount: 1 } },
  ]);
  const out = sink();
  const err = sink();
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(pass), Client, log: out.fn, errLog: err.fn }), 0, err.lines.join('\n'));
  const up = state.queries.find((q) => /UPDATE mqtt_users/.test(q.text));
  assert.match(up.text, /WHERE username = \$1 AND password_hash = \$3/);
  assert.equal(up.params[0], 'home_101');
  assert.equal(bcrypt.compareSync(pass, up.params[1]), true);
  assert.equal(up.params[2], stored);
  assert.ok(![...out.lines, ...err.lines].join('\n').includes(pass));
});

test('upgrade_legacy: yanlis parola / superuser / satir yok / yaris -> DEGISIKLIK YOK', async () => {
  const pass = rnd(16);
  const stored = crypto.createHash('sha256').update(pass).digest('hex');

  const wrong = makeClient([{ match: /SELECT password_hash/, reply: { rows: [{ password_hash: stored, is_superuser: false }] } }]);
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(rnd(16)), Client: wrong.Client, log: sink().fn, errLog: sink().fn }), 1);
  assert.ok(!wrong.state.queries.some((q) => /^UPDATE/.test(q.text)));

  const su = makeClient([{ match: /SELECT password_hash/, reply: { rows: [{ password_hash: stored, is_superuser: true }] } }]);
  const e = sink();
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(pass), Client: su.Client, log: sink().fn, errLog: e.fn }), 1);
  assert.match(e.lines.join('\n'), /Legacy superuser/);
  assert.ok(!su.state.queries.some((q) => /^UPDATE/.test(q.text)));

  const none = makeClient([{ match: /SELECT password_hash/, reply: { rows: [] } }]);
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(pass), Client: none.Client, log: sink().fn, errLog: sink().fn }), 1);

  const race = makeClient([
    { match: /SELECT password_hash/, reply: { rows: [{ password_hash: stored, is_superuser: false }] } },
    { match: /UPDATE mqtt_users/, reply: { rows: [], rowCount: 0 } },
  ]);
  const e3 = sink();
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(pass), Client: race.Client, bcrypt: fastBcrypt, log: sink().fn, errLog: e3.fn }), 1);
  assert.match(e3.lines.join('\n'), /bu arada degisti/);
});

test('upgrade_legacy: zaten bcrypt ise parola dogruysa 0 (degisiklik yok), yanlissa 1', async () => {
  const pass = rnd(16);
  const hash = bcrypt.hashSync(pass, 4);
  const mk = () => makeClient([{ match: /SELECT password_hash/, reply: { rows: [{ password_hash: hash, is_superuser: false }] } }]);
  const a = mk();
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(pass), Client: a.Client, log: sink().fn, errLog: sink().fn }), 0);
  assert.ok(!a.state.queries.some((q) => /^UPDATE/.test(q.text)));
  const b = mk();
  assert.equal(await upgradeLegacy.main({ env: LG_ENV(rnd(16)), Client: b.Client, log: sink().fn, errLog: sink().fn }), 1);
});

test('upgrade_legacy: onay ve kullanici adi dogrulamasi', async () => {
  for (const patch of [{ MIGRATE_CONFIRM: undefined }, { LEGACY_MQTT_USER: 'a b' }, { LEGACY_MQTT_USER: undefined }, { LEGACY_MQTT_PASS: undefined }]) {
    const { Client, state } = makeClient();
    assert.equal(await upgradeLegacy.main({ env: { ...LG_ENV(rnd(8)), ...patch }, Client, log: sink().fn, errLog: sink().fn }), 2);
    assert.equal(state.options, null);
  }
  assert.equal(upgradeLegacy.safeEqualHex('ab', 'abc'), false);
  assert.equal(upgradeLegacy.safeEqualHex('ab', 'ab'), true);
});
