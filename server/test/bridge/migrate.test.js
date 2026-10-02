'use strict';

// C8 - Migration calistiricisi (scripts/migrate.js): siralama, transaction sarmalayicisi,
// hedef onayi, baseline, hata geri alma, checksum. Gercek PostgreSQL YOKTUR: sahte pg istemcisi.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  main,
  parseArgs,
  listMigrationFiles,
  checksum,
  versionOf,
  maskSql,
  stripTransactionWrapper,
  findTransactionControl,
  hasNoTransactionDirective,
  planMigrations,
  MIGRATIONS_DIR,
  ADVISORY_LOCK_KEY,
} = require('../../scripts/migrate');

// -- Bellek ici dosya sistemi ----------------------------------------------------------
function memFs(files, dirs = []) {
  return {
    readdirSync: () => [
      ...Object.keys(files).map((name) => ({ name, isFile: () => true })),
      ...dirs.map((name) => ({ name, isFile: () => false })),
    ],
    readFileSync: (p) => {
      const name = path.basename(p);
      if (!(name in files)) throw new Error(`yok: ${name}`);
      return files[name];
    },
  };
}

// -- Sahte pg istemcisi -------------------------------------------------------------------
function makeClientClass(state) {
  return class FakeClient {
    constructor(opts) {
      state.options = opts;
    }
    async connect() {
      state.connected = true;
    }
    async end() {
      state.ended = true;
    }
    async query(text, params) {
      state.queries.push({ text, params });
      const t = String(text);
      if (/to_regclass/.test(t)) {
        const name = String(params[0]).replace('public.', '');
        const exists = name === 'schema_migrations' ? state.hasTable : state.tables.includes(name);
        return { rows: [{ t: exists ? name : null }] };
      }
      if (/FROM schema_migrations/.test(t)) return { rows: state.applied.map((a) => ({ ...a })) };
      if (/CREATE TABLE IF NOT EXISTS schema_migrations/.test(t)) {
        state.hasTable = true;
        return { rows: [] };
      }
      if (/pg_try_advisory_lock/.test(t)) return { rows: [{ ok: state.lockOk }] };
      if (/^INSERT INTO schema_migrations/.test(t)) {
        state.applied.push({
          name: params[0],
          version: params[1],
          checksum: /NULL, TRUE/.test(t) ? null : params[2],
          baseline: /TRUE, 0\)/.test(t),
          applied_at: new Date(0),
        });
        return { rows: [], rowCount: 1 };
      }
      if (state.failOn && t.includes(state.failOn)) throw Object.assign(new Error('simule edilen hata'), { position: '12' });
      if (!/^(BEGIN|COMMIT|ROLLBACK|SET |SELECT pg_advisory_unlock)/.test(t)) state.executed.push(t);
      return { rows: [], rowCount: 0 };
    }
  };
}

function newState(over = {}) {
  return { queries: [], executed: [], applied: [], hasTable: false, tables: [], lockOk: true, failOn: null, ...over };
}

const URL_OK = 'postgresql://app_user:s3cret-pass-word@127.0.0.1:5434/ev_otomasyon';

function run(files, { argv = [], env = {}, state = newState(), dirs = [] } = {}) {
  const out = [];
  const err = [];
  return main({
    argv,
    env: { DATABASE_URL: URL_OK, ...env },
    dir: '/migrations',
    fsApi: memFs(files, dirs),
    Client: makeClientClass(state),
    log: (...a) => out.push(a.join(' ')),
    errLog: (...a) => err.push(a.join(' ')),
  }).then((code) => ({ code, out, err, state }));
}

const FILES = {
  '001_a.sql': 'CREATE TABLE a(id int); -- MARK_A',
  '002_b.sql': 'BEGIN;\nCREATE TABLE b(id int); -- MARK_B\nCOMMIT;\n',
  '003_c.sql': 'CREATE TABLE c(id int); -- MARK_C',
};

// -- Saf yardimcilar -------------------------------------------------------------------------

test('versionOf: onde gelen sayi; "010b" -> 10; sayisiz -> null', () => {
  assert.equal(versionOf('001_a.sql'), 1);
  assert.equal(versionOf('010b_x.sql'), 10);
  assert.equal(versionOf('022_scheduled.sql'), 22);
  assert.equal(versionOf('x_001.sql'), null);
});

test('listMigrationFiles: duz metin siralamasi (010 < 010b < 011), yalniz ust duzey .sql, alt dizin yok', () => {
  const files = listMigrationFiles(
    '/m',
    memFs({
      '011_scheduled_rules.sql': '',
      '010b_prereq.sql': '',
      '010_night.sql': '',
      '004_home_invitations_schema.sql': '',
      '004_device_inventory_serial.sql': '',
      '002_x.sql': '',
      'notes.txt': '',
      'run_011.js': '',
    }, ['dev_seeds'])
  );
  // .txt ve .js listelenmez (yalniz .sql); dev_seeds dizin oldugu icin listelenmez
  assert.deepEqual(
    files.map((f) => f.name),
    [
      '002_x.sql',
      '004_device_inventory_serial.sql',
      '004_home_invitations_schema.sql',
      '010_night.sql',
      '010b_prereq.sql',
      '011_scheduled_rules.sql',
    ]
  );
  assert.equal(files.find((f) => f.name.startsWith('010b')).version, 10);
});

test('listMigrationFiles: sayiyla baslamayan .sql dosyasi hatadir', () => {
  assert.throws(() => listMigrationFiles('/m', memFs({ 'notes.sql': '' })), /sayiyla baslamali/);
});

test('GERCEK migrations/ dizini: dogru sira, tohum yok, dev_seeds disarida', () => {
  const files = listMigrationFiles(MIGRATIONS_DIR);
  const names = files.map((f) => f.name);
  assert.ok(names.indexOf('010_night_peace_and_child_lock.sql') < names.indexOf('010b_scheduled_rules_uuid_prereq.sql'));
  assert.ok(names.indexOf('010b_scheduled_rules_uuid_prereq.sql') < names.indexOf('011_scheduled_rules.sql'));
  assert.ok(names.includes('022_scheduled_rules_fix.sql'));
  assert.equal(names.includes('002_seed_initial_data.sql'), false, '002 tohumu dev_seeds\'e tasindi');
  assert.equal(names.some((n) => n.includes('dev_seeds')), false);
  // siralama deterministik (kopyasi siralanmis hal ile ayni)
  assert.deepEqual(names, [...names].sort());
  // her dosyanin sayisal onekli versiyonu var ve eski numaralar bozulmamis
  for (const n of ['001_multi_tenant_schema.sql', '011_scheduled_rules.sql', '016_remove_installer_role.sql', '017_device_claim_otp.sql']) {
    assert.ok(names.includes(n), `${n} yerinde olmali`);
  }
});

test('checksum: satir sonu (CRLF/LF) farki ozeti degistirmez', () => {
  assert.equal(checksum('a\r\nb\r\n'), checksum('a\nb\n'));
  assert.notEqual(checksum('a\nb\n'), checksum('a\nc\n'));
  assert.match(checksum('x'), /^[0-9a-f]{64}$/);
});

test('maskSql: yorum, tirnakli metin ve dolar-tirnakli govdeyi bosaltir; konumlar korunur', () => {
  const sql = "SELECT 'BEGIN;' -- COMMIT;\n/* ROLLBACK; */ DO $$ BEGIN; END $$; SELECT $tag$COMMIT;$tag$;";
  const masked = maskSql(sql);
  assert.equal(masked.length, sql.length);
  assert.doesNotMatch(masked, /BEGIN|COMMIT|ROLLBACK/);
  assert.match(masked, /SELECT/);
  // cift tirnak kacisi
  assert.doesNotMatch(maskSql("SELECT 'it''s COMMIT;'"), /COMMIT/);
});

test('stripTransactionWrapper: bastaki BEGIN; ve sondaki COMMIT; sokulur, yorumlar korunur', () => {
  const sql = '-- baslik\n\nBEGIN;\nCREATE TABLE x(i int);\nCOMMIT;\n-- son\n';
  const { sql: out, stripped } = stripTransactionWrapper(sql);
  assert.equal(stripped, true);
  assert.match(out, /-- baslik/);
  assert.match(out, /CREATE TABLE x/);
  assert.doesNotMatch(out, /\bBEGIN\s*;/);
  assert.doesNotMatch(out, /\bCOMMIT\s*;/);
  assert.match(out, /-- son/);
  assert.deepEqual(findTransactionControl(out), []);
});

test('stripTransactionWrapper: START TRANSACTION / COMMIT WORK varyantlari; sarmalayici yoksa degismez', () => {
  assert.equal(stripTransactionWrapper('START TRANSACTION;\nSELECT 1;\nCOMMIT WORK;').stripped, true);
  const plain = 'CREATE TABLE y(i int);\nCREATE INDEX i ON y(i);\n';
  assert.deepEqual(stripTransactionWrapper(plain), { sql: plain, stripped: false });
});

test('stripTransactionWrapper: plpgsql govdesindeki BEGIN/END ve DO bloklarina DOKUNMAZ', () => {
  const sql = "DO $$\nBEGIN\n  PERFORM 1;\nEND $$;\nCREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql;\n";
  const r = stripTransactionWrapper(sql);
  assert.equal(r.stripped, false);
  assert.equal(r.sql, sql);
  assert.deepEqual(findTransactionControl(sql), []);
});

test('findTransactionControl: ortadaki BEGIN/COMMIT/ROLLBACK atomikligi bozar -> tespit edilir', () => {
  assert.deepEqual(findTransactionControl('SELECT 1;\nCOMMIT;\nSELECT 2;'), ['COMMIT']);
  assert.deepEqual(findTransactionControl('SELECT 1; BEGIN; SELECT 2; ROLLBACK;'), ['BEGIN', 'ROLLBACK']);
  assert.deepEqual(findTransactionControl("SELECT 'COMMIT;';"), []);
  assert.deepEqual(findTransactionControl('-- COMMIT;\nSELECT 1;'), []);
});

test('hasNoTransactionDirective: yalnizca ilk satirlardaki yonerge', () => {
  assert.equal(hasNoTransactionDirective('-- migrate:no-transaction\nCREATE INDEX CONCURRENTLY ...'), true);
  assert.equal(hasNoTransactionDirective('/* x */\n-- migrate:no-transaction'), true);
  assert.equal(hasNoTransactionDirective('SELECT 1;'), false);
  assert.equal(hasNoTransactionDirective('\n'.repeat(30) + '-- migrate:no-transaction'), false);
});

test('GERCEK migration dosyalari: hepsi tek transaction icinde uygulanabilir (sarmalayici sokulunce orta BEGIN/COMMIT YOK)', () => {
  const files = listMigrationFiles(MIGRATIONS_DIR);
  assert.ok(files.length >= 20);
  const wrapped = [];
  for (const f of files) {
    const raw = fs.readFileSync(path.join(MIGRATIONS_DIR, f.name), 'utf8');
    if (hasNoTransactionDirective(raw)) continue;
    const prepared = stripTransactionWrapper(raw);
    if (prepared.stripped) wrapped.push(f.name);
    assert.deepEqual(findTransactionControl(prepared.sql), [], `${f.name}: dosya kendi transaction'ini yonetiyor`);
  }
  // eski dosyalarin bir kismi BEGIN/COMMIT'li (011, 012, 013, 016, 017); runner bunlari sokuyor
  for (const name of ['011_scheduled_rules.sql', '012_social_and_otp_auth.sql', '013_password_reset.sql', '016_remove_installer_role.sql', '017_device_claim_otp.sql']) {
    assert.ok(wrapped.includes(name), `${name} sarmalayicisi sokulmeli`);
  }
});

test('planMigrations: bekleyenler, diskte olmayanlar, sira disi uyarisi, --to siniri', () => {
  const files = [
    { name: '001_a.sql', version: 1 },
    { name: '002_b.sql', version: 2 },
    { name: '003_c.sql', version: 3 },
    { name: '004_d.sql', version: 4 },
  ];
  const applied = new Map([
    ['001_a.sql', {}],
    ['003_c.sql', {}],
    ['000_gone.sql', {}],
  ]);
  const p = planMigrations(files, applied);
  assert.deepEqual(p.pending.map((f) => f.name), ['002_b.sql', '004_d.sql']);
  assert.deepEqual(p.missing, ['000_gone.sql']);
  assert.deepEqual(p.outOfOrder, ['002_b.sql']);
  assert.deepEqual(planMigrations(files, new Map(), { to: 2 }).pending.map((f) => f.name), ['001_a.sql', '002_b.sql']);
});

test('parseArgs: bayraklar ve hatalar', () => {
  assert.deepEqual(parseArgs([]).errors, []);
  assert.equal(parseArgs(['--status']).status, true);
  assert.equal(parseArgs(['--dry-run']).dryRun, true);
  assert.equal(parseArgs(['--baseline', '17']).baseline, 17);
  assert.equal(parseArgs(['--to', '22']).to, 22);
  assert.ok(parseArgs(['--baseline']).errors.length > 0);
  assert.ok(parseArgs(['--baseline', 'abc']).errors.length > 0);
  assert.ok(parseArgs(['--bogus']).errors.length > 0);
  assert.ok(parseArgs(['--baseline', '5', '--to', '6']).errors.length > 0);
});

// -- main: hedef ve onay -----------------------------------------------------------------------

test('main: DATABASE_URL yoksa veya gecersizse CIKIS 2, baglanti denenmez', async () => {
  for (const url of [undefined, '', 'notaurl', 'mysql://u@h/db', 'postgres://u@h']) {
    const state = newState();
    const r = await run(FILES, { env: { DATABASE_URL: url }, state });
    assert.equal(r.code, 2, String(url));
    assert.equal(state.connected, undefined, 'baglanti acilmamali');
  }
});

test('main: hedef host/db YAZDIRILIR, parola ASLA yazdirilmaz', async () => {
  const r = await run(FILES, { argv: ['--dry-run'] });
  const all = [...r.out, ...r.err].join('\n');
  assert.match(r.out[0], /^Hedef: app_user@127\.0\.0\.1:5434\/ev_otomasyon$/);
  assert.ok(!all.includes('s3cret-pass-word'), 'parola cikti icinde olmamali');
});

test('main: degisiklik yapan mod MIGRATE_CONFIRM ister (yok/yanlis -> 2, hicbir sorgu yok)', async () => {
  for (const confirm of [undefined, '', 'baska_db', 'EV_OTOMASYON']) {
    const state = newState();
    const r = await run(FILES, { env: { MIGRATE_CONFIRM: confirm }, state });
    assert.equal(r.code, 2, String(confirm));
    assert.equal(state.queries.length, 0, 'onaysiz hicbir sorgu calismamali');
    assert.match(r.err.join('\n'), /MIGRATE_CONFIRM/);
  }
});

test('main: --status ve --dry-run onay GEREKTIRMEZ ve hicbir sey yazmaz', async () => {
  for (const argv of [['--status'], ['--dry-run']]) {
    const state = newState();
    const r = await run(FILES, { argv, state });
    assert.equal(r.code, 0);
    assert.equal(state.queries.some((q) => /^(BEGIN|CREATE TABLE|INSERT|SELECT pg_try_advisory_lock)/.test(q.text)), false);
    assert.equal(state.executed.length, 0);
  }
});

test('main: --status uygulanmis/bekleyen listeler ve degismis icerigi isaretler', async () => {
  const state = newState({
    hasTable: true,
    applied: [
      { name: '001_a.sql', version: 1, checksum: checksum(FILES['001_a.sql']), baseline: false, applied_at: new Date(0) },
      { name: '002_b.sql', version: 2, checksum: 'degismis-ozet', baseline: false, applied_at: new Date(0) },
    ],
  });
  const r = await run(FILES, { argv: ['--status'], state });
  const text = r.out.join('\n');
  assert.match(text, /\[uygulandi\] 001_a\.sql/);
  assert.match(text, /\[uygulandi\] 002_b\.sql.*ICERIK DEGISMIS/);
  assert.match(text, /\[bekliyor \] 003_c\.sql/);
  assert.equal(r.code, 1, 'icerik degisimi durum kodunu 1 yapar');
});

// -- main: uygulama ------------------------------------------------------------------------------

test('main: bekleyenleri sirayla, HER DOSYA TEK TRANSACTION ve kayitla uygular (BEGIN/COMMIT sarmalayicisi sokulur)', async () => {
  const r = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' } });
  assert.equal(r.code, 0, r.err.join('\n'));

  const kinds = r.state.queries
    .map((q) => q.text)
    .filter((t) => /^(BEGIN|COMMIT|ROLLBACK|INSERT INTO schema_migrations)/.test(t))
    .map((t) => t.split(' ')[0] + (t.startsWith('INSERT') ? ':ins' : ''));
  assert.deepEqual(kinds, ['BEGIN', 'INSERT:ins', 'COMMIT', 'BEGIN', 'INSERT:ins', 'COMMIT', 'BEGIN', 'INSERT:ins', 'COMMIT']);

  assert.equal(r.state.executed.length, 3);
  assert.match(r.state.executed[0], /MARK_A/);
  assert.match(r.state.executed[1], /MARK_B/);
  assert.match(r.state.executed[2], /MARK_C/);
  assert.doesNotMatch(r.state.executed[1], /\bBEGIN\s*;/, 'dosyanin kendi BEGIN;i sokulmus olmali');
  assert.doesNotMatch(r.state.executed[1], /\bCOMMIT\s*;/);

  assert.deepEqual(r.state.applied.map((a) => a.name), ['001_a.sql', '002_b.sql', '003_c.sql']);
  // checksum ORIJINAL dosya iceriginden (sokulmemis)
  assert.equal(r.state.applied[1].checksum, checksum(FILES['002_b.sql']));
  assert.equal(r.state.applied.every((a) => a.baseline === false), true);
});

test('main: oturum ayarlari (statement_timeout=0, lock_timeout) ve tek calistirici kilidi', async () => {
  const r = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' } });
  const texts = r.state.queries.map((q) => q.text);
  assert.ok(texts.includes('SET statement_timeout = 0'));
  assert.ok(texts.includes('SET lock_timeout = 15000'));
  const lock = r.state.queries.find((q) => /pg_try_advisory_lock/.test(q.text));
  assert.deepEqual(lock.params, [ADVISORY_LOCK_KEY]);
  assert.ok(r.state.queries.some((q) => /pg_advisory_unlock/.test(q.text)), 'kilit birakilmali');
  assert.equal(r.state.ended, true);
});

test('main: kilit alinamazsa (baska calistirici) CIKIS 1 ve hicbir migration calismaz', async () => {
  const state = newState({ lockOk: false });
  const r = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state });
  assert.equal(r.code, 1);
  assert.equal(state.executed.length, 0);
  assert.match(r.err.join('\n'), /Baska bir migrate/);
});

test('main: ikinci dosya hata verirse ROLLBACK, durur, ucuncusu CALISMAZ, birinci kayitli kalir', async () => {
  const state = newState({ failOn: 'MARK_B' });
  const r = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state });
  assert.equal(r.code, 1);
  assert.deepEqual(state.applied.map((a) => a.name), ['001_a.sql']);
  assert.equal(state.executed.some((s) => /MARK_C/.test(s)), false, 'sonraki migration calismamali');
  const seq = state.queries.map((q) => q.text).filter((t) => /^(BEGIN|COMMIT|ROLLBACK)/.test(t));
  assert.deepEqual(seq, ['BEGIN', 'COMMIT', 'BEGIN', 'ROLLBACK']);
  assert.match(r.err.join('\n'), /002_b\.sql uygulanamadi \(geri alindi\)/);
});

test('main: uygulanmis dosya icerigi degismisse DURUR (checksum); bilincli istisna ile devam', async () => {
  const mk = () =>
    newState({
      hasTable: true,
      applied: [{ name: '001_a.sql', version: 1, checksum: 'eski-ozet', baseline: false, applied_at: new Date(0) }],
    });
  const blocked = mk();
  const r1 = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state: blocked });
  assert.equal(r1.code, 1);
  assert.equal(blocked.executed.length, 0);
  assert.match(r1.err.join('\n'), /icerigi degismis/);

  const allowed = mk();
  const r2 = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon', MIGRATE_ALLOW_CHECKSUM_MISMATCH: 'true' }, state: allowed });
  assert.equal(r2.code, 0);
  assert.equal(allowed.executed.length, 2);
});

test('main: baseline kayitlarinin checksum\'u yok -> icerik degisse de engel degil', async () => {
  const state = newState({
    hasTable: true,
    applied: [{ name: '001_a.sql', version: 1, checksum: null, baseline: true, applied_at: new Date(0) }],
  });
  const r = await run({ ...FILES, '001_a.sql': 'tamamen farkli icerik' }, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state });
  assert.equal(r.code, 0);
  assert.equal(state.executed.length, 2);
});

test('main: --to N yalnizca N\'ye kadar uygular; --dry-run uygulamaz ama listeler', async () => {
  const state = newState();
  const r = await run(FILES, { argv: ['--to', '2'], env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state });
  assert.equal(r.code, 0);
  assert.deepEqual(state.applied.map((a) => a.name), ['001_a.sql', '002_b.sql']);

  const dry = await run(FILES, { argv: ['--dry-run'] });
  assert.match(dry.out.join('\n'), /3 bekleyen migration/);
  assert.match(dry.out.join('\n'), /hicbir sey uygulanmadi/);
});

test('main: bekleyen yoksa "Bekleyen migration yok" ve temiz cikis', async () => {
  const applied = Object.entries(FILES).map(([name, sql], i) => ({ name, version: i + 1, checksum: checksum(sql), baseline: false, applied_at: new Date(0) }));
  const r = await run(FILES, { env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state: newState({ hasTable: true, applied }) });
  assert.equal(r.code, 0);
  assert.match(r.out.join('\n'), /Bekleyen migration yok/);
});

test('main: dosya ORTADA kendi BEGIN/COMMIT\'ini yonetiyorsa reddedilir; no-transaction yonergesiyle transaction disi calisir', async () => {
  const bad = await run(
    { '001_a.sql': 'SELECT 1;\nCOMMIT;\nSELECT 2;' },
    { env: { MIGRATE_CONFIRM: 'ev_otomasyon' } }
  );
  assert.equal(bad.code, 1);
  assert.match(bad.err.join('\n'), /kendi transaction'ini yonetiyor/);

  const noTx = await run(
    { '001_a.sql': '-- migrate:no-transaction\nCREATE INDEX CONCURRENTLY i ON t(c); -- MARK_NT' },
    { env: { MIGRATE_CONFIRM: 'ev_otomasyon' } }
  );
  assert.equal(noTx.code, 0);
  const texts = noTx.state.queries.map((q) => q.text);
  assert.equal(texts.includes('BEGIN'), false, 'transaction disi: BEGIN yok');
  assert.ok(noTx.state.executed.some((s) => /MARK_NT/.test(s)));
});

// -- main: baseline ------------------------------------------------------------------------------

test('main: --baseline N dosyalari CALISTIRMADAN isaretler (checksum bos, baseline=true)', async () => {
  const state = newState({ tables: ['users', 'homes', 'home_users', 'devices', 'endpoints'] });
  const r = await run(FILES, { argv: ['--baseline', '2'], env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state });
  assert.equal(r.code, 0, r.err.join('\n'));
  assert.equal(state.executed.length, 0, 'baseline hicbir dosyayi calistirmaz');
  assert.deepEqual(state.applied.map((a) => a.name), ['001_a.sql', '002_b.sql']);
  assert.equal(state.applied.every((a) => a.checksum === null && a.baseline === true), true);
  const seq = state.queries.map((q) => q.text).filter((t) => /^(BEGIN|COMMIT|ROLLBACK)/.test(t));
  assert.deepEqual(seq, ['BEGIN', 'COMMIT']);
});

test('main: baseline guvenlikleri - onay, bos olmayan tablo, bilinen tablolar, --force', async () => {
  // onaysiz
  const noConfirm = await run(FILES, { argv: ['--baseline', '2'] });
  assert.equal(noConfirm.code, 2);

  // kayit varsa
  const nonEmpty = newState({ hasTable: true, tables: ['users', 'homes', 'home_users', 'devices', 'endpoints'], applied: [{ name: '001_a.sql', version: 1, checksum: null, baseline: true, applied_at: new Date(0) }] });
  const r1 = await run(FILES, { argv: ['--baseline', '2'], env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state: nonEmpty });
  assert.equal(r1.code, 1);
  assert.match(r1.err.join('\n'), /zaten kayit iceriyor/);

  // bos veritabani (canli degil) -> reddedilir; --force ile gecer
  const empty = newState();
  const r2 = await run(FILES, { argv: ['--baseline', '2'], env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state: empty });
  assert.equal(r2.code, 1);
  assert.match(r2.err.join('\n'), /beklenen tablolar yok/);
  assert.equal(empty.applied.length, 0);

  const forced = newState();
  const r3 = await run(FILES, { argv: ['--baseline', '2', '--force'], env: { MIGRATE_CONFIRM: 'ev_otomasyon' }, state: forced });
  assert.equal(r3.code, 0);
  assert.equal(forced.applied.length, 2);
});

test('baseline sonrasi gercek zincir: --baseline 17 sonrasi bekleyenler DIZINDEN TURETILIR (baska paketler migration ekleyince kirilmaz)', async () => {
  const files = listMigrationFiles(MIGRATIONS_DIR);
  const BASELINE = 17;
  const applied = new Map(files.filter((f) => f.version <= BASELINE).map((f) => [f.name, {}]));
  const plan = planMigrations(files, applied);
  assert.ok(files.filter((f) => f.version <= BASELINE).some((f) => f.name.startsWith('010b_')), '010b baseline kapsaminda');

  // Beklenen liste dizinden BAGIMSIZ okunur: numarasi > baseline olan her NNN_*.sql (listMigrationFiles'a guvenilmez)
  const expected = fs
    .readdirSync(MIGRATIONS_DIR, { withFileTypes: true })
    .filter((e) => e.isFile() && /^\d+.*\.sql$/.test(e.name))
    .map((e) => e.name)
    .filter((n) => parseInt(n, 10) > BASELINE)
    .sort();
  assert.ok(expected.length > 0, 'baseline sonrasi en az bir migration olmali');
  assert.deepEqual(plan.pending.map((f) => f.name), expected);

  // Zincir saglik denetimi: numaralar artan ve (baseline sonrasi) TEKRARSIZ, sira disi dosya yok
  const nums = plan.pending.map((f) => f.version);
  assert.deepEqual(nums, [...nums].sort((a, b) => a - b), 'numaralar artan olmali');
  assert.equal(new Set(nums).size, nums.length, `baseline sonrasi numaralar tekrarsiz olmali: ${nums.join(',')}`);
  assert.deepEqual(plan.outOfOrder, []);
  assert.deepEqual(plan.missing, []);

  // Sabit ALT KUME: WP-A/B/C'nin 018..025 zinciri bekleyenlerin icinde ve SIRAYLA (arada baskalari olabilir)
  const prefixes = plan.pending.map((f) => f.name.slice(0, 3));
  const mustHave = ['018', '019', '020', '021', '022', '023', '024', '025'];
  const positions = mustHave.map((p) => prefixes.indexOf(p));
  assert.deepEqual(
    positions.map((p, i) => [mustHave[i], p >= 0]),
    mustHave.map((p) => [p, true]),
    'WP-A/B/C migration\'lari (018-025) bekleyenler arasinda olmali'
  );
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b), '018-025 sirasi korunmali');
});

test('migration dizini: 018 ve sonrasinda numara cakismasi yok; eski tekrarlar yalnizca bilinen 004 cifti ve 010/010b', () => {
  const files = listMigrationFiles(MIGRATIONS_DIR);
  const byVersion = new Map();
  for (const f of files) byVersion.set(f.version, [...(byVersion.get(f.version) || []), f.name]);
  const repeated = [...byVersion].filter(([, names]) => names.length > 1);

  // Paketler arasi numara cakismasi (ornegin iki ayri 026) yasak: sira belirsiz olurdu
  assert.deepEqual(
    repeated.filter(([v]) => v >= 18).map(([v, names]) => `${v}: ${names.join(' + ')}`),
    [],
    'baska bir paket ayni migration numarasini almis olabilir'
  );

  // Tarihsel (dondurulmus) istisnalar: iki adet 004 (dosya adina gore deterministik) ve 010 + 010b (taze kurulum onkosulu)
  assert.deepEqual(repeated.filter(([v]) => v < 18).map(([v]) => v), [4, 10]);
  assert.deepEqual(byVersion.get(4), ['004_device_inventory_serial_and_status.sql', '004_home_invitations_schema.sql']);
  assert.deepEqual(byVersion.get(10), ['010_night_peace_and_child_lock.sql', '010b_scheduled_rules_uuid_prereq.sql']);
});
